## yt-dlp: finds it (on PATH, else the copy the player installed) and runs
## it in the background: looking up a link's captions and subtitles, checking
## for a newer release, updating itself (yt-dlp -U) and installing its standalone
## build, which can then keep itself up to date with -U too.

import std/[os, osproc, json, math, strutils, strformat, algorithm, sequtils]
import runlog, config, spherical

const
  YtdlSubLangs* = "all,-live_chat"
    ## Every real subtitle (a live stream's chat replay isn't one). Automatic
    ## captions come apart (captions): asking for those here would bring the
    ## machine translations into every language, keyed like real subtitles.
  ReleaseUrl = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/"
  LatestApi = "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"

type
  YtTask* = enum
    ytVersion   ## the installed version
    ytLatest    ## the latest release's version
    ytUpdate    ## yt-dlp -U
    ytInstall   ## the standalone build, to managedPath
    ytCaptions  ## a link's automatic captions
    ytSubs      ## a link's subtitles, as files
    ytPlaylist  ## a playlist's videos, as they're found
    ytInfo      ## videos' durations and sizes, for the playlist's columns
    ytDownload  ## a link's video, whole, to a file (File > Save)

  Quality* = tuple[id, label, lang, langName: string]
    ## A format a link offers, as the controls' quality menu lists it; audio
    ## has its language too, as Audio Track lists it

  Storyboard* = object
    ## The sheets of little frames a link offers for seek bar previews, in
    ## the order of the video
    width*, height*: int      ## of a frame, in pixels
    columns*, rows*: int      ## frames of a sheet, at most
    fps*: float               ## frames a second of the video
    sheets*: seq[tuple[url: string, duration: float]]

  YtJob* = ref object
    task*: YtTask
    url*: string              ## ytCaptions, ytSubs: the link
    p: Process                ## nil once finished
    partial: string           ## output after the last line break
    lines*: seq[string]       ## output lines, stdout and stderr together
    code*: int = -1           ## exit code once finished; -1 while running
    progress*: float = -1     ## percent done, as last printed
    bytes*, total*: int64     ## ytDownload: bytes downloaded, of how many (0: unknown)
    streamBase: int64         ## ytDownload: the streams downloaded before this one
    streamDone, streamTotal: int64  ## and this one's bytes, as last printed
    inStream: bool            ## ytDownload: a stream downloading (not a subtitle)
    step*, steps*: int        ## ytDownload: of video, audio and merging them,
                              ## which it's on (steps 0: one stream, no merging)
    data: string              ## ytCaptions: what it printed
    subData: string           ## ytCaptions: and the link's subtitles, as printed
    fmts: string              ## ytCaptions: the link's formats, as printed
    boards: string            ## ytCaptions: and their storyboards' fields
    dest: string              ## ytInstall: where it goes; ytSubs: the start
                              ## of its files' paths
    subs*: seq[string]        ## ytSubs: the files it made
    items*: seq[tuple[id, title: string, duration: float]]
                              ## ytPlaylist: the videos found so far (duration
                              ## 0 when unknown)
    infos*: seq[tuple[id: string, duration: float, width, height: int, abr: float,
                       title: string]]
                              ## ytInfo: the videos looked up so far

proc managedPath*(): string =
  ## Where the player installs yt-dlp: on PATH for most Linux setups.
  when defined(windows): getEnv("LOCALAPPDATA") / "Programs" / "yt-dlp" / "yt-dlp.exe"
  else: getHomeDir() / ".local" / "bin" / "yt-dlp"

proc findYtdlp*(custom = ""): string =
  ## `custom` (Options > Player > Paths) when that file exists; else the
  ## yt-dlp the player installed, once it has (a launcher's PATH may lack
  ## ~/.local/bin, or have a package manager's yt-dlp first, which -U can't
  ## update); else the one on PATH; "" when there is none.
  let c = custom.strip.expandTilde
  if c.len > 0 and fileExists(c): c
  elif fileExists(managedPath()): managedPath()
  else: findExe("yt-dlp")

proc downloadDir*(): string = getCacheDir("majestic-media-player") / "yt-dlp"

proc removeDownloads*() =
  ## Deletes what older versions downloaded (links now always stream).
  try: removeDir(downloadDir())
  except OSError: discard

