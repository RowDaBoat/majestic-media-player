## Commands window: composes shell commands for the Run menu out of text
## and cards. A card is a bash variable drawn as a chip inside the command
## line; it holds a value, or refers to the current media file, a timestamp
## of it or an external file. When the command runs, a file dialog asks for
## each external file, then the Run window asks for the timestamps (the
## start, the current time, the end, a loop mark, a bookmark or a chapter)
## and lets the
## values be changed. Value cards can be numbers of a rectangle (its width,
## height, x or y) that the Run window lets be drawn over the video, or a
## file path it lets be browsed for with a save dialog; a path card can have
## its folder opened, or the file played in a new player, once the command
## succeeds. A file list card holds files chosen on run, in an order the Run
## window lets be changed: a bash array, or the path of a list file.

import std/[strutils, sequtils, os, math, tables, algorithm]
import silky, vmath, bumpy, pixie
from player import naturalCmp
import ui, theme, config

type
  CmdAction* = enum
    caNone, caApply, caOk, caDelete, caCancel

  CmdDialog* = ref object
    saved*: seq[CommandLine]  ## the saved command lines, for the title list
    origTitle*: string        ## saved entry being edited, "" for a new one
    title*: string
    toks: seq[CmdPart]        ## the command line; text one character per token
    caret: int                ## token index
    caretEol: bool            ## caret drawn after the token before it (line end)
    anchor: int               ## other end of the selection (== caret: none)
    dragCaret: int            ## where the press that may start a drag put the caret
    dragFrom: Vec2            ## where that press happened, text coordinates
    selected: int             ## card token whose properties are shown, else -1
    scroll: float32           ## command line field, vertical
    refScroll: float32        ## reference list
    listOpen: bool            ## title list dropped down
    listScroll: int           ## its first row shown
    error: string             ## why the last Apply was refused
    applyRequested*: bool     ## debug scripting: press OK next frame

const
  LineH = 26'f32              ## command line row
  ChipPad = 7'f32
  FieldPad = 8'f32
  RowH = 24'f32               ## reference and title list rows
  NameStart = {'a'..'z', 'A'..'Z', '_'}
  NameChars = NameStart + {'0'..'9'}

proc validName*(s: string): bool =
  ## Bash variable names: letters, digits and underscores, no leading digit.
  s.len > 0 and s[0] in NameStart and s.allCharsInSet(NameChars)

proc chars(s: string): seq[string] =
  ## UTF-8 characters of s.
  var i = 0
  while i < s.len:
    var j = i + 1
    while j < s.len and (s[j].ord and 0xC0) == 0x80: inc j
    result.add s[i ..< j]
    i = j

proc isTimestamp*(p: CmdPart): bool =
  ## Timestamp cards; earlier versions had bookmark cards in their place.
  p.card and p.kind == ckReference and
    (p.content.startsWith("timestamp") or p.content.startsWith("bookmark"))

proc toTokens(parts: seq[CmdPart]): seq[CmdPart] =
  for p in parts:
    if p.card:
      result.add p
      # Earlier versions had bookmark cards, at first by number.
      if p.isTimestamp: result[^1].content = "timestamp"
    else:
      for ch in p.text.chars: result.add CmdPart(text: ch)

proc toParts(toks: seq[CmdPart]): seq[CmdPart] =
  for t in toks:
    if not t.card and result.len > 0 and not result[^1].card: result[^1].text.add t.text
    else: result.add t

# --- resolving cards ---------------------------------------------------------


proc isExternal(p: CmdPart): bool =
  p.card and p.kind == ckReference and p.content == "external"

proc isRect*(p: CmdPart): bool = p.card and p.kind == ckValue and p.rect > 0

proc isPath*(p: CmdPart): bool = p.card and p.kind == ckValue and p.path

proc isList*(p: CmdPart): bool =
  ## A file list card: files chosen on run, in order.
  p.card and p.kind == ckReference and p.content == "files"

proc listItems*(value: string): seq[string] =
  ## The files of a file list card's pick (one per line).
  value.split('\n').filterIt(it.len > 0)

proc listFileText*(files: seq[string], form: ListForm): string =
  ## What a file list card's list file holds: ffmpeg's concat demuxer
  ## script (paths in single quotes, a quote written '\''), or a path per
  ## line.
  if form == lfConcat:
    result = "ffconcat version 1.0\n"
    for f in files: result.add "file '" & f.replace("'", "'\\''") & "'\n"
  else:
    for f in files: result.add f & "\n"

proc digitsOnly*(s: string): string =
  for c in s:
    if c in Digits: result.add c

const MathChars = Digits + {'+', '-', '*', '/', '(', ')', '.', ' '}

proc mathOnly*(s: string): string =
  ## What a pixel field keeps while typed in: digits and basic math.
  for c in s:
    if c in MathChars: result.add c

proc mathDigits*(s: string): string =
  ## A pixel field's text once done typing: its math worked out to a whole,
  ## non-negative number.
  if s.allCharsInSet(Digits): return s
  try: $int(round(clamp(evalMath(s), 0.0, 1e9)))
  except ValueError: s.digitsOnly

proc externalCards*(parts: seq[CmdPart]): seq[string] =
  ## Names of the external-file cards, asked for with a file dialog on run,
  ## each once, in order.
  for p in parts:
    if p.isExternal and p.name notin result: result.add p.name

proc runCards*(parts: seq[CmdPart]): seq[CmdPart] =
  ## The cards the Run window asks about (values, timestamps and file
  ## lists), each name once, in order.
  for p in parts:
    if p.card and (p.kind == ckValue or p.isTimestamp or p.isList) and
       not result.anyIt(it.name == p.name):
      result.add p

proc resolve*(p: CmdPart, path: string, picks: Table[string, string]): tuple[value, err: string] =
  ## A card's value now, or why it has none. picks holds what the Run window
  ## gave each card: a timestamp's time, the chosen external file, or a
  ## value replacing the card's own.
  case p.kind
  of ckValue:
    let v = picks.getOrDefault(p.name, p.content)
    result.value = if v.startsWith("~"): v.expandTilde else: v
  of ckReference:
    if p.content == "file":
      if path.len > 0: result.value = path
      else: result.err = "No media file is open"
    elif p.isTimestamp:
      if p.name in picks: result.value = picks[p.name]
      elif path.len == 0: result.err = "No media file is open"
      else: result.err = "No known time chosen for " & p.name
    elif p.isExternal:
      if p.name in picks: result.value = picks[p.name]
      else: result.err = "No file chosen for " & p.name
    elif p.isList:
      if picks.getOrDefault(p.name).len > 0: result.value = picks[p.name]
      else: result.err = "No files chosen for " & p.name
    else:
      result.err = "Card " & p.name & " doesn't refer to anything"

proc compose*(parts: seq[CmdPart], path: string, picks: Table[string, string],
    timeFix = ""): tuple[script, err: string] =
  ## A bash script: one assignment per card, then the command line with each
  ## card expanded as "${name}" (quoted to fit the quotes typed around it).
  ## With timeFix, a bash function, timestamps are assigned what it makes of
  ## them (times of a clip of the media file). A file list card passed as
  ## arguments is an array, expanded as "${name[@]}": a word per file; picks
  ## holds its files a line each. Passed as a list file, picks holds that
  ## file's path instead.
  var assigned: seq[string]
  var body = ""
  var inSingle, inDouble, escaped = false
  for p in parts:
    if not p.card:
      for ch in p.text:
        if escaped: escaped = false
        elif ch == '\\' and not inSingle: escaped = true
        elif ch == '\'' and not inDouble: inSingle = not inSingle
        elif ch == '"' and not inSingle: inDouble = not inDouble
        body.add ch
      continue
    escaped = false
    let (value, err) = p.resolve(path, picks)
    if err.len > 0: return ("", err)
    let array = p.isList and p.list == lfArgs
    if p.name notin assigned:
      assigned.add p.name
      result.script.add p.name & "=" &
        (if array: "(" & value.listItems.mapIt(quoteShellPosix(it)).join(" ") & ")"
         elif timeFix.len > 0 and p.isTimestamp: "$(" & timeFix & " " & quoteShellPosix(value) & ") || exit"
         else: quoteShellPosix(value)) & "\n"
    let v = "${" & p.name & (if array: "[@]}" else: "}")
    body.add(if inSingle: "'\"" & v & "\"'" elif inDouble: v else: "\"" & v & "\"")
  result.script.add body

proc preview(toks: seq[CmdPart], path: string): string =
  ## The command line as it would run now, values in place of the cards;
  ## timestamps and external files are only known on run.
  for t in toks:
    if not t.card: result.add t.text
    elif t.isTimestamp: result.add "[" & t.name & ": timestamp]"
    elif t.isExternal: result.add "[" & t.name & ": external file]"
    elif t.isList: result.add "[" & t.name & ": files]"
    else:
      let (value, err) = t.resolve(path, initTable[string, string]())
      result.add(if err.len > 0: "[" & t.name & "?]" else: quoteShellPosix(value))

# --- dialog state ------------------------------------------------------------

proc newCmdDialog*(): CmdDialog = CmdDialog(selected: -1)

proc load*(d: CmdDialog, c: CommandLine) =
  ## Edits a saved command line, or starts a new one when c has no title.
  d.origTitle = c.title
  d.title = c.title
  d.toks = c.parts.toTokens
  d.caret = d.toks.len
  d.caretEol = true
  d.anchor = d.caret
  d.selected = -1
  d.scroll = 0
  d.listOpen = false
  d.error = ""

proc commandLine*(d: CmdDialog): CommandLine =
  var toks = d.toks
  for t in toks.mitems:
    if t.isRect: t.content = t.content.mathDigits
  CommandLine(title: d.title.strip, parts: toks.toParts)

