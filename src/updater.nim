## Help > Check for Updates: looks up the player's latest release on GitHub
## and, when asked to, gets it ready in the background: on Windows the
## release's .zip, unpacked; as an AppImage, the release's AppImage; else
## the release's source, built with make as install.sh does. Then installs it
## in place of the running program (which can be replaced while it runs),
## for the app to restart into (relaunch).

import std/[os, osproc, json, strutils]
when not defined(windows): import std/posix
import runlog, appimage

const
  Repo = "arkl1te/majestic-media-player"
  LatestApi = "https://api.github.com/repos/" & Repo & "/releases/latest"
  ReleasesUrl* = "https://github.com/" & Repo & "/releases"
  KeptLines = 40              ## output lines kept, for errorText
  ResumeArg* = "--resume"     ## a restart into an update: bring the state back

type
  UpStage* = enum
    upLatest    ## the latest release
    upDownload  ## its .zip (Windows) or source
    upExtract   ## unpacking it
    upBuild     ## compiling it (from source)
    upInstall   ## putting it in place of the running program

  UpJob* = ref object
    stage*: UpStage
    p: Process                ## nil once a stage finished
    partial: string           ## output after the last line break
    lines: seq[string]        ## its last lines, stdout and stderr together
    code*: int = -1           ## exit code once finished; -1 while running
    progress*: float = -1     ## upDownload: percent done, as last printed
    version*: string          ## the latest release's version ("0.18.0")
    notes*: string            ## and its release notes
    url: string               ## what upDownload fetches
    archive: string           ## what upDownload makes

let exePath = getAppFilename()
  ## The running program, as it started: once replaced, Linux reports the
  ## running one "(deleted)".

proc workDir(): string = getCacheDir("majestic-media-player") / "update"

proc srcDir(): string = workDir() / "src"

proc running*(j: UpJob): bool = j != nil and j.p != nil

proc run(j: UpJob, stage: UpStage, exe: string, args: openArray[string], dir = "") =
  j.stage = stage
  j.code = -1
  j.lines.setLen 0
  j.partial.setLen 0
  try:
    j.p = startProcess(exe, workingDir = dir, args = args,
      options = {poUsePath, poStdErrToStdOut, poDaemon})
    j.p.nonBlocking()
  except OSError as e:
    j.lines.add e.msg
    j.code = 127

proc fail(j: UpJob, msg: string) =
  j.lines.add msg
  j.code = 1

proc checkForUpdate*(): UpJob =
  ## Looks up the latest release; done (code 0) once version is known.
  ## MMP_UPDATE_API stands in for GitHub's (debug scripts: a file:// URL).
  result = UpJob()
  result.run(upLatest, "curl", ["-fsSL", "--max-time", "15",
    "-H", "Accept: application/vnd.github+json", getEnv("MMP_UPDATE_API", LatestApi)])

proc canBuild*(): string =
  ## Without a release build for this system: "" when the source can be
  ## built here, else what's missing.
  when defined(windows): ""
  else:
    var missing: seq[string]
    for t in ["make", "nim", "git", "cc", "bash"]:
      if findExe(t).len == 0: missing.add t
    if missing.len > 0: "building it needs " & missing.join(", ") & " (see install.sh)"
    else: ""

proc percentIn(s: string): float =
  ## The number before the last '%' in s, else -1.
  let e = s.rfind('%')
  if e < 0: return -1
  var b = e
  while b > 0 and s[b - 1] in {'0' .. '9', '.'}: dec b
  try: parseFloat(s[b ..< e]) except ValueError: -1

proc addLine(j: UpJob, line: string) =
  let l = line.strip
  if l.len == 0: return
  if j.stage == upDownload and l.startsWith("#"):
    let pc = percentIn(l)
    if pc >= 0: j.progress = pc
    return
  j.lines.add l
  # upLatest: the release's JSON, whole.
  if j.lines.len > KeptLines and j.stage != upLatest: j.lines.delete(0)

proc read(j: UpJob) =
  for ch in j.p.readPipe():
    if ch in {'\n', '\r'}:
      j.addLine(j.partial)
      j.partial.setLen 0
    else: j.partial.add ch