proc running*(j: YtJob): bool = j != nil and j.p != nil

proc start(task: YtTask, exe: string, args: openArray[string], url = ""): YtJob =
  result = YtJob(task: task, url: url)
  try:
    result.p = startProcess(exe, args = args,
      options = {poUsePath, poStdErrToStdOut, poDaemon})
    result.p.nonBlocking()
  except OSError as e:
    result.lines.add e.msg
    result.code = 127

proc cookieArgs(cookies: string): seq[string] =
  if cookies.len > 0: @["--cookies-from-browser", cookies] else: @[]

proc captions*(exe, url: string, cookies = ""): YtJob =
  ## `cookies`: the browser to sign in with (cookieBrowsers), "" for none.
  ## Lists the link's formats too (qualities, storyboard).
  start(ytCaptions, exe, @["--no-warnings", "--no-playlist"] & cookieArgs(cookies) &
    @["-O", "MMPCAPS %(automatic_captions)j", "-O", "MMPSUBS %(subtitles)j",
      "-O", "MMPFMTS %(formats.:.{format_id," &
      "vcodec,acodec,height,fps,abr,language,format_note,protocol})j", "-O", "MMPSB %(formats.:.{format_id," &
      "width,height,columns,rows,fps,fragments})j", "--", url], url)

proc playlistItems*(exe, url: string, cookies = ""): YtJob =
  ## Lists a playlist's videos (url: the playlist's link, or a video's in it),
  ## each printed as soon as its page of the list comes in.
  start(ytPlaylist, exe, @["--no-warnings", "--flat-playlist", "--lazy-playlist",
    "--yes-playlist"] & cookieArgs(cookies) & @["-O", "MMPITEM %(id)s %(duration)s %(title)s",
    "--", url], url)

proc videoInfos*(exe: string, ids: openArray[string], cookies = ""): YtJob =
  ## Looks up YouTube videos' titles, durations, sizes and audio bitrates (of the formats yt-dlp picks), each
  ## printed as soon as it's found; a playlist's listing has no sizes.
  start(ytInfo, exe, @["--no-warnings", "--no-playlist", "--ignore-errors",
    "--skip-download"] & cookieArgs(cookies) &
    @["-O", "MMPINFO %(id)s %(duration)s %(width)s %(height)s %(abr)s %(title)s",
    "--"] & @ids)

proc formatSpec*(c: Config): string =
  ## The -f (ytdl-format) value for Options > Online > Bandwidth. A limit no
  ## format meets falls back to the smallest one, not the best.
  let a = if c.streamSmallAudio: "wa" else: "ba"
  var f = ""
  if c.streamQuality == sqLimit: f.add &"[height<=?{c.streamMaxHeight}]"
  if c.streamMaxFps30: f.add "[fps<=?30]"
  case c.streamQuality
  of sqLowest: "wv*+wa/w"
  of sqAudioOnly: a & "/" & (if c.streamSmallAudio: "w" else: "b")
  of sqBest, sqLimit:
    &"bv*{f}+{a}/b{f}" & (if f.len > 0: &"/wv*+{a}/w" else: "")

const AudioRanks* = ["highest", "mid", "lowest"]
  ## Audio locks: a row of the quality menu's audio column by where it is,
  ## the same on every link (its qualities aren't): first, middle, last.

proc rankRow*(rank: string, rows: int): int =
  ## The row an audio rank stands for among `rows`; -1 for none.
  if rows == 0: return -1
  case rank
  of "highest": 0
  of "mid": rows div 2
  of "lowest": rows - 1
  else: -1

proc sameQuality*(lock, label: string): bool =
  ## A locked video quality and one a link offers are alike.
  label == lock or label.startsWith(lock & " ") or lock.startsWith(label & " ")

proc lockFilters(lock: string, video: bool): seq[string] =
  ## A locked quality as yt-dlp selectors, best first: a video label
  ## ("1080p60") for video alone, then with sound; an audio rank (AudioRanks).
  let parts = lock.split(' ')
  if video:
    let hp = parts[0].split('p')
    let h = try: parseInt(hp[0]) except ValueError: return
    let fps = if hp.len > 1 and hp[1].len > 0: (try: parseInt(hp[1]) except ValueError: 0) else: 0
    let f = &"[height={h}]" &
      (if fps > 0: &"[fps>={fps.float - 0.5}][fps<{fps.float + 0.5}]" else: "[fps<=?30]")
    @["bv" & f, "bv*" & f]
  else:
    # Audio is locked by rank: yt-dlp's best and worst of those the menu
    # lists; the middle one has no selector (found once the formats are).
    case lock
    of "highest": @["ba[abr>0][format_id!*=-drc]"]
    of "lowest": @["wa[abr>0][format_id!*=-drc]"]
    else: @[]

