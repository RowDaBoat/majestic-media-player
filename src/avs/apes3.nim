# Ported from grandchild's fork of AVS (https://github.com/grandchild/vis_avs), Copyright 2005
# Nullsoft, Inc. and its contributors; Texer II and Picture II by Steven Wittens. The Convolution
# Filter is also Copyright 2002 Tom Holden. BSD licenses: assets/licenses/AVS-Nullsoft-BSD.txt

## More third-party APEs, ported from grandchild's BSD port (vis_avs), its
## MMX code reproduced byte for byte: Texer II (Acko.net), Texer, Holden's
## Convolution Filter, Add Borders (Virtual Effect) and Picture II. Their
## images are looked up the way AVS found them in its own folder: in the
## preset's folder, the ones above it and the rest of its collection
## (`findPresetFile`); BMPs are read by our own decoder (bmp.nim).

import std/[math, strutils]
import pixie
import core, list, bmp

# --- images ----------------------------------------------------------------------------

type Picture = object
  w, h: int
  px: seq[uint32]  ## 0x00RRGGBB, rows top to bottom

proc loadPicture(name: string): Picture =
  ## The image a preset names, or an empty one when it can't be found or read.
  let path = findPresetFile(name)
  if path.len == 0: return
  try:
    let data = readFile(path)
    if isBmp(data.toOpenArrayByte(0, data.high)):
      (result.w, result.h, result.px) = decodeBmp(data.toOpenArrayByte(0, data.high))
      return
    let img = decodeImage(data)
    result.w = img.width
    result.h = img.height
    result.px = newSeq[uint32](img.width * img.height)
    for i, c in img.data:
      # pixie keeps premultiplied pixels: opaque ones (every BMP's) are as stored.
      let s = c.rgba
      result.px[i] = (uint32(s.r) shl 16) or (uint32(s.g) shl 8) or uint32(s.b)
  except CatchableError:
    result = Picture()

proc lanes(p: uint32): array[4, uint32] {.inline.} =
  [p and 0xff, (p shr 8) and 0xff, (p shr 16) and 0xff, p shr 24]

proc pack(l: array[4, uint32]): uint32 {.inline.} =
  ## packuswb of words that are never negative here: saturated at 255.
  min(l[0], 255) or (min(l[1], 255) shl 8) or (min(l[2], 255) shl 16) or (min(l[3], 255) shl 24)

proc subSat(a, b: uint32): uint32 {.inline.} =
  ## psubusb: a - b per byte, floored at 0, the top byte too.
  let x = lanes(a)
  let y = lanes(b)
  var r: array[4, uint32]
  for k in 0 .. 3: r[k] = (if x[k] > y[k]: x[k] - y[k] else: 0)
  pack(r)

proc mmxMinMax(s, d: uint32, isMax, srcFirst: bool): uint32 {.inline.} =
  ## Texer II's max/min: signed byte compares after flipping the colors' top
  ## bits (0x808080), so per color byte a true max or min; the top byte is
  ## compared unflipped and comes out as both or'd when it passes, else 0.
  ## srcFirst: the compare is source > frame (the unscaled paths), else
  ## frame > source.
  let a = lanes(s)
  let b = lanes(d)
  var r: array[4, uint32]
  for k in 0 .. 2: r[k] = (if isMax: max(a[k], b[k]) else: min(a[k], b[k]))
  let gt = if srcFirst: cast[int8](a[3]) > cast[int8](b[3]) else: cast[int8](b[3]) > cast[int8](a[3])
  r[3] = (if gt: a[3] or b[3] else: 0)
  pack(r)

# --- Texer II ----------------------------------------------------------------------------

const
  Texer2DefaultSize = 21
  Texer2Default: array[Texer2DefaultSize * Texer2DefaultSize, uint8] = [
    0'u8, 0, 0, 0, 0, 0, 3, 8, 13, 16, 18, 16, 13, 8, 3, 1, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 3, 11, 22, 33, 42, 47, 50, 47, 42, 33, 22, 11, 3, 0, 0, 0, 0,
    0, 0, 0, 5, 18, 34, 50, 65, 77, 84, 87, 84, 77, 65, 50, 34, 18, 5, 0, 0, 0,
    0, 0, 5, 20, 40, 62, 83, 101, 116, 125, 128, 125, 116, 102, 83, 62, 40, 20, 5, 0, 0,
    0, 3, 17, 40, 66, 93, 119, 141, 156, 165, 168, 165, 156, 141, 119, 93, 66, 40, 17, 3, 0,
    0, 11, 33, 62, 93, 125, 154, 177, 193, 202, 205, 202, 193, 177, 154, 125, 93, 62, 33, 11, 0,
    3, 22, 50, 83, 119, 154, 184, 207, 222, 231, 234, 231, 222, 207, 184, 154, 119, 83, 50, 22, 3,
    8, 33, 65, 101, 141, 177, 207, 228, 242, 250, 252, 250, 242, 228, 207, 177, 141, 101, 65, 33, 8,
    13, 42, 77, 116, 156, 193, 222, 242, 254, 255, 255, 255, 254, 242, 222, 193, 156, 116, 77, 42, 13,
    16, 47, 84, 125, 165, 202, 231, 250, 255, 255, 255, 255, 255, 250, 231, 202, 165, 125, 84, 47, 16,
    18, 50, 87, 128, 168, 205, 234, 252, 255, 255, 255, 255, 255, 252, 234, 205, 168, 128, 87, 50, 18,
    16, 47, 84, 125, 165, 202, 231, 250, 255, 255, 255, 255, 255, 250, 231, 202, 165, 125, 84, 47, 16,
    13, 42, 77, 116, 156, 193, 222, 242, 254, 255, 255, 255, 254, 242, 222, 193, 156, 116, 77, 42, 13,
    8, 33, 65, 101, 141, 177, 207, 228, 242, 250, 252, 250, 242, 228, 207, 177, 141, 101, 65, 33, 8,
    3, 22, 50, 83, 119, 154, 184, 207, 222, 231, 234, 231, 222, 207, 184, 154, 119, 83, 50, 22, 3,
    0, 11, 33, 62, 93, 125, 154, 177, 193, 202, 205, 202, 193, 177, 154, 125, 93, 62, 33, 11, 0,
    0, 3, 17, 40, 66, 93, 119, 141, 156, 165, 168, 165, 156, 141, 119, 93, 66, 40, 17, 3, 0,
    0, 0, 5, 20, 40, 62, 83, 102, 116, 125, 128, 125, 116, 101, 83, 62, 40, 20, 5, 0, 0,
    0, 0, 0, 5, 18, 34, 50, 65, 77, 84, 87, 84, 77, 65, 50, 34, 18, 5, 0, 0, 0,
    0, 0, 0, 0, 3, 11, 22, 33, 42, 47, 50, 47, 42, 33, 22, 11, 3, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 3, 8, 13, 16, 18, 16, 13, 8, 3, 1, 0, 0, 0, 0, 0]
    ## Tuggummi's blurred circle, Texer II's image when the preset names none.

