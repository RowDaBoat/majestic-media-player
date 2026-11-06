## The visualizer in the video frame: AVS presets (src/avs/) rendered on a
## thread of their own from what the player plays (src/audiotap.nim), shown
## as a texture.
##
## The worker owns the engine (every AVS object lives on its thread); the main
## thread hands it the frame size, the volume and preset files, and takes the
## newest frame. Presets come built in (Winamp's own, assets/avs/) and from
## the user's folder (`dir`, the config dir's `avs/`), any depth, where
## Visualizers' Add... copies presets with their images (`importPreset`).

import std/[os, locks, monotimes, times, strutils, algorithm, random, sets, math, tables, strformat]
import opengl, vmath, bumpy
import videogl, audiotap
import avs/engine
from avs/core import Pixels, csrand
import avs/eel as avseel except csrand

const
  BuiltinNames = [
    "Justin - groove.avs", "Tag - Bitter Paper.avs", "Tag - Lightspeed.avs",
    "Tag - Trance Travel.avs", "justin - bouncing colorfade.avs",
    "justin - bumpaphobia mk2.avs",
    "justin - joy.avs", "justin - mirrored neatness.avs", "justin - new interferences rule.avs",
    "justin - pretty dots.avs", "justin - pulsing orb of love.avs", "justin - quite nice.avs",
    "justin - say trip.avs", "justin - scope to smoke.avs", "justin - spiro.avs",
    "justin - steve likes it.avs", "justin - superscope love.avs", "justin - too much sex.avs",
    "justin and tag - brainbug 2 remix.avs", "lone - Arkanoid Legent.avs",
    "lone - Gold shower 3D (justinmod).avs", "lone - Living power ball.avs",
    "lone - No way to go 3.avs", "lone - Nuclear Blobs.avs",
    "lone - Oh my god, it's full of stars (justinmod).avs", "lone - Shirka's eye.avs",
    "lone - Spacefolding inside a Black Hole.avs", "lone - Wind in mind.avs", "new taste.avs",
    "pulsing shit.avs", "yay mk ii dots.avs", "yay mk ii.avs", "yay mk iii.avs", "yay.avs"]
  BuiltinPrefix* = "builtin:"
  MaxFps* = 60               ## the display's ticks a second, and the fastest steps
  MinRate* = 5
  MaxRenderWidth* = 960       ## wider frames render smaller and are scaled up

proc builtinData(): seq[string] {.compileTime.} =
  for n in BuiltinNames: result.add staticRead("../assets/avs/" & n)

const BuiltinData = builtinData()

type
  Shared = object
    lock: Lock
    cond: Cond
    want, quit: bool
    w, h: int
    gain: float32
    rate: int                 ## the preset's steps a second (MaxFps: one a tick)
    beatFloor: int
    beatMargin: float
    posMs, lenSec: float64
    tap: AudioTap
    frame: ptr UncheckedArray[uint32]
    fw, fh, cap: int
    frameSeq: int
    loaded: int               ## presets loaded so far (failed ones count too)
    failed: bool              ## the last preset wasn't one

  Load = object
    name, data: string

  AvsView* = ref object
    sh: ptr Shared
    thread: Thread[ptr Shared]
    started: bool
    tex: GLuint
    texW, texH: int
    shown: int
    presets*: seq[string]     ## builtin:NAME or a file's path
    current*: int             ## index into presets, -1 for none yet
    dir*: string
    extra*: seq[string]       ## files added from elsewhere (Visualizers...), listed too
    hidden*: seq[string]      ## the folder's files removed from the list
    disabled*: HashSet[string]  ## presets turned off: not in the menu, not stepped to
    rates*: Table[string, int]  ## presets stepped slower than MaxFps: steps a second

var loads: Channel[Load]

proc blendFrames(o: ptr UncheckedArray[uint32], a, b: seq[uint32], n, t: int) =
  ## o = a + (b - a) * t / 256, each channel.
  let u = uint32(256 - t)
  let t = uint32(t)
  for i in 0 ..< n:
    let p = a[i]
    let q = b[i]
    let rb = ((p and 0xff00ff'u32) * u + (q and 0xff00ff'u32) * t) shr 8
    let ag = ((p shr 8) and 0xff00ff'u32) * u + ((q shr 8) and 0xff00ff'u32) * t
    o[i] = (rb and 0xff00ff'u32) or (ag and 0xff00ff00'u32)

