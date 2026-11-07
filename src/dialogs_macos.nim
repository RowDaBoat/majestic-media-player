## NSOpenPanel / NSSavePanel, shown without blocking (begin with a completion
## handler) so the main loop carries on. Included by dialogs.nim.

import cocoa

type
  Dialog* = ref object
    handle: pointer
    purpose*: string         # caller-defined tag, e.g. "open", "subtitle"

proc startDialog*(kind: DialogKind, purpose, title, startPath: string,
                  filterExts: seq[string] = @[], filterName = "",
                  extraFilters: seq[(string, seq[string])] = @[]): Dialog =
  ## The panels have no filter choice: they allow the extensions of every
  ## filter given (any file when none are).
  var exts = filterExts
  for (_, more) in extraFilters:
    for e in more:
      if e notin exts: exts.add e
  let arr = allocCStringArray(exts)
  defer: deallocCStringArray(arr)
  Dialog(purpose: purpose,
    handle: mmpDialogStart(kind.ord.cint, title.cstring, startPath.cstring, arr, exts.len.cint))

proc poll*(d: Dialog, done: var bool): seq[string] =
  ## Returns the selected paths once the dialog has closed (empty if cancelled).
  done = d == nil or d.handle == nil
  if done or mmpDialogDone(d.handle) == 0: return
  done = true
  for i in 0 ..< mmpDialogCount(d.handle):
    result.add $mmpDialogPath(d.handle, i)
  mmpDialogFree(d.handle)
  d.handle = nil