proc pickSpec*(c: Config, video, audio: string): string =
  ## The -f for the formats picked in the quality menu: each a format id,
  ## "~<lock>" for a locked quality (a video label, an audio rank) looked for
  ## by what it is,
  ## or "" for Options > Online's choice. A video with sound of its own (no
  ## audio apart) plays as it is. Left to Auto, audio is as Options > Online
  ## picks it. What the link doesn't offer falls back to Options > Online's.
  let a = if c.streamSmallAudio or c.streamQuality == sqLowest: "wa" else: "ba"
  proc sels(x: string, video: bool): seq[string] =
    if x.startsWith("~"): lockFilters(x[1 .. ^1], video) else: @[x]
  var alts: seq[string]
  if video.len > 0:
    let auds = if audio.len > 0: sels(audio, false) else: @[]
    for v in sels(video, true):
      for au in auds: alts.add v & "+" & au
      alts.add v & "+" & a
      alts.add v
  elif audio.len > 0:
    var f = ""
    if c.streamQuality == sqLimit: f.add &"[height<=?{c.streamMaxHeight}]"
    if c.streamMaxFps30: f.add "[fps<=?30]"
    for au in sels(audio, false):
      case c.streamQuality
      of sqAudioOnly: alts.add au
      of sqLowest: alts.add [&"wv*+{au}", au]
      of sqBest, sqLimit:
        alts.add &"bv*{f}+{au}"
        if f.len > 0: alts.add &"bv*+{au}"
        alts.add au
  alts.add formatSpec(c)
  alts.deduplicate.join("/")

proc subtitles*(exe, url, dest: string, cookies = ""): YtJob =
  ## Downloads url's subtitles (not its video) as dest.<lang>.<ext>.
  try: createDir(dest.parentDir)
  except OSError: discard
  result = start(ytSubs, exe, @["--no-warnings", "--no-playlist", "--skip-download"] &
    cookieArgs(cookies) & @["--write-subs", "--sub-langs", YtdlSubLangs, "--sub-format",
    "ass/srt/best", "-P", dest.parentDir, "-o", dest.extractFilename & ".%(ext)s", "--", url], url)
  result.dest = dest

proc download*(exe, url, dir, name, ext: string, cookies = "", format = "bv*+ba/b",
               skipSubs: seq[string] = @[]): YtJob =
  ## Downloads url whole (best video and audio, or format) into dir as `name`
  ## (an output template), an `ext` (mkv, mp4) with its subtitles (but for the
  ## languages in skipSubs) and chapters.
  start(ytDownload, exe, @["--no-playlist", "--newline", "--force-overwrites",
    "-f", format, "--merge-output-format", ext, "--remux-video", ext,
    "--embed-subs", "--sub-langs", YtdlSubLangs & skipSubs.mapIt(",-" & it).join,
    "--embed-chapters", "--progress-template",
    "download:MMPPROG %(progress.downloaded_bytes)s %(progress.total_bytes)s " &
    "%(progress.total_bytes_estimate)s"] & cookieArgs(cookies) &
    @["-P", dir, "-o", name, "--", url], url)

proc downloadScript*(exe, url, dest: string, cookies = "", format = "bv*+ba/b"): string =
  ## Bash lines downloading url whole (best video and audio, or format) to
  ## dest, an .mkv with its subtitles and chapters, for a command line to run
  ## on; the script exits when it fails.
  let args = @[exe, "--no-playlist", "--newline", "-f", format,
    "--merge-output-format", "mkv", "--remux-video", "mkv", "--embed-subs",
    "--sub-langs", YtdlSubLangs, "--embed-chapters", "--no-part"] & cookieArgs(cookies) &
    @["-o", dest, "--", url]
  args.mapIt(quoteShellPosix(it)).join(" ") & " || exit\n"

