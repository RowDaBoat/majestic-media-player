## Trans effects: Color Modifier, Water, Water Bump, Bump (r_dcolormod.cpp,
## r_water.cpp, r_waterbump.cpp, r_bump.cpp).

import std/math
import core, list

# --- Color Modifier ---------------------------------------------------------------

type ColorModifier = ref object of Effect
  code: array[4, string]   ## pixel, frame, beat, init
  compiled: array[4, EelCode]
  recompute: int32
  tabValid: bool
  tab: array[768, uint8]
  vR, vG, vB, vBeat: ptr float64
  inited, needRecompile: bool

method desc(e: ColorModifier): string = "Trans / Color Modifier"
proc newColorModifier(): Effect = ColorModifier(needRecompile: true, recompute: 1, vm: newEelVm())

method load(e: ColorModifier, d: openArray[byte]) =
  var pos = 0
  if d.len > 0 and d[0] == 1:
    pos = 1
    for k in 0 .. 3: e.code[k] = loadString(d, pos)
  elif d.len - pos >= 1024:
    for k in 0 .. 3: e.code[k] = cString(d, pos + k * 256, 256)
    pos += 1024
  if d.len - pos >= 4: (e.recompute = getInt(d, pos); pos += 4)
  e.needRecompile = true
  e.tabValid = false

