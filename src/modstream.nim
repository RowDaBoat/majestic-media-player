## A tracker module played through libopenmpt here instead of FFmpeg's copy,
## which takes no settings: that's what lets the tracker button shift its
## pitch and keep its samples unstretched (libopenmpt's pitch factor).
##
## mpv opens `mmpmod://N` (`prepare`), a WAV stream rendered as it reads:
## 48 kHz float stereo, as long as libopenmpt says the song is. The song's
## time stays the stream's (the pitch factor changes how fast samples play,
## not the tempo), so the seek bar, chart and bookmarks are as with FFmpeg.
## A seek renders on from where libopenmpt lands (a row's start at or
## before the spot: left alone, it lands after it) to the exact frame, so
## the stream's bytes are the same wherever it starts.
##
## libopenmpt takes pitch factors up to 4 only, and leaves the old one on
## for any higher: unstretched samples at a slow speed (the factor is the
## inverse of the speed) went flat and slowed down with it. Past 4, the
## rest comes from the tempo: at tempo 1/K (K = 2^shift) libopenmpt makes K
## frames of each one, its samples going 1/K as far in each, and every Kth
## frame of those, band-limited (decimate), is the stream's. Still at 48
## kHz, libopenmpt counts each tick's frames as at tempo 1, times K exactly,
## so the song keeps the stream's time to the frame; at a lower rate with
## the tempo (the same frames otherwise) the counts round differently and
## the song drifts, about 1 ms a second in some modules. Seeks go at tempo
## 1, where libopenmpt's seconds are the song's.
##
## mpv calls in from its own threads: streams use only shared memory and
## libopenmpt; the factor comes in through an atomic.

import std/[atomics, locks, math]
import mpv, tracker

const
  Rate = 48000
  FrameBytes = 8                ## stereo float32
  HeaderBytes = 44
  ChunkFrames = 512             ## rendered at a time, ~11 ms
  Protocol = "mmpmod"
  Slots = 4                     ## modules prepared, newest kept
  MaxPitch = 4.0                ## libopenmpt's highest pitch factor
  MaxShift = 7                  ## tempo down to 1/128: factors up to 512
                                ## (mpv's slowest speed, 0.01, at +24 is 400)
  Half = 16                     ## the decimation filter's reach each side,
                                ## in the stream's frames
  RawCap = (ChunkFrames + 2 * Half) shl MaxShift + 1
                                ## libopenmpt's frames held at most

type
  ModStream = object
    m: Module
    total: int64                ## bytes, header included
    header: array[HeaderBytes, byte]
    pos: int64                  ## where mpv reads next
    next: int64                 ## where libopenmpt renders next (frame aligned)
    bufStart, bufLen: int64     ## the rendered chunk's bytes in the stream
    buf: array[ChunkFrames * 2, float32]
    factor: float               ## the pitch factor asked for, as rendered
    shift: int                  ## tempo 1/2^shift, frames decimated by 2^shift
    raw: ptr UncheckedArray[float32]  ## libopenmpt's frames while shift > 0
    rawBase: int64              ## libopenmpt's frame number of raw's first
    rawLen: int                 ## frames in raw

  Slot = object
    id: int
    data: string                ## the module file

var
  factorBits: Atomic[uint64]
  slotLock: Lock
  slots: array[Slots, Slot]
  nextId = 1
  taps: array[1 .. MaxShift, ptr UncheckedArray[float32]]
    ## the decimation filters, 2 * Half * 2^shift + 1 long

initLock slotLock
factorBits.store(cast[uint64](1.0))

proc besselI0(x: float): float =
  var term = 1.0
  result = 1.0
  for k in 1 .. 50:
    term *= (x / (2 * k.float)) * (x / (2 * k.float))
    result += term
    if term < result * 1e-17: break

proc makeTaps(shift: int): ptr UncheckedArray[float32] =
  ## A Kaiser windowed sinc low-pass, at 0.45 of the decimated rate (the
  ## band above is the transition, ~80 dB down past it), summing to 1.
  const Beta = 8.0
  let k = 1 shl shift
  let reach = Half * k
  let fc = 0.45 / k.float
  var h = newSeq[float](2 * reach + 1)
  var sum = 0.0
  for j in -reach .. reach:
    let x = 2 * fc * j.float
    let sinc = if j == 0: 1.0 else: sin(PI * x) / (PI * x)
    let r = j.float / reach.float
    h[j + reach] = 2 * fc * sinc * besselI0(Beta * sqrt(max(0.0, 1 - r * r))) / besselI0(Beta)
    sum += h[j + reach]
  result = cast[ptr UncheckedArray[float32]](allocShared(h.len * sizeof(float32)))
  for i, v in h: result[i] = float32(v / sum)

for shift in 1 .. MaxShift: taps[shift] = makeTaps(shift)

proc setPitchFactor*(f: float) =
  ## How fast samples play in every module stream, 1 as written. Heard
  ## from the next chunk rendered (mpv reads somewhat ahead).
  factorBits.store(cast[uint64](f))

proc pitchFactor(): float = cast[float](factorBits.load)

