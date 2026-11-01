## Online videos kept on disk: a link streamed through mpv's yt-dlp hook is
## written out as it streams (mpv's dump-cache) into the cache folder, along
## with its subtitles and chapters. Opened again where some of it was saved,
## a link plays that from disk, the stream going on where it ends.

import std/[os, strutils, strformat, tables, times, hashes, algorithm, sequtils, uri]
import jsony
import spherical
when not defined(windows): import std/posix

type
  Seg* = object
    ## A file of the stream as mpv wrote it: its time 0 is the link's `start`,
    ## and it holds the link up to `stop`.
    file*: string
    start*, stop*: float
    format*: string           ## yt-dlp's format ids it holds ("401+251"); "": saved
                              ## before formats were noted, as `auto` then was
    sphere*: SphereInfo       ## its picture on the sphere: mpv's files don't say

  Saved* = object
    title*: string
    duration*: float          ## the link's whole length
    segs*: seq[Seg]
    subs*: seq[string]        ## its subtitle files
    subsDone*: bool           ## looked for (there may be none)
    chapters*: string         ## its chapters, ffmetadata
    used*: float              ## last opened, epoch seconds
    auto*: string             ## the format ids Options > Online's choice came to
    autoVideo*, autoAudio*: string  ## Auto's video and audio, as each last played
    videoOffers*, audioOffers*: seq[tuple[id, label, lang, langName: string]]  ## the qualities it offers
                              ## (the quality menu's), for locks

  SaveIndex* = Table[string, Saved]

  LinkInfo* = object
    ## What the playlist shows of a link, kept whether its streams are or not
    ## so that it isn't looked up again.
    title*: string
    duration*: float
    width*, height*: int
    audioBitrate*: float
    looked*: bool             ## yt-dlp answered: what's unknown it doesn't know
    noted*: float             ## last written, epoch seconds

  LinkInfos* = Table[string, LinkInfo]

  Limits* = object
    ## Options > Playback > Media Cache; 0 = no limit.
    hours*: float             ## links not opened for this long are forgotten
    count*: int               ## past this many links, the least recently opened go
    bytes*: int64             ## saved streams past this, the oldest go first

  WebItem* = object
    ## A saved link as Options > Playback > Media Cache lists it.
    url*, title*: string
    bytes*: int64
    saved*, duration*: float  ## seconds of it saved, its whole length
    used*: float
    files*: seq[string]

const MaxLinkInfos = 100_000

var dirChosen = ""

proc defaultSaveDir*(): string = getCacheDir("majestic-media-player") / "streams"
proc saveDir*(): string = (if dirChosen.len > 0: dirChosen else: defaultSaveDir())
proc setSaveDir*(d: string) =
  ## The folder links are saved in; "" = defaultSaveDir.
  dirChosen = d
proc indexPath(): string = saveDir() / "index.json"
proc infosPath(): string = saveDir() / "links.json"

proc ours(f: string): bool =
  ## A file the player saved: the folder may be one the user picked, holding
  ## other files too.
  let n = f.extractFilename
  if n in ["index.json", "index.json.tmp", "links.json", "links.json.tmp"]: return true
  n.len > 13 and n[12] in {'-', '.'} and n[0 .. 11].allCharsInSet({'0' .. '9', 'a' .. 'f'})

proc youtubeHost*(u: Uri): string =
  ## The link's host without its www., m. or music.
  result = u.hostname.toLowerAscii
  for pre in ["www.", "m.", "music."]:
    if result.startsWith(pre): result = result[pre.len .. ^1]

proc youtubeId*(url: string): string =
  ## The video id of a YouTube link (watch?v=, youtu.be/, shorts/, live/,
  ## embed/), "" for anything else.
  let u = try: url.parseUri except UriParseError: return ""
  let host = u.youtubeHost
  let parts = u.path.split('/').filterIt(it.len > 0)
  if host == "youtu.be":
    if parts.len > 0: result = parts[0]
  elif host in ["youtube.com", "youtube-nocookie.com"]:
    if parts.len == 1 and parts[0] == "watch":
      for (k, v) in u.query.decodeQuery:
        if k == "v": result = v
    elif parts.len >= 2 and parts[0] in ["shorts", "live", "embed", "v"]:
      result = parts[1]
  if not result.allCharsInSet(Letters + Digits + {'-', '_'}): result = ""

