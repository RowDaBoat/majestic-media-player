## A MIDI song as timed MIDI messages: what midistream plays and the
## tracker chart lays out. Standard MIDI files (and RIFF .rmi wrapping one)
## are read as written. HMI songs (Human Machine Interfaces' SOS format, of
## DOS games such as Abuse) are played through the way SOS does, as worked
## out from Abuse's own copy of the library (TECHNICAL.md has the details).
##
## Rows for the chart: 16th notes from a standard file's tempo map and time
## signatures; an HMI song keeps neither (only its 120 Hz timer ticks), so
## its tempo is guessed from where its notes start.

import std/[algorithm, math, os, strutils, sequtils]

type
  MidiEvent* = object
    t*: float              ## seconds into the song
    b*: array[3, uint8]    ## status and data bytes
    n*: uint8              ## bytes used of b; 0 for a SysEx (data)
    data*: string          ## a SysEx message, F0 to F7

  MidiSong* = ref object
    path*, title*, format*: string
    events*: seq[MidiEvent]   ## in time order
    length*: float            ## seconds, the last sound's end
    fadeFrom*: float          ## a looping song fades out from here to length; 0 none
    rowT*: seq[float]         ## the chart's rows: each one's start
    bars*: seq[int]           ## the first row of each bar
    beatRows*: seq[int]       ## rows per beat, per bar
    tempoGuessed*: bool       ## the rows come from the notes, not the file

const
  HmiLoops = 2              ## times a looping HMI song's loop plays
  HmiFade = 8.0             ## seconds it then fades out over
  Tail = 2.0                ## seconds after the last note, for its release

proc ev(t: float, a, b, c: int, n: int): MidiEvent =
  MidiEvent(t: t, b: [uint8(a and 0xff), uint8(b and 0x7f), uint8(c and 0x7f)], n: uint8(n))

proc rowsPerQuarter(onsets: seq[float], quarter, tol: float): int =
  ## 4 rows to a quarter note (16ths), or 6 (16th triplets) when clearly
  ## more of the notes start on those: a shuffle or 12/8 laid out in 16ths
  ## would fall between rows.
  if onsets.len == 0 or quarter <= 0: return 4
  proc fit(n: int): float =
    let row = quarter / n.float
    var hits = 0
    for x in onsets:
      if abs(x - round(x / row) * row) < tol: inc hits
    hits / onsets.len
  if fit(6) >= fit(4) + 0.15: 6 else: 4

# --- Standard MIDI files ----------------------------------------------------

proc be32(d: string, p: int): int =
  (d[p].ord shl 24) or (d[p + 1].ord shl 16) or (d[p + 2].ord shl 8) or d[p + 3].ord

proc be16(d: string, p: int): int = (d[p].ord shl 8) or d[p + 1].ord

proc vlq(d: string, p: var int, stop: int): int =
  for _ in 0 .. 3:
    if p >= stop: return
    let b = d[p].ord
    inc p
    result = (result shl 7) or (b and 0x7f)
    if b < 0x80: return

type
  Raw = object
    tick: int
    order: int
    e: MidiEvent
  TimeSig = object
    tick, num, den: int

