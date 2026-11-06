## An animated GIF's frames, for a cover that moves: mpv shows a picture
## track's first frame only. The file is read once into its frames'
## compressed data; each frame is then decoded and laid on the canvas as it
## comes due (a GIF's frames mostly hold what changed), the composed frames
## kept while they all fit a memory budget, else composed again each time
## around. Where nothing was ever drawn, the canvas is black: the frame's.

type
  GifFrame = object
    x, y, w, h: int
    interlaced: bool
    palette: seq[uint32]      ## RGBA, R in the low byte (GL_RGBA bytes)
    transparent: int          ## the palette index left undrawn, -1 for none
    disposal: int             ## what becomes of it before the next: 2 cleared, 3 undone
    delay: float              ## seconds it stays up
    minCode: int              ## LZW's
    data: string              ## the image's LZW sub-blocks, joined

  GifAnim* = ref object
    w*, h*: int               ## the canvas (mpv's picture), pixels
    frames: seq[GifFrame]
    canvas: seq[uint32]
    saved: seq[uint32]        ## the canvas before a frame to undo (disposal 3)
    at: int                   ## the frame on the canvas, -1 for none yet
    indexes: seq[uint8]       ## a frame's decoded palette indexes
    cacheable: bool           ## every composed frame fits CacheBudget
    cache: seq[seq[uint32]]   ## composed frames 0 ..< cache.len

const
  CacheBudget = 64 shl 20     ## bytes of composed frames kept
  MaxPixels = 4096 * 4096     ## bigger canvases aren't animated
  Black = 0xFF000000'u32

proc le16(s: string, i: int): int = s[i].ord or s[i + 1].ord shl 8

proc palette(s: string, i, n: int): seq[uint32] =
  for k in 0 ..< n:
    let p = i + k * 3
    result.add s[p].ord.uint32 or s[p + 1].ord.uint32 shl 8 or s[p + 2].ord.uint32 shl 16 or Black

proc subBlocks(s: string, i: var int): string =
  ## The sub-blocks at s[i] joined, i left after their terminator.
  while i < s.len:
    let n = s[i].ord
    inc i
    if n == 0: return
    result.add s[i ..< min(s.len, i + n)]
    i += n

proc readGif*(data: string): GifAnim =
  ## The GIF in data, nil unless it is one with frames to step through: a
  ## still one is mpv's alone. A file cut short keeps the frames it has.
  if data.len < 13 or data[0 ..< 6] notin ["GIF87a", "GIF89a"]: return nil
  let g = GifAnim(w: le16(data, 6), h: le16(data, 8), at: -1)
  if g.w <= 0 or g.h <= 0 or g.w * g.h > MaxPixels: return nil
  var i = 13
  var global: seq[uint32]
  let flags = data[10].ord
  if (flags and 0x80) != 0:
    let n = 2 shl (flags and 7)
    if i + n * 3 > data.len: return nil
    global = palette(data, i, n)
    i += n * 3
  var (transparent, disposal, delay) = (-1, 0, 0)
  while i < data.len:
    let kind = data[i]
    inc i
    case kind
    of '\x21':  # extension: a graphic control one sets up the next frame
      if i >= data.len: break
      let label = data[i]
      inc i
      let b = subBlocks(data, i)
      if label == '\xF9' and b.len >= 4:
        disposal = (b[0].ord shr 2) and 7
        delay = le16(b, 1)
        transparent = if (b[0].ord and 1) != 0: b[3].ord else: -1
    of '\x2C':  # image
      if i + 9 > data.len: break
      var f = GifFrame(x: le16(data, i), y: le16(data, i + 2), w: le16(data, i + 4),
        h: le16(data, i + 6), transparent: transparent, disposal: disposal,
        # As browsers do: 0 or 1 hundredths is a tenth of a second.
        delay: (if delay <= 1: 10 else: delay) / 100)
      let ff = data[i + 8].ord
      f.interlaced = (ff and 0x40) != 0
      i += 9
      if (ff and 0x80) != 0:
        let n = 2 shl (ff and 7)
        if i + n * 3 > data.len: break
        f.palette = palette(data, i, n)
        i += n * 3
      else: f.palette = global
      if i >= data.len: break
      f.minCode = data[i].ord
      inc i
      f.data = subBlocks(data, i)
      if f.minCode in 1 .. 11 and f.w > 0 and f.h > 0: g.frames.add f
      (transparent, disposal, delay) = (-1, 0, 0)
    else: break  # the trailer (0x3B), or something unreadable
  if g.frames.len < 2: return nil
  g.cacheable = g.w * g.h * 4 * g.frames.len <= CacheBudget
  g

