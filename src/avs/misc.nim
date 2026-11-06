## Misc effects: Clear Screen, OnBeat Clear, Custom BPM, Set Render Mode,
## Comment, Buffer Save (r_clear.cpp, r_nfclr.cpp, r_bpm.cpp, r_linemode.cpp,
## r_comment.cpp, r_stack.cpp).

import core, list

# --- Clear Screen -------------------------------------------------------------

type ClearScreen = ref object of Effect
  enabled, onlyfirst, blend, blendavg: int32
  color: uint32
  fcounter: int

method desc(e: ClearScreen): string = "Render / Clear screen"
proc newClear(): Effect = ClearScreen(enabled: 1)

method load(e: ClearScreen, d: openArray[byte]) =
  var pos = 0
  if d.len - pos >= 4: (e.enabled = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.color = cast[uint32](getInt(d, pos)); pos += 4)
  if d.len - pos >= 4: (e.blend = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.blendavg = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.onlyfirst = getInt(d, pos); pos += 4)

method render(e: ClearScreen, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if e.enabled == 0: return 0
  if e.onlyfirst != 0 and e.fcounter != 0: return 0
  if (isBeat and BeatPreinit) != 0: return 0
  inc e.fcounter
  let n = w * h
  if e.blend == 2:
    for i in 0 ..< n: blendLine(fb[i], e.color)
  elif e.blend != 0:
    for i in 0 ..< n: fb[i] = blendAdd(fb[i], e.color)
  elif e.blendavg != 0:
    for i in 0 ..< n: fb[i] = blendAvg(fb[i], e.color)
  else:
    for i in 0 ..< n: fb[i] = e.color
  0

# --- OnBeat Clear ---------------------------------------------------------------

type OnBeatClear = ref object of Effect
  nf, cf, df: int32
  color: uint32
  blend: int32

method desc(e: OnBeatClear): string = "Render / OnBeat Clear"
proc newOnBeatClear(): Effect = OnBeatClear(nf: 1, color: colorRgb(255, 255, 255))

method load(e: OnBeatClear, d: openArray[byte]) =
  var pos = 0
  if d.len - pos >= 4: (e.color = cast[uint32](getInt(d, pos)); pos += 4)
  if d.len - pos >= 4: (e.blend = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.nf = getInt(d, pos); pos += 4)

method render(e: OnBeatClear, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if (isBeat and BeatPreinit) != 0: return 0
  if isBeat != 0:
    if e.nf != 0:
      inc e.cf
      if e.cf >= e.nf:
        e.cf = 0
        e.df = 0
        let n = w * h
        if e.blend == 0:
          for i in 0 ..< n: fb[i] = e.color
        else:
          for i in 0 ..< (n div 4) * 4: fb[i] = blendAvg(fb[i], e.color)
  else:
    inc e.df
    if e.df >= e.nf: e.df = 0
  0

# --- Custom BPM ------------------------------------------------------------------

type CustomBpm = ref object of Effect
  enabled, arbitrary, skip, invert, arbVal, skipVal, skipfirst: int32
  arbLastTC: uint32
  skipCount, count: int
  started: bool

method desc(e: CustomBpm): string = "Misc / Custom BPM"
proc newCustomBpm(): Effect = CustomBpm(enabled: 1, arbitrary: 1, arbVal: 500, skipVal: 1)

method load(e: CustomBpm, d: openArray[byte]) =
  var pos = 0
  if d.len - pos >= 4: (e.enabled = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.arbitrary = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.skip = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.invert = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.arbVal = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.skipVal = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.skipfirst = getInt(d, pos); pos += 4)

method render(e: CustomBpm, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if not e.started:
    e.started = true
    e.arbLastTC = getTickCount()  # the constructor's GetTickCount()
  if e.enabled == 0: return 0
  if (isBeat and BeatPreinit) != 0: return 0
  if isBeat != 0: inc e.count
  if e.skipfirst != 0 and e.count <= e.skipfirst:
    return (if isBeat != 0: RetClearBeat else: 0)
  if e.arbitrary != 0:
    let now = getTickCount()
    if now > e.arbLastTC + uint32(e.arbVal):
      e.arbLastTC = now
      return RetSetBeat
    return RetClearBeat
  if e.skip != 0:
    if isBeat != 0:
      inc e.skipCount
      if e.skipCount >= e.skipVal + 1:
        e.skipCount = 0
        return RetSetBeat
    return RetClearBeat
  if e.invert != 0:
    return (if isBeat != 0: RetClearBeat else: RetSetBeat)
  0

# --- Set Render Mode ----------------------------------------------------------------

type SetRenderMode = ref object of Effect
  newmode: int32

method desc(e: SetRenderMode): string = "Misc / Set render mode"
proc newSetRenderMode(): Effect = SetRenderMode(newmode: cast[int32](0x80010000'u32))

method load(e: SetRenderMode, d: openArray[byte]) =
  if d.len >= 4: e.newmode = getInt(d, 0)

method render(e: SetRenderMode, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if (isBeat and BeatPreinit) != 0: return 0
  if (e.newmode and BeatPreinit) != 0: lineBlendMode = e.newmode and 0x7fffffff
  0

# --- Comment -----------------------------------------------------------------------------

type Comment* = ref object of Effect
  text*: string

method desc(e: Comment): string = "Misc / Comment"
proc newComment(): Effect = Comment()

method load(e: Comment, d: openArray[byte]) =
  var pos = 0
  e.text = loadString(d, pos)

# --- Buffer Save -------------------------------------------------------------------------

type BufferSave = ref object of Effect
  clear: bool
  dirCh: int
  blend, dir, which, adjblendVal: int32

method desc(e: BufferSave): string = "Misc / Buffer Save"
proc newBufferSave(): Effect = BufferSave(adjblendVal: 128)

method load(e: BufferSave, d: openArray[byte]) =
  var pos = 0
  if d.len - pos >= 4: (e.dir = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.which = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.blend = getInt(d, pos); pos += 4)
  if d.len - pos >= 4: (e.adjblendVal = getInt(d, pos); pos += 4)
  if e.which < 0: e.which = 0
  if e.which >= NBuf: e.which = NBuf - 1

method render(e: BufferSave, vis: var VisData, isBeat: int32, fb, fbout: Pixels, w, h: int): int =
  if (isBeat and BeatPreinit) != 0: return 0
  let buf = getGlobalBuffer(w, h, e.which, e.dir != 1)
  if buf == nil: return 0
  let n = w * h
  if e.clear:
    e.clear = false
    clearPixels(buf, n)
  let tdir = if e.dir < 2: int(e.dir) else: (int(e.dir) and 1) xor e.dirCh
  e.dirCh = e.dirCh xor 1
  let src = if tdir == 0: fb else: buf
  let dst = if tdir != 0: fb else: buf
  case e.blend
  of 1: avgBlock(dst, src, n)
  of 2: addBlock(dst, src, n)
  of 3:
    for y in 0 ..< h:
      let r = y and 1
      for k in 0 ..< w div 2: dst[y * w + r + 2 * k] = src[y * w + r + 2 * k]
  of 4:
    for i in 0 ..< n: dst[i] = blendSub(dst[i], src[i])
  of 5:
    var y = 0
    while y < (h div 2) * 2:
      copyMem(dst[y * w].addr, src[y * w].addr, w * 4)
      y += 2
  of 6:
    for i in 0 ..< n: dst[i] = dst[i] xor src[i]
  of 7:
    for i in 0 ..< n: dst[i] = blendMax(dst[i], src[i])
  of 8:
    for i in 0 ..< n: dst[i] = blendMin(dst[i], src[i])
  of 9:
    for i in 0 ..< n: dst[i] = blendSub(src[i], dst[i])
  of 10: mulBlock(dst, src, n)
  of 11: adjBlock(dst, src, dst, n, e.adjblendVal)
  else: copyPixels(dst, src, n)
  0

proc registerMisc*() =
  registerEffect(5, newOnBeatClear)
  registerEffect(18, newBufferSave)
  registerEffect(21, newComment)
  registerEffect(25, newClear)
  registerEffect(33, newCustomBpm)
  registerEffect(40, newSetRenderMode)
