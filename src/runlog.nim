## Run log: what the Run menu's command lines printed. Each run keeps its
## output (stdout and stderr together) as lines; a carriage return starts its
## line over, so progress meters like ffmpeg's stay on one line.

import std/[os, osproc, times, sequtils, strutils]
when defined(windows):
  import std/winlean
else:
  import std/posix

const
  MaxRunLines = 5000  ## per run; the oldest go first
  MaxRuns = 50        ## runs kept; the oldest finished go first

type
  RunEntry* = ref object
    title*: string
    started*: DateTime
    dir*: string
    lines*: seq[string]
    p*: Process         ## nil once finished (or when it never started)
    code*: int          ## exit code; -1 while running
    error*: string      ## why it did not start
    stopped*: bool      ## ended by the Stop button
    reveal*: seq[string]  ## files whose folders open once it succeeds
    play*: seq[string]    ## files played in a new player once it succeeds
    temps*: seq[string]   ## files made for it (file lists), deleted once it ends
    cr: bool            ## a carriage return came: the next text replaces the line

proc running*(e: RunEntry): bool = e.p != nil

proc newRunEntry*(title, dir: string): RunEntry =
  RunEntry(title: title, dir: dir, started: now(), lines: @[""], code: -1)

proc add*(e: RunEntry, text: string) =
  for ch in text:
    case ch
    of '\n':
      e.cr = false
      e.lines.add ""
    of '\r': e.cr = true
    of '\t': e.lines[^1].add "    "
    else:
      if ch < ' ': continue
      if e.cr:
        e.cr = false
        e.lines[^1].setLen 0
      e.lines[^1].add ch
  if e.lines.len > MaxRunLines:
    e.lines.delete(0 ..< e.lines.len - MaxRunLines)

proc output*(e: RunEntry): seq[string] =
  ## Its lines without the empty one a final newline leaves.
  result = e.lines
  if result.len > 0 and result[^1].len == 0: result.setLen(result.len - 1)

proc stripAnsi(s: string): string =
  ## Drops terminal escape sequences (colors, cursor moves).
  var i = 0
  while i < s.len:
    if s[i] == '\e' and i + 1 < s.len and s[i + 1] == '[':
      i += 2
      while i < s.len and s[i] notin {'@' .. '~'}: inc i
      inc i
    elif s[i] == '\e': i += 2
    else:
      result.add s[i]
      inc i

proc bashExe(): string =
  ## bash to run scripts with. On Windows, Git for Windows' one: the bash.exe
  ## in System32 is WSL's, which sees the files under different paths.
  when defined(windows):
    var tries = @[getEnv("MMP_BASH")]
    let git = findExe("git")
    if git.len > 0:
      tries.add git.parentDir.parentDir / "bin" / "bash.exe"  # Git\cmd\git.exe
      tries.add git.parentDir / "bash.exe"                    # Git\bin\git.exe
    for root in [getEnv("ProgramFiles"), getEnv("ProgramW6432"),
                 getEnv("LOCALAPPDATA") / "Programs"]:
      if root.len > 0: tries.add root / "Git" / "bin" / "bash.exe"
    for t in tries:
      if t.len > 0 and fileExists(t): return t
    raise newException(OSError, "bash not found; install Git for Windows or set MMP_BASH")
  else:
    "bash"

proc nonBlocking*(p: Process) =
  ## Makes p's output pipe readable with readPipe without stalling.
  when not defined(windows):
    let fd = p.outputHandle.cint
    discard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) or O_NONBLOCK)

proc readPipe*(p: Process): string =
  ## What p's output pipe holds now, without blocking (see nonBlocking).
  var buf: array[4096, char]
  while true:
    when defined(windows):
      let h = p.outputHandle
      var avail, got: int32
      if not peekNamedPipe(h, nil, 0, nil, avail.addr) or avail <= 0: break
      if readFile(h, buf[0].addr, min(avail, buf.len.int32), got.addr, nil) == 0: break
      let n = got.int
    else:
      let n = read(p.outputHandle.cint, buf[0].addr, buf.len)
    if n <= 0: break
    let at = result.len
    result.setLen(at + n)
    copyMem(result[at].addr, buf[0].addr, n)

proc start*(e: RunEntry, script: string) =
  ## Runs script with bash in e.dir, its output piped to us. No stdin: tools
  ## like ffmpeg would otherwise read our terminal's keys. poDaemon: no
  ## console window pops up on Windows.
  e.p = startProcess(bashExe(), e.dir, ["-c", "exec </dev/null\n" & script],
    options = {poUsePath, poStdErrToStdOut, poDaemon})
  e.p.nonBlocking()

proc readAvailable(e: RunEntry): bool =
  let s = e.p.readPipe()
  if s.len > 0:
    stdout.write s  # also to our terminal, as before the log existed
    e.add s.stripAnsi
    result = true

proc poll*(e: RunEntry): bool =
  ## Reads what the process printed and notes when it exits. True when
  ## anything changed.
  if e.p == nil: return
  result = e.readAvailable
  let code = e.p.peekExitCode
  if code != -1:
    discard e.readAvailable  # what came between the read and the exit
    stdout.flushFile()
    e.code = code
    e.p.close()
    e.p = nil
    result = true

proc descendants(pid: int): seq[int] {.used.} =
  ## Every process below pid, from /proc.
  var parents: seq[(int, int)]  # (pid, parent pid)
  for kind, path in walkDir("/proc"):
    let name = path.extractFilename
    if kind != pcDir or not name.allCharsInSet(Digits): continue
    try:
      # The command name (in parentheses) may hold spaces; ppid follows it.
      let stat = readFile(path / "stat")
      let fields = stat[stat.rfind(')') + 2 .. ^1].splitWhitespace
      parents.add (parseInt(name), parseInt(fields[1]))
    except CatchableError: discard
  var queue = @[pid]
  while queue.len > 0:
    let p = queue.pop
    for (child, parent) in parents:
      if parent == p:
        result.add child
        queue.add child

proc stop*(e: RunEntry) =
  ## Ends the run: bash and whatever it started (ffmpeg and the like).
  if e.p == nil: return
  e.stopped = true
  let pid = e.p.processID
  when defined(windows):
    # No SIGTERM to pass down: end the whole tree.
    discard execCmdEx("taskkill /T /F /PID " & $pid, options = {poUsePath, poDaemon})
  else:
    for child in descendants(pid): discard kill(child.Pid, SIGTERM)
    discard kill(pid.Pid, SIGTERM)

proc removeTemps*(e: RunEntry) =
  ## Deletes the files made for the run.
  for f in e.temps:
    try: removeFile(f)
    except OSError: discard
  e.temps.setLen 0

proc trim*(log: var seq[RunEntry]) =
  var i = 0
  while log.len > MaxRuns and i < log.len:
    if log[i].running: inc i
    else: log.delete(i)
