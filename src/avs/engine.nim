# Ported from Advanced Visualization Studio 2.81d, Copyright 2005 Nullsoft, Inc.
# BSD license: assets/licenses/AVS-Nullsoft-BSD.txt

## An AVS instance: a preset, its two frame buffers, and the audio data it
## sees each frame (main.cpp's render thread and Winamp's vis feed).
##
## Winamp handed AVS 576 waveform samples (8-bit signed) and 576 spectrum
## values (0..255) per channel; AVS ran the spectrum through a log table and
## detected beats from the waveform's energy. Here the samples come as floats
## (the newest last), the spectrum from a Hann-windowed FFT of the newest
## 1024 samples spread over 576 bands.

import std/[math, complex, os, strutils]
import core, list, effects

const
  WaveLen* = 576
  BeatFloor* = WaveLen * 16   ## main.cpp's: an average level of 16 out of 128
  BeatMargin* = 2 / 32        ## main.cpp's: how far over the recent peaks a beat is
  FftLen = 1024

type
  AvsEngine* = ref object
    root*: EffectList
    path*: string
    fb: array[2, seq[uint32]]
    s: int
    w*, h*: int
    vis*: VisData
    beatPeak1, beatPeak2, beatCnt, beatPeak1Peak: int
    beatFloor*: int           ## the level (summed |samples|) a beat must pass
    beatMargin*: float        ## how far over the recent peaks' level it must be
    beatHeld: bool            ## a beat fed since the last frame (main.cpp's g_is_beat)
    fedSince: bool            ## audio fed since the last frame: its spectrum keeps the peaks
    logtab: array[256, uint8]
    window: array[FftLen, float64]

var registered {.threadvar.}: bool

proc newAvsEngine*(): AvsEngine =
  if not registered:
    registerAll()
    registered = true
  resetVarsOnRecompile = true
  result = AvsEngine(root: newEffectList(root = true), beatFloor: BeatFloor,
    beatMargin: BeatMargin)
  for x in 0 .. 255:
    let a = ln(x.float64 * 60.0 / 255.0 + 1.0) / ln(60.0)
    result.logtab[x] = uint8(clamp(int(a * 255.0), 0, 255))
  for i in 0 ..< FftLen:
    result.window[i] = 0.5 - 0.5 * cos(2 * PI * i.float64 / (FftLen - 1).float64)

proc loadPresetData*(e: AvsEngine, data: string, path = ""): bool =
  ## Swaps in the preset in data (an .avs file's bytes); false if it isn't one.
  resetMultiDelay()
  presetFilesFound.setLen 0
  presetDir = (if path.len > 0 and not path.startsWith("builtin:"): path.parentDir else: "")
  let root = loadPreset(data.toOpenArrayByte(0, data.len - 1))
  if root == nil: return false
  e.root = root
  e.path = path
  for b in globalBuffers.mitems: b = GlobalBuffer()
  true

proc presetFiles*(data, path: string): seq[string] =
  ## The files (images) the preset in data, the file at path, uses: loaded
  ## to find them, never run.
  discard newAvsEngine().loadPresetData(data, path)
  result = presetFilesFound
  presetFilesFound.setLen 0

proc fft(a: var seq[Complex64]) =
  ## In-place radix-2 FFT.
  let n = a.len
  var j = 0
  for i in 1 ..< n:
    var bit = n shr 1
    while (j and bit) != 0:
      j = j xor bit
      bit = bit shr 1
    j = j xor bit
    if i < j: swap(a[i], a[j])
  var len = 2
  while len <= n:
    let ang = -2 * PI / len.float64
    let wl = complex(cos(ang), sin(ang))
    var i = 0
    while i < n:
      var w = complex(1.0, 0.0)
      for k in 0 ..< len div 2:
        let u = a[i + k]
        let v = a[i + k + len div 2] * w
        a[i + k] = u + v
        a[i + k + len div 2] = u - v
        w = w * wl
      i += len
    len = len shl 1

