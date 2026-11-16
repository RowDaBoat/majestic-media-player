## Majestic Meta Container (.m2c): the tags of a media file whose format
## can't keep any (Westwood .aud, MIDI, tracker modules, files TagLib can't
## write), in a file of their own in the m2c subfolder of its folder:
## `<folder>/m2c/<file name>.m2c` for `<folder>/<file name>`. Properties writes one for such a file
## (tagdlg); wherever tags are read (the playlist's columns, the Library,
## Media Info, the window title, media controls, folder pictures), a file's
## .m2c lays its fields over the file's own.
##
## The format, UTF-8 text, a field per line:
##
##   # Majestic Meta Container 1
##   TITLE=Bog
##   ARTIST=Frank Klepacki
##   ARTIST=Second Artist
##   COMMENT=First line\nSecond line
##   DATE=
##
## Keys are TagLib's property names (TITLE, ARTIST, ALBUMARTIST,
## TRACKNUMBER, TRACKTOTAL...), upper case; a key given again adds a value.
## `KEY=` with nothing after it clears the field: a value the file holds
## itself (a MIDI file's title) is hidden. In values, `\\` is a backslash,
## `\n` a line break, `\r` a carriage return. Spaces and tabs around a key
## and its value don't count (`TITLE = Bog` is fine). Lines starting with #
## are comments; blank lines and lines without `=` are skipped.
##
## ReplayGain goes in a .m2c as in tags (REPLAYGAIN_TRACK_GAIN "-6.54 dB",
## REPLAYGAIN_TRACK_PEAK "0.988831", and the ALBUM ones): the analysis
## writes them there for such files, and the player applies them itself
## (player.nim's `rgFor`), as mpv only reads a file's own.
##
## The Library's worker threads read these too: nothing here but `usesSide`
## calls TagLib, which is loaded on the main thread before any thread uses it.

import std/[os, strutils, tables, json, algorithm, times, sequtils]
import tagedit
from config import MidiExtensions, TrackerExtensions

const
  SideDir* = "m2c"
  SideExt* = ".m2c"
  Magic = "# Majestic Meta Container 1"
  # The order fields are written in: the usual ones first, as Properties
  # lists them, then the rest by name.
  Order = ["TITLE", "ARTIST", "ALBUM", "ALBUMARTIST", "DATE", "GENRE",
    "TRACKNUMBER", "TRACKTOTAL", "DISCNUMBER", "DISCTOTAL", "COMPOSER", "COMMENT"]

type
  SideTags* = object
    exists*: bool                     ## there's a .m2c for the file
    tags*: Table[string, seq[string]] ## field -> its values (none empty)
    cleared*: seq[string]             ## fields `KEY=` hides

proc sidePath*(media: string): string =
  ## Where the .m2c of the media file at `media` is.
  media.parentDir / SideDir / (media.extractFilename & SideExt)

proc isLocal(media: string): bool =
  ## A file on disk (a cue sheet's track, "<sheet>.cue#<n>", never has one).
  media.len > 0 and not media.contains("://")

proc sideTime*(media: string): int64 =
  ## When the file's .m2c was last written, seconds since 1970; 0 without one.
  if not media.isLocal: return 0
  try: getLastModificationTime(media.sidePath).toUnix
  except OSError: 0

