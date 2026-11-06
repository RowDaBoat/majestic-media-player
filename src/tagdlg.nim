## Playlist > Properties: the selected files' tags in a grid, one field per
## row (Name | Value), edited in place like a spreadsheet's cells: typing
## over a cell replaces its value, Enter or Tab keeps it and goes down. The
## value box under the grid shows (and edits) the whole selected value,
## line breaks included. With several files, a field they don't agree on
## shows <multiple values> and is left alone unless edited.
##
## Autofill fills fields from the file names, by a pattern such as
## "%tracknumber% - %title%", or numbers the tracks in playlist order.
## Details shows what else a file holds, read-only: ffprobe's report, a
## tracker module's message and sample names, a MIDI file's texts.
## Nothing is written until OK or Apply (`saveFile`, called by the app).

import std/[strutils, sequtils, tables, algorithm, os, strformat, math]
import silky, vmath, bumpy, pixie
import ui, theme, tagedit, mediainfo, tracker
from config import MidiExtensions, TrackerExtensions

type
  DetailSection* = tuple[title: string, rows: seq[(string, string)]]

  TagEntry* = object
    path*: string
    editable*: bool           ## TagLib opened it: its tags can be written
    orig*, tags*: Tags        ## as read and as edited, totals apart from numbers
    combine: bool             ## the format keeps "number/total" in one field
    trackTotalKey, discTotalKey: string  ## the total fields' names in the file
    details: seq[DetailSection]
    detailsRead: bool

  TagTab* = enum ttMetadata = "Metadata", ttAutofill = "Autofill", ttDetails = "Details"

  TagAction* = enum
    taNone, taApply, taOk, taCancel
    taPattern                 ## a pattern filled fields: remember it (pattern)
    taPrefs                   ## patterns forgotten or columns resized: keep patterns, colWidths

  RowKind = enum rkField, rkHeader, rkAdd
  GridRow = object
    kind: RowKind
    key, label: string
    standard: bool

  TagDialog* = ref object
    files*: seq[TagEntry]     ## in playlist order
    tab*: TagTab
    sel: string               ## the selected row's field; AddKey for Add field
    editKey: string           ## the field being edited, "" when none
    edit, editStart: string   ## its text, and what it was when editing began
    editBar: bool             ## edited in the value box, not in its cell
    naming: bool              ## the Add field row takes a name
    newName: string
    added: seq[string]        ## fields added, kept as rows while empty
    reveal: bool              ## scroll the selected row into view
    scroll, previewScroll, detailScroll: float32
    dragId: string            ## a scroll bar's thumb being dragged
    dragFrom: (float32, float32)  ## from pointer y, scroll
    pattern*: string          ## Autofill's
    patterns*: seq[string]    ## used before, latest first
    listOpen: bool            ## their dropdown under the pattern field
    listHot: int              ## its entry picked by the arrow keys
    colWidths*: Table[string, float]  ## the preview's columns resized by hand, by field
    colDrag: string           ## the column whose edge is being dragged
    colDragFrom: (float32, float32)  ## from pointer x, width
    resizeCursor: bool        ## the pointer shows it's over a column edge
    numberFrom: float
    numberTotal*, numberPad*: bool
    status*: string
    statusError*: bool
    detailFile*: int

const
  TagSize* = ivec2(860, 640)
  RowH = 24'f32
  NameW = 210'f32
  BarW = 10'f32               ## scroll bars
  AddKey = "\0add"
  DefaultPattern* = "%tracknumber% - %title%"
  Standard = [("Title", "TITLE"), ("Artist", "ARTIST"), ("Album", "ALBUM"),
    ("Album Artist", "ALBUMARTIST"), ("Date", "DATE"), ("Genre", "GENRE"),
    ("Track Number", "TRACKNUMBER"), ("Total Tracks", "TRACKTOTAL"),
    ("Disc Number", "DISCNUMBER"), ("Total Discs", "DISCTOTAL"),
    ("Composer", "COMPOSER"), ("Comment", "COMMENT")]
  # Formats whose fields are free-form (Vorbis comments, APE): totals get
  # fields of their own. The others (ID3v2, MP4, ASF...) write "3/12".
  SeparateTotals = [".flac", ".ogg", ".oga", ".opus", ".spx", ".ape", ".wv",
    ".mpc", ".tta", ".ofr", ".ofs"]
  NoSplit = ["COMMENT", "LYRICS", "UNSYNCEDLYRICS", "DESCRIPTION"]
  # Autofill's names for fields, besides the fields' own.
  FieldAliases = {"track": "TRACKNUMBER", "totaltracks": "TRACKTOTAL",
    "tracks": "TRACKTOTAL", "disc": "DISCNUMBER", "totaldiscs": "DISCTOTAL",
    "discs": "DISCTOTAL", "year": "DATE", "album artist": "ALBUMARTIST",
    "album_artist": "ALBUMARTIST", "band": "ALBUMARTIST"}.toTable
  # ffprobe's names for the fields of files TagLib can't open.
  ProbeNames = {"ALBUM_ARTIST": "ALBUMARTIST", "TRACK": "TRACKNUMBER",
    "DISC": "DISCNUMBER", "YEAR": "DATE"}.toTable

proc isStandard(key: string): bool = Standard.anyIt(it[1] == key)

# --- reading and writing -------------------------------------------------------

proc normalize(e: var TagEntry, t: Tags): Tags =
  ## Track and disc totals in fields of their own, whichever way the file keeps them.
  result = t
  e.combine = e.path.splitFile.ext.toLowerAscii notin SeparateTotals
  e.trackTotalKey = "TRACKTOTAL"
  e.discTotalKey = "DISCTOTAL"
  for (num, total, alias) in [("TRACKNUMBER", "TRACKTOTAL", "TOTALTRACKS"),
                              ("DISCNUMBER", "DISCTOTAL", "TOTALDISCS")]:
    if alias in result and total notin result:
      result[total] = result[alias]
      result.del alias
      if num == "TRACKNUMBER": e.trackTotalKey = alias else: e.discTotalKey = alias
    let n = result.getOrDefault(num)
    if n.len > 0 and '/' in n[0]:
      let parts = n[0].split('/', 1)
      if parts[0].strip.len > 0: result[num] = @[parts[0].strip]
      else: result.del num
      if parts[1].strip.len > 0 and total notin result: result[total] = @[parts[1].strip]
      e.combine = true

