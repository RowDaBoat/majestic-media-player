# Ported from Advanced Visualization Studio 2.81d, Copyright 2005 Nullsoft, Inc.
# BSD license: assets/licenses/AVS-Nullsoft-BSD.txt

## Trans effects: Grain, Mosaic, Scatter, Unique Tone, Interferences, Dynamic
## Shift, Dynamic Distance Modifier (r_grain.cpp, r_mosaic.cpp, r_scat.cpp,
## r_onetone.cpp, r_interf.cpp, r_shift.cpp, r_ddm.cpp).

import std/math
import core, list

# --- Grain -----------------------------------------------------------------------

type Grain = ref object of Effect
  enabled, blend, blendavg, smax, staticgrain: int32
  depth: seq[uint8]
  oldx, oldy: int
  randtab: array[491, uint8]
  randtabPos: int
  seeded: bool

method desc(e: Grain): string = "Trans / Grain"
proc newGrain(): Effect = Grain(smax: 100, enabled: 1)

method load(e: Grain, d: openArray[byte]) =
  var pos = 0
  for f in [addr e.enabled, addr e.blend, addr e.blendavg, addr e.smax, addr e.staticgrain]:
    if d.len - pos >= 4: (f[] = getInt(d, pos); pos += 4)

proc fastrandbyte(e: Grain): uint8 {.inline.} =
  result = e.randtab[e.randtabPos]
  inc e.randtabPos
  if (e.randtabPos and 15) == 0: e.randtabPos += crand() mod 73
  if e.randtabPos >= 491: e.randtabPos -= 491

