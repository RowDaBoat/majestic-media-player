## Trans effects: Blitter Feedback, Roto Blitter, Colorfade, Color Clip,
## Brightness, Fast Brightness, Invert, Mirror, Interleave (r_blit.cpp,
## r_rotblit.cpp, r_colorfade.cpp, r_contrast.cpp, r_bright.cpp,
## r_fastbright.cpp, r_invert.cpp, r_mirror.cpp, r_interleave.cpp).

import std/math
import core, list

# --- Blitter Feedback ------------------------------------------------------------

type Blitter = ref object of Effect
  scale, scale2, blend, beatch, fpos, subpixel: int32

method desc(e: Blitter): string = "Trans / Blitter Feedback"
proc newBlitter(): Effect = Blitter(scale: 30, scale2: 30, fpos: 30, subpixel: 1)

method load(e: Blitter, d: openArray[byte]) =
  var pos = 0
  if d.len - pos >= 4: (e.scale = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.scale2 = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.blend = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.beatch = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.subpixel = getInt(d, pos); pos += 4)
  else: e.subpixel = 0
  e.fpos = e.scale

proc blitOut(e: Blitter, fb, fbout: Pixels, w, h, fval: int): int =
  const adj = 7
  let dsx = (fval + (1 shl adj) - 32) shl (16 - adj)
  let xlen = ((w shl 16) div dsx) and not 3
  let ylen = (h shl 16) div dsx
  if xlen >= w or ylen >= h: return 0
  let sx0 = (w - xlen) div 2
  let sy0 = (h - ylen) div 2
  var sy = 32768
  for y in 0 ..< ylen:
    var sx = 32768
    let src = (sy shr 16) * w
    let od = (sy0 + y) * w + sx0
    sy += dsx
    if e.blend == 0:
      for x in 0 ..< (xlen div 4) * 4:
        fbout[od + x] = fb[src + (sx shr 16)]
        sx += dsx
    else:
      let s2 = (y + sy0) * w + sx0
      for x in 0 ..< (xlen div 4) * 4:
        fbout[od + x] = blendAvg(fb[s2 + x], fb[src + (sx shr 16)])
        sx += dsx
  for y in 0 ..< ylen:
    let o = (sy0 + y) * w + sx0
    copyMem(fb[o].addr, fbout[o].addr, xlen * 4)
  0

proc blitNormal(e: Blitter, fb, fbout: Pixels, w, h, fval: int): int =
  let dsx = ((fval + 32) shl 16) div 64
  let isx = ((w shl 16) - (dsx * w)) div 2
  var sy = ((h shl 16) - (dsx * h)) div 2
  let n = w * h
  var o = 0
  for y in 0 ..< h:
    var sx = isx
    let src = (sy shr 16) * w
    let ypart = (sy shr 8) and 0xff
    sy += dsx
    if e.subpixel != 0:
      # The MMX loop: bilinear, w pixels.
      for x in 0 ..< w:
        let i = src + (sx shr 16)
        fbout[o + x] = if i + w + 1 < n: blend4(fb, i, w, (sx shr 8) and 0xff, ypart) else: fb[min(i, n - 1)]
        sx += dsx
      if e.blend != 0:
        for x in 0 ..< (w div 4) * 4: fbout[o + x] = blendAvg(fbout[o + x], fb[y * w + x])
    elif e.blend == 0:
      for x in 0 ..< (w div 4) * 4:
        fbout[o + x] = fb[src + (sx shr 16)]
        sx += dsx
    else:
      let s2 = y * w
      for x in 0 ..< (w div 4) * 4:
        fbout[o + x] = blendAvg(fb[s2 + x], fb[src + (sx shr 16)])
        sx += dsx
    o += w
  1

