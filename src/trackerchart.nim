## The tracker chart: a tracker module's patterns in the video frame, one
## column per channel, scrolling up through the row that plays, which stays
## in a band across the middle. Each column glows with its channel's level.

import std/[strformat, strutils, math]
import silky, vmath, bumpy, chroma
import theme, ui, tracker

type
  TrackerChart* = ref object
    song*: TrackerSong
    tried*: string        ## the path last opened (or failed to), so it isn't retried
    shown: float          ## the time drawn, smoothed between time-pos updates
    pos: float            ## the time-pos it was smoothed from
    posAt: float          ## when pos changed
    drawnAt: float        ## when shown was last worked out
    jumps: int            ## the player's seeks and steps when last drawn
    jumpAt: float         ## when they last changed
    zoom: int = -1        ## the MonoSizes step zoomed to, -1: fit to the frame
    zoomWidth: int        ## the cell width kept while zoomed (of Widths)
    pan*: Vec2            ## the grid's offset: + x right, + y down (clamped when drawn)
    fitFont, fitWidth: int  ## the zoom step and cell width last drawn
    colsX, colW, centerY, rowH: float32  ## where the columns and band were last drawn
    anchor: Vec2          ## the point a zoom keeps in place, until drawn (x < 0: the pan's place)
    anchorPending: bool
    anchorFrom: (float32, float32, float32, float32, Vec2)  ## colsX, colW, centerY, rowH, pan then

const
  CellPad = 6'f32          ## either side of a column's text
  HeaderH = 46'f32
  ChannelH = 24'f32
  Margin = 12'f32
  Widths = [0, 10, 6, 3]   ## cell widths tried, widest first (0: in full)

proc c(hex: string, alpha = 1.0): ColorRGBX =
  var col = parseHtmlColor(hex)
  col.a = alpha
  col.rgbx

let
  colNote = c("#e7e9ee")
  colSpecial = c("#ff7a90")
  colInstrument = c("#6fb6ff")
  colVolume = c("#7bdc8f")
  colEffect = c("#ffb86b")
  colEmpty = c("#3b3f49")
  colGutter = c("#5c616b")
  colBeat = c("#ffffff", 0.025)
  colMeasure = c("#ffffff", 0.055)
  colBand = c("#9d8cff", 0.16)
  colBandEdge = c("#9d8cff", 0.55)
  colColumnLine = c("#ffffff", 0.06)
  colPatternLine = c("#9d8cff", 0.30)

proc fade(col: ColorRGBX, k: float32): ColorRGBX =
  ## col at k of its opacity (premultiplied).
  let k = clamp(k, 0, 1)
  rgbx(uint8(col.r.float32 * k), uint8(col.g.float32 * k), uint8(col.b.float32 * k),
       uint8(col.a.float32 * k))

proc hlColor(h: char): ColorRGBX =
  case h
  of 'n': colNote
  of 'm': colSpecial
  of 'i': colInstrument
  of 'u', 'v': colVolume
  of 'e', 'f': colEffect
  else: colEmpty

proc close*(c: TrackerChart) =
  if c == nil: return
  c.song.close()
  c.song = nil
  c.pan = vec2(0, 0)

proc zoomed*(c: TrackerChart): bool =
  ## Zoomed or panned away from fitting the frame.
  c != nil and (c.zoom >= 0 or c.pan != vec2(0, 0))

proc resetView*(c: TrackerChart) =
  c.zoom = -1
  c.pan = vec2(0, 0)
  c.anchorPending = false

proc zoomBy*(c: TrackerChart, steps: int, at = vec2(-1, -1)): string =
  ## Zooms the text steps of MonoSizes (+ in), keeping the point at (UI
  ## units, the frame's; else the first column and row shown) in place.
  ## Returns the OSD message, empty before the chart was drawn.
  if c.colW <= 0: return ""
  if c.zoom < 0:
    c.zoom = c.fitFont
    c.zoomWidth = c.fitWidth
  let z = clamp(c.zoom + steps, 0, MonoSizes.high)
  if z != c.zoom:
    if not c.anchorPending:
      c.anchorFrom = (c.colsX, c.colW, c.centerY, c.rowH, c.pan)
    c.anchor = at
    c.anchorPending = true
    c.zoom = z
  &"Zoom: {int(round(MonoSizes[z] / 13 * 100))}%"