method render(e: Grain, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if not e.seeded:  # the constructor's rand() calls
    e.seeded = true
    for x in 0 ..< 491: e.randtab[x] = uint8(crand() and 255)
    e.randtabPos = crand() mod 491
  if (isBeat and BeatPreinit) != 0: return 0
  if e.enabled == 0: return 0
  let smaxSc = (int(e.smax) * 255) div 100
  if w != e.oldx or h != e.oldy:
    e.depth = newSeq[uint8](w * h * 2)
    for i in 0 ..< w * h:
      e.depth[i * 2] = uint8(crand() mod 255)
      e.depth[i * 2 + 1] = uint8(crand() mod 100)
    e.oldx = w
    e.oldy = h
  e.randtabPos += crand() mod 300
  if e.randtabPos >= 491: e.randtabPos -= 491
  for i in 0 ..< w * h:
    let p = fb[i]
    if p != 0:
      var c = 0'u32
      var s = -1
      if e.staticgrain != 0:
        if int(e.depth[i * 2 + 1]) < smaxSc: s = int(e.depth[i * 2])
      else:
        if int(e.fastrandbyte()) < smaxSc: s = int(e.fastrandbyte())
      if s >= 0:
        let su = uint32(s)
        c = c or min(((p and 0xff0000) * su) shr 8, 0xff0000'u32) and 0xff0000
        c = c or min(((p and 0xff00) * su) shr 8, 0xff00'u32) and 0xff00
        c = c or min(((p and 0xff) * su) shr 8, 0xff'u32)
      fb[i] = if e.blend != 0: blendAdd(p, c) elif e.blendavg != 0: blendAvg(p, c) else: c
  0

# --- Mosaic -------------------------------------------------------------------------

type Mosaic = ref object of Effect
  enabled, quality, quality2, blend, blendavg, onbeat, durFrames: int32
  nF, thisQuality: int

method desc(e: Mosaic): string = "Trans / Mosaic"
proc newMosaic(): Effect = Mosaic(enabled: 1, quality: 50, durFrames: 15)

method load(e: Mosaic, d: openArray[byte]) =
  var pos = 0
  for f in [addr e.enabled, addr e.quality, addr e.quality2, addr e.blend, addr e.blendavg,
            addr e.onbeat, addr e.durFrames]:
    if d.len - pos >= 4: (f[] = getInt(d, pos); pos += 4)

method render(e: Mosaic, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if (isBeat and BeatPreinit) != 0: return 0
  if e.enabled == 0: return 0
  var rval = 0
  if e.onbeat != 0 and isBeat != 0:
    e.thisQuality = e.quality2
    e.nF = e.durFrames
  elif e.nF == 0: e.thisQuality = e.quality
  if e.thisQuality < 100 and e.thisQuality > 0:
    var p = 0
    var p2 = 0
    let sxInc = (w * 65536) div e.thisQuality
    let syInc = (h * 65536) div e.thisQuality
    var ypos = sxInc * 0 + (syInc shr 17)
    var dypos = 0
    let n = w * h
    for y in 0 ..< h:
      let fbread = ypos * w
      var dpos = 0
      var xpos = sxInc shr 17
      var src = fb[min(fbread + xpos, n - 1)]
      for x in 0 ..< w:
        if p < n:
          fbout[p] = if e.blend != 0: blendAdd(fb[p2], src)
                     elif e.blendavg != 0: blendAvg(fb[p2], src)
                     else: src
        inc p
        inc p2
        dpos += 1 shl 16
        if dpos >= sxInc:
          xpos += dpos shr 16
          if xpos >= w: break
          src = fb[fbread + xpos]
          dpos -= sxInc
      dypos += 1 shl 16
      if dypos >= syInc:
        ypos += dypos shr 16
        dypos -= syInc
        if ypos >= h: break
    rval = 1
  if e.nF != 0:
    dec e.nF
    if e.nF != 0 and e.durFrames != 0:
      let a = abs(int(e.quality - e.quality2)) div int(e.durFrames)
      e.thisQuality += a * (if e.quality2 > e.quality: -1 else: 1)
  rval

# --- Scatter ------------------------------------------------------------------------------

type Scatter = ref object of Effect
  enabled: int32
  fudge: array[512, int]
  ftw: int

method desc(e: Scatter): string = "Trans / Scatter"
proc newScatter(): Effect = Scatter(enabled: 1)

method load(e: Scatter, d: openArray[byte]) =
  if d.len >= 4: e.enabled = getInt(d, 0)

method render(e: Scatter, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if e.enabled == 0: return 0
  if e.ftw != w:
    for x in 0 ..< 512:
      var xp = (x mod 8) - 4
      var yp = (x div 8) mod 8 - 4
      if xp < 0: inc xp
      if yp < 0: inc yp
      e.fudge[x] = w * yp + xp
    e.ftw = w
  if (isBeat and BeatPreinit) != 0: return 0
  let n = w * h
  var i = 0
  while i < min(w * 4, n):
    fbout[i] = fb[i]
    inc i
  for k in 0 ..< max(w * (h - 8), 0):
    let s = i + e.fudge[crand() and 511]
    fbout[i] = fb[clamp(s, 0, n - 1)]
    inc i
  while i < n:
    fbout[i] = fb[i]
    inc i
  1

# --- Unique Tone --------------------------------------------------------------------------------

type UniqueTone = ref object of Effect
  enabled, invert, blend, blendavg: int32
  color: uint32
  tr, tg, tb: array[256, uint8]

method desc(e: UniqueTone): string = "Trans / Unique tone"

proc rebuild(e: UniqueTone) =
  for i in 0 .. 255:
    e.tb[i] = uint8((i.float64 / 255.0) * float32(e.color and 0xFF).float64)
    e.tg[i] = uint8((i.float64 / 255.0) * float32((e.color and 0xFF00) shr 8).float64)
    e.tr[i] = uint8((i.float64 / 255.0) * float32((e.color and 0xFF0000) shr 16).float64)

proc newUniqueTone(): Effect =
  let e = UniqueTone(color: 0xFFFFFF, enabled: 1)
  e.rebuild()
  e

method load(e: UniqueTone, d: openArray[byte]) =
  var pos = 0
  if d.len - pos >= 4: (e.enabled = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.color = cast[uint32](getInt(d, pos)); pos += 4)
  for f in [addr e.blend, addr e.blendavg, addr e.invert]:
    if d.len - pos >= 4: (f[] = getInt(d, pos); pos += 4)
  e.rebuild()

method render(e: UniqueTone, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if e.enabled == 0: return 0
  if (isBeat and BeatPreinit) != 0: return 0
  for i in 0 ..< w * h:
    let c = fb[i]
    var d = int(max(max(c and 0xFF, (c and 0xFF00) shr 8), (c and 0xFF0000) shr 16))
    if e.invert != 0: d = 255 - d
    let v = uint32(e.tb[d]) or (uint32(e.tg[d]) shl 8) or (uint32(e.tr[d]) shl 16)
    fb[i] = if e.blend != 0: blendAdd(c, v) elif e.blendavg != 0: blendAvg(c, v) else: v
  0

# --- Interferences ----------------------------------------------------------------------------------

const InterfPi = 3.14159

type Interferences = ref object of Effect
  enabled, nPoints, distance, alpha, rotation, rotationinc, distance2, alpha2,
    rotationinc2, rgb, blend, blendavg, onbeat: int32
  speed, a, status: float32

method desc(e: Interferences): string = "Trans / Interferences"

proc newInterferences(): Effect =
  let e = Interferences(enabled: 1, nPoints: 2, distance: 10, alpha: 128, rgb: 1, onbeat: 1,
                        distance2: 32, rotationinc2: 25, alpha2: 192, status: 2, speed: 0.2)
  e.a = float32(e.rotation.float32.float64 / 255 * float32(InterfPi).float64 * 2)
  e

method load(e: Interferences, d: openArray[byte]) =
  var pos = 0
  for f in [addr e.enabled, addr e.nPoints, addr e.rotation, addr e.distance, addr e.alpha,
            addr e.rotationinc, addr e.blend, addr e.blendavg, addr e.distance2, addr e.alpha2,
            addr e.rotationinc2, addr e.rgb, addr e.onbeat]:
    if d.len - pos >= 4: (f[] = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.speed = cast[float32](getInt(d, pos)); pos += 4)
  e.a = float32(e.rotation.float32.float64 / 255 * float32(InterfPi).float64 * 2)
  e.status = float32(InterfPi)

method render(e: Interferences, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if (isBeat and BeatPreinit) != 0: return 0
  if e.enabled == 0: return 0
  let pnts = min(int(e.nPoints), 8)
  if pnts <= 0: return 0
  let angle = float32(float32(2 * InterfPi).float64 / pnts.float64)
  if e.onbeat != 0 and isBeat != 0:
    if e.status.float64 >= InterfPi: e.status = 0
  let s = float32(sin(e.status.float64))
  let rinc = int(e.rotationinc) + ftol(float32(e.rotationinc2 - e.rotationinc).float64 * s.float64)
  let alpha = int(e.alpha) + ftol(float32(e.alpha2 - e.alpha).float64 * s.float64)
  let dist = int(e.distance) + ftol(float32(e.distance2 - e.distance).float64 * s.float64)
  e.a = float32(e.rotation.float32.float64 / 255 * float32(InterfPi).float64 * 2)
  var xpts, ypts: array[8, int]
  for i in 0 ..< pnts:
    xpts[i] = ftol(cos(e.a.float64) * dist.float64)
    ypts[i] = ftol(sin(e.a.float64) * dist.float64)
    e.a = float32(e.a.float64 + angle.float64)
  let bt = addr blendTable[clamp(alpha, 0, 255)]
  var o = 0
  let n = w * h
  for y in 0 ..< h:
    var yoffs: array[8, int]
    for i in 0 ..< pnts:
      yoffs[i] = if y >= ypts[i] and y - ypts[i] < h: (y - ypts[i]) * w else: -1
    template px(i, x: int): uint32 =
      fb[clamp(x - xpts[i] + yoffs[i], 0, n - 1)]
    template ok(i, x: int): bool =
      x - xpts[i] >= 0 and x - xpts[i] < w and yoffs[i] != -1
    if e.rgb != 0 and (pnts == 3 or pnts == 6):
      for x in 0 ..< w:
        var r, g, b: int
        if ok(0, x): r = int(bt[px(0, x) and 0xff])
        if ok(1, x): g = int(bt[(px(1, x) shr 8) and 0xff])
        if ok(2, x): b = int(bt[(px(2, x) shr 16) and 0xff])
        if pnts == 6:
          if ok(3, x): r += int(bt[px(3, x) and 0xff])
          if ok(4, x): g += int(bt[(px(4, x) shr 8) and 0xff])
          if ok(5, x): b += int(bt[(px(5, x) shr 16) and 0xff])
          r = min(r, 255); g = min(g, 255); b = min(b, 255)
        fbout[o] = uint32(r) or (uint32(g) shl 8) or (uint32(b) shl 16)
        inc o
    else:
      for x in 0 ..< w:
        var r, g, b: int
        for i in 0 ..< pnts:
          if ok(i, x):
            let p = px(i, x)
            r += int(bt[p and 0xff])
            g += int(bt[(p shr 8) and 0xff])
            b += int(bt[(p shr 16) and 0xff])
        fbout[o] = uint32(min(r, 255)) or (uint32(min(g, 255)) shl 8) or (uint32(min(b, 255)) shl 16)
        inc o
  e.rotation += int32(rinc)
  e.rotation = if e.rotation > 255: e.rotation - 255 else: e.rotation
  e.rotation = if e.rotation < -255: e.rotation + 255 else: e.rotation
  e.status = float32(e.status.float64 + e.speed.float64)
  e.status = min(e.status, float32(InterfPi))
  if e.status.float64 < -InterfPi: e.status = float32(InterfPi)
  if e.blend == 0 and e.blendavg == 0: return 1
  if e.blendavg != 0:
    for i in 0 ..< (n div 4) * 4: fb[i] = blendAvg(fb[i], fbout[i])
  else: addBlock(fb, fbout, n)
  0

# --- Dynamic Shift -------------------------------------------------------------------------------------

type DynShift = ref object of Effect
  code: array[3, string]   ## init, frame, beat
  compiled: array[3, EelCode]
  blend, subpixel: int32
  lastW, lastH: int
  vX, vY, vW, vH, vB, vAlpha: ptr float64
  inited, needRecompile: bool

method desc(e: DynShift): string = "Trans / Dynamic Shift"

proc newDynShift(): Effect =
  DynShift(code: ["d=0;", "x=sin(d)*1.4; y=1.4*cos(d); d=d+0.01;", "d=d+2.0"],
           subpixel: 1, needRecompile: true, vm: newEelVm())

method load(e: DynShift, d: openArray[byte]) =
  var pos = 0
  if d.len > 0 and d[0] == 1:
    pos = 1
    for k in 0 .. 2: e.code[k] = loadString(d, pos)
  elif d.len - pos >= 768:
    for k in 0 .. 2: e.code[k] = cString(d, pos + k * 256, 256)
    pos += 768
  if d.len - pos >= 4: (e.blend = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.subpixel = getInt(d, pos); pos += 4)
  e.needRecompile = true

method render(e: DynShift, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if e.needRecompile:
    if e.vB == nil or resetVarsOnRecompile:
      e.vm.resetVars()
      e.vX = e.vm.reg("x"); e.vY = e.vm.reg("y"); e.vW = e.vm.reg("w")
      e.vH = e.vm.reg("h"); e.vB = e.vm.reg("b"); e.vAlpha = e.vm.reg("alpha")
      e.inited = false
    e.needRecompile = false
    for k in 0 .. 2: e.compiled[k] = e.vm.compile(e.code[k])
  e.vW[] = w.float64
  e.vH[] = h.float64
  e.vB[] = (if isBeat != 0: 1.0 else: 0.0)
  if (isBeat and BeatPreinit) != 0: return 0
  if e.compiled[0] != nil and (not e.inited or e.lastH != h or e.lastW != w):
    e.lastW = w
    e.lastH = h
    e.vX[] = 0; e.vY[] = 0; e.vAlpha[] = 0.5
    e.compiled[0].run()
    e.inited = true
  e.compiled[1].run()
  if isBeat != 0: e.compiled[2].run()
  var doblend = e.blend != 0
  var ialpha = 127
  if doblend:
    ialpha = ftol(e.vAlpha[] * 255.0)
    if ialpha <= 0: return 0
    if ialpha >= 255: doblend = false
  let n = w * h
  var inp = 0
  var bp = 0
  var o = 0
  var xa = ftol(e.vX[])
  var ya = ftol(e.vY[])
  template zero() =
    if not doblend: fbout[o] = 0
    else:
      fbout[o] = blendAdj(0, fb[bp], ialpha)
      inc bp
    inc o
  template put(v: uint32) =
    if not doblend: fbout[o] = v
    else:
      fbout[o] = blendAdj(v, fb[bp], ialpha)
      inc bp
    inc o
  if e.subpixel == 0:
    var endy = h + ya
    var endx = w + xa
    if endx > w: endx = w
    if endy > h: endy = h
    if ya < 0: inp += -ya * w
    if ya > h: ya = h
    if xa > w: xa = w
    var y = 0
    while y < ya:
      for x in 0 ..< w: zero()
      inc y
    while y < endy:
      let ip = inp
      if xa < 0: inp += -xa
      var x = 0
      while x < xa: (zero(); inc x)
      while x < endx:
        put(fb[clamp(inp, 0, n - 1)])
        inc inp
        inc x
      while x < w: (zero(); inc x)
      inp = ip + w
      inc y
    while y < h:
      for x in 0 ..< w: zero()
      inc y
  else:
    let vx = e.vX[]
    let vy = e.vY[]
    var xpart = ftol((vx - ftol(vx).float64) * 255.0)
    if xpart < 0: xpart = -xpart
    else:
      inc xa
      xpart = 255 - xpart
    xpart = clamp(xpart, 0, 255)
    var ypart = ftol((vy - ftol(vy).float64) * 255.0)
    if ypart < 0: ypart = -ypart
    else:
      inc ya
      ypart = 255 - ypart
    ypart = clamp(ypart, 0, 255)
    if ya < 1 - h: ya = 1 - h
    if xa < 1 - w: xa = 1 - w
    if ya > h - 1: ya = h - 1
    if xa > w - 1: xa = w - 1
    if ya < 0: inp += -ya * w
    var endy = h - 1 + ya
    var endx = w - 1 + xa
    if endx > w - 1: endx = w - 1
    if endy > h - 1: endy = h - 1
    if endx < 0: endx = 0
    if endy < 0: endy = 0
    var y = 0
    while y < ya:
      for x in 0 ..< w: zero()
      inc y
    while y < endy:
      let ip = inp
      if xa < 0: inp += -xa
      var x = 0
      while x < xa: (zero(); inc x)
      while x < endx:
        put(if inp + w + 1 < n: blend4(fb, inp, w, xpart, ypart) else: fb[clamp(inp, 0, n - 1)])
        inc inp
        inc x
      while x < w: (zero(); inc x)
      inp = ip + w
      inc y
    while y < h:
      for x in 0 ..< w: zero()
      inc y
  1

# --- Dynamic Distance Modifier ------------------------------------------------------------------------

const sqTable: array[256, uint8] = [
  0'u8, 16, 22, 27, 32, 35, 39, 42, 45, 48, 50, 53, 55, 57, 59, 61, 64, 65,
  67, 69, 71, 73, 75, 76, 78, 80, 81, 83, 84, 86, 87, 89, 90, 91, 93, 94,
  96, 97, 98, 99, 101, 102, 103, 104, 106, 107, 108, 109, 110, 112, 113,
  114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 128,
  128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141,
  142, 143, 144, 144, 145, 146, 147, 148, 149, 150, 150, 151, 152, 153,
  154, 155, 155, 156, 157, 158, 159, 160, 160, 161, 162, 163, 163, 164,
  165, 166, 167, 167, 168, 169, 170, 170, 171, 172, 173, 173, 174, 175,
  176, 176, 177, 178, 178, 179, 180, 181, 181, 182, 183, 183, 184, 185,
  185, 186, 187, 187, 188, 189, 189, 190, 191, 192, 192, 193, 193, 194,
  195, 195, 196, 197, 197, 198, 199, 199, 200, 201, 201, 202, 203, 203,
  204, 204, 205, 206, 206, 207, 208, 208, 209, 209, 210, 211, 211, 212,
  212, 213, 214, 214, 215, 215, 216, 217, 217, 218, 218, 219, 219, 220,
  221, 221, 222, 222, 223, 224, 224, 225, 225, 226, 226, 227, 227, 228,
  229, 229, 230, 230, 231, 231, 232, 232, 233, 234, 234, 235, 235, 236,
  236, 237, 237, 238, 238, 239, 240, 240, 241, 241, 242, 242, 243, 243,
  244, 244, 245, 245, 246, 246, 247, 247, 248, 248, 249, 249, 250, 250,
  251, 251, 252, 252, 253, 253, 254, 254, 255]

proc isqrt(n: uint32): int =
  template t(i: uint32): int = int(sqTable[min(i, 255'u32)])
  if n >= 0x10000:
    if n >= 0x1000000:
      if n >= 0x10000000:
        if n >= 0x40000000: t(n shr 24) shl 8 else: t(n shr 22) shl 7
      else:
        if n >= 0x4000000: t(n shr 20) shl 6 else: t(n shr 18) shl 5
    else:
      if n >= 0x100000:
        if n >= 0x400000: t(n shr 16) shl 4 else: t(n shr 14) shl 3
      else:
        if n >= 0x40000: t(n shr 12) shl 2 else: t(n shr 10) shl 1
  else:
    if n >= 0x100:
      if n >= 0x1000:
        if n >= 0x4000: t(n shr 8) else: t(n shr 6) shr 1
      else:
        if n >= 0x400: t(n shr 4) shr 2 else: t(n shr 2) shr 3
    else:
      if n >= 0x10:
        if n >= 0x40: t(n) shr 4 else: t(n shl 2) shl 5
      else:
        if n >= 0x4: t(n shr 4) shl 6 else: t(n shr 6) shl 7

type Ddm = ref object of Effect
  code: array[4, string]   ## pixel, frame, beat, init
  compiled: array[4, EelCode]
  blend, subpixel: int32
  lastW, lastH: int
  maxd: float64
  wmul: seq[int]
  tab: seq[int32]
  vD, vB: ptr float64
  inited, needRecompile: bool

method desc(e: Ddm): string = "Trans / Dynamic Distance Modifier"

proc newDdm(): Effect =
  Ddm(code: ["d=d-sigmoid((t-50)/100,2)",
             "t=t+u;t=min(100,t);t=max(0,t);u=if(equal(t,100),-1,u);u=if(equal(t,0),1,u)",
             "", "u=1;t=0"], needRecompile: true, vm: newEelVm())

method load(e: Ddm, d: openArray[byte]) =
  var pos = 0
  if d.len > 0 and d[0] == 1:
    pos = 1
    for k in 0 .. 3: e.code[k] = loadString(d, pos)
  else:
    if d.len - pos >= 512:
      e.code[0] = cString(d, pos, 256)
      e.code[1] = cString(d, pos + 256, 256)
      pos += 512
    if d.len - pos >= 512:
      e.code[2] = cString(d, pos, 256)
      e.code[3] = cString(d, pos + 256, 256)
      pos += 512
  if d.len - pos >= 4: (e.blend = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.subpixel = getInt(d, pos); pos += 4)
  e.needRecompile = true

method render(e: Ddm, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if e.lastH != h or e.lastW != w or e.wmul.len == 0:
    e.lastW = w
    e.lastH = h
    e.maxd = sqrt(float64(w * w + h * h) / 4.0)
    e.wmul = newSeq[int](h)
    for y in 0 ..< h: e.wmul[y] = y * w
    e.tab = @[]
  var imaxd = ftol(e.maxd + 32.9)
  if imaxd < 33: imaxd = 33
  if e.tab.len == 0: e.tab = newSeq[int32](imaxd)
  if e.needRecompile:
    if e.vB == nil or resetVarsOnRecompile:
      e.vm.resetVars()
      e.vD = e.vm.reg("d")
      e.vB = e.vm.reg("b")
      e.inited = false
    e.needRecompile = false
    for k in 0 .. 3: e.compiled[k] = e.vm.compile(e.code[k])
  if (isBeat and BeatPreinit) != 0: return 0
  e.vB[] = (if isBeat != 0: 1.0 else: 0.0)
  if e.compiled[3] != nil and not e.inited:
    e.compiled[3].run()
    e.inited = true
  e.compiled[1].run()
  if isBeat != 0: e.compiled[2].run()
  if e.compiled[0] != nil:
    var x = 0
    while x < imaxd - 32:
      e.vD[] = x.float64 / (e.maxd - 1)
      e.compiled[0].run()
      e.tab[x] = int32(ftol(e.vD[] * 256.0 * e.maxd / float64(x + 1)))
      inc x
    while x < imaxd:
      e.tab[x] = e.tab[x - 1]
      inc x
  else:
    for x in 0 ..< imaxd: e.tab[x] = 0
  let w2 = w div 2
  let h2 = h div 2
  var o = 0
  let sub = e.subpixel != 0
  let blend = e.blend != 0
  for y in 0 ..< h:
    let ty = int32(y - h2)
    var x2 = int32(w2 * w2 + w2) + ty * ty + 256
    var dx2 = int32(-2 * w2)
    let yysc = ty
    var xxsc = int32(-w2)
    for x in 0 ..< w:
      let qd = e.tab[min(isqrt(cast[uint32](x2)), imaxd - 1)]
      x2 = x2 +% dx2
      dx2 += 2
      var px: uint32
      if sub:
        var xpart = qd *% xxsc +% 128
        var ypart = qd *% yysc +% 128
        var ow = w2 + int(xpart shr 8)
        var oh = h2 + int(ypart shr 8)
        xpart = xpart and 0xff
        ypart = ypart and 0xff
        inc xxsc
        if ow < 0: ow = 0
        elif ow >= w - 1: ow = w - 2
        if oh < 0: oh = 0
        elif oh >= h - 1: oh = h - 2
        px = blend4(fb, ow + e.wmul[oh], w, int(xpart), int(ypart))
      else:
        var ow = w2 + int((qd *% xxsc +% 128) shr 8)
        inc xxsc
        var oh = h2 + int((qd *% yysc +% 128) shr 8)
        if ow < 0: ow = 0
        elif ow >= w: ow = w - 1
        if oh < 0: oh = 0
        elif oh >= h: oh = h - 1
        px = fb[ow + e.wmul[oh]]
      fbout[o] = if blend: blendAvg(px, fb[o]) else: px
      inc o
  1

proc registerTrans3*() =
  registerEffect(16, newScatter)
  registerEffect(24, newGrain)
  registerEffect(30, newMosaic)
  registerEffect(35, newDdm)
  registerEffect(38, newUniqueTone)
  registerEffect(41, newInterferences)
  registerEffect(42, newDynShift)