proc worker(sh: ptr Shared) {.thread.} =
  # Every AVS object and table the engine uses lives on this thread (threadvars,
  # or read-only once built): the effect system can't see through its methods.
  {.cast(gcsafe).}:
    let eng = newAvsEngine()
    csrand(uint32(getTime().toUnix and 0xffffffff))
    var left, right: array[1024, float32]
    let start = getMonoTime()
    var next = getMonoTime()
    var trFrames, trAud = 0  # AVSTRACE
    var trPeak = 0'f32  # AVSTRACE
    var trLast = getMonoTime()  # AVSTRACE
    var prev, cur: seq[uint32]  # the last two steps
    var haveCur = false
    var acc = 1.0               # steps owed: one is taken at 1, the rest blends
    while true:
      var w, h, rate: int
      var gain: float32
      acquire(sh.lock)
      while not sh.want and not sh.quit: wait(sh.cond, sh.lock)
      let quit = sh.quit
      w = sh.w
      h = sh.h
      gain = sh.gain
      rate = clamp(sh.rate, MinRate, MaxFps)
      eng.beatFloor = sh.beatFloor
      eng.beatMargin = sh.beatMargin
      avseel.env.posMs = sh.posMs
      avseel.env.lenSec = sh.lenSec
      release(sh.lock)
      if quit: break
      while true:
        let (ok, msg) = loads.tryRecv()
        if not ok: break
        let trT0 = getMonoTime()  # AVSTRACE
        let good = eng.loadPresetData(msg.data, msg.name)
        (acc, haveCur) = (1.0, false)  # no blending into the last preset's steps
        stderr.writeLine "AVSTRACE load ", (getMonoTime() - trT0).inMilliseconds, " ms ", msg.name.extractFilename, " ok=", good  # AVSTRACE
        acquire(sh.lock)
        inc sh.loaded
        sh.failed = not good
        release(sh.lock)
      if w < 8 or h < 2:
        sleep(20)
        continue
      let hasAud = sh.tap.latest(left, right)  # AVSTRACE
      block:  # AVSTRACE
        var pk = 0'f32
        for v in left: pk = max(pk, abs(v))
        inc trFrames
        if hasAud: inc trAud
        trPeak = max(trPeak, pk)
        if (getMonoTime() - trLast).inMilliseconds >= 1000:
          stderr.writeLine "AVSTRACE t=", (getMonoTime() - start).inMilliseconds, " frames=", trFrames, " withAudio=", trAud, " peak=", trPeak, " gain=", gain
          trFrames = 0; trAud = 0; trPeak = 0; trLast = getMonoTime()
      if gain != 1:
        for v in left.mitems: v *= gain
        for v in right.mitems: v *= gain
      # Audio goes in every tick (beats found wait for the next step); the
      # preset steps at its own rate.
      eng.setAudio(left, right)
      acc += rate / MaxFps
      if cur.len != w * h:  # a new size: start again from a step
        acc = 1
        haveCur = false
      if acc >= 1:
        acc = min(acc - 1, 0.999)
        let tick = uint32((getMonoTime() - start).inMilliseconds and 0xffffffff)
        var px: Pixels
        try:
          px = eng.render(w, h, tick)
        except CatchableError, Defect:
          # A preset that breaks the engine is dropped rather than the player.
          discard eng.loadPresetData("Nullsoft AVS Preset 0.2\x1a\x00\x00\x00")
          continue
        if cur.len != w * h:
          cur.setLen(w * h)
          prev.setLen(w * h)
        swap(prev, cur)
        copyMem(cur[0].addr, px[0].addr, w * h * 4)
        if not haveCur: copyMem(prev[0].addr, cur[0].addr, w * h * 4)
        haveCur = true
      acquire(sh.lock)
      if sh.cap < w * h:
        if sh.frame != nil: deallocShared(sh.frame)
        sh.frame = cast[ptr UncheckedArray[uint32]](allocShared(w * h * 4))
        sh.cap = w * h
      if rate >= MaxFps:
        copyMem(sh.frame[0].addr, cur[0].addr, w * h * 4)
      else:
        # Slower than the display: the picture between the last two steps,
        # a step behind, so it moves every tick rather than every few.
        blendFrames(sh.frame, prev, cur, w * h, int(acc * 256))
      sh.fw = w
      sh.fh = h
      inc sh.frameSeq
      release(sh.lock)
      next = next + initDuration(microseconds = 1_000_000 div MaxFps)
      let now = getMonoTime()
      if next > now: sleep(int((next - now).inMilliseconds))
      else: next = now

proc newAvsView*(dir: string): AvsView =
  result = AvsView(current: -1, dir: dir)
  for n in BuiltinNames: result.presets.add BuiltinPrefix & n

