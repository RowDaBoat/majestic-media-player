## Options window: a tree of pages on the left (drawn like a classic Windows
## tree view) and the selected page on the right. Edits apply to the config
## live; the caller snapshots it beforehand so Cancel can undo them.

import std/[os, strutils, sequtils, strformat, math, tables, times]
import silky, vmath, bumpy, chroma, pixie
import ui, theme, config, assoc, keymap, websave, mediainfo, screenpick, fontlist, gpumem

type
  OptionsPage* = enum
    opPlayer = "Player"
    opInterface = "Interface"
    opFormats = "Formats"
    opPaths = "Paths"
    opKeys = "Keys"
    opPlayback = "Playback"
    opOnline = "Online"
    opWeb = "Media Cache"
    opAudioFiles = "Audio Files"
    opReplayGain = "ReplayGain"
    opSubtitles = "Subtitles"
    opSubStyle = "Default"
    opMisc = "Miscellaneous"
    opSystem = "System"

  OptionsAction* = enum
    oaNone, oaOk, oaCancel

  PathRequest* = enum
    ## Paths page buttons the caller carries out (file dialogs, file manager).
    prNone, prBrowseScreenshots, prBrowseOpen, prShowSettings,
    prBrowseWeb, prOpenWebDir, prClearWeb, prDeleteWeb, prBrowseMkvpropedit, prBrowseYtdlp,
    prBrowseSoundFont

  WebInfo* = object
    ## Playback > Media Cache: the cached links, filled in by the caller.
    dir*: string
    used*, free*, total*: int64  ## bytes the folder takes, left on its disk, the disk's size (-1: unknown)
    items*: seq[WebItem]

  OptionsDialog* = ref object
    page*: OptionsPage
    expanded: set[OptionsPage]  ## tree nodes showing their children
    scroll: float32             ## page content scroll
    assoc: seq[AssocItem]
    assocLoaded: bool
    search: string
    listScroll: float32
    listCursor: int             ## Formats list row moved with the keyboard
    status: string              ## Formats page: outcome of the last Apply
    assocApplied*: bool         ## associations were written; the caller clears it
    request*: PathRequest       ## Paths page button pressed; the caller clears it
    keySearch: string
    keyScroll: float32
    keySel: KeyAction           ## Keys page: selected command
    capturing: bool             ## Keys page: waiting for the selected command's new key
    capSlot: int                ## which of its keys that replaces; -1 adds one
    keyTaken: bool              ## a key went to the capture this frame
    keyNote: string             ## Keys page: outcome of the last change
    keyReveal: bool             ## scroll the selected command into view
    web*: WebInfo               ## Media Cache page; the caller refreshes it
    webPicked*: seq[string]     ## Media Cache page: links checked in the list
    webScroll: float32
    confirmClear: bool          ## Media Cache page: Clear pressed once, asking again
    picker: string              ## Subtitles page: color row whose picker is open
    pickAt: Rect                ## that row's swatch, where the picker hangs
    pickH, pickS, pickV: float  ## the picker's color, 0..1 (hue kept while it's gray)
    pickFrom: string            ## the color it opened with (Esc goes back to it)
    pickHex: string             ## the picked color, for the row to take
    pickNew: bool               ## pickHex changed since the row last took it
    pickClose: bool             ## close once the row took pickHex
    pickDrag: int               ## 1: dragging in the square, 2: on the hue bar
    screenPicking: bool         ## the desktop is letting the user pick a color on screen
    screenNote: string          ## why picking on screen failed; "" while it may work
    fonts: seq[string]          ## Subtitles > Default: the installed font families
    fontsLoaded: bool
    fontOpen: bool              ## the Font row's list is showing
    fontQuery: string           ## what the list is narrowed to ("" = every font)
    fontHi: int                 ## the list's highlighted row, -1 when none
    fontTop: int                ## its first visible row
    fontAt: Rect                ## the Font field and its arrow, where the list hangs
    find: string                ## the search bar above both columns; "" when not searching
    findScroll: float32         ## the search results' scroll

  Pane = object
    ## Layout cursor for a page.
    x, y, w: float32
    started: bool               ## a group header was placed already
    find: seq[string]           ## search words, lower case; empty when not searching
    page: OptionsPage           ## while searching: the page being gone through,
    title: string               ## its group being gone through,
    header: bool                ## whether that group's header was drawn,
    shown: bool                 ## whether the last row was
    jump: bool                  ## a result was clicked: open jumpTo, leaving the search
    jumpTo: OptionsPage

const
  Tree = [(opPlayer, 0), (opInterface, 1), (opFormats, 1), (opPaths, 1), (opKeys, 1), (opPlayback, 0),
          (opOnline, 1), (opWeb, 1), (opAudioFiles, 1), (opReplayGain, 1), (opSubtitles, 0),
          (opSubStyle, 1), (opMisc, 0), (opSystem, 0)]
  Parents = {opPlayer, opPlayback, opSubtitles}
  TreeWidth = 180'f32
  TreeRow = 22'f32
  TreeIndent = 16'f32
  Row = 28'f32                  ## height of one option line
  LabelW = 210'f32              ## label column for numbers and text inputs

proc newOptionsDialog*(): OptionsDialog = OptionsDialog(expanded: Parents)

proc parentOf(p: OptionsPage): OptionsPage =
  ## The tree node p hangs off; p itself for a top-level node.
  result = p
  for (q, level) in Tree:
    if q == p: return
    if level == 0: result = q

proc opened*(d: OptionsDialog, ui: Ui) =
  ## The window is being shown: re-read associations, start at the top.
  d.assocLoaded = false
  d.status = ""
  d.keyNote = ""
  d.capturing = false
  d.confirmClear = false
  d.picker = ""
  d.fontOpen = false
  d.scroll = 0
  d.find = ""
  ui.navId = "o-tree"
  ui.navVisible = false

proc searching*(d: OptionsDialog): bool =
  ## Whether the search bar holds something (Esc empties it first).
  d.find.len > 0

proc selectPage*(d: OptionsDialog, ui: Ui, p: OptionsPage) =
  if p == d.page: return
  d.page = p
  d.scroll = 0
  d.capturing = false
  d.confirmClear = false
  d.fontOpen = false
  ui.focusId = ""
  d.expanded.incl p.parentOf

# --- tree ---------------------------------------------------------------------

proc visibleRows(d: OptionsDialog): seq[(OptionsPage, int)] =
  for (p, level) in Tree:
    if level == 0 or p.parentOf in d.expanded: result.add (p, level)

proc dotsH(ui: Ui, x1, x2, y: float32) =
  var x = x1.round
  while x < x2:
    ui.rect(rect(x, y.round, 1, 1), colTextDisabled)
    x += 2

proc dotsV(ui: Ui, x, y1, y2: float32) =
  var y = y1.round
  while y < y2:
    ui.rect(rect(x.round, y, 1, 1), colTextDisabled)
    y += 2

proc pageChanged(p: OptionsPage, c, before: Config): bool =
  ## Whether a setting of page p differs from when the window opened.
  template differs(field: untyped): bool = c.field != before.field
  case p
  of opPlayer: differs(autoFitWindow) or differs(openMode) or differs(rememberPlaylist) or
    differs(rememberTime) or differs(rememberTransform) or differs(rememberWindowPos) or
    differs(rememberWindowSize)
  of opInterface: differs(osdScale) or differs(osdScaleByWindow) or differs(osdTimestamp) or
    differs(showFrames) or differs(showMillis) or differs(showRemaining) or
    differs(titleFullPath) or differs(titleUseMediaTitle) or differs(uiScale)
  of opFormats: false  # associations apply at once
  of opPaths: differs(mkvpropedit) or differs(openDir) or differs(screenshotDir) or
    differs(screenshotNoAsk) or differs(ytdlp)
  of opKeys: differs(keys)
  of opPlayback: differs(audioLangs) or differs(bookmarksAsChapters) or
    differs(keepDisplayOn) or differs(rateStep) or differs(seekPreview) or
    differs(seekStep) or differs(snapWithShift) or differs(subLangs) or differs(volumeStep)
  of opOnline: differs(signInCookies) or differs(streamMaxFps30) or
    differs(streamMaxHeight) or differs(streamOnSave) or differs(streamQuality) or
    differs(streamSmallAudio)
  of opWeb: differs(webCount) or differs(webCountOn) or differs(webDir) or
    differs(webKeepHours) or differs(webKeepOn) or differs(webSizeGB) or differs(webSizeOn)
  of opAudioFiles: differs(coverNames) or differs(shortAudioDelay) or differs(shortAudioMs) or
    differs(showCover) or differs(showFileCover) or differs(showTrackerChart) or differs(showVisualizer) or differs(soundFont) or
    differs(avsBeatThreshold) or differs(avsBeatSensitivity)
  of opReplayGain: differs(replayGain) or differs(replayGainFallback) or
    differs(replayGainNoClip) or differs(replayGainPreamp)
  of opSubtitles: differs(subDelay) or differs(subPaths)
  of opSubStyle: differs(subBold) or differs(subColor) or differs(subFont) or
    differs(subItalic) or differs(subLineSpacing) or differs(subOpacity) or
    differs(subOutlineColor) or differs(subOutlineOpacity) or differs(subOutlineSize) or
    differs(subShadowColor) or differs(subShadowOffset) or differs(subShadowOpacity) or
    differs(subSize) or differs(subSpacing) or differs(subStyleAss)
  of opMisc: differs(panStep) or differs(rotateStep) or differs(sizeStep)
  of opSystem: differs(loopFramesMB) or differs(renderMode)

