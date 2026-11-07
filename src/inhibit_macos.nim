## Keeps the display awake with an IOKit power assertion (PreventUserIdleDisplaySleep),
## held by the process until released.

import cocoa

type
  Inhibitor* = object
    wanted: bool   ## last state asked for

proc set*(ih: var Inhibitor, on: bool) =
  ## Inhibits or releases; cheap to call every frame, as it only acts on change.
  if on == ih.wanted: return
  ih.wanted = on
  mmpInhibit(on.cint)
