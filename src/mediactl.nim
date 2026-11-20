## Playback controls in the desktop's task bar, one implementation per
## platform with the same interface: MPRIS on Linux, which Plasma's task manager
## shows in its window tooltips (and media keys and widgets use), thumbnail
## toolbar buttons on Windows, and Now Playing and the media keys on macOS. The main loop feeds it the state with `update`
## and carries out what `poll` returns.

import windy

type
  MediaStatus* = enum
    msStopped = "Stopped", msPaused = "Paused", msPlaying = "Playing"

  MediaState* = object
    status*: MediaStatus
    title*, artist*, album*, url*: string
    position*, duration*: float   ## seconds
    rate*: float
    volume*: float                ## 1 is 100%
    canPlay*, canPause*, canSeek*, canGoNext*, canGoPrevious*: bool

  MediaCommandKind* = enum
    mcPlay, mcPause, mcPlayPause, mcStop, mcNext, mcPrevious,
    mcSeekBy, mcSeekTo, mcVolume, mcRaise, mcQuit

  MediaCommand* = object
    kind*: MediaCommandKind
    value*: float                 ## seconds, or the volume with 1 as 100%

when defined(windows):
  include mediactl_win32
elif defined(macosx):
  include mediactl_macos
else:
  include mediactl_mpris
