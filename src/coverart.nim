## The kinds of pictures inside an audio file (front cover, back cover,
## booklet...), in the order ffmpeg makes them tracks. mpv shows the first
## one and doesn't tell which is which, so the player reads them here to
## show the front cover. ID3v2 tags (MP3 and more) and FLAC's own pictures;
## other formats seldom hold more than the one.

import std/[streams, strutils]

const
  FrontCover* = 3    ## ID3v2 / FLAC picture type
  MaxTag = 64 shl 20 ## bigger ID3v2 tags are skipped, not read

proc be(s: string, i, n: int): int =
  for k in 0 ..< n: result = result shl 8 or s[i + k].ord

proc syncsafe(s: string, i: int): int =
  for k in 0 ..< 4: result = result shl 7 or (s[i + k].ord and 0x7f)

proc unsync(s: string): string =
  ## Undoes ID3v2 unsynchronisation (0xFF 0x00 -> 0xFF).
  var i = 0
  while i < s.len:
    result.add s[i]
    if s[i] == '\xFF' and i + 1 < s.len and s[i + 1] == '\0': inc i
    inc i

proc id3Types(f: Stream): seq[int] =
  let h = f.readStr(10)
  if h.len < 10: return
  let (major, flags, size) = (h[3].ord, h[5].ord, syncsafe(h, 6))
  if major notin 2 .. 4 or size > MaxTag: return
  var body = f.readStr(size)
  if (flags and 0x80) != 0 and major < 4: body = unsync(body)
  var i = 0
  if (flags and 0x40) != 0 and major >= 3 and body.len >= 4:  # extended header
    i = if major == 3: 4 + be(body, 0, 4) else: syncsafe(body, 0)
  let head = if major == 2: 6 else: 10
  while i + head <= body.len and body[i] != '\0':
    let id = body[i ..< i + (if major == 2: 3 else: 4)]
    let n = if major == 2: be(body, i + 3, 3)
            elif major == 3: be(body, i + 4, 4)
            else: syncsafe(body, i + 4)
    let start = i + head
    i = start + n
    if i > body.len: break
    var c = body[start ..< i]
    if id == "PIC":  # encoding, 3-letter format, type
      result.add (if c.len > 4: c[4].ord else: -1)
    elif id == "APIC":  # encoding, MIME type (ends with a 0), type
      if major == 4:
        let ff = be(body, start - 2, 2)
        if (ff and 0x02) != 0: c = unsync(c)
        if (ff and 0x01) != 0 and c.len >= 4: c = c[4 .. ^1]  # data length
      let z = c.find('\0', 1)
      result.add (if z >= 0 and z + 1 < c.len: c[z + 1].ord else: -1)

proc flacTypes(f: Stream): seq[int] =
  discard f.readStr(4)
  while not f.atEnd:
    let h = f.readStr(4)
    if h.len < 4: return
    let (kind, n) = (h[0].ord and 0x7f, be(h, 1, 3))
    if kind == 6:  # PICTURE: its type first
      let t = f.readStr(4)
      if t.len < 4: return
      result.add be(t, 0, 4)
      f.setPosition(f.getPosition + n - 4)
    else: f.setPosition(f.getPosition + n)
    if (h[0].ord and 0x80) != 0: return  # the last block

proc pictureTypes*(path: string): seq[int] =
  ## The type of each picture in the file at path, in order (-1 where
  ## unreadable); empty when it has none or isn't an ID3v2 or FLAC file.
  let f = newFileStream(path)
  if f == nil: return
  defer: f.close()
  try:
    case f.peekStr(4)
    of "fLaC": result = flacTypes(f)
    else:
      if f.peekStr(3) == "ID3": result = id3Types(f)
  except CatchableError:
    result.setLen 0
