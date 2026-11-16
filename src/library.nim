## Media libraries (the Library panel, Options > Libraries): the folders and
## files each library lists, walked for media on threads of their own into one
## index that every library reads from, their tags read afterwards.
##
## Nothing here touches a library's files on the calling (main) thread: a
## folder on a network share or a drive pulled out can block a call for
## minutes, so walking, checking that a path is there and reading tags all
## happen on worker threads, and the main thread only takes in what they post.
## A worker waiting on one call for too long is noted as not responding (its
## path says so) and another takes over the remaining work. Workers run at
## idle priority and pace themselves while something plays.
##
## Workers are started as needed and never end: Nim's allocator hands a block
## freed on another thread back to the heap of the thread that allocated it,
## which goes with that thread, and what a worker posts is freed on the main
## thread (see rgscan).

import std/[os, strutils, tables, sets, locks, times, algorithm, json, unicode, math, hashes, sequtils]
import jsony
import config, mpv, wsaud, m2c

const
  IndexVersion = 1
  MaxWalkers = 3          ## walking threads at work at once (not counting stuck ones)
  MaxThreads = 12         ## threads ever started, stuck ones included
  MaxProbers = 3          ## of them, tag readers ever started
  StuckAfter = 8.0        ## seconds on one call before a worker counts as not responding
  ProbeTimeout = 10.0     ## seconds for mpv to open a file before it's given up on
  ProbeRestBusy = 120     ## ms between files while something plays
  ProbeQueueLen = 24      ## paths handed to the tag readers ahead
  BatchSize = 200         ## files posted at once by a walk
  RootTimeouts = 2        ## files timing out in a root before its others are left unread
  TagValueMax = 400       ## characters kept of a tag's value

type
  LibFile* = object
    ## A media file of the index. Until `probed`, only what walking the
    ## folder gave (path, size, time) is known.
    path*: string
    size*: int64
    mtime*: int64           ## seconds since 1970
    ctime*: int64           ## when the file was created (its birth time), seconds since 1970; 0: unknown
    sideTime*: int64        ## when its .m2c (m2c) was written, seconds since 1970; 0: none
    probed*: bool           ## its tags were read (or reading them failed)
    duration*: float        ## seconds
    width*, height*: int    ## the first real video track's; 0 without one
    bitrate*: float         ## bits per second: the whole file's for video, the audio's otherwise
    title*, artist*, album*: string
    tags*: seq[(string, string)]  ## every tag: key in lower case, value
    seen*: int              ## the walk that last found it (this session)

  RootState* = enum
    rsUnknown = "not checked yet"
    rsScanning = "scanning"
    rsReady = "ready"
    rsMissing = "missing"
    rsStuck = "not responding"
    rsError = "can't be read"

  RootInfo* = object
    state*: RootState
    isFile*: bool
    gen: int                ## the walk under way (or last done)
    walked: bool            ## walked (a top folder), rather than checked
    found*: int             ## files the walk found so far
    expected: int           ## files the index had under it as the walk began (0: none known)
    error*: string
    timeouts: int           ## files that timed out while their tags were read
    prior: RootState        ## the state before the walk under way
    cancelled: bool         ## the walk under way was cancelled; its thread hasn't said it stopped
    rewalk: bool            ## walk it again once the cancelled walk stops

  EvKind = enum
    evFound, evDone, evLoaded, evProbed, evBeat

  Found = object
    path: string
    size, mtime, ctime, sideTime: int64

  Event = object
    kind: EvKind
    root: string
    gen: int
    files: seq[Found]
    state: RootState
    isFile: bool
    err: string
    cancelled: bool         ## evDone: the walk stopped partway, cancelled
    loaded: seq[LibFile]
    probed: LibFile
    timedOut: bool
    worker: int

  JobKind = enum
    jkWalk, jkLoad

  Job = object
    kind: JobKind
    path: string
    exts: seq[string]       ## what a walk keeps (lower case, no dot)
    gen: int
    walk: bool              ## a folder's files are listed (a top folder), else only checked

  WorkerRole = enum
    wrWalker, wrProber

  WorkerState = object
    role: WorkerRole
    busy: bool
    beat: float             ## the last sign of life while busy
    path: string            ## what it's on: the root walked, the file read
    stuck: bool             ## noted as not responding (by poll)

  Shared = object
    lock: Lock
    cond: Cond              ## a job for the walkers
    probeCond: Cond         ## a file for the tag readers
    jobs: seq[Job]
    probeQueue: seq[string]
    events: seq[Event]
    busy: bool              ## something plays: go slowly
    cancelGen: int          ## walks up to this one are cancelled
    workers: int            ## threads started
    ws: array[MaxThreads, WorkerState]

  CmpOp = enum
    coEq, coGt, coLt

  TermKind = enum
    tkText, tkSize, tkBitrate, tkDim, tkFormat, tkFilename, tkField, tkPath, tkCreated

  Term = object
    kind: TermKind
    op: CmpOp
    text: string            ## lower case
    keys: seq[string]       ## tkField: the tag keys it reads (normalized)
    lo, hi: float           ## a number's range (tkSize, tkBitrate, single-number tkDim)
    w, h: int               ## tkDim: WxH, 0 for a single number
    bad: bool               ## tkCreated: the date couldn't be read (matches nothing)

  Query* = object
    ## A search: tags separated by commas.
    terms: seq[Term]
    formats: seq[string]    ## format: tags (any of them)
    within*, excludes*: seq[string]  ## within: / exclude: values (libraries), lower case
    folders*: seq[string]   ## in: values (folders, any of them): folderValue, or an
                            ## absolute path as typed (normPath)
    hidden*: bool           ## hidden: hidden libraries searched too
    empty*: bool            ## nothing that narrows the search

  LibIndex* = ref object
    files*: seq[LibFile]
    byPath: Table[string, int]
    roots*: Table[string, RootInfo]  ## every path the libraries list, normalized
    exts: seq[string]       ## what walks keep: every library's types
    explicit: HashSet[string]  ## the files listed as such (kept whatever their type)
    gen*: int               ## bumped by every change to `files`
    dropGen*: int           ## bumped by files leaving `files` (indices move)
    attic: Table[string, LibFile]  ## files that left, with their tags, should they come back
    metaGen*: int           ## bumped by tags read
    loaded, loading: bool
    active*: bool           ## scanning has begun this session
    walkGen: int
    pending: seq[string]    ## roots to walk once the saved index is in
    queued: HashSet[string] ## files handed to the tag readers
    probeCursor: int
    dirty: bool             ## changed since saved
    savedAt: float
    probeFails: HashSet[string]  ## timed out this session: not tried again
    stale: HashSet[string]  ## queued when its tags changed: that reading's are the old ones
    hay: seq[string]        ## per file, what free text is looked for in, lower case
    dirs: seq[string]       ## per file, its folders for in: tags (dirsOf)
    hayKey: (int, int, int) ## the gen, dropGen and metaGen it was made at
    feedAt: float           ## when to look through the index for files to read again
    unreadCount: int        ## files whose tags are to be read, as last counted
    unreadAt: float
    runFrom: int            ## the first walk of the scan under way (or last made)
    readDone: int           ## tags read since the reading last ran out of files
    stopped*: bool          ## the scan was cancelled: no tags are read until the next walk

var
  sh: Shared
  threads: array[MaxThreads, Thread[int]]
  inited: bool

# --- paths ------------------------------------------------------------------------

proc normPath*(p: string): string =
  ## A library path as compared and keyed: ~ expanded, absolute, no trailing
  ## separator, without touching the file system.
  result = p.strip.expandTilde
  if result.len == 0: return
  if not result.isAbsolute: result = getCurrentDir() / result
  result = result.normalizedPath
  while result.len > 1 and result[^1] in {DirSep, AltSep} and
      not (defined(windows) and result.len == 3 and result[1] == ':'):
    result.setLen result.len - 1

proc under*(path, dir: string): bool =
  ## Whether path is dir or lies inside it.
  if path.len < dir.len: return false
  when defined(windows):
    let (p, d) = (path.toLowerAscii, dir.toLowerAscii)
  else:
    let (p, d) = (path, dir)
  p.startsWith(d) and (p.len == d.len or p[d.len] in {DirSep, AltSep} or d[^1] in {DirSep, AltSep})

proc extOf*(path: string): string =
  path.splitFile.ext.toLowerAscii.strip(chars = {'.'})

proc libraryExts*(l: Library): seq[string] =
  ## The file types a library lists.
  case l.kind
  of lkAudio: @AudioExtensions & @TrackerExtensions & @MidiExtensions
  of lkVideo: @VideoExtensions
  of lkAll: MediaExtensions
  of lkCustom: l.exts

# --- worker threads ------------------------------------------------------------