proc parseSmf(d: string, s: MidiSong): bool =
  var p = 0
  if d.len >= 12 and d[0 ..< 4] == "RIFF" and d[8 ..< 12] == "RMID":
    p = 12
    while p + 8 <= d.len:
      let size = d[p + 4].ord or (d[p + 5].ord shl 8) or (d[p + 6].ord shl 16) or (d[p + 7].ord shl 24)
      if d[p ..< p + 4] == "data":
        p += 8
        break
      p += 8 + size + (size and 1)
  if p + 14 > d.len or d[p ..< p + 4] != "MThd": return false
  let fmt = d.be16(p + 8)
  let ntrks = d.be16(p + 10)
  let division = d.be16(p + 12)
  s.format = "Standard MIDI file, type " & $fmt
  p += 8 + d.be32(p + 4)
  var raws: seq[Raw]
  var tempos: seq[(int, int)]      # (tick, microseconds per quarter)
  var sigs: seq[TimeSig]
  var order = 0
  for tr in 0 ..< ntrks:
    if p + 8 > d.len: break
    let size = d.be32(p + 4)
    let isTrack = d[p ..< p + 4] == "MTrk"
    var q = p + 8
    let stop = min(d.len, q + size)
    p = q + size
    if not isTrack: continue
    var tick = 0
    var status = 0
    while q < stop:
      tick += d.vlq(q, stop)
      if q >= stop: break
      var b = d[q].ord
      if b >= 0x80:
        inc q
        if b < 0xf0: status = b
      elif status != 0:
        b = status
      else:
        break
      if b == 0xff:
        if q >= stop: break
        let kind = d[q].ord
        inc q
        let n = d.vlq(q, stop)
        let body = d[q ..< min(stop, q + n)]
        q += n
        case kind
        of 0x51:
          if body.len >= 3:
            tempos.add (tick, (body[0].ord shl 16) or (body[1].ord shl 8) or body[2].ord)
        of 0x58:
          if body.len >= 2: sigs.add TimeSig(tick: tick, num: body[0].ord, den: 1 shl min(body[1].ord, 6))
        of 0x03:
          # The first track's name is the song's (later tracks name their
          # instruments), when it has anything to read in it.
          if tr == 0 and s.title.len == 0 and body.anyIt(it.isAlphaNumeric):
            s.title = body.strip
        of 0x2f: break
        else: discard
      elif b == 0xf0 or b == 0xf7:
        let n = d.vlq(q, stop)
        let body = d[q ..< min(stop, q + n)]
        q += n
        if b == 0xf0:
          var e = MidiEvent(n: 0, data: "\xF0" & body)
          if not e.data.endsWith("\xF7"): e.data.add '\xF7'
          raws.add Raw(tick: tick, order: order, e: e)
          inc order
      else:
        let hi = b and 0xf0
        let count = if hi in [0xc0, 0xd0]: 1 else: 2
        if q + count > stop: break
        let d1 = d[q].ord
        let d2 = if count == 2: d[q + 1].ord else: 0
        q += count
        raws.add Raw(tick: tick, order: order, e: ev(0, b, d1, d2, count + 1))
        inc order
  if raws.len == 0: return false
  raws.sort(proc (a, b: Raw): int = cmp((a.tick, a.order), (b.tick, b.order)))
  tempos.sort(proc (a, b: (int, int)): int = cmp(a[0], b[0]))
  # Ticks to seconds: SMPTE division counts frames, else quarter notes at
  # the tempo of the moment.
  let smpte = (division and 0x8000) != 0
  let ppq = if smpte: 0 else: max(1, division)
  let tps = if smpte: float(256 - (division shr 8)) * float(division and 0xff) else: 0.0
  # The tempo map as segments: each one's first tick, time and tempo.
  var segTick = @[0]
  var segTime = @[0.0]
  var segUs = @[500_000]
  for (tk, v) in tempos:
    let t = segTime[^1] + float(tk - segTick[^1]) * segUs[^1].float / 1e6 / max(1, ppq).float
    if tk == segTick[^1]:
      segUs[^1] = v
    else:
      segTick.add tk
      segTime.add t
      segUs.add v
  proc secondsAt(tick: float): float =
    if smpte: return tick / max(1.0, tps)
    let i = max(0, segTick.upperBound(int(tick)) - 1)
    segTime[i] + (tick - segTick[i].float) * segUs[i].float / 1e6 / ppq.float
  var lastTick = 0
  for r in raws.mitems:
    r.e.t = secondsAt(r.tick.float)
    s.events.add r.e
    lastTick = max(lastTick, r.tick)
  # Rows: 16th notes, bars by the time signature (4/4 until one says).
  if smpte:
    let step = 1 / 8
    var t = 0.0
    var i = 0
    while t <= s.events[^1].t + Tail:
      if i mod 16 == 0:
        s.bars.add s.rowT.len
        s.beatRows.add 4
      s.rowT.add t
      t += step
      inc i
  else:
    sigs.sort(proc (a, b: TimeSig): int = cmp(a.tick, b.tick))
    var onsets: seq[float]
    for r in raws:
      if r.e.n == 3 and (r.e.b[0] and 0xf0) == 0x90 and r.e.b[2] > 0: onsets.add r.tick.float
    let perQuarter = rowsPerQuarter(onsets, ppq.float, max(1.0, ppq / 96))
    var tick = 0.0
    var si = -1
    let endTick = float(lastTick + ppq)
    while tick <= endTick:
      while si + 1 < sigs.len and sigs[si + 1].tick.float <= tick + 1e-6: inc si
      let (num, den) = if si >= 0: (max(1, sigs[si].num), sigs[si].den) else: (4, 4)
      let beatRows = max(1, perQuarter * 4 div den)
      let rowTicks = ppq.float * 4 / den.float / beatRows.float
      s.bars.add s.rowT.len
      s.beatRows.add beatRows
      for r in 0 ..< num * beatRows:
        s.rowT.add secondsAt(tick + r.float * rowTicks)
      tick += float(num * beatRows) * rowTicks
  true

