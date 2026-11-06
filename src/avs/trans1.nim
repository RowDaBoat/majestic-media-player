## Trans effects: Fadeout, Blur, Movement, Dynamic Movement
## (r_fadeout.cpp, r_blur.cpp, r_trans.cpp, r_dmove.cpp).

import std/math
import core, list

const MPi = 3.14159265358979323846

# --- Fadeout ------------------------------------------------------------------------

type Fadeout = ref object of Effect
  fadtab: array[3, array[256, uint8]]
  fadelen: int32
  color: uint32

method desc(e: Fadeout): string = "Trans / Fadeout"

proc maketab(e: Fadeout) =
  let seek = [int(e.color and 0xff), int((e.color shr 8) and 0xff), int((e.color shr 16) and 0xff)]
  let f = int(e.fadelen)
  for x in 0 .. 255:
    for c in 0 .. 2:
      var v = x
      if v <= seek[c] - f: v += f
      elif v >= seek[c] + f: v -= f
      else: v = seek[c]
      e.fadtab[c][x] = uint8(v and 0xff)

proc newFadeout(): Effect =
  let e = Fadeout(fadelen: 16)
  e.maketab()
  e

method load(e: Fadeout, d: openArray[byte]) =
  var pos = 0
  if d.len - pos >= 4: (e.fadelen = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.color = cast[uint32](getInt(d, pos)); pos += 4)
  e.maketab()

