## File > Properties: a MediaInfo-style report (General, Video, Audio, Text,
## Menu...) read with ffprobe, or with mpv's own track list when ffprobe is
## missing or the file isn't a local one.

import std/[os, osproc, json, strutils, strformat, math, tables]
import mpv

type
  InfoSection* = object
    title*: string
    rows*: seq[(string, string)]

const
  ProbeTimeout = 5.0  ## seconds before giving up on ffprobe

  formatNames = {
    "h264": "AVC", "hevc": "HEVC", "av1": "AV1", "vp9": "VP9", "vp8": "VP8",
    "mpeg4": "MPEG-4 Visual", "mpeg2video": "MPEG Video", "mpeg1video": "MPEG Video",
    "vc1": "VC-1", "wmv3": "VC-1", "theora": "Theora", "prores": "ProRes",
    "dnxhd": "VC-3", "mjpeg": "JPEG", "png": "PNG", "gif": "GIF", "ffv1": "FFV1",
    "aac": "AAC", "ac3": "AC-3", "eac3": "E-AC-3", "dts": "DTS", "truehd": "MLP FBA",
    "mlp": "MLP", "flac": "FLAC", "opus": "Opus", "vorbis": "Vorbis",
    "mp3": "MPEG Audio", "mp2": "MPEG Audio", "alac": "ALAC", "wmav2": "WMA",
    "wavpack": "WavPack", "ape": "Monkey's Audio",
    "subrip": "UTF-8", "srt": "UTF-8", "ass": "ASS", "ssa": "SSA", "webvtt": "WebVTT",
    "mov_text": "Timed Text", "hdmv_pgs_subtitle": "PGS", "dvd_subtitle": "VobSub",
    "dvb_subtitle": "DVB Subtitle", "eia_608": "EIA-608"}.toTable

  matroskaIds = {
    "h264": "V_MPEG4/ISO/AVC", "hevc": "V_MPEGH/ISO/HEVC", "av1": "V_AV1",
    "vp9": "V_VP9", "vp8": "V_VP8", "mpeg4": "V_MPEG4/ISO/ASP", "mpeg2video": "V_MPEG2",
    "aac": "A_AAC", "opus": "A_OPUS", "vorbis": "A_VORBIS", "flac": "A_FLAC",
    "ac3": "A_AC3", "eac3": "A_EAC3", "dts": "A_DTS", "truehd": "A_TRUEHD",
    "mp3": "A_MPEG/L3", "subrip": "S_TEXT/UTF8", "ass": "S_TEXT/ASS",
    "ssa": "S_TEXT/SSA", "webvtt": "S_TEXT/WEBVTT", "hdmv_pgs_subtitle": "S_HDMV/PGS",
    "dvd_subtitle": "S_VOBSUB"}.toTable

  moduleKinds = {
    "mptm": "OpenMPT", "mod": "MOD", "s3m": "Scream Tracker 3", "xm": "FastTracker 2",
    "it": "Impulse Tracker", "mo3": "MO3", "669": "Composer 669", "mtm": "MultiTracker",
    "med": "OctaMED", "stm": "Scream Tracker 2", "ult": "UltraTracker",
    "okt": "Oktalyzer", "umx": "Unreal Music", "dbm": "DigiBooster Pro",
    "digi": "DigiBooster", "far": "Farandole Composer", "ptm": "PolyTracker",
    "mt2": "MadTracker 2", "imf": "Imago Orpheus", "symmod": "Symphonie"}.toTable

  lossless = ["flac", "alac", "truehd", "mlp", "wavpack", "ape", "tta"]

  languages = {
    "eng": "English", "en": "English", "jpn": "Japanese", "ja": "Japanese",
    "spa": "Spanish", "es": "Spanish", "fre": "French", "fra": "French", "fr": "French",
    "ger": "German", "deu": "German", "de": "German", "ita": "Italian", "it": "Italian",
    "por": "Portuguese", "pt": "Portuguese", "rus": "Russian", "ru": "Russian",
    "chi": "Chinese", "zho": "Chinese", "zh": "Chinese", "kor": "Korean", "ko": "Korean",
    "ara": "Arabic", "ar": "Arabic", "hin": "Hindi", "dut": "Dutch", "nld": "Dutch",
    "swe": "Swedish", "nor": "Norwegian", "nob": "Norwegian Bokmal", "dan": "Danish",
    "fin": "Finnish", "pol": "Polish", "tur": "Turkish", "gre": "Greek", "ell": "Greek",
    "heb": "Hebrew", "cze": "Czech", "ces": "Czech", "hun": "Hungarian", "tha": "Thai",
    "vie": "Vietnamese", "ind": "Indonesian", "ukr": "Ukrainian", "rum": "Romanian",
    "ron": "Romanian", "cat": "Catalan", "hrv": "Croatian", "srp": "Serbian",
    "slo": "Slovak", "slk": "Slovak", "bul": "Bulgarian", "may": "Malay", "msa": "Malay",
    "fil": "Filipino", "tam": "Tamil", "tel": "Telugu", "per": "Persian", "fas": "Persian",
    "lat": "Latin", "glg": "Galician", "baq": "Basque", "eus": "Basque",
    "ice": "Icelandic", "isl": "Icelandic", "est": "Estonian", "lav": "Latvian",
    "lit": "Lithuanian", "slv": "Slovenian", "zxx": "No linguistic content"}.toTable

  generalTags = {
    "title": "Title", "artist": "Performer", "album_artist": "Album/Performer",
    "album": "Album", "composer": "Composer", "genre": "Genre", "date": "Recorded date",
    "creation_time": "Encoded date", "encoder": "Writing application",
    "encoded_by": "Encoded by", "comment": "Comment", "description": "Description",
    "copyright": "Copyright", "publisher": "Publisher", "track": "Track name/Position",
    "disc": "Part/Position", "language": "Language", "purl": "URL",
    "synopsis": "Synopsis", "show": "TV show", "episode_id": "Episode",
    "season_number": "Season", "lyrics": "Lyrics"}.toTable

  # Technical tags already shown elsewhere (or meaningless to a viewer).
  hiddenTags = ["major_brand", "minor_version", "compatible_brands", "handler_name",
    "vendor_id", "duration", "bps", "number_of_frames", "number_of_bytes",
    "_statistics_tags", "_statistics_writing_app", "_statistics_writing_date_utc",
    "filename", "mimetype"]

