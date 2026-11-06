## Render effects: Simple, SuperScope, Dot Plane, Oscilloscope Star, Ring
## (r_simple.cpp, r_sscope.cpp, r_dotpln.cpp, r_oscstar.cpp, r_oscring.cpp).

import std/math
import core, list

type ScopeData = array[577, uint8]
  ## A channel as the effects index it, one past the end included: C read
  ## the next byte of visdata there (the next channel's first, else 0).

proc channelData(vis: var VisData, kind, ch: int): ScopeData =
  ## visdata[kind][ch] as unsigned bytes.
  for i in 0 ..< 576: result[i] = cast[uint8](vis[kind][ch][i])
  let flat = kind * 2 + ch + 1
  if flat < 4: result[576] = cast[uint8](vis[flat div 2][flat mod 2][0])

proc centerData(vis: var VisData, kind: int): ScopeData =
  ## The two channels' average in signed chars, as C computed it.
  for i in 0 ..< 576:
    result[i] = cast[uint8](int8(vis[kind][0][i] div 2 + vis[kind][1][i] div 2))

proc cycleColor(colors: openArray[uint32], num: int, pos: var int): uint32 =
  ## The color fading through the list, 64 frames per color.
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

proc loadColors(d: openArray[byte], pos: var int, colors: var array[16, uint32],
                num: var int, bad: int) =
  if d.len - pos >= 4:
    num = int(getInt(d, pos))
    pos += 4
  var x = 0
  if num <= 16:
    while d.len - pos >= 4 and x < num:
      colors[x] = cast[uint32](getInt(d, pos))
      inc x
      pos += 4
  else: num = bad

# --- Simple -----------------------------------------------------------------------

type Simple = ref object of Effect
  effect: int32
  numColors: int
  colors: array[16, uint32]
  colorPos: int

method desc(e: Simple): string = "Render / Simple"

proc newSimple(): Effect =
  let e = Simple(effect: 0 or (2 shl 2) or (2 shl 4), numColors: 1)
  e.colors[0] = colorRgb(255, 255, 255)
  e

method load(e: Simple, d: openArray[byte]) =
  var pos = 0
  if d.len - pos >= 4: (e.effect = getInt(d, pos); pos += 4)
  loadColors(d, pos, e.colors, e.numColors, 0)

