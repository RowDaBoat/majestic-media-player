## XDG side of assoc.nim (included there): associations live in the
## mimeapps.list in the user's config directory, per MIME type, so extensions
## sharing one (mp4, m4v, f4v) move together.

import std/[strutils, tables, sequtils]

const DesktopId* = "majestic-media-player.desktop"

const
  DefaultSection = "[Default Applications]"
  AddedSection = "[Added Associations]"

proc mimeappsPath(): string = getConfigDir() / "mimeapps.list"

proc dataDirs(): seq[string] =
  result.add getEnv("XDG_DATA_HOME", getHomeDir() / ".local/share")
  for d in getEnv("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(':'):
    if d.len > 0: result.add d

proc extensionMimes(): Table[string, seq[string]] =
  ## ext -> MIME types, from shared-mime-info's globs2 ("weight:type:glob").
  ## Text types are skipped (*.ts is also Qt Linguist, *.dts device trees).
  for dir in dataDirs():
    let path = dir / "mime" / "globs2"
    if not fileExists(path): continue
    for line in lines(path):
      if line.startsWith("#"): continue
      let parts = line.split(':')
      if parts.len < 3 or not parts[2].startsWith("*."): continue
      let (mime, ext) = (parts[1], parts[2][2 .. ^1].toLowerAscii)
      if mime.startsWith("text/"): continue
      let known = result.getOrDefault(ext)
      if mime notin known: result.mgetOrPut(ext, @[]).add mime

proc readLines(path: string): seq[string] =
  if fileExists(path):
    try: result = readFile(path).splitLines
    except IOError: discard
  while result.len > 0 and result[^1].len == 0: result.setLen(result.len - 1)

proc sectionRange(lines: seq[string], section: string): (int, int) =
  ## Index of the section header and one past its last line; (-1, -1) if absent.
  for i, l in lines:
    if l.strip == section:
      var j = i + 1
      while j < lines.len and not lines[j].strip.startsWith("["): inc j
      return (i, j)
  (-1, -1)

proc entries(lines: seq[string], section, key: string): seq[string] =
  let (a, b) = lines.sectionRange(section)
  for i in a + 1 ..< b:
    let l = lines[i]
    let eq = l.find('=')
    if eq > 0 and l[0 ..< eq].strip == key:
      for e in l[eq + 1 .. ^1].split(';'):
        if e.strip.len > 0: result.add e.strip

proc setEntries(lines: var seq[string], section, key: string, values: seq[string]) =
  ## Replaces key's value list; an empty list removes the key.
  var (a, b) = lines.sectionRange(section)
  if a < 0:
    if values.len == 0: return
    if lines.len > 0: lines.add ""
    lines.add section
    (a, b) = (lines.high, lines.len)
  for i in a + 1 ..< b:
    let eq = lines[i].find('=')
    if eq > 0 and lines[i][0 ..< eq].strip == key:
      if values.len == 0: lines.delete(i)
      else: lines[i] = key & "=" & values.join(";") & ";"
      return
  if values.len > 0:
    # After the section's last entry, before any blank lines that separate it.
    var at = b
    while at > a + 1 and lines[at - 1].strip.len == 0: dec at
    lines.insert(key & "=" & values.join(";") & ";", at)

proc loadAssocItems*(): seq[AssocItem] =
  let mimes = extensionMimes()
  let lines = readLines(mimeappsPath())
  for (exts, video) in [(@VideoExtensions, true), (@AudioExtensions, false),
                        (@AssocTrackerExtensions, false)]:
    for ext in exts:
      var m = mimes.getOrDefault(ext)
      # *.mod is also application/x-object (compiled objects): only the
      # music types, so associating a module doesn't take .o files along.
      if ext in AssocTrackerExtensions: m.keepItIf(it.startsWith("audio/"))
      var it = AssocItem(ext: ext, mimes: m, video: video)
      it.current = it.mimes.len > 0
      for m in it.mimes:
        let d = lines.entries(DefaultSection, m)
        if d.len == 0 or d[0] != DesktopId: it.current = false
      it.checked = it.current
      result.add it
  result.sort(proc (x, y: AssocItem): int = cmp(x.ext, y.ext))

proc applyAssociations*(items: var seq[AssocItem]): string =
  ## Writes the checked state to mimeapps.list. Checked types get the player
  ## first in their default list; unchecked ones lose it, so the previous
  ## default (kept after it) takes over again. Returns an error, or "".
  let path = mimeappsPath()
  var lines = readLines(path)
  # An AppImage has no launcher entry for the defaults to name until it makes one.
  for it in items:
    if it.checked and not it.current:
      let err = integrate()
      if err.len > 0: return err
      break
  for it in items:
    if it.checked == it.current: continue
    for m in it.mimes:
      var d = lines.entries(DefaultSection, m)
      let i = d.find(DesktopId)
      if i >= 0: d.delete(i)
      if it.checked:
        d.insert(DesktopId, 0)
        var added = lines.entries(AddedSection, m)
        if DesktopId notin added:
          added.insert(DesktopId, 0)
          lines.setEntries(AddedSection, m, added)
      lines.setEntries(DefaultSection, m, d)
  try:
    createDir(path.parentDir)
    let tmp = path & ".majestic-tmp"
    writeFile(tmp, lines.join("\n") & "\n")
    moveFile(tmp, path)
  except CatchableError as e:
    return e.msg
  for it in items.mitems: it.current = it.checked

proc userOverrides*(items: seq[AssocItem]): seq[string] =
  ## Nothing outranks mimeapps.list's defaults (see the Windows version).
  discard
