## BMP decoding as Windows' LoadImage read them for AVS's image effects: every
## header (OS/2 core, info, v4/v5), 1/4/8-bit palettes, RLE4 and RLE8, 16-bit
## 555 and bitfields, 24 and 32-bit. pixie refuses RLE, 16-bit and some 4-bit
## files, and packs ship plenty of those (Whacko AVS 6's sprites are RLE8).

type BmpError* = object of CatchableError

proc u16(d: openArray[byte], p: int): int =
  if p < 0 or p + 2 > d.len: raise newException(BmpError, "truncated BMP")
  int(d[p]) or (int(d[p + 1]) shl 8)

proc u32(d: openArray[byte], p: int): uint32 =
  if p < 0 or p + 4 > d.len: raise newException(BmpError, "truncated BMP")
  uint32(d[p]) or (uint32(d[p + 1]) shl 8) or (uint32(d[p + 2]) shl 16) or (uint32(d[p + 3]) shl 24)

proc i32(d: openArray[byte], p: int): int = int(cast[int32](u32(d, p)))

proc isBmp*(d: openArray[byte]): bool = d.len >= 2 and d[0] == byte('B') and d[1] == byte('M')

proc channel(v, mask: uint32): uint32 =
  ## The bits of mask in v, scaled to 0..255 by repeating them, as GDI widens
  ## 5-bit colors (0x1f to 0xff).
  if mask == 0: return 0
  var shift = 0
  while ((mask shr shift) and 1) == 0: inc shift
  var bits = 0
  while bits + shift < 32 and ((mask shr (shift + bits)) and 1) == 1: inc bits
  let x = (v and mask) shr shift
  if bits >= 8: return x shr (bits - 8)
  result = 0
  var have = 0
  while have < 8:
    let s = 8 - have - bits
    result = result or (if s >= 0: x shl s else: x shr -s)
    have += bits
  result = result and 0xff

proc decodeBmp*(d: openArray[byte]): tuple[w, h: int, px: seq[uint32]] =
  ## 0x00RRGGBB pixels, rows top to bottom. Raises BmpError on what it can't read.
  if not isBmp(d): raise newException(BmpError, "not a BMP")
  let dataOff = int(u32(d, 10))
  let hs = int(u32(d, 14))
  var w, h, bpp, compression, nColors: int
  var palEntry = 4
  var masks: array[3, uint32]
  var haveMasks = false
  if hs == 12:  # OS/2 BITMAPCOREHEADER
    w = u16(d, 18); h = cast[int16](u16(d, 20)).int; bpp = u16(d, 24)
    palEntry = 3
  elif hs >= 40:
    w = i32(d, 18); h = i32(d, 22); bpp = u16(d, 28)
    compression = int(u32(d, 30)); nColors = int(u32(d, 46))
    if compression in [3, 6]:  # BITFIELDS, ALPHABITFIELDS: after the header, or in it (v4/v5)
      for k in 0 .. 2: masks[k] = u32(d, 14 + 40 + k * 4)
      haveMasks = true
  else: raise newException(BmpError, "unknown BMP header")
  let topDown = h < 0
  h = abs(h)
  if w <= 0 or h <= 0 or w > 16384 or h > 16384: raise newException(BmpError, "bad BMP size")
  # The palette.
  var pal: seq[uint32]
  if bpp <= 8:
    let n = if nColors > 0 and nColors <= (1 shl bpp): nColors else: 1 shl bpp
    var p = 14 + hs + (if haveMasks and hs == 40: 12 else: 0)
    for k in 0 ..< n:
      if p + 3 > d.len: break
      pal.add (uint32(d[p + 2]) shl 16) or (uint32(d[p + 1]) shl 8) or uint32(d[p])
      p += palEntry
    while pal.len < (1 shl bpp): pal.add 0
  result.w = w
  result.h = h
  result.px = newSeq[uint32](w * h)
  template put(x, y: int, c: uint32) =
    if x >= 0 and x < w and y >= 0 and y < h:
      let row = if topDown: y else: h - 1 - y
      result.px[row * w + x] = c
  case compression
  of 1, 2:  # RLE8, RLE4: rows bottom up, runs and absolute stretches; skipped pixels stay black
    let four = compression == 2
    var p = dataOff
    var x = 0
    var y = 0
    while p + 1 < d.len and y < h:
      let a = int(d[p])
      let b = int(d[p + 1])
      p += 2
      if a > 0:  # a run of a pixels
        for k in 0 ..< a:
          let idx = if four: (if (k and 1) == 0: b shr 4 else: b and 15) else: b
          put(x, y, pal[idx])
          inc x
      elif b == 0: (x = 0; inc y)       # end of line
      elif b == 1: break                # end of bitmap
      elif b == 2:                      # delta
        if p + 1 >= d.len: break
        x += int(d[p]); y += int(d[p + 1]); p += 2
      else:                             # b literal pixels, padded to words
        let bytes = if four: (b + 1) div 2 else: b
        for k in 0 ..< b:
          let q = p + (if four: k div 2 else: k)
          if q >= d.len: break
          let idx = if four: (if (k and 1) == 0: int(d[q]) shr 4 else: int(d[q]) and 15) else: int(d[q])
          put(x, y, pal[idx])
          inc x
        p += bytes + (bytes and 1)
  of 0, 3, 6:
    if bpp notin [1, 2, 4, 8, 16, 24, 32]: raise newException(BmpError, "unsupported BMP bit count")
    if not haveMasks:
      if bpp == 16: masks = [0x7c00'u32, 0x03e0, 0x001f]
      elif bpp == 32: masks = [0xff0000'u32, 0x00ff00, 0x0000ff]
    let stride = ((w * bpp + 31) div 32) * 4
    for y in 0 ..< h:
      let rowStart = dataOff + y * stride
      for x in 0 ..< w:
        var c = 0'u32
        case bpp
        of 1, 2, 4, 8:
          let bit = x * bpp
          let q = rowStart + bit div 8
          if q >= d.len: continue
          let idx = (int(d[q]) shr (8 - bpp - (bit and 7))) and ((1 shl bpp) - 1)
          c = pal[idx]
        of 16:
          let q = rowStart + x * 2
          if q + 2 > d.len: continue
          let v = uint32(u16(d, q))
          c = (channel(v, masks[0]) shl 16) or (channel(v, masks[1]) shl 8) or channel(v, masks[2])
        of 24:
          let q = rowStart + x * 3
          if q + 3 > d.len: continue
          c = (uint32(d[q + 2]) shl 16) or (uint32(d[q + 1]) shl 8) or uint32(d[q])
        else:
          let q = rowStart + x * 4
          if q + 4 > d.len: continue
          let v = u32(d, q)
          c = (channel(v, masks[0]) shl 16) or (channel(v, masks[1]) shl 8) or channel(v, masks[2])
        put(x, y, c)
  else: raise newException(BmpError, "unsupported BMP compression")