proc denormalize(e: TagEntry): Tags =
  ## The edited fields as the file keeps them.
  result = e.tags
  for (num, total, key) in [("TRACKNUMBER", "TRACKTOTAL", e.trackTotalKey),
                            ("DISCNUMBER", "DISCTOTAL", e.discTotalKey)]:
    let tot = result.getOrDefault(total)
    if e.combine:
      result.del total
      let n = result.getOrDefault(num)
      if tot.len > 0 and n.len > 0: result[num] = @[n[0] & "/" & tot[0]]
    elif key != total and tot.len > 0:
      result.del total
      result[key] = tot

proc midiTexts(path: string): seq[DetailSection]  # below

proc extOf(path: string): string = path.splitFile.ext.toLowerAscii.strip(chars = {'.'})

proc isTracker*(path: string): bool = path.extOf in TrackerExtensions
proc isMidi(path: string): bool = path.extOf in MidiExtensions

proc readEntry(path: string): TagEntry =
  ## Tracker modules are read with TagLib but never written: saving one, it
  ## rewrites the samples' and instruments' names (where trackers' authors
  ## leave their messages), losing their non-ASCII characters.
  result.path = path
  var t: Tags
  if path.isMidi:
    # Its text events; ffprobe would read it as a module, with made-up fields.
    const fields = {"Title": "TITLE", "Artist": "ARTIST", "Copyright": "COPYRIGHT",
      "Comment": "COMMENT", "Date": "DATE", "Genre": "GENRE", "Text": "TEXT",
      "Marker": "MARKER", "Cue point": "CUEPOINT"}.toTable
    for s in midiTexts(path):
      for (k, v) in s.rows:
        let key = if k.startsWith("Lyrics"): "LYRICS" else: fields.getOrDefault(k)
        if key.len > 0: t.mgetOrPut(key, @[]).add v
  else:
    let r = readTags(path)
    if r.ok:
      result.editable = not path.isTracker
      t = r.tags
    else:
      for (k, v) in fileTags(path):
        t.mgetOrPut(ProbeNames.getOrDefault(k, k), @[]).add v
  result.tags = result.normalize(t)
  result.orig = result.tags

proc changed*(e: TagEntry): bool = e.editable and e.tags != e.orig

proc dirty*(d: TagDialog): bool = d.files.anyIt(it.changed)

proc saveFile*(d: TagDialog, i: int): tuple[ok: bool, msg: string] =
  ## Writes file i's edited fields, and reads them back as now kept.
  let e = d.files[i].addr
  if not e[].changed: return (true, "")
  let r = writeTags(e.path, e[].denormalize)
  if not r.ok: return (false, r.error)
  let back = readTags(e.path)
  if back.ok:
    var fresh = TagEntry(path: e.path, editable: true)
    fresh.tags = fresh.normalize(back.tags)
    fresh.orig = fresh.tags
    (fresh.details, fresh.detailsRead) = (e.details, false)
    e[] = fresh
  if r.dropped.len > 0:
    return (true, "this format can't keep " & r.dropped.join(", "))
  (true, "")

proc newTagDialog*(paths: seq[string], pattern: string, patterns: seq[string],
                   numberTotal, numberPad: bool): TagDialog =
  result = TagDialog(pattern: (if pattern.len > 0: pattern else: DefaultPattern),
    patterns: patterns, numberFrom: 1, numberTotal: numberTotal, numberPad: numberPad,
    sel: "TITLE")
  for p in paths: result.files.add readEntry(p)

proc editableCount(d: TagDialog): int = d.files.countIt(it.editable)

# --- values --------------------------------------------------------------------

proc joinValues(vs: seq[string]): string = vs.join("; ")

proc parseValues(key, s: string): seq[string] =
  ## A cell's text as the field's values: "a; b" is two, except in free text.
  if s.strip.len == 0: return
  if key in NoSplit or '\n' in s: return @[s]
  for v in s.split("; "):
    if v.strip.len > 0: result.add v.strip

proc cell(d: TagDialog, key: string): tuple[text: string, mixed: bool] =
  ## The field's value, or mixed when the files don't agree on it: the files
  ## edits go to, when there are any.
  var first = true
  let some = d.files.anyIt(it.editable)
  for e in d.files:
    if some and not e.editable: continue
    let v = e.tags.getOrDefault(key).joinValues
    if first: (result.text, first) = (v, false)
    elif v != result.text: return ("", true)

proc setField*(d: TagDialog, key, text: string) =
  ## Gives every file that can be written the field's new value ("" removes it).
  let vs = parseValues(key, text)
  for e in d.files.mitems:
    if not e.editable: continue
    if vs.len == 0: e.tags.del key
    else: e.tags[key] = vs

proc gridRows(d: TagDialog): seq[GridRow] =
  for (label, key) in Standard:
    result.add GridRow(kind: rkField, key: key, label: label, standard: true)
  var others: seq[string]
  for e in d.files:
    for k in e.tags.keys:
      if not k.isStandard and k notin others: others.add k
  for k in d.added:
    if k notin others: others.add k
  others.sort()
  result.add GridRow(kind: rkHeader, label: "Other fields")
  for k in others: result.add GridRow(kind: rkField, key: k, label: k)
  if d.editableCount > 0: result.add GridRow(kind: rkAdd, key: AddKey, label: "Add field...")

proc oneLine(s: string): string =
  ## A value for its cell: line breaks shown as dots.
  s.multiReplace(("\r\n", " · "), ("\n", " · "), ("\r", " · "), ("\t", " "))

# --- Autofill ------------------------------------------------------------------

type Token = tuple[lit: string, field: string]  ## a literal, or a %field%

proc tokens(pattern: string): seq[Token] =
  var i = 0
  var lit = ""
  while i < pattern.len:
    if pattern[i] == '%':
      let j = pattern.find('%', i + 1)
      if j < 0:
        lit.add pattern[i ..^ 1]
        break
      if j == i + 1: lit.add '%'  # %% is a percent sign
      else:
        if lit.len > 0: result.add (lit, "")
        lit = ""
        result.add ("", pattern[i + 1 ..< j].toLowerAscii)
      i = j + 1
    else:
      lit.add pattern[i]
      inc i
  if lit.len > 0: result.add (lit, "")

proc fieldKey(name: string): string =
  ## A pattern's field name as a tag field; "" for text to skip.
  if name in ["_", "skip", "ignore"]: return ""
  if name in FieldAliases: return FieldAliases[name]
  name.toUpperAscii.replace(' ', '_')