proc rescan*(v: AvsView) =
  ## The presets: the built-in ones, then the folder's, sorted by path.
  let cur = if v.current in 0 ..< v.presets.len: v.presets[v.current] else: ""
  v.presets = @[]
  for n in BuiltinNames: v.presets.add BuiltinPrefix & n
  var found: seq[string]
  if v.dir.len > 0 and dirExists(v.dir):
    for f in walkDirRec(v.dir):
      if f.toLowerAscii.endsWith(".avs"): found.add f
  found.sort(proc (a, b: string): int = cmpIgnoreCase(a, b))
  for f in found:
    if f notin v.hidden: v.presets.add f
  for f in v.extra:
    if f notin v.presets and fileExists(f): v.presets.add f
  v.current = v.presets.find(cur)

proc isBuiltin*(id: string): bool = id.startsWith(BuiltinPrefix)

proc enabled*(v: AvsView, i: int): bool =
  i in 0 ..< v.presets.len and v.presets[i] notin v.disabled

proc presetData*(id: string): string =
  ## A preset's bytes: built in, or its file's; "" when it can't be read.
  if id.startsWith(BuiltinPrefix):
    let k = BuiltinNames.find(id[BuiltinPrefix.len .. ^1])
    if k >= 0: return BuiltinData[k]
  else:
    try: return readFile(id)
    except IOError, OSError: discard

proc presetName*(id: string): string =
  ## A preset's name as shown: the file name without .avs.
  let n = if id.startsWith(BuiltinPrefix): id[BuiltinPrefix.len .. ^1] else: id.extractFilename
  if n.toLowerAscii.endsWith(".avs"): n[0 ..< n.len - 4] else: n

proc sameBytes(a, b: string): bool =
  try: getFileSize(a) == getFileSize(b) and readFile(a) == readFile(b)
  except IOError, OSError: false

proc copyIn(src, dest: string, rename: bool): string =
  ## src copied to dest, made where it's missing; a file there already with
  ## src's bytes is taken as the copy. A different one: with rename, the copy
  ## goes beside it as "NAME (2).ext" (the first number free); without, it's
  ## left alone and nothing is copied. The copy's path, "" when there is none.
  let (dir, name, ext) = dest.splitFile
  var to = dest
  var n = 1
  while fileExists(to) or dirExists(to):
    if sameBytes(src, to): return to
    if not rename: return ""
    inc n
    to = dir / &"{name} ({n}){ext}"
  try:
    createDir(dir)
    copyFile(src, to)
    to
  except IOError, OSError:
    try: removeFile(to)  # a partial copy
    except OSError: discard
    ""

proc inPresetsFolder*(v: AvsView, path: string): bool =
  v.dir.len > 0 and path.isRelativeTo(v.dir) and path != v.dir

proc importPreset*(v: AvsView, src, srcRoot, destRoot: string): string =
  ## Copies the preset file src into the presets folder: to destRoot, at its
  ## path under srcRoot, with the images it uses (found as it loads) where it
  ## finds them, at their paths under srcRoot too, or beside it. One already
  ## in the folder stays where it is. The preset's path in the folder, "" if
  ## it couldn't be copied.
  if v.inPresetsFolder(src): return src
  let data = try: readFile(src) except IOError, OSError: return ""
  result = copyIn(src, destRoot / relativePath(src, srcRoot), rename = true)
  if result.len == 0: return
  for f in presetFiles(data, src):
    if v.inPresetsFolder(f): continue
    let to = if f.isRelativeTo(srcRoot): destRoot / relativePath(f, srcRoot)
             else: result.parentDir / f.extractFilename
    discard copyIn(f, to, rename = false)

proc ensureStarted(v: AvsView) =
  if v.started: return
  v.started = true
  loads.open()
  v.sh = cast[ptr Shared](allocShared0(sizeof(Shared)))
  initLock(v.sh.lock)
  initCond(v.sh.cond)
  v.sh.gain = 1
  v.sh.tap = startTap()
  createThread(v.thread, worker, v.sh)

proc select*(v: AvsView, i: int): bool =
  ## Loads preset i; false if it couldn't be read.
  if i notin 0 ..< v.presets.len: return false
  v.ensureStarted()
  let id = v.presets[i]
  var data: string
  if id.startsWith(BuiltinPrefix):
    let k = BuiltinNames.find(id[BuiltinPrefix.len .. ^1])
    if k < 0: return false
    data = BuiltinData[k]
  else:
    try: data = readFile(id)
    except IOError, OSError: return false
  loads.send(Load(name: id, data: data))
  v.current = i
  true

proc selectId*(v: AvsView, id: string): bool =
  let i = v.presets.find(id)
  if i >= 0: v.select(i) else: false

proc step*(v: AvsView, d: int): bool =
  ## The next (d=1) or previous (d=-1) preset turned on, wrapping.
  let n = v.presets.len
  var i = v.current
  for _ in 0 ..< n:
    i = if i < 0: (if d > 0: 0 else: n - 1) else: (i + d + n) mod n
    if v.enabled(i): return v.select(i)
  false

