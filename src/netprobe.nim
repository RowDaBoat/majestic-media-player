## Whether the network answers: a quick request (curl) to a link's host, so a
## dropped stream opens again as soon as the network is back, not after a
## wait that can't know how long it's gone for, nor with yt-dlp hanging on
## a network that isn't there.

import std/[osproc, uri]

const
  ProbeTime = "3"  ## seconds a probe waits for an answer
  Offline = [5, 6, 7, 28, 35, 52, 56]
    ## curl's exits for no network: couldn't resolve (the proxy or the host),
    ## couldn't connect, timed out, the connection cut or answered nothing

type
  NetProbe* = ref object
    p: Process                ## nil once finished
    up*: bool                 ## once finished: the host answered

proc running*(j: NetProbe): bool = j != nil and j.p != nil

proc probeHost*(url: string): NetProbe =
  ## Asks url's host for anything at all; nil when curl can't be run.
  var host = ""
  try: host = parseUri(url).hostname
  except UriParseError: discard
  if host.len == 0: return nil
  let null = when defined(windows): "NUL" else: "/dev/null"
  try:
    NetProbe(p: startProcess("curl", args = ["-sI", "-o", null, "--max-time", ProbeTime,
      "https://" & host & "/"], options = {poUsePath, poStdErrToStdOut, poDaemon}))
  except OSError:
    nil

proc poll*(j: NetProbe): bool =
  ## True when the probe just finished (see up).
  if not j.running or j.p.running: return false
  j.up = j.p.peekExitCode notin Offline
  j.p.close()
  j.p = nil
  true
