## Keeps the display awake while video plays (Options > Player), one
## implementation per platform with the same interface.

when defined(windows):
  import inhibit_win32
  export inhibit_win32
elif defined(macosx):
  import inhibit_macos
  export inhibit_macos
else:
  import inhibit_dbus
  export inhibit_dbus