proc channel(e: AvsEngine, ch: int, src: openArray[float32]) =
  let n = src.len
  for i in 0 ..< WaveLen:
    let k = n - WaveLen + i
    let v = if k >= 0: src[k].float64 else: 0.0
    e.vis[1][ch][i] = int8(clamp(int(round(v * 128.0)), -128, 127))
  var buf = newSeq[Complex64](FftLen)
  for i in 0 ..< FftLen:
    let k = n - FftLen + i
    buf[i] = complex((if k >= 0: src[k].float64 else: 0.0) * e.window[i], 0.0)
  fft(buf)
  for i in 0 ..< WaveLen:
    # 576 bands over the 512 bins, linearly.
    let pos = i.float64 * (FftLen div 2 - 1).float64 / (WaveLen - 1).float64
    let k = int(pos)
    let f = pos - k.float64
    let m = abs(buf[k]) * (1 - f) + abs(buf[min(k + 1, FftLen div 2 - 1)]) * f
    # Music's highs are far weaker than its lows: tilted up (x6 at the top),
    # they show as Winamp's analyzer showed them.
    let tilt = 1.0 + 5.0 * i.float64 / (WaveLen - 1).float64
    let v = clamp(int(m * (255.0 / 256.0) * 4.0 * tilt), 0, 255)
    let t = e.logtab[v]
    # Fed again before a frame took the last: the peaks of both, as AVS's
    # render() kept them between frames (g_visdata_pstat).
    if not e.fedSince or t > cast[uint8](e.vis[0][ch][i]): e.vis[0][ch][i] = cast[int8](t)

proc detectBeat*(e: AvsEngine): bool
proc setAudio*(e: AvsEngine, left, right: openArray[float32]) =
  ## The newest samples, FftLen or more per channel (older first). Fed more
  ## often than frames render (as Winamp fed AVS, at its own pace), a beat
  ## found in any waits for the next frame, and the spectrum keeps its peaks.
  e.channel(0, left)
  e.channel(1, right)
  e.fedSince = true
  if e.detectBeat(): e.beatHeld = true

proc marginFor*(sensitivity: float): float =
  ## beatMargin for a sensitivity in %: 100 is main.cpp's 1/16 over the peaks,
  ## 200 none (about twice the beats), 300 1/16 under them; 0 twice main.cpp's.
  BeatMargin * (2 - sensitivity / 100)

proc detectBeat*(e: AvsEngine): bool =
  ## main.cpp's beat detection, on the waveform bytes: a beat is a level
  ## beatMargin over the recent peaks' (main.cpp's 1/16), and over beatFloor
  ## (main.cpp's BeatFloor, which quiet music never reaches).
  var lt = [0, 0]
  for ch in 0 .. 1:
    for x in 0 ..< WaveLen:
      var r = int(cast[uint8](e.vis[1][ch][x]) xor 128) - 128
      if r < 0: r = -r
      lt[ch] += r
  let l = max(lt[0], lt[1])
  e.beatPeak1 = (e.beatPeak1 * 125 + e.beatPeak2 * 3) div 128
  inc e.beatCnt
  if l >= int(float(e.beatPeak1) * (1 + e.beatMargin)) and l > e.beatFloor:
    if e.beatCnt > 0:
      e.beatCnt = 0
      result = true
    e.beatPeak1 = (l + e.beatPeak1Peak) div 2
    e.beatPeak1Peak = l
  elif l > e.beatPeak2:
    e.beatPeak2 = l
  else:
    e.beatPeak2 = (e.beatPeak2 * 14) div 16

proc render*(e: AvsEngine, w, h: int, tick: uint32): Pixels =
  ## Renders a frame at w x h (w a multiple of 8, h even); the result stays
  ## valid until the next call.
  if w != e.w or h != e.h:
    let old = (e.fb[e.s], e.w, e.h)
    for b in e.fb.mitems: b = newSeq[uint32](w * h)
    # Keep the picture (scaled) across a resize, as AVS could.
    if old[1] > 0 and old[2] > 0:
      for y in 0 ..< h:
        let sy = y * old[2] div h
        for x in 0 ..< w:
          e.fb[0][y * w + x] = old[0][sy * old[1] + x * old[1] div w]
    e.s = 0
    e.w = w
    e.h = h
  tickCount = tick
  env.visdata = addr e.vis
  env.tickMs = tick
  let beat = e.beatHeld
  e.beatHeld = false
  e.fedSince = false
  let a = pixelsOf(e.fb[e.s])
  let b = pixelsOf(e.fb[e.s xor 1])
  let t = e.root.render(e.vis, int32(beat), a, b, w, h)
  if (t and 1) != 0: e.s = e.s xor 1
  pixelsOf(e.fb[e.s])