proc matchName(toks: seq[Token], s: string): seq[(string, string)] =
  ## The fields a name holds by the pattern (field key, value), each at least
  ## one character long and as short as the rest allows; @[] when it doesn't
  ## fit. Text ending the pattern ends what's read: the name goes on past it
  ## unread ("%title% Original" reads "Song" from "Song Original Mix").
  var caps: seq[(string, string)]
  proc go(i, pos: int): bool =
    if i == toks.len: return pos == s.len
    let t = toks[i]
    if t.field.len == 0:
      if i == toks.high: return s.continuesWith(t.lit, pos)
      return s.continuesWith(t.lit, pos) and go(i + 1, pos + t.lit.len)
    let last = i == toks.high
    let lo = if last: s.len else: pos + 1
    for e in lo .. s.len:
      if e <= pos: continue
      caps.add (fieldKey(t.field), s[pos ..< e])
      if go(i + 1, e): return true
      caps.setLen caps.len - 1
  if toks.len > 0 and go(0, 0):
    for (k, v) in caps:
      if k.len > 0: result.add (k, v.strip)
    if result.len == 0: result.add ("", "")  # matched, nothing to keep

proc subject(path, pattern: string): string =
  ## What a pattern is matched against: the file's name without its
  ## extension, with as many of its folders as the pattern has slashes.
  let p = path.replace('\\', '/')
  let parts = p.split('/')
  let depth = pattern.count('/') + pattern.count('\\')
  var tail = parts[max(0, parts.len - 1 - depth) .. ^1]
  tail[^1] = tail[^1].splitFile.name
  tail.join("/")

proc autofill(d: TagDialog, e: TagEntry): seq[(string, string)] =
  let pat = d.pattern.replace('\\', '/')
  matchName(tokens(pat), subject(e.path, pat))

proc patternFields(d: TagDialog): seq[string] =
  for t in tokens(d.pattern):
    if t.field.len > 0 and fieldKey(t.field).len > 0 and fieldKey(t.field) notin result:
      result.add fieldKey(t.field)

proc fill*(d: TagDialog): int =
  ## Fills the fields of every file the pattern fits; how many it fit.
  for e in d.files.mitems:
    if not e.editable: continue
    let caps = d.autofill(e)
    if caps.len == 0: continue
    inc result
    for (k, v) in caps:
      if k.len > 0 and v.len > 0: e.tags[k] = @[v]

proc number*(d: TagDialog): int =
  ## Numbers the files that can be written top to bottom; how many.
  let n = d.editableCount
  let last = int(d.numberFrom) + n - 1
  let width = if d.numberPad: max(2, ($last).len) else: 1
  var i = 0
  for e in d.files.mitems:
    if not e.editable: continue
    e.tags["TRACKNUMBER"] = @[align($(int(d.numberFrom) + i), width, '0')]
    if d.numberTotal: e.tags["TRACKTOTAL"] = @[$last]
    inc i
  n

# --- Details -------------------------------------------------------------------

proc vlq(d: string, q: var int, stop: int): int =
  for _ in 0 .. 3:
    if q >= stop: return
    let b = d[q].ord
    inc q
    result = (result shl 7) or (b and 0x7f)
    if b < 0x80: return

proc midiTexts(path: string): seq[DetailSection] =
  ## A MIDI file's text events (copyright, track names, lyrics, markers...)
  ## and a RIFF MIDI file's INFO fields.
  var d: string
  try: d = readFile(path)
  except IOError, OSError: return
  proc be(p, n: int): int =
    for k in 0 ..< n: result = (result shl 8) or d[p + k].ord
  proc le32(p: int): int = d[p].ord or (d[p + 1].ord shl 8) or (d[p + 2].ord shl 16) or (d[p + 3].ord shl 24)
  var rows: seq[(string, string)]
  var p = 0
  if d.len >= 12 and d[0 ..< 4] == "RIFF" and d[8 ..< 12] == "RMID":
    const infoNames = {"INAM": "Title", "IART": "Artist", "ICOP": "Copyright",
      "ICMT": "Comment", "ICRD": "Date", "IGNR": "Genre", "ISFT": "Software",
      "IENG": "Engineer", "ISBJ": "Subject", "IKEY": "Keywords"}.toTable
    var q = 12
    var smf = -1
    while q + 8 <= d.len:
      let id = d[q ..< q + 4]
      let size = le32(q + 4)
      if id == "data": smf = q + 8
      elif id == "LIST" and q + 12 <= d.len and d[q + 8 ..< q + 12] == "INFO":
        var r = q + 12
        while r + 8 <= min(d.len, q + 8 + size):
          let sid = d[r ..< r + 4]
          let n = le32(r + 4)
          if r + 8 + n > d.len: break
          let v = d[r + 8 ..< r + 8 + n].strip(chars = {'\0', ' '})
          if v.len > 0: rows.add (infoNames.getOrDefault(sid, sid), v)
          r += 8 + n + (n and 1)
      q += 8 + size + (size and 1)
    if smf < 0: return
    p = smf
  if p + 14 > d.len or d[p ..< p + 4] != "MThd": return
  p += 8 + be(p + 4, 4)
  const metaNames = [1: "Text", 2: "Copyright", 3: "Track name", 4: "Instrument",
                     5: "Lyrics", 6: "Marker", 7: "Cue point"]
  var track = 0
  while p + 8 <= d.len:
    let size = be(p + 4, 4)
    let stop = min(d.len, p + 8 + size)
    if d[p ..< p + 4] != "MTrk":
      p = stop
      continue
    inc track
    var q = p + 8
    var status = 0
    var lyrics = ""
    while q < stop:
      discard vlq(d, q, stop)
      if q >= stop: break
      var b = d[q].ord
      if b >= 0x80:
        inc q
        if b < 0xF0: status = b
      elif status == 0: break
      else: b = status  # running status: b is the first data byte
      if b == 0xFF:
        if q >= stop: break
        let kind = d[q].ord
        inc q
        let n = vlq(d, q, stop)
        if q + n > stop: break
        let text = d[q ..< q + n]
        q += n
        if kind == 0x2F: break
        if kind in 1 .. 7:
          if kind == 5: lyrics.add text
          elif text.strip.len > 0:
            let label = if kind in [3, 4]: &"{metaNames[kind]} ({track})" else: metaNames[kind]
            rows.add (label, text.strip)
      elif b in [0xF0, 0xF7]:
        let n = vlq(d, q, stop)
        q += n
      else:  # a channel message: q is at its data, whether its status was there or not
        q += (if (b and 0xF0) in [0xC0, 0xD0]: 1 else: 2)
    if lyrics.strip.len > 0:
      rows.add (&"Lyrics ({track})", lyrics.multiReplace(("\r\n", "\n"), ("\r", "\n"), ("/", "\n"), ("\\", "\n\n")).strip)
    p = stop
  if rows.len > 0: result.add ("MIDI texts", rows)