proc drawTree(d: OptionsDialog, ui: Ui, r: Rect, keys: bool, changed, clashing: set[OptionsPage]) =
  ## While searching the tree is greyed out; clicking a page leaves the
  ## search for it. Pages with unsaved changes get a *, those with clashing
  ## keys are yellow; a collapsed node stands for its children.
  let dim = d.find.strip.len > 0
  ui.rect(r, colBackground)
  ui.border(r, colBorder)
  let rows = d.visibleRows
  let focused = not dim and ui.tabStop("o-tree", r)
  let top = r.y + 6
  let x0 = r.x + 14             # root connector column, expanders sit on it
  proc rowY(i: int): float32 = top + i.float32 * TreeRow
  proc mid(i: int): float32 = rowY(i) + TreeRow / 2

  # Connectors: roots share one column; children hang off their parent.
  var firstRoot, lastRoot = -1
  for i, (p, level) in rows:
    if level == 0:
      if firstRoot < 0: firstRoot = i
      lastRoot = i
  ui.dotsV(x0, mid(firstRoot), mid(lastRoot) + 1)
  for i, (p, level) in rows:
    let cy = mid(i)
    if level == 0:
      if p notin Parents: ui.dotsH(x0, x0 + 10, cy)
    else:
      let xc = x0 + TreeIndent
      # The first child hangs below its parent's label, the next ones off the
      # sibling above.
      ui.dotsV(xc, mid(i - 1) + (if rows[i - 1][1] == level: 0'f32 else: 6), cy + 1)
      ui.dotsH(xc, xc + 10, cy)

  for i, (p, level) in rows:
    let y = rowY(i)
    let cy = mid(i)
    proc toggle(d: OptionsDialog) =
      if p in d.expanded:
        d.expanded.excl p
        if d.page.parentOf == p: d.selectPage(ui, p)
      else: d.expanded.incl p
    if p in Parents:
      let ex = rect(x0 - 7, cy - 7, 15, 15)
      ui.rect(ex, colBackground)
      ui.icon(if p in d.expanded: "expand16" else: "arrow16", vec2(x0 + 0.5, cy),
        if ui.hover(ex): colText else: colTextDim)
      if ui.hover(ex) and ui.pressed():
        ui.consumeClick()
        d.toggle()
    let lx = x0 + level.float32 * TreeIndent + 12
    proc marked(pages: set[OptionsPage]): bool =
      ## p, or a child the collapsed p hides.
      p in pages or p in Parents and p notin d.expanded and
        Tree.anyIt(it[0].parentOf == p and it[0] in pages)
    let name = $p & (if marked(changed): "*" else: "")
    let label = rect(lx, y + 2, ui.textSize(name).x + 10, TreeRow - 4)
    let rowR = rect(lx, y, r.x + r.w - lx - 4, TreeRow)
    let sel = d.page == p and not dim
    let hov = ui.hover(rowR)
    if sel: ui.rect(label, colAccent)
    elif hov: ui.rect(label, colHover)
    if sel and focused: ui.focusRing(rect(label.x + 2, label.y + 2, label.w - 4, label.h - 4))
    ui.textIn(name, rect(label.x + 5, label.y, label.w, label.h),
      if sel: colOnAccent elif marked(clashing): colWarning
      elif dim: colTextDisabled else: colText)
    if hov and ui.pressed():
      ui.consumeClick()
      if dim:
        d.find = ""
        d.scroll = 0
      ui.navId = "o-tree"
      d.selectPage(ui, p)
    if hov and p in Parents and ui.window.buttonPressed[DoubleClick]: d.toggle()

  # Keyboard: Up/Down move, Left collapses (or goes to the parent), Right expands.
  if dim or not keys or ui.navId notin ["", "o-tree"]: return
  let w = ui.window
  var cur = 0
  for i, (p, _) in rows:
    if p == d.page: cur = i
  if w.buttonPressed[KeyUp] and cur > 0: d.selectPage(ui, rows[cur - 1][0])
  elif w.buttonPressed[KeyDown] and cur < rows.high: d.selectPage(ui, rows[cur + 1][0])
  elif w.buttonPressed[KeyLeft]:
    if d.page.parentOf != d.page: d.selectPage(ui, d.page.parentOf)
    elif d.page in Parents: d.expanded.excl d.page
  elif w.buttonPressed[KeyRight] and d.page in Parents:
    d.expanded.incl d.page

# --- page building blocks -----------------------------------------------------

proc crumb(p: OptionsPage): string =
  ## Where a page sits in the tree, e.g. Player->Interface.
  if p.parentOf == p: $p else: $p.parentOf & "->" & $p

proc group(ui: Ui, p: var Pane, title: string) =
  if p.find.len > 0:            # its header waits for a matching row
    p.title = title
    p.header = false
    p.shown = false
    return
  if p.started: p.y += 6 + 7    # plus half an em of the 13 px header font, whole pixels
  p.started = true
  ui.groupHeader(vec2(p.x, p.y), p.w, title)
  p.y += 26

proc show(ui: Ui, p: var Pane, texts: varargs[string]): bool =
  ## Whether a row goes on the page. While searching, only the rows whose
  ## page name, group title, label or values hold every word of the search,
  ## under their group's header naming where they come from; a click on it
  ## opens that page.
  if p.find.len == 0: return true
  let hay = ($p.page & " " & p.title & " " & texts.join(" ")).toLowerAscii
  p.shown = p.find.allIt(it in hay)
  if not p.shown or p.header: return p.shown
  p.header = true
  if p.started: p.y += 6 + 7
  p.started = true
  let title = p.page.crumb & "->" & p.title
  let hr = rect(p.x, p.y, ui.textSize(title, FontSmall).x + 2, 20)
  let hov = ui.hover(hr)
  ui.textIn(title, hr, if hov: colAccent else: colTextDim, FontSmall)
  ui.rect(rect(hr.x + hr.w + 8, p.y + 10, max(0'f32, p.w - hr.w - 8), 1), colBorder)
  if hov:
    ui.tip(hr, "Open " & $p.page)
    if ui.pressed():
      ui.consumeClick()
      p.jump = true
      p.jumpTo = p.page
  p.y += 26
  true

proc follows(p: Pane): bool =
  ## Whether a hint or note goes on the page: while searching, only under
  ## the row it explains.
  p.find.len == 0 or p.shown

proc gap(p: var Pane) =
  if p.follows: p.y += 10

proc checkRow(ui: Ui, p: var Pane, id, label: string, value: var bool) =
  if not ui.show(p, label): return
  discard ui.checkbox(id, vec2(p.x + 8, p.y + 2), label, value)
  p.y += Row

proc radioRow[T](ui: Ui, p: var Pane, id, label: string, value: var T, option: T) =
  if not ui.show(p, label): return
  if ui.radioButton(id, vec2(p.x + 8, p.y + 2), label, value == option):
    value = option
  p.y += Row

proc numberRow(ui: Ui, p: var Pane, id, label: string, value: var float,
            step, lo, hi: float, decimals = 0) =
  if not ui.show(p, label, formatFloat(value, ffDecimal, decimals).strip(leading = false, chars = {'.'})):
    return
  ui.textIn(label, rect(p.x + 8, p.y, LabelW, 26), colText)
  discard ui.numberField(id, rect(p.x + 8 + LabelW, p.y, 150, 26), value,
    step, lo, hi, decimals)
  p.y += Row + 4

proc textRow(ui: Ui, p: var Pane, id, label: string, value: var string, placeholder: string) =
  if not ui.show(p, label, value): return
  ui.textIn(label, rect(p.x + 8, p.y, LabelW, 26), colText)
  discard ui.textField(id, rect(p.x + 8 + LabelW, p.y, max(120'f32, p.w - LabelW - 8), 26),
    value, placeholder)
  p.y += Row + 4

proc button(ui: Ui, id, label: string, r: Rect, enabled: bool): bool =
  ## A text button, greyed out and inert when not enabled.
  if enabled: return ui.textButton(id, r, label)
  ui.rect(r, colPanelRaised)
  ui.border(r, colBorder)
  ui.textIn(label, r, colTextDisabled, h = CenterAlign)

proc toggleNumberRow(ui: Ui, p: var Pane, id, label: string, on: var bool,
                     value: var int, step, lo, hi: int) =
  ## A checkbox turning a limit on, its number beside it.
  if not ui.show(p, label, $value): return
  discard ui.checkbox(id, vec2(p.x + 8, p.y + 2), label, on)
  var v = value.float
  discard ui.numberField(id & "-n", rect(p.x + 8 + LabelW, p.y, 150, 26), v,
    step.float, lo.float, hi.float)
  value = clamp(int(round(v)), lo, hi)
  p.y += Row + 4

proc hint(ui: Ui, p: var Pane, s: string) =
  if not p.follows: return
  ui.textIn(s, rect(p.x + 8, p.y - 2, p.w - 8, 18), colTextDim, FontSmall)
  p.y += 20

proc folderRow(ui: Ui, p: var Pane, id, label: string, value: var string,
               placeholder: string): bool =
  ## A folder text input with a Browse... button; true when it was pressed.
  if not ui.show(p, label, value): return
  const bw = 96'f32
  ui.textIn(label, rect(p.x + 8, p.y, LabelW, 26), colText)
  let fw = max(120'f32, p.w - LabelW - 8 - bw - 8)
  discard ui.textField(id, rect(p.x + 8 + LabelW, p.y, fw, 26), value, placeholder)
  result = ui.textButton(id & "-browse", rect(p.x + 16 + LabelW + fw, p.y, bw, 26),
    "Browse...")
  p.y += Row + 4

proc folderNote(ui: Ui, p: var Pane, value: string) =
  ## Warns when a typed folder does not exist.
  if not p.follows: return
  let d = value.expandPath
  if d.len > 0 and not dirExists(d):
    ui.textIn("This folder does not exist.", rect(p.x + 8 + LabelW, p.y - 2, p.w - LabelW - 8, 18),
      colAccent, FontSmall)
    p.y += 20

proc fileNote(ui: Ui, p: var Pane, value: string) =
  ## Warns when a typed program does not exist.
  if not p.follows: return
  let f = value.expandPath
  if f.len > 0 and not fileExists(f):
    ui.textIn("This file does not exist.", rect(p.x + 8 + LabelW, p.y - 2, p.w - LabelW - 8, 18),
      colAccent, FontSmall)
    p.y += 20

# --- pages ----------------------------------------------------------------------

proc resultRow(ui: Ui, p: var Pane, label, value: string, valueW = 0'f32): bool =
  ## A search result standing for an entry of a page's list (a format, a
  ## command, a cached link): its name and value; true when clicked, which
  ## opens the page.
  let r = rect(p.x + 8, p.y, p.w - 8, 24)
  let vw = if valueW > 0: valueW else: r.w - LabelW
  let hov = ui.hover(r)
  if hov:
    ui.rect(r, colHover)
    ui.tip(r, "Open " & $p.page)
  ui.textIn(ui.ellipsize(label, r.w - vw - 16), rect(r.x + 8, r.y, r.w - vw - 16, r.h), colText)
  ui.textIn(ui.ellipsize(value, vw - 8, FontSmall), rect(r.x + r.w - vw, r.y, vw - 8, r.h),
    colTextDim, FontSmall)
  if hov and ui.pressed():
    ui.consumeClick()
    p.jump = true
    p.jumpTo = p.page
    result = true
  p.y += 24

proc playerPage(ui: Ui, c: var Config, p: var Pane) =
  ui.group(p, "Open options")
  ui.radioRow(p, "o-same", "Same player for each media file", c.openMode, omSamePlayer)
  ui.radioRow(p, "o-new", "New player for each media file", c.openMode, omNewPlayer)
  p.gap
  ui.checkRow(p, "o-fit", "Resize window to fit video on open", c.autoFitWindow)
  ui.checkRow(p, "o-rtime", "Remember time (continue where the file was left off)", c.rememberTime)
  ui.checkRow(p, "o-rpos", "Remember window position", c.rememberWindowPos)
  ui.checkRow(p, "o-rsize", "Remember window size", c.rememberWindowSize)
  ui.checkRow(p, "o-rxf", "Remember last pan, rotation and zoom", c.rememberTransform)
  ui.checkRow(p, "o-rpl", "Remember playlist", c.rememberPlaylist)
  ui.hint(p, "The Default playlist and the file playing. Playlists of your own are always kept.")

proc interfacePage(ui: Ui, c: var Config, p: var Pane) =
  ui.group(p, "Interface")
  ui.numberRow(p, "o-scale", "UI scaling (percent)", c.uiScale, 25, 50, 300)
  ui.hint(p, "Size of text, menus and controls in every window.")
  ui.group(p, "OSD")
  let osd = "x" & formatFloat(c.osdScale, ffDecimal, 2)
  if ui.show(p, "OSD scaling", osd):
    ui.textIn("OSD scaling", rect(p.x + 8, p.y, LabelW, 26), colText)
    let sw = clamp(p.w - LabelW - 8 - 70, 120'f32, 300'f32)
    discard ui.slider("o-osdscale", rect(p.x + 8 + LabelW, p.y, sw, 26), c.osdScale,
      OsdScaleMin, OsdScaleMax, 0.05)
    ui.textIn(osd, rect(p.x + 8 + LabelW + sw + 14, p.y, 60, 26), colText)
    p.y += Row + 4
  ui.checkRow(p, "o-osdwin", "Scale with window size", c.osdScaleByWindow)
  ui.hint(p, if c.osdScaleByWindow: "OSD text grows and shrinks with the video frame."
             else: "OSD text keeps the same size whatever the window's size.")
  ui.group(p, "Timestamps")
  ui.checkRow(p, "o-osdtime", "Show timestamp in OSD", c.osdTimestamp)
  ui.checkRow(p, "o-millis", "Show milliseconds", c.showMillis)
  ui.checkRow(p, "o-remain", "Show remaining time", c.showRemaining)
  ui.checkRow(p, "o-frames", "Show frames", c.showFrames)
  ui.group(p, "Title bar")
  ui.radioRow(p, "o-tname", "File name only", c.titleFullPath, false)
  ui.radioRow(p, "o-tpath", "Display full path", c.titleFullPath, true)
  ui.checkRow(p, "o-ttitle", "Replace file name with title", c.titleUseMediaTitle)

proc loadAssoc(d: OptionsDialog) =
  if not d.assocLoaded:
    d.assoc = loadAssocItems()
    d.assocLoaded = true
    d.listScroll = 0

proc formatsResults(d: OptionsDialog, ui: Ui, p: var Pane) =
  ## Formats while searching: the matching formats; a click shows it in the list.
  d.loadAssoc()
  ui.group(p, "File association")
  for it in d.assoc:
    let kind = if it.video: "Video" else: "Audio"
    let mimes = if it.mimes.len > 0: it.mimes.join(", ") else: NoTypeText
    if ui.show(p, "." & it.ext, kind, mimes) and
       ui.resultRow(p, "." & it.ext, kind & (if it.checked: ", opens here" else: "") & "  " & mimes):
      d.search = it.ext
      d.listCursor = 0

proc formatsPage(d: OptionsDialog, ui: Ui, p: var Pane, bottom: float32) =
  d.loadAssoc()
  ui.group(p, "File association")
  discard ui.textField("o-search", rect(p.x + 8, p.y, p.w - 8, 26), d.search,
    TypeSearchHint)
  p.y += 34

  let footer = 8'f32 + 34 + 18  # buttons and the status line below the list
  let list = rect(p.x + 8, p.y, p.w - 8, max(120'f32, bottom - p.y - footer))
  ui.rect(list, colBackground)
  ui.border(list, colBorder)
  let needle = d.search.strip.toLowerAscii.strip(chars = {'.', '*'})
  var shown: seq[int]
  for i, it in d.assoc:
    if needle.len == 0 or needle in it.ext or needle in it.mimes.join(" "):
      shown.add i
  const rowH = 24'f32
  let inner = rect(list.x + 1, list.y + 1, list.w - 2, list.h - 2)
  let maxScroll = max(0'f32, shown.len.float32 * rowH - inner.h)
  let listFocused = ui.tabStop("o-assoc-list", list)
  d.listCursor = clamp(d.listCursor, 0, max(0, shown.high))
  if listFocused and ui.focusId.len == 0 and shown.len > 0:
    # Up/Down/PageUp/PageDown/Home/End move the cursor row, Space toggles it.
    let w = ui.window
    let page = max(1, int(inner.h / rowH) - 1)
    var c = d.listCursor
    if w.buttonPressed[KeyUp]: dec c
    if w.buttonPressed[KeyDown]: inc c
    if w.buttonPressed[KeyPageUp]: c -= page
    if w.buttonPressed[KeyPageDown]: c += page
    if w.buttonPressed[KeyHome]: c = 0
    if w.buttonPressed[KeyEnd]: c = shown.high
    c = clamp(c, 0, shown.high)
    if c != d.listCursor:
      d.listCursor = c
      ui.navVisible = true
      let top = c.float32 * rowH
      if top < d.listScroll: d.listScroll = top
      if top + rowH > d.listScroll + inner.h: d.listScroll = top + rowH - inner.h
    if w.buttonPressed[KeySpace] and d.assoc[shown[c]].mimes.len > 0:
      d.assoc.setChecked(shown[c], not d.assoc[shown[c]].checked)
      ui.navVisible = true
  if ui.hover(inner) and ui.scroll() != 0:
    d.listScroll += ui.scroll() * rowH / 3
    ui.scrollConsumed = true
  d.listScroll = clamp(d.listScroll, 0, maxScroll)
  let outerClip = ui.hitClip
  ui.hitClip = inner
  ui.sk.pushClipRect(inner)
  for n, i in shown:
    let it = d.assoc[i]
    let row = rect(inner.x, inner.y + n.float32 * rowH - d.listScroll, inner.w, rowH)
    if row.y + rowH < inner.y or row.y > inner.y + inner.h: continue
    let ok = it.mimes.len > 0
    let hov = ok and ui.hover(row)
    if hov: ui.rect(row, colHover)
    if listFocused and ui.navVisible and n == d.listCursor: ui.border(row, colAccent)
    let box = rect(row.x + 8, row.y + 4, 16, 16)
    ui.rect(box, if it.checked: colAccent else: colPanelRaised)
    ui.border(box, if hov: colAccent else: colBorder)
    if it.checked: ui.icon("check16", box.xy + box.wh / 2, colOnAccent)
    let changed = it.checked != it.current
    ui.textIn((if changed: "• " else: "") & "." & it.ext,
      rect(row.x + 32, row.y, 80, rowH), if not ok: colTextDisabled
                                           elif changed: colAccent else: colText)
    ui.textIn(if it.video: "Video" else: "Audio", rect(row.x + 112, row.y, 60, rowH),
      colTextDim, FontSmall)
    let mimes = if ok: it.mimes.join(", ") else: NoTypeText
    ui.textIn(ui.ellipsize(mimes, row.w - 186, FontSmall),
      rect(row.x + 176, row.y, row.w - 180, rowH),
      if ok: colTextDim else: colTextDisabled, FontSmall)
    if hov and ui.pressed():
      ui.pressId = "o-assoc" & $i
      ui.navId = "o-assoc-list"
      d.listCursor = n
      ui.consumeClick()
    if hov and ui.window.buttonReleased[MouseLeft] and ui.pressId == "o-assoc" & $i:
      d.assoc.setChecked(i, not it.checked)
  if shown.len == 0:
    ui.textIn("No matching formats", inner, colTextDim, FontSmall, h = CenterAlign)
  ui.sk.popClipRect()
  ui.hitClip = outerClip
  p.y = list.y + list.h + 8

  let bw = 140'f32
  if ui.textButton("o-allvideo", rect(p.x + 8, p.y, bw, 28), "Select all video"):
    for i, it in d.assoc:
      if it.video and it.mimes.len > 0: d.assoc.setChecked(i, true)
  if ui.textButton("o-allaudio", rect(p.x + 16 + bw, p.y, bw, 28), "Select all audio"):
    for i, it in d.assoc:
      if not it.video and it.mimes.len > 0: d.assoc.setChecked(i, true)
  var waiting = 0
  for it in d.assoc:
    if it.checked != it.current: inc waiting
  let applyR = rect(p.x + p.w - 160, p.y, 160, 28)
  if waiting > 0:
    if ui.textButton("o-apply", applyR, "Apply associations", primary = true):
      let err = d.assoc.applyAssociations()
      let kept = d.assoc.userOverrides()
      d.status =
        if err.len > 0: "Could not save associations: " & err
        elif kept.len > 0:
          "Applied. Windows keeps your own default app for ." & kept.join(", .") &
            "; change it in Settings > Default apps."
        else: "Associations applied."
      if err.len == 0: d.assocApplied = true
  else:
    ui.rect(applyR, colPanelRaised)
    ui.border(applyR, colBorder)
    ui.textIn("Apply associations", applyR, colTextDisabled, h = CenterAlign)
  p.y += 34
  let note =
    if waiting > 0: &"{waiting} format(s) changed, not applied yet"
    else: d.status
  ui.textIn(ui.ellipsize(note, p.w - 8, FontSmall), rect(p.x + 8, p.y, p.w - 8, 18),
    if waiting > 0: colAccent else: colTextDim, FontSmall)
  p.y += 18

proc pathsPage(d: OptionsDialog, ui: Ui, c: var Config, p: var Pane) =
  ui.group(p, "Screenshots")
  if ui.folderRow(p, "o-shotdir", "Folder", c.screenshotDir, defaultScreenshotDir()):
    d.request = prBrowseScreenshots
  ui.folderNote(p, c.screenshotDir)
  ui.checkRow(p, "o-shotask", "Save without asking for a file name", c.screenshotNoAsk)
  ui.hint(p, "Alt+I saves a PNG named after the file and the time straight into the folder.")
  ui.group(p, "Open dialogs")
  if ui.folderRow(p, "o-opendir", "Start in", c.openDir,
      "Folder of the playing file"):
    d.request = prBrowseOpen
  ui.folderNote(p, c.openDir)
  ui.hint(p, "Empty: the playing file's folder, else the last folder a file was opened from.")
  ui.group(p, "Programs")
  if ui.folderRow(p, "o-mkvpe", "mkvpropedit", c.mkvpropedit, "Found automatically"):
    d.request = prBrowseMkvpropedit
  ui.fileNote(p, c.mkvpropedit)
  if ui.folderRow(p, "o-ytdlp", "yt-dlp", c.ytdlp, "Found automatically"):
    d.request = prBrowseYtdlp
  ui.fileNote(p, c.ytdlp)
  ui.hint(p, "mkvpropedit embeds bookmarks as chapters; yt-dlp opens and saves online videos.")
  ui.hint(p, "Empty: the one the player installed, else the one on PATH.")
  ui.group(p, "Settings")
  if ui.show(p, "Settings folder", configDir()):
    ui.textIn("Settings folder", rect(p.x + 8, p.y, LabelW, 26), colText)
    const bw = 96'f32
    let tw = max(120'f32, p.w - LabelW - 8 - bw - 8)
    ui.textIn(ui.ellipsize(configDir(), tw), rect(p.x + 8 + LabelW, p.y, tw, 26), colTextDim)
    if ui.textButton("o-cfgdir", rect(p.x + 16 + LabelW + tw, p.y, bw, 26), "Open"):
      d.request = prShowSettings
    p.y += Row + 4
  ui.hint(p, "Settings, remembered positions, bookmarks and Run commands are kept here.")

const KeyCapture = "o-keycap"     ## focusId while waiting for a key

proc startCapture*(d: OptionsDialog, ui: Ui, act: KeyAction, slot = -1) =
  d.keySel = act
  d.capturing = true
  d.capSlot = slot
  d.keyReveal = true
  ui.focusId = KeyCapture       # the window's own keys (Esc, Enter, Tab) stand back
  ui.navId = "o-keys-list"

proc stopCapture(d: OptionsDialog, ui: Ui) =
  d.capturing = false
  if ui.focusId == KeyCapture: ui.focusId = ""

proc assignKeys*(d: OptionsDialog, c: var Config, act: KeyAction, ks: seq[KeyCombo]) =
  ## Gives act the keys ks. A key another command has stays there too: OK
  ## waits for one of them to give it up.
  c.setCombos(act, ks)
  d.keyNote =
    if ks.len == 0: Actions[act].label & ": no key"
    else: Actions[act].label & ": " & c.keysText(act)

proc addKey(d: OptionsDialog, c: var Config, act: KeyAction, k: KeyCombo, slot = -1) =
  ## k as another key of act, or in place of its key number slot.
  var ks = c.combos(act)
  if slot in 0 .. ks.high: ks[slot] = k
  else: ks.add k
  d.assignKeys(c, act, ks.deduplicate)

proc keysResults(d: OptionsDialog, ui: Ui, c: Config, p: var Pane) =
  ## Keys while searching: the matching commands under their groups; a click
  ## selects it in the list.
  for g in KeyGroup:
    ui.group(p, $g)
    for act in KeyAction:
      if Actions[act].group != g: continue
      let key = c.keysText(act)
      if ui.show(p, Actions[act].label, key) and
         ui.resultRow(p, Actions[act].label, if key.len > 0: key else: "None", 190):
        d.keySearch = ""
        d.keySel = act
        d.keyReveal = true

proc keysPage(d: OptionsDialog, ui: Ui, c: var Config, p: var Pane, bottom: float32) =
  let w = ui.window
  d.keyTaken = false
  let wasCapturing = d.capturing
  if d.capturing:
    # The next key pressed, with the modifiers held, goes to the command.
    # Escape or a click cancels.
    let key = w.pressedKey
    if w.buttonPressed[KeyEscape] or w.buttonPressed[MouseLeft] or
       w.buttonPressed[MouseRight] or ui.focusId != KeyCapture:
      d.stopCapture(ui)
      d.keyTaken = w.buttonPressed[KeyEscape]
    elif key != ButtonUnknown:
      d.addKey(c, d.keySel, KeyCombo(mods: w.heldMods, key: key), d.capSlot)
      d.stopCapture(ui)
      d.keyTaken = true

  ui.group(p, "Keyboard shortcuts")
  discard ui.textField("o-keysearch", rect(p.x + 8, p.y, p.w - 8, 26), d.keySearch,
    "Search commands or keys")
  p.y += 34

  # Rows: a header per group, then its commands matching the search.
  type KeyRow = tuple[header: bool, group: KeyGroup, act: KeyAction]
  var rows: seq[KeyRow]
  var acts: seq[int]            # indexes of the command rows
  for g in KeyGroup:
    var first = true
    for act in KeyAction:
      let info = Actions[act]
      if info.group != g: continue
      if not c.matchesSearch(act, d.keySearch): continue
      if first:
        rows.add (true, g, act)
        first = false
      acts.add rows.len
      rows.add (false, g, act)

  let clashes = c.keyClashes
  let footer = 8'f32 + 34 + 18  # buttons and the status line below the list
  let list = rect(p.x + 8, p.y, p.w - 8, max(120'f32, bottom - p.y - footer))
  ui.rect(list, colBackground)
  ui.border(list, colBorder)
  const rowH = 24'f32
  const keyW = 220'f32
  let inner = rect(list.x + 1, list.y + 1, list.w - 2, list.h - 2)
  let maxScroll = max(0'f32, rows.len.float32 * rowH - inner.h)
  let listFocused = ui.tabStop("o-keys-list", list)
  var cur = -1                  # position of the selected command in acts
  for n, i in acts:
    if rows[i].act == d.keySel: cur = n
  proc reveal(d: OptionsDialog, i: int) =
    let top = i.float32 * rowH
    if top < d.keyScroll: d.keyScroll = top
    if top + rowH > d.keyScroll + inner.h: d.keyScroll = top + rowH - inner.h
  if d.keyReveal and cur >= 0:
    d.keyReveal = false
    d.reveal(acts[cur])
  if listFocused and ui.focusId.len == 0 and acts.len > 0:
    # Up/Down/PageUp/PageDown/Home/End move the selection, Enter or Space
    # asks for another key, Delete or Backspace removes its keys.
    let page = max(1, int(inner.h / rowH) - 1)
    var n = max(cur, 0)
    if w.buttonPressed[KeyUp]: dec n
    if w.buttonPressed[KeyDown]: inc n
    if w.buttonPressed[KeyPageUp]: n -= page
    if w.buttonPressed[KeyPageDown]: n += page
    if w.buttonPressed[KeyHome]: n = 0
    if w.buttonPressed[KeyEnd]: n = acts.high
    n = clamp(n, 0, acts.high)
    if n != cur:
      cur = n
      d.keySel = rows[acts[n]].act
      ui.navVisible = true
      # Bring the group header into view with the first command.
      d.reveal(if n == 0: 0 else: acts[n])
    if cur >= 0:
      if w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter] or w.buttonPressed[KeySpace]:
        ui.enterUsed = true
        d.startCapture(ui, d.keySel)
      elif w.buttonPressed[KeyDelete] or w.buttonPressed[KeyBackspace]:
        d.assignKeys(c, d.keySel, @[])
  if ui.hover(inner) and ui.scroll() != 0:
    d.keyScroll += ui.scroll() * rowH / 3
    ui.scrollConsumed = true
  d.keyScroll = clamp(d.keyScroll, 0, maxScroll)

  let outerClip = ui.hitClip
  ui.hitClip = inner
  ui.sk.pushClipRect(inner)
  for i, row in rows:
    let r = rect(inner.x, inner.y + i.float32 * rowH - d.keyScroll, inner.w, rowH)
    if r.y + rowH < inner.y or r.y > inner.y + inner.h: continue
    if row.header:
      ui.textIn($row.group, rect(r.x + 8, r.y, r.w - 16, rowH), colAccent, FontSmall)
      ui.rect(rect(r.x + 8, r.y + rowH - 3, r.w - 16, 1), colBorder)
      continue
    let act = row.act
    let sel = act == d.keySel and cur >= 0
    let capturing = sel and d.capturing
    let clash = act in clashes
    let hov = ui.hover(r)
    # Yellow doesn't read on the accent color.
    let accent = sel and (listFocused or capturing) and not clash
    if sel: ui.rect(r, if accent: colAccent else: colPanelRaised)
    elif hov: ui.rect(r, colHover)
    let fg = if clash: colWarning elif accent: colOnAccent else: colText
    let changed = not c.isDefault(act)
    ui.textIn(ui.ellipsize(Actions[act].label, r.w - keyW - 40),
      rect(r.x + 20, r.y, r.w - keyW - 28, rowH), fg)
    let kr = rect(r.x + r.w - keyW - 6, r.y + 2, keyW, rowH - 4)
    let keys = c.combos(act)
    var picked = -1             # the key under the pointer
    if capturing:
      ui.rect(kr, colBackground)
      ui.border(kr, colAccent)
      ui.textIn("Press a key...", rect(kr.x + 8, kr.y, kr.w - 16, kr.h), colTextDim, FontSmall)
    else:
      let kcol =
        if clash: colWarning
        elif accent: colOnAccent
        elif keys.len == 0: colTextDisabled
        elif changed: colAccent
        else: colTextDim
      var x = kr.x + 8
      proc put(s: string) =
        ui.textIn(s, rect(x, kr.y, kr.x + kr.w - x, kr.h), kcol, FontSmall)
        x += ui.textSize(s, FontSmall).x
      if changed: put("• ")
      if keys.len == 0: put("None")
      for i, k in keys:
        if i > 0: put(" / ")
        let chip = rect(x - 3, kr.y, ui.textSize($k, FontSmall).x + 6, kr.h)
        if ui.hover(chip):
          picked = i
          ui.rect(chip, if accent: colAccentHover else: colPressed)
        put($k)
      if ui.hover(kr):
        ui.tip(kr, if picked >= 0: "Click to change, right-click to remove" else: "Click to add a key")
    if hov and ui.pressed():
      ui.consumeClick()
      ui.navId = "o-keys-list"
      ui.focusId = ""
      # Clicking a key changes it; clicking beside it or double-clicking the
      # row adds one.
      if ui.hover(kr) or (sel and w.buttonPressed[DoubleClick]): d.startCapture(ui, act, picked)
      else: d.keySel = act
    elif picked >= 0 and w.buttonPressed[MouseRight] and not wasCapturing:
      d.keySel = act
      c.removeCombo(act, keys[picked])
      d.keyNote = Actions[act].label & ": " & $keys[picked] & " removed"
  if rows.len == 0:
    ui.textIn("No matching commands", inner, colTextDim, FontSmall, h = CenterAlign)
  ui.sk.popClipRect()
  ui.hitClip = outerClip
  p.y = list.y + list.h + 8

  let has = cur >= 0
  const bw = 110'f32
  let by = p.y
  proc at(i: int): Rect = rect(list.x + i.float32 * (bw + 8), by, bw, 28)
  if ui.button("o-keyset", "Add...", at(0), has): d.startCapture(ui, d.keySel)
  if ui.button("o-keyclear", "Clear", at(1), has and c.combos(d.keySel).len > 0):
    d.assignKeys(c, d.keySel, @[])
  if ui.button("o-keyreset", "Default", at(2), has and not c.isDefault(d.keySel)):
    d.assignKeys(c, d.keySel, d.keySel.defaults)
  let allR = rect(p.x + p.w - 150, p.y, 150, 28)
  if c.keys.len > 0:
    if ui.textButton("o-keyresetall", allR, "Reset all keys"):
      c.keys.clear()
      d.keyNote = "All keys are back to their defaults."
  else:
    ui.rect(allR, colPanelRaised)
    ui.border(allR, colBorder)
    ui.textIn("Reset all keys", allR, colTextDisabled, h = CenterAlign)
  p.y += 34
  let note =
    if d.capturing: "Press a key for \"" & Actions[d.keySel].label & "\"; Esc cancels."
    elif clashes.card > 0: "The yellow commands share a key: change one of them to save."
    elif d.keyNote.len > 0: d.keyNote
    else: "Click a key to change it, right-click to remove it. Add... gives a command another key."
  ui.textIn(ui.ellipsize(note, p.w - 8, FontSmall), rect(p.x + 8, p.y, p.w - 8, 18),
    if d.capturing: colAccent elif clashes.card > 0: colWarning else: colTextDim, FontSmall)
  p.y += 18

proc playbackPage(ui: Ui, c: var Config, p: var Pane) =
  ui.group(p, "Display")
  ui.checkRow(p, "o-awake", "Keep the monitor on while playing video", c.keepDisplayOn)
  ui.hint(p, "Stops the system from blanking or turning off the screen during video playback.")
  ui.group(p, "Track preference")
  ui.textRow(p, "o-slang", "Subtitles", c.subLangs, "e.g. eng, jpn")
  ui.textRow(p, "o-alang", "Audio", c.audioLangs, "e.g. jpn, eng")
  ui.hint(p, "Language codes in order of preference; the first matching track is picked on open.")
  ui.group(p, "Seek bar")
  ui.checkRow(p, "o-prev", "Show thumbnail preview on hover", c.seekPreview)
  ui.checkRow(p, "o-snap", "Hold Shift to snap to chapters", c.snapWithShift)
  ui.hint(p, if c.snapWithShift: "Seeking snaps to chapters only while Shift is held."
             else: "Seeking snaps to chapters; hold Shift to seek freely.")
  ui.checkRow(p, "o-bmch", "Bookmarks as chapters", c.bookmarksAsChapters)
  ui.hint(p, "Next/previous chapter stops at bookmarks; the seek bar titles parts by them.")
  ui.group(p, "Steps")
  ui.numberRow(p, "o-rate", "Playback rate", c.rateStep, 0.05, 0.05, 2, 2)
  var jumpMs = c.seekStep * 1000
  ui.numberRow(p, "o-jump", "Jump (milliseconds)", jumpMs, 100, 1, 600_000)
  c.seekStep = round(jumpMs) / 1000
  ui.numberRow(p, "o-vol", "Volume", c.volumeStep, 0.5, 0.5, 50, 1)

proc onlinePage(ui: Ui, c: var Config, p: var Pane) =
  ui.group(p, "Sign-in for age-restricted videos")
  ui.textRow(p, "o-cookies", "Sign in with", c.signInCookies, "auto")
  ui.hint(p, "Browser whose cookies yt-dlp uses when a video asks to sign in (age-restricted).")
  ui.hint(p, "auto tries each installed browser; none turns it off; or brave, chrome, firefox...")

  ui.group(p, "Bandwidth")
  ui.radioRow(p, "o-sqbest", "Best quality (highest resolution, frame rate and audio)",
    c.streamQuality, sqBest)
  ui.radioRow(p, "o-sqlimit", "Limit resolution to:", c.streamQuality, sqLimit)
  # The heights to pick from, on a line of their own under it; picking one
  # picks the limit too.
  const Heights = [2160, 1440, 1080, 720, 480, 360, 240]
  if ui.show(p, "Limit resolution to:", Heights.mapIt($it & "p").join(" ")):
    var x = p.x + 32
    for h in Heights:
      let label = $h & "p"
      if ui.radioButton(&"o-sqh{h}", vec2(x, p.y + 2), label,
                        c.streamQuality == sqLimit and c.streamMaxHeight == h):
        c.streamQuality = sqLimit
        c.streamMaxHeight = h
      x += 24 + ui.textSize(label).x + 14
    p.y += Row
  ui.radioRow(p, "o-sqlow", "Lowest quality (uses the least data)", c.streamQuality, sqLowest)
  ui.radioRow(p, "o-sqaudio", "Audio only (no video is downloaded)", c.streamQuality, sqAudioOnly)
  p.gap
  ui.checkRow(p, "o-sqfps", "Limit frame rate to 30 fps", c.streamMaxFps30)
  ui.checkRow(p, "o-sqaudiosmall", "Lower-bitrate audio", c.streamSmallAudio)
  ui.checkRow(p, "o-sqsave", "Also when saving links (File > Save, command lines)", c.streamOnSave)
  ui.hint(p, "Applies to links opened from now on; cached media plays as it was cached.")
  ui.hint(p, "When nothing fits a limit, the smallest version available is fetched instead.")

proc audioFilesPage(d: OptionsDialog, ui: Ui, c: var Config, p: var Pane) =
  ui.group(p, "Front cover")
  ui.checkRow(p, "o-cover", "Show an audio file's front cover", c.showCover)
  ui.hint(p, "Animated GIFs move at their own pace, playing or paused.")
  ui.checkRow(p, "o-coverfile", "Show a picture named after the audio file instead", c.showFileCover)
  ui.hint(p, "Song.jpg for song.mp3: shown over the cover inside the file and the folder picture.")
  if ui.show(p, "Folder pictures", c.coverNames):
    ui.textIn("Folder pictures", rect(p.x + 8, p.y, LabelW, 26), colText)
    discard ui.textArea("o-covernames", rect(p.x + 8 + LabelW, p.y, max(120'f32, p.w - LabelW - 8), 96),
      c.coverNames, "e.g. folder")
    p.y += 96 + 4
  ui.hint(p, "Without a cover inside it, a picture in its folder with one of these names, one per line.")
  ui.hint(p, "Earlier lines win; letter case and the extension (.jpg, .png...) don't matter.")
  ui.group(p, "Tracker chart")
  ui.checkRow(p, "o-trackerchart", "Show the tracker chart (MOD, XM, IT, MIDI...)", c.showTrackerChart)
  ui.hint(p, "Each channel's notes, scrolling as they play. Modules need libopenmpt.")
  ui.group(p, "Visualizer")
  ui.checkRow(p, "o-visualizer", "Show the visualizer for sound without a picture", c.showVisualizer)
  ui.hint(p, "AVS presets, playing to what you hear. Add your own .avs files")
  ui.hint(p, "to the presets folder (right-click the video: Visualizer Preset).")
  ui.numberRow(p, "o-avsbeat", "Beat threshold (%)", c.avsBeatThreshold, 5, 0, 400)
  ui.hint(p, "How loud the sound must be for beats: 100 is Winamp's, lower makes quiet music beat")
  ui.hint(p, "(ReplayGain makes it quieter), 0 lets any sound. Presets can still beat by themselves.")
  ui.numberRow(p, "o-avssens", "Beat sensitivity (%)", c.avsBeatSensitivity, 10, 0, 300)
  ui.hint(p, "How readily beats come at any loudness: 100 is Winamp's, 200 about twice the beats,")
  ui.hint(p, "300 the most. Presets that pass on every Nth beat (Custom BPM) change more often too.")
  ui.group(p, "MIDI files")
  if ui.folderRow(p, "o-soundfont", "SoundFont", c.soundFont, "None: only one beside the file"):
    d.request = prBrowseSoundFont
  ui.fileNote(p, c.soundFont)
  ui.hint(p, "MIDI, HMI and XMI files play through FluidSynth with a SoundFont (.sf2, .sf3): one in")
  ui.hint(p, "the file's folder, else this one. Without either, they don't play.")
  ui.group(p, "Very short files")
  ui.checkRow(p, "o-shortaudio", "Add delay after very short files", c.shortAudioDelay)
  ui.numberRow(p, "o-shortaudioms", "Delay (milliseconds)", c.shortAudioMs, 50, 1, 60_000)
  ui.hint(p, "A file shorter than this is followed by this much silence before the next item.")

proc replayGainPage(ui: Ui, c: var Config, p: var Pane) =
  ui.group(p, "Mode")
  ui.radioRow(p, "o-rgoff", "Off", c.replayGain, rgOff)
  ui.radioRow(p, "o-rgtrack", "Track gain (every file at the same loudness)", c.replayGain, rgTrack)
  ui.radioRow(p, "o-rgalbum", "Album gain (albums keep their quiet and loud songs)", c.replayGain, rgAlbum)
  ui.hint(p, "Uses the loudness values stored in a file's tags; files aren't scanned for them.")
  ui.hint(p, "Album gain falls back to track gain for files with no album values.")
  ui.group(p, "Gain")
  ui.numberRow(p, "o-rgpreamp", "Pre-amp (dB)", c.replayGainPreamp, 0.5, -15, 15, 1)
  ui.hint(p, "Added to every file's ReplayGain value; positive values play louder.")
  ui.numberRow(p, "o-rgfallback", "Without ReplayGain (dB)", c.replayGainFallback, 0.5, -30, 15, 1)
  ui.hint(p, "The gain for files without ReplayGain values (videos too) while ReplayGain is on.")
  p.gap
  ui.checkRow(p, "o-rgclip", "Prevent clipping", c.replayGainNoClip)
  ui.hint(p, "Lowers the gain when it would push the file's peak past full scale.")

proc webPage(d: OptionsDialog, ui: Ui, c: var Config, p: var Pane, bottom: float32) =
  let web = d.web
  ui.group(p, "Cache folder")
  const bw = 96'f32
  const lw = 110'f32            # narrower labels: the folder field has two buttons
  proc pct(part, whole: float): string =
    let v = 100 * part / whole
    if v < 10: formatFloat(v, ffDecimal, 1) & "%" else: $int(round(v)) & "%"
  var usage = fmtBytes(web.used.float)
  if c.webSizeOn: usage.add "  (" & pct(web.used.float, float(c.webSizeGB.int64 shl 30)) &
    &" of {c.webSizeGB} GiB)"
  elif web.total > 0: usage.add "  (" & pct(web.used.float, web.total.float) & " of the disk)"
  if web.free >= 0: usage.add "  " & fmtBytes(web.free.float) & " free"
  if ui.show(p, "Space taken", usage, "Clear cache"):
    ui.textIn("Space taken", rect(p.x + 8, p.y, lw, 26), colText)
    let uw = p.w - lw - 8 - 128
    ui.textIn(ui.ellipsize(usage, uw), rect(p.x + 8 + lw, p.y, uw, 26), colTextDim)
    let clearR = rect(p.x + p.w - 120, p.y, 120, 26)
    if d.confirmClear:
      if ui.textButton("o-webclear-yes", clearR, "Really clear?", primary = true):
        d.confirmClear = false
        d.request = prClearWeb
      elif ui.pressed() and not ui.hover(clearR): d.confirmClear = false
    elif ui.button("o-webclear", "Clear cache", clearR, web.items.len > 0 or web.used > 0):
      d.confirmClear = true
    p.y += Row + 4
  if ui.show(p, "Folder", c.webDir, defaultSaveDir()):
    ui.textIn("Folder", rect(p.x + 8, p.y, lw, 26), colText)
    let fw = max(120'f32, p.w - lw - 8 - 2 * (bw + 8))
    discard ui.textField("o-webdir", rect(p.x + 8 + lw, p.y, fw, 26), c.webDir,
      defaultSaveDir())
    if ui.textButton("o-webdir-browse", rect(p.x + 16 + lw + fw, p.y, bw, 26), "Browse..."):
      d.request = prBrowseWeb
    if ui.textButton("o-webdir-open", rect(p.x + 24 + lw + fw + bw, p.y, bw, 26), "Open"):
      d.request = prOpenWebDir
    p.y += Row + 4
  ui.hint(p, "Online media is cached here as it streams, and plays from disk when opened again.")
  if p.follows and c.webDir.expandPath notin ["", web.dir]:
    ui.textIn("Applied on OK; what's cached in the current folder stays there.",
      rect(p.x + 8, p.y - 2, p.w - 8, 18), colAccent, FontSmall)
    p.y += 20

  ui.group(p, "Delete automatically")
  ui.toggleNumberRow(p, "o-webkeep", "Delete after (hours)", c.webKeepOn, c.webKeepHours, 1, 1, 87600)
  ui.toggleNumberRow(p, "o-webcount", "Keep at most (items)", c.webCountOn, c.webCount, 1, 1, 10000)
  ui.toggleNumberRow(p, "o-websize", "Max. disk space (GiB)", c.webSizeOn, c.webSizeGB, 1, 1, 100000)
  ui.hint(p, "Checked on OK, at start and as media is cached; the least recently opened go first.")

  ui.group(p, "Cached media")
  if p.find.len > 0:            # the matching links; a click opens the page
    for it in web.items:
      let title = if it.title.len > 0: it.title else: it.url
      if ui.show(p, title, it.url): discard ui.resultRow(p, title, fmtBytes(it.bytes.float), 90)
    return
  # Checked items still cached; the list may have changed since.
  var picked: seq[string]
  for it in web.items:
    if it.url in d.webPicked: picked.add it.url
  d.webPicked = picked
  if ui.button("o-webdel", "Delete selected", rect(p.x + 8, p.y, 140, 28), picked.len > 0):
    d.request = prDeleteWeb
  if ui.textButton("o-webshow", rect(p.x + 156, p.y, 190, 28), "Open containing folder"):
    d.request = prOpenWebDir
  let count = &"{web.items.len} item(s)" & (if picked.len > 0: &", {picked.len} selected" else: "")
  ui.textIn(count, rect(p.x + 354, p.y, p.w - 354, 28), colTextDim, FontSmall, h = RightAlign)
  p.y += 36

  const rowH = 24'f32
  const sizeW = 76'f32
  const savedW = 140'f32
  const dateW = 120'f32
  let list = rect(p.x + 8, p.y, p.w - 8, max(160'f32, bottom - p.y - 8))
  ui.rect(list, colBackground)
  ui.border(list, colBorder)
  # Header: a box checking every item, and the columns' names.
  let head = rect(list.x + 1, list.y + 1, list.w - 2, rowH)
  let titleW = head.w - 32 - savedW - sizeW - dateW
  var all = web.items.len > 0 and picked.len == web.items.len
  if ui.checkbox("o-weball", vec2(head.x + 8, head.y + 1), "", all):
    d.webPicked = @[]
    if all:
      for it in web.items: d.webPicked.add it.url
  var x = head.x + 32
  for (name, cw) in [("Title", titleW), ("Saved", savedW), ("Size", sizeW), ("Last opened", dateW)]:
    ui.textIn(name, rect(x, head.y, cw - 8, rowH), colTextDim, FontSmall)
    x += cw
  ui.rect(rect(head.x, head.y + rowH, head.w, 1), colBorder)

  let inner = rect(list.x + 1, head.y + rowH + 1, list.w - 2, list.h - rowH - 3)
  let maxScroll = max(0'f32, web.items.len.float32 * rowH - inner.h)
  if ui.hover(inner) and ui.scroll() != 0:
    d.webScroll += ui.scroll() * rowH / 3
    ui.scrollConsumed = true
  d.webScroll = clamp(d.webScroll, 0, maxScroll)
  let outerClip = ui.hitClip
  ui.hitClip = inner
  ui.sk.pushClipRect(inner)
  for n, it in web.items:
    let row = rect(inner.x, inner.y + n.float32 * rowH - d.webScroll, inner.w, rowH)
    if row.y + rowH < inner.y or row.y > inner.y + inner.h: continue
    let on = it.url in d.webPicked
    let hov = ui.hover(row)
    if hov: ui.rect(row, colHover)
    let box = rect(row.x + 8, row.y + 4, 16, 16)
    ui.rect(box, if on: colAccent else: colPanelRaised)
    ui.border(box, if hov: colAccent else: colBorder)
    if on: ui.icon("check16", box.xy + box.wh / 2, colOnAccent)
    var x = row.x + 32
    let title = if it.title.len > 0: it.title else: it.url
    let tr = rect(x, row.y, titleW - 8, rowH)
    ui.textIn(ui.ellipsize(title, tr.w), tr, colText)
    if ui.hover(tr): ui.tip(tr, it.url)
    x += titleW
    let saved =
      if it.duration > 0 and it.saved >= it.duration - 1: "Complete"
      elif it.duration > 0: fmtTime(it.saved, dur = it.duration) & " / " & fmtTime(it.duration)
      else: fmtTime(it.saved)
    ui.textIn(saved, rect(x, row.y, savedW - 8, rowH), colTextDim, FontSmall)
    x += savedW
    ui.textIn(fmtBytes(it.bytes.float), rect(x, row.y, sizeW - 8, rowH), colTextDim, FontSmall)
    x += sizeW
    let date = if it.used > 0: fromUnix(int64(it.used)).local.format("yyyy-MM-dd HH:mm") else: ""
    ui.textIn(date, rect(x, row.y, dateW - 8, rowH), colTextDim, FontSmall)
    if hov and ui.pressed():
      ui.pressId = "o-web" & $n
      ui.consumeClick()
    if hov and ui.window.buttonReleased[MouseLeft] and ui.pressId == "o-web" & $n:
      if on: d.webPicked.delete(d.webPicked.find(it.url))
      else: d.webPicked.add it.url
  if web.items.len == 0:
    ui.textIn("Nothing cached", inner, colTextDim, FontSmall, h = CenterAlign)
  ui.sk.popClipRect()
  ui.hitClip = outerClip
  p.y = list.y + list.h + 8

const SubSwatches = ["#FFFFFF", "#FFF3A0", "#FFE000", "#7FE8FF", "#A0A0A0", "#000000"]
  ## Options > Subtitles: colors one click away

const PickerFocus = "o-picker"  ## focusId while a color picker is open

proc hexColor(hex: string): Color =
  parseHtmlColor("#" & hex.strip.strip(trailing = false, chars = {'#'}))

proc hsvHex(h, s, v: float): string =
  ## Hue, saturation, value (0..1) as #RRGGBB.
  let k = (h mod 1) * 6
  proc f(n: float): float =
    let t = (n + k) mod 6
    v - v * s * clamp(min(t, 4 - t), 0, 1)
  "#" & toHex(int(round(f(5) * 255)), 2) & toHex(int(round(f(3) * 255)), 2) &
    toHex(int(round(f(1) * 255)), 2)

proc hexHsv(hex: string): (float, float, float) =
  let c = hexColor(hex)
  let (r, g, b) = (c.r.float, c.g.float, c.b.float)
  let v = max(r, max(g, b))
  let d = v - min(r, min(g, b))
  let s = if v > 0: d / v else: 0.0
  var h = 0.0
  if d > 0:
    h = (if v == r: (g - b) / d elif v == g: 2 + (b - r) / d else: 4 + (r - g) / d) / 6
    if h < 0: h += 1
  (h, s, v)

proc rgbHex(rgb: (float, float, float)): string =
  proc b(v: float): string = toHex(int(round(clamp(v, 0, 1) * 255)), 2)
  "#" & b(rgb[0]) & b(rgb[1]) & b(rgb[2])

proc openPicker(d: OptionsDialog, ui: Ui, id, value: string, at: Rect) =
  d.picker = id
  d.pickAt = at
  d.pickFrom = if value.validColor: value else: "#FFFFFF"
  (d.pickH, d.pickS, d.pickV) = hexHsv(d.pickFrom)
  d.pickNew = false
  d.pickClose = false
  d.pickDrag = 0
  ui.focusId = PickerFocus      # the window's own keys (Esc, Enter, Tab) stand back
  ui.navVisible = false

const
  PickPad = 10'f32
  PickSq = vec2(200, 160)       ## saturation (across) / value (down) square
  PickHueW = 18'f32
  PickFootH = 26'f32
  PickSwatch = 20'f32           ## saved colors, in a row under the footer
  PickSwatchStep = 24'f32
  MaxSwatches = 9               ## as many as the row fits

proc pickerRect(d: OptionsDialog, ui: Ui): Rect =
  ## Below the swatch, or above it when the window ends first.
  let w = PickPad * 3 + PickSq.x + PickHueW
  let h = PickPad * 4 + PickSq.y + PickFootH + PickSwatch
  let a = d.pickAt
  let y = if a.y + a.h + 4 + h <= ui.size.y - 4: a.y + a.h + 4 else: max(4'f32, a.y - 4 - h)
  rect(clamp(a.x, 4, max(4'f32, ui.size.x - w - 4)), y, w, h)

proc pickerParts(r: Rect): tuple[sq, hue, old, cur, screen, save, saved: Rect] =
  let sq = rect(r.x + PickPad, r.y + PickPad, PickSq.x, PickSq.y)
  let fy = sq.y + sq.h + PickPad
  let right = r.x + r.w - PickPad
  (sq, rect(sq.x + sq.w + PickPad, sq.y, PickHueW, sq.h),
   rect(sq.x, fy, 30, PickFootH), rect(sq.x + 30, fy, 30, PickFootH),
   rect(right - PickFootH * 2 - 4, fy, PickFootH, PickFootH), rect(right - PickFootH, fy, PickFootH, PickFootH),
   rect(sq.x, fy + PickFootH + PickPad, right - sq.x, PickSwatch))

proc savedAt(row: Rect, m: Vec2, count: int): int =
  ## The saved color under m, or -1.
  if not m.inside(row): return -1
  let i = int((m.x - row.x) / PickSwatchStep)
  if i < count and m.x - row.x - i.float32 * PickSwatchStep < PickSwatch: i else: -1

proc pickerInput(d: OptionsDialog, ui: Ui, c: var Config) =
  ## Before anything else is drawn: the open picker takes the mouse and keys.
  var shot = spIdle
  var rgb: (float, float, float)
  if d.screenPicking:
    shot = pollScreenPick(rgb)
    if shot != spWaiting: d.screenPicking = false
    if shot == spFailed: d.screenNote = "The desktop couldn't pick a color"
  if d.picker.len == 0 or d.pickClose: return
  let w = ui.window
  let r = d.pickerRect(ui)
  let parts = r.pickerParts
  let m = ui.mouse
  let was = (d.pickH, d.pickS, d.pickV)
  if shot == spPicked: (d.pickH, d.pickS, d.pickV) = hexHsv(rgbHex(rgb))
  let saved = parts.saved.savedAt(m, c.colorSwatches.len)
  if w.buttonPressed[MouseLeft]:
    if m.inside(parts.sq): d.pickDrag = 1
    elif m.inside(parts.hue): d.pickDrag = 2
    elif m.inside(parts.old): (d.pickH, d.pickS, d.pickV) = hexHsv(d.pickFrom)
    elif m.inside(parts.screen):
      if not d.screenPicking and d.screenNote.len == 0:
        if startScreenPick(): d.screenPicking = true
        else: d.screenNote = "Picking on screen isn't available on this desktop"
    elif m.inside(parts.save):
      let hex = hsvHex(d.pickH, d.pickS, d.pickV)
      let i = c.colorSwatches.find(hex)
      if i >= 0: c.colorSwatches.delete(i)
      c.colorSwatches.insert(hex, 0)
      if c.colorSwatches.len > MaxSwatches: c.colorSwatches.setLen(MaxSwatches)
    elif saved >= 0: (d.pickH, d.pickS, d.pickV) = hexHsv(c.colorSwatches[saved])
    elif not m.inside(r) and not d.screenPicking: d.pickClose = true
  elif w.buttonPressed[MouseRight]:
    if saved >= 0: c.colorSwatches.delete(saved)
    elif not m.inside(r) and not d.screenPicking: d.pickClose = true
  if not w.buttonDown[MouseLeft]: d.pickDrag = 0
  case d.pickDrag
  of 1:
    d.pickS = clamp((m.x - parts.sq.x) / parts.sq.w, 0, 1)
    d.pickV = 1 - clamp((m.y - parts.sq.y) / parts.sq.h, 0, 1)
  of 2: d.pickH = clamp((m.y - parts.hue.y) / parts.hue.h, 0, 0.9999)
  else: discard
  if m.inside(parts.hue) and ui.scroll() != 0:
    d.pickH = clamp(d.pickH + (if ui.scroll() < 0: -0.01 else: 0.01), 0, 0.9999)
  if w.buttonPressed[KeyEscape]:
    (d.pickH, d.pickS, d.pickV) = hexHsv(d.pickFrom)
    d.pickClose = true
  elif w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter]: d.pickClose = true
  if (d.pickH, d.pickS, d.pickV) != was or w.buttonPressed[KeyEscape]:
    d.pickHex = hsvHex(d.pickH, d.pickS, d.pickV)
    if w.buttonPressed[KeyEscape]: d.pickHex = d.pickFrom
    d.pickNew = true
  ui.captured = true            # nothing under the picker reacts

proc drawPicker(d: OptionsDialog, ui: Ui, cfg: Config) =
  if d.picker.len == 0: return
  let r = d.pickerRect(ui)
  let parts = r.pickerParts
  ui.sk.pushLayer(PopupsLayer)
  defer: ui.sk.popLayer()
  ui.rect(rect(r.x + 3, r.y + 3, r.w, r.h), rgbx(0, 0, 0, 90))  # shadow
  ui.rect(r, colPopup)
  ui.border(r, colBorder)
  let hue = hexColor(hsvHex(d.pickH, 1, 1)).rgbx
  let white = rgbx(255, 255, 255, 255)
  let black = rgbx(0, 0, 0, 255)
  let clear = rgbx(0, 0, 0, 0)
  ui.gradient(parts.sq, white, hue, hue, white)
  ui.gradient(parts.sq, clear, clear, black, black)
  ui.border(parts.sq, colBorder)
  let c = vec2(parts.sq.x + d.pickS.float32 * parts.sq.w, parts.sq.y + (1 - d.pickV.float32) * parts.sq.h)
  ui.sk.pushClipRect(parts.sq)
  ui.border(rect(c.x - 6, c.y - 6, 12, 12), black, 1)
  ui.border(rect(c.x - 5, c.y - 5, 10, 10), white, 2)
  ui.sk.popClipRect()
  let seg = parts.hue.h / 6
  for i in 0 ..< 6:
    let top = hexColor(hsvHex(i / 6, 1, 1)).rgbx
    let bottom = hexColor(hsvHex((i + 1) / 6, 1, 1)).rgbx
    ui.gradient(rect(parts.hue.x, parts.hue.y + i.float32 * seg, parts.hue.w, seg), top, top, bottom, bottom)
  ui.border(parts.hue, colBorder)
  let hy = parts.hue.y + d.pickH.float32 * parts.hue.h
  ui.rect(rect(parts.hue.x - 3, hy - 2, parts.hue.w + 6, 4), black)
  ui.rect(rect(parts.hue.x - 2, hy - 1, parts.hue.w + 4, 2), white)
  ui.rect(parts.old, hexColor(d.pickFrom).rgbx)
  ui.rect(parts.cur, hexColor(hsvHex(d.pickH, d.pickS, d.pickV)).rgbx)
  ui.border(rect(parts.old.x, parts.old.y, 60, PickFootH), colBorder)
  ui.textIn(hsvHex(d.pickH, d.pickS, d.pickV), rect(parts.cur.x + parts.cur.w + 10, parts.cur.y, 80, PickFootH), colText)
  let m = ui.mouse
  proc button(r: Rect, icon: string, on, enabled: bool) =
    let hov = enabled and m.inside(r)
    if hov: ui.rect(r, if ui.down(): colPressed else: colHover)
    ui.icon(icon & "16", r.xy + r.wh / 2,
      if not enabled: colTextDisabled elif on: colAccent elif hov: colWhite else: colText)
  button(parts.screen, "eyedropper", d.screenPicking, d.screenNote.len == 0)
  button(parts.save, "plus", false, true)
  for i, hex in cfg.colorSwatches:
    let s = rect(parts.saved.x + i.float32 * PickSwatchStep, parts.saved.y, PickSwatch, PickSwatch)
    ui.rect(s, hexColor(hex).rgbx)
    ui.border(s, if m.inside(s): colAccent else: colBorder)
  if cfg.colorSwatches.len == 0:
    ui.textIn("Saved colors show here", parts.saved, colTextDim, FontSmall)
  template tip(at: Rect, s: string) =
    if m.inside(at):
      ui.tooltip = s
      ui.tooltipAnchor = at
  tip(parts.old, "Back to " & d.pickFrom & " (Esc)")
  tip(parts.screen, if d.screenNote.len > 0: d.screenNote
                    elif d.screenPicking: "Picking on screen..."
                    else: "Pick a color anywhere on screen")
  tip(parts.save, "Save this color")
  let saved = parts.saved.savedAt(m, cfg.colorSwatches.len)
  if saved >= 0:
    tip(parts.saved, cfg.colorSwatches[saved] & "  (right-click: remove)")

proc colorRow(d: OptionsDialog, ui: Ui, p: var Pane, id, label: string, value: var string,
              opacity: var float) =
  ## A #RRGGBB field with its swatch (click: a color picker), an opacity in
  ## percent and a few colors to pick from.
  if d.picker == id:
    if d.pickNew:
      value = d.pickHex
      d.pickNew = false
    if d.pickClose:
      d.picker = ""
      if ui.focusId == PickerFocus: ui.focusId = ""
  if not ui.show(p, label, value): return
  ui.textIn(label, rect(p.x + 8, p.y, LabelW, 26), colText)
  var x = p.x + 8 + LabelW
  let ok = value.validColor
  let sw = rect(x, p.y, 26, 26)
  if d.picker == id: d.pickAt = sw  # follows the page
  if ui.hover(sw):
    ui.tip(sw, "Pick a color")
    if ui.pressed():
      ui.consumeClick()
      d.openPicker(ui, id, value, sw)
  if ok:
    var col = parseHtmlColor("#" & value.strip.strip(trailing = false, chars = {'#'}))
    col.a = clamp(opacity, 0, 100) / 100
    ui.rect(sw, colBackground)
    ui.rect(sw, col.rgbx)
  else:
    ui.rect(sw, colBackground)
    ui.textIn("?", sw, colAccent, h = CenterAlign)
  ui.border(sw, if ui.hover(sw) or d.picker == id: colAccent else: colBorder)
  x += 32
  discard ui.textField(id, rect(x, p.y, 90, 26), value, "#RRGGBB")
  x += 98
  discard ui.numberField(id & "-a", rect(x, p.y, 110, 26), opacity, 5, 0, 100)
  ui.textIn("%", rect(x + 114, p.y, 20, 26), colTextDim)
  x += 140
  for i, hex in SubSwatches:
    let r = rect(x + i.float32 * 24, p.y + 3, 20, 20)
    if r.x + r.w > p.x + p.w: break
    let hov = ui.hover(r)
    ui.rect(r, parseHtmlColor(hex).rgbx)
    ui.border(r, if hov: colAccent else: colBorder)
    if hov:
      ui.tip(r, hex)
      if ui.pressed():
        ui.pressId = id & "-sw" & $i
        ui.consumeClick()
      if ui.window.buttonReleased[MouseLeft] and ui.pressId == id & "-sw" & $i:
        value = hex
  p.y += Row + 4
  if not ok:
    ui.textIn("Not a color; type it as #RRGGBB.", rect(p.x + 8 + LabelW, p.y - 2, p.w - LabelW - 8, 18),
      colAccent, FontSmall)
    p.y += 20


const
  FontFocus = "o-sfont"         ## the Font field's id
  FontRowH = 22'f32             ## a row of its list
  FontRows = 12                 ## rows the list shows at once

proc fontMatches(d: OptionsDialog): seq[string] =
  let q = d.fontQuery.strip.toLowerAscii
  for f in d.fonts:
    if q.len == 0 or q in f.toLowerAscii: result.add f

proc fontListRect(d: OptionsDialog, ui: Ui, n: int): Rect =
  ## Below the field, or above it when the window ends first.
  let h = max(1, min(n, FontRows)).float32 * FontRowH + 2
  let a = d.fontAt
  let y = if a.y + a.h + 2 + h <= ui.size.y - 4: a.y + a.h + 2 else: max(4'f32, a.y - 2 - h)
  rect(a.x, y, a.w, h)

proc showFontHi(d: OptionsDialog, n: int) =
  ## Scrolls the list so the highlighted row is in it.
  if d.fontHi >= 0:
    if d.fontHi < d.fontTop: d.fontTop = d.fontHi
    elif d.fontHi >= d.fontTop + FontRows: d.fontTop = d.fontHi - FontRows + 1
  d.fontTop = clamp(d.fontTop, 0, max(0, n - FontRows))

proc openFonts(d: OptionsDialog, query, current: string) =
  ## Shows the list narrowed to query, highlighting current (or the first
  ## font starting with the query).
  if not d.fontsLoaded:
    d.fonts = systemFonts()
    d.fontsLoaded = true
  d.fontOpen = true
  d.fontQuery = query
  let m = d.fontMatches
  d.fontHi = -1
  let cur = current.strip.toLowerAscii
  let q = query.strip.toLowerAscii
  for i, f in m:
    if f.toLowerAscii == cur:
      d.fontHi = i
      break
  if d.fontHi < 0 and q.len > 0:
    for i, f in m:
      if f.toLowerAscii.startsWith(q):
        d.fontHi = i
        break
  d.fontTop = d.fontHi - FontRows div 2
  d.showFontHi(m.len)

proc fontInput(d: OptionsDialog, ui: Ui, c: var Config) =
  ## Before anything else is drawn: the open font list takes the mouse over
  ## it, the arrows, Enter and Esc.
  if not d.fontOpen: return
  let w = ui.window
  let m = d.fontMatches
  let r = d.fontListRect(ui, m.len)
  let mouse = ui.mouse
  if mouse.inside(r):
    if ui.scroll() != 0:
      d.fontTop += (if ui.scroll() < 0: -3 else: 3)
      d.fontTop = clamp(d.fontTop, 0, max(0, m.len - FontRows))
      ui.scrollConsumed = true
    if w.buttonPressed[MouseLeft]:
      let i = d.fontTop + int((mouse.y - r.y - 1) / FontRowH)
      if i >= 0 and i < m.len:
        c.subFont = m[i]
        d.fontOpen = false
    ui.captured = true          # nothing under the list reacts
  elif w.buttonPressed[MouseLeft] and not mouse.inside(d.fontAt):
    d.fontOpen = false
  if w.buttonPressed[KeyDown] and m.len > 0:
    d.fontHi = min(d.fontHi + 1, m.high)
    d.showFontHi(m.len)
  elif w.buttonPressed[KeyUp] and m.len > 0:
    d.fontHi = max(d.fontHi - 1, 0)
    d.showFontHi(m.len)
  elif w.buttonPressed[KeyPageDown] and m.len > 0:
    d.fontHi = min(d.fontHi + FontRows, m.high)
    d.showFontHi(m.len)
  elif w.buttonPressed[KeyPageUp] and m.len > 0:
    d.fontHi = max(d.fontHi - FontRows, 0)
    d.showFontHi(m.len)
  if w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter]:
    if d.fontHi >= 0 and d.fontHi < m.len: c.subFont = m[d.fontHi]
    d.fontOpen = false
  elif w.buttonPressed[KeyEscape]:
    d.fontOpen = false

proc drawFonts(d: OptionsDialog, ui: Ui, c: Config) =
  if not d.fontOpen: return
  let m = d.fontMatches
  let r = d.fontListRect(ui, m.len)
  ui.sk.pushLayer(PopupsLayer)
  defer: ui.sk.popLayer()
  ui.rect(rect(r.x + 3, r.y + 3, r.w, r.h), rgbx(0, 0, 0, 90))  # shadow
  ui.rect(r, colPopup)
  ui.border(r, colBorder)
  ui.sk.pushClipRect(r)
  defer: ui.sk.popClipRect()
  if m.len == 0:
    ui.textIn(if d.fonts.len == 0: "No fonts found" else: "No matching fonts",
      rect(r.x + 8, r.y + 1, r.w - 16, FontRowH), colTextDim)
    return
  let mouse = ui.mouse
  let cur = c.subFont.strip.toLowerAscii
  for row in 0 ..< min(FontRows, m.len - d.fontTop):
    let i = d.fontTop + row
    let rr = rect(r.x + 1, r.y + 1 + row.float32 * FontRowH, r.w - 2, FontRowH)
    let hi = i == d.fontHi
    if hi: ui.rect(rr, colAccent)
    elif mouse.inside(rr): ui.rect(rr, colHover)
    let col = if hi: colOnAccent elif m[i].toLowerAscii == cur: colAccent else: colText
    ui.textIn(ui.ellipsize(m[i], rr.w - 20), rect(rr.x + 8, rr.y, rr.w - 16, rr.h), col)
  if m.len > FontRows:
    let th = max(16'f32, r.h * FontRows / m.len.float32)
    let ty = r.y + (r.h - th) * (d.fontTop.float32 / float32(m.len - FontRows))
    ui.rect(rect(r.x + r.w - 5, ty, 3, th), colTrack)

proc fontRow(d: OptionsDialog, ui: Ui, p: var Pane, value: var string) =
  ## A font family field with an arrow opening the installed fonts; typing
  ## narrows the list to the matching ones.
  ui.textIn("Font", rect(p.x + 8, p.y, LabelW, 26), colText)
  let fw = max(120'f32, p.w - LabelW - 8) - 26
  let field = rect(p.x + 8 + LabelW, p.y, fw, 26)
  let arrow = rect(field.x + fw, p.y, 26, 26)
  d.fontAt = rect(field.x, field.y, fw + 26, 26)  # follows the page
  let focused = ui.focusId == FontFocus
  let ev = ui.textField(FontFocus, field, value, "sans-serif")
  let wasOpen = d.fontOpen
  if eeChanged in ev: d.openFonts(value, "")
  elif focused and not d.fontOpen and ui.window.buttonPressed[KeyDown]:
    d.openFonts("", value)
  if d.fontOpen and ui.focusId != FontFocus and not ui.mouse.inside(d.fontListRect(ui, d.fontMatches.len)):
    d.fontOpen = false          # Tab or a click left the field
  let hov = ui.hover(arrow)
  ui.rect(arrow, if hov and ui.down(): colPressed elif hov: colHover else: colPanelRaised)
  ui.border(arrow, if hov or d.fontOpen: colAccent else: colBorder)
  ui.icon("expand16", arrow.xy + arrow.wh / 2, if hov: colText else: colTextDim)
  if hov:
    ui.tip(arrow, "Installed fonts")
    if ui.pressed():
      ui.consumeClick()
      if wasOpen: d.fontOpen = false
      else:
        d.openFonts("", value)
        ui.focusId = FontFocus  # typing narrows the list, Esc / Enter reach it
        ui.focusFresh = true
        ui.navId = FontFocus
  p.y += Row + 4

proc subtitlesPage(d: OptionsDialog, ui: Ui, c: var Config, p: var Pane) =
  ui.group(p, "Subtitles")
  ui.numberRow(p, "o-sdelay", "Delay (milliseconds)", c.subDelay, 50, -600_000, 600_000)
  ui.textRow(p, "o-spaths", "Autoload paths", c.subPaths, "e.g. Subs;Subtitles;~/subs")
  ui.hint(p, "Folders searched for subtitles matching the file's name, separated by ';'.")
  ui.hint(p, "Relative paths start at the media file's folder.")

proc subStylePage(d: OptionsDialog, ui: Ui, c: var Config, p: var Pane) =
  ui.group(p, "Default style")
  if ui.show(p, "Font", c.subFont): d.fontRow(ui, p, c.subFont)
  if ui.show(p, "Style", "Bold", "Italic"):
    ui.textIn("Style", rect(p.x + 8, p.y, LabelW, 26), colText)
    discard ui.checkbox("o-sbold", vec2(p.x + 8 + LabelW, p.y + 2), "Bold", c.subBold)
    discard ui.checkbox("o-sitalic", vec2(p.x + 8 + LabelW + 90, p.y + 2), "Italic", c.subItalic)
    p.y += Row + 4
  ui.numberRow(p, "o-ssize", "Size", c.subSize, 2, 1, 300)
  ui.numberRow(p, "o-sspacing", "Character spacing", c.subSpacing, 0.5, -10, 10, 1)
  ui.numberRow(p, "o-slinesp", "Line spacing", c.subLineSpacing, 1, -100, 200, 1)
  d.colorRow(ui, p, "o-scolor", "Color", c.subColor, c.subOpacity)
  p.gap
  ui.numberRow(p, "o-soutline", "Outline size", c.subOutlineSize, 0.25, 0, 20, 2)
  d.colorRow(ui, p, "o-soutcolor", "Outline color", c.subOutlineColor, c.subOutlineOpacity)
  p.gap
  ui.numberRow(p, "o-sshadow", "Shadow offset", c.subShadowOffset, 0.5, 0, 20, 2)
  d.colorRow(ui, p, "o-sshcolor", "Shadow color", c.subShadowColor, c.subShadowOpacity)
  p.gap
  ui.checkRow(p, "o-sass", "Also restyle styled (ASS/SSA) subtitles", c.subStyleAss)
  ui.hint(p, if c.subStyleAss: "Styled subtitles lose their own fonts, colors and positioning."
             else: "Styled subtitles keep their own look; this style is for plain ones (SRT...).")
  p.gap
  if ui.show(p, "Reset style"):
    if ui.textButton("o-sreset", rect(p.x + 8, p.y, 140, 28), "Reset style"):
      c.resetSubStyle()
    p.y += 34

proc miscPage(ui: Ui, c: var Config, p: var Pane) =
  ui.group(p, "Steps")
  ui.numberRow(p, "o-move", "Move (pixels)", c.panStep, 1, 1, 500)
  ui.numberRow(p, "o-rot", "Rotate (degrees)", c.rotateStep, 1, 1, 90)
  ui.numberRow(p, "o-size", "Resize (percent)", c.sizeStep, 1, 1, 50)

proc systemPage(ui: Ui, c: var Config, p: var Pane) =
  ui.group(p, "Rendering")
  ui.radioRow(p, "o-rdgpu", "Prefer GPU", c.renderMode, rdPreferGpu)
  ui.hint(p, "Starts on the GPU; on the CPU while the GPU's memory is full, until it frees up.")
  ui.radioRow(p, "o-rdadapt", "Adaptive", c.renderMode, rdAdaptive)
  ui.hint(p, "Switches back and forth as the GPU's memory runs out and frees up.")
  ui.radioRow(p, "o-rdcpu", "Always CPU", c.renderMode, rdCpu)
  ui.hint(p, "Never uses the GPU, at the cost of several CPU cores while playing.")
  p.gap
  ui.hint(p, if softwareGl: "Rendering on the CPU now."
             elif cpuWanted: "Decoding on the CPU now (no software renderer installed)."
             else: "Rendering on the GPU now.")
  ui.hint(p, "Switching restarts the player, picking up where it was.")
  p.gap
  ui.group(p, "Memory")
  var mb = c.loopFramesMB.float
  ui.numberRow(p, "o-lfmem", "Loop frames (MB)", mb, 64, 64, LoopFramesMaxMB.float)
  c.loopFramesMB = clamp(int(round(mb)), 64, LoopFramesMaxMB)
  ui.hint(p, "Video memory for short A-B loops' frames, which keep them moving,")
  ui.hint(p, "and for the frames kept around a paused position, for instant frame steps.")
  ui.hint(p, &"Loops needing more play the plain way, often frozen. At most {LoopFramesMaxMB} MB.")

# --- window -----------------------------------------------------------------------

proc draw*(d: OptionsDialog, ui: Ui, c: var Config, before: Config, r: Rect): OptionsAction =
  ## Draws the window's contents filling r (the Options window's client area).
  ## before is the config when it opened, for the pages with unsaved changes.
  let w = ui.window
  # Keys that belong to the window, not to a text field being edited.
  let keys = ui.focusId.len == 0
  let enter = keys and (w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter])
  d.pickerInput(ui, c)
  d.fontInput(ui, c)

  # The search bar spans both columns. Esc in it, or with nothing focused,
  # empties it first.
  let findR = rect(r.x + 16, r.y + 16, r.w - 32, 26)
  if d.find.len > 0 and w.buttonPressed[KeyEscape] and ui.focusId in ["", "o-find"]:
    d.find = ""
    ui.focusId = ""
  if eeChanged in ui.textField("o-find", findR, d.find,
      "Search options: headers, labels or values"):
    d.findScroll = 0
    d.picker = ""
    d.fontOpen = false
  let searching = d.find.strip.len > 0

  let body = rect(r.x + 16, findR.y + findR.h + 10, r.w - 32, r.h - 16 - 58 - findR.h - 10)
  let treeR = rect(body.x, body.y, TreeWidth, body.h)
  var changed: set[OptionsPage]
  for (page, _) in Tree:
    if page.pageChanged(c, before): changed.incl page
  let clashing = c.keyClashes.card > 0
  # On the Keys page its list shows them already.
  let clashPages = if clashing and (searching or d.page != opKeys): {opKeys} else: {}
  d.drawTree(ui, treeR, keys, changed, clashPages)

  let pageR = rect(treeR.x + treeR.w + 16, body.y, body.w - treeR.w - 16, body.h)
  ui.sk.pushClipRect(pageR)
  let outerClip = ui.hitClip
  ui.hitClip = pageR
  let scroll = if searching: addr d.findScroll else: addr d.scroll
  let origin = pageR.y - scroll[]
  var p = Pane(x: pageR.x, y: origin, w: pageR.w - 12)
  let pageStops = ui.tabStops.len
  if searching:
    # Every page in the tree's order, keeping the rows that match.
    p.find = strutils.splitWhitespace(d.find.toLowerAscii)
    for (page, _) in Tree:
      p.page = page
      case page
      of opPlayer: playerPage(ui, c, p)
      of opInterface: interfacePage(ui, c, p)
      of opFormats: d.formatsResults(ui, p)
      of opPaths: d.pathsPage(ui, c, p)
      of opKeys: d.keysResults(ui, c, p)
      of opPlayback: playbackPage(ui, c, p)
      of opOnline: onlinePage(ui, c, p)
      of opWeb: d.webPage(ui, c, p, pageR.y + pageR.h)
      of opAudioFiles: d.audioFilesPage(ui, c, p)
      of opReplayGain: replayGainPage(ui, c, p)
      of opSubtitles: d.subtitlesPage(ui, c, p)
      of opSubStyle: d.subStylePage(ui, c, p)
      of opMisc: miscPage(ui, c, p)
      of opSystem: systemPage(ui, c, p)
    if not p.started:
      ui.textIn("No matching options", rect(p.x, p.y, p.w, 40), colTextDim, h = CenterAlign)
  else:
    case d.page
    of opPlayer: playerPage(ui, c, p)
    of opInterface: interfacePage(ui, c, p)
    of opFormats: d.formatsPage(ui, p, pageR.y + pageR.h)
    of opPaths: d.pathsPage(ui, c, p)
    of opKeys: d.keysPage(ui, c, p, pageR.y + pageR.h)
    of opPlayback: playbackPage(ui, c, p)
    of opOnline: onlinePage(ui, c, p)
    of opWeb: d.webPage(ui, c, p, pageR.y + pageR.h)
    of opAudioFiles: d.audioFilesPage(ui, c, p)
    of opReplayGain: replayGainPage(ui, c, p)
    of opSubtitles: d.subtitlesPage(ui, c, p)
    of opSubStyle: d.subStylePage(ui, c, p)
    of opMisc: miscPage(ui, c, p)
    of opSystem: systemPage(ui, c, p)
  ui.hitClip = outerClip
  ui.sk.popClipRect()
  let pageStopsEnd = ui.tabStops.len

  # Long pages scroll when the window is small.
  let contentH = p.y - origin
  let maxScroll = max(0'f32, contentH - pageR.h)
  if ui.hover(pageR) and ui.scroll() != 0:
    scroll[] += ui.scroll() * 3
    ui.scrollConsumed = true
  scroll[] = clamp(scroll[], 0, maxScroll)
  if maxScroll > 0:
    let th = max(24'f32, pageR.h * pageR.h / contentH)
    let ty = pageR.y + (pageR.h - th) * (scroll[] / maxScroll)
    ui.rect(rect(pageR.x + pageR.w - 4, ty, 3, th), colTrack)
  if p.jump:                    # a search result was clicked: open its page
    d.find = ""
    d.selectPage(ui, p.jumpTo)
    d.scroll = 0

  ui.rect(rect(r.x + 1, r.y + r.h - 50, r.w - 2, 1), colBorder)
  let by = r.y + r.h - 40
  let okR = rect(r.x + r.w - 212, by, 92, 30)
  if clashing:
    discard ui.button("o-ok", "OK", okR, false)
    ui.tip(okR, "Some keys are on more than one command (Player > Keys)")
  elif ui.textButton("o-ok", okR, "OK", primary = true):
    result = oaOk
  if ui.textButton("o-cancel", rect(r.x + r.w - 112, by, 92, 30), "Cancel"):
    result = oaCancel
  # Enter means OK unless a focused button took it.
  if result == oaNone and enter and not ui.enterUsed and not clashing: result = oaOk
  d.drawPicker(ui, c)
  d.drawFonts(ui, c)
  if result != oaNone:
    ui.focusId = ""
    return

  # Tab / Shift+Tab: tree, page controls, OK, Cancel. Scroll the page so a
  # newly focused control is visible.
  # A Tab that was just bound to a command doesn't move the focus too.
  let i = if d.keyTaken or d.picker.len > 0: -1 else: ui.tabNavigate()
  if i >= pageStops and i < pageStopsEnd:
    let sr = ui.tabStops[i].r
    if sr.y < pageR.y: scroll[] -= pageR.y - sr.y + 4
    elif sr.y + sr.h > pageR.y + pageR.h: scroll[] += sr.y + sr.h - pageR.y - pageR.h + 4
    scroll[] = clamp(scroll[], 0, maxScroll)
