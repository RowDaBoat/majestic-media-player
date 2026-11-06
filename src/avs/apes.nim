## AVS 2.81d's built-in APEs: Channel Shift, Color Reduction, Multiplier,
## Video Delay, Multi Delay (r_chanshift.cpp, r_colorreduction.cpp,
## r_multiplier.cpp, r_videodelay.cpp, r_multidelay.cpp).

import std/times
import core, list

# --- Channel Shift ----------------------------------------------------------------

const
  IdcGbr = 1018'i32
  IdcBrg = 1019'i32
  IdcRbg = 1020'i32
  IdcBgr = 1021'i32
  IdcGrb = 1022'i32
  IdcRgb = 1183'i32

type ChannelShift = ref object of Effect
  mode, onbeat: int32

method desc(e: ChannelShift): string = "Trans / Channel Shift"
proc newChannelShift(): Effect = ChannelShift(mode: IdcRbg, onbeat: 1)

method load(e: ChannelShift, d: openArray[byte]) =
  csrand(uint32(epochTime().int64))  # it reseeded rand() with time(0) as it loaded
  if d.len <= 8:
    var b: array[8, byte]
    let cur = [e.mode, e.onbeat]
    copyMem(b[0].addr, cur[0].addr, 8)
    for i in 0 ..< d.len: b[i] = d[i]
    e.mode = getInt(b, 0)
    e.onbeat = getInt(b, 4)

