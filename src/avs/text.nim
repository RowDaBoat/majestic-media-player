# Ported from Advanced Visualization Studio 2.81d, Copyright 2005 Nullsoft, Inc.
# BSD license: assets/licenses/AVS-Nullsoft-BSD.txt

## Render / Text (r_text.cpp): words from the preset's text, one at a time,
## drawn in the font it names. GDI drew them into a bitmap filled with a
## "clip color", and every pixel that isn't that color went onto the frame;
## here pixie draws them, antialiased against the clip color as Windows'
## font smoothing did, from the font file the system has for that name
## (fontconfig on Linux, GDI's own font on Windows). A symbol font's bytes
## (Webdings, Wingdings, charset 2) are its U+F0xx glyphs, as GDI mapped them;
## when the font isn't installed, the system's substitute draws the bytes.

import std/[math, strutils, tables, unicode]
import pixie, pixie/fontformats/opentype
import core, list

const
  DtCenter = 1
  DtRight = 2
  DtVCenter = 4
  DtBottom = 8
  SymbolCharset = 2'u8
  Cp1252High: array[32, uint16] = [  # 0x80..0x9f
    0x20AC'u16, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160,
    0x2039, 0x0152, 0x8D, 0x017D, 0x8F, 0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013,
    0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178]

type
  LogFont = object
    height, width, escapement, weight: int32
    italic, charset: uint8
    face: string

  FontFace = ref object
    tf: OpenType           ## nil: no font at all, nothing is drawn
    scale: float32         ## pixels per font unit
    sx: float32            ## horizontal stretch (lfWidth)
    ascent, height: int    ## tmAscent, tmHeight
    symbol: bool

# --- finding a font file ------------------------------------------------------------------

var typefaces {.threadvar.}: Table[string, OpenType]

proc parseFace(data: string, index: int): OpenType =
  try:
    if data.len >= 4 and data[0 .. 3] == "ttcf":
      let all = parseOpenTypeCollection(data)
      if all.len == 0: return nil
      result = all[clamp(index, 0, all.high)]
    else:
      result = parseOpenType(data)  # TrueType and CFF outlines alike
  except CatchableError:
    result = nil

when defined(windows):
  import ../win32api

  type LogFontA = object
    lfHeight, lfWidth, lfEscapement, lfOrientation, lfWeight: int32
    lfItalic, lfUnderline, lfStrikeOut, lfCharSet, lfOutPrecision,
      lfClipPrecision, lfQuality, lfPitchAndFamily: uint8
    lfFaceName: array[32, char]

  proc CreateFontIndirectA(lf: ptr LogFontA): HANDLE {.stdcall, dynlib: "gdi32", importc.}
  proc CreateCompatibleDC(dc: HDC): HDC {.stdcall, dynlib: "gdi32", importc.}
  proc DeleteDC(dc: HDC): int32 {.stdcall, dynlib: "gdi32", importc.}
  proc SelectObject(dc: HDC, o: HANDLE): HANDLE {.stdcall, dynlib: "gdi32", importc.}
  proc DeleteObject(o: HANDLE): int32 {.stdcall, dynlib: "gdi32", importc.}
  proc GetFontData(dc: HDC, table, offset: uint32, buf: pointer, size: uint32): uint32 {.
    stdcall, dynlib: "gdi32", importc.}

  proc systemTypeface(lf: LogFont): OpenType =
    ## The font GDI itself picks for the LOGFONT, read back from GDI.
    var g = LogFontA(lfHeight: -100, lfWeight: lf.weight, lfItalic: lf.italic,
                     lfCharSet: lf.charset)
    for i, c in lf.face:
      if i >= 31: break
      g.lfFaceName[i] = c
    let dc = CreateCompatibleDC(0)
    if dc == 0: return nil
    let f = CreateFontIndirectA(g.addr)
    let old = SelectObject(dc, f)
    var data: string
    const Ttcf = 0x66637474'u32
    var n = GetFontData(dc, Ttcf, 0, nil, 0)
    var collection = n != 0xffffffff'u32 and n > 0
    if not collection: n = GetFontData(dc, 0, 0, nil, 0)
    if n != 0xffffffff'u32 and n > 0:
      data.setLen n
      discard GetFontData(dc, (if collection: Ttcf else: 0), 0, data[0].addr, n)
    discard SelectObject(dc, old)
    discard DeleteObject(f)
    discard DeleteDC(dc)
    if data.len > 0: parseFace(data, 0) else: nil

