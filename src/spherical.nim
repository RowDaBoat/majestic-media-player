## 360° video detection: reads the spherical-video metadata straight from the
## container headers (Matroska/WebM Projection element, MP4 sv3d/st3d boxes
## and the older Spherical Video V1 XML), without ffprobe or decoding.
## Only headers are read: a few KB for typical files.
## YouTube's newer 360° and VR180 videos come with a mesh instead (Spherical
## Video V2's mshp, in its own ytmp box): the picture's layout, drawn as it is.

import std/[base64, math, os, strutils]
import zippy

type
  Projection* = enum
    prNone, prEquirect, prCubemap, prMesh

  StereoLayout* = enum
    slMono, slTopBottom, slSideBySide

  SphereInfo* = object
    projection*: Projection
    stereo*: StereoLayout
    ## Equirectangular crop: fractions of the full 360x180 picture cut from
    ## each edge (all zero for a full sphere, left/right 0.25 for VR180).
    top*, bottom*, left*, right*: float32
    ## Pose of the picture on the sphere, degrees.
    yaw*, pitch*, roll*: float32
    mesh*: string             ## prMesh: its box's content, base64 (meshes)

  MeshPart* = object
    ## An eye's mesh, ready to draw.
    vertices*: seq[float32]   ## x, y, z, u, v of each; -z ahead, v up
    indices*: seq[uint32]     ## triangles

const
  MaxElement = 16 * 1024 * 1024  ## larger header elements are malformed or not ours

proc is360*(s: SphereInfo): bool =
  s.projection == prEquirect or (s.projection == prMesh and s.mesh.len > 0)

# --- byte helpers -----------------------------------------------------------

proc readAt(f: File, pos: int64, n: int): string =
  ## Up to n bytes at pos (fewer at the end of the file).
  if n <= 0: return ""
  result = newString(n)
  f.setFilePos(pos)
  result.setLen f.readBuffer(result[0].addr, n)

proc be(s: string, i, n: int): uint64 =
  for k in 0 ..< n: result = result shl 8 or s[i + k].uint8.uint64

proc beFloat(s: string): float32 =
  ## Matroska float element: 4 or 8 bytes, big endian.
  case s.len
  of 4: cast[float32](be(s, 0, 4).uint32)
  of 8: cast[float64](be(s, 0, 8)).float32
  else: 0

proc fixed32(v: uint64): float32 = float32(v.float64 / 4294967296.0)
proc fixed16(v: uint64): float32 = float32(cast[int32](v.uint32).float64 / 65536.0)

proc parseBounds(s: var SphereInfo, d: string, at: int) =
  ## Equirect bounds as 0.32 fixed point: top, bottom, left, right.
  if d.len < at + 16: return
  s.top = fixed32(be(d, at, 4)); s.bottom = fixed32(be(d, at + 4, 4))
  s.left = fixed32(be(d, at + 8, 4)); s.right = fixed32(be(d, at + 12, 4))
  if s.top + s.bottom >= 1 or s.left + s.right >= 1:
    (s.top, s.bottom, s.left, s.right) = (0'f32, 0'f32, 0'f32, 0'f32)

# --- Matroska / WebM --------------------------------------------------------

const
  idSegment = 0x18538067'u64
  idTracks = 0x1654AE6B'u64
  idCluster = 0x1F43B675'u64
  idTrackEntry = 0xAE'u64
  idTrackType = 0x83'u64
  idVideo = 0xE0'u64
  idStereoMode = 0x53B8'u64
  idProjection = 0x7670'u64
  idProjectionType = 0x7671'u64
  idProjectionPrivate = 0x7672'u64
  idPoseYaw = 0x7673'u64
  idPosePitch = 0x7674'u64
  idPoseRoll = 0x7675'u64

type Ebml = tuple[id: uint64, size: int64, data: int64]  ## size -1 = unknown

