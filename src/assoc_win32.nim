## Windows side of assoc.nim (included there). The player registers a ProgID
## and its capabilities under HKEY_CURRENT_USER (no admin rights needed),
## and a checked extension points at that ProgID. Windows lets the user's
## own choice in Settings > Default apps override it, and only the user may
## change that choice; userOverrides lists the extensions where they did.

import win32api

const
  ProgId = "MajesticMediaPlayer.Media"
  AppKey = r"Software\MajesticMediaPlayer"
  AppTitle = "Majestic Media Player"
  HKEY_CURRENT_USER = cast[HANDLE](0x80000001'u)
  KEY_READ = 0x20019'i32
  KEY_WRITE = 0x20006'i32
  REG_SZ = 1'i32
  RRF_RT_REG_SZ = 0x2'i32
  SHCNE_ASSOCCHANGED = 0x08000000'i32

proc RegCreateKeyExW(key: HANDLE, sub: ptr WCHAR, reserved: int32, class: ptr WCHAR,
  options, sam: int32, sec: pointer, res: ptr HANDLE, disp: ptr int32): int32 {.stdcall, importc, dynlib: "advapi32".}
proc RegSetValueExW(key: HANDLE, name: ptr WCHAR, reserved, kind: int32,
  data: pointer, size: int32): int32 {.stdcall, importc, dynlib: "advapi32".}
proc RegGetValueW(key: HANDLE, sub, name: ptr WCHAR, flags: int32, kind: ptr int32,
  data: pointer, size: ptr int32): int32 {.stdcall, importc, dynlib: "advapi32".}
proc RegDeleteKeyValueW(key: HANDLE, sub, name: ptr WCHAR): int32 {.stdcall, importc, dynlib: "advapi32".}
proc RegCloseKey(key: HANDLE): int32 {.stdcall, importc, dynlib: "advapi32".}
proc SHChangeNotify(event, flags: int32, a, b: pointer) {.stdcall, importc, dynlib: "shell32".}

proc wp(w: var seq[uint16]): ptr WCHAR = cast[ptr WCHAR](w[0].addr)

proc regGet(sub: string, name = ""): string =
  ## A string value under HKCU ("" for the key's default); "" when absent.
  var s = toWide(sub)
  var n = toWide(name)
  var size: int32
  if RegGetValueW(HKEY_CURRENT_USER, s.wp, (if name.len > 0: n.wp else: nil),
      RRF_RT_REG_SZ, nil, nil, size.addr) != 0 or size <= 2: return
  var buf = newSeq[uint16](size div 2 + 1)
  if RegGetValueW(HKEY_CURRENT_USER, s.wp, (if name.len > 0: n.wp else: nil),
      RRF_RT_REG_SZ, nil, buf[0].addr, size.addr) == 0:
    result = fromWide(cast[ptr WCHAR](buf[0].addr))

proc regSet(sub, name, value: string) =
  ## Creates the key as needed; raises OSError on failure.
  var s = toWide(sub)
  var key: HANDLE
  var err = RegCreateKeyExW(HKEY_CURRENT_USER, s.wp, 0, nil, 0, KEY_WRITE, nil,
    key.addr, nil)
  if err == 0:
    var n = toWide(name)
    var v = toWide(value)
    err = RegSetValueExW(key, (if name.len > 0: n.wp else: nil), 0, REG_SZ,
      v[0].addr, int32(v.len * 2))
    discard RegCloseKey(key)
  if err != 0: raise newException(OSError, "registry error " & $err & " at HKCU\\" & sub)

proc regDelete(sub, name: string) =
  var s = toWide(sub)
  var n = toWide(name)
  discard RegDeleteKeyValueW(HKEY_CURRENT_USER, s.wp, (if name.len > 0: n.wp else: nil))

proc classKey(ext: string): string = r"Software\Classes\." & ext

proc userChoice(ext: string): string =
  ## The ProgID picked in Settings (or "Always use this app"), if any.
  regGet(r"Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\." & ext &
    r"\UserChoice", "ProgId")

proc registerApp() =
  ## The ProgID that opens files with this executable, and the capabilities
  ## that list the player under Settings > Default apps.
  let exe = getAppFilename()
  let cmd = "\"" & exe & "\" \"%1\""
  regSet(r"Software\Classes\" & ProgId, "", "Media file")
  regSet(r"Software\Classes\" & ProgId & r"\DefaultIcon", "", exe & ",0")
  regSet(r"Software\Classes\" & ProgId & r"\shell\open\command", "", cmd)
  let app = r"Software\Classes\Applications\" & exe.extractFilename
  regSet(app, "FriendlyAppName", AppTitle)
  regSet(app & r"\shell\open\command", "", cmd)
  regSet(AppKey & r"\Capabilities", "ApplicationName", AppTitle)
  regSet(AppKey & r"\Capabilities", "ApplicationDescription",
    "Dark-themed media player built on mpv")
  for ext in @VideoExtensions & @AudioExtensions & @AssocTrackerExtensions:
    regSet(AppKey & r"\Capabilities\FileAssociations", "." & ext, ProgId)
  regSet(r"Software\RegisteredApplications", AppTitle, AppKey & r"\Capabilities")

proc loadAssocItems*(): seq[AssocItem] =
  for (exts, video) in [(@VideoExtensions, true), (@AudioExtensions, false),
                        (@AssocTrackerExtensions, false)]:
    for ext in exts:
      # Each extension is its own type here; the "MIME" shown is ".ext".
      var it = AssocItem(ext: ext, mimes: @["." & ext], video: video)
      it.current = regGet(classKey(ext)) == ProgId
      it.checked = it.current
      result.add it
  result.sort(proc (x, y: AssocItem): int = cmp(x.ext, y.ext))

proc applyAssociations*(items: var seq[AssocItem]): string =
  ## Points checked extensions at the player's ProgID (and adds it to their
  ## "Open with" list); unchecked ones lose both. Returns an error, or "".
  try:
    registerApp()
    for it in items:
      if it.checked == it.current: continue
      let key = classKey(it.ext)
      if it.checked:
        regSet(key, "", ProgId)
        regSet(key & r"\OpenWithProgids", ProgId, "")
      else:
        if regGet(key) == ProgId: regDelete(key, "")
        regDelete(key & r"\OpenWithProgids", ProgId)
  except OSError as e:
    return e.msg
  SHChangeNotify(SHCNE_ASSOCCHANGED, 0, nil, nil)
  for it in items.mitems: it.current = it.checked

proc userOverrides*(items: seq[AssocItem]): seq[string] =
  ## Checked extensions that still open elsewhere, because the user chose
  ## another default app for them in Windows.
  for it in items:
    if it.checked:
      let c = userChoice(it.ext)
      if c.len > 0 and c != ProgId: result.add it.ext