# --- value formatting -----------------------------------------------------------

proc thousands(n: int64): string =
  ## 2014 -> "2 014", MediaInfo's digit grouping.
  let s = $abs(n)
  for i, c in s:
    if i > 0 and (s.len - i) mod 3 == 0: result.add ' '
    result.add c
  if n < 0: result = "-" & result

proc fmtBytes*(n: float): string =
  ## Three significant digits: "5.17 MiB", "584 MiB", "1.23 GiB".
  const units = ["Bytes", "KiB", "MiB", "GiB", "TiB"]
  var v = n
  var u = 0
  while v >= 1024 and u < units.high:
    v /= 1024
    inc u
  if u == 0: return &"{n.int64.thousands} Bytes"
  let shown = if v >= 100: $int(round(v)) elif v >= 10: formatFloat(v, ffDecimal, 1)
              else: formatFloat(v, ffDecimal, 2)
  shown & " " & units[u]

proc fmtDuration(t: float): string =
  ## "1 h 23 min", "9 min 44 s", "13 s 81 ms".
  let ms = int(round(t * 1000))
  let (h, m, s, f) = (ms div 3_600_000, ms div 60_000 mod 60, ms div 1000 mod 60, ms mod 1000)
  if h > 0: &"{h} h {m} min"
  elif m > 0: &"{m} min {s} s"
  elif s > 0: &"{s} s {f} ms"
  else: &"{f} ms"

proc fmtClock(t: float): string =
  ## "00:01:23.456", for chapter marks.
  let ms = int(round(t * 1000))
  &"{ms div 3_600_000:02}:{ms div 60_000 mod 60:02}:{ms div 1000 mod 60:02}.{ms mod 1000:03}"

proc fmtBitrate*(bps: float): string =
  let kbps = bps / 1000
  if kbps >= 10_000: formatFloat(kbps / 1000, ffDecimal, 1) & " Mb/s"
  else: thousands(int64(round(kbps))) & " kb/s"

proc fmtRate(hz: int): string =
  ## 48000 -> "48.0 kHz", 44100 -> "44.1 kHz".
  formatFloat(hz / 1000, ffDecimal, if hz mod 100 == 0: 1 else: 3) & " kHz"

proc parseFraction(s: string): float =
  ## "30000/1001" -> 29.97; "24" -> 24; bad input -> 0.
  let parts = s.split('/')
  try:
    if parts.len == 2:
      let d = parseFloat(parts[1])
      if d != 0: return parseFloat(parts[0]) / d
    elif parts.len == 1: return parseFloat(parts[0])
  except ValueError: discard

proc fmtFps(frac: string): string =
  let fps = parseFraction(frac)
  if fps <= 0: return ""
  result = formatFloat(fps, ffDecimal, 3)
  if not frac.endsWith("/1") and '/' in frac: result.add &" ({frac})"
  result.add " FPS"

proc parseClock(s: string): float =
  ## Matroska's DURATION tag: "00:00:13.067000000".
  let parts = s.split(':')
  if parts.len != 3: return 0
  try: parts[0].parseFloat * 3600 + parts[1].parseFloat * 60 + parts[2].parseFloat
  except ValueError: 0

proc language(code: string): string =
  let c = code.toLowerAscii
  if c in ["", "und"]: ""
  else: languages.getOrDefault(c, code)

proc yesNo(b: bool): string = (if b: "Yes" else: "No")