else:
  import std/dynlib

  proc systemTypeface(lf: LogFont): OpenType =
    ## fontconfig's match for the family, weight and slant.
    var lib = loadLib("libfontconfig.so.1")
    if lib == nil: lib = loadLib("libfontconfig.so")
    if lib == nil: return nil
    defer: unloadLib(lib)
    let
      patternCreate = cast[proc (): pointer {.cdecl.}](lib.symAddr("FcPatternCreate"))
      patternDestroy = cast[proc (p: pointer) {.cdecl.}](lib.symAddr("FcPatternDestroy"))
      addString = cast[proc (p: pointer, obj: cstring, s: cstring): cint {.cdecl.}](
        lib.symAddr("FcPatternAddString"))
      addInteger = cast[proc (p: pointer, obj: cstring, i: cint): cint {.cdecl.}](
        lib.symAddr("FcPatternAddInteger"))
      substitute = cast[proc (config, p: pointer, kind: cint): cint {.cdecl.}](
        lib.symAddr("FcConfigSubstitute"))
      defaultSubstitute = cast[proc (p: pointer) {.cdecl.}](lib.symAddr("FcDefaultSubstitute"))
      fontMatch = cast[proc (config, p: pointer, res: ptr cint): pointer {.cdecl.}](
        lib.symAddr("FcFontMatch"))
      getString = cast[proc (p: pointer, obj: cstring, n: cint, s: ptr cstring): cint {.cdecl.}](
        lib.symAddr("FcPatternGetString"))
      getInteger = cast[proc (p: pointer, obj: cstring, n: cint, i: ptr cint): cint {.cdecl.}](
        lib.symAddr("FcPatternGetInteger"))
    if patternCreate.isNil or patternDestroy.isNil or addString.isNil or addInteger.isNil or
       substitute.isNil or defaultSubstitute.isNil or fontMatch.isNil or getString.isNil or
       getInteger.isNil:
      return nil
    proc attempt(family: string): (string, int, string) =
      let p = patternCreate()
      if p == nil: return
      defer: patternDestroy(p)
      if family.len > 0: discard addString(p, "family", system.cstring(family))
      let w = if lf.weight == 0: 400 else: lf.weight
      let fcw = if w < 250: 40 elif w < 350: 50 elif w < 450: 80 elif w < 550: 100
                elif w < 650: 180 elif w < 750: 200 else: 210
      discard addInteger(p, "weight", fcw.cint)
      discard addInteger(p, "slant", (if lf.italic != 0: 100 else: 0).cint)
      discard substitute(nil, p, 0)
      defaultSubstitute(p)
      var res: cint
      let m = fontMatch(nil, p, res.addr)
      if m == nil: return
      defer: patternDestroy(m)
      var file, fam: cstring
      var index: cint
      if getString(m, "file", 0, file.addr) != 0 or file == nil: return
      discard getInteger(m, "index", 0, index.addr)
      if getString(m, "family", 0, fam.addr) != 0: fam = nil
      ($file, index.int, (if fam == nil: "" else: $fam))
    var (file, index, got) = attempt(lf.face)
    if cmpIgnoreCase(got, lf.face) != 0:
      # Windows faces Linux has under another name.
      const Aliases = [("Book Antiqua", "Palatino Linotype"), ("Book Antiqua", "P052"),
                       ("Palatino", "Palatino Linotype"), ("Garamond", "EB Garamond"),
                       ("Century Gothic", "URW Gothic"), ("Bookman Old Style", "URW Bookman")]
      for (win, other) in Aliases:
        if cmpIgnoreCase(win, lf.face) != 0: continue
        let (f2, i2, g2) = attempt(other)
        if cmpIgnoreCase(g2, other) == 0:
          (file, index) = (f2, i2)
          break
    if file.len == 0: return nil
    try: parseFace(readFile(file), index)
    except IOError: nil

