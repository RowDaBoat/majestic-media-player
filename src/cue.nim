## Cue sheets: an album ripped to one audio file (album.flac) with a .cue
## beside it saying where each track starts. Each track becomes a playlist
## entry of its own, "<sheet>.cue#<track number>", played as a segment of the
## audio file through mpv's EDL (so its time, duration, seeking and end are
## the track's).
##
## Rippers often leave a sheet per format (album.flac.cue, album.wav.cue) or
## one naming the .wav the audio was ripped to before being compressed: a
## FILE that isn't there is looked for under the same name with another
## audio extension.

import std/[os, strutils, tables, times, algorithm]
from std/unicode import validateUtf8, Rune, toUTF8
from config import AudioExtensions

type
  CueTrack* = object
    number*: int        ## TRACK nn
    title*, performer*: string
    start*: float       ## seconds into the audio file (INDEX 01)

  CueSheet* = object
    path*: string       ## the .cue
    audio*: string      ## the audio file it describes, "" when not found
    exact*: bool        ## audio is the file FILE names (not one found by name)
    title*, performer*, genre*: string
    year*: int
    tracks*: seq[CueTrack]

var cache: Table[string, tuple[stamp: Time, sheet: CueSheet]]

proc isCueFile*(path: string): bool =
  path.toLowerAscii.endsWith(".cue")

proc toUtf8(s: string): string =
  ## Sheets come in UTF-8 (with or without a BOM) or the ripper's code page:
  ## anything that isn't valid UTF-8 is taken as Windows-1252/Latin-1.
  var t = s
  if t.startsWith("\xEF\xBB\xBF"): t = t[3 .. ^1]
  if validateUtf8(t) < 0: return t
  for c in t: result.add Rune(ord(c)).toUTF8

proc unquote(s: string): string =
  let s = s.strip
  if s.len >= 2 and s[0] == '"':
    let e = s.rfind('"')
    if e > 0: return s[1 ..< e]
  s

proc msf(s: string): float =
  ## "mm:ss:ff", ff in CD frames (1/75 s); -1 when malformed.
  let p = s.strip.split(':')
  if p.len != 3: return -1
  try: p[0].parseInt.float * 60 + p[1].parseInt.float + p[2].parseInt.float / 75
  except ValueError: -1

proc findAudio(cue, fileRef: string): tuple[path: string, exact: bool] =
  ## The audio file FILE names, else one of the same name (or the sheet's)
  ## with another audio extension: album.wav ripped then compressed to .flac.
  let dir = cue.parentDir
  let refName = fileRef.replace('\\', '/').extractFilename
  if refName.len > 0:
    let direct = if fileRef.isAbsolute: fileRef else: dir / fileRef.replace('\\', '/')
    if fileExists(direct): return (direct, true)
    if fileExists(dir / refName): return (dir / refName, true)
  var bases: seq[string]
  if refName.len > 0: bases.add refName.changeFileExt("").toLowerAscii
  let own = cue.extractFilename.changeFileExt("")  # album.wav (.cue gone)
  bases.add own.toLowerAscii
  bases.add own.changeFileExt("").toLowerAscii     # album
  var best = (rank: bases.len, path: "")
  try:
    for kind, f in walkDir(dir):
      if kind notin {pcFile, pcLinkToFile}: continue
      let (_, name, ext) = f.splitFile
      if ext.toLowerAscii.strip(chars = {'.'}) notin AudioExtensions: continue
      let r = bases.find(name.toLowerAscii)
      if r >= 0 and (r < best.rank or r == best.rank and f < best.path): best = (r, f)
  except OSError: discard
  (best.path, false)

proc parseCue*(path, text: string): CueSheet =
  ## The sheet's tracks in the one audio file it describes. Sheets of
  ## several FILEs (a file per track) give no tracks: those files play as
  ## they are.
  result.path = path
  var files = 0
  var fileRef = ""
  var cur = -1
  for raw in text.toUtf8.splitLines:
    let line = raw.strip
    let sp = line.find(' ')
    if sp < 0: continue
    let (cmd, rest) = (line[0 ..< sp].toUpperAscii, line[sp + 1 .. ^1].strip)
    case cmd
    of "FILE":
      inc files
      # FILE "name" WAVE: the type after the closing quote
      fileRef = if rest.startsWith('"'): rest.unquote
                else: rest.rsplit(' ', 1)[0]
    of "TRACK":
      let w = rest.splitWhitespace
      var n = 0
      try: n = w[0].parseInt except ValueError, IndexDefect: discard
      if w.len < 2 or w[1].toUpperAscii != "AUDIO":
        cur = -1  # data tracks aren't played
        continue
      result.tracks.add CueTrack(number: n, start: -1)
      cur = result.tracks.high
    of "TITLE":
      if cur >= 0: result.tracks[cur].title = rest.unquote
      else: result.title = rest.unquote
    of "PERFORMER":
      if cur >= 0: result.tracks[cur].performer = rest.unquote
      else: result.performer = rest.unquote
    of "INDEX":
      if cur < 0: continue
      let w = rest.splitWhitespace
      if w.len < 2: continue
      let t = w[1].msf
      # INDEX 01 starts the track; a lone INDEX 00 (pregap) stands in for it.
      if w[0] == "01" or w[0] == "1": result.tracks[cur].start = t
      elif result.tracks[cur].start < 0 and w[0] in ["00", "0"]:
        result.tracks[cur].start = t
    of "REM":
      let w = rest.split(' ', 1)
      if w.len < 2: continue
      case w[0].toUpperAscii
      of "DATE":
        let d = w[1].unquote
        if d.len >= 4 and d[0 .. 3].allCharsInSet(Digits): result.year = d[0 .. 3].parseInt
      of "GENRE": result.genre = w[1].unquote
      else: discard
    else: discard
  var kept: seq[CueTrack]
  for t in result.tracks:
    if t.start >= 0 and (kept.len == 0 or t.start > kept[^1].start): kept.add t
  result.tracks = kept
  if files != 1:
    result.tracks.setLen 0
    return
  (result.audio, result.exact) = findAudio(path, fileRef)
  if result.audio.len == 0: result.tracks.setLen 0