proc prettyKey(k: string): string =
  ## "ENCODED_BY" / "encoded-by" -> "Encoded by".
  result = k.toLowerAscii.multiReplace(("_", " "), ("-", " ")).strip
  if result.len > 0: result[0] = result[0].toUpperAscii

proc formatName(codec: string): string =
  if codec.startsWith("pcm_"): "PCM"
  else: formatNames.getOrDefault(codec, codec.toUpperAscii)

# --- ffprobe JSON helpers ---------------------------------------------------------

proc str(n: JsonNode, key: string): string =
  let v = n{key}
  if v == nil: ""
  else:
    case v.kind
    of JString: v.getStr
    of JInt: $v.getInt
    of JFloat: $v.getFloat
    of JBool: $v.getBool
    else: ""

proc num(n: JsonNode, key: string): float =
  let s = n.str(key)
  try: (if s.len > 0: parseFloat(s) else: 0)
  except ValueError: 0

proc tag(n: JsonNode, name: string): string =
  ## Case-insensitive; also matches mkvmerge's language-suffixed "BPS-eng".
  let tags = n{"tags"}
  if tags == nil or tags.kind != JObject: return ""
  for k, v in tags:
    let lk = k.toLowerAscii
    if lk == name or lk.startsWith(name & "-"): return v.getStr
  ""

proc disposition(n: JsonNode, key: string): bool =
  n{"disposition", key}.getInt(0) != 0

proc probe(path: string): JsonNode =
  ## ffprobe's report for `path`, or nil. Written to a temp file so a large
  ## report can't fill a pipe; killed after ProbeTimeout (network mounts).
  let exe = findExe("ffprobe")
  if exe.len == 0: return nil
  let tmp = getTempDir() / &"majestic-probe-{getCurrentProcessId()}.json"
  try:
    let p = startProcess(exe, args = ["-v", "quiet", "-print_format", "json",
      "-show_format", "-show_streams", "-show_chapters", "-o", tmp, path],
      options = {poParentStreams, poDaemon})  # poDaemon: no console window on Windows
    var waited = 0.0
    while p.peekExitCode == -1 and waited < ProbeTimeout:
      sleep(10)
      waited += 0.01
    let code = p.peekExitCode
    if code == -1: p.kill()
    p.close()
    if code == 0: result = parseFile(tmp)
  except CatchableError: result = nil
  try: removeFile(tmp) except OSError: discard

# --- sections ------------------------------------------------------------------

proc add(s: var InfoSection, k, v: string) =
  if v.len > 0: s.rows.add (k, v)

proc containerFormat(fmt: JsonNode, path: string): string =
  let name = fmt.str("format_name")
  let ext = path.splitFile.ext.toLowerAscii
  if name.startsWith("matroska"): (if ext == ".webm": "WebM" else: "Matroska")
  elif name.startsWith("mov,mp4"): (if ext == ".mov": "QuickTime" else: "MPEG-4")
  else:
    case name
    of "avi": "AVI"
    of "mpegts": "MPEG-TS"
    of "mpeg": "MPEG-PS"
    of "flv": "Flash Video"
    of "ogg": "Ogg"
    of "wav": "Wave"
    of "mp3": "MPEG Audio"
    of "flac": "FLAC"
    of "asf": "Windows Media"
    of "libopenmpt": "Tracker module"
    else: fmt.str("format_long_name")

proc moduleKind(path: string): string =
  ## A tracker module's kind, going by its extension (libopenmpt doesn't
  ## tell FFmpeg): "Impulse Tracker", or "XYZ module" for the rarer ones.
  let ext = path.splitFile.ext.toLowerAscii.strip(chars = {'.'})
  moduleKinds.getOrDefault(ext, ext.toUpperAscii & " module")

proc streamDuration(st: JsonNode): float =
  result = st.num("duration")
  if result <= 0: result = parseClock(st.tag("duration"))

proc streamBitrate(st: JsonNode): float =
  result = st.num("bit_rate")
  if result <= 0:
    try: result = parseFloat(st.tag("bps"))
    except ValueError: discard

proc streamSize(st: JsonNode, fileSize: float): string =
  var bytes = 0.0
  try: bytes = parseFloat(st.tag("number_of_bytes"))
  except ValueError: bytes = st.streamBitrate * st.streamDuration / 8
  if bytes <= 0: return ""
  result = fmtBytes(bytes)
  if fileSize > 0: result.add &" ({int(round(bytes / fileSize * 100))}%)"

proc commonHead(s: var InfoSection, st: JsonNode, matroska: bool) =
  ## ID, Format, Format/Info, Codec ID: shared by every stream kind.
  let id = st.str("id")
  var shown = $(st{"index"}.getInt + 1)
  if id.startsWith("0x"):
    try: shown = $fromHex[int](id) except ValueError: discard
  s.add "ID", shown
  let codec = st.str("codec_name")
  s.add "Format", formatName(codec)
  s.add "Format/Info", st.str("codec_long_name")

