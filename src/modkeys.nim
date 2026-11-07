## The shortcut modifier: Ctrl, and on macOS Cmd as well (Ctrl still counts
## there, for Ctrl+Tab and the like: the system keeps Cmd+Tab for itself).
## Shortcuts are written "Ctrl+..." throughout and shown "Cmd+..." on macOS.

import std/strutils
import windy

const CtrlName* = when defined(macosx): "Cmd" else: "Ctrl"
  ## How the modifier is named in shortcuts shown to the user.

proc ctrlDown*(w: Window): bool =
  ## Whether the shortcut modifier is held.
  result = w.buttonDown[KeyLeftControl] or w.buttonDown[KeyRightControl]
  when defined(macosx):
    result = result or w.buttonDown[KeyLeftSuper] or w.buttonDown[KeyRightSuper]

proc keyLabel*(s: string): string =
  ## A shortcut written with Ctrl as this platform names it.
  when defined(macosx): s.replace("Ctrl+", CtrlName & "+") else: s
