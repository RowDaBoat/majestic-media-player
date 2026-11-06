## Menu bar + popup menus with separators, shortcuts, check/radio items and
## nested submenus. The menu tree is rebuilt every frame from app state, so
## checkmarks and dynamic lists (tracks, recent files) are always current.
## Each open popup level is its own override-redirect window, so menus can
## extend past the main window; layout and hit testing happen in main-window
## coordinates, which may lie outside the window.

import std/math
import silky, vmath, bumpy, pixie
import theme, ui, xwin

type
  MenuKind* = enum
    mkAction, mkCheck, mkRadio, mkSeparator, mkSub,
    mkColumn                  ## a column of a `columns` popup, its label a heading

  MenuNode* = ref object
    label*, shortcut*: string
    kind*: MenuKind
    checked*, enabled*: bool
    children*: seq[MenuNode]
    action*: proc ()
    remove*: proc ()          ## set: a cross at the row's right end runs it
    lock*: proc ()            ## set: a lock there instead, toggled by it
    locked*: bool             ## that lock is closed
    columns*: bool            ## its children (mkColumn) sit side by side
    contextual*: bool         ## about what's open: drawn on a purple ground
    listed*: bool             ## one of a list (files, tracks...): the command
                              ## palette shows it only inside its own submenu
    width: float32            ## mkColumn: as laid out (popupSize)

  MenuMode = enum
    mmClosed, mmBar, mmContext

  PopupLevel = object
    node: MenuNode
    rect: Rect                ## main-window coordinates

  MenuSystem* = ref object
    mode: MenuMode
    barIndex: int             ## open top-level menu in bar mode
    path: seq[int]            ## open submenu index per popup depth
    contextPos: Vec2
    sticky: bool              ## context menu stays open through clicks, until
                              ## the pointer leaves it and `keep`
    keep: Rect                ## what opened it (a button), main-window coordinates
    above: bool               ## context menu opens above contextPos
    barRects: seq[Rect]
    levels: seq[PopupLevel]   ## last frame's popups, for input capture
    windows: seq[PopupWindow] ## one per depth, reused across opens
    input: PopupInput         ## popup-window clicks since the last frame
    mouse: Vec2               ## pointer in main-window coordinates
    origin: Vec2              ## main window's content origin on screen (pixels)
    bounds: Rect              ## monitor the menus open on, main-window coordinates
    boundsValid: bool
    grabbed: bool             ## holds the pointer grab taken while open
    pendingAction: proc ()
    pendingRemove: proc ()

proc newMenuSystem*(): MenuSystem = MenuSystem()

# --- tree building ---------------------------------------------------------

proc newMenuRoot*(): MenuNode = MenuNode(kind: mkSub, enabled: true)

proc sub*(parent: MenuNode, label: string, enabled = true): MenuNode =
  result = MenuNode(label: label, kind: mkSub, enabled: enabled)
  parent.children.add result

proc item*(parent: MenuNode, label: string, shortcut = "", enabled = true,
           action: proc () = nil, remove: proc () = nil) =
  parent.children.add MenuNode(label: label, shortcut: shortcut, kind: mkAction,
    enabled: enabled, action: action, remove: remove)

proc check*(parent: MenuNode, label: string, shortcut = "", checked: bool,
            enabled = true, action: proc () = nil) =
  parent.children.add MenuNode(label: label, shortcut: shortcut, kind: mkCheck,
    checked: checked, enabled: enabled, action: action)

proc radio*(parent: MenuNode, label: string, shortcut = "", checked: bool,
            enabled = true, action: proc () = nil, lock: proc () = nil, locked = false) =
  parent.children.add MenuNode(label: label, shortcut: shortcut, kind: mkRadio,
    checked: checked, enabled: enabled, action: action, lock: lock, locked: locked)

proc column*(parent: MenuNode, label: string): MenuNode =
  result = MenuNode(label: label, kind: mkColumn, enabled: true)
  parent.children.add result

proc sep*(parent: MenuNode) =
  parent.children.add MenuNode(kind: mkSeparator)

