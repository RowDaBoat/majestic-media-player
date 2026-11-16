## Westwood Studios' .aud sound (Command & Conquer, Red Alert, Lands of
## Lore...). FFmpeg reads it (its wsaud demuxer), with two faults:
##
## - Its length is guessed from the bit rate, counting the chunk headers
##   as sound: about 1.5% too long, the seek bar ending seconds after the
##   sound. The header holds the true length (`audLength`).
## - IMA ADPCM (codec 99) carries the decoder's step size from chunk to
##   chunk, with nothing in the file to pick it up from: after a seek
##   FFmpeg starts again from the smallest step, and the sound comes out
##   ~25 dB quieter until a quiet passage happens to bring the two back
##   together.
##
## So an IMA file opens as `mmpaud://N` (`prepare`): a WAV stream of the
## file decoded from its start, as FFmpeg decodes it played through (each
## nibble expanded the same way, bit for bit), held in memory: any spot is
## then at hand, at its true loudness. Westwood SND1 (codec 1) starts each
## chunk afresh, so FFmpeg seeks it right: it opens as an EDL timeline of
## the header's length.
##
## mpv calls in from its own threads, opening a stream on one and closing
## it on another: a stream uses only the C heap (mpv's `streamAlloc0`). The
## file's bytes are read in `prepare` (on the app's thread) and decoded when
## mpv opens the stream.

import std/[locks, os, strutils, times]
import mpv

const
  HeaderBytes = 44
  AudHeader = 12                ## rate, packed size, unpacked size, flags, codec
  ChunkHeader = 8               ## packed size, unpacked size (u16), 0x0000DEAF
  ChunkSignature = 0x0000DEAF'u32
  Protocol = "mmpaud"
  Slots = 8                     ## the open file, the next one, standbys...
  CodecSnd1 = 1
  CodecIma = 99

  StepTable: array[89, int32] = [
    7'i32, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37,
    41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190,
    209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
    876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499,
    2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845,
    8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350,
    22385, 24623, 27086, 29794, 32767]
  IndexTable: array[16, int32] = [-1'i32, -1, -1, -1, 2, 4, 6, 8,
                                  -1, -1, -1, -1, 2, 4, 6, 8]

type
  AudInfo* = object
    rate*, channels*, codec*: int
    length*: float              ## seconds, from the header

  Bytes = ptr UncheckedArray[byte]

  Slot = object
    id: int
    path: array[4096, char]     ## what it holds, with size and mtime: asked
    size: int64                 ## again for the same file, the same stream
    mtime: float
    data: Bytes                 ## the file's bytes, on the C heap
    len: int

  AudStream = object
    pcm: ptr UncheckedArray[int16]  ## header's bytes, then the samples
    total: int64                ## bytes: header and samples
    header: array[HeaderBytes, byte]
    pos: int64

var
  slotLock: Lock
  slots: array[Slots, Slot]
  nextId = 1

initLock slotLock

proc isAudFile*(path: string): bool =
  not path.contains("://") and path.splitFile.ext.toLowerAscii == ".aud"

proc u16[T](b: T, at: int): int = b[at].int or b[at + 1].int shl 8

proc u32[T](b: T, at: int): uint32 =
  b[at].uint32 or b[at + 1].uint32 shl 8 or b[at + 2].uint32 shl 16 or b[at + 3].uint32 shl 24

proc parseHeader(h: array[AudHeader, byte]): AudInfo =
  ## The header's facts; rate 0 when it isn't one.
  ## Flags: bit 0 stereo, bit 1 16-bit; codec 1 Westwood SND1, 99 IMA ADPCM.
  let rate = h.u16(0)
  let size = h.u32(6).int64
  let (flags, codec) = (h[10].int, h[11].int)
  if rate notin 4000 .. 96000 or codec notin [CodecSnd1, CodecIma] or size <= 0: return
  let channels = (flags and 1) + 1
  let width = if (flags and 2) != 0: 2 else: 1
  AudInfo(rate: rate, channels: channels, codec: codec,
          length: size.float / float(width * channels * rate))

proc audInfo*(path: string): AudInfo =
  ## What the header of the file at path says; rate 0 when it isn't one.
  var f: File
  if not open(f, path): return
  defer: f.close()
  var h: array[AudHeader, byte]
  if f.readBytes(h, 0, h.len) == h.len: result = parseHeader(h)

proc audLength*(path: string): float =
  ## Seconds of sound the header says the file holds; 0 when it isn't one.
  path.audInfo.length

