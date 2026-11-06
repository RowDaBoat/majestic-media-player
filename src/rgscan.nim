## ReplayGain 2.0 values worked out for files and written to their tags (the
## playlist menu's ReplayGain > Analyze and Apply as Tracks / as Album).
##
## Each file's first audio track is decoded by ffmpeg into a WAV on a pipe
## (its header gives the rate and the channel layout) and measured on a
## thread of its own, as EBU R128 / ITU-R BS.1770-4 asks: K-weighted, in
## 400 ms blocks every 100 ms, gated at -70 LUFS and then 10 LU under the
## mean. The gain takes it to -18 LUFS; the peak is the highest sample.
## An album's loudness gates every file's blocks together, the same as one
## long file (summing per-file values would not), so the blocks are kept.
##
## Tags: REPLAYGAIN_{TRACK,ALBUM}_{GAIN,PEAK} ("-6.54 dB", "0.988831"), what
## mpv reads; Opus files get R128_{TRACK,ALBUM}_GAIN instead (Q7.8 relative
## to -23 LUFS, RFC 7845), which mpv reads as well.

import std/[os, osproc, streams, strutils, math, locks, tables]
import tagedit

const
  RgReference* = -18.0     ## LUFS a gain takes the file to
  AbsGate = -70.0
  RelGate = -10.0
  RgKeys = ["REPLAYGAIN_TRACK_GAIN", "REPLAYGAIN_TRACK_PEAK",
            "REPLAYGAIN_ALBUM_GAIN", "REPLAYGAIN_ALBUM_PEAK"]
  R128Keys = ["R128_TRACK_GAIN", "R128_ALBUM_GAIN"]

type
  Measure* = object
    path*: string
    error*: string            ## why it wasn't measured; "" when it was
    loudness*: float          ## LUFS, integrated
    peak*: float              ## highest sample, 1.0 full scale
    blocks: seq[float]        ## mean square of each 400 ms block over the absolute gate

  RgMode* = enum
    rmTrack                   ## each file its own track gain; album tags untouched
    rmAlbum                   ## track gains, and the album gain of them all

  RgJob* = ref object
    mode*: RgMode
    paths*: seq[string]
    results*: seq[Measure]    ## the files measured so far, in order
    written*: int             ## of them, tagged
    tagged*: seq[string]      ## files tagged since the caller last emptied it
    failed*: seq[string]      ## "name: why", for every file not tagged
    writing*: bool            ## measured; the album's tags are being written
    done*: bool
    cancelled*: bool

  Shared = object
    lock: Lock
    cond: Cond                ## a job given to the worker, or one it finished
    job: WorkArg              ## the next job, when pending
    pending: bool
    results: seq[Measure]
    index: int                ## file being measured
    frac: float               ## how far into it, 0..1
    written: int
    tagged, failed: seq[string]  ## tagged: since poll last took them
    writing, finished, cancel: bool
    ffmpeg: Process

  WorkArg = object
    mode: RgMode
    paths: seq[string]
    durations: seq[float]

# One worker for every job, started with the first and never ended. Nim's
# allocator hands a block freed on another thread back to the heap of the
# thread that allocated it, which goes with that thread when it ends: the
# results and failures it leaves in sh are freed on the main thread (by the
# next start), so the thread that made them has to still be there.
var
  sh: Shared
  worker: Thread[void]
  inited: bool

# --- loudness --------------------------------------------------------------

type
  Biquad = object
    b0, b1, b2, a1, a2: float
  BiquadState = object
    x1, x2, y1, y2: float

proc kWeighting(fs: float): (Biquad, Biquad) =
  ## The two stages of BS.1770's K-weighting at any sample rate (the
  ## coefficients libebur128 derives from the 48 kHz ones).
  block:
    let f0 = 1681.974450955533
    let g = 3.999843853973347
    let q = 0.7071752369554196
    let k = tan(PI * f0 / fs)
    let vh = pow(10.0, g / 20)
    let vb = pow(vh, 0.4996667741545416)
    let a0 = 1 + k / q + k * k
    result[0] = Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0,
      b2: (vh - vb * k / q + k * k) / a0, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
  block:
    let f0 = 38.13547087602444
    let q = 0.5003270373238773
    let k = tan(PI * f0 / fs)
    let a0 = 1 + k / q + k * k
    result[1] = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)