when defined(linux):
  type SchedParam {.importc: "struct sched_param", header: "<sched.h>".} = object
    sched_priority: cint
  proc sched_setscheduler(pid: cint, policy: cint, param: ptr SchedParam): cint {.
    importc, header: "<sched.h>".}
  proc setpriority(which: cint, who: cuint, prio: cint): cint {.importc, header: "<sys/resource.h>".}
  proc syscall(n: clong): clong {.importc, header: "<unistd.h>", varargs.}
  var SYS_gettid {.importc, header: "<sys/syscall.h>".}: clong
  var SYS_ioprio_set {.importc, header: "<sys/syscall.h>".}: clong
elif defined(windows):
  proc GetCurrentThread(): pointer {.importc, stdcall, dynlib: "kernel32".}
  proc SetThreadPriority(h: pointer, p: cint): cint {.importc, stdcall, dynlib: "kernel32".}

proc lowerPriority() =
  ## The calling thread runs only when nothing else wants the processor, and
  ## its disk reads wait for everyone else's. Threads it starts (mpv's) inherit it.
  when defined(linux):
    var sp: SchedParam
    if sched_setscheduler(0, 5, sp.addr) != 0:  # SCHED_IDLE
      discard setpriority(0, cuint(syscall(SYS_gettid)), 19)
    discard syscall(SYS_ioprio_set, 1.cint, 0.cint, cint(3 shl 13))  # IOPRIO_WHO_PROCESS, this thread, IDLE class
  elif defined(windows):
    discard SetThreadPriority(GetCurrentThread(), 0x00010000)  # THREAD_MODE_BACKGROUND_BEGIN

proc beat(i: int) =
  {.cast(gcsafe).}:
    withLock sh.lock:
      sh.ws[i].beat = epochTime()
      if sh.ws[i].stuck:
        sh.ws[i].stuck = false
        sh.events.add Event(kind: evBeat, worker: i, root: sh.ws[i].path)

proc post(e: sink Event) =
  {.cast(gcsafe).}:
    withLock sh.lock: sh.events.add e

proc busy(): bool =
  {.cast(gcsafe).}:
    withLock sh.lock: result = sh.busy

proc cancelled(gen: int): bool =
  ## Whether walk gen was cancelled.
  {.cast(gcsafe).}:
    withLock sh.lock: result = gen <= sh.cancelGen

proc skipName(name: string): bool =
  name.len == 0 or name[0] == '.' or name in ["$RECYCLE.BIN", "System Volume Information", "lost+found"]

when defined(linux):
  {.localPassC: "-D_GNU_SOURCE".}
  type
    StatxTime {.importc: "struct statx_timestamp", header: "<sys/stat.h>", bycopy.} = object
      tv_sec: int64
    Statx {.importc: "struct statx", header: "<sys/stat.h>", bycopy.} = object
      stx_mask: uint32
      stx_btime: StatxTime
  proc statx(dirfd: cint, path: cstring, flags: cint, mask: cuint, buf: var Statx): cint
    {.importc, header: "<sys/stat.h>".}

proc birthTime(path: string, fi: FileInfo): int64 =
  ## When the file was created, seconds since 1970; 0 when the file system
  ## doesn't keep it (some network shares and older ones on Linux).
  when defined(windows): fi.creationTime.toUnix
  elif defined(linux):
    const AtFdCwd = -100.cint
    const StatxBtime = 0x800.cuint
    var st: Statx
    if statx(AtFdCwd, path.cstring, 0, StatxBtime, st) == 0 and (st.stx_mask and StatxBtime) != 0:
      st.stx_btime.tv_sec
    else: 0
  else: 0

proc walk(i: int, job: Job) =
  ## Lists a top folder's media files (or checks a path is there), posting
  ## them in batches as they're found.
  var done = Event(kind: evDone, root: job.path, gen: job.gen, state: rsReady)
  if cancelled(job.gen):
    done.cancelled = true
    post done
    return
  var info: FileInfo
  try: info = getFileInfo(job.path)
  except OSError as e:
    done.state = if fileExists(job.path) or dirExists(job.path): rsError else: rsMissing
    if done.state == rsError: done.err = e.msg
    post done
    return
  beat(i)
  if info.kind in {pcFile, pcLinkToFile}:
    done.isFile = true
    post Event(kind: evFound, root: job.path, gen: job.gen,
      files: @[Found(path: job.path, size: info.size, mtime: info.lastWriteTime.toUnix,
                     ctime: birthTime(job.path, info), sideTime: sideTime(job.path))])
    post done
    return
  if not job.walk:
    post done
    return
  var exts = initHashSet[string]()
  for e in job.exts: exts.incl e
  var batch: seq[Found]
  var lastPost = epochTime()
  var seenDirs = initHashSet[(DeviceId, FileId)]()
  seenDirs.incl info.id
  var stack = @[job.path]
  var count = 0
  while stack.len > 0:
    # What was found goes out before each folder: one that never answers
    # mustn't keep the others' files back.
    if batch.len > 0:
      post Event(kind: evFound, root: job.path, gen: job.gen, files: move batch)
      batch = @[]
      lastPost = epochTime()
    if cancelled(job.gen):
      done.cancelled = true
      post done
      return
    let dir = stack.pop()
    # A folder with .m2c files (m2c): its files' times too, for their tags.
    let sides = dirExists(dir / SideDir)
    try:
      for kind, path in walkDir(dir):
        inc count
        if count mod 64 == 0:
          beat(i)
          if cancelled(job.gen):
            done.cancelled = true
            post done
            return
          if count mod 512 == 0 and busy(): sleep(2)
        let name = path.extractFilename
        if name.skipName: continue
        case kind
        of pcDir, pcLinkToDir:
          try:
            let di = getFileInfo(path)
            if not seenDirs.containsOrIncl(di.id): stack.add path
          except OSError: discard
        of pcFile, pcLinkToFile:
          if path.extOf notin exts: continue
          try:
            let fi = getFileInfo(path)
            batch.add Found(path: path, size: fi.size, mtime: fi.lastWriteTime.toUnix,
                            ctime: birthTime(path, fi),
                            sideTime: if sides: sideTime(path) else: 0)
          except OSError: discard
        if batch.len >= BatchSize or (batch.len > 0 and epochTime() - lastPost > 0.25):
          post Event(kind: evFound, root: job.path, gen: job.gen, files: move batch)
          batch = @[]
          lastPost = epochTime()
    except OSError: discard  # a folder that can't be read is left out
  if batch.len > 0: post Event(kind: evFound, root: job.path, gen: job.gen, files: move batch)
  post done

proc loadIndex(path: string) =
  var e = Event(kind: evLoaded)
  try:
    if fileExists(path):
      let j = readFile(path).fromJson(tuple[version: int, files: seq[LibFile]])
      if j.version == IndexVersion: e.loaded = j.files
  except CatchableError as err:
    stderr.writeLine "library: ignoring unreadable ", path, ": ", err.msg
  post e

proc walkerLoop(i: int) {.thread.} =
  {.cast(gcsafe).}:
    lowerPriority()
    while true:
      var job: Job
      withLock sh.lock:
        sh.ws[i].busy = false
        sh.ws[i].path = ""
        while sh.jobs.len == 0: wait(sh.cond, sh.lock)
        job = sh.jobs[0]
        sh.jobs.delete(0)
        sh.ws[i].busy = true
        sh.ws[i].beat = epochTime()
        sh.ws[i].path = job.path
      case job.kind
      of jkWalk: walk(i, job)
      of jkLoad: loadIndex(job.path)

const PreloadedHook = 1'u64

proc newProbeMpv(): MpvHandle =
  ## mpv opening files without playing anything: no tracks picked, so
  ## nothing is decoded, only the container read. With none picked mpv
  ## gives up on the file before it's loaded, so it's read in the
  ## on_preloaded hook, where the tracks and tags are known.
  let h = mpv_create()
  if h == nil: return nil
  for (k, v) in [("config", "no"), ("terminal", "no"), ("msg-level", "all=no"), ("vo", "null"),
                 ("ao", "null"), ("vid", "no"), ("aid", "no"), ("sid", "no"), ("hwdec", "no"),
                 ("pause", "yes"), ("idle", "yes"), ("keep-open", "yes"),
                 ("load-scripts", "no"), ("ytdl", "no"), ("cache", "no"), ("sub-auto", "no"),
                 ("audio-file-auto", "no"), ("cover-art-auto", "no"), ("input-default-bindings", "no")]:
    try: h.setOpt(k, v)
    except MpvError: discard
  if mpv_initialize(h) < 0:
    mpv_terminate_destroy(h)
    return nil
  discard mpv_hook_add(h, PreloadedHook, "on_preloaded", 0)
  h

proc readTags(f: var LibFile, tags: JsonNode) =
  if tags.kind != JObject: return
  var albumArtist = ""
  for k, v in tags:
    let key = k.toLowerAscii
    var s = v.getStr.strip
    if s.len == 0: continue
    if s.runeLen > TagValueMax: s = s.runeSubStr(0, TagValueMax)
    f.tags.add (key, s)
    case key
    of "title": f.title = s
    of "artist": f.artist = s
    of "album_artist", "albumartist": albumArtist = s
    of "album": f.album = s
    else: discard
  if f.artist.len == 0: f.artist = albumArtist