method render(e: ColorModifier, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if e.needRecompile:
    if e.vBeat == nil or resetVarsOnRecompile:
      e.vm.resetVars()
      e.vR = e.vm.reg("red"); e.vG = e.vm.reg("green"); e.vB = e.vm.reg("blue")
      e.vBeat = e.vm.reg("beat")
      e.inited = false
    e.needRecompile = false
    for k in 0 .. 3: e.compiled[k] = e.vm.compile(e.code[k])
  if (isBeat and BeatPreinit) != 0: return 0
  e.vBeat[] = (if isBeat != 0: 1.0 else: 0.0)
  if e.compiled[3] != nil and not e.inited:
    e.compiled[3].run()
    e.inited = true
  e.compiled[1].run()
  if isBeat != 0: e.compiled[2].run()
  if e.recompute != 0 or not e.tabValid:
    for x in 0 ..< 256:
      let v = x.float64 / 255.0
      e.vR[] = v; e.vB[] = v; e.vG[] = v
      e.compiled[0].run()
      let r = clamp(ftol(e.vR[] * 255.0 + 0.5), 0, 255)
      let g = clamp(ftol(e.vG[] * 255.0 + 0.5), 0, 255)
      let b = clamp(ftol(e.vB[] * 255.0 + 0.5), 0, 255)
      e.tab[512 + x] = uint8(r)
      e.tab[256 + x] = uint8(g)
      e.tab[x] = uint8(b)
    e.tabValid = true
  for i in 0 ..< w * h:
    let p = fb[i]
    fb[i] = (p and 0xff000000'u32) or uint32(e.tab[p and 0xff]) or
            (uint32(e.tab[256 + ((p shr 8) and 0xff)]) shl 8) or
            (uint32(e.tab[512 + ((p shr 16) and 0xff)]) shl 16)
  0

# --- Water --------------------------------------------------------------------------

type Water = ref object of Effect
  enabled: int32
  last: seq[uint32]

method desc(e: Water): string = "Trans / Water"
proc newWater(): Effect = Water(enabled: 1)

method load(e: Water, d: openArray[byte]) =
  if d.len >= 4: e.enabled = getInt(d, 0)

method render(e: Water, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if e.enabled == 0: return 0
  if e.last.len != w * h: e.last = newSeq[uint32](w * h)
  if (isBeat and BeatPreinit) != 0: return 0
  if w < 2 or h < 2: return 1
  let lf = e.last
  # The C edges: three channels, the neighbours summed (halved with 3 or 4).
  template cedge(i: int, nbs: openArray[int], halve: bool) =
    var r, g, b: int
    for k in nbs:
      let p = fb[i + k]
      r += int(p and 0xff); g += int(p and 0xff00); b += int(p and 0xff0000)
    if halve:
      r = r div 2; g = g div 2; b = b div 2
    let l = lf[i]
    r -= int(l and 0xff); g -= int(l and 0xff00); b -= int(l and 0xff0000)
    r = clamp(r, 0, 255); g = clamp(g, 0, 255 * 256); b = clamp(b, 0, 255 * 65536)
    fbout[i] = uint32(r or (g and 0xff00) or (b and 0xff0000))
  # The MMX middle: every byte, (sum of 4) / 2 - last, saturated.
  template mmx(i: int) =
    let a = fb[i + 1]
    let b2 = fb[i - 1]
    let c = fb[i + w]
    let d = fb[i - w]
    let l = lf[i]
    var r = 0'u32
    for s in [0'u32, 8, 16, 24]:
      let v = int((((a shr s) and 0xff) + ((b2 shr s) and 0xff) + ((c shr s) and 0xff) +
                   ((d shr s) and 0xff)) shr 1) - int((l shr s) and 0xff)
      r = r or (uint32(clamp(v, 0, 255)) shl s)
    fbout[i] = r
  # top row
  cedge(0, [1, w], false)
  for x in 1 .. w - 2: cedge(x, [1, -1, w], true)
  cedge(w - 1, [-1, w], false)
  for y in 1 .. h - 2:
    let b = y * w
    cedge(b, [1, w, -w], true)
    for x in 1 .. w - 2: mmx(b + x)
    cedge(b + w - 1, [-1, w, -w], true)
  let b = (h - 1) * w
  cedge(b, [1, -w], false)
  for x in 1 .. w - 2: cedge(b + x, [1, -1, -w], true)
  cedge(b + w - 1, [-1, -w], false)
  copyMem(e.last[0].addr, fb[0].addr, w * h * 4)
  1

# --- Water Bump ---------------------------------------------------------------------------

type WaterBump = ref object of Effect
  enabled, density, depth, randomDrop, dropX, dropY, dropRadius, mtd: int32
  buffers: array[2, seq[int32]]
  bw, bh: int
  page: int

method desc(e: WaterBump): string = "Trans / Water Bump"
proc newWaterBump(): Effect =
  WaterBump(enabled: 1, density: 6, depth: 600, dropX: 1, dropY: 1, dropRadius: 40)

method load(e: WaterBump, d: openArray[byte]) =
  var pos = 0
  for f in [addr e.enabled, addr e.density, addr e.depth, addr e.randomDrop, addr e.dropX,
            addr e.dropY, addr e.dropRadius, addr e.mtd]:
    if d.len - pos >= 4: (f[] = getInt(d, pos); pos += 4)

proc sineBlob(e: WaterBump, x0, y0, radius, height, page: int) =
  if radius <= 0: return
  var x = x0
  var y = y0
  let radsquare = radius * radius
  let length = (1024.0 / float32(radius).float64) * (1024.0 / float32(radius).float64)
  if x < 0:
    let m = e.bw - 2 * radius - 1
    x = 1 + radius + (if m > 0: crand() mod m else: 0)
  if y < 0:
    let m = e.bh - 2 * radius - 1
    y = 1 + radius + (if m > 0: crand() mod m else: 0)
  var left = -radius
  var right = radius
  var top = -radius
  var bottom = radius
  if x - radius < 1: left -= (x - radius - 1)
  if y - radius < 1: top -= (y - radius - 1)
  if x + radius > e.bw - 1: right -= (x + radius - e.bw + 1)
  if y + radius > e.bh - 1: bottom -= (y + radius - e.bh + 1)
  let buf = addr e.buffers[page]
  for cy in top ..< bottom:
    for cx in left ..< right:
      let square = cy * cy + cx * cx
      if square < radsquare:
        let dist = sqrt(square.float64 * length)
        let i = e.bw * (cy + y) + cx + x
        if i >= 0 and i < buf[].len:
          buf[][i] = buf[][i] +% int32(ftol((cos(dist) + 0xffff.float64) * height.float64) shr 19)

proc calcWater(e: WaterBump, npage, density: int) =
  let bw = e.bw
  let np = addr e.buffers[npage]
  let op = addr e.buffers[1 - npage]
  var count = bw + 1
  let y = (e.bh - 1) * bw
  while count < y:
    let x = count + bw - 2
    while count < x:
      let newh = ((op[][count + bw] +% op[][count - bw] +% op[][count + 1] +% op[][count - 1] +%
                   op[][count - bw - 1] +% op[][count - bw + 1] +% op[][count + bw - 1] +%
                   op[][count + bw + 1]) shr 2) -% np[][count]
      np[][count] = newh -% (newh shr density)
      inc count
    count += 2

method render(e: WaterBump, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if e.enabled == 0: return 0
  if e.bw != w or e.bh != h or e.buffers[0].len == 0:
    for i in 0 .. 1: e.buffers[i] = newSeq[int32](w * h)
    e.bw = w
    e.bh = h
  if (isBeat and BeatPreinit) != 0: return 0
  if isBeat != 0:
    if e.randomDrop != 0:
      let mx = max(w, h)
      e.sineBlob(-1, -1, int(e.dropRadius) * mx div 100, -int(e.depth), e.page)
    else:
      let x = case e.dropX
        of 0: w div 4
        of 2: w * 3 div 4
        else: w div 2
      let y = case e.dropY
        of 0: h div 4
        of 2: h * 3 div 4
        else: h div 2
      e.sineBlob(x, y, int(e.dropRadius), -int(e.depth), e.page)
  let len = e.bh * e.bw
  let bw = e.bw
  let p = addr e.buffers[e.page]
  var offset = bw + 1
  let ylim = (e.bh - 1) * bw
  template one(o: int) =
    let dx = p[][o] -% p[][o + 1]
    let dy = p[][o] -% p[][o + bw]
    let ofs = o + bw * int(dy shr 3) + int(dx shr 3)
    fbout[o] = if ofs < len and ofs > -1: fb[ofs] else: fb[o]
  while offset < ylim:
    let x = offset + bw - 2
    while offset < x:
      one(offset)
      inc offset
      one(offset)
      inc offset
    offset += 2
  e.calcWater(1 - e.page, int(e.density))
  e.page = 1 - e.page
  1

# --- Bump ------------------------------------------------------------------------------------

type Bump = ref object of Effect
  enabled, depth, depth2, onbeat, durFrames, blend, blendavg, showlight, invert, oldstyle, buffern: int32
  thisDepth, nF: int
  code: array[3, string]   ## frame, beat, init
  compiled: array[3, EelCode]
  vX, vY, vIsBeat, vIsLongBeat, vBi: ptr float64
  initted, needRecompile: bool

method desc(e: Bump): string = "Trans / Bump"

proc newBump(): Effect =
  Bump(enabled: 1, durFrames: 15, depth: 30, depth2: 100, thisDepth: 30,
       code: ["x=0.5+cos(t)*0.3;\r\ny=0.5+sin(t)*0.3;\r\nt=t+0.1;", "", "t=0;"],
       needRecompile: true, vm: newEelVm())

method load(e: Bump, d: openArray[byte]) =
  var pos = 0
  for f in [addr e.enabled, addr e.onbeat, addr e.durFrames, addr e.depth, addr e.depth2,
            addr e.blend, addr e.blendavg]:
    if d.len - pos >= 4: (f[] = getInt(d, pos); pos += 4)
  for k in 0 .. 2: e.code[k] = loadString(d, pos)
  if d.len - pos >= 4: (e.showlight = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.invert = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.oldstyle = getInt(d, pos); pos += 4)
  else: e.oldstyle = 1
  if d.len - pos >= 4: (e.buffern = getInt(d, pos); pos += 4)
  e.thisDepth = e.depth
  e.nF = 0
  e.needRecompile = true

proc depthof(c: uint32, inv: bool): int {.inline.} =
  let r = int(max(max(c and 0xFF, (c and 0xFF00) shr 8), (c and 0xFF0000) shr 16))
  if inv: 255 - r else: r

proc setdepth(l: int, c: uint32): uint32 {.inline.} =
  let r = min(int(c and 0xFF) + l, 254)
  let g = min(int(c and 0xFF00) + (l shl 8), 254 shl 8)
  let b = min(int(c and 0xFF0000) + (l shl 16), 254 shl 16)
  cast[uint32](int32(r or g or b))

proc setdepth0(c: uint32): uint32 {.inline.} =
  uint32(min(c and 0xFF, 254'u32) or min(c and 0xFF00, 254'u32 shl 8) or min(c and 0xFF0000, 254'u32 shl 16))

method render(e: Bump, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if e.enabled == 0: return 0
  if e.needRecompile:
    if e.vBi == nil or resetVarsOnRecompile:
      e.vm.resetVars()
      e.vX = e.vm.reg("x"); e.vY = e.vm.reg("y"); e.vIsBeat = e.vm.reg("isbeat")
      e.vIsLongBeat = e.vm.reg("islbeat"); e.vBi = e.vm.reg("bi")
      e.vBi[] = 1.0
      e.initted = false
    e.needRecompile = false
    for k in 0 .. 2: e.compiled[k] = e.vm.compile(e.code[k])
  if (isBeat and BeatPreinit) != 0: return 0
  let depthbuf = if e.buffern == 0: fb else: getGlobalBuffer(w, h, int(e.buffern) - 1, false)
  if depthbuf == nil: return 0
  let curbuf = depthbuf == fb
  if not e.initted:
    e.compiled[2].run()
    e.initted = true
  e.compiled[0].run()
  if isBeat != 0: e.compiled[1].run()
  e.vIsBeat[] = (if isBeat != 0: -1.0 else: 1.0)
  e.vIsLongBeat[] = (if e.nF != 0: -1.0 else: 1.0)
  if e.onbeat != 0 and isBeat != 0:
    e.thisDepth = e.depth2
    e.nF = e.durFrames
  elif e.nF == 0: e.thisDepth = e.depth
  clearPixels(fbout, w * h)
  var cx, cy: int
  if e.oldstyle != 0:
    cx = ftol(e.vX[] / 100.0 * w.float64)
    cy = ftol(e.vY[] / 100.0 * h.float64)
  else:
    cx = ftol(e.vX[] * w.float64)
    cy = ftol(e.vY[] * h.float64)
  cx = max(0, min(w, cx))
  cy = max(0, min(h, cy))
  if e.showlight != 0 and cx + cy * w < w * h: fbout[cx + cy * w] = 0xFFFFFF
  if e.vBi != nil:
    var bi = e.vBi[]
    bi = (if bi > 0: bi else: 0.0)  # MSVC max(bi, 0): 0 for NaN
    bi = (if bi < 1: bi else: 1.0)
    e.vBi[] = bi
    e.thisDepth = ftol(e.thisDepth.float64 * bi)
  let scaled = (e.thisDepth shl 8) div 100
  let inv = e.invert != 0
  var ly = 1 - cy
  for y in 1 .. h - 2:
    var lx = 1 - cx
    for x in 1 .. w - 2:
      let i = y * w + x
      let m1 = depthbuf[i - 1]
      let p1 = depthbuf[i + 1]
      let mw = depthbuf[i - w]
      let pw = depthbuf[i + w]
      if not curbuf or (m1 or p1 or mw or pw) != 0:
        var c1 = depthof(p1, inv) - depthof(m1, inv) - lx
        var c2 = depthof(pw, inv) - depthof(mw, inv) - ly
        c1 = 127 - abs(c1)
        c2 = 127 - abs(c2)
        let col = if c1 <= 0 or c2 <= 0: setdepth0(fb[i])
                  else: setdepth(int(int32(c1 * c2) *% int32(scaled)) shr (8 + 6), fb[i])
        fbout[i] = if e.blend != 0: blendAdd(fb[i], col) elif e.blendavg != 0: blendAvg(fb[i], col) else: col
      inc lx
    inc ly
  if e.nF != 0:
    dec e.nF
    if e.nF != 0 and e.durFrames != 0:
      let a = abs(int(e.depth - e.depth2)) div int(e.durFrames)
      e.thisDepth += a * (if e.depth2 > e.depth: -1 else: 1)
  1

proc registerTrans4*() =
  registerEffect(20, newWater)
  registerEffect(29, newBump)
  registerEffect(31, newWaterBump)
  registerEffect(45, newColorModifier)