# --- HMI songs ----------------------------------------------------------------
#
# SOS plays an HMI song tick by tick of its timer (the song header's rate):
# queued note-offs first, then each track in order, an event whenever its
# delta has run out. What follows is that, as it goes to a General MIDI
# device (an MPU-401): tracks are kept for the device class they're tagged
# with, take a channel from the driver's pool before they sound, and loop
# and branch through restore points that put their controllers back.

const
  GmPool = [0, 1, 2, 3, 4, 5, 6, 7, 8, -1, 10, 11, 12, 13, 14, 15]
  GmDevice = 0xa001        ## MPU-401

type
  PoolEntry = ref object
    ph: int                ## physical channel, -1: the drum channel's entry
    used: bool
    refs: int
    drv, scaled: int
  Group = ref object
    tracks: seq[HmiTrack]
    state: int             ## file offset of the shared controller state
  HmiTrack = ref object
    tb, idx, lch: int
    ptr0, counter: int
    status: int
    active, hasCh: bool
    entry: PoolEntry
    ph: int
    masks: array[4, int]
    branch: seq[(int, int)]  ## (branch id, track-relative offset)
    group: Group
  Pending = object
    note, cnt, ch: int
    track: HmiTrack
  Hmi = object
    d: string
    rate: int
    slot: array[128, int]
    now: int
    pending: seq[Pending]
    pool: seq[PoolEntry]
    tracks, active: seq[HmiTrack]
    branches: int
    sent: seq[(int, MidiEvent)]

proc u16(h: Hmi, o: int): int =
  if o + 1 < h.d.len: h.d[o].ord or (h.d[o + 1].ord shl 8) else: 0

proc u32(h: Hmi, o: int): int =
  if o + 3 < h.d.len:
    h.d[o].ord or (h.d[o + 1].ord shl 8) or (h.d[o + 2].ord shl 16) or (h.d[o + 3].ord shl 24)
  else: 0

proc byteAt(h: Hmi, o: int): int = (if o >= 0 and o < h.d.len: h.d[o].ord else: 0)

proc delta(h: Hmi, p: var int): int =
  for _ in 0 .. 3:
    let b = h.byteAt(p)
    inc p
    result = (result shl 7) or (b and 0x7f)
    if b < 0x80: return

proc send(h: var Hmi, a, b, c: int, n = 3) =
  h.sent.add (h.now, ev(0, a, b, c, n))

proc setState(h: var Hmi, t: HmiTrack, ctl, v: int) =
  let s = h.slot[ctl and 0x7f]
  if s != 0xff and t.group.state + s < h.d.len: h.d[t.group.state + s] = char(v and 0xff)

proc scale(e: PoolEntry, v: int): int =
  ## SOS's volume: song (music_volume, 127), master (127) and driver levels.
  ((127 * v div 127) * 127 div 127) * e.drv div 127

proc restore(h: var Hmi, t: HmiTrack, ctl, v, v2: int) =
  let ph = t.ph
  case ctl
  of 7:
    t.entry.scaled = t.entry.scale(v)
    h.send(0xb0 or ph, 7, t.entry.scaled)
  of 0x68: h.send(0xc0 or ph, v, 0, 2)
  of 0x69: h.send(0xe0 or ph, 0, v)
  of 0x6a: h.send(0xa0 or ph, v, v2)
  of 0x6b: h.send(0xd0 or ph, v, 0, 2)
  else: h.send(0xb0 or ph, ctl, v)