proc unescape(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      case s[i + 1]
      of 'n': result.add '\n'
      of 'r': result.add '\r'
      of '\\': result.add '\\'
      else: result.add s[i .. i + 1]  # not an escape: as written
      i += 2
    else:
      result.add s[i]
      inc i

proc escape(s: string): string =
  for c in s:
    case c
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    else: result.add c

proc parseSide*(text: string): SideTags =
  result.exists = true
  var t = text
  if t.startsWith("\xEF\xBB\xBF"): t = t[3 .. ^1]  # a BOM an editor added
  var empty: seq[string]
  for raw in t.split('\n'):
    let line = raw.strip(leading = false, trailing = true, chars = {'\r'})
    if line.strip.len == 0 or line.strip.startsWith("#"): continue
    let eq = line.find('=')
    if eq <= 0: continue
    let key = line[0 ..< eq].strip.toUpperAscii
    if key.len == 0: continue
    let value = line[eq + 1 .. ^1].strip(chars = {' ', '\t'}).unescape
    if value.len == 0:
      if key notin empty: empty.add key
    else: result.tags.mgetOrPut(key, @[]).add value
  for k in empty:
    if k notin result.tags: result.cleared.add k

proc readSide*(media: string): SideTags =
  ## The file's .m2c, `exists` false without one (or unreadable).
  if not media.isLocal: return
  let p = media.sidePath
  if not fileExists(p): return
  try: result = parseSide(readFile(p))
  except IOError, OSError: result = SideTags()

proc fieldOrder(a, b: string): int =
  let (i, j) = (Order.find(a), Order.find(b))
  if i >= 0 and j >= 0: cmp(i, j)
  elif i >= 0: -1
  elif j >= 0: 1
  else: cmp(a, b)

proc formatSide*(name: string, tags: Table[string, seq[string]], cleared: seq[string]): string =
  ## The .m2c text: `name` (the media file's) in a comment, the fields, then
  ## those cleared.
  result = Magic & "\n# Tags of " & name.escape & ", kept by Majestic Media Player.\n"
  var keys: seq[string]
  for k, vs in tags:
    if vs.anyIt(it.len > 0): keys.add k
  keys.sort(fieldOrder)
  for k in keys:
    for v in tags[k]:
      if v.len > 0: result.add k & "=" & v.escape & "\n"
  var gone = cleared
  gone.sort(fieldOrder)
  for k in gone:
    if k notin keys: result.add k & "=\n"

proc writeSide*(media: string, tags: Table[string, seq[string]], cleared: seq[string]): string =
  ## Writes the file's .m2c (whole, replacing it); with no fields and nothing
  ## cleared, removes it, and the m2c folder once empty. "" or the error.
  let p = media.sidePath
  let dir = p.parentDir
  var any = cleared.len > 0
  for k, vs in tags:
    if vs.anyIt(it.len > 0): any = true
  try:
    if not any:
      if fileExists(p): removeFile(p)
      if dirExists(dir):
        var empty = true
        for _ in walkDir(dir):
          empty = false
          break
        if empty: removeDir(dir)
      return ""
    createDir(dir)
    let tmp = dir / ("." & p.extractFilename & ".tmp")
    writeFile(tmp, formatSide(media.extractFilename, tags, cleared))
    moveFile(tmp, p)
    ""
  except IOError, OSError:
    "couldn't write " & SideDir / p.extractFilename & ": " & getCurrentExceptionMsg()

proc overlay*(meta: JsonNode, side: SideTags): JsonNode =
  ## mpv's (or ffprobe's) tags of a file, as a JSON object, with its .m2c's
  ## laid over them: a field it has replaces the file's of that name
  ## (whatever its case), several values joined by "; "; a cleared one goes.
  if not side.exists: return meta
  result = newJObject()
  var drop: seq[string]
  for k in side.tags.keys: drop.add k.toLowerAscii
  for k in side.cleared: drop.add k.toLowerAscii
  if meta != nil and meta.kind == JObject:
    for k, v in meta:
      if k.toLowerAscii notin drop: result[k] = v
  for k, vs in side.tags:
    result[k] = %vs.join("; ")

proc keepsNoTags*(path: string, taglibOk: bool): bool =
  ## The file's tags can't be written into it, so they go to a .m2c:
  ## Westwood .aud, MIDI, tracker modules (TagLib reads them, but saving one
  ## rewrites the samples' and instruments' names, where trackers' authors
  ## leave their messages, losing their non-ASCII characters), and whatever
  ## TagLib can't open (taglibOk: it read the file), all files without
  ## TagLib: their own fields, read-only, stay, the .m2c's over them.
  let ext = path.splitFile.ext.toLowerAscii.strip(chars = {'.'})
  ext == "aud" or ext in MidiExtensions or ext in TrackerExtensions or not taglibOk

proc usesSide*(path: string, taglibOk: bool): bool =
  ## Tags written for the file go to its .m2c: it has one, or its format
  ## keeps none.
  path.isLocal and (fileExists(path.sidePath) or path.keepsNoTags(taglibOk))

proc overlay*(tags: Table[string, seq[string]], side: SideTags): Table[string, seq[string]] =
  ## The same for fields as TagLib names them (upper case).
  result = tags
  if not side.exists: return
  for k in side.cleared: result.del k
  for k, vs in side.tags: result[k] = vs