proc ebmlHeader(f: File, pos, limit: int64): (bool, Ebml) =
  ## The element header at pos: its ID, payload size and payload offset.
  let h = f.readAt(pos, 12)
  if h.len < 2: return
  let b0 = h[0].uint8
  if b0 == 0: return
  var idLen = 1
  while (b0 and (0x80'u8 shr (idLen - 1))) == 0: inc idLen
  if idLen > 4 or h.len < idLen + 1: return
  let id = be(h, 0, idLen)
  let s0 = h[idLen].uint8
  if s0 == 0: return
  var sLen = 1
  while (s0 and (0x80'u8 shr (sLen - 1))) == 0: inc sLen
  if h.len < idLen + sLen: return
  # Nim masks shift counts to the type's width: 0xFF'u8 shr 8 would be 0xFF.
  let mask = if sLen >= 8: 0'u8 else: 0xFF'u8 shr sLen
  var size = uint64(s0 and mask)
  var allOnes = size == mask.uint64
  for k in 1 ..< sLen:
    let b = h[idLen + k].uint8
    size = size shl 8 or b
    allOnes = allOnes and b == 0xFF
  let data = pos + idLen + sLen
  if data > limit: return
  (true, (id, (if allOnes: -1'i64 else: size.int64), data))

iterator children(f: File, start, stop: int64): Ebml =
  ## The elements between start and stop; stops at one of unknown size.
  var pos = start
  while pos < stop:
    let (ok, e) = f.ebmlHeader(pos, stop)
    if not ok: break
    yield e
    if e.size < 0: break
    pos = e.data + e.size

proc readElement(f: File, e: Ebml): string =
  if e.size < 0 or e.size > MaxElement: "" else: f.readAt(e.data, e.size.int)

proc mkvVideo(f: File, e: Ebml, s: var SphereInfo) =
  for c in f.children(e.data, e.data + e.size):
    case c.id
    of idStereoMode:
      let d = f.readElement(c)
      case be(d, 0, d.len.clamp(0, 8))
      of 1, 11: s.stereo = slSideBySide   # left eye first / right eye first
      of 2, 3: s.stereo = slTopBottom     # right eye first / left eye first
      else: discard
    of idProjection:
      for p in f.children(c.data, c.data + c.size):
        let d = f.readElement(p)
        case p.id
        of idProjectionType:
          s.projection =
            case be(d, 0, d.len.clamp(0, 8))
            of 1: prEquirect
            of 2: prCubemap
            of 3: prMesh
            else: prNone
        of idProjectionPrivate:
          if s.projection == prMesh: s.mesh = encode(d)
          else: s.parseBounds(d, 4)  # after version + flags
        of idPoseYaw: s.yaw = beFloat(d)
        of idPosePitch: s.pitch = beFloat(d)
        of idPoseRoll: s.roll = beFloat(d)
        else: discard
    else: discard
  if s.projection != prEquirect:  # any mesh would have them in itself
    (s.top, s.bottom, s.left, s.right) = (0'f32, 0'f32, 0'f32, 0'f32)

proc mkvInfo(f: File, fileSize: int64): SphereInfo =
  ## First video track's projection. Tracks precede the clusters in any
  ## file worth playing, so the walk stops at the first cluster.
  for seg in f.children(0, fileSize):
    if seg.id != idSegment: continue
    let segEnd = if seg.size < 0: fileSize else: min(fileSize, seg.data + seg.size)
    for top in f.children(seg.data, segEnd):
      if top.id == idCluster: return
      if top.id != idTracks or top.size < 0: continue
      for t in f.children(top.data, top.data + top.size):
        if t.id != idTrackEntry or t.size < 0: continue
        var isVideo = false
        var video: Ebml
        var hasVideo = false
        for c in f.children(t.data, t.data + t.size):
          if c.id == idTrackType: isVideo = be(f.readElement(c), 0, 1) == 1
          elif c.id == idVideo and c.size >= 0: (video, hasVideo) = (c, true)
        if isVideo:
          if hasVideo: f.mkvVideo(video, result)
          return
    return

# --- MP4 / MOV --------------------------------------------------------------

type Box = tuple[kind: string, data, stop: int64]

iterator boxes(f: File, start, stop: int64): Box =
  var pos = start
  while pos + 8 <= stop:
    let h = f.readAt(pos, 16)
    if h.len < 8: break
    var size = be(h, 0, 4).int64
    var data = pos + 8
    if size == 1:
      if h.len < 16: break
      size = be(h, 8, 8).int64
      data = pos + 16
    elif size == 0:
      size = stop - pos
    if size < data - pos or pos + size > stop: break
    yield (h[4 .. 7], data, pos + size)
    pos += size

proc findBox(f: File, start, stop: int64, kind: string): (bool, Box) =
  for b in f.boxes(start, stop):
    if b.kind == kind: return (true, b)

const
  SphericalV1Uuid = "\xff\xcc\x82\x63\xf8\x55\x4a\x93\x88\x14\x58\x7a\x02\x52\x1f\xdd"

proc xmlTag(xml, tag: string): string =
  let a = xml.find("<GSpherical:" & tag & ">")
  if a < 0: return
  let s = a + tag.len + 13
  let e = xml.find('<', s)
  if e > s: result = xml[s ..< e].strip.toLowerAscii

proc sphericalV1(s: var SphereInfo, xml: string) =
  ## Spherical Video V1: an XML document in a uuid box under the track.
  if xml.xmlTag("Spherical") != "true": return
  if xml.xmlTag("ProjectionType") == "equirectangular": s.projection = prEquirect
  case xml.xmlTag("StereoMode")
  of "top-bottom": s.stereo = slTopBottom
  of "left-right": s.stereo = slSideBySide
  else: discard
  for (tag, field) in [("InitialViewHeadingDegrees", 0), ("InitialViewPitchDegrees", 1),
                       ("InitialViewRollDegrees", 2)]:
    try:
      let v = parseFloat(xml.xmlTag(tag)).float32
      case field
      of 0: s.yaw = v
      of 1: s.pitch = v
      else: s.roll = v
    except ValueError: discard

proc sampleEntry(f: File, b: Box, s: var SphereInfo) =
  ## sv3d and st3d sit among a visual sample entry's child boxes, after its
  ## 78-byte fixed part.
  for c in f.boxes(b.data + 78, b.stop):
    case c.kind
    of "st3d":
      let d = f.readAt(c.data, 5)
      if d.len == 5:
        case d[4].uint8
        of 1: s.stereo = slTopBottom
        of 2: s.stereo = slSideBySide
        else: discard
    of "sv3d":
      let (ok, proj) = f.findBox(c.data, c.stop, "proj")
      if not ok: continue
      for p in f.boxes(proj.data, proj.stop):
        if p.kind in ["mshp", "ytmp"]:
          s.projection = prMesh
          s.mesh = encode(f.readAt(p.data, int(min(p.stop - p.data, MaxElement))))
          continue
        let d = f.readAt(p.data, int(min(p.stop - p.data, 64)))
        case p.kind
        of "prhd":
          if d.len >= 16:
            s.yaw = fixed16(be(d, 4, 4)); s.pitch = fixed16(be(d, 8, 4))
            s.roll = fixed16(be(d, 12, 4))
        of "equi":
          s.projection = prEquirect
          s.parseBounds(d, 4)
        of "cbmp": s.projection = prCubemap
        else: discard
    else: discard

proc mp4Info(f: File, fileSize: int64): SphereInfo =
  ## First video track's projection; moov may follow mdat (no faststart).
  let (ok, moov) = f.findBox(0, fileSize, "moov")
  if not ok: return
  for trak in f.boxes(moov.data, moov.stop):
    if trak.kind != "trak": continue
    let (okM, mdia) = f.findBox(trak.data, trak.stop, "mdia")
    if not okM: continue
    let (okH, hdlr) = f.findBox(mdia.data, mdia.stop, "hdlr")
    if not okH or f.readAt(hdlr.data + 8, 4) != "vide": continue
    for u in f.boxes(trak.data, trak.stop):
      if u.kind == "uuid" and f.readAt(u.data, 16) == SphericalV1Uuid:
        result.sphericalV1(f.readAt(u.data + 16, int(min(u.stop - u.data - 16, 64 * 1024))))
    var b = mdia
    for kind in ["minf", "stbl", "stsd"]:
      let (found, child) = f.findBox(b.data, b.stop, kind)
      if not found: return
      b = child
    # stsd: version/flags and an entry count, then the sample entries.
    for entry in f.boxes(b.data + 8, b.stop):
      f.sampleEntry(entry, result)
      break
    return

# --- mesh --------------------------------------------------------------------

proc meshes*(s: SphereInfo): seq[MeshPart] =
  ## The mesh's parts: one, or one for each eye. None when it's malformed.
  type Bits = object
    d: string
    at: int                   ## in bits
  proc get(b: var Bits, n: int): uint32 =
    if b.at + n > b.d.len * 8: raise newException(ValueError, "mesh ends early")
    for _ in 0 ..< n:
      result = result shl 1 or uint32(b.d[b.at shr 3].uint8 shr (7 - (b.at and 7)) and 1)
      inc b.at
  proc delta(b: var Bits, n: int): int =
    let v = b.get(n).int  # zigzag
    (v shr 1) xor -(v and 1)
  proc width(count: int): int = ceil(log2(float(count * 2))).int
  try:
    let box = decode(s.mesh)
    if box.len < 12: return
    let body =
      case box[8 .. 11]
      of "dfl8": uncompress(box[12 .. ^1], dfDeflate)
      of "raw ": box[12 .. ^1]
      else: return
    var at = 0
    while at + 8 <= body.len:
      let size = be(body, at, 4).int
      if body[at + 4 .. at + 7] != "mesh" or size < 16 or at + size > body.len: return @[]
      var b = Bits(d: body[at + 8 ..< at + size])
      at += size
      let coords = b.get(32).int
      var values = newSeq[float32](coords)
      for v in values.mitems: v = cast[float32](b.get(32))
      let verts = b.get(32).int
      var part: MeshPart
      part.vertices = newSeq[float32](verts * 5)
      var ids: array[5, int]
      for i in 0 ..< verts:
        for k in 0 ..< 5:
          ids[k] += b.delta(width(coords))
          part.vertices[i * 5 + k] = values[ids[k]]
      b.at = (b.at + 7) and not 7
      for _ in 0 ..< b.get(32).int:
        discard b.get(8)  # texture
        let kind = b.get(8)
        let count = b.get(32).int
        var list = newSeq[uint32](count)
        var id = 0
        for i in 0 ..< count:
          id += b.delta(width(verts))
          if id notin 0 ..< verts: return @[]
          list[i] = id.uint32
        b.at = (b.at + 7) and not 7
        case kind
        of 0: part.indices.add list
        of 1:  # strip: the repeated indices between its runs make no triangle
          for i in 2 ..< count:
            if list[i - 2] == list[i - 1] or list[i - 1] == list[i] or list[i - 2] == list[i]:
              continue
            part.indices.add [list[i - 2], list[i - 1], list[i]]
        of 2:  # fan
          for i in 2 ..< count: part.indices.add [list[0], list[i - 1], list[i]]
        else: return @[]
      result.add part
  except ValueError, IndexDefect, ZippyError:
    return @[]

# --- entry point ------------------------------------------------------------

proc detectSphere*(path: string): SphereInfo =
  ## Spherical metadata of a local file's first video track; prNone for
  ## anything else (streams, other containers, unreadable files).
  if not fileExists(path): return
  var f: File
  if not f.open(path, fmRead): return
  defer: f.close()
  try:
    let size = f.getFileSize
    let magic = f.readAt(0, 12)
    if magic.len >= 4 and magic.startsWith("\x1a\x45\xdf\xa3"):
      result = f.mkvInfo(size)
    elif magic.len >= 8 and magic[4 .. 7] in ["ftyp", "moov", "free", "wide", "mdat", "skip"]:
      result = f.mp4Info(size)
  except IOError, OSError:
    result = SphereInfo()
  if result.projection == prMesh and result.meshes.len == 0: result = SphereInfo()

when isMainModule:
  for p in commandLineParams():
    echo p, ": ", detectSphere(p)
