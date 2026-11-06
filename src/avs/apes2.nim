# Color Map and Multi Filter follow grandchild's fork of AVS (https://github.com/grandchild/vis_avs),
# Copyright 2005 Nullsoft, Inc. and its contributors; FyrewurX is our own.
# BSD license: assets/licenses/AVS-Nullsoft-BSD.txt

## Third-party APEs that late presets lean on, written from their saved
## configs and the behaviour grandchild's BSD port (vis_avs) gives them:
## Color Map and Jheriko's Multi Filter. And FyrewurX, whose source was never released: our own fireworks
## drawn from its saved config (enabled, color) and how its presets use it.

import std/math
import core, list

# --- Color Map ---------------------------------------------------------------------

const
  CmMaps = 8
  CmMapHeader = 3 * 4 + 48

type
  CmColor = tuple[pos: int, color: uint32]

  ColorMap = ref object of Effect
    key, blendmode, cycleMode: int
    adjAlpha: int
    dontSkipFast: bool
    cycleSpeed: int
    enabled: array[CmMaps, bool]
    colors: array[CmMaps, seq[CmColor]]
    baked: array[CmMaps, array[256, uint32]]
    tween: array[256, uint32]
    current, next: int
    step: int

method desc(e: ColorMap): string = "Trans / Color Map"