proc sectionScript*(exe, url, dest: string, start, stop: float, cookies = "",
    format = "bv*+ba/b"): string =
  ## Like downloadScript, but only start..stop (seconds) of url, its
  ## subtitles whole. The video keeps its own timestamps (-copyts): yt-dlp's
  ## section downloads otherwise start the clock at the keyframe before start,
  ## which no one can tell, and leave the subtitles on the video's clock. The
  ## script then defines mmp_clip: a time of the video (HH:MM:SS.mmm) as a
  ## time of dest, what ffmpeg's -ss takes (from dest's start).
  let dir = dest.parentDir
  let q = quoteShellPosix
  let section = "*" & formatFloat(start, ffDecimal, 3) & "-" & formatFloat(stop, ffDecimal, 3)
  let args = @[exe, "--no-playlist", "--newline", "-f", format,
    "--merge-output-format", "mkv", "--write-subs", "--sub-langs", YtdlSubLangs,
    "--convert-subs", "srt", "--no-part", "--download-sections", section,
    "--downloader-args", "ffmpeg:-copyts"] & cookieArgs(cookies) &
    @["-o", dir / "part.%(ext)s", "-o", "subtitle:" & dir / "subs" / "part.%(ext)s", "--", url]
  result = args.mapIt(q(it)).join(" ") & " || exit\n"
  # Subtitles muxed in on the same clock, each tagged with its language.
  result.add "set -- " & q(dir) & "/part.*\n" &
    "ins=(); maps=(-map 0); n=0\n" &
    "for s in " & q(dir / "subs") & "/*.srt; do\n" &
    "  [ -e \"$s\" ] || continue\n" &
    "  l=${s%.srt}; l=${l##*.}; n=$((n+1))\n" &
    "  ins+=(-i \"$s\"); maps+=(-map \"$n\" \"-metadata:s:s:$((n-1))\" \"language=$l\")\n" &
    "done\n" &
    "ffmpeg -v error -y -copyts -i \"$1\" \"${ins[@]}\" \"${maps[@]}\" -c copy " & q(dest) & " || exit\n" &
    "mmp_off=$(ffprobe -v error -show_entries format=start_time -of csv=p=0 " & q(dest) & ")\n" &
    "case $mmp_off in ''|N/A) mmp_off=0;; esac\n" &
    "mmp_clip() { LC_ALL=C awk -v t=\"$1\" -v o=\"$mmp_off\" 'BEGIN { n = split(t, f, \":\"); " &
    "s = 0; for (i = 1; i <= n; i++) s = s * 60 + f[i]; ms = int((s - o) * 1000 + 0.5); " &
    "if (ms < 0) ms = 0; printf \"%02d:%02d:%02d.%03d\\n\", int(ms / 3600000), " &
    "int(ms / 60000) % 60, int(ms / 1000) % 60, ms % 1000 }'; }\n"

proc cookieBrowsers*(setting: string): seq[string] =
  ## The browsers whose cookies yt-dlp signs in with, in turn, for a link that
  ## asks to (age-restricted videos): "auto" tries each one installed, "none"
  ## none; anything else is a --cookies-from-browser value as it is
  ## ("brave", "firefox:~/.zen/profile"...).
  let s = setting.strip
  if s.len > 0 and s.toLowerAscii notin ["auto", "none"]: return @[s]
  if s.toLowerAscii == "none": return
  let home = getHomeDir()
  let dirs =
    when defined(windows):
      let local = getEnv("LOCALAPPDATA")
      let roaming = getEnv("APPDATA")
      @[("firefox", roaming / "Mozilla" / "Firefox"),
        ("brave", local / "BraveSoftware" / "Brave-Browser" / "User Data"),
        ("chrome", local / "Google" / "Chrome" / "User Data"),
        ("chromium", local / "Chromium" / "User Data"),
        ("edge", local / "Microsoft" / "Edge" / "User Data"),
        ("vivaldi", local / "Vivaldi" / "User Data"),
        ("opera", roaming / "Opera Software" / "Opera Stable")]
    elif defined(macosx):
      let sup = home / "Library" / "Application Support"
      @[("firefox", sup / "Firefox"), ("safari", home / "Library" / "Cookies"),
        ("brave", sup / "BraveSoftware" / "Brave-Browser"),
        ("chrome", sup / "Google" / "Chrome"), ("chromium", sup / "Chromium"),
        ("edge", sup / "Microsoft Edge"), ("vivaldi", sup / "Vivaldi"),
        ("opera", sup / "com.operasoftware.Opera")]
    else:
      let cfg = getConfigDir()
      @[("firefox", home / ".mozilla" / "firefox"),
        ("brave", cfg / "BraveSoftware" / "Brave-Browser"),
        ("chrome", cfg / "google-chrome"), ("chromium", cfg / "chromium"),
        ("edge", cfg / "microsoft-edge"), ("vivaldi", cfg / "vivaldi"),
        ("opera", cfg / "opera")]
  for (name, dir) in dirs:
    if dirExists(dir): result.add name