proc probeFile(i: int, h: MpvHandle, path: string): (LibFile, bool) =
  ## Reads path's duration, picture size, bit rate and tags; true when mpv
  ## didn't answer in time (it may be stuck in the file's open for good).
  var f = LibFile(path: path, probed: true)
  discard h.command("loadfile", path, "replace")
  let deadline = epochTime() + ProbeTimeout
  while true:
    let left = deadline - epochTime()
    if left <= 0: return (f, true)
    let ev = mpv_wait_event(h, min(0.5, left))
    beat(i)
    case ev.eventId
    of evHook:
      let id = cast[ptr MpvEventHook](ev.data).id
      if ev.replyUserdata != PreloadedHook or h.getStr("path") != path:
        discard mpv_hook_continue(h, id)  # a file given up on before
        continue
      f.duration = h.getFloat("duration")
      if path.isAudFile and path.audLength > 0: f.duration = path.audLength  # FFmpeg guesses long
      let tracks = h.getNode("track-list")
      var abr = 0.0
      if tracks.kind == JArray:
        for t in tracks:
          let kind = t{"type"}.getStr
          if kind == "video" and not t{"albumart"}.getBool and f.width == 0:
            f.width = t{"demux-w"}.getInt
            f.height = t{"demux-h"}.getInt
          elif kind == "audio" and abr == 0:
            abr = t{"demux-bitrate"}.getFloat
      let size = h.getInt("file-size", -1)
      let whole = if size > 0 and f.duration > 0: size.float * 8 / f.duration else: 0.0
      f.bitrate = if f.width > 0 or abr <= 0: whole else: abr
      f.readTags(h.getNode("metadata").overlay(readSide(path)))  # and its .m2c's
      discard mpv_hook_continue(h, id)
      return (f, false)
    of evEndFile:
      if cast[ptr MpvEventEndFile](ev.data).reason == efError:
        # mpv can't open it (a MIDI file, here): a .m2c's tags all the same.
        f.readTags(newJObject().overlay(readSide(path)))
        return (f, false)
    of evShutdown: return (f, false)
    else: discard

proc proberLoop(i: int) {.thread.} =
  {.cast(gcsafe).}:
    lowerPriority()
    var h: MpvHandle = nil
    var holding = false
    while true:
      var path: string
      var slow: bool
      withLock sh.lock:
        sh.ws[i].busy = false
        sh.ws[i].path = ""
        if sh.probeQueue.len == 0 and holding and h != nil:
          release(sh.lock)
          discard h.command("stop")  # lets go of the last file (a drive may be pulled out)
          acquire(sh.lock)
          holding = false
        while sh.probeQueue.len == 0: wait(sh.probeCond, sh.lock)
        path = sh.probeQueue[0]
        sh.probeQueue.delete(0)
        sh.ws[i].busy = true
        sh.ws[i].beat = epochTime()
        sh.ws[i].path = path
        slow = sh.busy
      if h == nil: h = newProbeMpv()
      var f = LibFile(path: path, probed: true)
      var timedOut = false
      if h != nil:
        (f, timedOut) = probeFile(i, h, path)
        holding = true
      if timedOut:
        # Stuck opening it, maybe for good: that mpv is left behind, as
        # closing it would wait for the open too.
        h = nil
        holding = false
      post Event(kind: evProbed, probed: f, timedOut: timedOut, worker: i)
      if slow: sleep(ProbeRestBusy)

proc initShared() =
  if inited: return
  initLock sh.lock
  initCond sh.cond
  initCond sh.probeCond
  inited = true

proc startWorker(role: WorkerRole): bool =
  ## Starts another thread; false once MaxThreads have been. Call under the lock.
  if sh.workers >= MaxThreads: return false
  let i = sh.workers
  inc sh.workers
  sh.ws[i] = WorkerState(role: role, busy: false)
  if role == wrWalker: createThread(threads[i], walkerLoop, i)
  else: createThread(threads[i], proberLoop, i)
  true

proc staffUp() =
  ## Enough healthy threads for the work waiting. Call under the lock.
  var (walkers, idleWalkers, probers, healthyProbers) = (0, 0, 0, 0)
  for i in 0 ..< sh.workers:
    let w = sh.ws[i]
    if w.role == wrWalker:
      if not w.stuck: inc walkers
      if not w.busy: inc idleWalkers
    else:
      inc probers
      if not w.stuck: inc healthyProbers
  if sh.jobs.len > idleWalkers and walkers < MaxWalkers:
    for _ in 0 ..< min(sh.jobs.len - idleWalkers, MaxWalkers - walkers):
      if not startWorker(wrWalker): break
  if sh.probeQueue.len > 0 and healthyProbers == 0 and probers < MaxProbers:
    discard startWorker(wrProber)

# --- the index ---------------------------------------------------------------------

proc indexPath(): string = getCacheDir("majestic-media-player") / "library.json"

proc newLibIndex*(): LibIndex =
  LibIndex(savedAt: epochTime())

proc setBusy*(ix: LibIndex, playing: bool) =
  ## Something plays (or is paused partway): the workers go slowly.
  if not inited: return
  withLock sh.lock: sh.busy = playing

proc enqueue(ix: LibIndex, job: Job) =
  initShared()
  withLock sh.lock:
    sh.jobs.add job
    staffUp()
    signal(sh.cond)

proc topRoots(ix: LibIndex): seq[string] =
  ## Folders walked: those not inside another listed folder.
  for p, r in ix.roots:
    if r.isFile: continue
    var inside = false
    for q, s in ix.roots:
      if q != p and not s.isFile and p.under(q) and (q.len < p.len or q < p): inside = true
    if not inside: result.add p
  result.sort()

proc scanning*(ix: LibIndex): bool

proc walkRoot(ix: LibIndex, root: string) =
  ## Walks a top folder, or checks a file or a folder inside another. One
  ## whose last walk is still going (or stuck) isn't walked again: each walk
  ## of a path that never answers would hold up another thread for good.
  if not ix.loaded:
    if root notin ix.pending: ix.pending.add root
    return
  let r = ix.roots[root].addr
  if r.state in {rsScanning, rsStuck}: return
  if r.cancelled:  # walked again once the cancelled walk's thread is free
    r.rewalk = true
    ix.stopped = false
    return
  ix.stopped = false
  if not ix.scanning: ix.runFrom = ix.walkGen + 1
  inc ix.walkGen
  r.gen = ix.walkGen
  r.found = 0
  r.walked = root in ix.topRoots
  r.expected = 0
  r.prior = r.state
  if r.walked:
    # What the last walk (or the saved index) had: how far this one is.
    for f in ix.files:
      if f.path.under(root): inc r.expected
  r.state = rsScanning
  ix.enqueue Job(kind: jkWalk, path: root, exts: ix.exts, gen: ix.walkGen, walk: r.walked)

proc rescan*(ix: LibIndex) =
  ## Walks every library path again.
  ix.stopped = false
  for p in toSeq(ix.roots.keys).sorted: ix.walkRoot(p)
  ix.unreadAt = 0

proc cancelScan*(ix: LibIndex) =
  ## Stops the walks under way (their files found so far are kept, none
  ## dropped for not being found) and the reading of tags, until the next
  ## walk (Rescan, a path added). A walk stuck on a path that doesn't
  ## answer can't be stopped: its root isn't walked again until it returns.
  ix.stopped = true
  ix.pending.setLen 0
  if inited:
    withLock sh.lock:
      sh.cancelGen = ix.walkGen
      for p in sh.probeQueue: ix.queued.excl p
      sh.probeQueue.setLen 0
  for r in ix.roots.mvalues:
    if r.state in {rsScanning, rsStuck}:
      r.cancelled = true
      r.rewalk = false
      r.state = r.prior
  ix.unreadAt = 0
  inc ix.gen

proc activate*(ix: LibIndex) =
  ## Starts using the index: reads the saved one and walks every path once.
  if ix.active: return
  ix.active = true
  ix.loading = true
  ix.enqueue Job(kind: jkLoad, path: indexPath())
  ix.rescan()

proc covered(ix: LibIndex, path: string): bool =
  ## Whether a library still lists path (a folder holding it, or it).
  for p, r in ix.roots:
    if path.under(p): return true

proc dropFile(ix: LibIndex, i: int) =
  let last = ix.files.high
  if ix.files[i].probed: ix.attic[ix.files[i].path] = ix.files[i]
  inc ix.dropGen
  ix.byPath.del ix.files[i].path
  if i != last:
    ix.files[i] = move ix.files[last]
    ix.byPath[ix.files[i].path] = i
  ix.files.setLen last
  ix.probeCursor = min(ix.probeCursor, max(0, ix.files.len - 1))
  ix.dirty = true

