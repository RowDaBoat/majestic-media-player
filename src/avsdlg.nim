## The video frame menu's Visualizer Preset > Visualizers...: every preset in
## a grid, with a checkbox each (presets turned off leave the menu's list and
## are never stepped to: Next, Previous, Random) and what the preset holds in
## columns resized by their header edges, and a rating of up to five stars
## set a quarter of a star at a time. A header click sorts by its column
## (again: the other way); by Added, oldest first, is the order presets were
## listed in. Right-clicks ask the app for a context menu (aaContext).
## Highlighting a row switches the
## visualizer to it; Add... copies more .avs files into the presets folder,
## Add Folder... a folder's (and its subfolders', with Include subfolders), Remove takes them out of
## the list (built-in ones can only be turned off). Frame Rate is how many
## times a second a preset steps (the context menu sets it). Beat threshold and
## Sensitivity, at the bottom, are Options' (how loud the sound must be for
## beats, how readily they come). The search field (Ctrl+F)
## shows only the presets matching it: by name, author or file name, or by
## rating ("4 stars", ">=3.5", "***", "unrated"; see `parseSearch`). The app
## does the changes (`AvsAction`), so this only draws and reports.

import std/[os, strutils, sequtils, tables, sets, times, strformat, math, algorithm]
from std/unicode import nil
import silky, vmath, bumpy, pixie
import ui, theme, avsview
import avs/[list, effects, misc]

type
  PresetMeta = object
    author, comment, version, size, modified, location: string
    effects: int              ## -1: not a preset that could be read
    bytes: int
    mtime: float              ## seconds since 1970; 0: none (built-in)

  AvsAction* = enum
    aaNone, aaSelect, aaToggle, aaAdd, aaAddDir, aaRemove, aaPrefs, aaRate, aaBeat, aaContext, aaClose

  AvsContext* = enum
    acRows, acHeader, acEmpty   ## what was right-clicked: highlighted rows, the header, nothing

  AvsDialog* = ref object
    sel*: seq[string]         ## the rows highlighted, by preset
    anchor: string            ## where a Shift+click range starts
    pick*: string             ## with aaSelect: the preset to switch to
    toggled*: seq[string]     ## with aaToggle: presets to turn on or off
    colWidths*: Table[string, float]  ## columns resized by hand
    ratings*: Table[string, int]  ## by preset: quarters of a star, 1 to 20
    rated*: seq[string]       ## with aaRate: presets given `rating` (0: none)
    rating*: int
    added*: Table[string, float]  ## by preset: when it was listed (seconds since 1970)
    sortKey*: string          ## the column sorted by
    sortDesc*: bool
    search*: string           ## the search field's text: only presets matching it are shown
    subfolders*: bool         ## Add Folder... looks into subfolders too
    beatThreshold*: float     ## the level beats need, % of Winamp's (the app's
                              ## avsBeatThreshold); aaBeat when changed here
    beatSensitivity*: float   ## how readily beats come, % of Winamp's (avsBeatSensitivity)
    rows*: seq[string]        ## the presets in the order shown (last frame)
    ctx*: AvsContext          ## with aaContext: what for, and where (window units)
    ctxPos*: Vec2
    scroll: float32
    reveal: bool              ## scroll the highlighted row into view
    center: bool              ## with reveal: centered, if out of view (jumpTo)
    colDrag: string
    colDragFrom: (float32, float32)
    resizeCursor: bool
    dragBar: bool
    dragBarFrom: (float32, float32)
    meta: Table[string, PresetMeta]

  SearchTerm* = object
    ## One word of the search: text a field holds, or a range of ratings.
    field*: string            ## "": the name, author or file name; else "name", "title", "author", "file"
    text*: string             ## lowercase
    rating*: bool             ## a rating from `lo` to `hi`, in quarters of a star
    lo*, hi*: int