proc codecId(s: var InfoSection, st: JsonNode, matroska: bool) =
  let codec = st.str("codec_name")
  let tag = st.str("codec_tag_string")
  if matroska: s.add "Codec ID", matroskaIds.getOrDefault(codec)
  elif tag.len > 0 and not tag.startsWith("["): s.add "Codec ID", tag

proc commonTail(s: var InfoSection, st: JsonNode, fileSize: float) =
  ## Size, title, language, flags and the writing library.
  s.add "Stream size", st.streamSize(fileSize)
  s.add "Title", st.tag("title")
  s.add "Writing library", st.tag("encoder")
  s.add "Language", language(st.tag("language"))
  s.add "Default", yesNo(st.disposition("default"))
  s.add "Forced", yesNo(st.disposition("forced"))
  if st.disposition("hearing_impaired"): s.add "Hearing impaired", "Yes"
  if st.disposition("visual_impaired"): s.add "Visually impaired", "Yes"
  if st.disposition("comment"): s.add "Commentary", "Yes"

proc levelStr(codec: string, level: int): string =
  ## AVC stores 10x the level, HEVC 30x: 42 -> "4.2", 153 -> "5.1".
  let l = if codec == "hevc": level / 30 else: level / 10
  if level <= 0: ""
  elif l == floor(l): $l.int
  else: formatFloat(l, ffDecimal, 1)

proc pixFmtInfo(pf: string): tuple[space, chroma: string, depth: int] =
  if pf.len == 0: return
  result.space =
    if pf.startsWith("yuv") or pf.startsWith("nv") or pf.startsWith("p0") or
       pf.startsWith("p2") or pf.startsWith("p4"): "YUV"
    elif pf.startsWith("gray"): "Y"
    elif pf.startsWith("rgb") or pf.startsWith("bgr") or pf.startsWith("gbr") or
         pf.startsWith("argb") or pf.startsWith("abgr"): "RGB"
    else: ""
  if pf.startsWith("yuva"): result.space = "YUVA"
  for (k, v) in [("420", "4:2:0"), ("422", "4:2:2"), ("444", "4:4:4"),
                 ("411", "4:1:1"), ("440", "4:4:0")]:
    if k in pf: result.chroma = v
  if pf.startsWith("nv12") or pf.startsWith("nv21") or pf.startsWith("p01"):
    result.chroma = "4:2:0"
  for d in [16, 14, 12, 10, 9]:
    if &"p{d}" in pf:
      result.depth = d
      break
  if pf.startsWith("p010"): result.depth = 10
  if result.depth == 0 and result.space in ["YUV", "YUVA", "Y"]: result.depth = 8
  if result.depth == 0 and pf in ["rgb24", "bgr24", "rgba", "bgra", "argb", "abgr", "gbrp"]:
    result.depth = 8

proc colorName(kind, v: string): string =
  case v
  of "", "unknown", "reserved": ""
  of "bt709": "BT.709"
  of "bt2020", "bt2020nc": (if kind == "matrix": "BT.2020 non-constant" else: "BT.2020")
  of "bt2020c": "BT.2020 constant"
  of "bt2020-10", "bt2020-12": "BT.2020"
  of "smpte170m": "BT.601 NTSC"
  of "bt470bg": "BT.601 PAL"
  of "smpte2084": "PQ"
  of "arib-std-b67": "HLG"
  of "iec61966-2-1": "sRGB/sYCC"
  of "smpte432": "Display P3"
  of "gbr": "Identity"
  of "linear": "Linear"
  else: v.toUpperAscii

proc hdrRows(s: var InfoSection, st: JsonNode, transfer: string) =
  var formats: seq[string]
  var mastering, primaries, cll, fall: string
  for sd in st{"side_data_list"}.getElems:
    case sd.str("side_data_type")
    of "DOVI configuration record":
      var dv = &"Dolby Vision, Version {sd.str(\"dv_version_major\")}.{sd.str(\"dv_version_minor\")}" &
        &", Profile {sd.str(\"dv_profile\")}"
      let compat = sd.str("dv_bl_signal_compatibility_id")
      if compat.len > 0 and compat != "0": dv.add "." & compat
      dv.add &", Level {sd.str(\"dv_level\")}"
      var layers: seq[string]
      if sd{"bl_present_flag"}.getInt == 1: layers.add "BL"
      if sd{"el_present_flag"}.getInt == 1: layers.add "EL"
      if sd{"rpu_present_flag"}.getInt == 1: layers.add "RPU"
      if layers.len > 0: dv.add ", " & layers.join("+")
      formats.add dv
    of "Mastering display metadata":
      formats.add "SMPTE ST 2086"
      let rx = parseFraction(sd.str("red_x"))
      primaries =
        if abs(rx - 0.708) < 0.005: "BT.2020"
        elif abs(rx - 0.680) < 0.005: "Display P3"
        elif abs(rx - 0.640) < 0.005: "BT.709"
        elif rx > 0: &"R: x={rx:.4f}"
        else: ""
      let lo = parseFraction(sd.str("min_luminance"))
      let hi = parseFraction(sd.str("max_luminance"))
      if hi > 0: mastering = &"min: {lo:.4f} cd/m2, max: {hi:.0f} cd/m2"
    of "Content light level metadata":
      if sd.num("max_content") > 0: cll = &"{sd.num(\"max_content\").int} cd/m2"
      if sd.num("max_average") > 0: fall = &"{sd.num(\"max_average\").int} cd/m2"
    of "Display Matrix":
      let rot = sd.num("rotation")
      if rot != 0: s.add "Rotation", &"{rot:.0f} degrees"
    else: discard
  if transfer == "smpte2084" and formats.len > 0 and "SMPTE ST 2086" in formats:
    formats[formats.find("SMPTE ST 2086")] = "SMPTE ST 2086, HDR10 compatible"
  elif transfer == "arib-std-b67": formats.add "HLG"
  s.add "HDR format", formats.join(" / ")
  s.add "Mastering display color primaries", primaries
  s.add "Mastering display luminance", mastering
  s.add "Maximum Content Light Level", cll
  s.add "Maximum Frame-Average Light Level", fall

