## Synchronize > Properties window: the players found (masters framed solid,
## slaves dashed, in their group's color) and, for the one selected, its
## master, its offset and whether it keeps looping. Changes apply right away.

import std/[math, strutils, sequtils, strformat]
import silky, vmath, bumpy, chroma
import ui, theme

type
  SyncInstance* = object
    pid*: int
    title*: string
    master*: int              ## 0 when not synchronized; its own pid for a master
    offset*: float
    loop*: bool
    fps*: float               ## its video's frame rate, 0 when unknown
    me*: bool                 ## the player showing the window

  SyncAction* = enum
    saNone, saMaster, saOffset, saLoop, saSeconds, saClose

  SyncDialog* = ref object
    selected*: int            ## pid of the instance shown on the right
    newMaster*: int           ## with saMaster: the master chosen, 0 for none
    newOffset*: float         ## with saOffset
    newLoop*: bool            ## with saLoop
    useSeconds*: bool         ## the offset shown in seconds, not in the master's frames
    listOpen*: bool           ## the Master dropdown's list
    listScroll: float32

const
  SyncSize* = ivec2(660, 380)
  ListW = 280'f32
  ItemH = 46'f32
  EntryH = 26'f32
  LabelW = 120'f32

proc groupColor*(master: int): ColorRGBX =
  ## A hue per master, kept semi-saturated so it reads on dark and on video.
  hsl(float32((master * 137) mod 360), 55, 60).color.rgbx

proc isMaster(s: SyncInstance): bool = s.master != 0 and s.master == s.pid
proc isSlave(s: SyncInstance): bool = s.master != 0 and s.master != s.pid

proc name(s: SyncInstance): string =
  (if s.title.len > 0: s.title else: "No file") & &"  (PID {s.pid})"

proc role(s: SyncInstance, all: seq[SyncInstance]): string =
  result =
    if s.isMaster: &"Master of {all.countIt(it.isSlave and it.master == s.pid)}"
    elif s.isSlave: &"Slave of PID {s.master}"
    else: "Not synchronized"
  if s.me: result.add "  · this player"

proc candidates(sel: SyncInstance, all: seq[SyncInstance]): seq[int] =
  ## Masters sel may follow: 0 (none), then every other player that isn't a slave.
  result = @[0]
  for s in all:
    if s.pid != sel.pid and not s.isSlave: result.add s.pid

proc offsetFps(sel: SyncInstance, all: seq[SyncInstance]): float =
  ## The frame rate sel's offset counts in: its master's, or its own without one.
  if not sel.isSlave: return sel.fps
  for s in all:
    if s.pid == sel.master: return s.fps

proc fpsLabel(fps: float): string =
  if fps <= 0: return "No frame rate"
  result = formatFloat(fps, ffDecimal, 3)
  result.trimZeros()
  result.add " fps"

proc newSyncDialog*(useSeconds: bool): SyncDialog = SyncDialog(useSeconds: useSeconds)

