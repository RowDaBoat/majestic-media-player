## Majestic Media Player — an mpv-based video player with a Silky UI.

import gpumem  # first: it picks the GL library before anything loads one
import std/[os, strutils, strformat, times, math, osproc, unicode, sequtils, algorithm,
  random, tables, sets, streams, json]
import silky, vmath, bumpy, chroma, pixie, opengl, jsony
import mpv, videogl, xwin, config, dialogs, theme, ui, menutree, player, icons, debugscript,
  options, instance, playlists, peers, cmdlines, runlog, mediainfo, inhibit, spherical, keymap,
  rectedit, syncdlg, ytdlp, websave, mediasave, mkvtoolnix, updater, ytthumb, ytboard, srv3,
  netprobe
from std/uri import encodeUrl, decodeUrl, parseUri, decodeQuery, UriParseError

const
  AppName = "Majestic Media Player"
  AppVersion = staticRead("../VERSION").strip  # single source of truth: /VERSION
  # Bytes, not a string: MSVC refuses a C string literal past 64 KB.
  FontData = block:
    const s = staticRead("../assets/fonts/IBMPlexSans-Regular.ttf")
    var bytes: array[s.len, byte]
    for i, c in s: bytes[i] = byte(c)
    bytes
  MinWindow = ivec2(480, 270)
  MinCompactWindow = ivec2(16, 16)  ## pixels, not UI units: compact mode shrinks all the way
  OptionsSize = ivec2(912, 684)
  RenameSize = ivec2(400, 178)
  CommandsSize = ivec2(880, 520)
  YtdlpSize = ivec2(460, 176)
  EmbedSize = ivec2(460, 176)
  UpdateSize = ivec2(500, 260)
  EqualizerSize = ivec2(520, 336)
  EqMaxGain = 12.0          ## dB at the top of the equalizer's sliders
  EqMinGainLimit = -60.0    ## the lowest its bottom can be set to
  EqSettle = 0.4            ## seconds after an equalizer change it's set for good
  PlaylistRowH = 26'f32
  PlaylistHeaderH = 24'f32  ## column headers
  PlaylistIconW = 28'f32    ## the first column's room for the playing icon
  PlaylistMinTextW = 60'f32 ## narrowest a text column gets
  PlaylistColumnDrag = 4'f32  ## pixels a press moves to drag its column, not sort by it
  # An empty sample: a text column, which shares the width the others leave.
  PlaylistFields: array[PlaylistField, tuple[label, sample: string]] = [
    pfName: ("Name", ""),
    pfFilename: ("Filename", ""),
    pfDuration: ("Duration", "00:00:00"),
    pfSize: ("Size", "999.9 MB"),
    pfDimensions: ("Dimensions", "3840×2160"),
    pfAudioBitrate: ("Audio bitrate", "9 999 kb/s"),
    pfTrack: ("Track number", "999"),
    pfArtist: ("Artist", ""),
    pfYear: ("Year", "9999"),
    pfAlbum: ("Album", "")]
  PlaylistGripW = 5'f32     ## draggable left edge of the playlist
  RunLogHeaderH = 28'f32
  RunLogRowH = 18'f32
  RunLogGripH = 5'f32       ## draggable bottom edge of the run log
  RunLogBarW = 10'f32       ## its scroll bar
  RunLogWheelRows = 4       ## lines scrolled per mouse wheel step
  PlaylistWheelRows = 2     ## playlist entries scrolled per mouse wheel step
  PlaylistFollowPage = 0.6'f32  ## of the list's height, when playback reaches its bottom
  PlaylistBarW = 14'f32     ## the playlist's scroll bar gutter
  PlaylistBarThin = 4'f32   ## its thumb's width at rest
  PlaylistBarWide = 10'f32  ## and with the pointer on it
  SphereFov = 75'f32        ## 360° video: vertical field of view a file opens with
  SphereFovStep = 5'f32     ## degrees per Ctrl+Wheel notch
  SphereTextureMax = 8192   ## cap on the equirectangular texture's longer side

type
  Overlay = enum
    ovNone, ovOptions, ovProperties, ovShortcuts, ovAbout, ovRename, ovCommands, ovSync,
    ovYtdlp, ovEmbed, ovUpdate

  YtMode = enum
    ymInstall, ymUpdate, ymBusy, ymFailed  ## what the yt-dlp window asks or shows

  UpdateMode = enum
    umChecking, umLatest, umAsk, umBusy, umFailed  ## what the Check for Updates window asks or shows

  EmbedMode = enum
    emAsk, emInstall, emBusy, emFailed  ## what the Embed As MKV Chapters window asks or shows

  ContextMenu = enum
    cmVideo, cmTime, cmStatus, cmSeekBar, cmPlaylist, cmPlaylistColumns, cmRepeat, cmRunLog, cmQuality  ## where the right-click menu was opened

  PointerShape = enum
    ptArrow, ptHidden, ptResize, ptResizeV, ptResizeNWSE, ptResizeNESW, ptCross, ptMove,
    ptMoving, ptText

  VideoTransform = object
    pan: Vec2
    rotation: float32
    zoom: float32 = 1
    scaleX: float32 = 1
    scaleY: float32 = 1

  StandbyState = enum
    sbOff       ## no loop to serve
    sbLoading   ## opening the file
    sbSeeking   ## going to its spot before A
    sbReady     ## waiting there, decoded
    sbRolling   ## playing unseen, muted, about to take over

  LoopSoundState = enum
    lsOff       ## no loop to serve
    lsLoading   ## going to A
    lsReady     ## waiting at A
    lsRolling   ## started, to be heard from the shown player's jump back on
    lsOn        ## heard; the shown players are silent and keep with it

  LoopFramesState = enum
    lfOff       ## no short loop to serve
    lfSeeking   ## the standby going to A
    lfStepping  ## stepping it through to B, a frame taken each step
    lfDone      ## all of the loop's frames taken
    lfFailed    ## couldn't (no memory, stuck): the plain way for this loop

  StepFramesState = enum
    sfParked    ## the standby waits where it stopped
    sfSeeking   ## going to where the next frames start
    sfStepping  ## stepping through them, a frame taken each step

  LoopFrame = object
    t: float                  ## its time
    target: VideoTarget

  MasterClock = object
    ## A slave's view of its master's playback, in the master's time.
    known: bool               ## heard from the master since joining
    loaded, playing, stopped: bool
    t: float                  ## master time at `at`
    at: float                 ## when, our clock
    speed: float = 1
    loopA, loopB: float       ## the master's loop (A-B or its file), master time;
                              ## none unless loopB > loopA
    dur: float                ## the master's file's duration, 0 when unknown

  SubLayout = object
    alignX: int = 1           ## 0 left, 1 center, 2 right
    alignY: int = 2           ## 0 top, 1 middle, 2 bottom
    offset: Vec2              ## screen pixels, +x right, +y down
    scale: float32 = 1

  App = ref object
    window: Window
    sk: Silky
    ui: Ui
    menus: MenuSystem
    quad: QuadRenderer
    player: Player
    standby: Player           ## seamless loops: the hidden second player
    sbState: StandbyState
    sbPath: string            ## the file it holds
    sbA, sbB, sbStart: float  ## the loop it serves; where it waits
    sbPending: bool           ## the standby has a frame to draw
    sbLastPos: float          ## the playing player's last position while rolling
    sbPlayingB: float = NaN   ## ab-loop-b as set on the playing player here
    sbHandoff: bool           ## it serves a link's saved part: opens the
                              ## stream to take over where the part ends
    sbOpts: string            ## mpv's per-file options it opens the file with
    handoffFailed: bool       ## it couldn't, for the part playing
    lsound: Player            ## a loop's sound, seamless (loopSound)
    lsState: LoopSoundState
    lsKey: string             ## the file, track and loop it serves
    lsSrc, lsTrack: string    ## the file it plays and its track there
    lsA, lsB: float           ## that loop
    lsAsked: int              ## its restarts when it was sent to A
    lsShown: Player           ## the playing player as last seen
    lsJumps: int              ## and its jumps then
    lsSilent: bool            ## the shown players' own sound is turned down
    lsRollAt: float           ## when it started rolling
    lsHeard: float = NaN      ## when its A was due to be heard, until learned from
    lsLead: float = 0.05      ## short loops: how long the playing player's
                              ## seek back to A takes, media seconds
    lsRound, lsSoughtRound: int  ## short loops: rounds of the sound, and the
                              ## last one the playing player was sent back for
    lsCheck: int = -1         ## short loops: the playing player's restarts
                              ## once sent back, to see how it landed; -1 none
    lsPhase: float            ## where in the loop it was last seen
    lsMoved: float            ## its position last seen, and since when
    lsMovedAt: float
    lfState: LoopFramesState
    lfKey: string             ## the file, loop, size and look its frames are for
    lfFrames: seq[LoopFrame]  ## a short loop's frames, as shown, in order
    lfTrash: seq[LoopFrame]   ## frames to free in the next GL pass
    lfAsked: int              ## the standby's restarts when it was sent to A
    lfLastT: float            ## its time at the frame last taken
    lfStart: float            ## where it was sent, a little before A
    lfPending: bool           ## it has a new frame to take
    lfSlot: LoopFrame         ## the frame being taken, until it settles
    lfSlotOpen: bool
    lfSettleAt: float         ## when it was last rendered
    lfAskedAt: float          ## when the last seek or step was asked for
    lfBytes: int              ## memory the frames take
    lfSize: (int, int)        ## the playing player's render size, last drawn
    lfLook: string            ## its settings that show in a frame, last drawn
    lfShow: int = -1          ## the frame to show, -1 for the player's own
    lfOn: bool                ## frames are being shown
    lfClock: float            ## without a loop sound: media time into the loop
    lfClockAt: float          ## when it last moved
    lfClockSet: bool          ## it has been put where the playing player is
    lfJumps: int              ## the playing player's jumps, as last seen
    lfDue: bool               ## a frame to draw, or to take, right away
    sfOn: bool                ## paused where step frames can serve
    sfState: StepFramesState
    sfKey: string             ## the file, size and look its frames are for
    sfPath: string            ## the file the standby has open for them
    sfFrames: seq[LoopFrame]  ## consecutive frames around the position, in order
    sfFill: seq[LoopFrame]    ## frames being taken to go before those
    sfBefore: bool            ## they go before (else after, as they're taken)
    sfShow: int = -1          ## the frame to show, -1 for the player's own
    sfOwed: int               ## steps waiting for frames, negative going back
    sfAtStart: bool           ## the first frame is the file's
    sfAtEnd: bool             ## the last one is
    sfStart: float            ## where the standby was sent
    sfStop: float             ## the time the frames being taken go up to
    sfAbort: bool             ## the position left them: stop taking them
    sfParkT: float = -1       ## the frame the standby stopped at, if a kept one's
    sfAsked: int              ## the standby's restarts when it was sent
    sfAskedAt: float          ## when the last seek or step was asked for
    sfLastT: float            ## its time at the frame last taken
    sfPending: bool           ## it has a new frame to take
    sfUpdated: bool           ## it gave a frame since it was last sent on
    sfSlot: LoopFrame         ## the frame being taken, until it settles
    sfSlotOpen: bool
    sfSettleAt: float         ## when it was last rendered
    sfJumps: int              ## the player's jumps, as last seen
    sfMovedAt: float          ## when it last paused or was sent elsewhere
    sfWanted: float           ## when stepping last seemed likely
    sfPlainAt: float          ## when it last stepped the plain way
    preview: Preview
    cfg: Config
    playlist: seq[string]
    plIndex: int
    plSelected: int
    plMarks: seq[int]         ## the whole selection, sorted, when more than plSelected
    plFocused: bool           ## the playlist was clicked last: it takes its keys
    plArrows: bool            ## clicked and the pointer has not left it since: Up/Down select
    plScroll: float32
    plReveal: bool            ## scroll the selected entry into view
    plFollow: bool            ## as plReveal, paging on when it lands on the bottom row
    plThumbFrom: (float32, float32)      ## pointer y and scroll when the thumb drag began
    plBarLift: float32        ## scroll bar's eased hover: 0 thin and grey, 1 wide and lit
    plBarAt: float            ## when plBarLift last eased
    prober: Prober            ## created on the first sort that needs it
    mediaInfo: Table[string, MediaInfo]  ## probe results, for columns and sorting
    plColumnFrom: tuple[index: int, x: float32, moved: bool]  ## the header pressed, while "plcolumn" is active
    plDurSeconds: bool        ## the Duration column in plain seconds: nothing lasts over a minute
    fileSizes: Table[string, int64]      ## -1 for streams and unreadable files
    plResizeFrom: (float32, float32)     ## pointer x and width when the drag began
    xf: VideoTransform
    subs: SubLayout
    subsKey: string           ## mpv subtitle placement last pushed
    osdFit: tuple[key: string, target, x, y: (int, int), subMarginX: int, unit: float, props: string]
    afterPlayback: AfterPlayback
    overlay: Overlay
    optionsDlg: OptionsDialog
    optWin: Window            ## Options dialog window, created on first use
    optSk: Silky              ## its own Silky: one tracks one window's input
    optUi: Ui
    atlasImg: Image
    atlas: SilkyAtlas
    cfgBefore: Config         ## config when Options opened, restored on Cancel
    settingsKey: string       ## player-facing settings last pushed to mpv
    coverSynced: bool         ## the cover settings below were pushed to mpv
    coverShown: bool          ## and what they were: Show Front Cover
    coverNames: string        ## Options' folder picture names
    positions: Positions      ## remembered playback positions
    subScales: SubScales      ## remembered subtitle sizes, per file
    bookmarks: Bookmarks      ## per-file bookmarks, shown on the seek bar
    bmPath, bmKey: string     ## the current file and its mediaKey, once known
    bmPending: string         ## the file whose mediaKey is being worked out
    renWin: Window            ## Edit Bookmark dialog, created on first use
    renSk: Silky
    renUi: Ui
    renPath: string           ## the bookmark being edited: its file and time
    renTime: float            ## its time now, moved as the Time field is left
    renOrigTime: float        ## its time when opened, restored on Cancel
    renText: string
    renTimeText: string       ## the Time field
    renPlaceholder: string    ## its default label, shown when renText is empty
    renOrigPos: float         ## playback position when opened, back to on Cancel
    renSeeked: bool           ## Preview moved playback since it opened
    embWin: Window            ## Embed as MKV Chapters confirmation, created on first use
    embSk: Silky
    embUi: Ui
    embPath: string           ## the file asked about, then the one being written
    embProc: Process          ## mkvpropedit writing its chapters
    embTmp: string            ## the chapters file mkvpropedit reads
    embClear: bool            ## clear the file's bookmarks once it's done
    embMode: EmbedMode
    upJob: UpJob              ## Check for Updates at work: the check, then getting the release
    thumb: ThumbJob           ## the YouTube link's thumbnail, for while no video track shows
    thumbTex: GLuint          ## it, uploaded
    thumbTexId: string        ## the video id thumbTex holds
    board: BoardJob           ## the YouTube link's seek bar previews, fetched in the background
    upMode: UpdateMode
    upMsg: string             ## the Check for Updates window's text when it failed
    upWin: Window             ## the Check for Updates window, created on first use
    upSk: Silky
    upUi: Ui
    upRestart: bool           ## restarting into the update: the state is saved for it
    rdRestart: string         ## restarting onto the other renderer, "cpu" or "gpu" (gpumem),
                              ## the state saved for it as for an update
    rdForNow: bool            ## on the CPU until the GPU has the memory again
    rdSince: float            ## since when the GPU's memory has been past the line (watchVram)
    rdCheckAt: float          ## when it's looked at next
    rdStart: float            ## when this run started rendering
    rdNote: string            ## what's said of the renderer once the file is open
    resume: ResumeState       ## the state from before restarting into an update,
    resuming: bool            ## brought back as its file opens
    embMsg: string            ## its text while installing or failed
    mkvJob: MkvJob            ## MKVToolNix being installed
    cmdDlg: CmdDialog         ## Commands window, its window created on first use
    cmdWin: Window
    cmdSk: Silky
    cmdUi: Ui
    commands: seq[CommandLine]  ## the Run menu's command lines
    runLog: seq[RunEntry]     ## command lines run, oldest first, with their output
    rlScroll: float32
    rlFollow: bool            ## keep the run log scrolled to its newest line
    rlResizeFrom: (float32, float32)     ## pointer y and height when the drag began
    rlThumbFrom: (float32, float32)      ## pointer y and scroll when the thumb drag began
    rlRows: seq[string]       ## the run log's rows as last drawn, for copying
    rlSelFrom, rlSelTo: (int, int)       ## selected text: (row, byte offset) where the drag began and where it is
    pickDlg: PickDialog       ## Run window: timestamps and values for a run
    extRun: CommandLine       ## the command line whose external files are asked for
    extQueue: seq[string]     ## its external-file cards still to ask about
    extPicks: Table[string, string]  ## the files chosen so far, by card name
    pickWin: Window
    pickSk: Silky
    pickUi: Ui
    rectEdit: RectEdit        ## a Run window rectangle being drawn over the video
    rectBefore: seq[string]   ## the Run window's values when it began, for Escape
    resumedAt: float          ## start time of the file being loaded, else 0
    savedPos: float           ## playback position last written to positions.json
    savedCfg: string          ## config.json as last written by autosave
    autosaveAt: float         ## when the remembered state was last checked
    instance: InstanceServer  ## receives files from later launches
    peers: PeerNet            ## other players, for Synchronize
    syncMaster: int           ## pid of our group's master, 0 when not synchronized
    syncMembers: seq[int]     ## the group, master included
    syncQuiet: bool           ## acting on a peer's command (or on our own EOF):
                              ## don't repeat it to the group
    followOffset: float       ## Synchronize > Properties, as a slave: start this long after the master
    followLoop: bool          ## as a slave: loop on our own until the master ends
    clock: MasterClock        ## as a slave: where the master is
    clockHeldUntil: float     ## a playback action is in flight: no ticks out (master)
                              ## or in (slave) until then
    tickAt, tickT: float      ## master: when the last tick went out, and its time
    followRunning: bool       ## slave: following has the file playing
    followSought: float       ## slave: time following last sought to while held, NaN when none
    followFixAt: float        ## slave: when following last corrected the playing file
    followLoopSet: string     ## slave: loop-file as following last set it
    followAbSet: string       ## slave: ab-loop-a/b as following last set them
    followAb: tuple[a, b: float]  ## slave: that loop, b = 0 when none
    followPrevT: float        ## slave: following's last target time
    followWrapped: bool       ## slave: the master looped, our file must jump back
    followSettleAt: float     ## slave: drift is played off from then on (after a loop)
    eqWin: Window             ## the Equalizer window, created on first use; shown
    eqSk: Silky               ## alongside the player, not over it
    eqUi: Ui
    eqPos: IVec2              ## where it was when last hidden, outer top-left
    equalizers: Equalizers    ## equalizers saved for media files
    eqUnsaved: string         ## the file whose saved equalizer changed, key
    eqChangedAt: float        ## when the equalizer last changed
    eqDragging: bool          ## a drag across its sliders, at this band and gain
    eqDragAt: (int, float)
    eqTipBand: int            ## a band moved by key or wheel: its value shown
    eqTipUntil: float         ## until then
    syncDlg: SyncDialog       ## Synchronize > Properties, its window created on first use
    syncWin: Window
    syncSk: Silky
    syncUi: Ui
    ytJob: YtJob              ## yt-dlp at work: a check, update or install
    ytUrl: string             ## the link it works for
    ytWatch: bool             ## the link being opened goes to yt-dlp if it fails
    ytCurrent, ytLatest: string  ## yt-dlp's versions, installed and released
    ytError: string           ## why the link couldn't be opened
    ytTries: int              ## the link's stream tried again this many times
    ytCookies: Table[string, string]  ## links that asked to sign in: the browser
                              ## whose cookies yt-dlp signs in with (cookieBrowsers)
    ytCookieTried: seq[string]  ## the browsers tried on the link being opened
    streamArgs: tuple[url: string, start: float, opts: string]
    streamPos: float          ## where the link's stream last played, to go on from
    stallAt: float            ## when the stream started waiting for data without
                              ## getting any (0: it isn't), and how much it had then
    stallAhead: float
    dropTries: int            ## the dropped stream reopened this many times
                              ## the link last streamed, to try again with
    stopOnLoad: bool          ## Stop, once the link loads (going online stopped)
    saved: SaveIndex          ## links kept on disk as they streamed (websave)
    webInfoAt: float          ## when Options > Playback > Media Cache's list was last read
    rec: Seg                  ## the stream being saved: its file and what it holds
    recUrl: string            ## its link; "" while none is
    recRanges: int            ## mpv's cache ranges as it started
    recWritten: float         ## rec.stop as last written to the index
    ytSubs: YtJob             ## a saved link's subtitles being downloaded
    saveJob: SaveJob          ## File > Save, while saving
    saveSrc: string           ## the file or link File > Save asked where to save
    ytRetry: string           ## a link to open again at ytRetryAt
    ytRetryAt: float
    ytRetryNet: bool          ## ytRetry is a dropped stream's: opened once the
                              ## network answers (netUp), never while it doesn't
    netProbe: NetProbe        ## asking the stream's host whether the network's there
    netProbeAt: float         ## when the next probe may start
    netUp: int                ## what the last probe found: 1 up, -1 down, 0 not known
    netWasDown: bool          ## a probe found no network since the stream last played
    netBackAt: float          ## when a probe found it back after that (0: it isn't)
    ytHooked: string          ## the yt-dlp mpv opens links with, "" until there is one
    ytCaps: YtJob             ## the open link's automatic captions being looked up
    ytCaptions: Table[string, seq[tuple[url, title, lang: string]]]  ## and found, by link
    ytStyling: StyledJob      ## the link's styled subtitles being fetched
    ytStyled: Table[string, seq[StyledTrack]]  ## and made into ASS, by link
    ytQualities: Table[string, tuple[video, audio: seq[Quality]]]  ## a link's formats, found alike
    ytBoards: Table[string, Storyboard]  ## a link's storyboard, found alike
    ytLang: Table[string, string]  ## a link's dub picked in Audio Track (not its own language)
    ytPick: Table[string, tuple[video, audio: string]]  ## formats picked in the quality
                              ## menu, by link ("": as Options > Online picks)
    qualityRect: Rect         ## the controls' quality button, as last drawn
    playFormat: Table[string, string]  ## format ids playing, by link (its stream's,
                              ## or its saved part's); "" unknown
    ytAuto: Table[string, string]  ## format ids Options > Online's choice came to, by link
    ytAutoParts: Table[string, tuple[video, audio: string]]  ## its video and audio
                              ## apart, each as it last played (autoParts)
    qualitySwitch: bool       ## the link opens again in another quality
    holding: bool             ## the frame before it stays up until the new one's first
    heldTarget: VideoTarget   ## that frame
    heldCorners: array[4, Vec2]  ## where it was drawn
    heldPath: string
    heldSince: float
    heldFresh: bool           ## a frame of the new stream came since it opened
    videoCorners: array[4, Vec2]  ## where the video was last drawn
    ytList: YtJob             ## a YouTube playlist's videos being listed (listYoutube)
    ytListUsed: int           ## the ones in the playlist so far
    ytListLast: string        ## the entry the next ones go after; "" while they go
                              ## before the link's own video (or none plays yet)
    ytListed: HashSet[string] ## links whose playlists were listed
    ytInfo: YtJob             ## YouTube videos' durations and sizes being looked
                              ## up for the playlist's columns (infoNext)
    ytInfoLinks: seq[string]  ## the links it's looking up
    ytInfoTried: HashSet[string]  ## links looked up, found or not
    linkTitles: Table[string, string]  ## links' titles, for the playlist's rows
    linkInfos: LinkInfos      ## links' metadata as the media cache keeps it
    linkInfosChanged: bool    ## not written yet (saveLinkInfos)
    linkInfosRead: HashSet[string]  ## playlist entries given theirs (readLinkInfos)
    ytMode: YtMode
    ytMsg: string             ## the yt-dlp window's text while busy or failed
    ytWin: Window             ## the yt-dlp window, created on first use
    ytSk: Silky
    ytUi: Ui
    props: seq[InfoSection]   ## File > Properties report
    propScroll: float32
    hintScroll: float32         ## status bar key hints' horizontal scroll
    hintScrollKey: string       ## the hints hintScroll belongs to
    propPageH: float32        ## height of its scrolling body, for Page Up / Down
    propThumbFrom: (float32, float32)    ## pointer y and scroll when the thumb drag began
    dialog: Dialog
    children: seq[Process]
    fullscreen: bool
    frameInset: IVec2         ## content minus frame top-left while decorated (for compact mode)
    ctxMenu: ContextMenu
    # mouse interaction with the video frame
    videoPress: bool
    videoPressPos: Vec2
    rotDrag: bool             ## Alt+Middle drag is turning the frame
    rotPivot: Vec2            ## window pixels the frame turns around
    rotStart: VideoTransform  ## transform when the drag began
    rotRef: float32           ## cursor angle around the pivot the turn counts from
    rotRefSet: bool
    rotPressPos: Vec2         ## window pixels where the press began
    panDrag: bool             ## Ctrl+Left drag is panning the zoomed frame
    panFrom: Vec2             ## window pixels where the pan drag began
    panStart: Vec2            ## pan when the drag began
    # 360° video camera, degrees
    lookYaw, lookPitch: float32
    lookFov: float32 = SphereFov
    lookDragging: bool        ## a left drag is turning the camera
    lookLast: Vec2            ## pointer position the drag last turned from
    osdMsg: string            ## OSD message drawn by us over a 360° view
    osdUntil: float
    osdLayer: OsdLayer        ## draws the OSD while the video is transformed
    osdFlag: bool             ## the OSD layer asked for a redraw
    osdApart: bool            ## the OSD is drawn by osdLayer now
    osdLayerSizes: string     ## osdSizes last pushed to osdLayer
    osdStatus: string         ## the layer's status line as last sent
    rotMoved: bool            ## past the click threshold; a click resets rotation
    lastMouse: Vec2
    lastMouseMove: float
    pointerShape: PointerShape
    # seek bar
    seekDragging: bool
    seekDragT: float
    seekRect: Rect            ## seek bar as last drawn
    seekSpan: float           ## seconds the seek bar's width stands for
    padLen: float             ## the delay under way after a short file; 0 none
    padAt: float              ## when it began, or while held the seconds it has run
    padHeld: bool             ## paused during the delay
    ctxSeekT: float           ## seek bar time the context menu was opened at
    ctxBookmark: int          ## bookmark under the pointer then, else -1
    ctxColumn: PlaylistField  ## playlist column header right-clicked
    ctxOnMarker: bool         ## a chapter or bookmark was under the pointer then
    ctxMarkerT: float         ## and its time
    # A-B loop; marks last only for the current file
    loopA, loopB: float
    hasLoopA, hasLoopB: bool
    abLoop: bool
    pingPongOn: bool          ## a ping-pong loop as last applied
    pingPongLast: float       ## its position the pass before, for crossing A or B
    plDir: int = 1            ## ping-pong playlist: the way it goes next
    reopening: bool           ## the file opens again (Player.reopen)
    reopenTracks: seq[Track]  ## its added tracks then, to add back
    reopenSel: seq[(string, int)]  ## and the tracks selected
    lastDragSeekAt: float
    previewQuad: Rect
    showPreview: bool
    # window management
    onTopApplied: bool
    screenInhibit: Inhibitor  # keeps the display on while video plays
    title: string
    hintsKey: string
    fitPending: bool
    # render scheduling
    frameFlag, previewFlag: bool
    framePending: bool        ## mpv has a frame queued for frameDue
    frameDue: int64           ## mpv_get_time_ns when it should be shown
    renderNow: bool           ## render the queued frame this iteration
    dirtyUntil: float
    focusLostAt: float        ## when the window lost focus, else 0
    menuOpenedAt: float       ## when the menus opened, else 0
    fakeMods: string          ## debug scripting: "ctrl", "alt+shift", ...
    inputPending: bool        ## button/key/scroll this iteration; Windy clears
                              ## those per pollEvents, so draw before the next
    videoRect: Rect
    script: Script
    shotPath: string
    dropped: seq[string]      ## paths/URLs from a drag and drop, one per file
    dropAt: Vec2              ## pointer position when the drop arrived
    plListRect: Rect          ## playlist rows area as last drawn (empty if hidden)

proc setlocale(category: cint, locale: cstring): cstring {.importc, header: "<locale.h>".}
var LC_NUMERIC {.importc, header: "<locale.h>".}: cint

proc now(): float = epochTime()

# --- small helpers ----------------------------------------------------------

proc ctrl(w: Window): bool = w.buttonDown[KeyLeftControl] or w.buttonDown[KeyRightControl]
proc shift(w: Window): bool = w.buttonDown[KeyLeftShift] or w.buttonDown[KeyRightShift]
proc alt(w: Window): bool = w.buttonDown[KeyLeftAlt] or w.buttonDown[KeyRightAlt]

proc updateOsdApart(a: App)

const OsdError = 8.0  ## seconds a failure stays up: time to read it, or screenshot it

proc ownOsd(a: App): bool =
  ## mpv draws the OSD into the picture, which a 360° view would warp onto
  ## the sphere (out of sight), and without one (audio, a link that didn't
  ## open) there's nothing to draw it in: the app shows the message instead.
  a.player.isSpherical or not a.player.hasVideo

proc osd(a: App, msg: string, secs = 1.5) =
  a.updateOsdApart()  # the transform may have just changed
  if a.ownOsd:
    if a.cfg.showOsd:
      a.osdMsg = msg
      a.osdUntil = now() + secs
      a.dirtyUntil = max(a.dirtyUntil, a.osdUntil + 0.1)
  elif a.osdApart:
    a.osdLayer.h.commandAsync("show-text", msg, $int(secs * 1000))
  else:
    a.player.osd(msg, secs)

proc fileTitle(path: string): string = path.extractFilename

proc bottomHeight(a: App): float32 =
  (if a.cfg.showSeekBar: SeekBarHeight else: 0) +
  (if a.cfg.showControls: ControlsHeight else: 0) +
  (if a.cfg.showStatus: StatusHeight else: 0)

proc playlistWidth(a: App): float32 =
  max(PlaylistMinWidth, round(a.cfg.playlistWidth).float32)

proc runLogHeight(a: App): float32 =
  max(RunLogMinHeight, round(a.cfg.runLogHeight).float32)

proc px(a: App, v: IVec2): IVec2 =
  ## UI units to window pixels (Options > Player > UI scaling).
  let s = a.sk.uiScale
  ivec2(int32(round(v.x.float32 * s)), int32(round(v.y.float32 * s)))

proc px(a: App, r: Rect): Rect =
  let s = a.sk.uiScale
  rect(r.x * s, r.y * s, r.w * s, r.h * s)

proc minWindow(a: App): IVec2 =
  if a.cfg.compactMode: MinCompactWindow else: a.px(MinWindow)

proc menuBarHeight(a: App): float32 =
  ## Height of the menu bar as laid out: none in full screen or compact mode.
  if a.fullscreen or a.cfg.compactMode: 0 else: MenuBarHeight

proc chromeSize(a: App): IVec2 =
  ## Window space not used by the video frame (windowed mode), in pixels.
  let menuH = if a.cfg.compactMode: 0'f32 else: MenuBarHeight
  a.px(ivec2(int32(if a.cfg.showPlaylist: a.playlistWidth else: 0),
        int32(menuH + a.bottomHeight + (if a.cfg.showRunLog: a.runLogHeight else: 0))))

proc naturalSize(a: App): Vec2 =
  var w = a.player.videoW.float32
  let h = a.player.videoH.float32
  let parts = a.cfg.aspectOverride.split(':')
  if parts.len == 2 and h > 0:
    try: w = h * parseFloat(parts[0]) / parseFloat(parts[1])
    except ValueError: discard
  vec2(w, h)

proc videoAspect(a: App): float =
  let n = a.naturalSize
  if n.y > 0: n.x / n.y else: 0

# --- atlas & UI scaling ----------------------------------------------------

proc glyphSet(): seq[string] =
  result = AsciiGlyphs
  for cp in 0xA0 .. 0x17F: result.add $Rune(cp)
  for s in ["…", "–", "—", "•", "‘", "’", "“", "”", "→", "←", "×", "°", "·", "▸"]:
    result.add s

proc buildAtlas(scale: float32): (Image, SilkyAtlas) =
  ## Fonts and icons rasterized at scale (Silky draws them at their UI size).
  let fontPath = getTempDir() / "majestic-media-player-font.ttf"
  if not fileExists(fontPath) or getFileSize(fontPath) != FontData.len:
    writeFile(fontPath, FontData)
  let b = newAtlasBuilder(2048, 2)
  let glyphs = glyphSet()
  proc px(size: int): int = int(round(size.float32 * scale))
  b.addFont(fontPath, FontMain, 15 * scale, glyphs)
  b.addFont(fontPath, FontSmall, 13 * scale, glyphs)
  b.addFont(fontPath, FontTitle, 20 * scale, glyphs)
  b.addIcons(scale)
  discard b.addImage("crown96", renderIcon(crownPath, 24, px(96)))
  discard b.addImage("music96", renderIcon(musicPath, 24, px(96)))
  discard b.addImage("knob16", renderIcon("M12 4a8 8 0 1 0 0.001 0z", 24, px(16)))
  (b.atlasImage, b.atlas)

# --- window management ------------------------------------------------------

proc updateTitle(a: App) =
  let path = a.player.path
  var name = if a.cfg.titleFullPath: path else: path.fileTitle
  if a.cfg.titleUseMediaTitle and a.player.loaded:
    # mpv falls back to the file name when the file has no title tag.
    let mt = a.player.h.getStr("media-title")
    if mt.len > 0 and mt != path.fileTitle and mt != path: name = mt
  let t = if path.len > 0: name & " - " & AppName else: AppName
  if t != a.title:
    a.title = t
    a.window.title = t

proc updateAspectHints(a: App) =
  # Not on Windows, to resize freely as on KWin, which ignores the hint: Fit
  # letterboxes the video in whatever shape the window is given.
  let enforce = not defined(windows) and not a.fullscreen and a.cfg.preserveAspect and
    a.cfg.frameMode == fmFit and a.player.hasVideo and not a.player.stopped
  let aspect = if enforce: a.videoAspect else: 0.0
  let chrome = a.chromeSize
  let key = &"{aspect:.4f}/{chrome.x}/{chrome.y}"
  if key != a.hintsKey:
    a.hintsKey = key
    a.window.setAspectHints(aspect, chrome, a.minWindow)

proc fitWindowToVideo(a: App) =
  ## Sizes the window so the video shows at its natural size, capped to 85%
  ## of the monitor.
  if a.fullscreen or a.window.maximized or not a.player.hasVideo: return
  let nat = a.naturalSize
  let chrome = a.chromeSize.vec2
  let mon = a.window.monitorSize.vec2
  let maxV = mon * 0.85 - chrome
  let s = min(1'f32, min(maxV.x / nat.x, maxV.y / nat.y))
  let v = vec2(round(nat.x * s), round(nat.y * s))
  var size = ivec2(int32(v.x + chrome.x), int32(v.y + chrome.y))
  size.x = max(size.x, a.minWindow.x)
  size.y = max(size.y, a.minWindow.y)
  a.window.size = size

proc resizeKeepingVideo(a: App, delta: IVec2) =
  ## Grows/shrinks the window by delta when chrome is toggled, so the video
  ## frame keeps its size. delta is in UI units.
  if a.fullscreen or a.window.maximized: return
  a.window.size = a.window.size + a.px(delta)

proc setFullscreen(a: App, on: bool) =
  if on == a.fullscreen: return
  a.menus.close()
  a.fullscreen = on
  a.window.fullscreen = on
  a.hintsKey = ""
  if on:
    a.window.setAspectHints(0, ivec2(0, 0), a.minWindow)
  elif a.cfg.compactMode:
    a.window.setDecorated(false)  # leaving full screen may restore the frame

proc setCompact(a: App, on: bool) =
  ## Compact mode hides the window frame and the menu bar (the right-click
  ## menu still has every command). The video keeps its size and its place on
  ## screen.
  if on == a.cfg.compactMode: return
  a.menus.close()
  a.cfg.compactMode = on
  a.hintsKey = ""
  if a.fullscreen: return  # applied when leaving full screen
  let content = a.window.pos
  if on: a.frameInset = content - a.window.framePos
  a.window.setDecorated(not on)
  if a.window.maximized: return
  let menu = a.px(ivec2(0, int32(MenuBarHeight))).y
  let d = if on: menu else: -menu
  var size = a.window.size - ivec2(0, d)
  size.x = max(size.x, a.minWindow.x)
  size.y = max(size.y, a.minWindow.y)
  a.window.size = size
  let moved = content + ivec2(0, d)
  a.window.moveFrame(if on: moved else: moved - a.frameInset)

proc applyOnTop(a: App) =
  let want = case a.cfg.onTop
    of otDefault: false
    of otAlways: true
    of otWhilePlaying: a.player.playing
    of otWhilePlayingVideo: a.player.playing and a.player.hasRealVideo
  if want != a.onTopApplied:
    a.onTopApplied = want
    a.window.setAlwaysOnTop(want)

proc applyKeepAwake(a: App) =
  a.screenInhibit.set(a.cfg.keepDisplayOn and a.player.playing and a.player.hasRealVideo)

# --- synchronize ------------------------------------------------------------
# Synchronized players repeat each other's playback controls: whoever acts
# sends the action to every other member, each playing its own file. Times go
# out as absolute positions, clamped to each file's duration. The master (the
# player that started the group) owns the membership and keeps its playlist;
# the others' playlists are emptied and locked while synchronized.
#
# The others (slaves) follow the master's clock: times on the wire are the
# master's, and every action and the master's periodic ticks update a slave's
# view of that clock (MasterClock); `follow` then keeps its file where the
# clock says, offset (Synchronize > Properties) and looping included.

proc synced(a: App): bool = a.syncMaster != 0

proc isSyncMaster(a: App): bool = a.synced and a.syncMaster == a.peers.pid

proc isSlave(a: App): bool = a.synced and not a.isSyncMaster

proc masterNow(a: App): float =
  ## Slave: the master's time now, from its last known time and rate. Inside
  ## its loop it wraps from B back to A just as the master's player does.
  let c = a.clock
  let raw = c.t + (if c.playing: (now() - c.at) * c.speed else: 0.0)
  let len = c.loopB - c.loopA
  if len > 0 and c.t < c.loopB and raw >= c.loopB:
    c.loopA + floorMod(raw - c.loopB, len)
  elif c.dur > 0 and c.t <= c.dur: min(raw, c.dur)  # it stops at its end
  else: raw

proc baseSpeed(a: App): float =
  ## The playback rate as set: a slave's own is nudged to keep up (follow).
  if a.isSlave and a.clock.known: a.clock.speed else: a.player.speed

proc playlistLocked(a: App): bool = a.synced and not a.isSyncMaster

proc editLocked(a: App): bool =
  ## True (with a note on screen) when the playlist may not be edited here.
  if a.playlistLocked and not a.syncQuiet:
    a.osd("Playlist is locked: synchronized with another player")
    return true

template quietly(a: App, body: untyped) =
  let wasQuiet = a.syncQuiet
  a.syncQuiet = true
  try: body
  finally: a.syncQuiet = wasQuiet

proc syncSend(a: App, fields: varargs[string]) =
  ## Repeats a playback action on the other synchronized players.
  if a.syncQuiet or not a.synced: return
  a.clockHeldUntil = now() + 0.5
  for m in a.syncMembers:
    if m != a.peers.pid: a.peers.send(m, fields)

proc clockAction(a: App, f: openArray[string]) =
  ## Slave: a playback action of the group (master time) moves our view of
  ## the master's clock; following does the rest.
  template num(i: int): float =
    (try: parseFloat(f[i]) except ValueError, IndexDefect: 0.0)
  let c = addr a.clock
  c.t = a.masterNow
  c.at = now()
  case f[0]
  of "play":
    c.playing = true
    c.stopped = false
  of "pause":
    c.playing = false
    c.t = num(1)
  of "stop":
    c.playing = false
    c.stopped = true
    c.t = 0
  of "seek":
    c.t = max(num(1), 0)
    c.stopped = false
  of "speed": c.speed = num(1)
  of "frame": c.playing = false  # a frame step pauses
  else: discard

proc followTarget(a: App): tuple[t: float, run: bool] =
  ## Slave: where the master's clock puts our file, and whether it plays.
  ## It waits at its start until the master reaches the offset, then goes
  ## along; past its end it loops on its own (Continue looping) or holds the
  ## last frame until the master loops.
  let dur = a.player.duration
  let rel = a.masterNow - a.followOffset
  if rel < 0: (0.0, false)
  elif rel < dur: (rel, a.clock.playing)
  elif a.followLoop: (floorMod(rel, dur), a.clock.playing)
  else: (dur, false)

proc stepPlayer(a: App, forward: bool)

proc slaveFrame(a: App, forward: bool) =
  ## Slave: a frame step of the group. It pauses the master; our file steps
  ## too when within reach, and the master's next tick sets the exact time.
  a.clockAction(["frame"])
  a.followRunning = false
  let (t, _) = a.followTarget
  a.followSought = t  # no seek back to where the step began
  let rel = a.masterNow - a.followOffset
  if a.player.loaded and rel >= 0 and (rel < a.player.duration or a.followLoop):
    a.player.stopped = false
    a.stepPlayer(forward)

proc slaveDo(a: App, fields: varargs[string]): bool =
  ## Slave: a playback control used here goes to the group, in master time,
  ## and drives our view of the master's clock. False when not a slave.
  if not a.isSlave or a.syncQuiet: return false
  a.syncSend(fields)
  a.clockAction(fields)
  true

proc clampTime(a: App, t: float): float =
  ## A group member's time on this player's (perhaps shorter) file.
  if a.player.duration > 0: clamp(t, 0, a.player.duration) else: max(t, 0)

# --- playback actions -------------------------------------------------------

proc loopReady(a: App): bool =
  a.hasLoopA and a.hasLoopB and a.loopB > a.loopA

proc pingPongFile(a: App): bool =
  ## Repeat > Ping-Pong on a file repeating forever: back and forth through
  ## it. Not in a synchronize group, whose clock only runs forward.
  a.cfg.repeatPingPong and a.cfg.repeatForever and not a.synced and
    (a.cfg.repeatMode == rmFile or a.playlist.len <= 1)

proc pingPongAb(a: App): bool =
  ## Repeat > Ping-Pong on the A-B loop: back and forth between A and B.
  a.cfg.repeatPingPong and a.abLoop and a.loopReady and not a.synced

proc applyLoop(a: App) =
  a.player.h.setProp("loop-file",
    if a.cfg.repeatForever and a.cfg.repeatMode == rmFile and not a.pingPongFile: "inf"
    else: "no")

proc applyAbLoop(a: App) =
  a.sbPlayingB = NaN  # seamless loops: set again from this
  if a.isSlave:  # the master's loop rules; following sets it
    a.followAbSet = ""
    return
  let on = a.abLoop and a.loopReady and not a.pingPongAb
  for (prop, t) in [("ab-loop-a", a.loopA), ("ab-loop-b", a.loopB)]:
    if on: a.player.h.setProp(prop, t) else: a.player.h.setProp(prop, "no")

proc clearLoopMarks(a: App) =
  a.hasLoopA = false
  a.hasLoopB = false
  a.abLoop = false
  a.applyAbLoop()

proc setLoopMark(a: App, isB: bool, t: float) =
  ## Sets mark A or B; marks placed out of order swap roles. Completing the
  ## pair starts the loop.
  let had = a.loopReady
  if isB: (a.loopB, a.hasLoopB) = (t, true)
  else: (a.loopA, a.hasLoopA) = (t, true)
  if a.hasLoopA and a.hasLoopB and a.loopA > a.loopB: swap(a.loopA, a.loopB)
  if a.loopReady and not had: a.abLoop = true
  a.applyAbLoop()
  a.osd((if isB: "Loop B: " else: "Loop A: ") & fmtTime(t, a.cfg.showMillis, a.player.duration))

proc unsetLoopMark(a: App, isB: bool) =
  ## Removes mark A or B, which also ends the loop.
  if isB: a.hasLoopB = false else: a.hasLoopA = false
  a.abLoop = false
  a.applyAbLoop()
  a.osd(if isB: "Loop B unset" else: "Loop A unset")

proc savePosition(a: App) =
  ## Remembers where the current file was left off; finished (or barely
  ## started) files are forgotten.
  let p = a.player
  if not a.cfg.rememberTime or not p.loaded or p.path.len == 0 or p.duration <= 0: return
  a.savedPos = p.timePos
  # Reloaded first so positions other players remembered meanwhile survive.
  a.positions = loadPositions()
  if p.timePos > 5 and p.timePos < p.duration - 5 and not p.eofReached:
    a.positions.remember(p.path, p.timePos)
  else:
    a.positions.del(p.path)
  a.positions.save()

proc listedLinks(a: App): seq[string] =
  ## The playlist's YouTube links fully listed: their videos are its entries,
  ## not to be added again next run.
  a.playlist.filterIt(it in a.ytListed and not (a.ytList.running and a.ytList.url == it))

proc rememberState(a: App) =
  ## Copies the state kept between runs (volume, window, pan/rotate/scale,
  ## playlist) into the config.
  a.cfg.volume = a.player.volume
  a.cfg.muted = a.player.muted
  a.cfg.transform = SavedTransform(panX: a.xf.pan.x, panY: a.xf.pan.y,
    rotation: a.xf.rotation, zoom: a.xf.zoom, scaleX: a.xf.scaleX, scaleY: a.xf.scaleY)
  if not a.fullscreen and not a.window.maximized and not a.window.minimized:
    let (pos, size) = (a.window.framePos, a.window.size)
    (a.cfg.windowX, a.cfg.windowY, a.cfg.windowW, a.cfg.windowH) =
      (pos.x.int, pos.y.int, size.x.int, size.y.int)
  if a.cfg.rememberPlaylist:
    a.cfg.playlist = a.playlist
    a.cfg.playlistIndex = if a.plIndex >= 0: a.plIndex else: a.plSelected
    a.cfg.playlistTitles.clear()
    for f in a.playlist:
      if f in a.linkTitles: a.cfg.playlistTitles[f] = a.linkTitles[f]
    a.cfg.playlistListed = a.listedLinks
  else:
    (a.cfg.playlist, a.cfg.playlistIndex) = (newSeq[string](), -1)
    a.cfg.playlistTitles.clear()
    a.cfg.playlistListed.setLen 0
  discard a.cfg.reloadRecent()  # another player's changes
  proc titles(a: App): Table[string, string] =
    for r in a.cfg.recentFiles:
      let t = a.linkTitles.getOrDefault(r, a.cfg.recentTitles.getOrDefault(r))
      if t.len > 0: result[r] = t
  if a.titles != a.cfg.recentTitles:
    discard a.cfg.reloadRecent(force = true)  # on top of the latest list
    a.cfg.recentTitles = a.titles
    a.cfg.saveRecent()

proc autosave(a: App) =
  ## Saves the remembered state as it changes rather than only on exit, so
  ## a crash or a killed session loses at most a couple of seconds of it.
  let t = now()
  if t - a.autosaveAt < 2: return
  a.autosaveAt = t
  if a.player.loaded and abs(a.player.timePos - a.savedPos) >= 1:
    a.savePosition()
  # Options edits the config live until OK or Cancel; never persist those.
  if a.overlay == ovOptions: return
  a.rememberState()
  let j = a.cfg.toJson
  if j != a.savedCfg:
    a.cfg.save()
    a.savedCfg = j

proc isWebLink(path: string): bool =
  let l = path.toLowerAscii
  l.startsWith("http://") or l.startsWith("https://")

proc quoted(s: string): string = &"%{s.len}%{s}"  ## a per-file option's value, taken as it is

const
  SavedMin = 5.0  ## a link's saved part plays when this much of it is left

proc linkStart(url: string): float =
  ## Where a link says to start (t=1645s, t=27m25s, start=1645...), else 0.
  try:
    let u = parseUri(url)
    for part in [u.query, u.anchor]:
      for (k, v) in decodeQuery(part):
        if k notin ["t", "start"]: continue
        var (num, total) = ("", 0.0)
        for c in v:
          if c in {'0' .. '9', '.'}: num.add c
          elif c in {'h', 'm', 's'} and num.len > 0:
            total += parseFloat(num) * (if c == 'h': 3600.0 elif c == 'm': 60.0 else: 1.0)
            num = ""
          else: return 0
        if num.len > 0: total += parseFloat(num)
        return total
  except UriParseError, ValueError: discard

proc streamOpts(a: App, url: string): seq[string] =
  ## A link's stream, once its subtitles are saved: those, not the yt-dlp
  ## hook's (the same, numbered alike in its saved part and the stream).
  let s = a.saved.lookup(url)
  if s.subsDone and s.subs.len > 0: result.add "sub-files=" & quoted(s.subs.join($PathSep))

proc ytdlRaw(a: App, url: string): string =
  ## The yt-dlp hook's options for a link (all of them: per file, they stand
  ## in for the player's): no subtitles once they're saved (streamOpts), and
  ## the browser it signs in with when it asked to.
  let subsDone = a.saved.lookup(url).subsDone
  let cookies = a.ytCookies.getOrDefault(url)
  if not subsDone and cookies.len == 0: return
  var raw = @["sub-langs=" & quoted(if subsDone: "none" else: YtdlSubLangs), "no-playlist="]
  if cookies.len > 0: raw.add "cookies-from-browser=" & quoted(cookies)
  "ytdl-raw-options=" & quoted(raw.join(","))

proc qualitiesOf(a: App, url: string): tuple[known: bool, video, audio: seq[Quality]] =
  ## The qualities a link offers: as found this time, else as saved with it.
  if url in a.ytQualities:
    let q = a.ytQualities[url]
    return (true, q.video, q.audio)
  let s = a.saved.lookup(url)
  if s.videoOffers.len > 0 or s.audioOffers.len > 0: (true, s.videoOffers, s.audioOffers)
  else: (false, newSeq[Quality](), newSeq[Quality]())

proc audioRows(a: App, url: string): seq[Quality] =
  ## The link's audio qualities in the language it plays in, as the quality
  ## menu lists them: its own unless a dub is picked (and still offered).
  let all = a.qualitiesOf(url).audio
  if all.len == 0: return
  let lang = a.ytLang.getOrDefault(url, all[0].lang)
  result = all.filterIt(it.lang == lang)
  if result.len == 0: result = all.filterIt(it.lang == all[0].lang)

proc chosen(a: App, url: string): tuple[video, audio: string] =
  ## What the quality menu has for the link, video and audio, each: a format
  ## id; "~<lock>" for a locked quality while its formats aren't known; "" for
  ## Auto. The menu's picks come first ("auto": Auto), then its locks: video
  ## by label, audio by rank (AudioRanks).
  let pick = a.ytPick.getOrDefault(url)
  let q = a.qualitiesOf(url)
  proc one(p, lock: string, list: seq[Quality], video: bool): string =
    if p == "auto": return ""
    if p.len > 0: return p
    if lock.len == 0 or lock == "auto": return ""
    if not video and lock notin AudioRanks: return ""  # an older exact lock
    if not q.known: return "~" & lock
    if video:
      for x in list:
        if sameQuality(lock, x.label): return x.id
      ""  # not offered: Auto
    else:
      let row = rankRow(lock, list.len)
      if row >= 0: list[row].id else: ""
  (one(pick.video, a.cfg.streamLockVideo, q.video, true),
   one(pick.audio, a.cfg.streamLockAudio, a.audioRows(url), false))

proc wants(a: App, url: string): tuple[video, audio: string] =
  ## What the link streams in (chosen). Auto's audio is left to Options >
  ## Online but for language: yt-dlp knows no dub was picked, and its "wa" is
  ## any language's, so those are found among the language's own.
  result = a.chosen(url)
  let rows = a.audioRows(url)
  if result.audio.len > 0 or rows.len == 0: return
  let small = a.cfg.streamSmallAudio or a.cfg.streamQuality == sqLowest
  if small and audioLanguages(a.qualitiesOf(url).audio).len > 1: result.audio = rows[^1].id
  elif url in a.ytLang: result.audio = rows[0].id

proc picked(a: App, url: string): bool =
  ## The link doesn't stream in Auto, Auto (a pick or a lock).
  let w = a.wants(url)
  w.video.len > 0 or w.audio.len > 0

proc autoParts(a: App, url: string): tuple[video, audio: string] =
  ## Auto's video and audio format ids for the link, as each last played; "" unknown.
  result = a.ytAutoParts.getOrDefault(url)
  let s = a.saved.lookup(url)
  if result.video.len == 0: result.video = s.autoVideo
  if result.audio.len == 0: result.audio = s.autoAudio
  let full = s.auto.split('+')
  if full.len == 2:
    if result.video.len == 0: result.video = full[0]
    if result.audio.len == 0: result.audio = full[1]

proc linkFormat(a: App, url: string): string =
  ## The format ids the link's stream comes in, as picked or locked (Auto's
  ## as it last came to); "" while unknown.
  let w = a.wants(url)
  if not a.picked(url): return a.ytAuto.getOrDefault(url, a.saved.lookup(url).auto)
  if w.video.startsWith("~") or w.audio.startsWith("~"): return ""
  if w.video.len == 0 and a.cfg.streamQuality == sqAudioOnly: return w.audio
  let auto = a.autoParts(url)
  let v = if w.video.len > 0: w.video else: auto.video
  let au = if w.audio.len > 0: w.audio else: auto.audio
  if v.len > 0 and au.len > 0: v & "+" & au else: ""

proc streamFormat(a: App, url: string): string =
  ## yt-dlp's -f for a link: the quality menu's picks and locks, else Options > Online's.
  let w = a.wants(url)
  pickSpec(a.cfg, w.video, w.audio)

proc entry(a: App, url: string): var Saved = a.saved.mgetOrPut(url.linkKey, Saved())

proc savedIn(a: App, url: string): Saved =
  ## What's saved of the link in the format it streams in (linkFormat).
  let f = a.linkFormat(url)
  result = a.saved.lookup(url).inFormat(f)
  if f.len == 0 and a.picked(url): result.segs.setLen 0  # not knowing which

proc withRaw(a: App, url, opts: string): string =
  ## opts, the yt-dlp hook's options and the format picked (streamFormat).
  let raw = "ytdl-format=" & quoted(a.streamFormat(url)) &
    (let r = a.ytdlRaw(url); if r.len > 0: "," & r else: "")
  if raw.len == 0: opts elif opts.len == 0: raw else: opts & "," & raw

proc savedFile(a: App, url: string): string =
  ## The media cache's file holding all of the link, in the quality saves
  ## download (saveFormat); "" when none does.
  if a.cfg.streamOnSave: a.savedIn(url).wholeFile else: a.saved.lookup(url).wholeFile

proc saveFormat(a: App, url: string): string =
  ## yt-dlp's -f for File > Save and command lines: as the link streams, or the best.
  if a.cfg.streamOnSave: a.streamFormat(url) else: "bv*+ba/b"

proc streamLink(a: App, url: string, start: float, opts: string) =
  ## Streams a link (mpv's yt-dlp hook), noting how, to try again should it fail.
  let args = a.withRaw(url, opts)  # first: opts may be streamArgs' own (a retry)
  a.ytWatch = true
  a.streamArgs = (url, start, opts)
  a.streamPos = start
  a.player.load(url, start, false, args)

proc playSaved(a: App, url: string, start: float, part: tuple[start, stop: float],
               extra: seq[string] = @[]) =
  ## Plays a link's saved `part` (savedIn) from `start`, the stream to go on
  ## past it; `extra`: more per-file options.
  a.entry(url).used = epochTime()
  let s = a.savedIn(url)
  a.playFormat[url] = a.linkFormat(url)
  var opts = extra
  if s.chapters.len > 0 and fileExists(s.chapters): opts.add "chapters-file=" & quoted(s.chapters)
  if s.subs.len > 0: opts.add "sub-files=" & quoted(s.subs.join($PathSep))
  if s.title.len > 0: opts.add "force-media-title=" & quoted(s.title)
  a.ytWatch = false
  a.handoffFailed = false
  let edl = s.timeline(part.start, part.stop)
  if s.complete: a.player.load(url, start, false, opts.join(","), edl)
  else: a.player.load(url, start, false, opts.join(","), edl, part.start, part.stop, s.duration)

proc handoffOff(a: App)

proc youtubeList(url: string): string =
  ## The playlist id of a YouTube link (playlist?list=, or a video's with
  ## &list=), "" for anything else.
  let u = try: url.parseUri except UriParseError: return ""
  if u.youtubeHost notin ["youtube.com", "youtu.be"]: return
  for (k, v) in u.query.decodeQuery:
    if k == "list": result = v
  if not result.allCharsInSet(Letters + Digits + {'-', '_'}): result = ""

proc showYtdlp(a: App, mode: YtMode, msg = "")

proc selectOnly(a: App, i: int) =
  a.plSelected = i
  a.plMarks.setLen 0

proc plSelection(a: App): seq[int] =
  ## The selected entries, in playlist order.
  if a.plSelected notin 0 ..< a.playlist.len: return
  if a.plMarks.len == 0: @[a.plSelected]
  else: a.plMarks.filterIt(it < a.playlist.len)

proc plIsSelected(a: App, i: int): bool =
  if a.plMarks.len == 0: i == a.plSelected else: a.plMarks.binarySearch(i) >= 0

proc listYoutube(a: App, i: int): bool =
  ## Entry i is a YouTube playlist's link, or a video's with its list= id, not
  ## listed yet: the playlist's videos are looked up, joining around it as
  ## yt-dlp finds them (pollYtList); the video plays meanwhile. True for a
  ## playlist alone, whose first video plays in its place once found.
  let link = a.playlist[i]
  if link.youtubeList.len == 0 or link in a.ytListed: return
  result = link.youtubeId.len == 0
  if result:
    a.plIndex = i
    a.selectOnly(i)
  let exe = findYtdlp(a.cfg.ytdlp)
  if exe.len == 0:
    # A video streams (and asks for yt-dlp on its own); a playlist asks here.
    if result:
      a.ytUrl = link
      a.showYtdlp(ymInstall)
    return
  a.ytListed.incl link
  if a.ytList.running: a.ytList.stop()
  a.ytList = playlistItems(exe, link, a.ytCookies.getOrDefault(link))
  a.ytListUsed = 0
  a.ytListLast = ""
  if result:
    a.cfg.addRecent(link)
    a.osd("Loading playlist...")

proc playIndex(a: App, i: int, start = -1.0) =
  ## Plays entry i from `start`, or from where it was left off when negative.
  if i < 0 or i >= a.playlist.len: return
  if a.listYoutube(i): return
  a.savePosition()
  a.plIndex = i
  if a.cfg.playlistCursorFollows:
    a.selectOnly(i)
    a.plFollow = true
  let path = a.playlist[i]
  if not a.cfg.rememberTransform: a.xf = VideoTransform()
  a.resumedAt =
    if start >= 0: start
    elif a.cfg.rememberTime: a.positions.getOrDefault(path, 0.0)
    else: 0.0
  a.clearLoopMarks()
  a.subs.scale = a.subScales.getOrDefault(path, 1'f32)
  a.reopening = false  # another file instead
  if a.ytCaps.running and a.ytCaps.url != path:
    a.ytCaps.stop()
    a.ytCaps = nil
  a.ytError = ""
  a.ytRetry = ""
  a.ytTries = 0
  a.dropTries = 0
  a.netWasDown = false
  a.ytCookieTried.setLen 0
  a.stopOnLoad = false
  a.handoffOff()
  # A link played before: from disk, when saved where it starts.
  a.qualitySwitch = false
  let s = a.savedIn(path)
  let at = if a.resumedAt > 0 or not path.isWebLink: a.resumedAt else: path.linkStart
  let part = s.chainAt(at)
  if path.isWebLink and part.stop > part.start and
     (s.complete or part.stop - at >= SavedMin):
    a.playSaved(path, at, part)
  elif path.isWebLink:
    a.streamLink(path, a.resumedAt, a.streamOpts(path).join(","))
  else:
    a.ytWatch = false
    a.player.load(path, a.resumedAt, a.cfg.repeatPingPong and not path.contains("://"))
  a.applyLoop()
  a.cfg.addRecent(path)
  a.cfg.lastDir = path.parentDir
  a.updateTitle()

proc expandPaths(paths: seq[string]): seq[string] =
  ## Files and URLs as given; directories become their media files.
  for p in paths:
    if dirExists(p): result.add mediaFilesIn(p, isMediaFile)
    elif p.contains("://"): result.add p.withoutTracking
    elif fileExists(p): result.add p

proc openPaths(a: App, paths: seq[string]) =
  if a.editLocked: return
  let files = expandPaths(paths)
  if files.len == 0:
    a.osd("Nothing playable found")
    return
  a.playlist = files
  for f in files: a.ytListed.excl f  # opened anew: its videos aren't in here
  a.plScroll = 0
  a.playIndex(0)

proc saveResume(a: App) =
  ## What the player is doing, for it to restart into an update with.
  let p = a.player
  var r = ResumeState(playlist: a.playlist, index: (if p.loaded: a.plIndex else: -1),
    selected: a.plSelected, time: p.timePos, paused: p.paused, stopped: p.stopped,
    speed: p.speed, aid: p.selectedTrack("audio"), sid: p.selectedTrack("sub"),
    vid: p.selectedTrack("video"), loopA: a.loopA, loopB: a.loopB,
    hasLoopA: a.hasLoopA, hasLoopB: a.hasLoopB, abLoop: a.abLoop,
    windowX: a.cfg.windowX, windowY: a.cfg.windowY, windowW: a.cfg.windowW,
    windowH: a.cfg.windowH, maximized: a.window.maximized, fullscreen: a.fullscreen,
    transform: a.cfg.transform, listed: a.listedLinks)
  for f in a.playlist:
    if f in a.linkTitles: r.titles[f] = a.linkTitles[f]
  # A link's captions come back by themselves (addCaptions).
  for t in p.tracks:
    if t.external and t.kind in ["sub", "audio"] and not t.file.contains("://"):
      r.tracks.add (t.kind, t.file)
  r.save()

proc resumeState(a: App, r: ResumeState) =
  ## The playlist and its file as they were before restarting into an
  ## update: where it was, paused or stopped as it was (its tracks and loop
  ## once it opens).
  a.playlist = r.playlist.filterIt(fileExists(it) or it.contains("://"))
  a.linkTitles = r.titles
  a.ytListed = r.listed.toHashSet
  if r.fullscreen: a.setFullscreen(true)
  let at = if r.index in 0 ..< r.playlist.len: a.playlist.find(r.playlist[r.index]) else: -1
  if at < 0:
    if r.selected in 0 ..< r.playlist.len: a.plSelected = a.playlist.find(r.playlist[r.selected])
    return
  a.resume = r
  a.resuming = true
  a.playIndex(at, r.time)
  if r.paused or r.stopped: a.player.h.setProp("pause", true)

proc closeFile(a: App) =
  if a.editLocked: return
  a.savePosition()
  a.handoffOff()
  a.clearLoopMarks()
  a.player.close()
  a.preview.forget()
  a.playlist.setLen 0
  a.plIndex = -1
  a.selectOnly(-1)
  a.updateTitle()

proc onWayland(): bool =
  getEnv("WAYLAND_DISPLAY").len > 0 and findExe("wl-copy").len > 0 and
    findExe("wl-paste").len > 0

proc fileUri(path: string): string =
  result = "file://"
  for part in path.absolutePath.split('/'):
    if part.len > 0: result.add "/" & encodeUrl(part, usePlus = false)

proc copyToClipboard(a: App) =
  ## The opened file goes on the clipboard as a file (text/uri-list), so a
  ## file manager pastes the file itself; streams go as their URL.
  let path = a.player.path
  if not a.player.loaded or path.len == 0: return
  when defined(windows):
    if not path.contains("://"):
      a.window.setClipboardFile(path.absolutePath)
      a.osd("Copied " & path.extractFilename)
      return
  if path.contains("://"):
    setClipboardString(path)
    a.osd("Copied URL")
    return
  if not onWayland():
    setClipboardString(path)
  else:
    try:
      let p = startProcess("wl-copy", args = @["--type", "text/uri-list"],
        options = {poUsePath})
      p.inputStream.write(path.fileUri & "\r\n")
      p.inputStream.close()
      discard p.waitForExit(2000)
      p.close()
    except OSError:
      setClipboardString(path)
  a.osd("Copied " & path.extractFilename)

proc copyTimeLink(a: App) =
  ## The YouTube link with the current position, so it opens right here.
  if not a.player.loaded or a.plIndex notin 0 ..< a.playlist.len: return
  let id = a.playlist[a.plIndex].youtubeId
  if id.len == 0:
    a.osd("Not a YouTube video")
    return
  let t = max(0, a.player.timePos.int)
  setClipboardString("https://www.youtube.com/watch?v=" & id & "&t=" & $t & "s")
  a.osd("Copied link at " & fmtTime(t.float, dur = a.player.duration))

proc looksLikeAddress(s: string): bool =
  ## "www.example.com/watch?v=..." or "youtu.be/...": a host, then a path.
  let host = s.split('/')[0]
  let dot = host.rfind('.')
  '/' in s and ' ' notin s and dot > 0 and host.len - dot - 1 >= 2 and
    host[dot + 1 .. ^1].allCharsInSet(Letters) and
    host.allCharsInSet(Letters + Digits + {'.', '-'})

proc pathOrLink(line: string): string =
  ## A pasted or dropped line as a path or link: file:// URIs become paths,
  ## bare web addresses ("youtu.be/...") links, and a link amid other text
  ## (a dragged sentence) is picked out; "" for blanks and comments.
  var e = strutils.strip(line, chars = Whitespace + {'"', '\''})
  if e.contains("://") and e.contains(' '):
    for word in strutils.splitWhitespace(e):
      if word.contains("://"):
        e = strutils.strip(word, chars = {'"', '\'', '<', '>', '(', ')', ','})
        break
  if e.len == 0 or e.startsWith("#"): ""
  elif e.toLowerAscii.startsWith("file://"): decodeUrl(e.parseUri.path, false)
  elif e.contains("://"): e
  elif not fileExists(e.expandTilde) and not dirExists(e.expandTilde) and e.looksLikeAddress:
    "https://" & e  # for yt-dlp
  else: e.expandTilde

proc clipboardPaths(a: App): seq[string] =
  ## Files and URLs on the clipboard: a file manager's text/uri-list (on
  ## Windows, Explorer's file list), or plain text holding paths or URLs, one
  ## per line.
  when defined(windows):
    result = a.window.clipboardFiles()
    if result.len > 0: return
  var text = ""
  if onWayland():
    # Listing types never asks the owner for data, so this cannot stall on
    # our own X selection; only a uri-list (never ours) is then fetched.
    let (types, code) = execCmdEx("wl-paste --list-types")
    if code == 0 and "text/uri-list" in types.splitLines:
      let (uris, code2) = execCmdEx("wl-paste --no-newline --type text/uri-list")
      if code2 == 0: text = uris
  if text.len == 0: text = getClipboardString()
  for line in text.splitLines:
    let p = pathOrLink(line)
    if p.len > 0: result.add p

proc openFromClipboard(a: App) =
  if a.editLocked: return
  let paths = a.clipboardPaths()
  if paths.len == 0:
    a.osd("Clipboard has no file to open")
    return
  a.openPaths(paths)

proc reopenLast(a: App): bool =
  ## With nothing loaded, Play starts the selected playlist entry, or else
  ## reopens the most recently opened file.
  if a.player.loaded: return false
  if a.playlist.len > 0:
    a.playIndex(max(a.plSelected, 0))
    return true
  if a.playlistLocked: return false
  for r in a.cfg.recentFiles:
    if fileExists(r) or r.contains("://"):
      a.openPaths(@[r])
      return true

proc padRunning(a: App): bool = a.padLen > 0 and not a.padHeld

proc padElapsed(a: App): float =
  if a.padHeld: a.padAt else: now() - a.padAt

proc padHold(a: App, on: bool) =
  if on != a.padHeld:
    a.padAt = now() - a.padAt
    a.padHeld = on

proc play(a: App) =
  if a.padLen > 0:
    a.padHold(false)
    return
  if a.reopenLast(): return
  if a.slaveDo("play"): return
  let restart = a.player.eofReached  # Play at the end starts over
  a.player.play()
  if restart: a.syncSend("seek", "0", "true")
  a.syncSend("play")

proc pause(a: App) =
  if a.padLen > 0:
    a.padHold(true)
    return
  if a.slaveDo("pause", $a.masterNow): return
  a.player.pause()
  a.syncSend("pause", $a.player.timePos)

proc stop(a: App) =
  if a.slaveDo("stop"): return
  a.player.stop()
  a.syncSend("stop")

proc togglePlay(a: App) =
  let p = a.player
  if not p.loaded: return
  if a.padLen > 0: a.padHold(not a.padHeld)
  elif p.stopped or p.eofReached or p.paused: a.play()
  else: a.pause()

proc playPause(a: App) =
  if not a.reopenLast(): a.togglePlay()

proc seekTo(a: App, t: float, exact = true) =
  if a.padLen > 0 and t >= a.player.duration: return  # already there, waiting
  if a.slaveDo("seek", $(t + a.followOffset), $exact): return
  a.player.stopped = false
  a.player.seek(a.clampTime(t), exact)
  a.syncSend("seek", $t, $exact)

proc folderNeighbor(a: App, dir: int): string =
  if a.player.path.len == 0 or not fileExists(a.player.path): return
  let files = mediaFilesIn(a.player.path.parentDir, isMediaFile)
  let i = files.find(a.player.path.absolutePath)
  let j = (if i < 0: files.find(a.player.path) else: i) + dir
  if j >= 0 and j < files.len: files[j] else: ""

proc navigateLocal(a: App, dir: int) =
  ## Previous/next: walks the playlist, or the folder when it is the sole item.
  if a.playlist.len > 1:
    var j = a.plIndex + dir
    if j < 0 or j >= a.playlist.len:
      if a.cfg.repeatForever and a.cfg.repeatMode == rmPlaylist:
        j = (j + a.playlist.len) mod a.playlist.len
      else: return
    a.playIndex(j)
  else:
    let f = a.folderNeighbor(dir)
    if f.len > 0:
      a.playlist = @[f]
      a.playIndex(0)
    else:
      a.osd(if dir > 0: "Last file in folder" else: "First file in folder")

proc navigate(a: App, dir: int) =
  # Each player has its own file; the folder step would rewrite a locked playlist.
  if not a.editLocked: a.navigateLocal(dir)

# --- playlist editing -------------------------------------------------------

proc addToPlaylist(a: App, paths: seq[string], at = -1) =
  ## Inserts at `at` (appends when out of range) without touching playback;
  ## starts playing them when nothing is open.
  if a.editLocked: return
  let files = expandPaths(paths)
  if files.len == 0:
    a.osd("Nothing playable found")
    return
  let first = if at < 0 or at > a.playlist.len: a.playlist.len else: at
  a.playlist.insert(files, first)
  if a.plIndex >= first: a.plIndex += files.len
  if a.plSelected >= first: a.plSelected += files.len
  for m in a.plMarks.mitems:
    if m >= first: m += files.len
  if not a.player.loaded: a.playIndex(first)
  else: a.osd(if files.len == 1: "Added to playlist" else: &"Added {files.len} files to playlist")

proc removeSelected(a: App) =
  if a.editLocked: return
  let sel = a.plSelection
  if sel.len == 0: return
  for i in countdown(sel.high, 0): a.playlist.delete(sel[i])
  if a.plIndex in sel: a.plIndex = -1
  else: a.plIndex -= sel.countIt(it < a.plIndex)
  a.selectOnly(min(sel[0], a.playlist.len - 1))

proc reorderPlaylist(a: App, order: seq[int]) =
  ## order[new position] = old index; the playing and selected entries follow.
  if a.editLocked: return
  let old = a.playlist
  var cur, sel = -1
  var marks: seq[int]
  for i, j in order:
    a.playlist[i] = old[j]
    if j == a.plIndex: cur = i
    if j == a.plSelected: sel = i
    if a.plMarks.binarySearch(j) >= 0: marks.add i
  a.plIndex = cur
  a.plSelected = sel
  a.plMarks = marks
  a.plReveal = true

type PlaylistMove = enum pmTop, pmUp, pmDown, pmBottom

proc canMove(a: App, up: bool): bool =
  ## Whether the selection is not already a block at that end.
  let sel = a.plSelection
  sel.len > 0 and (if up: sel[^1] != sel.high else: sel[0] != a.playlist.len - sel.len)

proc moveSelected(a: App, move: PlaylistMove) =
  ## The selected entries, in their order, one step or to an end; a block
  ## already at the edge stays put while the rest catch up.
  let sel = a.plSelection
  if sel.len == 0: return
  let n = a.playlist.len
  var picked = newSeq[bool](n)
  for i in sel: picked[i] = true
  var order = toSeq(0 ..< n)
  case move
  of pmTop: order = sel & order.filterIt(not picked[it])
  of pmBottom: order = order.filterIt(not picked[it]) & sel
  of pmUp:
    for i in 1 ..< n:
      if picked[order[i]] and not picked[order[i - 1]]: swap(order[i], order[i - 1])
  of pmDown:
    for i in countdown(n - 2, 0):
      if picked[order[i]] and not picked[order[i + 1]]: swap(order[i], order[i + 1])
  a.reorderPlaylist(order)

proc duplicateSelected(a: App) =
  ## Copies of the selected entries go right after the last one and become
  ## the selection.
  if a.editLocked: return
  let sel = a.plSelection
  if sel.len == 0: return
  let at = sel[^1] + 1
  a.playlist.insert(sel.mapIt(a.playlist[it]), at)
  if a.plIndex >= at: a.plIndex += sel.len
  a.plSelected = at + max(0, sel.find(a.plSelected))
  a.plMarks = if sel.len > 1: toSeq(at ..< at + sel.len) else: @[]
  a.plReveal = true

proc selectAll(a: App) =
  if a.playlist.len == 0: return
  if a.plSelected notin 0 ..< a.playlist.len: a.plSelected = 0
  a.plMarks = toSeq(0 ..< a.playlist.len)

proc playlistKeys(a: App): bool =
  ## Ctrl+A, Ctrl+D and Ctrl+Shift+Up/Down/Home/End while the playlist has
  ## the focus, and Up/Down while the pointer stays where it clicked (plArrows);
  ## true when one was taken.
  let w = a.window
  let pressed = w.buttonPressed
  if a.plArrows and a.cfg.showPlaylist and not a.playlistLocked and a.playlist.len > 0 and
      not (w.ctrl or w.alt or w.shiftDown) and (pressed[KeyUp] or pressed[KeyDown]):
    let step = if pressed[KeyUp]: -1 else: 1
    a.selectOnly(clamp(a.plSelected + step, 0, a.playlist.high))
    a.plReveal = true
    return true
  if not (a.plFocused and a.cfg.showPlaylist) or a.playlistLocked or not w.ctrl or w.alt:
    return
  result = true
  if w.shiftDown:
    if pressed[KeyUp]: a.moveSelected(pmUp)
    elif pressed[KeyDown]: a.moveSelected(pmDown)
    elif pressed[KeyHome]: a.moveSelected(pmTop)
    elif pressed[KeyEnd]: a.moveSelected(pmBottom)
    else: result = false
  elif pressed[KeyA]: a.selectAll()
  elif pressed[KeyD]: a.duplicateSelected()
  else: result = false

proc probeInfo(a: App, path: string): MediaInfo =
  ## Duration and video size, probed once per file (streams are not probed).
  if path in a.mediaInfo: return a.mediaInfo[path]
  if not path.contains("://"):
    if a.prober == nil: a.prober = newProber()
    result = a.prober.probe(path)
  a.mediaInfo[path] = result

proc fileSize(a: App, path: string): int64 =
  ## Size in bytes, read once per file; -1 for streams and unreadable files.
  if path in a.fileSizes: return a.fileSizes[path]
  result = -1
  if not path.contains("://"):
    try: result = getFileSize(path)
    except OSError: discard
  a.fileSizes[path] = result

proc probeNext(a: App, visible: Slice[int]) =
  ## Starts the background probe of the next file the playlist columns need,
  ## visible rows first; releases the prober's file once all are known.
  if a.prober != nil and a.prober.pending.len > 0: return
  var next = ""
  for i in visible:
    let p = a.playlist[i]
    if not p.contains("://") and p notin a.mediaInfo: next = p; break
  if next.len == 0:
    for p in a.playlist:
      if not p.contains("://") and p notin a.mediaInfo: next = p; break
  if next.len == 0:
    a.prober.finish()
    return
  if a.prober == nil: a.prober = newProber()
  if a.prober != nil: a.prober.start(next)

proc noteLink(a: App, url: string, title = "", m = MediaInfo(), looked = false) =
  ## Keeps what was found out about a link in the media cache.
  let e = a.linkInfos.mgetOrPut(url.linkKey, LinkInfo()).addr
  if title.len > 0: e.title = title
  if m.duration > 0: e.duration = m.duration
  if m.width > 0 and m.height > 0: (e.width, e.height) = (m.width, m.height)
  if m.audioBitrate > 0: e.audioBitrate = m.audioBitrate
  e.looked = e.looked or looked
  e.noted = epochTime()
  a.linkInfosChanged = true

proc saveLinkInfos(a: App) =
  if a.linkInfosChanged:
    a.linkInfos.save()
    a.linkInfosChanged = false

proc readLinkInfos(a: App) =
  ## Gives new playlist entries what the media cache has of their links, by
  ## video id however they're spelled; those it has all of aren't looked up.
  for p in a.playlist:
    if a.linkInfosRead.containsOrIncl(p) or not p.isWebLink: continue
    let (c, s) = (a.linkInfos.lookup(p), a.saved.lookup(p))
    let title = if c.title.len > 0: c.title else: s.title
    if title.len > 0 and p notin a.linkTitles: a.linkTitles[p] = title
    let m = a.mediaInfo.mgetOrPut(p, MediaInfo()).addr
    if m.duration <= 0: m.duration = if c.duration > 0: c.duration else: s.duration
    if m.width == 0: (m.width, m.height) = (c.width, c.height)
    if m.audioBitrate == 0: m.audioBitrate = c.audioBitrate
    if c.looked and m.duration > 0 and p in a.linkTitles: a.ytInfoTried.incl p

proc infoNext(a: App, visible: Slice[int]) =
  ## Starts looking up the titles, durations and sizes of the YouTube videos
  ## the playlist columns lack (a playlist's listing has no sizes), a few at
  ## a time, visible rows first.
  const Batch = 8
  if a.ytInfo.running: return
  a.readLinkInfos()
  let wantSize = pfDimensions in a.cfg.playlistColumns
  let wantBitrate = pfAudioBitrate in a.cfg.playlistColumns
  var links: seq[string]
  let need = proc (p: string): bool =
    if p in a.ytInfoTried or p in links or p.youtubeId.len == 0: return false
    let m = a.mediaInfo.getOrDefault(p)
    m.duration <= 0 or p notin a.linkTitles or (wantSize and m.width == 0) or
      (wantBitrate and m.audioBitrate == 0)
  for i in visible:
    if links.len < Batch and need(a.playlist[i]): links.add a.playlist[i]
  for p in a.playlist:
    if links.len < Batch and need(p): links.add p
  if links.len == 0: return
  let exe = findYtdlp(a.cfg.ytdlp)
  if exe.len == 0: return
  for p in links: a.ytInfoTried.incl p
  a.ytInfoLinks = links
  a.ytInfo = videoInfos(exe, links, a.ytCookies.getOrDefault(links[0]))

proc pollYtInfo(a: App) =
  ## Collects what was found so far, keeps it and redraws to show it.
  let j = a.ytInfo
  if j == nil or not j.poll(): return
  a.dirtyUntil = max(a.dirtyUntil, now() + 0.05)
  for (id, dur, w, h, abr, title) in j.infos:
    for p in a.ytInfoLinks:
      if p.youtubeId != id: continue
      var m = a.mediaInfo.mgetOrPut(p, MediaInfo()).addr
      if dur > 0: m.duration = dur
      if w > 0 and h > 0: (m.width, m.height) = (w, h)
      if abr > 0: m.audioBitrate = abr
      if title.len > 0 and p notin a.linkTitles: a.linkTitles[p] = title
      a.noteLink(p, title, m[], looked = true)
  j.infos.setLen 0
  if not j.running: a.ytInfo = nil

proc pollProbe(a: App) =
  ## Collects a finished background probe and redraws to show it.
  if a.prober == nil or a.prober.pending.len == 0: return
  let path = a.prober.pending
  if a.prober.poll():
    a.mediaInfo[path] = a.prober.info
    a.dirtyUntil = max(a.dirtyUntil, now() + 0.05)

proc rowName(a: App, path: string): string =
  ## A playlist row's name: a link's title when known, else the file's.
  if a.ytList.running and a.ytList.url == path and path.youtubeId.len == 0:
    "Loading playlist..."
  elif path in a.linkTitles: a.linkTitles[path]
  elif path.isWebLink and a.saved.lookup(path).title.len > 0: a.saved.lookup(path).title
  elif a.mediaInfo.getOrDefault(path).title.len > 0: a.mediaInfo[path].title
  else: path.extractFilename

proc sortPlaylist(a: App, by: PlaylistField) =
  ## Sorts ascending, or descending when already in ascending order.
  if a.editLocked: return
  let n = a.playlist.len
  if n < 2: return
  var keys = newSeq[(float, float)](n)
  var names = newSeq[string](n)
  for i, p in a.playlist:
    case by
    of pfFilename: names[i] = p.extractFilename
    of pfSize: keys[i] = (a.fileSize(p).float, 0.0)
    of pfName, pfDuration, pfDimensions, pfAudioBitrate, pfTrack, pfArtist, pfYear, pfAlbum:
      let m = a.probeInfo(p)
      case by
      of pfName: names[i] = a.rowName(p)
      of pfArtist: names[i] = m.artist
      of pfAlbum: names[i] = m.album
      of pfDuration: keys[i] = (m.duration, 0.0)
      of pfDimensions: keys[i] = (float(m.width * m.height), m.width.float)
      of pfAudioBitrate: keys[i] = (m.audioBitrate, 0.0)
      of pfTrack: keys[i] = (m.track.float, 0.0)
      of pfYear: keys[i] = (m.year.float, 0.0)
      else: discard
  if by notin {pfFilename, pfSize}: a.prober.finish()
  let byName = by in {pfName, pfFilename, pfArtist, pfAlbum}
  let byKey = proc (i, j: int): int =
    if byName: naturalCmp(names[i], names[j]) else: cmp(keys[i], keys[j])
  let ascending = (0 ..< n - 1).toSeq.allIt(byKey(it, it + 1) <= 0)
  var order = toSeq(0 ..< n)
  order.sort(byKey, if ascending: Descending else: Ascending)
  a.reorderPlaylist(order)

proc clearPlaylist(a: App) =
  ## Empties the playlist; the open file keeps playing.
  if a.editLocked: return
  a.playlist.setLen 0
  a.plIndex = -1
  a.selectOnly(-1)
  a.plScroll = 0

proc randomizePlaylist(a: App) =
  var order = toSeq(0 ..< a.playlist.len)
  order.shuffle()
  a.reorderPlaylist(order)

proc spawn(a: App, cmd: string, args: varargs[string]) =
  if findExe(cmd).len == 0:
    stderr.writeLine "not found: ", cmd
    return
  # poDaemon: no console window flashes up on Windows.
  const opts = when defined(windows): {poUsePath, poParentStreams, poDaemon}
               else: {poUsePath, poParentStreams}
  try:
    a.children.add startProcess(cmd, args = @args, options = opts)
  except OSError as e:
    stderr.writeLine "cannot run ", cmd, ": ", e.msg

proc showInFolder(a: App, path: string) =
  ## Opens the file manager on path's folder with the file selected.
  if path.contains("://"): return
  let path = path.absolutePath
  when defined(windows):
    a.spawn("explorer.exe", "/select," & path)
  else:
    # FileManager1 (Dolphin, Nautilus, ...) selects the file; else just open the folder.
    if findExe("dbus-send").len > 0 and execCmdEx("dbus-send --session --print-reply " &
        "--dest=org.freedesktop.FileManager1 /org/freedesktop/FileManager1 " &
        "org.freedesktop.FileManager1.ShowItems array:string:" & quoteShell(path.fileUri) &
        " string:").exitCode == 0:
      return
    a.spawn("xdg-open", path.parentDir)

proc openFolder(a: App, dir: string) =
  ## Opens the file manager on dir, made first should it not be there.
  try: createDir(dir)
  except OSError: discard
  when defined(windows): a.spawn("explorer.exe", dir)
  else: a.spawn("xdg-open", dir)

when defined(windows):
  proc runPowerAction(a: App) =
    case a.afterPlayback
    of apMonitorOff: a.window.monitorOff()
    of apSleep, apHibernate:
      if not suspend(a.afterPlayback == apHibernate):
        a.osd("Windows refused to " &
          (if a.afterPlayback == apSleep: "sleep" else: "hibernate"))
    of apShutdown: a.spawn("shutdown", "/s", "/t", "0")
    of apLogOff: a.spawn("shutdown", "/l")
    of apLock: lockSession()
    else: discard
else:
  proc runPowerAction(a: App) =
    case a.afterPlayback
    of apMonitorOff:
      if findExe("kscreen-doctor").len > 0: a.spawn("kscreen-doctor", "--dpms", "off")
      else: a.spawn("xset", "dpms", "force", "off")
    of apSleep: a.spawn("systemctl", "suspend")
    of apHibernate: a.spawn("systemctl", "hibernate")
    of apShutdown: a.spawn("systemctl", "poweroff")
    of apLogOff:
      if findExe("qdbus6").len > 0:
        a.spawn("qdbus6", "org.kde.Shutdown", "/Shutdown", "org.kde.Shutdown.logout")
      else:
        a.spawn("loginctl", "terminate-session", getEnv("XDG_SESSION_ID"))
    of apLock: a.spawn("loginctl", "lock-session")
    else: discard

proc runAfterPlayback(a: App) =
  case a.afterPlayback
  of apNothing: discard
  of apNextInFolder:
    let f = a.folderNeighbor(1)
    if f.len > 0:
      a.playlist = @[f]
      a.playIndex(0)
  of apExit: a.window.closeRequested = true
  else: a.runPowerAction()

proc afterEof(a: App) =
  if a.cfg.repeatForever and a.cfg.repeatMode == rmPlaylist and a.playlist.len > 0:
    if a.cfg.repeatPingPong and a.playlist.len > 1:
      # Ping-pong: back the other way from either end.
      if a.plIndex + a.plDir notin 0 ..< a.playlist.len: a.plDir = -a.plDir
      a.playIndex(clamp(a.plIndex + a.plDir, 0, a.playlist.len - 1))
    else: a.playIndex((a.plIndex + 1) mod a.playlist.len)
  elif a.plIndex + 1 < a.playlist.len:
    a.playIndex(a.plIndex + 1)
  else:
    a.runAfterPlayback()

proc shortAudioPad(a: App): float =
  ## Seconds of silence owed after this file: it is a very short audio file
  ## (Options > Audio Files) and the end of it goes on to another item.
  let p = a.player
  if not a.cfg.shortAudioDelay or not p.loaded or p.hasRealVideo or p.duration <= 0 or
     p.duration * 1000 >= a.cfg.shortAudioMs: return
  if p.partEnd > 0 or a.pingPongFile or a.abLoop or a.playlistLocked: return
  if a.cfg.repeatForever and a.cfg.repeatMode == rmFile: return  # mpv loops it: no end
  let next = a.cfg.repeatForever and a.playlist.len > 0 or a.plIndex + 1 < a.playlist.len or
    a.afterPlayback == apNextInFolder and a.folderNeighbor(1).len > 0
  if next: a.cfg.shortAudioMs / 1000 else: 0

proc tickPad(a: App) =
  ## The delay after a short file: over, or called off by leaving the end.
  if a.padLen == 0: return
  let p = a.player
  if not (p.loaded and p.eofReached and not p.stopped):
    # Sought away: mpv paused itself at the end, the delay was still playing.
    if p.loaded and not p.stopped and not p.opening and not a.padHeld:
      p.h.setProp("pause", false)
    a.padLen = 0
    a.padHeld = false
  elif a.padElapsed >= a.padLen:
    a.padLen = 0
    a.afterEof()
  else: a.dirtyUntil = max(a.dirtyUntil, now() + 0.05)  # the stripes filling

proc handleEof(a: App) =
  let p = a.player
  a.tickPad()
  if not (p.loaded and p.eofReached and not p.eofHandled and not p.stopped): return
  p.eofHandled = true
  if p.partEnd > 0:  # the end of a link's saved part: the stream goes on
    p.beyond = p.timePos
    return
  if a.pingPongFile or a.pingPongAb:  # at either end of the file: turn around
    p.setBackward(not p.backward)
    p.h.setProp("pause", false)
    return
  # A synchronized player's file may be shorter than the master's: it waits at
  # the end (clamped) until the group seeks back.
  if a.playlistLocked: return
  a.padLen = a.shortAudioPad
  if a.padLen > 0: a.padAt = now()
  else: a.afterEof()

proc volumeStep(a: App, up: bool) =
  ## Soft cap 100, hard cap 200: the volume step (default 5) below the soft
  ## cap, +2 above it, and the volume step down.
  let v = a.player.volume
  let st = a.cfg.volumeStep
  let nv =
    if up: (if v < 100: min(v + st, 100) else: min(v + 2, 200))
    else: max(v - st, 0)
  a.player.setVolume(nv)
  a.osd(&"Volume: {nv:g}%")

proc setMute(a: App, on: bool) =
  a.player.h.setProp("mute", on)
  a.osd(if on: "Mute" else: "Unmute")

proc changeRate(a: App, dir: float) =
  if not a.player.loaded: return
  let s = clamp(a.baseSpeed + dir * a.cfg.rateStep, 0.1, 100.0)  # 100 = mpv's own maximum
  a.player.h.setProp("speed", s)
  if a.isSlave: a.clock.speed = s
  a.syncSend("speed", $s)
  a.osd(&"Speed: {s:.2f}x")

proc pickLang(a: App, url, lang: string)

proc cycleTrack(a: App, kind: string, up: bool) =
  if a.player.loaded:
    if kind == "aid":
      # a link's languages are its audio tracks
      let langs = audioLanguages(a.qualitiesOf(a.player.path).audio)
      if a.player.path.isWebLink and langs.len > 1:
        let rows = a.audioRows(a.player.path)
        let cur = langs.mapIt(it.lang).find(rows[0].lang)
        let next = langs[(cur + (if up: 1 else: -1) + langs.len) mod langs.len]
        a.pickLang(a.player.path, next.lang)
        a.osd("Audio: " & next.langName)
        return
      # audio cycles through its tracks only, never landing on "no"
      var ids: seq[int]
      for t in a.player.tracks:
        if t.kind == "audio": ids.add t.id
      if ids.len == 0: return
      let cur = ids.find(a.player.selectedTrack("audio"))
      let next =
        if cur < 0: (if up: ids[0] else: ids[^1])
        else: ids[(cur + (if up: 1 else: -1) + ids.len) mod ids.len]
      if a.osdApart:
        a.player.h.setProp("aid", $next)
        a.player.expandText("aid: ${aid}")
      else:
        a.player.h.commandStr("osd-msg set aid " & $next)
      return
    if a.osdApart:
      a.player.h.commandStr("cycle " & kind & (if up: " up" else: " down"))
      # mpv's own message for it, shown by the OSD layer
      a.player.expandText(kind & ": ${" & kind & "}")
    else:
      a.player.h.commandStr("osd-msg cycle " & kind & (if up: " up" else: " down"))

proc setTrack(a: App, prop: string, id: int) =
  a.player.h.setProp(prop, if id <= 0: "no" else: $id)

proc frameStep(a: App, forward: bool) =
  if not a.player.loaded: return
  if a.isSlave and not a.syncQuiet:
    a.syncSend("frame", $forward)
    a.slaveFrame(forward)
    return
  a.player.stopped = false
  a.stepPlayer(forward)
  a.syncSend("frame", $forward)

proc seekRelative(a: App, d: float) =
  if a.player.loaded:
    if a.slaveDo("seek", $(a.masterNow + d), "false"): return
    a.player.stopped = false
    a.player.seekRelative(d)
    a.syncSend("seek", $(a.player.timePos + d), "false")

proc entryOf(a: App, path: string): string =
  ## The bookmarks key filed under path: an entry last seen there, or one
  ## written by an older version (keyed by path), else "".
  if path in a.bookmarks: return path
  for k, e in a.bookmarks:
    if e.path == path: return k

proc keyKnown(a: App, path, key: string) =
  ## Files the bookmarks found under path (older versions, or the contents
  ## changed) under key, and a moved file's bookmarks under its new path.
  (a.bmPath, a.bmKey) = (path, key)
  if key in a.bookmarks and a.bookmarks[key].path == path: return
  if key notin a.bookmarks and a.entryOf(path).len == 0: return
  a.bookmarks = loadBookmarks()
  if key notin a.bookmarks:
    let old = a.entryOf(path)
    if old.len == 0: return
    a.bookmarks[key] = a.bookmarks[old]
    a.bookmarks.del(old)
  a.bookmarks[key].path = path
  a.bookmarks.save()
  a.dirtyUntil = max(a.dirtyUntil, now() + 0.05)

proc pollMediaKey(a: App) =
  ## Starts working out the current file's key when it changes, and files
  ## its bookmarks under it once done.
  let path = if a.player.loaded: a.player.path else: ""
  if path.len > 0 and path != a.bmPath and path != a.bmPending:
    a.bmPending = path
    requestMediaKey(path)
  while true:
    let r = takeMediaKey()
    if not r.ok: break
    if r.path == a.bmPending:
      a.bmPending = ""
      a.keyKnown(r.path, r.key)

proc bookmarkKey(a: App, path: string): string =
  ## The key of path's bookmarks. Before the background mediaKey is done, the
  ## entry filed under the path (when there is one) stands in.
  if path == a.bmPath: a.bmKey
  else: a.entryOf(path)

proc fileBookmarks(a: App): seq[Bookmark] =
  if a.player.loaded: a.bookmarks.getOrDefault(a.bookmarkKey(a.player.path)).marks
  else: @[]

proc fileChapters(a: App): seq[Bookmark] =
  ## The current file's chapters, named as on the seek bar.
  if a.player.loaded:
    for i, c in a.player.chapters:
      result.add Bookmark(time: c.time, name: (if c.title.len > 0: c.title else: &"Chapter {i + 1}"))

proc timeChoices(a: App): seq[TimeChoice] =
  ## What the Run window's timestamp rows pick from, at the current time.
  timeChoices(a.player.timePos, a.player.duration,
    (if a.hasLoopA: a.loopA else: -1), (if a.hasLoopB: a.loopB else: -1),
    a.fileBookmarks, a.fileChapters)

proc chapterStep(a: App, d: int) =
  let p = a.player
  if not p.loaded: return
  var cur = -1
  for i, c in p.chapters:
    if c.time <= p.timePos + 0.01: cur = i
  # With bookmarks as chapters, a bookmark nearer than the chapter mpv would
  # land on wins. mpv never goes back past the current chapter's start.
  if a.cfg.bookmarksAsChapters:
    let marks = a.fileBookmarks
    var bi = -1
    if d > 0:
      let limit = if cur + 1 < p.chapters.len: p.chapters[cur + 1].time else: Inf
      for i, b in marks:
        if b.time > p.timePos + 0.05 and b.time < limit: bi = i; break
    else:
      let limit = if cur >= 0: p.chapters[cur].time else: -Inf
      for i in countdown(marks.high, 0):
        if marks[i].time < p.timePos - 0.5 and marks[i].time > limit: bi = i; break
    if bi >= 0:
      a.seekTo(marks[bi].time)
      a.osd(marks[bi].label(bi))
      return
  if p.chapters.len > 0:
    let j = cur + d
    if a.isSlave:  # the master's clock moves, not just this file
      if j >= 0 and j < p.chapters.len: a.seekTo(p.chapters[j].time)
      return
    inc p.jumps
    if a.osdApart:
      p.h.commandStr("add chapter " & $d)
      p.expandText("Chapter: ${chapter}")
    else:
      p.h.commandStr("osd-msg add chapter " & $d)
    # The others' files have chapters of their own: send where this one lands.
    if j >= 0 and j < p.chapters.len: a.syncSend("seek", $p.chapters[j].time, "true")

proc nearestBookmark(a: App, t: float): int =
  ## Index of the current file's bookmark closest to time t, else -1.
  result = -1
  var best = Inf
  for i, b in a.fileBookmarks:
    if abs(b.time - t) < best:
      best = abs(b.time - t)
      result = i

proc editBookmarks(a: App, path: string, edit: proc (marks: var seq[Bookmark])) =
  ## Applies `edit` to a file's bookmarks on the file's latest contents, so
  ## other players' bookmarks aren't overwritten.
  # Editing doesn't wait for the background key.
  if path != a.bmPath: a.keyKnown(path, mediaKey(path))
  let key = a.bmKey
  a.bookmarks = loadBookmarks()
  var e = a.bookmarks.getOrDefault(key)
  edit(e.marks)
  e.path = path
  if e.marks.len > 0: a.bookmarks[key] = e
  else: a.bookmarks.del(key)
  a.bookmarks.save()

proc addBookmark(a: App, t: float) =
  let p = a.player
  if not p.loaded or p.path.len == 0: return
  if a.fileBookmarks.anyIt(abs(it.time - t) < 0.05): return
  a.editBookmarks(p.path, proc (marks: var seq[Bookmark]) =
    var i = 0
    while i < marks.len and marks[i].time < t: inc i
    marks.insert(Bookmark(time: t), i))
  a.osd("Bookmark added at " & fmtTime(t, a.cfg.showMillis, a.player.duration))

proc removeBookmark(a: App, t: float) =
  ## Removes the current file's bookmark at time t.
  a.editBookmarks(a.player.path, proc (marks: var seq[Bookmark]) =
    for i, b in marks:
      if b.time == t:
        marks.delete(i)
        break)
  a.osd("Bookmark removed at " & fmtTime(t, a.cfg.showMillis, a.player.duration))

proc renameBookmark(a: App, path: string, t: float, name: string) =
  a.editBookmarks(path, proc (marks: var seq[Bookmark]) =
    for b in marks.mitems:
      if b.time == t: b.name = name)

proc moveBookmark(a: App, path: string, t, to: float): bool =
  ## Moves a file's bookmark at time t to time `to`, keeping them in order.
  ## False when another bookmark is already there.
  var moved = false
  a.editBookmarks(path, proc (marks: var seq[Bookmark]) =
    if marks.anyIt(it.time != t and abs(it.time - to) < 0.0005): return
    for i, b in marks:
      if b.time == t:
        var m = b
        m.time = to
        marks.delete(i)
        var j = 0
        while j < marks.len and marks[j].time < to: inc j
        marks.insert(m, j)
        moved = true
        break)
  a.dirtyUntil = max(a.dirtyUntil, now() + 0.1)  # the seek bar shows it now
  moved

proc eqMinGain(a: App): float = clamp(a.cfg.equalizerMinGain, EqMinGainLimit, -1)

proc bandGains(a: App, gains: seq[float]): seq[float] =
  ## One gain per equalizer band, in the sliders' range.
  result = newSeq[float](EqFreqs.len)
  for i in 0 ..< min(gains.len, result.len): result[i] = clamp(gains[i], a.eqMinGain, EqMaxGain)

proc eqKey(a: App): string =
  ## The current file's key among the saved equalizers: its mediaKey once
  ## known, the entry last seen at its path until then; "" without a file.
  let path = a.player.path
  if path.len == 0: return ""
  if path == a.bmPath: return a.bmKey
  for k, e in a.equalizers:
    if e.path == path: return k

proc eqSaved(a: App): bool =
  ## The current file has an equalizer saved for it.
  let k = a.eqKey
  k.len > 0 and k in a.equalizers

proc equalizer(a: App): tuple[on: bool, gains: seq[float]] =
  ## The equalizer heard: the one saved for the current file, else the
  ## settings'.
  let k = a.eqKey
  if k.len > 0 and k in a.equalizers: (a.equalizers[k].on, a.bandGains(a.equalizers[k].gains))
  else: (a.cfg.equalizerOn, a.bandGains(a.cfg.equalizerGains))

proc changeEqualizer(a: App, on: bool, gains: seq[float]) =
  ## Changes the equalizer heard; the file's saved one is written out once
  ## the change settles (syncEqualizer).
  a.eqChangedAt = now()
  let k = a.eqKey
  if k.len > 0 and k in a.equalizers:
    a.equalizers[k].on = on
    a.equalizers[k].gains = a.bandGains(gains)
    a.eqUnsaved = k
  else:
    (a.cfg.equalizerOn, a.cfg.equalizerGains) = (on, a.bandGains(gains))

proc saveEqualizer(a: App) =
  ## The file's changed equalizer written out, on the file's latest
  ## contents, so other players' entries aren't overwritten.
  let k = a.eqUnsaved
  a.eqUnsaved = ""
  if k notin a.equalizers: return
  let e = a.equalizers[k]
  a.equalizers = loadEqualizers()
  a.equalizers[k] = e
  a.equalizers.save()

proc rememberEqualizer(a: App, on: bool) =
  ## Saves the equalizer heard for the current file, which has it from then
  ## on (turned on or off as it is now), or forgets the file's: the
  ## settings take it as it is, so nothing changes to the ear.
  let path = a.player.path
  if path.len == 0: return
  let (eqOn, gains) = a.equalizer
  # Saving doesn't wait for the background key.
  if path != a.bmPath: a.keyKnown(path, mediaKey(path))
  let k = a.bmKey
  a.eqUnsaved = ""
  a.equalizers = loadEqualizers()
  if on:
    a.equalizers[k] = EqEntry(path: path, on: eqOn, gains: gains)
    a.osd("Equalizer saved for this media")
  else:
    a.equalizers.del(k)
    (a.cfg.equalizerOn, a.cfg.equalizerGains) = (eqOn, gains)
    a.osd("Equalizer no longer saved for this media")
  a.equalizers.save()

proc syncEqualizer(a: App) =
  ## The equalizer heard, onto the players. A slider on the move, or moved
  ## a moment ago, only goes to their running filters (Player.setEqualizer).
  let (on, gains) = a.equalizer
  let live = now() - a.eqChangedAt < EqSettle or
    a.eqUi != nil and a.eqUi.activeId.startsWith("eq-band")
  for p in [a.player, a.standby, a.lsound]:
    if p != nil: p.setEqualizer(on, gains, live)
  if not live and a.eqUnsaved.len > 0: a.saveEqualizer()

proc frameRate(a: App, path: string): float =
  ## The frame rate of the current file's video track, when path is that
  ## file; 0 when unknown.
  if path != a.player.path: return
  for tr in a.player.tracks:
    if tr.kind == "video" and tr.selected and not tr.albumArt and tr.fps > 0: return tr.fps

proc snapToFrame(a: App, path: string, t: float): float =
  ## Time t on the nearest frame of the current file's video track, when
  ## path is that file and its frame rate is known.
  let p = a.player
  result = if p.duration > 0 and path == p.path: clamp(t, 0, p.duration) else: max(t, 0)
  let fps = a.frameRate(path)
  if fps > 0:
    # The last frame starts before the end, so past it round down.
    result = round(result * fps) / fps
    if p.duration > 0 and result > p.duration: result = floor(p.duration * fps) / fps

proc xfChanged(a: App, msg: string) =
  a.osd(msg)

# --- synchronize: group and peer messages -----------------------------------

proc syncState(a: App): seq[string] =
  ## Where the master's playback is, for players joining the group.
  ## Its loop goes along, so slaves wrap when it does.
  let p = a.player
  var (la, lb) = (0.0, 0.0)
  if a.abLoop and a.loopReady: (la, lb) = (a.loopA, a.loopB)
  elif a.cfg.repeatForever and (a.cfg.repeatMode == rmFile or a.playlist.len <= 1):
    (la, lb) = (0.0, p.duration)
  @["state", $p.loaded, $p.posNow, $(p.paused or p.eofReached), $p.stopped, $p.speed,
    $la, $lb, $p.duration]

proc ownPlayback(a: App) =
  ## No longer a slave: our own looping is back, and the group's rate
  ## without following's nudge.
  if a.clock.known and a.player.loaded: a.player.h.setProp("speed", a.clock.speed)
  a.clock = MasterClock()
  a.followLoopSet = ""
  a.followAbSet = ""
  a.applyLoop()
  a.applyAbLoop()

proc setGroup(a: App, members: seq[int]) =
  ## Master (or a player about to become one): the new membership. Newcomers
  ## get where playback is; a group of one dissolves.
  let me = a.peers.pid
  let old = a.syncMembers
  let keep = if members.len > 1: members else: @[]
  for m in old:
    if m != me and m notin keep: a.peers.send(m, "group", "")
  let wasSlave = a.isSlave
  a.syncMembers = keep
  a.syncMaster = if keep.len > 0: me else: 0
  if wasSlave: a.ownPlayback()
  if keep.len == 0: return
  let list = keep.mapIt($it).join(",")
  for m in keep:
    if m == me: continue
    a.peers.send(m, "group", list)
    if m notin old: a.peers.send(m, a.syncState)

proc handleSyncRequest(a: App, op: string, pid: int) =
  ## Master: a membership change asked for here or by a member.
  let me = a.peers.pid
  var members = if a.synced: a.syncMembers else: @[me]
  case op
  of "all":
    for p in a.peers.peers:
      if p.pid notin members: members.add p.pid
  of "none": members.setLen 0
  of "add":
    if pid notin members and a.peers.find(pid) != nil: members.add pid
  of "remove": members.keepItIf(it != pid)
  a.setGroup(members)

proc syncRequest(a: App, op: string, pid = 0) =
  ## Membership changes go through the master; a player that isn't
  ## synchronized starts a group of its own.
  if a.peers == nil: return
  if a.synced and not a.isSyncMaster:
    a.peers.send(a.syncMaster, "request", op, $pid)
  else:
    a.handleSyncRequest(op, pid)

proc leftGroup(a: App) =
  ## No longer synchronized: our own repeat setting is back, the master's
  ## clock forgotten.
  a.syncMaster = 0
  a.syncMembers.setLen 0
  a.ownPlayback()

proc leaveGroup(a: App) =
  ## Before joining another group.
  if a.isSyncMaster: a.setGroup(@[])
  elif a.synced: a.peers.send(a.syncMaster, "request", "remove", $a.peers.pid)
  a.leftGroup()

proc joined(a: App) =
  ## Just joined a group: the playlist empties (and stays locked); the open
  ## file follows the master from where it is.
  a.playlist.setLen 0
  a.plIndex = -1
  a.selectOnly(-1)
  a.plScroll = 0
  a.clock = MasterClock()
  a.followRunning = a.player.playing
  a.followSought = NaN
  a.followFixAt = 0
  a.followLoopSet = ""
  a.followAbSet = ""
  a.followPrevT = 0
  a.followWrapped = false

proc setFollow(a: App, offset: float, loop: bool) =
  ## Our settings as a slave (Synchronize > Properties); the file is placed
  ## again right away.
  a.followOffset = max(offset, 0)
  a.followLoop = loop
  a.followSought = NaN
  a.followFixAt = 0

proc remotePlay(a: App) =
  ## Unlike Play here, doesn't restart a file that ended.
  let p = a.player
  if not p.loaded: return
  p.stopped = false
  p.h.setProp("pause", false)

proc setClock(a: App, loaded: bool, t: float, paused, stopped: bool, speed: float,
              loopA, loopB, dur: float) =
  ## Slave: the master's playback as it reported it.
  a.clock = MasterClock(known: true, loaded: loaded, playing: not paused and not stopped,
    stopped: stopped, t: t, at: now(), speed: (if speed > 0: speed else: 1.0),
    loopA: loopA, loopB: loopB, dur: dur)

proc followSpeed(a: App, nudge: float) =
  ## Slave: the group's rate, nudged to catch up.
  let s = a.clock.speed * nudge
  if abs(s - a.player.speed) > 0.0005: a.player.h.setProp("speed", s)

proc follow(a: App) =
  ## Slave: keeps our file where the master's clock puts it. Seeks while
  ## playing only on real drift (or a jump of the master), so both play on
  ## undisturbed.
  let p = a.player
  if not a.isSlave or not a.clock.known or not a.clock.loaded or not p.loaded or
     p.duration <= 0: return
  if a.clock.stopped:
    if not p.stopped:
      p.stop()
      a.followRunning = false
      a.followSought = 0
    return
  p.stopped = false
  let (t, run) = a.followTarget
  # mpv loops the file itself, without a seek's hitch.
  let loop = if a.followLoop and a.masterNow >= a.followOffset: "inf" else: "no"
  if loop != a.followLoopSet:
    a.followLoopSet = loop
    p.h.setProp("loop-file", loop)
  # The master's loop, in our time: where it fits our file, our player loops
  # natively, at the same moment as the master's.
  let c = a.clock
  let (la, lb) = (c.loopA - a.followOffset, c.loopB - a.followOffset)
  let ab = if c.loopB > c.loopA and la >= 0 and lb <= p.duration: $la & " " & $lb else: ""
  a.followAb = if ab.len > 0: (la, lb) else: (0.0, 0.0)
  if ab != a.followAbSet:
    a.followAbSet = ab
    a.sbPlayingB = NaN
    p.h.setProp("ab-loop-a", if ab.len > 0: $la else: "no")
    p.h.setProp("ab-loop-b", if ab.len > 0: $lb else: "no")
  # The master looped: our file jumps back with it right away, not on the
  # next drift check.
  let tnow = now()
  if run and a.followRunning and t < a.followPrevT - 0.35:
    a.followWrapped = true
    # A player stutters for a moment after jumping back, the master's known
    # here only from its next tick: no catching up on that. Seamless loops
    # (a standby taking over) don't stutter, and a short loop needs the time.
    a.followSettleAt = tnow + (if a.sbState == sbOff: 0.5 else: 0.0)
  a.followPrevT = t
  if run:
    if not a.followRunning:
      a.followRunning = true
      a.followSought = NaN
      a.followFixAt = tnow
      a.followWrapped = false
      a.followSpeed(1)
      p.seek(t)
      p.h.setProp("pause", false)
    elif not p.seeking:
      # How far ahead we are (behind: negative), across a loop's seam.
      var e = p.posNow - t
      let span = if a.followAbSet.len > 0: c.loopB - c.loopA
                 elif a.followLoop: p.duration
                 else: 0.0
      if span > 0: e -= span * round(e / span)
      if (tnow - a.followFixAt > 1 or a.followWrapped) and (abs(e) > 0.35 or p.paused):
        # drifted far, or the master jumped
        a.followFixAt = tnow
        a.followWrapped = false
        p.seek(t)
        p.h.setProp("pause", false)
      elif tnow - a.followFixAt > 0.5:
        # Small drift (each player's loop takes its own time to jump back,
        # decoders and outputs differ) is played off: a touch slower when
        # ahead, faster when behind, so it never adds up.
        a.followWrapped = false
        # Not while a seamless loop's standby runs up at our rate: it would
        # take over off by the change.
        if a.sbState != sbRolling:
          let nudge = if tnow < a.followSettleAt or abs(e) < 0.004: 1.0 else: 1 - clamp(round(e * 2, 3), -0.05, 0.05)
          a.followSpeed(nudge)
  else:
    if a.followRunning:
      a.followRunning = false
      p.pause()
    if t >= p.duration and p.eofReached: a.followSought = t  # on the last frame already
    if math.isNaN(a.followSought) or abs(t - a.followSought) > 0.0005:
      a.followSought = t
      p.seek(t)

proc syncTick(a: App) =
  ## Master: where playback is, to the slaves a few times a second, and right
  ## away when the file looped. Held back while an action is in flight.
  if not a.isSyncMaster: return
  let p = a.player
  let t = now()
  if t < a.clockHeldUntil or p.seeking: return
  if t - a.tickAt < 0.25 and p.timePos >= a.tickT - 0.5: return
  a.tickAt = t
  a.tickT = p.timePos
  for m in a.syncMembers:
    if m != a.peers.pid: a.peers.send(m, a.syncState)

proc handlePeerMessage(a: App, m: Message) =
  let f = m.fields
  let me = a.peers.pid
  template arg(i: int): string = (if i < f.len: f[i] else: "")
  template num(i: int): float =
    (try: parseFloat(arg(i)) except ValueError: 0.0)
  template flag(i: int): bool = arg(i) == "true"
  case f[0]
  of "group":
    let members = arg(1).split(',').filterIt(it.len > 0).mapIt(
      (try: parseInt(it) except ValueError: 0))
    if me in members:
      let isNew = a.syncMaster != m.sender
      if a.synced and isNew: a.leaveGroup()
      a.syncMaster = m.sender
      a.syncMembers = members
      if isNew: a.joined()
    elif a.syncMaster == m.sender:  # left the group, or it was dissolved
      a.leftGroup()
    return
  of "request":  # op pid
    # Members ask the master; Synchronize > Properties on any player asks
    # the master to be (or a slave's master) to take or let go of a player.
    let op = arg(1)
    if a.isSyncMaster and m.sender in a.syncMembers or
       op in ["add", "remove"] and not a.isSlave:
      a.handleSyncRequest(op, int(num(2)))
    return
  of "follow":  # offset loop: our settings as a slave, from any player's Properties
    a.setFollow(num(1), flag(2))
    return
  else: discard
  # Everything else only from our own group.
  if not a.synced or m.sender notin a.syncMembers: return
  if a.isSlave:  # all of it moves the master's clock; following does the rest
    case f[0]
    of "state":
      if m.sender == a.syncMaster and (not a.clock.known or now() >= a.clockHeldUntil):
        a.setClock(flag(1), num(2), flag(3), flag(4), num(5), num(6), num(7), num(8))
    of "play", "pause", "stop", "seek": a.clockAction(f)
    of "frame": a.slaveFrame(flag(1))
    of "speed":
      a.clockAction(f)
      if a.player.loaded: a.player.h.setProp("speed", num(1))
    else: discard
    return
  # Master: a slave's playback controls, in our time.
  a.clockHeldUntil = now() + 0.5
  a.quietly:
    case f[0]
    of "open":  # files launched on a member go into the master's playlist
      a.syncQuiet = false
      a.openPaths(f[1 .. ^1])
    of "play": a.remotePlay()
    of "pause":
      a.pause()
      a.seekTo(num(1))
    of "stop": a.stop()
    of "seek": a.seekTo(num(1), flag(2))
    of "frame": a.frameStep(flag(1))
    of "speed":
      if a.player.loaded: a.player.h.setProp("speed", num(1))
    else: discard

proc pollPeers(a: App): bool =
  ## Handles peer messages and lost peers; true when anything arrived.
  if a.peers == nil: return
  for m in a.peers.poll():
    result = true
    a.handlePeerMessage(m)
  for pid in a.peers.takeGone():
    result = true
    if pid == a.syncMaster:
      a.leftGroup()
      a.osd("Synchronization ended: the master player closed")
    elif a.isSyncMaster and pid in a.syncMembers:
      a.setGroup(a.syncMembers.filterIt(it != pid))
  a.syncTick()
  a.follow()
  a.peers.announce(a.player.path.extractFilename, a.syncMaster, a.followOffset, a.followLoop)

# --- seamless loops ---------------------------------------------------------
# Jumping back from a loop's B to its A is a seek, and a seek decodes from the
# keyframe before A: with keyframes far apart, picture and sound freeze for a
# moment every round. A second, hidden player (the standby) waits paused a
# little before A with that work done; shortly before B it starts playing,
# muted and unseen, and at B it takes over, the other one becoming the
# standby for the next round. mpv's own A-B loop stays set as the fallback.
# While the loop sound plays (loopSound), the takeovers keep time with it.

const
  StandbyPreroll = 0.2    ## how far before A the standby waits, media seconds
  StandbyMinLoop = 0.5    ## shorter loops jump the plain way

proc soundTarget(a: App): float

proc loopRegion(a: App): tuple[a, b: float] =
  ## The A-B loop the playing player is in, b = 0 when none: ours, or as a
  ## slave the master's (follow).
  if a.isSlave: a.followAb
  elif a.abLoop and a.loopReady and not a.pingPongAb: (a.loopA, a.loopB)
  else: (0.0, 0.0)  # a ping-pong loop turns around instead of jumping

proc mirrorStandby(a: App) =
  ## The playing player's settings and added tracks, onto the standby.
  ## Nothing here waits on the standby: it may be busy loading or seeking.
  let (p, sb) = (a.player, a.standby)
  let have = sb.tracks.filterIt(it.external).mapIt(it.file)
  for t in p.tracks:  # in the same order, so track ids match
    if t.external and t.file notin have and t.kind in ["sub", "audio"]:
      sb.h.commandAsync(t.kind & "-add", t.file, "auto", t.title, t.lang)
  for name in MirroredProps:
    if name in p.props and sb.props.getOrDefault(name) != p.props[name]:
      sb.h.setProp(name, p.props[name])

proc standbyAt(a: App, path: string, start: float, opts = "") =
  ## Sends the standby (paused, muted) to `start` in `path`, opened with
  ## mpv's per-file options `opts`.
  let sb = a.standby
  sb.h.setProp("mute", true)
  sb.stopped = false
  a.sbStart = start
  if path != a.sbPath or opts != a.sbOpts or not sb.loaded:
    a.sbPath = path
    a.sbOpts = opts
    sb.path = path
    sb.source = ""
    sb.partStart = 0
    sb.partEnd = 0
    sb.fullDuration = 0
    sb.loaded = false
    sb.loadError = ""
    sb.sphere = a.player.sphere  # its added tracks come with mirroring
    sb.h.setProp("pause", true)
    # Before opening: changed later, it would reopen the sound output.
    sb.h.setProp("audio-device", a.player.h.getStr("audio-device"))
    sb.h.commandAsync("loadfile", path, "replace", "-1",
      "start=" & formatFloat(start, ffDecimal, 6) & (if opts.len > 0: "," & opts else: ""))
    a.sbState = sbLoading
  else:
    # Seeking first: pausing first would have it wait for its sound to stop.
    sb.h.commandAsync("seek", formatFloat(start, ffDecimal, 6), "absolute", "exact")
    sb.h.setProp("pause", true)
    sb.seeking = true  # until mpv says otherwise
    a.sbState = sbSeeking

proc standbyOff(a: App) =
  if a.sbState == sbOff: return
  a.sbState = sbOff
  if not math.isNaN(a.sbPlayingB): a.applyAbLoop()  # B back where it was
  a.sbPath = ""
  a.sbOpts = ""
  a.standby.h.setProp("pause", true)
  a.standby.close()

proc takeOver(a: App, past = NaN) =
  ## At B: the standby, rolling, becomes the playing player; the other one
  ## goes back to wait before A. `past`: how far the loop sound is past A.
  let (old, sb) = (a.player, a.standby)
  a.mirrorStandby()  # anything changed during its run-up
  sb.h.setProp("mute", old.muted)
  old.h.setProp("mute", true)
  # Its own A-B loop would jump back to A first, a second slow seek.
  old.h.setProp("ab-loop-b", "no")
  # Each player's own time to get going, learned from where it got to.
  # With the loop sound starting or playing, a miss puts picture and sound
  # apart for the round: learned in one go, for the other player too (they're
  # alike).
  let want = a.sbA + (if math.isNaN(past): max(old.posNow - a.sbB, 0) else: past)
  let miss = want - sb.posNow
  let sound = a.lsState in {lsRolling, lsOn}
  sb.startDelay = clamp(sb.startDelay + (if sound: miss else: miss / 2), -0.1, 0.15)  # it varies a little
  if sound: old.startDelay = sb.startDelay
  sb.muted = old.muted
  sb.volume = old.volume
  a.player = sb
  a.standby = old
  (sb.hidden, old.hidden) = (false, true)
  a.sbPlayingB = NaN
  a.framePending = false
  a.renderNow = true  # the new one's frame, right away
  a.sbPending = false
  if a.sbHandoff:  # the stream from here on; the saved part is done with
    a.sbHandoff = false
    a.sbState = sbOff
    (a.sbPath, a.sbOpts) = ("", "")
    old.h.setProp("pause", true)
    old.close()
    return
  a.standbyAt(a.sbPath, a.sbStart)

proc standbyStep(a: App, la, lb, start: float) =
  ## One step of the standby's round: ready, rolling, taking over.
  let (p, sb) = (a.player, a.standby)
  case a.sbState
  of sbOff: discard
  of sbLoading:
    if sb.justLoaded:
      sb.justLoaded = false
      a.mirrorStandby()
      a.sbState = sbSeeking
  of sbSeeking:
    if not sb.seeking and abs(sb.timePos - start) < 0.1:
      a.sbState = sbReady
  of sbReady:
    # Its run-up before A takes as long as the playing one's before B,
    # started that much earlier as it takes to get going.
    let rollAt = lb - (la - start) - sb.startDelay
    let pos = if a.lsState == lsOn: a.soundTarget else: p.posNow
    if p.playing and not p.seeking and pos >= rollAt and pos < lb:
      a.mirrorStandby()
      sb.h.setProp("pause", false)
      a.sbState = sbRolling
      a.sbLastPos = pos
  of sbRolling:
    if a.lsState == lsOn:
      # At the loop sound's B; the playing player may be a little off it.
      let pos = a.soundTarget
      let wrapped = pos < a.sbLastPos - (lb - la) / 2
      if wrapped or pos >= lb - 0.004: a.takeOver(if wrapped: pos - la else: 0.0)
      elif not p.playing: a.standbyAt(p.path, start, a.sbOpts)
      else: a.sbLastPos = pos
      return
    let pos = p.posNow
    let jumped = p.seeking or p.timePos < a.sbLastPos - 0.3
    # A little early: the frame at B is due then, and shown later this pass.
    if pos >= lb - 0.004 or p.eofReached or (jumped and a.sbLastPos >= lb - 0.05):
      a.takeOver()  # at B, or mpv's own loop just beat us to it
    elif jumped or not p.playing:  # sought or paused meanwhile: wait again
      a.standbyAt(p.path, start, a.sbOpts)
    else:
      a.sbLastPos = pos

proc seamlessLoop(a: App) =
  ## Keeps a standby ready for the loop playing, and hands over at B.
  if a.sbHandoff: return  # busy going online (webHandoff)
  let p = a.player
  let (la, lb) = a.loopRegion
  let need = lb > la and lb - la >= StandbyMinLoop and p.loaded and not p.stopped and
    p.path.len > 0 and not p.path.contains("://") and p.hasRealVideo and not p.isSpherical
  if not need:
    a.standbyOff()
    return
  if a.standby == nil: return
  let sb = a.standby
  discard sb.pollEvents()
  if sb.loadError.len > 0 and p.path == a.sbPath: return  # can't open it: plain jumps
  let start = max(la - StandbyPreroll, 0)
  if p.path != a.sbPath or la != a.sbA or lb != a.sbB or a.sbState == sbOff:
    if a.sbState == sbRolling: sb.h.setProp("pause", true)
    (a.sbA, a.sbB) = (la, lb)
    a.standbyAt(p.path, start)
  else: a.standbyStep(la, lb, start)

proc placeLoopEnd(a: App) =
  ## mpv's own jump back comes a moment before B: while the standby can take
  ## over, or the loop sound times the jumps, it moves a little past B, still
  ## there should they not come. Without video, mpv jumps once it has decoded
  ## up to B, its sound buffered ahead: so far past B that what's heard gets
  ## there, for the loop sound to start at.
  let (la, lb) = a.loopRegion
  let q = a.player  # the other one, after a takeover
  if lb <= la:
    if not math.isNaN(a.sbPlayingB): a.applyAbLoop()  # B back where it was
    return
  let video = q.hasRealVideo
  let timed = a.sbState in {sbReady, sbRolling} or a.sbState == sbOff and
    (a.lsState == lsOn or not video and a.lsState in {lsReady, lsRolling})
  let past = if video: 0.1 else: 0.5
  let b = if timed and lb + past < q.duration: lb + past else: lb
  if b != a.sbPlayingB:
    a.sbPlayingB = b
    q.h.setProp("ab-loop-b", b)

proc pingPong(a: App) =
  ## Ping-pong loops: turns around on crossing B forward or A backward (the
  ## file's own ends come as EOF: handleEof). Back to forward when off.
  let p = a.player
  let on = a.pingPongFile or a.pingPongAb
  if on != a.pingPongOn:
    a.pingPongOn = on
    # mpv plays backward a keyframe's span at a time, decoding all of it
    # before showing its last frame: hardware decoders take several times
    # as long to hand over a span's frames.
    p.h.setProp("hwdec", if on: "no" else: hwdecMode())
    if not a.isSlave:  # following sets its loops itself
      a.applyLoop()
      a.applyAbLoop()
  # Ping-Pong turned on with a file open: it opens again without the
  # demuxer thread, as files opened from now on do.
  if a.cfg.repeatPingPong and not a.synced and p.loaded and not p.threadless and
     not a.reopening and not p.path.contains("://"):
    a.reopening = true
    a.reopenTracks = p.tracks.filterIt(it.external and it.kind in ["sub", "audio"])
    a.reopenSel = @[("aid", p.selectedTrack("audio")), ("sid", p.selectedTrack("sub")),
                    ("vid", p.selectedTrack("video"))]
    p.reopen(true)
  if not on:
    if p.backward: p.setBackward(false)
    return
  let pos = p.timePos
  if a.pingPongAb and p.playing and not p.seeking:
    if not p.backward and a.pingPongLast < a.loopB and pos >= a.loopB: p.setBackward(true)
    elif p.backward and a.pingPongLast > a.loopA and pos <= a.loopA: p.setBackward(false)
  a.pingPongLast = pos

proc renderStandby(a: App) =
  ## The standby's frames go to its own target, unseen, so it plays on and
  ## shows the right one the moment it takes over.
  let sb = a.standby
  if sb == nil or a.sbState notin {sbSeeking, sbReady, sbRolling}: return
  if (mpv_render_context_update(sb.render) and MpvRenderUpdateFrame) != 0:
    a.sbPending = true
  if not a.sbPending: return
  if a.sbState == sbRolling:
    let due = sb.render.nextFrameTarget()
    if due != 0 and mpv_get_time_ns(sb.h) < due - 1_500_000: return
  a.sbPending = false
  sb.target.ensureSize(a.player.target.w, a.player.target.h)
  sb.render.render(sb.target)
  # Once told of swaps (while it was the shown one), mpv waits for each.
  mpv_render_context_report_swap(sb.render)

# --- loop sound -------------------------------------------------------------
# A jump back from B to A, a seek or a standby's takeover, is never exact to
# the sample: every round the sound breaks off, or skips or repeats a little,
# which in a short loop is much of what's heard. While a loop plays, its
# sound comes from a third, video-less player instead (Player.loopSoundAt),
# with no seam at all. It starts at one of the playing player's jumps back,
# from then on silent like the standby; their jumps back keep time with it.

const
  LoopSoundMax = 60.0     ## longer loops keep their own sound: it holds the
                          ## loop's whole sound in memory
  LoopSoundPreroll = 0.1  ## decoding starts this much before A

proc soundPhase(a: App): float =
  ## Where in the loop the loop sound is heard now (at A until it gets there).
  a.lsA + floorMod(max(a.lsound.posNow - a.lsA, 0), a.lsB - a.lsA)

proc soundTarget(a: App): float =
  ## Where in the loop the picture belongs now: the loop sound's place, and
  ## audio-delay's (sound that late shows with the picture that far on).
  let delay = try: parseFloat(a.player.props.getOrDefault("audio-delay", "0"))
              except ValueError: 0.0
  a.lsA + floorMod(a.soundPhase + delay - a.lsA, a.lsB - a.lsA)

proc silenceShown(a: App, on: bool) =
  ## The playing player's own sound, and the standby's, down while the loop
  ## sound is heard: volume-gain, which nothing else uses or shows.
  if on == a.lsSilent: return
  a.lsSilent = on
  for p in [a.player, a.standby]:
    if p != nil: p.h.setProp("volume-gain", if on: -150.0 else: 0.0)

proc armLoopSound(a: App) =
  ## The loop sound to A, to wait there; the playing player's own sound until
  ## it's heard.
  let s = a.lsound
  a.silenceShown(false)
  if a.lsSrc != s.path or not s.loaded:
    # Before opening: changed later, it would reopen the sound output.
    s.h.setProp("audio-device", a.player.h.getStr("audio-device"))
  s.loopSoundAt(a.lsSrc, a.lsTrack, a.lsA, a.lsB, max(a.lsA - LoopSoundPreroll, 0))
  a.lsAsked = s.restarts
  a.lsState = lsLoading
  a.lsCheck = -1

proc loopSoundOff(a: App) =
  a.silenceShown(false)
  a.lsKey = ""
  if a.lsState == lsOff: return
  a.lsState = lsOff
  a.lsound.h.setProp("pause", true)
  a.lsound.close()

proc nativeJumps(a: App) =
  ## The playing player's own jumps back to A (no standby to take over) while
  ## the loop sound plays: a seek takes a while, so it goes that much before
  ## the sound's B, learned from how each one landed.
  let p = a.player
  let (la, lb) = (a.lsA, a.lsB)
  let span = lb - la
  if a.lsCheck >= 0 and p.restarts > a.lsCheck and not p.seeking and p.timePos > la + 0.001:
    a.lsCheck = -1
    var e = p.posNow - a.soundTarget  # ahead of the sound: went too early
    e -= span * round(e / span)
    a.lsLead = clamp(a.lsLead - clamp(e, -0.1, 0.1) / 2, 0.01, 0.9 * span)
  let late = a.lsSoughtRound < a.lsRound - 1  # missed last round's B
  if late or a.lsSoughtRound < a.lsRound and a.soundTarget >= lb - a.lsLead:
    a.lsSoughtRound = if late: a.lsRound - 1 else: a.lsRound
    a.lsCheck = p.restarts
    p.h.commandAsync("seek", formatFloat(la, ffDecimal, 6), "absolute", "exact")

proc soundHeard(a: App, tookOver: bool, late = false) =
  ## The playing player's jump back: from here on, the loop sound is heard.
  ## `late`: it only started now, nothing to learn its start from.
  let p = a.player
  a.silenceShown(true)
  if not tookOver and not p.seeking and not p.hasRealVideo and not late:
    p.h.commandAsync("seek", formatFloat(a.lsA, ffDecimal, 6), "absolute", "exact")
  a.lsState = lsOn
  a.lsHeard = if late: NaN else: now()
  a.lsRound = 0
  a.lsSoughtRound = -1
  a.lsCheck = if tookOver: -1 else: p.restarts
  a.lsPhase = a.lsA
  a.lsMoved = NaN

proc loopSound(a: App) =
  ## Keeps the loop sound ready for the loop playing, has it take over the
  ## sound at a jump back, and the jumps back in time with it.
  let s = a.lsound
  if s == nil: return
  discard s.pollEvents()
  let p = a.player
  let (la, lb) = a.loopRegion
  var (src, track) = (p.path, $p.selectedTrack("audio"))
  for t in p.tracks:
    if t.kind == "audio" and t.selected and t.external: (src, track) = (t.file, "auto")
  let need = lb > la and lb - la <= LoopSoundMax and track != "0" and p.loaded and
    not p.stopped and p.path.len > 0 and not p.path.contains("://")
  if not need:
    a.loopSoundOff()
    return
  let key = src & "\n" & track & "\n" & $la & "\n" & $lb
  if key != a.lsKey:
    a.loopSoundOff()
    a.lsKey = key
    (a.lsSrc, a.lsTrack, a.lsA, a.lsB) = (src, track, la, lb)
    a.lsShown = p
    a.lsJumps = p.jumps
    a.armLoopSound()
    return
  if s.loadError.len > 0: return  # can't open it: the playing player's sound
  # The playing player sent elsewhere (seek, step): from A again. Not a
  # standby taking over.
  let tookOver = p != a.lsShown
  let jumped = not tookOver and p.jumps != a.lsJumps
  a.lsShown = p
  a.lsJumps = p.jumps
  if jumped and a.lsState in {lsRolling, lsOn}:
    if a.sbState == sbRolling:  # not to take over from where it went
      a.standby.h.setProp("pause", true)
      a.standbyAt(a.sbPath, a.sbStart)
    a.armLoopSound()
    return
  let heard = a.lsState in {lsRolling, lsOn}
  if abs(s.volume - p.volume) > 0.001: s.setVolume(p.volume)
  if s.muted != (p.muted or not heard):
    s.muted = p.muted or not heard
    s.h.setProp("mute", s.muted)
  if abs(s.speed - p.speed) > 1e-6:
    s.speed = p.speed
    s.h.setProp("speed", p.speed)
  let pos = p.posNow
  case a.lsState
  of lsOff: discard
  of lsLoading:
    if s.loaded and s.restarts > a.lsAsked:
      a.lsState = lsReady
  of lsReady:
    # Started as long before the playing player's B as it takes to get
    # going, or at A for loops shorter than that. Missed (the jump back came
    # first): right away, a moment late.
    let at = max(lb - s.startDelay, la)
    let wrapped = not jumped and (tookOver or
      a.lsPhase >= lb - 0.05 and p.timePos < a.lsPhase - (lb - la) / 2)
    if p.playing and (wrapped or not p.seeking and pos >= at and pos < lb):
      s.muted = p.muted
      s.h.setProp("mute", s.muted)
      s.h.setProp("pause", false)
      s.paused = false
      a.lsState = lsRolling
      a.lsRollAt = now()
      a.lsPhase = pos
      if wrapped: a.soundHeard(tookOver, late = true)
    elif jumped: a.lsPhase = 0  # where the playing player was before B
    elif not p.seeking: a.lsPhase = pos
  of lsRolling:
    if tookOver or p.seeking or pos >= lb - 0.004 or p.timePos < a.lsPhase - 0.3:
      a.soundHeard(tookOver)
    elif not p.playing or now() - a.lsRollAt > (lb - la) / max(p.speed, 0.01) + 1:
      a.armLoopSound()  # paused, or never got there
    else: a.lsPhase = max(a.lsPhase, pos)
  of lsOn:
    if not math.isNaN(a.lsHeard) and s.timePos > la + 0.0005:
      # How long it took to be heard: when its A was, against when wanted.
      # Learned in one go, there being one such start a loop.
      let late = (now() - a.lsHeard) * s.speed - (s.posNow - la)
      s.startDelay = clamp(s.startDelay + late, 0, 0.3)
      a.lsHeard = NaN
    if not p.playing:
      if not s.paused:
        s.h.setProp("pause", true)
        s.paused = true
      return
    if s.paused:
      s.h.setProp("pause", false)
      s.paused = false
      a.lsMoved = NaN
    # A sound that stopped coming (its output gone, say): the playing
    # player's own again.
    if s.timePos != a.lsMoved:
      (a.lsMoved, a.lsMovedAt) = (s.timePos, now())
    elif now() - a.lsMovedAt > 0.5:
      a.armLoopSound()
      return
    let ph = a.soundPhase
    if ph < a.lsPhase - (lb - la) / 2: inc a.lsRound
    a.lsPhase = ph
    if a.sbState == sbOff: a.nativeJumps()  # no standby for this loop

# --- loop frames ------------------------------------------------------------
# A loop too short for the standby jumps back by seeking, and a seek decodes
# from the keyframe before A: taking about as long as the loop, it leaves the
# picture all but frozen. The loop's frames are taken once instead, stepping
# the (otherwise idle) standby from A to B and rendering each frame into a
# texture of its own, then shown in turn, in time with the loop sound (or a
# clock of their own when there's no sound).

const
  LoopFrameLook = ["vid", "sid", "secondary-sid", "sub-delay", "sub-visibility",
    "sub-align-x", "sub-align-y", "sub-margin-x", "sub-margin-y", "sub-pos",
    "sub-scale", "sub-font", "sub-bold", "sub-italic", "sub-font-size",
    "sub-color", "sub-outline-size", "sub-outline-color", "sub-shadow-offset",
    "sub-back-color", "sub-ass-override", "video-margin-ratio-left", "video-margin-ratio-right",
    "video-margin-ratio-top", "video-margin-ratio-bottom", "keepaspect",
    "video-scale-x", "video-scale-y"]  ## what shows in a frame

proc loopFramesMax(a: App): int =
  ## Memory the frames may take, bytes (Options > System).
  clamp(a.cfg.loopFramesMB, 64, LoopFramesMaxMB) * 1024 * 1024

proc dropLoopFrames(a: App) =
  ## Frees them (in the next GL pass).
  a.lfTrash.add a.lfFrames
  a.lfFrames.setLen 0
  a.lfBytes = 0

proc loopFramesOff(a: App) =
  if a.lfState in {lfSeeking, lfStepping}: a.standby.h.setProp("pause", true)
  if a.lfSlotOpen:
    a.lfSlotOpen = false
    a.lfTrash.add a.lfSlot
  a.dropLoopFrames()
  a.lfState = lfOff
  a.lfKey = ""

proc loopFramesFailed(a: App) =
  ## The plain way for this loop: no retrying until it changes.
  let key = a.lfKey
  a.loopFramesOff()
  a.lfKey = key
  a.lfState = lfFailed

proc takeLoopFrames(a: App, tw, th: int) =
  ## GL pass: renders the standby's frame, once it has a new one, into a
  ## texture of its own, and steps it on to the next, up to B. The new time
  ## and the new frame come separately: each is rendered again on every
  ## update until they stop, so the frame kept is the one of that time.
  a.lfSize = (tw, th)
  if a.lfState notin {lfSeeking, lfStepping}: return
  let sb = a.standby
  if (mpv_render_context_update(sb.render) and MpvRenderUpdateFrame) != 0:
    a.lfPending = true
  if a.lfSlotOpen:
    if a.lfPending:
      a.lfPending = false
      sb.render.render(a.lfSlot.target)
      mpv_render_context_report_swap(sb.render)
      a.lfSettleAt = now()
    elif now() - a.lfSettleAt > 0.025:
      a.lfSlotOpen = false
      a.lfFrames.add a.lfSlot
      a.lfBytes += tw * th * 4
      a.lfLastT = a.lfSlot.t
      a.lfState = lfStepping
      sb.h.commandAsync("frame-step")
      a.lfAskedAt = now()
    return
  # (A restart from before the load would still be at its old place.)
  let fresh = if a.lfState == lfSeeking:
                sb.loaded and sb.restarts > a.lfAsked and
                  sb.timePos >= a.lfStart - 0.001 and sb.timePos < a.lfStart + 0.1
              else: sb.timePos != a.lfLastT
  if not fresh:
    # Frames not to keep (from before the seek) still go somewhere: mpv
    # waits for each to be rendered before it gets on with the next.
    if a.lfPending:
      a.lfPending = false
      sb.target.ensureSize(tw, th)
      sb.render.render(sb.target)
      mpv_render_context_report_swap(sb.render)
    return
  sb.justLoaded = false  # not to be taken for the standby's own loading
  let t = sb.timePos
  let (la, lb) = a.loopRegion
  if t >= lb - 0.0005 or a.lfState == lfStepping and t < a.lfLastT or sb.eofReached:
    # Past B (or the end): all there is.
    if a.lfFrames.len == 0: a.loopFramesFailed()
    else: a.lfState = lfDone
    return
  if a.lfBytes + tw * th * 4 > a.loopFramesMax:
    a.loopFramesFailed()
    return
  if t <= la + 0.0005:  # showing at A, so the ones before it never are
    a.dropLoopFrames()
  for _ in 1 .. 8:  # errors from before, not to be taken for this one's
    if glGetError() == GL_NO_ERROR: break
  a.lfSlot = LoopFrame(t: t)
  a.lfSlot.target.ensureSize(tw, th)
  if glGetError() == GL_OUT_OF_MEMORY:
    a.lfTrash.add a.lfSlot
    a.loopFramesFailed()
    return
  a.lfPending = false
  sb.render.render(a.lfSlot.target)
  mpv_render_context_report_swap(sb.render)
  a.lfSlotOpen = true
  a.lfSettleAt = now()

proc loopFrames(a: App) =
  ## Keeps a short loop's frames taken, and picks the one to show.
  let p = a.player
  let sb = a.standby
  let (la, lb) = a.loopRegion
  let need = sb != nil and lb > la and lb - la < StandbyMinLoop and a.sbState == sbOff and
    p.loaded and not p.stopped and p.hasRealVideo and not p.isSpherical and
    p.path.len > 0 and not p.path.contains("://") and a.lfSize[0] > 1
  var want = -1
  a.lfOn = false
  if not need:
    if a.lfState != lfOff: a.loopFramesOff()
  else:
    # The memory allowed too: changed, a loop that didn't fit may now.
    var key = p.path & "\n" & $la & "\n" & $lb & "\n" & $a.lfSize & "\n" & $a.loopFramesMax
    for name in LoopFrameLook: key.add "\n" & p.props.getOrDefault(name)
    if key != a.lfKey:
      # Taken from A on: the standby there, looking like the playing player,
      # its sound, OSD and loops off.
      a.loopFramesOff()
      a.lfKey = key
      a.mirrorStandby()
      for (k, v) in [("aid", "no"), ("osd-level", "0"), ("ab-loop-a", "no"),
                     ("ab-loop-b", "no"), ("loop-file", "no"), ("mute", "yes"),
                     ("pause", "yes")]:
        sb.h.setProp(k, v)
      sb.stopped = false
      # A little before A: a seek lands on the first frame from there on, and
      # the one showing at A may have started before it. Opened anew: a seek
      # in the middle of a step lands anywhere.
      a.lfStart = max(la - 0.1, 0)
      sb.path = p.path
      sb.loaded = false
      sb.loadError = ""
      sb.sphere = p.sphere
      sb.h.commandAsync("loadfile", p.path, "replace", "-1",
        "start=" & formatFloat(a.lfStart, ffDecimal, 6))
      a.lfAsked = sb.restarts
      a.lfAskedAt = now()
      a.lfPending = false
      a.lfFrames.setLen 0
      a.lfState = lfSeeking
    if a.lfState in {lfSeeking, lfStepping}:
      discard sb.pollEvents()
      a.dirtyUntil = max(a.dirtyUntil, now() + 0.05)  # GL passes to take them in
      if sb.loadError.len > 0 or now() - a.lfAskedAt > 3: a.loopFramesFailed()
    # Where the picture is: with the loop sound, once it's heard; without
    # sound, a clock of its own, from where the playing player is.
    var t = NaN
    if a.lsState == lsOn: t = a.soundTarget
    elif a.lsState == lsOff:
      if p.jumps != a.lfJumps:
        a.lfJumps = p.jumps
        a.lfClockSet = false
      if not a.lfClockSet and not p.seeking:
        a.lfClock = if p.timePos >= la and p.timePos < lb: p.timePos - la else: 0.0
        a.lfClockSet = true
        a.lfClockAt = now()
      if a.lfClockSet:
        if p.playing: a.lfClock += (now() - a.lfClockAt) * p.speed
        a.lfClockAt = now()
        t = la + floorMod(a.lfClock, lb - la)
    if a.lfState == lfDone and not math.isNaN(t):
      a.lfOn = true
      want = 0
      for i, f in a.lfFrames:
        if f.t <= t + 0.0005: want = i
  if want != a.lfShow:
    a.lfShow = want
    a.lfDue = true

# --- step frames ------------------------------------------------------------
# Going back a frame is a seek: mpv decodes from the keyframe before it, on
# every press, however many frames that is. While paused, the standby takes
# the frames around the position instead, as for a short loop, so a step
# either way just shows another texture at once. The player follows with a
# seek (they coalesce), to be there on playing or stepping past them. More
# frames are taken, out of the way, before stepping gets to the edge of those
# kept. Anything they can't serve steps the plain way.

const
  StepBack = 120      ## frames taken at a time before the position, at most
  StepAhead = 30      ## and after it
  StepMargin = 30     ## more are taken this close to an edge
  StepMin = 16        ## fewer than this fit in memory: not worth it
  StepSettle = 0.004  ## seconds without an update for a frame to be final
  StepPause = 0.15    ## how long the position must stay put to take frames
  StepIdle = 30.0     ## seconds without a step until they're let go
  StepPlain = 0.25    ## a plain step unpauses the player for about this long

proc stepFramesMax(a: App): int =
  a.loopFramesMax div max(a.lfSize[0] * a.lfSize[1] * 4, 1)

proc stepDur(a: App): float =
  let fps = a.frameRate(a.player.path)
  if fps > 0: 1 / fps else: 1 / 30

proc stepIndex(a: App, t: float): int =
  ## The kept frame showing at time t; -1 outside them.
  result = -1
  if a.sfFrames.len == 0 or t > a.sfFrames[^1].t + a.stepDur / 2: return
  for i, f in a.sfFrames:
    if f.t > t + 0.0005: break
    result = i

proc stepRelease(a: App) =
  ## The player's own picture and time again.
  if a.sfShow >= 0: a.lfDue = true
  a.sfShow = -1
  a.sfOwed = 0
  a.player.holdTime = false

proc stepFramesOff(a: App) =
  ## Frees them (in the next GL pass). The standby stays open, for the next
  ## ones, unless caught in the middle: a seek during a step lands anywhere.
  a.stepRelease()
  if a.sfState != sfParked: a.sfPath = ""
  if a.sfSlotOpen:
    a.sfSlotOpen = false
    a.lfTrash.add a.sfSlot
  a.lfTrash.add a.sfFrames
  a.lfTrash.add a.sfFill
  a.sfFrames.setLen 0
  a.sfFill.setLen 0
  a.sfState = sfParked
  a.sfAbort = false
  a.sfAtStart = false
  a.sfAtEnd = false
  a.sfParkT = -1

proc stepFramesFailed(a: App) =
  ## The plain way, until the next step asks for them again.
  a.stepFramesOff()
  a.sfWanted = 0
  a.sfPath = ""

proc stepShow(a: App, i: int) =
  let p = a.player
  a.sfShow = i
  a.lfDue = true
  p.holdTime = true
  p.timePos = a.sfFrames[i].t
  p.seek(p.timePos)
  a.sfJumps = p.jumps

proc payStepsOwed(a: App) =
  while a.sfOwed != 0:
    let d = sgn(a.sfOwed)
    let j = a.stepIndex(a.player.timePos) + d
    if j >= 0 and j < a.sfFrames.len:
      a.stepShow(j)
      a.sfOwed -= d
    else:
      if (if d < 0: a.sfAtStart else: a.sfAtEnd): a.sfOwed = 0
      return

proc stepFromFrames(a: App, forward: bool): bool =
  ## A step among the kept frames; false to step the plain way.
  let p = a.player
  a.sfWanted = now()
  if not a.sfOn or not p.paused: return false
  let d = if forward: 1 else: -1
  if a.sfOwed != 0:
    a.sfOwed += d
    return true
  let i = a.stepIndex(p.timePos)
  if i < 0: return false
  if i + d < 0 or i + d >= a.sfFrames.len:
    if not (if forward: a.sfAtEnd else: a.sfAtStart): a.sfOwed = d
    return true
  a.stepShow(i + d)
  true

proc stepPlayer(a: App, forward: bool) =
  if not a.stepFromFrames(forward):
    a.player.frameStep(forward)
    a.sfJumps = a.player.jumps
    a.sfPlainAt = now()

proc stepFill(a: App, start, stop: float, before: bool) =
  ## Sends the standby to take the frames from `start` up to `stop`.
  let (p, sb) = (a.player, a.standby)
  (a.sfStart, a.sfStop, a.sfBefore) = (max(start, 0), stop, before)
  a.sfAsked = sb.restarts
  a.sfAskedAt = now()
  a.sfPending = false
  a.sfUpdated = false
  a.sfState = sfSeeking
  if a.sfPath == p.path and sb.loaded and sb.path == p.path:
    sb.h.commandAsync("seek", formatFloat(a.sfStart, ffDecimal, 6), "absolute", "exact")
    return
  # As for loop frames: looking like the playing player, the rest off.
  a.sfPath = p.path
  a.mirrorStandby()
  for (k, v) in [("aid", "no"), ("osd-level", "0"), ("ab-loop-a", "no"),
                 ("ab-loop-b", "no"), ("loop-file", "no"), ("mute", "yes"),
                 ("pause", "yes"), ("speed", "100")]:  # a step waits out the frame's time
    sb.h.setProp(k, v)
  sb.stopped = false
  sb.path = p.path
  sb.loaded = false
  sb.loadError = ""
  sb.sphere = p.sphere
  sb.h.commandAsync("loadfile", p.path, "replace", "-1",
    "start=" & formatFloat(a.sfStart, ffDecimal, 6))

proc stepOn(a: App) =
  ## Has the standby step to the next frame.
  a.sfState = sfStepping
  a.sfUpdated = false
  a.standby.h.commandAsync("frame-step")
  a.sfAskedAt = now()

proc stepTrim(a: App) =
  ## Back within memory, letting go of the frames furthest from the position.
  while a.sfFrames.len > a.stepFramesMax:
    if a.stepIndex(a.player.timePos) >= a.sfFrames.len div 2:
      a.lfTrash.add a.sfFrames[0]
      a.sfFrames.delete(0)
      a.sfAtStart = false
      if a.sfShow >= 0: dec a.sfShow
    else:
      a.lfTrash.add a.sfFrames.pop()
      a.sfAtEnd = false
      a.sfParkT = -1

proc stepFillDone(a: App) =
  ## The standby stops where it is, its frames joining the ones kept.
  let sb = a.standby
  a.sfState = sfParked
  a.sfParkT = sb.timePos
  if a.sfAbort:
    a.sfAbort = false
    a.lfTrash.add a.sfFill
    a.sfFill.setLen 0
    return
  if a.sfBefore:
    if a.sfFill.len == 0: a.sfAtStart = true
    if a.sfShow >= 0: a.sfShow += a.sfFill.len
    a.sfFrames = a.sfFill & a.sfFrames
    a.sfFill.setLen 0
    a.stepTrim()
  a.payStepsOwed()

proc keepStepFrame(a: App, f: LoopFrame) =
  if a.sfStart <= 0: a.sfAtStart = true
  if a.sfBefore:
    a.sfFill.add f
    if a.sfFill.len > a.stepFramesMax:
      a.lfTrash.add a.sfFill[0]
      a.sfFill.delete(0)
  elif a.sfFrames.len == 0 or f.t > a.sfFrames[^1].t + 0.0005:
    a.sfFrames.add f
    a.stepTrim()
    a.payStepsOwed()
  else: a.lfTrash.add f

proc takeStepFrame(a: App, tw, th: int): bool =
  ## One go at the standby's frame, as takeLoopFrames; true if it's waiting
  ## for mpv, nothing else to do for now.
  let sb = a.standby
  discard sb.pollEvents()
  if (mpv_render_context_update(sb.render) and MpvRenderUpdateFrame) != 0:
    a.sfPending = true
    a.sfUpdated = true
  if a.sfSlotOpen:
    if a.sfPending:
      a.sfPending = false
      sb.render.render(a.sfSlot.target, untimed = true)
      mpv_render_context_report_swap(sb.render)
      a.sfSettleAt = now()
    elif now() - a.sfSettleAt > StepSettle:
      a.sfSlotOpen = false
      a.sfLastT = a.sfSlot.t
      let t = a.sfSlot.t
      a.keepStepFrame(a.sfSlot)
      if not a.sfBefore and t >= a.sfStop - 0.0005: a.stepFillDone()
      else: a.stepOn()
    return true
  if a.sfState == sfStepping and sb.eofReached and sb.timePos == a.sfLastT:
    a.sfAtEnd = true
    a.stepFillDone()
    return true
  # The time and the frame both new, whichever came first: the time alone
  # would have the last frame taken for this one.
  let fresh = a.sfUpdated and (if a.sfState == sfSeeking:
                sb.loaded and sb.restarts > a.sfAsked and sb.timePos >= a.sfStart - 0.001
              else: sb.timePos != a.sfLastT)
  if not fresh:
    if a.sfPending:  # as for loop frames: mpv waits for it to be rendered
      a.sfPending = false
      sb.target.ensureSize(tw, th)
      sb.render.render(sb.target, untimed = true)
      mpv_render_context_report_swap(sb.render)
    return true
  sb.justLoaded = false
  let t = sb.timePos
  if a.sfAbort or a.sfBefore and t >= a.sfStop - 0.0005:
    a.stepFillDone()
    return true
  for _ in 1 .. 8:  # errors from before, not to be taken for this one's
    if glGetError() == GL_NO_ERROR: break
  a.sfSlot = LoopFrame(t: t)
  a.sfSlot.target.ensureSize(tw, th)
  if glGetError() == GL_OUT_OF_MEMORY:
    a.lfTrash.add a.sfSlot
    a.stepFramesFailed()
    return true
  a.sfPending = false
  sb.render.render(a.sfSlot.target, untimed = true)
  mpv_render_context_report_swap(sb.render)
  a.sfSlotOpen = true
  a.sfSettleAt = now()
  true

proc takeStepFrames(a: App, tw, th: int) =
  ## GL pass: takes frames for a few milliseconds, mpv being quicker at
  ## stepping than the window is at drawing.
  let until = now() + 0.005
  while a.sfState != sfParked and a.takeStepFrame(tw, th) and now() < until: discard

proc stepFrames(a: App) =
  ## Keeps the frames around a paused position taken.
  let (p, sb) = (a.player, a.standby)
  let (la, lb) = a.loopRegion
  if a.sbState != sbOff or a.lfState != lfOff: a.sfPath = ""
  let need = sb != nil and not cpuWanted and lb <= la and a.sbState == sbOff and
    a.lfState == lfOff and p.loaded and not p.stopped and not p.backward and
    (p.paused or now() - a.sfPlainAt < StepPlain) and
    p.hasRealVideo and not p.isSpherical and p.path.len > 0 and
    not p.path.contains("://") and a.lfSize[0] > 1 and a.stepFramesMax >= StepMin
  if not need:
    if a.sfOn:
      a.sfOn = false
      let open = a.sfPath.len > 0
      a.stepFramesOff()
      if open:  # its decoder's memory, not to be held on to while playing
        sb.close()
        a.sfPath = ""
    return
  if not a.sfOn:
    a.sfOn = true
    a.sfWanted = now()
    a.sfMovedAt = now()
    a.sfJumps = p.jumps
  var key = p.path & "\n" & $a.lfSize & "\n" & $a.loopFramesMax
  for name in LoopFrameLook: key.add "\n" & p.props.getOrDefault(name)
  if key != a.sfKey:
    a.stepFramesOff()
    a.sfKey = key
    a.sfPath = ""
    a.sfMovedAt = now()
  if p.jumps != a.sfJumps:  # sent elsewhere
    a.sfJumps = p.jumps
    a.sfMovedAt = now()
    a.stepRelease()
  if a.sfState != sfParked:
    discard sb.pollEvents()
    a.dirtyUntil = max(a.dirtyUntil, now() + 0.05)  # GL passes to take them in
    if sb.loadError.len > 0 or now() - a.sfAskedAt > 3:
      a.stepFramesFailed()
    elif a.stepIndex(p.timePos) < 0 and
         (p.timePos < a.sfStart or p.timePos > a.sfStop + a.stepDur):
      a.sfAbort = true
    return
  if a.sfWanted == 0 or now() - a.sfWanted > StepIdle:
    if a.sfFrames.len > 0:
      a.stepFramesOff()
      if sb.loaded:
        sb.close()
        a.sfPath = ""
    return
  let
    t = p.timePos
    d = a.stepDur
    i = a.stepIndex(t)
    most = a.stepFramesMax
    back = min(StepBack, most * 2 div 3)
    ahead = min(StepAhead, most div 4)
    margin = min(StepMargin, most div 3)
  if i < 0:
    if not p.seeking and now() - a.sfMovedAt >= StepPause:
      a.stepFramesOff()
      a.stepFill(t - back.float * d, t + ahead.float * d, false)
  elif i < margin and not a.sfAtStart:
    let first = a.sfFrames[0].t
    a.stepFill(first - back.float * d, first, true)
  elif a.sfFrames.len - 1 - i < margin and not a.sfAtEnd:
    let last = a.sfFrames[^1].t
    if a.sfParkT == last:  # already there
      (a.sfBefore, a.sfStop, a.sfLastT) = (false, last + ahead.float * d, last)
      a.stepOn()
    else: a.stepFill(last + d / 4, last + ahead.float * d, false)

# --- synchronize: Properties window ---------------------------------------

proc syncInstances(a: App): seq[SyncInstance] =
  ## Every player found, this one included, by pid.
  if a.peers == nil: return
  result.add SyncInstance(pid: a.peers.pid, title: a.player.path.extractFilename,
    master: a.syncMaster, offset: a.followOffset, loop: a.followLoop, me: true)
  for p in a.peers.peers:
    result.add SyncInstance(pid: p.pid, title: p.title, master: p.master, offset: p.offset,
      loop: p.loop)
  result.sort(proc (x, y: SyncInstance): int = cmp(x.pid, y.pid))

proc setMasterOf(a: App, pid, master: int) =
  ## pid follows master from now on (0: none). Membership is the master's:
  ## the new master takes pid in (it leaves its old group by itself), or the
  ## current one lets it go.
  let me = a.peers.pid
  proc ask(on: int, op: string) =
    if on == me: a.handleSyncRequest(op, pid)
    else: a.peers.send(on, "request", op, $pid)
  if master != 0: ask(master, "add")
  else:
    let peer = a.peers.find(pid)
    let cur = if pid == me: a.syncMaster elif peer != nil: peer.master else: 0
    if cur != 0 and cur != pid: ask(cur, "remove")

proc setFollowOf(a: App, pid: int, offset: float, loop: bool) =
  ## pid's offset and looping as a slave; it keeps them itself. The list
  ## shows them right away, before pid announces them.
  if pid == a.peers.pid:
    a.setFollow(offset, loop)
    return
  a.peers.send(pid, "follow", $offset, $loop)
  let peer = a.peers.find(pid)
  if peer != nil: (peer.offset, peer.loop) = (max(offset, 0), loop)

# --- dialogs ----------------------------------------------------------------

proc startDir(a: App): string =
  let custom = a.cfg.openDir.expandPath  # Options > Player > Paths
  if custom.len > 0 and dirExists(custom): custom
  elif a.player.path.len > 0 and fileExists(a.player.path): a.player.path.parentDir
  elif a.cfg.lastDir.len > 0 and dirExists(a.cfg.lastDir): a.cfg.lastDir
  else: getHomeDir()

proc ask(a: App, kind: DialogKind, purpose, title: string, start = "",
         exts: seq[string] = @[], filterName = "",
         extraFilters: seq[(string, seq[string])] = @[]) =
  if a.dialog != nil: return
  a.menus.close()
  a.dialog = startDialog(kind, purpose, title,
    if start.len > 0: start else: a.startDir, exts, filterName, extraFilters)

proc openFileDialog(a: App) =
  a.ask(dkOpenFiles, "open", "Open File", exts = @MediaExtensions,
    filterName = "Media files")

proc screenshot(a: App) =
  if not a.player.loaded: return
  let base = a.player.path.splitFile.name
  let stamp = fmtTime(a.player.timePos).replace(":", ".")
  let dir = a.cfg.screenshotFolder
  if a.cfg.screenshotNoAsk:
    var p = dir / &"{base}_{stamp}.png"
    var n = 2
    while fileExists(p):
      p = dir / &"{base}_{stamp}_{n}.png"
      inc n
    try: createDir(dir)
    except OSError: discard
    if a.player.h.command("screenshot-to-file", p, "video") >= 0:
      a.osd("Screenshot saved: " & p.extractFilename)
    else:
      a.osd("Screenshot failed")
    return
  a.ask(dkSaveFile, "screenshot", "Save Screenshot",
    dir / &"{base}_{stamp}.png", @["png", "jpg", "webp"], "Images")

proc saveMedia(a: App) =
  ## File > Save: asks where to save the media playing, whole.
  let p = a.player
  if not p.loaded: return
  if a.saveJob.running:
    let pc = a.saveJob.progress
    a.osd("Already saving " & a.saveJob.dest.extractFilename &
      (if pc >= 0: &" ({pc:.0f}%)" else: ""))
    return
  a.saveSrc = p.path
  if p.path.isWebLink:
    var title = a.linkTitles.getOrDefault(p.path, a.saved.lookup(p.path).title)
    if title.len == 0: title = p.h.getStr("media-title")
    if title.len == 0 or title == p.path: title = p.path.youtubeId
    a.ask(dkSaveFile, "savemedia", "Save", a.startDir / safeName(title) & ".mkv",
      @["mkv", "mp4"], "Videos")
  else:
    let ext = p.path.splitFile.ext
    a.ask(dkSaveFile, "savemedia", "Save", a.startDir / p.path.extractFilename,
      (if ext.len > 1: @[ext[1 .. ^1]] else: @[]), "Media files")

proc startSave(a: App, dest: string) =
  let src = a.saveSrc
  var d = dest
  var note = ""
  if src.isWebLink:
    let whole = a.savedFile(src)
    # As fetched by now: a save doesn't wait for them, only an .mkv holds them.
    var styled = a.ytStyled.getOrDefault(src).filterIt(fileExists(it.path))
    if d.splitFile.ext.toLowerAscii == ".mp4" and styled.len > 0:
      styled.setLen 0
      note = "plain subtitles: an .mp4 can't hold styled ones"
    if whole.len > 0:  # the media cache holds all of it
      if d.splitFile.ext.len == 0: d.add whole.splitFile.ext
      a.saveJob = copying(whole, d, styled)
    elif findYtdlp(a.cfg.ytdlp).len == 0:
      a.osd("Saving links needs yt-dlp")
      return
    else:
      a.saveJob = downloading(findYtdlp(a.cfg.ytdlp), src, d, a.ytCookies.getOrDefault(src),
        a.saveFormat(src), styled)
    a.saveJob.warning = note
  else:
    if d.splitFile.ext.len == 0: d.add src.splitFile.ext
    a.saveJob = copying(src, d)
  if a.saveJob.done: a.osd("Cannot save: " & a.saveJob.error)
  else: a.osd("Saving...")

proc pollSave(a: App) =
  let j = a.saveJob
  if not j.running or not j.poll(): return
  a.dirtyUntil = max(a.dirtyUntil, now() + 0.05)  # the status bar's progress
  if j.done:
    a.saveJob = nil
    if j.error.len == 0:
      a.osd("Saved: " & j.dest.extractFilename &
        (if j.warning.len > 0: " (" & j.warning & ")" else: ""))
    else: a.osd("Save failed: " & j.error)

proc cancelSave(a: App) =
  if not a.saveJob.running: return
  a.saveJob.cancel()
  a.saveJob = nil
  a.osd("Saving cancelled")

const PlaylistFilters = @[("M3U playlist", @["m3u", "m3u8"]), ("PLS playlist", @["pls"])]

proc loadPlaylistDialog(a: App) =
  a.ask(dkOpenFile, "plload", "Load Playlist", exts = @PlaylistExtensions,
    filterName = "Playlists", extraFilters = PlaylistFilters)

proc savePlaylistDialog(a: App) =
  a.ask(dkSaveFile, "plsave", "Save Playlist", a.startDir / "Playlist.m3u",
    extraFilters = PlaylistFilters)

const ChapterFilters = @[("Matroska simple chapters", @["txt"])]

proc exportBookmarksDialog(a: App) =
  if a.fileBookmarks.len == 0: return
  let name = a.player.path.extractFilename.splitFile.name
  a.ask(dkSaveFile, "bmexport", "Export Bookmarks",
    a.startDir / name & ".chapters.txt", extraFilters = ChapterFilters)

proc importBookmarksDialog(a: App) =
  if not a.player.loaded: return
  a.ask(dkOpenFile, "bmimport", "Import Bookmarks", exts = @["txt"],
    filterName = "Matroska simple chapters")

proc exportBookmarks(a: App, path: string) =
  var p = path
  if p.splitFile.ext.len == 0: p.add ".txt"
  try:
    writeFile(p, a.fileBookmarks.toSimpleChapters)
    a.osd("Bookmarks exported: " & p.extractFilename)
  except IOError, OSError:
    a.osd("Cannot write " & p.extractFilename)

proc importBookmarks(a: App, path: string) =
  ## Adds the file's chapters to the current file's bookmarks; ones at a
  ## bookmark's time already only fill in its name when it has none.
  if not a.player.loaded or a.player.path.len == 0: return
  var marks: seq[Bookmark]
  try: marks = readFile(path).parseSimpleChapters
  except IOError, OSError, ValueError:
    a.osd("No bookmarks found in " & path.extractFilename)
    return
  var added = 0
  a.editBookmarks(a.player.path, proc (cur: var seq[Bookmark]) =
    for m in marks:
      var j = -1
      for i, b in cur:
        if abs(b.time - m.time) < 0.05: j = i; break
      if j >= 0:
        if cur[j].name.len == 0: cur[j].name = m.name
        continue
      var i = 0
      while i < cur.len and cur[i].time < m.time: inc i
      cur.insert(m, i)
      inc added)
  a.osd(if added == 1: "1 bookmark imported" else: $added & " bookmarks imported")

proc loadPlaylist(a: App, path: string) =
  ## Replaces the playlist with the file's entries and plays the first.
  if a.editLocked: return
  var entries: seq[string]
  try: entries = readPlaylist(path)
  except IOError, OSError:
    a.osd("Cannot read playlist: " & path.extractFilename)
    return
  let files = expandPaths(entries)
  if files.len == 0:
    a.osd("Nothing playable found")
    return
  a.playlist = files
  a.plScroll = 0
  a.playIndex(0)

proc savePlaylist(a: App, path: string) =
  ## M3U, or PLS for a .pls name; .m3u is added when there is no extension.
  var p = path
  if p.splitFile.ext.len == 0: p.add ".m3u"
  var entries: seq[PlaylistEntry]
  for f in a.playlist:
    # durations only as already probed: probing every file here would stall
    let d = if f in a.mediaInfo and a.mediaInfo[f].duration > 0: a.mediaInfo[f].duration
            else: -1.0
    let title = if f.contains("://"): a.linkTitles.getOrDefault(f, f) else: f.splitFile.name
    entries.add PlaylistEntry(path: (if f.contains("://"): f else: f.absolutePath),
                              title: title, duration: d)
  try:
    writePlaylist(p, entries)
    a.osd("Playlist saved: " & p.extractFilename)
  except IOError, OSError:
    a.osd("Cannot save playlist: " & p.extractFilename)

proc askExternal(a: App)  # Run menu, below

proc pickOpen(a: App): bool =
  ## The Run window is up. It doesn't hold the main window: the times it
  ## offers follow the seek bar as the player is used.
  a.pickWin != nil and a.pickWin.visible

proc handleDialogResult(a: App, purpose: string, paths: seq[string]) =
  if paths.len == 0: return
  case purpose
  of "open": a.openPaths(paths)
  of "opendir": a.openPaths(paths[0 .. 0])
  of "pladd": a.addToPlaylist(paths)
  of "plload": a.loadPlaylist(paths[0])
  of "plsave": a.savePlaylist(paths[0])
  of "savemedia": a.startSave(paths[0])
  of "bmexport": a.exportBookmarks(paths[0])
  of "bmimport": a.importBookmarks(paths[0])
  of "pickpath":  # Run window, a path row's folder button
    let d = a.pickDlg
    if a.pickOpen and d.browseRow >= 0 and d.browseRow < d.texts.len:
      d.texts[d.browseRow] = paths[0]
      a.pickWin.activate()
  of "extfile":
    if a.extQueue.len > 0:
      a.extPicks[a.extQueue[0]] = paths[0].absolutePath
      a.extQueue.delete(0)
      a.askExternal()
  of "optmkvpe":  # Options' mkvpropedit Browse... button
    if a.overlay == ovOptions: a.cfg.mkvpropedit = paths[0]
  of "optytdlp":  # Options' yt-dlp Browse... button
    if a.overlay == ovOptions: a.cfg.ytdlp = paths[0]
  of "optshotdir", "optopendir", "optwebdir":  # Options' Browse... buttons
    if a.overlay == ovOptions:
      if purpose == "optshotdir": a.cfg.screenshotDir = paths[0]
      elif purpose == "optwebdir": a.cfg.webDir = paths[0]
      else: a.cfg.openDir = paths[0]
  of "subtitle":
    if a.player.loaded: a.player.h.command("sub-add", paths[0], "select")
  of "audio":
    if a.player.loaded: a.player.h.command("audio-add", paths[0], "select")
  of "screenshot":
    var p = paths[0]
    if p.splitFile.ext.len == 0: p.add ".png"
    if a.player.h.command("screenshot-to-file", p, "video") >= 0:
      a.osd("Screenshot saved: " & p.extractFilename)
    else:
      a.osd("Screenshot failed")

proc pollDialog(a: App) =
  if a.dialog == nil: return
  var done: bool
  let res = a.dialog.poll(done)
  if done:
    let purpose = a.dialog.purpose
    a.dialog = nil
    a.handleDialogResult(purpose, res)

# --- properties -------------------------------------------------------------

proc gatherProperties(a: App) =
  ## MediaInfo-style report, plus how this player is decoding the file.
  let h = a.player.h
  a.props = gatherMediaInfo(h, a.player.path)
  a.propScroll = 0
  var p = InfoSection(title: "Playback")
  template add(k, v: string) =
    if v.len > 0: p.rows.add (k, v)
  if a.player.hasVideo:
    add "Video decoder", h.getStr("video-codec")
    add "Hardware decoding", h.getStr("hwdec-current")
    add "Decoded pixel format", h.getStr("video-params/pixelformat")
    add "Display size", &"{a.player.videoW} x {a.player.videoH}"
    add "Video output", h.getStr("current-vo")
  add "Audio decoder", h.getStr("audio-codec")
  add "Audio output", h.getStr("current-ao")
  add "Audio device", h.getStr("audio-device")
  if p.rows.len > 0: a.props.add p

# --- settings -----------------------------------------------------------------

proc langList(s: string): string =
  ## "eng, jpn" or "eng jpn" -> "eng,jpn" (mpv's list syntax).
  s.multiReplace((";", ","), (" ", ",")).split(',').filterIt(it.len > 0).join(",")

proc coverNameList(s: string): seq[string] =
  ## Options' folder picture names, one per line, as mpv takes them.
  s.splitLines.mapIt(it.strip).filterIt(it.len > 0)

proc subPathList(s: string): string =
  ## "Subs; ~/subs" -> "Subs:/home/me/subs" (mpv's path-list syntax).
  s.split(';').mapIt(it.strip.expandTilde).filterIt(it.len > 0).join(":")

proc applyOsd(a: App) =
  ## Level 3 adds the time / duration status line to the OSD. With the OSD
  ## apart (see osdLayer), mpv's own stays off.
  let level = if not a.cfg.showOsd: "0" elif a.cfg.osdTimestamp: "3" else: "1"
  a.player.h.setProp("osd-level", if a.osdApart: "0" else: level)
  if a.osdLayer != nil:
    a.osdLayer.h.setProp("osd-level", if a.osdApart: level else: "0")
  # Empty osd-msg3 is mpv's built-in elapsed-time line.
  let f = if a.cfg.showMillis: "/full" else: ""
  a.player.h.setProp("osd-msg3", if not a.cfg.showRemaining: "" else:
    "${osd-sym-cc} -${time-remaining" & f & "} / ${duration" & f & "} (${percent-pos}%)")

proc syncSettings(a: App) =
  ## Pushes the player-facing options to mpv (and the title) when they change.
  let c = a.cfg
  let key = &"{c.showOsd}|{c.osdTimestamp}|{c.showMillis}|{c.showRemaining}|{c.subLangs}|{c.audioLangs}|{c.subDelay}|" &
    &"{c.subPaths}|{c.titleFullPath}|{c.titleUseMediaTitle}|{c.subFont}|{c.subBold}|{c.subItalic}|" &
    &"{c.subSize}|{c.subSpacing}|{c.subLineSpacing}|{c.subColor}|{c.subOpacity}|{c.subOutlineSize}|{c.subOutlineColor}|" &
    &"{c.subOutlineOpacity}|{c.subShadowOffset}|{c.subShadowColor}|{c.subShadowOpacity}|{c.subStyleAss}"
  # The cover's apart: showing or hiding it picks the video track, which
  # other settings changing mustn't do again.
  if not a.coverSynced or c.coverNames != a.coverNames:
    a.coverNames = c.coverNames
    a.player.setCoverNames(coverNameList(c.coverNames))
  if not a.coverSynced or c.showCover != a.coverShown:
    a.coverShown = c.showCover
    a.player.showCover(c.showCover)
  a.coverSynced = true
  if key == a.settingsKey: return
  a.settingsKey = key
  a.applyOsd()
  let h = a.player.h
  h.setProp("slang", langList(c.subLangs))
  h.setProp("alang", langList(c.audioLangs))
  h.setProp("sub-delay", c.subDelay / 1000)
  h.setProp("osd-fractions", if c.showMillis: "yes" else: "no")
  h.setProp("sub-file-paths", subPathList(c.subPaths))
  # Options > Subtitles style: text subtitles (SRT...), and ASS ones too when asked.
  let font = c.subFont.strip
  h.setProp("sub-font", if font.len > 0: font else: "sans-serif")
  h.setProp("sub-bold", c.subBold)
  h.setProp("sub-italic", c.subItalic)
  h.setProp("sub-font-size", clamp(c.subSize, 1, 300))
  h.setProp("sub-spacing", clamp(c.subSpacing, -10, 10))
  h.setProp("sub-line-spacing", clamp(c.subLineSpacing, -100, 200))
  h.setProp("sub-color", mpvColor(c.subColor, c.subOpacity, "#FFFFFF"))
  h.setProp("sub-outline-size", max(c.subOutlineSize, 0))
  h.setProp("sub-outline-color", mpvColor(c.subOutlineColor, c.subOutlineOpacity, "#000000"))
  h.setProp("sub-shadow-offset", max(c.subShadowOffset, 0))
  h.setProp("sub-back-color", mpvColor(c.subShadowColor, c.subShadowOpacity, "#000000"))
  h.setProp("sub-ass-override", if c.subStyleAss: "force" else: "scale")
  a.updateTitle()

proc recordEnd(a: App)
proc switchQuality(a: App, url: string)
proc pruneSaved(a: App)

proc hookYtdlp(a: App)

proc rendererChanged(a: App, before: RenderMode)

proc closeOptions(a: App, ok: bool) =
  if ok:
    a.cfg.save()
    a.rendererChanged(a.cfgBefore.renderMode)
    # Another folder for links: its own index, the current one left as is.
    let dir = a.cfg.webDir.expandPath
    if (if dir.len > 0: dir else: defaultSaveDir()) != saveDir():
      a.recordEnd()
      a.handoffOff()
      a.saveLinkInfos()
      setSaveDir(dir)
      a.saved = loadSaveIndex()
      a.linkInfos = loadLinkInfos()
      a.linkInfosRead.clear()
    a.pruneSaved()
    a.hookYtdlp()  # another yt-dlp chosen: mpv opens links with it
  else:
    let swatches = a.cfg.colorSwatches  # saved colors stay, like the recent files
    let (recents, titles) = (a.cfg.recentFiles, a.cfg.recentTitles)
    let eq = (a.cfg.equalizerOn, a.cfg.equalizerGains)  # its own window's, not Options'
    a.cfg = a.cfgBefore  # undo the live edits
    a.cfg.colorSwatches = swatches
    (a.cfg.recentFiles, a.cfg.recentTitles) = (recents, titles)
    (a.cfg.equalizerOn, a.cfg.equalizerGains) = eq
  a.optUi.focusId = ""
  a.overlay = ovNone
  a.syncSettings()
  if a.optWin.visible:
    a.optWin.visible = false
    a.window.activate()

proc newDialogWindow(a: App, title: string, size: IVec2, modal = true): (Window, Silky, Ui) =
  ## A hidden dialog window over the main one, with its own Silky and Ui.
  let w = newWindow(title, size, style = Decorated, visible = false,
    vsync = false)
  # Windy made the new window's own context current; it is drawn with the
  # main one instead (same visual), sharing the atlas texture and shaders.
  makeContextCurrent(a.window)
  w.icon = appIcon()
  w.setDialogFor(a.window, modal)
  let sk = newSilky(w, a.atlasImg, a.atlas)
  sk.uiScale = a.sk.uiScale
  sk.atlasScale = a.sk.atlasScale
  let ui = newUi(sk, w)
  let touch = proc () = a.dirtyUntil = now() + 1.2
  let input = proc () =
    touch()
    a.inputPending = true
  w.onMouseMove = touch
  w.onFocusChange = touch
  w.onResize = touch
  w.onScroll = input
  w.onButtonPress = proc (b: Button) = input()
  w.onButtonRelease = proc (b: Button) = input()
  w.onRune = proc (r: Rune) =
    input()
    ui.typedPending.add $r
  (w, sk, ui)

proc ensureOptionsWindow(a: App) =
  if a.optWin != nil: return
  (a.optWin, a.optSk, a.optUi) = a.newDialogWindow("Options", OptionsSize)

proc showDialog(a: App, w: Window, size: IVec2) =
  ## Centres a dialog's frame on the main window's frame (both have the
  ## same decorations), kept on the main window's monitor. size is in UI units.
  let size = a.px(size)
  var pos = a.window.framePos + (a.window.size - size) div 2
  let m = monitorAt(a.window.pos + a.window.size div 2)
  pos.x = clamp(pos.x, m.pos.x, max(m.pos.x, m.pos.x + m.size.x - size.x))
  pos.y = clamp(pos.y, m.pos.y, max(m.pos.y, m.pos.y + m.size.y - size.y))
  w.placeDialog(pos, size)
  w.visible = true
  w.activate()

proc uiScale(a: App): float32 = float32(clamp(a.cfg.uiScale, 50, 300) / 100)

proc applyUiScale(a: App) =
  ## Rebuilds the atlas when Options > Player > UI scaling changed; windows
  ## sized in UI units follow (the main window keeps its size).
  let s = a.uiScale
  if s == a.sk.uiScale: return
  let (img, atlas) = buildAtlas(s)
  (a.atlasImg, a.atlas) = (img, atlas)
  for sk in [a.sk, a.optSk, a.renSk, a.cmdSk, a.pickSk, a.syncSk, a.ytSk, a.embSk, a.upSk, a.eqSk]:
    if sk == nil: continue
    (sk.image, sk.atlas, sk.builder) = (img, atlas, AtlasBuilder(nil))
    sk.uiScale = s
    sk.atlasScale = s
    sk.uploadAtlas()
  for (w, size) in [(a.optWin, OptionsSize), (a.renWin, RenameSize), (a.cmdWin, CommandsSize),
                    (a.syncWin, SyncSize), (a.ytWin, YtdlpSize), (a.embWin, EmbedSize),
                    (a.upWin, UpdateSize), (a.eqWin, EqualizerSize)]:
    if w != nil and w.visible: a.showDialog(w, size)
  if a.pickWin != nil and a.pickWin.visible:
    let (sw, sh) = a.pickDlg.size
    a.showDialog(a.pickWin, ivec2(sw, sh))
  a.dirtyUntil = now() + 0.5

proc previewBookmark(a: App) =
  ## With Preview checked, playback jumps to the bookmark being edited.
  if not a.cfg.bookmarkPreview or not a.player.loaded or a.renPath != a.player.path: return
  a.seekTo(a.renTime)
  a.renSeeked = true

proc showRename(a: App, i: int) =
  ## Opens the Edit Bookmark dialog for the current file's bookmark i.
  let marks = a.fileBookmarks
  if i < 0 or i >= marks.len: return
  a.menus.close()
  a.renPath = a.player.path
  a.renTime = marks[i].time
  a.renOrigTime = a.renTime
  a.renTimeText = fmtTime(a.renTime, true, a.player.duration)
  a.renText = marks[i].name
  a.renPlaceholder = marks[i].label(i)
  a.renOrigPos = a.player.timePos
  a.renSeeked = false
  a.previewBookmark()
  if a.renWin == nil:
    (a.renWin, a.renSk, a.renUi) = a.newDialogWindow("Edit Bookmark", RenameSize)
  # Type right away, the caret after the current name.
  a.renUi.focusId = "ren-name"
  a.renUi.focusFresh = true
  a.showDialog(a.renWin, RenameSize)
  a.overlay = ovRename

proc closeRename(a: App, keep = false) =
  ## Closes the Edit Bookmark dialog; unless kept, as on Cancel, the
  ## bookmark goes back to where it was.
  if not keep and a.renTime != a.renOrigTime:
    discard a.moveBookmark(a.renPath, a.renTime, a.renOrigTime)
    a.renTime = a.renOrigTime
  # Playback too, when Preview moved it.
  if not keep and a.renSeeked and a.renPath == a.player.path: a.seekTo(a.renOrigPos)
  a.renUi.focusId = ""
  a.overlay = ovNone
  if a.renWin.visible:
    a.renWin.visible = false
    a.window.activate()

# --- Embed As MKV Chapters ---------------------------------------------------
# The current file's bookmarks written into it as chapters by mkvpropedit
# (MKVToolNix), in place; the chapters it has already are kept.

const MatroskaExts = [".mkv", ".mka", ".mk3d", ".webm"]

proc closeDialogs(a: App)  # below
proc closeUpdate(a: App)  # Check for Updates, below
proc shortPath(path: string): string  # yt-dlp, below

proc canEmbed(a: App): bool =
  ## A Matroska file on disk, with bookmarks, and nothing being written yet.
  let p = a.player
  p.loaded and not p.path.isWebLink and p.path.splitFile.ext.toLowerAscii in MatroskaExts and
    a.fileBookmarks.len > 0 and a.embProc == nil

proc showEmbedWindow(a: App, mode: EmbedMode, msg = "") =
  a.menus.close()
  if a.overlay notin {ovNone, ovEmbed}: a.closeDialogs()
  if a.embWin == nil:
    (a.embWin, a.embSk, a.embUi) = a.newDialogWindow("Embed As MKV Chapters", EmbedSize)
  a.embMode = mode
  a.embMsg = msg
  if a.overlay != ovEmbed:
    a.embUi.focusId = ""
    a.showDialog(a.embWin, EmbedSize)
    a.overlay = ovEmbed

proc showEmbed(a: App) =
  ## Asks whether to embed the current file's bookmarks, and whether to keep
  ## them; first, without mkvpropedit, whether to install MKVToolNix.
  a.menus.close()
  if not a.canEmbed: return
  a.embPath = a.player.path
  if a.mkvJob.running: a.showEmbedWindow(emBusy, a.embMsg)
  elif findMkvpropedit(a.cfg.mkvpropedit).len > 0: a.showEmbedWindow(emAsk)
  elif canInstallMkvtoolnix(): a.showEmbedWindow(emInstall)
  else: a.osd("Embedding chapters needs mkvpropedit (MKVToolNix)")

proc closeEmbed(a: App) =
  a.embUi.focusId = ""
  if a.overlay == ovEmbed: a.overlay = ovNone
  if a.embWin.visible:
    a.embWin.visible = false
    a.window.activate()

proc embedChapters(a: App): seq[Bookmark] =
  ## The file's chapters and bookmarks together, by time, all named. A
  ## bookmark at a chapter's time takes its place, keeping its title when the
  ## bookmark has no name of its own.
  let marks = a.fileBookmarks
  for c in a.player.chapters:
    if not marks.anyIt(abs(it.time - c.time) < 0.05):
      result.add Bookmark(time: c.time, name: c.title)
  for i, b in marks:
    var name = b.name
    if name.len == 0:
      for c in a.player.chapters:
        if abs(c.time - b.time) < 0.05 and c.title.len > 0: name = c.title
    result.add Bookmark(time: b.time, name: (if name.len > 0: name else: b.label(i)))
  result.sort(proc (x, y: Bookmark): int = cmp(x.time, y.time))
  for i, b in result.mpairs:
    if b.name.len == 0: b.name = &"Chapter {i + 1}"

proc startEmbed(a: App, clear: bool) =
  ## Runs mkvpropedit on the file asked about, if it's still the one playing.
  if a.embProc != nil or not a.player.loaded or a.player.path != a.embPath: return
  a.embTmp = getTempDir() / &"majestic-chapters-{getCurrentProcessId()}.txt"
  try:
    # The BOM: without one, mkvpropedit reads it in the system's code page.
    writeFile(a.embTmp, "\xEF\xBB\xBF" & a.embedChapters.toSimpleChapters)
  except IOError, OSError:
    a.osd("Cannot write the chapters file")
    return
  const opts = when defined(windows): {poUsePath, poStdErrToStdOut, poDaemon}
               else: {poUsePath, poStdErrToStdOut}
  try:
    a.embProc = startProcess(findMkvpropedit(a.cfg.mkvpropedit), args = @[a.embPath, "--chapters", a.embTmp],
      options = opts)
  except OSError as e:
    a.osd("Cannot run mkvpropedit: " & e.msg)
    return
  a.embClear = clear
  a.osd("Embedding chapters...")

proc mkvStatus(a: App): string =
  ## Installing MKVToolNix, for the status bar; "" when not.
  let j = a.mkvJob
  if not j.running: return
  result = "Installing MKVToolNix"
  if j.stage == mkDownload and j.progress >= 0: result.add &" {int(j.progress)}%"

proc embAnswer(a: App, ok: bool, clear = false) =
  ## The Embed As MKV Chapters window's buttons: embed (keeping the bookmarks
  ## or clearing them) or install MKVToolNix; else cancel, close or hide.
  let mode = a.embMode
  a.closeEmbed()
  if not ok: return
  case mode
  of emAsk: a.startEmbed(clear)
  of emInstall:
    a.mkvJob = installMkvtoolnix()
    a.showEmbedWindow(emBusy, "Installing MKVToolNix's mkvpropedit to " &
      shortPath(mkvManagedPath()) & "...")
  of emBusy, emFailed: discard

proc pollMkvtoolnix(a: App) =
  ## Once MKVToolNix is installed, asks about embedding as it would have.
  let j = a.mkvJob
  if j == nil or not j.poll(): return
  a.dirtyUntil = max(a.dirtyUntil, now() + 0.1)
  if j.running: return
  a.mkvJob = nil
  if j.code != 0:
    a.showEmbedWindow(emFailed, "MKVToolNix couldn't be installed: " & j.errorText)
    return
  a.osd("MKVToolNix installed")
  if a.canEmbed and a.player.path == a.embPath: a.showEmbedWindow(emAsk)
  elif a.overlay == ovEmbed: a.closeEmbed()

proc pollEmbed(a: App) =
  ## Once mkvpropedit is done: clears the bookmarks when asked to, and opens
  ## the file anew where it was, for mpv to read its new chapters.
  a.pollMkvtoolnix()
  let pr = a.embProc
  if pr == nil or pr.peekExitCode == -1: return
  let code = pr.peekExitCode
  let output = try: pr.outputStream.readAll except IOError, OSError: ""
  pr.close()
  a.embProc = nil
  try: removeFile(a.embTmp)
  except OSError: discard
  let path = a.embPath
  # 1: done, with warnings.
  if code notin {0, 1}:
    var err = ""
    for line in output.splitLines:
      if line.startsWith("Error:"): err = line[6 .. ^1].strip
    a.osd("Embedding chapters failed" & (if err.len > 0: ": " & err else: ""))
    return
  # The contents changed, so did their key: the bookmarks go under the new one.
  a.keyKnown(path, mediaKey(path))
  if a.embClear: a.editBookmarks(path, proc (marks: var seq[Bookmark]) = marks.setLen 0)
  if a.player.loaded and a.player.path == path and
     a.plIndex >= 0 and a.plIndex < a.playlist.len and a.playlist[a.plIndex] == path:
    a.playIndex(a.plIndex, a.player.timePos)
  a.osd("Chapters embedded" & (if a.embClear: ", bookmarks cleared" else: ""))

proc showSyncProps(a: App) =
  ## Opens Synchronize > Properties on this player.
  a.menus.close()
  if a.syncWin == nil:
    (a.syncWin, a.syncSk, a.syncUi) = a.newDialogWindow("Synchronize Properties", SyncSize)
    a.syncDlg = newSyncDialog()
  a.syncDlg.selected = a.peers.pid
  a.syncUi.focusId = ""
  a.showDialog(a.syncWin, SyncSize)
  a.overlay = ovSync

proc closeSyncProps(a: App) =
  a.syncUi.focusId = ""
  a.overlay = ovNone
  if a.syncWin.visible:
    a.syncWin.visible = false
    a.window.activate()

proc toggleEqualizer(a: App) =
  ## Shows the Equalizer window, or hides it. Not a dialog the player waits
  ## on: both stay in use. It opens over the player the first time, where it
  ## was left after that.
  if a.eqWin != nil and a.eqWin.visible:
    a.eqPos = a.eqWin.framePos
    a.eqUi.focusId = ""
    a.eqWin.visible = false
    a.window.activate()
  elif a.eqWin == nil:
    (a.eqWin, a.eqSk, a.eqUi) = a.newDialogWindow("Equalizer", EqualizerSize, modal = false)
    a.showDialog(a.eqWin, EqualizerSize)
  else:
    a.eqWin.placeDialog(a.eqPos, a.px(EqualizerSize))
    a.eqWin.visible = true
    a.eqWin.activate()

proc latestCommandLine(a: App): CommandLine =
  ## The command line created last (edits keep their place), else a new one.
  if a.commands.len > 0: a.commands[^1] else: CommandLine()

proc showCommands(a: App) =
  ## Opens the Commands window on the command line created last.
  a.menus.close()
  a.commands = loadCommandLines()
  a.cmdDlg.saved = a.commands
  a.cmdDlg.load(a.latestCommandLine)
  if a.cmdWin == nil:
    (a.cmdWin, a.cmdSk, a.cmdUi) = a.newDialogWindow("Commands", CommandsSize)
  a.cmdUi.focusId = "cl-title"
  a.cmdUi.focusFresh = true
  a.cmdUi.navVisible = false
  a.showDialog(a.cmdWin, CommandsSize)
  a.overlay = ovCommands

proc closeCommands(a: App) =
  a.cmdUi.focusId = ""
  a.overlay = ovNone
  if a.cmdWin.visible:
    a.cmdWin.visible = false
    a.window.activate()

proc editCommandLines(a: App, edit: proc (cmds: var seq[CommandLine])) =
  ## Like editBookmarks: applied to the file's latest contents.
  a.commands = loadCommandLines()
  edit(a.commands)
  a.commands.save()

proc frameEdgeAt(a: App, p: Vec2): set[WindowEdge] =
  ## The window edge under p (UI units) that resizes the window in compact
  ## mode, which has no frame to grab: its outermost pixels act as the border.
  ## Empty elsewhere, and when the window can't be resized. Always empty on
  ## Windows, where the window procedure reports those edges to the system.
  when defined(windows): return
  if not a.cfg.compactMode or a.fullscreen or a.window.maximized: return
  const Grip = 5'f32  # pixels
  let g = Grip / a.sk.uiScale
  let s = a.ui.size
  let (l, r, t, b) = (p.x < g, p.x >= s.x - g, p.y < g, p.y >= s.y - g)
  if t and l: {weTopLeft} elif t and r: {weTopRight}
  elif b and l: {weBottomLeft} elif b and r: {weBottomRight}
  elif t: {weTop} elif b: {weBottom} elif l: {weLeft} elif r: {weRight}
  else: {}

proc closeTip(a: App, act: KeyAction): string =
  ## Tooltip of a panel's close button, with the key that toggles the panel.
  let key = a.cfg.keyText(act)
  if key.len > 0: &"Close ({key})" else: "Close"

proc setPlaylistShown(a: App, shown: bool) =
  ## Shows or hides the playlist, growing or shrinking the window by its width.
  if a.cfg.showPlaylist == shown: return
  a.cfg.showPlaylist = shown
  let w = int32(a.playlistWidth)
  a.resizeKeepingVideo(ivec2(if shown: w else: -w, 0))

proc setRunLogShown(a: App, shown: bool) =
  ## Shows or hides the run log, growing or shrinking the window by its height.
  if a.cfg.showRunLog == shown: return
  a.cfg.showRunLog = shown
  if shown: a.rlFollow = true
  let h = int32(a.runLogHeight)
  a.resizeKeepingVideo(ivec2(0, if shown: h else: -h))

proc runDir(a: App): string =
  ## Where command lines run: the media file's folder, else home.
  let path = if a.player.loaded: a.player.path else: ""
  if path.len > 0 and not path.contains("://"): path.parentDir else: getHomeDir()

proc execute(a: App, c: CommandLine, picks = initTable[string, string]()) =
  ## Runs c with bash in the media file's folder, its cards resolved against
  ## the current file and picks (what the Run window gave each card). Output
  ## goes to the run log (and our stdout).
  var path = if a.player.loaded: a.player.path else: ""
  # A link: tools like ffmpeg can't open its page, so its file cards get a
  # file on disk, the saved one when all of it is, else one downloaded first.
  # With two timestamps or more (From and To), only the span between them is
  # downloaded, and the timestamps become times of that clip.
  var fetch, fetchErr, timeFix = ""
  if path.isWebLink and c.parts.anyIt(it.card and it.kind == ckReference and it.content == "file"):
    let local = a.savedFile(path)
    if local.len > 0: path = local
    elif findYtdlp(a.cfg.ytdlp).len == 0: fetchErr = "Opening links needs yt-dlp"
    else:
      var times: seq[float]
      for p in c.parts.runCards:
        if p.isTimestamp and p.name in picks:
          try: times.add parseTime(picks[p.name])
          except ValueError: discard
      let tmp = getTempDir() / &"majestic-{getCurrentProcessId()}-{int64(epochTime() * 1000)}"
      let file = tmp / "media.mkv"
      let (exe, cookies, format) = (findYtdlp(a.cfg.ytdlp), a.ytCookies.getOrDefault(path),
        a.saveFormat(path))
      fetch = "trap " & quoteShellPosix("rm -rf " & quoteShellPosix(tmp)) & " EXIT\n" &
        "mkdir -p " & quoteShellPosix(tmp) & " || exit\n"
      if times.len >= 2 and times.max > times.min:
        const Margin = 1.0  # seconds kept around the span
        let (lo, hi) = (max(0.0, times.min - Margin), times.max + Margin)
        fetch.add "echo " & quoteShellPosix(&"Downloading {fmtTime(lo, millis = true)}-" &
            &"{fmtTime(hi, millis = true)} of {path}") & "\n" &
          sectionScript(exe, path, file, lo, hi, cookies, format)
        timeFix = "mmp_clip"
      else:
        fetch.add "echo " & quoteShellPosix("Downloading " & path) & "\n" &
          downloadScript(exe, path, file, cookies, format)
      path = file
  var (script, err) = c.parts.compose(path, picks, timeFix)
  if fetchErr.len > 0: err = fetchErr
  script = fetch & script
  let dir = a.runDir
  let e = newRunEntry(c.title, dir)
  for p in c.parts:
    if not (p.isPath and p.reveal): continue
    let v = p.resolve(path, picks).value
    if v.len == 0: continue
    let f = if v.isAbsolute: v else: dir / v
    if f notin e.reveal: e.reveal.add f
  a.runLog.add e
  a.runLog.trim()
  a.rlFollow = true
  a.setRunLogShown(true)
  if err.len > 0:
    e.error = err
    a.osd(c.title & ": " & err)
    stderr.writeLine "run ", c.title, ": ", err
    return
  try:
    e.start(script)
    a.osd("Running " & c.title)
  except OSError as ex:
    e.error = "cannot run bash: " & ex.msg
    a.osd(c.title & ": cannot run bash")
    stderr.writeLine "run ", c.title, ": ", ex.msg

proc askExternal(a: App) =
  ## Asks for the next external file of a.extRun, then goes on with the run
  ## once all are chosen. Cancelling a dialog cancels the run.
  if a.extQueue.len > 0:
    a.ask(dkOpenFile, "extfile", a.extRun.title & ": " & a.extQueue[0])
    return
  let c = a.extRun
  let cards = c.parts.runCards
  if cards.len == 0:
    a.execute(c, a.extPicks)
    return
  if cards.anyIt(it.isTimestamp) and not a.player.loaded:
    a.osd(c.title & ": No media file is open")
    return
  a.menus.close()
  a.pickDlg.start(c, a.timeChoices, c.lastValues)
  let (sw, sh) = a.pickDlg.size
  if a.pickWin == nil:
    (a.pickWin, a.pickSk, a.pickUi) = a.newDialogWindow("Run", ivec2(sw, sh), modal = false)
  a.pickWin.title = c.title
  a.pickUi.focusId = ""
  a.pickUi.navId = "pk-0"
  a.pickUi.navVisible = false
  a.showDialog(a.pickWin, ivec2(sw, sh))

proc runCommandLine(a: App, c: CommandLine) =
  ## Runs c, first asking for its external files, timestamps and values when
  ## it has any.
  a.extRun = c
  a.extQueue = c.parts.externalCards
  a.extPicks = initTable[string, string]()
  a.askExternal()

proc closePick(a: App) =
  a.rectEdit = nil
  a.pickDlg.drawing = 0
  if a.pickWin.visible:
    a.pickWin.visible = false
    a.window.activate()

proc pollJobs(a: App) =
  for e in a.runLog:
    if not e.running or not e.poll(): continue
    if a.cfg.showRunLog: a.dirtyUntil = max(a.dirtyUntil, now() + 0.1)
    if not e.running:
      a.osd(if e.stopped: e.title & " stopped"
        elif e.code == 0: e.title & " finished"
        else: &"{e.title} failed (exit code {e.code})")
      if e.code == 0 and not e.stopped:
        for f in e.reveal: a.showInFolder(f)

# --- yt-dlp -------------------------------------------------------------------
# A link mpv can't open (its yt-dlp hook included) goes on from here: its
# stream is tried again at once (YouTube turns some down now and then), then
# yt-dlp is installed when missing, or updated when a newer one is out.
# Nothing is downloaded whole: a link always streams.

proc shortPath(path: string): string =
  ## path with the home folder as "~".
  let home = getHomeDir().strip(leading = false, chars = {DirSep})
  if path.startsWith(home & DirSep): "~" & path[home.len .. ^1] else: path

const HookStart = 0.5  ## seconds for a newly loaded mpv hook script to get going

proc hookYtdlp(a: App) =
  ## Lets mpv open links through yt-dlp, once there is one. mpv keeps the
  ## path it first found, so outside Windows it gets a link of ours, moved
  ## to whichever yt-dlp is found now.
  let exe = findYtdlp(a.cfg.ytdlp)
  if exe.len == 0 or exe == a.ytHooked: return
  var path = exe
  when not defined(windows):
    let link = getCacheDir("majestic-media-player") / "yt-dlp-exe"
    try:
      createDir(link.parentDir)
      if symlinkExists(link) or fileExists(link): removeFile(link)
      createSymlink(exe, link)
      path = link
    except OSError: discard
  # Moving the link is enough for a hook that has it already. The standby
  # opens links too (webHandoff), and takes turns with the player.
  if a.ytHooked.len == 0 or path == exe:
    for p in [a.player, a.standby]:
      if p != nil: p.useYtdlp(path)
  a.ytHooked = exe

proc ytStatus(a: App): string =
  ## What yt-dlp is doing, for the status bar; "" when nothing.
  let j = a.ytJob
  if not j.running: return
  case j.task
  of ytVersion, ytLatest: result = "Checking yt-dlp"
  of ytUpdate: result = "Updating yt-dlp"
  of ytInstall:
    result = "Installing yt-dlp"
    if j.progress >= 0: result.add &" {int(j.progress)}%"
  of ytCaptions, ytSubs, ytPlaylist, ytInfo, ytDownload: discard  # their own slots, quietly

proc ytCurrentLink(a: App): string =
  if a.plIndex in 0 ..< a.playlist.len: a.playlist[a.plIndex] else: ""

proc ytOpen(a: App, url: string, delay = 0.0) =
  ## Streams url again (from where it was tried), unless another entry has
  ## been opened meanwhile.
  if delay > 0:
    (a.ytRetry, a.ytRetryAt, a.ytRetryNet) = (url, now() + delay, false)
  elif url.len > 0 and a.ytCurrentLink == url:
    if a.streamArgs.url == url: a.streamLink(url, a.streamArgs.start, a.streamArgs.opts)
    else: a.playIndex(a.plIndex)

proc ytGiveUp(a: App) =
  ## The link's stream failed, yt-dlp as new as it gets. yt-dlp's reason, when
  ## it gave one: mpv's is then about the web page it tried in its place.
  let p = a.player
  if p.hookError.len > 0:
    a.ytError = errorReason(p.hookError)
    if a.ytCookieTried.len > 0:
      a.ytError.add " (not signed in on " & a.ytCookieTried.join(", ") & ")"
    elif not wantsSignIn(p.hookError): discard
    elif a.cfg.signInCookies.strip.toLowerAscii == "none":
      a.ytError.add " (signing in is off: Options > Playback)"
    else: a.ytError.add " (no browser found to sign in with)"
  else:
    a.ytError = "couldn't stream it" &
      (if p.loadError.len > 0: " (" & p.loadError & ")" else: "")
  a.osd("Couldn't open the link: " & a.ytError, OsdError)

proc closeDialogs(a: App) =
  ## Closes whichever dialog or overlay is up (as Cancel would).
  case a.overlay
  of ovOptions: a.closeOptions(false)
  of ovRename: a.closeRename()
  of ovCommands: a.closeCommands()
  of ovSync: a.closeSyncProps()
  of ovYtdlp:
    a.ytUi.focusId = ""
    a.ytWin.visible = false
  of ovEmbed: a.closeEmbed()
  of ovUpdate: a.closeUpdate()
  else: discard
  a.overlay = ovNone

proc showYtdlp(a: App, mode: YtMode, msg = "") =
  a.menus.close()
  if a.overlay notin {ovNone, ovYtdlp}: a.closeDialogs()
  if a.ytWin == nil:
    (a.ytWin, a.ytSk, a.ytUi) = a.newDialogWindow("yt-dlp", YtdlpSize)
  a.ytMode = mode
  a.ytMsg = msg
  if a.overlay != ovYtdlp:
    a.ytUi.focusId = ""
    a.showDialog(a.ytWin, YtdlpSize)
    a.overlay = ovYtdlp

proc closeYtdlp(a: App) =
  ## Hides the yt-dlp window. Turning down an update gives up on the link.
  let declined = a.ytMode == ymUpdate
  a.ytUi.focusId = ""
  if a.overlay == ovYtdlp: a.overlay = ovNone
  if a.ytWin.visible:
    a.ytWin.visible = false
    a.window.activate()
  if declined: a.ytGiveUp()

const
  StreamTries = 2     ## a link's stream is tried again at once this many times
  StallTimeout = 20.0 ## a stream waiting this long for data without any is dropped
  StallProbe = 2.0    ## one waiting this long has the network probed
  ResumeGrace = 3.0   ## once it's back, mpv's own reconnecting gets this long
                      ## (seconds) to bring the stream back before it's reopened
  ProbeEvery = 1.0    ## seconds between network probes
  DropDelays = [0.0, 2, 4, 8, 15, 15, 15, 15, 15, 15]
    ## a dropped stream is reopened after each of these in turn (seconds),
    ## the network maybe still coming back; at once when it answers again
    ## after it didn't, never while it doesn't

proc ytSignIn(a: App, url: string): bool =
  ## The link asked to sign in (or the browser yt-dlp signed in with didn't
  ## do): its stream again with the next browser's cookies, else it gives up.
  ## False when the failure is about something else.
  let err = a.player.hookError
  if a.ytCookieTried.len == 0 and a.ytCookies.getOrDefault(url).len > 0:
    a.ytCookieTried.add a.ytCookies[url]  # from an earlier opening
  # Its cookies couldn't be read (no profile, locked keyring...): the next one.
  let unread = a.ytCookieTried.len > 0 and "cookie" in err.toLowerAscii
  if not (wantsSignIn(err) or unread): return
  for b in cookieBrowsers(a.cfg.signInCookies):
    if b in a.ytCookieTried: continue
    a.ytCookieTried.add b
    a.ytCookies[url] = b
    a.osd("Signing in with " & b & "'s cookies...")
    a.ytOpen(url)
    return true
  a.ytCookies.del url
  a.ytGiveUp()
  true

proc ytFailed(a: App, url: string) =
  ## A link didn't open: its stream again, else on to yt-dlp.
  if a.ytJob.running and a.ytJob.task in {ytUpdate, ytInstall}: return
  if a.ytJob.running: a.ytJob.stop()
  a.ytUrl = url
  a.ytError = ""
  if a.ytSignIn(url): return
  let exe = findYtdlp(a.cfg.ytdlp)
  if exe.len == 0:
    a.showYtdlp(ymInstall)
  elif exe != a.ytHooked:
    a.hookYtdlp()  # installed meanwhile: mpv tries again with it
    a.ytOpen(url, HookStart)
  elif a.ytTries < StreamTries:
    inc a.ytTries
    a.osd("Couldn't stream the link" & (if a.player.loadError.len > 0:
      " (" & a.player.loadError & ")" else: "") & ", trying again...", OsdError)
    a.ytOpen(url)
  else:
    (a.ytCurrent, a.ytLatest) = ("", "")
    a.ytJob = version(exe)

proc reconnect(a: App, url: string) =
  ## The link's stream dropped (the system slept, the network went away): it
  ## opens again where it was, waiting longer each time for the network.
  if a.dropTries >= DropDelays.len:
    a.dropTries = 0
    a.ytFailed(url)
    return
  a.osd("Connection lost, reconnecting...", OsdError)
  (a.ytRetry, a.ytRetryAt, a.ytRetryNet) = (url, now() + DropDelays[a.dropTries], true)
  (a.netUp, a.netBackAt) = (0, 0.0)  # what it is now, not what it was
  inc a.dropTries

proc probeNet(a: App, url: string) =
  ## Keeps asking url's host whether the network's there (netUp).
  if a.netProbe.poll():
    a.netUp = if a.netProbe.up: 1 else: -1
    if a.netUp < 0: (a.netWasDown, a.netBackAt) = (true, 0.0)
    elif a.netWasDown and a.netBackAt == 0: a.netBackAt = now()
  if a.netProbe.running or now() < a.netProbeAt: return
  a.netProbeAt = now() + ProbeEvery
  a.netProbe = probeHost(url)
  if a.netProbe == nil and a.ytRetryNet:
    a.ytRetryNet = false  # no curl: reopened after the delays alone

proc ytInstall(a: App, msg: string) =
  a.ytJob = install()
  a.showYtdlp(ymBusy, msg)

proc ytAnswer(a: App, ok: bool) =
  ## The yt-dlp window's buttons: install or update, else close it.
  if ok and a.ytMode == ymInstall:
    a.ytInstall("Installing yt-dlp to " & shortPath(managedPath()) & "...")
  elif ok and a.ytMode == ymUpdate:
    a.ytJob = update(findYtdlp(a.cfg.ytdlp))
    a.showYtdlp(ymBusy, "Updating yt-dlp (yt-dlp -U)...")
  else: a.closeYtdlp()

proc addCaptions(a: App, url: string) =
  for c in a.ytCaptions.getOrDefault(url):
    a.player.h.commandAsync("sub-add", c.url, "auto", c.title, c.lang)

proc addStyled(a: App, url: string) =
  ## A link's styled subtitles, in the place of its plain ones in that language
  ## (the automatic captions, in the same language, are something else; saved
  ## files have their language in their name alone).
  let p = a.player
  p.refreshTracks()
  for t in a.ytStyled.getOrDefault(url):
    var (plain, selected, styled) = (0, false, false)
    for old in p.tracks:
      if old.kind != "sub" or not old.external or old.title.endsWith(" (automatic)") or
         old.lang != t.lang and not old.file.splitFile.name.endsWith("." & t.lang): continue
      if old.file.endsWith(".ass"): styled = true
      else: (plain, selected) = (old.id, old.selected)
    if styled: continue
    if plain != 0: p.h.command("sub-remove", $plain)
    # Not async: each would land whenever it's parsed, out of order in the menu.
    p.h.command("sub-add", t.path, if selected: "select" else: "auto", t.title, t.lang)

proc styleSaved(a: App, url: string) =
  ## A saved link's subtitles, styled from now on where they can be.
  if not a.saved.lookup(url).subsDone: return
  for t in a.ytStyled.getOrDefault(url):
    for f in a.entry(url).subs.mitems:
      if f.endsWith(".ass") or not f.splitFile.name.endsWith("." & t.lang): continue
      try:
        copyFile(t.path, f.changeFileExt("ass"))
        removeFile(f)
        f = f.changeFileExt("ass")
      except OSError, IOError: discard
  a.saved.save()

proc hookSubs(p: Player): seq[SubLink] =
  ## The subtitles mpv's yt-dlp hook found, as srv3: there from the start,
  ## where the lookup (captions) takes its time.
  for t in p.tracks:
    if t.kind == "sub" and t.external and "fmt=srt" in t.file and
       not t.title.endsWith(" (automatic)"):
      # Wrapped in an edl:// until it's first read.
      let link = t.file[max(t.file.find("https://"), 0) .. ^1]
      result.add (link.replace("fmt=srt", "fmt=srv3"), t.title, t.lang)

proc startStyling(a: App, url: string) =
  ## A link's styled subtitles: those found before, else the hook's.
  let p = a.player
  p.refreshTracks()
  if url in a.ytStyled: a.addStyled(url)
  elif a.ytStyling == nil or a.ytStyling.link != url:
    a.ytStyling.cancel()
    a.ytStyling = fetchStyled(url, p.hookSubs)

proc pollStyled(a: App) =
  let wasLoading = a.ytStyling.loading
  let finished = a.ytStyling.poll()
  if finished or a.ytStyling.loading != wasLoading:
    a.dirtyUntil = max(a.dirtyUntil, now() + 0.1)  # the status bar's note
  if not finished: return
  let j = a.ytStyling
  a.ytStyling = nil
  a.ytStyled[j.link] = j.done
  a.styleSaved(j.link)
  if a.player.path == j.link and a.player.loaded: a.addStyled(j.link)

proc pollYtList(a: App) =
  ## A YouTube playlist's videos, as yt-dlp finds them: those before the
  ## link's own video go before it, the rest after (a playlist alone: the
  ## first in its place, playing).
  let j = a.ytList
  if j == nil or not j.poll(): return
  a.dirtyUntil = max(a.dirtyUntil, now() + 0.1)
  let link = j.url
  let id = link.youtubeId
  while a.ytListUsed < j.items.len:
    let (vid, title, dur) = j.items[a.ytListUsed]
    inc a.ytListUsed
    let url = "https://www.youtube.com/watch?v=" & vid
    if dur > 0: a.mediaInfo.mgetOrPut(url, MediaInfo()).duration = dur
    a.noteLink(url, title, MediaInfo(duration: dur))
    let at = a.playlist.find(if a.ytListLast.len > 0: a.ytListLast else: link)
    if at < 0 or a.playlistLocked:  # gone from the playlist meanwhile
      j.stop()
      a.ytList = nil
      return
    if vid == id and a.ytListLast.len == 0:
      a.ytListLast = link
      if link notin a.linkTitles: a.linkTitles[link] = title
      continue
    a.linkTitles[url] = title
    if id.len == 0 and a.ytListLast.len == 0:
      a.playlist[at] = url
      a.ytListLast = url
      a.playIndex(at)
      continue
    if url in a.playlist:  # brought back from a previous run, or listed before
      if a.ytListLast.len > 0: a.ytListLast = url
      continue
    let pos = if a.ytListLast.len > 0: at + 1 else: at
    a.playlist.insert(url, pos)
    if a.plIndex >= pos: inc a.plIndex
    if a.plSelected >= pos: inc a.plSelected
    for m in a.plMarks.mitems:
      if m >= pos: inc m
    if a.ytListLast.len > 0: a.ytListLast = url
  if j.running: return
  a.ytList = nil
  if j.code != 0 and a.ytListUsed == 0:
    a.ytListed.excl link  # to try again
    a.osd("Couldn't load the playlist: " & errorReason(j.errorText), OsdError)
  elif a.ytListUsed > 1 or id.len == 0:
    a.osd(&"Playlist: {a.ytListUsed} videos")

proc goOnline(a: App, t: float, stopped = false)

var traceAt = 0.0
proc pollYtdlp(a: App) =
  let p = a.player
  if existsEnv("MMP_TRACE") and now() - traceAt >= 0.5:
    traceAt = now()
    stderr.writeLine "TRACE ", formatFloat(epochTime(), ffDecimal, 2), " pos=", formatFloat(p.timePos, ffDecimal, 1),
      " buf=", p.buffering, " ahead=", formatFloat(p.cacheAhead, ffDecimal, 1), " retry=", a.ytRetry.len > 0,
      " net=", a.netUp, " drops=", a.dropTries, " opening=", p.opening
  a.pollYtList()
  a.pollStyled()
  a.pollYtInfo()
  a.readLinkInfos()
  if not a.ytList.running and not a.ytInfo.running: a.saveLinkInfos()
  if a.ytRetry.len > 0 and a.ytRetryNet:
    a.probeNet(a.ytRetry)
    # The network back after it was gone: at once. Gone: not yet, yt-dlp
    # would only hang on it (and the stream wait for that once it's back).
    if a.netUp > 0 and a.netWasDown: a.ytRetryAt = now()
    elif a.netUp <= 0: a.ytRetryAt = max(a.ytRetryAt, now() + 0.1)
  if a.ytRetry.len > 0 and now() >= a.ytRetryAt:
    let url = a.ytRetry
    a.ytRetry = ""
    a.ytOpen(url)
  if a.ytWatch and not p.opening and (p.loaded or p.loadError.len > 0):
    a.ytWatch = false
    if p.loadError.len > 0:
      if a.dropTries > 0: a.reconnect(p.path) else: a.ytFailed(p.path)
  # A stream YouTube turned down (403) once open: mpv skips to the end, which
  # is a failed link, not the video over (no After playback). It goes on
  # from where it last played. So does one whose connection dropped (the
  # system slept, the network went away): mpv takes that for the stream's
  # end, well before the video's, or waits on it for data that never comes.
  if p.loaded and p.source.len == 0 and p.path.isWebLink and p.path == a.streamArgs.url and
      a.ytRetry.len == 0:  # not while it waits to reopen
    # A seek that failed (the stream refused it, say): mpv goes to the end and
    # pauses, which isn't the video over. The stream opens again at the spot.
    if p.sought >= 0 and not p.seeking and (p.paused or p.eofReached) and
       p.timePos >= p.duration - 1:
      let t = p.sought
      a.recordEnd()
      a.goOnline(t)
      return
    if not p.eofReached:
      a.streamPos = if p.sought >= 0: p.sought else: p.timePos
      # Played on fine since it was opened: tries count from here.
      if p.timePos > a.streamArgs.start + 30: a.ytTries = 0
      if p.timePos > a.streamArgs.start + 5: (a.dropTries, a.netWasDown) = (0, false)
    let cutShort = p.eofReached and p.duration > 0 and p.timePos < p.duration - 5
    var stalled = false
    if (p.buffering or p.seeking) and not p.paused:
      if a.stallAt == 0 or p.cacheAhead > a.stallAhead + 0.5:
        (a.stallAt, a.stallAhead, a.netUp, a.netBackAt) = (now(), p.cacheAhead, 0, 0.0)
      # Waiting a while: the network asked whether it's there. Back after it
      # was gone, mpv may reconnect by itself (the quickest); when it
      # doesn't soon (its connection hung on the gone network), it's reopened.
      if now() - a.stallAt > StallProbe: a.probeNet(p.path)
      stalled = now() - a.stallAt > StallTimeout or
        a.netBackAt > 0 and now() - a.netBackAt > ResumeGrace
    else: a.stallAt = 0
    if stalled or p.eofReached and not p.eofHandled and (p.streamError.len > 0 or cutShort):
      p.eofHandled = true
      a.stallAt = 0
      p.loadError =
        if p.streamError.len > 0: p.streamError
        elif stalled and a.netBackAt > 0: "the network came back, the stream didn't"
        elif stalled: "no data for " & $int(StallTimeout) & " s"
        else: "the connection dropped"
      a.streamArgs.start = a.streamPos
      if p.streamError.len > 0: a.ytFailed(p.path) else: a.reconnect(p.path)
  # A link opened (streamed or from disk): its automatic captions join.
  let link = a.ytCurrentLink
  if p.justLoaded and link.isWebLink:
    let mt = p.h.getStr("media-title")
    if mt.len > 0 and mt != link:
      a.linkTitles[link] = mt
      a.noteLink(link, mt)
  # The formats its stream came in (a saved part's are noted as it opens).
  if p.justLoaded and link.isWebLink and p.path == link and p.source.len == 0:
    let f = p.hookFormat
    a.playFormat[link] = f
    let w = a.wants(link)
    if f.len > 0 and not a.picked(link):
      a.ytAuto[link] = f
      if link.linkKey in a.saved and a.entry(link).auto != f:
        a.entry(link).setAuto(f)
        a.saved.save()
    # Auto's video or audio, whichever played in Auto (yt-dlp picks each
    # alike whatever the other is).
    let parts = f.split('+')
    if parts.len == 2 and (w.video.len == 0 or w.audio.len == 0):
      var ap = a.autoParts(link)
      if w.video.len == 0: ap.video = parts[0]
      if w.audio.len == 0: ap.audio = parts[1]
      a.ytAutoParts[link] = ap
      if link.linkKey in a.saved and (a.entry(link).autoVideo, a.entry(link).autoAudio) != ap:
        (a.entry(link).autoVideo, a.entry(link).autoAudio) = ap
        a.saved.save()
  if p.justLoaded and not a.reopening and link.isWebLink and findYtdlp(a.cfg.ytdlp).len > 0:
    a.startStyling(link)
    if link in a.ytCaptions: a.addCaptions(link)
    elif not a.ytCaps.running:
      a.ytCaps = captions(findYtdlp(a.cfg.ytdlp), link, a.ytCookies.getOrDefault(link))
  if a.ytCaps != nil and a.ytCaps.poll() and not a.ytCaps.running:
    let j = a.ytCaps
    a.ytCaps = nil
    if j.code == 0:
      a.ytCaptions[j.url] = j.originalCaptions
      # A saved link has no hook subtitles to go by.
      if j.url notin a.ytStyled and not a.ytStyling.running:
        a.ytStyling = fetchStyled(j.url, j.styledSubs)
      a.ytQualities[j.url] = j.qualities
      a.ytBoards[j.url] = j.storyboard
      if j.url.linkKey in a.saved:
        (a.entry(j.url).videoOffers, a.entry(j.url).audioOffers) = j.qualities
        a.saved.save()
      # A lock it opened without knowing them (the middle audio row) now
      # knows what it stands for: in it, once (the formats are found once).
      let f = a.linkFormat(j.url)
      if p.path == j.url and p.loaded and a.picked(j.url) and f.len > 0 and
         a.playFormat.getOrDefault(j.url).len > 0 and f != a.playFormat[j.url]:
        a.switchQuality(j.url)
      if link == j.url and p.loaded: a.addCaptions(link)
  let j = a.ytJob
  if j == nil or not j.poll(): return
  a.dirtyUntil = max(a.dirtyUntil, now() + 0.1)
  if j.running: return
  a.ytJob = nil
  case j.task
  of ytCaptions, ytSubs, ytPlaylist, ytInfo, ytDownload: discard
  of ytVersion:
    a.ytCurrent = j.versionText
    a.ytJob = latest()
  of ytLatest:
    a.ytLatest = j.versionText
    if newer(a.ytLatest, a.ytCurrent): a.showYtdlp(ymUpdate)
    else: a.ytGiveUp()
  of ytUpdate:
    if j.code == 0:
      a.closeYtdlp()
      a.ytOpen(a.ytUrl)
    else:
      # yt-dlp can't update itself (one from a package manager): the
      # standalone build instead, which can.
      a.ytInstall("This yt-dlp can't update itself (" & j.errorText &
        "). Installing the standalone build, which can, to " & shortPath(managedPath()) & "...")
  of ytInstall:
    if j.code == 0:
      a.hookYtdlp()
      a.closeYtdlp()
      a.osd("yt-dlp installed")
      a.ytOpen(a.ytUrl, HookStart)
    else:
      a.showYtdlp(ymFailed, "yt-dlp couldn't be installed: " & j.errorText)

# --- Check for Updates -------------------------------------------------------
# The latest release, looked up on GitHub; once agreed to, it's got ready in
# the background (updater) and installed, and the player restarts into it,
# its state brought back (ResumeState).

proc showUpdate(a: App, mode: UpdateMode, msg = "") =
  a.menus.close()
  if a.overlay notin {ovNone, ovUpdate}: a.closeDialogs()
  if a.upWin == nil:
    (a.upWin, a.upSk, a.upUi) = a.newDialogWindow("Check for Updates", UpdateSize)
  a.upMode = mode
  a.upMsg = msg
  if a.overlay != ovUpdate:
    a.upUi.focusId = ""
    a.showDialog(a.upWin, UpdateSize)
    a.overlay = ovUpdate

proc closeUpdate(a: App) =
  ## Hides the window; a check still looking is given up, an update going
  ## on carries on (the status bar shows it).
  if a.upJob.running and a.upJob.stage == upLatest:
    a.upJob.stop()
    a.upJob = nil
  a.upUi.focusId = ""
  if a.overlay == ovUpdate: a.overlay = ovNone
  if a.upWin.visible:
    a.upWin.visible = false
    a.window.activate()

proc checkForUpdates(a: App) =
  ## Help > Check for Updates: an update going on shows how it goes.
  if a.upJob.running and a.upJob.stage != upLatest:
    a.showUpdate(umBusy)
    return
  if not a.upJob.running: a.upJob = checkForUpdate()
  a.showUpdate(umChecking)

proc upAnswer(a: App, ok: bool) =
  ## The Check for Updates window's buttons: get the update; else cancel
  ## (stopping one going on), close or hide.
  if ok and a.upMode == umAsk:
    a.upJob.download()
    if a.upJob.running: a.showUpdate(umBusy)
    else: a.showUpdate(umFailed, "The update couldn't be got: " & a.upJob.errorText)
  elif not ok and a.upMode == umBusy and a.upJob.running:
    a.upJob.stop()
    a.upJob = nil
    a.closeUpdate()
    a.osd("Update cancelled")
  else: a.closeUpdate()

proc upStatus(a: App): string =
  ## The update being got, for the status bar; "" when none is.
  let j = a.upJob
  if not j.running or j.stage == upLatest: return
  case j.stage
  of upLatest: discard
  of upDownload:
    result = "Downloading " & AppName & " " & j.version
    if j.progress >= 0: result.add &" {int(j.progress)}%"
  of upExtract: result = "Unpacking " & AppName & " " & j.version
  of upBuild: result = "Building " & AppName & " " & j.version
  of upInstall: result = "Installing " & AppName & " " & j.version

proc pollUpdate(a: App) =
  ## The check's answer; once the update is in place, the player restarts
  ## into it.
  let j = a.upJob
  if j == nil or not j.poll(): return
  a.dirtyUntil = max(a.dirtyUntil, now() + 0.1)
  if j.running: return
  if j.code != 0:
    a.upJob = nil
    if j.code == 130: return  # cancelled
    let what = if j.stage == upLatest: "The latest release couldn't be looked up: "
               else: "The update couldn't be installed: "
    a.showUpdate(umFailed, what & j.errorText)
  elif j.stage == upLatest:
    if newer(j.version, AppVersion): a.showUpdate(umAsk)
    else:
      a.upJob = nil
      if a.overlay == ovUpdate: a.showUpdate(umLatest)
  else:
    a.upJob = nil
    a.osd("Restarting into " & AppName & " " & j.version & "...")
    a.upRestart = true
    a.window.closeRequested = true

# --- Rendering: GPU or CPU ----------------------------------------------------
# Options > System > Rendering. The renderer is picked as the program starts
# (gpumem); going over to the other is a restart, the state brought back as
# after an update.

const
  VramSettle = 3.0      ## seconds the GPU's memory stays past the line before a switch
  VramDwell = 30.0      ## Adaptive: seconds on a renderer before leaving it

proc restartRenderer(a: App, cpu: bool) =
  ## Restarts onto the CPU or the GPU, unless something going on would be
  ## lost or cut short: then it's looked at again shortly.
  if a.overlay != ovNone or a.pickOpen or a.menus.isOpen or pointerButtonsDown() or
     a.saveJob.running or a.upJob.running or a.embProc != nil or a.upRestart:
    return
  a.rdRestart = if cpu: "cpu" else: "gpu"
  a.window.closeRequested = true

proc watchVram(a: App) =
  ## Prefer GPU: back to the GPU once it has the memory. Adaptive: that,
  ## and over to the CPU when the GPU runs out (or mpv says it did).
  ## Always CPU, chosen while on the GPU: over to the CPU.
  let t = now()
  # Said once the file it restarted with plays, its tracks brought back
  # (mpv's OSD drops what comes before), or straight away when there's none.
  let p = a.player
  if a.rdNote.len > 0 and not a.resuming and
     (p.loaded and p.restarts > p.loadedRestarts or not p.loaded and not p.opening and t - a.rdStart > 1):
    a.osd(a.rdNote, 4)
    a.rdNote = ""
  let oom = p.gpuOom
  p.gpuOom = false
  if a.rdRestart.len > 0 or t < a.rdCheckAt and not oom: return
  a.rdCheckAt = t + 1
  let mode = a.cfg.renderMode
  if mode == rdCpu:
    if not cpuWanted: a.restartRenderer(true)
    return
  if not cpuWanted and mode != rdAdaptive:
    a.rdSince = 0
    return
  let free = freeVram()
  let past =
    if cpuWanted: a.rdForNow and free >= ReturnVram
    else: oom or free >= 0 and free < LowVram
  if not past:
    a.rdSince = 0
    return
  if a.rdSince == 0: a.rdSince = t
  if not oom and t - a.rdSince < VramSettle: return
  if mode == rdAdaptive and t - a.rdStart < VramDwell: return
  a.restartRenderer(not cpuWanted)

proc rendererChanged(a: App, before: RenderMode) =
  ## Options > System > Rendering, changed: from Always CPU, the GPU comes
  ## back once it has the memory; to it, the CPU at once (watchVram).
  let mode = a.cfg.renderMode
  if mode == before: return
  a.rdForNow = cpuWanted and mode != rdCpu
  a.rdStart = 0  # no waiting on Adaptive's dwell: the user asked
  a.rdCheckAt = 0

proc rendererNote(): string =
  ## What the start says of the renderer, when it's not the usual.
  if restartedOnto() == "gpu": "GPU memory is free again: rendering on the GPU"
  elif not cpuWanted: ""
  elif not softwareGl: "Software rendering unavailable: decoding on the CPU only"
  elif not startedLow: (if restartedOnto() == "cpu": "Rendering on the CPU" else: "")  # Always CPU
  elif restartedOnto() == "cpu": "GPU out of memory: rendering on the CPU"
  else: "GPU memory is full: rendering on the CPU until it frees up"

# --- online videos kept on disk ----------------------------------------------
# A link streaming is saved as it plays, a file for each stretch read without
# a jump (websave). Opened again where some of it was saved, that part plays
# from disk (playSaved), and the standby opens the stream shortly before the
# part ends, taking over there as it would at a seamless loop's B.

const
  HandoffLead = 30.0    ## the stream opens this long before the saved part ends, media seconds
  HandoffMargin = 0.5   ## and takes over this long before its end
  RecordMin = 2.0       ## a stream's new part worth saving, seconds

proc webLimits(a: App): Limits =
  Limits(hours: (if a.cfg.webKeepOn: a.cfg.webKeepHours.float else: 0),
         count: (if a.cfg.webCountOn: a.cfg.webCount else: 0),
         bytes: (if a.cfg.webSizeOn: a.cfg.webSizeGB.int64 shl 30 else: 0))

proc pruneSaved(a: App) =
  ## Applies Options > Playback > Media Cache's limits, sparing the link playing.
  a.saved.prune(a.webLimits, if a.player.path.isWebLink: a.player.path else: "")

proc handoffOff(a: App) =
  if not a.sbHandoff: return
  a.sbHandoff = false
  a.standbyOff()

proc trackOpts(a: App, url: string): seq[string] =
  ## The tracks chosen now, for the link opening again (from disk or its stream).
  let p = a.player
  let aid = p.selectedTrack("audio")
  result.add "aid=" & (if aid == 0: "no" else: $aid)
  if a.saved.lookup(url).subsDone:  # numbered alike only then
    var sid = p.selectedTrack("sub")
    for t in p.tracks:  # but for a styled track put in later (addStyled)
      if t.id == sid and t.file.endsWith(".ass"):
        for i, f in a.saved.lookup(url).subs:
          if f.splitFile.name.endsWith("." & t.lang): sid = i + 1
    result.add "sid=" & (if sid == 0: "no" else: $sid)

proc holdFrame(a: App)

proc goOnline(a: App, t: float, stopped = false) =
  ## From a link's saved part to its stream at t, the same tracks chosen
  ## (`stopped`: there, stopped). As with another quality, the frame, the
  ## window and the seek bar stay up meanwhile.
  let p = a.player
  a.handoffOff()
  let url = p.path
  let dur = p.duration
  var opts = a.streamOpts(url) & a.trackOpts(url)
  if t <= 0: opts.add "start=0"  # not the link's own (t=...)
  if stopped: opts.add "pause=yes"
  if not stopped: a.holdFrame()
  a.qualitySwitch = true
  a.stopOnLoad = stopped
  a.ytTries = 0
  a.dropTries = 0
  a.streamLink(url, t, opts.join(","))
  p.duration = max(p.duration, dur)
  p.keepTime = true

proc switchQuality(a: App, url: string) =
  ## The link playing goes on in the quality it wants now (wants) from where
  ## it is, from what's saved of it in that quality when there is some
  ## there, else its stream. Nothing reopens when it plays in it already.
  let p = a.player
  if p.path != url or not p.loaded: return
  let f = a.linkFormat(url)
  if f.len > 0 and f == a.playFormat.getOrDefault(url): return
  let t = p.posNow
  let dur = p.duration
  let stopped = p.stopped
  var opts = a.trackOpts(url)
  if stopped or p.paused: opts.add "pause=yes"
  a.recordEnd()  # what it saved so far, in the quality it was in
  a.handoffOff()
  if not stopped: a.holdFrame()
  a.qualitySwitch = true
  a.ytTries = 0
  a.dropTries = 0
  let s = a.savedIn(url)
  let part = s.chainAt(t)
  if part.stop > part.start and (s.complete or part.stop - t >= SavedMin):
    a.playSaved(url, t, part, opts)
  else:
    if t <= 0: opts.add "start=0"  # not the link's own (t=...)
    a.streamLink(url, t, (a.streamOpts(url) & opts).join(","))
  a.stopOnLoad = stopped
  # The time and the seek bar stay up meanwhile, as the frame does.
  p.duration = max(p.duration, dur)
  p.keepTime = true

proc pickQuality(a: App, url: string, video, audio: string) =
  ## The quality menu's pick ("auto": Auto, whatever is locked): the link
  ## goes on in it.
  if a.ytPick.getOrDefault(url) == (video, audio): return
  a.ytPick[url] = (video, audio)
  a.switchQuality(url)

proc pickLang(a: App, url, lang: string) =
  ## Audio Track's pick of a link's languages: the link goes on in it, in the
  ## row of its qualities the one picked was in (Auto stays Auto), heard even
  ## if its audio was off.
  let p = a.player
  let all = a.qualitiesOf(url).audio
  if p.path != url or all.len == 0: return
  let row = a.audioRows(url).mapIt(it.id).find(a.ytPick.getOrDefault(url).audio)
  if lang == all[0].lang: a.ytLang.del(url) else: a.ytLang[url] = lang
  if row >= 0:
    let rows = a.audioRows(url)
    a.ytPick[url].audio = rows[min(row, rows.high)].id
  if p.selectedTrack("audio") == 0:
    for t in p.tracks.mitems:
      if t.kind == "audio":
        t.selected = true  # as mpv says soon: the link may reopen before it does
        a.setTrack("aid", t.id)
        break
  a.switchQuality(url)

proc webHandoff(a: App) =
  ## While a link's saved part plays: the standby opens the stream a little
  ## before the part ends, to take over there (standbyStep, takeOver).
  let p = a.player
  let part = p.partEnd
  if a.standby == nil or part <= 0 or not p.loaded or p.stopped or a.handoffFailed:
    a.handoffOff()
    return
  let h = part - HandoffMargin
  let start = max(h - StandbyPreroll, 0)
  if not a.sbHandoff:
    let pos = p.posNow
    if p.seeking or pos >= h or pos < h - HandoffLead * max(p.speed, 1): return
    a.sbHandoff = true
    (a.sbA, a.sbB) = (h, h)
    a.standbyAt(p.path, start, a.withRaw(p.path, a.streamOpts(p.path).join(",")))
    return
  discard a.standby.pollEvents()
  if a.standby.loadError.len > 0:  # the part's end goes online the plain way
    a.handoffFailed = true
    a.handoffOff()
    return
  a.standbyStep(h, h, start)

proc recordEnd(a: App) =
  ## Done saving the stream: what its file holds goes in the index.
  if a.recUrl.len == 0: return
  let url = a.recUrl
  a.recUrl = ""
  if a.player.path == url: a.player.stopDump()
  # A dump that failed (mpv couldn't write a track) leaves a file that would
  # play without it, if at all: the link streams again next time instead.
  if a.player.dumpFailed or a.rec.stop - a.rec.start < 1:
    if a.player.dumpFailed and url.linkKey in a.saved:  # written now and then (recordStep)
      a.entry(url).segs.keepItIf(it.file != a.rec.file)
      a.saved.save()
    try: removeFile(a.rec.file)
    except OSError: discard
    return
  a.entry(url).addSeg(a.rec)
  a.pruneSaved()

proc recordStep(a: App) =
  ## Saves the link streaming as it streams, a file for each stretch read
  ## without a jump that reaches past what's saved there.
  let p = a.player
  if a.recUrl.len > 0:
    if p.path != a.recUrl or not p.loaded or not p.dumping:
      a.recordEnd()
      return
    if p.buffered.len == 0: return
    # mpv's cache range it's writing: the one reaching on from where it got to.
    var ours = (-1.0, -1.0)
    for r in p.buffered:
      if r[0] <= a.rec.stop + 0.5 and r[1] >= a.rec.stop - 0.05 and r[1] > ours[1]: ours = r
    # Read elsewhere (sought past the cache): the file would go on from there.
    let pos = p.timePos
    if ours[1] < 0 or p.buffered.len > a.recRanges or
       not p.seeking and (pos < ours[0] - 1 or pos > ours[1] + 15):
      a.recordEnd()
      return
    a.recRanges = p.buffered.len
    a.rec.stop = max(a.rec.stop, ours[1])
    if a.rec.stop - a.recWritten >= 10:  # now and then, should the player not get to close
      a.recWritten = a.rec.stop
      a.entry(a.recUrl).addSeg(a.rec)
      a.saved.save()
    return
  let link = a.ytCurrentLink
  if not (p.loaded and link.isWebLink and p.path == link and p.source.len == 0 and
          p.duration > 0 and not p.seeking): return
  # mpv's cache range being read; a dump would also take in any range after
  # it, out of place, so only the last one is saved.
  var cur = (-1.0, -1.0)
  for r in p.buffered:
    if r[0] <= p.timePos + 1 and p.timePos <= r[1] + 15 and r[0] > cur[0]: cur = r
  if cur[1] < 0: return
  for r in p.buffered:
    if r[0] > cur[1]: return
  # In the quality it streams in, noted with it; not knowing which, a pick
  # isn't saved (it would stand for Auto).
  let format = a.playFormat.getOrDefault(link)
  if format.len == 0 and a.picked(link): return
  # Worth it once it reaches past what's saved there in that quality.
  let c = a.saved.lookup(link).inFormat(
    if format.len > 0: format else: a.saved.lookup(link).auto).chainAt(cur[0])
  let have = if c.stop > c.start: c.stop else: cur[0]
  if cur[1] >= have + RecordMin:
    let r = cur
    try: createDir(saveDir())
    except OSError: return
    a.rec = Seg(file: newSegFile(link), start: max(r[0], 0), stop: max(r[0], 0), format: format)
    a.recUrl = link
    a.recRanges = p.buffered.len
    a.recWritten = a.rec.start
    p.dumpFrom(r[0], a.rec.file)
    a.entry(link).duration = p.duration
    a.entry(link).used = epochTime()
    if link in a.ytAuto and a.entry(link).auto != a.ytAuto[link]: a.entry(link).setAuto(a.ytAuto[link])
    if link in a.ytAutoParts:
      (a.entry(link).autoVideo, a.entry(link).autoAudio) = a.ytAutoParts[link]
    if link in a.ytQualities:
      (a.entry(link).videoOffers, a.entry(link).audioOffers) = a.ytQualities[link]
    let title = p.h.getStr("media-title")
    if title.len > 0 and title != link: a.entry(link).title = title
    if a.entry(link).chapters.len == 0 and p.chapters.len > 0:
      a.entry(link).chapters = writeChapters(link,
        p.chapters.mapIt((it.time, it.title)), p.duration)
    if not a.entry(link).subsDone and not a.ytSubs.running and findYtdlp(a.cfg.ytdlp).len > 0:
      a.ytSubs = subtitles(findYtdlp(a.cfg.ytdlp), link, saveDir() / keyOf(link) & "-subs",
        a.ytCookies.getOrDefault(link))

proc pollWebSave(a: App) =
  let p = a.player
  # Got before the saved part some other way (a chapter back, say): what
  # plays there only stands in for the time.
  if p.partEnd > 0 and p.beyond < 0 and p.settled and not p.seeking and
     p.timePos < p.partStart - 0.5:
    p.beyond = max(p.timePos, 0)
  if p.beyond >= 0:  # sought outside the saved part, or played to its end
    let t = p.beyond
    p.beyond = -1
    if p.partEnd > 0: a.goOnline(t, p.stopped)
  a.webHandoff()
  a.recordStep()
  if a.ytSubs != nil and a.ytSubs.poll() and not a.ytSubs.running:
    let j = a.ytSubs
    a.ytSubs = nil
    if j.code == 0:
      a.entry(j.url).subs = j.subs
      a.entry(j.url).subsDone = true
      a.saved.save()
      a.styleSaved(j.url)

proc dropSaved(a: App, urls: seq[string]) =
  ## Deletes links' saved files (Options > Playback > Media Cache); one playing from
  ## them goes on streaming.
  let p = a.player
  if a.recUrl.len > 0 and a.recUrl.linkKey in urls: a.recordEnd()
  if p.partEnd > 0 and p.path.linkKey in urls: a.goOnline(p.posNow, p.stopped)
  a.saved.drop(urls)

proc refreshWebInfo(a: App) =
  a.webInfoAt = now()
  let (free, total) = diskSpace()
  a.optionsDlg.web = WebInfo(dir: saveDir(), used: usedBytes(), free: free, total: total,
                             items: a.saved.items)

proc showOverlay(a: App, o: Overlay) =
  a.menus.close()
  if o == ovProperties:
    if not a.player.loaded: return
    a.gatherProperties()
  if o == ovOptions and a.overlay != ovOptions:
    a.cfgBefore = a.cfg
    a.ensureOptionsWindow()
    a.optionsDlg.opened(a.optUi)
    a.refreshWebInfo()
    a.showDialog(a.optWin, OptionsSize)
  a.overlay = o

# --- menu tree --------------------------------------------------------------

proc bindAct[T](f: proc (x: T), x: T): proc () =
  ## Binds a value to an action. Closures made directly in a loop would share
  ## the loop's variables; building them here gives each item its own copy.
  result = proc () = f(x)

proc relabeled(n: MenuNode, label: string): MenuNode =
  ## Same item under another name, sharing its action and children.
  result = MenuNode()
  result[] = n[]
  result.label = label

proc rlSelection(a: App): string =
  ## The run log text selected by dragging, its rows joined by newlines.
  var (s, e) = (a.rlSelFrom, a.rlSelTo)
  if e < s: swap(s, e)
  if s == e or s[0] >= a.rlRows.len: return
  for r in s[0] .. min(e[0], a.rlRows.len - 1):
    let row = a.rlRows[r]
    let c0 = if r == s[0]: min(s[1], row.len) else: 0
    let c1 = if r == e[0]: min(e[1], row.len) else: row.len
    if r > s[0]: result.add '\n'
    if c1 > c0: result.add row[c0 ..< c1]

proc recentName(a: App, path: string): string =
  ## An Open Recent entry's name: "title [id]" for a link.
  if not path.isWebLink: return path.extractFilename
  var title = a.linkTitles.getOrDefault(path, a.cfg.recentTitles.getOrDefault(path))
  if title.len == 0: title = a.saved.lookup(path).title
  var id = path.youtubeId
  if id.len == 0: id = path.youtubeList
  if title.len == 0: return path
  if id.len == 0: title else: &"{title} [{id}]"

proc buildMenu(a: App): tuple[bar, context: MenuNode] =
  let root = newMenuRoot()
  let p = a.player
  let loaded = p.loaded
  let cfg = addr a.cfg
  let k = proc (act: KeyAction): string = a.cfg.keyText(act)

  # File
  let locked = a.playlistLocked  # synchronized: the master's playlist rules
  let file = root.sub("File")
  file.item("Open File...", k(kaOpenFile), enabled = not locked, action = proc () = a.openFileDialog())
  let recent = file.sub("Open Recent", enabled = a.cfg.recentFiles.len > 0 and not locked)
  let openOne = proc (path: string) = a.openPaths(@[path])
  let removeOne = proc (path: string) =
    a.cfg.removeRecent(path)
    if a.cfg.recentFiles.len == 0: a.menus.close()
  for r in a.cfg.recentFiles:
    recent.item(a.recentName(r), action = bindAct(openOne, r),
      remove = bindAct(removeOne, r))
  if a.cfg.recentFiles.len > 0:
    recent.sep()
    recent.item("Clear List", action = proc () = a.cfg.clearRecent())
  file.item("Open Directory...", enabled = not locked, action = proc () =
    a.ask(dkOpenDir, "opendir", "Open Directory"))
  file.item("Open From Clipboard", k(kaOpenClipboard), enabled = not locked,
    action = proc () = a.openFromClipboard())
  file.item("Copy to Clipboard", k(kaCopyClipboard), enabled = loaded,
    action = proc () = a.copyToClipboard())
  file.item("Copy YouTube Link at Current Time", k(kaCopyTimeLink),
    enabled = loaded and a.plIndex in 0 ..< a.playlist.len and
      a.playlist[a.plIndex].youtubeId.len > 0, action = proc () = a.copyTimeLink())
  if a.saveJob.running:
    file.item("Cancel Saving", action = proc () = a.cancelSave())
  else:
    file.item("Save...", k(kaSave), enabled = loaded, action = proc () = a.saveMedia())
  file.item("Close", k(kaClose), enabled = loaded and not locked, action = proc () = a.closeFile())
  file.sep()
  file.item("Save Screenshot...", k(kaScreenshot), enabled = loaded and p.hasVideo,
    action = proc () = a.screenshot())
  file.sep()
  let loadTrack = file.sub("Load Track From File", enabled = loaded)
  loadTrack.item("Subtitle File...", k(kaLoadSubtitle), action = proc () =
    a.ask(dkOpenFile, "subtitle", "Load Subtitle", exts = @SubtitleExtensions,
      filterName = "Subtitles"))
  loadTrack.item("Audio File...", k(kaLoadAudio), action = proc () =
    a.ask(dkOpenFile, "audio", "Load Audio Track", exts = @MediaExtensions,
      filterName = "Audio files"))
  file.sep()
  file.item("Properties", k(kaProperties), enabled = loaded, action = proc () = a.showOverlay(ovProperties))
  file.sep()
  file.item("Exit", k(kaExit), action = proc () = a.window.closeRequested = true)
  let exitItem = file.children[^1]

  # View
  let view = root.sub("View")
  view.check("Compact Mode", k(kaCompact), cfg.compactMode, action = proc () =
    a.setCompact(not a.cfg.compactMode))
  view.check("Seek Bar", k(kaSeekBar), cfg.showSeekBar, action = proc () =
    a.cfg.showSeekBar = not a.cfg.showSeekBar
    a.resizeKeepingVideo(ivec2(0, int32(if a.cfg.showSeekBar: SeekBarHeight else: -SeekBarHeight))))
  view.check("Controls", k(kaControls), cfg.showControls, action = proc () =
    a.cfg.showControls = not a.cfg.showControls
    a.resizeKeepingVideo(ivec2(0, int32(if a.cfg.showControls: ControlsHeight else: -ControlsHeight))))
  view.check("Status", k(kaStatus), cfg.showStatus, action = proc () =
    a.cfg.showStatus = not a.cfg.showStatus
    a.resizeKeepingVideo(ivec2(0, int32(if a.cfg.showStatus: StatusHeight else: -StatusHeight))))
  view.check("Playlist", k(kaPlaylist), cfg.showPlaylist, action = proc () =
    a.setPlaylistShown(not a.cfg.showPlaylist))
  view.check("Run Log", k(kaRunLog), cfg.showRunLog, action = proc () =
    a.setRunLogShown(not a.cfg.showRunLog))
  view.sep()
  view.check("Show OSD", k(kaShowOsd), cfg.showOsd, action = proc () =
    a.cfg.showOsd = not a.cfg.showOsd
    a.syncSettings())
  view.check("Full Screen", k(kaFullScreen), a.fullscreen, action = proc () =
    a.setFullscreen(not a.fullscreen))
  let fullScreen = view.children[^1]

  let grab = view.sub("Pan, Rotate && Zoom".replace("&&", "&"))
  grab.item("Center", k(kaCenter), action = proc () =
    a.xf.pan = vec2(0, 0); a.xfChanged("Pan: center"))
  for (label, key, d) in [("Move Up", kaMoveUp, vec2(0, -1)), ("Move Down", kaMoveDown, vec2(0, 1)),
                          ("Move Left", kaMoveLeft, vec2(-1, 0)), ("Move Right", kaMoveRight, vec2(1, 0))]:
    grab.item(label, k(key), action = bindAct(proc (dir: Vec2) =
      a.xf.pan += dir * a.cfg.panStep.float32
      a.xfChanged(&"Pan: {int(a.xf.pan.x)}, {int(a.xf.pan.y)}"), d))
  grab.sep()
  grab.item("0 Degrees", k(kaRotate0), action = proc () =
    a.xf.rotation = 0; a.xfChanged("Rotation: 0°"))
  grab.item("Rotate Clockwise", k(kaRotateCw), action = proc () =
    a.xf.rotation = floorMod(a.xf.rotation + a.cfg.rotateStep.float32, 360)
    a.xfChanged(&"Rotation: {a.xf.rotation:g}°"))
  grab.item("Rotate Counter-clockwise", k(kaRotateCcw), action = proc () =
    a.xf.rotation = floorMod(a.xf.rotation - a.cfg.rotateStep.float32, 360)
    a.xfChanged(&"Rotation: {a.xf.rotation:g}°"))
  grab.sep()
  grab.item("Restore Size", k(kaRestoreSize), action = proc () =
    a.xf.zoom = 1; a.xf.scaleX = 1; a.xf.scaleY = 1; a.xfChanged("Size: 100%"))
  let step = a.cfg.sizeStep.float32 / 100
  for (label, key, which, d) in [
      ("Increase Size", kaSizeUp, 0, 1'f32), ("Decrease Size", kaSizeDown, 0, -1'f32),
      ("Increase Width", kaWidthUp, 1, 1'f32), ("Decrease Width", kaWidthDown, 1, -1'f32),
      ("Increase Height", kaHeightUp, 2, 1'f32), ("Decrease Height", kaHeightDown, 2, -1'f32)]:
    grab.item(label, k(key), action = bindAct(proc (wd: (int, float32)) =
      let (w, dd) = wd
      case w
      of 0:
        a.xf.zoom = max(0.05, a.xf.zoom + dd * step)
        a.xfChanged(&"Size: {int(round(a.xf.zoom * 100))}%")
      of 1:
        a.xf.scaleX = max(0.05, a.xf.scaleX + dd * step)
        a.xfChanged(&"Width: {int(round(a.xf.scaleX * 100))}%")
      else:
        a.xf.scaleY = max(0.05, a.xf.scaleY + dd * step)
        a.xfChanged(&"Height: {int(round(a.xf.scaleY * 100))}%"), (which, d)))
  grab.sep()
  grab.item("Reset", k(kaPanReset), action = proc () =
    a.xf = VideoTransform(); a.xfChanged("Reset"))

  let frame = view.sub("Video Frame")
  for (label, mode) in [("Half Size", fmHalf), ("Normal Size", fmFull), ("Double Size", fmDouble),
                        ("Stretch To Window", fmStretch), ("Fit", fmFit)]:
    frame.radio(label, "", cfg.frameMode == mode, action = bindAct(proc (m: FrameMode) =
      a.cfg.frameMode = m; a.hintsKey = "", mode))
  frame.sep()
  let ar = frame.sub("Aspect Ratio")
  for (label, value) in [("Original", ""), ("4:3", "4:3"), ("5:4", "5:4"),
                         ("16:9", "16:9"), ("16:10", "16:10")]:
    ar.radio(label, "", cfg.aspectOverride == value, action = bindAct(proc (v: string) =
      a.cfg.aspectOverride = v
      a.hintsKey = ""
      a.fitPending = true, value))
  frame.check("Preserve Aspect Ratio", "", cfg.preserveAspect, action = proc () =
    a.cfg.preserveAspect = not a.cfg.preserveAspect; a.hintsKey = "")
  view.sep()
  let ontop = view.sub("On Top")
  for (label, mode) in [("Default", otDefault), ("Always", otAlways),
                        ("While Playing", otWhilePlaying),
                        ("While Playing Video", otWhilePlayingVideo)]:
    ontop.radio(label, "", cfg.onTop == mode,
      action = bindAct(proc (m: OnTopMode) = a.cfg.onTop = m, mode))
  view.item("Options...", k(kaOptions), action = proc () = a.showOverlay(ovOptions))
  let options = view.children[^1]

  # Play
  let play = root.sub("Play")
  play.item(if p.playing or a.padRunning: "Pause" else: "Play", k(kaPlayPause),
    enabled = loaded or a.cfg.recentFiles.len > 0,
    action = proc () = a.playPause())
  play.item("Stop", k(kaStop), enabled = loaded, action = proc () = a.stop())
  let (playPause, stop) = (play.children[0], play.children[1])
  play.item("Frame Forward", k(kaFrameForward), enabled = loaded, action = proc () = a.frameStep(true))
  play.item("Frame Back", k(kaFrameBack), enabled = loaded, action = proc () = a.frameStep(false))
  play.item(&"Faster Playback (+{a.cfg.rateStep:g}x)", k(kaFaster), enabled = loaded,
    action = proc () = a.changeRate(1))
  play.item(&"Slower Playback (-{a.cfg.rateStep:g}x)", k(kaSlower), enabled = loaded,
    action = proc () = a.changeRate(-1))
  let rep = play.sub("Repeat")
  rep.check("Forever", k(kaRepeatForever), cfg.repeatForever, action = proc () =
    a.cfg.repeatForever = not a.cfg.repeatForever; a.applyLoop())
  rep.check("Ping-Pong", k(kaRepeatPingPong), cfg.repeatPingPong, action = proc () =
    a.cfg.repeatPingPong = not a.cfg.repeatPingPong; a.applyLoop(); a.applyAbLoop())
  rep.sep()
  rep.radio("File", "", cfg.repeatMode == rmFile, action = proc () =
    a.cfg.repeatMode = rmFile; a.applyLoop())
  rep.radio("Playlist", "", cfg.repeatMode == rmPlaylist, action = proc () =
    a.cfg.repeatMode = rmPlaylist; a.applyLoop())
  rep.sep()
  rep.check("Loop A-B", "", a.abLoop and a.loopReady, enabled = loaded and a.loopReady,
    action = proc () =
      a.abLoop = not a.abLoop; a.applyAbLoop())
  play.sep()
  var trackMenus: seq[MenuNode]
  let selectTrack = proc (pt: (string, int)) = a.setTrack(pt[0], pt[1])
  let selectLang = proc (lang: string) =
    a.pickLang(a.player.path, lang)
  for (title, kind, prop) in [("Audio Track", "audio", "aid"),
                              ("Subtitle Track", "sub", "sid"),
                              ("Video Track", "video", "vid")]:
    let m = play.sub(title, enabled = loaded)
    trackMenus.add m
    # A link's languages stand for its one audio track: it comes in one at a
    # time. Audio loaded from a file is listed still.
    let langs = if kind == "audio" and p.path.isWebLink: audioLanguages(a.qualitiesOf(p.path).audio)
                else: @[]
    let dubbed = langs.len > 1
    let opening = dubbed and not p.tracks.anyIt(it.kind == "audio")  # in another one, perhaps
    m.radio("None", "", p.selectedTrack(kind) == 0 and not opening,
      action = bindAct(selectTrack, (prop, 0)))
    if dubbed:
      let lang = a.audioRows(p.path)[0].lang
      let heard = opening or p.tracks.anyIt(it.kind == "audio" and it.selected and not it.loadedFile)
      for l in langs:
        m.radio(if l.langName.len > 0: l.langName else: "Unknown", "", heard and l.lang == lang,
          action = bindAct(selectLang, l.lang))
    for t in p.tracks:
      if t.kind == kind and (not dubbed or t.loadedFile):
        m.radio(t.trackLabel, "", t.selected, action = bindAct(selectTrack, (prop, t.id)))
  play.sep()
  let vol = play.sub("Volume")
  vol.item("Up", k(kaVolumeUp), action = proc () = a.volumeStep(true))
  vol.item("Down", k(kaVolumeDown), action = proc () = a.volumeStep(false))
  vol.check("Mute", k(kaMute), p.muted, action = proc () = a.setMute(not a.player.muted))
  vol.item("Max", action = proc () =
    a.player.setVolume(100); a.osd("Volume: 100%"))
  let after = play.sub("After Playback")
  for (label, mode) in [("Do Nothing", apNothing), ("Play Next File In The Folder", apNextInFolder),
                        ("Turn Off The Monitor", apMonitorOff), ("Exit", apExit),
                        ("Sleep", apSleep), ("Hibernate", apHibernate),
                        ("Shutdown", apShutdown), ("Log Off", apLogOff), ("Lock", apLock)]:
    after.radio(label, "", a.afterPlayback == mode,
      action = bindAct(proc (m: AfterPlayback) = a.afterPlayback = m, mode))

  # Navigate
  let nav = root.sub("Navigate")
  let bm = nav.sub("Bookmarks", enabled = loaded)
  bm.item("Add Bookmark", k(kaAddBookmark), enabled = loaded, action = proc () = a.addBookmark(a.player.timePos))
  bm.item("Remove Bookmark", enabled = a.fileBookmarks.len > 0, action = proc () =
    let i = a.nearestBookmark(a.player.timePos)
    if i >= 0: a.removeBookmark(a.fileBookmarks[i].time))
  bm.sep()
  bm.item("Import Bookmarks...", enabled = loaded, action = proc () = a.importBookmarksDialog())
  bm.item("Export Bookmarks...", enabled = a.fileBookmarks.len > 0,
    action = proc () = a.exportBookmarksDialog())
  bm.item("Embed As MKV Chapters...", enabled = a.canEmbed, action = proc () = a.showEmbed())
  let marks = a.fileBookmarks
  if marks.len > 0:
    bm.sep()
    for i, b in marks:
      bm.item(fmtTime(b.time, dur = p.duration) & "  " & b.label(i), action = bindAct(proc (t: float) = a.seekTo(t), b.time))
  nav.sep()
  nav.item(&"Jump Forward {a.cfg.seekStep:g}s", k(kaJumpForward), enabled = loaded,
    action = proc () = a.seekRelative(a.cfg.seekStep))
  nav.item(&"Jump Back {a.cfg.seekStep:g}s", k(kaJumpBack), enabled = loaded,
    action = proc () = a.seekRelative(-a.cfg.seekStep))
  nav.item("Go To Beginning", k(kaGoBeginning), enabled = loaded, action = proc () = a.seekTo(0))
  nav.sep()
  let hasCh = p.chapters.len > 0
  let canStep = hasCh or (a.cfg.bookmarksAsChapters and a.fileBookmarks.len > 0)
  let chm = nav.sub("Chapters", enabled = hasCh)
  for i, c in p.chapters:
    let label = fmtTime(c.time, dur = p.duration) & "  " & (if c.title.len > 0: c.title else: &"Chapter {i + 1}")
    chm.item(label, action = bindAct(proc (t: float) = a.seekTo(t), c.time))
  nav.item("Next Chapter", k(kaNextChapter), enabled = canStep, action = proc () = a.chapterStep(1))
  nav.item("Previous Chapter", k(kaPrevChapter), enabled = canStep, action = proc () = a.chapterStep(-1))
  nav.sep()
  nav.item("Next File", k(kaNextFile), enabled = loaded and not locked, action = proc () = a.navigate(1))
  nav.item("Previous File", k(kaPrevFile), enabled = loaded and not locked, action = proc () = a.navigate(-1))

  # Synchronize: the other players found, checked when in our group.
  let syn = root.sub("Synchronize")
  let others = if a.peers == nil: newSeq[Peer]() else: a.peers.peers
  syn.item("Connect All", enabled = others.anyIt(it.pid notin a.syncMembers),
    action = proc () = a.syncRequest("all"))
  syn.item("Disconnect All", enabled = a.synced, action = proc () = a.syncRequest("none"))
  syn.item("Properties...", enabled = a.peers != nil, action = proc () = a.showSyncProps())
  syn.sep()
  if others.len == 0:
    syn.item("No other players running", enabled = false)
  let toggle = proc (pid: int) =
    if pid notin a.syncMembers: a.syncRequest("add", pid)
    # Unchecking the master leaves its group.
    elif pid == a.syncMaster: a.syncRequest("remove", a.peers.pid)
    else: a.syncRequest("remove", pid)
  for peer in others.sortedByIt(it.pid):
    var label = (if peer.title.len > 0: peer.title else: "No file") & &"  (PID {peer.pid})"
    if peer.pid == a.syncMaster: label.add "  · master"
    elif peer.master != 0 and peer.pid notin a.syncMembers: label.add "  · synchronized elsewhere"
    syn.check(label, checked = peer.pid in a.syncMembers, action = bindAct(toggle, peer.pid))

  # Run: the Commands window and the command lines it saved.
  let run = root.sub("Run")
  run.item("Commands...", action = proc () = a.showCommands())
  if a.commands.len == 0:
    run.sep()
    run.item("No command lines", enabled = false)
  let runOne = proc (c: CommandLine) = a.runCommandLine(c)
  # Presets first, then the user's own, each group behind a separator.
  for presets in [true, false]:
    var first = true
    for c in a.commands:
      if c.isPreset != presets: continue
      if first: run.sep()
      first = false
      run.item(c.title, action = bindAct(runOne, c))

  # Help
  let help = root.sub("Help")
  help.item("Keyboard Shortcuts", k(kaShortcuts), action = proc () = a.showOverlay(ovShortcuts))
  help.item("Check for Updates...", action = proc () = a.checkForUpdates())
  help.sep()
  help.item("About " & AppName, action = proc () = a.showOverlay(ovAbout))

  # Right-click menu, built from the bar's nodes.
  let ctx = newMenuRoot()
  # Only for audio files: not links (YouTube's have a thumbnail item of their
  # own) nor videos, even with their video track turned off.
  if loaded and not a.player.path.contains("://") and
     not p.tracks.anyIt(it.kind == "video" and not it.albumArt):
    ctx.check("Show Front Cover", checked = a.cfg.showCover, action = proc () =
      a.cfg.showCover = not a.cfg.showCover
      a.cfg.save()
      a.syncSettings())
    ctx.sep()
  # Items about the opened link, in one group.
  let isYoutube = a.plIndex in 0 ..< a.playlist.len and a.playlist[a.plIndex].youtubeId.len > 0
  if loaded and a.player.path.contains("://"):
    ctx.item("Copy URL", k(kaCopyClipboard), action = proc () = a.copyToClipboard())
    if isYoutube:
      ctx.item("Copy with Timestamp", k(kaCopyTimeLink), action = proc () = a.copyTimeLink())
    else:
      ctx.sep()
  if isYoutube:
    # Not at Options > Online's Lowest Quality, which downloads no thumbnails.
    ctx.check("Show Thumbnail When Video Is Off", checked = a.cfg.ytThumbnail,
      enabled = a.cfg.streamQuality != sqLowest, action = proc () =
        a.cfg.ytThumbnail = not a.cfg.ytThumbnail
        a.cfg.save())
    ctx.sep()
  if p.isSpherical:
    ctx.check("Ctrl+Drag to Look",
      checked = a.cfg.sphereDragMovesWindow, action = proc () =
        a.cfg.sphereDragMovesWindow = not a.cfg.sphereDragMovesWindow
        a.cfg.save())
    ctx.sep()
  ctx.children.add file
  ctx.sep()
  ctx.children.add [playPause.relabeled("Play/Pause"), stop, rep]
  ctx.sep()
  ctx.children.add fullScreen
  ctx.sep()
  ctx.children.add nav
  ctx.sep()
  ctx.children.add [trackMenus[0].relabeled("Audio"), trackMenus[1].relabeled("Subtitles"),
                    trackMenus[2].relabeled("Video")]
  ctx.sep()
  ctx.children.add after
  ctx.sep()
  ctx.children.add view
  ctx.sep()
  ctx.children.add options
  ctx.sep()
  ctx.children.add exitItem

  case a.ctxMenu
  of cmVideo: (root, ctx)
  of cmRepeat:
    let rc = newMenuRoot()
    rc.children = rep.children
    (root, rc)
  of cmTime:
    let timeCtx = newMenuRoot()
    timeCtx.check("Enable milliseconds", checked = a.cfg.showMillis, action = proc () =
      a.cfg.showMillis = not a.cfg.showMillis
      a.cfg.save())
    timeCtx.check("Show remaining time", checked = a.cfg.showRemaining, action = proc () =
      a.cfg.showRemaining = not a.cfg.showRemaining
      a.cfg.save())
    (root, timeCtx)
  of cmStatus:
    let st = newMenuRoot()
    st.check("Show all shortcuts", checked = a.cfg.showAllShortcuts, action = proc () =
      a.cfg.showAllShortcuts = not a.cfg.showAllShortcuts
      a.cfg.save())
    (root, st)
  of cmSeekBar:
    # Adds at the time clicked; edits or removes the bookmark clicked on.
    let sb = newMenuRoot()
    let i = a.ctxBookmark
    let on = i >= 0 and i < a.fileBookmarks.len
    let (t, bt) = (a.ctxSeekT, if on: a.fileBookmarks[i].time else: 0.0)
    if a.plIndex in 0 ..< a.playlist.len and a.playlist[a.plIndex].youtubeId.len > 0:
      # Not at Options > Online's Lowest Quality, which downloads no thumbnails.
      sb.check("Preview YouTube Videos", checked = a.cfg.ytSeekPreview,
        enabled = a.cfg.seekPreview and a.cfg.streamQuality != sqLowest, action = proc () =
          a.cfg.ytSeekPreview = not a.cfg.ytSeekPreview
          a.cfg.save())
      sb.sep()
    sb.item("Add Bookmark", enabled = loaded and not on, action = proc () = a.addBookmark(t))
    sb.item("Edit Bookmark...", enabled = on, action = proc () = a.showRename(i))
    sb.item("Remove Bookmark", enabled = on, action = proc () = a.removeBookmark(bt))
    # Loop marks go at the marker clicked on, else at the time clicked.
    let mt = if a.ctxOnMarker: a.ctxMarkerT else: t
    sb.sep()
    for (isB, has, lt, name) in [(false, a.hasLoopA, a.loopA, "Loop A"),
                                 (true, a.hasLoopB, a.loopB, "Loop B")]:
      if has and abs(lt - mt) < 0.001:
        sb.check(name, checked = true, enabled = loaded,
          action = bindAct(proc (b: bool) = a.unsetLoopMark(b), isB))
      else:
        sb.check(name, checked = false, enabled = loaded,
          action = bindAct(proc (b: bool) = a.setLoopMark(b, mt), isB))
    sb.item("Clear Loop", enabled = a.hasLoopA or a.hasLoopB, action = proc () =
      a.clearLoopMarks(); a.osd("Loop cleared"))
    sb.sep()
    sb.check("Bookmarks as chapters", checked = a.cfg.bookmarksAsChapters, action = proc () =
      a.cfg.bookmarksAsChapters = not a.cfg.bookmarksAsChapters
      a.cfg.save())
    (root, sb)
  of cmQuality:
    # Video qualities on the left, audio on the right; "Auto" is Options >
    # Online's. A lock has every link open alike: in that video quality when
    # offered, in the audio row that far down (first, middle, last).
    let q = newMenuRoot()
    q.columns = true
    let url = a.player.path
    let w = a.chosen(url)
    let found = a.qualitiesOf(url)
    let looking = not found.known and a.ytCaps.running and a.ytCaps.url == url
    let pickVideo = proc (id: string) =
      a.pickQuality(url, id, a.ytPick.getOrDefault(url).audio)
    let pickAudio = proc (id: string) =
      a.pickQuality(url, a.ytPick.getOrDefault(url).video, id)
    # Locking picks it for this link too; unlocking keeps this link as it is.
    let lockVideo = proc (x: Quality) =  # x.label: what's locked
      if a.cfg.streamLockVideo == x.label:
        let cur = a.chosen(url).video
        if not cur.startsWith("~"):
          a.ytPick.mgetOrPut(url, ("", "")).video = if cur.len > 0: cur else: "auto"
        a.cfg.streamLockVideo = ""
      else:
        pickVideo(x.id)
        a.cfg.streamLockVideo = x.label
      a.cfg.save()
    let audio = a.audioRows(url)
    let rows = audio.len
    let lockAudio = proc (x: Quality) =  # x.label: "auto" or a rank
      let lk = a.cfg.streamLockAudio
      if lk == x.label or lk in AudioRanks and rankRow(lk, rows) == rankRow(x.label, rows):
        let cur = a.chosen(url).audio
        if not cur.startsWith("~"):
          a.ytPick.mgetOrPut(url, ("", "")).audio = if cur.len > 0: cur else: "auto"
        a.cfg.streamLockAudio = ""
      else:
        pickAudio(x.id)
        a.cfg.streamLockAudio = x.label
      a.cfg.save()
    let vc = q.column("Video")
    vc.radio("Auto", checked = w.video.len == 0, action = bindAct(pickVideo, "auto"),
      lock = bindAct(lockVideo, ("auto", "auto", "", "")), locked = a.cfg.streamLockVideo == "auto")
    for x in found.video:
      vc.radio(x.label, checked = w.video == x.id, action = bindAct(pickVideo, x.id),
        lock = bindAct(lockVideo, x), locked = a.cfg.streamLockVideo == x.label)
    if looking: vc.item("...", enabled = false)
    let ac = q.column("Audio")
    ac.radio("Auto", checked = w.audio.len == 0, action = bindAct(pickAudio, "auto"),
      lock = bindAct(lockAudio, ("auto", "auto", "", "")), locked = a.cfg.streamLockAudio == "auto")
    for i, x in audio:
      # Only the rows a rank stands for take a lock, so it sits where it means.
      var rank = ""
      for r in ["highest", "lowest", "mid"]:  # two rows: the second is the lowest
        if rankRow(r, rows) == i and rank.len == 0: rank = r
      if rank.len > 0:
        let lk = a.cfg.streamLockAudio
        ac.radio(x.label, checked = w.audio == x.id, action = bindAct(pickAudio, x.id),
          lock = bindAct(lockAudio, (x.id, rank, "", "")),
          locked = lk in AudioRanks and rankRow(lk, rows) == i)
      else:
        ac.radio(x.label, checked = w.audio == x.id, action = bindAct(pickAudio, x.id))
    if looking: ac.item("...", enabled = false)
    (root, q)
  of cmRunLog:
    let rl = newMenuRoot()
    # The selected text, or the whole log when nothing is selected.
    let sel = a.rlSelection
    rl.item("Copy to Clipboard", enabled = a.rlRows.len > 0, action = proc () =
      if sel.len > 0:
        setClipboardString(sel)
        a.osd("Copied the selected text")
      else:
        setClipboardString(a.rlRows.join("\n"))
        a.osd("Copied the run log"))
    (root, rl)
  of cmPlaylist:
    let pl = newMenuRoot()
    let n = a.playlist.len
    let hasSel = a.plSelection.len > 0
    let edit = not locked
    if hasSel:
      let path = a.playlist[a.plSelected]
      pl.item("Open Containing Directory", enabled = not path.contains("://"),
        action = proc () = a.showInFolder(path))
      pl.sep()
    else:
      pl.item("Add Media File...", enabled = edit, action = proc () =
        a.ask(dkOpenFiles, "pladd", "Add Media File", exts = @MediaExtensions,
          filterName = "Media files"))
    pl.item("Remove Media File", k(kaRemoveFromPlaylist), enabled = hasSel and edit, action = proc () =
      a.removeSelected())
    pl.item("Duplicate", "Ctrl+D", enabled = hasSel and edit, action = proc () =
      a.duplicateSelected())
    pl.sep()
    let sortBy = proc (by: PlaylistField) = a.sortPlaylist(by)
    for (label, by) in [("Sort by A-Z", pfName), ("Sort by Duration", pfDuration),
                        ("Sort by Dimensions", pfDimensions), ("Sort by Size", pfSize)]:
      pl.item(label, enabled = n > 1 and edit, action = bindAct(sortBy, by))
    pl.sep()
    let moveTo = proc (m: PlaylistMove) = a.moveSelected(m)
    let up = a.canMove(true) and edit
    let down = a.canMove(false) and edit
    pl.item("Move to Top", "Ctrl+Shift+Home", enabled = up, action = bindAct(moveTo, pmTop))
    pl.item("Move Up", "Ctrl+Shift+Up", enabled = up, action = bindAct(moveTo, pmUp))
    pl.item("Move Down", "Ctrl+Shift+Down", enabled = down, action = bindAct(moveTo, pmDown))
    pl.item("Move to Bottom", "Ctrl+Shift+End", enabled = down, action = bindAct(moveTo, pmBottom))
    pl.sep()
    pl.item("Randomize", enabled = n > 1 and edit, action = proc () = a.randomizePlaylist())
    pl.sep()
    pl.item("Save Playlist...", enabled = n > 0, action = proc () = a.savePlaylistDialog())
    pl.item("Load Playlist...", enabled = edit, action = proc () = a.loadPlaylistDialog())
    pl.sep()
    pl.item("Clear", enabled = n > 0 and edit, action = proc () = a.clearPlaylist())
    pl.sep()
    pl.check("Cursor follows playback", checked = a.cfg.playlistCursorFollows, action = proc () =
      a.cfg.playlistCursorFollows = not a.cfg.playlistCursorFollows)
    (root, pl)
  of cmPlaylistColumns:
    let cols = newMenuRoot()
    if a.ctxColumn == pfDuration:
      cols.check("Show milliseconds", checked = a.cfg.playlistShowMillis, action = proc () =
        a.cfg.playlistShowMillis = not a.cfg.playlistShowMillis
        a.cfg.save())
      cols.sep()
    let toggle = proc (f: PlaylistField) =
      let at = a.cfg.playlistColumns.find(f)
      if at >= 0: a.cfg.playlistColumns.delete(at)
      else: a.cfg.playlistColumns.add f
    let shown = a.cfg.playlistColumns
    for f in PlaylistField:
      # The last column left stays: the header is what brings the others back.
      cols.check(PlaylistFields[f].label, checked = f in shown,
        enabled = f notin shown or shown.len > 1, action = bindAct(toggle, f))
    (root, cols)

# --- keyboard ---------------------------------------------------------------

proc runMenuPath(a: App, path: seq[string]) =
  ## Runs the action of the menu item at path, e.g. @["View", "Seek Bar"].
  var node = a.buildMenu().bar
  for name in path:
    var found: MenuNode
    for ch in node.children:
      if ch.label == name: found = ch
    if found == nil:
      if existsEnv("MMP_SCRIPT"):
        stderr.writeLine "menu path not found: ", name, " in ", $node.children.mapIt(it.label)
      return
    node = found
  if node.action != nil and node.enabled: node.action()

# --- subtitle placement ------------------------------------------------------

const
  SubMoveStep = 2'f32        ## Shift+arrows, screen pixels
  SubScaleStep = 0.1'f32     ## Shift+Numpad +/-
  SubMarginX = 19            ## mpv's sub-margin-x / sub-margin-y defaults
  SubMarginY = 34
  OsdMargin = 16'f32         ## mpv's osd-margin-x / osd-margin-y defaults
  OsdOutline = 1.65'f32      ## osd-outline-size
  OsdBarW = 75'f32           ## osd-bar-w / -h (percent), -align-x / -y
  OsdBarH = 3.125'f32
  OsdBarAlign = (x: 0'f32, y: 0.5'f32)
  OsdBarOutline = 0.5'f32    ## osd-bar-outline-size
  OsdBarMarkerMin = 1.6'f32  ## osd-bar-marker-min-size

proc alignSubs(a: App, x, y: int) =
  ## Re-aligning drops the nudge: it was relative to the old anchor.
  a.subs.alignX = x
  a.subs.alignY = y
  a.subs.offset = vec2(0, 0)
  const names = [["Top Left", "Top", "Top Right"], ["Left", "Middle", "Right"],
                 ["Bottom Left", "Bottom", "Bottom Right"]]
  a.osd("Subtitles: " & names[y][x])

proc moveSubs(a: App, d: Vec2) =
  a.subs.offset += d
  a.osd(&"Subtitle offset: {int(a.subs.offset.x)}, {int(a.subs.offset.y)}")

proc scaleSubs(a: App, dir: float32) =
  a.subs.scale = clamp(round((a.subs.scale + dir * SubScaleStep) * 10) / 10, 0.2'f32, 5'f32)
  let path = a.player.path
  if a.player.loaded and path.len > 0:
    # Reloaded first so sizes other players remembered meanwhile survive.
    a.subScales = loadSubScales()
    if a.subs.scale == 1: a.subScales.del(path)
    else: a.subScales.remember(path, a.subs.scale)
    a.subScales.save()
  a.osd(&"Subtitle size: {int(round(a.subs.scale * 100))}%")

proc subPadding(a: App): tuple[l, r, t, b: float32] =
  ## mpv can't shift centered subtitles, but text subtitles are laid out on
  ## the whole render target while video-margin-ratio keeps the video out of
  ## its margins: padding one side of the target moves them by half of it.
  let o = a.subs.offset
  if a.subs.alignX == 1:
    result.l = max(0, -2 * o.x)
    result.r = max(0, 2 * o.x)
  if a.subs.alignY == 1:
    result.t = max(0, -2 * o.y)
    result.b = max(0, 2 * o.y)

proc marginFill(a: App, target: (int, int), mx, my: (int, int)): (float32, float32) =
  ## video-scale-x/y that stretch mpv's aspect-fitted video over the whole
  ## box left inside the margins: mpv only honors the margins with
  ## keepaspect, and keepaspect would otherwise undo the frame's own aspect
  ## (Stretch, Increase Width...). Mirrors aspect_calc_panscan, plus half a
  ## pixel so mpv's truncation lands on the box edge.
  let (dw, dh) = (a.player.videoW.float32, a.player.videoH.float32)
  if dw <= 0 or dh <= 0: return (1'f32, 1'f32)
  let boxW = target[0] - mx[0] - mx[1]
  let boxH = target[1] - my[0] - my[1]
  var fw = boxW
  var fh = int(boxW.float32 / dw * dh)
  if fh > boxH or fh < a.player.videoH:
    let tw = int(boxH.float32 / dh * dw)
    if tw <= boxW:
      fh = boxH
      fw = tw
  ((boxW.float32 + 0.5) / max(1, fw).float32, (boxH.float32 + 0.5) / max(1, fh).float32)

const OsdPlayResY = 288.0  ## mpv's canvas height for the OSD and text subtitles

proc lrint(x: float): float =
  ## C's lrint under the default rounding mode: halves go to the even side.
  let f = floor(x)
  if x - f > 0.5 or (x - f == 0.5 and (int64(f) and 1) != 0): f + 1 else: f

proc subMarginPx(marginX, w, h, cw, ch: int): float =
  ## Pixels between a left/right-anchored text subtitle and the target's edge
  ## for --sub-margin-x=marginX, in a w x h target holding a cw x ch video:
  ## mpv truncates the margin to 288-high units, rescales it to its
  ## video-aspect PlayResX (sd_ass configure_ass) and libass maps those
  ## units over the video fitted into the target (fit_width).
  let resX = float(int(OsdPlayResY * (float(cw) / float(ch))))
  let units = lrint(float(int(float(marginX) * OsdPlayResY / 720)) * resX / 384)
  let fit = if cw * h >= ch * w: float(w) else: float(cw) * float(h) / float(ch)
  units * fit / resX

proc unitsOpt(units: int): int =
  ## Smallest margin option mpv truncates to `units` 288-high units.
  int(ceil(float(units) * 720 / OsdPlayResY + 0.1))

proc osdLayout(alignX, marginX: int, target: (int, int), mx, my: (int, int)):
    tuple[target, x, y: (int, int), subMarginX: int, unit: float, props: string] =
  ## The OSD is laid out on the whole (padded) target: counter-scale and
  ## re-place it so it keeps the look and spot it has on the unpadded video.
  ## Its canvas is 288 units high (PlayResX = 288 * aspect, truncated) and
  ## mpv truncates its margins to whole units, ~2 pixels or more, so a padded
  ## target gets extra pixels on both sides of each axis, chosen so whole
  ## units land on the spot. They leave centered subtitles in place; anchored
  ## ones get their sub-margin-x redone to stay put. Returns the grown target
  ## and margins, the subtitles' margin option, the factor that undoes the
  ## padding's growth of OSD sizes and the OSD property settings (but for
  ## osd-scale and osd-outline-size, see osdSizes).
  let (cw, ch) = (target[0] - mx[0] - mx[1], target[1] - my[0] - my[1])
  result = (target, mx, my, marginX, 1.0, "")
  if cw <= 0 or ch <= 0: return
  let (vw, vh) = (float(cw), float(ch))
  proc playResX(w, h: float): float = float(int(OsdPlayResY * (w / h)))
  const marginUnits = int(OsdMargin * OsdPlayResY / 720)  # mpv's own text margin
  # Where the text sits on the unpadded video, in target pixels.
  let textX = float(marginUnits) * vw / playResX(vw, vh)
  let textY = float(marginUnits) * vh / OsdPlayResY
  # Where the anchored subtitles sit, from the video's left edge.
  proc subX(m, w, h, left: int): float =
    let px = subMarginPx(m, w, h, cw, ch)
    (if alignX == 0: px else: float(w) - px) - float(left)
  let subRef = subX(marginX, target[0], target[1], mx[0])
  let padded = mx[0] + mx[1] + my[0] + my[1] > 0
  # Each extra pixel moves the spot by one but also grows the units the
  # margin is made of, so the farther the margin, the more pixels it takes
  # to sweep a whole unit; anchored subtitles' units add their own period.
  let (w0, h0) = (float(target[0]), float(target[1]))
  let (ux0, uy0) = (w0 / playResX(w0, h0), h0 / OsdPlayResY)
  let slowX = max(0.08, 1 - 2 * (textX + float(mx[0])) / ux0 / playResX(w0, h0))
  let slowY = max(0.08, 1 - 2 * (textY + float(my[0])) / uy0 / OsdPlayResY)
  let spanX = if not padded: 0 else: min(400, max(64, max(int(24 * uy0), int(32 / slowX))))
  let spanY = if not padded or my[0] + my[1] == 0: 0 else: min(400, max(32, int(32 / slowY)))
  var best = (score: Inf, ex: 0, ey: 0, ml: marginUnits, mv: marginUnits, sm: marginX)
  for ey in 0 .. spanY:
    for ex in 0 .. spanX:
      let left = mx[0] + ex
      let (w, h) = (target[0] + 2 * ex, target[1] + 2 * ey)
      let (ux, uy) = (float(w) / playResX(float(w), float(h)), float(h) / OsdPlayResY)  # pixels per unit
      let (x, y) = (textX + float(left), textY + float(my[0] + ey))
      let (ml, mv) = (int(round(x / ux)), int(round(y / uy)))
      var err = max(abs(float(ml) * ux - x), abs(float(mv) * uy - y))
      var sm = marginX
      if alignX != 1 and ex > 0:
        # Redo the subtitles' margin for the moved edge: try the unit counts
        # around the one that would put them back.
        let need = (if alignX == 0: subRef + float(left) else: float(w - left) - subRef)
        var subErr = Inf
        let perUnit = subMarginPx(unitsOpt(8), w, h, cw, ch) / 8  # pixels per 288-high unit, roughly
        let k = int(need / perUnit)
        for kk in max(0, k - 2) .. k + 2:
          let m = unitsOpt(kk)
          let e = abs(subX(m, w, h, left) - subRef)
          if e < subErr: (subErr, sm) = (e, m)
        err = max(err, 2 * subErr)  # the subtitles are what's being watched
      let score = err + 0.001 * float(ex + ey)  # equal fits: less padding
      if score < best.score: best = (score, ex, ey, ml, mv, sm)
  let (ex, ey) = (best.ex, best.ey)
  result.target = (target[0] + 2 * ex, target[1] + 2 * ey)
  result.x = (mx[0] + ex, mx[1] + ex)
  result.y = (my[0] + ey, my[1] + ey)
  result.subMarginX = best.sm
  let (w, h) = (float(result.target[0]), float(result.target[1]))
  let (resX0, resX) = (playResX(vw, vh), playResX(w, h))
  let f = vh / h  # undoes the taller canvas's bigger units
  let barOutline = OsdBarOutline * f
  let barW = OsdBarW * vw / w
  let barH = max(0.1, OsdBarH * f)
  proc align(a, frame0, unit0, offset, frame, unit: float, obj, border: float): float =
    ## osd-bar-align that puts the bar where `a` puts it on the unpadded
    ## video (mirrors mpv's get_align; frames in units, units in pixels).
    let (obj0, border0) = (obj * unit / unit0, border * unit / unit0)
    let pos0 = border0 + (frame0 - 2 * border0 - obj0) / 2 * (1 + a)
    let pos = (pos0 * unit0 + offset) / unit
    let free = (frame - 2 * border - obj) / 2
    if free <= 0: a else: clamp((pos - border - free) / free, -1.0, 1.0)
  let barX = align(OsdBarAlign.x, resX0, vw / resX0, float(result.x[0]), resX, w / resX,
                   resX * barW / 100, barOutline)
  let barY = align(OsdBarAlign.y, OsdPlayResY, vh / OsdPlayResY, float(result.y[0]), OsdPlayResY,
                   h / OsdPlayResY, OsdPlayResY * barH / 100, barOutline)
  let markerMin = OsdBarMarkerMin * f
  result.unit = f
  result.props = &"osd-margin-x={unitsOpt(best.ml)}|osd-margin-y={unitsOpt(best.mv)}|" &
    &"osd-bar-w={barW:.6f}|osd-bar-h={barH:.6f}|osd-bar-align-x={barX:.6f}|" &
    &"osd-bar-align-y={barY:.6f}|osd-bar-outline-size={barOutline:.6f}|" &
    &"osd-bar-marker-min-size={markerMin:.6f}"

proc osdSizes(a: App, frameH: float, unit = 1.0): string =
  ## osd-scale and osd-outline-size for an OSD over a frame frameH pixels
  ## high (unit: see osdLayout). Options > Interface > OSD scaling sizes the
  ## text; unless it scales with the window, text and outline keep the size
  ## they have on a 720 pixel high frame.
  let fixed = if a.cfg.osdScaleByWindow: 1.0 else: 720 / max(1.0, frameH)
  let text = clamp(a.cfg.osdScale, OsdScaleMin, OsdScaleMax) * fixed * unit
  &"osd-scale={text:.6f}|osd-outline-size={OsdOutline * fixed * unit:.6f}"

proc applySubLayout(a: App, video: Vec2, pad: tuple[l, r, t, b: float32],
                    target: (int, int)): tuple[x, y: (int, int), target: (int, int)] =
  ## Pushes the placement for a video drawn `video` pixels big into a
  ## `target` pixels big render target, returning the margins (target
  ## pixels) mpv keeps the video out of and the target size, which the OSD
  ## placement may grow by a few pixels. The anchored
  ## cases use mpv's own margins, in scaled pixels: 720 of them span the
  ## height, and text subtitles' 384x288 canvas makes 960 span the width.
  let s = a.subs
  let full = video + vec2(pad.l + pad.r, pad.t + pad.b)
  let (kx, ky) = (full.x / 960, full.y / 720)
  let marginX0 =
    case s.alignX
    of 0: max(0, int(round(SubMarginX + s.offset.x / kx)))
    of 2: max(0, int(round(SubMarginX - s.offset.x / kx)))
    else: SubMarginX
  let marginY = if s.alignY == 0: max(0, int(round(SubMarginY + s.offset.y / ky))) else: SubMarginY
  let pos = if s.alignY == 2: clamp(100 + s.offset.y / video.y * 100, 0'f32, 150'f32) else: 100'f32
  # Whole target pixels per margin; the ratios carry an extra half pixel so
  # mpv's truncation (calc_margin) lands on exactly these.
  let mx0 = (int(round(pad.l / full.x * target[0].float32)), int(round(pad.r / full.x * target[0].float32)))
  let my0 = (int(round(pad.t / full.y * target[1].float32)), int(round(pad.b / full.y * target[1].float32)))
  let fitKey = &"{s.alignX}|{s.alignY}|{marginX0}|{target}|{mx0}|{my0}"
  if a.osdFit.key != fitKey:
    let (t, x, y, m, u, props) = osdLayout(s.alignX, marginX0, target, mx0, my0)
    a.osdFit = (fitKey, t, x, y, m, u, props)
  let (target, mx, my) = (a.osdFit.target, a.osdFit.x, a.osdFit.y)
  let osd = a.osdFit.props & "|" & a.osdSizes(video.y, a.osdFit.unit)
  let marginX = a.osdFit.subMarginX
  # Subtitles scale with the target height; keep padding from growing them.
  let scale = s.scale * float32(target[1] - my[0] - my[1]) / target[1].float32
  proc ratio(m, size: int): float32 = (if m > 0: (m.float32 + 0.5) / size.float32 else: 0)
  let ratios = (l: ratio(mx[0], target[0]), r: ratio(mx[1], target[0]),
                t: ratio(my[0], target[1]), b: ratio(my[1], target[1]))
  let padded = mx[0] + mx[1] + my[0] + my[1] > 0
  result = (mx, my, target)
  let (fillX, fillY) = if padded: a.marginFill(target, mx, my) else: (1'f32, 1'f32)
  let key = &"{s.alignX}|{s.alignY}|{marginX}|{marginY}|{pos:.3f}|{scale:.4f}|" &
    &"{ratios.l:.5f}|{ratios.r:.5f}|{ratios.t:.5f}|{ratios.b:.5f}|{fillX:.6f}|{fillY:.6f}|{osd}"
  if key == a.subsKey: return
  a.subsKey = key
  let h = a.player.h
  h.setProp("sub-align-x", ["left", "center", "right"][s.alignX])
  h.setProp("sub-align-y", ["top", "center", "bottom"][s.alignY])
  h.setProp("sub-margin-x", $marginX)
  h.setProp("sub-margin-y", $marginY)
  h.setProp("sub-pos", pos)
  h.setProp("sub-scale", scale)
  h.setProp("video-margin-ratio-left", ratios.l)
  h.setProp("video-margin-ratio-right", ratios.r)
  h.setProp("video-margin-ratio-top", ratios.t)
  h.setProp("video-margin-ratio-bottom", ratios.b)
  # Unpadded, keepaspect stays off: the target already has the frame's aspect.
  h.setProp("keepaspect", padded)
  h.setProp("video-scale-x", fillX)
  h.setProp("video-scale-y", fillY)
  for kv in osd.split('|'):
    if kv.len > 0:
      let p = kv.split('=')
      h.setProp(p[0], p[1])

const PanMenuLabels: array[kaCenter .. kaPanReset, string] = [
  "Center", "Move Up", "Move Down", "Move Left", "Move Right", "0 Degrees",
  "Rotate Clockwise", "Rotate Counter-clockwise", "Restore Size", "Increase Size",
  "Decrease Size", "Increase Width", "Decrease Width", "Increase Height",
  "Decrease Height", "Reset"]

proc runAction(a: App, act: KeyAction) =
  ## Carries out a rebindable command (Options > Player > Keys). View toggles
  ## and Pan/Rotate/Scale go through the menu actions so the window-resizing
  ## side effects live in one place.
  case act
  of kaOpenFile: a.openFileDialog()
  of kaLoadSubtitle:
    if a.player.loaded:
      a.ask(dkOpenFile, "subtitle", "Load Subtitle", exts = @SubtitleExtensions,
        filterName = "Subtitles")
  of kaLoadAudio:
    if a.player.loaded:
      a.ask(dkOpenFile, "audio", "Load Audio Track", exts = @MediaExtensions,
        filterName = "Audio files")
  of kaOpenClipboard: a.openFromClipboard()
  of kaCopyClipboard: a.copyToClipboard()
  of kaCopyTimeLink: a.copyTimeLink()
  of kaClose: a.closeFile()
  of kaSave: a.saveMedia()
  of kaScreenshot: a.screenshot()
  of kaProperties: a.showOverlay(ovProperties)
  of kaExit: a.window.closeRequested = true
  of kaPlayPause: a.playPause()
  of kaStop: a.runMenuPath(@["Play", "Stop"])
  of kaFrameForward: a.frameStep(true)
  of kaFrameBack: a.frameStep(false)
  of kaFaster: a.changeRate(1)
  of kaSlower: a.changeRate(-1)
  of kaRepeatForever: a.runMenuPath(@["Play", "Repeat", "Forever"])
  of kaRepeatPingPong: a.runMenuPath(@["Play", "Repeat", "Ping-Pong"])
  of kaVolumeUp: a.volumeStep(true)
  of kaVolumeDown: a.volumeStep(false)
  of kaMute: a.setMute(not a.player.muted)
  of kaNextAudio: a.cycleTrack("aid", true)
  of kaPrevAudio: a.cycleTrack("aid", false)
  of kaNextSub: a.cycleTrack("sid", true)
  of kaPrevSub: a.cycleTrack("sid", false)
  of kaJumpForward: a.seekRelative(a.cfg.seekStep)
  of kaJumpBack: a.seekRelative(-a.cfg.seekStep)
  of kaGoBeginning: a.seekTo(0)
  of kaSeek10 .. kaSeek90:
    if a.player.loaded:
      let k = act.ord - kaSeek10.ord + 1
      if a.isSlave: a.seekTo(a.player.duration * k.float / 10)
      else:
        a.player.stopped = false
        a.player.seekPercent(float(k * 10))
        a.syncSend("seek", $(a.player.duration * k.float / 10), "true")
  of kaNextChapter: a.chapterStep(1)
  of kaPrevChapter: a.chapterStep(-1)
  of kaNextFile: a.navigate(1)
  of kaPrevFile: a.navigate(-1)
  of kaAddBookmark: a.addBookmark(a.player.timePos)
  of kaRemoveFromPlaylist:
    if a.cfg.showPlaylist: a.removeSelected()
  of kaSubTopLeft .. kaSubBottomRight:
    # The numpad as a 3x3 grid.
    let i = act.ord - kaSubTopLeft.ord
    a.alignSubs(i mod 3, i div 3)
  of kaSubUp: a.moveSubs(vec2(0, -SubMoveStep))
  of kaSubDown: a.moveSubs(vec2(0, SubMoveStep))
  of kaSubMoveLeft: a.moveSubs(vec2(-SubMoveStep, 0))
  of kaSubMoveRight: a.moveSubs(vec2(SubMoveStep, 0))
  of kaSubBigger: a.scaleSubs(1)
  of kaSubSmaller: a.scaleSubs(-1)
  of kaCompact: a.setCompact(not a.cfg.compactMode)
  of kaSeekBar: a.runMenuPath(@["View", "Seek Bar"])
  of kaControls: a.runMenuPath(@["View", "Controls"])
  of kaStatus: a.runMenuPath(@["View", "Status"])
  of kaPlaylist: a.runMenuPath(@["View", "Playlist"])
  of kaRunLog: a.runMenuPath(@["View", "Run Log"])
  of kaShowOsd: a.runMenuPath(@["View", "Show OSD"])
  of kaFullScreen: a.setFullscreen(not a.fullscreen)
  of kaOptions: a.showOverlay(ovOptions)
  of kaShortcuts: a.showOverlay(ovShortcuts)
  of kaCenter .. kaPanReset:
    a.runMenuPath(@["View", "Pan, Rotate & Zoom", PanMenuLabels[act]])

proc rectKeys(a: App): bool  # rectangle drawing, below

proc handleKeys(a: App) =
  let w = a.window
  let pressed = w.buttonPressed
  if a.rectKeys(): return

  if pressed[KeyEscape]:
    # A text field being edited takes Escape itself.
    if a.overlay == ovOptions: a.closeOptions(false)
    elif a.overlay == ovRename: a.closeRename()
    elif a.overlay in {ovCommands, ovSync, ovYtdlp, ovEmbed, ovUpdate}: discard  # their windows handle Escape
    elif a.overlay != ovNone: a.overlay = ovNone
    elif a.menus.isOpen: a.menus.close()
    elif a.fullscreen: a.setFullscreen(false)
    return
  if a.overlay == ovProperties:
    # The report scrolls from the keyboard too; propertiesOverlay clamps.
    const RowH = 21'f32
    let page = max(RowH, a.propPageH - RowH * 2)
    if pressed[KeyDown]: a.propScroll += RowH
    elif pressed[KeyUp]: a.propScroll -= RowH
    elif pressed[KeyPageDown] or pressed[KeySpace]: a.propScroll += page
    elif pressed[KeyPageUp]: a.propScroll -= page
    elif pressed[KeyHome]: a.propScroll = 0
    elif pressed[KeyEnd]: a.propScroll = float32.high
  if a.overlay != ovNone: return

  # Ctrl+C with text selected in the run log copies that text instead.
  if pressed[KeyC] and w.ctrl and not w.alt and not w.shiftDown and a.cfg.showRunLog:
    let sel = a.rlSelection
    if sel.len > 0:
      setClipboardString(sel)
      a.osd("Copied the selected text")
      return
  if a.playlistKeys(): return

  let (ok, act) = a.cfg.pressedAction(w)
  if ok: a.runAction(act)

# --- video geometry ---------------------------------------------------------

proc videoGeometry(a: App, area: Rect, xf: VideoTransform): tuple[center, size: Vec2] =
  let nat = a.naturalSize
  var base =
    case a.cfg.frameMode
    of fmHalf: nat * 0.5
    of fmFull: nat
    of fmDouble: nat * 2
    of fmStretch: area.wh
    of fmFit:
      if a.cfg.preserveAspect and nat.x > 0 and nat.y > 0:
        nat * min(area.w / nat.x, area.h / nat.y)
      else: area.wh
  base *= xf.zoom
  base.x *= xf.scaleX
  base.y *= xf.scaleY
  (area.xy + area.wh / 2 + xf.pan, base)

proc videoGeometry(a: App, area: Rect): tuple[center, size: Vec2] =
  a.videoGeometry(area, a.xf)

proc clockDur(p: Player): float =
  ## The duration fmtTime sizes the clock by: with nothing loaded it counts
  ## as short media (MM:SS), a stream of unknown length as long (HH:MM:SS).
  if p.loaded: p.duration else: 1

proc osdStatusText(a: App): string =
  ## The status line mpv's OSD level 3 shows (see applyOsd), as the OSD
  ## layer's literal text: its own player has no file to take it from.
  let p = a.player
  let ms = a.cfg.showMillis
  # osd-sym-cc: mpv's escape for a glyph of its OSD symbol font
  result = "\xC2\x91" & (if p.paused or p.stopped: '\x02' else: '\x01') & " "
  if a.cfg.showRemaining: result.add "-" & fmtTime(max(0, p.duration - p.timePos), ms, p.clockDur)
  else: result.add fmtTime(p.timePos, ms, p.clockDur)
  result.add " / " & fmtTime(p.duration, ms, p.clockDur)
  if p.duration > 0: result.add &" ({int(clamp(p.timePos / p.duration, 0, 1) * 100)}%)"

proc updateOsdApart(a: App) =
  ## mpv draws its OSD into the picture, which pan, rotation and scaling
  ## would carry along: while any applies, the OSD layer draws it instead,
  ## over the untransformed frame.
  let l = a.osdLayer
  if l == nil: return
  while mpv_wait_event(l.h, 0).eventId != evNone: discard  # nothing to act on
  let p = a.player
  let apart = p.hasVideo and not p.stopped and not p.isSpherical and
    (a.xf != VideoTransform() or a.lfOn or a.sfShow >= 0)  # loop and step frames hold no OSD
  if apart != a.osdApart:
    a.osdApart = apart
    a.osdStatus = ""
    a.osdFlag = true
    a.applyOsd()
  if not apart and a.osdFlag:  # nothing to draw: just take the update
    a.osdFlag = false
    discard mpv_render_context_update(l.render)
  if apart and a.cfg.showOsd and a.cfg.osdTimestamp:
    let s = a.osdStatusText()
    if s != a.osdStatus:
      a.osdStatus = s
      l.h.setProp("osd-msg3", s.replace("$", "$$"))
  for t in p.expanded:
    if apart: l.h.commandAsync("show-text", t, "1500")
    else: p.osd(t)
  p.expanded.setLen 0

proc osdLayerRect(a: App, area: Rect): Rect =
  ## Where the OSD layer goes: over the frame as it would be untransformed.
  let (center, size) = a.videoGeometry(area, VideoTransform())
  let (w, h) = (max(1'f32, round(size.x)), max(1'f32, round(size.y)))
  rect(round(center.x - w / 2), round(center.y - h / 2), w, h)

proc renderOsdLayer(a: App, area: Rect) =
  ## Brings the OSD layer's texture up to date. Outside the frame's scissor
  ## clip, like the video's own render, which it would otherwise cut.
  let l = a.osdLayer
  if l == nil: return
  let redraw = a.osdFlag
  if a.osdFlag:
    a.osdFlag = false
    discard mpv_render_context_update(l.render)
  if not a.osdApart: return
  let r = a.osdLayerRect(area)
  let sizes = a.osdSizes(r.h)
  if sizes != a.osdLayerSizes:
    a.osdLayerSizes = sizes
    for kv in sizes.split('|'):
      let p = kv.split('=')
      l.h.setProp(p[0], p[1])
  let resized = int(r.w) != l.target.w or int(r.h) != l.target.h
  l.target.ensureSize(int(r.w), int(r.h))
  if redraw or resized: l.render.render(l.target)

proc drawOsdLayer(a: App, area: Rect, fb: IVec2) =
  if a.osdLayer == nil or not a.osdApart: return
  let r = a.osdLayerRect(area)
  a.quad.draw(a.osdLayer.target.tex, rectCorners(r.xy, r.wh), fb.vec2, premul = true)

proc zoomAt(a: App, area: Rect, at: Vec2, notches: float32) =
  ## Ctrl+Wheel: zooms by the Resize step per notch (up = in). Zooming in
  ## keeps the point under the cursor in place; zooming out keeps the window
  ## center's. `area` and `at` are window pixels. Zooming out stops once the
  ## (rotated) frame touches the window from inside, and the pan shrinks so
  ## the frame ends up centered there.
  let step = 1 + a.cfg.sizeStep.float32 / 100
  var z = clamp(a.xf.zoom * pow(step, -notches), 0.05, 50)
  let c = area.xy + area.wh / 2
  if notches > 0:
    let size = a.videoGeometry(area).size
    let rad = a.xf.rotation * PI.float32 / 180
    let bw = abs(size.x * cos(rad)) + abs(size.y * sin(rad))
    let bh = abs(size.x * sin(rad)) + abs(size.y * cos(rad))
    if bw < 1 or bh < 1: return
    # Zoom at which the frame touches the window; a frame already smaller
    # (Half size, Decrease Size) just stays as it is.
    let touch = a.xf.zoom * min(area.w / bw, area.h / bh)
    let floorZ = min(a.xf.zoom, touch)
    if z <= floorZ:
      z = floorZ
      if a.xf.zoom == z and a.xf.pan == vec2(0, 0): return
    # Anchored at the window center (a cursor anchor slides the picture
    # sideways while it shrinks), with an edge that reaches the window's
    # staying on it. Never less than a pull in step with the zoom, so the
    # frame lands centered exactly when it reaches the touching size.
    let t = if a.xf.zoom > floorZ: (z - floorZ) / (a.xf.zoom - floorZ) else: 0'f32
    let k = z / a.xf.zoom
    let lim = vec2(max(0'f32, bw * k - area.w) / 2, max(0'f32, bh * k - area.h) / 2)
    for i in 0 .. 1:
      let p = a.xf.pan[i]
      a.xf.pan[i] = sgn(p).float32 * min(abs(p * k), max(lim[i], abs(p * t)))
  else:
    let k = z / a.xf.zoom
    a.xf.pan = at + (c + a.xf.pan - at) * k - c
  a.xf.zoom = z
  a.xfChanged(&"Zoom: {int(round(z * 100))}%")

proc frameBounds(a: App, area: Rect): Vec2 =
  ## Size of the (rotated) frame's bounding box, window pixels.
  let size = a.videoGeometry(area).size
  let rad = a.xf.rotation * PI.float32 / 180
  vec2(abs(size.x * cos(rad)) + abs(size.y * sin(rad)),
    abs(size.x * sin(rad)) + abs(size.y * cos(rad)))

proc panLimit(a: App, area: Rect): Vec2 =
  ## How far the pan may go from the center on each axis so the frame's
  ## edges don't cross into the window: a frame larger than the window
  ## keeps covering it, a smaller one stays inside it.
  let b = a.frameBounds(area)
  vec2(abs(b.x - area.w) / 2, abs(b.y - area.h) / 2)

proc canPan(a: App, area: Rect): bool =
  ## Zoomed in far enough that part of the frame lies outside the window.
  let b = a.frameBounds(area)
  a.xf.zoom > 1 and (b.x > area.w + 0.5 or b.y > area.h + 0.5)

proc panDragTo(a: App, area: Rect, at: Vec2) =
  ## Ctrl+Left drag: the frame follows the pointer, stopping where its
  ## edges meet the window's. A pan already past that (Numpad moves) doesn't
  ## jump back, it just can't go further out. `area` and `at` are window pixels.
  let lim = a.panLimit(area)
  let want = a.panStart + at - a.panFrom
  let p = vec2(
    clamp(want.x, min(-lim.x, a.panStart.x), max(lim.x, a.panStart.x)),
    clamp(want.y, min(-lim.y, a.panStart.y), max(lim.y, a.panStart.y)))
  if p != a.xf.pan:
    a.xf.pan = p
    a.xfChanged(&"Pan: {int(p.x)}, {int(p.y)}")

proc resetLook(a: App) =
  a.lookYaw = 0; a.lookPitch = 0; a.lookFov = SphereFov

proc lookDrag(a: App, at: Vec2) =
  ## Left drag on a 360° view: the picture follows the pointer, as if
  ## grabbed. `at` is in UI units, like the frame area.
  let k = a.lookFov / max(1'f32, a.videoRect.h)
  let d = at - a.lookLast
  a.lookLast = at
  a.lookYaw = floorMod(a.lookYaw - d.x * k, 360)
  a.lookPitch = clamp(a.lookPitch + d.y * k, -90, 90)

proc changeFov(a: App, notches: float32) =
  ## Ctrl+Wheel on a 360° view: up narrows the view (zooms in).
  a.lookFov = clamp(a.lookFov + notches * SphereFovStep, 20, 120)
  a.osd(&"Field of view: {int(round(a.lookFov))}°")

proc beginRotate(a: App, area: Rect, at: Vec2, atCursor: bool) =
  ## Alt+Middle press: the frame turns around its center, or around the
  ## cursor (Ctrl). `area` and `at` are window pixels.
  a.rotDrag = true
  a.rotStart = a.xf
  a.rotRefSet = false
  a.rotPressPos = at
  a.rotMoved = false
  a.rotPivot = if atCursor: at else: area.xy + area.wh / 2 + a.xf.pan

proc rotateDrag(a: App, area: Rect, at: Vec2, snap: bool) =
  ## Alt+Middle drag: turns the frame by the angle the cursor sweeps around
  ## the pivot; Shift snaps the rotation to multiples of the Rotate step.
  if not a.rotMoved:
    if (at - a.rotPressPos).length <= 4: return
    a.rotMoved = true
  let v = at - a.rotPivot
  if v.length < 8: return  # too close to the pivot for a steady angle
  let ang = arctan2(v.y, v.x) * 180 / PI.float32
  if not a.rotRefSet:
    a.rotRef = ang; a.rotRefSet = true
    return
  var r = floorMod(a.rotStart.rotation + ang - a.rotRef, 360)
  if snap:
    let step = max(1'f32, a.cfg.rotateStep.float32)
    r = floorMod(round(r / step) * step, 360)
  else: r = round(r * 10) / 10
  let d = (r - a.rotStart.rotation) * PI.float32 / 180
  let c = area.xy + area.wh / 2
  let o = c + a.rotStart.pan - a.rotPivot
  a.xf.pan = a.rotPivot + vec2(o.x * cos(d) - o.y * sin(d), o.x * sin(d) + o.y * cos(d)) - c
  if r != a.xf.rotation:
    a.xf.rotation = r
    a.xfChanged(&"Rotation: {r:g}°")

# --- rectangle drawing (Run window) ------------------------------------------

proc videoMap(a: App): VideoMap =
  let s = a.sk.uiScale
  let (center, size) = a.videoGeometry(a.px(a.videoRect))
  VideoMap(center: center / s, size: size / s, rotation: a.xf.rotation,
    video: ivec2(a.player.pixelW.int32, a.player.pixelH.int32))

proc rectBlocker(a: App): string =
  ## Why no rectangle can be drawn over the video now, else "".
  let p = a.player
  if not p.hasVideo or p.stopped or p.pixelW <= 0 or p.pixelH <= 0: "No video is showing"
  elif p.isSpherical: "Rectangles can't be drawn on a 360° video"
  elif abs(a.xf.rotation / 90 - round(a.xf.rotation / 90)) > 0.001:
    "Rectangles need the frame turned by a multiple of 90°"
  else: ""

proc applyRect(a: App) =
  ## The drawn rectangle's numbers into the Run window rows it sets.
  let e = a.rectEdit
  let d = a.pickDlg
  if e == nil or not e.has: return
  for i, row in d.rows:
    if row.isRect and row.rect == e.rect and not d.crossed[i]:
      d.texts[i] = $e.value($row.dim)
  a.dirtyUntil = now() + 0.5

proc endRectDraw(a: App, keep: bool, refocus = true) =
  ## Stops drawing, keeping the numbers drawn or going back to the values
  ## from before.
  if a.rectEdit == nil: return
  if not keep: a.pickDlg.texts = a.rectBefore
  a.rectEdit = nil
  a.pickDlg.drawing = 0
  a.dirtyUntil = now() + 0.5
  if refocus and a.pickOpen: a.pickWin.activate()

proc movePickAside(a: App) =
  ## Takes the Run window off the video: beside the main window, when its
  ## monitor has room there.
  let w = a.pickWin
  let fp = w.framePos
  let off = w.pos - fp
  let width = w.size.x + 2 * off.x
  let mainL = a.window.framePos.x
  let mainR = a.window.pos.x + a.window.size.x + (a.window.pos.x - mainL)
  if fp.x + width <= mainL or fp.x >= mainR: return
  let m = monitorAt(a.window.pos + a.window.size div 2)
  let x =
    if mainR + width <= m.pos.x + m.size.x: mainR
    elif mainL - width >= m.pos.x: mainL - width
    else: return
  w.pos = ivec2(x, fp.y) + off

proc beginRectDraw(a: App, id: int) =
  ## Left-click on a Run window rectangle icon: draw that rectangle over the
  ## video, starting from the numbers its rows hold.
  let err = a.rectBlocker
  if err.len > 0:
    a.osd(err)
    return
  a.endRectDraw(true, refocus = false)
  let d = a.pickDlg
  a.rectBefore = d.texts
  var v: array[RectDim, int]
  var known: set[RectDim]
  for i, row in d.rows:
    if row.isRect and row.rect == id and d.texts[i].len > 0:
      try:
        v[row.dim] = parseInt(d.texts[i])
        known.incl row.dim
      except ValueError: discard
  let m = a.videoMap
  let e = RectEdit(rect: id)
  # Numbers without a card take the rest of the video; a rectangle of no
  # size isn't one.
  if known != {} and not (rdWidth in known and v[rdWidth] == 0) and
     not (rdHeight in known and v[rdHeight] == 0):
    e.seed(v[rdX], v[rdY],
      if rdWidth in known: v[rdWidth] else: m.video.x - v[rdX],
      if rdHeight in known: v[rdHeight] else: m.video.y - v[rdY], m)
  a.rectEdit = e
  d.drawing = id
  a.movePickAside()
  a.window.activate()
  a.dirtyUntil = now() + 0.5

proc rectKeys(a: App): bool =
  ## Keys while a rectangle is drawn: Enter keeps it, Escape goes back, the
  ## arrows move it a pixel.
  let e = a.rectEdit
  if e == nil: return false
  result = true
  let p = a.window.buttonPressed
  if p[KeyEnter] or p[NumpadEnter]: a.endRectDraw(true)
  elif p[KeyEscape]: a.endRectDraw(false)
  else:
    var d = ivec2(0, 0)
    if p[KeyLeft]: d.x -= 1
    if p[KeyRight]: d.x += 1
    if p[KeyUp]: d.y -= 1
    if p[KeyDown]: d.y += 1
    if e.nudge(a.videoMap, d): a.applyRect()

proc pollVideoFrame(a: App) =
  ## Picks up newly queued mpv frames and decides whether one is due.
  if a.frameFlag:
    a.frameFlag = false
    let flags = mpv_render_context_update(a.player.render)
    if (flags and MpvRenderUpdateFrame) != 0:
      a.framePending = true
      a.frameDue = a.player.render.nextFrameTarget()
  a.renderNow = a.framePending and
    (a.frameDue == 0 or mpv_get_time_ns(a.player.h) >= a.frameDue - 1_500_000)

proc drawSphere(a: App, area: Rect, fb: IVec2, flags: uint64) =
  ## 360° video: mpv renders the whole equirectangular picture at its own
  ## size, then the camera's view of it fills the frame area.
  let p = a.player
  let cap = min(1'f32, SphereTextureMax / max(p.videoW, p.videoH).float32)
  let size = (max(1, int(round(p.videoW.float32 * cap))), max(1, int(round(p.videoH.float32 * cap))))
  let (_, _, (tw, th)) = a.applySubLayout(vec2(size[0].float32, size[1].float32),
    (l: 0'f32, r: 0'f32, t: 0'f32, b: 0'f32), size)
  let resized = tw != p.target.w or th != p.target.h
  p.target.ensureSize(tw, th)
  let fresh = resized or (flags and MpvRenderUpdateFrame) != 0
  if fresh: p.render.render(p.target)
  let s = p.sphere
  var v = SphereView(yaw: a.lookYaw, pitch: a.lookPitch, fov: a.lookFov,
    poseYaw: s.yaw, posePitch: s.pitch, poseRoll: s.roll,
    bounds: [s.left, s.right, s.top, s.bottom], eye: [0'f32, 0, 1, 1])
  # Stereo pictures hold both eyes: show the first.
  case s.stereo
  of slTopBottom: v.eye = [0'f32, 0, 1, 0.5]
  of slSideBySide: v.eye = [0'f32, 0, 0.5, 1]
  of slMono: discard
  glEnable(GL_SCISSOR_TEST)
  glScissor(GLint(area.x), GLint(fb.y.float32 - area.y - area.h), GLsizei(area.w), GLsizei(area.h))
  a.quad.drawSphere(p.target.tex, area, fb.vec2, v, fresh)
  glDisable(GL_SCISSOR_TEST)

proc holdFrame(a: App) =
  ## The frame shown stays up while the link opens again in another quality,
  ## until the new stream shows its own (drawVideo).
  let p = a.player
  if a.holding:  # picked again meanwhile: the first frame still
    a.heldSince = now()
    a.heldFresh = false
    return
  if not p.hasVideo or p.stopped or p.isSpherical or p.target.tex == 0: return
  a.heldTarget = p.target
  p.target = VideoTarget()
  a.heldCorners = a.videoCorners
  a.heldPath = p.path
  a.heldSince = now()
  a.heldFresh = false
  a.holding = true

proc drawHeld(a: App, area: Rect, fb: IVec2, flags: uint64): bool =
  ## While holding: the held frame where it was, true; false once the new
  ## stream has a frame to show (or it failed, or something else opened).
  let p = a.player
  let fresh = (flags and MpvRenderUpdateFrame) != 0
  if fresh and not p.opening: a.heldFresh = true
  let ready = not p.opening and p.loaded and p.hasVideo and
    p.restarts > p.loadedRestarts and a.heldFresh
  if ready or p.path != a.heldPath or p.stopped or p.loadError.len > 0 or
     now() - a.heldSince > 30:
    a.heldTarget.free()
    a.holding = false
    return false
  if fresh:  # consumed, so mpv keeps its pipeline moving
    p.target.ensureSize(16, 16)
    p.render.render(p.target)
  a.renderOsdLayer(area)
  glEnable(GL_SCISSOR_TEST)
  glScissor(GLint(area.x), GLint(fb.y.float32 - area.y - area.h), GLsizei(area.w), GLsizei(area.h))
  a.quad.draw(a.heldTarget.tex, a.heldCorners, fb.vec2)
  a.drawOsdLayer(area, fb)
  glDisable(GL_SCISSOR_TEST)
  true

proc wantedThumb(a: App): string =
  ## The YouTube video id whose thumbnail the frame shows, "" for none: while
  ## a link plays without a video track, unless turned off or at Options >
  ## Online's Lowest Quality (nothing downloaded beyond the streams).
  let p = a.player
  if not a.cfg.ytThumbnail or a.cfg.streamQuality == sqLowest: return
  if not p.loaded or p.stopped or p.hasVideo or a.holding: return
  if a.plIndex notin 0 ..< a.playlist.len: return
  a.playlist[a.plIndex].youtubeId

proc thumbShown(a: App): bool =
  let id = a.wantedThumb
  id.len > 0 and a.thumb != nil and a.thumb.id == id and a.thumb.image != nil

proc pollThumbnail(a: App) =
  let id = a.wantedThumb
  if id.len == 0:
    if a.thumb.running:  # turned off meanwhile: no more downloading
      a.thumb.cancel()
      a.thumb = nil
    return
  if a.thumb == nil or a.thumb.id != id:
    a.thumb.cancel()
    a.thumb = fetchThumbnail(id)
    a.dirtyUntil = max(a.dirtyUntil, now() + 0.1)
  elif a.thumb.poll():
    a.dirtyUntil = max(a.dirtyUntil, now() + 0.1)

proc wantedBoard(a: App): string =
  ## The YouTube video id whose storyboard the seek bar previews, "" for none:
  ## a link playing, unless turned off or at Options > Online's Lowest Quality.
  ## Files have their frames (a link saved plays from one).
  if not a.cfg.seekPreview or not a.cfg.ytSeekPreview or a.cfg.streamQuality == sqLowest: return
  let p = a.player
  if a.preview == nil or not p.loaded or not p.path.contains("://"): return
  a.ytCurrentLink.youtubeId

proc shownBoard(a: App): BoardJob =
  ## The storyboard the seek bar previews now, nil for none.
  let id = a.wantedBoard
  if id.len > 0 and a.board != nil and a.board.id == id: a.board else: nil

proc pollBoard(a: App) =
  let id = a.wantedBoard
  if id.len == 0:
    if a.board != nil:  # turned off meanwhile: no more downloading
      a.board.cancel()
      a.board = nil
    return
  if a.board == nil or a.board.id != id:
    let sb = a.ytBoards.getOrDefault(a.ytCurrentLink)
    if sb.sheets.len > 0:
      a.board.cancel()
      a.board = fetchBoard(id, sb)
  elif a.board.poll():
    a.dirtyUntil = max(a.dirtyUntil, now() + 0.1)

proc drawThumbnail(a: App, area: Rect, fb: IVec2) =
  ## The thumbnail, fit in the frame.
  if not a.thumbShown: return
  let img = a.thumb.image
  if a.thumbTexId != a.thumb.id:
    if a.thumbTex == 0: glGenTextures(1, a.thumbTex.addr)
    glBindTexture(GL_TEXTURE_2D, a.thumbTex)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, img.width.GLsizei, img.height.GLsizei, 0,
      GL_RGBA, GL_UNSIGNED_BYTE, img.data[0].addr)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
    glBindTexture(GL_TEXTURE_2D, 0)
    a.thumbTexId = a.thumb.id
  let sz = vec2(img.width.float32, img.height.float32)
  let size = (sz * min(area.w / sz.x, area.h / sz.y)).floor
  a.quad.draw(a.thumbTex, rectCorners((area.xy + (area.wh - size) / 2).floor, size), fb.vec2)

proc drawVideo(a: App, area: Rect, fb: IVec2) =
  ## GL pass beneath the UI: black frame area and the transformed video.
  let flags = if a.renderNow: MpvRenderUpdateFrame else: 0'u64
  if a.renderNow:
    a.renderNow = false
    a.framePending = false
  a.lfDue = false
  for f in a.lfTrash.mitems: f.target.free()
  a.lfTrash.setLen 0
  glEnable(GL_SCISSOR_TEST)
  glScissor(GLint(area.x), GLint(fb.y.float32 - area.y - area.h), GLsizei(area.w), GLsizei(area.h))
  glClearColor(0, 0, 0, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  glDisable(GL_SCISSOR_TEST)
  if a.holding and a.drawHeld(area, fb, flags): return
  if not a.player.hasVideo or a.player.stopped:
    # Still consume frames so mpv keeps its pipeline moving.
    if (flags and MpvRenderUpdateFrame) != 0:
      a.player.target.ensureSize(16, 16)
      a.player.render.render(a.player.target)
    a.drawThumbnail(area, fb)
    return
  if a.player.isSpherical:
    a.drawSphere(area, fb, flags)
    return
  let (center, size) = a.videoGeometry(area)
  if size.x < 1 or size.y < 1: return
  # The target is padded around the video to move centered subtitles.
  let pad = a.subPadding()
  let full = size + vec2(pad.l + pad.r, pad.t + pad.b)
  # Render at the on-screen size (mpv does the high-quality scaling); cap the
  # texture so extreme zoom doesn't allocate huge buffers.
  let cap = min(1'f32, 4096 / max(full.x, full.y))
  let (mx, my, (tw, th)) = a.applySubLayout(size, pad,
    (max(1, int(round(full.x * cap))), max(1, int(round(full.y * cap)))))
  let resized = tw != a.player.target.w or th != a.player.target.h
  a.player.target.ensureSize(tw, th)
  if resized or (flags and MpvRenderUpdateFrame) != 0:
    a.player.render.render(a.player.target)
  a.renderStandby()
  a.takeLoopFrames(tw, th)
  a.takeStepFrames(tw, th)
  a.renderOsdLayer(area)
  glEnable(GL_SCISSOR_TEST)
  glScissor(GLint(area.x), GLint(fb.y.float32 - area.y - area.h), GLsizei(area.w), GLsizei(area.h))
  # Size and shift the padded quad so the texels mpv filled with video land
  # exactly on the video's own rect (margins are whole texels, `full` isn't).
  let k = vec2(size.x / max(1, tw - mx[0] - mx[1]).float32, size.y / max(1, th - my[0] - my[1]).float32)
  let quadSize = vec2(tw.float32 * k.x, th.float32 * k.y)
  let sh = vec2((mx[1] - mx[0]).float32 * k.x / 2, (my[1] - my[0]).float32 * k.y / 2)
  let rad = a.xf.rotation * PI.float32 / 180
  let shift = vec2(sh.x * cos(rad) - sh.y * sin(rad), sh.x * sin(rad) + sh.y * cos(rad))
  let tex = if a.lfShow >= 0 and a.lfShow < a.lfFrames.len and
                a.lfFrames[a.lfShow].target.w == tw and a.lfFrames[a.lfShow].target.h == th:
              a.lfFrames[a.lfShow].target.tex
            elif a.sfShow >= 0 and a.sfShow < a.sfFrames.len and
                 a.sfFrames[a.sfShow].target.w == tw and a.sfFrames[a.sfShow].target.h == th:
              a.sfFrames[a.sfShow].target.tex
            else: a.player.target.tex
  a.videoCorners = transformedCorners(center + shift, quadSize, a.xf.rotation)
  a.quad.draw(tex, a.videoCorners, fb.vec2)
  a.drawOsdLayer(area, fb)
  glDisable(GL_SCISSOR_TEST)

proc drawPreview(a: App, fb: IVec2) =
  if a.preview == nil: return
  if a.previewFlag:
    a.previewFlag = false
    let flags = mpv_render_context_update(a.preview.render)
    if (flags and MpvRenderUpdateFrame) != 0 and a.preview.target.fbo != 0:
      a.preview.render.render(a.preview.target)
  if a.showPreview and a.preview.hasFrame:
    let q = a.px(a.previewQuad)
    a.quad.draw(a.preview.target.tex, rectCorners(q.xy, q.wh), fb.vec2)

# --- UI panels --------------------------------------------------------------

proc seekBarContext(a: App, pos: Vec2) =
  ## Opens the seek bar's context menu for the point pos on it.
  let r = a.seekRect
  let (x0, w, dur, span) = (r.x + 12, r.w - 24, a.player.duration, a.seekSpan)
  if dur <= 0 or not a.player.loaded: return
  a.ctxSeekT = min(clamp((pos.x - x0) / w, 0, 1) * span, dur)
  a.ctxBookmark = -1
  var best = max(a.cfg.snapDistance, 4)
  for i, b in a.fileBookmarks:
    let d = abs(x0 + w * (b.time / span) - pos.x)
    if d <= best:
      best = d
      a.ctxBookmark = i
  # Nearest chapter, bookmark or loop mark, for the loop marks.
  a.ctxOnMarker = a.ctxBookmark >= 0
  if a.ctxOnMarker: a.ctxMarkerT = a.fileBookmarks[a.ctxBookmark].time
  var times: seq[float]
  for c in a.player.chapters: times.add c.time
  if a.hasLoopA: times.add a.loopA
  if a.hasLoopB: times.add a.loopB
  for mt in times:
    let d = abs(x0 + w * (mt / span) - pos.x)
    if d < best or (d <= best and not a.ctxOnMarker):
      best = d
      a.ctxOnMarker = true
      a.ctxMarkerT = mt
  a.ctxMenu = cmSeekBar
  a.menus.openContext(pos)

const SkipMin = 0.25  ## a hole in a link's download worth showing, seconds

proc heldRanges(a: App): seq[(float, float)] =
  ## What's at hand of what's playing, in order and joined: mpv's cache and,
  ## for a link, what's been saved of it in the quality it plays in.
  let p = a.player
  var spans = p.buffered
  if p.path.isWebLink:
    for g in a.savedIn(p.path).segs: spans.add (g.start, g.stop)
    if a.recUrl == p.path: spans.add (a.rec.start, a.rec.stop)
  spans.sort(proc (x, y: (float, float)): int = cmp(x[0], y[0]))
  for s in spans:
    if result.len > 0 and s[0] <= result[^1][1] + SkipMin:
      result[^1][1] = max(result[^1][1], s[1])
    else: result.add s

proc seekBar(a: App, r: Rect) =
  let ui = a.ui
  let p = a.player
  a.seekRect = r
  ui.rect(r, colPanel)
  let x0 = r.x + 12
  let w = r.w - 24
  let cy = r.y + r.h / 2
  let dur = p.duration
  # A short file's delay takes up the bar past its end.
  let pad = if a.padLen > 0: a.padLen else: a.shortAudioPad
  let span = dur + pad
  a.seekSpan = span
  let active = a.seekDragging
  # The bar spans the window's width, so leaving it sideways leaves the window
  # too, and Windy keeps reporting the last pointer position from inside it.
  let mouseIn = ui.fakeMouse.x >= 0 or a.window.mouseInside
  let hov = (ui.hover(r) and mouseIn or active) and dur > 0 and p.loaded
  let th = if hov: 6'f32 else: 4'f32
  let endX = if span > 0: round(x0 + w * (dur / span)) else: x0 + w
  ui.rect(rect(x0, cy - th / 2, endX - x0, th), colTrack)
  let held = a.heldRanges
  if dur > 0 and p.loaded:
    # What has been read ahead, beneath the played part.
    for (bs, be) in held:
      let bx = x0 + w * clamp(bs / span, 0, 1)
      ui.rect(rect(bx, cy - th / 2, x0 + w * clamp(be / span, 0, 1) - bx, th), colBuffered)
  let cur = if active: a.seekDragT
            elif a.padLen > 0: dur + a.padElapsed
            elif pad > 0 and p.eofReached: dur
            else: p.timePos
  let frac = if dur > 0: clamp(cur / span, 0, 1) else: 0
  ui.rect(rect(x0, cy - th / 2, min(w * frac, endX - x0), th), colAccent)
  if dur > 0 and p.loaded and p.path.isWebLink:
    # What a link's download jumped over, up to as far as it got: stripes, in
    # the played part's color left of the knob.
    let reach = max(p.timePos, if held.len > 0: held[^1][1] else: 0)
    var at = 0.0
    for (bs, be) in held & @[(reach, reach)]:
      if bs - at >= SkipMin:
        let (lx, rx) = (x0 + w * clamp(at / span, 0, 1), x0 + w * clamp(bs / span, 0, 1))
        let zone = rect(lx, cy - th / 2, rx - lx, th)
        ui.rect(zone, colTrack)
        ui.stripes(zone, colTextDisabled)
        if x0 + w * frac > lx:
          ui.stripes(rect(lx, zone.y, min(x0 + w * frac, rx) - lx, th), colAccent)
      at = max(at, be)
  if pad > 0 and dur > 0 and p.loaded:
    # Past the "]" the audio has ended: stripes that fill as the delay runs.
    let zone = rect(endX, cy - th / 2, x0 + w - endX, th)
    ui.stripes(zone, colTextDisabled)
    if x0 + w * frac > endX:
      ui.stripes(rect(endX, zone.y, x0 + w * frac - endX, th), colAccent)
    ui.rect(rect(endX - 1, cy - 7, 2, 14), colText)
    ui.rect(rect(endX - 5, cy - 7, 4, 2), colText)
    ui.rect(rect(endX - 5, cy + 5, 4, 2), colText)

  # A-B loop: the looped span when active, and each mark set.
  if dur > 0 and p.loaded:
    if a.abLoop and a.loopReady:
      let (lx, rx) = (x0 + w * (a.loopA / span), x0 + w * (a.loopB / span))
      ui.rect(rect(lx, cy + th / 2 + 2, rx - lx, 2), colLoop)
    for (has, lt) in [(a.hasLoopA, a.loopA), (a.hasLoopB, a.loopB)]:
      if has:
        let lx = round(x0 + w * (lt / span))
        ui.rect(rect(lx - 1, cy - 9, 2, 18), colLoop)

  # Markers: chapters, bookmarks and loop marks, all snapped to. Loop marks
  # are drawn above, and name the hover label only while snapped to.
  var markers: seq[(float, string, ColorRGBX, bool)]
  for i, c in p.chapters:
    markers.add (c.time, (if c.title.len > 0: c.title else: &"Chapter {i + 1}"), colMarker, false)
  for i, b in a.fileBookmarks:
    markers.add (b.time, b.label(i), colBookmark, false)
  if a.hasLoopA: markers.add (a.loopA, "Loop A", colLoop, true)
  if a.hasLoopB: markers.add (a.loopB, "Loop B", colLoop, true)
  markers.sort(proc (x, y: (float, string, ColorRGBX, bool)): int = cmp(x[0], y[0]))

  # While the seek bar's context menu is open, the hover label and thumbnail
  # stay where it was opened.
  let pinned = a.menus.contextOpen and a.ctxMenu == cmSeekBar and dur > 0 and p.loaded
  let mx = if pinned: a.menus.contextAnchor.x else: ui.mouse.x
  var t = 0.0
  var snapped = -1
  if hov or pinned:
    t = min(clamp((mx - x0) / w, 0, 1) * span, dur)
    if a.cfg.snapWithShift == a.window.shift:
      var best = a.cfg.snapDistance
      for i, m in markers:
        let d = abs(x0 + w * (m[0] / span) - mx)
        if d <= best:
          best = d
          snapped = i
      if snapped >= 0: t = markers[snapped][0]

  for i, m in markers:
    if dur <= 0: break
    let mx = round(x0 + w * (m[0] / span))
    let hl = i == snapped
    if m[3] and not hl: continue
    ui.rect(rect(mx - (if hl: 1.5 else: 1), cy - (if hl: 8 else: 6), (if hl: 3 else: 2), (if hl: 16 else: 12)),
      if hl: colWhite else: m[2])

  if dur > 0 and p.loaded:
    ui.icon("knob16", vec2(x0 + w * frac, cy), colWhite)

  if hov and not active and ui.released(MouseRight):
    a.seekBarContext(ui.mouse)

  # Dragging / clicking
  if hov and ui.pressed() and not active:
    a.seekDragging = true
    ui.consumeClick()
    a.seekDragT = t
    a.lastDragSeekAt = 0
    p.stopped = false
  if a.seekDragging:
    if ui.down():
      a.seekDragT = t
      if now() - a.lastDragSeekAt > 0.06:
        a.lastDragSeekAt = now()
        a.seekTo(t, exact = false)
    else:
      a.seekDragging = false
      a.seekTo(t)

  # Hover label and thumbnail
  a.showPreview = false
  if hov or pinned:
    var label = fmtTime(t, a.cfg.showMillis, a.player.duration)
    if snapped >= 0: label.add "  " & markers[snapped][1]
    else:
      for i in countdown(markers.high, 0):
        if markers[i][0] <= t and not markers[i][3]:
          label.add "  " & markers[i][1]
          break
    let ts = ui.textSize(label, FontSmall)
    var boxW = max(ts.x + 16, 60)
    var imgH = 0'f32
    let wantPreview = a.cfg.seekPreview and p.hasRealVideo and a.preview != nil and
      fileExists(p.path)
    if wantPreview:
      let pw = 224'f32
      let asp = a.videoAspect
      imgH = round(pw / (if asp > 0: asp else: 16 / 9))
      boxW = max(boxW, pw + 8)
      a.preview.request(p.path, t)
      a.preview.target.ensureSize(int(pw * ui.scale), int(imgH * ui.scale))
    var haveFrame = wantPreview
    let board = if wantPreview: nil else: a.shownBoard
    if board != nil:
      # Once its sheet is in; the fetching goes left to right.
      let pw = 224'f32
      imgH = round(pw * board.board.height.float32 / board.board.width.float32)
      boxW = max(boxW, pw + 8)
      let (sheet, crop) = board.tile(t)
      haveFrame = sheet.len > 0
      if haveFrame:
        a.preview.showImage(sheet, crop)
        a.preview.target.ensureSize(int(pw * ui.scale), int(imgH * ui.scale))
    let boxH = ts.y + 8 + (if imgH > 0: imgH + 4 else: 0)
    var bx = clamp(mx - boxW / 2, 4, ui.size.x - boxW - 4)
    let by = r.y - boxH - 6
    if pinned:
      # Keep clear of the menu: beside it when they would overlap.
      let mr = a.menus.contextRect
      if mr.w > 0 and overlaps(rect(bx, by, boxW, boxH), mr):
        bx = if mr.x - boxW - 4 >= 4: mr.x - boxW - 4
             else: min(mr.x + mr.w + 4, ui.size.x - boxW - 4)
    ui.sk.pushLayer(PopupsLayer)
    ui.rect(rect(bx, by, boxW, boxH), colPopup)
    ui.border(rect(bx, by, boxW, boxH), colBorder)
    if imgH > 0:
      let q = rect(bx + (boxW - 224) / 2, by + 4, 224, imgH)
      if haveFrame and a.preview.hasFrame:
        a.previewQuad = q
        a.showPreview = true
      else:
        ui.rect(q, colVideoBg)
    ui.textIn(label, rect(bx, by + boxH - ts.y - 6, boxW, ts.y + 4), colText, FontSmall, h = CenterAlign)
    ui.sk.popLayer()

proc volumeSlider(a: App, r: Rect) =
  let ui = a.ui
  let v = a.player.volume
  let hov = ui.hover(r) or ui.activeId == "volume"
  let cy = r.y + r.h / 2
  ui.rect(rect(r.x, cy - 2, r.w, 4), colTrack)
  let frac = clamp(v / 100, 0, 1)
  ui.rect(rect(r.x, cy - 2, r.w * frac, 4),
    if a.player.muted: colTextDisabled elif v > 100: colMarker else: colAccent)
  ui.icon("knob16", vec2(r.x + r.w * frac, cy), if hov: colWhite else: colText)
  if ui.hover(r) and ui.pressed():
    ui.activeId = "volume"
    ui.consumeClick()
  if ui.activeId == "volume" and ui.down():
    a.player.setVolume(round(clamp((ui.mouse.x - r.x) / r.w, 0, 1) * 100))
  ui.tip(r, &"Volume {int(round(v))}%")

const
  CtlButtonW = 36'f32
  CtlStep = CtlButtonW + 2       ## a button and the gap after it
  CtlSepW = 10'f32               ## a divider between button groups
  CtlVolumeW = 100'f32           ## the volume slider
  CtlHintsMargin = 60'f32        ## room past the full controls the key hints want

proc controlsVolumeW(a: App): float32 =
  ## Width of the volume group at the right of the controls bar: the
  ## percentage, the mute button and the slider.
  let pct = &"{int(round(a.player.volume))}%"
  a.ui.textSize(pct, FontSmall).x + 6 + CtlButtonW + 6 + CtlVolumeW + 16

proc controlsTier(a: App, w: float32): int =
  ## How much a controls bar w wide drops as the window narrows: 0 keeps
  ## everything, 1 hides the status bar's key hints, 2 the Repeat and
  ## Equalizer buttons (and a link's quality one), 3 the rate buttons, 4
  ## previous/next.
  let quality = if a.player.path.isWebLink: CtlStep else: 0
  let need = [6 + 3 * CtlStep, CtlSepW + 2 * CtlStep, 2 * CtlStep, CtlSepW + 2 * CtlStep + quality]
  var full = a.controlsVolumeW + 10
  for n in need: full += n
  if w >= full + CtlHintsMargin: return 0
  result = 1
  # Drop the groups from the right of the list until the rest fits.
  for i in countdown(need.high, 1):
    if w >= full: return
    full -= need[i]
    inc result

proc controls(a: App, r: Rect) =
  ## The playback buttons and the volume. A narrow bar drops buttons in
  ## the order controlsTier gives; past that, the volume clips at the right.
  let ui = a.ui
  let p = a.player
  ui.rect(r, colPanel)
  ui.sk.pushClipRect(r)
  let tier = a.controlsTier(r.w)
  let bw = CtlButtonW
  let bh = r.h - 8
  var x = r.x + 6
  let y = r.y + 4
  template btn(id, iconName, tipText: string, enabled: bool, toggled: bool,
               toggledCol: ColorRGBX, body: untyped) =
    if ui.iconButton(id, rect(x, y, bw, bh), iconName & "20", tipText, enabled, toggled, toggledCol):
      body
    x += CtlStep
  template btn(id, iconName, tipText: string, enabled: bool, toggled: bool, body: untyped) =
    btn(id, iconName, tipText, enabled, toggled, colAccent, body)
  template divider() =
    ui.rect(rect(x + 4, y + 6, 1, bh - 12), colBorder)
    x += CtlSepW
  btn("play", "play", "Play", p.loaded or a.cfg.recentFiles.len > 0, p.playing or a.padRunning): a.play()
  btn("pause", "pause", "Pause", p.loaded, p.loaded and p.paused and not p.stopped and not a.padRunning): a.pause()
  btn("stop", "stop", "Stop", p.loaded, p.stopped): a.stop()
  if tier < 4:
    divider()
    let navOk = p.loaded and not a.playlistLocked
    btn("prev", "prev", "Previous", navOk, false): a.navigate(-1)
    if tier < 3:
      btn("slower", "slower", "Slower playback", p.loaded, false): a.changeRate(-1)
      btn("faster", "faster", "Faster playback", p.loaded, false): a.changeRate(1)
    btn("next", "next", "Next", navOk, false): a.navigate(1)
  if tier < 2:
    divider()
    # Click toggles Repeat > Forever; right-click opens the Repeat menu.
    let loopR = rect(x, y, bw, bh)
    btn("loop", "loop", "Repeat (right-click for options)", true,
        a.cfg.repeatForever or (a.abLoop and a.loopReady)):
      a.cfg.repeatForever = not a.cfg.repeatForever
      a.applyLoop()
    if ui.hover(loopR) and ui.released(MouseRight):
      a.ctxMenu = cmRepeat
      a.menus.openContext(ui.mouse)
    # Lit while its window is open, blue while it's on.
    let eqOn = a.equalizer.on
    btn("equalizer", "equalizer", "Equalizer", true, eqOn or a.eqWin != nil and a.eqWin.visible,
        if eqOn: colEqualizer else: colAccent):
      a.toggleEqualizer()
    # A link's video and audio quality, picked from what it offers.
    if p.path.isWebLink:
      let gearR = rect(x, y, bw, bh)
      a.qualityRect = gearR
      let shown = a.menus.contextOpen and a.ctxMenu == cmQuality
      btn("quality", "gear", "Quality", p.loaded, shown):
        a.ctxMenu = cmQuality
        a.menus.openContext(gearR.xy, sticky = true, keep = gearR, above = true)

  # Volume on the right, never over the buttons.
  let vx = max(r.x + r.w - a.controlsVolumeW, x + 4)
  let sr = rect(vx + a.controlsVolumeW - CtlVolumeW - 16, r.y, CtlVolumeW, r.h)
  a.volumeSlider(sr)
  let vb = rect(sr.x - bw - 6, y, bw, bh)
  let volIcon = if p.muted: "nosound20" else: "volume20"
  if ui.iconButton("mute", vb, volIcon, if p.muted: "Unmute" else: "Mute"):
    a.setMute(not p.muted)
  let pct = &"{int(round(p.volume))}%"
  let pw = ui.textSize(pct, FontSmall).x
  ui.textIn(pct, rect(vb.x - pw - 6, r.y, pw + 2, r.h), colTextDim, FontSmall)
  ui.sk.popClipRect()

type KeyHint = tuple[key, label: string]

proc modifierHints(a: App): seq[seq[KeyHint]] =
  ## Shortcuts reachable with the modifiers currently held, in groups: the
  ## keys set in Options > Player > Keys, one group per command group, then
  ## the mouse gestures.
  let w = a.window
  var (c, s, al) = (w.ctrl, w.shift, w.alt)
  if a.fakeMods.len > 0:
    (c, s, al) = ("ctrl" in a.fakeMods, "shift" in a.fakeMods, "alt" in a.fakeMods)
  var mods: set[KeyMod]
  if c: mods.incl kmCtrl
  if s: mods.incl kmShift
  if al: mods.incl kmAlt
  if mods == {}: return
  let rot = &"{a.cfg.rotateStep:g}°"
  # View toggles and pan/rotate/scale only show with "Show all shortcuts".
  let all = a.cfg.showAllShortcuts
  let viewToggles = {kaCompact, kaSeekBar, kaControls, kaStatus, kaPlaylist, kaRunLog, kaShowOsd}
  # Ctrl+C copies the run log's selected text while there is some (handleKeys).
  let logSel = a.cfg.showRunLog and a.rlSelection.len > 0
  for g in KeyGroup:
    if g == kgPan and not all: continue
    var hints: seq[KeyHint]
    var done: set[KeyAction]
    # Clusters still on their default keys share one hint.
    for (acts, key, label) in [(@SubAlignActions, "Num1-9", "Align Subtitles"),
                               (@SubMoveActions, "Arrows", "Move Subtitles")]:
      if Actions[acts[0]].group == g and acts.allIt(a.cfg.isDefault(it)) and
         a.cfg.combos(acts[0]).len > 0 and a.cfg.combos(acts[0])[0].mods == mods:
        hints.add (key, label)
        for x in acts: done.incl x
    for act in KeyAction:
      if Actions[act].group != g or act in done: continue
      if act in viewToggles and not all: continue
      let ks = a.cfg.combos(act).filterIt(it.mods == mods)
      if ks.len == 0: continue
      let label =
        case act
        of kaRotateCw: "Rotate " & rot & " CW"
        of kaRotateCcw: "Rotate " & rot & " CCW"
        of kaCopyClipboard:
          if logSel and mods == {kmCtrl} and ks.anyIt(it.key == KeyC): "Copy Selected Text"
          else: Actions[act].hint
        else: Actions[act].hint
      hints.add (ks.mapIt(shortKeyName(it.key)).join("/"), label)
    if hints.len > 0: result.add hints
  if logSel and mods == {kmCtrl} and not result.anyIt(it.anyIt(it[1] == "Copy Selected Text")):
    result.add @[("C", "Copy Selected Text")]
  # The playlist's own keys while it has the focus (playlistKeys).
  if a.plFocused and a.cfg.showPlaylist and not a.playlistLocked:
    if mods == {kmCtrl}: result.add @[("A", "Select All Entries"), ("D", "Duplicate Entries")]
    elif mods == {kmCtrl, kmShift}:
      result.add @[("Up/Down", "Move Entries"), ("Home/End", "Move Entries To Top/Bottom")]
  let plShown = a.cfg.showPlaylist and not a.playlistLocked and a.playlist.len > 0
  var mouse: seq[KeyHint]
  if mods == {kmCtrl}:
    if a.player.isSpherical:
      # 360° view: the wheel changes the field of view; Ctrl swaps what a drag does.
      mouse = @[("Wheel", "Field Of View"),
        ("Drag", if a.cfg.sphereDragMovesWindow: "Look Around" else: "Move Window")]
    else: mouse = @[("Wheel", "Zoom At Cursor"), ("Drag", "Pan Zoomed Video")]
    if plShown: mouse.add ("LMB", "Toggle Playlist Entry")
  elif mods == {kmAlt}: mouse = @[("MDrag", "Rotate Frame"), ("MMB", "Reset Rotation")]
  elif mods == {kmAlt, kmShift}: mouse = @[("MDrag", "Rotate In " & rot & " Steps")]
  elif mods == {kmCtrl, kmAlt}: mouse = @[("MDrag", "Rotate Around Cursor")]
  elif mods == {kmCtrl, kmAlt, kmShift}:
    mouse = @[("MDrag", "Rotate Around Cursor In " & rot & " Steps")]
  elif mods == {kmShift}:
    mouse = @[("Drag", if a.cfg.snapWithShift: "Seek Snapping To Markers" else: "Seek Without Snapping")]
    if a.cfg.showRunLog and a.runLog.len > 0: mouse.add ("LMB", "Extend Log Selection")
    if plShown: mouse.add ("LMB", "Select Playlist Range")
  # Mouse shortcuts lead the bar, before any key group.
  if mouse.len > 0: result.insert(mouse, 0)

proc keyHintBar(a: App, r: Rect, groups: seq[seq[KeyHint]]) =
  ## Blender-style row of [key] label pairs; groups split by a divider.
  ## Hints that don't fit scroll sideways with the mouse wheel, with an
  ## arrow at each end that has more hidden past it.
  let ui = a.ui
  let capH = r.h - 8
  proc mouseIcon(key: string): string =
    ## Mouse inputs (LMB, RMB, MMB, Wheel, Drag) draw as an icon, not a key cap.
    for (k, spec) in mouseIcons:
      if k == key: return spec[0]
  proc capW(key: string): float32 =
    let icon = mouseIcon(key)
    if icon.len > 0: ui.sk.getImageSize(icon).x
    else: max(capH, ui.textSize(key, FontSmall).x + 10)
  proc pairW(h: KeyHint): float32 = capW(h.key) + 5 + ui.textSize(h.label, FontSmall).x
  const PairGap = 14'f32
  const GroupGap = 25'f32
  const Pad = 10'f32
  const ArrowW = 18'f32
  const WheelStep = 60'f32
  # Lay out first: x per pair from the start of the row, plus the dividers.
  var pos: seq[seq[float32]]
  var dividers: seq[float32]
  var x = 0'f32
  for gi, g in groups:
    if gi > 0:
      dividers.add x + GroupGap / 2
      x += GroupGap
    pos.add @[]
    for i, h in g:
      if i > 0: x += PairGap
      pos[^1].add x
      x += pairW(h)
  let view = rect(r.x + Pad, r.y, r.w - 2 * Pad, r.h)
  # Scrolled to the end, the left arrow takes room from the hints.
  let maxScroll = if x > view.w: x - view.w + ArrowW else: 0'f32
  # Other modifiers show other hints, which start from the left again.
  let key = $groups
  if key != a.hintScrollKey:
    a.hintScrollKey = key
    a.hintScroll = 0
  if ui.hover(r) and ui.scroll() != 0:
    a.hintScroll += ui.wheelNotches * WheelStep
    ui.scrollConsumed = true
  a.hintScroll = clamp(a.hintScroll, 0, maxScroll)
  let (moreLeft, moreRight) = (a.hintScroll > 0, a.hintScroll < maxScroll)
  let left = view.x - a.hintScroll + (if moreLeft: ArrowW else: 0)
  ui.rect(r, colPanel)
  ui.rect(rect(r.x, r.y, r.w, 1), colBorder)
  var clip = view
  if moreLeft: clip.x += ArrowW; clip.w -= ArrowW
  if moreRight: clip.w -= ArrowW
  ui.sk.pushClipRect(clip)
  for dx in dividers:
    ui.rect(rect(left + dx, r.y + 6, 1, r.h - 12), colBorder)
  for gi, g in groups:
    for i, h in g:
      let cap = rect(left + pos[gi][i], r.y + (r.h - capH) / 2, capW(h.key), capH)
      if cap.x > clip.x + clip.w or cap.x + pairW(h) < clip.x: continue
      let icon = mouseIcon(h.key)
      if icon.len > 0:
        ui.icon(icon, cap.xy + cap.wh / 2, colText)
      else:
        ui.rect(cap, colPanelRaised)
        ui.border(cap, colBorder)
        ui.textIn(h.key, cap, colText, FontSmall, h = CenterAlign)
      let lw = ui.textSize(h.label, FontSmall).x
      ui.textIn(h.label, rect(cap.x + cap.w + 5, r.y, lw + 2, r.h), colTextDim, FontSmall)
  ui.sk.popClipRect()
  # More hints past an end: an arrow there pointing that way.
  if moreLeft:
    ui.rect(rect(clip.x - 1, r.y + 6, 1, r.h - 12), colBorder)
    ui.icon("arrowleft16", vec2(r.x + (Pad + ArrowW) / 2, r.y + r.h / 2), colAccent)
  if moreRight:
    ui.rect(rect(clip.x + clip.w, r.y + 6, 1, r.h - 12), colBorder)
    ui.icon("arrow16", vec2(r.x + r.w - (Pad + ArrowW) / 2, r.y + r.h / 2), colAccent)

proc status(a: App, r: Rect) =
  let ui = a.ui
  let p = a.player
  # A window too narrow for all the controls drops the key hints first.
  if (a.window.focused or a.fakeMods.len > 0) and a.overlay == ovNone and not a.menus.isOpen and
     a.controlsTier(r.w) == 0:
    let hints = a.modifierHints()
    if hints.len > 0:
      a.keyHintBar(r, hints)
      if ui.hover(r) and ui.released(MouseRight):
        a.ctxMenu = cmStatus
        a.menus.openContext(ui.mouse)
      return
  ui.rect(r, colPanel)
  ui.rect(rect(r.x, r.y, r.w, 1), colBorder)
  let fileIcon =
    if not p.loaded: "nofile16"
    elif p.hasRealVideo: "film16"
    else: "music16"
  ui.icon(fileIcon, vec2(r.x + 16, r.y + r.h / 2), if p.loaded: colAccent else: colTextDim)
  let yt = if a.ytStatus.len > 0: a.ytStatus
           elif a.mkvStatus.len > 0: a.mkvStatus
           else: a.upStatus
  let state =
    if yt.len > 0: yt & "..."
    elif p.opening: "Opening..."
    elif not p.loaded: "Stopped"
    elif p.stopped: "Stopped"
    elif p.paused and not a.padRunning: "Paused"
    elif p.buffering: "Buffering"
    else: "Playing"
  var sw = ui.textSize(state, FontSmall).x
  ui.textIn(state, rect(r.x + 30, r.y, sw + 4, r.h), colText, FontSmall)
  if yt.len == 0 and not p.opening and p.loaded and not p.stopped and p.cacheAhead >= 0:
    # Seconds read ahead of the position, dim beside the state.
    let ahead = &"{p.cacheAhead:.1f}s"
    let ar = rect(r.x + 30 + sw + 8, r.y, ui.textSize(ahead, FontSmall).x + 4, r.h)
    ui.textIn(ahead, ar, colTextDim, FontSmall)
    ui.tip(ar, "Buffered ahead")
    sw += ar.w + 4
  if a.ytStyling.loading and a.ytStyling.link == p.path:
    let note = "Loading styled subtitles"
    let nr = rect(r.x + 30 + sw + 8, r.y, ui.textSize(note, FontSmall).x + 4, r.h)
    ui.textIn(note, nr, colTextDim, FontSmall)
    ui.tip(nr, "The plain subtitles are shown until they're in")
    sw += nr.w + 4
  if a.saveJob.running:
    let pc = a.saveJob.progress
    let (done, total) = a.saveJob.bytes
    let (unit, scale) = if total >= 1 shl 30: ("GB", float(1 shl 30)) else: ("MB", float(1 shl 20))
    let (step, steps) = a.saveJob.stage
    var saving = if steps > 0: &"Saving ({step}/{steps})" else: "Saving"
    saving.add(if pc >= 0: &" {pc:.2f}%" else: "...")
    if total > 0: saving.add &" ({done.float / scale:.1f} of {total.float / scale:.1f} {unit})"
    let sr = rect(r.x + 30 + sw + 8, r.y, ui.textSize(saving, FontSmall).x + 4, r.h)
    ui.textIn(saving, sr, colTextDim, FontSmall)
    ui.tip(sr, "Saving to " & a.saveJob.dest)
    sw += sr.w + 4
  let err = if a.ytError.len > 0: a.ytError
            elif yt.len > 0 or a.overlay == ovYtdlp or p.opening: ""
            else: p.loadError
  if err.len > 0:
    ui.textIn("Error: " & err, rect(r.x + 30 + max(sw + 16, 70), r.y, r.w / 2, r.h),
      colMarker, FontSmall)

  # Right side: audio icon, time.
  let audioIcon =
    if not p.loaded or p.audioChannels == 0 or p.muted or p.selectedTrack("audio") == 0: "nosound16"
    elif p.audioChannels == 1: "mono16"
    else: "stereo16"
  let iw = ui.sk.getImageSize(audioIcon).x
  let ix = r.x + r.w - iw / 2 - 12
  ui.icon(audioIcon, vec2(ix, r.y + r.h / 2), colText)
  let audioTip =
    case audioIcon
    of "stereo16": &"{p.audioChannels} channels"
    of "mono16": "Mono"
    else: "No sound"
  ui.tip(rect(ix - iw / 2, r.y, iw, r.h), audioTip)
  let ms = a.cfg.showMillis
  let pos = if a.seekDragging: a.seekDragT else: p.timePos
  var timeText =
    (if a.cfg.showRemaining: "-" & fmtTime(max(0.0, p.duration - pos), ms, p.clockDur)
     else: fmtTime(pos, ms, p.clockDur)) &
    " / " & fmtTime(p.duration, ms, p.clockDur)
  if p.loaded and abs(a.baseSpeed - 1) > 0.001:
    timeText = &"{a.baseSpeed:g}x   " & timeText
  let tw = ui.textSize(timeText, FontSmall).x
  let timeRect = rect(ix - iw / 2 - tw - 14, r.y, tw + 4, r.h)
  ui.textIn(timeText, timeRect, colText, FontSmall)
  if cpuWanted:
    # Rendering on the CPU (gpumem): said beside the time.
    let cw = ui.textSize("CPU", FontSmall).x
    let cr = rect(timeRect.x - cw - 14, r.y, cw + 4, r.h)
    ui.textIn("CPU", cr, colTextDim, FontSmall)
    ui.tip(cr, if not softwareGl: "Decoding on the CPU (no software renderer installed)"
               elif a.rdForNow: "Rendering on the CPU until the GPU's memory frees up"
               else: "Rendering on the CPU (Options > System > Rendering)")
  if ui.hover(timeRect) and ui.released():
    a.cfg.showRemaining = not a.cfg.showRemaining
    a.cfg.save()
  if ui.hover(timeRect) and ui.released(MouseRight):
    a.ctxMenu = cmTime
    a.menus.openContext(ui.mouse)
  elif ui.hover(r) and ui.released(MouseRight):
    a.ctxMenu = cmStatus
    a.menus.openContext(ui.mouse)

proc fmtSize(bytes: int64): string =
  if bytes < 1000: return &"{bytes} B"
  var v = bytes.float / 1024
  var unit = 0
  while v >= 1000 and unit < 3:
    v /= 1024
    inc unit
  &"{v:.1f} " & ["KB", "MB", "GB", "TB"][unit]

proc playlistCells(a: App, hdr: Rect): seq[(Rect, PlaylistField)] =
  ## The shown columns, left to right. Each is as wide as its widest text,
  ## except the text columns, which share what the others leave (with none
  ## shown, the last column takes it).
  let ui = a.ui
  let cols = a.cfg.playlistColumns
  a.plDurSeconds = pfDuration in cols and
    not a.playlist.anyIt(it in a.mediaInfo and a.mediaInfo[it].duration > 60)
  var widths = newSeq[float32](cols.len)
  var used = 0'f32
  var shared = 0
  for i, f in cols:
    let (label, sample) = PlaylistFields[f]
    if sample.len == 0: inc shared
    else:
      let longMillis = f == pfDuration and a.cfg.playlistShowMillis and not a.plDurSeconds
      let text = if longMillis: sample & ".000" else: sample
      widths[i] = max(ui.textSize(label, FontSmall).x, ui.textSize(text, FontSmall).x) + 18
      if i == 0: widths[i] += PlaylistIconW
      used += widths[i]
  if shared == 0: widths[^1] += max(0'f32, hdr.w - used)
  var x = hdr.x
  for i, f in cols:
    let w = if PlaylistFields[f].sample.len > 0: widths[i]
            else: max(PlaylistMinTextW, (hdr.w - used) / shared.float32)
    result.add (rect(x, hdr.y, w, hdr.h), f)
    x += w

proc cellText(a: App, path: string, field: PlaylistField): string =
  let m = a.mediaInfo.getOrDefault(path)
  case field
  of pfName: a.rowName(path)
  of pfFilename: path.extractFilename
  of pfDuration:
    let millis = a.cfg.playlistShowMillis
    if m.duration <= 0: ""
    elif a.plDurSeconds:
      let ms = int(m.duration * 1000)
      if millis: &"{ms div 1000}.{ms mod 1000:03}" else: $(ms div 1000)
    else: fmtTime(m.duration, millis, m.duration)
  of pfSize:
    let b = a.fileSize(path)
    if b >= 0: fmtSize(b) else: ""
  of pfDimensions:
    if m.width > 0: &"{m.width}×{m.height}" else: ""
  of pfAudioBitrate:
    if m.audioBitrate > 0: fmtBitrate(m.audioBitrate) else: ""
  of pfTrack:
    if m.track > 0: $m.track else: ""
  of pfArtist: m.artist
  of pfYear:
    if m.year > 0: $m.year else: ""
  of pfAlbum: m.album

proc playlistCell(a: App, s: string, cell: Rect, field: PlaylistField, first: bool,
                  color: ColorRGBX, font: string) =
  ## A column's text, in the header or a row: text columns start at its left
  ## edge, past the playing icon in the first column; the others end at its right.
  let ui = a.ui
  if PlaylistFields[field].sample.len == 0:
    let pad = if first: PlaylistIconW else: 9'f32
    let w = cell.w - pad - 4
    ui.textIn(ui.ellipsize(s, w, font), rect(cell.x + pad, cell.y, w, cell.h), color, font)
  else:
    ui.textIn(s, rect(cell.x, cell.y, cell.w - 9, cell.h), color, font, h = RightAlign)

proc playlistBar(a: App, gutter: Rect): float32 =
  ## Scroll bar beside the rows: drag the thumb, or click the track to jump
  ## there. It widens and lights up under the pointer. The track marks the
  ## selected rows and the playing one, inside the thumb while they're in view.
  ## Returns the thumb's middle.
  let ui = a.ui
  let track = rect(gutter.x, gutter.y + 3, gutter.w, max(0'f32, gutter.h - 6))
  let content = a.playlist.len.float32 * PlaylistRowH
  let maxScroll = max(1'f32, content - gutter.h)
  let thumbH = max(28'f32, track.h * gutter.h / content).min(track.h)
  let span = track.h - thumbH
  proc thumbY(scroll: float32): float32 = track.y + span * scroll / maxScroll
  if ui.hover(gutter) and ui.pressed():
    ui.consumeClick()
    if span > 0 and not ui.hover(rect(track.x, thumbY(a.plScroll), track.w, thumbH)):
      # Center the thumb on the pointer, then keep dragging from there.
      a.plScroll = clamp((ui.mouse.y - track.y - thumbH / 2) / span * maxScroll, 0, maxScroll)
    ui.activeId = "plscroll"
    a.plThumbFrom = (ui.mouse.y, a.plScroll)
  let dragging = ui.activeId == "plscroll"
  if dragging and span > 0:
    let (y0, s0) = a.plThumbFrom
    a.plScroll = clamp(s0 + (ui.mouse.y - y0) / span * maxScroll, 0, maxScroll)

  # The easing runs on the redraws that the pointer's movement already schedules.
  let t = now()
  let lift = if dragging or ui.hover(gutter): 1'f32
             elif ui.hover(a.plListRect): 0.35'f32 else: 0'f32
  a.plBarLift += (lift - a.plBarLift) * float32(1 - exp(-(t - a.plBarAt) * 16))
  a.plBarAt = t
  let w = PlaylistBarThin + (PlaylistBarWide - PlaylistBarThin) * a.plBarLift
  let x = gutter.x + (gutter.w - w) / 2
  proc rowY(i: int): float32 =
    floor(track.y + track.h * (i.float32 + 0.5) / a.playlist.len.float32)

  let groove = blend(colPanelRaised, colTrack, a.plBarLift)
  ui.pill(rect(x, track.y, w, track.h), groove, groove)
  var above = float32.low  # rows sharing a pixel row need just one mark
  for i in a.plSelection:
    let y = rowY(i)
    if y != above: ui.rect(rect(x, y - 1, w, 2), colTextDim)
    above = y
  let thumb = rect(x, thumbY(a.plScroll), w, thumbH)
  if dragging:
    ui.pill(rect(x - 3, thumb.y - 3, w + 6, thumbH + 6), colAccentDim, colAccentDim, feather = 5)
  ui.pill(thumb, blend(colTextDisabled, colAccentHover, a.plBarLift),
    blend(colTextDisabled, colAccent, a.plBarLift))
  if a.plIndex in 0 ..< a.playlist.len:
    ui.rect(rect(x - 1, rowY(a.plIndex) - 1, w + 2, 2), blend(colAccent, colWhite, a.plBarLift))
  thumb.y + thumbH / 2

proc playlistPanel(a: App, r: Rect) =
  let ui = a.ui
  ui.rect(r, colPanel)
  ui.rect(rect(r.x, r.y, 1, r.h), colBorder)
  # Dragging the left edge resizes the panel; the video frame takes the rest.
  let grip = rect(r.x, r.y, PlaylistGripW, r.h)
  if ui.hover(grip) and ui.pressed():
    ui.activeId = "plresize"
    a.plResizeFrom = (ui.mouse.x, r.w)
    ui.consumeClick()
  if ui.activeId == "plresize":
    let (x0, w0) = a.plResizeFrom
    a.cfg.playlistWidth = clamp(w0 + x0 - ui.mouse.x, PlaylistMinWidth,
      max(PlaylistMinWidth, ui.size.x - MinWindow.x.float32 / 2))
  let header = rect(r.x, r.y, r.w, 30)
  ui.icon("playlist16", vec2(r.x + 18, header.y + 15), colAccent)
  ui.textIn(&"Playlist ({a.playlist.len})", rect(r.x + 32, header.y, r.w - 70, 30), colText)
  if ui.iconButton("pl-close", rect(r.x + r.w - 30, header.y + 3, 24, 24), "close16", a.closeTip(kaPlaylist)):
    a.setPlaylistShown(false)
  ui.rect(rect(r.x + 1, header.y + 29, r.w - 1, 1), colBorder)
  if a.playlistLocked:
    a.plListRect = Rect()
    ui.textIn("Locked while synchronized", rect(r.x, header.y + 30, r.w, r.h - 30),
      colTextDim, FontSmall, h = CenterAlign)
    return

  # Column headers: a click sorts by the column, a drag moves it.
  let colHdr = rect(r.x + 1, r.y + 30, r.w - 1, PlaylistHeaderH)
  let list = rect(r.x + 1, colHdr.y + colHdr.h, r.w - 1, r.h - 30 - colHdr.h)
  let rowH = PlaylistRowH
  let maxScroll = max(0'f32, a.playlist.len.float32 * rowH - list.h)
  # Only a list that overflows gives up its right edge to the scroll bar.
  let barW = if maxScroll > 0: PlaylistBarW else: 0'f32
  let rows = rect(list.x, list.y, list.w - barW, list.h)
  let cells = a.playlistCells(rect(colHdr.x, colHdr.y, colHdr.w - barW, colHdr.h))
  let dragging = ui.activeId == "plcolumn"
  ui.rect(colHdr, colPanelRaised)
  ui.sk.pushClipRect(colHdr)
  for i, (cr, f) in cells:
    let label = PlaylistFields[f].label
    if dragging:
      if i == a.plColumnFrom.index: ui.rect(cr, colPressed)
    elif ui.hover(cr) and not ui.hover(grip):
      ui.rect(cr, colHover)
      ui.tip(cr, &"Sort by {label}. Drag to move the column")
      if ui.pressed():
        ui.consumeClick()
        ui.activeId = "plcolumn"
        a.plColumnFrom = (i, ui.mouse.x, false)
    if i > 0: ui.rect(rect(cr.x, cr.y + 4, 1, cr.h - 8), colBorder)
    a.playlistCell(label, cr, f, i == 0, colTextDim, FontSmall)
  if ui.activeId == "plcolumn":
    if abs(ui.mouse.x - a.plColumnFrom.x) >= PlaylistColumnDrag: a.plColumnFrom.moved = true
    # The gap the column would drop into: past every column whose middle it passed.
    let to = cells.countIt(ui.mouse.x > it[0].x + it[0].w / 2)
    if a.plColumnFrom.moved:
      let gap = if to < cells.len: cells[to][0].x else: cells[^1][0].x + cells[^1][0].w
      ui.rect(rect(clamp(gap - 1, colHdr.x, colHdr.x + colHdr.w - 2), colHdr.y, 2, colHdr.h), colAccent)
    if ui.released():
      let from0 = a.plColumnFrom.index
      if not a.plColumnFrom.moved: a.sortPlaylist(cells[from0][1])
      else:
        a.cfg.playlistColumns.delete(from0)
        a.cfg.playlistColumns.insert(cells[from0][1], if to > from0: to - 1 else: to)
  ui.sk.popClipRect()
  ui.rect(rect(colHdr.x, colHdr.y + colHdr.h - 1, colHdr.w, 1), colBorder)

  a.plListRect = list
  if ui.hover(colHdr) and ui.released(MouseRight):
    for (cr, f) in cells:
      if ui.hover(cr): a.ctxColumn = f
    a.ctxMenu = cmPlaylistColumns
    a.menus.openContext(ui.mouse)
  elif ui.hover(r) and ui.released(MouseRight):
    # Right-click selects the row under the pointer (none below the last one).
    # A row already in the selection keeps the selection for the menu.
    let i = int((ui.mouse.y - list.y + a.plScroll) / rowH)
    if ui.mouse.y < list.y or i >= a.playlist.len: a.selectOnly(-1)
    elif not a.plIsSelected(i): a.selectOnly(i)
    a.ctxMenu = cmPlaylist
    a.menus.openContext(ui.mouse)
  if a.playlist.len == 0:
    ui.textIn("Empty. Use File > Open File...", list, colTextDim, FontSmall, h = CenterAlign)
    return
  if ui.activeId == "plscroll":  # the drag wins over playback moving on
    a.plReveal = false
    a.plFollow = false
  if a.plReveal or a.plFollow:
    if a.plSelected >= 0:
      let y = a.plSelected.float32 * rowH
      a.plScroll = clamp(a.plScroll, y + rowH - list.h, y)
      # On the last whole row: page on, so that what plays next stays in view.
      if a.plFollow and y + rowH * 2 > a.plScroll + list.h:
        a.plScroll = clamp(a.plScroll + list.h * PlaylistFollowPage, y + rowH - list.h, y)
    a.plReveal = false
    a.plFollow = false
  if ui.hover(list) and ui.scroll() != 0:
    a.plScroll += ui.wheelNotches * rowH * PlaylistWheelRows
    ui.scrollConsumed = true
  a.plScroll = clamp(a.plScroll, 0, maxScroll)
  let thumbMid = if barW > 0: a.playlistBar(rect(rows.x + rows.w, list.y, barW, list.h)) else: 0'f32
  ui.sk.pushClipRect(rows)
  let first = int(a.plScroll / rowH)
  let last = min(a.playlist.len, first + int(list.h / rowH) + 2) - 1
  for i in first .. last:
    let row = rect(rows.x, rows.y + i.float32 * rowH - a.plScroll, rows.w, rowH)
    let hov = ui.hover(row) and ui.hover(list) and not ui.hover(grip)
    if a.plIsSelected(i): ui.rect(row, colPressed)
    elif hov: ui.rect(row, colHover)
    let current = i == a.plIndex
    if current: ui.icon("play16", vec2(row.x + 14, row.y + rowH / 2), colAccent)
    let path = a.playlist[i]
    for j, (cr, f) in cells:
      # Name and Filename read like the row's title, the rest as its details.
      let title = f in {pfName, pfFilename}
      a.playlistCell(a.cellText(path, f), rect(cr.x, row.y, cr.w, rowH), f, j == 0,
        if current: colAccent elif title: colText else: colTextDim,
        if title: FontMain else: FontSmall)
    if hov and ui.pressed():
      # Ctrl+click adds or drops a row, Shift+click selects up to it.
      let w = a.window
      let anchor = a.plSelected
      if w.ctrl:
        var sel = a.plSelection
        let at = sel.find(i)
        if at >= 0: sel.delete(at)
        else: sel.insert(i, sel.lowerBound(i))
        a.plSelected = if at < 0: i elif sel.len > 0: sel[min(at, sel.high)] else: -1
        a.plMarks = sel
      elif w.shiftDown and anchor in 0 ..< a.playlist.len:
        a.plMarks = toSeq(min(anchor, i) .. max(anchor, i))
      else: a.selectOnly(i)
      ui.consumeClick()
    if hov and a.window.buttonPressed[DoubleClick]:
      a.playIndex(i)
  ui.sk.popClipRect()
  if ui.activeId == "plscroll":
    # Which rows the thumb has reached, beside it.
    let s = &"{first + 1}-{min(a.playlist.len, first + int(list.h / rowH))} of {a.playlist.len}"
    let sz = ui.textSize(s, FontSmall) + vec2(14, 8)
    let bubble = rect(max(r.x + 4, rows.x + rows.w - sz.x - 4),
      clamp(thumbMid - sz.y / 2, list.y + 2, max(list.y + 2, list.y + list.h - sz.y - 2)), sz.x, sz.y)
    ui.rect(bubble, colPopup)
    ui.border(bubble, colBorder)
    ui.textIn(s, bubble, colText, FontSmall, h = CenterAlign)
  a.probeNext(first .. last)
  a.infoNext(first .. last)

proc runLogPanel(a: App, r: Rect) =
  ## The Run menu's command lines and what they printed, newest at the bottom.
  let ui = a.ui
  ui.rect(r, colPanel)
  ui.rect(rect(r.x, r.y + r.h - 1, r.w, 1), colBorder)
  # Dragging the bottom edge resizes the panel; the video frame takes the rest.
  let grip = rect(r.x, r.y + r.h - RunLogGripH, r.w, RunLogGripH)
  if ui.hover(grip) and ui.pressed():
    ui.activeId = "rlresize"
    a.rlResizeFrom = (ui.mouse.y, r.h)
    ui.consumeClick()
  if ui.activeId == "rlresize":
    let (y0, h0) = a.rlResizeFrom
    let below = (if a.fullscreen: 0'f32 else: a.menuBarHeight + a.bottomHeight) +
      MinWindow.y.float32 / 2
    a.cfg.runLogHeight = clamp(h0 + ui.mouse.y - y0, RunLogMinHeight,
      max(RunLogMinHeight, ui.size.y - below))

  # One row per line: each run's heading, its output, then how it ended.
  var rows: seq[(string, ColorRGBX)]
  for i, e in a.runLog:
    if i > 0: rows.add ("", colText)
    rows.add (e.started.format("HH:mm:ss") & "  " & e.title & "  —  " & e.dir, colAccent)
    for line in e.output: rows.add (line, colText)
    if e.error.len > 0: rows.add (e.error, colError)
    elif e.running: rows.add ((if e.stopped: "Stopping…" else: "Running…"), colMarker)
    elif e.stopped: rows.add ("Stopped", colMarker)
    elif e.code == 0: rows.add ("Finished", colTextDim)
    else: rows.add (&"Failed (exit code {e.code})", colError)
  a.rlRows = rows.mapIt(it[0])

  let header = rect(r.x, r.y, r.w, RunLogHeaderH)
  let running = a.runLog.countIt(it.running)
  # Header buttons, right to left: Close, Copy all, Clear (finished runs), Stop (running ones).
  if ui.iconButton("rl-close", rect(r.x + r.w - 30, header.y + 2, 24, 24), "close16", a.closeTip(kaRunLog)):
    a.setRunLogShown(false)
  var bx = r.x + r.w - 38
  let headerButton = proc (label, tip: string): bool =
    let b = rect(bx - 60, header.y + 4, 60, header.h - 8)
    bx -= 66
    let hov = ui.hover(b)
    ui.rect(b, if hov: colHover else: colPanelRaised)
    ui.border(b, colBorder)
    ui.textIn(label, b, colText, FontSmall, h = CenterAlign)
    ui.tip(b, tip)
    if hov and ui.pressed():
      ui.consumeClick()
      return true
  if rows.len > 0 and headerButton("Copy all", "Copy the whole log to the clipboard"):
    setClipboardString(a.rlRows.join("\n"))
    a.osd("Copied the run log")
  if a.runLog.len > running and headerButton("Clear", "Remove the finished runs"):
    a.runLog.keepItIf(it.running)
    a.rlSelFrom = (0, 0)
    a.rlSelTo = (0, 0)
  if running > 0 and headerButton("Stop", "Stop the running command lines"):
    for e in a.runLog: e.stop()
  ui.icon("terminal16", vec2(r.x + 18, header.y + header.h / 2), colAccent)
  ui.textIn(if running > 0: &"Run log ({running} running)" else: "Run log",
    rect(r.x + 32, header.y, max(0'f32, bx - r.x - 32), header.h), colText)
  ui.rect(rect(r.x, header.y + header.h - 1, r.w, 1), colBorder)

  let list = rect(r.x, header.y + header.h, r.w, max(0'f32, r.h - header.h - RunLogGripH))
  if a.runLog.len == 0:
    ui.textIn("Nothing has run yet. Command lines run from the Run menu show their output here.",
      list, colTextDim, FontSmall, h = CenterAlign)
    return

  let rowH = RunLogRowH
  let pad = 6'f32
  let contentH = rows.len.float32 * rowH + 2 * pad
  let maxScroll = max(0'f32, contentH - list.h)
  if ui.hover(list) and ui.scroll() != 0:
    a.rlScroll += ui.wheelNotches * rowH * RunLogWheelRows
    a.rlScroll = clamp(a.rlScroll, 0, maxScroll)
    a.rlFollow = a.rlScroll >= maxScroll
    ui.scrollConsumed = true

  # Scroll bar: drag the thumb, or click the track to jump there.
  let track = rect(list.x + list.w - RunLogBarW - 2, list.y + 2, RunLogBarW, max(0'f32, list.h - 4))
  if maxScroll > 0 and track.h > 0:
    let thumbH = max(24'f32, track.h * list.h / contentH).min(track.h)
    let span = track.h - thumbH
    var thumb = rect(track.x, track.y + span * a.rlScroll / maxScroll, track.w, thumbH)
    if ui.hover(track) and ui.pressed():
      ui.consumeClick()
      if not ui.hover(thumb):
        # Center the thumb on the pointer, then keep dragging from there.
        a.rlScroll = clamp((ui.mouse.y - track.y - thumbH / 2) / span * maxScroll, 0, maxScroll)
      ui.activeId = "rlscroll"
      a.rlThumbFrom = (ui.mouse.y, a.rlScroll)
    if ui.activeId == "rlscroll":
      let (y0, s0) = a.rlThumbFrom
      if span > 0:
        a.rlScroll = clamp(s0 + (ui.mouse.y - y0) / span * maxScroll, 0, maxScroll)
      a.rlFollow = a.rlScroll >= maxScroll
    a.rlScroll = clamp(a.rlScroll, 0, maxScroll)
    thumb.y = track.y + span * a.rlScroll / maxScroll
    ui.rect(track, colTrack)
    ui.rect(thumb, if ui.activeId == "rlscroll": colAccent
      elif ui.hover(thumb): colTextDim else: colTextDisabled)
  if a.rlFollow: a.rlScroll = maxScroll
  a.rlScroll = clamp(a.rlScroll, 0, maxScroll)

  # Selecting text: drag over it (scrolling when the pointer leaves the
  # list), Shift+click extends, a double-click takes a word and a triple-click
  # the whole log. Ctrl+C copies it (handleKeys); a click elsewhere drops it.
  let textX = list.x + 12
  let textArea = rect(list.x, list.y, list.w - RunLogBarW - 4, list.h)
  proc hitAt(p: Vec2, nearest = true): (int, int) =
    ## (row, byte offset) of the character boundary nearest to p, or with
    ## nearest off, where the character under p starts.
    let i = int(floor((p.y - list.y - pad + a.rlScroll) / rowH))
    if i < 0: return (0, 0)
    if i >= rows.len: return (rows.len - 1, rows[^1][0].len)
    let s = rows[i][0]
    let x = p.x - textX
    var lo = 0  # longest prefix not wider than x
    var hi = s.len
    while lo < hi:
      let mid = (lo + hi + 1) div 2
      if ui.textSize(s[0 ..< mid], FontSmall).x <= x: lo = mid
      else: hi = mid - 1
    while lo > 0 and lo < s.len and (s[lo].ord and 0xC0) == 0x80: dec lo
    if nearest and lo < s.len:
      var j = lo + 1
      while j < s.len and (s[j].ord and 0xC0) == 0x80: inc j
      if x > (ui.textSize(s[0 ..< lo], FontSmall).x + ui.textSize(s[0 ..< j], FontSmall).x) / 2:
        lo = j
    (i, lo)
  if ui.window.buttonPressed[MouseLeft] and not ui.mouse.inside(list):
    a.rlSelTo = a.rlSelFrom
  if ui.hover(textArea) and ui.released(MouseRight):
    a.ctxMenu = cmRunLog
    a.menus.openContext(ui.mouse)
  if ui.hover(textArea) and ui.pressed():
    ui.consumeClick()
    ui.activeId = "rlselect"
    let p = hitAt(ui.mouse)
    let clicks = ui.countClick("rlselect")
    if clicks == 2:
      let (row, col) = hitAt(ui.mouse, false)
      let (w0, w1) = wordAround(rows[row][0].classes, col)
      (a.rlSelFrom, a.rlSelTo) = ((row, w0), (row, w1))
    elif clicks >= 3:
      (a.rlSelFrom, a.rlSelTo) = ((0, 0), (rows.len - 1, rows[^1][0].len))
    else:
      if not ui.window.shiftDown: a.rlSelFrom = p
      a.rlSelTo = p
  if ui.activeId == "rlselect" and ui.down() and ui.clickCount == 1:
    if ui.mouse.y < list.y or ui.mouse.y >= list.y + list.h:
      a.rlScroll = clamp(a.rlScroll + (if ui.mouse.y < list.y: -rowH else: rowH), 0, maxScroll)
      a.rlFollow = a.rlScroll >= maxScroll
      a.dirtyUntil = max(a.dirtyUntil, now() + 0.05)
    a.rlSelTo = hitAt(ui.mouse)
  var (selA, selB) = (a.rlSelFrom, a.rlSelTo)
  if selB < selA: swap(selA, selB)

  let textW = list.w - 24 - (if maxScroll > 0: RunLogBarW + 4 else: 0)
  ui.sk.pushClipRect(textArea)
  let first = max(0, int((a.rlScroll - pad) / rowH))
  let last = min(rows.len, first + int(list.h / rowH) + 2) - 1
  for i in first .. last:
    let y = list.y + pad + i.float32 * rowH - a.rlScroll
    let row = rows[i][0]
    if selA != selB and i >= selA[0] and i <= selB[0]:
      let x0 = if i == selA[0]: ui.textSize(row[0 ..< min(selA[1], row.len)], FontSmall).x else: 0
      let x1 = if i == selB[0]: ui.textSize(row[0 ..< min(selB[1], row.len)], FontSmall).x
               else: ui.textSize(row, FontSmall).x + 4  # the line break
      if x1 > x0: ui.rect(rect(textX + x0, y, x1 - x0, rowH), colAccentDim)
    ui.textIn(row, rect(textX, y, textW, rowH), rows[i][1], FontSmall)
  ui.sk.popClipRect()

proc dropFiles(a: App, dropped: seq[string]) =
  ## Dropped on the playlist: insert at the row boundary under the pointer and
  ## keep playing. Anywhere else: replace the playlist and play. Files, links
  ## (from a browser) and text holding them (a dragged selection) alike.
  let paths = dropped.mapIt(pathOrLink(it)).filterIt(it.len > 0)
  let list = a.plListRect
  if list.w > 0 and a.dropAt.inside(list):
    let at = int((a.dropAt.y - list.y + a.plScroll) / PlaylistRowH + 0.5)
    a.addToPlaylist(paths, at)
  else:
    a.openPaths(paths)

proc idleScreen(a: App, area: Rect) =
  if a.holding or a.thumbShown: return  # a frame is up (another quality opening)
  let ui = a.ui
  let c = area.xy + area.wh / 2
  if a.player.loaded and not a.player.hasVideo and not a.player.stopped:
    ui.icon("music96", c - vec2(0, 30), colAccentDim)
    let name = ui.ellipsize(a.player.path.extractFilename, area.w - 40)
    ui.textIn(name, rect(area.x, c.y + 30, area.w, 30), colTextDim, h = CenterAlign)
  elif (not a.player.loaded or a.player.stopped) and area.h > 140:
    ui.icon("crown96", c - vec2(0, 24), colAccentDim)
    ui.textIn(AppName, rect(area.x, c.y + 34, area.w, 30), colTextDim, FontTitle, h = CenterAlign)

proc ownOsdMsg(a: App, area: Rect) =
  ## The OSD message mpv can't show (ownOsd), top left of the frame.
  if not a.ownOsd or now() >= a.osdUntil or a.osdMsg.len == 0: return
  let ui = a.ui
  let sz = ui.textSize(a.osdMsg, FontTitle)
  let r = rect(area.x + 16, area.y + 16, sz.x + 20, sz.y + 10)
  ui.rect(r, rgbx(0, 0, 0, 170))
  ui.text(a.osdMsg, r.xy + vec2(10, 5), colText, FontTitle)

proc compactOutline(a: App, r: Rect) =
  ## Compact mode has no window frame: a faint 1 pixel line marks the
  ## window's edge, drawn over its content so it takes no room.
  if not a.cfg.compactMode or a.fullscreen or a.window.maximized: return
  a.ui.border(r, colOutline, 1 / a.sk.uiScale)

proc syncOutline(a: App, r: Rect) =
  ## Synchronized players are framed in their group's color: solid around the
  ## master, dashed around the others.
  if not a.synced: return
  let ui = a.ui
  let col = groupColor(a.syncMaster)
  let t = 1 / a.sk.uiScale  # one pixel at any UI scale
  if a.isSyncMaster:
    ui.border(r, col, t)
    return
  ui.dashedBorder(r, col, 14, 8, t)

# --- overlays ---------------------------------------------------------------

proc overlayFrame(a: App, title: string, size: Vec2): Rect =
  let ui = a.ui
  ui.rect(rect(vec2(0, 0), ui.size), colScrim)
  let r = rect(((ui.size - size) / 2).floor, size)
  ui.rect(rect(r.xy + vec2(4, 6), r.wh), colShadow)
  ui.rect(r, colPanel)
  ui.border(r, colBorder)
  ui.textIn(title, rect(r.x + 20, r.y + 12, r.w - 60, 30), colText, FontTitle)
  if ui.iconButton("ov-close", rect(r.x + r.w - 40, r.y + 10, 30, 30), "close20", "Close"):
    a.overlay = ovNone
  ui.rect(rect(r.x + 1, r.y + 50, r.w - 2, 1), colBorder)
  # A press on the scrim dismisses it, without reaching anything beneath.
  if (ui.pressed() or ui.pressed(MouseRight)) and not ui.mouse.inside(r):
    a.overlay = ovNone
    ui.consumeClick()
  r

proc beginDialogDraw(a: App, w: Window, sk: Silky, size: IVec2): bool =
  ## Starts drawing a dialog window's frame (after the main window's swap).
  ## On X11 it is drawn in the main window's buffer and put into the dialog
  ## by X, so it needs no GL buffers of its own (see xwin_x11's putPixelsOn).
  when defined(windows): w.beginDrawOn()
  else:
    sk.beginOffscreen(a.window.size, size, colPanel)
    true

proc dialogImage(size: IVec2): Image =
  ## The dialog frame just drawn (for screenshots).
  when defined(windows): readFramebuffer(size) else: offscreenImage(size)

proc endDialogDraw(a: App, w: Window, sk: Silky, size: IVec2) =
  ## Presents the dialog frame begun by beginDialogDraw.
  when defined(windows): w.endDrawOn(a.window)
  else:
    sk.endOffscreen()
    w.putPixels(size, offscreenPixels())

proc renderOptions(a: App, shot: string) =
  ## Draws the Options window. Like the menu popups, call after the main
  ## window's swap.
  if a.overlay != ovOptions: return
  let w = a.optWin
  let ui = a.optUi
  if w.closeRequested:  # its title bar's close button, Alt+F4
    w.closeRequested = false
    a.closeOptions(false)
    return
  a.applyUiScale()
  let size = w.size
  if size.x <= 0 or size.y <= 0: return
  # A text field being edited takes Escape itself.
  let esc = w.buttonPressed[KeyEscape] and ui.focusId.len == 0 and not a.optionsDlg.searching
  if not a.beginDialogDraw(w, a.optSk, size): return  # retried next frame
  ui.beginFrame()
  a.optSk.beginUi(w, size)
  glViewport(0, 0, size.x, size.y)
  glClearColor(colPanel.r.float32 / 255, colPanel.g.float32 / 255,
    colPanel.b.float32 / 255, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  # The Media Cache page's list follows links being saved.
  if a.optionsDlg.page == opWeb and now() - a.webInfoAt > 2: a.refreshWebInfo()
  let action = a.optionsDlg.draw(ui, a.cfg, rect(vec2(0, 0), ui.size))
  ui.drawTooltip()
  a.optSk.endUi()
  ui.endFrame()
  if shot.len > 0: dialogImage(size).writeFile(shot.changeFileExt("") & "-options.png")
  a.endDialogDraw(w, a.optSk, size)
  case action
  of oaOk: a.closeOptions(true)
  of oaCancel: a.closeOptions(false)
  of oaNone:
    if esc: a.closeOptions(false)
  let req = a.optionsDlg.request
  a.optionsDlg.request = prNone
  case req
  of prNone: discard
  of prBrowseScreenshots:
    a.ask(dkOpenDir, "optshotdir", "Screenshot Folder", a.cfg.screenshotFolder)
  of prBrowseOpen:
    let d = a.cfg.openDir.expandPath
    a.ask(dkOpenDir, "optopendir", "Start Folder",
      if d.len > 0 and dirExists(d): d else: a.startDir)
  of prShowSettings: a.openFolder(configDir())
  of prBrowseMkvpropedit:
    let f = findMkvpropedit(a.cfg.mkvpropedit)
    a.ask(dkOpenFile, "optmkvpe", "mkvpropedit", if f.len > 0: f.parentDir else: "",
      exts = (when defined(windows): @["exe"] else: @[]), filterName = "Programs")
  of prBrowseYtdlp:
    let f = findYtdlp(a.cfg.ytdlp)
    a.ask(dkOpenFile, "optytdlp", "yt-dlp", if f.len > 0: f.parentDir else: "",
      exts = (when defined(windows): @["exe"] else: @[]), filterName = "Programs")
  of prBrowseWeb:
    let d = a.cfg.webDir.expandPath
    a.ask(dkOpenDir, "optwebdir", "Media Cache Folder",
      if d.len > 0 and dirExists(d): d else: saveDir())
  of prOpenWebDir:  # the folder set in the field, applied or not
    let d = a.cfg.webDir.expandPath
    a.openFolder(if d.len > 0: d else: defaultSaveDir())
  of prClearWeb:
    a.dropSaved(toSeq(a.saved.keys))
    a.saved.removeStray(initDuration())
    a.linkInfos.clear()
    a.linkInfosChanged = true
    a.saveLinkInfos()
    a.optionsDlg.webPicked = @[]
    a.refreshWebInfo()
  of prDeleteWeb:
    a.dropSaved(a.optionsDlg.webPicked)
    a.optionsDlg.webPicked = @[]
    a.refreshWebInfo()
  if a.optionsDlg.assocApplied:
    a.optionsDlg.assocApplied = false
    # Let KDE's service cache notice the new defaults right away.
    if findExe("kbuildsycoca6").len > 0: a.spawn("kbuildsycoca6")

proc renDuration(a: App): float =
  if a.renPath == a.player.path: a.player.duration else: -1.0

proc renMoveTo(a: App, t: float) =
  ## The bookmark being edited moves to the frame nearest t.
  let t = a.snapToFrame(a.renPath, t)
  if t != a.renTime and a.moveBookmark(a.renPath, a.renTime, t):
    a.renTime = t
    a.previewBookmark()
  a.renTimeText = fmtTime(a.renTime, true, a.renDuration)

proc renderRename(a: App, shot: string) =
  ## Draws the Edit Bookmark window; Enter does what Save does, Escape what
  ## Cancel does. Leaving the Time field moves the bookmark there, onto the
  ## nearest frame, so the seek bar shows it right away; the wheel over it
  ## (Up/Down in it) moves it a frame. With Preview, playback follows it.
  if a.overlay != ovRename: return
  let w = a.renWin
  let ui = a.renUi
  if w.closeRequested:
    w.closeRequested = false
    a.closeRename()
    return
  let size = w.size
  if size.x <= 0 or size.y <= 0: return
  let enter = w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter]
  let esc = w.buttonPressed[KeyEscape]
  if not a.beginDialogDraw(w, a.renSk, size): return  # retried next frame
  ui.beginFrame()
  a.renSk.beginUi(w, size)
  glViewport(0, 0, size.x, size.y)
  glClearColor(colPanel.r.float32 / 255, colPanel.g.float32 / 255,
    colPanel.b.float32 / 255, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  let W = ui.size.x
  let dur = a.renDuration
  proc commitTime() =
    ## The Time field was left without it seeing so.
    if esc: return  # Cancel puts it back anyway
    try: a.renMoveTo(parseTime(a.renTimeText))
    except ValueError: a.renTimeText = fmtTime(a.renTime, true, dur)
  # Switching to another window leaves the field too.
  if ui.focusId == "ren-time" and not w.focused:
    ui.focusId = ""
    commitTime()
  let wasTime = ui.focusId == "ren-time"
  ui.textIn("Name", rect(16, 10, W - 32, 22), colTextDim, FontSmall)
  discard ui.textField("ren-name", rect(16, 34, W - 32, 28), a.renText, a.renPlaceholder)
  # Clicking the Name field takes the focus before the Time field sees the click.
  if wasTime and ui.focusId != "ren-time": commitTime()
  ui.textIn("Time", rect(16, 72, W - 32, 22), colTextDim, FontSmall)
  # A frame a step; without video, a tenth of a second.
  let fps = a.frameRate(a.renPath)
  var t = a.renTime
  if ui.timeField("ren-time", rect(16, 96, W - 32, 28), a.renTimeText, t,
                  if fps > 0: 1 / fps else: 0.1, hi = (if dur > 0: dur else: Inf), dur = dur) and
     not esc:
    a.renMoveTo(t)
  if ui.checkbox("ren-preview", vec2(16, 139), "Preview", a.cfg.bookmarkPreview):
    a.cfg.save()
    a.previewBookmark()
  ui.tip(rect(16, 139, 90, 22), "Jump to the bookmark's time as it changes")
  let cancel = ui.textButton("ren-cancel", rect(W - 224, 136, 100, 28), "Cancel")
  let ok = ui.textButton("ren-ok", rect(W - 116, 136, 100, 28), "Save", primary = true)
  ui.drawTooltip()
  a.renSk.endUi()
  ui.endFrame()
  if shot.len > 0: dialogImage(size).writeFile(shot.changeFileExt("") & "-rename.png")
  a.endDialogDraw(w, a.renSk, size)
  if ok or enter:
    a.renameBookmark(a.renPath, a.renTime, a.renText.strip)
    a.closeRename(keep = true)
  elif esc or cancel:
    a.closeRename()

proc renderEmbed(a: App, shot: string) =
  ## Draws the Embed As MKV Chapters window: embed and keep the bookmarks,
  ## embed and clear them, or cancel. Enter keeps them.
  if a.overlay != ovEmbed: return
  let w = a.embWin
  let ui = a.embUi
  if w.closeRequested:
    w.closeRequested = false
    a.closeEmbed()
    return
  let size = w.size
  if size.x <= 0 or size.y <= 0: return
  let enter = w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter]
  let esc = w.buttonPressed[KeyEscape]
  if not a.beginDialogDraw(w, a.embSk, size): return  # retried next frame
  ui.beginFrame()
  a.embSk.beginUi(w, size)
  glViewport(0, 0, size.x, size.y)
  glClearColor(colPanel.r.float32 / 255, colPanel.g.float32 / 255,
    colPanel.b.float32 / 255, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  let W = ui.size.x
  let H = ui.size.y
  let n = a.fileBookmarks.len
  let text = case a.embMode
    of emAsk:
      &"Write {n} bookmark" & (if n == 1: "" else: "s") & " into " &
        a.embPath.extractFilename & " as chapters? The file is changed in place; " &
        "the chapters it has are kept. Keep the bookmarks afterwards, or clear them?"
    of emInstall:
      "Embedding chapters needs MKVToolNix's mkvpropedit, which wasn't found. " &
        "Install it? Its latest release goes to " &
        (when defined(windows): shortPath(mkvManagedPath().parentDir) & "."
         else: shortPath(getDataDir() / "majestic-media-player" / "mkvtoolnix") &
           ", run through " & shortPath(mkvManagedPath()) & ".")
    of emBusy, emFailed: a.embMsg
  var y = 14'f32
  for line in ui.wrapText(text, W - 32, 5):
    ui.textIn(line, rect(16, y, W - 32, 22), colText)
    y += 22
  let j = a.mkvJob
  if a.embMode == emBusy and j.running:
    let r = rect(16, min(y + 10, H - 56), W - 32, 6)
    ui.rect(r, colTrack)
    if j.stage == mkDownload and j.progress >= 0:
      ui.rect(rect(r.x, r.y, r.w * clamp(j.progress / 100, 0, 1), r.h), colAccent)
  let bw = if a.embMode == emAsk: 130'f32 else: 100'f32
  let br = rect(W - 16 - bw, H - 44, bw, 28)
  var ok, clear, cancel = false
  case a.embMode
  of emAsk:
    ok = ui.textButton("emb-keep", br, "Keep Bookmarks", primary = true)
    clear = ui.textButton("emb-clear", rect(br.x - bw - 8, br.y, bw, br.h), "Clear Bookmarks")
    cancel = ui.textButton("emb-cancel", rect(br.x - 2 * (bw + 8), br.y, bw, br.h), "Cancel")
  of emInstall:
    ok = ui.textButton("emb-install", br, "Install", primary = true)
    cancel = ui.textButton("emb-cancel", rect(br.x - bw - 8, br.y, bw, br.h), "Cancel")
  of emBusy: cancel = ui.textButton("emb-hide", br, "Hide")
  of emFailed: cancel = ui.textButton("emb-close", br, "Close", primary = true)
  ui.drawTooltip()
  a.embSk.endUi()
  ui.endFrame()
  if shot.len > 0: dialogImage(size).writeFile(shot.changeFileExt("") & "-embed.png")
  a.endDialogDraw(w, a.embSk, size)
  if (ok or clear or enter) and a.embMode in {emAsk, emInstall}: a.embAnswer(true, clear)
  elif cancel or esc or (enter and a.embMode == emFailed): a.embAnswer(false)

proc renderEqualizer(a: App, shot: string) =
  ## Draws the Equalizer window: its changes are heard as they are made,
  ## on or off (on only has the gains apply). Escape hides it, like its
  ## close button.
  let w = a.eqWin
  if w == nil or not w.visible: return
  let ui = a.eqUi
  if w.closeRequested or w.buttonPressed[KeyEscape]:
    w.closeRequested = false
    a.toggleEqualizer()
    return
  let size = w.size
  if size.x <= 0 or size.y <= 0: return
  if not a.beginDialogDraw(w, a.eqSk, size): return  # retried next frame
  ui.beginFrame()
  a.eqSk.beginUi(w, size)
  glViewport(0, 0, size.x, size.y)
  glClearColor(colPanel.r.float32 / 255, colPanel.g.float32 / 255,
    colPanel.b.float32 / 255, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  let W = ui.size.x
  let H = ui.size.y
  let was = a.equalizer
  var (on, gains) = was
  discard ui.checkbox("eq-on", vec2(16, 12), "Enable Equalizer", on)
  var saved = a.eqSaved
  let saveX = 16 + 24 + ui.textSize("Enable Equalizer").x + 18
  let saveChanged = ui.checkbox("eq-save", vec2(saveX, 12), "Save for this media", saved,
    enabled = a.player.path.len > 0)
  ui.tip(rect(saveX, 12, 24 + ui.textSize("Save for this media").x, 22),
    "Reopening this media file brings these settings back")
  let normR = rect(W - 184, 10, 86, 26)
  if ui.textButton("eq-norm", normR, "Normalize"):
    # The highest band goes to 0 dB, the others with it by as much, so none
    # is above 0; what passes the bottom of the range stops there.
    let top = max(gains)
    for g in gains.mitems: g = clamp(g - top, a.eqMinGain, EqMaxGain)
  ui.tip(normR, "Move the highest band to 0 dB, and the others by as much")
  if ui.textButton("eq-reset", rect(W - 90, 10, 74, 26), "Reset"):
    gains = newSeq[float](EqFreqs.len)
  ui.rect(rect(0, 46, W, 1), colBorder)
  # The bands: their gains above, sliders, frequencies below; the dB scale
  # on the left.
  const ScaleW = 52'f32
  let lo = a.eqMinGain
  let (top, bottom) = (84'f32, H - 76)
  let x0 = 16 + ScaleW + 8
  let colW = (W - 16 - x0) / EqFreqs.len.float32
  let zeroY = top + (bottom - top) * float32(EqMaxGain / (EqMaxGain - lo))
  for (label, y) in [(&"+{EqMaxGain:g} dB", top), ("0 dB", zeroY), (&"{lo:g} dB", bottom)]:
    ui.textIn(label, rect(8, y - 10, ScaleW, 20), colTextDim, FontSmall, h = RightAlign)
  ui.rect(rect(16 + ScaleW, zeroY, W - 32 - ScaleW, 1), colBorder)
  # The arrow keys move the slider under the pointer, else the one with
  # keyboard focus.
  let pointed = ui.mouse.x >= x0 and ui.mouse.x < x0 + colW * EqFreqs.len.float32 and
    ui.mouse.y >= top - 8 and ui.mouse.y <= bottom + 8
  if pointed and ui.focusId.len == 0 and
     [KeyUp, KeyDown, KeyLeft, KeyRight, KeyHome, KeyEnd].anyIt(w.buttonPressed[it]):
    ui.navId = &"eq-band{int(floor((ui.mouse.x - x0) / colW))}"
  # Dragging from a slider across the others sets each one passed to the
  # pointer's height, as if drawn: the bands skipped by a fast move in
  # between, along the line from where it was. Near 0 it lands on 0, as
  # the sliders do, unless Shift is held.
  if ui.activeId.startsWith("eq-band") and ui.down():
    let j = clamp(int(floor((ui.mouse.x - x0) / colW)), 0, EqFreqs.high)
    var v = round(EqMaxGain - clamp((ui.mouse.y - top) / (bottom - top), 0, 1) * (EqMaxGain - lo))
    if not w.shiftDown and abs(ui.mouse.y - zeroY) <= 5: v = 0
    let (pj, pv) = if a.eqDragging: a.eqDragAt else: (j, v)
    for k in min(pj, j) .. max(pj, j):
      let t = if j == pj: 1.0 else: (k - pj) / (j - pj)
      gains[k] = round(pv + (v - pv) * t)
    (a.eqDragging, a.eqDragAt) = (true, (j, v))
    ui.activeId = &"eq-band{j}"
  else:
    a.eqDragging = false
  # A line per dB, fewer when they would crowd.
  var ticks = 1.0
  for t in [1.0, 2, 3, 6, 12]:
    ticks = t
    if (bottom - top) * float32(t / (EqMaxGain - lo)) >= 5: break
  proc dB(g: float): string = (if g == 0: "0" else: &"{g:+g}") & " dB"
  for i, f in EqFreqs:
    let x = x0 + colW * i.float32
    let g = gains[i]
    ui.textIn(if g == 0: "0" else: &"{g:+g}", rect(x, 56, colW, 20),
      if g == 0: colTextDim else: colText, FontSmall, h = CenterAlign)
    let id = &"eq-band{i}"
    let sr = rect(x, top, colW, bottom - top)
    if ui.vSlider(id, sr, gains[i], lo, EqMaxGain, 1, origin = 0,
                  fill = if on: colAccent else: colTextDisabled, ticks = ticks, snapTo = 0) and
       ui.activeId != id:
      (a.eqTipBand, a.eqTipUntil) = (i, now() + 1.0)
    if not (a.eqTipBand == i and now() < a.eqTipUntil):
      ui.tip(sr, dB(gains[i]))
    let name = if f >= 1000: &"{f / 1000:g}K" else: &"{f:g}"
    ui.textIn(name, rect(x, bottom + 12, colW, 20), colTextDim, FontSmall, h = CenterAlign)
  # The bottom of the sliders' range.
  ui.rect(rect(0, H - 46, W, 1), colBorder)
  let minW = ui.textSize("Minimum").x
  ui.textIn("Minimum", rect(16, H - 36, minW + 2, 26), colText)
  var minGain = lo
  if ui.numberField("eq-min", rect(16 + minW + 10, H - 36, 120, 26), minGain, 1, EqMinGainLimit, -1):
    a.cfg.equalizerMinGain = minGain
  ui.textIn("dB", rect(16 + minW + 138, H - 36, 30, 26), colTextDim)
  discard ui.tabNavigate()
  ui.drawTooltip()
  # A band moved by key or wheel: its value by its cap for a moment.
  if now() < a.eqTipUntil:
    let i = a.eqTipBand
    let text = dB(gains[i])
    let sz = ui.textSize(text, FontSmall) + vec2(14, 8)
    let ky = top + (bottom - top) * float32((EqMaxGain - gains[i]) / (EqMaxGain - lo))
    var p = vec2(x0 + colW * (i.float32 + 0.5) + 14, ky - sz.y / 2)
    if p.x + sz.x > W - 4: p.x = x0 + colW * (i.float32 + 0.5) - 14 - sz.x
    ui.sk.pushLayer(PopupsLayer)
    ui.rect(rect(p, sz), colPopup)
    ui.border(rect(p, sz), colBorder)
    ui.text(text, p + vec2(7, 4), colText, FontSmall)
    ui.sk.popLayer()
  a.eqSk.endUi()
  ui.endFrame()
  if shot.len > 0: dialogImage(size).writeFile(shot.changeFileExt("") & "-equalizer.png")
  a.endDialogDraw(w, a.eqSk, size)
  if saveChanged: a.rememberEqualizer(saved)
  elif (on, gains) != was: a.changeEqualizer(on, gains)

proc renderSyncProps(a: App, shot: string) =
  ## Draws Synchronize > Properties; its changes apply as they are made.
  if a.overlay != ovSync: return
  let w = a.syncWin
  let ui = a.syncUi
  if w.closeRequested:
    w.closeRequested = false
    a.closeSyncProps()
    return
  let size = w.size
  if size.x <= 0 or size.y <= 0: return
  let all = a.syncInstances
  if not a.beginDialogDraw(w, a.syncSk, size): return  # retried next frame
  ui.beginFrame()
  a.syncSk.beginUi(w, size)
  glViewport(0, 0, size.x, size.y)
  glClearColor(colPanel.r.float32 / 255, colPanel.g.float32 / 255,
    colPanel.b.float32 / 255, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  let d = a.syncDlg
  let action = d.draw(ui, rect(vec2(0, 0), ui.size), all)
  ui.drawTooltip()
  a.syncSk.endUi()
  ui.endFrame()
  if shot.len > 0: dialogImage(size).writeFile(shot.changeFileExt("") & "-sync.png")
  a.endDialogDraw(w, a.syncSk, size)
  let sel = all.filterIt(it.pid == d.selected)
  case action
  of saNone: discard
  of saClose: a.closeSyncProps()
  of saMaster: a.setMasterOf(d.selected, d.newMaster)
  of saOffset:
    if sel.len > 0: a.setFollowOf(d.selected, d.newOffset, sel[0].loop)
  of saLoop:
    if sel.len > 0: a.setFollowOf(d.selected, sel[0].offset, d.newLoop)

proc renderYtdlp(a: App, shot: string) =
  ## Draws the yt-dlp window: an install or update to agree to, or one going on.
  if a.overlay != ovYtdlp: return
  let w = a.ytWin
  let ui = a.ytUi
  if w.closeRequested:
    w.closeRequested = false
    a.closeYtdlp()
    return
  let size = w.size
  if size.x <= 0 or size.y <= 0: return
  let enter = w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter]
  let esc = w.buttonPressed[KeyEscape]
  if not a.beginDialogDraw(w, a.ytSk, size): return  # retried next frame
  ui.beginFrame()
  a.ytSk.beginUi(w, size)
  glViewport(0, 0, size.x, size.y)
  glClearColor(colPanel.r.float32 / 255, colPanel.g.float32 / 255,
    colPanel.b.float32 / 255, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  let W = ui.size.x
  let H = ui.size.y
  let text = case a.ytMode
    of ymInstall:
      "Opening this link needs yt-dlp, which wasn't found on PATH. Install it? " &
        "Its standalone build goes to " & shortPath(managedPath()) &
        ", from where it keeps itself up to date (yt-dlp -U)."
    of ymUpdate:
      &"This link didn't open. A newer yt-dlp is out: {a.ytLatest} (you have " &
        &"{a.ytCurrent}). Update it now?"
    of ymBusy, ymFailed: a.ytMsg
  var y = 14'f32
  for line in ui.wrapText(text, W - 32, 5):
    ui.textIn(line, rect(16, y, W - 32, 22), colText)
    y += 22
  let j = a.ytJob
  if a.ytMode == ymBusy and j.running:
    let r = rect(16, min(y + 10, H - 56), W - 32, 6)
    ui.rect(r, colTrack)
    if j.progress >= 0: ui.rect(rect(r.x, r.y, r.w * clamp(j.progress / 100, 0, 1), r.h), colAccent)
  let bw = 100'f32
  let br = rect(W - 16 - bw, H - 44, bw, 28)
  var ok, cancel = false
  case a.ytMode
  of ymInstall, ymUpdate:
    ok = ui.textButton("yt-ok", br, (if a.ytMode == ymInstall: "Install" else: "Update"),
      primary = true)
    cancel = ui.textButton("yt-cancel", rect(br.x - bw - 8, br.y, bw, br.h),
      if a.ytMode == ymInstall: "Cancel" else: "Not now")
  of ymBusy: cancel = ui.textButton("yt-hide", br, "Hide")
  of ymFailed: cancel = ui.textButton("yt-close", br, "Close", primary = true)
  ui.drawTooltip()
  a.ytSk.endUi()
  ui.endFrame()
  if shot.len > 0: dialogImage(size).writeFile(shot.changeFileExt("") & "-ytdlp.png")
  a.endDialogDraw(w, a.ytSk, size)
  if (ok or enter) and a.ytMode in {ymInstall, ymUpdate}: a.ytAnswer(true)
  elif cancel or esc or (enter and a.ytMode == ymFailed): a.ytAnswer(false)

proc renderUpdate(a: App, shot: string) =
  ## Draws the Check for Updates window: the check, an update to agree to
  ## (with its release notes), or getting it.
  if a.overlay != ovUpdate: return
  let w = a.upWin
  let ui = a.upUi
  if w.closeRequested:
    w.closeRequested = false
    a.closeUpdate()
    return
  let size = w.size
  if size.x <= 0 or size.y <= 0: return
  let enter = w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter]
  let esc = w.buttonPressed[KeyEscape]
  if not a.beginDialogDraw(w, a.upSk, size): return  # retried next frame
  ui.beginFrame()
  a.upSk.beginUi(w, size)
  glViewport(0, 0, size.x, size.y)
  glClearColor(colPanel.r.float32 / 255, colPanel.g.float32 / 255,
    colPanel.b.float32 / 255, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  let W = ui.size.x
  let H = ui.size.y
  let j = a.upJob
  let version = if j != nil: j.version else: ""
  let text = case a.upMode
    of umChecking: "Looking up the latest release..."
    of umLatest: &"You have the latest version: {AppName} {AppVersion}."
    of umAsk:
      &"{AppName} {version} is out (you have {AppVersion}). Get it now? " &
        (when defined(windows): "" else: "It's built from its source, which takes a minute or two. ") &
        "Once it's ready the player restarts into it, playing what it was."
    of umBusy:
      if not j.running: ""
      else:
        case j.stage
        of upLatest: "Looking up the latest release..."
        of upDownload: &"Downloading {AppName} {version}..."
        of upExtract: &"Unpacking {AppName} {version}..."
        of upBuild: &"Building {AppName} {version}... " & j.lastLine
        of upInstall: &"Installing {AppName} {version}..."
    of umFailed: a.upMsg
  var y = 14'f32
  for line in ui.wrapText(text, W - 32, 4):
    ui.textIn(line, rect(16, y, W - 32, 22), colText)
    y += 22
  if a.upMode == umAsk and j.notes.len > 0:
    # Its release notes, as far as they fit: markdown's marks left out.
    y += 8
    for para in j.notes.splitLines:
      let l = para.strip(chars = {'#', ' ', '\t'})
      if l.len == 0: continue
      let room = int((H - 56 - y) / 20)
      if room <= 0: break
      for line in ui.wrapText(l, W - 32, room, FontSmall):
        ui.textIn(line, rect(16, y, W - 32, 20), colTextDim, FontSmall)
        y += 20
  if a.upMode == umBusy and j.running:
    let r = rect(16, H - 56, W - 32, 6)
    ui.rect(r, colTrack)
    if j.stage == upDownload and j.progress >= 0:
      ui.rect(rect(r.x, r.y, r.w * clamp(j.progress / 100, 0, 1), r.h), colAccent)
  let bw = 100'f32
  let br = rect(W - 16 - bw, H - 44, bw, 28)
  var ok, cancel = false
  case a.upMode
  of umAsk:
    ok = ui.textButton("up-ok", br, "Update", primary = true)
    cancel = ui.textButton("up-cancel", rect(br.x - bw - 8, br.y, bw, br.h), "Not now")
  of umChecking: cancel = ui.textButton("up-cancel", br, "Cancel")
  of umBusy:
    ok = ui.textButton("up-hide", br, "Hide", primary = true)
    cancel = ui.textButton("up-cancel", rect(br.x - bw - 8, br.y, bw, br.h), "Cancel")
  of umLatest, umFailed: ok = ui.textButton("up-close", br, "Close", primary = true)
  ui.drawTooltip()
  a.upSk.endUi()
  ui.endFrame()
  if shot.len > 0: dialogImage(size).writeFile(shot.changeFileExt("") & "-update.png")
  a.endDialogDraw(w, a.upSk, size)
  if a.upMode == umAsk and (ok or enter): a.upAnswer(true)
  elif cancel or (esc and a.upMode != umBusy): a.upAnswer(false)
  elif ok or esc or enter: a.closeUpdate()

proc renderCommands(a: App, shot: string) =
  ## Draws the Commands window window and carries out its buttons.
  if a.overlay != ovCommands: return
  let w = a.cmdWin
  let ui = a.cmdUi
  if w.closeRequested:
    w.closeRequested = false
    a.closeCommands()
    return
  let size = w.size
  if size.x <= 0 or size.y <= 0: return
  if not a.beginDialogDraw(w, a.cmdSk, size): return  # retried next frame
  ui.beginFrame()
  a.cmdSk.beginUi(w, size)
  glViewport(0, 0, size.x, size.y)
  glClearColor(colPanel.r.float32 / 255, colPanel.g.float32 / 255,
    colPanel.b.float32 / 255, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  let path = if a.player.loaded: a.player.path else: ""
  let action = a.cmdDlg.draw(ui, rect(vec2(0, 0), ui.size), path)
  ui.drawTooltip()
  a.cmdSk.endUi()
  ui.endFrame()
  if shot.len > 0: dialogImage(size).writeFile(shot.changeFileExt("") & "-commands.png")
  a.endDialogDraw(w, a.cmdSk, size)
  let d = a.cmdDlg
  case action
  of caNone: discard
  of caCancel: a.closeCommands()
  of caApply, caOk:
    let (orig, c) = (d.origTitle, d.commandLine)
    a.editCommandLines(proc (cmds: var seq[CommandLine]) =
      let i = cmds.mapIt(it.title).find(orig)
      if orig.len > 0 and i >= 0: cmds[i] = c
      else: cmds.add c)
    if orig.len > 0: moveValues(orig, c.title)
    if action == caOk: a.closeCommands()
    else:
      # Keep editing, now as the saved entry.
      d.saved = a.commands
      d.origTitle = c.title
  of caDelete:
    let orig = d.origTitle
    a.editCommandLines(proc (cmds: var seq[CommandLine]) =
      cmds.keepItIf(it.title != orig))
    moveValues(orig, "")
    d.saved = a.commands
    d.load(a.latestCommandLine)

proc browsePickPath(a: App, i: int) =
  ## Save dialog for path row i of the Run window, starting at its path.
  let d = a.pickDlg
  if i < 0 or i >= d.rows.len: return
  var start = d.texts[i].strip
  if start.startsWith("~"): start = start.expandTilde
  if start.len == 0: start = a.runDir
  elif not start.isAbsolute: start = a.runDir / start
  a.ask(dkSaveFile, "pickpath", d.cmd.title & ": " & d.rows[i].name, start)

proc renderPick(a: App, shot: string) =
  ## Draws the Run window; Run executes the command line with the times and
  ## values chosen.
  if not a.pickOpen: return
  let w = a.pickWin
  let ui = a.pickUi
  if w.closeRequested:
    w.closeRequested = false
    a.closePick()
    return
  let size = w.size
  if size.x <= 0 or size.y <= 0: return
  let choices = a.timeChoices
  if not a.beginDialogDraw(w, a.pickSk, size): return  # retried next frame
  ui.beginFrame()
  a.pickSk.beginUi(w, size)
  glViewport(0, 0, size.x, size.y)
  glClearColor(colPanel.r.float32 / 255, colPanel.g.float32 / 255,
    colPanel.b.float32 / 255, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  let action = a.pickDlg.draw(ui, rect(vec2(0, 0), ui.size), choices)
  ui.drawTooltip()
  a.pickSk.endUi()
  ui.endFrame()
  if shot.len > 0: dialogImage(size).writeFile(shot.changeFileExt("") & "-pick.png")
  a.endDialogDraw(w, a.pickSk, size)
  case action
  of paNone: discard
  of paCancel: a.closePick()
  of paDraw: a.beginRectDraw(a.pickDlg.drawRequest)
  of paBrowse: a.browsePickPath(a.pickDlg.browseRow)
  of paRun:
    if a.dialog != nil and a.dialog.purpose == "pickpath": return  # its path is still to come
    a.endRectDraw(true, refocus = false)
    let d = a.pickDlg
    var picks = a.extPicks
    var used = initTable[string, RunValue]()
    for i, row in d.rows:
      if row.kind == ckValue:
        picks[row.name] = d.texts[i]
        used[row.name] = RunValue(value: d.texts[i], crossed: d.crossed[i])
        continue
      if d.picks[i] < 0 or d.picks[i] >= choices.len: continue
      let ch = choices[d.picks[i]]
      if ch.time >= 0: picks[row.name] = fmtTime(ch.time, millis = true)
      used[row.name] = RunValue(which: ch.which, time: ch.time)
    d.cmd.rememberValues(used)
    a.closePick()
    a.execute(d.cmd, picks)

proc propertiesOverlay(a: App) =
  ## Scrollable sections, two columns: field name and value.
  const
    RowH = 21'f32
    HeadH = 34'f32
    KeyW = 260'f32
    Pad = 24'f32
  let ui = a.ui
  var contentH = 0'f32
  for s in a.props: contentH += HeadH + s.rows.len.float32 * RowH
  let size = vec2(min(900'f32, ui.size.x - 40),
    min(64 + contentH + 8 + 56, ui.size.y - 40))
  let r = a.overlayFrame("Properties", size)
  let body = rect(r.x + 1, r.y + 52, r.w - 2, r.h - 52 - 51)
  a.propPageH = body.h
  let maxScroll = max(0'f32, contentH + 8 - body.h)
  if ui.hover(body) and ui.scroll() != 0:
    a.propScroll += ui.wheelNotches * RowH * RunLogWheelRows
    ui.scrollConsumed = true
  a.propScroll = clamp(a.propScroll, 0, maxScroll)

  # Scroll bar: drag the thumb, or click the track to jump there.
  let track = rect(r.x + r.w - RunLogBarW - 4, body.y + 2, RunLogBarW, max(0'f32, body.h - 4))
  if maxScroll > 0 and track.h > 0:
    let thumbH = max(24'f32, track.h * body.h / (contentH + 8)).min(track.h)
    let span = track.h - thumbH
    var thumb = rect(track.x, track.y + span * a.propScroll / maxScroll, track.w, thumbH)
    if ui.hover(track) and ui.pressed():
      ui.consumeClick()
      if not ui.hover(thumb):
        # Center the thumb on the pointer, then keep dragging from there.
        a.propScroll = clamp((ui.mouse.y - track.y - thumbH / 2) / span * maxScroll, 0, maxScroll)
      ui.activeId = "propscroll"
      a.propThumbFrom = (ui.mouse.y, a.propScroll)
    if ui.activeId == "propscroll" and span > 0:
      let (y0, s0) = a.propThumbFrom
      a.propScroll = clamp(s0 + (ui.mouse.y - y0) / span * maxScroll, 0, maxScroll)
    thumb.y = track.y + span * a.propScroll / maxScroll
    ui.rect(track, colTrack)
    ui.rect(thumb, if ui.activeId == "propscroll": colAccent
      elif ui.hover(thumb): colTextDim else: colTextDisabled)

  ui.sk.pushClipRect(body)
  let outerClip = ui.hitClip
  ui.hitClip = body
  let x = r.x + Pad
  let valW = r.w - Pad * 2 - KeyW - 12 - RunLogBarW
  var y = body.y + 4 - a.propScroll
  for s in a.props:
    if y + HeadH > body.y and y < body.y + body.h:
      ui.textIn(s.title, rect(x, y + 4, r.w - Pad * 2, 24), colAccent)
      ui.rect(rect(x, y + 29, r.w - Pad * 2, 1), colBorder)
    y += HeadH
    for (k, v) in s.rows:
      if y + RowH > body.y and y < body.y + body.h:
        ui.textIn(ui.ellipsize(k, KeyW - 8, FontSmall), rect(x, y, KeyW, RowH), colTextDim, FontSmall)
        let shown = ui.ellipsize(v, valW, FontSmall)
        let vr = rect(x + KeyW, y, valW, RowH)
        ui.textIn(shown, vr, colText, FontSmall)
        if shown != v: ui.tip(vr, v)
      y += RowH
  ui.hitClip = outerClip
  ui.sk.popClipRect()
  ui.rect(rect(r.x + 1, r.y + r.h - 50, r.w - 2, 1), colBorder)
  let by = r.y + r.h - 40
  if ui.textButton("prop-copy", rect(r.x + Pad, by, 150, 30), "Copy to Clipboard"):
    setClipboardString(a.props.toText)
    a.osd("Properties copied")
  if ui.textButton("prop-close", rect(r.x + r.w - 116, by, 92, 30), "Close", primary = true):
    a.overlay = ovNone
  ui.drawTooltip()

type ShortcutGroup = tuple[title: string, rows: seq[(string, string)]]

proc keysText(a: App, acts: openArray[KeyAction], whenDefault = ""): string =
  ## Keys of the commands on one row, "Up / Down"; whenDefault replaces them
  ## while they're all on their default keys ("0 ... 9"). Commands without a
  ## key are left out.
  if whenDefault.len > 0 and acts.allIt(a.cfg.isDefault(it)): return whenDefault
  acts.mapIt(a.cfg.keysText(it)).filterIt(it.len > 0).join(" / ")

proc shortcutColumns(a: App): array[2, seq[ShortcutGroup]] =
  ## The F1 window's rows, with the keys set in Options > Player > Keys.
  ## Rows whose commands have no key are left out.
  proc keyRows(a: App, title: string,
               rows: openArray[(string, seq[KeyAction], string)]): ShortcutGroup =
    result.title = title
    for (label, acts, whenDefault) in rows:
      let keys = a.keysText(acts, whenDefault)
      if keys.len > 0: result.rows.add (label, keys)
  result[0] = @[
    a.keyRows("File", [
      ("Open file", @[kaOpenFile], ""), ("Load subtitle file", @[kaLoadSubtitle], ""),
      ("Load audio file", @[kaLoadAudio], ""),
      ("Open from clipboard", @[kaOpenClipboard], ""),
      ("Copy to clipboard", @[kaCopyClipboard], ""),
      ("Copy YouTube link at current time", @[kaCopyTimeLink], ""), ("Close", @[kaClose], ""),
      ("Save", @[kaSave], ""), ("Save screenshot", @[kaScreenshot], ""), ("Properties", @[kaProperties], ""),
      ("Exit", @[kaExit], "")]),
    a.keyRows("Playback", [
      ("Play / Pause", @[kaPlayPause], ""), ("Stop", @[kaStop], ""),
      ("Frame forward / back", @[kaFrameForward, kaFrameBack], ""),
      ("Faster / slower playback", @[kaFaster, kaSlower], "Shift+. / Shift+,"),
      ("Repeat forever", @[kaRepeatForever], ""),
      ("Repeat ping-pong", @[kaRepeatPingPong], ""),
      ("Volume up / down", @[kaVolumeUp, kaVolumeDown], ""), ("Mute", @[kaMute], ""),
      ("Next / previous audio track", @[kaNextAudio, kaPrevAudio], ""),
      ("Next / previous subtitle track", @[kaNextSub, kaPrevSub], "")]),
    a.keyRows("Navigate", [
      ("Jump forward / back", @[kaJumpForward, kaJumpBack], ""),
      ("Go to beginning", @[kaGoBeginning], ""),
      ("Jump to 10% ... 90%", @SeekActions, "1 ... 9"),
      ("Next / previous chapter", @[kaNextChapter, kaPrevChapter], ""),
      ("Next / previous file", @[kaNextFile, kaPrevFile], ""),
      ("Add bookmark", @[kaAddBookmark], ""),
      ("Remove selected playlist item", @[kaRemoveFromPlaylist], "")]),
    a.keyRows("Subtitles", [
      ("Align (numpad as a 3x3 grid)",
        @[kaSubBottomLeft, kaSubBottom, kaSubBottomRight, kaSubLeft, kaSubCenter, kaSubRight,
          kaSubTopLeft, kaSubTop, kaSubTopRight], "Shift+Numpad 1 ... 9"),
      ("Move", @SubMoveActions, "Shift+Arrows"),
      ("Bigger / smaller", @[kaSubBigger, kaSubSmaller], "Shift+Numpad + / -")]),
    ("Text fields", @[
      ("Next / previous word", "Ctrl+Right / Ctrl+Left"),
      ("Select next / previous word", "Ctrl+Shift+Right / Left"),
      ("Timestamp: a frame later / earlier", "Up / Down")]),
    ("Drawing a rectangle (Run window)", @[
      ("Confirm / cancel", "Enter / Esc"),
      ("Move by one pixel", "Arrows")]),
    ("Run log", @[("Copy selected text", "Ctrl+C")]),
    ("Playlist (after clicking it)", @[
      ("Select previous / next entry (pointer still over it)", "Up / Down"),
      ("Select all entries", "Ctrl+A"),
      ("Duplicate selected entries", "Ctrl+D"),
      ("Move selected entries up / down", "Ctrl+Shift+Up / Down"),
      ("Move selected entries to top / bottom", "Ctrl+Shift+Home / End")])]
  var view = a.keyRows("View", [
    ("Compact mode", @[kaCompact], ""),
    ("Seek bar", @[kaSeekBar], ""), ("Controls", @[kaControls], ""),
    ("Status", @[kaStatus], ""), ("Playlist", @[kaPlaylist], ""),
    ("Run log", @[kaRunLog], ""), ("Show OSD", @[kaShowOsd], ""),
    ("Full screen", @[kaFullScreen], "")])
  view.rows.add ("Leave full screen / close dialog", "Esc")
  view.rows.add a.keyRows("", [("Options", @[kaOptions], ""),
    ("Keyboard shortcuts", @[kaShortcuts], "")]).rows
  result[1] = @[
    view,
    a.keyRows("Pan, Rotate & Zoom", [
      ("Center", @[kaCenter], ""), ("Move up / down", @[kaMoveUp, kaMoveDown], "Numpad 8 / 2"),
      ("Move left / right", @[kaMoveLeft, kaMoveRight], "Numpad 4 / 6"),
      ("0 degrees", @[kaRotate0], ""),
      ("Rotate clockwise / counter-clockwise", @[kaRotateCw, kaRotateCcw], "Alt+Numpad 6 / 4"),
      ("Restore size", @[kaRestoreSize], ""),
      ("Increase / decrease size", @[kaSizeUp, kaSizeDown], "Ctrl+Numpad 9 / 3"),
      ("Increase / decrease width", @[kaWidthUp, kaWidthDown], "Ctrl+Numpad 6 / 4"),
      ("Increase / decrease height", @[kaHeightUp, kaHeightDown], "Ctrl+Numpad 8 / 2"),
      ("Reset", @[kaPanReset], "")]),
    ("Mouse", @[
      ("Play / Pause", "Click video"), ("Full screen", "Double-click video"),
      ("Move window", "Drag video"), ("Context menu", "Right-click"),
      ("Move playlist column", "Drag column header"),
      ("Resize window (compact mode)", "Drag window edge"),
      ("Volume", "Wheel"), ("Zoom at cursor", "Ctrl+Wheel"),
      ("Restore zoom / panning", "Middle-click video"),
      ("Pan zoomed video", "Ctrl+Drag video"),
      ("Rotate frame (Shift: in Rotate steps)", "Alt+Middle-drag video"),
      ("Reset rotation", "Alt+Middle-click video"),
      ("Rotate around cursor (Shift: in steps)", "Ctrl+Alt+Middle-drag video"),
      ("360° video: look around / move window", "Drag / Ctrl+Drag video"),
      ("360° video: field of view", "Ctrl+Wheel"),
      ("360° video: reset view", "Middle-click video"),
      ("Toggle seek snapping", "Shift+Drag seek bar"),
      ("Repeat options", "Right-click loop button"),
      ("Select word / all in a text field", "Double / Triple-click"),
      ("Step a timestamp field by one frame", "Wheel over it"),
      ("Select run log text / extend selection", "Drag / Shift+Click run log"),
      ("Add or remove a playlist entry from the selection", "Ctrl+Click playlist"),
      ("Select playlist entries up to the clicked one", "Shift+Click playlist"),
      ("Select word / whole run log", "Double / Triple-click run log"),
      ("Draw on video / keep value (Run window)", "Click / Right-click rectangle icon"),
      ("Draw, resize or move the rectangle", "Drag video / its side / inside it")])]
  for col in result.mitems:
    col.keepItIf(it.rows.len > 0)

proc shortcutsOverlay(a: App) =
  let ui = a.ui
  const
    RowH = 21'f32
    HeadH = 32'f32
    ColW = 420'f32
    ColGap = 32'f32
    Pad = 24'f32
  let columns = a.shortcutColumns
  var colH = 0'f32
  for col in columns:
    var h = 0'f32
    for g in col: h += HeadH + g.rows.len.float32 * RowH
    colH = max(colH, h)
  let r = a.overlayFrame("Keyboard Shortcuts",
    vec2(Pad * 2 + ColW * 2 + ColGap, 60 + colH + Pad - 8))
  for ci, col in columns:
    let x = r.x + Pad + ci.float32 * (ColW + ColGap)
    var y = r.y + 58
    for g in col:
      ui.textIn(g.title, rect(x, y, ColW, 24), colAccent)
      ui.rect(rect(x, y + 25, ColW, 1), colBorder)
      y += HeadH
      for (k, v) in g.rows:
        let vw = ui.textSize(v, FontSmall).x
        ui.textIn(k, rect(x, y, ColW - vw - 12, RowH), colText, FontSmall)
        ui.textIn(v, rect(x + ColW - vw - 2, y, vw + 2, RowH), colTextDim, FontSmall, h = RightAlign)
        y += RowH

proc aboutOverlay(a: App) =
  let ui = a.ui
  let r = a.overlayFrame("About", vec2(420, 260))
  ui.icon("crown96", vec2(r.x + r.w / 2, r.y + 110), colAccent)
  ui.textIn(AppName & " " & AppVersion, rect(r.x, r.y + 160, r.w, 26), colText, h = CenterAlign)
  ui.textIn("Built with Nim, Silky and libmpv " & a.player.h.getStr("mpv-version").replace("mpv ", ""),
    rect(r.x, r.y + 188, r.w, 22), colTextDim, FontSmall, h = CenterAlign)

# --- frame ------------------------------------------------------------------

proc frame(a: App) =
  let w = a.window
  let ui = a.ui
  let fb = w.size
  if fb.x <= 0 or fb.y <= 0: return

  a.applyUiScale()
  ui.beginFrame()
  let (root, ctxRoot) = a.buildMenu()

  # Layout
  let fs = a.fullscreen
  let bottomH = a.bottomHeight
  let menuH = a.menuBarHeight
  let W = ui.size.x
  let H = ui.size.y
  let plW = if a.cfg.showPlaylist: min(a.playlistWidth, W) else: 0
  # The run log spans the window's width under the menu bar (in full screen,
  # over the top of the video).
  let rlH = if a.cfg.showRunLog: min(a.runLogHeight, max(0'f32, H - menuH - bottomH)) else: 0
  let rlRect = rect(0, menuH, W, rlH)
  let top = menuH + rlH
  let videoArea =
    if fs: rect(0, 0, W, H)
    else: rect(0, top, max(0'f32, W - plW), max(0'f32, H - top - bottomH))
  a.videoRect = videoArea
  let revealZone = H - bottomH - 48
  let mouseIn = ui.fakeMouse.x >= 0 or w.mouseInside
  let bottomVisible = not fs or ui.mouse.y >= revealZone and mouseIn or
    a.seekDragging or ui.activeId == "volume" or
    a.menus.contextOpen and a.ctxMenu == cmQuality  # over its gear button
  let bottomRect = rect(0, H - bottomH, W, bottomH)
  let plRect =
    if fs: rect(W - plW, rlH, plW, (if bottomVisible: H - bottomH else: H) - rlH)
    else: rect(W - plW, top, plW, H - top - bottomH)

  # Input capture order: overlays and a Run window rectangle being drawn >
  # menus > everything else.
  if a.overlay != ovNone or a.rectEdit != nil:
    ui.captured = true
  else:
    a.menus.captureInput(ui)

  # GL video pass (beneath the UI).
  a.sk.beginUi(w, fb)
  glViewport(0, 0, fb.x, fb.y)
  glClearColor(colBackground.r.float32 / 255, colBackground.g.float32 / 255,
    colBackground.b.float32 / 255, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  a.drawVideo(a.px(videoArea), fb)
  a.idleScreen(videoArea)
  a.ownOsdMsg(videoArea)

  # Compact mode: dragging the window's outer pixels resizes it.
  let edge = if a.overlay == ovNone and not a.menus.isOpen and a.rectEdit == nil and
                ui.activeId == "" and w.mouseInside: a.frameEdgeAt(ui.mouse)
             else: {}
  for e in edge:
    if ui.pressed():
      ui.consumeClick()
      w.startWindowResize(e)

  # A Run window rectangle being drawn over the video.
  let overVideo = ui.mouse.inside(videoArea) and
    not (fs and bottomVisible and ui.mouse.y >= H - bottomH) and
    not (a.cfg.showPlaylist and ui.mouse.inside(plRect)) and
    not (a.cfg.showRunLog and ui.mouse.inside(rlRect))
  if a.rectEdit != nil:
    let err = a.rectBlocker
    if err.len > 0:
      a.osd(err)
      a.endRectDraw(false)
  if a.rectEdit != nil:
    let m = a.videoMap
    if a.rectEdit.update(m, ui.mouse, overVideo and w.buttonPressed[MouseLeft],
                         w.buttonDown[MouseLeft]):
      a.applyRect()
    ui.sk.pushClipRect(videoArea)
    a.rectEdit.draw(ui, m, videoArea, a.pickDlg.cmd.parts.rectNumber(a.rectEdit.rect))
    ui.sk.popClipRect()

  # Video-frame mouse handling: click = play/pause, drag = move window.
  if ui.hover(videoArea) and not (fs and bottomVisible and ui.mouse.y >= H - bottomH) and
     not (a.cfg.showPlaylist and ui.mouse.inside(plRect)) and
     not (a.cfg.showRunLog and ui.mouse.inside(rlRect)):
    if ui.pressed() and w.ctrl and not a.player.isSpherical and
       a.rectEdit == nil and a.canPan(a.px(videoArea)):
      a.panDrag = true
      a.panFrom = ui.mouse * a.sk.uiScale
      a.panStart = a.xf.pan
    elif ui.pressed():
      a.videoPress = true
      a.videoPressPos = ui.mouse
    if a.window.buttonPressed[DoubleClick]:
      a.setFullscreen(not a.fullscreen)
      a.videoPress = false
    if ui.released(MouseRight):
      a.ctxMenu = cmVideo
      a.menus.openContext(ui.mouse)
    if ui.scroll() != 0 and not (a.cfg.showPlaylist and ui.mouse.inside(plRect)):
      # Unfocused, the keyboard (and Ctrl) goes elsewhere: ask the system.
      let ctrl = w.ctrl or (not w.focused and ctrlHeld())
      if ctrl and a.player.isSpherical: a.changeFov(ui.wheelNotches)
      elif ctrl: a.zoomAt(a.px(videoArea), ui.mouse * a.sk.uiScale, ui.wheelNotches)
      else: a.volumeStep(ui.scroll() < 0)
      ui.scrollConsumed = true
    if ui.pressed(MouseMiddle) and a.player.isSpherical:
      a.resetLook(); a.osd("View reset")
    elif ui.pressed(MouseMiddle) and w.alt:
      a.beginRotate(a.px(videoArea), ui.mouse * a.sk.uiScale, w.ctrl)
    elif ui.pressed(MouseMiddle) and (a.xf.zoom != 1 or a.xf.pan != vec2(0, 0)):
      a.xf.zoom = 1; a.xf.pan = vec2(0, 0); a.xfChanged("Zoom: 100%")
  if a.rotDrag:
    if not ui.down(MouseMiddle):
      a.rotDrag = false
      if not a.rotMoved:  # Alt+Middle-click
        a.xf.rotation = 0; a.xfChanged("Rotation: 0°")
    else: a.rotateDrag(a.px(videoArea), ui.mouse * a.sk.uiScale, w.shift)
  if a.panDrag:
    if not ui.down(): a.panDrag = false
    else: a.panDragTo(a.px(videoArea), ui.mouse * a.sk.uiScale)
  if a.videoPress:
    if not ui.down():
      a.videoPress = false
      if ui.window.buttonReleased[MouseLeft]:
        a.togglePlay()
    elif (ui.mouse - a.videoPressPos).length > 4:
      a.videoPress = false
      # 360° view: a drag looks around, Ctrl+drag moves the window (or the
      # other way round, from the frame's context menu). Full screen only looks.
      if a.player.isSpherical and (fs or w.ctrl == a.cfg.sphereDragMovesWindow):
        a.lookDragging = true
        a.lookLast = a.videoPressPos
        a.lookDrag(ui.mouse)
      elif not fs: w.startWindowDrag()
  if a.lookDragging:
    if not ui.down() or not a.player.isSpherical: a.lookDragging = false
    else: a.lookDrag(ui.mouse)

  # Chrome
  if w.buttonPressed[MouseLeft] or w.buttonPressed[MouseRight]:
    a.plFocused = a.cfg.showPlaylist and ui.mouse.inside(plRect)
    a.plArrows = a.plFocused
  if not (a.cfg.showPlaylist and ui.mouse.inside(plRect)): a.plArrows = false
  if a.cfg.showPlaylist: a.playlistPanel(plRect)
  else: a.plListRect = Rect()
  if a.cfg.showRunLog: a.runLogPanel(rlRect)
  if bottomVisible and bottomH > 0:
    var y = H - bottomH
    if a.cfg.showSeekBar:
      a.seekBar(rect(0, y, W, SeekBarHeight)); y += SeekBarHeight
    if a.cfg.showControls:
      a.controls(rect(0, y, W, ControlsHeight)); y += ControlsHeight
    if a.cfg.showStatus:
      a.status(rect(0, y, W, StatusHeight))
    if bottomRect.h > 0 and ui.hover(bottomRect) and ui.scroll() != 0:
      a.volumeStep(ui.scroll() < 0)
      ui.scrollConsumed = true
  else:
    a.showPreview = false
    a.seekDragging = false
  if menuH > 0:
    a.menus.drawBar(ui, root, rect(0, 0, W, MenuBarHeight))

  # Overlays draw on the popup layer with the mouse released to them.
  if a.overlay != ovNone:
    ui.captured = false
    ui.sk.pushLayer(PopupsLayer)
    case a.overlay
    of ovOptions:  # its own window; clicks here bring it back up
      if ui.pressed(): a.optWin.activate()
    of ovRename:
      if ui.pressed(): a.renWin.activate()
    of ovCommands:
      if ui.pressed(): a.cmdWin.activate()
    of ovSync:
      if ui.pressed(): a.syncWin.activate()
    of ovYtdlp:
      if ui.pressed(): a.ytWin.activate()
    of ovEmbed:
      if ui.pressed(): a.embWin.activate()
    of ovUpdate:
      if ui.pressed(): a.upWin.activate()
    of ovProperties: a.propertiesOverlay()
    of ovShortcuts: a.shortcutsOverlay()
    of ovAbout: a.aboutOverlay()
    of ovNone: discard
    ui.sk.popLayer()
    if ui.pressed() and a.overlay != ovNone: ui.consumeClick()
  else:
    ui.captured = false
    a.menus.updatePopups(ui, root, ctxRoot)
    ui.drawTooltip()
  ui.sk.pushLayer(PopupsLayer)
  a.compactOutline(rect(0, 0, W, H))
  a.syncOutline(rect(0, 0, W, H))
  ui.sk.popLayer()

  # Cursor auto-hide over playing video.
  if ui.mouse != a.lastMouse:
    a.lastMouse = ui.mouse
    a.lastMouseMove = now()
  let hide = a.player.playing and a.player.hasVideo and
    ui.mouse.inside(videoArea) and not a.menus.isOpen and a.overlay == ovNone and
    not (a.cfg.showRunLog and ui.mouse.inside(rlRect)) and
    not (fs and bottomVisible) and now() - a.lastMouseMove > 1.0
  let resize = ui.activeId == "plresize" or a.cfg.showPlaylist and
    ui.hover(rect(plRect.x, plRect.y, PlaylistGripW, plRect.h)) and a.overlay == ovNone and
    not a.menus.isOpen
  let resizeV = ui.activeId == "rlresize" or a.cfg.showRunLog and
    ui.hover(rect(0, rlRect.y + rlRect.h - RunLogGripH, W, RunLogGripH)) and
    a.overlay == ovNone and not a.menus.isOpen
  let overLog = ui.activeId == "rlselect" or a.cfg.showRunLog and a.runLog.len > 0 and
    ui.hover(rect(rlRect.x, rlRect.y + RunLogHeaderH, rlRect.w - RunLogBarW - 4,
      rlRect.h - RunLogHeaderH - RunLogGripH)) and a.overlay == ovNone and not a.menus.isOpen
  var shape = if edge * {weLeft, weRight} != {}: ptResize
              elif edge * {weTop, weBottom} != {}: ptResizeV
              elif edge * {weTopLeft, weBottomRight} != {}: ptResizeNWSE
              elif edge != {}: ptResizeNESW
              elif hide: ptHidden elif resize: ptResize elif resizeV: ptResizeV
              elif overLog: ptText
              elif ui.activeId == "plcolumn" and a.plColumnFrom.moved: ptMoving
              else: ptArrow
  if a.rectEdit != nil and (overVideo or w.buttonDown[MouseLeft]):
    shape = case a.rectEdit.cursorAt(a.videoMap, ui.mouse)
      of rcCross: ptCross
      of rcMove: ptMove
      of rcMoving: ptMoving
      of rcResizeH: ptResize
      of rcResizeV: ptResizeV
      of rcResizeNWSE: ptResizeNWSE
      of rcResizeNESW: ptResizeNESW
  if shape != a.pointerShape:
    a.pointerShape = shape
    if shape in {ptResizeNWSE, ptResizeNESW}:
      # Windy has no diagonal cursors.
      w.setDiagonalCursor(nwse = shape == ptResizeNWSE)
    else:
      w.clearDiagonalCursor()
      w.cursor = case shape
        of ptHidden: hiddenCursor()
        of ptResize: Cursor(kind: ResizeLeftRightCursor)
        of ptResizeV: Cursor(kind: ResizeUpDownCursor)
        of ptCross: Cursor(kind: CrosshairCursor)
        of ptMove: Cursor(kind: OpenHandCursor)
        of ptMoving: Cursor(kind: ClosedHandCursor)
        of ptText: Cursor(kind: IBeamCursor)
        of ptArrow, ptResizeNWSE, ptResizeNESW: Cursor(kind: ArrowCursor)

  a.sk.endUi()
  a.drawPreview(fb)
  ui.endFrame()
  let shot = a.shotPath
  if shot.len > 0:
    readFramebuffer(fb).writeFile(shot)
    a.shotPath = ""
  w.swapBuffers()
  mpv_render_context_report_swap(a.player.render)
  # Menu popups live in their own windows. Draw them only after the main swap:
  # pointing the context at another drawable discards the main back buffer.
  a.menus.renderPopups(ui, if shot.len == 0: nil else:
    proc (level: int, image: Image) =
      image.writeFile(shot.changeFileExt("") & &"-menu{level}.png"))
  a.renderOptions(shot)
  a.renderRename(shot)
  a.renderCommands(shot)
  a.renderPick(shot)
  a.renderSyncProps(shot)
  a.renderYtdlp(shot)
  a.renderEmbed(shot)
  a.renderUpdate(shot)
  a.renderEqualizer(shot)

# --- setup & main loop --------------------------------------------------------

proc keyUi(a: App): Ui =
  ## The Ui of the window taking the keyboard.
  case a.overlay
  of ovOptions: a.optUi
  of ovRename: a.renUi
  of ovCommands: a.cmdUi
  of ovSync: a.syncUi
  of ovYtdlp: a.ytUi
  of ovEmbed: a.embUi
  of ovUpdate: a.upUi
  else: (if a.pickOpen: a.pickUi else: a.ui)

proc runScriptStep(a: App, st: ScriptStep) =
  let arg = st.args.join(" ")
  case st.cmd
  of "open": a.openPaths(@[arg])
  of "menu":
    var path: seq[int]
    for x in st.args[1 .. ^1]: path.add parseInt(x)
    a.menus.openBar(parseInt(st.args[0]), path)
  of "ctx":  # x y [seek]: the seek bar's menu, else the video's
    let pos = vec2(parseFloat(st.args[0]), parseFloat(st.args[1]))
    if st.args.len > 2: a.seekBarContext(pos)
    else: a.ctxMenu = cmVideo; a.menus.openContext(pos)
  of "plctx": a.ctxMenu = cmPlaylist; a.menus.openContext(vec2(parseFloat(st.args[0]), parseFloat(st.args[1])))
  of "colctx":  # x y field: the playlist header's menu, as right-clicking that column
    a.ctxColumn = parseEnum[PlaylistField](st.args[2])
    a.ctxMenu = cmPlaylistColumns
    a.menus.openContext(vec2(parseFloat(st.args[0]), parseFloat(st.args[1])))
  of "sbctx": a.seekBarContext(vec2(parseFloat(st.args[0]), parseFloat(st.args[1])))
  of "plselect": a.selectOnly(parseInt(arg))
  of "plaction":  # playlist context menu item by label
    a.ctxMenu = cmPlaylist
    for n in a.buildMenu().context.children:
      if n.label == arg and n.enabled and n.action != nil: n.action()
    a.ctxMenu = cmVideo
  of "ctxaction":  # video frame context menu item by label (top level)
    a.ctxMenu = cmVideo
    for n in a.buildMenu().context.children:
      if n.label == arg and n.enabled and n.action != nil: n.action()
  of "pldump": stderr.writeLine "playlist ", a.plIndex, " ", $a.playlist.mapIt(it.extractFilename)
  of "close": a.menus.close()
  of "mouse":
    a.ui.fakeMouse = if arg == "off": vec2(-1, -1)
                     else: vec2(parseFloat(st.args[0]), parseFloat(st.args[1]))
  of "mods": a.fakeMods = if arg == "off": "" else: arg
  of "hintscroll": a.hintScroll = parseFloat(arg)  # status bar key hints, clamped when drawn
  of "optpage":
    a.ensureOptionsWindow()
    for p in OptionsPage:
      if ($p).toLowerAscii.startsWith(arg.toLowerAscii): a.optionsDlg.selectPage(a.optUi, p)
  of "optkey":  # id [combo]: Options > Keys; gives the command combo ("none" clears), else asks for a key
    for act in KeyAction:
      if $act == st.args[0]:
        if st.args.len > 1:
          let k = if st.args[1] == "none": KeyCombo() else: parseCombo(st.args[1 .. ^1].join(" "))
          a.optionsDlg.assignKeys(a.cfg, act, if k.key == ButtonUnknown: @[] else: @[k])
        else: a.optionsDlg.startCapture(a.optUi, act)
  of "key":  # combo: runs the command bound to it, as pressing it would
    let k = parseCombo(arg)
    for act in KeyAction:
      if k in a.cfg.combos(act):
        a.runAction(act)
        break
  of "focus": a.keyUi.focusId = arg
  of "type": a.keyUi.typedPending.add arg
  of "overlay":
    a.showOverlay(case arg
      of "options": ovOptions
      of "properties": ovProperties
      of "shortcuts": ovShortcuts
      of "about": ovAbout
      else: ovNone)
  of "commands": a.showCommands()
  of "equalizer": a.toggleEqualizer()  # the Equalizer window, shown or hidden
  of "eq":  # on | off | save | unsave | band gain: as the Equalizer window's controls do
    var (on, gains) = a.equalizer
    case arg
    of "on", "off": a.changeEqualizer(arg == "on", gains)
    of "save", "unsave": a.rememberEqualizer(arg == "save")
    else:
      gains[parseInt(st.args[0])] = parseFloat(st.args[1])
      a.changeEqualizer(on, gains)
  of "eqdump": stderr.writeLine "eq ", a.equalizer, " saved=", a.eqSaved, " af=", a.player.h.getStr("af")
  of "cmdcard":  # name [value|reference [content]]: a card at the caret
    let kind = if st.args.len > 1 and st.args[1] == "reference": ckReference else: ckValue
    a.cmdDlg.addCard(st.args[0], kind, if st.args.len > 2: st.args[2 .. ^1].join(" ") else: "")
  of "cmdrect":  # name rect dim [default]: a rectangle card at the caret
    a.cmdDlg.addCard(st.args[0], ckValue, if st.args.len > 3: st.args[3] else: "",
      parseInt(st.args[1]), parseEnum[RectDim](st.args[2]))
  of "cmdpath":  # name reveal(0|1) [default]: a path card at the caret
    a.cmdDlg.addCard(st.args[0], ckValue, if st.args.len > 2: st.args[2 .. ^1].join(" ") else: "",
      path = true, reveal = st.args[1] == "1")
  of "cmdapply": a.cmdDlg.applyRequested = true
  of "run": a.runMenuPath(@["Run", arg])
  of "runstop": (for e in a.runLog: e.stop())  # the run log's Stop button
  of "pick":  # row index: choose a time (0-based, separators count) in the Run window
    a.pickDlg.choose(parseInt(st.args[0]), a.timeChoices, parseInt(st.args[1]))
  of "pickrun": a.pickDlg.runRequested = true
  of "picktext":  # row text: a value for this run
    a.pickDlg.texts[parseInt(st.args[0])] = st.args[1 .. ^1].join(" ")
  of "pickopen": a.pickDlg.openRow = parseInt(arg)
  of "pickdraw": a.beginRectDraw(a.pickDlg.rows[parseInt(arg)].rect)  # row: its rectangle icon
  of "pickbrowse": a.browsePickPath(parseInt(arg))  # row: its folder button
  of "pickcross": a.pickDlg.crossed[parseInt(arg)] = not a.pickDlg.crossed[parseInt(arg)]
  of "rectset":  # x y w h: the rectangle being drawn
    if a.rectEdit != nil:
      a.rectEdit.seed(parseInt(st.args[0]), parseInt(st.args[1]), parseInt(st.args[2]),
        parseInt(st.args[3]), a.videoMap)
      a.applyRect()
  of "rectend": a.endRectDraw(arg == "1")  # 1 keeps the rectangle, 0 goes back
  of "action": a.runMenuPath(arg.split('/'))
  of "dialogresult": a.handleDialogResult(st.args[0], @[st.args[1 .. ^1].join(" ")])  # purpose path
  of "fs": a.setFullscreen(arg == "1")
  of "subs":  # alignX alignY dx dy scale
    a.subs = SubLayout(alignX: parseInt(st.args[0]), alignY: parseInt(st.args[1]),
      offset: vec2(parseFloat(st.args[2]), parseFloat(st.args[3])), scale: parseFloat(st.args[4]))
  of "seek": a.seekTo(parseFloat(arg))
  of "bmadd": a.addBookmark(parseFloat(arg))
  of "bmedit": a.showRename(parseInt(arg))  # index: Edit Bookmark for the current file's nth bookmark
  of "bmpreview": a.cfg.bookmarkPreview = arg == "1"
  of "bmtime": a.renMoveTo(parseTime(arg))  # as if typed into Edit Bookmark's Time field
  of "bmstep":  # n: frames, as the wheel over Edit Bookmark's Time field steps
    let fps = a.frameRate(a.renPath)
    a.renMoveTo(a.renTime + parseFloat(arg) * (if fps > 0: 1 / fps else: 0.1))
  of "bmcancel": a.closeRename()
  of "bmdump": stderr.writeLine "bm ", a.fileBookmarks.mapIt(it.time), " ren=", a.renTime,
    " text=", a.renTimeText, " pos=", a.player.timePos
  of "abloop":  # a b: sets both loop marks, starting the loop
    a.setLoopMark(false, parseFloat(st.args[0]))
    a.setLoopMark(true, parseFloat(st.args[1]))
  of "look":  # yaw pitch fov: the 360° camera, degrees
    (a.lookYaw, a.lookPitch, a.lookFov) = (parseFloat(st.args[0]).float32,
      parseFloat(st.args[1]).float32, parseFloat(st.args[2]).float32)
  of "pause": a.togglePlay()
  of "frame": a.frameStep(arg == "1")  # 1 forward, 0 back
  of "sync":  # all | none | add <pid> | remove <pid> | addany (first peer found)
    if arg == "addany":
      if a.peers != nil and a.peers.peers.len > 0: a.syncRequest("add", a.peers.peers[0].pid)
    else: a.syncRequest(st.args[0], if st.args.len > 1: parseInt(st.args[1]) else: 0)
  of "syncprops": a.showSyncProps()  # Synchronize > Properties
  of "syncmaster":  # pid master: the Properties window's Master (pid 0: this player; p: the first peer)
    let v = st.args.mapIt(if it == "p": a.peers.peers[0].pid else: parseInt(it))
    a.setMasterOf(if v[0] == 0: a.peers.pid else: v[0], v[1])
  of "syncselect":  # index [open]: select the Properties window's nth player, opening its Master list
    let all = a.syncInstances
    a.syncDlg.selected = all[parseInt(st.args[0])].pid
    a.syncDlg.listOpen = st.args.len > 1
  of "syncfollow":  # offset loop: this player's settings as a slave
    a.setFollow(parseFloat(st.args[0]), st.args[1] == "1")
  of "syncdump":
    if a.peers == nil: return
    stderr.writeLine "sync ", a.peers.pid, " master=", a.syncMaster, " members=", $a.syncMembers,
      " offset=", a.followOffset, " loop=", a.followLoop, " clock=", a.masterNow,
      " peers=", $a.peers.peers.mapIt((it.pid, it.title, it.master, it.offset, it.loop)),
      " playlist=", $a.playlist.mapIt(it.extractFilename), " index=", a.plIndex,
      " path=", a.player.path.extractFilename, " t=", a.player.timePos,
      " paused=", a.player.paused, " stopped=", a.player.stopped, " speed=", a.player.speed
  of "size": a.window.size = ivec2(parseInt(st.args[0]).int32, parseInt(st.args[1]).int32)
  of "shot": a.shotPath = arg
  of "quit": a.window.closeRequested = true
  of "uiscale": a.cfg.uiScale = parseFloat(arg)  # percent, as Options sets it
  of "set": a.player.h.setProp(st.args[0], st.args[1 .. ^1].join(" "))
  of "ytdlp": a.ytAnswer(arg == "1")  # 1 | 0: the yt-dlp window's Install/Update or Cancel
  of "embed":  # keep | clear | install | 0: the Embed As MKV Chapters window's buttons
    if arg == "show": a.showEmbed()
    else: a.embAnswer(arg != "0", arg == "clear")
  of "update": a.checkForUpdates()  # Help > Check for Updates
  of "updanswer": a.upAnswer(arg == "1")  # 1 | 0: its Update or Not now/Cancel/Close
  of "updump":
    let p = a.player
    stderr.writeLine "update version=", AppVersion, " mode=", a.upMode, " overlay=", a.overlay,
      " status=", a.upStatus, " latest=", (if a.upJob != nil: a.upJob.version else: ""),
      " msg=", a.upMsg, " playlist=", a.playlist.len, " index=", a.plIndex,
      " selected=", a.plSelected, " path=", p.path, " time=", p.timePos.formatFloat(ffDecimal, 1),
      " paused=", p.paused, " stopped=", p.stopped, " speed=", p.speed,
      " aid=", p.selectedTrack("audio"), " sid=", p.selectedTrack("sub"),
      " loop=", a.hasLoopA, "/", a.hasLoopB, "/", a.abLoop, " ", a.loopA, "-", a.loopB,
      " fs=", a.fullscreen, " zoom=", a.xf.zoom, " size=", a.window.size
  of "embdump":
    stderr.writeLine "embed mode=", a.embMode, " overlay=", a.overlay, " msg=", a.embMsg,
      " status=", a.mkvStatus, " exe=", findMkvpropedit(a.cfg.mkvpropedit), " marks=", a.fileBookmarks.len,
      " chapters=", a.player.chapters.len, " running=", a.embProc != nil
  of "quality":  # the quality button's menu, as clicking it opens it
    a.ctxMenu = cmQuality
    a.menus.openContext(a.qualityRect.xy, sticky = true, keep = a.qualityRect, above = true)
  of "qpick":  # video audio: the quality menu's picks, format ids ("-": Auto)
    let f = st.args.mapIt(if it == "-": "" else: it)
    a.pickQuality(a.player.path, f[0], f[1])
  of "qlang":  # a language's code: Audio Track's pick of it
    a.pickLang(a.player.path, arg)
  of "qlock":  # Video|Audio label: clicks the lock of the quality menu's item
    let was = a.ctxMenu
    a.ctxMenu = cmQuality
    let (_, qm) = a.buildMenu()
    a.ctxMenu = was
    let label = st.args[1 .. ^1].join(" ")
    for col in qm.children:
      if col.label == st.args[0]:
        for it in col.children:
          if it.label == label and it.lock != nil: it.lock()
  of "qdump":
    stderr.writeLine "quality open=", a.menus.contextOpen and a.ctxMenu == cmQuality,
      " pick=", a.ytPick.getOrDefault(a.player.path),
      " found=", a.ytQualities.getOrDefault(a.player.path),
      " format=", a.player.h.getStr("ytdl-format"), " h=", a.player.videoH,
      " acodec=", a.player.h.getStr("audio-codec-name"),
      " pos=", a.player.timePos, " paused=", a.player.paused,
      " button=", a.qualityRect, " menu=", a.menus.contextRect,
      " playing=", a.playFormat.getOrDefault(a.player.path), " auto=", a.ytAuto.getOrDefault(a.player.path),
      " wants=", a.wants(a.player.path), " rows=", $a.audioRows(a.player.path).mapIt(it.label),
      " aid=", a.player.selectedTrack("audio"), " locks=", (a.cfg.streamLockVideo, a.cfg.streamLockAudio),
      " holding=", a.holding, " opening=", a.player.opening, " source=", a.player.source.len > 0,
      " segs=", $a.saved.lookup(a.player.path).segs.mapIt(&"{it.start:.0f}..{it.stop:.0f}:{it.format}")
  of "ytdump":
    stderr.writeLine "ytdlp status=", a.ytStatus, " mode=", a.ytMode, " overlay=", a.overlay,
      " opening=", a.player.opening, " loaded=", a.player.loaded, " path=", a.player.path,
      " err=", a.player.loadError, " yterr=", a.ytError, " tries=", a.ytTries,
      " hooked=", a.ytHooked,
      " versions=", a.ytCurrent, "/", a.ytLatest, " msg=", a.ytMsg,
      " buffered=", a.player.buffered, " chapters=", a.player.chapters.len,
      " subs=", a.player.tracks.countIt(it.kind == "sub")
  of "saveto":  # path: File > Save, the dialog answered
    a.saveSrc = a.player.path
    a.startSave(arg)
  of "webdump":  # the open link's saved part, its saving and the standby going online
    let p = a.player
    let s = a.saved.lookup(a.ytCurrentLink)
    stderr.writeLine "web t=", p.timePos.formatFloat(ffDecimal, 3), " dur=", p.duration,
      " source=", p.source.len > 0, " part=", p.partStart, "..", p.partEnd,
      " stopped=", p.stopped, " paused=", p.paused, " dumping=", p.dumping,
      " rec=", (if a.recUrl.len > 0: $a.rec.start & ".." & $a.rec.stop else: "-"),
      " sb=", a.sbState, " handoff=", a.sbHandoff, " saved=", s.covered, "/", s.duration,
      " segs=", s.segs.len, " subs=", s.subs.len, " subsDone=", s.subsDone,
      " tracks=", p.tracks.mapIt(it.kind & $it.id & (if it.selected: "*" else: "")).join(",")
  of "dump":
    for prop in st.args:
      stderr.writeLine "dump ", prop, " = ", a.player.h.getStr(prop)
  else: stderr.writeLine "script: unknown command ", st.cmd

proc main() =
  discard setlocale(LC_NUMERIC, "C")
  when defined(windows): attachStdio()
  let a = App(plIndex: -1, plSelected: -1, optionsDlg: newOptionsDialog(),
    cmdDlg: newCmdDialog(), pickDlg: newPickDialog())
  a.cfg = loadConfig()
  discard a.cfg.reloadRecent()
  a.script = loadScript()
  randomize()
  let params = commandLineParams()
  let files = params.stripRenderArgs.filterIt(it != ResumeArg).mapIt(
    if it.contains("://"): it else: it.absolutePath)
  # Restarted into an update: what it was doing comes back.
  let (resumed, rs) = if ResumeArg in params: takeResume() else: (false, ResumeState())
  removeOld()
  # Debug scripts must not hand their files to (or take files from) a real
  # player the user has open.
  let scripted = a.script.steps.len > 0
  if files.len > 0 and a.cfg.openMode == omSamePlayer and not scripted and
     forwardToRunning(files):
    return
  if not scripted: a.instance = startServer()
  # Debug scripts only see other players in a folder of their own.
  if not scripted or existsEnv("MMP_SYNC_DIR"): a.peers = startPeerNet()
  a.positions = loadPositions()
  a.subScales = loadSubScales()
  a.bookmarks = loadBookmarks()
  a.equalizers = loadEqualizers()
  if a.cfg.seedPresets(): a.cfg.save()
  a.commands = loadCommandLines()
  if a.cfg.rememberTransform:
    let t = a.cfg.transform
    a.xf = VideoTransform(pan: vec2(t.panX, t.panY), rotation: t.rotation,
      zoom: t.zoom, scaleX: t.scaleX, scaleY: t.scaleY)
  # vsync off: under XWayland the NVIDIA driver can block glXSwapBuffers for
  # whole seconds when KWin withholds frame callbacks (hidden/occluded window),
  # freezing UI and video. The compositor presents our buffers tear-free, mpv
  # paces video frames, and UI-only redraws are rate-capped in the main loop.
  let c = a.cfg
  let minSize = if c.compactMode: MinCompactWindow else: MinWindow
  let startSize =
    if c.rememberWindowSize and c.windowW >= minSize.x and c.windowH >= minSize.y:
      ivec2(c.windowW.int32, c.windowH.int32)
    else: ivec2(1024, 640)
  # Ties the window to majestic-media-player.desktop (taskbar icon, audio
  # stream matching), whatever the binary is called.
  when defined(linux): x11ClassName = "majestic-media-player"
  try:
    a.window = newWindow(AppName, startSize, vsync = false)
    makeContextCurrent(a.window)
    loadExtensions()
    if glGetString(GL_VERSION) == nil: raise newException(ValueError, "no OpenGL context")
  except CatchableError as e:
    # The GPU couldn't open the window (its memory full, say): the CPU can.
    if cpuWanted: raise
    stderr.writeLine "GPU rendering failed (", e.msg, "): starting on the CPU"
    if resumed: rs.save()  # taken: for the restart to take
    a.instance.close()
    a.peers.close()
    try:
      startProcess(getAppFilename(), args = params.stripRenderArgs & (RenderArg & "cpu"),
        options = {poParentStreams, poDaemon}).close()
    except OSError as e: stderr.writeLine "cannot restart: ", e.msg
    return
  a.window.icon = appIcon()
  a.window.initMainWindow()
  if c.compactMode: a.window.setDecorated(false)
  when defined(windows): setDialogOwner(a.window.getHWND)
  a.window.disableVsync()
  if c.rememberWindowPos and c.windowW > 0:
    # Only onto a monitor that still exists.
    let p = ivec2(c.windowX.int32, c.windowY.int32)
    let m = monitorAt(p + ivec2(40, 40))
    if p.x + 40 >= m.pos.x and p.y + 40 >= m.pos.y and
       p.x + 40 < m.pos.x + m.size.x and p.y + 40 < m.pos.y + m.size.y:
      a.window.moveFrame(p)
  if resumed:
    if rs.windowW >= minSize.x and rs.windowH >= minSize.y:
      a.window.size = ivec2(rs.windowW.int32, rs.windowH.int32)
      a.window.moveFrame(ivec2(rs.windowX.int32, rs.windowY.int32))
    if rs.maximized: a.window.maximized = true
    let t = rs.transform
    a.xf = VideoTransform(pan: vec2(t.panX, t.panY), rotation: t.rotation,
      zoom: t.zoom, scaleX: t.scaleX, scaleY: t.scaleY)

  let scale = a.uiScale
  let (img, atlas) = buildAtlas(scale)
  (a.atlasImg, a.atlas) = (img, atlas)
  a.sk = newSilky(a.window, img, atlas)
  a.sk.uiScale = scale
  a.sk.atlasScale = scale
  a.ui = newUi(a.sk, a.window)
  a.window.setAspectHints(0, ivec2(0, 0), a.minWindow)
  a.menus = newMenuSystem()
  a.quad = newQuadRenderer()

  a.player = newPlayer(a.cfg.volume, a.cfg.muted, a.cfg.showOsd)
  removeDownloads()
  setSaveDir(a.cfg.webDir.expandPath)
  a.saved = loadSaveIndex()
  a.linkInfos = loadLinkInfos()
  a.pruneSaved()
  a.player.initRender()
  a.applyLoop()
  a.syncSettings()
  try:
    a.standby = newPlayer(a.cfg.volume, true, a.cfg.showOsd)
    a.standby.hidden = true
    a.standby.initRender()
  except MpvError as e:
    stderr.writeLine "seamless loops disabled: ", e.msg
    a.standby = nil
  a.hookYtdlp()
  try:
    a.lsound = newLoopSound(a.cfg.volume)
  except MpvError as e:
    stderr.writeLine "seamless loop sound disabled: ", e.msg
    a.lsound = nil
  try:
    a.preview = newPreview()
    if a.preview != nil: a.preview.initRender()
  except MpvError as e:
    stderr.writeLine "seek preview disabled: ", e.msg
    a.preview = nil
  try:
    a.osdLayer = newOsdLayer()
    a.osdLayer.initRender()
  except MpvError as e:
    stderr.writeLine "OSD layer disabled (OSD follows pan/rotate/zoom): ", e.msg
    a.osdLayer = nil

  # Any input schedules redraws for a short while (hover effects, tooltips).
  let touch = proc () = a.dirtyUntil = now() + 1.2
  a.window.onMouseMove = touch
  a.window.onScroll = proc () =
    touch()
    a.inputPending = true
  a.window.onButtonPress = proc (b: Button) =
    touch()
    a.inputPending = true
  a.window.onButtonRelease = proc (b: Button) =
    touch()
    a.inputPending = true
  a.window.onResize = proc () = touch()
  a.window.onRune = proc (r: Rune) =
    touch()
    a.ui.typedPending.add $r
    a.inputPending = true
  # Windy reports a drop one file at a time; gather them so the whole drop
  # becomes one playlist (or one insertion when dropped on the playlist).
  a.window.onFileDrop = proc (path: string, data: string) =
    touch()
    if a.dropped.len == 0: a.dropAt = a.window.mousePos.vec2 / a.sk.uiScale
    a.dropped.add path
  a.window.onFocusChange = proc () =
    touch()
    # Popups take no focus, so focus moving elsewhere means a click outside
    # the app (or Alt+Tab): dismiss menus like a toolkit would. Checked a bit
    # later in the loop, since activating the window by clicking the menu bar
    # can produce a brief focus-out that must not close the menu just opened.
    a.focusLostAt = if a.window.focused: 0.0 else: now()
    a.dirtyUntil = now() + 0.5

  a.rdForNow = startedLow
  a.rdStart = now()
  a.rdNote = rendererNote()
  if resumed: a.resumeState(rs)
  elif files.len > 0: a.openPaths(files)
  elif c.rememberPlaylist:
    # Restored without playing; Play starts the entry that was current.
    a.playlist = c.playlist.filterIt(fileExists(it) or it.contains("://"))
    a.linkTitles = c.playlistTitles
    a.ytListed = c.playlistListed.toHashSet
    if a.playlist.len > 0:
      let cur = c.playlistIndex
      a.plSelected =
        if cur >= 0 and cur < c.playlist.len and c.playlist[cur] in a.playlist:
          a.playlist.find(c.playlist[cur])
        else: 0

  var lastFrame = 0.0
  proc enableRunes() =
    # Silky's own text-input layer (unused here) switches rune input off at
    # the end of every UI frame and on focus changes; without it Windy drops
    # typed characters, so turn it back on before reading events.
    a.window.runeInputEnabled = true
    if a.optWin != nil: a.optWin.runeInputEnabled = true
    if a.renWin != nil: a.renWin.runeInputEnabled = true
    if a.cmdWin != nil: a.cmdWin.runeInputEnabled = true
    if a.pickWin != nil: a.pickWin.runeInputEnabled = true
    if a.syncWin != nil: a.syncWin.runeInputEnabled = true
    if a.ytWin != nil: a.ytWin.runeInputEnabled = true
    if a.embWin != nil: a.embWin.runeInputEnabled = true
    if a.upWin != nil: a.upWin.runeInputEnabled = true
    if a.eqWin != nil: a.eqWin.runeInputEnabled = true

  proc step(): bool =
    ## One pass of the main loop after reading events; false when there was
    ## nothing to draw.
    if a.dropped.len > 0:
      a.dropFiles(a.dropped)
      a.dropped.setLen 0
    let incoming = a.instance.poll()
    if incoming.len > 0 and a.playlistLocked:
      # The master's playlist rules; the files go there.
      a.peers.send(a.syncMaster, @["open"] & incoming.mapIt(
        if it.contains("://"): it else: it.absolutePath))
      a.osd("Opening in the synchronization master")
    elif incoming.len > 0:
      a.closeDialogs()
      a.ui.focusId = ""
      a.openPaths(incoming.mapIt(if it.contains("://"): it else: it.absolutePath))
      a.window.activate()
      a.dirtyUntil = now() + 0.5
    if a.menus.pollInput(): a.dirtyUntil = now() + 1.2
    if takeFrameReady(): a.frameFlag = true
    if takePreviewReady(): a.previewFlag = true
    if takeOsdReady(): a.osdFlag = true
    let peerNews = a.pollPeers()
    let changed = a.player.pollEvents() or peerNews
    a.seamlessLoop()
    a.loopSound()
    a.placeLoopEnd()
    a.pingPong()
    a.loopFrames()
    a.stepFrames()
    a.pollProbe()
    a.pollMediaKey()
    a.syncEqualizer()
    a.preview.pollEvents()
    a.pollDialog()
    a.pollJobs()
    a.pollYtdlp()
    a.pollWebSave()
    a.pollSave()
    a.pollEmbed()
    a.pollUpdate()
    a.pollThumbnail()
    a.pollBoard()
    a.watchVram()
    for st in a.script.due: a.runScriptStep(st)
    if a.script.next < a.script.steps.len: a.dirtyUntil = now() + 0.5

    if a.player.justLoaded and a.reopening:
      # The same file again (pingPong): its added tracks and choices back.
      a.player.justLoaded = false
      a.reopening = false
      let have = a.player.externalFiles
      for t in a.reopenTracks:
        if t.file notin have: a.player.h.command(t.kind & "-add", t.file, "auto")
      for (prop, id) in a.reopenSel:
        a.player.h.setProp(prop, if id == 0: "no" else: $id)
    if a.player.justLoaded and a.resuming:
      # Restarted into an update: the file as it was left.
      a.resuming = false
      let r = a.resume
      let have = a.player.externalFiles  # found by mpv itself (sub-auto...)
      for t in r.tracks:
        if t.file notin have: a.player.h.command(t.kind & "-add", t.file, "auto")
      for (prop, id) in [("aid", r.aid), ("sid", r.sid), ("vid", r.vid)]:
        a.player.h.setProp(prop, if id == 0: "no" else: $id)
      if r.speed != 1: a.player.h.setProp("speed", r.speed)
      if r.stopped: a.player.stop()
      (a.loopA, a.hasLoopA, a.loopB, a.hasLoopB) = (r.loopA, r.hasLoopA, r.loopB, r.hasLoopB)
      a.abLoop = r.abLoop and a.loopReady
      a.applyAbLoop()
    if a.player.justLoaded and a.qualitySwitch:
      # The same link in another quality: as it was, window and all.
      a.player.justLoaded = false
      a.qualitySwitch = false
      if a.stopOnLoad:
        a.stopOnLoad = false
        a.player.stop()
    if a.player.justLoaded:
      a.player.justLoaded = false
      if a.stopOnLoad:  # gone online at Stop
        a.stopOnLoad = false
        a.player.stop()
      a.resetLook()
      a.lookDragging = false
      a.updateTitle()
      # The master moved to another file: the group follows to its start time.
      if not a.isSlave:
        a.syncSend("seek", $a.resumedAt, "true")
        a.syncSend("play")
      if a.resumedAt > 0:
        a.osd("Resumed at " & fmtTime(a.resumedAt, dur = a.player.duration))
        a.resumedAt = 0
      a.hintsKey = ""
      if a.cfg.autoFitWindow: a.fitPending = true
    if a.fitPending and a.player.hasVideo:
      a.fitPending = false
      a.fitWindowToVideo()
    a.handleEof()
    # Re-checked every iteration while unfocused, so menus opened or kept
    # open after the focus left still close. The grace period also counts
    # from the opening, as the click that opens a menu on an inactive window
    # activates it a moment later. A press held on a popup is spared, so a
    # focus blip from clicking it can't swallow the item.
    if not a.menus.isOpen: a.menuOpenedAt = 0
    elif a.menuOpenedAt == 0: a.menuOpenedAt = now()
    if a.focusLostAt > 0 and now() - max(a.focusLostAt, a.menuOpenedAt) > 0.15 and
       not a.window.focused and a.menus.isOpen and
       not (pointerButtonsDown() and a.menus.pointerOverPopup(a.ui)):
      a.menus.close()
      a.dirtyUntil = now() + 0.5
    a.applyOnTop()
    a.applyKeepAwake()
    a.updateAspectHints()
    a.autosave()

    let t = now()
    a.pollVideoFrame()
    a.updateOsdApart()
    let wantDraw = a.renderNow or a.lfDue or a.previewFlag or a.osdFlag or changed or t < a.dirtyUntil or
      t - lastFrame > 0.25 or a.dialog != nil and t - lastFrame > 0.1
    # Due video frames and input draw immediately (a skipped frame would lose
    # the press); other UI-only redraws are capped at ~240 fps.
    let needDraw = wantDraw and
      (a.renderNow or a.lfDue or a.inputPending or t - lastFrame >= 1 / 240)
    if needDraw:
      a.inputPending = false
      a.handleKeys()
      a.frame()
      a.syncSettings()
      lastFrame = t
    needDraw

  var polling, stepping = false
  var pollAt = 0.0
  when defined(windows):
    # Dragging a title bar or a border holds the thread in Windows' own loop,
    # inside pollEvents: step from there, so video and drawing carry on.
    whileModal(proc () =
      if not polling or stepping or now() - pollAt < 0.008: return
      stepping = true
      discard step()
      # Handled: the main loop mustn't handle it again once pollEvents returns.
      for w in [a.window, a.optWin, a.renWin, a.cmdWin, a.pickWin, a.syncWin, a.ytWin, a.embWin,
                a.upWin, a.eqWin]:
        if w != nil: w.clearFrameInput()
      enableRunes()
      stepping = false)

  while not a.window.closeRequested:
    enableRunes()
    polling = true
    pollAt = now()
    pollEvents()
    polling = false
    if not step(): sleep(1)

  if a.overlay == ovOptions: a.closeOptions(false)
  if a.ytCaps.running: a.ytCaps.stop()
  a.board.cancel()
  a.ytStyling.cancel()
  if a.ytSubs.running: a.ytSubs.stop()
  if a.ytList.running: a.ytList.stop()
  if a.ytInfo.running: a.ytInfo.stop()
  if a.upJob.running: a.upJob.stop()
  a.cancelSave()
  a.recordEnd()  # mpv closes the file as it shuts down
  if a.eqUnsaved.len > 0: a.saveEqualizer()
  a.saved.save()
  a.saveLinkInfos()
  a.savePosition()
  a.rememberState()
  a.cfg.save()
  if a.upRestart or a.rdRestart.len > 0: a.saveResume()
  a.instance.close()
  a.peers.close()
  for c in a.children: c.close()
  if a.preview != nil:
    mpv_render_context_free(a.preview.render)
    mpv_terminate_destroy(a.preview.h)
  for p in [a.player, a.standby]:
    if p != nil:
      mpv_render_context_free(p.render)
      mpv_terminate_destroy(p.h)
  if a.lsound != nil: mpv_terminate_destroy(a.lsound.h)
  if a.osdLayer != nil:
    mpv_render_context_free(a.osdLayer.render)
    mpv_terminate_destroy(a.osdLayer.h)
  if a.upRestart: relaunch()
  elif a.rdRestart.len > 0: relaunch(RenderArg & a.rdRestart)

when isMainModule:
  main()