proc videoSection(st: JsonNode, matroska: bool, fileSize: float): InfoSection =
  var s: InfoSection
  s.commonHead(st, matroska)
  let codec = st.str("codec_name")
  let profile = st.str("profile")
  let level = levelStr(codec, st{"level"}.getInt(0))
  s.add "Format profile",
    if profile.len > 0 and level.len > 0 and codec in ["h264", "hevc"]: &"{profile}@L{level}"
    else: profile
  s.codecId(st, matroska)
  let dur = st.streamDuration
  if dur > 0: s.add "Duration", fmtDuration(dur)
  let br = st.streamBitrate
  if br > 0: s.add "Bit rate", fmtBitrate(br)
  let maxBr = st.num("max_bit_rate")
  if maxBr > 0: s.add "Maximum bit rate", fmtBitrate(maxBr)
  let (w, h) = (st{"width"}.getInt(0), st{"height"}.getInt(0))
  if w > 0: s.add "Width", &"{w.thousands} pixels"
  if h > 0: s.add "Height", &"{h.thousands} pixels"
  let dar = st.str("display_aspect_ratio")
  if dar.len > 0 and dar != "0:1":
    s.add "Display aspect ratio",
      if dar in ["16:9", "4:3", "21:9", "1:1", "5:4", "16:10"]: dar
      else: formatFloat(parseFraction(dar.replace(':', '/')), ffDecimal, 3) & ":1"
  let sar = st.str("sample_aspect_ratio")
  if sar.len > 0 and sar notin ["1:1", "0:1"]:
    s.add "Pixel aspect ratio", formatFloat(parseFraction(sar.replace(':', '/')), ffDecimal, 3)
  let avg = st.str("avg_frame_rate")
  let real = st.str("r_frame_rate")
  let fpsFrac = if parseFraction(avg) > 0: avg else: real
  if parseFraction(fpsFrac) > 0:
    s.add "Frame rate mode", (if avg == real or parseFraction(avg) == 0: "Constant" else: "Variable")
    s.add "Frame rate", fmtFps(fpsFrac)
  let frames = st.str("nb_frames")
  let count = if frames.len > 0 and frames != "0": frames else: st.tag("number_of_frames")
  try: s.add "Frame count", thousands(parseBiggestInt(count)) except ValueError: discard
  let pf = pixFmtInfo(st.str("pix_fmt"))
  s.add "Color space", pf.space
  s.add "Chroma subsampling", pf.chroma
  var depth = st.num("bits_per_raw_sample").int
  if depth <= 0: depth = pf.depth
  if depth > 0: s.add "Bit depth", &"{depth} bits"
  s.add "Scan type",
    case st.str("field_order")
    of "progressive": "Progressive"
    of "tt", "tb": "Interlaced (TFF)"
    of "bb", "bt": "Interlaced (BFF)"
    else: ""
  let fps = parseFraction(fpsFrac)
  if br > 0 and w > 0 and h > 0 and fps > 0:
    s.add "Bits/(Pixel*Frame)", formatFloat(br / (w.float * h.float * fps), ffDecimal, 3)
  s.add "Pixel format", st.str("pix_fmt")
  s.commonTail(st, fileSize)
  s.add "Time code of first frame", st.tag("timecode")
  let range = st.str("color_range")
  s.add "Color range", (case range
    of "tv": "Limited"
    of "pc": "Full"
    else: "")
  let transfer = st.str("color_transfer")
  s.add "Color primaries", colorName("primaries", st.str("color_primaries"))
  s.add "Transfer characteristics", colorName("transfer", transfer)
  s.add "Matrix coefficients", colorName("matrix", st.str("color_space"))
  s.add "Chroma sample location", (let cl = st.str("chroma_location");
    if cl in ["", "unspecified"]: "" else: cl.capitalizeAscii)
  s.hdrRows(st, transfer)
  s