method render(e: Fadeout, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if (isBeat and BeatPreinit) != 0: return 0
  if e.fadelen == 0: return 0
  let n = w * h
  if e.color != 0:
    for i in 0 ..< n:
      let p = fb[i]
      fb[i] = (p and 0xff000000'u32) or uint32(e.fadtab[0][p and 0xff]) or
              (uint32(e.fadtab[1][(p shr 8) and 0xff]) shl 8) or
              (uint32(e.fadtab[2][(p shr 16) and 0xff]) shl 16)
  else:
    # MMX psubusb on every byte, alpha too, 8 pixels at a time; the rest as
    # the asm's tail did (it took the table's value away: x - max(x-f, 0)).
    let f = uint32(e.fadelen and 0xff)
    let main = (n div 8) * 8
    for i in 0 ..< main:
      let p = fb[i]
      var r = 0'u32
      for s in [0'u32, 8, 16, 24]:
        let c = (p shr s) and 0xff
        r = r or ((if c > f: c - f else: 0'u32) shl s)
      fb[i] = r
    for i in main ..< n:
      let p = fb[i]
      var r = p and 0xff000000'u32
      for s in [0'u32, 8, 16]:
        let c = (p shr s) and 0xff
        r = r or (((c - uint32(e.fadtab[0][c])) and 0xff) shl s)
      fb[i] = r
  0

# --- Blur ------------------------------------------------------------------------------

type Blur = ref object of Effect
  enabled, roundmode: int32

method desc(e: Blur): string = "Trans / Blur"
proc newBlur(): Effect = Blur(enabled: 1)

method load(e: Blur, d: openArray[byte]) =
  var pos = 0
  if d.len - pos >= 4: (e.enabled = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.roundmode = getInt(d, pos); pos += 4)
  else: e.roundmode = 0

template d2(x: uint32): uint32 = (x and 0xFEFEFEFF'u32) shr 1
template d4(x: uint32): uint32 = (x and 0xFCFCFCFF'u32) shr 2
template d8(x: uint32): uint32 = (x and 0xF8F8F8FF'u32) shr 3
template d16(x: uint32): uint32 = (x and 0xF0F0F0FF'u32) shr 4

proc blurRows(e: Blur, f, o: Pixels, w, h: int) =
  let rm = e.roundmode != 0
  template adj(v: uint32): uint32 = (if rm: v else: 0'u32)
  # One edge row: `nb` is the neighbour row's offset (below for the top, above for the bottom).
  template edgeRow(row, nb: int, first, mid, last: untyped) =
    block:
      let b = row
      block:
        let i {.inject.} = b
        let n {.inject.} = b + nb
        o[i] = first
      for xx in 1 .. w - 2:
        let i {.inject.} = b + xx
        let n {.inject.} = b + xx + nb
        o[i] = mid
      block:
        let i {.inject.} = b + w - 1
        let n {.inject.} = b + w - 1 + nb
        o[i] = last
  template midRows(first, mid, last: untyped) =
    for y in 1 .. h - 2:
      let b = y * w
      block:
        let i {.inject.} = b
        let dn {.inject.} = b + w
        let up {.inject.} = b - w
        o[i] = first
      for xx in 1 .. w - 2:
        let i {.inject.} = b + xx
        let dn {.inject.} = i + w
        let up {.inject.} = i - w
        o[i] = mid
      block:
        let i {.inject.} = b + w - 1
        let dn {.inject.} = i + w
        let up {.inject.} = i - w
        o[i] = last
  case e.enabled
  of 2:  # light
    for (row, nb) in [(0, w), ((h - 1) * w, -w)]:
      edgeRow(row, nb,
        d2(f[i]) + d4(f[i]) + d8(f[i + 1]) + d8(f[n]) + adj(0x03030303'u32),
        d2(f[i]) + d8(f[i]) + d8(f[i + 1]) + d8(f[i - 1]) + d8(f[n]) + adj(0x04040404'u32),
        d2(f[i]) + d4(f[i]) + d8(f[i - 1]) + d8(f[n]) + adj(0x03030303'u32))
    midRows(
      d2(f[i]) + d8(f[i]) + d8(f[i + 1]) + d8(f[dn]) + d8(f[up]) + adj(0x04040404'u32),
      d2(f[i]) + d4(f[i]) + d16(f[i + 1]) + d16(f[i - 1]) + d16(f[dn]) + d16(f[up]) + adj(0x05050505'u32),
      d2(f[i]) + d8(f[i]) + d8(f[i - 1]) + d8(f[dn]) + d8(f[up]) + adj(0x04040404'u32))
  of 3:  # more
    for (row, nb) in [(0, w), ((h - 1) * w, -w)]:
      edgeRow(row, nb,
        d2(f[i + 1]) + d2(f[n]) + adj(0x01010101'u32),
        d4(f[i + 1]) + d4(f[i - 1]) + d2(f[n]) + adj(0x02020202'u32),
        d2(f[i - 1]) + d2(f[n]) + adj(0x01010101'u32))
    midRows(
      d2(f[i + 1]) + d4(f[dn]) + d4(f[up]) + adj(0x02020202'u32),
      d4(f[i + 1]) + d4(f[i - 1]) + d4(f[dn]) + d4(f[up]) + adj(0x03030303'u32),
      d2(f[i - 1]) + d4(f[dn]) + d4(f[up]) + adj(0x02020202'u32))
  else:  # normal
    for (row, nb) in [(0, w), ((h - 1) * w, -w)]:
      edgeRow(row, nb,
        d2(f[i]) + d4(f[i + 1]) + d4(f[n]) + adj(0x02020202'u32),
        d4(f[i]) + d4(f[i + 1]) + d4(f[i - 1]) + d4(f[n]) + adj(0x03030303'u32),
        d2(f[i]) + d4(f[i - 1]) + d4(f[n]) + adj(0x02020202'u32))
    midRows(
      d4(f[i]) + d4(f[i + 1]) + d4(f[dn]) + d4(f[up]) + adj(0x03030303'u32),
      d2(f[i]) + d8(f[i + 1]) + d8(f[i - 1]) + d8(f[dn]) + d8(f[up]) + adj(0x04040404'u32),
      d4(f[i]) + d4(f[i - 1]) + d4(f[dn]) + d4(f[up]) + adj(0x03030303'u32))

method render(e: Blur, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if (isBeat and BeatPreinit) != 0: return 0
  if e.enabled == 0: return 0
  if w < 2 or h < 2: return 0
  e.blurRows(fb, fbout, w, h)
  1

# --- Movement -------------------------------------------------------------------------------

const
  RefMin = 3
  RefMax = 23
  OffsetMask = (1 shl 22) - 1

type MoveDesc = tuple[evalCode: string, usesEval, usesRect: bool]

const moveDescs: array[24, MoveDesc] = [
  ("", false, false), ("", false, false), ("x=x+1/32; // use wrap for this one", false, true),
  ("r = r + (0.1 - (0.2 * d));\r\nd = d * 0.96;", false, false),
  ("d = d * (0.99 * (1.0 - sin(r-$PI*0.5) / 32.0));\r\nr = r + (0.03 * sin(d * $PI * 4));", false, false),
  ("d = d * (0.94 + (cos((r-$PI*0.5) * 32.0) * 0.06));", false, false),
  ("d = d * (1.01 + (cos((r-$PI*0.5) * 4) * 0.04));\r\nr = r + (0.03 * sin(d * $PI * 4));", false, false),
  ("", false, false),
  ("r = r + (0.1 * sin(d * $PI * 5));", false, false),
  ("t = sin(d * $PI);\r\nd = d - (8*t*t*t*t*t)/sqrt((sw*sw+sh*sh)/4);", false, false),
  ("t = sin(d * $PI);\r\nd = d - (8*t*t*t*t*t)/sqrt((sw*sw+sh*sh)/4);\r\nt=cos(d*$PI/2.0);\r\nr= r + 0.1*t*t*t;", false, false),
  ("d = d * (0.95 + (cos(((r-$PI*0.5) * 5.0) - ($PI / 2.50)) * 0.03));", false, false),
  ("r = r + 0.04;\r\nd = d * (0.96 + cos(d * $PI) * 0.05);", false, false),
  ("t = cos(d * $PI);\r\nr = r + (0.07 * t);\r\nd = d * (0.98 + t * 0.10);", false, false),
  ("// this is a very bad approximation in script. fixme.\r\nd=sqrt(x*x+y*y); r=atan2(y,x);\r\nr=r+0.1-0.2*d; d=d*0.96;\r\nx=cos(r)*d + 8/128; y=sin(r)*d;", false, true),
  ("d = 0.15", false, false),
  ("r = cos(r * 3)", false, false),
  ("d = d * (1 - ((d - .35) * .5));\r\nr = r + .1;", false, false),
  ("d = d * (1 - (sin((r-$PI*0.5) * 7) * .03));\r\nr = r + (cos(d * 12) * .03);", true, false),
  ("d = d * (1 - (sin((r - $PI*0.5) * 12) * .05));\r\nr = r + (cos(d * 18) * .05);\r\nd = d * (1-((d - .4) * .03));\r\nr = r + ((d - .4) * .13)", true, false),
  ("x = x + (cos(y * 18) * .02);\r\ny = y + (sin(x * 14) * .03);", true, true),
  ("x = x + (cos(abs(y-.5) * 8) * .02);\r\ny = y + (sin(abs(x-.5) * 8) * .05);\r\nx = x * .95;\r\ny = y * .95;", true, true),
  ("y = y * ( 1 + (sin(r + $PI/2) * .3) );\r\nx = x * ( 1 + (cos(r + $PI/2) * .3) );\r\nx = x * .995;\r\ny = y * .995;", true, true),
  ("y = (r*6)/($PI); x = d;", true, true)]

proc usesEval(t: int): bool = t >= RefMin and t <= RefMax and moveDescs[t].usesEval

proc radial(n: int, r, d: var float64, maxd: float64, xo, yo: var int): bool =
  ## The built-in radial maps; false for those without one.
  case n
  of 3: r += 0.1 - 0.2 * (d / maxd); d *= 0.96
  of 4: d *= 0.99 * (1.0 - sin(r) / 32.0); r += 0.03 * sin(d / maxd * MPi * 4)
  of 5: d *= 0.94 + (cos(r * 32.0) * 0.06)
  of 6: d *= 1.01 + (cos(r * 4.0) * 0.04); r += 0.03 * sin(d / maxd * MPi * 4)
  of 8: r += 0.1 * sin(d / maxd * MPi * 5)
  of 9:
    let t = sin(d / maxd * MPi)
    d -= 8 * t * t * t * t * t
  of 10:
    var t = sin(d / maxd * MPi)
    d -= 8 * t * t * t * t * t
    t = cos((d / maxd) * MPi / 2.0)
    r += 0.1 * t * t * t
  of 11: d *= 0.95 + (cos(r * 5.0 - MPi / 2.50) * 0.03)
  of 12: r += 0.04; d *= 0.96 + cos(d / maxd * MPi) * 0.05
  of 13:
    let t = cos(d / maxd * MPi)
    r += 0.07 * t
    d *= 0.98 + t * 0.10
  of 14: r += 0.1 - 0.2 * (d / maxd); d *= 0.96; xo = 8
  of 15: d = maxd * 0.15
  of 16: r = cos(r * 3)
  of 17: d *= (1 - (((d / maxd) - 0.35) * 0.5)); r += 0.1
  else: return false
  true

type Movement = ref object of Effect
  tab: seq[int32]
  tabW, tabH: int
  tabSubpixel: bool
  transEffect: int32
  code: string
  codeChanged: bool
  effect, blend, sourcemapped, rectangular, subpixel, wrap: int32

method desc(e: Movement): string = "Trans / Movement"
proc newMovement(): Effect = Movement(effect: 1, subpixel: 1, codeChanged: true)

method load(e: Movement, d: openArray[byte]) =
  var pos = 0
  if d.len - pos >= 4: (e.effect = getInt(d, pos); pos += 4)
  if e.effect == 32767:
    if pos + 6 <= d.len and cString(d, pos, 6) == "!rect ":
      pos += 6
      e.rectangular = 1
    if pos < d.len and d[pos] == 1:
      inc pos
      let l = int(getInt(d, pos))
      pos += 4
      if l > 0 and d.len - pos >= l:
        e.code = cString(d, pos, l)
        pos += l
      else: e.code = ""
    elif d.len - pos >= 256:
      let l = 256 - (if e.rectangular != 0: 6 else: 0)
      e.code = cString(d, pos, l)
      pos += l
  if d.len - pos >= 4: (e.blend = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.sourcemapped = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.rectangular = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.subpixel = getInt(d, pos); pos += 4)
  else: e.subpixel = 0
  if d.len - pos >= 4: (e.wrap = getInt(d, pos); pos += 4)
  else: e.wrap = 0
  if e.effect == 0 and d.len - pos >= 4: (e.effect = getInt(d, pos); pos += 4)
  if (e.effect != 32767 and e.effect > RefMax) or e.effect < 0: e.effect = 0
  e.codeChanged = true

proc entry(ow0, oh0: int, tmp1, tmp2: float64, w, h: int, wrap, sub: bool): int32 =
  ## A table entry from the source point: offset, and 5-bit fractions when sub.
  var ow = ow0
  var oh = oh0
  if sub:
    var xpartial = ftol(32.0 * (tmp2 - ow.float64))
    var ypartial = ftol(32.0 * (tmp1 - oh.float64))
    if wrap:
      ow = ow mod (w - 1)
      oh = oh mod (h - 1)
      if ow < 0: ow += w - 1
      if oh < 0: oh += h - 1
    else:
      if ow < 0: (xpartial = 0; ow = 0)
      if ow >= w - 1: (xpartial = 31; ow = w - 2)
      if oh < 0: (ypartial = 0; oh = 0)
      if oh >= h - 1: (ypartial = 31; oh = h - 2)
    # 32-bit, as C had it: a negative fraction's bits spill over the others.
    cast[int32](cast[uint32](int32(ow + oh * w)) or (cast[uint32](int32(ypartial)) shl 22) or
                (cast[uint32](int32(xpartial)) shl 27))
  else:
    if wrap:
      ow = ow mod w
      oh = oh mod h
      if ow < 0: ow += w
      if oh < 0: oh += h
    else:
      if ow < 0: ow = 0
      if ow >= w: ow = w - 1
      if oh < 0: oh = 0
      if oh >= h: oh = h - 1
    int32(ow + oh * w)

proc buildTab(e: Movement, vis: var VisData, w, h: int) =
  e.tab = newSeq[int32](w * h)
  e.tabW = w
  e.tabH = h
  e.transEffect = e.effect
  let te = int(e.transEffect)
  e.tabSubpixel = e.subpixel != 0 and w * h < (1 shl 22) and
    ((te >= RefMin and te <= RefMax and te != 1 and te != 2 and te != 7) or te == 32767)
  let wrap = e.wrap != 0
  var p = 0
  if te == 1:
    for i in 0 ..< w * h:
      let r = p + (crand() mod 3) - 1 + ((crand() mod 3) - 1) * w
      inc p
      e.tab[i] = int32(min(w * h - 1, max(r, 0)))
  elif te == 2:
    var i = 0
    for y in 0 ..< h:
      var lp = w div 64
      for x in 0 ..< w:
        e.tab[i] = int32(p + lp)
        inc i
        inc lp
        if lp >= w: lp -= w
      p += w
  elif te == 7:
    var i = 0
    for y in 0 ..< h:
      for x in 0 ..< w:
        if (x and 2) != 0 or (y and 2) != 0: e.tab[i] = int32(x + y * w)
        else:
          let xp = w div 2 + (((x and not 1) - w div 2) * 7) div 8
          let yp = h div 2 + (((y and not 1) - h div 2) * 7) div 8
          e.tab[i] = int32(xp + yp * w)
        inc i
  elif te >= RefMin and te <= RefMax and not usesEval(te):
    let maxd = sqrt(float64((w * w + h * h)) / 4.0)
    var dummyR, dummyD: float64
    var xo0, yo0: int
    if radial(te, dummyR, dummyD, 1.0, xo0, yo0):
      var i = 0
      for y in 0 ..< h:
        for x in 0 ..< w:
          let xd = float64(x - w div 2)
          let yd = float64(y - h div 2)
          var d = sqrt(xd * xd + yd * yd)
          var r = arctan2(yd, xd)
          var xo, yo: int
          discard radial(te, r, d, maxd, xo, yo)
          let tmp1 = (float64(h div 2) + sin(r) * d + 0.5) + float64(yo * h) * (1.0 / 256.0)
          let tmp2 = (float64(w div 2) + cos(r) * d + 0.5) + float64(xo * w) * (1.0 / 256.0)
          e.tab[i] = entry(ftol(tmp2), ftol(tmp1), tmp1, tmp2, w, h, wrap, e.tabSubpixel)
          inc i
  elif te == 32767 or usesEval(te):
    let vm = newEelVm()
    let maxd = sqrt(float64(w * w + h * h)) / 2.0
    let divmaxd = 1.0 / maxd
    let vd = vm.reg("d")
    let vr = vm.reg("r")
    let px = vm.reg("x")
    let py = vm.reg("y")
    let pw = vm.reg("sw")
    let ph = vm.reg("sh")
    let isRect = if te == 32767: e.rectangular != 0 else: moveDescs[te].usesRect
    pw[] = w.float64
    ph[] = h.float64
    let code = vm.compile(if te == 32767: e.code else: moveDescs[te].evalCode)
    if code != nil:
      let w2 = float64(w div 2)
      let h2 = float64(h div 2)
      let xsc = 1.0 / w2
      let ysc = 1.0 / h2
      var i = 0
      for y in 0 ..< h:
        for x in 0 ..< w:
          let xd = x.float64 - w2
          let yd = y.float64 - h2
          px[] = xd * xsc
          py[] = yd * ysc
          vd[] = sqrt(xd * xd + yd * yd) * divmaxd
          vr[] = arctan2(yd, xd) + MPi * 0.5
          code.run()
          var tmp1, tmp2: float64
          if not isRect:
            vd[] *= maxd
            vr[] -= MPi / 2.0
            tmp1 = float64(h div 2) + sin(vr[]) * vd[]
            tmp2 = float64(w div 2) + cos(vr[]) * vd[]
          else:
            tmp1 = (py[] + 1.0) * h2
            tmp2 = (px[] + 1.0) * w2
          if e.tabSubpixel:
            e.tab[i] = entry(ftol(tmp2), ftol(tmp1), tmp1, tmp2, w, h, wrap, true)
          else:
            e.tab[i] = entry(ftol(tmp2 + 0.5), ftol(tmp1 + 0.5), tmp1, tmp2, w, h, wrap, false)
          inc i
    else:
      e.tabSubpixel = false
      for i in 0 ..< w * h: e.tab[i] = int32(i)
  e.codeChanged = false

method render(e: Movement, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if e.effect == 0: return 0
  if e.tab.len == 0 or e.tabW != w or e.tabH != h or e.effect != e.transEffect or e.codeChanged:
    e.buildTab(vis, w, h)
  if (isBeat and BeatPreinit) != 0: return 0
  if (e.sourcemapped and 2) != 0 and isBeat != 0: e.sourcemapped = e.sourcemapped xor 1
  let n = w * h
  if (e.sourcemapped and 1) != 0:
    if e.blend == 0: clearPixels(fbout, n)
    else: copyPixels(fbout, fb, n)
  let tab = e.tab
  if e.tab.len == 0: return 0
  # A table entry that's out of range (a fuzzy edge) is clamped, never read past.
  if (e.sourcemapped and 1) != 0:
    let mask = if e.tabSubpixel: OffsetMask else: -1
    for i in 0 ..< n:
      let o = int(tab[i]) and mask
      if o >= 0 and o < n: fbout[o] = blendMax(fb[i], fbout[o])
    if e.blend != 0:
      for i in 0 ..< n: fbout[i] = blendAvg(fbout[i], fb[i])
  elif e.tabSubpixel:
    for i in 0 ..< n:
      let t = cast[uint32](tab[i])
      let off = int(t and OffsetMask)
      let px = blend4(fb, off, w, int((t shr 24) and (31 shl 3)), int((t shr 19) and (31 shl 3)))
      fbout[i] = if e.blend != 0: blendAvg(fb[i], px) else: px
  elif e.blend != 0:
    for i in 0 ..< n: fbout[i] = blendAvg(fb[i], fb[int(tab[i])])
  else:
    for i in 0 ..< n: fbout[i] = fb[int(tab[i])]
  1

# --- Dynamic Movement ---------------------------------------------------------------------------

type DynMovement = ref object of Effect
  code: array[4, string]   ## point, frame, beat, init
  compiled: array[4, EelCode]
  needRecompile, inited: bool
  vD, vB, vR, vX, vY, vW, vH, vAlpha: ptr float64
  lastW, lastH, lastXres, lastYres: int
  wmul: seq[int]
  tab: seq[int32]          ## the grid, then the interpolation rows, as one block (C's m_tab)
  subpixel, rectcoords, xres, yres, blend, wrap, buffern, nomove: int32

method desc(e: DynMovement): string = "Trans / Dynamic Movement"

proc newDynMovement(): Effect =
  DynMovement(needRecompile: true, xres: 16, yres: 16, subpixel: 1, vm: newEelVm())

method load(e: DynMovement, d: openArray[byte]) =
  var pos = 0
  if d.len > 0 and d[0] == 1:
    pos = 1
    for k in 0 .. 3: e.code[k] = loadString(d, pos)
  elif d.len - pos >= 1024:
    for k in 0 .. 3: e.code[k] = cString(d, pos + k * 256, 256)
    pos += 1024
  if d.len - pos >= 4: (e.subpixel = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.rectcoords = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.xres = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.yres = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.blend = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.wrap = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.buffern = getInt(d, pos); pos += 4)
  else: e.buffern = 0
  if d.len - pos >= 4: (e.nomove = getInt(d, pos); pos += 4)
  else: e.nomove = 0
  e.needRecompile = true

method render(e: DynMovement, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  let subpixel = e.subpixel != 0
  let rect = e.rectcoords != 0
  let blend = e.blend != 0
  let wrap = e.wrap != 0
  let nomove = e.nomove != 0
  var wAdj = int32((w - 2) shl 16)
  var hAdj = int32((h - 2) shl 16)
  let xres = clamp(int(e.xres) + 1, 2, 256)
  let yres = clamp(int(e.yres) + 1, 2, 256)
  if e.lastH != h or e.lastW != w or e.tab.len == 0 or e.lastXres != xres or e.lastYres != yres:
    e.lastXres = xres
    e.lastYres = yres
    e.lastW = w
    e.lastH = h
    e.wmul = newSeq[int](h)
    for y in 0 ..< h: e.wmul[y] = y * w
    e.tab = newSeq[int32](xres * yres * 3 + (xres * 6 + 6))
  if not subpixel:
    wAdj = int32((w - 1) shl 16)
    hAdj = int32((h - 1) shl 16)
  if e.needRecompile:
    if e.vB == nil or resetVarsOnRecompile:
      e.vm.resetVars()
      e.vD = e.vm.reg("d"); e.vB = e.vm.reg("b"); e.vR = e.vm.reg("r")
      e.vX = e.vm.reg("x"); e.vY = e.vm.reg("y"); e.vW = e.vm.reg("w")
      e.vH = e.vm.reg("h"); e.vAlpha = e.vm.reg("alpha")
      e.inited = false
    e.needRecompile = false
    for k in 0 .. 3: e.compiled[k] = e.vm.compile(e.code[k])
  if (isBeat and BeatPreinit) != 0: return 0
  let fbin = if e.buffern == 0: fb else: getGlobalBuffer(w, h, int(e.buffern) - 1, false)
  if fbin == nil: return 0
  e.vW[] = w.float64
  e.vH[] = h.float64
  e.vB[] = (if isBeat != 0: 1.0 else: 0.0)
  e.vAlpha[] = 0.5
  if e.compiled[3] != nil and not e.inited:
    e.compiled[3].run()
    e.inited = true
  e.compiled[1].run()
  if isBeat != 0: e.compiled[2].run()
  block grid:
    var t = 0
    let xsc = 2.0 / w.float64
    let ysc = 2.0 / h.float64
    let dw2 = w.float64 * 32768.0
    let dh2 = h.float64 * 32768.0
    var maxd = sqrt(float64(w * w + h * h)) * 0.5
    let divmaxd = 1.0 / maxd
    maxd *= 65536.0
    var ycPos = 0'i32
    let xcDpos = int32((w shl 16) div (xres - 1))
    let ycDpos = int32((h shl 16) div (yres - 1))
    for y in 0 ..< yres:
      var xcPos = 0'i32
      for x in 0 ..< xres:
        let xd = (xcPos.float64 - dw2) * (1.0 / 65536.0)
        let yd = (ycPos.float64 - dh2) * (1.0 / 65536.0)
        xcPos = xcPos +% (xcDpos)
        e.vX[] = xd * xsc
        e.vY[] = yd * ysc
        e.vD[] = sqrt(xd * xd + yd * yd) * divmaxd
        e.vR[] = arctan2(yd, xd) + MPi * 0.5
        e.compiled[0].run()
        var tmp1, tmp2: int32
        if not rect:
          e.vD[] *= maxd
          e.vR[] -= MPi * 0.5
          tmp1 = int32(ftol(dw2 + cos(e.vR[]) * e.vD[]))
          tmp2 = int32(ftol(dh2 + sin(e.vR[]) * e.vD[]))
        else:
          tmp1 = int32(ftol((e.vX[] + 1.0) * dw2))
          tmp2 = int32(ftol((e.vY[] + 1.0) * dh2))
        if not wrap:
          if tmp1 < 0: tmp1 = 0
          if tmp1 > wAdj: tmp1 = wAdj
          if tmp2 < 0: tmp2 = 0
          if tmp2 > hAdj: tmp2 = hAdj
        e.tab[t] = tmp1
        e.tab[t + 1] = tmp2
        var va = e.vAlpha[]
        if va < 0.0: va = 0.0
        elif va > 1.0: va = 1.0
        e.tab[t + 2] = int32(ftol(va * 255.0 * 65536.0))
        t += 3
      ycPos = ycPos +% (ycDpos)

  # Fixed point interpolation of the grid over the frame.
  let tab = cast[ptr UncheckedArray[int32]](e.tab[0].addr)
  let interp = xres * yres * 3
  var rd = 0
  var inp = 0       ## fbin
  var bi = 0        ## framebuffer (blending in)
  var outp = 0      ## fbout
  let xcDpos = int32((w shl 16) div (xres - 1))
  let ycDpos = int32((h shl 16) div (yres - 1))
  var ycPos = 0'i32
  var lypos = 0'i32
  var yl = h
  let n = w * h
  template inPx(xp, yp: int32): int = int(xp shr 16) + e.wmul[clamp(int(yp shr 16), 0, h - 1)]
  block frame:
    while yl > 0:
      ycPos = ycPos +% (ycDpos)
      var yseek = (ycPos shr 16) - lypos
      if yseek == 0: break frame
      lypos = ycPos shr 16
      let xr3 = xres * 3
      var st = interp
      for l in 0 ..< xres:
        let t1 = tab[rd]
        let t2 = tab[rd + 1]
        let t3 = tab[rd + 2]
        tab[st] = t1
        tab[st + 1] = t2
        tab[st + 2] = (tab[rd + xr3] -% t1) div yseek
        tab[st + 3] = (tab[rd + xr3 + 1] -% t2) div yseek
        tab[st + 4] = t3
        tab[st + 5] = (tab[rd + xr3 + 2] -% t3) div yseek
        rd += 3
        st += 6
      if yseek > yl.int32: yseek = int32(yl)
      yl -= int(yseek)
      while yseek > 0:
        dec yseek
        var sk = interp
        var l = w
        var lpos = 0'i32
        var xcPos = 0'i32
        while l > 0:
          xcPos = xcPos +% (xcDpos)
          var seek = (xcPos shr 16) - lpos
          if seek == 0: break frame
          lpos = xcPos shr 16
          var xp = tab[sk]
          var yp = tab[sk + 1]
          var ap = tab[sk + 4]
          var da = (tab[sk + 10] -% ap) div seek
          var dx = (tab[sk + 6] -% xp) div seek
          var dy = (tab[sk + 7] -% yp) div seek
          tab[sk] = tab[sk] +% tab[sk + 2]
          tab[sk + 1] = tab[sk + 1] +% tab[sk + 3]
          tab[sk + 4] = tab[sk + 4] +% tab[sk + 5]
          sk += 6
          if seek > l.int32: seek = int32(l)
          l -= int(seek)
          if seek <= 0: continue
          if nomove:
            if fbin != fb:
              while seek > 0:
                dec seek
                if bi < n: fb[bi] = blendAdj(fbin[inp], fb[bi], int(ap shr 16))
                inc inp
                ap = ap +% (da)
                inc bi
            else:
              while seek > 0:
                dec seek
                if bi < n: fb[bi] = blendAdj(0, fb[bi], int(ap shr 16))
                ap = ap +% (da)
                inc bi
            continue
          template body() =
            var px: uint32
            if subpixel: px = blend4_16(fbin, inPx(xp, yp), w, int(xp), int(yp))
            else: px = fbin[min(inPx(xp, yp), n - 1)]
            if blend:
              px = blendAdj(px, fb[min(bi, n - 1)], int(ap shr 16))
              ap = ap +% (da)
              inc bi
            if outp < n: fbout[outp] = px
            inc outp
          if not wrap:
            if xp < 0: xp = 0
            elif xp >= wAdj: xp = wAdj - 1
            if yp < 0: yp = 0
            elif yp >= hAdj: yp = hAdj - 1
            while seek > 0:
              dec seek
              if xp < 0: xp = 0
              elif xp >= wAdj: xp = wAdj - 1
              if yp < 0: yp = 0
              elif yp >= hAdj: yp = hAdj - 1
              body()
              xp = xp +% (dx)
              yp = yp +% (dy)
          else:
            xp = xp mod wAdj
            yp = yp mod hAdj
            if xp < 0: xp += wAdj
            if yp < 0: yp += hAdj
            if dx <= -wAdj: dx = -wAdj + 1
            elif dx >= wAdj: dx = wAdj - 1
            if dy <= -hAdj: dy = -hAdj + 1
            elif dy >= hAdj: dy = hAdj - 1
            while seek > 0:
              dec seek
              if xp < 0: xp += wAdj
              elif xp >= wAdj: xp -= wAdj
              if yp < 0: yp += hAdj
              elif yp >= hAdj: yp -= hAdj
              body()
              xp = xp +% (dx)
              yp = yp +% (dy)
        tab[sk] = tab[sk] +% tab[sk + 2]
        tab[sk + 1] = tab[sk + 1] +% tab[sk + 3]
        tab[sk + 4] = tab[sk + 4] +% tab[sk + 5]
  if nomove: 0 else: 1

proc registerTrans1*() =
  registerEffect(3, newFadeout)
  registerEffect(6, newBlur)
  registerEffect(15, newMovement)
  registerEffect(43, newDynMovement)
