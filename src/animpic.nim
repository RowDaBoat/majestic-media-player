## An animated picture's frames (GIF, APNG, WebP), for a cover that moves:
## mpv shows a picture track's first frame only, and FFmpeg can't decode an
## animated WebP at all. Frames are decoded as they come due and laid on the
## canvas, the composed frames kept while they all fit a memory budget, else
## composed again each time around. Frames come opaque, over black.
##
## GIFs are gifanim's. APNG frames are made into PNGs of their own for
## pixie's decoder (16-bit and interlaced ones stay still: pixie reads
## neither). WebP goes through libwebp's animation decoder, `dlopen`ed;
## without it an animated WebP can't be shown (`webpMissing`).

import std/[dynlib, strutils]
import pixie, pixie/fileformats/png
import gifanim

type
  ApngFrame = object
    x, y, w, h: int
    dispose, blend: int       ## 1: region cleared after, 2: undone after; blend 1: over
    delay: float
    data: seq[string]         ## its IDAT / fdAT payloads (fdAT's sequence numbers off)

  WebPData = object
    bytes: pointer
    size: csize_t

  WebPAnimDecoderOptions = object
    colorMode: cint
    useThreads: cint
    padding: array[7, uint32]

  WebPAnimInfo = object
    canvasWidth, canvasHeight, loopCount, bgcolor, frameCount: uint32
    pad: array[4, uint32]

  WebpDecObj = object
    dec: pointer
    data: string              ## libwebp reads it in place: kept while dec is

  WebpDec = ref WebpDecObj

  Kind = enum kGif, kApng, kWebp

  AnimPic* = ref object
    w*, h*: int               ## the canvas, pixels
    delays: seq[float]        ## seconds each frame stays up
    case kind: Kind
    of kGif: gif: GifAnim
    of kApng:
      ihdr: string            ## IHDR's 13 bytes
      shared: string          ## PLTE and tRNS chunks, whole, for each frame's PNG
      frames: seq[ApngFrame]
      straight: seq[uint32]   ## the canvas, alpha not yet over black
      saved: seq[uint32]      ## it before a frame to undo (dispose 2)
    of kWebp: webp: WebpDec
    canvas: seq[uint32]       ## the frame at `at`, over black
    at: int                   ## -1 for none yet
    cacheable: bool           ## every composed frame fits CacheBudget
    cache: seq[seq[uint32]]   ## composed frames 0 ..< cache.len

const
  CacheBudget = 64 shl 20     ## bytes of composed frames kept
  MaxPixels = 4096 * 4096     ## bigger canvases aren't animated
  Black = 0xFF000000'u32
  PngSig = "\x89PNG\r\n\x1a\n"
  WebpAbi = 0x0107            ## WEBP_DEMUX_ABI_VERSION: the major byte must match
  ModeRgbAPremul = 7          ## MODE_rgbA: alpha already multiplied in

# --- libwebp -------------------------------------------------------------------

var
  webpTried, webpOk: bool
  optionsInit: proc (o: ptr WebPAnimDecoderOptions, abi: cint): cint {.cdecl.}
  decoderNew: proc (d: ptr WebPData, o: ptr WebPAnimDecoderOptions, abi: cint): pointer {.cdecl.}
  decoderInfo: proc (dec: pointer, info: ptr WebPAnimInfo): cint {.cdecl.}
  decoderNext: proc (dec: pointer, buf: ptr ptr UncheckedArray[uint32], ts: ptr cint): cint {.cdecl.}
  decoderReset: proc (dec: pointer) {.cdecl.}
  decoderDelete: proc (dec: pointer) {.cdecl, raises: [].}

