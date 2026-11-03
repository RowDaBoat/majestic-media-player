## Running as an AppImage (tools/appimage.sh). The program then runs from a
## temporary mount that's gone once it quits, so whatever must outlive it
## points at the .AppImage file instead: a restart, an update, the launcher
## entry that file associations need.

import std/[os, strutils]

proc findAppImage(): string =
  ## The AppImage's runtime sets APPIMAGE and APPDIR; both are inherited by
  ## anything started from another AppImage too, so only when this program
  ## is the one inside APPDIR.
  when defined(linux):
    let (file, dir) = (getEnv("APPIMAGE"), getEnv("APPDIR"))
    if file.len > 0 and dir.len > 0 and fileExists(file) and
       getAppFilename().startsWith(dir.normalizedPath & "/"):
      return file

let appImageFile* = findAppImage()
  ## The .AppImage this program runs from, "" when it doesn't.

proc selfExe*(): string =
  ## What starts this program anew.
  if appImageFile.len > 0: appImageFile else: getAppFilename()

const
  DesktopFile = staticRead("../assets/desktop/majestic-media-player.desktop")
  IconFile = staticRead("../assets/desktop/majestic-media-player.svg")
  Marker = "X-Majestic-AppImage="  ## in the launcher entries written here

proc desktopPath(): string =
  getEnv("XDG_DATA_HOME", getHomeDir() / ".local/share") / "applications" /
    "majestic-media-player.desktop"

proc execQuote(path: string): string =
  ## Quoted for a .desktop Exec line (the spec's double quotes, with ",
  ## `, $ and \ escaped; the \ doubled again by the value's own escaping).
  result = "\""
  for c in path:
    if c in {'"', '`', '$'}: result.add "\\\\" & c
    elif c == '\\': result.add "\\\\\\\\"
    else: result.add c
  result.add '"'

proc strValue(s: string): string =
  ## A .desktop string value: \ escaped.
  s.replace("\\", "\\\\")

proc writtenHere(path: string): bool =
  try: Marker in readFile(path) except IOError: false

proc integrate*(always = true): string =
  ## Installs the launcher entry (and its icon) for the user, starting this
  ## AppImage: file associations name it. One a package or `make install`
  ## put there stays. `always` = false only refreshes one written before
  ## (the AppImage moved). Returns an error, or "".
  if appImageFile.len == 0: return
  if '\n' in appImageFile or '\r' in appImageFile:
    return "the AppImage's path has a line break in it"
  let path = desktopPath()
  if fileExists(path) and not writtenHere(path): return
  if not always and not fileExists(path): return
  var lines: seq[string]
  for l in DesktopFile.splitLines:
    if l.startsWith("Exec="):
      lines.add "TryExec=" & strValue(appImageFile)
      lines.add "Exec=" & execQuote(appImageFile) & " %F"
    elif l.startsWith("TryExec="): discard
    elif l.len > 0: lines.add l
  lines.add Marker & "true"
  let text = lines.join("\n") & "\n"
  try:
    if fileExists(path) and readFile(path) == text: return
    createDir(path.parentDir)
    writeFile(path & ".tmp", text)
    moveFile(path & ".tmp", path)
    let icon = getEnv("XDG_DATA_HOME", getHomeDir() / ".local/share") /
      "icons/hicolor/scalable/apps/majestic-media-player.svg"
    if not fileExists(icon):
      createDir(icon.parentDir)
      writeFile(icon, IconFile)
  except CatchableError as e:
    return e.msg