proc wantsSignIn*(err: string): bool =
  ## yt-dlp's error says the link needs a signed-in account (age-restricted,
  ## "confirm you're not a bot"...), which browser cookies give it.
  "Sign in" in err or "--cookies" in err

proc errorReason*(err: string): string =
  ## yt-dlp's "ERROR: [youtube] id: Sign in to confirm your age. Use ..." as
  ## "Sign in to confirm your age".
  result = err.strip
  if result.startsWith("ERROR:"): result = result[6 .. ^1].strip
  if result.startsWith("["):
    let c = result.find(": ")
    if c > 0: result = result[c + 2 .. ^1]
  let dot = result.find(". ")
  if dot > 0: result = result[0 ..< dot]
  result = result.strip(chars = {'.', ' '})

proc originalCaptions*(j: YtJob): seq[tuple[url, title, lang: string]] =
  ## ytCaptions: the captions in the video's own language (YouTube keys them
  ## "<lang>-orig"; the others are machine translations of them), as srt,
  ## else vtt, when there is one.
  let all = try: parseJson(j.data) except CatchableError: return
  if all.kind != JObject: return
  for key, formats in all:
    if not key.endsWith("-orig") or formats.kind != JArray or formats.len == 0: continue
    var pick = formats[0]
    for ext in ["vtt", "srt"]:  # the later wins
      for f in formats:
        if f{"ext"}.getStr == ext: pick = f
    result.add (pick{"url"}.getStr, pick{"name"}.getStr(key) & " (automatic)",
      key[0 ..< key.len - 5])

proc styledSubs*(j: YtJob): seq[tuple[url, title, lang: string]] =
  ## ytCaptions: the link's subtitles in YouTube's own format (srv3), the one
  ## that keeps their styling.
  let all = try: parseJson(j.subData) except CatchableError: return
  if all.kind != JObject: return
  for key, formats in all:
    if formats.kind != JArray: continue
    for f in formats:
      if f{"ext"}.getStr == "srv3":
        result.add (f{"url"}.getStr, f{"name"}.getStr(key), key)
        break
  result.sort(proc(a, b: auto): int = cmp(a.lang, b.lang))  # the order mpv's hook adds them in

type
  LinkSphere* = object
    ## How a link's picture lies on the sphere, as far as yt-dlp's formats say.
    sphere*: SphereInfo
    meshUrl*: string          ## a format with a mesh, whose header says the rest
    meshHls*: bool            ## the picture isn't that format but an HLS one

proc noted(f: JsonNode, what: string): bool =
  ## A format's note (its picture's projection is there) has `what`, whose
  ## full name may go on ("equi_threed_top_bottom").
  f{"format_note"}.getStr.split(", ").anyIt(it.startsWith(what))

proc flat(f: JsonNode, spherical: bool): bool =
  ## YouTube renders a 360° video's lesser formats through a fixed camera,
  ## noted as nothing. Its HLS ones, noted as nothing too, stay on the sphere.
  spherical and not f.noted("equi") and not f.noted("mesh") and
    "m3u8" notin f{"protocol"}.getStr

proc stereoNoted(f: JsonNode): StereoLayout =
  let note = f{"format_note"}.getStr
  if "top_bottom" in note: slTopBottom
  elif "left_right" in note: slSideBySide
  else: slMono