proc available*(): bool = loadApi()

proc prepare*(path: string): string =
  ## The stream mpv can open in place of the module at path, "" when
  ## libopenmpt is missing or can't read it.
  if not loadApi(): return ""
  var data: string
  try: data = readFile(path)
  except IOError, OSError: return ""
  let m = openModule(data)
  if m == nil: return ""
  api.destroy(m)
  withLock slotLock:
    let id = nextId
    inc nextId
    slots[id mod Slots] = Slot(id: id, data: move data)
    result = Protocol & "://" & $id

proc put32(h: var array[HeaderBytes, byte], at: int, v: uint32) =
  for i in 0 .. 3: h[at + i] = byte((v shr (8 * i)) and 0xff)

proc put16(h: var array[HeaderBytes, byte], at: int, v: uint16) =
  for i in 0 .. 1: h[at + i] = byte((v shr (8 * i)) and 0xff)

proc writeHeader(s: ptr ModStream, dataBytes: uint32) =
  for i, c in "RIFF": s.header[i] = byte(c)
  s.header.put32(4, 36 + dataBytes)
  for i, c in "WAVEfmt ": s.header[8 + i] = byte(c)
  s.header.put32(16, 16)
  s.header.put16(20, 3)                     # IEEE float
  s.header.put16(22, 2)
  s.header.put32(24, Rate)
  s.header.put32(28, Rate * FrameBytes)
  s.header.put16(32, FrameBytes)
  s.header.put16(34, 32)
  for i, c in "data": s.header[36 + i] = byte(c)
  s.header.put32(40, dataBytes)

proc split(f: float): int =
  ## The shift for pitch factor f: the least that leaves libopenmpt's own
  ## (f / 2^shift) at most MaxPitch.
  while f > MaxPitch * float(1 shl result) and result < MaxShift: inc result

proc setPitch(s: ptr ModStream, f: float) =
  ## libopenmpt's pitch factor for f at the stream's shift (the min: past
  ## MaxShift, or a rounding error over MaxPitch, it'd be refused).
  s.factor = f
  discard api.ctlSetFloat(s.m, "play.pitch_factor", min(f / float(1 shl s.shift), MaxPitch))

proc readRaw(s: ptr ModStream, at, frames: int) =
  ## libopenmpt's next `frames` into raw from `at`, silence past the song.
  let got = api.readStereo(s.m, Rate, frames.csize_t, s.raw[at * 2].addr).int
  for i in (at + got) * 2 ..< (at + frames) * 2: s.raw[i] = 0

proc fill(s: ptr ModStream, lo, hi: int64) =
  ## raw to hold libopenmpt's frames from lo to hi (from rawBase, if later:
  ## where a seek landed, nothing before it).
  if lo > s.rawBase:
    let d = int(min(lo - s.rawBase, s.rawLen.int64))
    if d < s.rawLen:
      moveMem(s.raw[0].addr, s.raw[d * 2].addr, (s.rawLen - d) * FrameBytes)
    s.rawLen -= d
    s.rawBase += d
  while s.rawBase + s.rawLen < hi:
    let at = s.rawBase + s.rawLen
    if at < lo:  # a seek's way to the frame: rendered and let go
      let n = int(min(lo - at, RawCap.int64))
      s.readRaw(0, n)
      s.rawBase += n
    else:
      let n = int(min(hi - at, int64(RawCap - s.rawLen)))
      s.readRaw(s.rawLen, n)
      s.rawLen += n