proc draw*(d: SyncDialog, ui: Ui, r: Rect, all: seq[SyncInstance]): SyncAction =
  let w = ui.window
  if all.len == 0: return
  if not all.anyIt(it.pid == d.selected):
    d.selected = all[0].pid
    d.listOpen = false
  let sel = all.filterIt(it.pid == d.selected)[0]
  let leads = all.anyIt(it.isSlave and it.master == sel.pid)
  let choices = sel.candidates(all)
  proc label(pid: int): string =
    if pid == 0: "None"
    else: all.filterIt(it.pid == pid)[0].name
  var escUsed = false

  # The open list takes the pointer; a press elsewhere closes it.
  let px = r.x + ListW + 32
  let field = rect(px + LabelW, r.y + 46, r.x + r.w - 16 - px - LabelW, 28)
  let contentH = choices.len.float32 * EntryH
  let lh = min(contentH, r.y + r.h - 60 - (field.y + field.h)) + 2
  let lr = rect(field.x, field.y + field.h + 2, field.w, lh)
  if d.listOpen:
    let over = ui.mouse.inside(lr)
    if w.buttonPressed[KeyEscape]:
      d.listOpen = false
      escUsed = true
    elif ui.pressed() and not over:
      d.listOpen = false
      ui.consumeClick()
    elif over:
      if ui.scroll() != 0:
        d.listScroll += ui.scroll() * EntryH
        ui.scrollConsumed = true
      ui.captured = true
    d.listScroll = clamp(d.listScroll, 0, max(0'f32, contentH - (lr.h - 2)))
  let open = d.listOpen

  # Left: the players.
  ui.groupHeader(vec2(r.x + 16, r.y + 12), ListW, "Players")
  var y = r.y + 40
  for s in all:
    let ir = rect(r.x + 16, y, ListW, ItemH - 6)
    y += ItemH
    let hov = ui.hover(ir)
    if hov and ui.pressed():
      ui.consumeClick()
      if d.selected != s.pid:
        d.selected = s.pid
        d.listOpen = false
    ui.rect(ir, if s.pid == d.selected: colPressed elif hov: colHover else: colPanelRaised)
    if s.isMaster: ui.border(ir, groupColor(s.pid), 2)
    elif s.isSlave: ui.dashedBorder(ir, groupColor(s.master), 8, 5, 2)
    else: ui.border(ir, colBorder)
    ui.textIn(ui.ellipsize(s.name, ir.w - 20), rect(ir.x + 10, ir.y + 3, ir.w - 20, 20), colText)
    ui.textIn(ui.ellipsize(s.role(all), ir.w - 20, FontSmall),
      rect(ir.x + 10, ir.y + 21, ir.w - 20, 16), colTextDim, FontSmall)

  # Right: the selected player's properties.
  ui.groupHeader(vec2(px, r.y + 12), r.x + r.w - 16 - px, "Properties")
  ui.textIn("Master", rect(px, field.y, LabelW, field.h), colText)
  let fhov = not leads and ui.hover(field)
  if fhov and ui.pressed():
    ui.consumeClick()
    d.listOpen = not open
    d.listScroll = 0
  ui.rect(field, if leads: colPanel else: colBackground)
  ui.border(field, if open: colAccent elif fhov: colTextDim else: colBorder)
  let shown = if sel.isSlave: sel.master else: 0
  ui.textIn(ui.ellipsize(label(shown), field.w - 40), rect(field.x + 8, field.y, field.w - 40, field.h),
    if leads: colTextDisabled else: colText)
  ui.icon("expand16", vec2(field.x + field.w - 15, field.y + field.h / 2),
    if leads: colTextDisabled elif fhov: colText else: colTextDim)
  if leads: ui.tip(field, "It is a master: its slaves follow it")

  let oy = field.y + 44
  ui.textIn("Offset", rect(px, oy, LabelW, 28), colText)
  # The offset is kept in seconds. Without a frame rate it can only be shown so.
  let fps = sel.offsetFps(all)
  let seconds = d.useSeconds or fps <= 0
  let offsetR = rect(field.x, oy, 150, 28)
  var offset = if seconds: round(sel.offset * 1000) / 1000 else: round(sel.offset * fps)
  let changed =
    if seconds: ui.numberField("sy-offset", offsetR, offset, (if fps > 0: 1 / fps else: 0.5), -359999, 359999, 3)
    else: ui.numberField("sy-offset", offsetR, offset, 1, -359999 * fps, 359999 * fps)
  if changed:
    d.newOffset = if seconds: offset else: round(offset) / fps
    result = saOffset
  ui.textIn(if seconds: "seconds" else: "frames", rect(field.x + 158, oy, 80, 28), colTextDim, FontSmall)
  ui.tip(rect(px, oy, LabelW, 28), "How far ahead of the master, behind it when negative")

  let sy = oy + 36
  if ui.checkbox("sy-seconds", vec2(field.x, sy), "Use seconds", d.useSeconds):
    result = saSeconds
  ui.textIn(fpsLabel(fps), rect(field.x + 120, sy, r.x + r.w - 16 - field.x - 120, 20), colTextDim, FontSmall)

  var loop = sel.loop
  let ly = sy + 32
  if ui.checkbox("sy-loop", vec2(field.x, ly), "Continue looping", loop):
    d.newLoop = loop
    result = saLoop
  let note =
    if loop: ["Loops on its own after the offset", "until the master reaches its end."]
    else: ["Holds its last frame, then starts over once", "the master loops and reaches the offset."]
  for i, line in note:
    ui.textIn(line, rect(field.x, ly + 26 + i.float32 * 17, r.x + r.w - 16 - field.x, 17),
      colTextDim, FontSmall)
  if not sel.isSlave:
    ui.textIn("Offset and looping apply while it follows a master.",
      rect(px, ly + 80, r.x + r.w - 16 - px, 18), colTextDim, FontSmall)

  ui.rect(rect(r.x + 1, r.y + r.h - 50, r.w - 2, 1), colBorder)
  if ui.textButton("sy-close", rect(r.x + r.w - 112, r.y + r.h - 40, 92, 30), "Close", primary = true):
    result = saClose
  if not escUsed and not open and ui.focusId.len == 0 and w.buttonPressed[KeyEscape]:
    result = saClose

  # The open list, over everything.
  if d.listOpen and open:
    ui.captured = false
    ui.sk.pushLayer(PopupsLayer)
    ui.rect(rect(lr.xy + vec2(3, 4), lr.wh), colShadow)
    ui.rect(lr, colPopup)
    ui.border(lr, colAccent)
    let inner = rect(lr.x + 1, lr.y + 1, lr.w - 2, lr.h - 2)
    let outerClip = ui.hitClip
    ui.hitClip = inner
    ui.sk.pushClipRect(inner)
    for k, pid in choices:
      let rr = rect(inner.x, inner.y - d.listScroll + k.float32 * EntryH, inner.w, EntryH)
      if rr.y + rr.h < inner.y or rr.y > inner.y + inner.h: continue
      let hov = ui.hover(rr)
      let cur = pid == shown
      if cur: ui.rect(rr, colAccent)
      elif hov: ui.rect(rr, colHover)
      if pid != 0:
        ui.rect(rect(rr.x + 8, rr.y + 8, 10, 10), groupColor(pid))
      ui.textIn(ui.ellipsize(label(pid), rr.w - 36), rect(rr.x + 26, rr.y, rr.w - 36, EntryH),
        if cur: colOnAccent else: colText)
      if hov and ui.pressed():
        ui.consumeClick()
        d.listOpen = false
        if not cur:
          d.newMaster = pid
          result = saMaster
    ui.sk.popClipRect()
    ui.hitClip = outerClip
    if contentH > inner.h:
      let th = max(16'f32, inner.h * inner.h / contentH)
      let ty = inner.y + (inner.h - th) * (d.listScroll / (contentH - inner.h))
      ui.rect(rect(lr.x + lr.w - 4, ty, 3, th), colTrack)
    ui.sk.popLayer()
