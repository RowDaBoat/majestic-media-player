## macOS (Cocoa) counterparts of xwin_x11's window helpers: interactive move
## and resize, always-on-top, a hidden cursor and the borderless popup windows
## menus are drawn into. The Cocoa side lives in cocoa.m.
##
## Screen positions are global pixels as on X11: from the top-left of the
## primary screen, in points times its backing scale (see cocoa.m).

import std/importutils
import windy, vmath, pixie, chroma
import cocoa

proc ns(window: Window): pointer = cast[pointer](window.nativeWindow)

proc initMainWindow*(window: Window) = discard

proc disableVsync*(window: Window) =
  ## Windy sets the swap interval as asked already; this makes sure.
  mmpDisableVsync(window.ns)

type WindowEdge* = enum
  ## Ordered as _NET_WM_MOVERESIZE's size directions (and cocoa.m's edges).
  weTopLeft, weTop, weTopRight, weRight, weBottomRight, weBottom, weBottomLeft, weLeft

proc releasedLeft(window: Window) =
  ## The tracking loop swallowed the release; clear Windy's button state to
  ## match (as on X11, where the window manager takes the pointer).
  privateAccess(Window)
  window.state.buttonDown.excl MouseLeft

proc startWindowDrag*(window: Window) =
  ## Moves the window with the pointer until the left button is released.
  mmpTrackWindow(window.ns, -1)
  window.releasedLeft()

proc startWindowResize*(window: Window, edge: WindowEdge) =
  ## Resizes the window from edge until the left button is released (for
  ## undecorated windows; macOS usually resizes those from their edges itself).
  mmpTrackWindow(window.ns, edge.ord.cint)
  window.releasedLeft()

proc setDecorated*(window: Window, on: bool) =
  ## Shows or hides the title bar, keeping the content's size and place.
  mmpSetDecorated(window.ns, on.cint)

proc activate*(window: Window) =
  ## Brings the app forward and makes window key.
  mmpActivate(window.ns)

proc framePos*(window: Window): IVec2 =
  ## Screen position of the window's outer (title bar) top-left corner.
  var x, y: cint
  mmpFramePos(window.ns, x, y)
  ivec2(x, y)

proc moveFrame*(window: Window, pos: IVec2) =
  ## Places the outer top-left corner at pos.
  mmpMoveFrame(window.ns, pos.x, pos.y)

proc setAlwaysOnTop*(window: Window, on: bool) =
  mmpSetOnTop(window.ns, on.cint)

proc setAspectHints*(window: Window, aspect: float, chrome: IVec2, minSize: IVec2) =
  ## Cocoa can only hold the whole content to an aspect, not the part left
  ## after chrome, so like on Windows only the minimum size applies: Fit
  ## letterboxes the video in whatever shape the window is given.
  mmpSetMinSize(window.ns, minSize.x, minSize.y)

proc setDialogFor*(window, parent: Window, modal = true) =
  mmpSetDialogFor(window.ns, parent.ns)

proc keepContentsOnResize*(window: Window, background: ColorRGBX) =
  ## Cocoa keeps the window's picture while it is resized already.
  discard

proc placeDialog*(window: Window, pos, size: IVec2, minSize = ivec2(0, 0)) =
  ## Sizes the window and puts its outer top-left corner at pos. The size is
  ## fixed, unless minSize is given: then the user can resize it down to that.
  mmpPlaceDialog(window.ns, pos.x, pos.y, size.x, size.y, minSize.x, minSize.y)

proc monitorAt*(point: IVec2): tuple[pos, size: IVec2] =
  ## Screen rect of the monitor holding point, else the primary one.
  result = (ivec2(0, 0), ivec2(1920, 1080))
  for i in 0 ..< mmpMonitorCount():
    var x, y, w, h: cint
    mmpMonitor(i, x, y, w, h)
    let r = (ivec2(x, y), ivec2(w, h))
    if i == 0: result = r
    if point.x >= x and point.x < x + w and point.y >= y and point.y < y + h:
      return r