proc typefaceFor(lf: LogFont): OpenType =
  let key = lf.face.toLowerAscii & "|" & $lf.weight & "|" & $lf.italic & "|" & $lf.charset
  if key in typefaces: return typefaces[key]
  result = systemTypeface(lf)
  typefaces[key] = result

proc newFontFace(lf: LogFont): FontFace =
  ## The font as CreateFontIndirect sized it: a negative height is the em
  ## (character height), a positive one the cell (ascent + descent).
  result = FontFace(sx: 1)
  result.tf = typefaceFor(lf)
  let ot = result.tf
  if ot == nil: return
  var asc = ot.hhea.ascender.float32
  var desc = -ot.hhea.descender.float32
  if ot.os2 != nil and ot.os2.usWinAscent.int + ot.os2.usWinDescent.int > 0:
    asc = ot.os2.usWinAscent.float32
    desc = ot.os2.usWinDescent.float32
  let upem = ot.head.unitsPerEm.float32
  let h = if lf.height == 0: -12'i32 else: lf.height
  result.scale =
    if h < 0: float32(-h) / upem
    else: float32(h) / max(asc + desc, 1)
  result.ascent = int(round(asc * result.scale))
  result.height = result.ascent + int(round(desc * result.scale))
  if lf.width != 0 and ot.os2 != nil and ot.os2.xAvgCharWidth > 0:
    result.sx = float32(abs(lf.width)) / (ot.os2.xAvgCharWidth.float32 * result.scale)
  result.symbol = lf.charset == SymbolCharset

proc runeOf(f: FontFace, c: char): Rune =
  let b = ord(c)
  if f.symbol:
    let r = Rune(0xF000 + b)
    if f.tf.hasGlyph(r): return r
  if b in 0x80 .. 0x9f: Rune(Cp1252High[b - 0x80]) else: Rune(b)

proc layout(f: FontFace, text: string): (Path, int) =
  ## The text's outline at baseline 0 from x 0, and its width (GDI's integer advances).
  result[0] = newPath()
  if f.tf == nil: return
  var pen = 0
  for c in text:
    let r = f.runeOf(c)
    try:
      let g = f.tf.getGlyphPath(r)
      g.transform(translate(vec2(pen.float32, 0)) * scale(vec2(f.scale * f.sx, f.scale)))
      result[0].addPath(g)
    except PixieError: discard
    pen += int(round(f.tf.getAdvance(r) * f.scale * f.sx))
  result[1] = pen

# --- the effect --------------------------------------------------------------------------

type Text = ref object of Effect
  enabled: bool
  color, outlinecolor: uint32
  blend, blendavg, onbeat, insertBlank, randomPos: bool
  valign, halign, onbeatSpeed, normSpeed: int
  lf: LogFont
  text: string
  hasText: bool
  outline, shadow, randomword: bool
  outlinesize, xshift, yshift: int
  font: FontFace
  # r_text.cpp's state
  lw, lh: int
  curword, nb, nf, oddeven: int
  xshiftCur, yshiftCur, valignCur, halignCur: int
  forceshift, forcealign, forceredraw, shiftinit: bool
  rl, rt, rr, rb: int
  oldValign, oldHalign, oldCurword, oldClipcolor: int
  oldOutline, oldShadow: int
  oldBlend1, oldBlend2, oldBlend3: bool
  oldXshift, oldYshift: int
  oldtxt: string
  clipcolor: uint32
  buf: seq[uint32]
  img: Image

method desc(e: Text): string = "Render / Text"

