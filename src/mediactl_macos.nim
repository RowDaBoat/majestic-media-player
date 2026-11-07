## Now Playing (Control Center, the menu bar's Now Playing item) and the media
## keys, through MPNowPlayingInfoCenter and MPRemoteCommandCenter. Included
## by mediactl.nim.

import std/math
import cocoa

type
  MediaControls* = ref object
    state: MediaState
    sentAt: float          ## when the state was last handed to the system
    sent: bool

proc newMediaControls*(window: Window): MediaControls =
  mmpMediaInit()
  MediaControls()

proc poll*(c: MediaControls): seq[MediaCommand] =
  var cmd: MmpMediaCommand
  while mmpMediaPoll(cmd) != 0:
    result.add MediaCommand(kind: MediaCommandKind(cmd.kind), value: cmd.value)

proc update*(c: MediaControls, s: MediaState, time: float) =
  ## The system runs the position on from the rate it was given, so it's only
  ## sent again on a change, or when playback strayed from that (a seek).
  let o = c.state
  let expected = o.position + (if o.status == msPlaying: (time - c.sentAt) * o.rate else: 0)
  let changed = not c.sent or s.status != o.status or s.title != o.title or
    s.artist != o.artist or s.album != o.album or s.duration != o.duration or
    s.rate != o.rate or s.canPlay != o.canPlay or s.canPause != o.canPause or
    s.canSeek != o.canSeek or s.canGoNext != o.canGoNext or
    s.canGoPrevious != o.canGoPrevious or abs(s.position - expected) > 1.5
  if not changed: return
  c.state = s
  c.sentAt = time
  c.sent = true
  mmpMediaUpdate(s.status.ord.cint, s.title.cstring, s.artist.cstring, s.album.cstring,
    s.position, s.duration, s.rate, s.canPlay.cint, s.canPause.cint, s.canSeek.cint,
    s.canGoNext.cint, s.canGoPrevious.cint)