proc linkSphere*(info: string): LinkSphere =
  ## From the JSON yt-dlp gave for a link: what's playing decides, not the
  ## video: the same one can be on the sphere in one format and flat in the
  ## other (flat).
  if "equi" notin info and "mesh" notin info: return
  let j = try: parseJson(info) except CatchableError: return
  var video = j
  for f in j{"requested_formats"}.getElems:
    if f{"vcodec"}.getStr notin ["", "none"]: video = f
  var equi, mesh: JsonNode
  for f in j{"formats"}.getElems:
    if f.noted("equi"): equi = f
    elif f.noted("mesh"): mesh = f
  if video.noted("mesh"): result.meshUrl = video{"url"}.getStr
  elif video.noted("equi"):
    result.sphere = SphereInfo(projection: prEquirect, stereo: video.stereoNoted)
  elif "m3u8" notin video{"protocol"}.getStr: discard
  elif equi != nil:
    result.sphere = SphereInfo(projection: prEquirect, stereo: equi.stereoNoted)
  elif mesh != nil:
    result.meshUrl = mesh{"url"}.getStr
    result.meshHls = true

proc hlsSphere*(mesh: SphereInfo): SphereInfo =
  ## An HLS format's picture on a video that also has a format with `mesh`:
  ## equirectangular (top and bottom if in 3D), but a mesh for each eye means
  ## VR180, and those HLS formats are flat.
  if mesh.meshes.len == 1:
    SphereInfo(projection: prEquirect,
      stereo: if mesh.stereo == slMono: slMono else: slTopBottom)
  else: SphereInfo()

proc qualities*(j: YtJob): tuple[video, audio: seq[Quality]] =
  ## ytCaptions: the link's video qualities, tallest first ("1080p60"), and
  ## its audio ones as yt-dlp ranks them, best first ("130k aac"): its "ba"
  ## first (so the link's own language), of each language its "wa" last
  ## (AudioRanks). yt-dlp lists formats worst to best, so of those alike the
  ## one it prefers stands for them.
  ## A link with no video apart from its sound lists its videos with sound.
  let all = try: parseJson(j.fmts) except CatchableError: return
  if all.kind != JArray: return
  proc num(f: JsonNode, key: string): float =
    let n = f{key}
    if n == nil: 0.0 elif n.kind == JInt: n.getInt.float else: n.getFloat
  type V = tuple[q: Quality, h, fps: float]
  type A = tuple[q: Quality, abr: float]
  var alone, muxed: seq[V]
  var audio: seq[A]
  let spherical = all.anyIt(it.noted("equi") or it.noted("mesh"))
  for f in all:
    let id = f{"format_id"}.getStr
    if id.len == 0 or id.endsWith("-drc"): continue  # the same, compressed
    if f.flat(spherical): continue
    let (vc, ac) = (f{"vcodec"}.getStr, f{"acodec"}.getStr)
    let (h, fps, abr) = (f.num("height"), f.num("fps"), f.num("abr"))
    if h > 0 and vc != "none":
      let label = &"{int(h)}p" & (if fps > 30: $int(round(fps)) else: "")
      if ac == "none": alone.add ((id, label, "", ""), h, fps)
      else: muxed.add ((id, label, "", ""), h, fps)
    elif vc == "none" and ac notin ["", "none"] and abr > 0:
      let codec = ac.split('.')[0].toLowerAscii
      let short =
        case codec
        of "mp4a": "aac"
        of "ac-3": "ac3"
        of "ec-3": "eac3"
        else: codec
      let lang = f{"language"}.getStr
      # "German (DE), low", "English (US) original (default), low"
      let note = f{"format_note"}.getStr
      let name = if ", " in note: note.split(", ")[0].replace(" (default)", "") else: lang
      audio.add ((id, &"{int(round(abr))}k {short}", lang, name), abr)
  var videos: seq[V]
  let found = if alone.len > 0: alone else: muxed
  for i, v in found:
    if found[i + 1 .. ^1].allIt(it.q.label != v.q.label): videos.add v
  videos.sort(proc (x, y: V): int = cmp((y.h, y.fps), (x.h, x.fps)))
  result.video = videos.mapIt(it.q)
  audio.reverse()
  for i, a in audio:
    if audio[0 ..< i].anyIt(it.q.label == a.q.label and it.q.lang == a.q.lang): continue
    result.audio.add a.q