proc edlSource(path: string, length: float): string =
  "edl://!no_chapters;%" & $path.len & "%" & path & ",0," & formatFloat(length, ffDecimal, 6)

proc prepare*(path: string): string =
  ## What mpv opens for the file: an IMA ADPCM file's decoded stream, an
  ## SND1 file's EDL of its true length; "" when the header can't say (FFmpeg
  ## then opens the file itself).
  let info = path.audInfo
  if info.rate == 0: return ""
  if info.codec != CodecIma: return edlSource(path, info.length)
  if path.len >= Slot.path.len: return edlSource(path, info.length)
  var size: int64
  var mtime: float
  try:
    size = getFileSize(path)
    mtime = getLastModificationTime(path).toUnixFloat
  except OSError: return ""
  withLock slotLock:
    for i in 0 ..< Slots:
      let s = slots[i].addr
      if s.data != nil and s.size == size and s.mtime == mtime and
         $cast[cstring](s.path[0].addr) == path:
        return Protocol & "://" & $s.id
  var bytes: string
  try: bytes = readFile(path)
  except IOError, OSError: return ""
  if bytes.len < AudHeader: return ""
  let data = cast[Bytes](streamAlloc0(bytes.len))
  if data == nil: return ""
  copyMem(data, bytes[0].addr, bytes.len)
  withLock slotLock:
    let id = nextId
    inc nextId
    let s = slots[id mod Slots].addr
    streamFree(s.data)
    s[] = Slot(id: id, size: size, mtime: mtime, data: data, len: bytes.len)
    copyMem(s.path[0].addr, path.cstring, path.len)
    result = Protocol & "://" & $id

proc expand(predictor, index: var int32, nibble: int): int16 {.inline.} =
  ## One IMA ADPCM nibble, as FFmpeg's adpcm_ima_expand_nibble(…, 3).
  let step = StepTable[index]
  index = clamp(index + IndexTable[nibble], 0'i32, 88'i32)
  let diff = ((2 * int32(nibble and 7) + 1) * step) shr 3
  predictor = clamp(if (nibble and 8) != 0: predictor - diff else: predictor + diff,
                    -32768'i32, 32767'i32)
  predictor.int16

iterator chunks(data: Bytes, len: int): tuple[at, size: int] =
  ## Each whole chunk's sound bytes, as FFmpeg's wsaud demuxer hands them
  ## on: up to the first header that isn't one, a chunk cut short left out.
  var at = AudHeader
  while at + ChunkHeader <= len:
    let size = data.u16(at)
    if data.u32(at + 4) != ChunkSignature or at + ChunkHeader + size > len: break
    yield (at + ChunkHeader, size)
    at += ChunkHeader + size

proc decodedFrames(data: Bytes, len, channels: int): int64 =
  for (at, size) in chunks(data, len):
    result += int64(size * 2 div channels div 2 * 2)

proc decode(data: Bytes, len, channels: int, outp: ptr UncheckedArray[int16]) =
  ## The whole file's sound, interleaved: each byte two samples of one
  ## channel (low nibble first), the channels taking turns byte by byte, the
  ## decoder's state carried across chunks, as FFmpeg decodes it.
  var predictor, index: array[2, int32]
  var o = 0
  for (at, size) in chunks(data, len):
    var i = at
    for n in 0 ..< size * 2 div channels div 2:
      for c in 0 ..< channels:
        let v = data[i].int
        inc i
        outp[o + c] = expand(predictor[c], index[c], v and 0x0f)
        outp[o + c + channels] = expand(predictor[c], index[c], v shr 4)
      o += 2 * channels

proc put32(h: var array[HeaderBytes, byte], at: int, v: uint32) =
  for i in 0 .. 3: h[at + i] = byte((v shr (8 * i)) and 0xff)

proc put16(h: var array[HeaderBytes, byte], at: int, v: uint16) =
  for i in 0 .. 1: h[at + i] = byte((v shr (8 * i)) and 0xff)

proc writeHeader(s: ptr AudStream, rate, channels: int, dataBytes: uint32) =
  for i, c in "RIFF": s.header[i] = byte(c)
  s.header.put32(4, 36 + dataBytes)
  for i, c in "WAVEfmt ": s.header[8 + i] = byte(c)
  s.header.put32(16, 16)
  s.header.put16(20, 1)                     # PCM
  s.header.put16(22, channels.uint16)
  s.header.put32(24, rate.uint32)
  s.header.put32(28, uint32(rate * channels * 2))
  s.header.put16(32, uint16(channels * 2))
  s.header.put16(34, 16)
  for i, c in "data": s.header[36 + i] = byte(c)
  s.header.put32(40, dataBytes)