proc channelInfo(h: var Hmi, t: HmiTrack) =
  ## A channel taken: Reset All Controllers, then the track's state again.
  h.send(0xb0 or t.ph, 0x79, 0)
  for ctl in 0 ..< 0x7f:
    let s = h.slot[ctl]
    if s == 0xff: continue
    let v = h.byteAt(t.group.state + s)
    if v != 0xff: h.restore(t, ctl, v, 0)

proc acquire(h: var Hmi, t: HmiTrack) =
  if t.lch == 9:
    (t.ph, t.entry, t.hasCh) = (9, h.pool[9], true)
    return
  if t.hasCh: return
  var free: PoolEntry
  for e in h.pool:
    if not e.used:
      free = e
      break
  if free == nil: return  # SOS would steal by priority: no Abuse song needs 16
  free.used = true
  var n = 0
  for m in t.group.tracks:
    (m.entry, m.ph, m.hasCh) = (free, free.ph, true)
    if m.active: inc n
  free.refs = n
  h.channelInfo(t)

proc release(h: var Hmi, t: HmiTrack) =
  let e = t.entry
  if e == nil or e.ph == -1: return
  t.hasCh = false
  dec e.refs
  if e.refs <= 0: e.used = false

proc kill(h: var Hmi, t: HmiTrack) =
  ## Controller 108: the channel's queued notes end now.
  if not t.hasCh: return
  var keep: seq[Pending]
  for n in h.pending:
    if n.ch == t.ph: h.send(0x90 or t.ph, n.note, 0)
    else: keep.add n
  h.pending = keep

proc updateChannel(h: var Hmi, t: HmiTrack, p: int) =
  ## A restore point's controllers, put back. SOS masks each by bit
  ## (ctl and 0x20) of its word, which is bit 0 either way.
  let n = h.byteAt(p) shr 1
  var q = p + 1
  for _ in 0 ..< n:
    let ctl = h.byteAt(q)
    if (t.masks[(ctl shr 5) and 3] and 1) == 0:
      q += 2
      continue
    h.setState(t, ctl, h.byteAt(q + 1))
    if ctl == 0x6a:
      h.restore(t, ctl, h.byteAt(q + 1), h.byteAt(q + 2))
      q += 3
    else:
      h.restore(t, ctl, h.byteAt(q + 1), 0)
      q += 2

proc land(h: var Hmi, t: HmiTrack, p: int) =
  ## The end of a branch: on from the restore point at p.
  t.ptr0 = p + 4
  h.kill(t)
  if t.hasCh: h.updateChannel(t, t.ptr0)
  t.ptr0 += h.byteAt(t.ptr0) + 1 + 4
  t.counter = h.delta(t.ptr0)

proc branchSong(h: var Hmi, id: int) =
  inc h.branches
  for t in h.tracks:
    var off = -1
    for (bid, o) in t.branch:
      if bid == id:
        off = o
        break
    if off < 0: continue
    h.land(t, t.tb + off)
    if not t.active:
      t.active = true
      h.active.add t
      h.active.sort(proc (a, b: HmiTrack): int = cmp(a.idx, b.idx))
      h.acquire(t)