method render(e: Blitter, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if (isBeat and BeatPreinit) != 0: return 0
  if isBeat != 0 and e.beatch != 0: e.fpos = e.scale2
  var fval: int
  if e.scale < e.scale2:
    fval = int(if e.fpos > e.scale: e.fpos else: e.scale)
    e.fpos -= 3
  else:
    fval = int(if e.fpos < e.scale: e.fpos else: e.scale)
    e.fpos += 3
  if fval < 0: fval = 0
  if fval < 32: return e.blitNormal(fb, fbout, w, h, fval)
  if fval > 32: return e.blitOut(fb, fbout, w, h, fval)
  0

# --- Roto Blitter ---------------------------------------------------------------------

type RotoBlitter = ref object of Effect
  zoomScale, rotDir, blend, beatch, beatchSpeed, zoomScale2, beatchScale, scaleFpos: int32
  rotRev: int32
  subpixel: int32
  rotRevPos: float64
  wmul: seq[int]
  lw, lh: int

method desc(e: RotoBlitter): string = "Trans / Roto Blitter"

proc newRotoBlitter(): Effect =
  RotoBlitter(zoomScale: 31, rotDir: 31, rotRev: 1, rotRevPos: 1.0, zoomScale2: 31,
              scaleFpos: 31, subpixel: 1)

method load(e: RotoBlitter, d: openArray[byte]) =
  var pos = 0
  if d.len - pos >= 4: (e.zoomScale = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.rotDir = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.blend = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.beatch = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.beatchSpeed = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.zoomScale2 = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.beatchScale = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.subpixel = getInt(d, pos); pos += 4)
  else: e.subpixel = 0
  e.scaleFpos = e.zoomScale

method render(e: RotoBlitter, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if e.lw != w or e.lh != h or e.wmul.len == 0:
    e.lw = w
    e.lh = h
    e.wmul = newSeq[int](h)
    for x in 0 ..< h: e.wmul[x] = x * w
  if (isBeat and BeatPreinit) != 0: return 0
  if isBeat != 0 and e.beatch != 0: e.rotRev = -e.rotRev
  if e.beatch == 0: e.rotRev = 1
  e.rotRevPos += (1.0 / float64(1 + e.beatchSpeed * 4)) * (e.rotRev.float64 - e.rotRevPos)
  if e.rotRevPos > e.rotRev.float64 and e.rotRev > 0: e.rotRevPos = e.rotRev.float64
  if e.rotRevPos < e.rotRev.float64 and e.rotRev < 0: e.rotRevPos = e.rotRev.float64
  if isBeat != 0 and e.beatchScale != 0: e.scaleFpos = e.zoomScale2
  var fval: int
  if e.zoomScale < e.zoomScale2:
    fval = int(max(e.scaleFpos, e.zoomScale))
    if e.scaleFpos > e.zoomScale: e.scaleFpos -= 3
  else:
    fval = int(min(e.scaleFpos, e.zoomScale))
    if e.scaleFpos < e.zoomScale: e.scaleFpos += 3
  let zoom = 1.0 + float64(fval - 31) / 31.0
  let theta = float64(e.rotDir - 32) * e.rotRevPos
  const MPi = 3.1415926536
  var temp = cos(theta * MPi / 180.0) * zoom
  let dsdx = int32(ftol(temp * 65536.0))
  let dtdy = int32(ftol(temp * 65536.0))
  temp = sin(theta * MPi / 180.0) * zoom
  let dsdy = -int32(ftol(temp * 65536.0))
  let dtdx = int32(ftol(temp * 65536.0))
  let w1 = int32(w - 1)
  let h1 = int32(h - 1)
  var sstart = -((w1 div 2) *% dsdx +% (h1 div 2) *% dsdy) +% w1 *% (32768'i32 + (1'i32 shl 20))
  var tstart = -((w1 div 2) *% dtdx +% (h1 div 2) *% dtdy) +% h1 *% (32768'i32 + (1'i32 shl 20))
  var s = sstart
  var t = tstart
  let ds = w1 shl 16
  let dt = h1 shl 16
  if dsdx <= -ds or dsdx >= ds or dtdx <= -dt or dtdx >= dt: return 1
  var o = 0
  let src = fb
  for y in 0 ..< h:
    if ds != 0: s = s mod ds
    if dt != 0: t = t mod dt
    if s < 0: s += ds
    if t < 0: t += dt
    for x in 0 ..< w:
      if dsdx <= 0 and dtdx <= 0:
        if t < 0: t += dt
        if s < 0: s += ds
      elif dsdx <= 0:
        if t >= dt: t -= dt
        if s < 0: s += ds
      elif dtdx <= 0:
        if t < 0: t += dt
        if s >= ds: s -= ds
      else:
        if t >= dt: t -= dt
        if s >= ds: s -= ds
      let i = int(s shr 16) + e.wmul[int(t shr 16)]
      var px: uint32
      if e.subpixel != 0: px = blend4_16(src, i, w, int(s), int(t))
      else: px = src[i]
      if e.blend != 0: px = blendAvg(fb[o], px)
      fbout[o] = px
      inc o
      s = s +% dsdx
      t = t +% dtdx
    sstart = sstart +% dsdy
    tstart = tstart +% dtdy
    s = sstart
    t = tstart
  1