proc markContextual*(parent: MenuNode) =
  ## Makes the items added so far contextual, with the separators between
  ## them (not a trailing one), so they read as one purple block.
  var last = parent.children.high
  while last >= 0 and parent.children[last].kind == mkSeparator: dec last
  for i in 0 .. last: parent.children[i].contextual = true

proc markListed*(parent: MenuNode, first = 0) =
  ## Marks the items from index first on as a list (MenuNode.listed).
  for i in first ..< parent.children.len:
    if parent.children[i].kind != mkSeparator: parent.children[i].listed = true

# --- state ---------------------------------------------------------------------

proc isOpen*(m: MenuSystem): bool = m.mode != mmClosed

proc contextOpen*(m: MenuSystem): bool = m.mode == mmContext

proc contextAnchor*(m: MenuSystem): Vec2 = m.contextPos

proc contextRect*(m: MenuSystem): Rect =
  ## The open context menu's top level as last laid out, or empty.
  if m.mode == mmContext and m.levels.len > 0: m.levels[0].rect else: Rect()

proc close*(m: MenuSystem) =
  m.mode = mmClosed
  m.path.setLen 0
  m.levels.setLen 0
  m.boundsValid = false
  for w in m.windows: w.hide()

proc openBar*(m: MenuSystem, barIndex: int, path: seq[int] = @[]) =
  m.mode = mmBar
  m.barIndex = barIndex
  m.path = path

proc openContext*(m: MenuSystem, pos: Vec2, sticky = false, keep = Rect(), above = false) =
  ## `sticky`: picking items leaves it open; it closes once the pointer is
  ## away from it and from `keep`. `above`: it opens upward from pos.
  m.mode = mmContext
  m.contextPos = pos
  m.path = @[]
  m.sticky = sticky
  m.keep = keep
  m.above = above

proc pollInput*(m: MenuSystem): bool =
  ## Call after pollEvents every loop iteration. Collects clicks on the popup
  ## windows; returns true when they saw pointer activity (redraw needed).
  m.input.activity = false
  m.windows.pollInput(m.input)
  # Keep the grab until the press that closed the menus is released, so the
  # release still reaches the main window (Windy would think it held otherwise).
  if m.grabbed and m.mode == mmClosed and not pointerButtonsDown():
    m.grabbed = false
    ungrabPointer()
  m.input.activity

proc overMenu(m: MenuSystem, p: Vec2): bool =
  for lv in m.levels:
    if p.inside(lv.rect): return true
  if m.mode == mmBar:
    for r in m.barRects:
      if p.inside(r): return true

proc pointerOverPopup*(m: MenuSystem, ui: Ui): bool =
  ## Live check (not last frame's pointer), for focus-change handling.
  let local = ui.window.pointerPos.local.vec2 / ui.scale
  for lv in m.levels:
    if local.inside(lv.rect): return true

proc captureInput*(m: MenuSystem, ui: Ui) =
  ## Call at the start of the frame, before other widgets. Claims the mouse
  ## when it is over an open menu and closes menus on outside clicks.
  m.mouse = ui.mouse
  if m.mode == mmClosed: return
  # The main window stops seeing the pointer once it enters a popup window,
  # so ask the server where it is.
  let (screen, local) = ui.window.pointerPos
  m.origin = (screen - local).vec2
  if ui.fakeMouse.x < 0: m.mouse = local.vec2 / ui.scale
  if not m.boundsValid:
    m.boundsValid = true
    let mon = monitorAt(screen)
    m.bounds = rect((mon.pos.vec2 - m.origin) / ui.scale, mon.size.vec2 / ui.scale)
  if m.mode == mmContext and m.sticky and m.levels.len > 0:
    const Near = 24'f32  # how far the pointer may stray
    proc grown(r: Rect): Rect = rect(r.x - Near, r.y - Near, r.w + 2 * Near, r.h + 2 * Near)
    var near = m.mouse.inside(m.keep.grown)
    for lv in m.levels:  # its submenus too
      if m.mouse.inside(lv.rect.grown): near = true
    if not near:
      m.close()
      return
  if m.overMenu(m.mouse) or m.input.anyPressed:
    ui.captured = true
  elif ui.window.buttonPressed[MouseLeft] or ui.window.buttonPressed[MouseRight] or
       ui.window.buttonPressed[MouseMiddle]:
    m.close()
    ui.consumeClick()
    ui.captured = true
  if ui.window.buttonPressed[KeyEscape]:
    m.close()

