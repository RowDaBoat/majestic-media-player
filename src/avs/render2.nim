# Ported from Advanced Visualization Studio 2.81d, Copyright 2005 Nullsoft, Inc.
# BSD license: assets/licenses/AVS-Nullsoft-BSD.txt

## Render effects: Rotating Stars, Dot Fountain, Dot Grid, Moving Particle,
## Starfield, Bass Spin, Timescope (r_rotstar.cpp, r_dotfnt.cpp, r_dotgrid.cpp,
## r_parts.cpp, r_stars.cpp, r_bspin.cpp, r_timescope.cpp).

import std/math
import core, list

proc cycleColor(colors: openArray[uint32], num: int, pos: var int): uint32 =
  inc pos
  if pos >= num * 64: pos = 0
  let p = pos div 64
  let r = uint32(pos and 63)
  let c1 = colors[p]
  let c2 = if p + 1 < num: colors[p + 1] else: colors[0]
  let r1 = ((c1 and 255) * (63 - r) + (c2 and 255) * r) div 64
  let r2 = (((c1 shr 8) and 255) * (63 - r) + ((c2 shr 8) and 255) * r) div 64
  let r3 = (((c1 shr 16) and 255) * (63 - r) + ((c2 shr 16) and 255) * r) div 64
  r1 or (r2 shl 8) or (r3 shl 16)

proc loadColorList(d: openArray[byte], pos: var int, colors: var array[16, uint32], num: var int) =
  if d.len - pos >= 4:
    num = int(getInt(d, pos))
    pos += 4
  var x = 0
  if num <= 16:
    while d.len - pos >= 4 and x < num:
      colors[x] = cast[uint32](getInt(d, pos))
      inc x
      pos += 4
  else: num = 0

proc flatVis(vis: var VisData, i: int): int8 {.inline.} =
  ## visdata as one array of 2304 chars, past the end 0.
  if i < 0 or i >= 2304: 0'i8 else: vis[i div 1152][(i div 576) mod 2][i mod 576]

# --- Rotating Stars -------------------------------------------------------------------

type RotStar = ref object of Effect
  numColors: int
  colors: array[16, uint32]
  colorPos: int
  r1: float64

method desc(e: RotStar): string = "Render / Rotating Stars"

proc newRotStar(): Effect =
  let e = RotStar(numColors: 1)
  e.colors[0] = colorRgb(255, 255, 255)
  e

method load(e: RotStar, d: openArray[byte]) =
  var pos = 0
  loadColorList(d, pos, e.colors, e.numColors)