proc configure*(ix: LibIndex, libs: seq[Library]) =
  ## Follows the libraries as set: new paths are walked, ones no library
  ## lists anymore leave the index with their files, and a change of types
  ## walks everything again.
  var exts: seq[string]
  var wanted: seq[string]
  ix.explicit.clear()
  for l in libs:
    for e in l.libraryExts:
      let e = e.toLowerAscii.strip(chars = {'.', '*', ' '})
      if e.len > 0 and e notin exts: exts.add e
    for p in l.paths:
      let n = p.normPath
      if n.len > 0 and n notin wanted: wanted.add n
  exts.sort()
  let extsChanged = exts != ix.exts
  ix.exts = exts
  var gone: seq[string]
  for p in ix.roots.keys:
    if p notin wanted: gone.add p
  for p in gone: ix.roots.del p
  var added: seq[string]
  for p in wanted:
    if p notin ix.roots:
      ix.roots[p] = RootInfo()
      added.add p
  for p in wanted:
    if ix.roots[p].isFile: ix.explicit.incl p
  if gone.len > 0 or extsChanged:
    var i = 0
    while i < ix.files.len:
      let f = ix.files[i].addr
      if not ix.covered(f.path) or (f.path.extOf notin exts and f.path notin ix.explicit):
        ix.dropFile(i)
      else: inc i
    inc ix.gen
  elif added.len > 0: inc ix.gen  # the folders searched are below the listed ones
  if not ix.active: return
  if extsChanged: ix.rescan()
  else:
    for p in added: ix.walkRoot(p)

proc addFound(ix: LibIndex, f: Found, gen: int) =
  let i = ix.byPath.getOrDefault(f.path, -1)
  if i < 0:
    ix.byPath[f.path] = ix.files.len
    var g = LibFile(path: f.path, size: f.size, mtime: f.mtime, ctime: f.ctime,
                    sideTime: f.sideTime, seen: gen)
    var old: LibFile
    if ix.attic.pop(f.path, old) and old.size == f.size and old.mtime == f.mtime and
       old.sideTime == f.sideTime:
      g = old
      g.seen = gen
      g.ctime = f.ctime
    ix.files.add g
    ix.dirty = true
  else:
    let e = ix.files[i].addr
    e.seen = gen
    if e.size != f.size or e.mtime != f.mtime or e.sideTime != f.sideTime:
      e[] = LibFile(path: f.path, size: f.size, mtime: f.mtime, ctime: f.ctime,
                    sideTime: f.sideTime, seen: gen)
      ix.queued.excl f.path
      ix.dirty = true
    elif e.ctime != f.ctime:  # an index saved before creation times were kept, or a file put back
      e.ctime = f.ctime
      ix.dirty = true

proc walkDone(ix: LibIndex, e: Event) =
  if e.root notin ix.roots: return
  let r = ix.roots[e.root].addr
  if r.gen != e.gen: return  # an older walk's
  if r.cancelled:
    # Stopped (or done anyway, just as it was cancelled): what it found
    # is kept, nothing it didn't is dropped; the state is as before it.
    r.cancelled = false
    if r.rewalk:
      r.rewalk = false
      ix.walkRoot(e.root)
    return
  r.state = e.state
  r.error = e.err
  if e.state == rsReady:
    r.isFile = e.isFile
    if e.isFile:
      r.walked = false
      ix.explicit.incl e.root
  if e.state == rsReady and r.walked:
    # What this walk didn't find is gone (top folders don't overlap), but
    # for files listed themselves, which their own check keeps.
    var i = 0
    while i < ix.files.len:
      let f = ix.files[i].addr
      if f.seen != e.gen and f.path notin ix.explicit and f.path.under(e.root):
        ix.dropFile(i)
        continue
      inc i
  inc ix.gen

proc applyLoaded(ix: LibIndex, files: seq[LibFile]) =
  ## The saved index: tags of files still as they were, and the files of
  ## paths not walked yet (so the panel fills at once).
  for f in files:
    if not ix.covered(f.path): continue
    if f.path.extOf notin ix.exts and f.path notin ix.explicit: continue
    let i = ix.byPath.getOrDefault(f.path, -1)
    if i < 0:
      ix.byPath[f.path] = ix.files.len
      var g = f
      g.seen = 0
      ix.files.add g
    else:
      let e = ix.files[i].addr
      if not e.probed and f.probed and e.size == f.size and e.mtime == f.mtime and
         e.sideTime == f.sideTime:
        let seen = e.seen
        e[] = f
        e.seen = seen
  ix.loaded = true
  ix.loading = false
  inc ix.gen
  inc ix.metaGen
  let pending = move ix.pending
  for p in pending:
    if p in ix.roots: ix.walkRoot(p)

proc rootOf(ix: LibIndex, path: string): string =
  ## The longest library path holding path.
  for p, r in ix.roots:
    if path.under(p) and p.len > result.len: result = p

proc applyProbed(ix: LibIndex, e: Event) =
  let f = e.probed
  ix.queued.excl f.path
  if not ix.stale.missingOrExcl(f.path): return  # from before its tags changed
  if e.timedOut:
    ix.probeFails.incl f.path
    let root = ix.rootOf(f.path)
    if root.len > 0: inc ix.roots[root].timeouts
  let i = ix.byPath.getOrDefault(f.path, -1)
  if i < 0: return
  let x = ix.files[i].addr
  if x.probed: return
  (x.probed, x.duration, x.width, x.height, x.bitrate) = (true, f.duration, f.width, f.height, f.bitrate)
  (x.title, x.artist, x.album, x.tags) = (f.title, f.artist, f.album, f.tags)
  ix.dirty = true
  inc ix.metaGen
  inc ix.readDone

proc reprobe*(ix: LibIndex, path: string, sideTime: int64) =
  ## path's tags changed (Properties saved them, into it or its .m2c, which
  ## the caller says when was written): they're read again soon, as they
  ## are now. Touches no file: the next walk notes the file's own new size
  ## and time.
  let i = ix.byPath.getOrDefault(path, -1)
  if i < 0: return
  let f = ix.files[i].addr
  f.probed = false
  f.sideTime = sideTime
  if path in ix.queued: ix.stale.incl path  # read again once that reading is in
  ix.probeFails.excl path
  ix.feedAt = 0
  ix.dirty = true

proc wantsProbe(ix: LibIndex, i: int): bool =
  let f = ix.files[i].addr
  if f.probed or f.path in ix.queued or f.path in ix.probeFails: return false
  let root = ix.rootOf(f.path)
  if root.len == 0: return false
  let r = ix.roots[root]
  r.timeouts < RootTimeouts and r.state notin {rsMissing, rsError}

proc feedProbers(ix: LibIndex, first: seq[int]) =
  ## Keeps the tag readers' queue topped up: the rows in view first, then the
  ## rest from where the last look stopped. Looks through at most a slice of
  ## the index each time, and only now and then once nothing was left.
  ## Nothing while the scan is cancelled.
  if not ix.loaded or ix.stopped: return
  let now = epochTime()
  var room: int
  withLock sh.lock: room = ProbeQueueLen - sh.probeQueue.len
  if room <= ProbeQueueLen div 2: return
  var add: seq[string]
  for i in first:
    if add.len >= room: break
    if i in 0 ..< ix.files.len and ix.wantsProbe(i):
      add.add ix.files[i].path
      ix.queued.incl ix.files[i].path
  if now >= ix.feedAt:
    var n = 0
    while add.len < room and n < min(ix.files.len, 4000):
      if ix.probeCursor >= ix.files.len: ix.probeCursor = 0
      if ix.wantsProbe(ix.probeCursor):
        add.add ix.files[ix.probeCursor].path
        ix.queued.incl ix.files[ix.probeCursor].path
      inc ix.probeCursor
      inc n
    # A whole slice with nothing to read: look again in a while (new files
    # and tags read make sure of that sooner).
    if add.len == 0: ix.feedAt = now + 1.0
  if add.len == 0: return
  withLock sh.lock:
    # The rows in view go to the front.
    sh.probeQueue = add & sh.probeQueue
    staffUp()
    broadcast(sh.probeCond)

proc save*(ix: LibIndex) =
  ## Writes the index to the cache, for the panel to fill at once next time.
  if not ix.dirty or not ix.loaded: return
  ix.dirty = false
  ix.savedAt = epochTime()
  let path = indexPath()
  try:
    createDir(path.parentDir)
    writeAtomic(path, (version: IndexVersion, files: ix.files).toJson)
  except CatchableError as e:
    stderr.writeLine "library: cannot save ", path, ": ", e.msg

proc maybeSave*(ix: LibIndex, playing: bool) =
  ## Saves now and then: while nothing plays, a while after the last change;
  ## while something plays, only after a long while (a save takes a moment).
  if not ix.dirty: return
  let age = epochTime() - ix.savedAt
  if (not playing and age > 20) or age > 600: ix.save()