proc loadWebp(): bool =
  ## libwebpdemux's animation decoder, false when it's missing.
  if webpTried: return webpOk
  webpTried = true
  let names = when defined(windows): @["libwebpdemux-2.dll", "libwebpdemux.dll"]
              elif defined(macosx): @["libwebpdemux.2.dylib", "libwebpdemux.dylib"]
              else: @["libwebpdemux.so.2", "libwebpdemux.so"]
  var lib: LibHandle
  for n in names:
    lib = loadLib(n)
    if lib != nil: break
  if lib == nil: return false
  template sym(v: untyped, name: string) =
    let p = lib.symAddr(name)
    if p == nil: return false
    v = cast[typeof(v)](p)
  sym optionsInit, "WebPAnimDecoderOptionsInitInternal"
  sym decoderNew, "WebPAnimDecoderNewInternal"
  sym decoderInfo, "WebPAnimDecoderGetInfo"
  sym decoderNext, "WebPAnimDecoderGetNext"
  sym decoderReset, "WebPAnimDecoderReset"
  sym decoderDelete, "WebPAnimDecoderDelete"
  webpOk = true
  true

proc `=destroy`(d: WebpDecObj) =
  if d.dec != nil: decoderDelete(d.dec)
  `=destroy`(d.data)

proc `=copy`(a: var WebpDecObj, b: WebpDecObj) {.error.}

# --- reading -------------------------------------------------------------------

proc be32(s: string, i: int): int =
  s[i].ord shl 24 or s[i + 1].ord shl 16 or s[i + 2].ord shl 8 or s[i + 3].ord

proc be16(s: string, i: int): int = s[i].ord shl 8 or s[i + 1].ord

proc le24(s: string, i: int): int = s[i].ord or s[i + 1].ord shl 8 or s[i + 2].ord shl 16

proc le32(s: string, i: int): int = le24(s, i) or s[i + 3].ord shl 24

proc seconds(d: float): float =
  ## As browsers do, a frame of 10 ms or less stays up a tenth of a second.
  if d <= 0.0105: 0.1 else: d

proc apngInfo(data: string): AnimPic =
  ## The APNG in data, read into its frames' compressed data; nil unless it
  ## has frames to step through (a plain PNG or a single frame is mpv's).
  if not data.startsWith(PngSig): return nil
  var (i, animated, idat) = (8, false, false)
  let a = AnimPic(kind: kApng, at: -1)
  while i + 12 <= data.len:
    let n = be32(data, i)
    let kind = data[i + 4 ..< i + 8]
    if n < 0 or i + 12 + n > data.len: break
    let c = data[i + 8 ..< i + 8 + n]
    case kind
    of "IHDR":
      if n == 13: a.ihdr = c
    of "acTL": animated = true
    of "PLTE", "tRNS":
      if not idat: a.shared.add data[i ..< i + 12 + n]
    of "fcTL":
      if n >= 26:
        let den = be16(c, 22)
        a.frames.add ApngFrame(w: be32(c, 4), h: be32(c, 8), x: be32(c, 12), y: be32(c, 16),
          delay: seconds(be16(c, 20) / (if den == 0: 100 else: den)),
          dispose: c[24].ord, blend: c[25].ord)
    of "IDAT":
      idat = true
      # Before any fcTL it's a default image outside the animation.
      if a.frames.len > 0: a.frames[^1].data.add c
    of "fdAT":
      if a.frames.len > 0 and n > 4: a.frames[^1].data.add c[4 .. ^1]
    of "IEND": break
    else: discard
    i += 12 + n
  if not animated or a.ihdr.len != 13: return nil
  a.w = be32(a.ihdr, 0)
  a.h = be32(a.ihdr, 4)
  var kept: seq[ApngFrame]
  for f in a.frames:
    if f.data.len > 0 and f.w > 0 and f.h > 0 and f.x >= 0 and f.y >= 0: kept.add f
  a.frames = kept
  if a.frames.len < 2 or a.w <= 0 or a.h <= 0 or a.w * a.h > MaxPixels: return nil
  for f in a.frames: a.delays.add f.delay
  a

