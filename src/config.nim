## Persistent settings, stored at ~/.config/majestic-media-player/config.json.

import std/[os, strutils, tables, sequtils, math, algorithm, times]
import jsony, crunchy/sha256

type
  FrameMode* = enum
    fmHalf, fmFull, fmDouble, fmStretch, fmFit

  OnTopMode* = enum
    otDefault, otAlways, otWhilePlaying, otWhilePlayingVideo

  RepeatMode* = enum
    rmFile, rmPlaylist

  PlaylistField* = enum
    ## A playlist column, and what sorting by it goes by.
    pfName, pfFilename, pfDuration, pfSize, pfDimensions, pfAudioBitrate,
    pfTrack, pfArtist, pfYear, pfAlbum

  OpenMode* = enum
    omSamePlayer, omNewPlayer

  StreamQuality* = enum
    ## Options > Playback > Online > Bandwidth: what yt-dlp fetches of a link.
    sqBest, sqLimit, sqLowest, sqAudioOnly

  RenderMode* = enum
    ## Options > System > Rendering: GPU or CPU (the software renderer).
    rdPreferGpu   ## the GPU; the CPU while it has too little memory to start on
    rdAdaptive    ## back and forth, as the GPU's memory runs short and frees up
    rdCpu         ## the CPU, always

  AfterPlayback* = enum
    apNothing, apNextInFolder, apMonitorOff, apExit, apSleep, apHibernate,
    apShutdown, apLogOff, apLock

  SavedTransform* = object
    ## Pan, rotate & zoom state, kept when "Remember last pan, rotation
    ## and zoom" is on.
    panX*, panY*, rotation*: float
    zoom*: float = 1
    scaleX*: float = 1
    scaleY*: float = 1

  Config* = object
    recentFiles*: seq[string]
    recentTitles*: Table[string, string]  # its links' titles
    lastDir*: string
    volume*: float = 100
    muted*: bool
    equalizerOn*: bool = false     # its gains apply; they're kept and edited either way
    equalizerGains*: seq[float]    # dB per band (player.EqFreqs); missing bands are 0
    equalizerMinGain*: float = -12 # dB at the bottom of its sliders (the top is +12)
    compactMode*: bool = false     # no window frame and no menu bar
    showSeekBar*: bool = true
    showControls*: bool = true
    showStatus*: bool = true
    showPlaylist*: bool = false
    playlistWidth*: float = 300    # pixels, changed by dragging its left edge
    playlistColumns*: seq[PlaylistField]   # shown, left to right; set by loadConfig when empty
    playlistColumnWidths*: Table[string, float]  # pixels, by field name: the columns resized by hand
    playlistShowSize*: bool = false        # older versions' columns, read once into playlistColumns
    playlistShowDimensions*: bool = false
    playlistCursorFollows*: bool = true    # the selection moves to the entry that plays
    playlistShowMillis*: bool = false      # the Duration column as HH:MM:SS.mmm
    showRunLog*: bool = false
    seededPresets*: seq[string]    # preset command lines already offered once
    runLogHeight*: float = 200     # pixels, changed by dragging its bottom edge
    showOsd*: bool = true
    frameMode*: FrameMode = fmFit
    aspectOverride*: string = ""   # "" = original, else "4:3", "16:9", ...
    preserveAspect*: bool = true
    onTop*: OnTopMode = otDefault
    repeatForever*: bool = false
    repeatPingPong*: bool = false  # loops turn around at either end
    repeatMode*: RepeatMode = rmPlaylist
    # Options > Player
    uiScale*: float = 100          # percent
    openMode*: OpenMode = omSamePlayer
    osdTimestamp*: bool = false
    osdScale*: float = 1           # OSD text size multiplier
    osdScaleByWindow*: bool = true # OSD text grows and shrinks with the video frame
    showMillis*: bool = false      # timestamps as HH:MM:SS.mmm
    showRemaining*: bool = false   # status/OSD time as -remaining / duration
    showFrames*: bool = false      # the frame number left of the status/OSD time
    syncOffsetSeconds*: bool = false  # Synchronize > Properties: the offset in seconds, not frames
    showAllShortcuts*: bool = false  # status bar hints include view toggles and pan/rotate/scale
    autoFitWindow*: bool = true
    sphereDragMovesWindow*: bool = false  # 360° video: drag moves the window, Ctrl+drag looks around
    rememberTime*: bool = false
    rememberWindowPos*: bool = false
    rememberWindowSize*: bool = false
    rememberTransform*: bool = false
    rememberPlaylist*: bool = false
    bookmarksAsChapters*: bool = false  # chapter steps also stop at bookmarks
    bookmarkPreview*: bool = false # Edit Bookmark seeks to the time it shows
    titleFullPath*: bool = false
    titleUseMediaTitle*: bool = true
    # Options > Player > Paths
    screenshotDir*: string = ""    # "" = ~/Pictures (or home)
    screenshotNoAsk*: bool = false # save straight into screenshotDir
    openDir*: string = ""          # "" = the playing file's folder, else lastDir
    mkvpropedit*: string = ""      # "" = found automatically (mkvtoolnix.findMkvpropedit)
    ytdlp*: string = ""            # "" = found automatically (ytdlp.findYtdlp)
    # Options > Player > Keys
    keys*: Table[string, string]   # command id -> "Home|0" ("" = none); only changed keys
    # Options > Playback
    keepDisplayOn*: bool = true    # inhibit screen blanking while video plays
    rateStep*: float = 0.25
    seekStep*: float = 5           # seconds (set in milliseconds in Options)
    volumeStep*: float = 5
    seekPreview*: bool = true
    snapWithShift*: bool = false   # off: snap unless Shift; on: only with Shift
    snapDistance*: float = 8       # pixels
    subLangs*: string = ""         # "eng, jpn": preferred subtitle languages
    audioLangs*: string = ""
    signInCookies*: string = "auto"  # browser yt-dlp signs in with for links that ask to:
                                     # "auto" (each installed in turn), "none", or a
                                     # --cookies-from-browser value ("brave", "firefox:...")
    streamQuality*: StreamQuality = sqBest
    streamMaxHeight*: int = 1080   # sqLimit: tallest video fetched, in lines
    streamMaxFps30*: bool = false  # skip 60 fps formats
    streamSmallAudio*: bool = false  # the lowest-bitrate audio instead of the best
    streamOnSave*: bool = true     # File > Save and command lines download alike
    streamLockVideo*: string = ""  # the quality menu's locks, for every link: the video
                                   # quality ("1080p60", when offered) or "auto"; "" none
    streamLockAudio*: string = ""  # the audio row by rank: "auto", "highest", "mid",
                                   # "lowest" (ytdlp.AudioRanks); "" none
    ytThumbnail*: bool = true      # a YouTube link's thumbnail while no video track shows
    ytSeekPreview*: bool = true    # seek bar previews on YouTube links, from its storyboards
    showCover*: bool = true        # an audio file's front cover in the video frame
    coverNames*: string = "folder\nalbum"  # pictures beside an audio file taken as its
                                   # cover when it has none in it: names without the
                                   # extension, one per line, first found wins
    shortAudioDelay*: bool = true  # silence after a very short audio file, before the next
    shortAudioMs*: float = 500     # how short, and how much silence: milliseconds
    # Options > Playback > Media Cache
    webDir*: string = ""           # "" = the cache folder's "streams"
    webKeepOn*: bool = true        # forget links not opened for webKeepHours
    webKeepHours*: int = 168
    webCountOn*: bool = false      # keep at most webCount links
    webCount*: int = 50
    webSizeOn*: bool = true        # keep at most webSizeGB (GiB) of streams
    webSizeGB*: int = 20
    # Options > Subtitles
    subDelay*: float = 0           # milliseconds
    subPaths*: string = ""         # extra subtitle folders, ';'-separated
    subFont*: string = ""          # font family, "" = mpv's sans-serif
    subBold*: bool = false
    subItalic*: bool = false
    subSize*: float = 38           # mpv's sub-font-size, scaled pixels at 720 lines
    subSpacing*: float = 0         # mpv's sub-spacing (kerning), same scaled pixels
    subLineSpacing*: float = 0     # mpv's sub-line-spacing, same scaled pixels
    subColor*: string = "#FFFFFF"  # colors as #RRGGBB, opacity apart in percent
    subOpacity*: float = 100
    subOutlineSize*: float = 1.65
    subOutlineColor*: string = "#000000"
    subOutlineOpacity*: float = 100
    subShadowOffset*: float = 0
    subShadowColor*: string = "#000000"
    subShadowOpacity*: float = 69
    subStyleAss*: bool = false     # restyle ASS/SSA subtitles too (sub-ass-override=force)
    colorSwatches*: seq[string]    # the color picker's saved colors, newest first
    # Options > Miscellaneous
    panStep*: float = 10           # pixels
    rotateStep*: float = 5         # degrees
    sizeStep*: float = 5           # percent
    # Options > System
    loopFramesMB*: int = 768       # short loops' frames held in video memory, MB
    renderMode*: RenderMode = rdPreferGpu
    # Remembered state
    windowX*, windowY*: int
    windowW*, windowH*: int        # 0 = never saved
    transform*: SavedTransform
    playlist*: seq[string]         # kept when "Remember playlist" is on
    playlistIndex*: int = -1
    playlistTitles*: Table[string, string]  # its links' titles
    playlistListed*: seq[string]   # its YouTube playlist links already listed