proc parseRelease(j: UpJob) =
  ## The release's version, notes and what to download for this system.
  let r = try: parseJson(j.lines.join("\n")) except CatchableError: nil
  if r == nil or r.kind != JObject:
    j.fail("couldn't read the latest release")
    return
  j.version = r{"tag_name"}.getStr.strip(trailing = false, chars = {'v', 'V'})
  j.notes = r{"body"}.getStr.replace("\r", "").strip
  when defined(windows):
    for a in r{"assets"}.getElems:
      if a{"name"}.getStr.endsWith("-windows-x64.zip"):
        j.url = a{"browser_download_url"}.getStr
  else:
    if appImageFile.len > 0:
      const arch = when defined(arm64): "-aarch64.AppImage" else: "-x86_64.AppImage"
      for a in r{"assets"}.getElems:
        if a{"name"}.getStr.endsWith(arch):
          j.url = a{"browser_download_url"}.getStr
    else:
      j.url = r{"tarball_url"}.getStr
  if j.version.len == 0: j.fail("couldn't find the latest release")
  else: j.code = 0

proc download*(j: UpJob) =
  ## Gets the release checked for ready to install: done (code 0) once it is.
  if j.url.len == 0:
    j.fail("the release " & j.version & " has no download for this system")
    return
  if appImageFile.len > 0:
    # Next to it, for the rename over it to be one step.
    j.archive = appImageFile.parentDir / ("." & appImageFile.extractFilename & ".update")
    try: writeFile(j.archive, "")
    except IOError:
      j.fail("can't write to " & appImageFile.parentDir & ": move the AppImage to a folder of yours")
      return
    j.progress = -1
    j.run(upDownload, "curl", ["-fL", "--retry", "2", "-#", "-o", j.archive, j.url])
    return
  let need = canBuild()
  if need.len > 0:
    j.fail(need)
    return
  try:
    # A source build's dependencies (vendor) are kept for the next one.
    createDir(workDir())
    for kind, f in walkDir(workDir()):
      if f != srcDir(): (if kind == pcDir: removeDir(f) else: removeFile(f))
  except OSError as e:
    j.fail(e.msg)
    return
  j.archive = workDir() / (when defined(windows): "release.zip" else: "source.tar.gz")
  j.progress = -1
  j.run(upDownload, "curl", ["-fL", "--retry", "2", "-#", "-o", j.archive, j.url])

proc extract(j: UpJob) =
  when defined(windows):
    # Windows' own tar reads zip.
    try: createDir(workDir() / "release")
    except OSError as e:
      j.fail(e.msg)
      return
    j.run(upExtract, "tar", ["-xf", j.archive, "-C", workDir() / "release"])
  else:
    try:
      createDir(srcDir())
      for kind, f in walkDir(srcDir()):
        if f.extractFilename == "vendor": continue
        if kind == pcDir: removeDir(f) else: removeFile(f)
    except OSError as e:
      j.fail(e.msg)
      return
    j.run(upExtract, "tar", ["-xzf", j.archive, "-C", srcDir(), "--strip-components=1"])

proc build(j: UpJob) =
  j.run(upBuild, "make", ["--no-print-directory"], srcDir())

proc replaceFile(src, dest: string) =
  ## Puts src at dest, even while dest runs: on Windows the running one is
  ## moved aside (dest.old, removed next start); elsewhere renaming over it
  ## leaves the running program its own copy.
  when defined(windows):
    if fileExists(dest):
      removeFile(dest & ".old")
      moveFile(dest, dest & ".old")
    try: moveFile(src, dest)
    except OSError:
      if fileExists(dest & ".old"): moveFile(dest & ".old", dest)
      raise
  else:
    copyFile(src, dest & ".new")
    setFilePermissions(dest & ".new", getFilePermissions(src))
    moveFile(dest & ".new", dest)