# --- layout & drawing ------------------------------------------------------

const
  padX = 10'f32
  checkW = 24'f32
  arrowW = 22'f32
  shortcutGap = 36'f32

proc popupSize(ui: Ui, node: MenuNode): Vec2 =
  if node.columns:
    # Columns as narrow as their labels: a check, the label, a margin.
    var w = 8'f32
    var rowsN = 0
    for col in node.children:
      var labelW = ui.textSize(col.label).x
      var lockW = 0'f32
      for c in col.children:
        labelW = max(labelW, ui.textSize(c.label).x)
        if c.lock != nil: lockW = arrowW
      col.width = ceil(checkW + labelW + padX + lockW)
      w += col.width
      rowsN = max(rowsN, col.children.len + 1)
    return vec2(w, ceil(8 + rowsN.float32 * MenuRowHeight))
  var labelW, scW = 0'f32
  var h = 8'f32
  for c in node.children:
    if c.kind == mkSeparator:
      h += MenuSeparatorHeight
    else:
      labelW = max(labelW, ui.textSize(c.label).x)
      if c.shortcut.len > 0: scW = max(scW, ui.textSize(c.shortcut).x)
      h += MenuRowHeight
  let w = checkW + labelW + (if scW > 0: shortcutGap + scW else: 0) + arrowW + padX
  vec2(ceil(max(w, 160)), ceil(h))

proc removeRect(row: Rect): Rect =
  ## The cross of a removable row, in the space submenu arrows use.
  rect(row.x + row.w - arrowW - 2, row.y + 2, arrowW, row.h - 4)

iterator rows(node: MenuNode, r: Rect): (int, MenuNode, Rect) =
  ## Each child's row inside a popup at r (separators get a short row); of
  ## columns, each one's heading (the mkColumn) and then its items.
  if node.columns:
    var x = r.x + 4
    var i = 0
    for col in node.children:
      var y = r.y + 4
      for c in @[col] & col.children:
        yield (i, c, rect(x, y, col.width, MenuRowHeight))
        y += MenuRowHeight
        inc i
      x += col.width
  else:
    var y = r.y + 4
    for i, c in node.children:
      let h = if c.kind == mkSeparator: MenuSeparatorHeight else: MenuRowHeight
      yield (i, c, rect(r.x + 4, y, r.w - 8, h))
      y += h

proc placePopup(m: MenuSystem, ui: Ui, node: MenuNode, anchor: Rect,
                depth: int, below: bool) =
  ## Places one popup level and recurses into its open submenu, if any.
  let size = popupSize(ui, node)
  let b = m.bounds
  var pos =
    if depth == 0 and m.mode == mmContext and m.above: vec2(anchor.x, max(b.y, anchor.y - size.y))
    elif below: vec2(anchor.x, anchor.y + anchor.h)
    else: vec2(anchor.x + anchor.w - 2, anchor.y - 4)
  if pos.x + size.x > b.x + b.w:
    pos.x = if below: b.x + b.w - size.x else: anchor.x - size.x + 2
  pos.x = max(pos.x, b.x)
  if pos.y + size.y > b.y + b.h:
    pos.y = max(b.y, b.y + b.h - size.y)
  let r = rect(round(pos.x), round(pos.y), size.x, size.y)
  m.levels.add PopupLevel(node: node, rect: r)
  if m.path.len > depth:
    let i = m.path[depth]
    if i in 0 ..< node.children.len and node.children[i].kind == mkSub:
      for (j, _, row) in rows(node, r):
        if j == i:
          m.placePopup(ui, node.children[i], row, depth + 1, false)
          break

proc topLevelAt(m: MenuSystem, p: Vec2): int =
  ## The deepest popup under p (a flipped submenu can cover an ancestor), or -1.
  result = -1
  for d in countdown(m.levels.high, 0):
    if p.inside(m.levels[d].rect): return d

