# Ported from Advanced Visualization Studio 2.81d, Copyright 2005 Nullsoft, Inc.
# BSD license: assets/licenses/AVS-Nullsoft-BSD.txt

## The AVS engine's common ground (r_defs.h, linedraw.cpp, matrix.cpp, rlib.cpp):
## pixels, blending as the MMX build did it, line drawing, the global buffers
## and the effect base type.
##
## Pixels are 32-bit 0x00RRGGBB, rows top to bottom, as AVS's DirectDraw
## surfaces were. Every effect renders `fb` (the current frame) into itself or
## into `fbout`, returning 1 when its result is in `fbout`.

import std/[algorithm, math, os, strutils, tables, times]
import eel
export eel

type
  Pixels* = ptr UncheckedArray[uint32]
  VisData* = array[2, array[2, array[576, int8]]]
    ## [0] spectrum, [1] waveform; [channel]; 576 values. Spectrum values are
    ## unsigned bytes stored in chars, as Winamp handed them over.

  Effect* = ref object of RootObj
    ## A preset's effect (C_RBASE).
    vm*: EelVm               ## its variables, for effects with code

const
  BeatPreinit* = 0x80000000'i32  ## isBeat flag: a transition's warm-up render
  RetSetBeat* = 0x10000000
  RetClearBeat* = 0x20000000
  NBuf* = 8

method render*(e: Effect, vis: var VisData, isBeat: int32, fb, fbout: Pixels,
               w, h: int): int {.base.} = 0
method load*(e: Effect, data: openArray[byte]) {.base.} = discard
method desc*(e: Effect): string {.base.} = "Unknown"

# --- reading configs ---------------------------------------------------------

proc getInt*(d: openArray[byte], pos: int): int32 =
  ## GET_INT(): a little-endian int at pos (0 past the end).
  if pos < 0 or pos + 4 > d.len: return 0
  cast[int32](uint32(d[pos]) or (uint32(d[pos + 1]) shl 8) or (uint32(d[pos + 2]) shl 16) or
              (uint32(d[pos + 3]) shl 24))

proc loadString*(d: openArray[byte], pos: var int): string =
  ## C_RBASE::load_string: a length-prefixed string, NUL-terminated.
  let size = getInt(d, pos)
  pos += 4
  if size > 0 and d.len - pos >= size:
    for i in 0 ..< size:
      let c = d[pos + i]
      if c == 0: break
      result.add char(c)
    pos += size

proc cString*(d: openArray[byte], at, maxLen: int): string =
  ## A NUL-terminated string in a fixed field.
  for i in 0 ..< maxLen:
    if at + i >= d.len: break
    let c = d[at + i]
    if c == 0: break
    result.add char(c)

# --- blending ----------------------------------------------------------------

var blendTable*: array[256, array[256, uint8]]
for j in 0 .. 255:
  for i in 0 .. 255:
    blendTable[i][j] = uint8((i.float64 / 255.0) * j.float32.float64)

var lineBlendMode* {.threadvar.}: int32
  ## g_line_blend_mode: bits 0-7 the mode, 8-15 the adjustable blend's value,
  ## 16-23 the line width; bit 31 set when Set Render Mode is active.

