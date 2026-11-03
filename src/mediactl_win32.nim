## Thumbnail toolbar buttons (ITaskbarList3) in the preview shown when hovering
## the taskbar button, included by mediactl.nim: Previous, Play/Pause, Next.

import pixie, pixie/fileformats/png
import win32api, xwin, icons

type
  Guid = object
    a: uint32
    b, c: uint16
    d: array[8, uint8]
  ThumbButton = object  ## THUMBBUTTON
    mask, id, bitmap: uint32
    icon: HICON
    tip: array[260, uint16]
    flags: uint32
  Taskbar = object
    vtbl: ptr TaskbarVtbl
  ThumbBarCall = proc (this: ptr Taskbar, h: HWND, count: uint32,
                       buttons: ptr ThumbButton): HRESULT {.stdcall.}
  TaskbarVtbl = object  ## ITaskbarList3, in order, with its bases
    queryInterface, addRef, release: pointer
    hrInit: proc (this: ptr Taskbar): HRESULT {.stdcall.}
    addTab, deleteTab, activateTab, setActiveAlt, markFullscreenWindow: pointer
    setProgressValue, setProgressState, registerTab, unregisterTab, setTabOrder, setTabActive: pointer
    thumbBarAddButtons, thumbBarUpdateButtons: ThumbBarCall

  MediaControls* = ref object
    hwnd: HWND
    taskbar: ptr Taskbar
    created: uint32        ## the message Explorer sends once a button exists
    added: bool            ## the buttons are in place, to be updated from now on
    playIcon, pauseIcon, prevIcon, nextIcon: HICON
    state: MediaState
    pending: seq[MediaCommand]

const
  ClsidTaskbarList = Guid(a: 0x56FDF344'u32, b: 0xFD6D, c: 0x11D0,
    d: [0x95'u8, 0x8A, 0x00, 0x60, 0x97, 0xC9, 0xA0, 0x90])
  IidTaskbarList3 = Guid(a: 0xEA1AFB91'u32, b: 0x9E28, c: 0x4B86,
    d: [0x90'u8, 0xE9, 0x9E, 0x9F, 0x8A, 0x5E, 0xEF, 0xAF])
  ClsctxInprocServer = 1'u32
  WmCommand = 0x0111'u32
  ThbnClicked = 0x1800
  ThbIcon = 2'u32
  ThbTooltip = 4'u32
  ThbFlags = 8'u32
  ThbfDisabled = 1'u32
  SmCxSmIcon = 49'i32
  IdPrevious = 1'u32
  IdPlayPause = 2'u32
  IdNext = 3'u32

proc CoCreateInstance(clsid: ptr Guid, outer: pointer, context: uint32, iid: ptr Guid,
                      obj: ptr pointer): HRESULT {.stdcall, dynlib: "ole32", importc.}
proc RegisterWindowMessageW(name: ptr WCHAR): uint32 {.stdcall, dynlib: "user32", importc.}

proc makeIcon(name: string, size: int): HICON =
  let png = namedIcon(name, size).encodePng()
  CreateIconFromResourceEx(cast[PBYTE](png[0].unsafeAddr), png.len.DWORD, 1, 0x00030000, 0, 0, 0)

proc button(id: uint32, icon: HICON, tip: string, enabled: bool): ThumbButton =
  result = ThumbButton(mask: ThbIcon or ThbTooltip or ThbFlags, id: id, icon: icon,
                       flags: if enabled: 0 else: ThbfDisabled)
  let w = toWide(tip)
  copyMem(result.tip[0].addr, w[0].unsafeAddr, min(w.len, result.tip.len - 1) * 2)

proc apply(c: MediaControls) =
  ## Puts the buttons in the state's shape. Adding fails until the taskbar
  ## button exists, and later on too, after which only updating works.
  if c.taskbar == nil or c.hwnd == 0: return
  let s = c.state
  let playing = s.status == msPlaying
  var buttons = [
    button(IdPrevious, c.prevIcon, "Previous", s.canGoPrevious),
    button(IdPlayPause, if playing: c.pauseIcon else: c.playIcon,
           if playing: "Pause" else: "Play", if playing: s.canPause else: s.canPlay),
    button(IdNext, c.nextIcon, "Next", s.canGoNext)]
  let t = c.taskbar
  if not c.added:
    c.added = t.vtbl.thumbBarAddButtons(t, c.hwnd, buttons.len.uint32, buttons[0].addr) >= 0
    if c.added: return
  c.added = t.vtbl.thumbBarUpdateButtons(t, c.hwnd, buttons.len.uint32, buttons[0].addr) >= 0

proc onMessage(c: MediaControls, msg: UINT, wParam: WPARAM) =
  if msg == c.created:
    c.added = false  # the first time, or Explorer restarted
    c.apply()
  elif msg == WmCommand and ((wParam.int shr 16) and 0xFFFF) == ThbnClicked:
    case uint32(wParam.int and 0xFFFF)
    of IdPrevious: c.pending.add MediaCommand(kind: mcPrevious)
    of IdPlayPause: c.pending.add MediaCommand(kind: mcPlayPause)
    of IdNext: c.pending.add MediaCommand(kind: mcNext)
    else: discard

proc newMediaControls*(window: Window): MediaControls =
  ## Needs COM on this thread, which initMainWindow's OLE start gave it.
  let c = MediaControls()
  result = c
  var clsid = ClsidTaskbarList
  var iid = IidTaskbarList3
  var obj: pointer
  if CoCreateInstance(clsid.addr, nil, ClsctxInprocServer, iid.addr, obj.addr) < 0: return
  let t = cast[ptr Taskbar](obj)
  if t.vtbl.hrInit(t) < 0: return
  c.taskbar = t
  c.hwnd = window.getHWND
  let name = toWide("TaskbarButtonCreated")
  c.created = RegisterWindowMessageW(cast[ptr WCHAR](name[0].unsafeAddr))
  let size = GetSystemMetrics(SmCxSmIcon).int
  c.playIcon = makeIcon("play", size)
  c.pauseIcon = makeIcon("pause", size)
  c.prevIcon = makeIcon("prev", size)
  c.nextIcon = makeIcon("next", size)
  window.setMessageHook(proc (msg: UINT, wParam: WPARAM, lParam: LPARAM) =
    c.onMessage(msg, wParam))
  c.apply()  # the window is showing already, so TaskbarButtonCreated may be gone

proc poll*(c: MediaControls): seq[MediaCommand] =
  result = move c.pending

proc update*(c: MediaControls, s: MediaState, time: float) =
  let o = c.state
  let changed = s.status != o.status or s.canPlay != o.canPlay or s.canPause != o.canPause or
    s.canGoNext != o.canGoNext or s.canGoPrevious != o.canGoPrevious
  c.state = s
  if changed: c.apply()
