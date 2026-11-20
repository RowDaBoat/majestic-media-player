## The seek bar's waveform (its menu's Waveform): the sound playing, decoded
## on a thread of its own into the highest sample and the RMS of each
## bucket, a 1/Buckets slice of its length (1 ms at least). The sound comes
## from ffmpeg as a float WAV on a pipe, as ReplayGain scanning's does
## (rgscan), or for a MIDI file from FluidSynth with the SoundFont it plays
## with. The main thread takes in what's done (poll), so the waveform fills
## from the left as it's decoded.
##
## One worker for every request, started with the first and never ended,
## for the reason rgscan gives: what it allocates goes back to its own heap.
## A new request makes the one running stale: its ffmpeg is killed, and a
## render stops at its next read.

import std/[osproc, streams, math, locks, strutils]
import midistream

const
  Buckets* = 32768

type
  WaveSource* = object
    file*: string          ## decoded from; "" = nothing to decode
    stream*: int           ## its audio stream, counting audio streams only
    start*, length*: float ## the stretch of it, seconds (a cue track); length 0: to its end
    font*: string          ## a MIDI file's SoundFont: rendered by FluidSynth, not ffmpeg
    duration*: float       ## the seek bar's length, which sets the buckets' length

  Wave* = ref object
    src*: WaveSource
    bucket*: float         ## seconds each bucket holds
    peak*, rms*: seq[float32]  ## per bucket from the start, 1.0 full scale
    top*: float32          ## the highest peak taken in
    done*: bool            ## decoded to the end, failed, or replaced
    error*: string         ## why it failed; "" when it didn't
    gen: int

  Shared = object
    lock: Lock
    cond: Cond
    job: WaveSource
    bucket: float
    gen: int               ## the latest request's
    pending: bool          ## the worker has yet to take it
    peak, rms: seq[float32]
    done: bool
    error: string
    ffmpeg: Process        ## decoding the latest request, to kill when it goes stale

  Reader = object
    o: Stream              ## ffmpeg's stdout, when not a render
    render: pointer        ## midistream's, for a MIDI file

var
  sh: Shared
  worker: Thread[void]
  inited: bool

proc read(r: Reader, dst: pointer, n: int): int =
  {.cast(gcsafe).}:
    result = if r.render != nil: renderRead(r.render, dst, n) else: r.o.readData(dst, n)

proc readFull(r: Reader, dst: pointer, n: int): int =
  ## n bytes unless the sound ends first (a pipe hands them in pieces).
  while result < n:
    let got = r.read(cast[ptr UncheckedArray[byte]](dst)[result].addr, n - result)
    if got <= 0: break
    result += got

proc u16(s: openArray[byte], i: int): int = s[i].int or s[i + 1].int shl 8
proc u32(s: openArray[byte], i: int): int =
  s[i].int or s[i + 1].int shl 8 or s[i + 2].int shl 16 or s[i + 3].int shl 24
proc fourcc(s: openArray[byte], i: int): string =
  for k in 0 ..< 4: result.add char(s[i + k])

proc publish(gen: int, peak, rms: var seq[float32]): bool =
  ## Hands the buckets made so far over; false once the request is stale.
  withLock sh.lock:
    if sh.gen != gen: return false
    sh.peak.add peak
    sh.rms.add rms
  peak.setLen 0
  rms.setLen 0
  true

