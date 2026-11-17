## mpv-backed playback core: one instance for playback (the app runs a second
## as a seamless loop's standby, and a video-less third for a loop's sound)
## and a lightweight instance that renders seek-bar thumbnails.

import std/[algorithm, atomics, json, math, osproc, sequtils, strutils, os, tables, times]
import mpv, videogl, spherical, gpumem, coverart, modstream, midistream, cue, folderpics, wsaud, m2c
from config import AudioExtensions
from ytdlp import YtdlSubLangs, linkSphere, hlsSphere

type
  DemuxMode* = enum
    ## How mpv reads a file (Player.setDemuxing). Played backward, mpv reads
    ## a stretch further back each time it runs out (setBackStep). In its
    ## demuxer thread, that thread misses the call now and then: once it has
    ## read to the file's end (playback stands still a second or two, for
    ## good with mpv's cache). Read in mpv's core instead (threadless),
    ## nothing is read ahead: on a slow drive, playing forward stands still at
    ## each hiccup (tmp/rvs/eofprobe.py, tmp/slowfs).
    dmAhead       ## mpv's demuxer thread reads ahead, with its cache as mpv
                  ## picks (on for a network or FUSE drive): a file played
                  ## forward, as with reverse playback off
    dmThreadless  ## read in mpv's core as needed: played backward, or sound
                  ## alone, which turns around itself at once

  ReplayGain* = object
    ## An audio track's ReplayGain values, as mpv read them from its tags.
    ## Without album values mpv gives the track's for them.
    known*: bool              ## the file has them
    trackGain*, albumGain*: float  ## dB
    trackPeak*, albumPeak*: float  ## linear, 1 = full scale; 0 when unknown

  SideGain* = object
    ## A file's ReplayGain as its .m2c (m2c) has it, which mpv can't read.
    rg*: ReplayGain           ## known: the .m2c has values
    hidden*: bool             ## it clears REPLAYGAIN_TRACK_GAIN: the file's own don't count

  RgSettings* = object
    ## ReplayGain as Options has it, given by the app (syncSettings): files
    ## open with mpv's options for them (rgOpts).
    known*: bool              ## given at least once
    mode*: int                ## 0 off, 1 track gain, 2 album gain
    preamp*, fallback*: float ## dB: added to values; for files without
    noClip*: bool             ## lowered so the peak stays at full scale

  Track* = object
    id*: int
    kind*: string           ## "video", "audio", "sub"
    title*, lang*, codec*: string
    selected*, external*, albumArt*: bool
    file*: string           ## an external track's file
    channels*, sampleRate*: int
    width*, height*: int
    fps*: float
    default*, forced*: bool
    rg*: ReplayGain           ## audio tracks

  Chapter* = object
    time*: float
    title*: string

  Prop = enum
    pPause, pTimePos, pDuration, pEof, pTracks, pChapters, pVolume, pMute,
    pSpeed, pVideoParams, pAudioChannels, pIdle, pSeeking, pCacheState,
    pPausedForCache

  Player* = ref object
    h*: MpvHandle
    render*: MpvRenderContext
    target*: VideoTarget
    path*: string
    source*: string           ## what mpv opened, when not path (a link's
                              ## saved part: path is the link)
    partStart*, partEnd*: float  ## a link's saved part: where it starts
                              ## and ends, link time (partEnd 0: not one)
    fullDuration*: float      ## and the link's length, shown as the duration
    beyond*: float = -1       ## a seek asked for past the saved part
    dumping*: bool            ## writing what it streams to a file (dumpFrom)
    dumpFailed*: bool         ## that ended in an error (its file is no good)
    dumpId: uint64
    loaded*: bool             ## a file is open
    opening*: bool            ## a file is being opened (links take a while)
    stopped*: bool            ## our Stop state (paused at 0, video hidden)
    paused*: bool
    seeking*: bool
    timePos*, duration*: float
    timeAt: float             ## when timePos last changed, epochTime
    frameDur: float           ## the last step of timePos while playing, a frame
    holdTime*: bool           ## the app sets timePos (step frames): mpv's lags behind
    holdJumps*: int           ## jumps of the step holding it: any later jump's time counts
    endPinned: bool           ## timePos is the last frame's (pinEnd), until eof-reached goes
    eofJumps: int             ## jumps when the end was reached
    timeJumps: int            ## jumps when the last time was taken
    eofReached*: bool
    backward*: bool           ## playing in reverse (ping-pong loops)
    demux*: DemuxMode         ## how mpv reads the file opened (setDemuxing)
    backStep: float = 60      ## demuxer-backward-playback-step as set (setBackward)
    volume*: float
    muted*: bool
    speed*: float = 1
    tracks*: seq[Track]
    chapters*: seq[Chapter]
    buffered*: seq[(float, float)]  ## spans read ahead into the cache, seconds
    cacheAhead*: float = -1   ## seconds read ahead of the position (-1: unknown)
    buffering*: bool          ## playback held until the cache fills
    videoConfigs*: int        ## times the video was set up (a picture's size came)
    shotAsked*, shotDone*: bool  ## takeShot: asked for, and come (in shot)
    shot*: tuple[w, h: int, pixels: seq[uint32]]  ## the frame it took, w 0 for none
    videoW*, videoH*: int     ## display size (aspect-corrected)
    pixelW*, pixelH*: int     ## stored size, as upright as shown (what ffmpeg
                              ## filters see, autorotation included)
    audioChannels*: int
    loadError*: string
    hookError*: string        ## yt-dlp's error opening the link (mpv's hook),
                              ## "ERROR: ..."; mpv's own (loadError) is then
                              ## about the web page it tried in its place
    streamError*: string      ## why a link's stream was cut short ("HTTP error
                              ## 403"): mpv then skips to the end
    gpuOom*: bool             ## mpv told of the GPU out of memory; the app clears it
    sphere*: SphereInfo       ## 360° metadata of the open file
    savedSphere: SphereInfo   ## its saved part's (mpv's files don't say)
    meshRead: Process         ## reading a link's mesh (startMeshRead); nil otherwise
    meshHead: string          ## where it goes
    meshHls: bool             ## LinkSphere's
    justLoaded*: bool         ## set on FILE_LOADED, cleared by the app
    eofHandled*: bool
    props*: Table[string, string]  ## MirroredProps as they are now
    info*: Table[string, string]   ## InfoProps as they are now
    rgs*: RgSettings          ## ReplayGain's settings: files open with them (rgOpts)
    noVideo*: bool            ## Video Track > Always Disable: each file opens
                              ## without its video (a cover still shows)
    fileCover*: bool = true   ## Show Front Cover (file): a picture named after
                              ## the audio file is its cover, over any other;
                              ## off, it's never shown
    folderPicture: string     ## the file's folder picture (addFolderPicture),
                              ## "" for none
    quickCoverFor*: proc (path: string): string
                              ## the picture mpv is to show as a saved quick
                              ## cover of the file at path, "" for none
    hidden*: bool             ## a seamless loop's standby: copies the shown
                              ## player's file details instead of finding them
    startDelay*: float = 0.04 ## seamless loops: how long it takes to get going
                              ## from paused, media seconds
    jumps*: int               ## seeks, steps and stops asked for through
                              ## this module (not a loop's own jumps back)
    soundKey: string          ## a loop sound's filters and track as set
    loopAf: string            ## a loop sound's own filters (before the equalizer's)
    eqAf: string              ## the equalizer's filter as af has it, "" when off
    eqSet: seq[float]         ## the gains in it
    eqLive: seq[float]        ## the gains last sent, af or af-command
    turnAf: string            ## a seamless turn's fades (setTurnFades), "" for none
    openOpts*: string         ## mpv's per-file options the file was opened with (load)
    restarts*: int            ## playback restarts (after loads and seeks)
    loadRestarts: int         ## restarts as the file was opened
    loadedRestarts*: int      ## and once it had loaded (the next is its own)
    keepTime*: bool           ## opening: its time and duration stay as they are
    openSeek: float           ## sought there while keepTime, -1: not; done once open
    pausedAt: float           ## when it last paused, epoch seconds
    endPaused: bool           ## paused by mpv on reaching the end, not by the user
    endHold*: bool            ## sent to the last frame to stay there: not playback ending
    endResumed*: bool         ## a seek back from there just set it playing
    sought*: float            ## where a seek is headed until its time gets there, -1: none
    landing: float = -1       ## the time to show until an exact seek lands, -1: none
    landingJumps, landingRestarts: int  ## jumps and restarts when it was asked for
    landingAt: float          ## and when, epochTime
                              ## (the same media again) until it has loaded
    expanded*: seq[string]    ## expandText results, in order
    linkHooked: bool          ## LinkWaitHook added
    linkHold: uint64          ## the opening held until linkHoldUntil (its
    linkHoldUntil*: float     ## hook id, 0 for none), epoch seconds
    nextPath*: string         ## gapless: the file queued in mpv's playlist
                              ## (queueNext), which mpv goes on to by itself
    nextSource, nextKey: string  ## what mpv opens for it, and the request
    nextStart: float          ## where it starts
    gapless: bool             ## gapless-audio is on (left on past the change of
                              ## file: turned off then, mpv would cut the sound)
    advanced*: bool           ## mpv went on to nextPath; the app takes it from here
    endedPath*: string        ## and the file that ended then

  Preview* = ref object
    h*: MpvHandle
    render*: MpvRenderContext
    target*: VideoTarget
    path: string
    busy: bool                ## a seek is in flight
    opening: bool             ## a file asked for hasn't started yet
    wanted, shown: float      ## requested vs. displayed time
    wantedImage, wantedCrop: string  ## showImage's request
    crop: string              ## and the part of the image displayed
    hasFrame*: bool
    usedAt: float             ## when last asked for, epoch seconds

var
  # int, not bool: with MSVC, std/atomics' exchange is a 64-bit interlocked
  # exchange whatever the type, so on a bool it zeroes the 7 bytes after it
  # (other globals).
  frameReady: Atomic[int]
  previewReady: Atomic[int]
  osdReady: Atomic[int]

let logAll = existsEnv("MMP_DEBUG")  ## mpv's log (warnings and up) to stderr