proc decimate(s: ptr ModStream, frames: int) =
  ## The stream's next `frames` from libopenmpt's, 2^shift for each one.
  let k = 1 shl s.shift
  let reach = Half * k
  let first = (s.next - HeaderBytes) div FrameBytes
  s.fill(first * k - reach, (first + frames - 1) * k + reach + 1)
  let h = taps[s.shift]
  for i in 0 ..< frames:
    let lo = (first + i) * k - reach  # the filter's first frame
    var l, r: float32
    for j in int(max(0'i64, s.rawBase - lo)) .. 2 * reach:
      let at = int(lo + j - s.rawBase)
      l += h[j] * s.raw[at * 2]
      r += h[j] * s.raw[at * 2 + 1]
    s.buf[i * 2] = l
    s.buf[i * 2 + 1] = r

proc reposition(s: ptr ModStream, at: int64)

proc render(s: ptr ModStream, frames: int) =
  ## The next `frames` (at most a chunk) into buf, silence past the song.
  let f = pitchFactor()
  if f != s.factor:
    if f <= MaxPitch * float(1 shl s.shift) or s.shift == MaxShift:
      s.setPitch(f)
    else:
      # A higher shift: from a seek, the next frame's own (a new tempo in
      # the middle of a tick would put the rest of that tick off).
      s.reposition(s.next)
  if s.shift > 0:
    s.decimate(frames)
    return
  let got = api.readStereo(s.m, Rate, frames.csize_t, s.buf[0].addr).int
  for i in got * 2 ..< frames * 2: s.buf[i] = 0

proc reposition(s: ptr ModStream, at: int64) =
  ## libopenmpt to the frame holding byte `at`: where it lands, then on.
  let frame = (at - HeaderBytes) div FrameBytes
  let t = frame.float / Rate
  let f = pitchFactor()
  s.shift = split(f)
  if s.shift > 0 and s.raw == nil:
    s.raw = cast[ptr UncheckedArray[float32]](streamAlloc0(RawCap * FrameBytes))
    if s.raw == nil: s.shift = 0     # out of memory: pitch capped at MaxPitch
  s.setPitch(f)
  # At tempo 1, the seconds libopenmpt seeks to are the song's.
  discard api.ctlSetFloat(s.m, "play.tempo_factor", 1.0)
  # libopenmpt lands on a row's start, often the one after t: rendering
  # from there would sound ahead of the time mpv tells (by up to a row,
  # again at every seek), so it goes back until it lands at or before t.
  var landed = api.setPosition(s.m, t)
  var back = 0.0
  while landed > t and back < t:
    back = max(0.25, back * 2)
    landed = api.setPosition(s.m, max(0.0, t - back))
  s.next = HeaderBytes + frame * FrameBytes
  s.bufLen = 0
  if s.shift > 0:
    # decimate renders on from the landing, a whole frame of the stream's.
    discard api.ctlSetFloat(s.m, "play.tempo_factor", 1 / float(1 shl s.shift))
    s.rawBase = int64(round(landed * Rate)) shl s.shift
    s.rawLen = 0
    return
  var skip = int((t - landed) * Rate + 0.5)
  while skip > 0:
    let n = min(skip, ChunkFrames)
    s.render(n)
    skip -= n

proc readCb(cookie: pointer, buf: ptr UncheckedArray[byte], nbytes: uint64): int64 {.cdecl.} =
  let s = cast[ptr ModStream](cookie)
  var done = 0'i64
  let want = nbytes.int64
  while done < want and s.pos < s.total:
    if s.pos < HeaderBytes:
      let k = min(want - done, HeaderBytes - s.pos)
      copyMem(buf[done].addr, s.header[s.pos].addr, k)
      s.pos += k
      done += k
      continue
    if s.pos >= s.bufStart and s.pos < s.bufStart + s.bufLen:
      let k = min(want - done, s.bufStart + s.bufLen - s.pos)
      copyMem(buf[done].addr, cast[ptr UncheckedArray[byte]](s.buf[0].addr)[s.pos - s.bufStart].addr, k)
      s.pos += k
      done += k
      continue
    if s.pos < s.next or s.pos >= s.next + ChunkFrames * FrameBytes:
      s.reposition(s.pos)
    let frames = int(min(ChunkFrames.int64, (s.total - s.next) div FrameBytes))
    if frames <= 0: break
    s.render(frames)
    s.bufStart = s.next
    s.bufLen = frames * FrameBytes
    s.next += s.bufLen
  done

proc seekCb(cookie: pointer, offset: int64): int64 {.cdecl.} =
  let s = cast[ptr ModStream](cookie)
  if offset < 0 or offset > s.total: return MpvErrorGeneric
  s.pos = offset
  offset

proc sizeCb(cookie: pointer): int64 {.cdecl.} =
  cast[ptr ModStream](cookie).total

proc closeCb(cookie: pointer) {.cdecl.} =
  let s = cast[ptr ModStream](cookie)
  api.destroy(s.m)
  streamFree(s.raw)
  streamFree(s)

proc openCb(userData: pointer, uri: cstring, info: ptr MpvStreamCbInfo): cint {.cdecl.} =
  # The id after "mmpmod://", parsed without allocating.
  const Skip = Protocol.len + 3
  var id = 0
  var i = Skip
  while uri[i] in {'0' .. '9'}:
    id = id * 10 + (ord(uri[i]) - ord('0'))
    inc i
  var m: Module
  withLock slotLock:
    let sl = slots[id mod Slots].addr
    if sl.id == id and sl.data.len > 0:
      var err: cint
      var msg: cstring
      m = api.create(sl.data[0].addr, sl.data.len.csize_t, api.silentLog, nil,
                     api.ignoreErrors, nil, err.addr, msg.addr, nil)
      if msg != nil: api.freeString(msg)
  if m == nil: return MpvErrorLoadingFailed
  let s = streamCreate(ModStream)
  if s == nil:
    api.destroy(m)
    return MpvErrorLoadingFailed
  s.m = m
  # WAV sizes are 32-bit: past ~3 hours the stream ends.
  let dataBytes = min(int64(api.duration(m) * Rate) * FrameBytes,
                      (high(uint32).int64 - 36) div FrameBytes * FrameBytes)
  s.total = HeaderBytes + dataBytes
  s.writeHeader(dataBytes.uint32)
  s.factor = -1  # set on the first render
  s.next = HeaderBytes
  info.cookie = s
  info.readFn = readCb
  info.seekFn = seekCb
  info.sizeFn = sizeCb
  info.closeFn = closeCb
  info.cancelFn = nil
  0

proc register*(h: MpvHandle) =
  ## Lets the player open prepared module streams.
  discard mpv_stream_cb_add_ro(h, Protocol, nil, openCb)
