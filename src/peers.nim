## Peer links for Synchronize: every player listens on its own local socket
## (see ipc) in a shared runtime folder, finds the others by listing it, and
## keeps one connection per pair (the lower pid connects). Messages are lines of
## tab-separated fields; hello/title/status are handled here, the rest is
## handed to the app.

import std/[net, nativesockets, os, sequtils, strutils, times]
import ipc

type
  Peer* = ref object
    pid*: int
    title*: string            ## what its window shows
    master*: int              ## its synchronization master, 0 when none
    offset*: float            ## as a slave: seconds ahead of its master, behind when negative
    loop*: bool               ## as a slave: loops on its own until the master ends
    fps*: float               ## its video's frame rate, 0 when unknown
    sock: Socket
    buf: string

  Message* = object
    sender*: int
    fields*: seq[string]

  PeerNet* = ref object
    pid*: int
    dir, path: string
    server: Socket
    peers*: seq[Peer]
    unnamed: seq[Peer]        ## accepted, waiting for their hello
    lastScan: float
    title: string             ## last announced, repeated to new peers
    status: seq[string]       ## master, offset, loop, fps: likewise
    gone*: seq[int]           ## peers lost since the last poll

proc escape(s: string): string =
  s.multiReplace(("\\", "\\\\"), ("\t", "\\t"), ("\n", "\\n"))

proc unescape(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      inc i
      result.add(case s[i]
        of 't': '\t'
        of 'n': '\n'
        else: s[i])
    else: result.add s[i]
    inc i

proc encode(fields: openArray[string]): string =
  for i, f in fields:
    if i > 0: result.add '\t'
    result.add escape(f)
  result.add '\n'

proc syncDir(): string =
  getEnv("MMP_SYNC_DIR", getEnv("XDG_RUNTIME_DIR", getTempDir()) / "majestic-media-player-sync")

proc write(p: Peer, data: string): bool =
  ## Whole message or nothing usable: false once the peer is unreachable.
  p.sock.sendAll(data)

proc greet(n: PeerNet, p: Peer): bool =
  p.write(encode(["hello", $n.pid])) and p.write(encode(["title", n.title])) and
    p.write(encode(@["status"] & n.status))

proc startPeerNet*(): PeerNet =
  ## Listens for other players; nil when the socket can't be made.
  let dir = syncDir()
  try: createDir(dir)
  except OSError: return nil
  let pid = getCurrentProcessId()
  let path = dir / $pid & ".sock"
  removeFile(path)
  var s: Socket
  try:
    s = listenAt(path)
  except CatchableError as e:
    stderr.writeLine "synchronize: cannot listen on ", path, ": ", e.msg
    return nil
  PeerNet(pid: pid, dir: dir, path: path, server: s, status: @["0", "0", "false", "0"])

proc find*(n: PeerNet, pid: int): Peer =
  if n == nil: return
  for p in n.peers:
    if p.pid == pid: return p

proc drop(n: PeerNet, p: Peer) =
  p.sock.close()
  let i = n.peers.find(p)
  if i >= 0:
    n.peers.delete(i)
    n.gone.add p.pid

proc send*(n: PeerNet, pid: int, fields: varargs[string]) =
  let p = n.find(pid)
  if p != nil and not p.write(encode(fields)): n.drop(p)

proc announce*(n: PeerNet, title: string, master: int, offset: float, loop: bool, fps: float) =
  ## Tells every peer this player's title, master, slave settings and frame
  ## rate when they change.
  if n == nil: return
  let st = @[$master, $offset, $loop, $fps]
  if title != n.title:
    n.title = title
    for p in n.peers: n.send(p.pid, "title", title)
  if st != n.status:
    n.status = st
    for p in n.peers: n.send(p.pid, @["status"] & st)

proc scan(n: PeerNet) =
  ## Connects to players with a higher pid that we don't know yet; removes
  ## sockets left behind by players that died.
  for kind, f in walkDir(n.dir):
    let (_, name, ext) = f.splitFile
    if ext != ".sock": continue
    var pid: int
    try: pid = parseInt(name)
    except ValueError: continue
    if pid <= n.pid or n.find(pid) != nil: continue
    let s = dial(f)
    if s == nil:
      if not processAlive(pid): removeFile(f)
      continue
    let p = Peer(pid: pid, sock: s)
    if n.greet(p): n.peers.add p
    else: s.close()

proc readLines(p: Peer): (seq[string], bool) =
  ## Complete lines received so far; false once the connection closed.
  if not p.sock.recvAvailable(p.buf): return (@[], false)
  var lines: seq[string]
  var start = 0
  while (let nl = p.buf.find('\n', start); nl >= 0):
    lines.add p.buf[start ..< nl]
    start = nl + 1
  p.buf = p.buf[start .. ^1]
  (lines, true)

proc poll*(n: PeerNet): seq[Message] =
  ## Messages for the app since the last call; lost peers go to `gone`.
  if n == nil: return
  while true:
    var client: Socket
    new(client)
    try: n.server.accept(client)
    except OSError: break
    client.getFd.setBlocking(true)
    n.unnamed.add Peer(sock: client)
  if epochTime() - n.lastScan > 1.0:
    n.lastScan = epochTime()
    n.scan()

  var i = 0
  while i < n.unnamed.len:
    let p = n.unnamed[i]
    let (lines, open) = p.readLines()
    var keep = open
    if lines.len > 0:
      let f = lines[0].split('\t')
      keep = false
      if f.len == 2 and f[0] == "hello":
        try: p.pid = parseInt(f[1])
        except ValueError: discard
        if p.pid > 0 and p.pid != n.pid and n.find(p.pid) == nil and n.greet(p):
          n.peers.add p
          # the rest of what arrived with the hello
          p.buf = lines[1 .. ^1].join("\n") & (if lines.len > 1: "\n" else: "") & p.buf
      n.unnamed.delete(i)
      if p notin n.peers: p.sock.close()
      continue
    if not keep:
      p.sock.close()
      n.unnamed.delete(i)
    else: inc i

  for p in n.peers[0 .. ^1]:  # a copy: drop() edits the list
    let (lines, open) = p.readLines()
    for line in lines:
      let f = line.split('\t').mapIt(unescape(it))
      if f.len == 0: continue
      case f[0]
      of "title": p.title = if f.len > 1: f[1] else: ""
      of "status":  # master offset loop fps
        p.master = 0
        p.offset = 0
        p.fps = 0
        try:
          if f.len > 1: p.master = parseInt(f[1])
          if f.len > 2: p.offset = parseFloat(f[2])
          if f.len > 4: p.fps = parseFloat(f[4])
        except ValueError: discard
        p.loop = f.len > 3 and f[3] == "true"
      else: result.add Message(sender: p.pid, fields: f)
    if not open: n.drop(p)

proc takeGone*(n: PeerNet): seq[int] =
  if n == nil: return
  result = n.gone
  n.gone.setLen 0

proc close*(n: PeerNet) =
  if n == nil: return
  for p in n.peers: p.sock.close()
  for p in n.unnamed: p.sock.close()
  n.server.close()
  removeFile(n.path)