proc withoutTracking*(url: string): string =
  ## A YouTube link without its pp= (how the link was found, nothing to play).
  result = url
  let u = try: url.parseUri except UriParseError: return
  if u.youtubeHost notin ["youtube.com", "youtu.be", "youtube-nocookie.com"]: return
  let q = url.find('?')
  if q < 0: return
  let hash = url.find('#', q)
  let stop = if hash < 0: url.len else: hash
  let kept = url[q + 1 ..< stop].split('&').filterIt(not it.startsWith("pp="))
  result = url[0 ..< q] & (if kept.len > 0: "?" & kept.join("&") else: "") & url[stop .. ^1]

proc linkKey*(url: string): string =
  ## What a link is saved under: however a YouTube video was reached (a
  ## playlist, an index, a time, youtu.be/...), it's the one video.
  let id = url.youtubeId
  if id.len > 0: "https://www.youtube.com/watch?v=" & id else: url

proc lookup*(t: SaveIndex, url: string): Saved =
  ## What's saved of a link, by any of its spellings.
  t.getOrDefault(url.linkKey)

proc lookup*(t: LinkInfos, url: string): LinkInfo =
  ## What's known of a link, by any of its spellings.
  t.getOrDefault(url.linkKey)

proc keyOf*(url: string): string =
  ## The start of the names of a link's files.
  (hash(url.linkKey).uint64 and 0xFFFF_FFFF_FFFF'u64).toHex(12).toLowerAscii

proc newSegFile*(url: string): string =
  saveDir() / &"{keyOf(url)}-{int64(epochTime() * 1000)}.mkv"

proc removeQuietly(f: string) =
  if f.len == 0: return
  try: removeFile(f)
  except OSError: discard

proc sorted(s: Saved): seq[Seg] =
  result = s.segs
  result.sort(proc (a, b: Seg): int = cmp(a.start, b.start))

proc chainAt*(s: Saved, t: float): tuple[start, stop: float] =
  ## The stretch saved without a gap that holds t; stop <= start when none.
  var run = (start: 0.0, stop: -1.0)
  for g in s.sorted:
    if run.stop >= run.start and g.start <= run.stop + 0.05:
      run.stop = max(run.stop, g.stop)
    else:
      if run.stop > run.start and run.start <= t + 0.05 and t < run.stop: return run
      run = (g.start, g.stop)
  if run.stop > run.start and run.start <= t + 0.05 and t < run.stop: return run
  (0.0, -1.0)

proc covered*(s: Saved): float =
  ## How far from the start the saved files reach without a gap.
  let c = s.chainAt(0)
  if c.stop > c.start: c.stop else: 0

proc complete*(s: Saved): bool =
  ## The whole link is saved.
  s.duration > 0 and s.covered >= s.duration - 1

proc wholeFile*(s: Saved): string =
  ## The one file holding all of the link, from its start; "" when none does.
  for g in s.segs:
    if s.duration > 0 and g.start <= 0.05 and g.stop >= s.duration - 1 and fileExists(g.file):
      return g.file

proc timeline*(s: Saved, start, stop: float): string =
  ## The stretch saved from `start` to `stop` (chainAt), one file after
  ## another, as an mpv EDL keeping the link's times: before `start` it holds
  ## a stand-in (never played) for the time it leaves out.
  let segs = s.sorted
  result = "edl://!no_chapters;"
  var at = start
  var first = true
  while at < stop - 0.05:
    # Of the files holding `at`, the one that goes on furthest.
    var best = -1
    for i, g in segs:
      if g.start <= at + 0.05 and g.stop > at + 0.05 and
         (best < 0 or g.stop > segs[best].stop): best = i
    if best < 0: break
    let g = segs[best]
    if first and start > 0.05:
      result.add &"%{g.file.len}%{g.file},0,{start:.6f};"
    first = false
    let upTo = min(g.stop, stop)
    result.add &"%{g.file.len}%{g.file},{max(at - g.start, 0):.6f},{upTo - at:.6f};"
    at = upTo

proc formatOf(s: Saved, g: Seg): string = (if g.format.len > 0: g.format else: s.auto)

proc inFormat*(s: Saved, format: string): Saved =
  ## s with only its files of the stream in `format` (format ids).
  result = s
  result.segs = s.segs.filterIt(s.formatOf(it) == format)

proc setAuto*(s: var Saved, format: string) =
  ## Notes what Options > Online's choice came to; files saved before formats
  ## were noted keep standing for the one it came to then.
  if s.auto.len > 0:
    for g in s.segs.mitems:
      if g.format.len == 0: g.format = s.auto
  s.auto = format

proc addSeg*(s: var Saved, g: Seg) =
  ## Adds a file of the stream; those in its format it holds all of go.
  var keep: seq[Seg]
  for o in s.segs:
    if o.file != g.file and s.formatOf(o) == s.formatOf(g) and
       o.start >= g.start - 0.05 and o.stop <= g.stop: removeQuietly(o.file)
    elif o.file != g.file: keep.add o
  keep.add g
  s.segs = keep

proc forget*(s: Saved) =
  ## Deletes a link's saved files.
  for g in s.segs: removeQuietly(g.file)
  for f in s.subs: removeQuietly(f)
  removeQuietly(s.chapters)

proc save*(t: SaveIndex) =
  try:
    createDir(saveDir())
    writeFile(indexPath() & ".tmp", t.toJson)
    moveFile(indexPath() & ".tmp", indexPath())
  except IOError, OSError: discard

proc save*(t: LinkInfos) =
  if t.len == 0:  # cleared: nothing left for the Media Cache page to count
    removeQuietly(infosPath())
    return
  try:
    createDir(saveDir())
    writeFile(infosPath() & ".tmp", t.toJson)
    moveFile(infosPath() & ".tmp", infosPath())
  except IOError, OSError: discard

proc loadLinkInfos*(): LinkInfos =
  ## The links' metadata; the Limits leave it be (it's small, and a playlist
  ## outlives its streams), only the oldest going past MaxLinkInfos.
  result = try: readFile(infosPath()).fromJson(LinkInfos)
           except CatchableError: initTable[string, LinkInfo]()
  if result.len <= MaxLinkInfos: return
  var order = toSeq(result.pairs)
  order.sort(proc (a, b: (string, LinkInfo)): int = cmp(a[1].noted, b[1].noted))
  for (url, _) in order[0 ..< order.len - MaxLinkInfos]: result.del url
  result.save()

proc absorb(s: var Saved, newer: Saved) =
  ## Takes in `newer`, another entry of the same link. Files in the same format
  ## held by another go; subtitles stay one entry's, being numbered alike.
  for g in s.segs.mitems: g.format = s.formatOf(g)
  for o in newer.segs:
    if not fileExists(o.file): continue
    var g = o
    g.format = newer.formatOf(o)
    if s.segs.anyIt(it.format == g.format and it.start <= g.start + 0.05 and
                    it.stop >= g.stop and fileExists(it.file)):
      removeQuietly(g.file)
    else: s.addSeg(g)
  if newer.title.len > 0: s.title = newer.title
  s.duration = max(s.duration, newer.duration)
  if newer.subsDone: (s.subs, s.subsDone) = (newer.subs, true)
  if newer.chapters.len > 0: s.chapters = newer.chapters
  s.used = max(s.used, newer.used)
  if newer.auto.len > 0: s.auto = newer.auto
  if newer.autoVideo.len > 0: s.autoVideo = newer.autoVideo
  if newer.autoAudio.len > 0: s.autoAudio = newer.autoAudio
  if newer.videoOffers.len > 0: s.videoOffers = newer.videoOffers
  if newer.audioOffers.len > 0: s.audioOffers = newer.audioOffers

proc loadSaveIndex*(): SaveIndex =
  ## The index; links saved under other spellings than linkKey's join up.
  let read = try: readFile(indexPath()).fromJson(SaveIndex)
             except CatchableError: initTable[string, Saved]()
  if toSeq(read.keys).allIt(it == it.linkKey): return read
  var order = toSeq(read.pairs)
  order.sort(proc (a, b: (string, Saved)): int = cmp(a[1].used, b[1].used))
  for (url, s) in order:
    let key = url.linkKey
    if key in result: result[key].absorb(s)
    else: result[key] = s
  result.save()

proc fileBytes(f: string): int64 =
  try: getFileSize(f) except OSError: 0

proc removeStray*(t: SaveIndex, grace = initDuration(minutes = 1)) =
  ## Deletes files of ours no link has. The grace spares a file being written
  ## by another instance of the player.
  var known: seq[string]
  for s in t.values:
    for g in s.segs: known.add g.file
    known.add s.subs
    known.add s.chapters
  let recent = getTime() - grace
  try:
    for kind, f in walkDir(saveDir()):
      if kind == pcFile and f.ours and f notin [indexPath(), infosPath()] and f notin known and
         getLastModificationTime(f) < recent: removeQuietly(f)
  except OSError: discard

proc prune*(t: var SaveIndex, lim: Limits, keep = "") =
  ## Forgets links not opened for lim.hours, and the files gone; then the
  ## least recently opened links while there are more than lim.count, or
  ## their streams take more than lim.bytes. Files of ours no link has go
  ## too. `keep` (the link playing) stays whatever the limits.
  let keep = if keep.len > 0: keep.linkKey else: ""
  let cut = epochTime() - lim.hours * 3600
  var gone: seq[string]
  for url, s in t.mpairs:
    if lim.hours > 0 and s.used < cut and url != keep:
      s.forget()
      gone.add url
      continue
    var segs: seq[Seg]
    for g in s.segs:
      if fileExists(g.file): segs.add g
    s.segs = segs
    if s.segs.len == 0 and url != keep: gone.add url
  for url in gone: t.del url
  var order: seq[(float, string, int64)]
  var total = 0'i64
  for url, s in t:
    var b = 0'i64
    for g in s.segs: b += fileBytes(g.file)
    total += b
    order.add (s.used, url, b)
  order.sort()
  var left = t.len
  for (_, url, b) in order:
    if (lim.bytes <= 0 or total <= lim.bytes) and (lim.count <= 0 or left <= lim.count): break
    if url == keep: continue
    t[url].forget()
    total -= b
    dec left
    t.del url
  t.removeStray()
  t.save()

proc drop*(t: var SaveIndex, urls: openArray[string]) =
  ## Deletes the links' saved files and forgets them.
  for url in urls:
    let key = url.linkKey
    if key in t:
      t[key].forget()
      t.del key
  t.save()

proc savedTime(s: Saved): float =
  ## Seconds of the link the files hold, overlaps counted once.
  var at = 0.0
  for g in s.sorted:
    let a = max(g.start, at)
    if g.stop > a: result += g.stop - a
    at = max(at, g.stop)

proc items*(t: SaveIndex): seq[WebItem] =
  ## The saved links, the most recently opened first.
  for url, s in t:
    var it = WebItem(url: url, title: s.title, saved: s.savedTime,
                     duration: s.duration, used: s.used)
    for g in s.segs: it.files.add g.file
    it.files.add s.subs
    if s.chapters.len > 0: it.files.add s.chapters
    for f in it.files: it.bytes += fileBytes(f)
    result.add it
  result.sort(proc (a, b: WebItem): int = cmp(b.used, a.used))

proc usedBytes*(): int64 =
  ## What the files of ours in the folder take.
  try:
    for kind, f in walkDir(saveDir()):
      if kind == pcFile and f.ours: result += fileBytes(f)
  except OSError: discard

proc diskSpace*(): tuple[free, total: int64] =
  ## Space left on the folder's disk, and its size; -1 when unknown.
  result = (-1'i64, -1'i64)
  var d = saveDir()
  while not dirExists(d) and d.parentDir.len > 0 and d.parentDir != d: d = d.parentDir
  when defined(windows):
    proc GetDiskFreeSpaceExW(dir: WideCString, avail, total, free: ptr uint64): int32 {.
      stdcall, dynlib: "kernel32", importc.}
    var avail, total: uint64
    if GetDiskFreeSpaceExW(newWideCString(d), addr avail, addr total, nil) != 0:
      result = (int64(avail), int64(total))
  else:
    var st: Statvfs
    if statvfs(d.cstring, st) == 0:
      result = (int64(st.f_bavail) * int64(st.f_frsize), int64(st.f_blocks) * int64(st.f_frsize))

proc writeChapters*(url: string, chapters: seq[tuple[time: float, title: string]],
                    duration: float): string =
  ## Writes chapters as ffmetadata (mpv's chapters-file), returning the file;
  ## "" when none.
  if chapters.len == 0: return
  proc esc(s: string): string =
    for c in s:
      if c in {'=', ';', '#', '\\', '\n'}: result.add '\\'
      result.add c
  var text = ";FFMETADATA1\n"
  for i, c in chapters:
    let stop = if i + 1 < chapters.len: chapters[i + 1].time else: max(duration, c.time)
    text.add &"[CHAPTER]\nTIMEBASE=1/1000\nSTART={int(c.time * 1000)}\n" &
      &"END={int(stop * 1000)}\ntitle={esc(c.title)}\n"
  result = saveDir() / keyOf(url) & ".ffmetadata"
  try:
    createDir(saveDir())
    writeFile(result, text)
  except IOError, OSError: result = ""
