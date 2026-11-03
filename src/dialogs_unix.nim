## kdialog (KDE) or zenity file dialogs, run as a child process; else the
## desktop's own, through the xdg-desktop-portal's FileChooser (any desktop
## with a portal: Cinnamon, XFCE, ... without either program). Included by
## dialogs.nim.

import std/[osproc, streams, strutils, uri]
import portal

type
  Dialog* = ref object
    process: Process
    request: string          # the portal's request path, when it's the portal's
    purpose*: string         # caller-defined tag, e.g. "open", "subtitle"

proc which(exe: string): bool = findExe(exe).len > 0

proc globs(exts: seq[string]): string =
  for i, e in exts:
    if i > 0: result.add " "
    result.add "*." & e

proc portalDialog(kind: DialogKind, title, startPath: string,
                  filters: seq[(string, seq[string])]): string =
  ## FileChooser.OpenFile / SaveFile; the request's path, "" when there's no portal.
  # startPath is a folder, or a file in one (the name to save as).
  let (folder, name) =
    if startPath.len == 0 or dirExists(startPath): (startPath, "")
    else: (startPath.parentDir, startPath.extractFilename)
  request("FileChooser", if kind == dkSaveFile: "SaveFile" else: "OpenFile",
    proc (it: ptr Iter) =
      appendString(it, "")  # no parent window handle
      appendString(it, title)
      var opts: Iter
      discard iterOpen(it, TypeArray, "{sv}", addr opts)
      if kind in {dkOpenFiles, dkOpenDir}:
        let (key, on) = if kind == dkOpenDir: ("directory", 1'u32) else: ("multiple", 1'u32)
        dictEntry(addr opts, key, "b"):
          var b = on
          discard iterAppendBasic(value, TypeBool, addr b)
      if kind == dkSaveFile and name.len > 0:
        dictEntry(addr opts, "current_name", "s"): appendString(value, name)
      if folder.len > 0 and dirExists(folder):
        # A NUL-terminated byte string.
        dictEntry(addr opts, "current_folder", "ay"):
          var bytes: Iter
          discard iterOpen(value, TypeArray, "y", addr bytes)
          for ch in folder & '\0':
            var c = ch.uint8
            discard iterAppendBasic(addr bytes, TypeByte, addr c)
          discard iterClose(value, addr bytes)
      if filters.len > 0 and kind != dkOpenDir:
        # a(sa(us)): (name, [(0 = glob, pattern)]), then all files.
        dictEntry(addr opts, "filters", "a(sa(us))"):
          var list: Iter
          discard iterOpen(value, TypeArray, "(sa(us))", addr list)
          for (fname, exts) in filters & @[("All files", @["*"])]:
            var f, pats: Iter
            discard iterOpen(addr list, TypeStruct, nil, addr f)
            appendString(addr f, fname)
            discard iterOpen(addr f, TypeArray, "(us)", addr pats)
            for g in exts:
              var p: Iter
              discard iterOpen(addr pats, TypeStruct, nil, addr p)
              var kind0 = 0'u32
              discard iterAppendBasic(addr p, TypeUint32, addr kind0)
              appendString(addr p, if g == "*": g else: "*." & g)
              discard iterClose(addr pats, addr p)
            discard iterClose(addr f, addr pats)
            discard iterClose(addr list, addr f)
          discard iterClose(value, addr list)
      discard iterClose(it, addr opts))

proc portalPaths(m: Msg): seq[string] =
  ## results["uris"]: file:// URIs (as), nothing when cancelled.
  var results, uris: Iter
  if responseCode(m, results) != 0 or not findResult(addr results, "uris", uris) or
     iterArgType(addr uris) != TypeArray: return
  var u: Iter
  iterRecurse(addr uris, addr u)
  while iterArgType(addr u) == TypeString:
    var s: cstring
    iterGetBasic(addr u, addr s)
    let uri = $s
    if uri.startsWith("file://"): result.add decodeUrl(uri[7 .. ^1], decodePlus = false)
    discard iterNext(addr u)

proc startDialog*(kind: DialogKind, purpose, title, startPath: string,
                  filterExts: seq[string] = @[], filterName = "",
                  extraFilters: seq[(string, seq[string])] = @[]): Dialog =
  ## extraFilters: further (name, extensions) choices after the first filter.
  var filters: seq[(string, seq[string])]
  if filterExts.len > 0: filters.add (filterName, filterExts)
  filters.add extraFilters
  var cmd: string
  var args: seq[string]
  if which("kdialog"):
    cmd = "kdialog"
    args = @["--title", title]
    var filter = ""
    for (name, exts) in filters:
      filter.add name & " (" & globs(exts) & ")|"
    if filter.len > 0: filter.add "All files (*)"
    case kind
    of dkOpenFiles:
      args.add ["--getopenfilename", startPath, filter, "--multiple", "--separate-output"]
    of dkOpenFile:
      args.add ["--getopenfilename", startPath, filter]
    of dkOpenDir:
      args.add ["--getexistingdirectory", startPath]
    of dkSaveFile:
      args.add ["--getsavefilename", startPath, filter]
  elif which("zenity"):
    cmd = "zenity"
    args = @["--file-selection", "--title=" & title, "--filename=" & startPath]
    case kind
    of dkOpenFiles: args.add ["--multiple", "--separator=\n"]
    of dkOpenDir: args.add "--directory"
    of dkSaveFile: args.add ["--save", "--confirm-overwrite"]
    of dkOpenFile: discard
    if filters.len > 0 and kind != dkOpenDir:
      for (name, exts) in filters:
        args.add "--file-filter=" & name & " | " & globs(exts)
      args.add "--file-filter=All files | *"
  else:
    let request = portalDialog(kind, title, startPath, filters)
    if request.len == 0:
      stderr.writeLine "No file dialog available: install kdialog or zenity."
      return nil
    return Dialog(purpose: purpose, request: request)
  result = Dialog(purpose: purpose,
    process: startProcess(cmd, args = args, options = {poUsePath}))

proc poll*(d: Dialog, done: var bool): seq[string] =
  ## Returns the selected paths once the dialog has closed (empty if cancelled).
  done = false
  if d != nil and d.request.len > 0:
    let m = pollResponse(d.request)
    if m == nil: return
    done = true
    d.request = ""
    result = portalPaths(m)
    unref(m)
    return
  if d == nil or d.process == nil:
    done = true
    return
  if d.process.peekExitCode() == -1:
    return
  done = true
  let output = d.process.outputStream.readAll()
  let code = d.process.waitForExit()
  d.process.close()
  d.process = nil
  if code != 0: return
  for line in output.splitLines:
    let p = line.strip(leading = false)
    if p.len > 0: result.add p