type
  Texer2 = ref object of Effect
    version: int32
    image: string
    resize, wrap, colorize: bool
    code: array[4, string]   ## init, frame, beat, point
    compiled: array[4, EelCode]
    iw, ih: int
    tex: array[4, seq[uint32]]  ## normal, flipped, mirrored, turned 180°, padded with 0s
    needInit, needRecompile: bool
    vN, vI, vX, vY, vV, vB, vW, vH, vIw, vIh, vSizex, vSizey, vRed, vGreen, vBlue, vSkip: ptr float64

method desc(e: Texer2): string = "Render / Texer II"

proc newTexer2(): Effect =
  Texer2(colorize: true, needInit: true, needRecompile: true, vm: newEelVm())

proc setImage(e: Texer2, pic: Picture) =
  let (w, h) = (pic.w, pic.h)
  e.iw = w
  e.ih = h
  # Past the image the MMX code read whatever followed it: zeros here.
  for t in e.tex.mitems: t = newSeq[uint32](w * h + 2 * w + 4)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let v = pic.px[y * w + x]
      e.tex[0][y * w + x] = v
      e.tex[1][(h - y - 1) * w + x] = v
      e.tex[2][(y + 1) * w - x - 1] = v
      e.tex[3][(h - y) * w - x - 1] = v

proc defaultSprite(): Picture =
  ## Texer II's own image, a blurred white dot.
  result = Picture(w: Texer2DefaultSize, h: Texer2DefaultSize)
  for v in Texer2Default:
    result.px.add uint32(v) * 0x010101'u32

proc loadImage(e: Texer2) =
  var pic = if e.image.len > 0: loadPicture(e.image) else: Picture()
  if pic.w == 0 or pic.h == 0: pic = defaultSprite()
  e.setImage(pic)

method load(e: Texer2, d: openArray[byte]) =
  var pos = 0
  e.version = getInt(d, pos)
  if e.version notin 0'i32 .. 1'i32: e.version = 0
  pos += 4
  e.image = cString(d, pos, 260)
  pos += 260
  e.resize = getInt(d, pos) != 0; pos += 4
  e.wrap = getInt(d, pos) != 0; pos += 4
  e.colorize = getInt(d, pos) != 0; pos += 4
  pos += 4
  for k in 0 .. 3: e.code[k] = loadString(d, pos)
  e.needRecompile = true
  e.needInit = true
  e.loadImage()

proc roundToInt(x: float64): int {.inline.} = int(fistp32(x))

proc fractional(f: float64): float64 {.inline.} = f - float64(ftol(f))

proc texel(t: seq[uint32], i: int): uint32 {.inline.} =
  if i >= 0 and i < t.len: t[i] else: 0