proc validate(d: CmdDialog): string =
  let title = d.title.strip
  if title.len == 0: return "Give the command line a name."
  for c in d.saved:
    if c.title == title and c.title != d.origTitle:
      return "Another command line is already called “" & title & "”."
  if not d.toks.anyIt(it.card or it.text.strip.len > 0): return "The command line is empty."
  for i, t in d.toks:
    if not t.card: continue
    if not validName(t.name): return "“" & t.name & "” is not a valid variable name."
    if t.kind == ckReference and t.content.len == 0:
      return "Choose what card " & t.name & " refers to."
    for u in d.toks[0 ..< i]:
      if u.card and u.name == t.name and (u.kind != t.kind or u.content != t.content or
                                          u.rect != t.rect or u.dim != t.dim or
                                          u.path != t.path or u.reveal != t.reveal or
                                          u.play != t.play or u.list != t.list):
        return "Two different cards are named " & t.name & "."

proc insertTok(d: CmdDialog, t: CmdPart, at: int) =
  d.toks.insert(t, at)
  if d.selected >= at: inc d.selected

proc deleteTok(d: CmdDialog, at: int) =
  d.toks.delete(at)
  if d.selected == at: d.selected = -1
  elif d.selected > at: dec d.selected

proc isSpace(t: CmdPart): bool = not t.card and t.text == " "

proc addCard*(d: CmdDialog, name: string, kind = ckValue, content = "", rect = 0,
              dim = rdNone, path = false, reveal = false, play = false, list = lfArgs) =
  ## Inserts a card at the caret, spaced from its neighbours, and selects it;
  ## the caret goes after the space that follows it.
  var at = clamp(d.caret, 0, d.toks.len)
  if at > 0 and not d.toks[at - 1].isSpace:
    d.insertTok(CmdPart(text: " "), at)
    inc at
  d.insertTok(CmdPart(card: true, name: name, kind: kind, content: content, rect: rect,
    dim: dim, path: path, reveal: reveal, play: play, list: list), at)
  # Typing carries on after a space.
  if at + 1 == d.toks.len or not d.toks[at + 1].isSpace:
    d.insertTok(CmdPart(text: " "), at + 1)
  d.selected = at
  d.caret = at + 2
  d.caretEol = false
  d.anchor = d.caret
  d.error = ""

proc addText*(d: CmdDialog, text: string) =
  ## Inserts text at the caret, as typed (debug scripting).
  for ch in text.chars:
    d.insertTok(CmdPart(text: ch), d.caret)
    inc d.caret
  d.anchor = d.caret
  d.caretEol = false

proc selectCard*(d: CmdDialog, name: string) =
  ## Shows the properties of the first card called name (debug scripting).
  for k, t in d.toks:
    if t.card and t.name == name:
      d.selected = k
      return

proc freeName(d: CmdDialog, base: string): string =
  ## base, else base2, base3, ... whichever no card is named yet.
  result = base
  var n = 1
  while d.toks.anyIt(it.card and it.name == result):
    inc n
    result = base & $n

proc rectNumber*(toks: seq[CmdPart], id: int): int =
  ## Rectangles are numbered by where their first card is.
  var seen: seq[int]
  for t in toks:
    if t.isRect and t.rect notin seen: seen.add t.rect
  seen.find(id) + 1

proc makeRect(d: CmdDialog, s: int) =
  ## Turns card s into the width of a new rectangle; a name New card made
  ## up becomes "width".
  var id = 1
  for t in d.toks:
    if t.isRect: id = max(id, t.rect + 1)
  d.toks[s].rect = id
  d.toks[s].dim = rdWidth
  d.toks[s].content = d.toks[s].content.mathDigits
  let name = d.toks[s].name
  if name.startsWith("var") and name.len > 3 and name[3 .. ^1].allCharsInSet(Digits):
    d.toks[s].name = ""
    d.toks[s].name = d.freeName("width")

proc newCard(d: CmdDialog, ui: Ui) =
  ## New card button: a card named var1, var2, ... ready to be renamed.
  var n = 1
  while d.toks.anyIt(it.card and it.name == "var" & $n): inc n
  d.addCard("var" & $n)
  ui.focusId = "cl-name"
  ui.navId = "cl-name"
  ui.focusFresh = true

# --- command line field --------------------------------------------------------

proc chipLabel(t: CmdPart): string = (if t.name.len > 0: t.name else: "?")

proc layout(ui: Ui, toks: seq[CmdPart], width: float32): seq[Rect] =
  ## Token rects relative to the text origin. Words wrap as a whole; a word
  ## wider than the field breaks between characters. Positions within a word
  ## come from measuring its prefixes, so kerning is kept.
  result = newSeq[Rect](toks.len)
  var x, y = 0'f32
  var i = 0
  while i < toks.len:
    let t = toks[i]
    if t.card or t.isSpace:
      let w = if t.card: ui.textSize(t.chipLabel).x + ChipPad * 2 else: ui.textSize(" ").x
      if t.card and x > 0 and x + w > width:
        x = 0
        y += LineH
      result[i] = rect(x, y, w, LineH)
      x += w
      inc i
      continue
    var j = i
    var word = ""
    while j < toks.len and not toks[j].card and not toks[j].isSpace:
      word.add toks[j].text
      inc j
    if x > 0 and x + ui.textSize(word).x > width:
      x = 0
      y += LineH
    var prefix = ""
    var a = 0'f32               # prefix width at token k
    var lineStart = x           # where the word's current line piece begins
    var cut = 0'f32             # prefix width at that piece's start
    for k in i ..< j:
      prefix.add toks[k].text
      let b = ui.textSize(prefix).x
      var px = lineStart + a - cut
      if px > 0 and px + b - a > width:
        y += LineH
        lineStart = 0
        cut = a
        px = 0
      result[k] = rect(px, y, b - a, LineH)
      a = b
    x = result[j - 1].x + result[j - 1].w
    i = j

proc caretPos(d: CmdDialog, rs: seq[Rect]): Vec2 =
  let c = clamp(d.caret, 0, rs.len)
  if rs.len == 0: vec2(0, 0)
  elif c == rs.len or (d.caretEol and c > 0): vec2(rs[c - 1].x + rs[c - 1].w, rs[c - 1].y)
  else: rs[c].xy

proc hitCaret(rs: seq[Rect], p: Vec2): tuple[caret: int, eol: bool] =
  ## Caret index nearest to p (text coordinates).
  if rs.len == 0: return (0, false)
  let lastLine = int(rs[^1].y / LineH)
  let line = clamp(int(floor(p.y / LineH)), 0, lastLine)
  var last = -1
  for k, r in rs:
    if int(r.y / LineH) != line: continue
    if p.x < r.x + r.w / 2: return (k, false)
    last = k
  if last < 0: (rs.len, false) else: (last + 1, true)

proc hitTok(rs: seq[Rect], p: Vec2): int =
  ## Token under p (text coordinates), or the nearest one on p's line.
  if rs.len == 0: return 0
  let line = clamp(int(floor(p.y / LineH)), 0, int(rs[^1].y / LineH))
  result = -1
  for k, r in rs:
    if int(r.y / LineH) != line: continue
    result = k
    if p.x < r.x + r.w: return
  if result < 0: result = rs.len - 1

proc eolAt(rs: seq[Rect], c: int): bool =
  ## Whether caret index c, at a line's end, is drawn there rather than at
  ## the next line's start.
  c > 0 and c < rs.len and rs[c].y > rs[c - 1].y

proc classes(toks: seq[CmdPart]): seq[int] =
  ## Word classes for ui's word helpers; each card is a word of its own.
  for k, t in toks:
    result.add(if t.card: 3 + k else: charClass(t.text[0]))

proc clipText(toks: openArray[CmdPart]): string =
  ## Copied text: cards become bash variables.
  for t in toks: result.add(if t.card: "$" & t.name else: t.text)