proc install(j: UpJob) =
  ## The built or unpacked release in place of the running program. Under a
  ## bin folder (make install's), make install again, for the launcher entry
  ## and the icon too.
  j.stage = upInstall
  let exe = exePath
  try:
    when defined(windows):
      var dir = ""
      for kind, d in walkDir(workDir() / "release"):
        if kind == pcDir and fileExists(d / "majestic-media-player.exe"): dir = d
      if dir.len == 0:
        j.fail("majestic-media-player.exe wasn't in the download")
        return
      for f in walkFiles(dir / "*.dll"):
        replaceFile(f, exe.parentDir / f.extractFilename)
      if dirExists(dir / "cpu"):  # Mesa's software OpenGL (gpumem)
        createDir(exe.parentDir / "cpu")
        for f in walkFiles(dir / "cpu" / "*.dll"):
          replaceFile(f, exe.parentDir / "cpu" / f.extractFilename)
      replaceFile(dir / "majestic-media-player.exe", exe)
      removeDir(workDir() / "release")
      j.code = 0
    else:
      let built = srcDir() / "majestic-media-player"
      if not fileExists(built):
        j.fail("the build made no program")
      elif exe.parentDir.extractFilename == "bin":
        j.run(upInstall, "make", ["--no-print-directory", "install",
          "PREFIX=" & exe.parentDir.parentDir], srcDir())
      else:
        replaceFile(built, exe)
        j.code = 0
  except OSError, IOError:
    j.fail(getCurrentExceptionMsg())

proc poll*(j: UpJob): bool =
  ## Reads what it printed and goes on to the next stage once one is done.
  ## True when anything changed.
  if not j.running: return
  let before = (j.stage, j.progress, j.lines.len)
  j.read()
  let code = j.p.peekExitCode
  if code == -1: return (j.stage, j.progress, j.lines.len) != before
  j.read()
  j.addLine(j.partial)
  j.partial.setLen 0
  j.p.close()
  j.p = nil
  if code != 0:
    j.code = code
    if j.stage == upDownload and appImageFile.len > 0:
      try: removeFile(j.archive)
      except OSError: discard
    return true
  case j.stage
  of upLatest: j.parseRelease()
  of upDownload:
    if appImageFile.len > 0:
      # The running one keeps its copy: the mount holds it open.
      j.stage = upInstall
      try:
        setFilePermissions(j.archive, getFilePermissions(appImageFile) +
          {fpUserExec, fpUserRead})
        moveFile(j.archive, appImageFile)
        j.code = 0
      except OSError, IOError:
        j.fail(getCurrentExceptionMsg())
    else: j.extract()
  of upExtract:
    try: removeFile(j.archive)
    except OSError: discard
    when defined(windows): j.install() else: j.build()
  of upBuild: j.install()
  of upInstall: j.code = 0
  true

proc stop*(j: UpJob) =
  if not j.running: return
  try:
    # A build's compilers too: its process group (poDaemon).
    when not defined(windows): discard kill(Pid(-j.p.processID), SIGTERM)
    j.p.terminate()
    discard j.p.waitForExit(1000)
    j.p.close()
  except OSError: discard
  j.p = nil
  j.code = 130
  if j.stage == upDownload and appImageFile.len > 0:
    try: removeFile(j.archive)
    except OSError: discard

proc errorText*(j: UpJob): string =
  ## What went wrong: its last line.
  if j.lines.len > 0: j.lines[^1] else: "exit code " & $j.code

proc lastLine*(j: UpJob): string =
  ## What it printed last (the build's progress).
  if j.lines.len > 0: j.lines[^1] else: ""

proc removeOld*() =
  ## What an update moved aside on Windows, no longer running.
  when defined(windows):
    for pattern in ["*.old", "cpu" / "*.old"]:
      for f in walkFiles(exePath.parentDir / pattern):
        try: removeFile(f)
        except OSError: discard

proc relaunch*(extra: varargs[string]) =
  ## Starts the (updated) program anew, to bring back the state saved for it
  ## (`extra`: more arguments).
  # A debug script runs once; MMP_RESUME_SCRIPT is the restarted one's.
  if existsEnv("MMP_RESUME_SCRIPT"): putEnv("MMP_SCRIPT", getEnv("MMP_RESUME_SCRIPT"))
  else: delEnv("MMP_SCRIPT")
  delEnv("MMP_RESUME_SCRIPT")
  try:
    let p = startProcess(selfExe(), args = @[ResumeArg] & @extra, options = {poParentStreams, poDaemon})
    p.close()
  except OSError as e:
    stderr.writeLine "cannot restart: ", e.msg
