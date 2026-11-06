## A MIDI file played through FluidSynth: mpv has no MIDI synthesizer, so
## a MIDI or HMI file opens as `mmpmidi://N` (`prepare`), a WAV stream
## rendered as mpv reads it (48 kHz float stereo) with the SoundFont found
## for it (`soundFontFor`: one beside the file, else the one in Options).
##
## The song's messages come from midisong, as times; each is played at its
## frame, between slices of rendered sound. A seek starts the synth afresh
## and puts it where the song is at that time: every message before it but
## the notes (programs, controllers, pitch bends, SysEx), so it sounds as
## from the start, less notes held across the spot. A looping song (HMI)
## fades out over its last seconds.
##
## mpv calls in from its own threads, opening a stream on one and closing
## it on another: a stream uses only the C heap (mpv's `streamAlloc0`) and
## FluidSynth. The song is parsed in `prepare` and kept flat.

import std/[algorithm, locks, os, strutils]
import mpv, fluidsynth, midisong

const
  Rate = 48000
  FrameBytes = 8                ## stereo float32
  HeaderBytes = 44
  ChunkFrames = 512
  Protocol = "mmpmidi"
  Slots = 4
  Gain = 0.2                    ## FluidSynth's own default: Abuse's loudest song peaks at -0.1 dBFS
  SoundFontExts* = [".sf2", ".sf3"]

type
  Msg = object
    frame: int64
    b: array[3, uint8]
    n: uint8                    ## 0: SysEx at data[off ..< off + len]
    off, len: int32

  Flat = object                 ## a song on the C heap
    msgs: ptr UncheckedArray[Msg]
    count: int
    data: ptr UncheckedArray[char]
    dataLen: int
    frames, fadeFrom: int64     ## length; fade start, 0: none
    font: array[1024, char]     ## the SoundFont's path

  MidiStream = object
    song: Flat
    settings: Settings
    synth: Synth
    total: int64
    header: array[HeaderBytes, byte]
    pos: int64                  ## where mpv reads next
    next: int64                 ## where the synth renders next
    bufStart, bufLen: int64
    buf: array[ChunkFrames * 2, float32]
    msg: int                    ## the next message to play

  Slot = object
    id: int
    song: Flat

var
  slotLock: Lock
  slots: array[Slots, Slot]
  nextId = 1

initLock slotLock

proc available*(): bool = fluidsynth.load()

proc soundFontFor*(path, configured: string): string =
  ## The SoundFont a MIDI file plays with: one in its folder (the first by
  ## name), else the one set in Options; "" when there's neither.
  var found: seq[string]
  try:
    for kind, f in walkDir(path.parentDir):
      if kind in {pcFile, pcLinkToFile} and f.splitFile.ext.toLowerAscii in SoundFontExts:
        found.add f
  except OSError: discard
  if found.len > 0:
    found.sort(proc (a, b: string): int = cmpIgnoreCase(a, b))
    return found[0]
  let c = configured.expandTilde
  if c.len > 0 and fileExists(c): return c
  ""

proc freeFlat(f: var Flat) =
  streamFree(f.msgs)
  streamFree(f.data)
  f.msgs = nil
  f.data = nil

proc allocFlat(f: var Flat, count, dataLen: int): bool =
  ## Room for count messages and dataLen bytes of SysEx; false (and none)
  ## when out of memory.
  f.msgs = cast[ptr UncheckedArray[Msg]](streamAlloc0(count * sizeof(Msg)))
  f.data = cast[ptr UncheckedArray[char]](streamAlloc0(dataLen))
  if f.msgs == nil or f.data == nil:
    freeFlat(f)
    return false
  true

proc flatten(s: MidiSong, font: string): Flat =
  ## The song flat; no msgs when out of memory.
  var total = 0
  for e in s.events: total += e.data.len
  if not result.allocFlat(s.events.len, total): return
  result.count = s.events.len
  var at = 0
  for i, e in s.events:
    var m = Msg(frame: int64(e.t * Rate + 0.5), b: e.b, n: e.n)
    if e.n == 0:
      m.off = at.int32
      m.len = e.data.len.int32
      for c in e.data:
        result.data[at] = c
        inc at
    result.msgs[i] = m
  result.dataLen = total
  result.frames = int64(s.length * Rate)
  result.fadeFrom = if s.fadeFrom > 0: int64(s.fadeFrom * Rate) else: 0
  for i, c in font:
    if i >= result.font.high: break
    result.font[i] = c