proc clock*(c: TrackerChart, timePos, speed: float, playing: bool, jumps: int,
            now: float): float =
  ## The time to draw: time-pos moves in steps (each audio chunk mpv writes),
  ## so it runs on from the last step while playing. Changing speed makes
  ## time-pos jump (mpv counts the buffered sound at the new speed), back and
  ## then ahead, so the time drawn runs on at the speed and only eases toward
  ## it; only a seek (or a loop) moves it at once.
  if jumps != c.jumps:
    c.jumps = jumps
    c.jumpAt = now
  if timePos != c.pos:
    c.pos = timePos
    c.posAt = now
  let speed = max(speed, 0)
  var target = c.pos
  if playing: target += min(0.25, now - c.posAt) * speed
  let dt = now - c.drawnAt
  c.drawnAt = now
  if not playing or dt <= 0 or dt > 0.25 or now - c.jumpAt < 0.5 or abs(target - c.shown) > 1 + speed:
    c.shown = target
    return target
  let err = target - (c.shown + dt * speed)
  c.shown += dt * (speed + clamp(err * 5, -0.8 * speed, 2 * speed + 0.5))
  c.shown

proc successor(s: TrackerSong, o, r: int): (int, int) =
  ## The row after (o, r) in order, (-1, -1) past the end.
  if o < 0 or o >= s.orderPatterns.len: return (-1, -1)
  if r + 1 < s.rows(s.orderPatterns[o]): return (o, r + 1)
  var n = o + 1
  while n < s.orderPatterns.len and s.orderPatterns[n] < 0: inc n
  if n < s.orderPatterns.len: (n, 0) else: (-1, -1)

proc predecessor(s: TrackerSong, o, r: int): (int, int) =
  if o < 0 or o >= s.orderPatterns.len: return (-1, -1)
  if r > 0: return (o, r - 1)
  var n = o - 1
  while n >= 0 and s.orderPatterns[n] < 0: dec n
  if n >= 0: (n, s.rows(s.orderPatterns[n]) - 1) else: (-1, -1)

proc drawCell(ui: Ui, cell: Cell, pos: Vec2, cw: float32, font: string, k: float32) =
  ## The cell's characters in their highlight colors, run by run.
  var i = 0
  while i < cell.text.len:
    var j = i + 1
    let h = if i < cell.hl.len: cell.hl[i] else: ' '
    while j < cell.text.len and (if j < cell.hl.len: cell.hl[j] else: ' ').hlColor == h.hlColor: inc j
    if cell.text[i ..< j].len > 0 and h != ' ':
      ui.text(cell.text[i ..< j], vec2(pos.x + i.float32 * cw, pos.y), fade(h.hlColor, k), font)
    i = j