const
  MaxRecent = 15
  LoopFramesMaxMB* = 4096          ## hard cap of loopFramesMB (4 GB)
  OsdScaleMin* = 0.25             ## range of osdScale
  OsdScaleMax* = 8.0

proc validColor*(hex: string): bool =
  ## "#RRGGBB" (or "RRGGBB") as typed in Options.
  let h = hex.strip.strip(trailing = false, chars = {'#'})
  h.len == 6 and h.allIt(it in HexDigits)

proc mpvColor*(hex: string, opacity: float, fallback: string): string =
  ## An Options color and opacity (percent) in mpv's "#AARRGGBB"; fallback
  ## ("#RRGGBB") when the typed color isn't one.
  let h = (if hex.validColor: hex else: fallback).strip.strip(trailing = false, chars = {'#'})
  "#" & toHex(int(round(clamp(opacity, 0, 100) * 2.55)), 2) & h.toUpperAscii

proc resetSubStyle*(c: var Config) =
  ## Options > Subtitles > Default > Reset style: the style fields back to their defaults.
  let d = Config()
  c.subFont = d.subFont
  c.subBold = d.subBold
  c.subItalic = d.subItalic
  c.subSize = d.subSize
  c.subSpacing = d.subSpacing
  c.subLineSpacing = d.subLineSpacing
  c.subColor = d.subColor
  c.subOpacity = d.subOpacity
  c.subOutlineSize = d.subOutlineSize
  c.subOutlineColor = d.subOutlineColor
  c.subOutlineOpacity = d.subOutlineOpacity
  c.subShadowOffset = d.subShadowOffset
  c.subShadowColor = d.subShadowColor
  c.subShadowOpacity = d.subShadowOpacity
  c.subStyleAss = d.subStyleAss