const
  AvsSize* = ivec2(920, 580)
  AvsMinSize* = ivec2(720, 320)  ## the smallest the window can be resized to
  RowH = 24'f32
  CheckW = 30'f32
  MinCol = 50'f32
  BarW = 10'f32
  StarW = 16'f32             ## a star's icon; its points span 2 to 22 of 24
  StarPitch = 18'f32         ## the narrowest a star's slot gets
  StarL = StarW * 2 / 24
  StarGlyphW = StarW * 20 / 24
  StarsW = StarPitch * 5
  Steps = 4                  ## a rating's steps per star: quarters
  Columns = [("name", "Name", 220'f32), ("rating", "Rating", 140'f32), ("author", "Author", 96'f32),
    ("effects", "Effects", 60'f32), ("fps", "Frame Rate", 84'f32), ("comment", "Comment", 170'f32),
    ("size", "Size", 70'f32), ("modified", "Modified", 124'f32), ("added", "Added", 124'f32),
    ("location", "Location", 0'f32)]

proc columnTitles*(): seq[(string, string)] =
  ## Every column's key and title, in order (for the app's Sort By menu).
  for (key, title, _) in Columns: result.add (key, title)

var registered: bool

proc newAvsDialog*(widths: Table[string, float], ratings: Table[string, int],
                   added: Table[string, float], sortKey: string, sortDesc: bool,
                   subfolders: bool): AvsDialog =
  AvsDialog(colWidths: widths, ratings: ratings, added: added, subfolders: subfolders,
    sortKey: if Columns.anyIt(it[0] == sortKey): sortKey else: "added", sortDesc: sortDesc)

# --- metadata ------------------------------------------------------------------

proc countEffects(l: EffectList, comment: var string): int =
  ## Every effect in the list and its lists; the first comment's text.
  for fx in l.children:
    if fx of EffectList: result += countEffects(EffectList(fx), comment) + 1
    else:
      inc result
      if fx of Comment and comment.len == 0: comment = Comment(fx).text.strip

proc authorOf(name: string): string =
  ## "justin - joy": justin.
  let dash = name.find(" - ")
  if dash > 0: name[0 ..< dash].strip else: ""

proc titleOf(name: string): string =
  ## "justin - joy": joy; a name without an author is all title.
  let dash = name.find(" - ")
  if dash > 0: name[dash + 3 .. ^1].strip else: name

proc fmtSize(n: int): string =
  if n < 1024: &"{n} B"
  elif n < 1024 * 1024: formatFloat(n / 1024, ffDecimal, 1) & " KiB"
  else: formatFloat(n / (1024 * 1024), ffDecimal, 1) & " MiB"

proc metaOf(d: AvsDialog, id, dir: string): PresetMeta =
  ## What the preset holds, read once: its settings only, nothing runs.
  if id in d.meta: return d.meta[id]
  if not registered:
    registerAll()
    registered = true
  result.author = authorOf(presetName(id))
  let data = presetData(id)
  result.effects = -1
  if data.len > 24 and data.startsWith("Nullsoft AVS Preset 0."):
    result.version = data[20 .. 22]
    let root = loadPreset(data.toOpenArrayByte(0, data.len - 1))
    if root != nil: result.effects = countEffects(root, result.comment)
  result.comment = result.comment.multiReplace(("\r\n", " · "), ("\n", " · "), ("\r", " · "))
  if id.isBuiltin:
    result.location = "Built-in"
    result.bytes = data.len
    result.size = fmtSize(data.len)
  else:
    try:
      result.bytes = getFileSize(id).int
      result.size = fmtSize(result.bytes)
      let t = getLastModificationTime(id)
      result.mtime = t.toUnixFloat
      result.modified = t.format("yyyy-MM-dd HH:mm")
    except OSError: discard
    let home = getHomeDir().strip(leading = false, chars = {DirSep})
    result.location =
      if dir.len > 0 and id.startsWith(dir & DirSep):
        let rel = id[dir.len + 1 .. ^1].parentDir
        "Presets folder" & (if rel.len > 0 and rel != ".": DirSep & rel else: "")
      elif id.startsWith(home & DirSep): "~" & id[home.len .. ^1].parentDir
      else: id.parentDir
  d.meta[id] = result

proc jumpTo*(d: AvsDialog, id: string) =
  ## Highlights preset id and scrolls the list to it (centered, unless it's
  ## already in view) on the next draw; nothing with id "".
  d.sel = if id.len > 0: @[id] else: @[]
  d.anchor = id
  d.reveal = id.len > 0
  d.center = d.reveal

proc forget*(d: AvsDialog) =
  ## Reads the presets' metadata again (the list changed).
  d.meta.clear()

# --- search --------------------------------------------------------------------

proc fileOf(id: string): string =
  ## The preset's file name; a built-in one's, the file it was built in from.
  if id.isBuiltin: id[BuiltinPrefix.len .. ^1] else: id.extractFilename

proc ratingSpec(spec: string, starred: bool, t: var SearchTerm): bool =
  ## Reads `spec` as a range of ratings: "***" (or ★★★), "4 stars" (4 to
  ## 4.75), "3.5*" (exactly), "4+" (4 or more), ">=3.5", "<2". A bare number
  ## is one only when `starred`, after "rating:" or before "stars"; without,
  ## it's text a name may hold ("brainbug 2").
  var s = spec.replace("★", "*").toLowerAscii
  if s.len > 0 and s.allIt(it == '*'):
    let n = min(s.len, 5)
    (t.rating, t.lo, t.hi) = (true, n * Steps, min(5 * Steps, n * Steps + Steps - 1))
    return true
  var op = ""
  for o in [">=", "<=", "=>", "=<", ">", "<", "="]:
    if s.startsWith(o):
      op = o
      s = s[o.len .. ^1]
      break
  var marked = starred or op.len > 0
  var plus = false
  var trimmed = true
  while trimmed:  # "4+ stars", "4*+": the marks in any order
    trimmed = false
    for suf in ["stars", "star", "*", "+"]:
      if s.len > suf.len and s.endsWith(suf):
        s.setLen s.len - suf.len
        if suf == "+": plus = true
        marked = true
        trimmed = true
  if not marked or s.len == 0 or not s.allIt(it in Digits + {'.'}) or s.count('.') > 1 or
     not s.anyIt(it in Digits):
    return false
  let q = int(round(parseFloat(s) * Steps))
  let whole = '.' notin s
  case op
  of ">": (t.lo, t.hi) = (q + 1, 5 * Steps)
  of ">=", "=>": (t.lo, t.hi) = (q, 5 * Steps)
  of "<": (t.lo, t.hi) = (0, q - 1)
  of "<=", "=<": (t.lo, t.hi) = (0, q)
  else:
    if plus: (t.lo, t.hi) = (q, 5 * Steps)
    elif whole and q > 0: (t.lo, t.hi) = (q, q + Steps - 1)  # 4 stars: 4 to 4.75
    else: (t.lo, t.hi) = (q, q)                                # 0 stars: unrated
  (t.lo, t.hi) = (max(t.lo, 0), min(t.hi, 5 * Steps))
  t.rating = true
  true

proc parseSearch*(s: string): seq[SearchTerm] =
  ## The search's words, every one of which a preset must match. A word is
  ## text found in the preset's name (author and title) or file name, any
  ## case; "quotes" keep a phrase together. "author:", "title:", "name:" and
  ## "file:" look in that alone; a rating (see `ratingSpec`), "rating:N",
  ## "unrated" and "rated" pick presets by their stars.
  var words: seq[string]
  var cur = ""
  var quoted = false
  for ch in s:
    if ch == '"': quoted = not quoted
    elif ch in Whitespace and not quoted:
      if cur.len > 0: words.add cur
      cur = ""
    else: cur.add ch
  if cur.len > 0: words.add cur
  const Fields = [("author", "author"), ("by", "author"), ("title", "title"), ("name", "name"),
    ("file", "file"), ("filename", "file"), ("rating", "rating"), ("rated", "rating"), ("stars", "rating")]
  var i = 0
  while i < words.len:
    var w = words[i]
    inc i
    var t: SearchTerm
    let colon = w.find(':')
    let lw = w.toLowerAscii
    var field = ""
    if colon > 0:
      for (k, f) in Fields:
        if lw[0 ..< colon] == k: field = f
      if field.len > 0:
        w = w[colon + 1 .. ^1]
        if w.len == 0 and i < words.len:  # "author: justin"
          w = words[i]
          inc i
    elif lw.startsWith("rating") and lw.len > 6 and lw[6] in {'<', '>', '='}:  # rating>=4
      field = "rating"
      w = w[6 .. ^1]
    if w.len == 0: continue
    let lv = w.toLowerAscii
    if field.len == 0 and lv in ["unrated", "norating"]:
      result.add SearchTerm(rating: true, lo: 0, hi: 0)
      continue
    if field.len == 0 and lv == "rated":
      result.add SearchTerm(rating: true, lo: 1, hi: 5 * Steps)
      continue
    if field.len == 0 or field == "rating":
      # "4 stars": the number takes the next word along.
      let next = if i < words.len: words[i].toLowerAscii.replace("★", "*") else: ""
      let starsNext = next in ["star", "stars", "*"]
      if ratingSpec(w, field == "rating" or starsNext, t):
        if starsNext: inc i
        result.add t
        continue
      if field == "rating":
        if lv in ["none", "no", "0"]: result.add SearchTerm(rating: true, lo: 0, hi: 0)
        else: result.add SearchTerm(rating: true, lo: 1, hi: 0)  # nothing matches it
        continue
    result.add SearchTerm(field: field, text: unicode.toLower(w))

proc matches*(terms: seq[SearchTerm], id: string, rating: int): bool =
  ## Whether the preset `id`, rated `rating` quarters of a star, matches every term.
  let name = unicode.toLower(presetName(id))
  let file = unicode.toLower(fileOf(id))
  for t in terms:
    let ok =
      if t.rating: rating in t.lo .. t.hi
      else:
        case t.field
        of "name": t.text in name
        of "title": t.text in titleOf(name)
        of "author": t.text in authorOf(name)
        of "file": t.text in file
        else: t.text in name or t.text in file
    if not ok: return false
  true

proc cellText(d: AvsDialog, v: AvsView, m: PresetMeta, id, col: string): string =
  case col
  of "fps": $v.rateOf(id) & " fps"
  of "added":
    let t = d.added.getOrDefault(id)
    if t > 0: fromUnixFloat(t).local.format("yyyy-MM-dd HH:mm") else: ""
  of "name": presetName(id)
  of "author": m.author
  of "effects": (if m.effects >= 0: $m.effects else: "not a preset")
  of "comment": m.comment
  of "size": m.size
  of "modified": m.modified
  of "location": m.location
  else: ""

proc sorted(d: AvsDialog, v: AvsView, ids: seq[string]): seq[string] =
  ## The presets `ids` in the order shown: by the sort column, ties in the order
  ## they're listed. By Added, presets with the same date (or none: built-in)
  ## keep their listed order too, turned around with the rest.
  let presets = v.presets
  var idx = initTable[string, int]()
  for i, id in presets: idx[id] = i
  let key = d.sortKey
  let desc = d.sortDesc
  proc cmpBy(a, b: string): int =
    case key
    of "name": cmpIgnoreCase(presetName(a), presetName(b))
    of "rating": cmp(d.ratings.getOrDefault(a), d.ratings.getOrDefault(b))
    of "added": cmp(d.added.getOrDefault(a), d.added.getOrDefault(b))
    of "fps": cmp(v.rateOf(a), v.rateOf(b))
    else:
      let (ma, mb) = (d.metaOf(a, v.dir), d.metaOf(b, v.dir))
      case key
      of "effects": cmp(ma.effects, mb.effects)
      of "size": cmp(ma.bytes, mb.bytes)
      of "modified": cmp(ma.mtime, mb.mtime)
      else: cmpIgnoreCase(d.cellText(v, ma, a, key), d.cellText(v, mb, b, key))
  result = ids
  result.sort(proc (a, b: string): int =
    result = cmpBy(a, b)
    if desc: result = -result
    if result == 0:
      result = cmp(idx[a], idx[b])
      if desc and key == "added": result = -result)

# --- drawing -------------------------------------------------------------------

type Col = tuple[key, title: string, x, w: float32]

proc layout(d: AvsDialog, r: Rect): seq[Col] =
  ## Every column as wide as resized, else its default; the last fills the
  ## rest. Each keeps MinCol, the last too, by narrowing the others' share.
  var x = r.x + CheckW
  for i, (key, title, def) in Columns:
    var w = d.colWidths.getOrDefault(key, def).float32
    if i == Columns.high: w = max(MinCol, r.x + r.w - x)
    else: w = clamp(w, MinCol, max(MinCol, r.x + r.w - x - MinCol * float32(Columns.high - i)))
    result.add (key, title, x, w)
    x += w

proc starPitch(cellW: float32): float32 =
  ## Each star's slot: the column's width shared out evenly, so a wider
  ## column gives every quarter more room to aim at.
  max(StarPitch, (cellW - 16) / 5)

proc ratingAt(x0, pitch, mx: float32): int =
  ## The rating a click at `mx` gives, the slots starting at `x0`: the
  ## quarters of a slot up to the pointer, rounded up; left of them, none.
  let rel = mx - x0
  if rel < 0: return 0
  let i = min(4, int(rel / pitch))
  let f = clamp((rel - i.float32 * pitch) / pitch, 0, 1)
  clamp(i * Steps + int(ceil(f * Steps - 1e-3)), 0, 5 * Steps)

proc fmtRating*(n: int): string =
  ## "3.75 stars"
  var s = formatFloat(n / Steps, ffDecimal, 2)
  s = s.strip(leading = false, chars = {'0'}).strip(leading = false, chars = {'.'})
  s & (if n == Steps: " star" else: " stars")

proc stars(ui: Ui, x0, pitch, cy: float32, n: int, fill, empty: ColorRGBX) =
  ## Five stars, each centered in its slot, filled like a bar: a quarter of
  ## a star for each of `n`.
  for i in 0 ..< 5:
    let x = floor(x0 + (i.float32 + 0.5) * pitch - StarW / 2)
    let c = vec2(x + StarW / 2, cy)
    let part = clamp(n - i * Steps, 0, Steps)
    if part < Steps: ui.icon("star16", c, empty)
    if part == Steps: ui.icon("star16", c, fill)
    elif part > 0:
      ui.sk.pushClipRect(rect(x, cy - StarW, StarL + StarGlyphW * part.float32 / Steps, StarW * 2))
      ui.icon("star16", c, fill)
      ui.sk.popClipRect()

proc checkBox(ui: Ui, c: Vec2, on: bool, hov: bool) =
  let box = rect(c.x - 8, c.y - 8, 16, 16)
  ui.rect(box, if on: colAccent else: colPanelRaised)
  ui.border(box, if hov: colAccent else: colBorder)
  if on: ui.icon("check16", c, colOnAccent)

proc draw*(d: AvsDialog, ui: Ui, r: Rect, v: AvsView): AvsAction =
  let w = ui.window
  let presets = v.presets
  let ctrl = w.buttonDown[KeyLeftControl] or w.buttonDown[KeyRightControl]
  let enter = w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter]
  let subR = rect(r.x + 256, r.y + 15, 22 + ui.textSize("Include subfolders").x, 22)
  let remR = rect(subR.x + subR.w + 12, r.y + 12, 104, 28)
  # The search, first so what's typed shows in the rows the same frame: the
  # rest of the top row up to a third of the window, Ctrl+F to type in it.
  # Esc empties it first, then (empty) closes the window; Enter and Down go
  # on to the rows.
  const SearchId = "av-search"
  if ctrl and w.buttonPressed[KeyF]:
    ui.focusId = SearchId
    ui.focusFresh = true
  let wasSearching = ui.focusId == SearchId
  let searchW = min(clamp(r.w / 3, 200, 320), r.x + r.w - 16 - (remR.x + remR.w + 16))
  let clearR = rect(r.x + r.w - 16 - 28, r.y + 12, 28, 28)
  let fieldR = rect(r.x + r.w - 16 - searchW, r.y + 12, searchW - 30, 28)
  let before = d.search
  const Placeholder = "Search name, author, file, rating"
  discard ui.textField(SearchId, fieldR, d.search,
    if ui.textSize(Placeholder).x + 16 <= fieldR.w: Placeholder else: "Search")
  ui.tip(fieldR, "Name, author or file name; ratings: 4 stars, 3.5*, >=4, 4+, ***, unrated (Ctrl+F)")
  if d.search.len > 0 and ui.iconButton("av-search-clear", clearR, "close16", "Clear the search (Esc)"):
    d.search = ""
  elif d.search.len == 0:
    ui.icon("search16", vec2(clearR.x + clearR.w / 2, clearR.y + clearR.h / 2), colTextDim)
  if w.buttonPressed[KeyEscape] and d.search.len > 0 and (wasSearching or ui.focusId.len == 0):
    d.search = ""
    ui.focusId = ""
  if wasSearching and (w.buttonPressed[KeyDown] or w.buttonPressed[KeyPageDown]):
    ui.focusId = ""  # the rows' keys take it from here
  if d.search != before:
    d.scroll = 0
    d.reveal = true
  let terms = parseSearch(d.search)
  let shown = if terms.len == 0: presets
              else: presets.filterIt(terms.matches(it, d.ratings.getOrDefault(it)))
  d.sel.keepItIf(it in shown)
  # Buttons.
  if ui.textButton("av-add", rect(r.x + 16, r.y + 12, 104, 28), "Add..."):
    result = aaAdd
  ui.tip(rect(r.x + 16, r.y + 12, 104, 28), "List .avs files")
  let dirR = rect(r.x + 126, r.y + 12, 120, 28)
  if ui.textButton("av-adddir", dirR, "Add Folder..."): result = aaAddDir
  ui.tip(dirR, if d.subfolders: "List every .avs file in a folder and its subfolders"
               else: "List every .avs file in a folder")
  if ui.checkbox("av-subdirs", vec2(subR.x, subR.y), "Include subfolders", d.subfolders):
    result = aaPrefs
  ui.tip(subR, "Add Folder... also looks into the folder's subfolders")
  let removable = d.sel.filterIt(not it.isBuiltin)
  if removable.len > 0:
    if ui.textButton("av-remove", remR, "Remove"): result = aaRemove
  else:
    ui.rect(remR, colPanel)
    ui.border(remR, colBorder)
    ui.textIn("Remove", remR, colTextDisabled, h = CenterAlign)
  ui.tip(remR, if d.sel.len > 0 and removable.len == 0: "Built-in presets can be turned off, not removed"
               else: "Take the highlighted presets out of the list (their files stay)")
  let on = shown.countIt(it notin v.disabled)

  # The grid.
  let grid = rect(r.x + 16, r.y + 52, r.w - 32, r.h - 52 - 60)
  let head = rect(grid.x, grid.y, grid.w, RowH)
  let cols = d.layout(head)
  ui.rect(head, colPanelRaised)
  ui.border(head, colBorder)
  # The header's checkbox turns every preset shown on, or off when all are.
  let allOn = on == shown.len
  let hc = vec2(head.x + CheckW / 2, head.y + RowH / 2)
  let hhov = ui.hover(rect(head.x, head.y, CheckW, RowH))
  ui.checkBox(hc, allOn and shown.len > 0, hhov)
  let every = if terms.len > 0: "every preset found" else: "every preset"
  ui.tip(rect(head.x, head.y, CheckW, RowH), "Turn " & every & (if allOn: " off" else: " on"))
  if hhov and ui.pressed():
    ui.consumeClick()
    d.toggled = shown.filterIt((it in v.disabled) != allOn)
    if d.toggled.len > 0: result = aaToggle
  for i, c in cols:
    ui.rect(rect(c.x, head.y, 1, RowH), colBorder)
    let sortedBy = c.key == d.sortKey
    let tw = c.w - 14 - (if sortedBy: 16 else: 0)
    ui.textIn(ui.ellipsize(c.title, tw, FontSmall), rect(c.x + 8, head.y, tw, RowH),
      if sortedBy: colText else: colTextDim, FontSmall)
    if sortedBy and c.w > 40:
      ui.icon(if d.sortDesc: "chevdown16" else: "chevup16", vec2(c.x + c.w - 13, head.y + RowH / 2), colTextDim)
  # Column edges: drag to resize, double-click to fit.
  var overEdge = false
  for i, c in cols:
    if i == cols.high: break
    let edge = rect(c.x + c.w - 4, head.y, 8, RowH)
    let hov = ui.hover(edge)
    if hov: overEdge = true
    if hov and ui.pressed():
      ui.consumeClick()
      if ui.countClick("av-edge-" & c.key) >= 2:
        var fit = ui.textSize(c.title, FontSmall).x + 22
        if c.key == d.sortKey: fit += 16
        if c.key == "rating": fit = max(fit, StarsW + 18)
        else:
          for id in presets: fit = max(fit, ui.textSize(d.cellText(v, d.metaOf(id, v.dir), id, c.key)).x + 22)
        d.colWidths[c.key] = max(MinCol, fit)
        result = aaPrefs
      else:
        d.colDrag = c.key
        d.colDragFrom = (ui.mouse.x, c.w)
  if d.colDrag.len > 0:
    overEdge = true
    if ui.down():
      d.colWidths[d.colDrag] = max(MinCol, d.colDragFrom[1] + ui.mouse.x - d.colDragFrom[0]).float
    else:
      d.colDrag = ""
      result = aaPrefs
  # A header click sorts by its column, again the other way; a right-click
  # asks for the sorting menu.
  if not overEdge:
    for c in cols:
      let hr = rect(c.x, head.y, c.w, RowH)
      if not ui.hover(hr): continue
      ui.tip(hr, "Sort by " & c.title & (if c.key == d.sortKey: (if d.sortDesc: ", ascending" else: ", descending") else: ""))
      if ui.pressed():
        ui.consumeClick()
        if c.key == d.sortKey: d.sortDesc = not d.sortDesc
        else: (d.sortKey, d.sortDesc) = (c.key, false)
        d.reveal = true
        result = aaPrefs
  if ui.hover(head) and ui.window.buttonPressed[MouseRight]:
    (d.ctx, d.ctxPos) = (acHeader, ui.mouse)
    result = aaContext
  if overEdge != d.resizeCursor:
    d.resizeCursor = overEdge
    w.cursor = Cursor(kind: if overEdge: ResizeLeftRightCursor else: ArrowCursor)

  let body = rect(grid.x, grid.y + RowH - 1, grid.w, grid.h - RowH + 1)
  let rows = d.sorted(v, shown)
  d.rows = rows
  let playingId = if v.current >= 0: presets[v.current] else: ""
  ui.rect(body, colBackground)
  let inner = rect(body.x + 1, body.y + 1, body.w - 2, body.h - 2)
  let content = rows.len.float32 * RowH
  let maxScroll = max(0'f32, content - inner.h)
  if ui.hover(body) and ui.scroll() != 0:
    d.scroll += ui.wheelNotches * RowH * 3
    ui.scrollConsumed = true
  if d.reveal and d.sel.len > 0:
    d.reveal = false
    let i = rows.find(d.sel[^1])
    if i >= 0:
      let y = i.float32 * RowH
      let outside = y < d.scroll or y + RowH > d.scroll + inner.h
      if d.center and outside: d.scroll = y - (inner.h - RowH) / 2
      elif y < d.scroll: d.scroll = y
      elif y + RowH > d.scroll + inner.h: d.scroll = y + RowH - inner.h
  d.center = false
  d.scroll = clamp(d.scroll, 0, maxScroll)
  let rowW = inner.w - (if maxScroll > 0: BarW else: 0)
  let outerClip = ui.hitClip
  ui.hitClip = inner
  ui.sk.pushClipRect(inner)
  var clicked = -1
  var rightClicked = false
  for i, id in rows:
    let y = inner.y + i.float32 * RowH - d.scroll
    if y + RowH < inner.y or y > inner.y + inner.h: continue
    let rr = rect(inner.x, y, rowW, RowH)
    let hov = ui.hover(rr)
    let high = id in d.sel
    let playing = id == playingId
    let off = id in v.disabled
    if high: ui.rect(rr, colPressed)
    elif hov: ui.rect(rr, colHover)
    ui.rect(rect(rr.x, y + RowH - 1, rr.w, 1), colBorder)
    let cr = rect(rr.x, y, CheckW, RowH)
    let chov = ui.hover(cr)
    ui.checkBox(vec2(cr.x + CheckW / 2, y + RowH / 2), not off, chov)
    # The rating: the stars and a little to their left, to take it off.
    let have = d.ratings.getOrDefault(id)
    var rateX = 0'f32
    var pitch = StarPitch
    var preview = -1
    for c in cols:
      if c.key != "rating": continue
      rateX = floor(c.x + 8)
      pitch = starPitch(c.w)
      let rend = min(c.x + c.w, inner.x + rowW)
      let hit = rect(rateX - 6, y, max(0'f32, min(rateX + 5 * pitch, rend) - rateX + 6), RowH)
      if hit.w > 0 and ui.hover(hit):
        preview = ratingAt(rateX, pitch, ui.mouse.x)
        if preview == have and have > 0: preview = 0
        ui.tip(hit, if preview == 0: (if have > 0: "Take the rating off (" & fmtRating(have) & ")" else: "Not rated")
                    else: "Rate " & fmtRating(preview))
    if preview >= 0 and ui.pressed():
      ui.consumeClick()
      # Over a highlighted row, every highlighted row goes along; a second
      # click on what they all have takes it off.
      d.rated = if high: d.sel else: @[id]
      d.rating = ratingAt(rateX, pitch, ui.mouse.x)
      if d.rated.allIt(d.ratings.getOrDefault(it) == d.rating): d.rating = 0
      for r in d.rated:
        if d.rating > 0: d.ratings[r] = d.rating else: d.ratings.del r
      result = aaRate
    elif chov and ui.pressed():
      ui.consumeClick()
      # Over a highlighted row, every highlighted row goes along.
      d.toggled = if high: d.sel else: @[id]
      result = aaToggle
    elif hov and ui.pressed():
      ui.consumeClick()
      clicked = i
    if hov and w.buttonPressed[MouseRight]:
      # The menu is for the highlighted rows; one outside them is highlighted
      # alone first (without playing it).
      rightClicked = true
      if not high:
        d.sel = @[id]
        d.anchor = id
      (d.ctx, d.ctxPos) = (acRows, ui.mouse)
      result = aaContext
    let m = d.metaOf(id, v.dir)
    for k, c in cols:
      ui.rect(rect(c.x, y, 1, RowH), colBorder)
      let cw = min(c.w, inner.x + rowW - c.x) - 16
      if cw <= 0: continue
      if c.key == "rating":
        ui.sk.pushClipRect(rect(c.x + 1, y, cw + 14, RowH))
        let shown = if preview >= 0: preview else: have
        # A disabled preset's stars fade with its text: filled as dark as the
        # text, the empty ones darker still, so the rating stays readable.
        ui.stars(rateX, pitch, y + RowH / 2, shown,
          if preview >= 0: colAccentHover elif off: colTextDisabled else: colAccent,
          if off and preview < 0: colTrack else: colTextDisabled)
        ui.sk.popClipRect()
        continue
      let text = d.cellText(v, m, id, c.key)
      var col = if off: colTextDisabled elif c.key == "name": colText else: colTextDim
      if c.key == "fps" and not off and v.rateOf(id) != MaxFps: col = colText  # set by hand
      var tx = c.x + 8
      var tw = cw
      if c.key == "name" and playing:
        # The one playing: marked, in the accent color.
        col = if off: colTextDim else: colAccent
        ui.icon("arrow16", vec2(c.x + 12, y + RowH / 2), col)
        tx += 14
        tw -= 14
      if c.key == "effects" and m.effects < 0: col = colError
      let right = c.key in ["effects", "size", "fps"]
      ui.textIn(ui.ellipsize(text, tw), rect(tx, y, tw, RowH), col,
        h = if right: RightAlign else: LeftAlign)
  if rows.len == 0 and presets.len > 0:
    ui.textIn("No presets match \"" & d.search.strip & "\"", rect(inner.x, inner.y, inner.w, RowH * 3),
      colTextDim, h = CenterAlign)
  if not rightClicked and ui.hover(inner) and w.buttonPressed[MouseRight]:
    (d.ctx, d.ctxPos) = (acEmpty, ui.mouse)
    result = aaContext
  ui.sk.popClipRect()
  ui.hitClip = outerClip
  ui.border(body, colBorder)
  # Scroll bar.
  if maxScroll > 0:
    let track = rect(inner.x + inner.w - BarW + 2, inner.y + 2, BarW - 4, inner.h - 4)
    let th = max(20'f32, track.h * inner.h / content)
    let span = track.h - th
    let bhov = ui.hover(rect(track.x - 2, track.y, track.w + 4, track.h))
    if bhov and ui.pressed():
      ui.consumeClick()
      d.dragBar = true
      d.dragBarFrom = (ui.mouse.y, d.scroll)
    if d.dragBar:
      if ui.down() and span > 0:
        d.scroll = clamp(d.dragBarFrom[1] + (ui.mouse.y - d.dragBarFrom[0]) / span * maxScroll, 0, maxScroll)
      else: d.dragBar = false
    ui.rect(rect(track.x, track.y + span * d.scroll / maxScroll, track.w, th),
      if d.dragBar or bhov: colTextDim else: colTrack)

  # Highlighting: a click (Ctrl adds or takes one, Shift a range) or the
  # arrows; one row highlighted alone plays.
  var moveTo = -1
  if clicked >= 0:
    let id = rows[clicked]
    if ctrl:
      if id in d.sel: d.sel.keepItIf(it != id) else: d.sel.add id
      d.anchor = id
    elif w.shiftDown and d.anchor in rows:
      let a = rows.find(d.anchor)
      d.sel = rows[min(a, clicked) .. max(a, clicked)]
    else: moveTo = clicked
  if wasSearching and enter and ui.focusId.len == 0 and rows.len > 0 and d.sel.len == 0:
    moveTo = 0  # Enter in the search: the first match, unless one's highlighted
  elif ui.focusId.len == 0 and rows.len > 0:
    let cur = if d.sel.len > 0: rows.find(d.sel[^1]) else: rows.find(playingId)
    let page = max(1, int(inner.h / RowH) - 1)
    if w.buttonPressed[KeyDown]: moveTo = min(cur + 1, rows.high)
    elif w.buttonPressed[KeyUp]: moveTo = max(cur - 1, 0)
    elif w.buttonPressed[KeyPageDown]: moveTo = min(cur + page, rows.high)
    elif w.buttonPressed[KeyPageUp]: moveTo = max(cur - page, 0)
    elif w.buttonPressed[KeyHome]: moveTo = 0
    elif w.buttonPressed[KeyEnd]: moveTo = rows.high
    elif w.buttonPressed[KeySpace] and d.sel.len > 0:
      d.toggled = d.sel
      result = aaToggle
    elif w.buttonPressed[KeyDelete] and removable.len > 0: result = aaRemove
    elif ctrl and w.buttonPressed[KeyA]: d.sel = rows
  if moveTo >= 0:
    let id = rows[moveTo]
    d.sel = @[id]
    d.anchor = id
    d.reveal = true
    if id != playingId:
      d.pick = id
      result = aaSelect

  # Bottom: the beat threshold and sensitivity, the hint (when there's room),
  # how many presets are on (of those found, searching), Close.
  ui.rect(rect(r.x + 1, r.y + r.h - 50, r.w - 2, 1), colBorder)
  var beatX = r.x + 16
  proc beatField(id, label, tip: string, value: var float, step, lo, hi: float): bool =
    ## label [-] value [+] %, from beatX on.
    let labelW = ui.textSize(label).x
    let fr = rect(beatX + labelW + 8, r.y + r.h - 38, 96, 26)
    let whole = rect(beatX, r.y + r.h - 40, fr.x + fr.w + 6 + ui.textSize("%").x - beatX, 30)
    ui.textIn(label, rect(beatX, whole.y, labelW, 30), colText)
    result = ui.numberField(id, fr, value, step, lo, hi)
    ui.textIn("%", rect(fr.x + fr.w + 6, whole.y, 20, 30), colTextDim)
    ui.tip(whole, tip)
    beatX = whole.x + whole.w + 18
  if beatField("av-beat", "Beat threshold", "How loud the sound must be for beats, in % of " &
      "Winamp's level: lower makes quiet music beat (ReplayGain makes it quieter), 0 lets any sound. " &
      "Presets can still beat by themselves.", d.beatThreshold, 5, 0, 400):
    result = aaBeat
  if beatField("av-beatsens", "Sensitivity", "How readily beats come at any loudness, in % of " &
      "Winamp's: 200 is about twice the beats, 300 the most. Presets that pass on every Nth beat " &
      "(Custom BPM) change more often too.", d.beatSensitivity, 10, 0, 300):
    result = aaBeat
  let count =
    if terms.len == 0: &"{on} of {presets.len} presets on"
    else: &"{shown.len} of {presets.len} found, {on} on"
  let countW = ui.textSize(count, FontSmall).x
  let closeX = r.x + r.w - 108
  ui.textIn(count, rect(closeX - 16 - countW, r.y + r.h - 40, countW, 30), colTextDim, FontSmall)
  let hintX = beatX + 2
  let hintW = closeX - 16 - countW - 16 - hintX
  let hint = if hintW < 140: @[]
             else: ui.wrapText("Highlight a preset to play it. Presets turned off are skipped.",
                               hintW, 2, FontSmall)
  let lineH = 15'f32
  for i, line in hint:
    ui.textIn(line, rect(hintX, r.y + r.h - 25 - lineH * hint.len.float32 / 2 + lineH * i.float32, hintW, lineH),
      colTextDim, FontSmall)
  if ui.textButton("av-close", rect(closeX, r.y + r.h - 40, 92, 30), "Close", primary = true):
    result = aaClose
  if w.buttonPressed[KeyEscape] and ui.focusId.len == 0 and not wasSearching and before.len == 0:
    result = aaClose
