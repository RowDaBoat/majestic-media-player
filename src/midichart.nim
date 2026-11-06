## A MIDI song laid out for the tracker chart, as a tracker would hold it:
## each bar a pattern, each 16th note a row (midisong's rows), and each MIDI
## channel as many columns as it plays notes at once. A note goes in the
## first of its channel's columns free when it starts and stays there until
## it ends, where "===" marks its end when nothing starts there. Cells read
## note, instrument (the channel's program, 1-based) and velocity.
##
## Levels, per column every VuStep: the note's velocity scaled by the
## channel's volume and expression, sinking slowly while it's held and gone
## shortly after it ends.

import std/[algorithm, math, os, sequtils, strformat, strutils]
import tracker, midisong

const
  MaxVoices = 8            ## columns per channel at most
  Release = 0.25           ## seconds a level takes to go after its note ends
  Sink = 2.5               ## seconds for a held note's level to sink to 1/e
  NoteNames = ["C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"]

type
  Note = object
    start, stop: float
    ch, key, vel, prog: int
    gain: float32          ## volume x expression when it started, 0..1
  Kind = enum ckEmpty, ckNote, ckOff
  Slot = object
    kind: Kind
    key, prog, vel: uint8

proc notesOf(s: MidiSong): seq[Note] =
  ## Every note with its end, program and level; a key struck again while
  ## held ends the one before.
  var prog: array[16, int]
  var vol, expr: array[16, int]
  for c in 0 .. 15: (vol[c], expr[c]) = (100, 127)
  var held: array[16, array[128, int]]  # index into result, -1 none
  for c in 0 .. 15:
    for k in 0 .. 127: held[c][k] = -1
  for e in s.events:
    if e.n == 0: continue
    let st = e.b[0].int
    let c = st and 0x0f
    case st and 0xf0
    of 0x90, 0x80:
      let k = e.b[1].int
      if held[c][k] >= 0:
        result[held[c][k]].stop = e.t
        held[c][k] = -1
      if (st and 0xf0) == 0x90 and e.b[2] > 0:
        held[c][k] = result.len
        result.add Note(start: e.t, stop: -1, ch: c, key: k, vel: e.b[2].int, prog: prog[c],
                        gain: float32(vol[c] * expr[c]) / (127 * 127))
    of 0xb0:
      case e.b[1].int
      of 7: vol[c] = e.b[2].int
      of 11: expr[c] = e.b[2].int
      of 120, 123:
        for k in 0 .. 127:
          if held[c][k] >= 0:
            result[held[c][k]].stop = e.t
            held[c][k] = -1
      else: discard
    of 0xc0: prog[c] = e.b[1].int
    else: discard
  for n in result.mitems:
    if n.stop < 0: n.stop = s.length

proc rowOf(s: MidiSong, t: float): int =
  ## The row t falls in, rounded to the nearest row's start: notes played a
  ## hair early still land on the beat they're for.
  let i = s.rowT.upperBound(t, proc (a, b: float): int = cmp(a, b)) - 1
  if i < 0: return 0
  if i + 1 < s.rowT.len and s.rowT[i + 1] - t < (s.rowT[i + 1] - s.rowT[i]) * 0.3: i + 1
  else: i

proc cellText(sl: Slot, width: int, drums: bool): Cell =
  ## The cell at width (0/10: note, instrument, velocity; 6: note, velocity
  ## in hex; 3: the note).
  let w = if width == 0: 11 elif width >= 9: 9 elif width >= 6: 6 else: 3
  case sl.kind
  of ckEmpty:
    let t = case w
            of 11: "... ... ..."
            of 9: "... .. .."
            of 6: "... .."
            else: "..."
    Cell(text: t, hl: '.'.repeat(t.len))
  of ckOff:
    let t = "===" & ' '.repeat(w - 3)
    Cell(text: t, hl: "mmm" & ' '.repeat(w - 3))
  of ckNote:
    let k = sl.key.int
    let name = NoteNames[k mod 12] & $(k div 12 - 1).clamp(0, 9)
    let p = sl.prog.int + 1
    let v = sl.vel.int
    case w
    of 11: Cell(text: &"{name} {p:03} {v:03}", hl: "nnn iii vvv")
    of 9: Cell(text: &"{name} {p:02X} {v:02X}", hl: "nnn ii vv")
    of 6: Cell(text: &"{name} {v:02X}", hl: "nnn vv")
    else: Cell(text: name, hl: "nnn")