proc poll*(ix: LibIndex, visible: seq[int] = @[]): bool =
  ## Takes in what the workers found; true when anything changed. Cheap when
  ## nothing did: called every turn of the main loop.
  if not inited: return
  var events: seq[Event]
  var stuckNow, unstuck: seq[string]
  let now = epochTime()
  withLock sh.lock:
    swap(events, sh.events)
    for i in 0 ..< sh.workers:
      let w = sh.ws[i].addr
      if w.busy and not w.stuck and now - w.beat > StuckAfter:
        w.stuck = true
        stuckNow.add w.path
        if w.role == wrProber:
          # Whatever it's opening, the files beside it are left unread.
          stuckNow[^1] = "\0" & w.path
    if stuckNow.len > 0: staffUp()
  for p in stuckNow:
    result = true
    if p.len > 0 and p[0] == '\0':
      let file = p[1 .. ^1]
      ix.probeFails.incl file
      let root = ix.rootOf(file)
      if root.len > 0:
        ix.roots[root].timeouts = RootTimeouts
        ix.roots[root].state = rsStuck
    elif p in ix.roots and ix.roots[p].state == rsScanning:
      ix.roots[p].state = rsStuck
  for e in events:
    result = true
    case e.kind
    of evFound:
      if e.root in ix.roots and ix.roots[e.root].gen == e.gen and not ix.roots[e.root].cancelled:
        for f in e.files: ix.addFound(f, e.gen)
        ix.roots[e.root].found += e.files.len
        ix.feedAt = 0
        if ix.roots[e.root].state == rsStuck: ix.roots[e.root].state = rsScanning
        inc ix.gen
    of evDone: ix.walkDone(e)
    of evLoaded:
      ix.applyLoaded(e.loaded)
      ix.feedAt = 0
    of evProbed: ix.applyProbed(e)
    of evBeat:
      if e.root in ix.roots and ix.roots[e.root].state == rsStuck:
        ix.roots[e.root].state = rsScanning
  if result: ix.unreadAt = 0  # counted again when next asked
  ix.feedProbers(visible)

proc scanning*(ix: LibIndex): bool =
  ## Walking something, or reading the saved index.
  if ix.loading: return true
  for r in ix.roots.values:
    if r.state == rsScanning: return true

proc scanProgress*(ix: LibIndex): float =
  ## How far the scan under way is, 0..1, against what the folders walked
  ## held last time; -1 when that isn't known (reading the saved index, a
  ## folder walked for the first time).
  if ix.loading: return -1
  var found, total = 0
  for r in ix.roots.values:
    if not r.walked or r.gen < ix.runFrom: continue
    if r.state in {rsScanning, rsStuck}:
      if r.expected == 0: return -1
      # More files than last time: nearly done, as far as can be told.
      found += min(r.found, r.expected)
      total += max(r.expected, r.found + 1)
    else:
      found += r.found
      total += r.found
  if total == 0: -1.0 else: found / total

proc unread*(ix: LibIndex): int =
  ## Files whose tags are still to be read (and can be), counted at most
  ## twice a second.
  let now = epochTime()
  if now - ix.unreadAt > 0.5:
    ix.unreadAt = now
    ix.unreadCount = 0
    for i in 0 ..< ix.files.len:
      if ix.wantsProbe(i) or ix.files[i].path in ix.queued: inc ix.unreadCount
    if ix.unreadCount == 0: ix.readDone = 0
  ix.unreadCount

proc readProgress*(ix: LibIndex): float =
  ## How far reading the tags is, 0..1: the files read since it began
  ## against those and the ones left.
  let left = ix.unread
  if left == 0: 1.0 else: ix.readDone / (ix.readDone + left)

proc rootState*(ix: LibIndex, path: string): RootState =
  ix.roots.getOrDefault(path.normPath).state

proc find*(ix: LibIndex, path: string): int =
  ix.byPath.getOrDefault(path, -1)

# --- library views --------------------------------------------------------------

proc members*(ix: LibIndex, l: Library): seq[int32] =
  ## The index's files a library lists: inside its folders and of its
  ## types, or listed themselves; none under a path that's missing.
  var dirs, files: seq[string]
  for p in l.paths:
    let n = p.normPath
    if n.len == 0: continue
    let r = ix.roots.getOrDefault(n)
    if r.state == rsMissing: continue
    if r.isFile: files.add n else: dirs.add n
  var exts = initHashSet[string]()
  for e in l.libraryExts: exts.incl e.toLowerAscii.strip(chars = {'.', '*', ' '})
  for i in 0 ..< ix.files.len:
    let p = ix.files[i].path
    if p in files:
      result.add int32(i)
      continue
    if p.extOf notin exts: continue
    for d in dirs:
      if p.under(d):
        result.add int32(i)
        break

# --- searching ------------------------------------------------------------------

proc squash*(s: string): string =
  ## A key as compared: lower case, without spaces, dashes or underscores.
  for c in s.toLowerAscii:
    if c notin {' ', '_', '-', '\t'}: result.add c

const FieldAliases = {
  "artist": @["artist", "albumartist", "performer"],
  "albumartist": @["albumartist", "artist"],
  "year": @["date", "year", "originaldate", "originalyear"],
  "date": @["date", "year"],
  "track": @["track", "tracknumber"],
  "disc": @["disc", "discnumber", "disk"],
  "comment": @["comment", "description"]}.toTable

proc parseNumber(s: string, binaryK: bool): tuple[lo, hi: float, ok: bool] =
  ## "1.5 GB" -> the range of sizes that round to it at the precision given
  ## (1.45-1.55 GB). K/M/G/T: 1000s for bit rates, 1024s for sizes (as the
  ## player shows them), "kB"-style units without the i too.
  var t = s.strip.toLowerAscii.replace(",", ".").replace(" ", "")
  var i = 0
  while i < t.len and t[i] in {'0' .. '9', '.'}: inc i
  if i == 0: return
  let digits = t[0 ..< i]
  var v: float
  try: v = parseFloat(digits)
  except ValueError: return
  let dot = digits.find('.')
  let step = if dot < 0: 1.0 else: pow(10.0, -float(digits.len - dot - 1))
  var unit = t[i .. ^1]
  for suffix in ["/s", "ps", "bit", "bits", "bytes", "byte"]:
    if unit.endsWith(suffix) and unit.len > suffix.len: unit.setLen unit.len - suffix.len
  if unit.endsWith("ib"): unit.setLen unit.len - 2
  elif unit.len > 1 and unit[^1] == 'b': unit.setLen unit.len - 1
  let k = if binaryK: 1024.0 else: 1000.0
  let mul = case unit
    of "", "b": 1.0
    of "k": k
    of "m": k * k
    of "g": k * k * k
    of "t": k * k * k * k
    else: return
  (max(0.0, (v - step / 2) * mul), (v + step / 2) * mul, true)

proc parseDim(s: string, t: var Term): bool =
  ## "1920x1080", or one number for the shorter side: "1080", "1080p", "4k".
  var v = s.strip.toLowerAscii.replace(" ", "").replace("×", "x").replace("*", "x")
  let x = v.find('x')
  if x > 0:
    try:
      t.w = parseInt(v[0 ..< x])
      t.h = parseInt(v[x + 1 .. ^1])
      return t.w > 0 and t.h > 0
    except ValueError: return false
  if v.endsWith("p"): v.setLen v.len - 1
  let n = case v
    of "4k": 2160
    of "8k": 4320
    of "2k": 1440
    else:
      try: parseInt(v) except ValueError: return false
  t.lo = n.float
  t.hi = n.float
  n > 0

proc parseCreated(s: string, t: var Term): bool =
  ## A dc: value: a date to the year, month, day, hour, minute or second,
  ## its digits run together (`20251010`) or split by anything else
  ## (`2025-10-10`, `2025/10/10 14:30`), local time, standing for that whole
  ## span; after it with `after:`/`>`, before it with `before:`/`<`,
  ## `>=`/`<=` taking the span in too.
  var v = s.strip.toLowerAscii
  t.op = coEq
  var orEqual = false
  for (word, op) in [("after", coGt), ("before", coLt)]:
    if v.startsWith(word):
      t.op = op
      v = v[word.len .. ^1].strip(trailing = false, chars = {':', ' '})
  for (sign, op, eq) in [(">=", coGt, true), ("=>", coGt, true), ("<=", coLt, true),
                         ("=<", coLt, true), (">", coGt, false), ("<", coLt, false),
                         ("=", coEq, false)]:
    if v.startsWith(sign):
      if t.op == coEq: t.op = op
      orEqual = eq
      v = v[sign.len .. ^1].strip(trailing = false)
      break
  var groups: seq[string]
  var g = ""
  for c in v & " ":
    if c in Digits: g.add c
    elif g.len > 0:
      groups.add g
      g = ""
  if groups.len == 0: return false
  # Year, month, day, hour, minute, second: a group of more digits holds
  # several (the year's four, then two each).
  var parts: seq[int]
  for i, gr in groups:
    var at = 0
    if i == 0:
      if gr.len < 4 or gr.len mod 2 != 0: return false
      parts.add parseInt(gr[0 ..< 4])
      at = 4
    elif gr.len <= 2:
      parts.add parseInt(gr)
      continue
    elif gr.len mod 2 != 0: return false
    while at < gr.len:
      parts.add parseInt(gr[at ..< at + 2])
      at += 2
  if parts.len > 6: return false
  let given = parts.len
  while parts.len < 6: parts.add (if parts.len < 3: 1 else: 0)
  let (y, mo, d, h, mi, sec) = (parts[0], parts[1], parts[2], parts[3], parts[4], parts[5])
  if y < 1 or mo notin 1 .. 12 or d < 1 or d > getDaysInMonth(Month(mo), y) or
      h > 23 or mi > 59 or sec > 59:
    return false
  let start = dateTime(y, Month(mo), MonthdayRange(d), HourRange(h), MinuteRange(mi),
                       SecondRange(sec), 0, local())
  let step = case given
    of 1: 1.years
    of 2: 1.months
    of 3: 1.days
    of 4: 1.hours
    of 5: 1.minutes
    else: 1.seconds
  t.lo = start.toTime.toUnix.float
  t.hi = (start + step).toTime.toUnix.float
  if orEqual:
    if t.op == coGt: t.hi = t.lo  # from the span's start
    else: t.lo = t.hi             # up to its end
  true