proc expandPath*(p: string): string =
  ## A folder typed in Options: trimmed, with ~ expanded.
  result = p.strip
  if result.len > 0: result = result.expandTilde

proc defaultScreenshotDir*(): string =
  result = getHomeDir() / "Pictures"
  if not dirExists(result): result = getHomeDir()

proc screenshotFolder*(c: Config): string =
  let d = c.screenshotDir.expandPath
  if d.len > 0: d else: defaultScreenshotDir()

proc newHook*(c: var Config) =
  c = Config()

proc enumHook*(s: string, v: var FrameMode) =
  ## By name, taking the one older versions wrote for Fit too.
  v = if s == "fmTouchInside": fmFit else: parseEnum[FrameMode](s, fmFit)

proc configDir*(): string = getConfigDir() / "majestic-media-player"

proc configPath(): string = configDir() / "config.json"

proc writeAtomic(path, data: string) =
  ## Saved through a temporary file, so a crash mid-write (now that state is
  ## saved while playing) can't leave a truncated file behind.
  let tmp = path & ".tmp"
  writeFile(tmp, data)
  moveFile(tmp, path)

proc dropOldKeys(keys: var Table[string, string]) =
  ## Keys saved before 0 joined Home on Go To Beginning, when 0 had its own command.
  if "seek-0" in keys:
    keys.del("seek-0")
    keys.del("go-to-beginning")