proc monitorSize*(window: Window): IVec2 =
  ## Size of the monitor that holds the window centre.
  monitorAt(window.pos + window.size div 2).size

proc pointerPos*(window: Window): tuple[screen, local: IVec2] =
  ## Pointer position on screen and relative to the window's content.
  var x, y: cint
  mmpPointer(x, y)
  let screen = ivec2(x, y)
  (screen, screen - window.pos)

proc pointerButtonsDown*(): bool =
  ## Whether the left, middle or right mouse button is held anywhere.
  (mmpPressedButtons() and 7) != 0

const
  ShiftFlag = 1'u shl 17
  ControlFlag = 1'u shl 18

proc ctrlHeld*(): bool =
  ## Whether Ctrl is held, even while another window has the keyboard.
  (mmpModifiers().uint and ControlFlag) != 0

proc shiftHeld*(): bool =
  ## Whether Shift is held, even while another window has the keyboard.
  (mmpModifiers().uint and ShiftFlag) != 0

proc grabPointer*(window: Window): bool =
  ## Cocoa has no pointer grabs: clicks outside the app are caught as focus
  ## loss instead, and the popups never take the focus from the main window.
  false

proc ungrabPointer*() = discard

proc setDiagonalCursor*(window: Window, nwse: bool) =
  ## A diagonal resize cursor, set behind Windy's back: its next cursor=
  ## replaces it.
  mmpSetDiagonalCursor(nwse.cint)

proc clearDiagonalCursor*(window: Window) = discard

var hiddenCursorImage: Image

proc hiddenCursor*(): Cursor =
  if hiddenCursorImage == nil:
    hiddenCursorImage = newImage(1, 1)
  Cursor(kind: CustomCursor, image: hiddenCursorImage, hotspot: ivec2(0, 0))

# --- popup windows ------------------------------------------------------------

type
  PopupWindow* = ref object
    ## Borderless window at the pop-up menu level that never takes the
    ## keyboard, so it can extend past the main window. Its picture is drawn
    ## by the main window's GL context and put in as a layer's contents.
    handle: pointer
    pos, size*: IVec2

  PopupInput* = object
    activity*: bool          ## any pointer event arrived
    leftPressed*, leftReleased*, anyPressed*: bool

proc newPopupWindow*(background: ColorRGBX): PopupWindow =
  let c = background  # opaque, so premultiplied == straight
  PopupWindow(handle: mmpPopupNew(c.r, c.g, c.b), pos: ivec2(-1, -1))

proc show*(p: PopupWindow, pos, size: IVec2) =
  p.pos = pos
  p.size = size
  mmpPopupShow(p.handle, pos.x, pos.y, size.x, size.y)

proc hide*(p: PopupWindow) =
  mmpPopupHide(p.handle)

proc putPixels*(p: PopupWindow, bgra: openArray[uint8]) =
  ## Shows a p.size image (BGRA, top row first) in the popup.
  if p.size.x <= 0 or p.size.y <= 0 or bgra.len < p.size.x * p.size.y * 4: return
  mmpPopupPut(p.handle, p.size.x, p.size.y, bgra[0].unsafeAddr)

proc putPixels*(window: Window, size: IVec2, bgra: openArray[uint8]) =
  ## Shows a size big image (BGRA, top row first) in the window.
  if size.x <= 0 or size.y <= 0 or bgra.len < size.x * size.y * 4: return
  mmpWindowPut(window.ns, size.x, size.y, bgra[0].unsafeAddr)

proc pollInput*(popups: openArray[PopupWindow], input: var PopupInput) =
  ## Collects the pointer events the popups saw since the last call.
  var got: MmpInput
  for p in popups: mmpPopupTakeInput(p.handle, got)
  input.activity = input.activity or got.activity != 0
  input.leftPressed = input.leftPressed or got.leftPressed != 0
  input.leftReleased = input.leftReleased or got.leftReleased != 0
  input.anyPressed = input.anyPressed or got.anyPressed != 0