method render(e: RotStar, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if (isBeat and BeatPreinit) != 0: return 0
  if e.numColors == 0: return 0
  let color = cycleColor(e.colors, e.numColors, e.colorPos)
  let x = ftol(cos(e.r1) * w.float64 / 4.0)
  let y = ftol(sin(e.r1) * h.float64 / 4.0)
  let lw = lineWidth()
  for c in 0 .. 1:
    var r2 = -e.r1
    var s = 0
    var a = x
    var b = y
    for l in 3 ..< 14:
      let v = int(vis[0][c][l])  # signed: peaks over 127 don't count
      if v > s and v > int(vis[0][c][l + 1]) + 4 and v > int(vis[0][c][l - 1]) + 4: s = v
    if c == 1:
      a = -a
      b = -b
    let vw = w.float64 / 8.0 * float64(s + 9) / 88.0
    let vh = h.float64 / 8.0 * float64(s + 9) / 88.0
    let nx = ftol(cos(r2) * vw)
    let ny = ftol(sin(r2) * vh)
    var lx = w div 2 + a + nx
    var ly = h div 2 + b + ny
    r2 += 3.14159 * 4.0 / 5.0
    for t in 0 ..< 5:
      let nx = ftol(cos(r2) * vw + float64(w div 2 + a))
      let ny = ftol(sin(r2) * vh + float64(h div 2 + b))
      r2 += 3.14159 * 4.0 / 5.0
      line(fb, lx, ly, nx, ny, w, h, color, lw)
      lx = nx
      ly = ny
  e.r1 += 0.1
  0

# --- Dot Fountain ------------------------------------------------------------------------

const
  RotDiv = 30
  RotHeight = 256

type
  FountainPoint = object
    r, dr, h, dh, ax, ay: float32
    c: uint32

  DotFountain = ref object of Effect
    r: float32
    points: array[RotHeight, array[RotDiv, FountainPoint]]
    colorTab: array[64, uint32]
    rotvel, angle: int32
    colors: array[5, uint32]

method desc(e: DotFountain): string = "Render / Dot Fountain"

proc initColorTab(e: DotFountain) =
  for t in 0 ..< 4:
    var r = int32(e.colors[t] and 255) shl 16
    var g = int32((e.colors[t] shr 8) and 255) shl 16
    var b = int32((e.colors[t] shr 16) and 255) shl 16
    let dr = ((int32(e.colors[t + 1] and 255) - int32(e.colors[t] and 255)) shl 16) div 16
    let dg = ((int32((e.colors[t + 1] shr 8) and 255) - int32((e.colors[t] shr 8) and 255)) shl 16) div 16
    let db = ((int32((e.colors[t + 1] shr 16) and 255) - int32((e.colors[t] shr 16) and 255)) shl 16) div 16
    for x in 0 ..< 16:
      e.colorTab[t * 16 + x] = uint32(r shr 16) or (uint32(g shr 16) shl 8) or (uint32(b shr 16) shl 16)
      r += dr; g += dg; b += db

proc newDotFountain(): Effect =
  let e = DotFountain(angle: -20, rotvel: 16)
  e.colors = [colorRgb(24, 107, 28), colorRgb(35, 10, 255), colorRgb(116, 29, 42),
              colorRgb(217, 54, 144), colorRgb(255, 136, 107)]
  e.initColorTab()
  e

method load(e: DotFountain, d: openArray[byte]) =
  var pos = 0
  if d.len - pos >= 4: (e.rotvel = getInt(d, pos); pos += 4)
  for x in 0 ..< 5:
    if d.len - pos >= 4: (e.colors[x] = cast[uint32](getInt(d, pos)); pos += 4)
  if d.len - pos >= 4: (e.angle = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.r = float32(getInt(d, pos).float64 / 32.0); pos += 4)
  e.initColorTab()

method render(e: DotFountain, vis: var VisData, isBeat: int32, fb, fbout: Pixels, width, height: int): int =
  if (isBeat and BeatPreinit) != 0: return 0
  var m, m2: Mat4
  matrixRotate(m, 2, e.r)
  matrixRotate(m2, 1, e.angle.float32)
  matrixMultiply(m, m2)
  matrixTranslate(m2, 0, -20, 400)
  matrixMultiply(m, m2)
  let pb = e.points[0]
  var fo = RotHeight - 2
  while true:
    let booga = float32(1.3 / float64(fo + 100))
    for p in 0 ..< RotDiv:
      var o = e.points[fo][p]
      o.r = float32(o.r.float64 + o.dr.float64)
      o.dh = float32(o.dh.float64 + float64(0.05'f32))
      o.dr = float32(o.dr.float64 + booga.float64)
      o.h = float32(o.h.float64 + o.dh.float64)
      e.points[fo + 1][p] = o
    if fo == 0: break
    dec fo
  for p in 0 ..< RotDiv:
    var t = int(cast[uint8](vis[1][0][p]) xor 128)
    t = t * 5
    t = t div 4  # C division truncates toward zero, as div does
    t -= 64
    if isBeat != 0: t += 128
    if t > 255: t = 255
    let o = addr e.points[0][p]
    o.r = 1.0
    var dr = float32(t.float64 / 200.0)
    if dr < 0: dr = -dr
    o.h = 250
    dr = float32(dr.float64 + 1.0)
    o.dh = float32(-dr.float64 * (100.0 + (o.dh.float64 - pb[p].dh.float64)) / 100.0 * float64(2.8'f32))
    t = t div 4
    if t > 63: t = 63
    if t >= 0: o.c = e.colorTab[t]
    else:
      # C indexed before the table, into the end of the points array.
      let off = RotHeight * RotDiv * 7 + t
      let q = e.points[off div 7 div RotDiv][(off div 7) mod RotDiv]
      o.c = case off mod 7
        of 0: cast[uint32](q.r)
        of 1: cast[uint32](q.dr)
        of 2: cast[uint32](q.h)
        of 3: cast[uint32](q.dh)
        of 4: cast[uint32](q.ax)
        of 5: cast[uint32](q.ay)
        else: q.c
    let a = float32(p.float64 * float64(3.14159'f32) * 2.0 / RotDiv.float64)
    o.ax = float32(sin(a.float64))
    o.ay = float32(cos(a.float64))
    o.dr = 0
  var adj = float32(width.float64 * 440.0 / 640.0)
  let adj2 = float32(height.float64 * 440.0 / 480.0)
  if adj2 < adj: adj = adj2
  for fo in 0 ..< RotHeight:
    for p in 0 ..< RotDiv:
      let pt = e.points[fo][p]
      var (x, y, z) = matrixApply(m, float32(pt.ax.float64 * pt.r.float64), pt.h,
                                  float32(pt.ay.float64 * pt.r.float64))
      z = float32(adj.float64 / z.float64)
      if z > 0.0000001:
        let ix = ftol(x.float64 * z.float64) + width div 2
        let iy = ftol(y.float64 * z.float64) + height div 2
        if iy >= 0 and iy < height and ix >= 0 and ix < width:
          blendLine(fb[iy * width + ix], pt.c)
  e.r = float32(e.r.float64 + e.rotvel.float64 / 5.0)
  if e.r >= 360: e.r = float32(e.r.float64 - 360)
  if e.r < 0: e.r = float32(e.r.float64 + 360)
  0

# --- Dot Grid ---------------------------------------------------------------------------------

type DotGrid = ref object of Effect
  numColors: int
  colors: array[16, uint32]
  colorPos: int
  xp, yp, xMove, yMove, spacing, blend: int32

method desc(e: DotGrid): string = "Render / Dot Grid"

proc newDotGrid(): Effect =
  let e = DotGrid(numColors: 1, xMove: 128, yMove: 128, spacing: 8, blend: 3)
  e.colors[0] = colorRgb(255, 255, 255)
  e

method load(e: DotGrid, d: openArray[byte]) =
  var pos = 0
  loadColorList(d, pos, e.colors, e.numColors)
  if d.len - pos >= 4: (e.spacing = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.xMove = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.yMove = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.blend = getInt(d, pos); pos += 4)

method render(e: DotGrid, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if (isBeat and BeatPreinit) != 0: return 0
  if e.numColors == 0: return 0
  let color = cycleColor(e.colors, e.numColors, e.colorPos)
  if e.spacing < 2: e.spacing = 2
  while e.yp < 0: e.yp += e.spacing * 256
  while e.xp < 0: e.xp += e.spacing * 256
  let sp = int(e.spacing)
  let sy = int(e.yp shr 8) mod sp
  let sx = int(e.xp shr 8) mod sp
  var y = sy
  while y < h:
    var x = sx
    let row = y * w
    while x < w:
      case e.blend
      of 1: fb[row + x] = blendAdd(fb[row + x], color)
      of 2: fb[row + x] = blendAvg(fb[row + x], color)
      of 3: blendLine(fb[row + x], color)
      else: fb[row + x] = color
      x += sp
    y += sp
  e.xp += e.xMove
  e.yp += e.yMove
  0

# --- Moving Particle --------------------------------------------------------------------------

type Particle = ref object of Effect
  enabled: int32
  color: uint32
  maxdist, size, size2, blend: int32
  sPos: int
  c, v, p: array[2, float64]

method desc(e: Particle): string = "Render / Moving Particle"

proc newParticle(): Effect =
  Particle(blend: 1, size: 8, size2: 8, sPos: 8, maxdist: 16, enabled: 1,
           color: colorRgb(255, 255, 255), v: [-0.01551, 0.0], p: [-0.6, 0.3])

method load(e: Particle, d: openArray[byte]) =
  var pos = 0
  if d.len - pos >= 4: (e.enabled = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.color = cast[uint32](getInt(d, pos)); pos += 4)
  if d.len - pos >= 4: (e.maxdist = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.size = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.size2 = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.blend = getInt(d, pos); pos += 4)
  e.sPos = e.size

method render(e: Particle, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if (e.enabled and 1) == 0: return 0
  if (isBeat and BeatPreinit) != 0: return 0
  let ss = min(h div 2, (w * 3) div 8)
  if isBeat != 0:
    e.c[0] = float32(float64((crand() mod 33) - 16) / 48.0).float64
    e.c[1] = float32(float64((crand() mod 33) - 16) / 48.0).float64
  for k in 0 .. 1:
    e.v[k] -= 0.004 * (e.p[k] - e.c[k])
  for k in 0 .. 1:
    e.p[k] += e.v[k]
  for k in 0 .. 1:
    e.v[k] *= 0.991
  let xp = ftol(e.p[0] * ss.float64 * (e.maxdist.float64 / 32.0)) + w div 2
  var yp = ftol(e.p[1] * ss.float64 * (e.maxdist.float64 / 32.0)) + h div 2
  if isBeat != 0 and (e.enabled and 2) != 0: e.sPos = e.size2
  var sz = e.sPos
  e.sPos = (e.sPos + e.size) div 2
  template put(i: int) =
    case e.blend
    of 0: fb[i] = e.color
    of 2: fb[i] = blendAvg(fb[i], e.color)
    of 3: blendLine(fb[i], e.color)
    else: fb[i] = blendAdd(fb[i], e.color)
  if sz <= 1:
    if xp >= 0 and yp >= 0 and xp < w and yp < h: put(xp + yp * w)
    return 0
  if sz > 128: sz = 128
  let md = float64(sz * sz) * 0.25
  yp -= sz div 2
  for y in 0 ..< sz:
    if yp + y >= 0 and yp + y < h:
      let yd = y.float64 - sz.float64 * 0.5
      let l = sqrt(md - yd * yd)
      var xs = ftol(l + 0.99)
      if xs < 1: xs = 1
      var xe = xp + xs
      if xe > w: xe = w
      var xst = xp - xs
      if xst < 0: xst = 0
      for x in xst ..< xe: put(x + (yp + y) * w)
  0

# --- Starfield ------------------------------------------------------------------------------------

type
  Star = object
    x, y: int32
    z, speed: float32

  StarField = ref object of Effect
    enabled: int32
    color: uint32
    maxStars, maxStarsSet: int
    xoff, yoff, zoff: int32
    warpSpeed: float32
    blend, blendavg: int32
    stars: array[4096, Star]
    width, height: int
    onbeat: int32
    spdBeat, incBeat: float32
    durFrames: int32
    currentSpeed: float32
    nc: int32

method desc(e: StarField): string = "Render / Starfield"

proc newStarField(): Effect =
  StarField(color: 0xFFFFFF, enabled: 1, maxStars: 350, maxStarsSet: 350, zoff: 255,
            warpSpeed: 6, currentSpeed: 6, spdBeat: 4, durFrames: 15)

proc getFloat(d: openArray[byte], pos: int): float32 = cast[float32](getInt(d, pos))

method load(e: StarField, d: openArray[byte]) =
  var pos = 0
  if d.len - pos >= 4: (e.enabled = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.color = cast[uint32](getInt(d, pos)); pos += 4)
  if d.len - pos >= 4: (e.blend = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.blendavg = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.warpSpeed = getFloat(d, pos); pos += 4)
  e.currentSpeed = e.warpSpeed
  if d.len - pos >= 4: (e.maxStarsSet = int(getInt(d, pos)); pos += 4)
  if d.len - pos >= 4: (e.onbeat = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.spdBeat = getFloat(d, pos); pos += 4)
  if d.len - pos >= 4: (e.durFrames = getInt(d, pos); pos += 4)

proc mulDiv(a, b, c: int): int =
  ## Windows' MulDiv: a*b/c rounded half away from zero.
  if c == 0: return -1
  let p = a * b
  let q = (abs(p) + abs(c) div 2) div abs(c)
  if (p < 0) != (c < 0): -q else: q

proc createStar(e: StarField, a: int) =
  e.stars[a].x = int32((crand() mod e.width) - e.xoff)
  e.stars[a].y = int32((crand() mod e.height) - e.yoff)
  e.stars[a].z = e.zoff.float32

proc initStars(e: StarField) =
  e.maxStars = mulDiv(e.maxStarsSet, e.width * e.height, 512 * 384)
  if e.maxStars > 4095: e.maxStars = 4095
  for i in 0 ..< e.maxStars:
    e.stars[i].x = int32((crand() mod e.width) - e.xoff)
    e.stars[i].y = int32((crand() mod e.height) - e.yoff)
    e.stars[i].z = float32(crand() mod 255)
    e.stars[i].speed = float32(float64(crand() mod 9 + 1) / 10)

proc blendAdapt(a, b: uint32, divisor: int): uint32 =
  uint32(int(((a shr 4) and 0x0F0F0F)) * (16 - divisor) + int((b shr 4) and 0x0F0F0F) * divisor)

method render(e: StarField, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if e.enabled == 0: return 0
  if e.onbeat != 0 and isBeat != 0:
    e.currentSpeed = e.spdBeat
    e.incBeat = float32((e.warpSpeed.float64 - e.currentSpeed.float64) / e.durFrames.float64)
    e.nc = e.durFrames
  if e.width != w or e.height != h:
    e.width = w
    e.height = h
    e.xoff = int32(w div 2)
    e.yoff = int32(h div 2)
    e.initStars()
  if (isBeat and BeatPreinit) != 0: return 0
  for i in 0 ..< e.maxStars:
    let s = addr e.stars[i]
    let iz = ftol(s.z)
    if iz > 0:
      let nx = (int(s.x) shl 7) div iz + e.xoff
      let ny = (int(s.y) shl 7) div iz + e.yoff
      if nx > 0 and nx < w and ny > 0 and ny < h:
        var c = ftol(float64(255 - iz) * s.speed.float64)
        var col: uint32
        if e.color != 0xFFFFFF:
          let g = uint32(c and 0xff)
          col = blendAdapt(g or (g shl 8) or (g shl 16), e.color, c shr 4)
        else:
          col = uint32(c) or (uint32(c) shl 8) or (uint32(c) shl 16)
        let p = addr fb[ny * w + nx]
        p[] = if e.blend != 0: blendAdd(p[], col) elif e.blendavg != 0: blendAvg(p[], col) else: col
        s.z = float32(s.z.float64 - s.speed.float64 * e.currentSpeed.float64)
      else: e.createStar(i)
    else: e.createStar(i)
  if e.nc == 0: e.currentSpeed = e.warpSpeed
  else:
    e.currentSpeed = float32(max(0.0, e.currentSpeed.float64 + e.incBeat.float64))
    dec e.nc
  0

# --- Bass Spin --------------------------------------------------------------------------------------

type BassSpin = ref object of Effect
  enabled: int32
  colors: array[2, uint32]
  mode: int32
  lastA: int
  lx, ly: array[2, array[2, int]]
  rv, v, dir: array[2, float64]

method desc(e: BassSpin): string = "Render / Bass Spin"

proc newBassSpin(): Effect =
  BassSpin(enabled: 3, colors: [colorRgb(255, 255, 255), colorRgb(255, 255, 255)],
           rv: [3.14159, 0.0], dir: [-1.0, 1.0], mode: 1)

method load(e: BassSpin, d: openArray[byte]) =
  var pos = 0
  if d.len - pos >= 4: (e.enabled = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.colors[0] = cast[uint32](getInt(d, pos)); pos += 4)
  if d.len - pos >= 4: (e.colors[1] = cast[uint32](getInt(d, pos)); pos += 4)
  if d.len - pos >= 4: (e.mode = getInt(d, pos); pos += 4)

proc triangle(fb: Pixels, pts0: array[6, int], width, height: int, color: uint32) =
  var p = pts0
  for y in 0 .. 1:
    if p[1] > p[3]:
      swap(p[0], p[2]); swap(p[1], p[3])
    if p[3] > p[5]:
      swap(p[2], p[4]); swap(p[3], p[5])
  var x1 = p[0] shl 16
  var x2 = x1
  var dx1 = if p[1] < p[3]: ((p[2] - p[0]) shl 16) div (p[3] - p[1]) else: 0
  let dx2 = if p[1] < p[5]: ((p[4] - p[0]) shl 16) div (p[5] - p[1]) else: 0
  var row = p[1] * width
  let ymax = min(p[5], height)
  var y = p[1]
  while y < ymax:
    if y == p[3]:
      if y == p[5]: return
      x1 = p[2] shl 16
      dx1 = ((p[4] - p[2]) shl 16) div (p[5] - p[3])
    if y >= 0:
      var x = (min(x1, x2) - 32768) shr 16
      var xl = ((max(x1, x2) + 32768) shr 16) - x
      if xl < 0: xl = -xl
      if xl == 0: inc xl
      var t = row + x
      if x < 0:
        t -= x
        xl -= x
      if x + xl >= width: xl = width - x
      if xl > 0:
        for k in 0 ..< xl:
          let i = t + k
          if i >= 0 and i < width * height: blendLine(fb[i], color)
    row += width
    x1 += dx1
    x2 += dx2
    inc y

method render(e: BassSpin, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if (isBeat and BeatPreinit) != 0: return 0
  let lw = lineWidth()
  for y in 0 .. 1:
    if (e.enabled and (1'i32 shl y)) == 0: continue
    let ss = min(h div 2, (w * 3) div 8)
    var s = ss.float64
    let cx = if y == 0: w div 2 - ss div 2 else: w div 2 + ss div 2
    var d = 0
    for x in 0 ..< 44: d += int(cast[uint8](vis[0][y][x]))
    var a = (d * 512) div (e.lastA + 30 * 256)
    e.lastA = d
    if a > 255: a = 255
    e.v[y] = 0.7 * (max(a - 104, 12).float64 / 96.0) + 0.3 * e.v[y]
    e.rv[y] += 3.14159 / 6.0 * e.v[y] * e.dir[y]
    s *= a.float64 * 1.0 / float64(256.0'f32)
    let yp = ftol(sin(e.rv[y]) * s)
    let xp = ftol(cos(e.rv[y]) * s)
    let oc = e.colors[y]
    if e.mode == 0:
      if e.lx[0][y] != 0 or e.ly[0][y] != 0:
        line(fb, e.lx[0][y], e.ly[0][y], xp + cx, yp + h div 2, w, h, oc, lw)
      e.lx[0][y] = xp + cx
      e.ly[0][y] = yp + h div 2
      line(fb, cx, h div 2, cx + xp, h div 2 + yp, w, h, oc, lw)
      if e.lx[1][y] != 0 or e.ly[1][y] != 0:
        line(fb, e.lx[1][y], e.ly[1][y], cx - xp, h div 2 - yp, w, h, oc, lw)
      e.lx[1][y] = cx - xp
      e.ly[1][y] = h div 2 - yp
      line(fb, cx, h div 2, cx - xp, h div 2 - yp, w, h, oc, lw)
    elif e.mode == 1:
      if e.lx[0][y] != 0 or e.ly[0][y] != 0:
        triangle(fb, [cx, h div 2, e.lx[0][y], e.ly[0][y], xp + cx, yp + h div 2], w, h, oc)
      e.lx[0][y] = xp + cx
      e.ly[0][y] = yp + h div 2
      if e.lx[1][y] != 0 or e.ly[1][y] != 0:
        triangle(fb, [cx, h div 2, e.lx[1][y], e.ly[1][y], cx - xp, h div 2 - yp], w, h, oc)
      e.lx[1][y] = cx - xp
      e.ly[1][y] = h div 2 - yp
  0

# --- Timescope -------------------------------------------------------------------------------------

type Timescope = ref object of Effect
  whichCh, enabled: int32
  color: uint32
  blend, blendavg, nbands: int32
  x: int

method desc(e: Timescope): string = "Render / Timescope"

proc newTimescope(): Effect =
  Timescope(color: 0xFFFFFF, blend: 2, enabled: 1, nbands: 576, whichCh: 2)

method load(e: Timescope, d: openArray[byte]) =
  var pos = 0
  if d.len - pos >= 4: (e.enabled = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.color = cast[uint32](getInt(d, pos)); pos += 4)
  if d.len - pos >= 4: (e.blend = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.blendavg = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.whichCh = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.nbands = getInt(d, pos); pos += 4)

method render(e: Timescope, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if e.enabled == 0: return 0
  if (isBeat and BeatPreinit) != 0: return 0
  e.x = (e.x + 1) mod w
  let r = int(e.color and 0xff)
  let g = int((e.color shr 8) and 0xff)
  let b = int((e.color shr 16) and 0xff)
  for i in 0 ..< h:
    # The original reads spectrum channel 0 whatever the channel setting.
    let c = int(cast[uint8](flatVis(vis, (i * int(e.nbands)) div h)))
    let col = uint32((r * c) div 256 + (((g * c) div 256) shl 8) + (((b * c) div 256) shl 16))
    let p = addr fb[e.x + i * w]
    if e.blend == 2: blendLine(p[], col)
    elif e.blend == 1: p[] = blendAdd(p[], col)
    elif e.blendavg != 0: p[] = blendAvg(p[], col)
    else: p[] = col
  0

proc registerRender2*() =
  registerEffect(7, newBassSpin)
  registerEffect(8, newParticle)
  registerEffect(13, newRotStar)
  registerEffect(17, newDotGrid)
  registerEffect(19, newDotFountain)
  registerEffect(27, newStarField)
  registerEffect(39, newTimescope)