proc len*(g: GifAnim): int = g.frames.len

proc delay*(g: GifAnim, i: int): float = g.frames[i].delay

proc decode(f: GifFrame, o: var seq[uint8]): int =
  ## The frame's palette indexes into o, in the order stored; how many came
  ## (fewer when the data ends early or is broken).
  let n = f.w * f.h
  if o.len < n: o.setLen n
  let clear = 1 shl f.minCode
  var prefix: array[4096, uint16]
  var suffix: array[4096, uint8]
  var stack: array[4097, uint8]
  var (size, next, old, first) = (f.minCode + 1, clear + 2, -1, 0'u8)
  var (acc, bits, pos) = (0'u32, 0, 0)
  while result < n:
    while bits < size:
      if pos >= f.data.len: return
      acc = acc or (f.data[pos].ord.uint32 shl bits)
      bits += 8
      inc pos
    let code = int(acc and ((1'u32 shl size) - 1))
    acc = acc shr size
    bits -= size
    if code == clear:
      (size, next, old) = (f.minCode + 1, clear + 2, -1)
      continue
    if code == clear + 1: return  # end of information
    if old < 0:
      if code >= clear: return
      o[result] = code.uint8
      inc result
      (old, first) = (code, code.uint8)
      continue
    var (c, sp) = (code, 0)
    if code >= next:  # the code being made: old's string plus its first byte
      if code > next: return
      stack[sp] = first
      inc sp
      c = old
    while c >= clear:
      stack[sp] = suffix[c]
      inc sp
      c = prefix[c].int
    stack[sp] = c.uint8
    inc sp
    first = c.uint8
    while sp > 0 and result < n:
      dec sp
      o[result] = stack[sp]
      inc result
    if next < 4096:
      prefix[next] = old.uint16
      suffix[next] = first
      inc next
      if next == 1 shl size and size < 12: inc size
    old = code

proc rows(f: GifFrame): seq[int] =
  ## The frame's row each stored row goes to.
  if not f.interlaced:
    for y in 0 ..< f.h: result.add y
    return
  for (start, step) in [(0, 8), (4, 8), (2, 4), (1, 2)]:
    var y = start
    while y < f.h:
      result.add y
      y += step

proc compose(g: GifAnim, k: int) =
  ## Lays frame k on the canvas, which holds frame k - 1 (or nothing at 0).
  if k == 0:
    g.canvas.setLen g.w * g.h
    for p in g.canvas.mitems: p = Black
  else:
    let p = g.frames[k - 1]
    if p.disposal == 2:
      for y in max(0, p.y) ..< min(g.h, p.y + p.h):
        for x in max(0, p.x) ..< min(g.w, p.x + p.w): g.canvas[y * g.w + x] = Black
    elif p.disposal == 3 and g.saved.len == g.canvas.len:
      g.canvas = g.saved
  let f = g.frames[k]
  if f.disposal == 3: g.saved = g.canvas
  let got = f.decode(g.indexes)
  let rows = f.rows
  for i in 0 ..< got:
    let (y, x) = (f.y + rows[i div f.w], f.x + i mod f.w)
    let c = g.indexes[i].int
    if c == f.transparent or c >= f.palette.len or x >= g.w or y >= g.h: continue
    g.canvas[y * g.w + x] = f.palette[c]
  g.at = k
  if g.cacheable and g.cache.len == k: g.cache.add g.canvas

proc frame*(g: GifAnim, i: int): ptr uint32 =
  ## Frame i's pixels (w * h, RGBA), until the next call.
  if i < g.cache.len: return g.cache[i][0].addr
  if i <= g.at: g.at = -1  # around again, uncached: from the start
  while g.at < i: g.compose(g.at + 1)
  g.canvas[0].addr