proc newText(): Effect =
  Text(enabled: true, color: 0xffffff, halign: DtCenter, valign: DtVCenter, onbeatSpeed: 15,
       normSpeed: 15, outlinesize: 1, forcealign: true, shiftinit: true, oldOutline: -1,
       oldCurword: -1, oldClipcolor: -1, oldShadow: -1)

const
  ChooseFontSize = 60   ## Win32's CHOOSEFONT, saved whole
  LogFontSize = 60

method load(e: Text, d: openArray[byte]) =
  var pos = 0
  template field(v: untyped, conv: untyped) =
    if d.len - pos >= 4:
      let x {.inject.} = getInt(d, pos)
      v = conv
      pos += 4
  field(e.enabled, x != 0)
  field(e.color, cast[uint32](x))
  field(e.blend, x != 0)
  field(e.blendavg, x != 0)
  field(e.onbeat, x != 0)
  field(e.insertBlank, x != 0)
  field(e.randomPos, x != 0)
  field(e.valign, x.int)
  field(e.halign, x.int)
  field(e.onbeatSpeed, x.int)
  field(e.normSpeed, x.int)
  if d.len - pos >= ChooseFontSize: pos += ChooseFontSize
  if d.len - pos >= LogFontSize:
    e.lf = LogFont(height: getInt(d, pos), width: getInt(d, pos + 4),
                   escapement: getInt(d, pos + 8), weight: getInt(d, pos + 16),
                   italic: d[pos + 20], charset: d[pos + 23], face: cString(d, pos + 28, 32))
    pos += LogFontSize
  var size = 0'i32
  if d.len - pos >= 4: (size = getInt(d, pos); pos += 4)
  e.text = ""
  e.hasText = false
  if size > 0 and d.len - pos >= size:
    for i in 0 ..< size:
      if d[pos + i] == 0: break
      e.text.add char(d[pos + i])
    e.hasText = true
    pos += size
  field(e.outline, x != 0)
  field(e.outlinecolor, cast[uint32](x))
  field(e.xshift, x.int)
  field(e.yshift, x.int)
  field(e.outlinesize, x.int)
  field(e.randomword, x != 0)
  field(e.shadow, x != 0)
  e.font = newFontFace(e.lf)
  e.forcealign = true
  e.forceredraw = true
  e.forceshift = true
  e.shiftinit = true

proc nWords(e: Text): int =
  for c in e.text:
    if c == ';': inc result

proc fmtTime(ms: int, digits: int): string =
  result = $(ms div 60000) & ":" & align($((ms div 1000) mod 60), 2, '0')
  if digits > 0:
    var dv = 1
    for x in 0 ..< 3 - digits: dv *= 10
    result.add "." & align($((ms mod 1000) div dv), digits, '0')