proc audioLanguages*(audio: seq[Quality]): seq[Quality] =
  ## One of a link's audio qualities (qualities) for each language it comes
  ## in: its own first, as yt-dlp ranks it, then the dubs by name.
  for x in audio:
    if result.allIt(it.lang != x.lang): result.add x
  if result.len > 2:
    result[1 .. ^1] = result[1 .. ^1].sortedByIt(it.langName)

proc storyboard*(j: YtJob): Storyboard =
  ## ytCaptions: the link's sharpest storyboard; none (no sheets) for a link
  ## without one, as live streams are.
  let all = try: parseJson(j.boards) except CatchableError: return
  if all.kind != JArray: return
  for f in all:
    if not f{"format_id"}.getStr.startsWith("sb") or f{"width"}.getInt <= result.width:
      continue
    let frags = f{"fragments"}
    let fps = f{"fps"}.getFloat
    if frags == nil or frags.kind != JArray or frags.len == 0 or fps <= 0 or
       f{"height"}.getInt <= 0 or f{"columns"}.getInt <= 0 or f{"rows"}.getInt <= 0: continue
    result = Storyboard(width: f{"width"}.getInt, height: f{"height"}.getInt,
      columns: f{"columns"}.getInt, rows: f{"rows"}.getInt, fps: fps)
    for s in frags: result.sheets.add (s{"url"}.getStr, s{"duration"}.getFloat)

proc version*(exe: string): YtJob = start(ytVersion, exe, ["--version"])

proc latest*(): YtJob =
  start(ytLatest, "curl", ["-fsSL", "--max-time", "15",
    "-H", "Accept: application/vnd.github+json", LatestApi])

proc update*(exe: string): YtJob = start(ytUpdate, exe, ["-U"])

proc install*(): YtJob =
  ## Fetches the standalone build into managedPath.
  let name =
    when defined(windows): "yt-dlp.exe"
    elif defined(macosx): "yt-dlp_macos"
    elif defined(arm64): "yt-dlp_linux_aarch64"
    else: "yt-dlp_linux"
  let dest = managedPath()
  try: createDir(dest.parentDir)
  except OSError: discard
  result = start(ytInstall, "curl", ["-fL", "--retry", "2", "-#",
    "-o", dest & ".part", ReleaseUrl & name])
  result.dest = dest

proc percentIn(s: string): float =
  ## The number before the last '%' in s, else -1.
  let e = s.rfind('%')
  if e < 0: return -1
  var b = e
  while b > 0 and s[b - 1] in {'0' .. '9', '.'}: dec b
  try: parseFloat(s[b ..< e]) except ValueError: -1

proc addLine(j: YtJob, line: string) =
  let l = line.strip
  if l.len == 0: return
  let pc = percentIn(l)
  if j.task == ytInstall and l.startsWith("#"):
    if pc >= 0: j.progress = pc
  elif j.task == ytDownload and l.startsWith("MMPPROG "):
    if not j.inStream: return  # a subtitle file
    proc num(s: string): int64 =
      try: int64(parseFloat(s)) except ValueError: 0
    let f = l.split(' ')
    if f.len < 4: return
    let done = num(f[1])
    let total = if num(f[2]) > 0: num(f[2]) else: num(f[3])
    (j.streamDone, j.streamTotal) = (done, total)
    j.bytes = j.streamBase + done
    j.total = if total > 0: j.streamBase + total else: 0
    if j.total > 0: j.progress = min(j.bytes.float * 100 / j.total.float, 100)
  elif j.task == ytDownload and l.startsWith("[info]") and " format(s): " in l:
    # "Downloading 1 format(s): 395+251": video and audio apart, merged after.
    let n = l.split(" format(s): ", 1)[1].count('+') + 1
    j.steps = if n > 1: n + 1 else: 0
    j.lines.add l
  elif j.task == ytDownload and l.startsWith("[download] Destination: "):
    # Each stream downloads in turn, counting from 0: the bytes add up.
    let ext = l.splitFile.ext.toLowerAscii
    j.inStream = ext notin [".vtt", ".srt", ".ass", ".ssa", ".ttml", ".srv1", ".srv2",
                            ".srv3", ".json3", ".lrc"]
    if j.inStream:
      j.streamBase += max(j.streamTotal, j.streamDone)
      (j.streamDone, j.streamTotal) = (0'i64, 0'i64)
      inc j.step
    j.lines.add l
  elif j.task == ytDownload and l.startsWith("[Merger]"):
    j.step = j.steps
    j.lines.add l
  elif l.startsWith("MMPCAPS "): j.data = l[8 .. ^1]
  elif l.startsWith("MMPSUBS "): j.subData = l[8 .. ^1]
  elif l.startsWith("MMPFMTS "): j.fmts = l[8 .. ^1]
  elif l.startsWith("MMPSB "): j.boards = l[6 .. ^1]
  elif l.startsWith("MMPITEM "):
    let item = l[8 .. ^1].split(' ', 2)
    let title = if item.len > 2: item[2] else: ""
    let dur = if item.len > 1: (try: item[1].parseFloat except ValueError: 0.0) else: 0.0
    # Private and deleted videos stay listed, unplayable.
    if title notin ["[Private video]", "[Deleted video]"]: j.items.add (item[0], title, dur)
  elif l.startsWith("MMPINFO "):
    let f = l[8 .. ^1].split(' ', 5)
    if f.len == 6:  # NA for what's unknown (a live stream's duration, audio's size)
      let num = proc (s: string): float = (try: s.parseFloat except ValueError: 0.0)
      j.infos.add (f[0], num(f[1]), num(f[2]).int, num(f[3]).int, num(f[4]) * 1000, f[5])
  else: j.lines.add l

