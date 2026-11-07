## Non-blocking native file dialogs: startDialog shows one, and poll() each
## frame returns the result once it closes.

import std/os

type
  DialogKind* = enum
    dkOpenFiles, dkOpenFile, dkOpenDir, dkSaveFile

when defined(windows):
  include dialogs_win32
elif defined(macosx):
  include dialogs_macos
else:
  include dialogs_unix