proc readCb(cookie: pointer, buf: ptr UncheckedArray[byte], nbytes: uint64): int64 {.cdecl.} =
  let s = cast[ptr AudStream](cookie)
  var done = 0'i64
  let want = nbytes.int64
  while done < want and s.pos < s.total:
    if s.pos < HeaderBytes:
      let k = min(want - done, HeaderBytes - s.pos)
      copyMem(buf[done].addr, s.header[s.pos].addr, k)
      s.pos += k
      done += k
    else:
      let k = min(want - done, s.total - s.pos)
      copyMem(buf[done].addr, cast[Bytes](s.pcm)[s.pos - HeaderBytes].addr, k)
      s.pos += k
      done += k
  done

proc seekCb(cookie: pointer, offset: int64): int64 {.cdecl.} =
  let s = cast[ptr AudStream](cookie)
  if offset < 0 or offset > s.total: return MpvErrorGeneric
  s.pos = offset
  offset

proc sizeCb(cookie: pointer): int64 {.cdecl.} =
  cast[ptr AudStream](cookie).total

proc closeCb(cookie: pointer) {.cdecl.} =
  let s = cast[ptr AudStream](cookie)
  streamFree(s.pcm)
  streamFree(s)

proc openCb(userData: pointer, uri: cstring, info: ptr MpvStreamCbInfo): cint {.cdecl.} =
  const Skip = Protocol.len + 3
  var id = 0
  var i = Skip
  while uri[i] in {'0' .. '9'}:
    id = id * 10 + (ord(uri[i]) - ord('0'))
    inc i
  # The file's bytes copied out, to decode without holding the lock.
  var data: Bytes
  var len = 0
  withLock slotLock:
    let sl = slots[id mod Slots].addr
    if sl.id == id and sl.data != nil:
      data = cast[Bytes](streamAlloc0(sl.len))
      if data != nil:
        copyMem(data, sl.data, sl.len)
        len = sl.len
  if data == nil: return MpvErrorLoadingFailed
  var head: array[AudHeader, byte]
  copyMem(head[0].addr, data, AudHeader)
  let a = parseHeader(head)
  if a.codec != CodecIma:
    streamFree(data)
    return MpvErrorLoadingFailed
  let frames = decodedFrames(data, len, a.channels)
  let dataBytes = frames * a.channels * 2
  if frames <= 0 or dataBytes > high(uint32).int64 - 36:
    streamFree(data)
    return MpvErrorLoadingFailed
  let s = streamCreate(AudStream)
  let pcm = cast[ptr UncheckedArray[int16]](streamAlloc0(dataBytes.int))
  if s == nil or pcm == nil:
    streamFree(s)
    streamFree(pcm)
    streamFree(data)
    return MpvErrorLoadingFailed
  decode(data, len, a.channels, pcm)
  streamFree(data)
  s.pcm = pcm
  s.total = HeaderBytes + dataBytes
  s.writeHeader(a.rate, a.channels, dataBytes.uint32)
  info.cookie = s
  info.readFn = readCb
  info.seekFn = seekCb
  info.sizeFn = sizeCb
  info.closeFn = closeCb
  info.cancelFn = nil
  0

proc register*(h: MpvHandle) =
  ## Lets the player open prepared .aud streams.
  discard mpv_stream_cb_add_ro(h, Protocol, nil, openCb)

when isMainModule:
  # Test: nim c -r -d:release src/wsaud.nim FILE.aud OUT.raw: the file
  # decoded as the stream holds it (s16 interleaved), to compare with
  # `ffmpeg -i FILE.aud -f s16le` (no seeks: FFmpeg's from-start decode).
  let bytes = readFile(paramStr(1))
  let data = cast[Bytes](bytes[0].unsafeAddr)
  var head: array[AudHeader, byte]
  copyMem(head[0].addr, data, AudHeader)
  let a = parseHeader(head)
  let frames = decodedFrames(data, bytes.len, a.channels)
  var pcm = newSeq[int16](frames * a.channels)
  decode(data, bytes.len, a.channels, cast[ptr UncheckedArray[int16]](pcm[0].addr))
  var raw = newString(pcm.len * 2)
  copyMem(raw[0].addr, pcm[0].addr, raw.len)
  writeFile(paramStr(2), raw)
  echo a, " frames ", frames, " (header ", a.length * a.rate.float, ")"