proc readCue*(path: string): CueSheet =
  ## The sheet at path, read again only when it changes; no tracks when it
  ## can't be read or names no audio file that's there.
  let full = path.absolutePath
  var stamp: Time
  try: stamp = getLastModificationTime(full)
  except OSError:
    cache.del full
    return CueSheet(path: full)
  if full in cache and cache[full].stamp == stamp: return cache[full].sheet
  var text = ""
  try: text = readFile(full)
  except IOError, OSError: discard
  result = parseCue(full, text)
  cache[full] = (stamp, result)

# --- playlist entries ------------------------------------------------------

proc cueEntry*(cue: string, track: int): string = cue & "#" & $track

proc splitCueEntry*(s: string): tuple[cue: string, track: int] =
  ## "<sheet>.cue#<n>" apart; ("", 0) for anything else.
  let h = s.rfind('#')
  if h <= 4 or h == s.high or not s[h + 1 .. ^1].allCharsInSet(Digits) or
     not s[0 ..< h].isCueFile or s.contains("://"):
    return ("", 0)
  try: (s[0 ..< h], s[h + 1 .. ^1].parseInt)
  except ValueError: ("", 0)

proc isCueEntry*(s: string): bool = s.splitCueEntry.cue.len > 0

proc cueTrack*(entry: string): tuple[sheet: CueSheet, i: int] =
  ## The entry's sheet and the index of its track there; i is -1 when the
  ## sheet or the track is gone.
  result.i = -1
  let (cue, n) = entry.splitCueEntry
  if cue.len == 0: return
  result.sheet = readCue(cue)
  for i, t in result.sheet.tracks:
    if t.number == n: return (result.sheet, i)

proc cueEntryExists*(entry: string): bool = entry.cueTrack.i >= 0

proc entries*(s: CueSheet): seq[string] =
  for t in s.tracks: result.add cueEntry(s.path, t.number)

proc span*(s: CueSheet, i: int): tuple[start, length: float] =
  ## Where track i lies in the audio file; length -1 for the last (to the end).
  let start = s.tracks[i].start
  (start, if i < s.tracks.high: s.tracks[i + 1].start - start else: -1.0)

proc cueSource*(entry: string): string =
  ## What mpv opens for the entry: its track of the audio file, as an EDL
  ## timeline of that one segment; "" when the track is gone.
  let (s, i) = entry.cueTrack
  if i < 0: return ""
  let (start, length) = s.span(i)
  result = "edl://!no_chapters;%" & $s.audio.len & "%" & s.audio & "," &
    formatFloat(start, ffDecimal, 6)
  if length > 0: result.add "," & formatFloat(length, ffDecimal, 6)

proc cueFile*(entry: string): string =
  ## The file on disk behind a playlist entry: a track's audio file, else
  ## the entry itself.
  if entry.isCueEntry: entry.cueTrack.sheet.audio else: entry

proc cueTitle*(entry: string): string =
  ## A track's name as the sheet has it ("Track 3" without one); "" for
  ## anything but a track.
  let (s, i) = entry.cueTrack
  if i < 0: return ""
  let t = s.tracks[i]
  if t.title.len > 0: t.title else: "Track " & $t.number

proc cueArtist*(s: CueSheet, i: int): string =
  if s.tracks[i].performer.len > 0: s.tracks[i].performer else: s.performer

# --- finding sheets --------------------------------------------------------

proc sheetsIn(dir: string): seq[CueSheet] =
  ## The usable sheets in dir, the one naming its audio file exactly first
  ## (album.flac.cue before album.wav.cue).
  var cues: seq[string]
  try:
    for kind, f in walkDir(dir):
      if kind in {pcFile, pcLinkToFile} and f.isCueFile: cues.add f
  except OSError: discard
  cues.sort()
  for c in cues:
    let s = readCue(c)
    if s.tracks.len > 0: result.add s
  result.sort(proc (a, b: CueSheet): int = cmp(b.exact, a.exact), SortOrder.Ascending)

proc sheetFor*(audio: string): CueSheet =
  ## The sheet beside an audio file that splits it into tracks, if any.
  let full = audio.absolutePath
  for s in sheetsIn(full.parentDir):
    if s.audio.absolutePath == full: return s

proc withCueTracks*(files: seq[string]): seq[string] =
  ## Files as given, but a .cue becomes its tracks and an audio file a sheet
  ## splits becomes the sheet's tracks (once, however many sheets name it).
  ## A sheet that doesn't work stays out: there's nothing in it to play.
  var sheets: Table[string, seq[CueSheet]]  # per folder
  var done: seq[string]                     # audio files already split
  for f in files:
    if f.contains("://") or f.isCueEntry:
      result.add f
      continue
    var s: CueSheet
    if f.isCueFile:
      s = readCue(f)
      if s.tracks.len == 0: continue
    else:
      let full = f.absolutePath
      let dir = full.parentDir
      if dir notin sheets: sheets[dir] = sheetsIn(dir)
      for c in sheets[dir]:
        if c.audio.absolutePath == full:
          s = c
          break
      if s.tracks.len == 0:
        result.add f
        continue
    let audio = s.audio.absolutePath
    if audio in done: continue
    done.add audio
    result.add s.entries