proc scan(r: Reader, bucket: float, gen: int): string =
  ## Reads the float WAV r gives into buckets; why it couldn't, else "".
  var head: array[12, byte]
  if r.readFull(head[0].addr, 12) != 12 or fourcc(head, 0) != "RIFF":
    return "no sound decoded"
  var (rate, chans) = (0, 0)
  while true:
    var ch: array[8, byte]
    if r.readFull(ch[0].addr, 8) != 8: return "the decoded sound ended early"
    let (id, size) = (fourcc(ch, 0), u32(ch, 4))
    if id == "data": break
    var body = newSeq[byte](size + (size and 1))
    if body.len > 0 and r.readFull(body[0].addr, body.len) != body.len:
      return "the decoded sound ended early"
    if id == "fmt " and size >= 16: (chans, rate) = (u16(body, 2), u32(body, 4))
  if rate <= 0 or chans <= 0: return "no audio format in the decoded sound"
  let per = bucket * rate.float          # frames a bucket holds
  var buf = newSeq[float32](4096 * chans)
  var leftover = 0                       # bytes of a partial frame held in buf
  var (pk, sq, inBucket, made) = (0'f32, 0.0, 0, 0)
  var edge = per
  var frames = 0
  var peak, rms: seq[float32]
  while true:
    let got = r.read(cast[ptr UncheckedArray[byte]](buf[0].addr)[leftover].addr,
                     buf.len * 4 - leftover)
    if got <= 0: break
    let bytes = leftover + got
    let n = bytes div (4 * chans)
    for i in 0 ..< n:
      for c in 0 ..< chans:
        let x = abs(buf[i * chans + c])
        if x > pk: pk = x
        sq += float(x) * float(x)
      inc inBucket
      inc frames
      if frames.float >= edge:
        peak.add pk
        rms.add float32(sqrt(sq / float(inBucket * chans)))
        inc made
        edge = float(made + 1) * per
        (pk, sq, inBucket) = (0'f32, 0.0, 0)
    leftover = bytes - n * 4 * chans
    if leftover > 0:
      moveMem(buf[0].addr, cast[ptr UncheckedArray[byte]](buf[0].addr)[n * 4 * chans].addr, leftover)
    if peak.len > 0 and not publish(gen, peak, rms): return "replaced"
  if inBucket > 0:
    peak.add pk
    rms.add float32(sqrt(sq / float(inBucket * chans)))
  if not publish(gen, peak, rms): return "replaced"
  if frames == 0: return "no sound decoded"

proc work(job: WaveSource, bucket: float, gen: int) =
  var err = ""
  if job.font.len > 0:
    var rd: pointer
    {.cast(gcsafe).}: rd = renderOpen(job.file, job.font)
    if rd == nil: err = "FluidSynth can't play it"
    else:
      err = scan(Reader(render: rd), bucket, gen)
      {.cast(gcsafe).}: renderClose(rd)
  else:
    var args = @["-v", "fatal", "-nostdin"]
    if job.start > 0: args.add ["-ss", formatFloat(job.start, ffDecimal, 6)]
    args.add ["-i", job.file]
    if job.length > 0: args.add ["-t", formatFloat(job.length, ffDecimal, 6)]
    args.add ["-map", "0:a:" & $job.stream, "-vn", "-sn", "-dn",
              "-c:a", "pcm_f32le", "-f", "wav", "-"]
    var p: Process
    try: p = startProcess("ffmpeg", args = args, options = {poUsePath, poDaemon})  # poDaemon: no console window on Windows
    except OSError: err = "ffmpeg can't be run"
    if p != nil:
      var stale = false
      withLock sh.lock:
        if sh.gen == gen: sh.ffmpeg = p
        else: stale = true
      if not stale: err = scan(Reader(o: p.outputStream), bucket, gen)
      withLock sh.lock:
        if sh.ffmpeg == p: sh.ffmpeg = nil
      if stale or err == "replaced":
        try: p.kill() except OSError: discard
      discard p.waitForExit()
      if err == "no sound decoded":
        let msg = p.errorStream.readAll.strip
        err = if "matches no streams" in msg: "no audio"
              elif msg.len > 0: msg.splitLines[^1]
              else: "ffmpeg can't decode it"
      p.close()
  withLock sh.lock:
    if sh.gen == gen:
      sh.done = true
      sh.error = err

proc workLoop() {.thread.} =
  ## Decodes each request, the latest one only, for as long as the program runs.
  {.cast(gcsafe).}:
    while true:
      var job: WaveSource
      var (bucket, gen) = (0.0, 0)
      withLock sh.lock:
        while not sh.pending: wait(sh.cond, sh.lock)
        sh.pending = false
        (job, bucket, gen) = (sh.job, sh.bucket, sh.gen)
      work(job, bucket, gen)

proc stale() =
  ## Ends the request running (sh.lock held). sh.ffmpeg is left for the
  ## worker to clear: Nim's reference counts aren't thread-safe, so only the
  ## thread that started the Process assigns it. Clearing it here counted it
  ## down on the main thread, whose cycle collector then traced it after the
  ## worker freed it (a crash). It stays a live, unreaped process until the
  ## worker clears it, so killing it twice is harmless.
  inc sh.gen
  sh.pending = false
  if sh.ffmpeg != nil:
    try: sh.ffmpeg.kill() except OSError: discard

proc request*(src: WaveSource): Wave =
  ## Starts decoding src, in place of whatever was being decoded.
  if not inited:
    initLock sh.lock
    initCond sh.cond
    createThread(worker, workLoop)
    inited = true
  if src.font.len > 0: discard midistream.available()  # FluidSynth's globals, set before the thread uses them
  result = Wave(src: src, bucket: max(0.001, src.duration / Buckets))
  withLock sh.lock:
    stale()
    sh.job = src
    sh.bucket = result.bucket
    sh.peak.setLen 0
    sh.rms.setLen 0
    sh.done = false
    sh.error = ""
    sh.pending = true
    result.gen = sh.gen
    signal(sh.cond)

proc cancel*() =
  ## Stops decoding, whatever was asked last.
  if not inited: return
  withLock sh.lock: stale()

proc poll*(w: Wave): bool =
  ## Takes in the buckets decoded since; true when there were any, or when it
  ## just ended.
  if w == nil or w.done: return
  withLock sh.lock:
    if sh.gen != w.gen:
      w.done = true
      w.error = "replaced"
      return true
    for i in w.peak.len ..< sh.peak.len:
      w.peak.add sh.peak[i]
      w.rms.add sh.rms[i]
      if sh.peak[i] > w.top: w.top = sh.peak[i]
      result = true
    if sh.done:
      w.done = true
      w.error = sh.error
      result = true