proc commandField(d: CmdDialog, ui: Ui, r: Rect) =
  ## The command line: wrapping text with cards as chips. Click a chip to
  ## show its properties. Dragging or Shift+click/arrows select, a
  ## double-click selects a word and a triple-click everything; Ctrl+arrows
  ## move by words.
  const id = "cl-line"
  let w = ui.window
  let hov = ui.hover(r)
  let inner = rect(r.x + FieldPad, r.y + 4, r.w - FieldPad * 2, r.h - 8)
  discard ui.tabStop(id, r, edit = true)
  if ui.focusId == id and ui.focusFresh:
    ui.focusFresh = false
    d.caret = d.toks.len
    d.caretEol = true
    d.anchor = d.caret
  if ui.focusId == id and w.buttonPressed[MouseLeft] and not hov:
    ui.focusId = ""
  var rs = layout(ui, d.toks, inner.w)
  let origin = vec2(inner.x, inner.y - d.scroll)
  if hov and ui.pressed():
    ui.consumeClick()
    ui.navId = id
    ui.focusId = id
    ui.activeId = id
    let p = ui.mouse - origin
    d.dragFrom = p
    let clicks = ui.countClick(id)
    var chip = -1
    for k, t in d.toks:
      if t.card and p.inside(rs[k]): chip = k
    if clicks == 2:
      (d.anchor, d.caret) = wordAround(d.toks.classes, hitTok(rs, p))
      d.caretEol = eolAt(rs, d.caret)
    elif clicks >= 3:
      d.anchor = 0
      d.caret = d.toks.len
      d.caretEol = true
    else:
      if chip >= 0:
        d.selected = chip
        d.caret = chip + 1
        d.caretEol = true
      else:
        (d.caret, d.caretEol) = hitCaret(rs, p)
      if not w.shiftDown: d.anchor = d.caret
      d.dragCaret = d.caret
  if ui.focusId == id and ui.activeId == id and ui.down():
    let p = ui.mouse - origin
    if ui.clickCount == 2:
      (d.anchor, d.caret) = wordDrag(d.toks.classes, hitTok(rs, d.dragFrom), hitTok(rs, p))
      d.caretEol = eolAt(rs, d.caret)
    elif ui.clickCount == 1 and (p - d.dragFrom).length > 3:
      d.anchor = d.dragCaret
      (d.caret, d.caretEol) = hitCaret(rs, p)

  let focused = ui.focusId == id
  var moved = false
  if focused:
    d.caret = clamp(d.caret, 0, d.toks.len)
    d.anchor = clamp(d.anchor, 0, d.toks.len)
    let ctrl = w.ctrlDown
    let shift = w.shiftDown
    let (s0, s1) = (min(d.anchor, d.caret), max(d.anchor, d.caret))
    proc deleteSelection() =
      for _ in s0 ..< s1: d.deleteTok(s0)
      d.caret = s0
      d.anchor = s0
      d.caretEol = false
      moved = true
    if ctrl and w.buttonPressed[KeyA]:
      d.anchor = 0
      d.caret = d.toks.len
      d.caretEol = true
    if ctrl and (w.buttonPressed[KeyC] or w.buttonPressed[KeyX]) and s1 > s0:
      setClipboardString(d.toks[s0 ..< s1].clipText)
      if w.buttonPressed[KeyX]: deleteSelection()
    var ins = ""
    for ch in ui.typed:
      if ch.ord >= 0x20 and ch.ord != 0x7f: ins.add ch
    if ctrl and w.buttonPressed[KeyV]:
      ins.add getClipboardString().multiReplace(("\r", ""), ("\n", " "), ("\t", " "))
    if ins.len > 0 and d.caret != d.anchor: deleteSelection()
    for ch in ins.chars:
      d.insertTok(CmdPart(text: ch), d.caret)
      inc d.caret
      d.anchor = d.caret
      d.caretEol = false
      moved = true
    if (w.buttonPressed[KeyBackspace] or w.buttonPressed[KeyDelete]) and
       d.caret != d.anchor:
      deleteSelection()
    elif w.buttonPressed[KeyBackspace] and d.caret > 0:
      dec d.caret
      d.deleteTok(d.caret)
      d.anchor = d.caret
      d.caretEol = false
      moved = true
    elif w.buttonPressed[KeyDelete] and d.caret < d.toks.len:
      d.deleteTok(d.caret)
      d.caretEol = false
      moved = true
    if moved: rs = layout(ui, d.toks, inner.w)
    # Moving keys: with Shift they extend the selection, without it a
    # selection collapses to the side moved toward (arrows) or the caret
    # moves on from where it is.
    let cp = d.caretPos(rs)
    let (lo, hi) = (min(d.anchor, d.caret), max(d.anchor, d.caret))
    var keyMoved = false
    if w.buttonPressed[KeyLeft]:
      d.caret = if ctrl: wordLeft(d.toks.classes, d.caret)
                elif shift or lo == hi: max(0, d.caret - 1) else: lo
      d.caretEol = false
      keyMoved = true
    if w.buttonPressed[KeyRight]:
      d.caret = if ctrl: wordRight(d.toks.classes, d.caret)
                elif shift or lo == hi: min(d.toks.len, d.caret + 1) else: hi
      # Stepping past a line's last token: stay at that line's end.
      d.caretEol = eolAt(rs, d.caret)
      keyMoved = true
    if w.buttonPressed[KeyHome]:
      (d.caret, d.caretEol) = hitCaret(rs, vec2(-1, cp.y + 1))
      keyMoved = true
    if w.buttonPressed[KeyEnd]:
      (d.caret, d.caretEol) = hitCaret(rs, vec2(1e9, cp.y + 1))
      keyMoved = true
    if w.buttonPressed[KeyUp] and cp.y > 0:
      (d.caret, d.caretEol) = hitCaret(rs, vec2(cp.x, cp.y - LineH + 1))
      keyMoved = true
    if w.buttonPressed[KeyDown]:
      (d.caret, d.caretEol) = hitCaret(rs, vec2(cp.x, cp.y + LineH + 1))
      keyMoved = true
    if keyMoved:
      if not shift: d.anchor = d.caret
      moved = true
    if w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter] or
       w.buttonPressed[KeyTab] or w.buttonPressed[KeyEscape]:
      ui.focusId = ""

  # Scrolling: the wheel, and following the caret.
  let contentH = (if rs.len > 0: rs[^1].y + LineH else: LineH)
  let maxScroll = max(0'f32, contentH - inner.h)
  if hov and ui.scroll() != 0:
    d.scroll += ui.scroll() * LineH
    ui.scrollConsumed = true
  if focused and moved:
    let cy = d.caretPos(rs).y
    if cy < d.scroll: d.scroll = cy
    if cy + LineH > d.scroll + inner.h: d.scroll = cy + LineH - inner.h
  d.scroll = clamp(d.scroll, 0, maxScroll)
  let o = vec2(inner.x, inner.y - d.scroll)

  ui.rect(r, colBackground)
  ui.border(r, if ui.focusId == id: colAccent elif hov: colTextDim else: colBorder)
  ui.sk.pushClipRect(inner)
  if d.toks.len == 0 and ui.focusId != id:
    ui.textIn("Type a command; New card adds a variable at the caret",
      rect(o.x, o.y, inner.w, LineH), colTextDisabled)
  let (lo, hi) = (min(d.anchor, d.caret), max(d.anchor, d.caret))
  for k, t in d.toks:
    let tr = rect(rs[k].xy + o, rs[k].wh)
    if tr.y + tr.h < inner.y or tr.y > inner.y + inner.h: continue
    if ui.focusId == id and k >= lo and k < hi:
      ui.rect(rect(tr.x, tr.y + 2, tr.w, tr.h - 4), colAccentDim)
    if not t.card:
      ui.textIn(t.text, rect(tr.x, tr.y, tr.w + 20, tr.h), colText)
      continue
    let chip = rect(tr.x + 1, tr.y + 3, tr.w - 2, tr.h - 6)
    ui.rect(chip, if t.kind == ckReference: colCardRef elif t.isRect: colCardRect
                  elif t.isPath: colCardPath else: colCardValue)
    let bad = not validName(t.name) or t.kind == ckReference and t.content.len == 0
    # The other cards of the selected card's rectangle are outlined dashed.
    let sibling = t.isRect and d.selected >= 0 and d.selected < d.toks.len and
      d.toks[d.selected].isRect and d.toks[d.selected].rect == t.rect
    if k == d.selected: ui.border(chip, colAccent)
    elif bad: ui.border(chip, colError)
    elif sibling: ui.dashedBorder(chip, colAccent, 4, 3)
    elif ui.hover(chip): ui.border(chip, colTextDim)
    ui.textIn(t.chipLabel, chip, colText, h = CenterAlign)
  if ui.focusId == id:
    let cp = d.caretPos(rs) + o
    ui.rect(rect(cp.x, cp.y + 4, 1, LineH - 8), colAccent)
  ui.sk.popClipRect()
  if maxScroll > 0:
    let th = max(20'f32, inner.h * inner.h / contentH)
    let ty = inner.y + (inner.h - th) * (d.scroll / maxScroll)
    ui.rect(rect(r.x + r.w - 4, ty, 3, th), colTrack)

# --- properties ----------------------------------------------------------------

proc choiceList(d: CmdDialog, ui: Ui, id: string, r: Rect,
    rows: openArray[tuple[key, label, detail: string]], key: var string, path = ""): bool =
  ## Flat list to pick one of rows from, by key; true when key changed.
  ui.rect(r, colBackground)
  ui.border(r, colBorder)
  let inner = rect(r.x + 1, r.y + 1, r.w - 2, r.h - 2)
  let focused = ui.tabStop(id, r)
  if focused: ui.focusRing(r)
  var cur = -1
  for i, row in rows:
    if row.key == key: cur = i
  if focused and ui.focusId.len == 0:
    let w = ui.window
    var c = cur
    if w.buttonPressed[KeyUp]: c = max(0, c - 1)
    if w.buttonPressed[KeyDown]: c = min(rows.high, c + 1)
    if c != cur and c >= 0:
      key = rows[c].key
      result = true
      cur = c
      let top = c.float32 * RowH
      if top < d.refScroll: d.refScroll = top
      if top + RowH > d.refScroll + inner.h: d.refScroll = top + RowH - inner.h
  let maxScroll = max(0'f32, rows.len.float32 * RowH - inner.h)
  if ui.hover(inner) and ui.scroll() != 0:
    d.refScroll += ui.scroll() * RowH
    ui.scrollConsumed = true
  d.refScroll = clamp(d.refScroll, 0, maxScroll)
  let outerClip = ui.hitClip
  ui.hitClip = inner
  ui.sk.pushClipRect(inner)
  for i, row in rows:
    let rr = rect(inner.x, inner.y + i.float32 * RowH - d.refScroll, inner.w, RowH)
    if rr.y + RowH < inner.y or rr.y > inner.y + inner.h: continue
    let sel = i == cur
    let hov = ui.hover(rr)
    if sel: ui.rect(rr, colAccent)
    elif hov: ui.rect(rr, colHover)
    let dw = if row.detail.len > 0: ui.textSize(row.detail, FontSmall).x + 12 else: 0'f32
    ui.textIn(ui.ellipsize(row.label, rr.w - dw - 16), rect(rr.x + 8, rr.y, rr.w - dw - 16, RowH),
      if sel: colOnAccent elif row.key == "file" and path.len == 0: colTextDim else: colText)
    if dw > 0:
      ui.textIn(row.detail, rect(rr.x + rr.w - dw, rr.y, dw - 8, RowH),
        if sel: colOnAccent else: colTextDim, FontSmall, h = RightAlign)
    if row.key == "file" and path.len > 0: ui.tip(rr, path)
    if hov and ui.pressed():
      ui.consumeClick()
      ui.navId = id
      result = key != row.key
      key = row.key
  ui.sk.popClipRect()
  ui.hitClip = outerClip

proc properties(d: CmdDialog, ui: Ui, r: Rect, path: string) =
  ui.groupHeader(r.xy, r.w, "Card properties")
  var y = r.y + 30
  let s = d.selected
  if s < 0 or s >= d.toks.len or not d.toks[s].card:
    d.selected = -1
    ui.textIn("Click a card in the command line to edit it,", rect(r.x, y, r.w, 20),
      colTextDim, FontSmall)
    ui.textIn("or add one with New card.", rect(r.x, y + 18, r.w, 20), colTextDim, FontSmall)
    return
  const labelW = 70'f32
  ui.textIn("Name", rect(r.x, y, labelW, 26), colText)
  discard ui.textField("cl-name", rect(r.x + labelW, y, r.w - labelW, 26), d.toks[s].name,
    "variable name")
  y += 28
  let name = d.toks[s].name
  if validName(name):
    ui.textIn("Runs as the bash variable $" & name, rect(r.x + labelW, y, r.w - labelW, 18),
      colTextDim, FontSmall)
  else:
    ui.textIn(if name.len == 0: "Required"
              else: "Letters, digits and _; no leading digit",
      rect(r.x + labelW, y, r.w - labelW, 18), colError, FontSmall)
  y += 26
  ui.textIn("Type", rect(r.x, y, labelW, 22), colText)
  if ui.radioButton("cl-value", vec2(r.x + labelW, y), "Value", d.toks[s].kind == ckValue) and
     d.toks[s].kind != ckValue:
    d.toks[s].kind = ckValue
    d.toks[s].content = ""
    d.toks[s].list = lfArgs
    d.refScroll = 0
  if ui.radioButton("cl-refer", vec2(r.x + labelW + 90, y), "Reference",
                    d.toks[s].kind == ckReference) and d.toks[s].kind != ckReference:
    d.toks[s].kind = ckReference
    d.toks[s].content = "file"
    d.toks[s].rect = 0
    d.toks[s].dim = rdNone
    d.toks[s].path = false
    d.toks[s].reveal = false
    d.toks[s].play = false
    d.refScroll = 0
  y += 34
  ui.textIn("Content", rect(r.x, y, labelW, 26), colText)
  let fw = r.w - labelW
  if d.toks[s].kind == ckReference:
    # What a card can refer to: the media file's path, or a timestamp,
    # external file or list of files picked when the command runs.
    let rows = [
      (key: "file", label: "Current media file", detail: (if path.len > 0: "" else: "none open")),
      (key: "timestamp", label: "Timestamp", detail: "chosen on run"),
      (key: "external", label: "External file", detail: "chosen on run"),
      (key: "files", label: "Files", detail: "chosen on run, in order")]
    if d.choiceList(ui, "cl-ref", rect(r.x + labelW, y, fw, RowH * rows.len.float32 + 2), rows,
                    d.toks[s].content, path):
      d.toks[s].list = lfArgs
    if not d.toks[s].isList: return
    # How the files reach the command: words, or a file listing them.
    y += RowH * rows.len.float32 + 10
    ui.textIn("Pass as", rect(r.x, y, labelW, 22), colText)
    for (form, label) in [(lfArgs, "Arguments, a word per file"),
                          (lfConcat, "ffmpeg concat list file"),
                          (lfLines, "Text file, a path per line")]:
      if ui.radioButton("cl-list" & $form, vec2(r.x + labelW, y), label, d.toks[s].list == form):
        d.toks[s].list = form
      y += 24
    let n = d.toks[s].name
    let note = case d.toks[s].list
      of lfArgs: @["Runs as \"${" & n & "[@]}\": for f in", "\"${" & n & "[@]}\"; do ...; done"]
      of lfConcat: @["For ffmpeg -f concat -safe 0 -i; the", "file is deleted once the run ends."]
      of lfLines: @["The file is deleted once the run", "ends."]
    for line in note:
      ui.textIn(ui.ellipsize(line, fw, FontSmall), rect(r.x + labelW, y + 2, fw, 18), colTextDim,
        FontSmall)
      y += 18
    return
  let contents = [(key: "text", label: "Text", detail: ""),
                  (key: "rect", label: "Rectangle", detail: "drawn on run"),
                  (key: "path", label: "Path", detail: "browsed for on run")]
  var content = if d.toks[s].isRect: "rect" elif d.toks[s].isPath: "path" else: "text"
  if d.choiceList(ui, "cl-kind", rect(r.x + labelW, y, fw, RowH * 3 + 2), contents, content):
    d.toks[s].path = content == "path"
    if not d.toks[s].path: d.toks[s].reveal = false
    if content == "rect": d.makeRect(s)
    else:
      d.toks[s].rect = 0
      d.toks[s].dim = rdNone
  y += RowH * 3 + 10
  ui.textIn("Default", rect(r.x, y, labelW, 26), colText)
  if d.toks[s].isPath:
    discard ui.textField("cl-content", rect(r.x + labelW, y, fw, 26), d.toks[s].content, "path")
    ui.textIn("Can be changed or browsed for on run.", rect(r.x + labelW, y + 28, fw, 18),
      colTextDim, FontSmall)
    ui.textIn("~ is home; else from the media's folder.", rect(r.x + labelW, y + 46, fw, 18),
      colTextDim, FontSmall)
    ui.textIn("Once the command succeeds:", rect(r.x + labelW, y + 72, fw, 18), colTextDim,
      FontSmall)
    discard ui.checkbox("cl-reveal", vec2(r.x + labelW, y + 92), "Open containing folder",
      d.toks[s].reveal)
    discard ui.checkbox("cl-play", vec2(r.x + labelW, y + 116), "Open in a new player",
      d.toks[s].play)
    ui.tip(rect(r.x + labelW, y + 116, fw, 22),
      "Opens the file in a player of its own; the Run window can change it for a run")
    return
  if not d.toks[s].isRect:
    discard ui.textField("cl-content", rect(r.x + labelW, y, fw, 26), d.toks[s].content, "text")
    ui.textIn("Can be changed on run.", rect(r.x + labelW, y + 28, fw, 18), colTextDim, FontSmall)
    ui.textIn("A leading ~ means your home folder.",
      rect(r.x + labelW, y + 46, fw, 18), colTextDim, FontSmall)
    return
  discard ui.textField("cl-content", rect(r.x + labelW, y, fw, 26), d.toks[s].content, "number")
  d.toks[s].content =
    if ui.focusId == "cl-content": d.toks[s].content.mathOnly
    else: d.toks[s].content.mathDigits
  let t = d.toks[s]
  let dimLabel = case t.dim
    of rdHeight: "Height"
    of rdX: "X"
    of rdY: "Y"
    else: "Width"
  ui.textIn(dimLabel & " of rectangle " & $d.toks.rectNumber(t.rect) & ", in pixels",
    rect(r.x + labelW, y + 28, fw, 18), colTextDim, FontSmall)
  # More cards of this rectangle, at the caret.
  y += 52
  let bw = (fw - 6) / 2
  for i, (dim, label) in [(rdWidth, "Add width"), (rdHeight, "Add height"),
                          (rdX, "Add X"), (rdY, "Add Y")]:
    let br = rect(r.x + labelW + float32(i mod 2) * (bw + 6), y + float32(i div 2) * 32, bw, 26)
    if ui.textButton("cl-add" & $dim, br, label):
      d.addCard(d.freeName($dim), ckValue, "", t.rect, dim)

# --- window ---------------------------------------------------------------------

proc draw*(d: CmdDialog, ui: Ui, r: Rect, path: string): CmdAction =
  ## Draws the window's contents filling r. path is the current media file,
  ## offered as a reference.
  let w = ui.window
  let keys = ui.focusId.len == 0  # keys for the window, not a field being edited
  let W = r.w
  let H = r.h

  # Name, with the saved command lines dropped down from the arrow.
  ui.textIn("Name", rect(r.x + 16, r.y + 10, 200, 20), colTextDim, FontSmall)
  let titleR = rect(r.x + 16, r.y + 32, W - 32 - 34 - 88 * 2, 28)
  let arrowR = rect(titleR.x + titleR.w + 4, titleR.y, 30, 28)
  let newR = rect(arrowR.x + arrowR.w + 8, titleR.y, 80, 28)
  let delR = rect(newR.x + newR.w + 8, titleR.y, 80, 28)
  const ListMax = 10
  # Presets first, then the user's own behind a separator (-1).
  var entries: seq[int]
  for presets in [true, false]:
    var first = true
    for i, c in d.saved:
      if c.isPreset != presets: continue
      if first and entries.len > 0: entries.add -1
      first = false
      entries.add i
  let listRows = entries.len
  proc entryH(e: int): float32 = (if e < 0: MenuSeparatorHeight else: RowH)
  # Tall enough for its tallest stretch of rows, so scrolling keeps its size.
  var listH = 0'f32
  for s in 0 .. max(0, listRows - ListMax):
    var h = 0'f32
    for e in entries[s ..< min(listRows, s + ListMax)]: h += entryH(e)
    listH = max(listH, h)
  let listR = rect(titleR.x, titleR.y + titleR.h + 2, titleR.w + 34, listH + 2)
  let overList = d.listOpen and ui.mouse.inside(listR)
  var escUsed = false
  if d.listOpen:
    if w.buttonPressed[KeyEscape]:
      d.listOpen = false
      escUsed = true
    if ui.pressed() and not overList:
      d.listOpen = false
      ui.consumeClick()
  if overList:
    if ui.scroll() != 0:
      d.listScroll += int(sgn(ui.scroll()))
      ui.scrollConsumed = true
    ui.captured = true
  d.listScroll = clamp(d.listScroll, 0, max(0, listRows - ListMax))

  discard ui.textField("cl-title", titleR, d.title, "Untitled")
  ui.rect(arrowR, colPanelRaised)
  ui.border(arrowR, colBorder)
  if ui.iconButton("cl-list", arrowR, "expand16", "Saved command lines",
                   enabled = listRows > 0):
    d.listOpen = not d.listOpen
    d.listScroll = 0
  if ui.textButton("cl-new", newR, "New"):
    d.load(CommandLine())
    ui.focusId = "cl-title"
    ui.navId = "cl-title"
    ui.focusFresh = true
  let canDelete = d.origTitle.len > 0
  if canDelete:
    if ui.textButton("cl-delete", delR, "Delete"): result = caDelete
  else:
    ui.rect(delR, colPanelRaised)
    ui.border(delR, colBorder)
    ui.textIn("Delete", delR, colTextDisabled, h = CenterAlign)

  # A separator under the title row, then the two columns.
  ui.rect(rect(r.x + 1, r.y + 68, W - 2, 1), colBorder)
  let top = r.y + 80
  let bottom = r.y + H - 58
  const cardsW = 300'f32
  ui.groupHeader(vec2(r.x + 16, top), W - 32, "Command line")
  let colTop = top + 26

  # Left column: the command line and what it would run.
  let leftR = rect(r.x + 16, colTop, W - 32 - cardsW - 20, bottom - colTop)
  const previewH = 4 * 18'f32 + 26
  let fieldR = rect(leftR.x, leftR.y, leftR.w, leftR.h - previewH)
  d.commandField(ui, fieldR)
  var py = fieldR.y + fieldR.h + 10
  ui.textIn("Runs as", rect(leftR.x, py, leftR.w, 18), colTextDim, FontSmall)
  py += 20
  let shown = d.toks.preview(path)
  for line in ui.wrapText(shown, leftR.w, 4, FontSmall):
    ui.textIn(line, rect(leftR.x, py, leftR.w, 18), colText, FontSmall)
    py += 18

  # Right column: New card, then the selected card's properties.
  let rightR = rect(leftR.x + leftR.w + 20, colTop, cardsW, bottom - colTop)
  if ui.textButton("cl-newcard", rect(rightR.x, rightR.y, 120, 28), "New card"):
    d.newCard(ui)
  d.properties(ui, rect(rightR.x, rightR.y + 44, rightR.w, rightR.h - 44), path)

  # Buttons; the reason for a refused Apply or OK on their left.
  ui.rect(rect(r.x + 1, r.y + H - 50, W - 2, 1), colBorder)
  let by = r.y + H - 40
  if d.error.len > 0:
    ui.textIn(ui.ellipsize(d.error, W - 360), rect(r.x + 16, by, W - 360, 30), colError)
  let apply = ui.textButton("cl-apply", rect(r.x + W - 312, by, 92, 30), "Apply")
  let cancel = ui.textButton("cl-cancel", rect(r.x + W - 212, by, 92, 30), "Cancel")
  var ok = ui.textButton("cl-ok", rect(r.x + W - 112, by, 92, 30), "OK", primary = true)
  if d.applyRequested:
    d.applyRequested = false
    ok = true
  # Enter is OK unless a focused button took it.
  if keys and not ui.enterUsed and
     (w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter]):
    ok = true
  if cancel or keys and not escUsed and w.buttonPressed[KeyEscape]: result = caCancel
  elif apply or ok:
    d.error = d.validate
    if d.error.len == 0: result = (if ok: caOk else: caApply)

  # The dropped-down title list, over everything.
  if d.listOpen:
    ui.captured = false
    ui.sk.pushLayer(PopupsLayer)
    ui.rect(rect(listR.xy + vec2(3, 4), listR.wh), colShadow)
    ui.rect(listR, colPopup)
    ui.border(listR, colBorder)
    var y = listR.y + 1
    for n in 0 ..< min(listRows, ListMax):
      let i = entries[n + d.listScroll]
      let rr = rect(listR.x + 1, y, listR.w - 2, entryH(i))
      y += rr.h
      if i < 0:
        ui.rect(rect(rr.x + 8, rr.y + rr.h / 2, rr.w - 16, 1), colBorder)
        continue
      let hov = ui.hover(rr)
      if hov: ui.rect(rr, colHover)
      let label = d.saved[i].title
      let current = label == d.origTitle
      ui.textIn(ui.ellipsize(label, rr.w - 20), rect(rr.x + 10, rr.y, rr.w - 20, RowH),
        if current: colAccent else: colText)
      if hov and ui.pressed():
        ui.consumeClick()
        ui.focusId = ""
        d.load(d.saved[i])
    ui.sk.popLayer()

  if result != caNone:
    ui.focusId = ""
    return
  discard ui.tabNavigate()

# --- Run window: timestamps and values for one run --------------------------------

type
  PickAction* = enum
    paNone, paRun, paCancel, paDraw, paBrowse, paAddFiles

  TimeChoice* = object
    ## An entry of a timestamp row's list: a time, a separator, or a note
    ## (gray text, not chosen).
    label*: string
    time*: float              ## seconds, < 0 when unknown
    which*: string            ## "start", "current", "end", "loopA" or "loopB";
                              ## "" for a bookmark or chapter
    chapter*: bool            ## a chapter, not a bookmark
    sep*, note*: bool

  ListedFile* = tuple[known: bool, duration: float, width, height: int]
    ## What a file list shows of a file: its length and picture size (0 for
    ## none), known once probed.

  PickDialog* = ref object
    ## Shown when a command line with value, timestamp or file list cards
    ## runs: one row per card, its name and a dropdown of times (the start,
    ## the current time, the end, the A-B loop marks, the media file's
    ## bookmarks and chapters), a field holding the card's value, or a list
    ## of files to put in order.
    cmd*: CommandLine
    rows*: seq[CmdPart]       ## the cards asked about
    picks*: seq[int]          ## timestamp rows: the index of the time chosen
    chosen*: seq[TimeChoice]  ## timestamp rows: the time chosen, found again
                              ## in the list as bookmarks come and go
    texts*: seq[string]       ## value rows: the value to run with
    crossed*: seq[bool]       ## rectangle rows: a drawn rectangle leaves them alone
    plays*: seq[bool]         ## path rows: the file played in a new player once done
    files*: seq[seq[string]]  ## file list rows: the files, in order
    marked*: seq[seq[bool]]   ## and which of them are selected
    cursor*: seq[int]         ## and the one the arrow keys go from, else -1
    anchor: seq[int]          ## where a Shift+click selection starts
    fileScroll: seq[float32]  ## pixels
    drawing*: int             ## rectangle being drawn over the video, else 0
    drawRequest*: int         ## with paDraw: the rectangle to draw
    browseRow*: int           ## with paBrowse: the path row to browse for
    addRow*: int              ## with paAddFiles: the file list row to add to
    openRow*: int             ## row whose dropdown is open, else -1
    listScroll: float32       ## the open list, in pixels
    dragRow: int              ## file list row pressed on, else -1
    dragFrom: Vec2
    dragging: bool            ## its selected files being dragged elsewhere
    dropAt: int               ## and the place they would go (a file index)
    pressedOn: int            ## a selected file pressed on: selected alone on
                              ## release, unless dragged; else -1
    error*: string            ## why Run was refused
    runRequested*: bool       ## debug scripting: press Run next frame

const
  PickTop = 44'f32
  PickRowH = 36'f32
  PickLabelW = 150'f32
  NoteH = 40'f32              ## the list's two-line note
  FilesShown = 8              ## file list rows in view
  FileRowH = 24'f32
  FileBoxH = FilesShown.float32 * FileRowH + 2
  FileBarH = 28'f32           ## a file list's buttons, under it
  PlayRowH = 26'f32           ## a path row's "Open in a new player" checkbox

proc timeChoices*(pos, duration, loopA, loopB: float,
    marks, chapters: seq[Bookmark]): seq[TimeChoice] =
  ## What a timestamp row picks from: the start, the current time and the
  ## end, then the A-B loop marks (< 0 when not set), then the bookmarks,
  ## then the chapters (named), each group after a separator. Without
  ## bookmarks, a note says how to add some.
  result = @[TimeChoice(label: "Start", which: "start"),
    TimeChoice(label: "Current time", time: pos, which: "current"),
    TimeChoice(label: "End", time: (if duration > 0: duration else: -1), which: "end"),
    TimeChoice(sep: true),
    TimeChoice(label: "Loop A", time: loopA, which: "loopA"),
    TimeChoice(label: "Loop B", time: loopB, which: "loopB"),
    TimeChoice(sep: true)]
  if marks.len == 0:
    result.add TimeChoice(note: true, label: "No bookmarks found.\n" &
      "Right-click the seek bar to get started.")
  for i, b in marks: result.add TimeChoice(label: b.label(i), time: b.time)
  if chapters.len > 0: result.add TimeChoice(sep: true)
  for i, b in chapters: result.add TimeChoice(label: b.label(i), time: b.time, chapter: true)

proc pickable(ch: TimeChoice): bool = not ch.sep and not ch.note

proc stepChoice(choices: seq[TimeChoice], k, dir: int): int =
  ## The next entry from k in direction dir, skipping separators and notes;
  ## k at the end.
  result = k
  var j = k + dir
  while j >= 0 and j < choices.len:
    if choices[j].pickable: return j
    j += dir

proc locate(choices: seq[TimeChoice], c: TimeChoice): int =
  ## Where c is in choices, which may have changed since it was chosen: the
  ## same entry, else a bookmark or chapter at its time (a bookmark made a
  ## chapter), else the nearest one (moved or removed), else the current time.
  var other, nearest, current = -1
  var best = Inf
  for k, ch in choices:
    if not ch.pickable: continue
    if ch.which.len > 0:
      if ch.which == c.which: return k
      if ch.which == "current": current = k
    elif c.which.len == 0:
      let dt = abs(ch.time - c.time)
      if dt < 0.0005:
        if ch.chapter == c.chapter: return k
        other = k
      # Off its group counts as farther than anything in it.
      let far = dt + (if ch.chapter == c.chapter: 0.0 else: 1e9)
      if far < best: (best, nearest) = (far, k)
  if other >= 0: other elif nearest >= 0: nearest elif current >= 0: current else: 0

proc choose*(d: PickDialog, i: int, choices: seq[TimeChoice], k: int) =
  ## Row i picks choices[k].
  if k < 0 or k >= choices.len or not choices[k].pickable: return
  d.picks[i] = k
  d.chosen[i] = choices[k]

proc newPickDialog*(): PickDialog = PickDialog(openRow: -1, dragRow: -1, pressedOn: -1)

proc draggingFiles*(d: PickDialog): bool =
  ## A file list's selected files are being dragged to another place.
  d.dragging

proc start*(d: PickDialog, c: CommandLine, choices: seq[TimeChoice],
    last = initTable[string, RunValue](), seed: seq[string] = @[], seedFirst = false) =
  ## Prepares the window for c. Cards start at what they were last run with
  ## (last): a value, the start, current time, end or a loop mark, or the
  ## bookmark or chapter at the same time (the same file). Otherwise values
  ## start at the card's own, the first timestamp card at the first bookmark
  ## (else the current time) and each later one at the entry after the
  ## previous card's, so a command using bookmarks in order needs no changes
  ## for a file marked in order. File lists start with seed when seedFirst
  ## (files picked in the playlist) or when the files they last ran with
  ## are gone, else with those.
  d.cmd = c
  d.rows = c.parts.runCards
  let n = d.rows.len
  d.picks = newSeq[int](n)
  d.chosen = newSeq[TimeChoice](n)
  d.texts = newSeq[string](n)
  d.crossed = newSeq[bool](n)
  d.plays = newSeq[bool](n)
  d.files = newSeq[seq[string]](n)
  d.marked = newSeq[seq[bool]](n)
  d.cursor = newSeqWith(n, -1)
  d.anchor = newSeqWith(n, -1)
  d.fileScroll = newSeq[float32](n)
  d.drawing = 0
  var prev = -1  # the previous timestamp card's pick
  for i, row in d.rows:
    if row.isTimestamp:
      d.picks[i] =
        if prev >= 0: choices.stepChoice(prev, 1)
        else:
          var first = 1
          for k, ch in choices:
            if ch.pickable and ch.which.len == 0: first = k; break
          first
      if row.name in last:
        let v = last[row.name]
        for k, ch in choices:
          if ch.pickable and (if v.which.len > 0: ch.which == v.which
                             else: ch.which.len == 0 and abs(ch.time - v.time) < 0.0005):
            d.picks[i] = k
            break
      d.chosen[i] = choices[d.picks[i]]
      prev = d.picks[i]
    elif row.isList:
      let kept = if row.name in last: last[row.name].value.listItems.filterIt(it.fileExists)
                 else: @[]
      d.files[i] = if seedFirst or kept.len == 0: seed else: kept
      d.marked[i] = newSeq[bool](d.files[i].len)
    else:
      d.texts[i] = if row.name in last: last[row.name].value else: row.content
      d.crossed[i] = row.isRect and row.name in last and last[row.name].crossed
      # The card's own setting, unless the last run changed it since it was
      # last set in the Commands window.
      d.plays[i] = row.play
      if row.isPath and row.name in last and last[row.name].hasPlay and
         last[row.name].playDefault == row.play:
        d.plays[i] = last[row.name].play
  d.openRow = -1
  d.listScroll = 0
  d.dragRow = -1
  d.dragging = false
  d.pressedOn = -1
  d.error = ""

proc rowHeight(row: CmdPart): float32 =
  if row.isList: FileBoxH + 8 + FileBarH + 12
  elif row.isPath: PickRowH + PlayRowH
  else: PickRowH

proc rowTop(d: PickDialog, i: int): float32 =
  ## Row i's top, from the window's.
  result = PickTop
  for row in d.rows[0 ..< min(i, d.rows.len)]: result += row.rowHeight

proc size*(d: PickDialog): tuple[w, h: int32] =
  ## Taller with timestamp rows, for room to drop their lists down; wider
  ## with a file list.
  let minH = if d.rows.anyIt(it.isTimestamp): 320'f32 else: 200'f32
  let w = if d.rows.anyIt(it.isList): 680'i32 else: 480'i32
  (w, int32(max(minH, d.rowTop(d.rows.len) + 70)))

proc choiceText(ch: TimeChoice): (string, string) =
  (ch.label, if ch.time < 0: "unknown" else: fmtTime(ch.time, millis = true))

proc entryH(ch: TimeChoice): float32 =
  if ch.sep: MenuSeparatorHeight elif ch.note: NoteH else: RowH

proc entryY(choices: seq[TimeChoice], k: int): float32 =
  ## Top of entry k in the list, from the list's top.
  for ch in choices[0 ..< min(k, choices.len)]: result += ch.entryH

proc dropRect(d: PickDialog, r: Rect, i: int): Rect =
  rect(r.x + 16 + PickLabelW, r.y + d.rowTop(i), r.w - 32 - PickLabelW, 28)

proc listRect(d: PickDialog, r: Rect, i: int, contentH: float32): Rect =
  ## The open dropdown's list: below its field, or above when there is more
  ## room there; it scrolls when the window is too short for all entries.
  let dr = d.dropRect(r, i)
  let below = r.y + r.h - (dr.y + dr.h) - 6
  let above = dr.y - r.y - 6
  let h = min(contentH, max(below, above) - 2) + 2
  let y = if below >= h or below >= above: dr.y + dr.h + 2 else: dr.y - 2 - h
  rect(dr.x, y, dr.w, h)

proc centerOn(d: PickDialog, r: Rect, i: int, choices: seq[TimeChoice]) =
  ## Scrolls row i's list to have its chosen entry in the middle.
  let lr = d.listRect(r, i, choices.entryY(choices.len))
  d.listScroll = choices.entryY(d.picks[i]) + RowH / 2 - (lr.h - 2) / 2

# --- file lists ---------------------------------------------------------------

proc revealFile(d: PickDialog, i, k: int) =
  ## Scrolls file list i to have file k in view.
  if k < 0: return
  let top = k.float32 * FileRowH
  if top < d.fileScroll[i]: d.fileScroll[i] = top
  if top + FileRowH > d.fileScroll[i] + FileBoxH - 2:
    d.fileScroll[i] = top + FileRowH - (FileBoxH - 2)

proc selectOnly(d: PickDialog, i, k: int) =
  for m in d.marked[i].mitems: m = false
  if k >= 0 and k < d.files[i].len: d.marked[i][k] = true
  d.cursor[i] = k
  d.anchor[i] = k
  d.revealFile(i, k)

proc fileListRow*(d: PickDialog): int =
  ## The first file list row, else -1.
  for i, row in d.rows:
    if row.isList: return i
  -1

proc dropTarget*(d: PickDialog, r: Rect, p: Vec2): tuple[row, at: int] =
  ## Where files dropped at p (in the window's r) go: into the file list
  ## under p, at the boundary nearest to it, else at the end of the first one.
  result = (d.fileListRow, -1)
  for i, row in d.rows:
    if not row.isList: continue
    let dr = d.dropRect(r, i)
    let box = rect(dr.x, dr.y, dr.w, FileBoxH)
    if p.inside(box):
      let k = int(round((p.y - box.y - 1 + d.fileScroll[i]) / FileRowH))
      return (i, clamp(k, 0, d.files[i].len))

proc addFiles*(d: PickDialog, i: int, paths: seq[string], at = -1) =
  ## Adds paths to file list row i, at the end or before file at, and selects
  ## them. Paths with line breaks are left out: no list file could hold them.
  if i < 0 or i >= d.rows.len or not d.rows[i].isList: return
  let add = paths.filterIt(it.len > 0 and '\n' notin it and '\r' notin it)
  if add.len == 0: return
  let pos = if at < 0 or at > d.files[i].len: d.files[i].len else: at
  d.files[i].insert(add, pos)
  d.marked[i] = newSeq[bool](d.files[i].len)
  for k in pos ..< pos + add.len: d.marked[i][k] = true
  d.anchor[i] = pos
  d.cursor[i] = pos + add.len - 1
  d.revealFile(i, pos + add.len - 1)
  d.revealFile(i, pos)
  d.error = ""

proc removeMarked*(d: PickDialog, i: int) =
  ## Removes the selected files; the one after them is selected next.
  var first = -1
  var files: seq[string]
  for k, f in d.files[i]:
    if d.marked[i][k]:
      if first < 0: first = k
    else: files.add f
  if first < 0: return
  d.files[i] = files
  d.marked[i] = newSeq[bool](files.len)
  d.selectOnly(i, min(first, files.len - 1))

proc moveMarked*(d: PickDialog, i, at: int) =
  ## Moves the selected files, in their order, together before file at
  ## (counted before the move; the length: to the end).
  var moved, rest: seq[string]
  var before = 0  # selected files above at: the place shifts up by them
  for k, f in d.files[i]:
    if d.marked[i][k]:
      moved.add f
      if k < at: inc before
    else: rest.add f
  if moved.len == 0: return
  let pos = clamp(at - before, 0, rest.len)
  d.files[i] = rest[0 ..< pos] & moved & rest[pos .. ^1]
  d.marked[i] = newSeq[bool](d.files[i].len)
  for k in pos ..< pos + moved.len: d.marked[i][k] = true
  d.anchor[i] = pos
  d.cursor[i] = pos + moved.len - 1
  d.revealFile(i, d.cursor[i])
  d.revealFile(i, pos)

proc stepMarked*(d: PickDialog, i, dir: int) =
  ## Moves each run of selected files a place up (dir < 0) or down; nothing
  ## moves when one is at that end already.
  let n = d.files[i].len
  if n == 0 or not d.marked[i].anyIt(it): return
  if (dir < 0 and d.marked[i][0]) or (dir > 0 and d.marked[i][n - 1]): return
  template swapAt(a, b: int) =
    swap(d.files[i][a], d.files[i][b])
    swap(d.marked[i][a], d.marked[i][b])
  if dir < 0:
    for k in 1 ..< n:
      if d.marked[i][k] and not d.marked[i][k - 1]: swapAt(k, k - 1)
  else:
    for k in countdown(n - 2, 0):
      if d.marked[i][k] and not d.marked[i][k + 1]: swapAt(k, k + 1)
  if d.cursor[i] >= 0: d.cursor[i] = clamp(d.cursor[i] + sgn(dir), 0, n - 1)
  if d.anchor[i] >= 0: d.anchor[i] = clamp(d.anchor[i] + sgn(dir), 0, n - 1)
  d.revealFile(i, d.cursor[i])

proc sortFiles*(d: PickDialog, i: int) =
  ## Sorts by file name, numbers by value; descending when ascending
  ## already. With two files or more selected, only those, among the places
  ## they hold.
  let sel = toSeq(0 ..< d.files[i].len).filterIt(d.marked[i][it])
  let places = if sel.len >= 2: sel else: toSeq(0 ..< d.files[i].len)
  let names = places.mapIt(d.files[i][it])
  var sorted = names.sorted(proc (a, b: string): int =
    naturalCmp(a.extractFilename, b.extractFilename))
  if sorted == names: sorted.reverse()
  for j, k in places: d.files[i][k] = sorted[j]

proc fileSummary(files: seq[string], info: proc (path: string): ListedFile): string =
  ## "3 files · 00:41:22": the total length once every file's is known.
  result = $files.len & (if files.len == 1: " file" else: " files")
  var total = 0.0
  for f in files:
    let fi = info(f)
    if not fi.known or fi.duration <= 0: return
    total += fi.duration
  if files.len > 0: result.add " · " & fmtTime(total, dur = total)

proc fileList(d: PickDialog, ui: Ui, r: Rect, i: int,
    info: proc (path: string): ListedFile): PickAction =
  ## File list row i: the files in order, numbered, with their picture size
  ## and length. Click selects, Ctrl+click adds or removes, Shift+click
  ## selects a range; dragging the selected files moves them. With the list
  ## focused, Up/Down/Home/End move, with Shift selecting as they go; as in
  ## the playlist, Ctrl+Shift with them moves the selected files, Delete
  ## removes them and Ctrl+A selects all.
  let w = ui.window
  let dr = d.dropRect(r, i)
  let box = rect(dr.x, dr.y, dr.w, FileBoxH)
  let inner = rect(box.x + 1, box.y + 1, box.w - 2, box.h - 2)
  let id = "pk-" & $i
  let focused = ui.tabStop(id, box)
  let hov = ui.hover(inner)
  let ctrl = w.ctrlDown
  let shift = w.shiftDown
  template n(): int = d.files[i].len
  proc fileAt(y: float32): int = int(floor((y - inner.y + d.fileScroll[i]) / FileRowH))

  if hov and ui.scroll() != 0:
    d.fileScroll[i] += ui.scroll() * FileRowH / 10 * 3
    ui.scrollConsumed = true
  if hov and ui.pressed():
    ui.consumeClick()
    ui.navId = id
    ui.focusId = ""
    d.openRow = -1
    let k = fileAt(ui.mouse.y)
    d.pressedOn = -1
    if k >= 0 and k < n:
      if ctrl:
        d.marked[i][k] = not d.marked[i][k]
        d.cursor[i] = k
        d.anchor[i] = k
      elif shift and d.anchor[i] >= 0 and d.anchor[i] < n:
        for m in d.marked[i].mitems: m = false
        for j in min(k, d.anchor[i]) .. max(k, d.anchor[i]): d.marked[i][j] = true
        d.cursor[i] = k
      elif d.marked[i][k]:
        d.pressedOn = k
        d.cursor[i] = k
        d.anchor[i] = k
      else: d.selectOnly(i, k)
      d.dragRow = i
      d.dragFrom = ui.mouse
      d.dragging = false
    else: d.selectOnly(i, -1)

  # Dragging the selected files: a line shows where they'd go; past the
  # list's top or bottom it scrolls.
  if d.dragRow == i:
    if ui.down():
      if not d.dragging and (ui.mouse - d.dragFrom).length > 4 and d.marked[i].anyIt(it):
        d.dragging = true
        d.pressedOn = -1
      if d.dragging:
        if ui.mouse.y < inner.y: d.fileScroll[i] -= max(2'f32, (inner.y - ui.mouse.y) / 3)
        elif ui.mouse.y > inner.y + inner.h:
          d.fileScroll[i] += max(2'f32, (ui.mouse.y - inner.y - inner.h) / 3)
        d.dropAt = clamp(int(round((clamp(ui.mouse.y, inner.y, inner.y + inner.h) - inner.y +
          d.fileScroll[i]) / FileRowH)), 0, n)
    else:
      if d.dragging: d.moveMarked(i, d.dropAt)
      elif d.pressedOn >= 0 and d.pressedOn < n: d.selectOnly(i, d.pressedOn)
      d.dragRow = -1
      d.dragging = false
      d.pressedOn = -1

  if focused and ui.focusId.len == 0 and d.openRow < 0 and n > 0:
    let p = w.buttonPressed
    let c = d.cursor[i]
    if ctrl and p[KeyA]:
      for m in d.marked[i].mitems: m = true
    elif p[KeyDelete]: d.removeMarked(i)
    elif ctrl and shift and p[KeyUp]: d.stepMarked(i, -1)
    elif ctrl and shift and p[KeyDown]: d.stepMarked(i, 1)
    elif ctrl and shift and p[KeyHome]: d.moveMarked(i, 0)
    elif ctrl and shift and p[KeyEnd]: d.moveMarked(i, n)
    elif not ctrl:
      var k = -2
      if p[KeyUp]: k = if c < 0: n - 1 else: max(0, c - 1)
      elif p[KeyDown]: k = if c < 0: 0 else: min(n - 1, c + 1)
      elif p[KeyHome]: k = 0
      elif p[KeyEnd]: k = n - 1
      if k >= 0 and shift and d.anchor[i] in 0 ..< n:
        # Shift extends the selection from where it started.
        for m in d.marked[i].mitems: m = false
        for j in min(k, d.anchor[i]) .. max(k, d.anchor[i]): d.marked[i][j] = true
        d.cursor[i] = k
        d.revealFile(i, k)
      elif k >= 0: d.selectOnly(i, k)
  let contentH = n.float32 * FileRowH
  let maxScroll = max(0'f32, contentH - inner.h)
  d.fileScroll[i] = clamp(d.fileScroll[i], 0, maxScroll)

  ui.rect(box, colBackground)
  ui.border(box, if d.dragging and d.dragRow == i: colAccent elif hov: colTextDim else: colBorder)
  if focused: ui.focusRing(box)
  let outerClip = ui.hitClip
  ui.hitClip = inner
  ui.sk.pushClipRect(inner)
  if n == 0:
    ui.textIn("Add files, or drop them here", inner, colTextDim, h = CenterAlign)
  const NumW = 34'f32
  let numW = max(NumW, ui.textSize($n, FontSmall).x + 14)
  for k in max(0, int(d.fileScroll[i] / FileRowH)) ..< n:
    let rr = rect(inner.x, inner.y + k.float32 * FileRowH - d.fileScroll[i], inner.w, FileRowH)
    if rr.y > inner.y + inner.h: break
    let f = d.files[i][k]
    let sel = d.marked[i][k]
    if sel: ui.rect(rr, colAccent)
    elif ui.hover(rr) and not d.dragging: ui.rect(rr, colHover)
    if focused and ui.navVisible and k == d.cursor[i]: ui.border(rr, colTextDim)
    let fi = info(f)
    var detail = "…"
    if fi.known and fi.duration <= 0 and fi.width == 0: detail = "unknown"
    elif fi.known:
      detail = (if fi.width > 0 and fi.height > 0: $fi.width & "×" & $fi.height else: "no picture") &
        (if fi.duration > 0: "    " & fmtTime(fi.duration, dur = fi.duration) else: "")
    let dw = ui.textSize(detail, FontSmall).x
    let dimCol = if sel: colOnAccent else: colTextDim
    ui.textIn($(k + 1), rect(rr.x, rr.y, numW - 10, FileRowH), dimCol, FontSmall, h = RightAlign)
    let nameW = rr.w - numW - dw - 22
    ui.textIn(ui.ellipsize(f.extractFilename, nameW), rect(rr.x + numW, rr.y, nameW, FileRowH),
      if sel: colOnAccent elif fi.known or f.fileExists: colText else: colError)
    ui.textIn(detail, rect(rr.x + rr.w - dw - 10, rr.y, dw, FileRowH), dimCol, FontSmall)
    if not d.dragging: ui.tip(rr, f)
  if d.dragging and d.dragRow == i:
    let y = inner.y + d.dropAt.float32 * FileRowH - d.fileScroll[i]
    ui.rect(rect(inner.x + 2, y - 1, inner.w - 4, 2), colAccentHover)
  ui.sk.popClipRect()
  ui.hitClip = outerClip
  if maxScroll > 0:
    let th = max(16'f32, inner.h * inner.h / contentH)
    let ty = inner.y + (inner.h - th) * (d.fileScroll[i] / maxScroll)
    ui.rect(rect(box.x + box.w - 4, ty, 3, th), colTrack)

  # Buttons under the list, and how many files and how long in all.
  let by = box.y + box.h + 8
  if ui.textButton(id & "-add", rect(dr.x, by, 76, FileBarH), "Add..."):
    result = paAddFiles
    d.addRow = i
  let any = d.marked[i].anyIt(it)
  var bx = dr.x + 84
  for (name, icon, tip) in [("remove", "trash16", "Remove the selected files (Delete)"),
                            ("up", "chevup16", "Move the selected files up (Ctrl+Shift+Up)"),
                            ("down", "chevdown16", "Move the selected files down (Ctrl+Shift+Down)")]:
    let br = rect(bx, by, 30, FileBarH)
    ui.rect(br, colPanelRaised)
    ui.border(br, colBorder)
    if ui.iconButton(id & "-" & name, br, icon, tip, enabled = any):
      case name
      of "remove": d.removeMarked(i)
      of "up": d.stepMarked(i, -1)
      else: d.stepMarked(i, 1)
      ui.navId = id
    bx += 34
  if ui.textButton(id & "-sort", rect(bx + 4, by, 64, FileBarH), "Sort"):
    d.sortFiles(i)
  ui.tip(rect(bx + 4, by, 64, FileBarH),
    "Sort by file name, or the other way when sorted already; only the selected files when two or more are")
  let sx = bx + 76
  ui.textIn(ui.ellipsize(fileSummary(d.files[i], info), dr.x + dr.w - sx, FontSmall),
    rect(sx, by, dr.x + dr.w - sx, FileBarH), colTextDim, FontSmall, h = RightAlign)

proc draw*(d: PickDialog, ui: Ui, r: Rect, choices: seq[TimeChoice],
    info: proc (path: string): ListedFile): PickAction =
  ## choices is what timestamp rows pick from (timeChoices), at this frame:
  ## each row keeps its time as the list changes. info tells what file lists
  ## show of a file.
  let w = ui.window
  for i, row in d.rows:
    if row.isTimestamp: d.picks[i] = choices.locate(d.chosen[i])
  let noField = ui.focusId.len == 0  # else Escape belongs to the value field
  let contentH = choices.entryY(choices.len)
  var escUsed = false

  # An open list takes the pointer; a press elsewhere closes it.
  var lr: Rect
  if d.openRow >= 0:
    lr = d.listRect(r, d.openRow, contentH)
    let over = ui.mouse.inside(lr)
    if w.buttonPressed[KeyEscape]:
      d.openRow = -1
      escUsed = true
    elif ui.pressed() and not over:
      d.openRow = -1
      ui.consumeClick()
    elif over:
      if ui.scroll() != 0:
        d.listScroll += ui.scroll() * RowH
        ui.scrollConsumed = true
      ui.captured = true
    d.listScroll = clamp(d.listScroll, 0, max(0'f32, contentH - (lr.h - 2)))
  let open = d.openRow

  ui.textIn(ui.ellipsize("Variables of " & d.cmd.title & " for this run.", r.w - 32, FontSmall),
    rect(r.x + 16, r.y + 12, r.w - 32, 20), colTextDim, FontSmall)
  # Rectangle rows end in an icon: hovering it lights the icons of the rows
  # its rectangle sets.
  proc iconRect(dr: Rect): Rect = rect(dr.x + dr.w - 28, dr.y, 28, dr.h)
  var hovRect = 0
  for i, row in d.rows:
    if row.isRect and ui.hover(iconRect(d.dropRect(r, i))): hovRect = row.rect
  for i, row in d.rows:
    let dr = d.dropRect(r, i)
    ui.textIn(ui.ellipsize(row.name, PickLabelW - 12),
      rect(r.x + 16, dr.y, PickLabelW - 12, dr.h), colText)
    let id = "pk-" & $i
    if row.isList:
      let a = d.fileList(ui, r, i, info)
      if a != paNone: result = a
      continue
    if row.isRect:
      discard ui.textField(id, rect(dr.x, dr.y, dr.w - 32, dr.h), d.texts[i], "number")
      d.texts[i] = if ui.focusId == id: d.texts[i].mathOnly else: d.texts[i].mathDigits
      let ir = iconRect(dr)
      let hov = ui.hover(ir)
      if hov and ui.pressed():
        ui.consumeClick()
        ui.pressId = id & "-rect"
      if hov and ui.pressed(MouseRight): d.crossed[i] = not d.crossed[i]
      if hov and ui.released() and ui.pressId == id & "-rect":
        result = paDraw
        d.drawRequest = row.rect
      let lit = not d.crossed[i] and (row.rect == hovRect or row.rect == d.drawing)
      if hov: ui.rect(ir, if ui.down() and ui.pressId == id & "-rect": colPressed else: colHover)
      ui.icon(if d.crossed[i]: "rectoff20" else: "rect20", ir.xy + ir.wh / 2,
        if lit: colRect elif d.crossed[i]: colTextDisabled else: colTextDim)
      ui.tip(ir, if d.crossed[i]: "Kept as typed; right-click to let the drawn rectangle set it"
                 else: "Draw the rectangle on the video; right-click to keep this value")
      continue
    if row.isPath:
      discard ui.textField(id, rect(dr.x, dr.y, dr.w - 32, dr.h), d.texts[i], "path")
      if ui.iconButton(id & "-browse", iconRect(dr), "folder20", "Choose where to save"):
        result = paBrowse
        d.browseRow = i
      let pr = vec2(dr.x, dr.y + dr.h + 4)
      discard ui.checkbox(id & "-play", pr, "Open in a new player when finished", d.plays[i])
      ui.tip(rect(pr.x, pr.y, dr.w, 22), "Once the command succeeds, plays " &
        (if d.texts[i].strip.len > 0: d.texts[i].strip.extractFilename else: "the file") &
        " in a player of its own")
      continue
    if not row.isTimestamp:
      discard ui.textField(id, dr, d.texts[i], "empty")
      continue
    let hov = ui.hover(dr)
    let focused = ui.tabStop(id, dr)
    if hov and ui.pressed():
      ui.consumeClick()
      ui.navId = id
      d.openRow = if open == i: -1 else: i
      # Start with the chosen time in view.
      if d.openRow >= 0: d.centerOn(r, i, choices)
    if focused and ui.focusId.len == 0 and d.openRow < 0:
      if w.buttonPressed[KeyUp]: d.choose(i, choices, choices.stepChoice(d.picks[i], -1))
      if w.buttonPressed[KeyDown]: d.choose(i, choices, choices.stepChoice(d.picks[i], 1))
      if w.buttonPressed[KeySpace]:
        d.openRow = i
        d.centerOn(r, i, choices)
    ui.rect(dr, colBackground)
    ui.border(dr, if open == i: colAccent elif hov: colTextDim else: colBorder)
    if focused: ui.focusRing(dr)
    let (label, time) = choiceText(choices[d.picks[i]])
    let tw = ui.textSize(time, FontSmall).x
    ui.textIn(ui.ellipsize(label, dr.w - tw - 52), rect(dr.x + 8, dr.y, dr.w - tw - 52, dr.h),
      colText)
    ui.textIn(time, rect(dr.x + dr.w - tw - 34, dr.y, tw, dr.h), colTextDim, FontSmall)
    ui.icon("expand16", vec2(dr.x + dr.w - 15, dr.y + dr.h / 2),
      if hov: colText else: colTextDim)

  ui.rect(rect(r.x + 1, r.y + r.h - 50, r.w - 2, 1), colBorder)
  let by = r.y + r.h - 40
  if d.error.len > 0:
    ui.textIn(ui.ellipsize(d.error, r.w - 250), rect(r.x + 16, by, r.w - 250, 30), colError)
  let keys = noField and d.openRow < 0
  let cancel = ui.textButton("pk-cancel", rect(r.x + r.w - 212, by, 92, 30), "Cancel")
  var run = ui.textButton("pk-run", rect(r.x + r.w - 112, by, 92, 30), "Run", primary = true)
  if d.runRequested:
    d.runRequested = false
    run = true
  # Enter runs, also from a value field.
  if d.openRow < 0 and open < 0 and not ui.enterUsed and
     (w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter]):
    run = true
  if cancel or keys and not escUsed and w.buttonPressed[KeyEscape]: result = paCancel
  elif run:
    d.error = ""
    for i, row in d.rows:
      if row.isList and d.files[i].len == 0:
        d.error = "Add files to “" & row.name & "” first."
        break
    if d.error.len == 0: result = paRun

  # The open list, over everything.
  if d.openRow >= 0 and d.openRow == open:
    ui.captured = false
    ui.sk.pushLayer(PopupsLayer)
    ui.rect(rect(lr.xy + vec2(3, 4), lr.wh), colShadow)
    ui.rect(lr, colPopup)
    ui.border(lr, colAccent)
    let inner = rect(lr.x + 1, lr.y + 1, lr.w - 2, lr.h - 2)
    let outerClip = ui.hitClip
    ui.hitClip = inner
    ui.sk.pushClipRect(inner)
    var y = inner.y - d.listScroll
    for k, ch in choices:
      let rr = rect(inner.x, y, inner.w, ch.entryH)
      y += rr.h
      if rr.y + rr.h < inner.y or rr.y > inner.y + inner.h: continue
      if ch.sep:
        ui.rect(rect(rr.x + 8, rr.y + rr.h / 2, rr.w - 16, 1), colBorder)
        continue
      if ch.note:
        let lines = ch.label.splitLines
        for j, line in lines:
          ui.textIn(ui.ellipsize(line, rr.w - 16, FontSmall),
            rect(rr.x + 8, rr.y + 4 + j.float32 * 16, rr.w - 16, 16), colTextDim, FontSmall)
        continue
      let hov = ui.hover(rr)
      let sel = k == d.picks[open]
      if sel: ui.rect(rr, colAccent)
      elif hov: ui.rect(rr, colHover)
      let (label, time) = choiceText(ch)
      let tw = ui.textSize(time, FontSmall).x
      ui.textIn(ui.ellipsize(label, rr.w - tw - 30), rect(rr.x + 8, rr.y, rr.w - tw - 30, RowH),
        if sel: colOnAccent else: colText)
      ui.textIn(time, rect(rr.x + rr.w - tw - 10, rr.y, tw, RowH),
        if sel: colOnAccent else: colTextDim, FontSmall)
      if hov and ui.pressed():
        ui.consumeClick()
        d.choose(open, choices, k)
        d.openRow = -1
    ui.sk.popClipRect()
    ui.hitClip = outerClip
    if contentH > inner.h:
      let th = max(16'f32, inner.h * inner.h / contentH)
      let ty = inner.y + (inner.h - th) * (d.listScroll / (contentH - inner.h))
      ui.rect(rect(lr.x + lr.w - 4, ty, 3, th), colTrack)
    ui.sk.popLayer()

  if result == paNone: discard ui.tabNavigate()
