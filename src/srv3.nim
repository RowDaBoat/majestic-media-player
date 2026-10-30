## YouTube's styled subtitles: colors, fonts, positions, karaoke. They come in
## its own format, srv3 (mpv reads none of it, and yt-dlp's srt and vtt drop
## the styling), so each is fetched with curl into the cache folder and turned
## into ASS. Subtitles without styling stay as they are, in the user's style.

import std/[os, osproc, parsexml, strformat, strutils, tables, xmlparser, xmltree]
from websave import keyOf

const
  PlayW = 1280.0
  PlayH = 720.0
  BaseSize = 37.4    ## sz=100: the player's 16 px at 360 lines, as ASS counts a
                     ## font's size (Roboto's ascent and descent, not its em)
  Fonts = ["Roboto", "Courier New", "Times New Roman", "Lucida Console", "Roboto",
           "Comic Sans MS", "Monotype Corsiva", "Arial"]  ## by fs=
  Header = """[Script Info]
ScriptType: v4.00+
PlayResX: 1280
PlayResY: 720
WrapStyle: 0
ScaledBorderAndShadow: yes
YCbCr Matrix: None

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Text,Roboto,37.4,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,2,0,0,0,1
Style: Box,Roboto,37.4,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,3,1,0,2,0,0,0,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""

type
  Pen = object
    bold, italic, underline: bool
    fg, bg, edge: string     ## RRGGBB
    fgA, bgA: int            ## opacity, 0 to 255
    edgeKind: int            ## et=: 1 hard shadow, 2 bevel, 3 glow, 4 soft shadow
    font, size: int          ## fs=; sz=, 100 the player's own
  Span = tuple[pen: Pen, text: string]
  Anchor = tuple[ap, ah, av: int]

  StyledTrack* = tuple[path, title, lang: string]  ## one turned into ASS
  SubLink* = tuple[url, title, lang: string]  ## a language's srv3
  StyledJob* = ref object
    link*: string
    p: Process                ## nil once finished
    fetching: seq[SubLink]    ## what p is getting
    rest: seq[SubLink]        ## what's left, should the first have styling
    done*: seq[StyledTrack]   ## once finished

const
  DefaultPen = Pen(fg: "FFFFFF", bg: "080808", edge: "222222", fgA: 255, bgA: 191, size: 100)
  DefaultAnchor: Anchor = (7, 50, 100)

proc intAttr(x: XmlNode, name: string, default: int): int =
  try: parseInt(x.attr(name)) except ValueError: default

proc colorAttr(x: XmlNode, name, default: string): string =
  let c = x.attr(name)
  if c.len == 7 and c[0] == '#': c[1 .. ^1].toUpperAscii else: default

proc parsePen(x: XmlNode): Pen =
  let d = DefaultPen
  Pen(bold: x.attr("b") == "1", italic: x.attr("i") == "1", underline: x.attr("u") == "1",
    fg: x.colorAttr("fc", d.fg), bg: x.colorAttr("bc", d.bg), edge: x.colorAttr("ec", d.edge),
    fgA: x.intAttr("fo", d.fgA), bgA: x.intAttr("bo", d.bgA), edgeKind: x.intAttr("et", 0),
    font: x.intAttr("fs", 0), size: x.intAttr("sz", d.size))

proc penStyled(x: XmlNode): bool =
  for name in ["fc", "bc", "et", "fs"]:
    if x.attr(name).len > 0: return true
  x.intAttr("sz", 100) != 100

proc parseAnchor(x: XmlNode): Anchor =
  (clamp(x.intAttr("ap", DefaultAnchor.ap), 0, 8), x.intAttr("ah", DefaultAnchor.ah),
   x.intAttr("av", DefaultAnchor.av))

proc stamp(ms: int): string =
  let cs = ms div 10
  &"{cs div 360000}:{cs div 6000 mod 60:02}:{cs div 100 mod 60:02}.{cs mod 100:02}"

proc assColor(rgb: string): string = "&H" & rgb[4 .. 5] & rgb[2 .. 3] & rgb[0 .. 1] & "&"

proc assAlpha(opacity: int): string =
  &"&H{255 - clamp(opacity, 0, 255):02X}&"

proc escaped(s: string): string =
  ## A line's text as ASS has it; a backslash starts nothing (U+2060 keeps it
  ## from \n and the like).
  s.multiReplace(("\\", "\\⁠"), ("{", "\\{"), ("}", "\\}"), ("\r", ""), ("\n", "\\N"))

proc fontSize(pen: Pen): float =
  ## The player grows text far slower than sz= says.
  BaseSize * (1 + 0.25 * (max(pen.size, 0).float / 100 - 1))

proc textTags(pen: Pen): string =
  ## What a span's text looks like, its background (boxTags) aside. Edges are
  ## the player's, in PlayH's scale: they don't grow with the text.
  let (fg, edge) = (assAlpha(pen.fgA), assColor(pen.edge))
  let edges =
    case pen.edgeKind
    of 1: &"\\bord0\\shad3\\4c{edge}\\4a{fg}"
    of 2: &"\\bord1\\shad0\\3c{edge}\\3a{fg}"
    of 3: &"\\bord1.5\\blur1\\shad0\\3c{edge}\\3a{fg}"
    of 4: &"\\bord0.5\\shad2\\blur2\\3c{edge}\\3a{fg}\\4c{edge}\\4a{fg}"
    else: "\\bord0\\shad0"
  &"\\fn{Fonts[clamp(pen.font, 0, Fonts.high)]}\\fs{fontSize(pen):.1f}" &
    &"\\b{ord(pen.bold)}\\i{ord(pen.italic)}\\u{ord(pen.underline)}" &
    &"\\1c{assColor(pen.fg)}\\1a{fg}{edges}"

proc boxTags(pen: Pen): string =
  ## The same text's size, unseen, over a background.
  &"\\fn{Fonts[clamp(pen.font, 0, Fonts.high)]}\\fs{fontSize(pen):.1f}" &
    &"\\b{ord(pen.bold)}\\i{ord(pen.italic)}\\1a&HFF&\\shad0\\3c{assColor(pen.bg)}\\3a{assAlpha(pen.bgA)}"

proc spansOf(p: XmlNode, pens: Table[string, Pen]): seq[Span] =
  ## A line's text by pen. The zero-width spaces pad it for the player alone.
  let own = pens.getOrDefault(p.attr("p"), DefaultPen)
  template add(pen: Pen, s: string) =
    let text = s.replace("​", "")
    if text.len > 0: result.add (pen, text)
  for c in p:
    if c.kind == xnText: add(own, c.text)
    elif c.kind == xnElement and c.tag == "s":
      add(pens.getOrDefault(c.attr("p"), own), c.innerText)

proc assLine(spans: seq[Span], tags: proc(pen: Pen): string): string =
  ## Spaces at its ends, which ASS would drop, widen a background.
  for i, s in spans:
    var text = escaped(s.text)
    if i == 0:
      var n = 0
      while n < text.len and text[n] == ' ': inc n
      text = "\\h".repeat(n) & text[n .. ^1]
    if i == spans.high:
      var n = text.len
      while n > 0 and text[n - 1] == ' ': dec n
      text = text[0 ..< n] & "\\h".repeat(text.len - n)
    result.add "{" & tags(s.pen) & "}" & text

proc srv3ToAss*(xml: string): string =
  ## An srv3 subtitle as ASS; "" for one with no styling to keep (or none at all).
  let root = try: parseXml(xml, {reportWhitespace})
    except CatchableError: return
  let (head, body) = (root.child("head"), root.child("body"))
  if head == nil or body == nil: return
  var pens: Table[string, Pen]
  var anchors: Table[string, Anchor]
  var styled = false
  for x in head:
    if x.kind != xnElement: continue
    if x.tag == "pen":
      pens[x.attr("id")] = parsePen(x)
      styled = styled or penStyled(x)
    elif x.tag == "wp":
      anchors[x.attr("id")] = parseAnchor(x)
      styled = styled or anchors[x.attr("id")] != DefaultAnchor and x.attr("ap").len > 0
  if not styled: return
  result = Header
  for p in body:
    if p.kind != xnElement or p.tag != "p": continue
    let (start, dur) = (p.intAttr("t", 0), p.intAttr("d", 0))
    let spans = p.spansOf(pens)
    if dur <= 0 or spans.len == 0: continue
    let a = anchors.getOrDefault(p.attr("wp"), DefaultAnchor)
    # \an counts its rows from the bottom; the player keeps 2% clear all around.
    let pos = &"\\an{(2 - a.ap div 3) * 3 + a.ap mod 3 + 1}" &
      &"\\pos({(2 + 0.96 * a.ah.float) * PlayW / 100:.1f},{(2 + 0.96 * a.av.float) * PlayH / 100:.1f})"
    let times = &"{stamp(start)},{stamp(start + dur)}"
    var (seen, box) = (false, false)
    for s in spans:
      seen = seen or s.pen.fgA > 0
      box = box or s.pen.bgA > 0 and s.text.strip.len > 0
    if box:
      result.add &"Dialogue: 0,{times},Box,,0,0,0,,{{{pos}}}{assLine(spans, boxTags)}\n"
    if seen:
      result.add &"Dialogue: 0,{times},Text,,0,0,0,,{{{pos}}}{assLine(spans, textTags)}\n"

proc subsDir(): string = getCacheDir("majestic-media-player") / "subtitles"

proc fetch(j: StyledJob, tracks: seq[SubLink]): bool =
  ## With a list of curl's own: a video can have a hundred languages.
  let start = subsDir() / keyOf(j.link)
  var list = ""
  for t in tracks:
    let name = (start & "." & t.lang & ".srv3").replace("\\", "\\\\")
    list.add &"url = \"{t.url}\"\noutput = \"{name}\"\n"
  try:
    createDir(subsDir())
    writeFile(start & ".curl", list)
    j.p = startProcess("curl", args = ["-fsLg", "--max-time", "60", "-K", start & ".curl"],
      options = {poUsePath, poStdErrToStdOut, poDaemon})
    j.fetching = tracks
    true
  except IOError, OSError: false

proc fetchStyled*(link: string, tracks: seq[SubLink]): StyledJob =
  ## Fetches a link's srv3 subtitles (poll): one first, for most have no
  ## styling and there's no reason to ask for the rest. Nil when there are
  ## none or curl can't be run.
  if tracks.len == 0: return
  result = StyledJob(link: link, rest: tracks[1 .. ^1])
  if not result.fetch(tracks[0 .. 0]): return nil

proc running*(j: StyledJob): bool = j != nil and j.p != nil

proc loading*(j: StyledJob): bool =
  ## Getting the rest of a link now known to have styling.
  j.running and j.done.len > 0

proc poll*(j: StyledJob): bool =
  ## True when it just finished: `done`, those with styling, in the order given.
  if not j.running or j.p.running: return false
  j.p.close()
  j.p = nil
  for t in j.fetching:
    let src = subsDir() / keyOf(j.link) & "." & t.lang & ".srv3"
    try:
      let ass = srv3ToAss(readFile(src))
      if ass.len > 0:
        writeFile(src.changeFileExt("ass"), ass)
        j.done.add (src.changeFileExt("ass"), t.title, t.lang)
    except IOError: discard  # a language curl couldn't get
    discard tryRemoveFile(src)
  if j.done.len > 0 and j.rest.len > 0 and j.fetch(j.rest):
    j.rest.setLen 0
    return false
  discard tryRemoveFile(subsDir() / keyOf(j.link) & ".curl")
  true

proc cancel*(j: StyledJob) =
  if not j.running: return
  try: j.p.terminate(); j.p.close()
  except OSError: discard
  j.p = nil