proc randomPreset*(v: AvsView): bool =
  ## Any other preset turned on (the current one if it's the only one).
  var pool: seq[int]
  for i in 0 ..< v.presets.len:
    if v.enabled(i) and i != v.current: pool.add i
  if pool.len == 0:
    return v.enabled(v.current) and v.select(v.current)
  v.select(pool[rand(pool.high)])

proc rateOf*(v: AvsView, id: string): int =
  ## How many times a second preset id steps: AVS presets move a set amount
  ## each frame, so ones made on slower computers play too fast at MaxFps.
  clamp(v.rates.getOrDefault(id, MaxFps), MinRate, MaxFps)

proc renderSize*(area: Vec2): (int, int) =
  ## The frame size for an area in pixels: at most MaxRenderWidth wide, the
  ## width a multiple of 8 and the height even (as AVS wanted).
  var w = max(area.x, 16)
  var h = max(area.y, 16)
  if w > MaxRenderWidth:
    h = h * MaxRenderWidth / w
    w = MaxRenderWidth
  (max(16, (int(w) div 8) * 8), max(16, (int(h) div 2) * 2))

proc update*(v: AvsView, visible: bool, area: Vec2, gain: float32, posMs, lenSec: float64,
             beatThreshold = 100.0, beatSensitivity = 100.0): bool =
  ## Tells the worker what's wanted; true when a new frame waits to be shown.
  ## beatThreshold: the level beats need, in % of Winamp's; beatSensitivity:
  ## how readily they come over the recent peaks, in % of Winamp's (marginFor).
  if not visible and not v.started: return false
  v.ensureStarted()
  let (w, h) = renderSize(area)
  acquire(v.sh.lock)
  let was = v.sh.want
  v.sh.want = visible
  v.sh.w = w
  v.sh.h = h
  v.sh.gain = gain
  v.sh.rate = if v.current in 0 ..< v.presets.len: v.rateOf(v.presets[v.current]) else: MaxFps
  v.sh.beatFloor = int(round(BeatFloor.float * max(beatThreshold, 0) / 100))
  v.sh.beatMargin = marginFor(beatSensitivity)
  v.sh.posMs = posMs
  v.sh.lenSec = lenSec
  result = visible and v.sh.frameSeq != v.shown
  if visible and not was: signal(v.sh.cond)
  release(v.sh.lock)

var trShown, trDraws = 0  # AVSTRACE
var trShownAt = getMonoTime()  # AVSTRACE

proc draw*(v: AvsView, q: QuadRenderer, area: Rect, fb: IVec2) =
  ## The newest frame, stretched over area (framebuffer pixels).
  if not v.started: return
  inc trDraws  # AVSTRACE
  if (getMonoTime() - trShownAt).inMilliseconds >= 1000:  # AVSTRACE
    stderr.writeLine "AVSTRACE main draws=", trDraws, " uploads=", trShown, " tex=", v.tex, " ", v.texW, "x", v.texH  # AVSTRACE
    trShown = 0; trDraws = 0; trShownAt = getMonoTime()  # AVSTRACE
  acquire(v.sh.lock)
  if v.sh.frameSeq != v.shown and v.sh.frame != nil:
    if v.tex == 0:
      glGenTextures(1, v.tex.addr)
      glBindTexture(GL_TEXTURE_2D, v.tex)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
      # AVS leaves the top byte as it likes: the picture is opaque.
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_A, GL_ONE.GLint)
    glBindTexture(GL_TEXTURE_2D, v.tex)
    if v.texW != v.sh.fw or v.texH != v.sh.fh:
      v.texW = v.sh.fw
      v.texH = v.sh.fh
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, v.texW.GLsizei, v.texH.GLsizei, 0,
                   GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, v.sh.frame)
    else:
      glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, v.texW.GLsizei, v.texH.GLsizei,
                      GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, v.sh.frame)
    glBindTexture(GL_TEXTURE_2D, 0)
    v.shown = v.sh.frameSeq
    inc trShown  # AVSTRACE
  release(v.sh.lock)
  if v.tex != 0 and v.texW > 0:
    q.draw(v.tex, rectCorners(area.xy, area.wh), fb.vec2)

proc hasFrame*(v: AvsView): bool = v.tex != 0 and v.texW > 0

proc lastFailed*(v: AvsView): bool =
  if not v.started: return false
  acquire(v.sh.lock)
  result = v.sh.failed
  release(v.sh.lock)

proc close*(v: AvsView) =
  ## Stops the worker and the tap (at exit).
  if not v.started: return
  acquire(v.sh.lock)
  v.sh.quit = true
  signal(v.sh.cond)
  release(v.sh.lock)
  joinThread(v.thread)
  stopTap(v.sh.tap)
  v.started = false