proc lerp(a, b: uint32, t, n: int): uint32 =
  ## a to b, t of n.
  result = 0
  for s in [0'u32, 8, 16]:
    let ca = int((a shr s) and 0xff)
    let cb = int((b shr s) and 0xff)
    result = result or (uint32(ca + (cb - ca) * t div n) shl s)

proc bake(e: ColorMap, m: int) =
  var cs = e.colors[m]
  if cs.len == 0: return
  for i in 1 ..< cs.len:  # sorted by position, stably
    var j = i
    while j > 0 and cs[j - 1].pos > cs[j].pos:
      swap(cs[j - 1], cs[j])
      dec j
  var i = 0
  while i < min(cs[0].pos, 256):
    e.baked[m][i] = cs[0].color
    inc i
  for k in 0 ..< cs.len - 1:
    let (a, b) = (cs[k], cs[k + 1])
    while i < min(b.pos, 256):
      e.baked[m][i] = lerp(a.color, b.color, i - a.pos, max(b.pos - a.pos, 1))
      inc i
  while i < 256:
    e.baked[m][i] = cs[^1].color
    inc i

proc newColorMap(): Effect =
  let e = ColorMap(cycleSpeed: 11, step: 256)
  for m in 0 ..< CmMaps: e.colors[m] = @[(0, 0x000000'u32), (255, 0xffffff'u32)]
  e.enabled[0] = true
  for m in 0 ..< CmMaps: e.bake(m)
  e.tween = e.baked[0]
  e

method load(e: ColorMap, d: openArray[byte]) =
  if d.len < 16: return
  var pos = 0
  e.key = int(getInt(d, pos)); pos += 4
  e.blendmode = int(getInt(d, pos)); pos += 4
  e.cycleMode = int(getInt(d, pos)); pos += 4
  e.adjAlpha = int(d[pos]); pos += 2  # and an unused byte
  e.dontSkipFast = d[pos] != 0; inc pos
  e.cycleSpeed = int(d[pos]); inc pos
  var lengths: array[CmMaps, int]
  for m in 0 ..< CmMaps:
    if d.len - pos >= CmMapHeader:
      e.enabled[m] = getInt(d, pos) != 0
      lengths[m] = int(getInt(d, pos + 4))
    pos += CmMapHeader
  var first = -1
  for m in 0 ..< CmMaps:
    var cs: seq[CmColor]
    var ok = true
    for i in 0 ..< max(lengths[m], 0):
      if d.len - pos < 12:
        ok = false
        break
      cs.add (int(getInt(d, pos)), cast[uint32](getInt(d, pos + 4)) and 0xffffff)
      pos += 12
    if cs.len > 0: e.colors[m] = cs
    e.bake(m)
    if not ok: break
    if e.enabled[m] and first < 0: first = m
  e.current = max(first, 0)
  e.next = e.current
  e.tween = e.baked[e.current]

proc keyOf(e: ColorMap, c: uint32): int {.inline.} =
  let r = int((c shr 16) and 0xff)
  let g = int((c shr 8) and 0xff)
  let b = int(c and 0xff)
  case e.key
  of 0: r
  of 1: g
  of 2: b
  of 3: min((r + g + b) div 2, 255)
  of 4: max(max(r, g), b)
  else: (r + g + b) div 3

method render(e: ColorMap, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if (isBeat and BeatPreinit) != 0: return 0
  e.next = e.next mod CmMaps
  var map: ptr array[256, uint32]
  if e.cycleMode == 0:
    e.step = 0
    map = addr e.baked[e.current]
  else:
    e.step = min(e.step + e.cycleSpeed, 256)
    if isBeat != 0 and (not e.dontSkipFast or e.step == 256):
      var any = false
      for m in 0 ..< CmMaps: any = any or e.enabled[m]
      if any:
        while true:
          e.next = if e.cycleMode == 1: crand() mod CmMaps else: (e.next + 1) mod CmMaps
          if e.enabled[e.next]: break
      e.step = 0
    if e.step == 256: e.current = e.next
    if e.step == 0 or e.step == 256 or e.current == e.next:
      e.tween = e.baked[e.current]
    else:
      for i in 0 .. 255: e.tween[i] = lerp(e.baked[e.current][i], e.baked[e.next][i], e.step, 256)
    map = addr e.tween
  let n = w * h
  for i in 0 ..< n:
    let p = fb[i]
    let c = map[e.keyOf(p)]
    fb[i] = case e.blendmode
      of 1: blendAdd(c, p) and 0xffffff
      of 2: blendMax(c, p)
      of 3: blendMin(c, p)
      of 4: blendAvg(c, p) and 0xffffff
      of 5: blendSub(p, c) and 0xffffff
      of 6: blendSub(c, p) and 0xffffff
      of 7: blendMul(c, p)
      of 8: (c xor p) and 0xffffff
      of 9: blendAdjNoMmx(c, p, e.adjAlpha)
      else: c
  0

# --- FyrewurX ------------------------------------------------------------------------
# Nullsoft's FunkyFX FyrewurX (fyrewurx.ape, AVS a35) shipped as a binary only, so this
# is a look-alike, not a port: beats launch rockets from the bottom that burst at their
# peak into a shell of sparks, falling and fading. Everything is added onto the frame
# in the config's color whatever the line blend mode: presets stack copies in dark
# colors (Tribute to Yathosho's 0x010203 lifts pixels past a Color Clip into Water).
# Distances are fractions of the frame's height, per frame, as AVS's effects step.

const
  FwMaxRockets = 4
  FwMaxSparks = 3000
  FwGravity = 0.0006       ## rockets, of the height per frame per frame
  FwSparkGravity = 0.00022
  FwDrag = 0.965

type
  FwParticle = object
    x, y, vx, vy: float     ## x in widths, y in heights; velocities in heights
    px, py: float           ## last frame's spot, the streak's tail
    life, maxLife: int
    bright: float

  FyrewurX = ref object of Effect
    enabled: bool
    color: uint32
    rockets, sparks: seq[FwParticle]

method desc(e: FyrewurX): string = "Render / FyrewurX"

proc newFyrewurX(): Effect = FyrewurX(enabled: true, color: 0x285080)

method load(e: FyrewurX, d: openArray[byte]) =
  if d.len >= 4: e.enabled = getInt(d, 0) != 0
  if d.len >= 8: e.color = cast[uint32](getInt(d, 4)) and 0xffffff

proc frand(): float {.inline.} = crand().float / 32767.0

proc scaled(c: uint32, k: float): uint32 {.inline.} =
  let k = int(clamp(k, 0.0, 1.0) * 256)
  ((((c shr 16) and 0xff) * k.uint32 shr 8) shl 16) or
    ((((c shr 8) and 0xff) * k.uint32 shr 8) shl 8) or ((c and 0xff) * k.uint32 shr 8)

proc streak(fb: Pixels, w, h: int, x0, y0, x1, y1: float, c: uint32) =
  ## Adds c along x0,y0 to x1,y1 (pixels), a dot when they meet.
  if c == 0: return
  let n = max(1, int(max(abs(x1 - x0), abs(y1 - y0))))
  for i in 0 .. n:
    let t = i / n
    let x = int(x0 + (x1 - x0) * t)
    let y = int(y0 + (y1 - y0) * t)
    if x >= 0 and y >= 0 and x < w and y < h:
      let p = y * w + x
      fb[p] = blendAdd(fb[p], c) and 0xffffff

proc burst(e: FyrewurX, r: FwParticle) =
  let n = 50 + crand() mod 40
  let speed = 0.012 + 0.008 * frand()
  for i in 0 ..< n:
    if e.sparks.len >= FwMaxSparks: break
    let a = frand() * 2 * PI
    let s = speed * (0.35 + 0.65 * sqrt(frand()))
    let life = 35 + crand() mod 35
    e.sparks.add FwParticle(x: r.x, y: r.y, px: r.x, py: r.y,
                            vx: cos(a) * s + r.vx * 0.3, vy: sin(a) * s + r.vy * 0.3,
                            life: life, maxLife: life, bright: 0.7 + 0.3 * frand())

method render(e: FyrewurX, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if (isBeat and BeatPreinit) != 0 or not e.enabled: return 0
  let aspect = h / w  # heights to widths, for x
  if isBeat != 0 and e.rockets.len < FwMaxRockets:
    let x = 0.15 + 0.7 * frand()
    let vy = -(0.022 + 0.008 * frand())  # peaks 40..75% of the way up
    e.rockets.add FwParticle(x: x, y: 1.0, px: x, py: 1.0,
                             vx: (frand() - 0.5) * 0.004, vy: vy, bright: 0.6)
  var i = 0
  while i < e.rockets.len:
    var r = e.rockets[i]
    r.px = r.x; r.py = r.y
    r.x += r.vx * aspect; r.y += r.vy
    r.vy += FwGravity
    streak(fb, w, h, r.px * w.float, r.py * h.float, r.x * w.float, r.y * h.float,
           scaled(e.color, r.bright))
    if r.vy >= -0.002:
      e.burst(r)
      e.rockets.del(i)
    else:
      e.rockets[i] = r
      inc i
  i = 0
  while i < e.sparks.len:
    var s = e.sparks[i]
    s.px = s.x; s.py = s.y
    s.x += s.vx * aspect; s.y += s.vy
    s.vx *= FwDrag; s.vy = s.vy * FwDrag + FwSparkGravity
    dec s.life
    let t = s.life / s.maxLife
    # A twinkle near the end, as embers do.
    let k = s.bright * t * (if t < 0.3 and crand() mod 3 == 0: 0.3 else: 1.0)
    streak(fb, w, h, s.px * w.float, s.py * h.float, s.x * w.float, s.y * h.float,
           scaled(e.color, k))
    if s.life <= 0 or s.y > 1.05:
      e.sparks.del(i)
    else:
      e.sparks[i] = s
      inc i
  0

# --- Multi Filter (Jheriko) ---------------------------------------------------------

type MultiFilter = ref object of Effect
  enabled: bool
  effect: int           ## 0..2 chrome, double, triple; 3 infinite root + border
  toggleOnBeat, toggled: bool

method desc(e: MultiFilter): string = "Trans / Multi Filter"
proc newMultiFilter(): Effect = MultiFilter(enabled: true)

method load(e: MultiFilter, d: openArray[byte]) =
  if d.len >= 4: e.enabled = getInt(d, 0) != 0
  if d.len >= 8:
    let m = getInt(d, 4)
    e.effect = if m in 0'i32 .. 3'i32: int(m) else: 0
  if d.len >= 12: e.toggleOnBeat = getInt(d, 8) != 0

proc chrome(c: uint32): uint32 {.inline.} =
  ## Every byte folded at the middle: 2c below 128, 510 - 2c from it (the APE's MMX
  ## worked on whole dwords).
  result = 0
  for s in [0'u32, 8, 16, 24]:
    let x = (c shr s) and 0xff
    result = result or ((if x < 128: x * 2 else: 510 - x * 2) shl s)

method render(e: MultiFilter, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if (isBeat and BeatPreinit) != 0 or not e.enabled: return 0
  if e.toggleOnBeat:
    if isBeat != 0: e.toggled = not e.toggled
    if not e.toggled: return 0
  let n = w * h
  case e.effect
  of 0, 1, 2:
    let times = e.effect + 1
    for i in 0 ..< n:
      var c = fb[i]
      for _ in 1 .. times: c = chrome(c)
      fb[i] = c
  of 3:
    # Anything not black turns white, as do the pixels above and left of it; the
    # APE's "small border convolution" only ever reached back.
    for y in 0 ..< h:
      for x in 0 ..< w:
        let p = x + y * w
        if (fb[p] and 0xffffff) != 0:
          fb[p] = 0xffffff
          if y > 0: fb[p - w] = 0xffffff
          if x > 0: fb[p - 1] = 0xffffff
        else:
          fb[p] = 0
  else: discard
  0

proc registerApes2*() =
  registerApe("Color Map", newColorMap)
  registerApe("FunkyFX FyrewurX v1", newFyrewurX)
  registerApe("Jheriko : MULTIFILTER", newMultiFilter)