proc getWord(e: Text, n: int): string =
  ## C_TextClass::getWord: word n, with $(playpos), $(playlen), $(title) and
  ## $(regNN) filled in, 255 characters at most.
  if not e.hasText: return ""
  let p = e.text
  var i = 0
  var w = 0
  while w < n and i < p.len:
    if p[i] == ';': inc w
    inc i
  var maxlen = 255
  while i < p.len and p[i] != ';' and maxlen > 0:
    template starts(s: string): bool =
      p.len - i >= s.len and cmpIgnoreCase(p[i ..< i + s.len], s) == 0
    var handled = false
    if starts("$(playpos") or starts("$(playlen"):
      let endp = p.find(')', i + 9)
      if endp >= 0:
        let isLen = starts("$(playlen")
        var dig = 0
        if i + 9 < p.len and p[i + 9] == '.':
          var k = i + 10
          var s = ""
          while k < p.len and p[k] in Digits: (s.add p[k]; inc k)
          dig = (try: parseInt(s) except ValueError: 0)
        dig = clamp(dig, 0, 3)
        let ms = if isLen: int(env.lenSec) * 1000 else: int(env.posMs)
        let s = fmtTime(ms, dig)
        let l = min(s.len, maxlen)
        result.add s[0 ..< l]
        maxlen -= l
        i = endp + 1
        handled = true
    elif starts("$(title"):
      let endp = p.find(')', i + 7)
      if endp >= 0:
        # The engine isn't told what plays: an empty title.
        i = endp + 1
        handled = true
    elif starts("$(reg") and i + 6 < p.len and p[i + 5] in Digits and p[i + 6] in Digits:
      let endp = p.find(')', i + 7)
      if endp >= 0:
        let r = clamp(parseInt(p[i + 5 .. i + 6]), 0, 99)
        var k = i + 7
        var prec = -1
        var width = 0
        if k < p.len and p[k] == ':':
          inc k
          var spec = ""
          while k < p.len and spec.len < 14 and (p[k] in Digits or p[k] == '.'):
            spec.add p[k]
            inc k
          let parts = spec.split('.')
          width = (try: parseInt(parts[0]) except ValueError: 0)
          if parts.len > 1: prec = (try: parseInt(parts[1]) except ValueError: 0)
        let v = globalRegs[r]
        var s = formatFloat(v, ffDecimal, (if prec < 0: 6 else: prec))
        if s.len < width: s = align(s, width)
        let l = min(s.len, maxlen)
        result.add s[0 ..< l]
        maxlen -= l
        i = endp + 1
        handled = true
    if not handled:
      result.add p[i]
      inc i
      dec maxlen

proc drawText(e: Text, w, h: int, txt: string) =
  ## The redraw: the clip color everywhere, then the text (its outline or
  ## shadow first) aligned in the shifted screen rectangle.
  if e.img == nil or e.img.width != w or e.img.height != h: e.img = newImage(w, h)
  let cc = e.clipcolor
  e.img.fill(rgbx(uint8((cc shr 16) and 255), uint8((cc shr 8) and 255), uint8(cc and 255), 255))
  if txt.len > 0 and e.font.tf != nil:
    let (path, cx) = e.font.layout(txt)
    let cy = e.font.height
    let flags = e.valignCur or e.halignCur
    proc place(l, t, r, b: int): Vec2 =
      let x = if (flags and DtCenter) != 0: l + (r - l - cx) div 2
              elif (flags and DtRight) != 0: r - cx
              else: l
      let y = if (flags and DtVCenter) != 0: t + (b - t - cy) div 2
              elif (flags and DtBottom) != 0: b - cy
              else: t
      vec2(x.float32, float32(y + e.font.ascent))
    proc paintOf(c: uint32): Paint =
      result = newPaint(SolidPaint)
      result.color = rgba(uint8((c shr 16) and 255), uint8((c shr 8) and 255),
                          uint8(c and 255), 255).color
    let s = e.outlinesize
    try:
      if e.outline:
        let pp = paintOf(e.outlinecolor)
        for (dx, dy) in [(-s, -s), (0, -s), (s, -s), (s, 0), (s, s), (0, s), (-s, s), (-s, 0)]:
          e.img.fillPath(path, pp, translate(place(e.rl + dx, e.rt + dy, e.rr + dx, e.rb + dy)))
      elif e.shadow:
        e.img.fillPath(path, paintOf(e.outlinecolor), translate(place(e.rl + s, e.rt + s, e.rr + s, e.rb + s)))
      e.img.fillPath(path, paintOf(e.color), translate(place(e.rl, e.rt, e.rr, e.rb)))
    except PixieError: discard
  e.buf.setLen w * h
  for i, c in e.img.data:
    e.buf[i] = (uint32(c.r) shl 16) or (uint32(c.g) shl 8) or uint32(c.b)