proc drawParticle(e: Texer2, fb: Pixels, tex: seq[uint32], sw, sh: int,
                  x, y, sizex, sizey: float64, color: uint32) =
  ## E_Texer2::DrawParticle: w, h and the image size counted one short, as it did.
  let w = sw - 1
  let h = sh - 1
  let iw = e.iw - 1
  let ih = e.ih - 1
  let mode = lineBlendMode and 0xff
  let col = lanes(color)
  var x0 = 0.0
  var y0 = 0.0
  if e.resize:
    let rl = -iw.float64 * 0.5 * sizex + 0.5 + (x * 0.5 + 0.5) * w.float64
    let rt = -ih.float64 * 0.5 * sizey + 0.5 + (y * 0.5 + 0.5) * h.float64
    let rr = (iw - 1).float64 * 0.5 * sizex + 0.5 + (x * 0.5 + 0.5) * w.float64
    let rb = (ih - 1).float64 * 0.5 * sizey + 0.5 + (y * 0.5 + 0.5) * h.float64
    var l2 = roundToInt(rl)
    var t2 = roundToInt(rt)
    var r2 = roundToInt(rr)
    var b2 = roundToInt(rb)
    if r2 < 0 or l2 > w or b2 < 0 or t2 > h: return
    x0 = (0.5 - fractional(rl + 0.5)) / (rr - rl)
    y0 = (0.5 - fractional(rt + 0.5)) / (rb - rt)
    if rl < 0.0:
      x0 = -rl / (rr - rl)
      l2 = 0
    if rt < 0.0:
      y0 = -rt / (rb - rt)
      t2 = 0
    if rr > w.float64: r2 = w
    if rb > h.float64: b2 = h
    let fx0 = x0 * iw.float64
    let fy0 = y0 * ih.float64
    var cx0 = int32(roundToInt(fx0))
    var cy0 = int32(roundToInt(fy0))
    let dx = 65535'i32 - int32(ftol((0.5 - (fx0 - cx0.float64)) * 65536.0))
    let dy = 65535'i32 - int32(ftol((0.5 - (fy0 - cy0.float64)) * 65536.0))
    let scx = (iw - 1).float64 / (rr - rl + 1.0)
    let scy = (ih - 1).float64 / (rb - rt + 1.0)
    let sdx = int32(ftol(scx * 65536.0))
    let sdy = int32(ftol(scy * 65536.0))
    cx0 = (cx0 shl 16) +% dx
    cy0 = (cy0 shl 16) +% dy
    if cx0 < 0:
      cx0 = cx0 +% sdx
      inc l2
    if cy0 < 0:
      cy0 = cy0 +% sdy
      inc t2
    if r2 <= l2 or b2 <= t2: return
    if mode > 9: return
    let tw = iw + 1
    let adj = uint32((lineBlendMode and 0xff00) shr 8)
    for yy in t2 .. b2:
      let fy = (cast[uint32](cy0) and 0xffff) shr 8
      let row = int(cast[uint32](cy0) shr 16) * tw
      var cx = cx0
      var o = yy * sw + l2
      for xx in l2 .. r2:
        let fx = (cast[uint32](cx) and 0xffff) shr 8
        let i = row + int(cast[uint32](cx) shr 16)
        let a = lanes(texel(tex, i))
        let b = lanes(texel(tex, i + 1))
        let c = lanes(texel(tex, i + tw))
        let d = lanes(texel(tex, i + tw + 1))
        var t: array[4, uint32]
        for k in 0 .. 3:
          let top = ((b[k] * fx) shr 8) + ((a[k] * (255 - fx)) shr 8)
          let bot = ((c[k] * (255 - fx)) shr 8) + ((d[k] * fx) shr 8)
          t[k] = ((((bot * fy) shr 8) + ((top * (255 - fy)) shr 8)) * col[k]) and 0xffff
        var s: array[4, uint32]
        for k in 0 .. 3: s[k] = t[k] shr 8
        let dst = fb[o]
        case mode
        of 0: fb[o] = pack(s)
        of 1: fb[o] = blendAddSat(pack(s), dst)
        of 2: fb[o] = mmxMinMax(pack(s), dst, true, false)
        of 3:
          let dl = lanes(dst)
          var r: array[4, uint32]
          for k in 0 .. 3: r[k] = min(s[k] + dl[k], 0xffff) shr 1
          fb[o] = pack(r)
        of 4: fb[o] = subSat(dst, pack(s))
        of 5: fb[o] = subSat(pack(s), dst)
        of 6:
          let dl = lanes(dst)
          var r: array[4, uint32]
          for k in 0 .. 3: r[k] = ((dl[k] * s[k]) and 0xffff) shr 8
          fb[o] = pack(r)
        of 7:
          let dl = lanes(dst)
          var r: array[4, uint32]
          for k in 0 .. 3:
            r[k] = min(((dl[k] * (255 - adj)) shr 8) + ((s[k] * adj) shr 8), 0xffff)
          fb[o] = pack(r)
        of 8: fb[o] = pack(s) xor dst
        else: fb[o] = mmxMinMax(pack(s), dst, false, false)
        cx = cx +% sdx
        inc o
      cy0 = cy0 +% sdy
  else:
    let l = roundToInt((x * 0.5 + 0.5) * w.float64) - iw div 2
    let t = roundToInt((y * 0.5 + 0.5) * h.float64) - ih div 2
    let r = l + iw - 1
    let b = t + ih - 1
    var l2 = l
    var t2 = t
    var r2 = r
    var b2 = b
    if r2 < 0 or l2 > w or b2 < 0 or t2 > h: return
    if l < 0:
      x0 = -l.float64 / float64(r - l)
      l2 = 0
    if t < 0:
      y0 = -t.float64 / float64(b - t)
      t2 = 0
    if r > w: r2 = w
    if b > h: b2 = h
    if r2 <= l2 or b2 <= t2: return
    if mode > 9: return
    let cx0 = roundToInt(x0 * iw.float64)
    var ty = roundToInt(y0 * ih.float64)
    let adj = uint32((lineBlendMode and 0xff00) shr 8)
    for yy in t2 .. b2:
      var o = yy * sw + l2
      var i = ty * (iw + 1) + cx0
      for xx in l2 .. r2:
        let dst = fb[o]
        let raw = texel(tex, i)
        var src = raw
        if e.colorize:
          let tl = lanes(raw)
          var m: array[4, uint32]
          for k in 0 .. 3: m[k] = (tl[k] * col[k]) shr 8
          src = pack(m)
        case mode
        of 0: fb[o] = src
        of 1: fb[o] = blendAddSat(dst, src)
        of 2: fb[o] = mmxMinMax(src, dst, true, true)
        of 3:
          let a = lanes(dst)
          let s = lanes(src)
          var m: array[4, uint32]
          for k in 0 .. 3: m[k] = (a[k] + s[k]) shr 1
          fb[o] = pack(m)
        of 4: fb[o] = subSat(dst, src)
        of 5: fb[o] = subSat(src, dst)
        of 6:
          # Multiply filters with the color after the product, from the raw texel.
          let a = lanes(dst)
          let s = lanes(raw)
          var m: array[4, uint32]
          for k in 0 .. 3:
            m[k] = (a[k] * s[k]) shr 8
            if e.colorize: m[k] = ((m[k] * col[k]) and 0xffff) shr 8
          fb[o] = pack(m)
        of 7:
          let a = lanes(dst)
          let s = lanes(src)
          var m: array[4, uint32]
          for k in 0 .. 3: m[k] = min(a[k] * adj + s[k] * (256 - adj), 0xffff) shr 8
          fb[o] = pack(m)
        of 8: fb[o] = dst xor src
        else: fb[o] = mmxMinMax(src, dst, false, true)
        inc o
        inc i
      inc ty