proc folderValue*(s: string): string =
  ## An in: tag's folder as compared: lower case, its names split at either
  ## slash, trimmed, joined by "/", commas left out (a tag can't hold one).
  var parts: seq[string]
  for p in unicode.toLower(s).replace('\\', '/').split('/'):
    let n = p.replace(",", "").strip
    if n.len > 0: parts.add n
  parts.join("/")

proc parseQuery*(s: string): Query =
  ## Tags are what's between commas; quotes are characters like any other.
  ## `within:`/`exclude:` pick libraries, `in:` folders (folderValue),
  ## `hidden` searches hidden libraries too,
  ## `size`/`bitrate`/`dimension` `exactly`/`biggerthan`/`smallerthan:`
  ## compare, `dc:` a creation date (`parseCreated`), `format:` takes a file type, `filename contains:` part of a
  ## name, any other `field:` a tag holding the text; the rest is looked for
  ## at the start of a word (hasWordStart) in the name, title, artist, album
  ## and folders.
  result.empty = true
  for raw in s.split(','):
    let tag = raw.strip
    if tag.len == 0: continue
    if tag.squash == "hidden":
      result.hidden = true
      continue
    let colon = tag.find(':')
    if colon < 0:
      result.terms.add Term(kind: tkText, text: unicode.toLower(tag))
      result.empty = false
      continue
    let key = tag[0 ..< colon].squash
    let val = tag[colon + 1 .. ^1].strip
    if val.len == 0: continue  # still being typed
    let lval = unicode.toLower(val)
    case key
    of "within":
      result.within.add lval
      continue
    of "in":
      result.folders.add(if val.isAbsolute: val.normPath else: folderValue(val))
      result.empty = false
      continue
    of "exclude":
      result.excludes.add lval
      continue
    of "format", "ext", "extension", "type":
      result.formats.add lval.strip(chars = {'.', '*'})
      result.empty = false
      continue
    of "filenamecontains", "filename", "name":
      result.terms.add Term(kind: tkFilename, text: lval)
      result.empty = false
      continue
    of "path", "folder", "pathcontains":
      result.terms.add Term(kind: tkPath, text: lval)
      result.empty = false
      continue
    of "dc", "datecreated", "created", "creationdate":
      var t = Term(kind: tkCreated)
      t.bad = not parseCreated(val, t)
      result.terms.add t
      result.empty = false
      continue
    else: discard
    var t = Term(kind: tkField)
    var measured = false
    for (name, kind) in [("size", tkSize), ("bitrate", tkBitrate), ("dimension", tkDim),
                         ("dimensions", tkDim), ("resolution", tkDim)]:
      for (word, op) in [("exactly", coEq), ("biggerthan", coGt), ("smallerthan", coLt)]:
        if key == name & word:
          t = Term(kind: kind, op: op)
          measured = true
    if measured:
      let ok = case t.kind
        of tkDim: parseDim(val, t)
        else:
          let (lo, hi, good) = parseNumber(val, t.kind == tkSize)
          (t.lo, t.hi) = (lo, hi)
          good
      if not ok: t.lo = -1  # unreadable: matches nothing, so the mistake shows
      result.terms.add t
      result.empty = false
      continue
    t.keys = FieldAliases.getOrDefault(key, @[key])
    t.text = lval
    result.terms.add t
    result.empty = false

proc libraryNamed*(libs: seq[Library], value: string, hidden: bool): seq[int] =
  ## The libraries a within:/exclude: value names: the one of that name (any
  ## case), else every one whose name begins with it.
  for i, l in libs:
    if unicode.toLower(l.name) == value: return @[i]
  for i, l in libs:
    if unicode.toLower(l.name).startsWith(value) and (hidden or not l.hidden): result.add i

proc tagKey(tag: string): string =
  ## A search tag's key, squashed ("" when it has none).
  let colon = tag.find(':')
  if colon >= 0: tag[0 ..< colon].squash else: ""

proc searchTags(search: string): seq[string] =
  ## The search's tags, trimmed, empty ones left out.
  for raw in search.split(','):
    let tag = raw.strip
    if tag.len > 0: result.add tag

proc withScope*(search, lib: string, folder = ""): string =
  ## The search once a library (lib, "" for All) or one of its folders
  ## (folder: its in: text, folderTag) is picked in the libraries' column:
  ## the first within: tag naming lib and the first in: tag naming folder,
  ## each added in front when there's none (in: after within:). A library
  ## picked takes the in: tags out, All the within: ones too. The other
  ## tags keep their order; when no other is left, a comma ends the search,
  ## so what's typed next is a tag of its own.
  var tags = searchTags(search)
  if lib.len == 0 or folder.len == 0: tags.keepItIf(it.tagKey != "in")
  if lib.len == 0:
    tags.keepItIf(it.tagKey != "within")
    return tags.join(", ")
  var w = -1
  for i, t in tags:
    if t.tagKey == "within":
      w = i
      break
  if w >= 0: tags[w] = "within:" & lib
  else:
    tags.insert("within:" & lib, 0)
    w = 0
  if folder.len > 0:
    var f = -1
    for i, t in tags:
      if t.tagKey == "in":
        f = i
        break
    if f >= 0: tags[f] = "in:" & folder
    else: tags.insert("in:" & folder, w + 1)
  result = tags.join(", ")
  if tags.allIt(it.tagKey in ["within", "in"]): result.add ", "

proc withinFromIn*(search: string, libs: seq[Library]): string =
  ## A search from before in: named folders: its in: tags naming a library
  ## (as libraryNamed reads them) made within: tags, the rest as it was.
  var parts = search.split(',')
  for p in parts.mitems:
    let tag = p.strip
    if tag.tagKey != "in": continue
    let v = unicode.toLower(tag[tag.find(':') + 1 .. ^1].strip)
    if v.len > 0 and libraryNamed(libs, v, true).len > 0:
      p = (if p.len > 0 and p[0] == ' ': " " else: "") & "within:" & tag[tag.find(':') + 1 .. ^1].strip
  parts.join(",")

proc withoutHidden*(search: string, libs: seq[Library]): string =
  ## The search without its `hidden` tag and its within: tags naming a
  ## hidden library, the other tags kept in their order.
  var tags: seq[string]
  for raw in search.split(','):
    let tag = raw.strip
    if tag.len == 0 or tag.squash == "hidden": continue
    if tag.tagKey == "within":
      let v = unicode.toLower(tag[tag.find(':') + 1 .. ^1].strip)
      if libs.anyIt(it.hidden and unicode.toLower(it.name) == v): continue
    tags.add tag
  tags.join(", ")

proc renamedInSearch*(search, old, name: string): string =
  ## The search with its within: and exclude: tags naming the library old (any
  ## case) naming it name instead.
  let lold = unicode.toLower(old.strip)
  var parts = search.split(',')
  for p in parts.mitems:
    let tag = p.strip
    let key = tag.tagKey
    if key in ["within", "exclude"] and
        unicode.toLower(tag[tag.find(':') + 1 .. ^1].strip) == lold:
      p = (if p.len > 0 and p[0] == ' ': " " else: "") & tag[0 .. tag.find(':')] & name
  parts.join(",")

proc displayName*(f: LibFile): string =
  ## A row's name: the title tag, else the file's name without its type.
  if f.title.len > 0: f.title else: f.path.splitFile.name

proc cmpRange(op: CmpOp, v, lo, hi: float): bool =
  case op
  of coEq: v >= lo and v < hi
  of coGt: v >= hi
  of coLt: v < lo