method render(e: Text, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if not e.enabled: return 0
  if (isBeat and BeatPreinit) != 0: return 0
  if e.forcealign:
    e.forcealign = false
    e.halignCur = e.halign
    e.valignCur = e.valign
  if e.shiftinit:
    e.shiftinit = false
    e.xshiftCur = e.xshift
    e.yshiftCur = e.yshift
  if (not e.onbeat and e.nf >= e.normSpeed) or (e.onbeat and isBeat != 0 and e.nb == 0):
    if not (e.insertBlank and (e.oddeven mod 2) == 0):
      if e.randomword: e.curword = crand() mod (e.nWords + 1)
      else: e.curword = (e.curword + 1) mod (e.nWords + 1)
    e.oddeven = (e.oddeven + 1) mod 2
  if e.onbeat and isBeat != 0 and e.nb == 0: e.nb = e.onbeatSpeed
  var txt = e.getWord(e.curword)
  if e.insertBlank and e.oddeven == 0: txt = ""
  if (not e.onbeat and e.nf >= e.normSpeed) or (e.onbeat and isBeat != 0 and e.nb == e.onbeatSpeed):
    e.nf = 0
    if e.randomPos and w > 0 and h > 0:
      # GetTextExtentPoint32 before the bitmap exists (the first frame) fails: 0 x 0.
      var cx, cy = 0
      if e.lw != 0 and e.font.tf != nil:
        cx = e.font.layout(txt)[1]
        cy = e.font.height
      e.halignCur = 0
      if cx < w:
        let m = ftol(float32(float32(w - cx) / w.float32) * 100'f32)
        if m > 0: e.xshiftCur = crand() mod m
      e.valignCur = 0
      if cy < h:
        let m = ftol(float32(float32(h - cy) / h.float32) * 100'f32)
        if m > 0: e.yshiftCur = crand() mod m
      e.forceshift = true
    else:
      e.halignCur = e.halign
      e.valignCur = e.valign
      e.xshiftCur = e.xshift
      e.yshiftCur = e.yshift
  if e.color != 0 and e.outlinecolor != 0: e.clipcolor = 0
  elif e.color != 8 and e.outlinecolor != 8: e.clipcolor = 8
  elif e.color != 0x10 and e.outlinecolor != 0x10: e.clipcolor = 10
  if e.lw != w or e.lh != h or e.forceshift:
    e.forceshift = false
    e.forceredraw = true
    e.lw = w
    e.lh = h
    let dx = ftol(float32(e.xshiftCur.float32 * w.float32 / 100'f32))
    let dy = ftol(float32(e.yshiftCur.float32 * h.float32 / 100'f32))
    e.rl = dx; e.rr = w + dx
    e.rt = dy; e.rb = h + dy
  let shown = not (e.onbeat and e.nb == 0)
  let b1 = e.blend and shown
  let b2 = e.blendavg and shown
  if e.forceredraw or e.oldHalign != e.halignCur or e.oldValign != e.valignCur or
     e.curword != e.oldCurword or (txt.len > 0 and txt != e.oldtxt) or
     e.oldClipcolor != int(e.clipcolor) or e.oldBlend1 != b1 or e.oldBlend2 != b2 or
     e.oldBlend3 != shown or e.oldOutline != ord(e.outline) or e.oldShadow != ord(e.shadow) or
     e.xshiftCur != e.oldXshift or e.yshiftCur != e.oldYshift:
    e.forceredraw = false
    e.oldHalign = e.halignCur
    e.oldValign = e.valignCur
    e.oldCurword = e.curword
    e.oldtxt = txt
    e.oldClipcolor = int(e.clipcolor)
    e.oldBlend1 = b1
    e.oldBlend2 = b2
    e.oldBlend3 = shown
    e.oldOutline = ord(e.outline)
    e.oldShadow = ord(e.shadow)
    e.oldXshift = e.xshiftCur
    e.oldYshift = e.yshiftCur
    e.drawText(w, h, txt)
  if shown and e.buf.len == w * h:
    let cc = e.clipcolor
    for i in 0 ..< w * h:
      let p = e.buf[i]
      if p != cc:
        fb[i] = if b1: blendAdd(p, fb[i]) elif b2: blendAvg(p, fb[i]) else: p
  if not e.onbeat: inc e.nf
  if e.onbeat and e.nb > 0: dec e.nb
  0

proc registerText*() =
  registerEffect(28, newText)