proc copyFlat(f: Flat): Flat =
  ## A copy of f; no msgs when out of memory.
  result = f
  if not result.allocFlat(f.count, f.dataLen): return
  copyMem(result.msgs, f.msgs, f.count * sizeof(Msg))
  if f.dataLen > 0: copyMem(result.data, f.data, f.dataLen)

proc prepare*(path, font: string): string =
  ## The stream mpv can open in place of the MIDI file at path, played with
  ## the SoundFont `font`; "" when FluidSynth is missing or the file can't
  ## be read.
  if font.len == 0 or not fluidsynth.load(): return ""
  let s = openMidi(path)
  if s == nil: return ""
  var f = flatten(s, font)
  if f.msgs == nil: return ""
  withLock slotLock:
    let id = nextId
    inc nextId
    freeFlat(slots[id mod Slots].song)
    slots[id mod Slots] = Slot(id: id, song: f)
    result = Protocol & "://" & $id

proc put32(h: var array[HeaderBytes, byte], at: int, v: uint32) =
  for i in 0 .. 3: h[at + i] = byte((v shr (8 * i)) and 0xff)

proc put16(h: var array[HeaderBytes, byte], at: int, v: uint16) =
  for i in 0 .. 1: h[at + i] = byte((v shr (8 * i)) and 0xff)

proc writeHeader(s: ptr MidiStream, dataBytes: uint32) =
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

proc play(s: ptr MidiStream, m: Msg, notes: bool) =
  ## One message to the synth; notes false leaves notes out (a seek's way
  ## to its spot).
  let sy = s.synth
  if m.n == 0:
    # FluidSynth takes a SysEx without its F0 and F7.
    if m.len > 2:
      discard api.sysex(sy, cast[cstring](s.song.data[m.off + 1].addr), m.len - 2,
                        nil, nil, nil, 0)
    return
  let st = m.b[0].int
  let ch = cint(st and 0x0f)
  let (d1, d2) = (m.b[1].cint, m.b[2].cint)
  case st and 0xf0
  of 0x80:
    if notes: discard api.noteoff(sy, ch, d1)
  of 0x90:
    if not notes: discard
    elif d2 > 0: discard api.noteon(sy, ch, d1, d2)
    else: discard api.noteoff(sy, ch, d1)
  of 0xa0:
    if notes: discard api.keyPressure(sy, ch, d1, d2)
  of 0xb0: discard api.cc(sy, ch, d1, d2)
  of 0xc0: discard api.programChange(sy, ch, d1)
  of 0xd0: discard api.channelPressure(sy, ch, d1)
  of 0xe0: discard api.pitchBend(sy, ch, d1 or (d2 shl 7))
  else: discard

proc synthesize(s: ptr MidiStream, at, frames: int) =
  ## frames of sound into buf from frame `at` of it.
  if frames <= 0: return
  discard api.writeFloat(s.synth, frames.cint, s.buf[at * 2].addr, 0, 2,
                         s.buf[at * 2 + 1].addr, 0, 2)