proc foldersOf(ix: LibIndex, path: string): string =
  ## The folders a file lies in below the outermost listed folder holding
  ## it ("Artist/Album"); a file listed as such, outside any, its folder's
  ## name. The listed folder's own name is left out: every file in it
  ## would match.
  let dir = path.parentDir
  var root = ""
  if ix != nil:
    for p, r in ix.roots:
      if not r.isFile and dir.under(p) and (root.len == 0 or p.len < root.len): root = p
  if root.len == 0: return dir.extractFilename
  if dir.len <= root.len: return ""
  dir[root.len + (if root[^1] in {DirSep, AltSep}: 0 else: 1) .. ^1]

proc hayOf(f: LibFile, ix: LibIndex = nil): string =
  ## What free text is looked for in: the file's name, title, artist, album
  ## and folders.
  unicode.toLower(f.path.extractFilename & "\n" & f.title & "\n" & f.artist & "\n" &
    f.album & "\n" & ix.foldersOf(f.path))

proc dirsOf(f: LibFile, ix: LibIndex = nil): string =
  ## The folders an in: tag is looked for in: the outermost listed folder
  ## holding the file and those below it down to the file's, each as
  ## folderValue makes it, between slashes ("/music/artist/album/").
  var root = ""
  if ix != nil:
    for p, r in ix.roots:
      if not r.isFile and f.path.under(p) and (root.len == 0 or p.len < root.len): root = p
  let dir = f.path.parentDir
  let inner = if root.len == 0 or dir.len <= root.len: "" else: dir[root.len .. ^1]
  let v = folderValue((if root.len > 0: root.lastPathPart else: dir.lastPathPart) & "/" & inner)
  "/" & v & "/"

proc inFolders(q: Query, f: LibFile, dirs: string): bool =
  ## Whether f is in one of q's in: folders: one whose names run on in its
  ## folders (dirsOf), or an absolute path holding it.
  for v in q.folders:
    if v.isAbsolute:
      if f.path.under(v): return true
    elif ("/" & v & "/") in dirs: return true

proc spaceless(r: Rune): bool =
  ## A script written without spaces between words (Chinese, Japanese,
  ## Thai, Lao, Myanmar, Khmer; Korean too, whose words run long): any
  ## character may start one.
  let c = int(r)
  c in 0x0E00 .. 0x0EFF or c in 0x1000 .. 0x109F or c in 0x1780 .. 0x17FF or
    c in 0x1100 .. 0x11FF or c in 0x2E80 .. 0x9FFF or c in 0xA960 .. 0xA97F or
    c in 0xAC00 .. 0xD7FF or c in 0xF900 .. 0xFAFF or c in 0xFF66 .. 0xFFDC or
    c in 0x20000 .. 0x3FFFF

proc wordKind(r: Rune): int =
  ## 0 a separator, 1 a letter, 2 a digit: a word starts where it changes
  ## from 0 or between letters and digits ("quake2", "me1").
  if r.isAlpha: 1
  elif int(r) < 128 and char(int(r)) in Digits: 2
  else: 0

proc hasWordStart*(hay, text: string): bool =
  ## Whether text is in hay beginning a word: at the start, after a
  ## separator (space, punctuation, "_"), between letters and digits, or
  ## anywhere in a script without spaces. So "oni" finds "Oni" and
  ## "oni_theme", not "Electronic". Both lower case.
  if text.len == 0: return true
  let first = text.runeAt(0)
  var i = hay.find(text)
  while i >= 0:
    if i == 0: return true
    var b = i - 1
    while b > 0 and (hay[b].uint8 and 0xC0) == 0x80: dec b
    let before = hay.runeAt(b)
    let k = before.wordKind
    if k == 0 or k != first.wordKind or before.spaceless or first.spaceless: return true
    i = hay.find(text, i + 1)

proc matches*(q: Query, f: LibFile, hay = "", dirs = ""): bool =
  ## Whether f matches every tag of q; hay, dirs: f's hayOf and dirsOf when
  ## already made.
  if q.formats.len > 0 and f.path.extOf notin q.formats: return false
  if q.folders.len > 0 and not q.inFolders(f, if dirs.len > 0: dirs else: f.dirsOf): return false
  for t in q.terms:
    case t.kind
    of tkText:
      if not (if hay.len > 0: hay else: f.hayOf).hasWordStart(t.text): return false
    of tkFilename:
      if t.text notin unicode.toLower(f.path.extractFilename): return false
    of tkPath:
      if t.text notin unicode.toLower(f.path): return false
    of tkFormat: discard
    of tkCreated:
      # Where the file system keeps no creation time, the last change is
      # the earliest known.
      let c = if f.ctime > 0: f.ctime else: f.mtime
      if t.bad or c <= 0 or not cmpRange(t.op, c.float, t.lo, t.hi): return false
    of tkSize:
      if t.lo < 0 or not cmpRange(t.op, f.size.float, t.lo, t.hi): return false
    of tkBitrate:
      if t.lo < 0 or f.bitrate <= 0 or not cmpRange(t.op, f.bitrate, t.lo, t.hi): return false
    of tkDim:
      if t.lo < 0 or f.width <= 0 or f.height <= 0: return false
      if t.w > 0:
        let ok = case t.op
          of coEq: f.width == t.w and f.height == t.h
          of coGt: f.width >= t.w and f.height >= t.h and (f.width > t.w or f.height > t.h)
          of coLt: f.width <= t.w and f.height <= t.h and (f.width < t.w or f.height < t.h)
        if not ok: return false
      else:
        let side = min(f.width, f.height).float
        let ok = case t.op
          of coEq: side == t.lo
          of coGt: side > t.lo
          of coLt: side < t.lo
        if not ok: return false
    of tkField:
      var found = false
      for (k, v) in f.tags:
        if k.squash in t.keys and t.text in unicode.toLower(v):
          found = true
          break
      if not found:
        # Fields the file has without a tag of that name.
        let own = case t.keys[0]
          of "title": f.displayName
          of "duration", "length": (if f.duration > 0: $int(f.duration) else: "")
          else: ""
        if own.len == 0 or t.text notin unicode.toLower(own): return false
  true

proc completing*(text: string, caret: int): tuple[key, value: string, start: int] =
  ## The tag the caret is in, for the search's suggestions: its key (lower
  ## case, squashed) when it has one, what's typed after the colon, and
  ## where that value starts.
  let c = clamp(caret, 0, text.len)
  var a = c
  while a > 0 and text[a - 1] != ',': dec a
  let tag = text[a ..< c]
  let colon = tag.find(':')
  if colon < 0: return (tag.squash, "", -1)
  var vs = a + colon + 1
  while vs < c and text[vs] == ' ': inc vs
  (tag[0 ..< colon].squash, text[vs ..< c], vs)

# --- sorting -------------------------------------------------------------------

proc naturalLess(a, b: string): int =
  ## Case-insensitive, numbers by value ("2" before "10"); allocates nothing.
  var (i, j) = (0, 0)
  while i < a.len and j < b.len:
    if a[i] in Digits and b[j] in Digits:
      while i < a.len - 1 and a[i] == '0' and a[i + 1] in Digits: inc i
      while j < b.len - 1 and b[j] == '0' and b[j + 1] in Digits: inc j
      var (x, y) = (i, j)
      while x < a.len and a[x] in Digits: inc x
      while y < b.len and b[y] in Digits: inc y
      if x - i != y - j: return cmp(x - i, y - j)
      while i < x:
        if a[i] != b[j]: return cmp(a[i], b[j])
        inc i
        inc j
    else:
      let (ca, cb) = (a[i].toLowerAscii, b[j].toLowerAscii)
      if ca != cb: return cmp(ca, cb)
      inc i
      inc j
  cmp(a.len - i, b.len - j)

proc filterRows*(ix: LibIndex, rows: var seq[int32], q: Query) =
  ## Keeps the rows matching q, the files' search text made once per change.
  if q.empty: return
  let key = (ix.gen, ix.dropGen, ix.metaGen)
  if ix.hayKey != key or ix.hay.len != ix.files.len:
    ix.hay.setLen ix.files.len
    for i in 0 ..< ix.files.len: ix.hay[i] = ix.files[i].hayOf(ix)
    ix.dirs.setLen 0
    ix.hayKey = key
  if q.folders.len > 0 and ix.dirs.len != ix.files.len:
    ix.dirs.setLen ix.files.len
    for i in 0 ..< ix.files.len: ix.dirs[i] = ix.files[i].dirsOf(ix)
  var kept: seq[int32]
  for id in rows:
    if q.matches(ix.files[id], ix.hay[id], if ix.dirs.len > 0: ix.dirs[id] else: ""): kept.add id
  rows = kept

proc tagValue(f: LibFile, keys: openArray[string]): string =
  for k in keys:
    for (tk, v) in f.tags:
      if tk == k: return v

proc leadingInt(s: string): int =
  ## "3/12" -> 3; 0 when s doesn't start with a number.
  for c in s.strip:
    if c notin Digits or result > 99_999: break
    result = result * 10 + ord(c) - ord('0')

proc trackOf*(f: LibFile): int = f.tagValue(["track", "tracknumber", "part_number"]).leadingInt
proc discOf*(f: LibFile): int = f.tagValue(["disc", "discnumber", "disk"]).leadingInt