# --- Colorfade ----------------------------------------------------------------------------

var colorFadeTab: array[512, array[512, uint8]]
for x in 0 ..< 512:
  for y in 0 ..< 512:
    let xp = x - 255
    let yp = y - 255
    colorFadeTab[x][y] =
      if xp > 0 and xp > -yp: 0'u8
      elif yp < 0 and xp < -yp: 1'u8
      elif xp < 0 and yp > 0: 2'u8
      else: 3'u8

type ColorFade = ref object of Effect
  enabled: int32
  faders, beatfaders, faderpos: array[3, int32]
  ft: array[4, array[3, int]]

method desc(e: ColorFade): string = "Trans / Colorfade"

proc newColorFade(): Effect =
  let e = ColorFade(enabled: 1, faders: [8'i32, -8, -8])
  e.beatfaders = e.faders
  e.faderpos = e.faders
  e

method load(e: ColorFade, d: openArray[byte]) =
  var pos = 0
  if d.len - pos >= 4: (e.enabled = getInt(d, pos); pos += 4)
  for k in 0 .. 2:
    if d.len - pos >= 4: (e.faders[k] = getInt(d, pos); pos += 4)
  e.beatfaders = e.faders
  for k in 0 .. 2:
    if d.len - pos >= 4: (e.beatfaders[k] = getInt(d, pos); pos += 4)
  e.faderpos = e.faders

method render(e: ColorFade, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if e.enabled == 0 or (isBeat and BeatPreinit) != 0: return 0
  let fp = addr e.faderpos
  if fp[0] < e.faders[0]: inc fp[0]
  if fp[1] < e.faders[2]: inc fp[1]
  if fp[2] < e.faders[1]: inc fp[2]
  if fp[0] > e.faders[0]: dec fp[0]
  if fp[1] > e.faders[2]: dec fp[1]
  if fp[2] > e.faders[1]: dec fp[2]
  if (e.enabled and 4) == 0:
    fp[] = e.faders
  elif isBeat != 0 and (e.enabled and 2) != 0:
    fp[0] = int32((crand() mod 32) - 6)
    fp[1] = int32((crand() mod 64) - 32)
    if fp[1] < 0 and fp[1] > -16: fp[1] = -32
    if fp[1] >= 0 and fp[1] < 16: fp[1] = 32
    fp[2] = int32((crand() mod 32) - 6)
  elif isBeat != 0:
    fp[] = e.beatfaders
  let (fs1, fs2, fs3) = (int(fp[0]), int(fp[1]), int(fp[2]))
  e.ft = [[fs3, fs2, fs1], [fs2, fs1, fs3], [fs1, fs3, fs2], [fs3, fs3, fs3]]
  let q = cast[ptr UncheckedArray[uint8]](fb)
  template clip(v: int): uint8 = uint8(clamp(v, 0, 255))
  for i in 0 ..< w * h:
    let o = i * 4
    let r = int(q[o])      # the bytes as C named them: blue first in memory
    let g = int(q[o + 1])
    let b = int(q[o + 2])
    let p = int(colorFadeTab[(g - b) + 255][(b - r) + 255])
    q[o] = clip(r + e.ft[p][0])
    q[o + 1] = clip(g + e.ft[p][1])
    q[o + 2] = clip(b + e.ft[p][2])
  0

# --- Color Clip --------------------------------------------------------------------------------

type ColorClip = ref object of Effect
  enabled: int32
  clip, clipOut: uint32
  dist: int32

method desc(e: ColorClip): string = "Trans / Color Clip"
proc newColorClip(): Effect =
  ColorClip(enabled: 1, clip: colorRgb(32, 32, 32), clipOut: colorRgb(32, 32, 32), dist: 10)

method load(e: ColorClip, d: openArray[byte]) =
  var pos = 0
  if d.len - pos >= 4: (e.enabled = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.clip = cast[uint32](getInt(d, pos)); pos += 4)
  if d.len - pos >= 4: (e.clipOut = cast[uint32](getInt(d, pos)); pos += 4)
  else: e.clipOut = e.clip
  if d.len - pos >= 4: (e.dist = getInt(d, pos); pos += 4)

method render(e: ColorClip, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if e.enabled == 0: return 0
  if (isBeat and BeatPreinit) != 0: return 0
  var l = int(e.dist) * 2
  l = l * l
  let fsb = e.clip and 0xff0000
  let fsg = e.clip and 0xff00
  let fsr = e.clip and 0xff
  let n = w * h
  if e.enabled == 1:
    for i in 0 ..< n:
      let a = fb[i]
      if (a and 0xff) <= fsr and (a and 0xff00) <= fsg and (a and 0xff0000) <= fsb:
        fb[i] = (a and 0xff000000'u32) or e.clipOut
  elif e.enabled == 2:
    for i in 0 ..< n:
      let a = fb[i]
      if (a and 0xff) >= fsr and (a and 0xff00) >= fsg and (a and 0xff0000) >= fsb:
        fb[i] = (a and 0xff000000'u32) or e.clipOut
  else:
    let (cb, cg, cr) = (int(fsb shr 16), int(fsg shr 8), int(fsr))
    for i in 0 ..< n:
      let a = fb[i]
      let r = int(a and 255) - cr
      let g = int((a shr 8) and 255) - cg
      let b = int((a shr 16) and 255) - cb
      if r * r + g * g + b * b <= l: fb[i] = (a and 0xff000000'u32) or e.clipOut
  0

# --- Brightness -------------------------------------------------------------------------------

type Brightness = ref object of Effect
  enabled, redp, greenp, bluep, blend, blendavg, dissoc, exclude, distance: int32
  color: uint32
  needInit: bool
  rtab, gtab, btab: array[256, uint32]

method desc(e: Brightness): string = "Trans / Brightness"
proc newBrightness(): Effect = Brightness(needInit: true, blendavg: 1, enabled: 1, distance: 16)

method load(e: Brightness, d: openArray[byte]) =
  var pos = 0
  for f in [addr e.enabled, addr e.blend, addr e.blendavg, addr e.redp, addr e.greenp,
            addr e.bluep, addr e.dissoc]:
    if d.len - pos >= 4: (f[] = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.color = cast[uint32](getInt(d, pos)); pos += 4)
  if d.len - pos >= 4: (e.exclude = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.distance = getInt(d, pos); pos += 4)
  e.needInit = true

proc inRange(c, r: uint32, dist: int): bool =
  if abs(int(c and 0xFF) - int(r and 0xFF)) > dist: return false
  if abs(int(c and 0xFF00) - int(r and 0xFF00)) > (dist shl 8): return false
  if abs(int(c and 0xFF0000) - int(r and 0xFF0000)) > (dist shl 16): return false
  true

method render(e: Brightness, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  proc mul(p: int32): int =
    ftol((1.0 + float64(if p < 0: 1 else: 16) * (p.float32.float64 / 4096.0)) * 65536.0)
  let rm = mul(e.redp)
  let gm = mul(e.greenp)
  let bm = mul(e.bluep)
  if e.enabled == 0: return 0
  if e.needInit:
    for n in 0 .. 255:
      var r = (n * rm) and 0xffff0000
      if r > 0xff0000: r = 0xff0000
      if r < 0: r = 0
      var g = ((n * gm) shr 8) and 0xffff00
      if g > 0xff00: g = 0xff00
      if g < 0: g = 0
      var b = ((n * bm) shr 16) and 0xffff
      if b > 0xff: b = 0xff
      if b < 0: b = 0
      e.rtab[n] = uint32(r)
      e.gtab[n] = uint32(g)
      e.btab[n] = uint32(b)
    e.needInit = false
  if (isBeat and BeatPreinit) != 0: return 0
  let n = w * h
  let ex = e.exclude != 0
  let dist = int(e.distance)
  for i in 0 ..< n:
    let pix = fb[i]
    if ex and inRange(pix, e.color, dist): continue
    let v = e.rtab[(pix shr 16) and 0xff] or e.gtab[(pix shr 8) and 0xff] or e.btab[pix and 0xff]
    fb[i] = if e.blend != 0: blendAdd(pix, v) elif e.blendavg != 0: blendAvg(pix, v) else: v
  0

# --- Fast Brightness -----------------------------------------------------------------------------

type FastBright = ref object of Effect
  dir: int32

method desc(e: FastBright): string = "Trans / Fast Brightness"
proc newFastBright(): Effect = FastBright()

method load(e: FastBright, d: openArray[byte]) =
  e.dir = 0
  if d.len >= 4: e.dir = getInt(d, 0)

method render(e: FastBright, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if (isBeat and BeatPreinit) != 0: return 0
  let n = w * h
  if e.dir == 0:
    for i in 0 ..< n:
      let p = fb[i]
      var r = 0'u32
      for s in [0'u32, 8, 16, 24]:
        r = r or (min(((p shr s) and 0xff) * 2, 255'u32) shl s)
      fb[i] = r
  elif e.dir == 1:
    for i in 0 ..< n: fb[i] = (fb[i] shr 1) and 0x7F7F7F7F'u32
  0

# --- Invert ----------------------------------------------------------------------------------------

type Invert = ref object of Effect
  enabled: int32

method desc(e: Invert): string = "Trans / Invert"
proc newInvert(): Effect = Invert(enabled: 1)

method load(e: Invert, d: openArray[byte]) =
  if d.len >= 4: e.enabled = getInt(d, 0)

method render(e: Invert, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if (isBeat and BeatPreinit) != 0: return 0
  if e.enabled == 0: return 0
  for i in 0 ..< w * h: fb[i] = fb[i] xor 0xFFFFFF'u32
  0

# --- Mirror -----------------------------------------------------------------------------------------

type Mirror = ref object of Effect
  framecount: int
  enabled, mode, onbeat, rbeat, smooth, slower: int32

var
  mirrorLastMode {.threadvar.}: int32  ## C's statics, shared by every Mirror
  mirrorDivisors {.threadvar.}: uint32
  mirrorInc {.threadvar.}: uint32

method desc(e: Mirror): string = "Trans / Mirror"
proc newMirror(): Effect = Mirror(enabled: 1, slower: 4, mode: 1)

method load(e: Mirror, d: openArray[byte]) =
  var pos = 0
  for f in [addr e.enabled, addr e.mode, addr e.onbeat, addr e.smooth, addr e.slower]:
    if d.len - pos >= 4: (f[] = getInt(d, pos); pos += 4)

proc blendAdapt(a, b: uint32, divisor: int): uint32 {.inline.} =
  uint32(int((a shr 4) and 0x0F0F0F) * (16 - divisor) + int((b shr 4) and 0x0F0F0F) * divisor)

method render(e: Mirror, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if (isBeat and BeatPreinit) != 0: return 0
  if e.enabled == 0: return 0
  let t = w * h
  let halfw = w div 2
  let halfh = h div 2
  var mode = e.mode
  if e.onbeat != 0:
    if isBeat != 0: e.rbeat = int32(crand() mod 16) and e.mode
    mode = e.rbeat
  if mode != mirrorLastMode:
    let dif = mode xor mirrorLastMode
    var i = 1'i32
    var m = 0xFF'u32
    var d = 0'u32
    while i < 16:
      if (dif and i) != 0:
        mirrorInc = (mirrorInc and not m) or ((if (mirrorLastMode and i) != 0: 0xFF'u32 else: 1'u32) shl d)
        if (mirrorDivisors and m) == 0:
          mirrorDivisors = (mirrorDivisors and not m) or
            ((if (mirrorLastMode and i) != 0: 16'u32 else: 1'u32) shl d)
      i = i shl 1
      m = m shl 8
      d += 8
    mirrorLastMode = mode
  let smooth = e.smooth != 0
  if (mode and 4) != 0 or (smooth and (mirrorDivisors and 0x00FF0000'u32) != 0):
    let divis = int((mirrorDivisors and 0xFF0000'u32) shr 16)
    for hi in 0 ..< h:
      let row = hi * w
      for k in 0 ..< halfw:
        let dst = row + w - 1 - k
        fb[dst] = if smooth and divis != 0: blendAdapt(fb[dst], fb[row + k], divis) else: fb[row + k]
  if (mode and 8) != 0 or (smooth and (mirrorDivisors and 0xFF000000'u32) != 0):
    let divis = int((mirrorDivisors and 0xFF000000'u32) shr 24)
    for hi in 0 ..< h:
      let row = hi * w
      for k in 0 ..< halfw:
        let src = row + w - 1 - k
        fb[row + k] = if smooth and divis != 0: blendAdapt(fb[row + k], fb[src], divis) else: fb[src]
  if (mode and 1) != 0 or (smooth and (mirrorDivisors and 0xFF'u32) != 0):
    let divis = int(mirrorDivisors and 0xFF'u32)
    var j = t - w
    for hi in 0 ..< halfh:
      let row = hi * w
      for k in 0 ..< w:
        fb[row + k + j] = if smooth and divis != 0: blendAdapt(fb[row + k + j], fb[row + k], divis) else: fb[row + k]
      j -= 2 * w
  if (mode and 2) != 0 or (smooth and (mirrorDivisors and 0xFF00'u32) != 0):
    let divis = int((mirrorDivisors and 0xFF00'u32) shr 8)
    var j = t - w
    for hi in 0 ..< halfh:
      let row = hi * w
      for k in 0 ..< w:
        fb[row + k] = if smooth and divis != 0: blendAdapt(fb[row + k], fb[row + k + j], divis) else: fb[row + k + j]
      j -= 2 * w
  if smooth:
    inc e.framecount
    if e.slower != 0 and e.framecount mod int(e.slower) == 0:
      var m = 0xFF'u32
      var d = 0'u32
      for i in 0 .. 3:
        if (mirrorDivisors and m) != 0:
          let cur = (mirrorDivisors and m) shr d
          let inc8 = uint32(uint8((mirrorInc and m) shr d))
          mirrorDivisors = (mirrorDivisors and not m) or (((cur + inc8) mod 16) shl d)
        m = m shl 8
        d += 8
  0

# --- Interleave ---------------------------------------------------------------------------------

type Interleave = ref object of Effect
  x, y, enabled, blend, blendavg, onbeat, x2, y2, beatdur: int32
  color: uint32
  curX, curY: float64

method desc(e: Interleave): string = "Trans / Interleave"
proc newInterleave(): Effect =
  Interleave(beatdur: 4, x: 1, x2: 1, y: 1, y2: 1, curX: 1, curY: 1, enabled: 1)

method load(e: Interleave, d: openArray[byte]) =
  var pos = 0
  for f in [addr e.enabled, addr e.x, addr e.y]:
    if d.len - pos >= 4: (f[] = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.color = cast[uint32](getInt(d, pos)); pos += 4)
  for f in [addr e.blend, addr e.blendavg, addr e.onbeat, addr e.x2, addr e.y2, addr e.beatdur]:
    if d.len - pos >= 4: (f[] = getInt(d, pos); pos += 4)
  e.curX = e.x.float64
  e.curY = e.y.float64

method render(e: Interleave, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if (isBeat and BeatPreinit) != 0: return 0
  if e.enabled == 0: return 0
  var ystat = false
  var yp = 0
  let sc1 = (e.beatdur.float64 + 512.0 - 64.0) / 512.0
  e.curX = e.curX * sc1 + e.x.float64 * (1.0 - sc1)
  e.curY = e.curY * sc1 + e.y.float64 * (1.0 - sc1)
  if isBeat != 0 and e.onbeat != 0:
    e.curX = e.x2.float64
    e.curY = e.y2.float64
  let tx = ftol(e.curX)
  let ty = ftol(e.curY)
  var xos = 0
  if ty == 0: ystat = true
  if tx > 0: xos = (w mod tx) div 2
  if ty > 0: yp = (h mod ty) div 2
  template put(i: int) =
    if e.blend != 0: fb[i] = blendAdd(fb[i], e.color)
    elif e.blendavg != 0: fb[i] = blendAvg(fb[i], e.color)
    else: fb[i] = e.color
  if tx >= 0 and ty >= 0:
    var p = 0
    for j in 0 ..< h:
      var xstat = false
      if ty != 0:
        inc yp
        if yp >= ty:
          ystat = not ystat
          yp = 0
      var l = w
      if not ystat:
        for k in 0 ..< w: put(p + k)
        p += w
      elif tx != 0:
        var xo = xos
        while l > 0:
          let l2 = min(l, tx - xo)
          xo = 0
          l -= l2
          if not xstat:
            for k in 0 ..< l2: put(p + k)
          p += l2
          xstat = not xstat
      else: p += w
  0

proc registerTrans2*() =
  registerEffect(4, newBlitter)
  registerEffect(9, newRotoBlitter)
  registerEffect(11, newColorFade)
  registerEffect(12, newColorClip)
  registerEffect(22, newBrightness)
  registerEffect(23, newInterleave)
  registerEffect(26, newMirror)
  registerEffect(37, newInvert)
  registerEffect(44, newFastBright)