proc loadDetails(e: var TagEntry) =
  if e.detailsRead: return
  e.detailsRead = true
  e.details.setLen 0
  if e.path.isMidi:
    var size = -1'i64
    try: size = getFileSize(e.path)
    except OSError: discard
    e.details.add ("General", @[("Complete name", e.path), ("Format", "MIDI"),
      ("File size", if size >= 0: fmtBytes(size.float) else: "")].filterIt(it[1].len > 0))
    e.details.add midiTexts(e.path)
  else:
    for s in fileSections(e.path): e.details.add (s.title, s.rows)
    if e.path.isTracker: e.details.add moduleDetails(e.path)
  if e.details.len == 0: e.details.add ("General", @[("Complete name", e.path),
    ("", "ffprobe couldn't read this file")])

proc detailsText(e: TagEntry): string =
  for i, s in e.details:
    if i > 0: result.add "\n"
    result.add s.title & "\n"
    for (k, v) in s.rows:
      result.add (if k.len > 0: k.alignLeft(41) & ": " else: "") & v & "\n"

# --- drawing -------------------------------------------------------------------

proc scrollBar(d: TagDialog, ui: Ui, id: string, r: Rect, scroll: var float32, content: float32) =
  ## A thin bar at r's right edge when content is taller than r: drag its thumb.
  let maxScroll = max(0'f32, content - r.h)
  scroll = clamp(scroll, 0, maxScroll)
  if maxScroll <= 0: return
  let track = rect(r.x + r.w - BarW + 2, r.y + 2, BarW - 4, r.h - 4)
  let th = max(20'f32, track.h * r.h / content)
  let span = track.h - th
  let thumb = rect(track.x, track.y + span * scroll / maxScroll, track.w, th)
  let hov = ui.hover(rect(track.x - 2, track.y, track.w + 4, track.h))
  if hov and ui.pressed():
    ui.consumeClick()
    if not ui.mouse.inside(thumb):
      scroll = clamp((ui.mouse.y - track.y - th / 2) / span * maxScroll, 0, maxScroll)
    d.dragId = id
    d.dragFrom = (ui.mouse.y, scroll)
  if d.dragId == id:
    if ui.down() and span > 0:
      scroll = clamp(d.dragFrom[1] + (ui.mouse.y - d.dragFrom[0]) / span * maxScroll, 0, maxScroll)
    else: d.dragId = ""
  ui.rect(rect(track.x, track.y + span * scroll / maxScroll, track.w, th),
    if d.dragId == id or hov: colTextDim else: colTrack)

proc gridHead(ui: Ui, r: Rect, cols: seq[(string, float32)]) =
  ## A grid's header row: its columns' titles at their x, ruled between.
  ui.rect(r, colPanelRaised)
  ui.border(r, colBorder)
  for i, (title, x) in cols:
    let right = if i < cols.high: cols[i + 1][1] else: r.x + r.w
    if i > 0: ui.rect(rect(x, r.y, 1, r.h), colBorder)
    ui.textIn(ui.ellipsize(title, right - x - 14, FontSmall), rect(x + 8, r.y, right - x - 14, r.h),
      colTextDim, FontSmall)

proc commitEdit(d: TagDialog, keep = true) =
  ## Ends editing a field, its value kept (unless not) when it changed.
  if d.editKey.len == 0: return
  if keep and d.edit != d.editStart: d.setField(d.editKey, d.edit)
  d.editKey = ""
  d.editBar = false

proc startEdit(d: TagDialog, ui: Ui, key: string, typed = "", replace = false) =
  ## Edits the field in its cell, its text selected; when typing over it,
  ## with what was typed instead.
  d.commitEdit()
  let (text, mixed) = d.cell(key)
  d.editKey = key
  d.editStart = if mixed: "" else: text
  d.editBar = false
  if replace:
    d.edit = ""
    for ch in typed:
      if ch.ord >= 0x20 and ch.ord != 0x7f: d.edit.add ch
    ui.focusId = "tg-cell"
    ui.focusFresh = false
    (ui.caret, ui.selAnchor, ui.fieldScroll) = (d.edit.len, d.edit.len, 0'f32)
    return
  d.edit = d.editStart
  if '\n' in d.edit:
    d.editBar = true  # line breaks: in the value box
    ui.focusId = "tg-bar"
  else:
    ui.focusId = "tg-cell"
  ui.focusFresh = true

proc moveSel(d: TagDialog, rows: seq[GridRow], step: int) =
  let pick = rows.filterIt(it.kind != rkHeader)
  var i = 0
  for k, r in pick:
    if r.key == d.sel: i = k
  d.sel = pick[clamp(i + step, 0, pick.high)].key
  d.reveal = true

proc printable(s: string): bool =
  for ch in s:
    if ch.ord >= 0x20 and ch.ord != 0x7f: return true

proc drawMetadata(d: TagDialog, ui: Ui, r: Rect) =
  let w = ui.window
  let rows = d.gridRows
  if not rows.anyIt(it.kind != rkHeader and it.key == d.sel): d.sel = "TITLE"
  let canEdit = d.editableCount > 0
  let barH = 92'f32
  let grid = rect(r.x, r.y, r.w, r.h - barH - 8)
  ui.gridHead(rect(grid.x, grid.y, grid.w, RowH), @[("Name", grid.x), ("Value", grid.x + NameW)])
  let body = rect(grid.x, grid.y + RowH - 1, grid.w, grid.h - RowH + 1)
  ui.rect(body, colBackground)
  let content = rows.len.float32 * RowH
  let inner = rect(body.x + 1, body.y + 1, body.w - 2, body.h - 2)
  if ui.hover(body) and ui.scroll() != 0:
    d.scroll += ui.wheelNotches * RowH * 3
    ui.scrollConsumed = true
  if d.reveal:
    d.reveal = false
    for i, row in rows:
      if row.key == d.sel:
        let y = i.float32 * RowH
        if y < d.scroll: d.scroll = y
        if y + RowH > d.scroll + inner.h: d.scroll = y + RowH - inner.h
  d.scrollBar(ui, "tg-grid", inner, d.scroll, content)
  let keysFree = ui.focusId.len == 0 and not d.naming
  let outerClip = ui.hitClip
  ui.hitClip = inner
  ui.sk.pushClipRect(inner)
  let rowW = inner.w - (if content > inner.h: BarW else: 0)
  for i, row in rows:
    let y = inner.y + i.float32 * RowH - d.scroll
    if y + RowH < inner.y or y > inner.y + inner.h: continue
    let rr = rect(inner.x, y, rowW, RowH)
    let nameR = rect(rr.x, y, NameW - 1, RowH)
    let valR = rect(rr.x + NameW, y, rr.w - NameW, RowH)
    if row.kind == rkHeader:
      ui.rect(rr, colPanel)
      ui.textIn(row.label, rect(rr.x + 8, y, rr.w - 16, RowH), colTextDim, FontSmall)
      ui.rect(rect(rr.x, y + RowH - 1, rr.w, 1), colBorder)
      continue
    let selected = row.key == d.sel
    let hov = ui.hover(rr)
    ui.rect(rect(rr.x, y + RowH - 1, rr.w, 1), colBorder)
    ui.rect(rect(rr.x + NameW - 1, y, 1, RowH), colBorder)
    if selected: ui.rect(rect(nameR.x, nameR.y, nameR.w, nameR.h - 1), colPressed)
    elif hov: ui.rect(rect(nameR.x, nameR.y, nameR.w, nameR.h - 1), colHover)
    if row.kind == rkAdd:
      if d.naming:
        let res = ui.textField("tg-new", rect(nameR.x + 1, y + 1, nameR.w - 2, RowH - 2), d.newName,
          placeholder = "FIELD NAME")
        if eeCommitted in res:
          d.naming = false
          let key = d.newName.strip.toUpperAscii.replace(' ', '_')
          d.newName = ""
          if key.len > 0 and not w.buttonPressed[KeyEscape]:
            if key notin d.added: d.added.add key
            d.sel = key
            d.reveal = true
            d.startEdit(ui, key)
      else:
        ui.icon("plus16", vec2(nameR.x + 14, y + RowH / 2), colTextDim)
        ui.textIn(row.label, rect(nameR.x + 26, y, nameR.w - 30, RowH), colTextDim)
      if hov and ui.pressed():
        ui.consumeClick()
        d.commitEdit()
        d.sel = AddKey
        d.naming = true
        d.newName = ""
        ui.focusId = "tg-new"
        ui.focusFresh = true
      continue
    ui.textIn(ui.ellipsize(row.label, nameR.w - 16), rect(nameR.x + 8, y, nameR.w - 16, RowH),
      if row.standard: colText else: colTextDim)
    let editingHere = d.editKey == row.key and not d.editBar
    if editingHere:
      let res = ui.textField("tg-cell", rect(valR.x, y, valR.w, RowH - 1), d.edit)
      if eeCommitted in res:
        let esc = w.buttonPressed[KeyEscape]
        d.commitEdit(keep = not esc)
        if not esc and (w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter] or
                        w.buttonPressed[KeyTab]):
          d.moveSel(rows, if w.shiftDown: -1 else: 1)
    else:
      let (text, mixed) = d.cell(row.key)
      let tr = rect(valR.x + 8, y, valR.w - 16 - (if row.standard: 0'f32 else: 24), RowH)
      if mixed: ui.textIn("<multiple values>", tr, colTextDim)
      else: ui.textIn(ui.ellipsize(text.oneLine, tr.w), tr, colText)
      if selected:
        ui.border(rect(valR.x, y, valR.w, RowH - 1), if canEdit: colAccent else: colTextDim, 2)
      # Other fields can be removed from every file.
      if not row.standard and canEdit and (hov or selected):
        let xr = rect(valR.x + valR.w - 24, y + 2, 20, RowH - 5)
        if ui.iconButton("tg-del-" & row.key, xr, "close16", "Remove this field"):
          d.setField(row.key, "")
          d.added.keepItIf(it != row.key)
          continue
    if hov and ui.pressed() and not editingHere:
      ui.consumeClick()
      let again = selected and ui.mouse.inside(valR)
      let clicks = ui.countClick("tg-row-" & row.key)
      d.commitEdit()
      d.naming = false
      d.sel = row.key
      if canEdit and (again or clicks >= 2): d.startEdit(ui, row.key)
  ui.sk.popClipRect()
  ui.hitClip = outerClip
  ui.border(body, colBorder)

  # Keys, while nothing is edited: move, edit, clear, copy or paste.
  let ctrl = w.buttonDown[KeyLeftControl] or w.buttonDown[KeyRightControl]
  if keysFree and d.editKey.len == 0:
    let page = max(1, int(inner.h / RowH) - 1)
    if w.buttonPressed[KeyDown]: d.moveSel(rows, 1)
    elif w.buttonPressed[KeyUp]: d.moveSel(rows, -1)
    elif w.buttonPressed[KeyPageDown]: d.moveSel(rows, page)
    elif w.buttonPressed[KeyPageUp]: d.moveSel(rows, -page)
    elif w.buttonPressed[KeyHome] and ctrl: d.moveSel(rows, -rows.len)
    elif w.buttonPressed[KeyEnd] and ctrl: d.moveSel(rows, rows.len)
    elif w.buttonPressed[KeyTab]: d.moveSel(rows, if w.shiftDown: -1 else: 1)
    elif d.sel == AddKey:
      if w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter] or w.buttonPressed[KeyF2]:
        d.naming = true
        ui.focusId = "tg-new"
        ui.focusFresh = true
    elif canEdit:
      if w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter] or w.buttonPressed[KeyF2]:
        d.startEdit(ui, d.sel)
      elif w.buttonPressed[KeyDelete] or w.buttonPressed[KeyBackspace]:
        d.setField(d.sel, "")
      elif ctrl and w.buttonPressed[KeyC]:
        let (text, mixed) = d.cell(d.sel)
        if not mixed: setClipboardString(text)
      elif ctrl and w.buttonPressed[KeyV]:
        d.setField(d.sel, getClipboardString())
      elif not ctrl and ui.typed.printable:
        d.startEdit(ui, d.sel, ui.typed, replace = true)
    elif ctrl and w.buttonPressed[KeyC]:
      let (text, mixed) = d.cell(d.sel)
      if not mixed: setClipboardString(text)

  # The value box: the whole of the selected value, edited with line breaks.
  let barR = rect(r.x, grid.y + grid.h + 8, r.w, barH)
  let row = rows.filterIt(it.key == d.sel)
  let label = if row.len > 0 and row[0].kind == rkField: row[0].label else: ""
  if label.len > 0 and canEdit:
    if d.editKey == d.sel and d.editBar:
      if eeCommitted in ui.textArea("tg-bar", barR, d.edit): d.commitEdit()
    else:
      let (text, mixed) = d.cell(d.sel)
      var tmp = text
      let res = ui.textArea("tg-bar", barR, tmp,
        placeholder = if mixed: "<multiple values>" else: label & ": empty")
      if res * {eeFocused, eeChanged} != {}:
        d.commitEdit()
        (d.editKey, d.editBar, d.editStart, d.edit) = (d.sel, true, (if mixed: "" else: text), tmp)
        ui.focusId = "tg-bar"
  else:
    ui.rect(barR, colPanel)
    ui.border(barR, colBorder)
    if label.len > 0:
      let (text, mixed) = d.cell(d.sel)
      var y = barR.y + 4
      for line in (if mixed: @["<multiple values>"] else: text.splitLines):
        if y + 20 > barR.y + barR.h: break
        ui.textIn(ui.ellipsize(line, barR.w - 14), rect(barR.x + 7, y, barR.w - 14, 20), colTextDim)
        y += 20

const
  FileCol = "filename"  ## the preview's File name column, among its widths (fields are upper case)
  MinCol = 60'f32
  EntryH = 26'f32      ## the patterns dropdown's entries

type PreviewCol = tuple[key, label: string, x, w: float32]

proc previewCols(d: TagDialog, r: Rect, fields: seq[string]): seq[PreviewCol] =
  ## File name, then the pattern's fields, each as wide as resized (else
  ## sharing what's left); the last fills the rest, each keeping MinCol.
  let keys = @[FileCol] & fields
  let fileW = d.colWidths.getOrDefault(FileCol, 260)
  let share = if fields.len > 0: (r.w - fileW) / fields.len.float32 else: 0
  var x = r.x
  for i, k in keys:
    var label = if k == FileCol: "File name" else: k
    for (l, sk) in Standard:
      if sk == k: label = l
    var w = d.colWidths.getOrDefault(k, (if k == FileCol: fileW else: share)).float32
    if i == keys.high: w = max(MinCol, r.x + r.w - x)
    else: w = clamp(w, MinCol, max(MinCol, r.x + r.w - x - MinCol * float32(keys.high - i)))
    result.add (k, label, x, w)
    x += w

proc previewText(d: TagDialog, e: TagEntry, key: string): string =
  ## What the preview shows in a file's cell; "" where it shows a note.
  if key == FileCol: return subject(e.path, d.pattern.replace('\\', '/'))
  if not e.editable: return
  for (ck, cv) in d.autofill(e):
    if ck == key: return cv

proc forgetPattern(d: TagDialog, i: int) =
  d.patterns.delete i
  d.listHot = clamp(d.listHot, 0, max(0, d.patterns.high))
  if d.patterns.len == 0: d.listOpen = false

proc drawAutofill(d: TagDialog, ui: Ui, r: Rect): TagAction =
  let w = ui.window
  let canEdit = d.editableCount > 0
  var y = r.y
  ui.groupHeader(vec2(r.x, y), r.w, "Autofill tag fields from file names")
  y += 28
  ui.textIn("Pattern", rect(r.x, y, 70, 28), colText)
  let combo = rect(r.x + 70, y, r.w - 70 - 100, 28)  # the field and its dropdown button
  let dropR = rect(combo.x + combo.w - 28, y, 28, 28)
  let lr = rect(combo.x, combo.y + combo.h + 2, combo.w,
    min(d.patterns.len, 8).float32 * EntryH + 2)
  # The open list takes the pointer and the arrow keys; a press elsewhere
  # (or Escape) closes it.
  if d.listOpen:
    if w.buttonPressed[KeyEscape]: d.listOpen = false
    elif ui.pressed() and not ui.mouse.inside(lr) and not ui.mouse.inside(dropR):
      d.listOpen = false
    elif ui.mouse.inside(lr): ui.captured = true
  let open = d.listOpen
  discard ui.textField("tg-pattern", rect(combo.x, y, combo.w - 27, 28), d.pattern,
    placeholder = DefaultPattern)
  let has = d.patterns.len > 0
  let dhov = has and ui.hover(dropR)
  if dhov and ui.pressed():
    ui.consumeClick()
    d.listOpen = not open
    d.listHot = max(0, d.patterns.find(d.pattern))
  ui.rect(dropR, if open: colPressed elif dhov: colHover else: colPanelRaised)
  ui.border(dropR, if open: colAccent else: colBorder)
  ui.icon("expand16", dropR.xy + dropR.wh / 2, if not has: colTextDisabled elif dhov: colText else: colTextDim)
  ui.tip(dropR, if has: "Patterns used before" else: "No patterns used yet")
  if has and not open and ui.focusId == "tg-pattern" and w.buttonPressed[KeyDown]:
    d.listOpen = true
    d.listHot = max(0, d.patterns.find(d.pattern))
  let fields = d.patternFields
  var fits = 0
  for e in d.files:
    if e.editable and d.autofill(e).len > 0: inc fits
  let fillR = rect(r.x + r.w - 92, y, 92, 28)
  if canEdit and fits > 0:
    if ui.textButton("tg-fill", fillR, "Fill", primary = true):
      let n = d.fill()
      d.status = &"Filled the fields of {n} of {d.editableCount} files: OK or Apply writes them"
      d.statusError = false
      result = taPattern
  else:
    ui.rect(fillR, colPanel)
    ui.border(fillR, colBorder)
    ui.textIn("Fill", fillR, colTextDisabled, h = CenterAlign)
  y += 34
  for line in ["Name fields between percent signs: %title%, %artist%, %album%, %albumartist%, %date%,",
               "%genre%, %tracknumber%, %totaltracks%, %discnumber%, or any other. %_% skips text;",
               "each / reaches up a folder, as in %artist%/%album%/%tracknumber% %title%. Text at",
               "the end stops reading there: in %title% Original, what follows Original is left out."]:
    ui.textIn(line, rect(r.x + 70, y, r.w - 70, 17), colTextDim, FontSmall)
    y += 17
  y += 10

  # What the pattern finds in each name, in columns resized by their edges.
  let previewH = r.y + r.h - y - 150
  let head = rect(r.x, y, r.w, RowH)
  let cols = d.previewCols(head, fields)
  ui.gridHead(head, cols.mapIt((it.label, it.x)))
  var overEdge = false
  for i, c in cols:
    if i == cols.high: break
    let edge = rect(c.x + c.w - 4, head.y, 8, head.h)
    let hov = ui.hover(edge)
    if hov: overEdge = true
    if hov and ui.pressed():
      ui.consumeClick()
      if ui.countClick("tg-edge-" & c.key) >= 2:
        # Fit it to its title and cells.
        var fit = ui.textSize(c.label, FontSmall).x + 22
        for e in d.files:
          fit = max(fit, ui.textSize(d.previewText(e, c.key)).x + 22)
        d.colWidths[c.key] = max(MinCol, fit)
        result = taPrefs
      else:
        d.colDrag = c.key
        d.colDragFrom = (ui.mouse.x, c.w)
  if d.colDrag.len > 0:
    overEdge = true
    if ui.down():
      d.colWidths[d.colDrag] = max(MinCol, d.colDragFrom[1] + ui.mouse.x - d.colDragFrom[0]).float
    else:
      d.colDrag = ""
      result = taPrefs
  if overEdge != d.resizeCursor:
    d.resizeCursor = overEdge
    w.cursor = Cursor(kind: if overEdge: ResizeLeftRightCursor else: ArrowCursor)
  let body = rect(r.x, y + RowH - 1, r.w, previewH - RowH + 1)
  ui.rect(body, colBackground)
  let inner = rect(body.x + 1, body.y + 1, body.w - 2, body.h - 2)
  let content = d.files.len.float32 * RowH
  if ui.hover(body) and ui.scroll() != 0:
    d.previewScroll += ui.wheelNotches * RowH * 3
    ui.scrollConsumed = true
  d.scrollBar(ui, "tg-preview", inner, d.previewScroll, content)
  ui.sk.pushClipRect(inner)
  let rest = if cols.len > 1: cols[1].x else: inner.x + inner.w  # where notes go
  for i, e in d.files:
    let ry = inner.y + i.float32 * RowH - d.previewScroll
    if ry + RowH < inner.y or ry > inner.y + inner.h: continue
    ui.rect(rect(inner.x, ry + RowH - 1, inner.w, 1), colBorder)
    let fw = cols[0].w - 16
    ui.textIn(ui.ellipsize(d.previewText(e, FileCol), fw), rect(inner.x + 8, ry, fw, RowH),
      if e.editable: colText else: colTextDisabled)
    let note =
      if not e.editable: "can't be tagged"
      elif d.autofill(e).len == 0: "doesn't fit the pattern"
      else: ""
    if cols.len > 1: ui.rect(rect(rest, ry, 1, RowH), colBorder)
    if note.len > 0:
      ui.textIn(note, rect(rest + 8, ry, inner.x + inner.w - rest - 16, RowH),
        if e.editable: colError else: colTextDisabled)
      continue
    for k, c in cols:
      if k == 0: continue
      if k > 1: ui.rect(rect(c.x, ry, 1, RowH), colBorder)
      let cw = min(c.w, inner.x + inner.w - c.x) - 16
      ui.textIn(ui.ellipsize(d.previewText(e, c.key), cw), rect(c.x + 8, ry, cw, RowH), colText)
  ui.sk.popClipRect()
  ui.border(body, colBorder)

  # The patterns used before, over everything; × forgets one.
  if open and d.listOpen:
    ui.captured = false
    if w.buttonPressed[KeyDown]: d.listHot = min(d.listHot + 1, d.patterns.high)
    if w.buttonPressed[KeyUp]: d.listHot = max(d.listHot - 1, 0)
    var pick = -1
    if w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter]: pick = d.listHot
    ui.sk.pushLayer(PopupsLayer)
    ui.rect(rect(lr.xy + vec2(3, 4), lr.wh), colShadow)
    ui.rect(lr, colPopup)
    ui.border(lr, colAccent)
    var forget = -1
    for i, p in d.patterns:
      if i >= 8: break
      let er = rect(lr.x + 1, lr.y + 1 + i.float32 * EntryH, lr.w - 2, EntryH)
      let xr = rect(er.x + er.w - 26, er.y + 3, 22, EntryH - 6)
      let hov = ui.hover(er)
      let cur = p == d.pattern
      if i == d.listHot or hov: ui.rect(er, if cur: colAccentHover else: colHover)
      elif cur: ui.rect(er, colAccent)
      ui.textIn(ui.ellipsize(p, er.w - 46), rect(er.x + 10, er.y, er.w - 46, EntryH),
        if cur and not (i == d.listHot or hov): colOnAccent else: colText)
      if hov:
        if ui.iconButton(&"tg-forget-{i}", xr, "close16", "Forget this pattern"): forget = i
        elif ui.pressed() and not ui.mouse.inside(xr):
          ui.consumeClick()
          pick = i
    ui.sk.popLayer()
    if forget >= 0:
      d.forgetPattern(forget)
      result = taPrefs
    elif pick in 0 ..< d.patterns.len:
      d.pattern = d.patterns[pick]
      d.listOpen = false
      ui.focusId = ""

  y = body.y + body.h + 18
  ui.groupHeader(vec2(r.x, y), r.w, "Autofill track numbers")
  y += 28
  ui.textIn(&"Numbers the {d.editableCount} files top to bottom, in playlist order.",
    rect(r.x, y, r.w, 22), colTextDim)
  y += 32
  ui.textIn("Start at", rect(r.x, y, 70, 28), colText)
  discard ui.numberField("tg-from", rect(r.x + 70, y, 120, 28), d.numberFrom, 1, 0, 9999)
  discard ui.checkbox("tg-total", vec2(r.x + 214, y + 3), "Set Total Tracks", d.numberTotal)
  discard ui.checkbox("tg-pad", vec2(r.x + 384, y + 3), "Two digits (01, 02...)", d.numberPad)
  let numR = rect(r.x + r.w - 92, y, 92, 28)
  if canEdit:
    if ui.textButton("tg-number", numR, "Number"):
      let n = d.number()
      d.status = &"Numbered {n} files: OK or Apply writes them"
      d.statusError = false
  else:
    ui.rect(numR, colPanel)
    ui.border(numR, colBorder)
    ui.textIn("Number", numR, colTextDisabled, h = CenterAlign)

proc drawDetails(d: TagDialog, ui: Ui, r: Rect) =
  var y = r.y
  d.detailFile = clamp(d.detailFile, 0, d.files.high)
  if d.files.len > 1:
    if ui.iconButton("tg-prev", rect(r.x, y, 28, 28), "arrowleft16", "Previous file",
                     enabled = d.detailFile > 0):
      dec d.detailFile
      d.detailScroll = 0
    if ui.iconButton("tg-next", rect(r.x + 30, y, 28, 28), "arrow16", "Next file",
                     enabled = d.detailFile < d.files.high):
      inc d.detailFile
      d.detailScroll = 0
  let e = d.files[d.detailFile].addr
  e[].loadDetails()
  let head = (if d.files.len > 1: &"{d.detailFile + 1} of {d.files.len}:  " else: "") &
    e.path.extractFilename
  let hx = if d.files.len > 1: r.x + 68 else: r.x
  ui.textIn(ui.ellipsize(head, r.x + r.w - 150 - hx), rect(hx, y, r.x + r.w - 150 - hx, 28), colText)
  if ui.textButton("tg-copy", rect(r.x + r.w - 140, y, 140, 28), "Copy to Clipboard"):
    setClipboardString(e[].detailsText)
    d.status = "Copied the details"
    d.statusError = false
  y += 36
  let body = rect(r.x, y, r.w, r.y + r.h - y)
  ui.rect(body, colBackground)
  let inner = rect(body.x + 1, body.y + 1, body.w - 2, body.h - 2)
  const lineH = 19'f32
  # Rows as tall as their lines.
  var content = 0'f32
  for s in e.details:
    content += RowH
    for (_, v) in s.rows: content += max(1, v.splitLines.len).float32 * lineH + 5
  if ui.hover(body) and ui.scroll() != 0:
    d.detailScroll += ui.wheelNotches * lineH * 3
    ui.scrollConsumed = true
  d.scrollBar(ui, "tg-details", inner, d.detailScroll, content)
  let rowW = inner.w - (if content > inner.h: BarW else: 0)
  ui.sk.pushClipRect(inner)
  var ry = inner.y - d.detailScroll
  for s in e.details:
    if ry + RowH >= inner.y and ry <= inner.y + inner.h:
      ui.rect(rect(inner.x, ry, rowW, RowH), colPanelRaised)
      ui.textIn(s.title, rect(inner.x + 8, ry, rowW - 16, RowH), colAccent)
      ui.rect(rect(inner.x, ry + RowH - 1, rowW, 1), colBorder)
    ry += RowH
    for (k, v) in s.rows:
      let lines = v.splitLines
      let h = max(1, lines.len).float32 * lineH + 5
      if ry + h >= inner.y and ry <= inner.y + inner.h:
        let vx = if k.len > 0: inner.x + NameW else: inner.x
        if k.len > 0:
          ui.textIn(ui.ellipsize(k, NameW - 16), rect(inner.x + 8, ry + 2, NameW - 16, lineH), colTextDim)
          ui.rect(rect(inner.x + NameW - 1, ry, 1, h), colBorder)
        var ly = ry + 2
        for line in lines:
          if ly + lineH >= inner.y and ly <= inner.y + inner.h:
            ui.textIn(ui.ellipsize(line, inner.x + rowW - vx - 16), rect(vx + 8, ly, inner.x + rowW - vx - 16, lineH), colText)
          ly += lineH
        ui.rect(rect(inner.x, ry + h - 1, rowW, 1), colBorder)
      ry += h
  ui.sk.popClipRect()
  ui.border(body, colBorder)

proc draw*(d: TagDialog, ui: Ui, r: Rect): TagAction =
  let w = ui.window
  # Escape ends editing first; only then does it close the window.
  let busy = ui.focusId.len > 0 or d.editKey.len > 0 or d.naming or d.listOpen
  # What's selected, and whether it can be written.
  let n = d.files.len
  let ro = n - d.editableCount
  let mods = d.files.countIt(it.path.isTracker)
  let title = if n == 1: d.files[0].path.extractFilename else: &"{n} files"
  ui.textIn(ui.ellipsize(title, r.w - 32, FontTitle), rect(r.x + 16, r.y + 10, r.w - 32, 28), colText, FontTitle)
  let note =
    if not tagedit.available(): "Editing tags needs TagLib (libtag_c), which wasn't found: tags are shown read-only."
    elif mods > 0 and mods == ro:
      "Tracker modules are shown read-only: saving them would garble their samples' names." &
        (if ro < n: " Edits leave them as they are." else: "")
    elif ro == n and n == 1: "TagLib can't write this kind of file: its tags are shown read-only."
    elif ro == n: "TagLib can't write these kinds of files: their tags are shown read-only."
    elif ro > 0:
      var kinds: seq[string]
      if mods > 0: kinds.add "tracker modules"
      let midis = d.files.countIt(it.path.isMidi)
      if midis > 0: kinds.add "MIDI files"
      if ro > mods + midis: kinds.add "files TagLib can't write"
      $ro & " of the files are read-only (" & kinds.join(", ") & "): edits leave them as they are."
    else: ""
  if note.len > 0: ui.textIn(note, rect(r.x + 16, r.y + 38, r.w - 32, 18), colWarning, FontSmall)
  # Tabs.
  var tx = r.x + 16
  let ty = r.y + 62
  for t in TagTab:
    let label = $t
    let tw = ui.textSize(label).x + 28
    let tr = rect(tx, ty, tw, 30)
    let hov = ui.hover(tr)
    if hov and ui.pressed():
      ui.consumeClick()
      d.commitEdit()
      d.naming = false
      ui.focusId = ""
      d.tab = t
      d.listOpen = false
    if d.tab == t:
      ui.rect(tr, colPanelRaised)
      ui.rect(rect(tr.x, tr.y + tr.h - 2, tr.w, 2), colAccent)
    elif hov: ui.rect(tr, colHover)
    ui.textIn(label, tr, if d.tab == t: colText else: colTextDim, h = CenterAlign)
    tx += tw + 2
  ui.rect(rect(r.x + 16, ty + 30, r.w - 32, 1), colBorder)
  let page = rect(r.x + 16, ty + 42, r.w - 32, r.y + r.h - 56 - (ty + 42))
  case d.tab
  of ttMetadata: d.drawMetadata(ui, page)
  of ttAutofill: result = d.drawAutofill(ui, page)
  of ttDetails: d.drawDetails(ui, page)

  # Buttons; Escape cancels when nothing is edited.
  ui.rect(rect(r.x + 1, r.y + r.h - 50, r.w - 2, 1), colBorder)
  let by = r.y + r.h - 40
  if d.status.len > 0:
    ui.textIn(ui.ellipsize(d.status, r.w - 360, FontSmall), rect(r.x + 16, by, r.w - 360, 30),
      if d.statusError: colError else: colTextDim, FontSmall)
  elif d.tab == ttMetadata and d.editableCount > 0:
    ui.textIn("Type over a value to change it; Enter or Tab goes down; Delete clears it.",
      rect(r.x + 16, by, r.w - 360, 30), colTextDim, FontSmall)
  let dirty = d.dirty or d.editKey.len > 0 and d.edit != d.editStart
  let okR = rect(r.x + r.w - 316, by, 92, 30)
  let cancelR = rect(r.x + r.w - 214, by, 92, 30)
  let applyR = rect(r.x + r.w - 112, by, 92, 30)
  if ui.textButton("tg-ok", okR, "OK", primary = true):
    d.commitEdit()
    result = taOk
  if ui.textButton("tg-cancel", cancelR, "Cancel"):
    result = taCancel
  if dirty:
    if ui.textButton("tg-apply", applyR, "Apply"):
      d.commitEdit()
      result = taApply
  else:
    ui.rect(applyR, colPanel)
    ui.border(applyR, colBorder)
    ui.textIn("Apply", applyR, colTextDisabled, h = CenterAlign)
  if not busy and w.buttonPressed[KeyEscape]:
    result = taCancel