proc webpInfo(data: string): tuple[animated: bool, w, h: int, delays: seq[float]] =
  ## An animated WebP's canvas and frame durations, read from its chunks.
  if data.len < 30 or data[0 ..< 4] != "RIFF" or data[8 ..< 12] != "WEBP": return
  var i = 12
  while i + 8 <= data.len:
    let kind = data[i ..< i + 4]
    let n = le32(data, i + 4)
    if n < 0 or i + 8 + n > data.len: break
    if kind == "VP8X" and n >= 10:
      result.animated = (data[i + 8].ord and 0x02) != 0
      result.w = le24(data, i + 12) + 1
      result.h = le24(data, i + 15) + 1
    elif kind == "ANMF" and n >= 16:
      result.delays.add seconds(le24(data, i + 20) / 1000)
    i += 8 + n + (n and 1)  # chunks are padded to an even size

proc isAnimatedWebp*(data: string): bool =
  ## mpv can't show it (FFmpeg reads no ANMF chunks), not even its first frame.
  webpInfo(data).animated

proc webpMissing*(data: string): bool =
  ## An animated WebP, and no libwebp to show it with.
  data.isAnimatedWebp and not loadWebp()

proc readWebp(data: string): AnimPic =
  let info = webpInfo(data)
  if not info.animated or info.delays.len == 0 or not loadWebp(): return nil
  if info.w * info.h > MaxPixels: return nil
  let d = WebpDec(data: data)
  var opts: WebPAnimDecoderOptions
  if optionsInit(opts.addr, WebpAbi) == 0: return nil
  opts.colorMode = ModeRgbAPremul
  var wd = WebPData(bytes: d.data[0].addr, size: d.data.len.csize_t)
  d.dec = decoderNew(wd.addr, opts.addr, WebpAbi)
  if d.dec == nil: return nil
  var ai: WebPAnimInfo
  if decoderInfo(d.dec, ai.addr) == 0: return nil
  result = AnimPic(kind: kWebp, webp: d, w: ai.canvasWidth.int, h: ai.canvasHeight.int, at: -1,
                   delays: info.delays)
  # The decoder's count rules: chunks it skips aren't frames.
  result.delays.setLen ai.frameCount.int
  for k in info.delays.len ..< result.delays.len: result.delays[k] = 0.1

proc len*(a: AnimPic): int = a.delays.len

proc delay*(a: AnimPic, i: int): float = a.delays[i]

# --- composing -----------------------------------------------------------------

var crcTable: array[256, uint32]
for n in 0 ..< 256:
  var c = n.uint32
  for _ in 0 ..< 8: c = if (c and 1) != 0: 0xEDB88320'u32 xor (c shr 1) else: c shr 1
  crcTable[n] = c

proc crc(s: string): uint32 =
  result = 0xFFFFFFFF'u32
  for ch in s: result = crcTable[(result xor ch.ord.uint32) and 0xFF] xor (result shr 8)
  result = result xor 0xFFFFFFFF'u32

proc chunk(kind, data: string): string =
  proc u32(v: uint32): string =
    result = newString(4)
    for k in 0 ..< 4: result[k] = chr((v shr (24 - 8 * k)) and 0xFF)
  u32(data.len.uint32) & kind & data & u32(crc(kind & data))

proc framePng(a: AnimPic, f: ApngFrame): string =
  ## Frame f as a PNG of its own: the file's header at the frame's size.
  var ihdr = a.ihdr
  for k in 0 ..< 4:
    ihdr[k] = chr((f.w shr (24 - 8 * k)) and 0xFF)
    ihdr[4 + k] = chr((f.h shr (24 - 8 * k)) and 0xFF)
  result = PngSig & chunk("IHDR", ihdr) & a.shared
  for d in f.data: result.add chunk("IDAT", d)
  result.add chunk("IEND", "")

proc decodes(a: AnimPic): bool =
  ## pixie reads the first frame (16-bit and interlaced PNGs it can't).
  try:
    discard decodePng(a.framePng(a.frames[0]))
    true
  except PixieError: false

proc overBlack(p: uint32): uint32 =
  let al = p shr 24
  if al == 255: return p
  let r = (p and 0xFF) * al div 255
  let g = ((p shr 8) and 0xFF) * al div 255
  let b = ((p shr 16) and 0xFF) * al div 255
  r or g shl 8 or b shl 16 or Black