proc yearOf*(f: LibFile): int =
  ## The first four digits in a row of its date: "2019-05-01", "05/01/2019".
  let d = f.tagValue(["date", "year", "originaldate"])
  for i in 0 .. d.len - 4:
    if d[i .. i + 3].allCharsInSet(Digits): return d[i .. i + 3].parseInt

proc sortRows*(ix: LibIndex, rows: var seq[int32], field: PlaylistField, desc: bool) =
  ## Sorts by a column, as the playlist does (the path between equals), each
  ## row's key made once.
  let files = ix.files.addr
  const numeric = {pfDuration, pfSize, pfDimensions, pfAudioBitrate, pfTrack, pfDisc, pfYear}
  var keyed = newSeq[tuple[text: string, num: float, id: int32]](rows.len)
  for i, id in rows:
    let f = files[][id].addr
    keyed[i] = case field
      of pfName: (f[].displayName, 0.0, id)
      of pfFilename: (f.path.extractFilename, 0.0, id)
      of pfArtist: (f.artist, 0.0, id)
      of pfAlbum: (f.album, 0.0, id)
      of pfDuration: ("", f.duration, id)
      of pfSize: ("", f.size.float, id)
      of pfDimensions: ("", float(f.width * f.height), id)
      of pfAudioBitrate: ("", f.bitrate, id)
      of pfTrack: ("", f[].trackOf.float, id)
      of pfDisc: ("", f[].discOf.float, id)
      of pfYear: ("", f[].yearOf.float, id)
  proc byKey(x, y: tuple[text: string, num: float, id: int32]): int =
    result = if field in numeric: cmp(x.num, y.num) else: naturalLess(x.text, y.text)
    if result == 0: result = naturalLess(files[][x.id].path, files[][y.id].path)
    if desc: result = -result
  keyed.sort(byKey)
  for i, k in keyed: rows[i] = k.id

proc groupLabel*(ix: LibIndex, path: string): string =
  ## The folder a file is grouped under: its folder relative to the library
  ## path holding it, led by that path's own name ("Music / Album / CD1").
  var root = ""  # the longest listed folder holding it (a file listed itself is under one, or not)
  for p, r in ix.roots:
    if not r.isFile and path.under(p) and p.len > root.len: root = p
  let dir = path.parentDir
  if root.len == 0 or not dir.under(root): return dir.lastPathPart
  let rel = dir.relativePath(root)
  result = root.lastPathPart
  if rel.len > 0 and rel != ".": result.add " / " & rel.replace($DirSep, " / ")

proc groupRows*(ix: LibIndex, rows: var seq[int32]): seq[tuple[label, dir: string, count: int]] =
  ## Puts rows in folder groups (in name order), keeping their order within
  ## each; returns the groups in order, with the folder (its first file's)
  ## and how many rows each has.
  var keyed = newSeq[tuple[label: string, id: int32]](rows.len)
  for i, id in rows: keyed[i] = (ix.groupLabel(ix.files[id].path), id)
  keyed.sort(proc (x, y: tuple[label: string, id: int32]): int = naturalLess(x.label, y.label))  # stable
  for i, k in keyed:
    rows[i] = k.id
    if result.len == 0 or result[^1].label != k.label:
      result.add (k.label, ix.files[k.id].path.parentDir, 0)
    inc result[^1].count

# --- folder trees --------------------------------------------------------------

type
  FolderTree* = object
    ## A library's folders holding files it lists, from the index alone
    ## (never the disk): the Library panel's tree.
    tops*: seq[string]                  ## its listed folders holding any, in name order
    kids*: Table[string, seq[string]]   ## a folder's subfolders holding any, in name order
    count*: Table[string, int]          ## files in a folder and below

proc folderTree*(ix: LibIndex, l: Library): FolderTree =
  var dirs: seq[string]
  for p in l.paths:
    let n = p.normPath
    if n.len == 0: continue
    let r = ix.roots.getOrDefault(n)
    if r.isFile or r.state == rsMissing: continue
    dirs.add n
  # Those inside another listed folder are that one's subfolders.
  var tops: seq[string]
  for d in dirs:
    if not dirs.anyIt(it != d and d.under(it) and (it.len < d.len or it < d)) and d notin tops:
      tops.add d
  var seen = initHashSet[string]()
  for id in ix.members(l):
    let p = ix.files[id].path
    var top = ""
    for t in tops:
      if p.under(t):
        top = t
        break
    if top.len == 0: continue  # a file listed as such
    result.count.mgetOrPut(top, 0).inc
    var d = p.parentDir
    while d.len > top.len:
      result.count.mgetOrPut(d, 0).inc
      if d notin seen:
        seen.incl d
        result.kids.mgetOrPut(d.parentDir, @[]).add d
      d = d.parentDir
  let byName = proc (x, y: string): int = naturalLess(x.lastPathPart, y.lastPathPart)
  for t in tops:
    if t in result.count: result.tops.add t
  result.tops.sort(byName)
  for k in result.kids.mvalues: k.sort(byName)

proc children*(t: FolderTree, folder: string): seq[string] =
  ## A node's subfolders: a library's ("" for it) are its listed folders,
  ## or the subfolders of its only one.
  if folder.len > 0: t.kids.getOrDefault(folder)
  elif t.tops.len == 1: t.kids.getOrDefault(t.tops[0])
  else: t.tops

proc folderTag*(t: FolderTree, folder: string): string =
  ## A folder of the tree as its in: tag writes it: its names from the
  ## library's listed folder down ("Artist/Album"), that folder's own name
  ## first when the library lists several; commas left out (a tag can't
  ## hold one).
  var top = ""
  for tp in t.tops:
    if folder.under(tp):
      top = tp
      break
  if top.len == 0: return folder.lastPathPart.replace(",", "")
  var names: seq[string]
  if t.tops.len > 1: names.add top.lastPathPart
  if folder.len > top.len:
    for n in folder[top.len .. ^1].split({DirSep, AltSep}):
      if n.len > 0: names.add n
  if names.len == 0: names.add top.lastPathPart
  names.join("/").replace(",", "")

iterator allFolders*(t: FolderTree): string =
  ## Its folders, depth first in name order (the libraries' column's order).
  var stack: seq[string]
  for j in countdown(t.tops.high, 0): stack.add t.tops[j]
  while stack.len > 0:
    let f = stack.pop
    yield f
    let kids = t.kids.getOrDefault(f)
    for j in countdown(kids.high, 0): stack.add kids[j]

# --- default libraries --------------------------------------------------------

proc xdgUserDir(key, fallback: string): string =
  ## A folder from ~/.config/user-dirs.dirs (XDG_MUSIC_DIR="$HOME/Music").
  result = getHomeDir() / fallback
  when not defined(windows):
    try:
      for line in lines(getConfigDir() / "user-dirs.dirs"):
        let l = line.strip
        if l.startsWith(key & "="):
          let v = l[key.len + 1 .. ^1].strip(chars = {'"'}).replace("$HOME", getHomeDir().strip(
            leading = false, chars = {'/'}))
          if v.len > 0 and v != getHomeDir().strip(leading = false, chars = {'/'}): return v
    except IOError, OSError: discard

proc defaultLibraries*(): seq[Library] =
  ## Video, Music and Sounds, as a new player starts with them.
  result.add Library(name: "Video", kind: lkVideo, paths: @[xdgUserDir("XDG_VIDEOS_DIR", "Videos")])
  result.add Library(name: "Music", kind: lkAudio, paths: @[xdgUserDir("XDG_MUSIC_DIR", "Music")])
  when defined(windows):
    result.add Library(name: "Sounds", kind: lkAudio, paths: @[getEnv("WINDIR", "C:\\Windows") / "Media"])
  else:
    result.add Library(name: "Sounds", kind: lkAudio, paths: @["/usr/share/sounds"])

proc seedLibraries*(c: var Config) =
  ## The default libraries, once: removing them all doesn't bring them back.
  if c.librariesSeeded: return
  c.librariesSeeded = true
  if c.libraries.len == 0: c.libraries = defaultLibraries()

proc renamedInTree*(expanded: seq[string], old, name: string): seq[string] =
  ## The Library panel's expanded nodes once a library is renamed.
  for k in expanded:
    let nl = k.find('\n')
    result.add(if nl >= 0 and k[0 ..< nl] == old: name & k[nl .. ^1] else: k)

proc validLibraryName*(libs: seq[Library], name: string, skip = -1): string =
  ## Why a name can't be used ("" when it can): commas separate search tags.
  let n = name.strip
  if n.len == 0: return "Type a name"
  if ',' in n: return "Names can't hold commas"
  if unicode.toLower(n) == "all": return "\"All\" stands for every library"
  for i, l in libs:
    if i != skip and unicode.toLower(l.name) == unicode.toLower(n):
      return "There is a library of that name"

proc workerCount*(): int =
  ## Threads started so far (for testing).
  if not inited: return 0
  withLock sh.lock: result = sh.workers