proc draw*(c: TrackerChart, ui: Ui, area: Rect, t: float) =
  let s = c.song
  if s == nil or s.marks.len == 0 or s.channels == 0: return
  let mi = s.markAt(t)
  let m = s.marks[mi]
  let (order, row) = (m.order.int, m.row.int)
  # Between this row and the next one, if that one follows it in the
  # pattern: the rows glide up rather than jump.
  var frac = 0'f32
  if mi + 1 < s.marks.len:
    let n = s.marks[mi + 1]
    if s.successor(order, row) == (n.order.int, n.row.int) and n.t > m.t:
      frac = clamp((t - m.t) / (n.t - m.t), 0, 1).float32

  ui.sk.pushClipRect(area)
  defer: ui.sk.popClipRect()

  # Header: the title on the left, where the song is on the right.
  var top = area.y
  let showHeader = area.h >= 180 and area.w >= 320
  if showHeader:
    let pat = if order in 0 ..< s.orderPatterns.len: s.orderPatterns[order] else: -1
    let title = if s.title.len > 0: s.title else: "Untitled"
    let place = &"Order {order:03} / {s.orderPatterns.len - 1:03}    " &
      &"Pattern {pat:03}    Row {row:03} / {s.rows(pat) - 1:03}"
    let placeW = ui.textSize(place, FontMonoSmall).x
    let titleW = area.w - 2 * Margin - placeW - 24
    ui.text(ui.ellipsize(title, titleW, FontTitle), vec2(area.x + Margin, area.y + 6), colText, FontTitle)
    let info = (if s.tracker.len > 0: s.tracker & "  ·  " else: "") & &"{s.channels} channels"
    ui.text(ui.ellipsize(info, titleW, FontSmall), vec2(area.x + Margin, area.y + 29), colTextDim, FontSmall)
    ui.text(place, vec2(area.x + area.w - Margin - placeW, area.y + 13), colTextDim, FontMonoSmall)
    top += HeaderH
    ui.rect(rect(area.x, top - 1, area.w, 1), colBorder)

  # The widest cells (and font) that fit every channel; else the narrowest,
  # panned across. Zoomed: the cells kept, in the font zoomed to.
  if order notin 0 ..< s.orderPatterns.len or s.orderPatterns[order] < 0: return
  let pat0 = s.orderPatterns[order]
  # Row numbers as wide as the song's longest pattern needs, so the gutter
  # keeps its width from pattern to pattern.
  let gutterDigits = max(2, len($(s.maxRows - 1)))
  let avail = area.w - 2 * Margin
  proc measure(f: string, w: int): (float32, float32, float32) =
    let fcw = ui.textSize("0", f).x
    let cs = s.cells(pat0, w)
    let chars = if cs.len > 0: cs[0].text.len elif w > 0: w else: 13
    (fcw, chars.float32 * fcw + 2 * CellPad, gutterDigits.float32 * fcw + 2 * CellPad)
  var fontI = MonoSizes.find(11)
  var width = Widths[^1]
  if c.zoom >= 0:
    # The cells zoomed with, or wider ones if they now fit.
    (fontI, width) = (c.zoom, c.zoomWidth)
    for w in Widths:
      if w == width: break
      let (_, cwid, gw) = measure(monoFont(fontI), w)
      if gw + cwid * s.channels.float32 <= avail:
        width = w
        break
  else:
    block fit:
      for f in [MonoSizes.find(13), MonoSizes.find(11)]:
        for w in Widths:
          let (_, cwid, gw) = measure(monoFont(f), w)
          if gw + cwid * s.channels.float32 <= avail:
            (fontI, width) = (f, w)
            break fit
  let font = monoFont(fontI)
  let (cw, colW, gutterW) = measure(font, width)
  (c.fitFont, c.fitWidth) = (fontI, width)
  let rowH = round(ui.textSize("0", font).y + 2)
  # The columns' view: all of them, or whole ones beside room for the
  # counts of those panned out of it.
  let totalW = colW * s.channels.float32
  let moreW = ui.textSize(&"+{s.channels}", FontSmall).x + 8
  let fits = gutterW + totalW <= avail
  let viewW = if fits: totalW
              else: max(colW, floor((avail - gutterW - moreW) / colW) * colW)
  let gridW = gutterW + viewW
  let x0 = round(area.x + max(Margin, (area.w - gridW) / 2))
  let colsX = x0 + gutterW
  let gridTop = top + ChannelH + 6
  let gridH = area.y + area.h - gridTop
  let centerY = round(gridTop + (gridH - rowH) / 2)

  # The pan: a zoom keeps the point under the pointer where it was, then
  # neither the columns nor the band go past the frame's edges.
  if c.anchorPending:
    c.anchorPending = false
    let (aX, aW, aY, aH, aPan) = c.anchorFrom
    if c.anchor.x < 0:
      c.pan = vec2(aPan.x * colW / aW, aPan.y * rowH / aH)
    else:
      let u = (c.anchor.x - aX - aPan.x) / aW
      let v = (c.anchor.y - aY - aPan.y) / aH
      c.pan = vec2(c.anchor.x - colsX - u * colW, c.anchor.y - centerY - v * rowH)
  c.pan.x = if fits: 0'f32 else: clamp(c.pan.x, viewW - totalW, 0)
  c.pan.y = if gridH < rowH: 0'f32 else: clamp(c.pan.y, gridTop - centerY, gridTop + gridH - rowH - centerY)
  c.pan = vec2(round(c.pan.x), round(c.pan.y))
  (c.colsX, c.colW, c.centerY, c.rowH) = (colsX, colW, centerY, rowH)
  let colsLeft = colsX + c.pan.x
  let firstCh = max(0, int(floor(-c.pan.x / colW)))
  let lastCh = min(s.channels - 1, int(ceil((viewW - c.pan.x) / colW)) - 1)
  let view = rect(colsX, area.y, viewW, area.h)

  # Channel heads: the number and a level bar.
  let headY = top + 4
  ui.sk.pushClipRect(view)
  for ch in firstCh .. lastCh:
    let cx = colsLeft + ch.float32 * colW
    let lv = max(s.level(t, ch), max(s.level(t - VuStep, ch), s.level(t - 2 * VuStep, ch)))
    let label = $(ch + 1)
    let lw = ui.textSize(label, FontSmall).x
    ui.text(label, vec2(cx + (colW - lw) / 2, headY), if lv > 0.02: colText else: colTextDim, FontSmall)
    let bar = rect(cx + CellPad, headY + 18, colW - 2 * CellPad, 3)
    ui.rect(bar, colTrack)
    if lv > 0:
      ui.gradient(rect(bar.x, bar.y, bar.w * lv, bar.h), colAccent, colLoop, colLoop, colAccent)
  ui.sk.popClipRect()
  # How many are panned out either side (a column cut in half counts).
  let leftOut = int(ceil(-c.pan.x / colW - 0.01))
  let rightOut = s.channels - int(floor((viewW - c.pan.x) / colW + 0.01))
  if leftOut > 0:
    let more = &"+{leftOut}"
    ui.text(more, vec2(colsX - CellPad - ui.textSize(more, FontSmall).x, headY), colTextDim, FontSmall)
  if rightOut > 0:
    let more = &"+{rightOut}"
    ui.text(more, vec2(colsX + viewW + 8, headY), colTextDim, FontSmall)
  if gridH < rowH: return

  # Column glows: brighter the louder the channel is right now.
  ui.sk.pushClipRect(rect(colsX, gridTop, viewW, gridH))
  for ch in firstCh .. lastCh:
    let cx = colsLeft + ch.float32 * colW
    let lv = s.level(t, ch)
    if lv > 0.01:
      let glow = colAccent.fade(0.16 * lv)
      ui.gradient(rect(cx, gridTop, colW, gridH), glow.fade(0.2), glow.fade(0.2), glow, glow)
    ui.rect(rect(cx, gridTop, 1, gridH), colColumnLine)
  ui.sk.popClipRect()

  # Rows from the playing one outward, both ways, in pattern order. They
  # scroll on through their own time: a row enters the band as it starts and
  # leaves as it ends.
  ui.sk.pushClipRect(rect(area.x, gridTop, area.w, gridH))
  defer: ui.sk.popClipRect()
  let bandY = centerY + c.pan.y
  ui.rect(rect(x0, bandY, gridW, rowH), colBand)
  proc drawRow(o, r: int, y: float32) =
    let p = s.orderPatterns[o]
    let (beat, measure) = s.beat(p)
    let dist = abs(y - bandY) / max(1, gridH / 2)
    let k = if abs(y - bandY) < rowH / 2: 1'f32 else: max(0.12'f32, 0.85 - dist * 0.75)
    if r mod measure == 0: ui.rect(rect(x0, y, gridW, rowH), colMeasure)
    elif r mod beat == 0: ui.rect(rect(x0, y, gridW, rowH), colBeat)
    if r == 0: ui.rect(rect(x0, y, gridW, 1), colPatternLine)
    let num = align($r, gutterDigits, '0')
    ui.text(num, vec2(x0 + CellPad, y + 1),
      fade(if r mod beat == 0: colTextDim else: colGutter, k), font)
    let cells = s.cells(p, width)
    ui.sk.pushClipRect(rect(colsX, y, viewW, rowH))
    for ch in firstCh .. lastCh:
      let i = r * s.channels + ch
      if i < cells.len:
        ui.drawCell(cells[i], vec2(colsLeft + ch.float32 * colW + CellPad, y + 1), cw, font, k)
    ui.sk.popClipRect()
  let y0 = bandY + (0.5 - frac) * rowH
  drawRow(order, row, y0)
  var (o, r) = (order, row)
  var y = y0
  while y + rowH < gridTop + gridH:
    (o, r) = s.successor(o, r)
    if o < 0: break
    y += rowH
    drawRow(o, r, y)
  (o, r) = (order, row)
  y = y0
  while y > gridTop:
    (o, r) = s.predecessor(o, r)
    if o < 0: break
    y -= rowH
    drawRow(o, r, y)
  ui.rect(rect(x0, bandY, gridW, 1), colBandEdge)
  ui.rect(rect(x0, bandY + rowH - 1, gridW, 1), colBandEdge)