proc moduleAudioSection(st: JsonNode): InfoSection =
  ## A tracker module has no audio stream as such: libopenmpt renders the
  ## patterns to PCM as it plays, so that PCM's rate, size and "lossless" say
  ## nothing about the file. Only what it is rendered to.
  var s: InfoSection
  s.add "ID", $(st{"index"}.getInt + 1)
  s.add "Format", "Tracker module"
  s.add "Format/Info", "Rendered by libopenmpt"
  let dur = st.streamDuration
  if dur > 0: s.add "Duration", fmtDuration(dur)
  let ch = st{"channels"}.getInt(0)
  if ch > 0: s.add "Channel(s)", &"{ch} channel" & (if ch == 1: "" else: "s")
  s.add "Channel layout", st.str("channel_layout")
  let sr = st.num("sample_rate").int
  if sr > 0: s.add "Sampling rate", fmtRate(sr)
  s

proc audioSection(st: JsonNode, matroska: bool, fileSize: float): InfoSection =
  var s: InfoSection
  s.commonHead(st, matroska)
  let codec = st.str("codec_name")
  let profile = st.str("profile")
  if codec == "dts" and profile.len > 0: s.add "Commercial name", profile
  elif codec == "eac3": s.add "Commercial name", "Dolby Digital Plus"
  elif codec == "ac3": s.add "Commercial name", "Dolby Digital"
  elif codec == "truehd": s.add "Commercial name", "Dolby TrueHD"
  elif codec == "mp3": s.add "Format profile", "Layer 3"
  if codec != "dts": s.add "Format profile", profile
  s.codecId(st, matroska)
  let dur = st.streamDuration
  if dur > 0: s.add "Duration", fmtDuration(dur)
  let br = st.streamBitrate
  if codec in lossless or codec.startsWith("pcm_"):
    s.add "Bit rate mode", (if codec.startsWith("pcm_"): "Constant" else: "Variable")
  if br > 0: s.add "Bit rate", fmtBitrate(br)
  let maxBr = st.num("max_bit_rate")
  if maxBr > 0: s.add "Maximum bit rate", fmtBitrate(maxBr)
  let ch = st{"channels"}.getInt(0)
  if ch > 0: s.add "Channel(s)", &"{ch} channel" & (if ch == 1: "" else: "s")
  let layout = st.str("channel_layout")
  s.add "Channel layout", layout
  let sr = st.num("sample_rate").int
  if sr > 0: s.add "Sampling rate", fmtRate(sr)
  var depth = st.num("bits_per_raw_sample").int
  if depth <= 0: depth = st{"bits_per_sample"}.getInt(0)
  if depth > 0: s.add "Bit depth", &"{depth} bits"
  s.add "Sample format", st.str("sample_fmt")
  s.add "Compression mode",
    if codec in lossless or codec.startsWith("pcm_"): "Lossless" else: "Lossy"
  s.commonTail(st, fileSize)
  s

proc textSection(st: JsonNode, matroska: bool, fileSize: float): InfoSection =
  var s: InfoSection
  s.commonHead(st, matroska)
  s.codecId(st, matroska)
  let dur = st.streamDuration
  if dur > 0: s.add "Duration", fmtDuration(dur)
  let br = st.streamBitrate
  if br > 0: s.add "Bit rate", fmtBitrate(br)
  let frames = st.tag("number_of_frames")
  s.add "Count of elements", (if frames.len > 0: frames else: (let n = st.str("nb_frames"); if n == "0": "" else: n))
  let (w, h) = (st{"width"}.getInt(0), st{"height"}.getInt(0))
  if w > 0 and h > 0: s.add "Resolution", &"{w} x {h}"
  s.commonTail(st, fileSize)
  s

proc imageSection(st: JsonNode): InfoSection =
  var s: InfoSection
  s.add "Format", formatName(st.str("codec_name"))
  let (w, h) = (st{"width"}.getInt(0), st{"height"}.getInt(0))
  if w > 0: s.add "Width", &"{w.thousands} pixels"
  if h > 0: s.add "Height", &"{h.thousands} pixels"
  let pf = pixFmtInfo(st.str("pix_fmt"))
  s.add "Color space", pf.space
  s.add "Title", st.tag("title")
  s.add "Comment", st.tag("comment")
  s

proc otherSection(st: JsonNode): InfoSection =
  var s: InfoSection
  s.add "ID", $(st{"index"}.getInt + 1)
  let tagStr = st.str("codec_tag_string")
  s.add "Type", (if tagStr == "tmcd": "Time code"
                 elif st.str("codec_long_name").len > 0: st.str("codec_long_name")
                 else: st.str("codec_type").capitalizeAscii)
  s.add "Format", (if tagStr.startsWith("["): st.str("codec_name") else: tagStr)
  let dur = st.streamDuration
  if dur > 0: s.add "Duration", fmtDuration(dur)
  s.add "Time code of first frame", st.tag("timecode")
  s.add "Title", st.tag("title")
  s.add "Language", language(st.tag("language"))
  s