proc loadConfig*(): Config =
  result = Config()
  let path = configPath()
  if fileExists(path):
    try:
      result = readFile(path).fromJson(Config)
    except CatchableError as e:
      stderr.writeLine "config: ignoring unreadable ", path, ": ", e.msg
  if result.playlistColumns.len == 0:
    result.playlistColumns = @[pfName, pfDuration]
    if result.playlistShowSize: result.playlistColumns.add pfSize
    if result.playlistShowDimensions: result.playlistColumns.add pfDimensions
  dropOldKeys(result.keys)

proc readKeys(keys: var Table[string, string]): bool =
  ## The file's keys; false, leaving keys as they are, when it can't be read.
  try:
    keys = readFile(configPath()).fromJson(Config).keys
    dropOldKeys(keys)
    true
  except CatchableError:
    false

proc save*(c: Config, ownKeys = false) =
  ## Every running player saves the whole config, so the keys go by the file
  ## unless this one's Options changed them (ownKeys): a player still holding
  ## the old keys mustn't undo that.
  let path = configPath()
  var c = c
  if not ownKeys: discard readKeys(c.keys)
  try:
    createDir(path.parentDir)
    writeAtomic(path, c.toJson)
  except CatchableError as e:
    stderr.writeLine "config: cannot save ", path, ": ", e.msg

var keysStamp: Time  # the config file as last checked for keys

proc reloadKeys*(c: var Config) =
  ## Takes the keys another player saved since.
  let t = try: getLastModificationTime(configPath()) except OSError: Time()
  if t != keysStamp:
    keysStamp = t
    discard readKeys(c.keys)

# --- Open Recent, shared by every running player -----------------------------
# Kept apart from the config, which each player saves whole (the last one to
# save would win): every change reloads it first, and players pick up the
# others' changes as the file changes.

type RecentList = object
  files: seq[string]
  titles: Table[string, string]

var recentStamp: Time  # the file as last read or written here

proc recentPath(): string = configDir() / "recent.json"

proc recentTime(): Time =
  try: getLastModificationTime(recentPath()) except OSError: Time()

proc saveRecent*(c: Config) =
  let path = recentPath()
  try:
    createDir(path.parentDir)
    writeAtomic(path, RecentList(files: c.recentFiles, titles: c.recentTitles).toJson)
    recentStamp = recentTime()
  except CatchableError as e:
    stderr.writeLine "config: cannot save ", path, ": ", e.msg

proc reloadRecent*(c: var Config, force = false): bool =
  ## Takes the list another player saved since; true when it changed. Without
  ## the file yet, it starts from the list older versions kept in the config.
  let t = recentTime()
  if t == Time():
    c.saveRecent()
    return false
  if t == recentStamp and not force: return false
  recentStamp = t
  try:
    let r = readFile(recentPath()).fromJson(RecentList)
    if r.files == c.recentFiles and r.titles == c.recentTitles: return false
    (c.recentFiles, c.recentTitles) = (r.files, r.titles)
    result = true
  except CatchableError as e:
    stderr.writeLine "config: ignoring unreadable ", recentPath(), ": ", e.msg

proc addRecent*(c: var Config, path: string) =
  discard c.reloadRecent(force = true)
  let i = c.recentFiles.find(path)
  if i >= 0: c.recentFiles.delete(i)
  c.recentFiles.insert(path, 0)
  if c.recentFiles.len > MaxRecent:
    c.recentFiles.setLen(MaxRecent)
  c.saveRecent()

proc removeRecent*(c: var Config, path: string) =
  discard c.reloadRecent(force = true)
  let i = c.recentFiles.find(path)
  if i >= 0: c.recentFiles.delete(i)
  c.recentTitles.del path
  c.saveRecent()