proc event(h: var Hmi, t: HmiTrack): bool =
  ## One of the track's events; true when its next delta follows.
  let p = t.ptr0
  let rs = if h.byteAt(p) >= 0x80: 1 else: 0
  let st = if rs == 1: h.byteAt(p) else: t.status
  if rs == 1: t.status = st
  let hi = st and 0xf0
  let ph = t.ph
  let d1 = h.byteAt(p + rs)
  let d2 = h.byteAt(p + rs + 1)
  case hi
  of 0x90:
    t.ptr0 = p + rs + 2
    let dur = h.delta(t.ptr0)
    if t.hasCh:
      h.pending.add Pending(note: d1, cnt: dur, ch: ph, track: t)
      let vel = if ph == 9: d2 * t.entry.scaled div 127 else: d2
      h.send(0x90 or ph, d1, vel)
    return true
  of 0x80:
    if t.hasCh: h.send(0x90 or ph, d1, 0)
    return false
  of 0xa0:
    if t.hasCh: h.send(0xa0 or ph, d1, d2)
    h.setState(t, 0x6a, d1)
    t.ptr0 = p + rs + 2
    return true
  of 0xb0:
    t.ptr0 = p + rs + 2
    case d1
    of 7:
      if t.hasCh:
        t.entry.scaled = t.entry.scale(d2)
        if t.entry.ph != 9: h.send(0xb0 or ph, 7, t.entry.scaled)
      h.setState(t, 7, d2)
    of 103, 104, 106, 107, 119: discard  # masks, locks, priority, triggers: unused
    of 105:
      if d2 != 0: h.acquire(t)
      elif t.hasCh: h.release(t)
    of 108:
      h.kill(t)
      t.ptr0 = p
    else:
      if t.hasCh: h.send(0xb0 or ph, d1, d2)
      h.setState(t, d1, d2)
    return true
  of 0xc0, 0xd0:
    if t.hasCh: h.send(hi or ph, d1, 0, 2)
    h.setState(t, if hi == 0xc0: 0x68 else: 0x6b, d1)
    t.ptr0 = p + rs + 1
    return true
  of 0xe0:
    if t.hasCh: h.send(0xe0 or ph, d1, d2)
    h.setState(t, 0x69, d2)
    t.ptr0 = p + rs + 2
    return true
  else: discard
  if st == 0xf0:
    let n = h.u32(p + rs)
    var data = h.d[min(h.d.len, p + rs + 4) ..< min(h.d.len, p + rs + 4 + n)]
    if not data.startsWith("\xF0"): data = "\xF0" & data
    if not data.endsWith("\xF7"): data.add '\xF7'
    h.sent.add (h.now, MidiEvent(n: 0, data: data))
    t.ptr0 = p + rs + 4 + n
    return true
  if st == 0xfe:
    case h.byteAt(p + 1)
    of 0x10:
      t.ptr0 = p + h.byteAt(p + 4) + 9
      return true
    of 0x12, 0x14:  # loop start: its count reloaded
      if p + 3 < h.d.len: h.d[p + 2] = h.d[p + 3]
      t.ptr0 = p + 4
      return true
    of 0x11:
      h.land(t, t.tb + h.u32(p + 4))
      return false
    of 0x13:
      let c = t.tb + h.u32(p + 8)
      if h.byteAt(c) == 0:
        t.ptr0 = p + 12
        return true
      if h.byteAt(c) != 0xff: h.d[c] = char(h.byteAt(c) - 1)
      h.land(t, t.tb + h.u32(p + 4))
      return false
    of 0x15:
      let c = t.tb + h.u32(p + 4)
      if h.byteAt(c) == 0:
        t.ptr0 = p + 8
        return true
      if h.byteAt(c) != 0xff: h.d[c] = char(h.byteAt(c) - 1)
      h.branchSong(h.u16(p + 2))
      return false
    of 0x16:
      h.branchSong(h.u16(p + 2))
      return false
    else:
      t.active = false  # not SOS's: stop the track rather than misread it
      h.active.keepItIf(it != t)
      return false
  if st == 0xff and h.byteAt(p + 1) == 0x2f:
    t.active = false
    h.active.keepItIf(it != t)
  false

proc tick(h: var Hmi): bool =
  inc h.now
  var keep: seq[Pending]
  for n in h.pending.mitems:
    let old = n.cnt
    dec n.cnt
    if old == 0:
      if n.track.hasCh: h.send(0x90 or n.track.ph, n.note, 0)
    else: keep.add n
  h.pending = keep
  var idx = -1
  while true:
    var t: HmiTrack
    for x in h.active:
      if x.idx > idx:
        t = x
        break
    if t == nil: break
    idx = t.idx
    while t.active:
      let old = t.counter
      dec t.counter
      if old != 0: break
      if h.event(t): t.counter = h.delta(t.ptr0)
  h.active.len > 0

proc mapsGm(tags: openArray[int]): bool =
  for tag in tags:
    if tag == 0: break
    if tag == 0xa000 or tag == GmDevice: return true
  false