proc layoutPopups(m: MenuSystem, ui: Ui, node: MenuNode, anchor: Rect,
                  below: bool, released: bool) =
  ## Places the open popups, then tracks hover/open submenus and clicks in the
  ## topmost popup under the pointer only.
  m.levels.setLen 0
  m.placePopup(ui, node, anchor, 0, below)
  let d = m.topLevelAt(m.mouse)
  if d < 0: return
  let lv = m.levels[d]
  for (i, c, row) in rows(lv.node, lv.rect):
    if c.kind in {mkSeparator, mkColumn} or not c.enabled or not m.mouse.inside(row): continue
    if c.kind == mkSub:
      if not (m.path.len > d and m.path[d] == i):
        m.path.setLen d
        m.path.add i
        m.levels.setLen 0
        m.placePopup(ui, node, anchor, 0, below)
    else:
      if m.path.len > d:
        m.path.setLen d
        m.levels.setLen d + 1
      if released:
        if c.remove != nil and m.mouse.inside(removeRect(row)):
          m.pendingRemove = c.remove
        elif c.lock != nil and m.mouse.inside(removeRect(row)):
          m.pendingRemove = c.lock  # the menu stays open, as removing does
        elif c.action != nil:
          m.pendingAction = c.action

proc drawPopup(m: MenuSystem, ui: Ui, lv: PopupLevel, depth: int) =
  ## Draws one popup level into its own window, i.e. at the origin.
  let r = rect(vec2(0, 0), lv.rect.wh)
  let mouse = m.mouse - lv.rect.xy
  let top = m.topLevelAt(m.mouse) == depth
  ui.rect(r, colPopup)
  ui.border(r, colBorder)
  for (i, c, row) in rows(lv.node, r):
    if c.kind == mkSeparator:
      if c.contextual: ui.rect(row, colContextual)
      ui.rect(rect(row.x + 4, row.y + row.h / 2, row.w - 8, 1), colBorder)
      continue
    if c.kind == mkColumn:
      ui.textIn(c.label, rect(row.x + checkW, row.y, row.w, row.h), colTextDim)
      if row.x > r.x + 4:  # a line between columns
        ui.rect(rect(row.x, r.y + 6, 1, r.h - 12), colBorder)
      continue
    let hov = c.enabled and top and mouse.inside(row)
    let isOpenSub = c.kind == mkSub and m.path.len > depth and m.path[depth] == i
    if hov or isOpenSub:
      ui.rect(row, if c.contextual: colContextualHover else: colHover)
    elif c.contextual:
      ui.rect(row, colContextual)
    let fg = if c.enabled: colText else: colTextDisabled
    if c.checked:
      let ic = if c.kind == mkRadio: "radio16" else: "check16"
      ui.icon(ic, vec2(row.x + checkW / 2 + 2, row.y + row.h / 2),
        if c.enabled: colAccent else: colTextDisabled)
    ui.textIn(c.label, rect(row.x + checkW, row.y, row.w, row.h), fg)
    if c.shortcut.len > 0:
      ui.textIn(c.shortcut, rect(row.x, row.y, row.w - arrowW, row.h),
        if c.enabled: colTextDim else: colTextDisabled, h = RightAlign)
    if c.remove != nil and c.enabled:
      let xr = removeRect(row)
      let xHov = top and mouse.inside(xr)
      if xHov: ui.rect(xr, colPressed)
      ui.icon("close16", xr.xy + xr.wh / 2, if xHov: colText else: colTextDim)
    if c.lock != nil and c.enabled:
      let xr = removeRect(row)
      let xHov = top and mouse.inside(xr)
      if xHov: ui.rect(xr, colPressed)
      ui.icon(if c.locked: "lock16" else: "unlock16", xr.xy + xr.wh / 2,
        if c.locked: colAccent elif xHov: colText else: colTextDim)
    if c.kind == mkSub:
      ui.icon("arrow16", vec2(row.x + row.w - arrowW / 2, row.y + row.h / 2), fg)