proc generalSection(fmt: JsonNode, streams: seq[JsonNode], path: string): InfoSection =
  var s: InfoSection
  s.add "Complete name", path
  s.add "Format", containerFormat(fmt, path)
  if fmt.str("format_name") == "libopenmpt": s.add "Format/Info", moduleKind(path)
  let brand = fmt.tag("major_brand").strip
  if brand.len > 0 and fmt.str("format_name").startsWith("mov,mp4"):
    var compat: seq[string]
    let c = fmt.tag("compatible_brands")
    var i = 0
    while i + 4 <= c.len:
      compat.add c[i ..< i + 4].strip
      i += 4
    s.add "Codec ID", brand & (if compat.len > 0: &" ({compat.join(\"/\")})" else: "")
  let size = fmt.num("size")
  if size > 0: s.add "File size", fmtBytes(size)
  let dur = fmt.num("duration")
  if dur > 0: s.add "Duration", fmtDuration(dur)
  let br = fmt.num("bit_rate")
  if br > 0: s.add "Overall bit rate", fmtBitrate(br)
  for st in streams:
    if st.str("codec_type") == "video" and not st.disposition("attached_pic"):
      let avg = st.str("avg_frame_rate")
      s.add "Frame rate", fmtFps(if parseFraction(avg) > 0: avg else: st.str("r_frame_rate"))
      break
  var counts: OrderedTable[string, int]
  for st in streams:
    let k = st.str("codec_type")
    if k.len > 0: counts.mgetOrPut(k, 0).inc
  var summary: seq[string]
  for k, n in counts:
    let name = case k
      of "subtitle": "text"
      of "data": "other"
      else: k
    summary.add &"{n} {name}" & (if n == 1 or name == "text": "" else: "s")
  s.add "Streams", summary.join(", ")
  # Known tags first under MediaInfo's names, then whatever else is there.
  let tags = fmt{"tags"}
  if tags != nil and tags.kind == JObject:
    for k, v in tags:
      let lk = k.toLowerAscii
      if lk in hiddenTags: continue
      s.add generalTags.getOrDefault(lk, prettyKey(k)), v.getStr.strip
  var attachments: seq[string]
  for st in streams:
    if st.str("codec_type") == "attachment":
      let name = st.tag("filename")
      attachments.add (if name.len > 0: name else: st.str("codec_name"))
  s.add "Attachments", attachments.join(" / ")
  s

proc menuSection(chapters: seq[(float, string)]): InfoSection =
  var s: InfoSection
  for i, (t, title) in chapters:
    s.rows.add (fmtClock(t), if title.len > 0: title else: &"Chapter {i + 1}")
  s

proc numbered(sections: var seq[InfoSection], kind: string, items: seq[InfoSection]) =
  ## "Audio" alone, or "Audio #1", "Audio #2"... like MediaInfo.
  for i, it in items:
    var s = it
    s.title = if items.len == 1: kind else: &"{kind} #{i + 1}"
    sections.add s

# --- mpv fallback ------------------------------------------------------------------

proc mpvTrackSection(t: JsonNode): InfoSection =
  var s: InfoSection
  s.add "ID", t.str("src-id")
  let codec = t.str("codec")
  s.add "Format", formatName(codec)
  s.add "Format/Info", t.str("codec-desc")
  s.add "Format profile", t.str("codec-profile")
  let br = t.num("demux-bitrate")
  if br > 0: s.add "Bit rate", fmtBitrate(br)
  let (w, h) = (t{"demux-w"}.getInt(0), t{"demux-h"}.getInt(0))
  if w > 0: s.add "Width", &"{w.thousands} pixels"
  if h > 0: s.add "Height", &"{h.thousands} pixels"
  let fps = t.num("demux-fps")
  if fps > 0: s.add "Frame rate", formatFloat(fps, ffDecimal, 3) & " FPS"
  let ch = t{"demux-channel-count"}.getInt(0)
  if ch > 0: s.add "Channel(s)", &"{ch} channel" & (if ch == 1: "" else: "s")
  s.add "Channel layout", t.str("demux-channels")
  let sr = t.num("demux-samplerate").int
  if sr > 0: s.add "Sampling rate", fmtRate(sr)
  s.add "Title", t.str("title")
  s.add "Language", language(t.str("lang"))
  s.add "Default", yesNo(t{"default"}.getBool)
  s.add "Forced", yesNo(t{"forced"}.getBool)
  s.add "External file", t.str("external-filename")
  s