proc parseHmi(d: string, s: MidiSong): bool =
  if not d.startsWith("HMI-MIDISONG061595"): return false
  var h = Hmi(d: d)
  h.rate = max(1, h.u16(0xd4))
  for i in 0 ..< 128: h.slot[i] = h.byteAt(0x26 + i)
  s.format = "HMI song (Human Machine Interfaces SOS)"
  for ph in GmPool:
    h.pool.add PoolEntry(ph: ph, used: ph == -1, drv: 127)
  # The driver's reset: All Notes Off, volume 0, Reset All Controllers.
  for e in h.pool:
    if e.ph != -1:
      for (c, v) in [(0x7b, 0), (0x07, 0), (0x79, 0)]: h.send(0xb0 or e.ph, c, v)
  var groups: seq[(int, Group)]
  let table = h.u32(0xe8)
  for i in 0 ..< h.u16(0xe4):
    let tb = h.u32(table + 4 * i)
    if tb <= 0 or tb >= d.len: continue
    var tags: array[8, int]
    for k in 0 ..< 8: tags[k] = h.u16(tb + 0x99 + 2 * k)
    if not mapsGm(tags): continue
    let t = HmiTrack(tb: tb, idx: h.u16(tb + 0x47), lch: h.u16(tb + 0x79), active: true)
    t.masks = [0xff, 0xff, 0xff, 0xff]
    let bt = h.u32(tb + 0x63)
    if bt != 0:
      for k in 0 ..< h.byteAt(tb + bt):
        let e = tb + bt + 1 + 6 * k
        t.branch.add (h.u16(e), h.u32(e + 2))
    t.ptr0 = tb + h.u32(tb + 0x57)
    t.counter = h.delta(t.ptr0)
    var g: Group
    for (ch, gg) in groups:
      if ch == t.lch: g = gg
    if g == nil:
      g = Group(state: tb + h.u32(tb + 0x7d))
      groups.add (t.lch, g)
    g.tracks.add t
    t.group = g
    h.tracks.add t
  if h.tracks.len == 0: return false
  h.active = h.tracks
  h.active.sort(proc (a, b: HmiTrack): int = cmp(a.idx, b.idx))
  # Until the song's end, or its loop has played HmiLoops times and faded.
  let cap = h.rate * 3600
  var fadeTick = -1
  while h.tick():
    if fadeTick < 0 and h.branches >= HmiLoops: fadeTick = h.now
    if fadeTick >= 0 and h.now - fadeTick >= int(HmiFade * h.rate.float): break
    if h.now > cap: break
  for n in h.pending: h.send(0x90 or n.ch, n.note, 0)
  for (tk, e) in h.sent:
    var e = e
    e.t = tk / h.rate
    s.events.add e
  if fadeTick >= 0:
    s.fadeFrom = fadeTick / h.rate
  true

# --- XMI songs ----------------------------------------------------------------
#
# Miles Sound System's Extended MIDI (AIL; Theme Hospital, Ultima, Syndicate
# and many more DOS games): IFF chunks, `FORM XDIR` (the song count), then
# `CAT XMID` holding a `FORM XMID` per song with its `EVNT` (and `TIMB`, the
# MT-32 timbres it needs, unused on General MIDI). One track at a fixed 120
# Hz: a delay is the sum of the bytes under 0x80 before an event, a note-on
# carries its length (a VLQ), there's no running status. The tempo was
# applied when the file was made, so its tempo and time signature events only
# tell where beats and bars are. Controllers 110-120 are AIL's own (channel
# locks, protection, bank select, FOR/NEXT loops, beat count, callbacks,
# branch index; 120 isn't All Sound Off) and don't go to the synthesizer;
# a FOR (116, its count, 0: forever) to NEXT (117 >= 64) loop repeats, 117
# under 64 breaks out.

const
  XmiRate = 120
  XmiLoops = 2              ## times a forever loop plays, then it fades

proc be32At(d: string, p: int): int =
  if p + 3 < d.len: d.be32(p) else: 0