proc run(f: Biquad, s: var BiquadState, x: float): float {.inline.} =
  result = f.b0 * x + f.b1 * s.x1 + f.b2 * s.x2 - f.a1 * s.y1 - f.a2 * s.y2
  s.x2 = s.x1; s.x1 = x
  s.y2 = s.y1; s.y1 = result

proc lufs(ms: float): float = -0.691 + 10 * log10(ms)

proc gated(blocks: openArray[float]): float =
  ## Integrated loudness of blocks already over the absolute gate; NaN with none.
  if blocks.len == 0: return NaN
  var sum = 0.0
  for b in blocks: sum += b
  let rel = pow(10.0, (lufs(sum / blocks.len.float) + RelGate + 0.691) / 10)
  var (s, n) = (0.0, 0)
  for b in blocks:
    if b > rel: s += b; inc n
  if n == 0: NaN else: lufs(s / n.float)

proc channelWeights(n: int, mask: uint32): seq[float] =
  ## BS.1770's channel weights: surrounds 1.41, LFE left out. Without a mask
  ## (mono, stereo), every channel counts once.
  result = newSeq[float](n)
  var bit = 0
  for c in 0 ..< n:
    result[c] = 1.0
    if mask == 0: continue
    while bit < 32 and (mask and (1'u32 shl bit)) == 0: inc bit
    case bit
    of 3: result[c] = 0.0                   # LFE
    of 4, 5, 9, 10: result[c] = 1.41        # back and side left/right
    else: discard
    inc bit

proc readU16(s: openArray[byte], i: int): int = s[i].int or s[i + 1].int shl 8
proc readU32(s: openArray[byte], i: int): uint32 =
  s[i].uint32 or s[i + 1].uint32 shl 8 or s[i + 2].uint32 shl 16 or s[i + 3].uint32 shl 24

proc fourcc(s: openArray[byte], i: int): string =
  for k in i ..< i + 4: result.add char(s[k])

proc progress(index: int, frac: float) =
  withLock sh.lock:
    sh.index = index
    sh.frac = frac

proc cancelled(): bool =
  withLock sh.lock: result = sh.cancel

proc measure(path: string, duration: float, index: int): Measure {.gcsafe.} =
  result.path = path
  let args = @["-v", "fatal", "-nostdin", "-i", path, "-map", "0:a:0", "-vn", "-sn", "-dn",
               "-c:a", "pcm_f32le", "-f", "wav", "-"]
  var p: Process
  try: p = startProcess("ffmpeg", args = args, options = {poUsePath})
  except OSError:
    result.error = "ffmpeg can't be run"
    return
  {.cast(gcsafe).}:
    withLock sh.lock: sh.ffmpeg = p
  defer:
    {.cast(gcsafe).}:
      withLock sh.lock: sh.ffmpeg = nil
    p.close()
  let o = p.outputStream
  # Header: RIFF, then chunks up to "data"; ffmpeg's pipe WAV has fmt first.
  var head: array[12, byte]
  if o.readData(head[0].addr, 12) != 12 or fourcc(head, 0) != "RIFF":
    discard p.waitForExit()
    let err = p.errorStream.readAll.strip
    result.error = if "matches no streams" in err: "no audio"
                   elif err.len > 0: err.splitLines[^1]
                   else: "ffmpeg can't decode it"
    return
  var rate = 0
  var chans = 0
  var mask = 0'u32
  while true:
    var ch: array[8, byte]
    if o.readData(ch[0].addr, 8) != 8:
      result.error = "ffmpeg's output ended early"
      return
    let id = fourcc(ch, 0)
    let size = readU32(ch, 4).int
    if id == "data": break
    var body = newSeq[byte](size + (size and 1))
    if body.len > 0 and o.readData(body[0].addr, body.len) != body.len:
      result.error = "ffmpeg's output ended early"
      return
    if id == "fmt " and size >= 16:
      chans = readU16(body, 2)
      rate = readU32(body, 4).int
      if size >= 24 and readU16(body, 0) == 0xFFFE: mask = readU32(body, 20)
  if rate <= 0 or chans <= 0:
    result.error = "ffmpeg gave no audio format"
    return
  let (st1, st2) = kWeighting(rate.float)
  var s1 = newSeq[BiquadState](chans)
  var s2 = newSeq[BiquadState](chans)
  let w = channelWeights(chans, mask)
  let sub = max(1, int(round(rate / 10)))   # 100 ms
  let absGate = pow(10.0, (AbsGate + 0.691) / 10)
  var subs: array[4, float]                  # the last four 100 ms sums
  var subCount = 0
  var acc = 0.0
  var inSub = 0
  var frames = 0
  var buf = newSeq[float32](4096 * chans)
  var leftover = 0                           # bytes of a partial frame held in buf
  let total = if duration > 0: duration * rate.float else: 0.0
  var nextReport = 0
  while true:
    let want = buf.len * 4 - leftover
    let got = o.readData(cast[ptr UncheckedArray[byte]](buf[0].addr)[leftover].addr, want)
    if got <= 0: break
    let bytes = leftover + got
    let n = bytes div (4 * chans)
    for i in 0 ..< n:
      var e = 0.0
      for c in 0 ..< chans:
        let x = buf[i * chans + c].float
        if abs(x) > result.peak: result.peak = abs(x)
        if w[c] != 0:
          let y = st2.run(s2[c], st1.run(s1[c], x))
          e += w[c] * y * y
      acc += e
      inc inSub
      if inSub == sub:
        subs[subCount mod 4] = acc
        inc subCount
        acc = 0; inSub = 0
        if subCount >= 4:
          let ms = (subs[0] + subs[1] + subs[2] + subs[3]) / float(4 * sub)
          if ms > absGate: result.blocks.add ms
    frames += n
    leftover = bytes - n * 4 * chans
    if leftover > 0:
      moveMem(buf[0].addr, cast[ptr UncheckedArray[byte]](buf[0].addr)[n * 4 * chans].addr, leftover)
    if frames >= nextReport:
      nextReport = frames + rate div 4
      {.cast(gcsafe).}:
        if total > 0: progress(index, min(1.0, frames.float / total))
        if cancelled():
          result.error = "cancelled"
          return
  discard p.waitForExit()
  result.loudness = gated(result.blocks)
  if result.loudness.isNaN:
    result.error = if frames == 0: "no audio decoded" else: "silent or under 0.4 s"

# --- tags -------------------------------------------------------------------

proc fmtGain(g: float): string = formatFloat(g, ffDecimal, 2) & " dB"
proc fmtPeak(p: float): string = formatFloat(p, ffDecimal, 6)
proc q78(g: float): string = $int(round(clamp(g, -128.0, 127.99) * 256))

proc isOpus(path: string): bool = path.splitFile.ext.toLowerAscii == ".opus"

proc writeGain(path: string, track: Measure, album: ptr tuple[loudness, peak: float]): string =
  ## Writes track's (and album's) values into path's tags; "" or why not.
  let r = readTags(path)
  if not r.ok: return "its tags can't be read"
  var tags = r.tags
  let tg = RgReference - track.loudness
  if isOpus(path):
    # R128 gains are relative to -23 LUFS; a REPLAYGAIN_* left behind would
    # disagree with them.
    for k in RgKeys: tags.del k
    tags["R128_TRACK_GAIN"] = @[q78(-23.0 - track.loudness)]
    if album != nil: tags["R128_ALBUM_GAIN"] = @[q78(-23.0 - album.loudness)]
  else:
    tags["REPLAYGAIN_TRACK_GAIN"] = @[fmtGain(tg)]
    tags["REPLAYGAIN_TRACK_PEAK"] = @[fmtPeak(track.peak)]
    if album != nil:
      tags["REPLAYGAIN_ALBUM_GAIN"] = @[fmtGain(RgReference - album.loudness)]
      tags["REPLAYGAIN_ALBUM_PEAK"] = @[fmtPeak(album.peak)]
  let w = writeTags(path, tags)
  if not w.ok: return w.error
  if w.dropped.len > 0: return "this format can't hold " & w.dropped.join(", ")

proc removeGain*(path: string): string =
  ## Takes every ReplayGain field out of path's tags; "" or why not.
  let r = readTags(path)
  if not r.ok: return "its tags can't be read"
  var tags = r.tags
  for k in RgKeys: tags.del k
  for k in R128Keys: tags.del k
  if tags.len == r.tags.len: return ""
  let w = writeTags(path, tags)
  if not w.ok: w.error else: ""

proc apply(m: Measure, album: ptr tuple[loudness, peak: float]) =
  ## Writes m's values to its file's tags (on the thread: a FLAC without
  ## room for them is rewritten whole, a second or more each), noting how
  ## it went for poll.
  let err = writeGain(m.path, m, album)
  withLock sh.lock:
    if err.len > 0: sh.failed.add m.path.extractFilename & ": " & err
    else:
      inc sh.written
      sh.tagged.add m.path

proc work(arg: WorkArg) =
  ## Measures every file, then tags them: each as it's measured for track
  ## gains, all of them at the end for an album's.
  {.cast(gcsafe).}:
    var measured: seq[(int, Measure)]   # path index, measure
    for i, path in arg.paths:
      if cancelled(): break
      progress(i, 0)
      let m = measure(path, arg.durations[i], i)
      withLock sh.lock:
        sh.results.add m
        if m.error.len > 0 and m.error != "cancelled":
          sh.failed.add path.extractFilename & ": " & m.error
      if m.error.len > 0: continue
      if arg.mode == rmTrack:
        if cancelled(): break
        apply(m, nil)
      else: measured.add (i, m)
    if arg.mode == rmAlbum and measured.len > 0 and not cancelled():
      var blocks: seq[float]
      var album: tuple[loudness, peak: float]
      for (_, m) in measured:
        blocks.add m.blocks
        album.peak = max(album.peak, m.peak)
      album.loudness = gated(blocks)
      if album.loudness.isNaN:
        withLock sh.lock: sh.failed.add "the album: silent"
      else:
        withLock sh.lock: sh.writing = true
        for k, (i, m) in measured:
          if cancelled(): break
          progress(i, k / measured.len)
          apply(m, album.addr)
    withLock sh.lock:
      sh.finished = true
      broadcast(sh.cond)

proc workLoop() {.thread.} =
  ## Runs each job start gives it, one at a time, for as long as the program runs.
  {.cast(gcsafe).}:
    while true:
      var arg: WorkArg
      withLock sh.lock:
        while not sh.pending: wait(sh.cond, sh.lock)
        sh.pending = false
        arg = sh.job
      work(arg)

# --- the job ------------------------------------------------------------------

proc canWriteTags*(): bool =
  ## TagLib is there to write with.
  tagedit.available()

proc running*(j: RgJob): bool = j != nil and not j.done

proc start*(paths: seq[string], durations: seq[float], mode: RgMode): RgJob =
  ## Measures paths on a thread and tags them as poll finds them measured.
  ## durations (0 where unknown) only make the progress smoother.
  if not inited:
    initLock sh.lock
    initCond sh.cond
    sh.finished = true
    createThread(worker, workLoop)
    inited = true
  discard tagedit.load()   # its library's globals, set before the thread uses them
  withLock sh.lock:
    while not sh.finished: wait(sh.cond, sh.lock)   # the last job's tail, if any
    sh.results = @[]
    sh.index = 0
    sh.frac = 0
    sh.written = 0
    sh.tagged = @[]
    sh.failed = @[]
    sh.writing = false
    sh.finished = false
    sh.cancel = false
    sh.job = WorkArg(mode: mode, paths: paths, durations: durations)
    sh.pending = true
    signal(sh.cond)
  result = RgJob(mode: mode, paths: paths)

proc progress*(j: RgJob): tuple[index: int, percent: float] =
  ## The file being measured and how far along all of them are; while an
  ## album's tags are written (j.writing), the file being tagged and how
  ## many of them are.
  withLock sh.lock:
    result = if sh.writing: (sh.index, sh.frac * 100)
             else: (sh.index, (sh.index.float + sh.frac) * 100 / max(1, j.paths.len).float)

proc cancel*(j: RgJob) =
  withLock sh.lock:
    sh.cancel = true
    if sh.ffmpeg != nil:
      try: sh.ffmpeg.kill() except OSError: discard
  j.cancelled = true

proc poll*(j: RgJob): bool =
  ## Takes in what the thread measured and tagged. True when anything
  ## changed. Never waits on the thread's work: the tags are written there.
  if not j.running: return
  var finished: bool
  withLock sh.lock:
    result = j.results.len != sh.results.len or j.written != sh.written or
             j.failed.len != sh.failed.len or j.writing != sh.writing or sh.finished
    for i in j.results.len ..< sh.results.len: j.results.add sh.results[i]
    for i in j.failed.len ..< sh.failed.len: j.failed.add sh.failed[i]
    j.written = sh.written
    j.writing = sh.writing
    j.tagged.add sh.tagged
    sh.tagged.setLen 0
    finished = sh.finished
  if finished: j.done = true
