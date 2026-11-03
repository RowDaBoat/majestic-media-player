## File associations: makes the player the default application for media
## types, through the XDG mimeapps.list on Linux and the registry on Windows.

import std/[os, algorithm]
import config
import appimage

type AssocItem* = object
  ext*: string
  mimes*: seq[string]       ## empty: the MIME database doesn't know the type
  video*: bool
  checked*: bool            ## wanted state, applied by applyAssociations
  current*: bool            ## state in the system when loaded

proc setChecked*(items: var seq[AssocItem], i: int, on: bool) =
  ## Checks or unchecks item i together with every item sharing a MIME type.
  var mimes = items[i].mimes
  var changed = true
  while changed:  # follow chains like ogv -> video/ogg -> ogg -> audio/ogg -> opus
    changed = false
    for it in items:
      var shares = false
      for m in it.mimes:
        if m in mimes: shares = true
      if shares:
        for m in it.mimes:
          if m notin mimes:
            mimes.add m
            changed = true
  for it in items.mitems:
    if it.mimes.len == 0: continue
    for m in it.mimes:
      if m in mimes:
        it.checked = on
        break
  items[i].checked = on and items[i].mimes.len > 0

proc pending*(items: seq[AssocItem]): bool =
  for it in items:
    if it.checked != it.current: return true

when defined(windows):
  include assoc_win32
else:
  include assoc_xdg