proc xmiEvents(d: string): (int, int) =
  ## The first song's EVNT chunk: start and end, (0, 0) when there's none.
  proc walk(d: string, p, stop: int): (int, int) =
    var p = p
    while p + 8 <= stop:
      let id = d[p ..< p + 4]
      let n = d.be32At(p + 4)
      let q = p + 8
      if id in ["FORM", "CAT "]:
        let r = walk(d, q + 4, min(stop, q + n))
        if r[1] > 0: return r
      elif id == "EVNT":
        return (q, min(stop, q + n))
      p = q + n + (n and 1)
  walk(d, 0, d.len)

proc parseXmi(d: string, s: MidiSong, tempos: var seq[(float, int)],
              sigs: var seq[(float, int, int)]): bool =
  let (start, stop) = xmiEvents(d)
  if stop <= start: return false
  s.format = "XMI song (Miles Sound System)"
  type Out = object
    tick, order: int
    e: MidiEvent
  var outs: seq[Out]
  var order = 0
  template emit(tk: int, msg: MidiEvent, first = false) =
    outs.add Out(tick: tk, order: (if first: -1 else: order), e: msg)
    inc order
  var p = start
  var tick = 0
  var loops: seq[(int, int, int)]   # (where the loop starts, count left (0: forever), tick)
  var forever = 0                   # times a forever loop came round
  var fadeTick = -1
  let cap = XmiRate * 3600
  while p < stop and tick < cap:
    var b = d[p].ord
    if b < 0x80:
      tick += b
      inc p
      continue
    inc p
    let hi = b and 0xf0
    if b == 0xff:
      if p >= stop: break
      let kind = d[p].ord
      inc p
      let n = d.vlq(p, stop)
      let body = d[p ..< min(stop, p + n)]
      p += n
      case kind
      of 0x2f: break
      of 0x51:
        if body.len >= 3:
          tempos.add (tick / XmiRate, (body[0].ord shl 16) or (body[1].ord shl 8) or body[2].ord)
      of 0x58:
        if body.len >= 2: sigs.add (tick / XmiRate, body[0].ord, 1 shl min(body[1].ord, 6))
      of 0x03:
        if s.title.len == 0 and body.anyIt(it.isAlphaNumeric): s.title = body.strip
      else: discard
    elif b == 0xf0 or b == 0xf7:
      let n = d.vlq(p, stop)
      let body = d[p ..< min(stop, p + n)]
      p += n
      if b == 0xf0:
        var e = MidiEvent(n: 0, data: "\xF0" & body)
        if not e.data.endsWith("\xF7"): e.data.add '\xF7'
        emit(tick, e)
    else:
      let count = if hi in [0xc0, 0xd0]: 1 else: 2
      if p + count > stop: break
      let d1 = d[p].ord
      let d2 = if count == 2: d[p + 1].ord else: 0
      p += count
      if hi == 0x90:
        let dur = d.vlq(p, stop)
        emit(tick, ev(0, b, d1, d2, 3))
        # Its end: before anything else at that tick, so a note struck
        # again right as it ends isn't cut.
        emit(tick + dur, ev(0, 0x90 or (b and 0x0f), d1, 0, 3), first = true)
      elif hi == 0xb0 and d1 in 110 .. 120:
        if d1 == 116:
          loops.add (p, d2, tick)
        elif d1 == 117 and loops.len > 0:
          if d2 < 64:
            loops.setLen loops.len - 1      # BREAK
          else:
            var (at, left, _) = loops[^1]
            if left == 0:                   # forever: twice, then a fade
              inc forever
              if forever >= XmiLoops and fadeTick < 0: fadeTick = tick
              p = at
            elif left > 1:
              loops[^1][1] = left - 1
              p = at
            else:
              loops.setLen loops.len - 1
      else:
        emit(tick, ev(0, b, d1, d2, count + 1))
    if fadeTick >= 0 and tick - fadeTick >= int(HmiFade * XmiRate.float): break
  if outs.len == 0: return false
  outs.sort(proc (a, b: Out): int = cmp((a.tick, a.order), (b.tick, b.order)))
  for o in outs:
    var e = o.e
    e.t = o.tick / XmiRate
    s.events.add e
  if fadeTick >= 0: s.fadeFrom = fadeTick / XmiRate
  true