proc wrapDiff(x: float64): float64 {.inline.} = round(x / 2.0) * 2.0

proc wrapOnceDiff(x: float64): float64 {.inline.} =
  if x > 1.0: 2.0 elif x < -1.0: -2.0 else: 0.0

proc overlapsEdge(c, size: float64, sizePx, screenPx: int): bool =
  let a = abs(c)
  let half = size * float64(sizePx - 1) / screenPx.float64
  a + half > 1.0 and a - half < 1.0

method render(e: Texer2, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if e.needRecompile:
    if e.vN == nil or resetVarsOnRecompile:
      e.vm.resetVars()
      e.vN = e.vm.reg("n"); e.vI = e.vm.reg("i"); e.vX = e.vm.reg("x"); e.vY = e.vm.reg("y")
      e.vV = e.vm.reg("v"); e.vB = e.vm.reg("b"); e.vW = e.vm.reg("w"); e.vH = e.vm.reg("h")
      e.vIw = e.vm.reg("iw"); e.vIh = e.vm.reg("ih"); e.vSizex = e.vm.reg("sizex")
      e.vSizey = e.vm.reg("sizey"); e.vRed = e.vm.reg("red"); e.vGreen = e.vm.reg("green")
      e.vBlue = e.vm.reg("blue"); e.vSkip = e.vm.reg("skip")
    e.needRecompile = false
    for k in 0 .. 3: e.compiled[k] = e.vm.compile(e.code[k])
  e.vI[] = 0; e.vX[] = 0; e.vY[] = 0; e.vV[] = 0
  e.vW[] = w.float64; e.vH[] = h.float64
  e.vB[] = (if isBeat != 0: 1.0 else: 0.0)
  e.vIw[] = e.iw.float64; e.vIh[] = e.ih.float64
  e.vSizex[] = 1; e.vSizey[] = 1
  e.vRed[] = 1; e.vGreen[] = 1; e.vBlue[] = 1
  e.vSkip[] = 0
  if e.needInit or (isBeat and BeatPreinit) != 0:
    e.vN[] = 0
    e.compiled[0].run()
    e.needInit = false
  e.compiled[1].run()
  if (isBeat and 1) != 0: e.compiled[2].run()
  let n = clamp(roundToInt(e.vN[]), 0, 65536)
  if n <= 0 or e.iw == 0: return 0
  let step = 1.0 / float64(n - 1)
  var fi = 0.0
  for j in 0 ..< n:
    e.vI[] = fi
    e.vSkip[] = 0
    let k = j * 575 div n
    e.vV[] = float64(int(vis[1][0][k]) + int(vis[1][1][k])) / 256.0
    fi += step
    e.compiled[3].run()
    if not (e.vSkip[] == 0.0): continue
    let szx = abs(e.vSizex[])
    let szy = abs(e.vSizey[])
    if szx <= 0.01 or szy <= 0.01: continue
    var color = uint32(clamp(roundToInt(255.0 * e.vBlue[]), 0, 255))
    color = color or (uint32(clamp(roundToInt(255.0 * e.vGreen[]), 0, 255)) shl 8)
    color = color or (uint32(clamp(roundToInt(255.0 * e.vRed[]), 0, 255)) shl 16)
    if not e.colorize: color = 0xffffff
    var t = 0
    if e.vSizex[] < 0 and e.vSizey[] > 0: t = 2
    elif e.vSizex[] > 0 and e.vSizey[] < 0: t = 1
    elif e.vSizex[] < 0 and e.vSizey[] < 0: t = 3
    var x = e.vX[]
    var y = e.vY[]
    if e.wrap:
      var ox, oy: bool
      if e.version == 0:
        x -= wrapOnceDiff(e.vX[])
        y -= wrapOnceDiff(e.vY[])
        ox = overlapsEdge(e.vX[], szx, e.iw, w)
        oy = overlapsEdge(e.vY[], szy, e.ih, h)
      else:
        x = e.vX[] - wrapDiff(e.vX[])
        y = e.vY[] - wrapDiff(e.vY[])
        ox = overlapsEdge(x, szx, e.iw, w)
        oy = overlapsEdge(y, szy, e.ih, h)
      let sx2 = if x > 0: 2.0 else: -2.0
      let sy2 = if y > 0: 2.0 else: -2.0
      if ox: e.drawParticle(fb, e.tex[t], w, h, x - sx2, y, szx, szy, color)
      if oy: e.drawParticle(fb, e.tex[t], w, h, x, y - sy2, szx, szy, color)
      if ox and oy: e.drawParticle(fb, e.tex[t], w, h, x - sx2, y - sy2, szx, szy, color)
    e.drawParticle(fb, e.tex[t], w, h, x, y, szx, szy, color)
  0

# --- Texer -------------------------------------------------------------------------------

type Texer = ref object of Effect
  image: string
  addToInput, colorize: bool
  numParticles: int
  pic: Picture

method desc(e: Texer): string = "Trans / Texer"

proc newTexer(): Effect = Texer(numParticles: 100)

method load(e: Texer, d: openArray[byte]) =
  var pos = 16
  if d.len - pos >= 260:
    e.image = cString(d, pos, 260)
  pos += 260
  if d.len - pos >= 4:
    let io = getInt(d, pos)
    e.addToInput = (io and 3) == 2
    e.colorize = (io and 0xc) == 8
  pos += 4
  if d.len - pos >= 4: e.numParticles = getInt(d, pos)
  e.pic = if e.image.len > 0: loadPicture(e.image) else: Picture()
  # A named image that's nowhere to be found: Texer II's dot rather than nothing, as
  # the image was nearly always a dot or a ring, and a missing one blanks the preset.
  if e.image.len > 0 and (e.pic.w == 0 or e.pic.h == 0): e.pic = defaultSprite()

method render(e: Texer, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if e.pic.w == 0 or e.pic.h == 0: return 0
  if e.addToInput: copyPixels(fbout, fb, w * h)
  else: clearPixels(fbout, w * h)
  let iw = e.pic.w
  let ih = e.pic.h
  let hw = iw div 2
  let hh = ih div 2
  var p = 0
  for y in 0 ..< h:
    for x in 0 ..< w:
      let m = fb[x + y * w]
      if (m and 0xffffff) == 0: continue
      # One copy of the image centered here, added, filtered by this pixel's color.
      let sx = x - hw
      let sy = y - hh
      let ml = lanes(m)
      for iy in max(0, -sy) ..< min(ih, h - sy):
        var o = (sy + iy) * w + sx
        for ix in max(0, -sx) ..< min(iw, w - sx):
          var s = e.pic.px[iy * iw + ix]
          if e.colorize:
            let sl = lanes(s)
            s = ((sl[0] * ml[0]) shr 8) or (((sl[1] * ml[1]) shr 8) shl 8) or
                (((sl[2] * ml[2]) shr 8) shl 16)
          fbout[o + ix] = blendAddSat(fbout[o + ix], s)
      inc p
      if p >= e.numParticles: return 1
  1

# --- Convolution Filter ------------------------------------------------------------------

const KDim = 7

type
  Tap = tuple[x, y: int, v: uint32]   ## y = KDim: the bias
  Convolution = ref object of Effect
    enabled, wrap, absolute, twoPass: bool
    kernel: array[KDim * KDim, int32]
    bias, scale: int32
    farray: array[KDim * KDim + 1, uint16]  ## |kernel| as words; [49] the bias, x256
    spreadFb: seq[uint64]  ## the frame's bytes as 16-bit lanes, when it isn't written in place

method desc(e: Convolution): string = "Trans / Convolution Filter"

proc newConvolution(): Effect =
  let e = Convolution(enabled: true, scale: 1)
  e.kernel[KDim * KDim div 2] = 1
  e

method load(e: Convolution, d: openArray[byte]) =
  var pos = 0
  template next(): int32 =
    (let v = getInt(d, pos); pos += 4; v)
  if d.len - pos >= 4: e.enabled = next() == 1
  if d.len - pos >= 4: e.wrap = next() == 1
  if d.len - pos >= 4: e.absolute = next() == 1
  if d.len - pos >= 4: e.twoPass = next() == 1
  for i in 0 ..< KDim * KDim:
    if d.len - pos >= 4: e.kernel[i] = next()
  if d.len - pos >= 4: e.bias = next()
  if d.len - pos >= 4: e.scale = next()
  if e.scale == 0: e.scale = 1

method render(e: Convolution, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  ## The code create_draw_func generated, run as it ran: words per byte (the
  ## top byte too), the right column and bottom row clamped one short (width-2,
  ## height-2), the bias counted 256 times, in place when nothing reads pixels
  ## already written.
  if not e.enabled or w < 7 or h < 2: return 0
  var possum, negsum: uint32
  var zerorun = 0
  var zerostring = true
  for i in 0 ..< KDim * KDim:
    let v = e.kernel[i]
    if v < 0:
      negsum += uint32(-v); zerostring = false
      e.farray[i] = cast[uint16](int16(-v and 0xffff))
    elif v > 0:
      possum += uint32(v); zerostring = false
      e.farray[i] = cast[uint16](int16(v and 0xffff))
    else:
      if zerostring: inc zerorun
      e.farray[i] = 0
  if e.bias < 0:
    negsum += uint32(-e.bias)
    e.farray[49] = uint16((-256 * e.bias) and 0xffff)
  else:
    possum += uint32(e.bias)
    e.farray[49] = uint16((256 * e.bias) and 0xffff)
  var pos, neg: array[2, seq[Tap]]
  let swap = e.scale <= 0
  for i in 0 ..< KDim * KDim:
    let v = e.kernel[i]
    if v == 0: continue
    let isPos = (v > 0) != swap
    let t0: Tap = (i mod KDim, i div KDim, uint32(abs(v)))
    let t1: Tap = (6 - i div KDim, i mod KDim, uint32(abs(v)))
    if isPos: (pos[0].add t0; pos[1].add t1)
    else: (neg[0].add t0; neg[1].add t1)
  if e.bias != 0:
    let t: Tap = (0, KDim, uint32(abs(e.bias)))
    if (e.bias > 0) != swap: (pos[0].add t; pos[1].add t)
    else: (neg[0].add t; neg[1].add t)
  let div0 = abs(e.scale)
  let useOut = zerorun < KDim * KDim div 2
  let o = if useOut: fbout else: fb
  let passes = if e.twoPass: 2 else: 1
  var shiftDiv = -1
  if div0 != 1:
    var j = 1'i64
    var k = 0
    while j < div0: (j = j shl 1; inc k)
    if j == div0: shiftDiv = k
  let recip = uint32((65536 div max(div0, 1)) and 0xffff)
  var rows: array[KDim, int]   ## c[0..6], rows clamped to 0 .. h-2
  for y in 0 ..< KDim: rows[y] = clamp(y - 3, 0, h - 2) * w
  proc tapShift(v: uint32): int =
    ## The power of two v is (psllw), -1 when it multiplies (pmullw), 0 for 1.
    if v == 1: return 0
    var j = 1'u32
    var k = 0
    while j < v: (j = j shl 1; inc k)
    if j == v: k else: -1
  var shifts: array[2, array[2, seq[int]]]
  let taps = [[pos[0], neg[0]], [pos[1], neg[1]]]
  for p in 0 ..< passes:
    for t in pos[p]: shifts[p][0].add tapShift(t.v)
    for t in neg[p]: shifts[p][1].add tapShift(t.v)
  # When no 16-bit lane can pass 65535, wrapping and saturating adds agree and
  # the four lanes add as one 64-bit word.
  type FastTap = tuple[y, dx: int, m: uint64, sh: int]
  var fast: array[2, array[2, seq[FastTap]]]
  var fastBias: array[2, array[2, uint64]]
  var isFast = true
  for p in 0 ..< passes:
    for side in 0 .. 1:
      var top = 0
      for n, t in taps[p][side]:
        if t.y == KDim:
          fastBias[p][side] += uint64(e.farray[49]) * 0x0001000100010001'u64
          top += int(e.farray[49])
          continue
        let sh = shifts[p][side][n]
        let m = if sh >= 0: 1 shl sh else: int(e.farray[KDim * t.y + t.x])
        top += 255 * m
        fast[p][side].add (t.y, t.x - 3, uint64(m), sh)
      if top > 0xffff: isFast = false
  template spread(px: uint32): uint64 =
    uint64(px and 0xff) or (uint64((px shr 8) and 0xff) shl 16) or
      (uint64((px shr 16) and 0xff) shl 32) or (uint64(px shr 24) shl 48)
  proc finish(acc: array[2, array[2, array[4, uint32]]]): uint32 =
    var res, first: array[4, uint32]
    for p in 0 ..< passes:
      var r = acc[p][0]
      if neg[p].len > 0:
        for k in 0 .. 3:
          if e.absolute:
            let d = clamp(int(cast[int16](uint16(acc[p][0][k]))) - int(cast[int16](uint16(acc[p][1][k]))),
                          -32768, 32767)
            r[k] = uint32(d and 0x7fff)
          elif e.wrap: r[k] = (acc[p][0][k] - acc[p][1][k]) and 0xffff
          else: r[k] = (if acc[p][0][k] > acc[p][1][k]: acc[p][0][k] - acc[p][1][k] else: 0)
      if p == 0: first = r
      else:
        for k in 0 .. 3: r[k] = min(r[k] + first[k], 0xffff)
      res = r
    if div0 != 1:
      if shiftDiv >= 0:
        for k in 0 .. 3: res[k] = res[k] shr shiftDiv
      else:
        for k in 0 .. 2: res[k] = (res[k] * recip) shr 16
    for k in 0 .. 3:
      let s = cast[int16](uint16(res[k]))
      result = result or (uint32(clamp(int(s), 0, 255)) shl (8 * k))
  proc pixel(i: int): uint32 =
    ## One pixel of the current row, from the frame as it is now.
    var acc: array[2, array[2, array[4, uint32]]]
    for p in 0 ..< passes:
      for side in 0 .. 1:
        let sum = if side == 0: possum else: negsum
        for n in 0 ..< taps[p][side].len:
          let t = taps[p][side][n]
          var add: array[4, uint32]
          if t.y == KDim:
            let b = uint32(e.farray[49])
            add = [b, b, b, b]
            for k in 0 .. 3: acc[p][side][k] = min(acc[p][side][k] + add[k], 0xffff)
            continue
          let col =
            if i < 3: max(i + t.x - 3, 0)
            elif i < w - 3: i + t.x - 3
            else: min(i + t.x - 3, w - 2)
          let px = lanes(fb[rows[t.y] + col])
          let sh = shifts[p][side][n]
          for k in 0 .. 3:
            add[k] =
              if sh >= 0: (px[k] shl sh) and 0xffff
              else: (px[k] * uint32(e.farray[KDim * t.y + t.x])) and 0xffff
          for k in 0 .. 3:
            acc[p][side][k] =
              if sum < 256: (acc[p][side][k] + add[k]) and 0xffff
              else: min(acc[p][side][k] + add[k], 0xffff)
    finish(acc)
  # In place, a pixel already written is read only by taps left of the center
  # on its row, and on the last two rows (clamped to h-2): those go one by one.
  var leftReads = false
  for p in 0 ..< passes:
    for side in 0 .. 1:
      for t in fast[p][side]:
        if t.y == 3 and t.dx < 0: leftReads = true
  let rowwise = isFast and w > 6 and (useOut or not leftReads)
  let midW = max(w - 6, 0)
  var accRow: array[2, array[2, seq[uint64]]]
  if rowwise:
    for p in 0 ..< passes:
      for side in 0 .. 1: accRow[p][side] = newSeq[uint64](midW)
  var midOut = newSeq[uint32](if rowwise: midW else: 0)
  let spreadAll = rowwise and useOut
  if spreadAll:
    e.spreadFb.setLen w * h
    let sp = cast[ptr UncheckedArray[uint64]](e.spreadFb[0].addr)
    for i in 0 ..< w * h: sp[i] = spread(fb[i])
  for j in 0 ..< h:
    if rowwise and (useOut or j < h - 2):
      for i in 0 .. 2: o[j * w + i] = pixel(i)
      for p in 0 ..< passes:
        for side in 0 .. 1:
          let a = cast[ptr UncheckedArray[uint64]](accRow[p][side][0].addr)
          let b = fastBias[p][side]
          for i in 0 ..< midW: a[i] = b
          for t in fast[p][side]:
            if spreadAll:
              let src = cast[ptr UncheckedArray[uint64]](e.spreadFb[rows[t.y] + 3 + t.dx].addr)
              if t.m == 1:
                for i in 0 ..< midW: a[i] += src[i]
              else:
                let m = t.m
                for i in 0 ..< midW: a[i] += src[i] * m
              continue
            let src = cast[Pixels](fb[rows[t.y] + 3 + t.dx].addr)
            if t.sh >= 0:
              let sh = t.sh
              for i in 0 ..< midW: a[i] += spread(src[i]) shl sh
            else:
              let m = t.m
              for i in 0 ..< midW: a[i] += spread(src[i]) * m
      let a0 = cast[ptr UncheckedArray[uint64]](accRow[0][0][0].addr)
      let n0 = cast[ptr UncheckedArray[uint64]](accRow[0][1][0].addr)
      let a1 = if passes > 1: cast[ptr UncheckedArray[uint64]](accRow[1][0][0].addr) else: nil
      let n1 = if passes > 1: cast[ptr UncheckedArray[uint64]](accRow[1][1][0].addr) else: nil
      let hasNeg0 = neg[0].len > 0
      let hasNeg1 = passes > 1 and neg[1].len > 0
      template combine(pv, nv: uint64, k: int, hasNeg: bool): uint32 =
        let pl = uint32((pv shr (16 * k)) and 0xffff)
        if not hasNeg: pl
        else:
          let nl = uint32((nv shr (16 * k)) and 0xffff)
          if e.absolute:
            uint32(clamp(int(cast[int16](uint16(pl))) - int(cast[int16](uint16(nl))), -32768, 32767) and 0x7fff)
          elif e.wrap: (pl - nl) and 0xffff
          elif pl > nl: pl - nl
          else: 0'u32
      for i in 0 ..< midW:
        var px = 0'u32
        for k in 0 .. 3:
          var r = combine(a0[i], n0[i], k, hasNeg0)
          if passes > 1: r = min(combine(a1[i], n1[i], k, hasNeg1) + r, 0xffff)
          if div0 != 1:
            if shiftDiv >= 0: r = r shr shiftDiv
            elif k < 3: r = (r * recip) shr 16
          let sv = int(cast[int16](uint16(r)))
          px = px or (uint32(if sv < 0: 0 elif sv > 255: 255 else: sv) shl (8 * k))
        midOut[i] = px
      for i in 0 ..< midW: o[j * w + 3 + i] = midOut[i]
      for i in w - 3 ..< w: o[j * w + i] = pixel(i)
    else:
      for i in 0 ..< w: o[j * w + i] = pixel(i)
    # c[0..5] = c[1..6]; c[6] one row down unless that is the last row.
    for y in 0 ..< KDim - 1: rows[y] = rows[y + 1]
    if rows[KDim - 1] + w != w * (h - 1): rows[KDim - 1] += w
  (if useOut: 1 else: 0)

# --- Add Borders -------------------------------------------------------------------------

type AddBorders = ref object of Effect
  enabled: bool
  color: uint32
  size: int

method desc(e: AddBorders): string = "Render / Add Borders"

proc newAddBorders(): Effect = AddBorders(size: 1)

method load(e: AddBorders, d: openArray[byte]) =
  e.enabled = d.len >= 4 and getInt(d, 0) != 0
  e.color = (if d.len >= 8: cast[uint32](getInt(d, 4)) else: 0)
  e.size = (if d.len >= 12: clamp(getInt(d, 8).int, 1, 50) else: 1)

method render(e: AddBorders, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if not e.enabled: return 0
  let framesize = w * (h - 1)
  let bh = max(h * e.size div 100, 1)
  let bw = max(w * e.size div 100, 1)
  for i in 0 ..< min(bh, h):
    for k in 0 ..< w:
      fb[k + i * w] = e.color
      fb[framesize + k - i * w] = e.color
  for i in 0 ..< min(bw, w):
    for k in 0 ..< h:
      fb[w * k + i] = e.color
      fb[w * k + (w - 1 - i)] = e.color
  0

# --- Picture II --------------------------------------------------------------------------

type Picture2 = ref object of Effect
  image: string
  blend, beatBlend: int        ## the common order: AVS's line blend modes, 10 ignore
  bilinear, beatBilinear: bool
  adjust, beatAdjust: int
  pic: Picture                 ## edges repeated one pixel all around
  ww, wh: int
  work, workBilinear: seq[uint32]

method desc(e: Picture2): string = "Render / Picture II"

proc newPicture2(): Effect =
  Picture2(bilinear: true, beatBilinear: true, adjust: 128, beatAdjust: 128)

const P2Legacy = [0, 1, 2, 4, 5, 6, 7, 9, 8, 3, 10]  ## common mode -> saved number

proc p2Mode(v: int32): int =
  for i, l in P2Legacy:
    if l == v: return i
  0

method load(e: Picture2, d: openArray[byte]) =
  e.image = cString(d, 0, 260)
  var pos = 260
  if d.len - pos >= 4: (e.blend = p2Mode(getInt(d, pos)); pos += 4)
  if d.len - pos >= 4: (e.beatBlend = p2Mode(getInt(d, pos)); pos += 4)
  if d.len - pos >= 4: (e.bilinear = getInt(d, pos) != 0; pos += 4)
  if d.len - pos >= 4: (e.beatBilinear = getInt(d, pos) != 0; pos += 4)
  if d.len - pos >= 4: (e.adjust = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.beatAdjust = getInt(d, pos); pos += 4)
  let src = if e.image.len > 0: loadPicture(e.image) else: Picture()
  e.pic = Picture()
  if src.w > 0 and src.h > 0:
    e.pic.w = src.w + 2
    e.pic.h = src.h + 2
    e.pic.px = newSeq[uint32](e.pic.w * e.pic.h)
    for y in 0 ..< e.pic.h:
      for x in 0 ..< e.pic.w:
        e.pic.px[x + y * e.pic.w] = src.px[clamp(x - 1, 0, src.w - 1) + clamp(y - 1, 0, src.h - 1) * src.w]
  e.ww = 0

proc mul255(a, b: uint32): uint32 {.inline.} = (a * b) div 255

proc refresh(e: Picture2, w, h: int) =
  e.ww = w
  e.wh = h
  e.work = newSeq[uint32](w * h)
  e.workBilinear = newSeq[uint32](w * h)
  let iw = e.pic.w
  let ih = e.pic.h
  var n = 0
  for y in 0 ..< h:
    for x in 0 ..< w:
      let px = 0.5 + x.float64 * float64(iw - 2) / w.float64
      let py = 0.5 + y.float64 * float64(ih - 2) / h.float64
      let pxi = int(px)
      let pyi = int(py)
      let fx = uint32(uint8(ftol((px - pxi.float64) * 256) and 0xff))
      let fy = uint32(uint8(ftol((py - pyi.float64) * 256) and 0xff))
      let l1 = mul255(255 - fx, 255 - fy)
      let l2 = mul255(fx, 255 - fy)
      let l3 = mul255(255 - fx, fy)
      let l4 = mul255(fx, fy)
      let i = pxi + pyi * iw
      let a = e.pic.px[i]
      let b = e.pic.px[min(i + 1, e.pic.px.high)]
      let c = e.pic.px[min(i + iw, e.pic.px.high)]
      let d = e.pic.px[min(i + iw + 1, e.pic.px.high)]
      var v = 0'u32
      for s in [0'u32, 8, 16]:
        v = v or ((mul255((a shr s) and 0xff, l1) + mul255((b shr s) and 0xff, l2) +
                   mul255((c shr s) and 0xff, l3) + mul255((d shr s) and 0xff, l4)) shl s)
      e.workBilinear[n] = v
      e.work[n] = e.pic.px[1 + x * (iw - 2) div w + (1 + y * (ih - 2) div h) * iw]
      inc n

method render(e: Picture2, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if e.pic.w == 0: return 0
  if e.ww != w or e.wh != h: e.refresh(w, h)
  let beat = isBeat != 0
  let src = if (if beat: e.beatBilinear else: e.bilinear): e.workBilinear else: e.work
  let mode = if beat: e.beatBlend else: e.blend
  let v = uint32((if beat: e.beatAdjust else: e.adjust) and 0xff)
  for i in 0 ..< w * h:
    let s = src[i]
    let d = fb[i]
    case mode
    of 0: fb[i] = s
    of 1: fb[i] = blendAdd(s and 0xffffff, d and 0xffffff)
    of 2: fb[i] = blendMax(s, d)
    of 3: fb[i] = ((s shr 1) and 0x7f7f7f) + ((d shr 1) and 0x7f7f7f)
    of 4: fb[i] = blendSub(d and 0xffffff, s)
    of 5: fb[i] = blendSub(s, d and 0xffffff)
    of 6:
      var r = 0'u32
      for sh in [0'u32, 8, 16]: r = r or (mul255((s shr sh) and 0xff, (d shr sh) and 0xff) shl sh)
      fb[i] = r
    of 7:
      var r = 0'u32
      for sh in [0'u32, 8, 16]:
        r = r or ((mul255((s shr sh) and 0xff, v) + mul255((d shr sh) and 0xff, 255 - v)) shl sh)
      fb[i] = r
    of 8: fb[i] = s xor d
    of 9: fb[i] = blendMin(s, d)
    else: discard
  0

proc registerApes3*() =
  registerApe("Acko.net: Texer II", newTexer2)
  registerApe("Texer", newTexer)
  registerApe("Holden03: Convolution Filter", newConvolution)
  registerApe("Virtual Effect: Addborders", newAddBorders)
  registerApe("Picture II", newPicture2)