proc read(j: YtJob) =
  for ch in j.p.readPipe():
    if ch in {'\n', '\r'}:
      j.addLine(j.partial)
      j.partial.setLen 0
    else: j.partial.add ch

proc finish(j: YtJob) =
  if j.task == ytInstall and j.code == 0:
    try:
      moveFile(j.dest & ".part", j.dest)
      when not defined(windows):
        j.dest.setFilePermissions(j.dest.getFilePermissions +
          {fpUserExec, fpGroupExec, fpOthersExec})
    except OSError as e:
      j.lines.add e.msg
      j.code = 1
  elif j.task == ytInstall:
    try: removeFile(j.dest & ".part")
    except OSError: discard
  if j.task == ytSubs and j.code == 0:
    let prefix = j.dest.extractFilename & "."
    try:
      for kind, f in walkDir(j.dest.parentDir):
        if kind == pcFile and f.extractFilename.startsWith(prefix) and
           not f.endsWith(".part"): j.subs.add f
    except OSError: discard
    j.subs.sort()

proc poll*(j: YtJob): bool =
  ## Reads what it printed and notes when it exits. True when anything changed.
  if not j.running: return
  let before = (j.lines.len, j.progress, j.items.len, j.infos.len)
  j.read()
  let code = j.p.peekExitCode
  if code != -1:
    j.read()
    j.addLine(j.partial)
    j.p.close()
    j.p = nil
    j.code = code
    j.finish()
    return true
  (j.lines.len, j.progress, j.items.len, j.infos.len) != before

proc stop*(j: YtJob) =
  if not j.running: return
  try:
    j.p.terminate()
    discard j.p.waitForExit(1000)
    j.p.close()
  except OSError: discard
  j.p = nil
  j.code = 130

proc errorText*(j: YtJob): string =
  ## What went wrong: its last ERROR line, else its last line.
  for i in countdown(j.lines.high, 0):
    if j.lines[i].startsWith("ERROR:"): return j.lines[i][6 .. ^1].strip
  if j.lines.len > 0: j.lines[^1] else: "exit code " & $j.code

proc versionText*(j: YtJob): string =
  ## ytVersion: the installed version; ytLatest: the latest release's.
  if j.code != 0: return
  case j.task
  of ytVersion:
    if j.lines.len > 0: j.lines[^1] else: ""
  of ytLatest:
    try: parseJson(j.lines.join("\n")){"tag_name"}.getStr
    except CatchableError: ""
  else: ""

proc newer*(latest, current: string): bool =
  ## latest is a later release than current ("2026.08.19" vs "2026.06.09";
  ## nightlies add a fourth part).
  if latest.len == 0 or current.len == 0: return false
  let l = latest.split('.')
  let c = current.split('.')
  for i in 0 ..< max(l.len, c.len):
    let x = (if i < l.len: (try: parseInt(l[i]) except ValueError: 0) else: 0)
    let y = (if i < c.len: (try: parseInt(c[i]) except ValueError: 0) else: 0)
    if x != y: return x > y
  false