method render(e: ChannelShift, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if (isBeat and BeatPreinit) != 0: return 0
  const modes = [IdcRgb, IdcRbg, IdcGbr, IdcGrb, IdcBrg, IdcBgr]
  if isBeat != 0 and e.onbeat != 0: e.mode = modes[crand() mod 6]
  let n = (w * h) div 4 * 4  # the asm went four at a time
  template each(body: untyped) =
    for i in 0 ..< n:
      let v {.inject.} = fb[i]
      fb[i] = body
  case e.mode
  of IdcRbg: each((v and 0xffff0000'u32) or ((v and 0xff) shl 8) or ((v shr 8) and 0xff))
  of IdcBrg: each(((v and 0xff) shl 16) or (((v shr 16) and 0xff) shl 8) or ((v shr 8) and 0xff))
  of IdcBgr: each(((v and 0xff) shl 16) or (v and 0xff00) or ((v shr 16) and 0xff))
  of IdcGbr: each((((v shr 16) and 0xff) shl 24) or (((v shr 8) and 0xff) shl 16) or
                  ((v and 0xff) shl 8) or ((v shr 16) and 0xff))
  of IdcGrb: each((((v shr 8) and 0xff) shl 16) or (((v shr 16) and 0xff) shl 8) or (v and 0xff))
  else: discard
  0

# --- Color Reduction ---------------------------------------------------------------

type ColorReduction = ref object of Effect
  levels: int32

method desc(e: ColorReduction): string = "Trans / Color Reduction"
proc newColorReduction(): Effect = ColorReduction(levels: 7)

method load(e: ColorReduction, d: openArray[byte]) =
  # A file name (MAX_PATH) and the levels; any other size zeroes both.
  e.levels = if d.len == 264: getInt(d, 260) else: 0

method render(e: ColorReduction, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if (isBeat and BeatPreinit) != 0: return 0
  var a = 8 - int(e.levels)
  var b = 0xFF'u32
  while a > 0:
    b = (b shl 1) and 0xFF
    dec a
  b = b or (b shl 16) or (b shl 8)
  # The asm stopped before the first four pixels.
  var c = w * h
  while true:
    c -= 4
    if c <= 0: break
    for k in 0 .. 3: fb[c + k] = fb[c + k] and b
  0

# --- Multiplier ---------------------------------------------------------------------

type Multiplier = ref object of Effect
  ml: int32

method desc(e: Multiplier): string = "Trans / Multiplier"
proc newMultiplier(): Effect = Multiplier(ml: 3)

method load(e: Multiplier, d: openArray[byte]) =
  if d.len == 4: e.ml = getInt(d, 0)

method render(e: Multiplier, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if (isBeat and BeatPreinit) != 0: return 0
  let n = w * h
  template bytes(f: untyped) =
    for i in 0 ..< (n div 2) * 2:
      let v = fb[i]
      var r = 0'u32
      for s in [0'u32, 8, 16, 24]:
        let x {.inject.} = (v shr s) and 0xff
        r = r or (uint32(f) shl s)
      fb[i] = r
  case e.ml
  of 0:  # infinite root: anything not black turns white (the first pixel is skipped)
    for i in countdown(n - 1, 1): fb[i] = if fb[i] != 0: 0xFFFFFF'u32 else: 0
  of 7:  # infinite square: only white stays
    for i in countdown(n - 1, 1): fb[i] = if fb[i] == 0xFFFFFF'u32: 0xFFFFFF'u32 else: 0
  of 1: bytes(min(x * 8, 255'u32))
  of 2: bytes(min(x * 4, 255'u32))
  of 3: bytes(min(x * 2, 255'u32))
  of 4: bytes(x shr 1)
  of 5: bytes(x shr 2)
  of 6: bytes(x shr 3)
  else: discard
  0

# --- delay rings -----------------------------------------------------------------------

type Ring = object
  ## A VirtualAlloc'd buffer as the delays used it, in pixels.
  data: seq[uint32]
  size: int            ## buffersize

proc move(r: var Ring, dst, src, n: int) =
  if n > 0: moveMem(r.data[dst].addr, r.data[src].addr, n * 4)

# --- Video Delay ---------------------------------------------------------------------------

type VideoDelay = ref object of Effect
  enabled, usebeats: bool
  delay: int
  ring: Ring
  inoutpos: int
  framessincebeat, framedelay: int
  framemem, oldframemem: int
  vbs, oldvbs: int

method desc(e: VideoDelay): string = "Trans / Video Delay"
proc newVideoDelay(): Effect =
  VideoDelay(enabled: true, delay: 10, framedelay: 10, ring: Ring(data: newSeq[uint32](1), size: 1))

method load(e: VideoDelay, d: openArray[byte]) =
  var pos = 0
  if d.len - pos >= 4: (e.enabled = getInt(d, pos) == 1; pos += 4)
  if d.len - pos >= 4: (e.usebeats = getInt(d, pos) == 1; pos += 4)
  if d.len - pos >= 4:
    e.delay = int(getInt(d, pos))
    if e.usebeats:
      if e.delay > 16: e.delay = 16
    elif e.delay > 200: e.delay = 200
    pos += 4
  # framedelay stays as it was: only the config dialog set it from delay.

proc realloc(r: var Ring, size: int) =
  r.size = max(size, 1)
  r.data = newSeq[uint32](r.size)

method render(e: VideoDelay, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if (isBeat and BeatPreinit) != 0: return 0
  e.framemem = w * h
  if e.usebeats:
    if isBeat != 0:
      e.framedelay = e.framessincebeat * e.delay
      if e.framedelay > 400: e.framedelay = 400
      e.framessincebeat = 0
    inc e.framessincebeat
  if not e.enabled or e.framedelay == 0: return 0
  let fm = e.framemem
  e.vbs = e.framedelay * fm
  if fm == e.oldframemem:
    if e.vbs != e.oldvbs:
      if e.vbs > e.oldvbs:
        if e.vbs > e.ring.size:
          if e.usebeats: e.ring.realloc(min(2 * e.vbs, fm * 400))
          else: e.ring.realloc(e.vbs)
          e.inoutpos = 0
        else:
          let size = e.oldvbs - e.inoutpos
          let l = e.vbs
          let d = l - size
          e.ring.move(d, e.inoutpos, size)
          var p = e.inoutpos
          while p < d:
            e.ring.move(p, d, fm)
            p += fm
      else:
        let preseg = e.inoutpos + fm
        if preseg > e.vbs:
          e.ring.move(0, preseg - e.vbs, e.vbs)
          e.inoutpos = e.vbs - fm
        elif preseg < e.vbs:
          e.ring.move(e.inoutpos + fm, e.oldvbs + preseg - e.vbs, e.vbs - preseg)
      e.oldvbs = e.vbs
  else:
    if e.usebeats: e.ring.realloc(min(2 * e.vbs, fm * 400))
    else: e.ring.realloc(e.vbs)
    e.inoutpos = 0
    e.oldvbs = e.vbs
  e.oldframemem = fm
  if e.inoutpos + fm > e.ring.data.len: e.inoutpos = 0
  copyMem(fbout[0].addr, e.ring.data[e.inoutpos].addr, fm * 4)
  copyMem(e.ring.data[e.inoutpos].addr, fb[0].addr, fm * 4)
  e.inoutpos += fm
  if e.inoutpos >= e.vbs: e.inoutpos = 0
  1

# --- Multi Delay -------------------------------------------------------------------------------

type MultiDelay = ref object of Effect
  mode, activebuffer: int32
  creationid: int

var
  mdUsebeats {.threadvar.}: array[6, bool]
  mdDelay {.threadvar.}: array[6, int]
  mdRing {.threadvar.}: array[6, Ring]
  mdIn {.threadvar.}, mdOut {.threadvar.}: array[6, int]
  mdFramedelay {.threadvar.}: array[6, int]
  mdVbs {.threadvar.}, mdOldVbs {.threadvar.}: array[6, int]
  mdInstances {.threadvar.}: int
  mdSinceBeat {.threadvar.}, mdPerBeat {.threadvar.}: int
  mdFramemem {.threadvar.}, mdOldFramemem {.threadvar.}: int
  mdRenderId {.threadvar.}: int

proc resetMultiDelay*() =
  ## Every Multi Delay goes with the preset that had them.
  mdInstances = 0

method desc(e: MultiDelay): string = "Trans / Multi Delay"

proc newMultiDelay(): Effect =
  inc mdInstances
  result = MultiDelay(creationid: mdInstances)
  if mdInstances == 1:
    for i in 0 ..< 6:
      mdRenderId = 0
      mdSinceBeat = 0
      mdPerBeat = 0
      mdFramemem = 1
      mdOldFramemem = 1
      mdUsebeats[i] = false
      mdDelay[i] = 0
      mdFramedelay[i] = 0
      mdRing[i] = Ring(data: newSeq[uint32](1), size: 1)
      mdIn[i] = 0
      mdOut[i] = 0
      mdVbs[i] = 0
      mdOldVbs[i] = 0

method load(e: MultiDelay, d: openArray[byte]) =
  var pos = 0
  if d.len - pos >= 4: (e.mode = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.activebuffer = getInt(d, pos); pos += 4)
  if d.len - pos >= 4:
    for i in 0 ..< 6:
      if d.len - pos >= 4: (mdUsebeats[i] = getInt(d, pos) == 1; pos += 4)
      if d.len - pos >= 4:
        mdDelay[i] = int(getInt(d, pos))
        mdFramedelay[i] = (if mdUsebeats[i]: mdPerBeat else: mdDelay[i]) + 1
        pos += 4

method render(e: MultiDelay, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if (isBeat and BeatPreinit) != 0: return 0
  if mdRenderId == mdInstances: mdRenderId = 0
  inc mdRenderId
  if mdRenderId == 1:
    mdFramemem = w * h
    if isBeat != 0:
      mdPerBeat = mdSinceBeat
      for i in 0 ..< 6:
        if mdUsebeats[i]: mdFramedelay[i] = mdPerBeat + 1
      mdSinceBeat = 0
    inc mdSinceBeat
    let fm = mdFramemem
    for i in 0 ..< 6:
      if mdFramedelay[i] > 1:
        mdVbs[i] = mdFramedelay[i] * fm
        if fm == mdOldFramemem:
          if mdVbs[i] != mdOldVbs[i]:
            if mdVbs[i] > mdOldVbs[i]:
              if mdVbs[i] > mdRing[i].size:
                if mdUsebeats[i]: mdRing[i].realloc(2 * mdVbs[i])
                else: mdRing[i].realloc(mdVbs[i])
                mdOut[i] = 0
                mdIn[i] = mdVbs[i] - fm
              else:
                let size = mdOldVbs[i] - mdOut[i]
                let d = mdVbs[i] - size
                mdRing[i].move(d, mdOut[i], size)
                var p = mdOut[i]
                while p < d:
                  mdRing[i].move(p, d, fm)
                  p += fm
            else:
              let preseg = mdOut[i]
              if preseg > mdVbs[i]:
                mdRing[i].move(0, preseg - mdVbs[i], mdVbs[i])
                mdIn[i] = mdVbs[i] - fm
                mdOut[i] = 0
              elif preseg < mdVbs[i]:
                mdRing[i].move(mdOut[i], mdOldVbs[i] + preseg - mdVbs[i], mdVbs[i] - preseg)
            mdOldVbs[i] = mdVbs[i]
        else:
          if mdUsebeats[i]: mdRing[i].realloc(2 * mdVbs[i])
          else: mdRing[i].realloc(mdVbs[i])
          mdOut[i] = 0
          mdIn[i] = mdVbs[i] - fm
          mdOldVbs[i] = mdVbs[i]
        mdOldFramemem = fm
  let a = int(e.activebuffer)
  if e.mode != 0 and a in 0 ..< 6 and mdFramedelay[a] > 1:
    let fm = mdFramemem
    let r = addr mdRing[a]
    if e.mode == 2:
      if mdOut[a] + fm <= r.data.len: copyMem(fb[0].addr, r.data[mdOut[a]].addr, fm * 4)
    else:
      if mdIn[a] + fm <= r.data.len: copyMem(r.data[mdIn[a]].addr, fb[0].addr, fm * 4)
  if mdRenderId == mdInstances:
    for i in 0 ..< 6:
      mdIn[i] += mdFramemem
      mdOut[i] += mdFramemem
      if mdIn[i] >= mdVbs[i]: mdIn[i] = 0
      if mdOut[i] >= mdVbs[i]: mdOut[i] = 0
  0

proc registerApes*() =
  registerApe("Channel Shift", newChannelShift)
  registerApe("Color Reduction", newColorReduction)
  registerApe("Multiplier", newMultiplier)
  registerApe("Holden04: Video Delay", newVideoDelay)
  registerApe("Holden05: Multi Delay", newMultiDelay)