proc render(s: ptr MidiStream, frames: int) =
  ## The next `frames` (at most a chunk) into buf, each message at its frame.
  let first = (s.next - HeaderBytes) div FrameBytes
  var done = 0
  while done < frames:
    var upto = frames
    while s.msg < s.song.count:
      let f = s.song.msgs[s.msg].frame - first
      if f > done:
        upto = int(min(f, frames.int64))
        break
      s.play(s.song.msgs[s.msg], true)
      inc s.msg
    s.synthesize(done, upto - done)
    done = upto
  # A looping song fades out (linearly) to its end.
  let fade = s.song.fadeFrom
  if fade > 0 and first + frames > fade:
    let span = max(1'i64, s.song.frames - fade).float32
    for i in 0 ..< frames:
      let k = clamp(1 - float32(first + i - fade) / span, 0, 1)
      s.buf[i * 2] *= k
      s.buf[i * 2 + 1] *= k

proc reposition(s: ptr MidiStream, at: int64) =
  ## The synth as the song has it at the frame holding byte `at`.
  let frame = (at - HeaderBytes) div FrameBytes
  discard api.systemReset(s.synth)
  s.msg = 0
  while s.msg < s.song.count and s.song.msgs[s.msg].frame < frame:
    s.play(s.song.msgs[s.msg], false)
    inc s.msg
  s.next = HeaderBytes + frame * FrameBytes
  s.bufLen = 0

proc readCb(cookie: pointer, buf: ptr UncheckedArray[byte], nbytes: uint64): int64 {.cdecl.} =
  let s = cast[ptr MidiStream](cookie)
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
    # Frame aligned: a read from the middle of a frame starts the chunk there.
    let aligned = HeaderBytes + (s.pos - HeaderBytes) div FrameBytes * FrameBytes
    if aligned != s.next: s.reposition(aligned)
    let frames = int(min(ChunkFrames.int64, (s.total - s.next) div FrameBytes))
    if frames <= 0: break
    s.render(frames)
    s.bufStart = s.next
    s.bufLen = frames * FrameBytes
    s.next += s.bufLen
  done

proc seekCb(cookie: pointer, offset: int64): int64 {.cdecl.} =
  let s = cast[ptr MidiStream](cookie)
  if offset < 0 or offset > s.total: return MpvErrorGeneric
  s.pos = offset
  offset

proc sizeCb(cookie: pointer): int64 {.cdecl.} =
  cast[ptr MidiStream](cookie).total

proc closeCb(cookie: pointer) {.cdecl.} =
  let s = cast[ptr MidiStream](cookie)
  if s.synth != nil: api.deleteSynth(s.synth)
  if s.settings != nil: api.deleteSettings(s.settings)
  freeFlat(s.song)
  streamFree(s)

proc openCb(userData: pointer, uri: cstring, info: ptr MpvStreamCbInfo): cint {.cdecl.} =
  const Skip = Protocol.len + 3
  var id = 0
  var i = Skip
  while uri[i] in {'0' .. '9'}:
    id = id * 10 + (ord(uri[i]) - ord('0'))
    inc i
  var song: Flat
  withLock slotLock:
    let sl = slots[id mod Slots].addr
    if sl.id == id and sl.song.msgs != nil: song = copyFlat(sl.song)
  if song.msgs == nil: return MpvErrorLoadingFailed
  let settings = api.newSettings()
  if settings == nil:
    freeFlat(song)
    return MpvErrorLoadingFailed
  discard api.setnum(settings, "synth.sample-rate", Rate.cdouble)
  discard api.setnum(settings, "synth.gain", Gain)
  discard api.setint(settings, "synth.lock-memory", 0)
  discard api.setint(settings, "synth.threadsafe-api", 0)
  let synth = api.newSynth(settings)
  if synth == nil or api.sfload(synth, cast[cstring](song.font[0].addr), 1) < 0:
    if synth != nil: api.deleteSynth(synth)
    api.deleteSettings(settings)
    freeFlat(song)
    return MpvErrorLoadingFailed
  let s = streamCreate(MidiStream)
  if s == nil:
    api.deleteSynth(synth)
    api.deleteSettings(settings)
    freeFlat(song)
    return MpvErrorLoadingFailed
  s.song = song
  s.settings = settings
  s.synth = synth
  let dataBytes = min(song.frames * FrameBytes, (high(uint32).int64 - 36) div FrameBytes * FrameBytes)
  s.total = HeaderBytes + dataBytes
  s.writeHeader(dataBytes.uint32)
  s.next = HeaderBytes
  info.cookie = s
  info.readFn = readCb
  info.seekFn = seekCb
  info.sizeFn = sizeCb
  info.closeFn = closeCb
  info.cancelFn = nil
  0

proc register*(h: MpvHandle) =
  ## Lets the player open prepared MIDI streams.
  discard mpv_stream_cb_add_ro(h, Protocol, nil, openCb)
