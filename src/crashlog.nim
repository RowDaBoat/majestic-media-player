## Crash log: when the app dies of an unhandled exception (a Nim defect such
## as an IndexDefect) or a fatal signal (a segfault), Nim's report — the stack
## trace and the error — is appended to crash.log in the config folder, with
## the version, the build, the time and what the app was showing. Then the
## report is shown as Nim would show it (stderr; a message box in the Windows
## GUI build), followed by where the log was saved.
##
## Nim hands its report to `errorMessageWriter` instead of showing it, so that
## is the hook; the process ends right after, as it would without it.
##
## The writer must not crash itself, or nothing is saved:
## - It turns ORC's cycle collector off first. A crash inside the collector (a
##   cell freed behind its back, e.g. a ref counted on two threads) leaves the
##   broken cell among its roots, and the next ref the writer dropped started
##   the collector again on it: a second segfault, no crash.log.
## - On Linux, another crash while it writes (the app's state can be broken
##   past reading) goes to `nestedCrash`, which allocates nothing: it notes in
##   the log and on stderr how far the report got, then lets the signal end
##   the app the default way (a core dump), as Nim's handler would.

import std/[os, times, strutils]
when defined(posix): import std/posix

const LogLimit = 1 shl 20  ## bytes; a bigger log starts over

var
  logPath: string
  appTitle: string             ## "Majestic Media Player 0.24.0"
  startedAt: float
  writing: bool                ## a crash while reporting one: show it plainly
  snapshot*: proc (): string {.closure.}
    ## what the app was doing, one "name: value" per line; called only for
    ## crashes on the main thread, where the app's state is safe to read
  mainThread {.threadvar.}: bool
  log: File                    ## crash.log while a report is written to it
  stage: cstring               ## what the writer is doing; nil when not writing
  report0: cstring             ## the report being written (for nestedCrash)
  saved: bool                  ## the report's essentials are in the log

when compileOption("exceptions", "goto"):
  # With goto-based exceptions (the default), the thread's error flag stays
  # set while Nim reports an unhandled exception, and every call that can
  # raise then returns at once as if one were in flight: the writer would
  # stop at its first such call. Nim emits this accessor into each module.
  proc nimErrorFlag(): ptr bool {.importc, nodecl.}

proc show(text: string) {.raises: [].} =
  try:
    stderr.write(text)
    stderr.flushFile()
  except CatchableError: discard
  when defined(windows) and defined(guiapp):
    proc MessageBoxW(hWnd: pointer, text, caption: WideCString, uType: uint32): int32 {.
      stdcall, dynlib: "user32", importc.}
    const MbIconError = 0x10'u32
    discard MessageBoxW(nil, newWideCString(text), newWideCString(appTitle), MbIconError)

proc openLog(): bool =
  createDir(logPath.parentDir)
  let mode = if fileExists(logPath) and getFileSize(logPath) > LogLimit: fmWrite else: fmAppend
  open(log, logPath, mode)

proc append(text: string) =
  log.write(text)
  log.flushFile()  # on disk before the next step, which could crash

when defined(posix):
  template fatalSignals(): untyped = [SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT]

  var
    oldActions: array[5, Sigaction]
    oldMask: Sigset

  proc rawWrite(fd: cint, s: cstring) =
    if fd >= 0 and s != nil: discard posix.write(fd, s, s.len)

  proc nestedCrash(sig: cint) {.noconv.} =
    ## A crash while the report is written. Signal-safe: no allocation, only
    ## write(2) on what is already there.
    const Note = "; the report ends here.)\n"
    let what = if stage != nil: stage else: cstring"writing the crash report"
    if log != nil:
      let fd = getFileHandle(log)
      rawWrite(fd, "\n(Another crash came while ")
      rawWrite(fd, what)
      rawWrite(fd, Note)
    rawWrite(2, report0)
    rawWrite(2, "\n(Another crash came while ")
    rawWrite(2, what)
    rawWrite(2, Note)
    if saved:
      rawWrite(2, "The details so far were saved to ")
      rawWrite(2, logPath.cstring)
      rawWrite(2, "\nPlease send that file along when reporting this crash.\n")
    # Ends the app as the signal would have: blocked while this handler runs,
    # it arrives with the default action once it returns.
    var dfl: Sigaction
    dfl.sa_handler = SIG_DFL
    discard sigemptyset(dfl.sa_mask)
    discard sigaction(sig, dfl)
    discard posix.`raise`(sig)

  proc guardOn() =
    ## Sends crashes during the report to nestedCrash. Nim's handler runs with
    ## its signal blocked, and a fault on a blocked signal kills the app on the
    ## spot, so they're unblocked too.
    var act: Sigaction
    act.sa_handler = nestedCrash
    discard sigemptyset(act.sa_mask)
    var unblock: Sigset
    discard sigemptyset(unblock)
    for i, s in fatalSignals():
      discard sigaction(s, act, oldActions[i])
      discard sigaddset(unblock, s)
    discard pthread_sigmask(SIG_UNBLOCK, unblock, oldMask)

  proc guardOff() =
    ## Back to Nim's handlers and signal mask, as before the report.
    for i, s in fatalSignals():
      discard sigaction(s, oldActions[i])
    var none: Sigset
    discard pthread_sigmask(SIG_SETMASK, oldMask, none)

proc writeReport(report: string) {.nimcall, gcsafe, raises: [], tags: [WriteIOEffect].} =
  {.cast(gcsafe), cast(tags: []).}:
    # Before anything that could drop a ref (see the module's doc).
    when declared(GC_disableOrc): GC_disableOrc()
    if writing or logPath.len == 0:
      show(report)
      return
    writing = true
    when declared(nimErrorFlag):
      # Left cleared: Nim quits right after the report either way, and set
      # again it would make Nim take the writer for failed and print it too.
      nimErrorFlag()[] = false
    report0 = report.cstring
    stage = "saving the report"
    when defined(posix): guardOn()
    try:
      if openLog():
        var text = "=== " & appTitle & " crashed on " &
          now().format("yyyy-MM-dd HH:mm:ss zzz") & "\n"
        text.add "Build: " & hostOS & " " & hostCPU & ", compiled " & CompileDate & " " &
          CompileTime & " UTC\n"
        text.add "Running for: " & formatFloat(epochTime() - startedAt, ffDecimal, 1) & " s\n"
        if not mainThread: text.add "Thread: not the main one\n"
        text.add "\n" & report
        if not report.endsWith("\n"): text.add "\n"
        append(text)  # first: reading the app's state below could crash too
        saved = true
        if mainThread and snapshot != nil:
          stage = "reading the app's state"
          var state = "State:\n"
          try: state.add snapshot()
          except Exception: state.add "(unavailable)\n"
          if not state.endsWith("\n"): state.add "\n"
          append(state)
        append("\n")
    except Exception: discard
    stage = "showing the report"
    if saved:
      show(report & "\nThe details were saved to " & logPath &
        "\nPlease send that file along when reporting this crash.\n")
    else:
      show(report)
    stage = nil
    if log != nil:
      log.close()
      log = nil
    when defined(posix): guardOff()

proc installCrashLog*(dir, title: string) =
  ## Call first thing on the main thread: crashes are written to dir/crash.log.
  logPath = dir / "crash.log"
  appTitle = title
  startedAt = epochTime()
  mainThread = true
  errorMessageWriter = writeReport