proc rowsFromTempo(s: MidiSong, tempos: seq[(float, int)], sigs: seq[(float, int, int)]) =
  ## Rows from tempo and time signature events already in seconds (an XMI
  ## song's: its beats are real time). Its times were rounded down to whole
  ## 120 Hz ticks, so notes can start up to a tick early.
  var onsets: seq[float]
  for e in s.events:
    if e.n == 3 and (e.b[0] and 0xf0) == 0x90 and e.b[2] > 0: onsets.add e.t * XmiRate
  let perQuarter = rowsPerQuarter(onsets, tempos[0][1].float * XmiRate / 1e6, 1.0)
  var t = 0.0
  var ti, si = -1
  while t <= s.length:
    while ti + 1 < tempos.len and tempos[ti + 1][0] <= t + 1e-9: inc ti
    while si + 1 < sigs.len and sigs[si + 1][0] <= t + 1e-9: inc si
    let us = if ti >= 0: tempos[ti][1] else: 500_000
    let (num, den) = if si >= 0: (max(1, sigs[si][1]), sigs[si][2]) else: (4, 4)
    let beatRows = max(1, perQuarter * 4 div den)
    let row = max(0.01, us.float / 1e6 * 4 / den.float / beatRows.float)
    s.bars.add s.rowT.len
    s.beatRows.add beatRows
    for r in 0 ..< num * beatRows:
      s.rowT.add t
      t += row

# --- the tempo of an HMI song, from its notes -------------------------------

proc guessRows(s: MidiSong) =
  ## 16th-note rows at the period the notes' starts line up best with
  ## (their circular mean over each period tried), bars of 16 rows.
  var on: seq[float]
  for e in s.events:
    if e.n == 3 and (e.b[0] and 0xf0) == 0x90 and e.b[2] > 0:
      if on.len == 0 or e.t != on[^1]: on.add e.t
  var best = (0.0, 0.125, 0.0)  # strength, period (s), phase (s)
  if on.len >= 8:
    var period = 0.04
    while period <= 0.2:
      var cx, cy: float
      for t in on:
        let a = 2 * PI * t / period
        cx += cos(a)
        cy += sin(a)
      let r = hypot(cx, cy) / on.len.float
      if r > best[0]:
        var ph = arctan2(cy, cx) / (2 * PI) * period
        if ph < 0: ph += period
        best = (r, period, ph)
      period += 0.0001
  let (_, step, phase) = best
  s.tempoGuessed = true
  var t = phase
  if t > 0.002:
    s.rowT.add 0.0
    s.bars.add 0
    s.beatRows.add 4
  var i = 0
  while t <= s.length:
    if i mod 16 == 0:
      s.bars.add s.rowT.len
      s.beatRows.add 4
    s.rowT.add t
    t += step
    inc i

# ------------------------------------------------------------------------------

proc openMidi*(path: string): MidiSong =
  ## The song at path, nil when it's neither a standard MIDI file nor an HMI
  ## song (or can't be read).
  var d: string
  try: d = readFile(path)
  except IOError, OSError: return nil
  result = MidiSong(path: path)
  let hmi = d.startsWith("HMI-MIDISONG")
  let xmi = d.startsWith("FORM") and d.len >= 12 and d[8 ..< 12] in ["XDIR", "XMID"]
  var tempos: seq[(float, int)]
  var sigs: seq[(float, int, int)]
  let ok = if hmi: parseHmi(d, result)
           elif xmi: parseXmi(d, result, tempos, sigs)
           else: parseSmf(d, result)
  if not ok or result.events.len == 0: return nil
  result.events.sort(proc (a, b: MidiEvent): int = cmp(a.t, b.t), SortOrder.Ascending)
  result.length = result.events[^1].t + (if result.fadeFrom > 0: 0.0 else: Tail)
  if hmi: result.guessRows()
  elif xmi:
    if tempos.len > 0: result.rowsFromTempo(tempos, sigs)
    else: result.guessRows()

proc isMidiPath*(path: string): bool =
  path.splitFile.ext.toLowerAscii in [".mid", ".midi", ".rmi", ".kar", ".hmi", ".xmi"]
