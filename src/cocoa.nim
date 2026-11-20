## Bindings to cocoa.m, the macOS helpers behind xwin_macos, dialogs_macos,
## inhibit_macos, mediactl_macos and audiotap.

{.compile("cocoa.m", "-fobjc-arc").}
{.passL: "-framework Cocoa -framework QuartzCore -framework IOKit -framework MediaPlayer -framework CoreAudio -framework UniformTypeIdentifiers -framework CoreServices".}

type
  MmpInput* {.bycopy.} = object
    activity*, leftPressed*, leftReleased*, anyPressed*: cint

  MmpMediaCommand* {.bycopy.} = object
    kind*: cint
    value*: cdouble

{.push importc, cdecl.}
proc mmpScale*(): cdouble
proc mmpFramePos*(win: pointer, x, y: var cint)
proc mmpMoveFrame*(win: pointer, x, y: cint)
proc mmpMonitorCount*(): cint
proc mmpMonitor*(i: cint, x, y, w, h: var cint)
proc mmpPointer*(x, y: var cint)
proc mmpPressedButtons*(): culong
proc mmpModifiers*(): culong
proc mmpActivate*(win: pointer)
proc mmpSetDecorated*(win: pointer, on: cint)
proc mmpSetOnTop*(win: pointer, on: cint)
proc mmpSetMinSize*(win: pointer, w, h: cint)
proc mmpSetDialogFor*(win, parent: pointer)
proc mmpPlaceDialog*(win: pointer, x, y, w, h, minW, minH: cint)
proc mmpDisableVsync*(win: pointer)
proc mmpTrackWindow*(win: pointer, edge: cint)
proc mmpSetDiagonalCursor*(nwse: cint)
proc mmpGlProc*(name: cstring): pointer
proc mmpPopupNew*(r, g, b: uint8): pointer
proc mmpPopupShow*(p: pointer, x, y, w, h: cint)
proc mmpPopupHide*(p: pointer)
proc mmpPopupPut*(p: pointer, w, h: cint, bgra: ptr uint8)
proc mmpPopupTakeInput*(p: pointer, into: var MmpInput)
proc mmpWindowPut*(win: pointer, w, h: cint, bgra: ptr uint8)
proc mmpDialogStart*(kind: cint, title, startPath: cstring, exts: cstringArray,
                     extCount: cint): pointer
proc mmpDialogDone*(d: pointer): cint
proc mmpDialogCount*(d: pointer): cint
proc mmpDialogPath*(d: pointer, i: cint): cstring
proc mmpDialogFree*(d: pointer)
proc mmpInhibit*(on: cint)
proc mmpMediaInit*()
proc mmpMediaPoll*(cmd: var MmpMediaCommand): cint
proc mmpMediaUpdate*(status: cint, title, artist, album: cstring,
                     position, duration, rate: cdouble,
                     canPlay, canPause, canSeek, canNext, canPrevious: cint)
proc mmpBundleId*(buf: cstring, len: cint): cint
proc mmpUtiForExt*(ext, buf: cstring, len: cint): cint
proc mmpIsDefaultFor*(uti: cstring): cint
proc mmpSetDefaultFor*(uti: cstring, on: cint): cint
proc mmpTapStart*()
proc mmpTapStop*()
proc mmpTapLatest*(left, right: ptr float32, n: cint): cint
{.pop.}