proc drawBar*(m: MenuSystem, ui: Ui, root: MenuNode, bar: Rect) =
  ## Draws the menu bar strip. Popups are laid out by updatePopups and drawn
  ## by renderPopups.
  ui.rect(bar, colPanel)
  ui.rect(rect(bar.x, bar.y + bar.h - 1, bar.w, 1), colBorder)
  m.barRects.setLen 0
  var x = bar.x + 4
  for i, c in root.children:
    let w = ui.textSize(c.label).x + 20
    let r = rect(x, bar.y + 2, w, bar.h - 4)
    m.barRects.add r
    let hov = m.mouse.inside(r) and (m.mode != mmContext) and
      (m.mode == mmBar or not ui.captured)
    let open = m.mode == mmBar and m.barIndex == i
    if hov and ui.window.buttonPressed[MouseLeft]:
      if open: m.close()
      else:
        m.mode = mmBar
        m.barIndex = i
        m.path.setLen 0
      ui.consumeClick()
    elif hov and m.mode == mmBar and not open:
      m.barIndex = i
      m.path.setLen 0
    let isOpen = m.mode == mmBar and m.barIndex == i
    if isOpen: ui.rect(r, colPressed)
    elif hov: ui.rect(r, colHover)
    ui.textIn(c.label, r, colText, h = CenterAlign)
    x += w

proc updatePopups*(m: MenuSystem, ui: Ui, root, contextRoot: MenuNode) =
  ## Lays out open popups, handles hover and runs a clicked action.
  let released = ui.window.buttonReleased[MouseLeft] or m.input.leftReleased
  m.input = PopupInput()
  m.levels.setLen 0
  case m.mode
  of mmBar:
    if m.barIndex < m.barRects.len:
      m.layoutPopups(ui, root.children[m.barIndex], m.barRects[m.barIndex], true, released)
  of mmContext:
    m.layoutPopups(ui, contextRoot, rect(m.contextPos, vec2(0, 0)), true, released)
  of mmClosed: discard
  if m.pendingRemove != nil:
    # Removing keeps the menu open, so several entries can go in a row.
    let rm = m.pendingRemove
    m.pendingRemove = nil
    rm()
  if m.pendingAction != nil:
    let a = m.pendingAction
    m.pendingAction = nil
    if not (m.mode == mmContext and m.sticky): m.close()
    a()

proc renderPopups*(m: MenuSystem, ui: Ui,
                   onDrawn: proc (level: int, image: Image) = nil, main: Window = nil) =
  ## Shows one window per open level and draws it. Call outside the main
  ## window's beginUi/endUi, right after its swap; onDrawn gets each popup's
  ## image (for screenshots). `main`: the window whose GL context draws them,
  ## when the menus belong to another (a dialog's); else ui's.
  ## While open, menus grab the pointer: presses anywhere then reach the main
  ## window, where captureInput closes the menus if they fall outside them.
  let main = if main != nil: main else: ui.window
  if m.levels.len > 0 and not m.grabbed:
    m.grabbed = ui.window.grabPointer()
  for i, lv in m.levels:
    if i >= m.windows.len: m.windows.add newPopupWindow(colPopup)
    let w = m.windows[i]
    let screen = m.origin + lv.rect.xy * ui.scale
    let size = lv.rect.wh * ui.scale
    w.show(ivec2(int32(round(screen.x)), int32(round(screen.y))),
      ivec2(int32(ceil(size.x)), int32(ceil(size.y))))
    when defined(windows):
      if not w.beginDraw(): continue  # retried next frame
      ui.sk.beginUi(ui.window, w.size)
      m.drawPopup(ui, lv, i)
      ui.sk.endUi()
      if onDrawn != nil: onDrawn(i, readFramebuffer(w.size))
      w.endDraw(main)
    else:
      # Drawn in the main window's buffer and put into the popup by X: no GL
      # buffers of its own (see xwin_x11's putPixelsOn).
      ui.sk.beginOffscreen(main.size, w.size, colPopup)
      ui.sk.beginUi(ui.window, w.size)
      m.drawPopup(ui, lv, i)
      ui.sk.endUi()
      ui.sk.endOffscreen()
      w.putPixels(offscreenPixels())
      if onDrawn != nil: onDrawn(i, offscreenImage(w.size))
  for i in m.levels.len ..< m.windows.len:
    m.windows[i].hide()