proc clearRecent*(c: var Config) =
  c.recentFiles.setLen 0
  c.recentTitles.clear()
  c.saveRecent()

# --- state brought back after restarting into an update ----------------------

type
  ResumeState* = object
    ## What the player was doing as it restarted into an update (Help >
    ## Check for Updates), whatever the Remember options say.
    playlist*: seq[string]
    titles*: Table[string, string]  # its links' titles
    listed*: seq[string]           # its YouTube playlist links already listed
    index*: int = -1               # the entry open, else -1
    selected*: int = -1            # the entry selected
    time*: float
    paused*, stopped*: bool
    speed*: float = 1
    tracks*: seq[tuple[kind, file: string]]  # tracks added from files
    aid*, sid*, vid*: int          # selected tracks, 0 for none
    loopA*, loopB*: float
    hasLoopA*, hasLoopB*, abLoop*: bool
    windowX*, windowY*, windowW*, windowH*: int  # the frame unmaximized, windowed
    maximized*, fullscreen*: bool
    transform*: SavedTransform

proc resumePath(): string = configDir() / "resume.json"

proc save*(r: ResumeState) =
  try:
    createDir(configDir())
    writeAtomic(resumePath(), r.toJson)
  except CatchableError as e:
    stderr.writeLine "config: cannot save ", resumePath(), ": ", e.msg

proc takeResume*(): tuple[ok: bool, state: ResumeState] =
  ## The state saved for this start, once: the file is removed.
  let path = resumePath()
  if not fileExists(path): return
  try:
    result = (true, readFile(path).fromJson(ResumeState))
  except CatchableError as e:
    stderr.writeLine "config: ignoring unreadable ", path, ": ", e.msg
  try: removeFile(path)
  except OSError: discard

# --- remembered playback positions -------------------------------------------

type Positions* = OrderedTable[string, float]

const MaxPositions = 500

proc positionsPath(): string = configDir() / "positions.json"

proc loadPositions*(): Positions =
  let path = positionsPath()
  if fileExists(path):
    try:
      result = readFile(path).fromJson(Positions)
    except CatchableError as e:
      stderr.writeLine "config: ignoring unreadable ", path, ": ", e.msg

proc save*(p: Positions) =
  let path = positionsPath()
  try:
    createDir(path.parentDir)
    writeAtomic(path, p.toJson)
  except CatchableError as e:
    stderr.writeLine "config: cannot save ", path, ": ", e.msg

proc remember*[T](p: var OrderedTable[string, T], path: string, v: T) =
  ## Most recent last, so the oldest entries go first when trimming.
  p.del(path)
  p[path] = v
  while p.len > MaxPositions:
    for k in p.keys:
      p.del(k)
      break

# --- remembered subtitle sizes -----------------------------------------------

type SubScales* = OrderedTable[string, float32]  ## path -> sub scale

proc subScalesPath(): string = configDir() / "subscales.json"

proc loadSubScales*(): SubScales =
  let path = subScalesPath()
  if fileExists(path):
    try:
      result = readFile(path).fromJson(SubScales)
    except CatchableError as e:
      stderr.writeLine "config: ignoring unreadable ", path, ": ", e.msg

proc save*(s: SubScales) =
  let path = subScalesPath()
  try:
    createDir(path.parentDir)
    writeAtomic(path, s.toJson)
  except CatchableError as e:
    stderr.writeLine "config: cannot save ", path, ": ", e.msg

# --- bookmarks ---------------------------------------------------------------

type
  Bookmark* = object
    time*: float
    name*: string                 ## "" shows as "Bookmark N"

  BookmarkJson = object
    time: float
    name: string

  BookmarkEntry* = object
    path*: string                 ## where the file was last seen, for people
    marks*: seq[Bookmark]         ## sorted by time

  BookmarkEntryJson = object
    path: string
    marks: seq[Bookmark]

  Bookmarks* = OrderedTable[string, BookmarkEntry]  ## mediaKey -> entry

proc parseHook*(s: string, i: var int, v: var Bookmark) =
  ## Objects, or the bare times that older versions wrote.
  eatSpace(s, i)
  if i < s.len and s[i] == '{':
    var o: BookmarkJson
    parseHook(s, i, o)
    v = Bookmark(time: o.time, name: o.name)
  else:
    v = Bookmark()
    parseHook(s, i, v.time)