proc blendOver(dst, src: uint32): uint32 =
  ## src laid over dst, both with straight alpha.
  let sa = src shr 24
  if sa == 255: return src
  if sa == 0: return dst
  let da = (dst shr 24) * (255 - sa) div 255
  let oa = sa + da
  result = oa shl 24
  for sh in [0'u32, 8, 16]:
    let c = (((src shr sh) and 0xFF) * sa + ((dst shr sh) and 0xFF) * da) div oa
    result = result or c shl sh

proc composeApng(a: AnimPic, k: int) =
  ## Lays frame k on the canvas, which holds frame k - 1 (or nothing at 0).
  if k == 0:
    a.straight = newSeq[uint32](a.w * a.h)  # transparent black
    a.saved.setLen 0
  else:
    let p = a.frames[k - 1]
    if p.dispose == 1:
      for y in p.y ..< min(a.h, p.y + p.h):
        for x in p.x ..< min(a.w, p.x + p.w): a.straight[y * a.w + x] = 0
    elif p.dispose == 2 and a.saved.len == a.straight.len:
      a.straight = a.saved
  let f = a.frames[k]
  if f.dispose == 2: a.saved = a.straight  # at 0: the empty canvas, as the spec has it
  try:
    let png = decodePng(a.framePng(f))
    for y in 0 ..< min(png.height, a.h - f.y):
      for x in 0 ..< min(png.width, a.w - f.x):
        let c = png.data[y * png.width + x]
        let s = c.r.uint32 or c.g.uint32 shl 8 or c.b.uint32 shl 16 or c.a.uint32 shl 24
        let i = (f.y + y) * a.w + f.x + x
        a.straight[i] = if f.blend == 0: s else: blendOver(a.straight[i], s)
  except PixieError: discard  # a broken frame: the one before stays up
  a.canvas.setLen a.w * a.h
  for i, p in a.straight: a.canvas[i] = overBlack(p)

proc composeWebp(a: AnimPic, k: int) =
  ## libwebp's next frame (k), its alpha already multiplied in: over black
  ## once alpha's dropped.
  if k == 0: decoderReset(a.webp.dec)
  var buf: ptr UncheckedArray[uint32]
  var ts: cint
  a.canvas.setLen a.w * a.h
  if decoderNext(a.webp.dec, buf.addr, ts.addr) == 0: return  # broken: the one before stays up
  for i in 0 ..< a.canvas.len: a.canvas[i] = buf[i] or Black

proc readAnimPic*(data: string): AnimPic =
  ## The animated picture in data, nil unless it is one with frames to step
  ## through that can be read: a still one is mpv's alone.
  if data.startsWith("GIF8"):
    let g = readGif(data)
    if g == nil: return nil
    result = AnimPic(kind: kGif, gif: g, w: g.w, h: g.h, at: -1)
    for i in 0 ..< g.len: result.delays.add g.delay(i)
    return
  result = apngInfo(data)
  if result != nil and not result.decodes: result = nil
  if result == nil: result = readWebp(data)
  if result != nil: result.cacheable = result.w * result.h * 4 * result.len <= CacheBudget

proc frame*(a: AnimPic, i: int): ptr uint32 =
  ## Frame i's pixels (w * h, RGBA), until the next call.
  if a.kind == kGif: return a.gif.frame(i)
  if i < a.cache.len: return a.cache[i][0].addr
  if i <= a.at: a.at = -1  # around again, uncached: from the start
  while a.at < i:
    inc a.at
    if a.kind == kApng: a.composeApng(a.at) else: a.composeWebp(a.at)
    if a.cacheable and a.cache.len == a.at: a.cache.add a.canvas
  a.canvas[0].addr

proc firstFramePng*(a: AnimPic): string =
  ## The first frame as a PNG, for mpv to show (and fit the window to)
  ## where it can't read the picture itself.
  let img = newImage(a.w, a.h)
  let p = a.frame(0)
  let px = cast[ptr UncheckedArray[uint32]](p)
  for i in 0 ..< a.w * a.h:
    let c = px[i]
    img.data[i] = rgbx(uint8(c and 0xFF), uint8((c shr 8) and 0xFF), uint8((c shr 16) and 0xFF), 255)
  encodePng(img)