const
  LandingWait* = 0.5  ## seconds for a seek that shows no sign of landing
  MirroredProps* = ["aid", "vid", "sid", "secondary-sid", "volume", "speed",
    "sub-delay", "audio-delay", "sub-visibility", "slang", "alang",
    "sub-file-paths", "sub-align-x", "sub-align-y", "sub-margin-x",
    "sub-margin-y", "sub-pos", "sub-scale", "sub-font", "sub-bold", "sub-italic",
    "sub-font-size", "sub-color", "sub-outline-size", "sub-outline-color",
    "sub-shadow-offset", "sub-back-color", "sub-ass-override", "video-margin-ratio-left",
    "video-margin-ratio-right", "video-margin-ratio-top",
    "video-margin-ratio-bottom", "keepaspect", "video-scale-x",
    "video-scale-y", "osd-level", "osd-msg3", "osd-fractions", "osd-scale",
    "osd-margin-x", "osd-margin-y", "osd-outline-size", "osd-bar-align-x",
    "osd-bar-align-y", "osd-bar-w", "osd-bar-h", "osd-bar-outline-size",
    "osd-bar-marker-min-size", "loop-file", "ab-loop-a", "ab-loop-b",
    "audio-display", "replaygain", "replaygain-preamp",
    "replaygain-clip", "replaygain-fallback"]
    ## What the app sets at runtime, observed (into `props`) so a second
    ## player can be made to look and sound the same (seamless loops)
  EqFreqs* = [31.0, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    ## The equalizer's bands, Hz: a peaking filter an octave wide on each
  MirrorBase = 1000           ## observation ids of MirroredProps
  InfoProps* = ["media-title", "metadata/by-key/Artist", "metadata/by-key/Album"]
    ## the file's details, kept in info: read every so often for the system's
    ## media controls, they'd wait out a busy player (one playing backward
    ## stops for a keyframe's span of decoding)
  InfoBase = 2000             ## and theirs
  ExpandReply = 77'u64        ## reply id of expandText
  ShotReply = 80'u64          ## takeShot's
  DumpReply = 1000'u64        ## dumpFrom's, plus its count
  LinkWaitHook = 78'u64       ## reply id of the on_load hooks after yt-dlp's
  CoverHook = 79'u64          ## the on_preloaded hook's (pickCover)
  LinkWaitMax = 30.0          ## seconds a link's opening waits at most
  ContextIdle* = 30.0         ## seconds unused before a render context is freed

const QuickCoverTitle* = "Quick cover"
  ## The title of a quick cover's track: a picture dropped or pasted on a file
  ## without a picture, added as its cover (the app's quickCover)

proc onMainUpdate(d: pointer) {.cdecl.} = frameReady.store(1)
proc onPreviewUpdate(d: pointer) {.cdecl.} = previewReady.store(1)
proc onOsdUpdate(d: pointer) {.cdecl.} = osdReady.store(1)

proc hwdecMode*(): string =
  ## Hardware decoding unless rendering on the CPU (gpumem), which keeps
  ## the GPU's memory out of it.
  if cpuWanted: "no" else: "auto-safe"

proc setHdrOpts(h: MpvHandle) =
  ## How HDR video (HLG or PQ: iPhone recordings, HDR10) is brought down to
  ## the screen's SDR. The render API draws with vo_gpu, which can't apply
  ## Dolby Vision's per-scene mapping, and its default curve keeps HLG's
  ## reference white (203 nits) at full white: an iPhone video's lit walls,
  ## skies and screens all crowd near white, the picture too bright and
  ## washed out next to the phone. Hable lowers the whole curve to make
  ## room for the highlights; against libplacebo with the Dolby Vision
  ## metadata applied (vo_gpu_next) on 35 iPhone 13 Pro Max frames, day and
  ## night, it halves the difference and leaves no brightness bias (+18
  ## levels in 255 before). Only HDR goes through the curve: SDR video comes
  ## out the same to the byte. The peak detection it pairs with is mpv's
  ## default (hdr-compute-peak).
  h.setOpt("tone-mapping", "hable")

proc takeFrameReady*(): bool = frameReady.exchange(0) != 0
proc takePreviewReady*(): bool = previewReady.exchange(0) != 0
proc takeOsdReady*(): bool = osdReady.exchange(0) != 0

proc observe(h: MpvHandle) =
  for (p, name, fmt) in [
      (pPause, "pause", fmtFlag), (pTimePos, "time-pos", fmtDouble),
      (pDuration, "duration", fmtDouble), (pEof, "eof-reached", fmtFlag),
      (pTracks, "track-list", fmtNode), (pChapters, "chapter-list", fmtNode),
      (pVolume, "volume", fmtDouble), (pMute, "mute", fmtFlag),
      (pSpeed, "speed", fmtDouble), (pVideoParams, "video-params", fmtNode),
      (pAudioChannels, "audio-params/channel-count", fmtInt64),
      (pIdle, "idle-active", fmtFlag), (pSeeking, "seeking", fmtFlag),
      (pCacheState, "demuxer-cache-state", fmtNode),
      (pPausedForCache, "paused-for-cache", fmtFlag)]:
    discard mpv_observe_property(h, p.uint64, name.cstring, fmt)
  for i, name in MirroredProps:
    discard mpv_observe_property(h, uint64(MirrorBase + i), name.cstring, fmtString)
  for i, name in InfoProps:
    discard mpv_observe_property(h, uint64(InfoBase + i), name.cstring, fmtString)

when defined(windows):
  type MemoryStatusEx = object
    length, memoryLoad: uint32
    totalPhys, availPhys, totalPageFile, availPageFile, totalVirtual, availVirtual,
      availExtendedVirtual: uint64
  proc GlobalMemoryStatusEx(s: ptr MemoryStatusEx): int32 {.stdcall, dynlib: "kernel32", importc.}

proc totalMemory(): float =
  ## The computer's RAM, bytes; 0 if it can't be told.
  when defined(windows):
    var s = MemoryStatusEx(length: uint32(sizeof(MemoryStatusEx)))
    if GlobalMemoryStatusEx(s.addr) != 0: s.totalPhys.float else: 0.0
  else:
    try:
      for l in lines("/proc/meminfo"):
        if l.startsWith("MemTotal:"): return parseFloat(l.splitWhitespace()[1]) * 1024
    except CatchableError: discard
    0.0

const IntraCodecs = ["prores", "apv", "dnxhd", "mjpeg", "jpeg2000", "cfhd", "ffv1",
  "utvideo", "huffyuv", "ffvhuff", "magicyuv", "rawvideo", "v210", "v410", "r210",
  "png", "dvvideo", "hap", "ljpeg", "jpegls", "lagarith", "dxv", "qoi", "tiff",
  "dpx", "exr", "notchlc", "hqx", "hq_hqa", "cllc", "mjpegb", "avrp", "ayuv", "y41p",
  "yuv4", "v308", "v408", "bitpacked", "sgirle", "vc1image"]
  ## Video codecs whose every frame is a keyframe (FFmpeg's intra-only ones
  ## found in files): editing and camera formats, lossless and raw video.
  ## (backBatches)

proc reversalBytes(): float =
  ## mpv's video-reversal-buffer, as newPlayer sets it.
  let gib = 1024.0 * 1024 * 1024
  clamp(totalMemory() / 8, gib, 6 * gib)

proc intraVideo*(p: Player): bool =
  ## The video playing has keyframes alone (IntraCodecs): no span of
  ## frames for mpv to decode before showing one, playing backward.
  p.tracks.anyIt(it.kind == "video" and it.selected and not it.albumArt and
                 it.codec in IntraCodecs)

proc backBatches*(p: Player): tuple[video, audio: int] =
  ## How many keyframes' spans of the video, and packets of sound, mpv
  ## decodes at a time playing backward (video- and audio-backward-batch):
  ## run out, it reads its stretch of the file again (setBackStep).
  ## A video of keyframes alone, one frame at a time with the decoder
  ## flushed after each, uses one of its threads: ProRes 1080p60 played
  ## backward at 0.88x, APV stood still 0.1 s at each stretch; with 8, none
  ## (tmp/rvs/probe.py). Not many more: mpv shows none of a batch before
  ## it's decoded it all (ProRes, 30: stood still 70 ms each time). 8, as
  ## long as that fits twice in mpv's reversal buffer. Anything else: 1, a
  ## keyframe and the frames that follow it, up to seconds of them.
  ## Sound: mpv's 10 packets are a fifth of a second of AAC or MP3: by far
  ## most of the stretches read again (an OBS recording: 125 in 20 s; 22
  ## with a second of sound at a time). So ~a second by the codec's packet
  ## size, 10 to 100 packets.
  result = (1, 10)
  for t in p.tracks:
    if not t.selected: continue
    if t.kind == "video" and not t.albumArt and t.codec in IntraCodecs:
      let frame = max(t.width * t.height, 1920 * 1080).float * 6  # bytes, 4:4:4 at 16 bits
      let fit = int(reversalBytes() / (2 * frame))
      result.video = clamp(fit, 1, 8)
    elif t.kind == "audio":
      # Packets of a frame each, every one a keyframe (mpv's batch counts
      # those): by its samples. Others (TrueHD and MLP, whose keyframes are
      # their sync frames, ~15 a second: 1024 of them, a minute of sound,
      # overflowed mpv's packet queue) keep mpv's 10.
      let samples = case t.codec
        of "aac": 1024.0
        of "mp3", "mp2", "mp1": 1152.0
        of "opus": 960.0
        of "vorbis": 1024.0
        of "flac", "alac": 4096.0
        of "ac3", "eac3": 1536.0
        of "dts": 512.0
        else: 0.0
      if samples > 0:
        let rate = if t.sampleRate > 0: t.sampleRate.float else: 48000.0
        result.audio = clamp(int(round(rate / samples)), 10, 100)

proc setBackStep*(p: Player)

proc applyBatches(p: Player) =
  ## backBatches, for a player read in mpv's core (only that one plays
  ## backward); mpv takes them as it next reads. A video of keyframes alone
  ## also steps back less far (setBackStep).
  let (v, a) = if p.demux == dmThreadless: p.backBatches else: (1, 10)
  p.h.setProp("video-backward-batch", $v)
  p.h.setProp("audio-backward-batch", $a)
  if p.demux == dmThreadless and p.intraVideo and not p.path.contains("://"): p.setBackStep()

proc newPlayer*(volume: float, muted, osd: bool, pictureOnly = false): Player =
  ## pictureOnly: a hidden player for frames alone (the keyframe bridge):
  ## no sound, no scripts (quicker to set up), paused, stepping at speed.
  result = Player(volume: volume, muted: muted, hidden: pictureOnly)
  let h = mpv_create()
  if h == nil: raise newException(MpvError, "mpv_create failed")
  result.h = h
  h.setOpt("config", "no")
  h.setOpt("vo", "libmpv")
  h.setOpt("hwdec", hwdecMode())
  if cpuWanted: h.setOpt("profile", "fast")  # cheap scaling for the software renderer
  h.setHdrOpts()
  # Direct rendering has the decoder wait on the render thread (ours) for
  # frame buffers, so any blocking mpv call from the UI could deadlock.
  h.setOpt("vd-lavc-dr", "no")
  h.setOpt("keep-open", "yes")
  # Gapless, mpv calls EOF with the audio still queued, and the next file
  # (handleEof) would throw that away: the last ~0.25 s of every file. Only
  # while mpv has the next file itself (queueNext) is it gapless.
  h.setOpt("gapless-audio", "no")
  h.setOpt("prefetch-playlist", "yes")  # the queued file opened ahead of time
  # YouTube sends a request left open to the file's end slowly (~0.25 MB/s,
  # enough to stream forward), a bounded one at full speed (10+ MB/s): FFmpeg
  # asks in 10 MiB pieces, as yt-dlp does. Playing backward needs that, each
  # step back a few seconds' worth read at once (setBackward). The yt-dlp
  # hook adds its own (cookies) to these.
  h.setOpt("stream-lavf-o", "request_size=10485760,multiple_requests=1")
  # Playing backward, mpv decodes a keyframe's span of frames before showing
  # its last one, keeping them in this much memory, and throws away those that
  # don't fit (the picture stands still, then jumps): 1 GiB by default, a
  # 5 s span of 1080p60, but a quarter of one in 4K60 (3.7 GB). Only what a
  # span holds is taken, so up to an eighth of the RAM, 6 GiB at most.
  h.setOpt("video-reversal-buffer", $int64(reversalBytes()))
  # mpv's pipewire output drops the end of a file that doesn't fill PipeWire's
  # last block (up to ~20 ms, clear on a short sound that ends loud); pulse,
  # served by PipeWire all the same, plays it all.
  when defined(linux): h.setOpt("ao", "pulse,")
  h.setOpt("idle", "yes")
  h.setOpt("terminal", "no")
  h.setOpt("input-default-bindings", "no")
  h.setOpt("input-vo-keyboard", "no")
  h.setOpt("osc", "no")
  h.setOpt("keepaspect", "no")         # we size the target to the aspect
  h.setOpt("volume-max", "200")
  h.setOpt("volume-gain-min", "-150")  # silent enough while a loop sound plays
  h.setOpt("volume", $volume)
  h.setOpt("mute", if muted: "yes" else: "no")
  h.setOpt("osd-level", if osd: "1" else: "0")
  h.setOpt("sub-auto", "fuzzy")
  h.setOpt("screenshot-format", "png")
  h.setOpt("audio-client-name", "majestic-media-player")
  h.setOpt("audio-display", "embedded-first")
  # mpv finds the picture named after an audio file; Options' folder
  # pictures are the app's (addFolderPicture): mpv's names take no patterns.
  h.setOpt("cover-art-whitelist", "")
  # Links go through yt-dlp (useYtdlp), which also fetches their subtitles.
  h.setOpt("ytdl", "no")
  # A playlist's videos are the app's playlist entries (listYoutube): a
  # video's link streams that video alone.
  h.setOpt("ytdl-raw-options", "sub-langs=%" & $YtdlSubLangs.len & "%" &
    YtdlSubLangs & ",no-playlist=")  # %n%: n bytes taken as they are
  if pictureOnly:
    for (k, v) in [("load-scripts", "no"), ("aid", "no"), ("osd-level", "0"), ("pause", "yes"),
                   ("speed", "100"), ("sub-auto", "no"), ("audio-file-auto", "no")]:
      h.setOpt(k, v)
  check mpv_initialize(h), "mpv_initialize"
  modstream.register(h)  # module streams
  midistream.register(h)  # MIDI files, through FluidSynth
  wsaud.register(h)  # Westwood .aud, decoded from its start
  # mpv's log goes to stderr only when MMP_DEBUG is set; load failures surface
  # in the status bar regardless. Errors come in anyway, for yt-dlp's
  # (hookError).
  discard mpv_request_log_messages(h, (if logAll: "warn" else: "error").cstring)
  observe(h)
  discard mpv_hook_add(h, CoverHook, "on_preloaded", 0)

proc useYtdlp*(p: Player, path: string) =
  ## Has mpv open links with the yt-dlp at path, through its built-in hook.
  ## The hook looks for yt-dlp once, on the first link, and keeps what it
  ## found (nothing included), so each path gets a hook of its own, loaded
  ## once there is a yt-dlp to find (setting ytdl later loads none).
  # all_formats (the hook's default in newer mpv) opens each format lazily,
  # its video track without a codec until then: dump-cache can't write
  # that, so a saved link would come back without its picture.
  p.h.setProp("script-opts", "ytdl_hook-ytdl_path=" & path & ",ytdl_hook-all_formats=no")
  p.h.command("load-script", "@ytdl_hook.lua")
  # YouTube turns down (403) a link's formats until a few seconds after
  # yt-dlp found them (their available_at, which yt-dlp itself sleeps
  # for), and mpv's hook doesn't wait: these hooks, run after it, do.
  if not p.linkHooked:
    p.linkHooked = true
    for name in ["on_load", "on_load_fail"]:
      discard mpv_hook_add(p.h, LinkWaitHook, name.cstring, 15)

proc releaseLink(p: Player) =
  ## Lets a held opening go on (see useYtdlp).
  if p.linkHold != 0:
    discard mpv_hook_continue(p.h, p.linkHold)
    (p.linkHold, p.linkHoldUntil) = (0'u64, 0.0)

proc linkAvailableAt(p: Player): float =
  ## When YouTube serves the formats yt-dlp just picked for the link,
  ## epoch seconds; 0 for no wait (or no link).
  let r = p.h.getNode("user-data/mpv/ytdl/json-subprocess-result")
  if r.kind != JObject: return
  try:
    let j = parseJson(r{"stdout"}.getStr)
    result = j{"available_at"}.getFloat
    for f in j{"requested_formats"}.getElems:
      result = max(result, f{"available_at"}.getFloat)
  except CatchableError: discard

proc newLoopSound*(volume: float): Player =
  ## A video-less player for an A-B loop's sound (loopSoundAt); paused,
  ## muted and hidden until the app has it play.
  result = Player(volume: volume, muted: true, hidden: true, startDelay: 0.02)
  let h = mpv_create()
  if h == nil: raise newException(MpvError, "mpv_create failed")
  result.h = h
  for (k, v) in [("config", "no"), ("vid", "no"), ("sid", "no"),
                 ("audio-display", "no"), ("sub-auto", "no"),
                 ("audio-file-auto", "no"), ("cover-art-auto", "no"),
                 ("load-scripts", "no"), ("keep-open", "yes"), ("idle", "yes"),
                 ("pause", "yes"), ("terminal", "no"),
                 ("input-default-bindings", "no"), ("volume-max", "200"),
                 ("volume", $volume), ("mute", "yes"),
                 ("audio-client-name", "majestic-media-player")]:
    h.setOpt(k, v)
  check mpv_initialize(h), "loop sound mpv_initialize"
  if existsEnv("MMP_DEBUG"):
    discard mpv_request_log_messages(h, "warn")
  observe(h)

proc eqFilter(gains: openArray[float]): string =
  ## The equalizer as an mpv af entry, labelled "eq", its bands named b0-b9
  ## for af-command.
  result = "@eq:lavfi=["
  for i, f in EqFreqs:
    if i > 0: result.add ","
    result.add "equalizer@b" & $i & "=f=" & $int(f) & ":t=o:w=1:g=" & $gains[i]
  result.add "]"

proc applyAf(p: Player) =
  p.h.setProp("af", [p.loopAf, p.turnAf, p.eqAf].filterIt(it.len > 0).join(","))

const TurnShift = 1_000_000
  ## Seconds added to the times the turn's fades see: afade takes no negative
  ## times, and playing backward, mpv's are the file's times negated.

proc turnFormat*(p: Player): string =
  ## The decoded sound's sample format in ffmpeg's name, if a turn's filters
  ## can take it as it is ("" if not). Filters giving out another format
  ## than they get have mpv open its sound output anew, its queued sound
  ## lost (afade takes these; adelay only planar ones, converted back).
  case p.h.getStr("audio-params/format")
  of "s16": "s16"
  of "s32": "s32"
  of "float": "flt"
  of "double": "dbl"
  of "s16p": "s16p"
  of "s32p": "s32p"
  of "floatp": "fltp"
  of "doublep": "dblp"
  else: ""

proc setTurnFades*(p: Player, fadeIn = NaN, fadeOut = NaN, d = 0.02, shift = 0.0,
                   fmt = "", rate = 0, startIn = false) =
  ## A seamless turn's fades (the app's turnTick): the sound fades in over
  ## `d` seconds centered on the file's time fadeIn, silent before it, or out
  ## centered on fadeOut, silent after it; NaN for neither. "Before" and
  ## "after" go the way the player plays, so set them after setBackward.
  ## ffmpeg's afade places them by the file's time, so to the sample. A
  ## change of af goes to the frames filtered from then on, mpv's output
  ## buffer ahead of what's heard (~0.3 s), and its other filters (the
  ## equalizer) carry on as they are, unbroken. Any seek recreates the
  ## filters from af: the fades last until cleared.
  ## `shift` moves the sound on (positive) or holds it back, seconds, to the
  ## sample, by dropping samples or putting silence in as the new filters
  ## start: for a standby still silent, and once only (the next call without
  ## it leaves it done; a seek before then would do it again). It needs the
  ## decoded sound's sample format (turnFormat) and rate, as the playing
  ## player has them: asking a player playing backward could wait on its
  ## core reading the file.
  ## `startIn` fades in over `d` from the first sample the filters get after
  ## the next seek (they're made anew), wherever that is: for a standby whose
  ## sound starts at its picture's frame, a frame's time off where it's sent.
  let dir = if p.backward: -1.0 else: 1.0
  let f = (proc (t: float): string = formatFloat(t, ffDecimal, 6))
  var fades: seq[string]
  let n = if shift < 0 and fmt.len == 0: 0 else: int(round(abs(shift) * rate.float))
  if n > 0:
    fades.add(if shift > 0: "atrim=start_sample=" & $n
              else: "adelay=delays=" & $n & "S:all=1,aformat=sample_fmts=" & fmt &
                ",asetpts=PTS-" & $n & "/SR/TB")
  if startIn: fades.add "afade=t=in:ss=0:d=" & f(d) & ":curve=qsin"
  for (t, kind) in [(fadeIn, "in"), (fadeOut, "out")]:
    if not t.isNaN:
      fades.add "afade=t=" & kind & ":st=" & f(TurnShift.float + dir * t - d / 2) &
        ":d=" & f(d) & ":curve=qsin"
  let shifted = n > 0
  let af = if fades.len == ord(shifted): "" else:
    "@turn:lavfi=[" & (if shifted: fades[0] & "," else: "") & "asetpts=PTS+" & $TurnShift &
      "/TB," & fades[ord(shifted) .. ^1].join(",") & ",asetpts=PTS-" & $TurnShift & "/TB]"
  if af == p.turnAf: return
  p.turnAf = af
  p.applyAf()

proc clearTurnFades*(p: Player) =
  ## No turn's fades: before anything that seeks, as the fades would be
  ## made again from af, silencing the wrong side of their time.
  if p.turnAf.len > 0: p.setTurnFades()

proc turnFaded*(p: Player): bool = p.turnAf.len > 0

proc setEqualizer*(p: Player, on: bool, gains: seq[float], live = false) =
  ## The equalizer on or off with these gains (dB, one per EqFreqs). Setting
  ## af rebuilds the filters, dropping a moment of sound, so `live` changes
  ## (a slider on the move) only go to the running filters; a call without
  ## it once they settle has af follow, for the next file or track.
  if on and live and p.eqAf.len > 0:
    if gains != p.eqLive:
      for i, g in gains:
        if i >= p.eqLive.len or p.eqLive[i] != g:
          p.h.commandAsync("af-command", "eq", "g", $g, "equalizer@b" & $i)
      p.eqLive = gains
    return
  # The running filters already have the gains that af is about to.
  if on == (p.eqAf.len > 0) and (not on or gains == p.eqSet): return
  p.eqAf = if on: eqFilter(gains) else: ""
  p.eqSet = gains
  p.eqLive = gains
  p.applyAf()

proc loopSoundAt*(p: Player, path, aid: string, a, b, start: float) =
  ## Has the loop sound wait, paused, at A of the loop from A to B (path's
  ## audio track `aid`): from there it plays A to B over and over, seamless
  ## to the sample, as ffmpeg's atrim and aloop filters keep the loop's sound
  ## and repeat it. Decoding begins at `start`, a little before A, so A
  ## sounds as in continuous play. Again on the same loop: back to A.
  let f = (proc (t: float): string = formatFloat(t, ffDecimal, 6))
  let af = "lavfi=[atrim=start=" & f(a) & ":end=" & f(b) &
    ",aloop=loop=-1:size=2147483647]"  # its size: all there is
  p.h.setProp("pause", true)
  p.stopped = false
  p.eofReached = false
  p.timePos = a
  if af & aid != p.soundKey:
    p.soundKey = af & aid
    p.loopAf = af
    p.h.setProp("aid", aid)
    p.applyAf()
  if path != p.path or not p.loaded:
    p.path = path
    p.loaded = false
    p.loadError = ""
    p.h.commandAsync("loadfile", path, "replace", "-1", "start=" & f(start))
  else:
    # A seek starts the filters over, so the loop's sound with them.
    p.h.commandAsync("seek", f(start), "absolute", "exact")

proc initRender*(p: Player) =
  ## Must run with the window's GL context current. Only once something with
  ## video opens (the on_preloaded hook): each context takes up ~200 MiB of
  ## video memory on NVIDIA, for the CUDA context of its hardware decoding.
  if p.render != nil: return
  # Non-blocking: the app waits for each frame's target time itself, so the UI
  # keeps running between video frames.
  p.render = createRenderContext(p.h, blockForTargetTime = false)
  mpv_render_context_set_update_callback(p.render, onMainUpdate, nil)

proc freeRender*(p: Player) =
  ## Its context and target, GL context current; video stops if it's playing.
  if p.render == nil: return
  mpv_render_context_free(p.render)
  p.render = nil
  p.target.free()

proc wantsRender(p: Player): bool =
  ## Whether what's opening may need a video output. Mpv's video fails for
  ## the file if there's no render context as it opens one. A link's tracks
  ## can turn up later.
  if p.path.contains("://"): return true
  for i in 0 ..< p.h.getInt("track-list/count"):
    if p.h.getStr("track-list/" & $i & "/type") == "video": return true

proc replayGainOf*(t: JsonNode): ReplayGain =
  ## A track-list entry's ReplayGain values.
  if t.kind != JObject or not t.hasKey("replaygain-track-gain"): return
  result = ReplayGain(known: true,
    trackGain: t{"replaygain-track-gain"}.getFloat, trackPeak: t{"replaygain-track-peak"}.getFloat)
  result.albumGain = t{"replaygain-album-gain"}.getFloat(result.trackGain)
  result.albumPeak = t{"replaygain-album-peak"}.getFloat(result.trackPeak)

proc applied*(rg: ReplayGain, album: bool, preamp: float, noClip: bool): float =
  ## The gain mpv applies with those settings, dB: the track's or the
  ## album's plus the pre-amp, lowered so the peak stays at full scale.
  result = (if album: rg.albumGain else: rg.trackGain) + preamp
  let peak = if album: rg.albumPeak else: rg.trackPeak
  if noClip and peak > 0: result = min(result, -20 * log10(peak))

proc gainValue(vs: seq[string]): float =
  ## "-6.54 dB" -> -6.54; NaN when there's none.
  if vs.len == 0: return NaN
  try: parseFloat(vs[0].strip.split(' ')[0].strip(leading = true, trailing = false, chars = {'+'}))
  except ValueError: NaN

proc sideGain*(side: SideTags): SideGain =
  ## The ReplayGain values in a .m2c (REPLAYGAIN_{TRACK,ALBUM}_{GAIN,PEAK}),
  ## as mpv reads them from tags: a track gain or nothing; without album
  ## values, the track's.
  let tg = side.tags.getOrDefault("REPLAYGAIN_TRACK_GAIN").gainValue
  if tg.isNaN:
    result.hidden = "REPLAYGAIN_TRACK_GAIN" in side.cleared
    return
  let tp = side.tags.getOrDefault("REPLAYGAIN_TRACK_PEAK").gainValue
  let ag = side.tags.getOrDefault("REPLAYGAIN_ALBUM_GAIN").gainValue
  let ap = side.tags.getOrDefault("REPLAYGAIN_ALBUM_PEAK").gainValue
  result.rg = ReplayGain(known: true, trackGain: tg, trackPeak: (if tp.isNaN: 0.0 else: tp))
  (result.rg.albumGain, result.rg.albumPeak) =
    if ag.isNaN: (tg, result.rg.trackPeak) else: (ag, if ap.isNaN: 0.0 else: ap)

proc rgFor*(s: RgSettings, g: SideGain): tuple[mode: string, preamp: float, clip: bool, fallback: float] =
  ## mpv's ReplayGain options for a file: its own values, which mpv reads;
  ## or its .m2c's, which mpv can't: those worked out here (`applied`) and
  ## given as the fallback gain with mpv's ReplayGain off, which mpv then
  ## applies alone (and with it on, only to files without values). Off,
  ## the fallback is 0: mpv applies it all the same.
  let on = s.mode in 1 .. 2
  if g.rg.known:
    ("no", s.preamp, not s.noClip,
     if on: g.rg.applied(s.mode == 2, s.preamp, s.noClip) else: 0.0)
  elif g.hidden:
    ("no", s.preamp, not s.noClip, if on: s.fallback else: 0.0)
  else:
    (["no", "track", "album"][clamp(s.mode, 0, 2)], s.preamp, not s.noClip,
     if on: s.fallback else: 0.0)

proc applyRg*(p: Player, s: RgSettings, g: SideGain) =
  ## The settings onto this player now, for its file's gain g.
  p.rgs = s
  let r = s.rgFor(g)
  p.h.setProp("replaygain", r.mode)
  p.h.setProp("replaygain-preamp", r.preamp)
  p.h.setProp("replaygain-clip", r.clip)
  p.h.setProp("replaygain-fallback", r.fallback)

proc rgOpts(s: RgSettings, path: string): string =
  ## rgFor's options for the file at path, as per-file options: mpv has them
  ## before its sound starts (a .m2c's gain from the first sample, a gapless
  ## change between such files and others at the right level).
  if not s.known or path.len == 0: return ""
  let r = s.rgFor(sideGain(readSide(path)))
  "replaygain=" & r.mode & ",replaygain-preamp=" & formatFloat(r.preamp, ffDecimal, 6) &
    ",replaygain-clip=" & (if r.clip: "yes" else: "no") &
    ",replaygain-fallback=" & formatFloat(r.fallback, ffDecimal, 6)

proc joinOpts(a, b: string): string =
  if a.len == 0: b elif b.len == 0: a else: a & "," & b

proc parseTracks(p: Player, j: JsonNode) =
  p.tracks.setLen 0
  if j.kind != JArray: return
  for t in j:
    p.tracks.add Track(
      id: t{"id"}.getInt, kind: t{"type"}.getStr,
      title: t{"title"}.getStr, lang: t{"lang"}.getStr,
      codec: t{"codec"}.getStr, selected: t{"selected"}.getBool,
      external: t{"external"}.getBool, albumArt: t{"albumart"}.getBool,
      file: t{"external-filename"}.getStr,
      channels: t{"demux-channel-count"}.getInt,
      sampleRate: t{"demux-samplerate"}.getInt,
      width: t{"demux-w"}.getInt, height: t{"demux-h"}.getInt,
      fps: t{"demux-fps"}.getFloat,
      default: t{"default"}.getBool, forced: t{"forced"}.getBool,
      rg: replayGainOf(t))
  p.applyBatches()

proc parseChapters(p: Player, j: JsonNode) =
  p.chapters.setLen 0
  # A cue track's are the whole album's, at the album's times.
  if j.kind != JArray or p.path.isCueEntry: return
  for c in j:
    p.chapters.add Chapter(time: c{"time"}.getFloat, title: c{"title"}.getStr)

proc posNow*(p: Player): float =
  ## The playback position now, finer than timePos (which moves a frame at a
  ## time): what has played since the shown frame's time came in. Never past
  ## the next frame, so a stalled player (just looped or sought) isn't taken
  ## for a playing one.
  if p.paused or p.seeking or p.eofReached or p.stopped or not p.loaded: return p.timePos
  let d = min((epochTime() - p.timeAt) * p.speed, p.frameDur)
  if p.backward: p.timePos - d else: p.timePos + d

proc setBackStep*(p: Player) =
  ## Run out of what it has read playing backward, mpv goes back this far and
  ## reads up to there before playing on (60 s by default): from a link,
  ## ~4 MB, a few tenths of a second's wait. A file reads fast enough, but
  ## all it reads waits in mpv's packet queue (150 MiB), and 60 s of a file
  ## over ~20 Mbps (a screen recording) fills it: backward playback stands
  ## still for good ("Backward playback is likely stuck/broken now"). So
  ## ~40 MB of a file, by its size over its length (the standby has no
  ## bitrate measured yet), 15 s at most (keyframes further apart take two
  ## goes); 10 s while that's unknown; 2 s at least: mpv can't play the
  ## stretch it went back for before it's read it all, in its core (ProRes
  ## at 173 Mbps: 5 s, 108 MB, stood still 0.13-0.2 s; 2 s, none). mpv
  ## keeps none of it once played (it would with its seekable cache, but a
  ## seek into the kept end of a file, its last keyframe's span, then never
  ## gets going: one stream waits on the other, which gets no new packet,
  ## mpv 0.41 demux.c "delaying stream", and a threadless core spins for
  ## good, tmp/rvs/sblat.py, eofprobe.py): each keyframe's span, and each
  ## batch of sound (backBatches), reads its stretch again.
  var step = 60.0
  if p.path.contains("://"):
    let rate = p.h.getFloat("video-bitrate", 0) + p.h.getFloat("audio-bitrate", 0)  # bits/s
    step = if rate > 0: clamp(32e6 / rate, 5, 60) else: 10.0
  elif p.path.len > 0:
    let size = try: getFileSize(p.path).float except CatchableError: 0.0
    let dur = if p.fullDuration > 0: p.fullDuration else: p.duration
    step = if size > 0 and dur > 0: clamp(40e6 * dur / size, 2, 15) else: 10.0
    # A video of keyframes alone needs no step longer than its batch and its
    # sound's (backBatches): a second at most, a quarter at least (ProRes at
    # 173 Mbps read back 8 times a second: 2 s stood still ~70 ms each
    # second, 1 s never).
    if p.intraVideo:
      step = if size > 0 and dur > 0: clamp(40e6 * dur / size, 0.25, 1) else: 1.0
  if step != p.backStep:
    p.backStep = step
    p.h.setProp("demuxer-backward-playback-step", step)

proc timeSince*(p: Player): tuple[pos, at, frame: float] =
  ## The time last told by mpv (the shown frame's), when it came (epochTime)
  ## and the last step it made playing (a frame's time).
  (p.timePos, p.timeAt, p.frameDur)

proc setBackward*(p: Player, on: bool) =
  ## Which way playback goes; mpv turns around where it is (a seek).
  if on == p.backward: return
  p.clearTurnFades()
  if on: p.setBackStep()
  p.backward = on
  p.h.setProp("play-direction", if on: "backward" else: "forward")

proc heardPos*(p: Player): tuple[pos, at: float] =
  ## Where in the file the sound heard now is (mpv's audio-pts: what it gave
  ## the output, less the output's latency), and when, epochTime; pos NaN
  ## when mpv can't tell, or took too long to answer for the time to hold
  ## (a threadless player reads the file in its core). Finer than posNow: to
  ## a fraction of a millisecond, going by recordings of the output.
  let t0 = epochTime()
  let v = p.h.getFloat("audio-pts", NaN)
  let t1 = epochTime()
  if v.isNaN or t1 - t0 > 0.002: return (NaN, t1)
  # mpv's own times run negated backward.
  ((if p.backward: -v else: v), (t0 + t1) / 2)

proc handleProp(p: Player, id: Prop, ev: ptr MpvEventProperty) =
  let d = ev.data
  template f: float = (if d == nil: 0.0 else: cast[ptr cdouble](d)[].float)
  template b: bool = (d != nil and cast[ptr cint](d)[] != 0)
  if p.keepTime and id in {pTimePos, pDuration}: return
  case id
  of pPause:
    p.paused = b
    if b: p.pausedAt = epochTime()
  of pTimePos:
    if p.holdTime and p.jumps == p.holdJumps or d == nil: return  # unavailable for a moment isn't 0
    if p.endPinned and p.jumps == p.eofJumps: return
    # With the video out, mpv's time is the sound's, behind it by the audio
    # output's latency. That's no step back, near the end of playing forward.
    let back = p.timePos - f
    if back > 0 and back < min(0.5, p.duration / 2) and p.jumps == p.timeJumps and
       not (p.paused or p.seeking or p.backward) and
       p.timePos >= p.duration - 3 * max(p.frameDur, 0.05) and epochTime() - p.timeAt < 0.6:
      return
    p.timeJumps = p.jumps
    let step = abs(f - p.timePos)
    if step > 0.001 and step < 0.1: p.frameDur = step
    p.timePos = f
    p.timeAt = epochTime()
    # On past it: mpv tells of the spot itself before seeking there.
    if p.sought >= 0 and not p.seeking and f > p.sought + 0.1 and f < p.sought + 15: p.sought = -1
  of pDuration: p.duration = max(f, p.fullDuration)
  of pEof:
    p.eofReached = b
    if p.eofReached: p.eofJumps = p.jumps
    if not p.eofReached: (p.eofHandled, p.endPinned) = (false, false)
    elif p.endHold: p.eofHandled = true
    # mpv pauses itself at the end, around when it tells of it.
    elif not p.paused or epochTime() - p.pausedAt < 0.2: p.endPaused = true
  of pVolume: p.volume = f
  of pMute: p.muted = b
  of pSpeed: p.speed = f
  of pSeeking: p.seeking = b
  of pAudioChannels:
    p.audioChannels = if d == nil: 0 else: cast[ptr int64](d)[].int
  of pIdle: discard
  of pCacheState:
    p.buffered.setLen 0
    p.cacheAhead = -1
    # A module or MIDI stream is rendered as it's read, an .aud one held in
    # memory: nothing downloaded.
    if d != nil and ev.format == fmtNode and not p.source.startsWith("mmpmod://") and
       not p.source.startsWith("mmpmidi://") and not p.source.startsWith("mmpaud://"):
      let j = cast[ptr MpvNode](d)[].toJson
      for r in j{"seekable-ranges"}.getElems:
        p.buffered.add (r{"start"}.getFloat, r{"end"}.getFloat)
      if j{"cache-duration"} != nil: p.cacheAhead = j{"cache-duration"}.getFloat
  of pPausedForCache: p.buffering = b
  of pTracks, pChapters, pVideoParams:
    let j = if d == nil or ev.format != fmtNode: newJNull()
            else: cast[ptr MpvNode](d)[].toJson
    case id
    of pTracks: p.parseTracks(j)
    of pChapters: p.parseChapters(j)
    else:
      if j.kind == JObject:
        inc p.videoConfigs
        p.videoW = j{"dw"}.getInt
        p.videoH = j{"dh"}.getInt
        let turned = j{"rotate"}.getInt mod 180 != 0
        p.pixelW = j{if turned: "h" else: "w"}.getInt
        p.pixelH = j{if turned: "w" else: "h"}.getInt
      else:
        p.videoW = 0
        p.videoH = 0
        p.pixelW = 0
        p.pixelH = 0

proc addSameNameAudio(p: Player) =
  ## A video's audio files of the same name (song.mkv + song.flac) join as
  ## external tracks, the first one selected. Audio-only files, cover art
  ## included, pick up nothing.
  if p.path.len == 0 or p.path.contains("://"): return
  var video = false
  for i in 0 ..< p.h.getInt("track-list/count"):
    let t = "track-list/" & $i & "/"
    if p.h.getStr(t & "type") == "video" and not p.h.getFlag(t & "albumart") and
       not p.h.getFlag(t & "external"):
      video = true
  if not video: return
  let (dir, name, _) = p.path.splitFile
  var found: seq[string]
  try:
    for kind, f in walkDir(dir):
      if kind notin {pcFile, pcLinkToFile} or f == p.path: continue
      let (_, n, ext) = f.splitFile
      if n == name and ext.toLowerAscii.strip(chars = {'.'}) in AudioExtensions:
        found.add f
  except OSError: return
  found.sort()
  for i, f in found:
    p.h.command("audio-add", f, if i == 0: "select" else: "auto", f.extractFilename)

proc namedAfter*(p: Player, file: string): bool =
  ## The picture at file is named after the file playing: mpv's exact
  ## cover-art-auto match (letter case and the extension aside).
  cmpIgnoreCase(file.splitFile.name.strip, p.path.splitFile.name.strip) == 0

var coverPatterns: seq[string]  ## Options' folder pictures, every player's

proc samePath(a, b: string): bool =
  a == b or (try: sameFile(a, b) except OSError: false)

proc coverPictures(p: Player): tuple[inside, folder: seq[int], own: int] =
  ## The audio file's pictures by track id: inside it, beside it from
  ## Options' folder pictures (addFolderPicture), and the one named after it
  ## (0 for none; mpv finds that one, a second one, song.png by song.jpg, is
  ## neither). None for a video. A quick cover isn't one of them.
  for i in 0 ..< p.h.getInt("track-list/count"):
    let t = "track-list/" & $i & "/"
    if p.h.getStr(t & "type") != "video": continue
    if p.h.getFlag(t & "external") and p.h.getStr(t & "title") == QuickCoverTitle: continue
    if not p.h.getFlag(t & "albumart"): return default(typeof(result))
    let id = p.h.getInt(t & "id")
    if not p.h.getFlag(t & "external"):
      result.inside.add id
      continue
    let f = p.h.getStr(t & "external-filename")
    let named = p.namedAfter(f)
    if named and result.own == 0: result.own = id
    if p.folderPicture.len > 0 and samePath(f, p.folderPicture): result.folder.insert(id, 0)
    elif not named: result.folder.add id

proc hasPictures(p: Player): bool =
  let c = p.coverPictures
  c.inside.len > 0 or c.folder.len > 0 or c.own != 0

proc coverTrack(p: Player): int =
  ## The track id of the audio file's cover to show, 0 for none (or a
  ## video): the picture named after it, with Show Front Cover (file); else
  ## of the pictures inside it the front cover (mpv takes the first, often
  ## the back or a booklet page), else the first one; else a folder picture.
  let c = p.coverPictures
  if p.fileCover and c.own != 0: return c.own
  if c.inside.len > 1 and not p.path.contains("://"):
    let types = pictureTypes(p.path)
    if types.len == c.inside.len and FrontCover in types:
      return c.inside[types.find(FrontCover)]
  if c.inside.len > 0: c.inside[0]
  elif c.folder.len > 0: c.folder[0]
  else: 0

proc isQuickCover*(t: Track): bool =
  t.kind == "video" and t.external and t.title == QuickCoverTitle

proc quickCoverShown(p: Player): bool =
  ## Read from mpv: the track list kept may still be the file before's.
  p.h.getFlag("current-tracks/video/external") and
    p.h.getStr("current-tracks/video/title") == QuickCoverTitle

proc pickCover(p: Player) =
  ## File-local: a vid set at runtime would hold for the files opened next.
  ## A picture left out is no cover: mpv would take it. A quick cover shown
  ## stays.
  if p.quickCoverShown: return
  let id = p.coverTrack
  if id != 0: p.h.setProp("file-local-options/vid", $id)
  elif p.hasPictures: p.h.setProp("file-local-options/vid", "no")

proc setNoVideo*(p: Player, on: bool) =
  ## Video Track > Always Disable, for the files opened next and the one
  ## open. Never mpv's own vid: a file-local vid would put that back at the
  ## end of the file, and a runtime one would hold for every file after.
  p.noVideo = on
  if not p.loaded or p.hasPictures: return
  p.h.setProp("file-local-options/vid", if on: "no" else: "auto")

proc showCover*(p: Player, on: bool) =
  ## Shows or hides an audio file's cover, now and for the files opened next.
  p.h.setProp("audio-display", if on: "embedded-first" else: "no")
  if not p.loaded: return
  if on:
    if p.h.getInt("vid") == 0: p.pickCover()
  elif p.coverTrack != 0 and not p.quickCoverShown: p.h.setProp("file-local-options/vid", "no")

proc quickCoverTrack*(p: Player, file: string): int =
  ## The id of the quick cover track showing file, 0 for none.
  for i in 0 ..< p.h.getInt("track-list/count"):
    let t = "track-list/" & $i & "/"
    if p.h.getStr(t & "type") == "video" and p.h.getStr(t & "title") == QuickCoverTitle and
       p.h.getStr(t & "external-filename") == file:
      return p.h.getInt(t & "id")

proc takeShot*(p: Player) =
  ## The frame shown, taken in the background: in `shot` once `shotDone`.
  (p.shotAsked, p.shotDone) = (true, false)
  p.shot = default(typeof(p.shot))
  p.h.screenshotRaw(ShotReply)

proc ownVid*(p: Player): string =
  ## The video track the file shows of its own, as vid: its video, else its
  ## cover (with Show Front Cover), else "no".
  for t in p.tracks:
    if t.kind == "video" and not t.albumArt: return $t.id
  let id = if p.h.getStr("audio-display") != "no": p.coverTrack else: 0
  if id != 0: $id else: "no"

proc addQuickCover*(p: Player, file: string): int =
  ## Adds the picture at file as the open file's cover and shows it (for
  ## that file only); its track id, 0 when mpv can't open it. Must run with
  ## the window's GL context current: a file opened without a picture has no
  ## render context, and mpv's video fails without one.
  if not p.loaded: return 0
  p.initRender()
  if p.h.command("video-add", file, "auto", QuickCoverTitle, "", "yes") < 0: return 0
  result = p.quickCoverTrack(file)
  if result != 0: p.h.setProp("file-local-options/vid", $result)

proc setFileCover*(p: Player, on: bool) =
  ## Show Front Cover (file), for the files opened next and the one open.
  p.fileCover = on
  if p.loaded and not p.hidden and p.h.getStr("audio-display") != "no": p.pickCover()

proc hasOwnCover*(p: Player): bool =
  ## Beside the audio file, a picture named after it (Show Front Cover (file)).
  p.tracks.anyIt(it.kind == "video" and it.albumArt and it.external and p.namedAfter(it.file))

proc setCoverPatterns*(patterns: openArray[string]) =
  ## Options' folder pictures, for every player: the lines tried in turn for
  ## an audio file without a cover in it (folderpics), the first finding a
  ## picture taking it. For the files opened next.
  coverPatterns = @patterns

proc addFolderPicture(p: Player) =
  ## In the on_preloaded hook: adds the picture Options' folder pictures find
  ## for the audio file opening as a cover track (one mpv found already,
  ## named after the file, is taken as it is).
  p.folderPicture = ""
  if coverPatterns.len == 0 or p.path.len == 0 or "://" in p.path: return
  let n = p.h.getInt("track-list/count")
  var have: seq[string]
  for i in 0 ..< n:
    let t = "track-list/" & $i & "/"
    if p.h.getStr(t & "type") != "video": continue
    if not p.h.getFlag(t & "albumart"): return  # a video
    if p.h.getFlag(t & "external"): have.add p.h.getStr(t & "external-filename")
  var tags: Table[string, string]
  let meta = p.h.getNode("metadata").overlay(readSide(p.path))  # and its .m2c's
  if meta.kind == JObject:
    for k, v in meta: tags[k] = v.getStr
  let f = findFolderPicture(coverPatterns, p.path, tags)
  if f.len == 0: return
  for h in have:
    if samePath(h, f):
      p.folderPicture = h
      return
  if p.h.command("video-add", f, "auto", "", "", "yes") >= 0: p.folderPicture = f

proc stopMeshRead(p: Player) =
  if p.meshRead == nil: return
  try: p.meshRead.terminate(); p.meshRead.close()
  except OSError: discard
  p.meshRead = nil
  discard tryRemoveFile(p.meshHead)

proc findSphere(p: Player) =
  ## How the file just loaded lies on the sphere. A mesh tells a link's 360°
  ## from its VR180, and only the stream's header holds it (mpv's demuxers
  ## skip it), so that comes apart: fetched as the link plays (pollMeshRead).
  p.stopMeshRead()
  if p.source.len > 0: p.sphere = p.savedSphere
  elif "://" notin p.path: p.sphere = detectSphere(p.path)
  else:
    let link = linkSphere(p.h.getNode("user-data/mpv/ytdl/json-subprocess-result/stdout").getStr)
    p.sphere = link.sphere
    if link.meshUrl.len == 0: return
    p.meshHls = link.meshHls
    p.meshHead = getTempDir() / "majestic-" & $getCurrentProcessId() & "-mesh"
    try:
      p.meshRead = startProcess("curl", args = ["-fsL", "--max-time", "15", "-r", "0-262143",
        "-o", p.meshHead, link.meshUrl], options = {poUsePath, poStdErrToStdOut, poDaemon})
    except OSError: discard

proc pollMeshRead(p: Player): bool =
  ## True when a link's mesh just came and changed what's on the sphere.
  if p.meshRead == nil or p.meshRead.running: return
  p.meshRead.close()
  p.meshRead = nil
  let s = detectSphere(p.meshHead)
  discard tryRemoveFile(p.meshHead)
  p.sphere = if p.meshHls: hlsSphere(s) else: s
  p.sphere.is360

proc settled*(p: Player): bool

proc setGapless(p: Player, on: bool) =
  if on == p.gapless: return
  p.gapless = on
  # weak: a change of sample format still reopens the output (a mono file
  # isn't played as stereo, or the other way round).
  p.h.setProp("gapless-audio", if on: "weak" else: "no")

proc resetNext(p: Player, gapless = false) =
  ## Nothing queued any more: mpv's playlist was cleared (loadfile replace,
  ## stop) or it went on to the file, with gapless audio still on then.
  (p.nextPath, p.nextSource, p.nextKey) = ("", "", "")
  if not gapless: p.setGapless(false)

proc queueNext*(p: Player, path: string, start = 0.0, opts = "", source = "") =
  ## Gapless playback: has mpv go on to path by itself at the end of this
  ## file, its audio straight after this one's; "" for nothing (the app opens
  ## what comes next). Asked again with the same, nothing happens.
  var o = opts.joinOpts(p.rgs.rgOpts(path))
  if start > 0:
    o = "start=" & formatFloat(start, ffDecimal, 3) & (if o.len > 0: "," & o else: "")
  let file = if source.len > 0: source else: path
  let key = if path.len == 0: "" else: file & "\n" & o
  if key == p.nextKey and (key.len > 0 or not p.gapless): return
  # Not while mpv changes files: until the new one plays, its sound may
  # still be on the way, or this file's.
  if p.opening or not p.settled: return
  if p.nextKey.len > 0: p.h.commandAsync("playlist-clear")  # all but the file playing
  if path.len == 0:
    p.resetNext()
    return
  if o.len > 0: p.h.commandAsync("loadfile", file, "append", "-1", o)
  else: p.h.commandAsync("loadfile", file, "append")
  p.setGapless(true)
  (p.nextPath, p.nextSource, p.nextKey, p.nextStart) = (path, source, key, start)

proc wentOn(p: Player) =
  ## mpv ended the file and opens the queued one: as load would have it.
  p.endedPath = p.path
  p.advanced = true
  p.path = p.nextPath
  p.source = p.nextSource
  p.loadRestarts = p.restarts
  p.stopped = false
  p.eofReached = false
  p.eofHandled = false
  p.holdTime = false
  p.endPinned = false
  p.timePos = p.nextStart
  p.duration = 0
  p.loadError = ""
  p.opening = true
  p.endPaused = false
  p.endHold = false
  p.sought = -1
  p.landing = -1
  p.buffered.setLen 0
  p.cacheAhead = -1
  p.buffering = false
  p.resetNext(gapless = true)

proc pollEvents*(p: Player): bool =
  ## Drains the mpv event queue. Returns true if anything changed.
  if p.pollMeshRead: result = true
  if p.linkHold != 0 and epochTime() >= p.linkHoldUntil:
    p.releaseLink()
    result = true
  while true:
    let ev = mpv_wait_event(p.h, 0)
    if ev.eventId == evNone: break
    result = true
    case ev.eventId
    of evPropertyChange:
      let id = ev.replyUserdata.int
      if id in Prop.low.int .. Prop.high.int:
        p.handleProp(Prop(id), cast[ptr MpvEventProperty](ev.data))
      elif id in MirrorBase ..< MirrorBase + MirroredProps.len:
        let e = cast[ptr MpvEventProperty](ev.data)
        let name = MirroredProps[id - MirrorBase]
        p.props[name] =
          if e.data == nil or e.format != fmtString: "" else: $cast[ptr cstring](e.data)[]
      elif id in InfoBase ..< InfoBase + InfoProps.len:
        let e = cast[ptr MpvEventProperty](ev.data)
        p.info[InfoProps[id - InfoBase]] =
          if e.data == nil or e.format != fmtString: "" else: $cast[ptr cstring](e.data)[]
    of evFileLoaded:
      # Read here rather than in load: the previous file may still show a
      # frame or two until mpv switches over.
      if not p.hidden:
        p.findSphere()
        p.addSameNameAudio()
      p.loaded = true
      p.opening = false
      p.justLoaded = true
      p.loadedRestarts = p.restarts
      if p.keepTime and p.openSeek >= 0:
        inc p.jumps
        p.h.commandAsync("seek", formatFloat(p.openSeek, ffDecimal, 3), "absolute", "exact")
      p.keepTime = false
      p.loadError = ""
      p.eofHandled = false
    of evEndFile:
      let e = cast[ptr MpvEventEndFile](ev.data)
      if (e.reason == efEof or e.reason == efError) and p.nextKey.len > 0 and not p.hidden:
        # It goes on to the queued file, even after a read error in this one.
        p.wentOn()
      elif e.reason == efError:
        p.loadError = $mpv_error_string(e.error)
        p.loaded = false
        p.opening = false
    of evPlaybackRestart: inc p.restarts
    of evHook:
      let e = cast[ptr MpvEventHook](ev.data)
      if ev.replyUserdata == CoverHook:
        # Tracks found, none picked yet: the cover's picked before mpv
        # shows another (and the window fits that one). A saved quick cover
        # over any.
        p.addFolderPicture()
        var quick = 0
        if not p.hidden and p.quickCoverFor != nil:
          let f = p.quickCoverFor(p.path)
          if f.len > 0 and p.h.command("video-add", f, "auto", QuickCoverTitle, "", "yes") >= 0:
            quick = p.quickCoverTrack(f)
        if quick != 0: p.h.setProp("file-local-options/vid", $quick)
        elif not p.hidden and p.h.getStr("audio-display") != "no": p.pickCover()
        if quick == 0 and p.noVideo and not p.hasPictures:
          p.h.setProp("file-local-options/vid", "no")
        if p.wantsRender():
          try: p.initRender()
          except MpvError as err:
            stderr.writeLine "video disabled: ", err.msg
            p.gpuOom = true  # it's the video memory that runs out here
        discard mpv_hook_continue(p.h, e.id)
        continue
      p.releaseLink()
      let at = p.linkAvailableAt()
      if at > epochTime():
        (p.linkHold, p.linkHoldUntil) = (e.id, min(at, epochTime() + LinkWaitMax))
      else: discard mpv_hook_continue(p.h, e.id)
    of evCommandReply:
      if ev.replyUserdata == DumpReply + p.dumpId:
        p.dumping = false
        p.dumpFailed = ev.error < 0
      elif ev.replyUserdata == ShotReply and p.shotAsked:
        p.shot = if ev.error >= 0: rawShot(cast[ptr MpvNode](ev.data)[]) else: default(typeof(p.shot))
        (p.shotAsked, p.shotDone) = (false, true)
      elif ev.replyUserdata == ExpandReply and ev.error >= 0:
        let n = cast[ptr MpvNode](ev.data)
        if n.format == fmtString: p.expanded.add $n.u.str
    of evLogMessage:
      type LogMsg = object
        prefix, level, text: cstring
      let m = cast[ptr LogMsg](ev.data)
      if $m.prefix == "ytdl_hook":
        for line in ($m.text).splitLines:
          if line.startsWith("ERROR:"): p.hookError = line.strip
      elif p.streamError.len == 0 and $m.level == "error" and
           ($m.prefix in ["curl", "timeline"] or "HTTP error" in $m.text):
        p.streamError = ($m.text).strip
      if $m.level == "error" and outOfMemory($m.text): p.gpuOom = true
      if logAll: stderr.write "[mpv/", $m.prefix, "] ", $m.text
    else: discard

proc setDemuxing*(p: Player, mode: DemuxMode) =
  ## mpv's demuxer options for the next file opened (DemuxMode). Threadless
  ## also goes without the cache: mpv turns it on by itself for a file on a
  ## network or FUSE disk (an NTFS drive), and turning around to backward at
  ## the end of a cached file spins mpv's core forever, the player frozen
  ## with it. How much it decodes at a time backward goes by the file's
  ## tracks, once known (backBatches).
  p.demux = mode
  p.h.setProp("demuxer-thread", if mode == dmAhead: "yes" else: "no")
  p.h.setProp("cache", if mode == dmAhead: "auto" else: "no")

proc isAnimatedPng(path: string): bool =
  ## A PNG on disk with an animation (acTL before its picture data): APNG.
  if path.contains("://") or path.splitFile.ext.toLowerAscii notin [".png", ".apng"]: return
  var f: File
  if not f.open(path): return
  defer: f.close()
  var head: array[8, char]
  if f.readBuffer(head[0].addr, 8) != 8 or head != ['\x89', 'P', 'N', 'G', '\r', '\n', '\x1A', '\n']:
    return
  for _ in 0 ..< 64:  # chunks before the picture: a few, else not worth reading
    var c: array[8, char]
    if f.readBuffer(c[0].addr, 8) != 8: return
    let n = c[0].ord shl 24 or c[1].ord shl 16 or c[2].ord shl 8 or c[3].ord
    let kind = c[4 .. 7].join("")
    if kind == "acTL": return true
    if kind in ["IDAT", "IEND"] or n < 0: return
    f.setFilePos(n.int64 + 4, fspCur)  # its data and CRC

proc decoderOpts(path: string): string =
  ## Per-file options a file needs to play: FFmpeg's APNG decoder, run on
  ## several threads, decodes nothing after a seek (each loop of Repeat is
  ## one), so mpv would jump back over and over on the last frame.
  if path.isAnimatedPng: "vd-lavc-threads=1" else: ""

proc withDecoderOpts*(opts, path: string): string =
  ## opts (mpv's per-file options, "name=value,...") and what path needs
  ## (decoderOpts), for every player opening it: standbys and previews too.
  let own = decoderOpts(path)
  if own.len == 0: opts elif opts.len == 0: own else: opts & "," & own

proc load*(p: Player, path: string, start = 0.0, demux = dmAhead, opts = "",
           source = "", partStart = 0.0, partEnd = 0.0, fullDuration = 0.0,
           sphere = SphereInfo()) =
  ## Opens path (or `source` in its place), starting at `start` seconds when
  ## given, with mpv's per-file options `opts` ("name=value,..."). A link's
  ## saved part (source) holds partStart to partEnd of the link's fullDuration
  ## and lies on `sphere`.
  p.stopMeshRead()
  let opts = withDecoderOpts(opts, if source.len > 0: source else: path).joinOpts(p.rgs.rgOpts(path))
  p.savedSphere = sphere
  p.setDemuxing(demux)
  p.path = path
  p.source = source
  p.loadRestarts = p.restarts
  p.partStart = partStart
  p.partEnd = partEnd
  p.fullDuration = fullDuration
  p.beyond = -1
  p.stopped = false
  p.eofReached = false
  p.eofHandled = false
  p.holdTime = false
  p.timePos = start
  p.duration = fullDuration
  p.loadError = ""
  p.hookError = ""
  p.streamError = ""
  p.opening = true
  p.keepTime = false
  p.openSeek = -1
  p.endPaused = false
  p.endHold = false
  p.sought = -1
  p.landing = -1
  p.buffered.setLen 0
  p.cacheAhead = -1
  p.buffering = false
  p.setBackward(false)
  p.clearTurnFades()
  p.openOpts = opts
  p.releaseLink()
  p.resetNext()  # replace clears mpv's playlist
  var o = opts
  if start > 0:
    o = "start=" & formatFloat(start, ffDecimal, 3) & (if o.len > 0: "," & o else: "")
  let file = if source.len > 0: source else: path
  if o.len > 0: p.h.commandAsync("loadfile", file, "replace", "-1", o)
  else: p.h.commandAsync("loadfile", file, "replace")
  p.h.setProp("pause", false)

proc hookFormat*(p: Player): string =
  ## The format ids yt-dlp picked for the link open ("401+251"), as mpv's
  ## yt-dlp hook kept its answer; "" when it opened none.
  let r = p.h.getNode("user-data/mpv/ytdl/json-subprocess-result")
  if r.kind != JObject: return
  try: parseJson(r{"stdout"}.getStr){"format_id"}.getStr
  except CatchableError: ""

proc reopen*(p: Player, demux: DemuxMode) =
  ## Opens the file again where it is, paused or playing as it was, for
  ## options mpv reads only on opening one. Its added tracks are gone then.
  p.setDemuxing(demux)
  p.clearTurnFades()
  p.releaseLink()
  p.resetNext()
  p.holdTime = false
  p.eofReached = false
  p.eofHandled = false
  inc p.jumps
  let file = if p.source.len > 0: p.source else: p.path
  p.h.commandAsync("loadfile", file, "replace", "-1",
    withDecoderOpts("start=" & formatFloat(p.timePos, ffDecimal, 6), file).joinOpts(p.rgs.rgOpts(p.path)))

proc externalFiles*(p: Player): seq[string] =
  ## The added tracks' files as mpv has them now (p.tracks may lag behind).
  for i in 0 ..< p.h.getInt("track-list/count"):
    let t = "track-list/" & $i & "/"
    if p.h.getFlag(t & "external"): result.add p.h.getStr(t & "external-filename")

proc close*(p: Player) =
  p.stopMeshRead()
  p.clearTurnFades()
  p.releaseLink()
  p.resetNext()
  p.h.commandAsync("stop")
  p.path = ""
  p.source = ""
  p.partStart = 0
  p.partEnd = 0
  p.fullDuration = 0
  p.beyond = -1
  p.loaded = false
  p.opening = false
  p.stopped = false
  p.buffered.setLen 0
  p.cacheAhead = -1
  p.buffering = false
  p.sphere = SphereInfo()
  p.tracks.setLen 0
  p.chapters.setLen 0
  p.videoW = 0
  p.videoH = 0
  p.pixelW = 0
  p.pixelH = 0
  p.timePos = 0
  p.duration = 0

proc settled*(p: Player): bool =
  ## Playing from where it was opened at (its time is to be trusted).
  p.loaded and p.restarts > p.loadRestarts

proc hasVideo*(p: Player): bool =
  p.loaded and p.videoW > 0 and p.videoH > 0

proc videoTrackOn*(p: Player): bool =
  ## A video track (cover art included) is selected, shown or not yet.
  p.tracks.anyIt(it.kind == "video" and it.selected)

proc switching*(p: Player): bool =
  ## Opening a file, or opened but not yet playing (or paused) from its
  ## start: the frame doesn't know yet whether it has a picture.
  p.opening or not p.loaded or p.restarts <= p.loadedRestarts

proc hasRealVideo*(p: Player): bool =
  ## A selected video track that is not just cover art.
  if not p.hasVideo: return false
  for t in p.tracks:
    if t.kind == "video" and t.selected and not t.albumArt: return true

proc isSpherical*(p: Player): bool =
  ## Shown as a 360° view: equirectangular metadata on a real video track.
  p.sphere.is360 and p.hasRealVideo

proc playing*(p: Player): bool = p.loaded and not p.paused and not p.stopped

proc togglePause*(p: Player) =
  if not p.loaded: return
  if p.stopped:
    p.stopped = false
    p.h.setProp("pause", false)
  elif p.eofReached:
    p.clearTurnFades()
    inc p.jumps
    p.h.commandAsync("seek", "0", "absolute")
    p.h.setProp("pause", false)
  else:
    p.h.setProp("pause", not p.paused)

proc play*(p: Player) =
  if p.loaded:
    p.stopped = false
    p.endHold = false
    if p.eofReached:
      p.clearTurnFades()
      inc p.jumps
      p.h.commandAsync("seek", "0", "absolute")
    p.h.setProp("pause", false)

proc pause*(p: Player) =
  if p.loaded: p.h.setProp("pause", true)

proc stop*(p: Player) =
  if not p.loaded: return
  if p.partEnd > 0 and p.partStart > 0.05:
    # 0 is before a link's saved part: the app goes online, stopped.
    p.beyond = 0
    p.h.setProp("pause", true)
    p.stopped = true
    return
  inc p.jumps
  p.setBackward(false)
  p.clearTurnFades()
  p.h.setProp("pause", true)
  p.h.commandAsync("seek", "0", "absolute", "exact")
  p.stopped = true

proc pinEnd*(p: Player, t: float) =
  ## The end was reached on the frame at time t: that's the time from here on,
  ## not the sound's. Going anywhere else ends it.
  if p.jumps != p.eofJumps: return
  p.endPinned = true
  p.timePos = t

proc keepAtEnd*(p: Player) =
  ## The end reached next stays paused there; nothing follows it.
  p.endHold = true
  p.endPaused = false
  if p.eofReached: p.eofHandled = true

proc holdEnd*(p: Player) =
  ## keepAtEnd, going forward.
  p.setBackward(false)
  p.keepAtEnd()

proc pastPart(p: Player, t: float): bool =
  ## A seek to t leaves the saved part: noted for the app to go online.
  result = p.partEnd > 0 and (t > p.partEnd - 0.5 or t < p.partStart - 0.05)
  if result: p.beyond = clamp(t, 0, max(p.duration - 1, 0))

proc noteSeek(p: Player, t: float) =
  ## A seek to t: noted (sought), unless it's to the end anyway. Back from the
  ## end mpv paused itself at, playing goes on, except at the very start: the
  ## file over and back at its beginning waits there.
  p.sought = if t < p.duration - 5: max(t, 0) else: -1
  if p.endPaused and p.eofReached and t > 0 and t < p.duration - 0.5:
    p.h.setProp("pause", false)
    p.endResumed = true
  if t < p.duration - 0.5: (p.endPaused, p.endHold) = (false, false)

proc seek*(p: Player, t: float, exact = true) =
  if not p.loaded or p.pastPart(t): return
  p.noteSeek(t)
  if p.opening and p.keepTime:  # mpv has no file to seek in yet
    p.openSeek = max(t, 0)
    p.timePos = p.openSeek
    return
  p.clearTurnFades()
  inc p.jumps
  p.h.commandAsync("seek", formatFloat(max(t, 0), ffDecimal, 3), "absolute",
    if exact: "exact" else: "keyframes")

proc turnAt*(p: Player, back: bool, at: float, fadeIn = NaN, d = 0.02, soft = false) =
  ## Turns around (setBackward) to play on from `at`, sought exactly, its
  ## sound faded in from there (fadeIn and d as setTurnFades) or not. In
  ## one command list: mpv makes its own seek for a turn (to its time, ~60 ms
  ## behind what's heard) the moment the direction changes, before taking a
  ## seek asked for after it; it then seeks again, a few tenths of a second
  ## more with a picture, and now and then starting a packet further on (58
  ## ms of FLAC). Waits for mpv to take it (no longer than the other calls
  ## turns make: audio-pts). soft: hardware decoding goes off in the same
  ## list (a video going backward): a hardware decoder can't hold a keyframe's
  ## span of frames ("No decoder surfaces left"), and failing over to software
  ## on its own stops the picture for a few tenths of a second.
  if not p.loaded or p.pastPart(at): return
  if back: p.setBackStep()
  p.backward = back
  p.setTurnFades(fadeIn = fadeIn, d = d)  # in before the seek makes the filters anew
  p.noteSeek(at)
  inc p.jumps
  p.h.commandStr((if soft: "set hwdec no; " else: "") &
    "set play-direction " & (if back: "backward" else: "forward") &
    "; seek " & formatFloat(max(at, 0), ffDecimal, 6) & " absolute exact")

proc landOn*(p: Player, t: float) =
  ## An exact seek to t was just asked for: its time is the one to show. mpv's
  ## stays the old one for a while, or that of a keyframe sought before it.
  if not p.loaded: return
  (p.landing, p.landingJumps, p.landingRestarts) = (t, p.jumps, p.restarts)
  p.landingAt = epochTime()

proc landingOn*(p: Player): float =
  ## Where the exact seek noted by landOn is landing, -1 once it has, or
  ## anything else took the player elsewhere, or mpv isn't going there.
  if p.landing < 0: return -1
  let there = p.restarts > p.landingRestarts and p.timePos >= p.landing - 0.1 and
    p.timePos <= p.landing + 1
  if p.jumps != p.landingJumps or
     not p.seeking and (there or epochTime() - p.landingAt > LandingWait):
    p.landing = -1
  p.landing

proc shownPos*(p: Player): float =
  ## The time to show: timePos, or where a seek is landing.
  let t = p.landingOn
  if t >= 0: t else: p.timePos

proc seekRelative*(p: Player, d: float) =
  if p.pastPart(p.timePos + d): return
  p.noteSeek(p.timePos + d)
  p.clearTurnFades()
  inc p.jumps
  p.h.commandAsync("seek", $d, "relative")

proc seekPercent*(p: Player, percent: float) =
  if p.pastPart(p.duration * percent / 100): return
  p.noteSeek(p.duration * percent / 100)
  p.clearTurnFades()
  inc p.jumps
  p.h.commandAsync("seek", $percent, "absolute-percent")

proc dumpFrom*(p: Player, start: float, file: string) =
  ## Writes the stream from `start` (a time in mpv's cache) to file, then
  ## all it reads after, until stopDump, an error or another file.
  inc p.dumpId
  p.dumping = true
  p.dumpFailed = false
  let args = ["dump-cache", formatFloat(start, ffDecimal, 6), "no", file]
  var cargs: array[5, cstring]
  for i, a in args: cargs[i] = a.cstring
  discard mpv_command_async(p.h, DumpReply + p.dumpId, cargs[0].addr)

proc stopDump*(p: Player) =
  if not p.dumping: return
  p.dumping = false
  inc p.dumpId  # its reply, still to come, is no longer ours
  p.h.commandAsync("dump-cache", "0", "0", "")

proc frameStep*(p: Player, forward: bool) =
  p.clearTurnFades()
  inc p.jumps
  p.h.commandAsync(if forward: "frame-step" else: "frame-back-step")

proc osd*(p: Player, msg: string, secs = 1.5) =
  p.h.commandAsync("show-text", msg, $int(secs * 1000))

proc expandText*(p: Player, text: string) =
  ## Expands mpv ${property} references as the OSD would show them; the
  ## result lands in `expanded` once mpv gets to it (after earlier requests).
  var args = ["expand-text".cstring, text.cstring, nil]
  discard mpv_command_async(p.h, ExpandReply, args[0].addr)

proc setVolume*(p: Player, v: float) =
  p.volume = clamp(v, 0, 200)
  p.h.setProp("volume", p.volume)

proc refreshTracks*(p: Player) =
  ## track-list as it is now, not as last observed (that of the file before,
  ## just after a load).
  p.parseTracks(p.h.getNode("track-list"))

proc selectedTrack*(p: Player, kind: string): int =
  for t in p.tracks:
    if t.kind == kind and t.selected: return t.id
  0

proc loadedFile*(t: Track): bool =
  ## A track from a file of its own, not the link's (the hook adds it by URL).
  t.external and not t.file.contains("://")

proc urlLang(url: string): string =
  ## A caption link's lang= parameter (YouTube's timedtext), else "".
  let q = url.find('?')
  if q < 0: return
  for kv in url[q + 1 .. ^1].split('&'):
    if kv.startsWith("lang="): return kv[5 .. ^1]

proc trackLabel*(t: Track): string =
  ## As mpv's OSD shows a track: #1: Title (eng opus 2ch 48000 Hz) [default].
  ## A track added without a title gets its file's name from mpv: a link's
  ## (a whole query string) is dropped, and the language read from it.
  var (title, lang) = (t.title, t.lang)
  let link = t.external and t.file.contains("://")
  if link and title == t.file.rsplit('/', 1)[^1]: title = ""
  if link and lang.len == 0: lang = urlLang(t.file)
  result = "#" & $t.id
  if title.len > 0: result.add ": " & title
  var info: seq[string]
  if lang.len > 0: info.add lang
  if t.codec.len > 0 and t.codec != "null": info.add t.codec
  if t.width > 0 and t.height > 0: info.add $t.width & "x" & $t.height
  if t.fps > 0:
    var fps = formatFloat(t.fps, ffDecimal, 3)
    fps.trimZeros()
    info.add fps & " fps"
  if t.channels > 0: info.add $t.channels & "ch"
  if t.sampleRate > 0: info.add $t.sampleRate & " Hz"
  if info.len > 0: result.add " (" & info.join(" ") & ")"
  if t.default: result.add " [default]"
  if t.forced: result.add " [forced]"
  if t.external: result.add " [external]"

# --- detached OSD -----------------------------------------------------------

type
  OsdLayer* = ref object
    ## A video-less mpv that only draws OSD, onto a transparent target over
    ## the whole video frame: mpv's own is laid out on the picture, so it
    ## would shrink into a letterboxed video and move with pan and zoom.
    h*: MpvHandle
    render*: MpvRenderContext
    target*: VideoTarget

proc newOsdLayer*(): OsdLayer =
  let h = mpv_create()
  if h == nil: raise newException(MpvError, "mpv_create failed")
  result = OsdLayer(h: h)
  h.setOpt("config", "no")
  h.setOpt("vo", "libmpv")
  h.setOpt("idle", "yes")
  h.setOpt("gpu-hwdec-interop", "no")  # nothing to decode
  h.setOpt("audio", "no")
  h.setOpt("terminal", "no")
  h.setOpt("input-default-bindings", "no")
  h.setOpt("input-vo-keyboard", "no")
  h.setOpt("osc", "no")
  h.setOpt("load-scripts", "no")
  h.setOpt("background", "color")
  h.setOpt("background-color", "#00000000")
  h.setOpt("osd-level", "0")
  check mpv_initialize(h), "osd mpv_initialize"

proc initRender*(o: OsdLayer) =
  o.render = createRenderContext(o.h, blockForTargetTime = false)
  mpv_render_context_set_update_callback(o.render, onOsdUpdate, nil)
  # Only now: a VO (which keeps the OSD while idle) opened before the render
  # context exists fails for good.
  o.h.setProp("force-window", "yes")

# --- thumbnail preview ------------------------------------------------------

proc newPreview*(): Preview =
  result = Preview(wanted: -1, shown: -1)
  let h = mpv_create()
  if h == nil: return nil
  result.h = h
  h.setOpt("config", "no")
  h.setOpt("vo", "libmpv")
  h.setOpt("hwdec", hwdecMode())
  if cpuWanted: h.setOpt("profile", "fast")  # cheap scaling for the software renderer
  h.setHdrOpts()                       # the thumbnails look like the video
  h.setOpt("vd-lavc-dr", "no")         # see newPlayer
  h.setOpt("terminal", "no")
  h.setOpt("audio", "no")
  h.setOpt("sid", "no")
  h.setOpt("pause", "yes")
  h.setOpt("keep-open", "always")
  h.setOpt("idle", "yes")
  h.setOpt("hr-seek", "no")
  h.setOpt("osd-level", "0")
  h.setOpt("keepaspect", "no")
  h.setOpt("demuxer-readahead-secs", "0")
  h.setOpt("cache", "no")
  h.setOpt("load-scripts", "no")
  check mpv_initialize(h), "preview mpv_initialize"

proc initRender(pv: Preview): bool =
  ## Whether it has a render context: made on the first request, GL context
  ## current, as a preview may never be asked for (see Player.initRender).
  pv.usedAt = epochTime()
  if pv.render != nil: return true
  try:
    pv.render = createRenderContext(pv.h, blockForTargetTime = false)
  except MpvError as e:
    stderr.writeLine "seek preview unavailable: ", e.msg
    return false
  mpv_render_context_set_update_callback(pv.render, onPreviewUpdate, nil)
  true

proc request*(pv: Preview, path: string, t: float) =
  ## Ask for a thumbnail at time t. Seeks are coalesced: only the latest
  ## request is issued once the previous one completes.
  if pv == nil or not pv.initRender(): return
  if path != pv.path:
    pv.path = path
    pv.hasFrame = false
    pv.busy = true
    pv.opening = true
    pv.shown = -1
    pv.h.commandAsync("loadfile", path, "replace", "-1",
      withDecoderOpts("start=" & formatFloat(t, ffDecimal, 2), path))
  pv.wantedImage = ""
  pv.wanted = t
  if not pv.busy and abs(pv.wanted - pv.shown) > 0.05:
    pv.busy = true
    pv.shown = pv.wanted
    pv.h.commandAsync("seek", formatFloat(t, ffDecimal, 2), "absolute", "keyframes")

proc showImage*(pv: Preview, path, crop: string) =
  ## Ask for a part of an image (crop: a video-crop value), coalesced like
  ## request. The last one stays up until it's in.
  if pv == nil or not pv.initRender(): return
  (pv.wantedImage, pv.wantedCrop) = (path, crop)
  if pv.busy: return
  if path != pv.path:
    if path.parentDir != pv.path.parentDir: pv.hasFrame = false  # another video's
    pv.path = path
    pv.crop = crop
    pv.busy = true
    pv.opening = true
    pv.h.commandAsync("loadfile", path, "replace", "-1", "video-crop=" & crop)
  elif crop != pv.crop:
    pv.crop = crop
    pv.h.setProp("video-crop", crop)

proc pollEvents*(pv: Preview) =
  if pv == nil: return
  while true:
    let ev = mpv_wait_event(pv.h, 0)
    if ev.eventId == evNone: break
    case ev.eventId
    of evStartFile:
      pv.opening = false
    of evPlaybackRestart:
      pv.busy = false
      pv.hasFrame = true
      if pv.wantedImage.len > 0:
        pv.showImage(pv.wantedImage, pv.wantedCrop)
      else:
        if pv.shown < 0: pv.shown = pv.wanted
        if abs(pv.wanted - pv.shown) > 0.05:
          let t = pv.wanted
          pv.request(pv.path, t)
    of evEndFile:
      # The file before the one opening doesn't count.
      if not pv.opening: pv.busy = false
    else: discard

proc forget*(pv: Preview) =
  ## Drop the loaded file (e.g. when the main file is closed).
  if pv == nil or pv.path.len == 0: return
  pv.h.commandAsync("stop")
  pv.path = ""
  pv.wantedImage = ""
  pv.hasFrame = false
  pv.busy = false
  pv.opening = false

proc releaseIdle*(pv: Preview) =
  ## Frees its render context once it's gone unused a while.
  if pv == nil or pv.render == nil or epochTime() - pv.usedAt < ContextIdle: return
  pv.forget()
  mpv_render_context_free(pv.render)
  pv.render = nil
  pv.target.free()

# --- folder navigation -----------------------------------------------------

proc naturalCmp*(a, b: string): int =
  ## Case-insensitive compare that orders embedded numbers numerically.
  var i, j = 0
  while i < a.len and j < b.len:
    if a[i].isDigit and b[j].isDigit:
      var si = i
      var sj = j
      while i < a.len and a[i].isDigit: inc i
      while j < b.len and b[j].isDigit: inc j
      let na = a[si ..< i].strip(trailing = false, chars = {'0'})
      let nb = b[sj ..< j].strip(trailing = false, chars = {'0'})
      if na.len != nb.len: return cmp(na.len, nb.len)
      let c = cmp(na, nb)
      if c != 0: return c
    else:
      let c = cmp(a[i].toLowerAscii, b[j].toLowerAscii)
      if c != 0: return c
      inc i
      inc j
  cmp(a.len - i, b.len - j)

proc mediaFilesIn*(dir: string, isMedia: proc (p: string): bool): seq[string] =
  for kind, f in walkDir(dir):
    if kind in {pcFile, pcLinkToFile} and isMedia(f):
      result.add f
  result.sort(proc (a, b: string): int = naturalCmp(a.extractFilename, b.extractFilename))

# --- media probing -------------------------------------------------------------

type
  MediaInfo* = object
    duration*: float          ## seconds, 0 when unknown
    width*, height*: int      ## first real video track, 0 for audio only
    shownW*, shownH*: int     ## its picture as shown: turned by its rotation,
                              ## stretched by its pixel aspect
    audioBitrate*: float      ## bits per second, 0 when unknown
    title*, artist*, album*: string  ## from the tags, "" when absent
    track*, disc*, year*: int ## from the tags, 0 when absent
    rg*: ReplayGain           ## the first audio track's

  Prober* = ref object
    ## Headless, paused mpv with null outputs, for the playlist's columns and
    ## sorting. Probes one file at a time, either blocking or in the background.
    h: MpvHandle
    pending*: string          ## path being probed, "" when idle
    url: string               ## what mpv opened for it (a cue track's segment)
    info*: MediaInfo          ## result of the last finished probe
    deadline: float
    loaded: bool              ## a file is open (released by finish)

proc newProber*(): Prober =
  let h = mpv_create()
  if h == nil: return nil
  for (k, v) in [("config", "no"), ("terminal", "no"), ("vo", "null"),
                 ("ao", "null"), ("sid", "no"), ("hwdec", "no"),
                 ("pause", "yes"), ("idle", "yes"), ("keep-open", "yes"),
                 ("load-scripts", "no"), ("cache", "no"), ("sub-auto", "no"),
                 ("audio-file-auto", "no"), ("cover-art-auto", "no")]:
    try: h.setOpt(k, v)
    except MpvError: discard
  if mpv_initialize(h) < 0:
    mpv_terminate_destroy(h)
    return nil
  Prober(h: h)

proc leadingInt(s: string): int =
  ## "3/12" -> 3; 0 when s doesn't start with a number.
  for c in s:
    if c notin Digits or result > 99_999: break
    result = result * 10 + ord(c) - ord('0')

proc yearOf(date: string): int =
  ## The first four digits in a row: "2019-05-01", "05/01/2019"; 0 without any.
  for i in 0 .. date.len - 4:
    if date[i .. i + 3].allCharsInSet(Digits): return date[i .. i + 3].parseInt

proc readTags(info: var MediaInfo, tags: JsonNode) =
  ## mpv keeps each format's own key names: "title" here, "TITLE" there,
  ## and Matroska's track number is PART_NUMBER.
  if tags.kind != JObject: return
  var albumArtist = ""
  for k, v in tags:
    let s = v.getStr.strip
    case k.toLowerAscii
    of "title": info.title = s
    of "artist": info.artist = s
    of "album_artist", "albumartist": albumArtist = s
    of "album": info.album = s
    of "track", "tracknumber", "part_number": info.track = s.leadingInt
    of "disc", "discnumber", "disk": info.disc = s.leadingInt
    of "date", "year":
      if info.year == 0: info.year = s.yearOf
    else: discard
  if info.artist.len == 0: info.artist = albumArtist

proc retag*(info: var MediaInfo, tags: seq[(string, string)]) =
  ## The tag fields of info as tags (field, first value) now have them, as
  ## written to the file; the rest (duration, sizes...) stays.
  (info.title, info.artist, info.album, info.track, info.disc, info.year) = ("", "", "", 0, 0, 0)
  var j = newJObject()
  for (k, v) in tags: j[k] = %v
  info.readTags(j)
  proc gain(tags: seq[(string, string)], k: string): float =
    for (tk, v) in tags:
      if tk.toUpperAscii == k:
        try: return parseFloat(v.strip.split(' ')[0])
        except ValueError: discard
    NaN
  let (tg, tp, ag, ap) = (tags.gain("REPLAYGAIN_TRACK_GAIN"), tags.gain("REPLAYGAIN_TRACK_PEAK"),
                          tags.gain("REPLAYGAIN_ALBUM_GAIN"), tags.gain("REPLAYGAIN_ALBUM_PEAK"))
  info.rg = ReplayGain()
  if not tg.isNaN:
    info.rg = ReplayGain(known: true, trackGain: tg, trackPeak: (if tp.isNaN: 0 else: tp))
    (info.rg.albumGain, info.rg.albumPeak) =
      if ag.isNaN: (tg, info.rg.trackPeak) else: (ag, if ap.isNaN: 0.0 else: ap)

proc audioBitrate(h: MpvHandle, tracks: JsonNode, video: bool): float =
  ## The first audio track's, as the file states it; else, with nothing but
  ## audio in there, the average over the whole file.
  for t in tracks:
    if t{"type"}.getStr != "audio": continue
    # A tracker module's "bit rate" is libopenmpt's rendered PCM (3 Mb/s):
    # the file's own average says more.
    if h.getStr("file-format") != "libopenmpt":
      result = t{"demux-bitrate"}.getFloat
    if result <= 0 and t.hasKey("metadata"):
      for k, v in t["metadata"].pairs:
        if k.toLowerAscii == "bps":
          try: result = v.getStr.parseFloat except ValueError: discard
    if result <= 0 and not video:
      let size = h.getInt("file-size", -1)
      let dur = h.getFloat("duration")
      if size > 0 and dur > 0: result = size.float * 8 / dur
    return

proc start*(pr: Prober, path: string, timeout = 3.0) =
  ## Begins probing path; poll until it returns true, then read `info`.
  pr.pending = path
  pr.info = MediaInfo()
  pr.deadline = epochTime() + timeout
  pr.loaded = true
  pr.url = if path.isCueEntry: path.cueSource else: path
  pr.h.command("loadfile", if pr.url.len > 0: pr.url else: path, "replace")

proc poll*(pr: Prober, wait = 0.0): bool =
  ## Handles the pending probe's events, waiting up to `wait` seconds for one.
  ## True once it is done; `info` stays zeroed when the file failed or timed out.
  while pr.pending.len > 0:
    let left = pr.deadline - epochTime()
    if left <= 0: break
    let ev = mpv_wait_event(pr.h, min(wait, left))
    case ev.eventId
    of evNone: return false
    of evFileLoaded:
      # Skip a late event from a file an earlier probe abandoned.
      if pr.h.getStr("path") != pr.url: continue
      pr.info.duration = pr.h.getFloat("duration")
      if pr.pending.isAudFile and pr.pending.audLength > 0: pr.info.duration = pr.pending.audLength
      let tracks = pr.h.getNode("track-list")
      if tracks.kind == JArray:
        for t in tracks:
          if t{"type"}.getStr == "video" and not t{"albumart"}.getBool:
            pr.info.width = t{"demux-w"}.getInt
            pr.info.height = t{"demux-h"}.getInt
            let par = t{"demux-par"}.getFloat(1.0)
            (pr.info.shownW, pr.info.shownH) =
              (int(round(pr.info.width.float * (if par > 0: par else: 1.0))), pr.info.height)
            if t{"demux-rotation"}.getInt mod 180 != 0:
              swap(pr.info.shownW, pr.info.shownH)
            break
        pr.info.audioBitrate = pr.h.audioBitrate(tracks, pr.info.width > 0)
        for t in tracks:
          if t{"type"}.getStr == "audio":
            pr.info.rg = replayGainOf(t)
            break
      # Its .m2c's tags over the file's, and ReplayGain values.
      let side = readSide(pr.pending)
      pr.info.readTags(pr.h.getNode("metadata").overlay(side))
      let g = sideGain(side)
      if g.rg.known or g.hidden: pr.info.rg = g.rg
      let (s, i) = pr.pending.cueTrack
      if i >= 0:
        # The audio file's tags are the album's: the track's are the sheet's.
        pr.info.title = pr.pending.cueTitle
        pr.info.artist = s.cueArtist(i)
        if s.title.len > 0: pr.info.album = s.title
        pr.info.track = s.tracks[i].number
        if s.year > 0: pr.info.year = s.year
        if s.disc > 0: pr.info.disc = s.disc
      break
    of evEndFile:
      if cast[ptr MpvEventEndFile](ev.data).reason == efError:
        # mpv can't open it (a MIDI file, here): a .m2c's tags all the same.
        let side = readSide(pr.pending)
        pr.info.readTags(newJObject().overlay(side))
        pr.info.rg = sideGain(side).rg
        break
    of evShutdown: break
    else: discard
  pr.pending = ""
  true

proc probe*(pr: Prober, path: string, timeout = 3.0): MediaInfo =
  ## Opens path just long enough to read its duration and video size.
  if pr == nil: return
  pr.start(path, timeout)
  while not pr.poll(timeout): discard
  pr.info

proc finish*(pr: Prober) =
  ## Releases the last probed file.
  if pr != nil and pr.loaded:
    pr.pending = ""
    pr.loaded = false
    pr.h.command("stop")