proc parseHook*(s: string, i: var int, v: var BookmarkEntry) =
  ## Entries, or the bare bookmark lists that older versions wrote (keyed by
  ## path, so the path is filled in from the key once loaded).
  eatSpace(s, i)
  if i < s.len and s[i] == '{':
    var o: BookmarkEntryJson
    parseHook(s, i, o)
    v = BookmarkEntry(path: o.path, marks: o.marks)
  else:
    v = BookmarkEntry()
    parseHook(s, i, v.marks)

proc mediaKey*(path: string): string =
  ## Identifies a media file by its contents, so bookmarks follow it when it
  ## is moved or renamed: its size and a SHA-256 of its first and last 64 KiB
  ## (which mpv reads anyway, so they're usually cached). Streams and
  ## unreadable files fall back to their path.
  const chunk = 65536
  if path.len == 0 or path.contains("://"): return path
  var f: File
  if not f.open(path): return path
  defer: f.close()
  try:
    let size = f.getFileSize
    var data = newString(min(size, 2 * chunk))
    if size <= 2 * chunk:
      if data.len > 0 and f.readBuffer(data[0].addr, data.len) != data.len: return path
    else:
      for n, pos in [0'i64, size - chunk]:
        f.setFilePos(pos)
        if f.readBuffer(data[n * chunk].addr, chunk) != chunk: return path
    let digest = sha256(data)
    result = toHex(size, 12).toLowerAscii & "-"
    for b in digest[0 ..< 16]: result.add toHex(b, 2).toLowerAscii
  except CatchableError:
    result = path

# mediaKey on a thread of its own: a cold file on a spinning or network disk
# can take a few hundred ms to read.
var keyRequests: Channel[string]
var keyResults: Channel[(string, string)]
var keyWorker: Thread[void]

proc keyLoop() {.thread.} =
  while true:
    let path = keyRequests.recv()
    keyResults.send((path, mediaKey(path)))

proc requestMediaKey*(path: string) =
  ## Works out path's mediaKey in the background; see takeMediaKey.
  if not keyWorker.running:
    keyRequests.open()
    keyResults.open()
    createThread(keyWorker, keyLoop)
  keyRequests.send(path)

proc takeMediaKey*(): tuple[ok: bool, path, key: string] =
  ## A finished requestMediaKey, if any: the path and its key.
  if not keyWorker.running: return
  let (ok, r) = keyResults.tryRecv()
  if ok: result = (true, r[0], r[1])

proc label*(b: Bookmark, i: int): string =
  if b.name.len > 0: b.name else: "Bookmark " & $(i + 1)

proc toSimpleChapters*(marks: seq[Bookmark]): string =
  ## Matroska simple-chapter format (OGM style), which mkvmerge, mkvpropedit
  ## --chapters and mpv --chapters-file read:
  ##   CHAPTER01=00:51:32.881
  ##   CHAPTER01NAME=Gun Kata 1
  let digits = max(2, len($marks.len))
  for i, b in marks:
    let n = intToStr(i + 1, digits)
    let ms = max(0, int(round(b.time * 1000)))
    let s = ms div 1000
    result.add "CHAPTER" & n & "=" & intToStr(s div 3600, 2) & ":" &
      intToStr((s mod 3600) div 60, 2) & ":" & intToStr(s mod 60, 2) & "." &
      intToStr(ms mod 1000, 3) & "\n"
    result.add "CHAPTER" & n & "NAME=" & b.label(i) & "\n"

proc parseSimpleChapters*(text: string): seq[Bookmark] =
  ## Reads toSimpleChapters' format, sorted by time. Lines that aren't
  ## chapters are skipped; names like "Bookmark 3" (the default label) come
  ## back as unnamed. Raises ValueError when no chapter is found.
  var byNum: OrderedTable[string, Bookmark]
  for raw in text.splitLines:
    let line = (if raw.startsWith("\xEF\xBB\xBF"): raw[3 .. ^1] else: raw).strip
    let eq = line.find('=')
    if eq < 0 or not line.toUpperAscii.startsWith("CHAPTER"): continue
    var key = line[7 ..< eq].toUpperAscii
    let value = line[eq + 1 .. ^1]
    if key.endsWith("NAME"):
      key.setLen key.len - 4
      if key.len > 0 and key.allCharsInSet(Digits):
        byNum.mgetOrPut(key.strip(trailing = false, chars = {'0'}), Bookmark()).name = value.strip
    elif key.len > 0 and key.allCharsInSet(Digits):
      let parts = value.strip.split(':')
      if parts.len != 3: continue
      try:
        let t = float(parseInt(parts[0]) * 3600 + parseInt(parts[1]) * 60) + parseFloat(parts[2])
        byNum.mgetOrPut(key.strip(trailing = false, chars = {'0'}), Bookmark()).time = t
      except ValueError: discard
  for k, b in byNum: result.add b
  if result.len == 0: raise newException(ValueError, "no chapters found")
  result.sort(proc (x, y: Bookmark): int = cmp(x.time, y.time))
  for i, b in result.mpairs:
    if b.name == "Bookmark " & $(i + 1): b.name = ""

proc bookmarksPath(): string = configDir() / "bookmarks.json"

proc loadBookmarks*(): Bookmarks =
  let path = bookmarksPath()
  if fileExists(path):
    try:
      result = readFile(path).fromJson(Bookmarks)
      for k, e in result.mpairs:
        if e.path.len == 0: e.path = k
    except CatchableError as e:
      stderr.writeLine "config: ignoring unreadable ", path, ": ", e.msg

proc save*(b: Bookmarks) =
  let path = bookmarksPath()
  try:
    createDir(path.parentDir)
    writeAtomic(path, b.toJson)
  except CatchableError as e:
    stderr.writeLine "config: cannot save ", path, ": ", e.msg

# --- equalizer saved for a media file ------------------------------------------

type
  EqEntry* = object
    path*: string                 ## where the file was last seen, for people
    on*: bool
    gains*: seq[float]

  Equalizers* = OrderedTable[string, EqEntry]  ## mediaKey -> entry, as bookmarks

proc equalizersPath(): string = configDir() / "equalizers.json"

proc loadEqualizers*(): Equalizers =
  let path = equalizersPath()
  if fileExists(path):
    try:
      result = readFile(path).fromJson(Equalizers)
    except CatchableError as e:
      stderr.writeLine "config: ignoring unreadable ", path, ": ", e.msg

proc save*(e: Equalizers) =
  let path = equalizersPath()
  try:
    createDir(path.parentDir)
    writeAtomic(path, e.toJson)
  except CatchableError as e:
    stderr.writeLine "config: cannot save ", path, ": ", e.msg

# --- command lines (Run menu) --------------------------------------------------

type
  CardKind* = enum
    ckValue = "value"             ## content is the text itself
    ckReference = "reference"     ## content is a key: "file", "timestamp" or "external"

  RectDim* = enum
    ## Which number of a rectangle a value card holds.
    rdNone = "none", rdWidth = "width", rdHeight = "height", rdX = "x", rdY = "y"

  CmdPart* = object
    ## Literal text, or a card: a variable placed in the command line.
    text*: string
    card*: bool
    name*: string
    kind*: CardKind
    content*: string
    rect*: int                    ## value cards: the rectangle drawn on run (1, 2, ...),
    dim*: RectDim                 ## and which of its numbers; 0 for text
    path*: bool                   ## value cards: a file path, browsed for with a save dialog on run,
    reveal*: bool                 ## and its folder opened once the command succeeds

  CommandLine* = object
    title*: string
    parts*: seq[CmdPart]

proc commandLinesPath(): string = configDir() / "commandlines.json"

proc loadCommandLines*(): seq[CommandLine] =
  let path = commandLinesPath()
  if fileExists(path):
    try:
      result = readFile(path).fromJson(seq[CommandLine])
    except CatchableError as e:
      stderr.writeLine "config: ignoring unreadable ", path, ": ", e.msg

proc save*(cmds: seq[CommandLine]) =
  let path = commandLinesPath()
  try:
    createDir(path.parentDir)
    writeAtomic(path, cmds.toJson)
  except CatchableError as e:
    stderr.writeLine "config: cannot save ", path, ": ", e.msg

# --- last values given in the Run window ------------------------------------

type
  RunValue* = object
    default*: string              ## the card's own content when this was given
    value*: string                ## value cards: the value
    which*: string                ## timestamp cards: "start", "current", "end", "loopA"
                                  ## or "loopB" chosen,
    time*: float                  ## else the time of the bookmark or chapter chosen
    crossed*: bool                ## rectangle cards: a drawn rectangle leaves it alone

  RunValues* = Table[string, Table[string, RunValue]]  ## title -> card name -> value

proc newHook*(v: var RunValue) =
  v = RunValue()

proc runValuesPath(): string = configDir() / "runvalues.json"

proc loadRunValues*(): RunValues =
  let path = runValuesPath()
  if fileExists(path):
    try:
      result = readFile(path).fromJson(RunValues)
    except CatchableError as e:
      stderr.writeLine "config: ignoring unreadable ", path, ": ", e.msg

proc save*(v: RunValues) =
  let path = runValuesPath()
  try:
    createDir(path.parentDir)
    writeAtomic(path, v.toJson)
  except CatchableError as e:
    stderr.writeLine "config: cannot save ", path, ": ", e.msg

proc lastValues*(c: CommandLine): Table[string, RunValue] =
  ## What c's cards were last run with, skipping cards whose own content has
  ## been changed in the Commands window since.
  for name, v in loadRunValues().getOrDefault(c.title):
    for p in c.parts:
      if p.card and p.name == name and p.content == v.default:
        result[name] = v
        break

proc moveValues*(oldTitle, newTitle: string) =
  ## Carries the values remembered for a command line over to its new title,
  ## or forgets them when newTitle is "" (deleted).
  var all = loadRunValues()
  if oldTitle notin all or oldTitle == newTitle: return
  if newTitle.len > 0: all[newTitle] = all[oldTitle]
  all.del(oldTitle)
  all.save()

proc rememberValues*(c: CommandLine, values: Table[string, RunValue]) =
  ## Keeps what c's cards ran with, for its next run.
  var all = loadRunValues()
  var mine = all.getOrDefault(c.title)
  for p in c.parts:
    if p.card and p.name in values:
      var v = values[p.name]
      v.default = p.content
      mine[p.name] = v
  all[c.title] = mine
  all.save()

const PresetCommandLines = staticRead("../assets/presets/commandlines.json")

let presetTitles = PresetCommandLines.fromJson(seq[CommandLine]).mapIt(it.title)

proc isPreset*(c: CommandLine): bool =
  ## True when c carries the title of a shipped command line.
  c.title in presetTitles

proc seedPresets*(c: var Config): bool =
  ## Adds the shipped command lines the user hasn't been offered yet, each
  ## once, so deleting one sticks. True when c changed and needs saving.
  var cmds = loadCommandLines()
  var added = false
  for p in PresetCommandLines.fromJson(seq[CommandLine]):
    if p.title in c.seededPresets: continue
    c.seededPresets.add p.title
    result = true
    if not cmds.anyIt(it.title == p.title):
      cmds.add p
      added = true
  if added: cmds.save()

const VideoExtensions* = [
  "mkv", "mp4", "m4v", "webm", "avi", "mov", "wmv", "flv", "mpg", "mpeg", "ts",
  "m2ts", "mts", "3gp", "ogv", "vob", "rmvb", "divx", "f4v", "asf"]

const AudioExtensions* = [
  "mp3", "flac", "ogg", "opus", "m4a", "aac", "wav", "wma", "alac", "ape",
  "wv", "mka", "aiff", "dts", "ac3"]

const MediaExtensions* = @VideoExtensions & @AudioExtensions

const SubtitleExtensions* = ["srt", "ass", "ssa", "vtt", "sub", "sup", "idx", "smi"]

proc isMediaFile*(path: string): bool =
  path.splitFile.ext.toLowerAscii.strip(chars = {'.'}) in MediaExtensions
