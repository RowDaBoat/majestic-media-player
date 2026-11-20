## Single-instance support for "Same player for each media file": the running
## player listens on a local socket (see ipc), and a newly launched one hands
## its files over (one path per line) and exits.
##
## Several files selected in a file manager can start one player each, all at
## once (Windows Explorer does): a lock lets one launch at a time look for a
## running player and, finding none, become it, so the others find it.

import std/[net, nativesockets, os, strutils, times]
import ipc
when defined(windows):
  import std/winlean
  proc AllowSetForegroundWindow(pid: int32): int32 {.stdcall, importc, dynlib: "user32".}
  proc CreateMutexW(attr: pointer, initialOwner: int32, name: WideCString): Handle
    {.stdcall, importc, dynlib: "kernel32".}
  proc ReleaseMutex(h: Handle): int32 {.stdcall, importc, dynlib: "kernel32".}
else:
  import std/posix
  proc flock(fd: cint, op: cint): cint {.importc, header: "<sys/file.h>".}
  const LockEx = 2.cint
  const LockNb = 4.cint
  const LockUn = 8.cint

type
  InstanceServer* = ref object
    sock: Socket
    path: string

  LaunchLock* = object
    ## Held by one launch at a time, while it looks for a running player.
    held*: bool
    when defined(windows): h: Handle
    else: fd: cint

proc socketDir(): string =
  # MMP_INSTANCE_DIR: debug scripts sharing files among themselves.
  getEnv("MMP_INSTANCE_DIR", getEnv("XDG_RUNTIME_DIR", getTempDir()))

proc socketPath(): string = socketDir() / "majestic-media-player.sock"

proc lockLaunch*(wait = 5.0): LaunchLock =
  ## Waits up to `wait` seconds for the lock; not held when that runs out.
  let deadline = epochTime() + wait
  when defined(windows):
    # Per user session, like the socket's folder.
    let name = "Local\\majestic-media-player-launch-" &
      socketDir().multiReplace(("\\", "/"), (":", "")).toLowerAscii
    result.h = CreateMutexW(nil, 0, newWideCString(name))
    if result.h == 0: return
    let r = waitForSingleObject(result.h, int32(max(wait, 0) * 1000))
    result.held = r == 0 or r == 0x80  # WAIT_OBJECT_0, WAIT_ABANDONED (died holding it)
    if not result.held:
      discard closeHandle(result.h)
      result.h = 0
  else:
    result.fd = posix.open(cstring(socketPath() & ".lock"), O_CREAT or O_RDWR or O_CLOEXEC, 0o600)
    if result.fd < 0: return
    while true:
      if flock(result.fd, LockEx or LockNb) == 0:
        result.held = true
        return
      if errno != EWOULDBLOCK and errno != EINTR: break
      if epochTime() >= deadline: break
      sleep(5)
    discard posix.close(result.fd)
    result.fd = -1

proc unlock*(l: var LaunchLock) =
  if not l.held: return
  l.held = false
  when defined(windows):
    discard ReleaseMutex(l.h)
    discard closeHandle(l.h)
  else:
    discard flock(l.fd, LockUn)
    discard posix.close(l.fd)

proc forwardToRunning*(paths: seq[string]): bool =
  ## Sends paths to an already running player. False if none is listening.
  let s = dial(socketPath())
  if s == nil: return false
  when defined(windows):
    # We were just launched, so we may raise windows; let the player do it.
    discard AllowSetForegroundWindow(-1)
  try:
    s.send(paths.join("\n") & "\n")
    result = true
  except OSError:
    discard
  s.close()

proc startServer*(): InstanceServer =
  ## Listens for paths from later launches; nil if another player already does.
  let path = socketPath()
  let live = dial(path)
  if live != nil:
    live.close()
    return nil
  removeFile(path)  # stale socket from a crashed instance
  var s: Socket
  try:
    s = listenAt(path)
  except CatchableError as e:
    stderr.writeLine "single instance: cannot listen on ", path, ": ", e.msg
    return nil
  InstanceServer(sock: s, path: path)

proc poll*(srv: InstanceServer): seq[seq[string]] =
  ## Paths received since the last call, one list per launch.
  if srv == nil: return
  while true:
    var client: Socket
    new(client)  # accept() fills in an allocated Socket
    try:
      srv.sock.accept(client)
    except OSError:
      break  # nothing pending
    client.getFd.setBlocking(true)
    var paths: seq[string]
    try:
      while true:
        let line = client.recvLine(timeout = 1000)
        if line.len == 0: break
        paths.add line
    except CatchableError:
      discard
    client.close()
    if paths.len > 0: result.add paths

proc close*(srv: InstanceServer) =
  if srv == nil: return
  srv.sock.close()
  removeFile(srv.path)