proc blendAdd*(a, b: uint32): uint32 {.inline.} =
  ## BLEND: saturating per byte (the alpha byte wraps, as in C).
  result = min((a and 0xff) + (b and 0xff), 0xff'u32)
  result = result or min((a and 0xff00) + (b and 0xff00), 0xff00'u32)
  result = result or min((a and 0xff0000) + (b and 0xff0000), 0xff0000'u32)
  result = result or min((a and 0xff000000'u32) + (b and 0xff000000'u32), 0xff000000'u32)

proc blendAddSat*(a, b: uint32): uint32 {.inline.} =
  ## MMX paddusb: saturating per byte, alpha too.
  result = min((a and 0xff) + (b and 0xff), 0xff'u32)
  result = result or min((a and 0xff00) + (b and 0xff00), 0xff00'u32)
  result = result or min((a and 0xff0000) + (b and 0xff0000), 0xff0000'u32)
  result = result or uint32(min(uint64(a and 0xff000000'u32) + uint64(b and 0xff000000'u32), 0xff000000'u64))

proc blendMax*(a, b: uint32): uint32 {.inline.} =
  max(a and 0xff, b and 0xff) or max(a and 0xff00, b and 0xff00) or
    max(a and 0xff0000, b and 0xff0000)

proc blendMin*(a, b: uint32): uint32 {.inline.} =
  min(a and 0xff, b and 0xff) or min(a and 0xff00, b and 0xff00) or
    min(a and 0xff0000, b and 0xff0000)

proc blendAvg*(a, b: uint32): uint32 {.inline.} =
  const m = not ((1'u32 shl 7) or (1'u32 shl 15) or (1'u32 shl 23))
  ((a shr 1) and m) + ((b shr 1) and m)

proc blendSub*(a, b: uint32): uint32 {.inline.} =
  ## BLEND_SUB: a - b per byte, floored at 0 (in C's int arithmetic).
  template ch(m: uint32): int32 =
    max(cast[int32]((a and m) - (b and m)), 0'i32)
  uint32(ch(0xff'u32) or ch(0xff00'u32) or ch(0xff0000'u32) or ch(0xff000000'u32))

proc blendAdj*(a, b: uint32, v: int): uint32 {.inline.} =
  ## BLEND_ADJ as MMX did it: (a*v + b*(255-v)) >> 8 per byte, alpha too.
  let v = uint32(v and 0xff)
  let iv = 0xff'u32 - v
  template ch(s: uint32): uint32 =
    ((((a shr s) and 0xff) * v + ((b shr s) and 0xff) * iv) shr 8) shl s
  ch(0) or ch(8) or ch(16) or ch(24)

proc blendAdjNoMmx*(a, b: uint32, v: int): uint32 {.inline.} =
  ## BLEND_ADJ_NOMMX (line drawing uses this one), with the /255 table.
  let v = v and 0xff
  var t = uint32(blendTable[a and 0xff][v]) + uint32(blendTable[b and 0xff][0xff - v])
  t = t or ((uint32(blendTable[(a shr 8) and 0xff][v]) + uint32(blendTable[(b shr 8) and 0xff][0xff - v])) shl 8)
  t = t or ((uint32(blendTable[(a shr 16) and 0xff][v]) + uint32(blendTable[(b shr 16) and 0xff][0xff - v])) shl 16)
  t

proc blendMul*(a, b: uint32): uint32 {.inline.} =
  ## BLEND_MUL, with the /255 table.
  uint32(blendTable[a and 0xff][b and 0xff]) or
    (uint32(blendTable[(a shr 8) and 0xff][(b shr 8) and 0xff]) shl 8) or
    (uint32(blendTable[(a shr 16) and 0xff][(b shr 16) and 0xff]) shl 16)

proc blendMulMmx*(a, b: uint32): uint32 {.inline.} =
  ## mmx_mulblend_block's: (a*b) >> 8 per byte, alpha too.
  template ch(s: uint32): uint32 =
    ((((a shr s) and 0xff) * ((b shr s) and 0xff)) shr 8) shl s
  ch(0) or ch(8) or ch(16) or ch(24)

proc blend4*(p: Pixels, i, w: int, xp, yp: int): uint32 {.inline.} =
  ## BLEND4 (MMX): bilinear between p[i], p[i+1], p[i+w], p[i+w+1]; xp, yp 0..255.
  let xp = uint32(xp)
  let yp = uint32(yp)
  let ixp = 0xff'u32 - xp
  let iyp = 0xff'u32 - yp
  let a = p[i]
  let b = p[i + 1]
  let c = p[i + w]
  let d = p[i + w + 1]
  template ch(s: uint32): uint32 =
    let top = (((a shr s) and 0xff) * ixp + ((b shr s) and 0xff) * xp) shr 8
    let bot = (((c shr s) and 0xff) * ixp + ((d shr s) and 0xff) * xp) shr 8
    (((top * iyp + bot * yp) shr 8) and 0xff) shl s
  ch(0) or ch(8) or ch(16) or ch(24)

proc blend4_16*(p: Pixels, i, w: int, xp, yp: int): uint32 {.inline.} =
  ## BLEND4_16: the same with 16-bit fractions.
  blend4(p, i, w, (xp shr 8) and 0xff, (yp shr 8) and 0xff)

proc blendLine*(p: var uint32, color: uint32) {.inline.} =
  ## BLEND_LINE: draws with the current line blend mode.
  let m = lineBlendMode and 0xff
  case m
  of 1: p = blendAdd(p, color)
  of 2: p = blendMax(p, color)
  of 3: p = blendAvg(p, color)
  of 4: p = blendSub(p, color)
  of 5: p = blendSub(color, p)
  of 6: p = blendMul(p, color)
  of 7: p = blendAdjNoMmx(p, color, (lineBlendMode shr 8) and 0xff)
  of 8: p = p xor color
  of 9: p = blendMin(p, color)
  else: p = color

proc lineWidth*(): int {.inline.} = int((lineBlendMode and 0xff0000) shr 16)

# --- blocks -----------------------------------------------------------------

proc avgBlock*(o, input: Pixels, n: int) =
  for i in 0 ..< n: o[i] = blendAvg(input[i], o[i])
proc addBlock*(o, input: Pixels, n: int) =
  for i in 0 ..< n: o[i] = blendAddSat(input[i], o[i])
proc mulBlock*(o, input: Pixels, n: int) =
  for i in 0 ..< n: o[i] = blendMulMmx(input[i], o[i])
proc adjBlock*(o, in1, in2: Pixels, n: int, v: int) =
  for i in 0 ..< n: o[i] = blendAdj(in1[i], in2[i], v)

proc copyPixels*(dst, src: Pixels, n: int) =
  if n > 0: copyMem(dst[0].addr, src[0].addr, n * 4)
proc clearPixels*(dst: Pixels, n: int) =
  if n > 0: zeroMem(dst[0].addr, n * 4)

# --- line drawing (linedraw.cpp) ------------------------------------------------

proc line*(fb: Pixels, x1, y1, x2, y2: int, width, height: int, color: uint32, lw0: int) =
  ## Bresenham with a width, as AVS drew lines; the endpoint is left out.
  var (x1, y1, x2, y2) = (x1, y1, x2, y2)
  let dy = abs(y2 - y1)
  let dx = abs(x2 - x1)
  var lw = lw0
  if lw < 1: lw = 1
  elif lw > 255: lw = 255
  let lw2 = lw div 2
  let n = width * height
  template put(i: int) =
    if i >= 0 and i < n: blendLine(fb[i], color)
  if dx == 0:
    x1 -= lw2
    if x1 + lw >= 0 and x1 < width:
      var d = max(min(y1, y2), 0)
      let ye = min(max(y1, y2), height - 1)
      if x1 < 0:
        lw += x1
        x1 = 0
      if x1 + lw >= width: lw = width - x1
      var o = d * width + x1
      if lw > 0:
        while d < ye:
          inc d
          for x in 0 ..< lw: put(o + x)
          o += width
    return
  if y1 == y2:
    y1 -= lw2
    if y1 + lw >= 0 and y1 < height:
      let d = max(min(x1, x2), 0)
      let xe = min(max(x1, x2), width - 1)
      if y1 < 0:
        lw += y1
        y1 = 0
      if y1 + lw >= height: lw = height - y1
      var o = y1 * width + d
      for y in 0 ..< lw:
        for lt in d ..< xe: put(o + lt - d)
        o += width
    return
  if dy <= dx:
    if x2 < x1:
      swap(x1, x2)
      swap(y1, y2)
    let yincr = if y2 > y1: 1 else: -1
    let offsincr = if y2 > y1: width else: -width
    y1 -= lw2
    var offs = y1 * width + x1
    var d = dy + dy - dx
    let eincr = dy + dy
    let neincr = d - dx
    if x2 >= 0 and x1 < width:
      if x1 < 0:
        var v = yincr * -x1
        if dx != 0: v = (v * dy) div dx
        y1 += v
        offs += v * width - x1
        x1 = 0
      if x2 > width: x2 = width
      while x1 < x2:
        var yp = y1
        var ype = y1 + lw
        var o = offs
        if yp < 0:
          o -= yp * width
          yp = 0
        if ype > height: ype = height
        while yp < ype:
          inc yp
          put(o)
          o += width
        if d < 0: d += eincr
        else:
          d += neincr
          y1 += yincr
          offs += offsincr
        inc offs
        inc x1
  else:
    if y2 < y1:
      swap(x1, x2)
      swap(y1, y2)
    let yincr = if x2 > x1: 1 else: -1
    var d = dx + dx - dy
    let eincr = dx + dx
    let neincr = d - dy
    x1 -= lw2
    var offs = y1 * width + x1
    if y2 >= 0 and y1 < height:
      if y1 < 0:
        var v = yincr * -y1
        if dy != 0: v = (v * dx) div dy
        x1 += v
        offs += v - y1 * width
        y1 = 0
      if y2 > height: y2 = height
      while y1 < y2:
        var xp = x1
        var xpe = x1 + lw
        var o = offs
        if xp < 0:
          o -= xp
          xp = 0
        if xpe > width: xpe = width
        while xp < xpe:
          inc xp
          # a row's run never wraps into the next: x stays within the row
          put(o)
          inc o
        if d < 0: d += eincr
        else:
          d += neincr
          x1 += yincr
          offs += yincr
        offs += width
        inc y1

# --- matrices (matrix.cpp) -----------------------------------------------------

type Mat4* = array[16, float32]

proc matrixRotate*(m: var Mat4, axis: int, deg: float32) =
  let d = float32(deg.float64 * float32(3.141592653589'f32).float64 / 180.0)
  for v in m.mitems: v = 0
  m[((axis - 1) shl 2) + axis - 1] = 1
  m[15] = 1
  let m1 = axis mod 3
  let m2 = (m1 + 1) mod 3
  let c = float32(cos(d.float64))
  let s = float32(sin(d.float64))
  m[(m1 shl 2) + m1] = c
  m[(m1 shl 2) + m2] = s
  m[(m2 shl 2) + m2] = c
  m[(m2 shl 2) + m1] = -s

proc matrixTranslate*(m: var Mat4, x, y, z: float32) =
  for v in m.mitems: v = 0
  m[0] = 1; m[5] = 1; m[10] = 1; m[15] = 1
  m[3] = x; m[7] = y; m[11] = z

proc matrixMultiply*(dest: var Mat4, src: Mat4) =
  let t = dest
  var i = 0
  var o = 0
  while i < 16:
    for c in 0 .. 3:
      dest[o] = float32(src[i].float64 * t[c].float64 + src[i + 1].float64 * t[4 + c].float64 +
                        src[i + 2].float64 * t[8 + c].float64 + src[i + 3].float64 * t[12 + c].float64)
      inc o
    i += 4

proc matrixApply*(m: Mat4, x, y, z: float32): (float32, float32, float32) =
  (float32(x.float64 * m[0] + y.float64 * m[1] + z.float64 * m[2] + m[3]),
   float32(x.float64 * m[4] + y.float64 * m[5] + z.float64 * m[6] + m[7]),
   float32(x.float64 * m[8] + y.float64 * m[9] + z.float64 * m[10] + m[11]))

# --- global buffers (getGlobalBuffer) ---------------------------------------------

type GlobalBuffer* = object
  data*: seq[uint32]
  w*, h*: int

var globalBuffers* {.threadvar.}: array[NBuf, GlobalBuffer]

proc getGlobalBuffer*(w, h, n: int, alloc: bool): Pixels =
  ## Buffer n at w x h, nil if it has another size (freed) and alloc is off.
  if n < 0 or n >= NBuf: return nil
  let b = addr globalBuffers[n]
  if b.data.len == 0 or b.w != w or b.h != h:
    b.data = @[]
    if alloc:
      b.w = w
      b.h = h
      b.data = newSeq[uint32](w * h)
      return cast[Pixels](b.data[0].addr)
    b.w = 0
    b.h = 0
    return nil
  cast[Pixels](b.data[0].addr)

# --- odds and ends -------------------------------------------------------------

proc ftol*(x: float64): int {.inline.} =
  ## C's (int) cast of a double (truncation; 0x80000000 when out of range).
  if x.isNaN or x >= 2147483648.0 or x <= -2147483649.0: return int(low(int32))
  int(x)

proc ftol*(x: float32): int {.inline.} = ftol(x.float64)

proc fistp*(x: float64): int {.inline.} = int(fistp32(x))

proc colorRgb*(r, g, b: int): uint32 =
  ## Windows' RGB(): 0x00BBGGRR.
  uint32(r and 0xff) or (uint32(g and 0xff) shl 8) or (uint32(b and 0xff) shl 16)

var tickCount* {.threadvar.}: uint32  ## GetTickCount() as the engine renders the frame

proc getTickCount*(): uint32 {.inline.} = tickCount

var presetDir* {.threadvar.}: string
  ## The folder of the preset being loaded, where its images are looked for.
var presetFilesFound* {.threadvar.}: seq[string]
  ## Every file findPresetFile has found (cleared by whoever wants them): the
  ## images a preset uses, to copy along with it.

const
  CollectionLevels = 3          ## how far above the preset's folder its collection may start
  CollectionMaxEntries = 100_000  ## what a collection search reads at most
  CollectionTtl = 30.0          ## seconds a collection's file index is reused

type CollectionIndex = object
  root: string
  built: float
  files: Table[string, string]  ## lowercase file name: the shallowest path

var collectionIndex {.threadvar.}: CollectionIndex

proc collectionRoot(dir: string): string =
  ## The folder CollectionLevels above dir, or the highest one below the home
  ## folder (never home itself, nor anything above it).
  let home = getHomeDir().normalizedPath
  result = ""
  var d = dir.normalizedPath
  for level in 0 .. CollectionLevels:
    if d.len == 0 or d == home or home.startsWith(d & DirSep) or
        d == d.parentDir: break
    result = d
    d = d.parentDir

proc indexCollection(root: string): Table[string, string] =
  ## Every file under root by lowercase name, shallower and then alphabetically
  ## earlier ones winning; hidden folders skipped.
  result = initTable[string, string]()
  var level = @[root]
  var seen = 0
  while level.len > 0 and seen < CollectionMaxEntries:
    var next: seq[string]
    for dir in level:
      var entries: seq[(PathComponent, string)]
      try:
        for kind, f in walkDir(dir): entries.add (kind, f)
      except OSError: continue
      entries.sort(proc (a, b: (PathComponent, string)): int = cmp(a[1], b[1]))
      for (kind, f) in entries:
        inc seen
        let base = f.extractFilename
        if kind in {pcFile, pcLinkToFile}:
          discard result.hasKeyOrPut(base.toLowerAscii, f)
        elif kind == pcDir and not base.startsWith('.'):
          next.add f
      if seen >= CollectionMaxEntries: break
    level = next

proc lookUpPresetFile(name: string): string =
  ## A file a preset names (a Texer's image), as AVS found it in its own
  ## folder (Winamp\Plugins\avs), where every pack's images ended up side by
  ## side: here in the preset's folder or one above it, as packs kept their
  ## images at their root, else anywhere in the collection the preset is in (up
  ## to CollectionLevels above it), any letter case. "" if none.
  if name.len == 0 or presetDir.len == 0: return ""
  let want = name.replace('\\', '/')
  let base = want.extractFilename
  var dir = presetDir
  for level in 0 .. CollectionLevels:
    let direct = dir / want
    if fileExists(direct): return direct
    try:
      for kind, f in walkDir(dir):
        if kind in {pcFile, pcLinkToFile} and cmpIgnoreCase(f.extractFilename, base) == 0:
          return f
    except OSError: discard
    let up = dir.parentDir
    if up.len == 0 or up == dir: break
    dir = up
  let root = collectionRoot(presetDir)
  if root.len == 0 or base.len == 0: return ""
  let now = epochTime()
  if collectionIndex.root != root or now - collectionIndex.built > CollectionTtl:
    collectionIndex = CollectionIndex(root: root, built: now, files: indexCollection(root))
  collectionIndex.files.getOrDefault(base.toLowerAscii)

proc findPresetFile*(name: string): string =
  ## A file a preset names, as lookUpPresetFile finds it, noted in
  ## presetFilesFound.
  result = lookUpPresetFile(name)
  if result.len > 0 and result notin presetFilesFound: presetFilesFound.add result

proc pixelsOf*(s: var seq[uint32]): Pixels {.inline.} =
  if s.len == 0: nil else: cast[Pixels](s[0].addr)