proc mpvSections(h: MpvHandle, path: string): seq[InfoSection] =
  var g = InfoSection(title: "General")
  g.add "Complete name", path
  let format = h.getStr("file-format")
  if format == "libopenmpt":
    g.add "Format", "Tracker module"
    g.add "Format/Info", moduleKind(path)
  else: g.add "Format", format
  let size = h.getInt("file-size", -1)
  if size > 0: g.add "File size", fmtBytes(size.float)
  let dur = h.getFloat("duration")
  if dur > 0: g.add "Duration", fmtDuration(dur)
  if size > 0 and dur > 0: g.add "Overall bit rate", fmtBitrate(size.float * 8 / dur)
  g.add "Title", h.getStr("media-title")
  let meta = h.getNode("metadata")
  if meta.kind == JObject:
    for k, v in meta:
      let lk = k.toLowerAscii
      if lk in hiddenTags or lk == "title": continue
      g.add generalTags.getOrDefault(lk, prettyKey(k)), v.getStr.strip
  result.add g
  var video, audio, text, image: seq[InfoSection]
  for t in h.getNode("track-list").getElems:
    let s = mpvTrackSection(t)
    case t.str("type")
    of "video": (if t{"albumart"}.getBool: image.add s else: video.add s)
    of "audio": audio.add s
    of "sub": text.add s
    else: discard
  result.numbered("Video", video)
  result.numbered("Audio", audio)
  result.numbered("Text", text)
  result.numbered("Image", image)

# --- entry point -------------------------------------------------------------------

proc probedSections(probed: JsonNode, path: string): seq[InfoSection] =
  ## General, Video, Audio, Text, Other and Image sections from ffprobe's report.
  let fmt = probed["format"]
  let streams = probed{"streams"}.getElems
  let matroska = fmt.str("format_name").startsWith("matroska")
  let module = fmt.str("format_name") == "libopenmpt"
  let fileSize = fmt.num("size")
  var g = generalSection(fmt, streams, path)
  g.title = "General"
  result.add g
  var video, audio, text, image, other: seq[InfoSection]
  for st in streams:
    case st.str("codec_type")
    of "video":
      if st.disposition("attached_pic"): image.add imageSection(st)
      else: video.add videoSection(st, matroska, fileSize)
    of "audio":
      audio.add(if module: moduleAudioSection(st) else: audioSection(st, matroska, fileSize))
    of "subtitle": text.add textSection(st, matroska, fileSize)
    of "data": other.add otherSection(st)
    else: discard
  result.numbered("Video", video)
  result.numbered("Audio", audio)
  result.numbered("Text", text)
  result.numbered("Other", other)
  result.numbered("Image", image)

proc fileSections*(path: string): seq[InfoSection] =
  ## The sections of a file not open in mpv: ffprobe's alone, chapters included.
  let probed = if fileExists(path): probe(path) else: nil
  if probed == nil or probed{"format"} == nil: return
  result = probedSections(probed, path)
  var chapters: seq[(float, string)]
  for c in probed{"chapters"}.getElems:
    chapters.add (c.num("start_time"), c.tag("title"))
  if chapters.len > 0:
    var m = menuSection(chapters)
    m.title = "Menu"
    result.add m

proc fileTags*(path: string): seq[(string, string)] =
  ## The container's tags as ffprobe reads them, for files TagLib can't open.
  let probed = if fileExists(path): probe(path) else: nil
  if probed == nil: return
  let tags = probed{"format", "tags"}
  if tags != nil and tags.kind == JObject:
    for k, v in tags:
      if k.toLowerAscii notin hiddenTags: result.add (k.toUpperAscii, v.getStr)

proc gatherMediaInfo*(h: MpvHandle, path: string): seq[InfoSection] =
  ## General, Video, Audio, Text, Other, Image and Menu sections for the open
  ## file, followed by the tracks mpv loaded from other files.
  let probed = if fileExists(path): probe(path) else: nil
  if probed == nil or probed{"format"} == nil:
    result = mpvSections(h, path)
  else:
    result = probedSections(probed, path)
    # Subtitle / audio files loaded beside the main one.
    var ext: seq[InfoSection]
    for t in h.getNode("track-list").getElems:
      if t{"external"}.getBool: ext.add mpvTrackSection(t)
    for i, s in ext:
      var e = s
      e.title = if ext.len == 1: "External track" else: &"External track #{i + 1}"
      result.add e
  # Menu from mpv: it also knows chapters ffprobe can't see (e.g. ordered
  # chapters, or the playlist being a cue sheet).
  var chapters: seq[(float, string)]
  for c in h.getNode("chapter-list").getElems:
    chapters.add (c.num("time"), c.str("title"))
  if chapters.len > 0:
    var m = menuSection(chapters)
    m.title = "Menu"
    result.add m

proc toText*(sections: seq[InfoSection]): string =
  ## MediaInfo's plain-text layout, for the clipboard.
  for i, s in sections:
    if i > 0: result.add "\n"
    result.add s.title & "\n"
    for (k, v) in s.rows:
      result.add k.alignLeft(41) & ": " & v & "\n"