method render(e: Simple, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if e.numColors == 0: return 0
  if (isBeat and BeatPreinit) != 0: return 0
  let yscale = float32(h.float64 / 2.0 / 256.0)
  let xscale = float32(288.0 / w.float64)
  let whichCh = (e.effect shr 2) and 3
  let yPos = (e.effect shr 4) and 3
  let color = cycleColor(e.colors, e.numColors, e.colorPos)
  let kind = if (e.effect and 3) > 1: 1 else: 0
  let fa = if whichCh < 2: channelData(vis, kind, whichCh) else: centerData(vis, kind)
  let lw = lineWidth()
  if (e.effect and (1 shl 6)) != 0:
    if (e.effect and 2) == 2:  # dot scope
      var yh = int(yPos) * h div 2
      if yPos == 2: yh = h div 4
      for x in 0 ..< w:
        let r = float32(x.float64 * xscale.float64)
        let ir = ftol(r)
        let s1 = float32(r.float64 - ir.float64)
        let yr = float32(float64(fa[ir] xor 128) * (1.0 - s1.float64) + float64(fa[ir + 1] xor 128) * s1.float64)
        let y = yh + ftol(yr.float64 * yscale.float64)
        if y >= 0 and y < h: fb[x + y * w] = color
    else:  # dot analyzer
      var h2 = h div 2
      var ys = yscale
      let xs = float32(200.0 / w.float64)
      var adj = 1
      if yPos != 1:
        ys = -ys
        adj = 0
      if yPos == 2: h2 -= ftol(ys.float64 * 256 / 2)
      for x in 0 ..< w:
        let r = float32(x.float64 * xs.float64)
        let ir = ftol(r)
        let s1 = float32(r.float64 - ir.float64)
        let yr = float32(float64(fa[ir]) * (1.0 - s1.float64) + float64(fa[ir + 1]) * s1.float64)
        let y = h2 + adj + ftol(yr.float64 * ys.float64 - 1.0)
        if y >= 0 and y < h: fb[x + w * y] = color
  else:
    case e.effect and 3
    of 0:  # solid analyzer
      var h2 = h div 2
      var ys = yscale
      let xs = float32(200.0 / w.float64)
      var adj = 1
      if yPos != 1:
        ys = -ys
        adj = 0
      if yPos == 2: h2 -= ftol(ys.float64 * 256 / 2)
      for x in 0 ..< w:
        let r = float32(x.float64 * xs.float64)
        let ir = ftol(r)
        let s1 = float32(r.float64 - ir.float64)
        let yr = float32(float64(fa[ir]) * (1.0 - s1.float64) + float64(fa[ir + 1]) * s1.float64)
        line(fb, x, h2 - adj, x, h2 + adj + ftol(yr.float64 * ys.float64 - 1.0), w, h, color, lw)
    of 1:  # line analyzer
      var h2 = h div 2
      let xs = float32(1.0 / xscale.float64 * float64(288.0'f32 / 200.0'f32))
      var ys = yscale
      if yPos != 1: ys = -ys
      if yPos == 2: h2 -= ftol(ys.float64 * 256 / 2)
      var ly = h2 + ftol(float64(fa[0]) * ys.float64)
      var lx = 0
      for x in 1 ..< 200:
        let oy = h2 + ftol(float64(fa[x]) * ys.float64)
        let ox = ftol(x.float64 * xs.float64)
        line(fb, lx, ly, ox, oy, w, h, color, lw)
        ly = oy
        lx = ox
    of 2:  # line scope
      let xs = float32(1.0 / xscale.float64)
      let yh = if yPos == 2: h div 4 else: int(yPos) * h div 2
      var lx = 0
      var ly = yh + ftol(float64(int(fa[0] xor 128)) * yscale.float64)
      for x in 1 ..< 288:
        let ox = ftol(x.float64 * xs.float64)
        let oy = yh + ftol(float64(int(fa[x] xor 128)) * yscale.float64)
        line(fb, lx, ly, ox, oy, w, h, color, lw)
        lx = ox
        ly = oy
    else:  # solid scope
      var yh = int(yPos) * h div 2
      if yPos == 2: yh = h div 4
      let ys = yh + ftol(yscale.float64 * 128.0)
      for x in 0 ..< w:
        let r = float32(x.float64 * xscale.float64)
        let ir = ftol(r)
        let s1 = float32(r.float64 - ir.float64)
        let yr = float32(float64(fa[ir] xor 128) * (1.0 - s1.float64) + float64(fa[ir + 1] xor 128) * s1.float64)
        line(fb, x, ys - 1, x, yh + ftol(yr.float64 * yscale.float64), w, h, color, lw)
  0

# --- SuperScope ---------------------------------------------------------------------

type SuperScope = ref object of Effect
  code: array[4, string]   ## point, frame, beat, init
  compiled: array[4, EelCode]
  whichCh: int32
  numColors: int
  colors: array[16, uint32]
  mode: int32
  colorPos: int
  vN, vB, vX, vY, vI, vV, vW, vH, vRed, vGreen, vBlue, vLinesize, vSkip, vDrawmode: ptr float64
  inited, needRecompile: bool

method desc(e: SuperScope): string = "Render / SuperScope"

proc newSuperScope(): Effect =
  let e = SuperScope(whichCh: 2, numColors: 1, needRecompile: true, vm: newEelVm())
  e.colors[0] = colorRgb(255, 255, 255)
  e.code = ["d=i+v*0.2; r=t+i*$PI*4; x=cos(r)*d; y=sin(r)*d", "t=t-0.05", "", "n=800"]
  e

proc fixedCodes(d: openArray[byte], pos: var int, n: int): seq[string] =
  ## The pre-2.x layout: n code fields of 256 bytes.
  for k in 0 ..< n: result.add cString(d, pos + k * 256, 256)
  pos += n * 256

method load(e: SuperScope, d: openArray[byte]) =
  var pos = 0
  if d.len > 0 and d[0] == 1:
    pos = 1
    for k in 0 .. 3: e.code[k] = loadString(d, pos)
  elif d.len - pos >= 1024:
    let c = fixedCodes(d, pos, 4)
    for k in 0 .. 3: e.code[k] = c[k]
  if d.len - pos >= 4: (e.whichCh = getInt(d, pos); pos += 4)
  loadColors(d, pos, e.colors, e.numColors, 0)
  if d.len - pos >= 4: (e.mode = getInt(d, pos); pos += 4)
  e.needRecompile = true

proc makeint(t: float64): uint32 {.inline.} =
  if t <= 0.0: 0'u32
  elif t >= 1.0: 255'u32
  else: uint32(ftol(t * 255.0))

method render(e: SuperScope, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if e.needRecompile:
    if e.vN == nil or resetVarsOnRecompile:
      e.vm.resetVars()
      e.vN = e.vm.reg("n"); e.vB = e.vm.reg("b"); e.vX = e.vm.reg("x"); e.vY = e.vm.reg("y")
      e.vI = e.vm.reg("i"); e.vV = e.vm.reg("v"); e.vW = e.vm.reg("w"); e.vH = e.vm.reg("h")
      e.vRed = e.vm.reg("red"); e.vGreen = e.vm.reg("green"); e.vBlue = e.vm.reg("blue")
      e.vLinesize = e.vm.reg("linesize"); e.vSkip = e.vm.reg("skip")
      e.vDrawmode = e.vm.reg("drawmode")
      e.vN[] = 100.0
      e.inited = false
    e.needRecompile = false
    for k in 0 .. 3: e.compiled[k] = e.vm.compile(e.code[k])
  if (isBeat and BeatPreinit) != 0: return 0
  if e.numColors == 0: return 0
  let ws = if (e.whichCh and 4) != 0: 1 else: 0
  let xorv = uint8((ws * 128) xor 128)
  let fa = if (e.whichCh and 3) >= 2: centerData(vis, ws xor 1)
           else: channelData(vis, ws xor 1, e.whichCh and 3)
  let color = cycleColor(e.colors, e.numColors, e.colorPos)
  e.vH[] = h.float64
  e.vW[] = w.float64
  e.vB[] = (if isBeat != 0: 1.0 else: 0.0)
  e.vBlue[] = float64(color and 0xff) / 255.0
  e.vGreen[] = float64((color shr 8) and 0xff) / 255.0
  e.vRed[] = float64((color shr 16) and 0xff) / 255.0
  e.vSkip[] = 0.0
  e.vLinesize[] = lineWidth().float64
  e.vDrawmode[] = (if e.mode != 0: 1.0 else: 0.0)
  if e.compiled[3] != nil and not e.inited:
    e.compiled[3].run()
    e.inited = true
  e.compiled[1].run()
  if isBeat != 0: e.compiled[2].run()
  if e.compiled[0] != nil:
    var candraw = false
    var lx, ly: int
    var l = ftol(e.vN[])
    if l > 128 * 1024: l = 128 * 1024
    for a in 0 ..< l:
      let r = (a.float64 * 576.0) / l.float64
      let ir = ftol(r)
      let s1 = r - ir.float64
      let yr = float64(fa[ir] xor xorv) * (1.0 - s1) + float64(fa[ir + 1] xor xorv) * s1
      e.vV[] = yr / 128.0 - 1.0
      e.vI[] = a.float64 / float64(l - 1)
      e.vSkip[] = 0.0
      e.compiled[0].run()
      let x = ftol((e.vX[] + 1.0) * w.float64 * 0.5)
      let y = ftol((e.vY[] + 1.0) * h.float64 * 0.5)
      if e.vSkip[] < 0.00001:
        let thiscolor = makeint(e.vBlue[]) or (makeint(e.vGreen[]) shl 8) or (makeint(e.vRed[]) shl 16)
        if e.vDrawmode[] < 0.00001:
          if y >= 0 and y < h and x >= 0 and x < w:
            blendLine(fb[x + y * w], thiscolor)
        elif candraw:
          if (thiscolor and 0xffffff) != 0 or (lineBlendMode and 0xff) != 1:
            line(fb, lx, ly, x, y, w, h, thiscolor, ftol(e.vLinesize[] + 0.5))
      candraw = true
      lx = x
      ly = y
  0

# --- Dot Plane ------------------------------------------------------------------------

const NumWidth = 64

type DotPlane = ref object of Effect
  r: float32
  atable, vtable: array[NumWidth * NumWidth, float32]
  ctable: array[NumWidth * NumWidth, uint32]
  colorTab: array[64, uint32]
  rotvel, angle: int32
  colors: array[5, uint32]

method desc(e: DotPlane): string = "Render / Dot Plane"

proc initColorTab(e: DotPlane) =
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

proc newDotPlane(): Effect =
  let e = DotPlane(angle: -20, rotvel: 16)
  e.colors = [colorRgb(24, 107, 28), colorRgb(35, 10, 255), colorRgb(116, 29, 42),
              colorRgb(217, 54, 144), colorRgb(255, 136, 107)]
  e.initColorTab()
  e

method load(e: DotPlane, d: openArray[byte]) =
  var pos = 0
  if d.len - pos >= 4: (e.rotvel = getInt(d, pos); pos += 4)
  for x in 0 ..< 5:
    if d.len - pos >= 4: (e.colors[x] = cast[uint32](getInt(d, pos)); pos += 4)
  if d.len - pos >= 4: (e.angle = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.r = float32(getInt(d, pos).float64 / 32.0); pos += 4)
  e.initColorTab()

method render(e: DotPlane, vis: var VisData, isBeat: int32, fb, fbout: Pixels, width, height: int): int =
  if (isBeat and BeatPreinit) != 0: return 0
  var m, m2: Mat4
  matrixRotate(m, 2, e.r)
  matrixRotate(m2, 1, e.angle.float32)
  matrixMultiply(m, m2)
  matrixTranslate(m2, 0, -20, 400)
  matrixMultiply(m, m2)
  var btable: array[NumWidth, float32]
  for i in 0 ..< NumWidth: btable[i] = e.atable[i]
  for fo in 0 ..< NumWidth:
    let t = (NumWidth - (fo + 2)) * NumWidth
    let o = t + NumWidth
    if fo == NumWidth - 1:
      for p in 0 ..< NumWidth:
        var v = max(cast[uint8](vis[0][0][p * 3]), cast[uint8](vis[0][0][p * 3 + 1]))
        let flat = p * 3 + 2  # may run into channel 1, as C's pointer did
        v = max(v, cast[uint8](vis[0][flat div 576][flat mod 576]))
        e.atable[o + p] = v.float32
        var ti = int(v) shr 2
        if ti > 63: ti = 63
        e.ctable[o + p] = e.colorTab[ti]
        e.vtable[o + p] = float32((e.atable[o + p].float64 - btable[p].float64) / 90.0)
    else:
      for p in 0 ..< NumWidth:
        var nv = float32(e.atable[t + p].float64 + e.vtable[t + p].float64)
        if nv < 0: nv = 0
        e.atable[o + p] = nv
        e.vtable[o + p] = float32(e.vtable[t + p].float64 - float64(0.15'f32) * (nv.float64 / 255.0))
        e.ctable[o + p] = e.ctable[t + p]
  var adj = float32(width.float64 * 440.0 / 640.0)
  let adj2 = float32(height.float64 * 440.0 / 480.0)
  if adj2 < adj: adj = adj2
  for fo in 0 ..< NumWidth:
    let f = if e.r < 90.0 or e.r > 270.0: NumWidth - fo - 1 else: fo
    var dw = float32(350.0 / NumWidth.float64)
    var w = float32(-(NumWidth.float64 * 0.5) * dw.float64)
    let q = float32((f.float64 - NumWidth.float64 * 0.5) * dw.float64)
    var ct = f * NumWidth
    var da = 1
    if e.r < 180.0:
      da = -1
      dw = -dw
      w = float32(-w.float64 + dw.float64)
      ct += NumWidth - 1
    for p in 0 ..< NumWidth:
      var (x, y, z) = matrixApply(m, w, float32(64.0 - e.atable[ct].float64), q)
      z = float32(adj.float64 / z.float64)
      let ix = ftol(x.float64 * z.float64) + width div 2
      let iy = ftol(y.float64 * z.float64) + height div 2
      if iy >= 0 and iy < height and ix >= 0 and ix < width:
        blendLine(fb[iy * width + ix], e.ctable[ct])
      w = float32(w.float64 + dw.float64)
      ct += da
  e.r = float32(e.r.float64 + e.rotvel.float64 / 5.0)
  if e.r >= 360: e.r = float32(e.r.float64 - 360)
  if e.r < 0: e.r = float32(e.r.float64 + 360)
  0

# --- Oscilloscope Star ------------------------------------------------------------------

type OscStar = ref object of Effect
  effect: int32
  numColors: int
  colors: array[16, uint32]
  size, rot: int32
  colorPos: int
  mr: float64

method desc(e: OscStar): string = "Render / Oscilliscope Star"

proc newOscStar(): Effect =
  let e = OscStar(effect: 0 or (2 shl 2) or (2 shl 4), numColors: 1, size: 8, rot: 3)
  e.colors[0] = colorRgb(255, 255, 255)
  e

method load(e: OscStar, d: openArray[byte]) =
  var pos = 0
  if d.len - pos >= 4: (e.effect = getInt(d, pos); pos += 4)
  loadColors(d, pos, e.colors, e.numColors, 1)
  if d.len - pos >= 4: (e.size = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.rot = getInt(d, pos); pos += 4)

method render(e: OscStar, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  let whichCh = (e.effect shr 2) and 3
  let yPos = e.effect shr 4
  if (isBeat and BeatPreinit) != 0: return 0
  if e.numColors == 0: return 0
  let color = cycleColor(e.colors, e.numColors, e.colorPos)
  let fa = if whichCh < 2: channelData(vis, 1, whichCh) else: centerData(vis, 1)
  let s = e.size.float64 / 32.0
  let isz = min(ftol(h.float64 * s), ftol(w.float64 * s))
  var cx = if yPos == 2: w div 2 elif yPos == 0: w div 4 else: w div 2 + w div 4
  var ii = 0
  let lw = lineWidth()
  for q in 0 ..< 5:
    let sn = sin(e.mr + q.float64 * (3.14159 * 2.0 / 5.0))
    let cs = cos(e.mr + q.float64 * (3.14159 * 2.0 / 5.0))
    var p = 0.0
    if yPos == 2: cx = w div 2
    elif yPos == 0: cx = w div 4
    var lx = cx
    var ly = h div 2
    var t = 64
    let dp = isz.float64 / t.float64
    var dfactor = 1.0 / float64(1024.0'f32)
    let hw = isz.float64
    while t > 0:
      dec t
      let ale = float64(int(fa[ii] xor 128) - 128) * dfactor * hw
      inc ii
      let x = cx + ftol(cs * p) - ftol(sn * ale)
      let y = h div 2 + ftol(sn * p) + ftol(cs * ale)
      if (x >= 0 and x < w and y >= 0 and y < h) or (lx >= 0 and lx < w and ly >= 0 and ly < h):
        line(fb, x, y, lx, ly, w, h, color, lw)
      lx = x
      ly = y
      p += dp
      dfactor -= ((1.0 / float64(1024.0'f32)) - (1.0 / float64(128.0'f32))) / float64(64.0'f32)
  e.mr += 0.01 * e.rot.float64
  if e.mr >= 3.14159 * 2: e.mr -= 3.14159 * 2
  0

# --- Ring -----------------------------------------------------------------------------------

type Ring = ref object of Effect
  effect: int32
  numColors: int
  colors: array[16, uint32]
  size, source: int32
  colorPos: int

method desc(e: Ring): string = "Render / Ring"

proc newRing(): Effect =
  let e = Ring(effect: 0 or (2 shl 2) or (2 shl 4), numColors: 1, size: 8)
  e.colors[0] = colorRgb(255, 255, 255)
  e

method load(e: Ring, d: openArray[byte]) =
  var pos = 0
  if d.len - pos >= 4: (e.effect = getInt(d, pos); pos += 4)
  loadColors(d, pos, e.colors, e.numColors, 1)
  if d.len - pos >= 4: (e.size = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.source = getInt(d, pos); pos += 4)

method render(e: Ring, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  let whichCh = (e.effect shr 2) and 3
  let yPos = e.effect shr 4
  if (isBeat and BeatPreinit) != 0: return 0
  if e.numColors == 0: return 0
  let color = cycleColor(e.colors, e.numColors, e.colorPos)
  let kind = if e.source != 0: 0 else: 1
  let fa = if whichCh < 2: channelData(vis, kind, whichCh) else: centerData(vis, kind)
  let s = e.size.float64 / 32.0
  let isz = min(h.float64 * s, w.float64 * s)
  let cx = if yPos == 2: w div 2 elif yPos == 0: w div 4 else: w div 2 + w div 4
  let cy = h div 2
  var a = 0.0
  template sample(q: int): float64 =
    if e.source == 0: 0.1 + (float64(fa[q] xor 128) / 255.0) * 0.9
    else: 0.1 + (float64(int(fa[q * 2]) div 2 + int(fa[q * 2 + 1]) div 2) / 255.0) * 0.9
  var sca = sample(0)
  var lx = ftol(cx.float64 + cos(a) * isz * sca)
  var ly = ftol(cy.float64 + sin(a) * isz * sca)
  let lw = lineWidth()
  for q in 1 .. 80:
    a -= 3.14159 * 2.0 / 80.0
    let qq = if q > 40: 80 - q else: q
    sca = sample(qq)
    let tx = ftol(cx.float64 + cos(a) * isz * sca)
    let ty = ftol(cy.float64 + sin(a) * isz * sca)
    if (tx >= 0 and tx < w and ty >= 0 and ty < h) or (lx >= 0 and lx < w and ly >= 0 and ly < h):
      line(fb, tx, ty, lx, ly, w, h, color, lw)
    lx = tx
    ly = ty
  0

proc registerRender1*() =
  registerEffect(0, newSimple)
  registerEffect(1, newDotPlane)
  registerEffect(2, newOscStar)
  registerEffect(14, newRing)
  registerEffect(36, newSuperScope)