proc openMidiChart*(s: MidiSong, font: string): TrackerSong =
  ## The chart's song for s, played with the SoundFont at font.
  if s == nil or s.rowT.len == 0 or s.bars.len == 0: return nil
  let notes = s.notesOf
  # Columns: each channel's voices, in channel order.
  var voices: array[16, int]
  var voiceOf = newSeq[int](notes.len)
  var busy: array[16, seq[float]]  # each voice's note end
  var order = toSeq(0 ..< notes.len)
  order.sort(proc (a, b: int): int = cmp(notes[a].start, notes[b].start))
  for i in order:
    let n = notes[i]
    var v = -1
    for j, until in busy[n.ch]:
      if until <= n.start + 1e-6:
        v = j
        break
    if v < 0:
      if busy[n.ch].len < MaxVoices:
        busy[n.ch].add 0
        v = busy[n.ch].high
      else:
        v = busy[n.ch].minIndex
    busy[n.ch][v] = n.stop
    voiceOf[i] = v
  var first: array[16, int]
  var labels: seq[string]
  var used = 0
  for c in 0 .. 15:
    voices[c] = busy[c].len
    first[c] = labels.len
    for v in 0 ..< voices[c]:
      labels.add(if v == 0: $(c + 1) else: $(c + 1) & char(ord('a') + v))
    if voices[c] > 0: inc used
  let cols = labels.len
  if cols == 0: return nil
  # The grid: every row's slot in every column.
  let rows = s.rowT.len
  var grid = newSeq[Slot](rows * cols)
  for i, n in notes:
    let col = first[n.ch] + voiceOf[i]
    let r = s.rowOf(n.start)
    if grid[r * cols + col].kind != ckNote:
      grid[r * cols + col] = Slot(kind: ckNote, key: n.key.uint8, prog: n.prog.uint8, vel: n.vel.uint8)
  for i, n in notes:
    let col = first[n.ch] + voiceOf[i]
    let r = s.rowOf(n.stop)
    if r > s.rowOf(n.start) and r < rows and grid[r * cols + col].kind == ckEmpty:
      grid[r * cols + col] = Slot(kind: ckOff)
  # Levels.
  let steps = int(s.length / VuStep) + 1
  var lv = newSeq[float32](steps * cols)
  for i, n in notes:
    let col = first[n.ch] + voiceOf[i]
    let base = float32(n.vel) / 127 * n.gain
    let a = max(0, int(n.start / VuStep))
    let b = min(steps - 1, int((n.stop + Release) / VuStep))
    for k in a .. b:
      let t = k.float * VuStep
      var l = base * exp(-float32(max(0.0, min(t, n.stop) - n.start) / Sink))
      if t > n.stop: l *= clamp(1 - float32((t - n.stop) / Release), 0, 1)
      lv[k * cols + col] = max(lv[k * cols + col], l)
  result = TrackerSong(path: s.path, channels: cols, labels: labels, done: true,
                       length: s.length, placeBars: true)
  result.title = if s.title.len > 0: s.title else: s.path.splitFile.name
  result.tracker = s.format
  result.info = s.format & "  ·  " & font.extractFilename & "  ·  " &
    &"{used} MIDI channel" & (if used == 1: "" else: "s") &
    (if s.tempoGuessed: "  ·  rows by guessed tempo" else: "")
  result.vu = newSeq[uint8](lv.len)
  for i, l in lv: result.vu[i] = uint8(min(255'f32, l * 255))
  for b in 0 ..< s.bars.len:
    let lo = s.bars[b]
    let hi = if b + 1 < s.bars.len: s.bars[b + 1] else: rows
    result.orderPatterns.add b
    result.patRows.add hi - lo
    let beat = max(1, s.beatRows[b])
    result.patBeats.add (beat, max(beat, hi - lo))
    for r in lo ..< hi:
      result.marks.add RowMark(t: s.rowT[r].float32, order: b.int32, row: int32(r - lo))
  let bars = s.bars
  let drumCol = first[9]
  result.cellsOf = proc (pattern, width: int): seq[Cell] =
    let lo = bars[pattern]
    let hi = if pattern + 1 < bars.len: bars[pattern + 1] else: rows
    for r in lo ..< hi:
      for c in 0 ..< cols:
        result.add cellText(grid[r * cols + c], width, c >= drumCol and c < drumCol + voices[9])
