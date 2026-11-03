## Tracker chart data: a tracker module's patterns, read with libopenmpt, and
## the order its rows play in, with each channel's level as it goes.
##
## mpv plays the module through FFmpeg, which keeps libopenmpt to itself, so
## the module is opened a second time here. libopenmpt is loaded at run time:
## without it (Windows' libmpv links it in statically) there's no chart.
##
## libopenmpt has no "which row plays at time t": the module is rendered once,
## silently and at a low rate, a slice per frame (`build`), noting when each
## row starts (`marks`) and every channel's VU level every `VuStep` seconds.

import std/[dynlib, algorithm, tables, monotimes, times]

const
  RenderRate = 8000           ## Hz: just enough for the levels
  Chunk = 40                  ## frames rendered at a time: 5 ms
  VuStep* = Chunk / RenderRate  ## seconds between level samples
  MaxLength = 3 * 3600.0      ## seconds: stop marking past this

type
  Module* = pointer
  CellFn = proc (m: Module, pattern, row, channel: int32, width: csize_t, pad: cint): cstring {.cdecl.}
  Api = object
    create*: proc (data: pointer, size: csize_t, logf, logu, errf, erru: pointer,
                  err: ptr cint, msg: ptr cstring, ctls: pointer): Module {.cdecl.}
    destroy*: proc (m: Module) {.cdecl.}
    freeString*: proc (s: cstring) {.cdecl.}
    numChannels, numOrders, currentOrder, currentRow: proc (m: Module): int32 {.cdecl.}
    orderPattern: proc (m: Module, order: int32): int32 {.cdecl.}
    patternRows, rowsPerBeat, rowsPerMeasure: proc (m: Module, pattern: int32): int32 {.cdecl.}
    format, highlight: CellFn
    readMono: proc (m: Module, rate: int32, count: csize_t, buf: ptr int16): csize_t {.cdecl.}
    position*: proc (m: Module): cdouble {.cdecl.}
    vu: proc (m: Module, channel: int32): cfloat {.cdecl.}
    metadata: proc (m: Module, key: cstring): cstring {.cdecl.}
    channelName: proc (m: Module, channel: int32): cstring {.cdecl.}
    # For modstream, which plays the module.
    readStereo*: proc (m: Module, rate: int32, count: csize_t, buf: ptr float32): csize_t {.cdecl.}
    setPosition*: proc (m: Module, seconds: cdouble): cdouble {.cdecl.}
    duration*: proc (m: Module): cdouble {.cdecl.}
    ctlSetFloat*: proc (m: Module, ctl: cstring, value: cdouble): cint {.cdecl.}
    silentLog*, ignoreErrors*: pointer

  RowMark* = object
    t*: float32          ## seconds into the song the row starts
    order*, row*: int32

  Cell* = object
    text*, hl*: string   ## formatted cell and libopenmpt's highlight per char

  TrackerSong* = ref object
    path*: string
    title*, tracker*: string
    channels*: int
    channelNames*: seq[string]
    orderPatterns*: seq[int]   ## pattern per order, -1 for skip/stop items
    marks*: seq[RowMark]       ## in play order
    vu*: seq[uint8]            ## level per VuStep, `channels` at a time
    done*: bool                ## the whole song is marked
    m: Module                  ## rendering, until done
    renderer: Module           ## the copy that renders (marks, levels)
    cells: Table[(int, int), seq[Cell]]   ## (pattern, width) -> rows * channels
    rowsMost: int              ## most rows of any pattern played, 0: not yet known
    data: string

var
  api*: Api
  apiTried, apiOk: bool

proc loadApi*(): bool =
  if apiTried: return apiOk
  apiTried = true
  let names = when defined(windows): @["libopenmpt.dll", "libopenmpt-0.dll"]
              elif defined(macosx): @["libopenmpt.0.dylib", "libopenmpt.dylib"]
              else: @["libopenmpt.so.0", "libopenmpt.so"]
  var lib: LibHandle
  for n in names:
    lib = loadLib(n)
    if lib != nil: break
  if lib == nil: return false
  template sym(field, name: untyped) =
    let p = lib.symAddr(name)
    if p == nil: return false
    api.field = cast[typeof(api.field)](p)
  sym create, "openmpt_module_create_from_memory2"
  sym destroy, "openmpt_module_destroy"
  sym freeString, "openmpt_free_string"
  sym numChannels, "openmpt_module_get_num_channels"
  sym numOrders, "openmpt_module_get_num_orders"
  sym currentOrder, "openmpt_module_get_current_order"
  sym currentRow, "openmpt_module_get_current_row"
  sym orderPattern, "openmpt_module_get_order_pattern"
  sym patternRows, "openmpt_module_get_pattern_num_rows"
  sym rowsPerBeat, "openmpt_module_get_pattern_rows_per_beat"
  sym rowsPerMeasure, "openmpt_module_get_pattern_rows_per_measure"
  sym format, "openmpt_module_format_pattern_row_channel"
  sym highlight, "openmpt_module_highlight_pattern_row_channel"
  sym readMono, "openmpt_module_read_mono"
  sym position, "openmpt_module_get_position_seconds"
  sym vu, "openmpt_module_get_current_channel_vu_mono"
  sym metadata, "openmpt_module_get_metadata"
  sym channelName, "openmpt_module_get_channel_name"
  sym silentLog, "openmpt_log_func_silent"
  sym ignoreErrors, "openmpt_error_func_ignore"
  sym readStereo, "openmpt_module_read_interleaved_float_stereo"
  sym setPosition, "openmpt_module_set_position_seconds"
  sym duration, "openmpt_module_get_duration_seconds"
  sym ctlSetFloat, "openmpt_module_ctl_set_floatingpoint"
  apiOk = true
  true

proc take(s: cstring): string =
  ## A libopenmpt string, freed.
  if s == nil: return ""
  result = $s
  api.freeString(s)

proc openModule*(data: string): Module =
  if data.len == 0: return nil
  var err: cint
  var msg: cstring
  result = api.create(data[0].unsafeAddr, data.len.csize_t, api.silentLog, nil,
    api.ignoreErrors, nil, err.addr, msg.addr, nil)
  if msg != nil: api.freeString(msg)

proc openTracker*(path: string): TrackerSong =
  ## The module at path, nil when libopenmpt is missing or can't read it.
  if not loadApi(): return nil
  var data: string
  try: data = readFile(path)
  except IOError, OSError: return nil
  let m = openModule(data)
  if m == nil: return nil
  let r = openModule(data)
  if r == nil:
    api.destroy(m)
    return nil
  result = TrackerSong(path: path, m: m, renderer: r, data: data)
  result.title = take(api.metadata(m, "title"))
  result.tracker = take(api.metadata(m, "tracker"))
  result.channels = api.numChannels(m)
  for c in 0 ..< result.channels:
    result.channelNames.add take(api.channelName(m, c.int32))
  for o in 0 ..< api.numOrders(m):
    let p = api.orderPattern(m, o.int32)
    result.orderPatterns.add(if api.patternRows(m, p) > 0: p.int else: -1)

proc close*(s: TrackerSong) =
  if s == nil: return
  if s.renderer != nil: api.destroy(s.renderer)
  if s.m != nil: api.destroy(s.m)
  s.renderer = nil
  s.m = nil

proc rows*(s: TrackerSong, pattern: int): int =
  if s.m == nil or pattern < 0: 0 else: api.patternRows(s.m, pattern.int32).int

proc maxRows*(s: TrackerSong): int =
  ## Most rows of any pattern in the order list.
  if s.rowsMost == 0:
    for p in s.orderPatterns: s.rowsMost = max(s.rowsMost, s.rows(p))
  s.rowsMost

proc beat*(s: TrackerSong, pattern: int): (int, int) =
  ## Rows per beat and per measure (libopenmpt guesses when the format has none).
  if s.m == nil or pattern < 0: return (4, 16)
  result = (api.rowsPerBeat(s.m, pattern.int32).int, api.rowsPerMeasure(s.m, pattern.int32).int)
  if result[0] <= 0: result[0] = 4
  if result[1] <= 0: result[1] = result[0] * 4

proc cells*(s: TrackerSong, pattern, width: int): lent seq[Cell] =
  ## The pattern's cells, `channels` per row, formatted at most width
  ## characters wide (0: in full), padded to the same width.
  let key = (pattern, width)
  if key notin s.cells:
    var cs: seq[Cell]
    let rows = s.rows(pattern)
    cs.setLen rows * s.channels
    for r in 0 ..< rows:
      for c in 0 ..< s.channels:
        let i = r * s.channels + c
        cs[i].text = take(api.format(s.m, pattern.int32, r.int32, c.int32, width.csize_t, 1))
        cs[i].hl = take(api.highlight(s.m, pattern.int32, r.int32, c.int32, width.csize_t, 1))
    s.cells[key] = cs
  s.cells[key]

proc build*(s: TrackerSong, budget: float): bool =
  ## Renders for up to budget seconds, marking rows and levels; true when
  ## anything was added.
  if s.done or s.renderer == nil: return false
  let until = getMonoTime() + initDuration(nanoseconds = int64(budget * 1e9))
  var buf: array[Chunk, int16]
  while getMonoTime() < until:
    if s.marks.len == 0:
      s.marks.add RowMark(t: 0, order: api.currentOrder(s.renderer), row: api.currentRow(s.renderer))
    let n = api.readMono(s.renderer, RenderRate, Chunk, buf[0].addr)
    let t = api.position(s.renderer)
    if n == 0 or t > MaxLength:
      s.done = true
      api.destroy(s.renderer)
      s.renderer = nil
      return true
    result = true
    for c in 0 ..< s.channels:
      s.vu.add uint8(min(255.0, api.vu(s.renderer, c.int32) * 255))
    let (o, r) = (api.currentOrder(s.renderer), api.currentRow(s.renderer))
    if o != s.marks[^1].order or r != s.marks[^1].row:
      s.marks.add RowMark(t: t.float32, order: o, row: r)

proc markAt*(s: TrackerSong, t: float): int =
  ## Index of the row playing at t, -1 before marks exist.
  if s.marks.len == 0: return -1
  let i = s.marks.upperBound(t, proc (m: RowMark, t: float): int = cmp(m.t.float, t))
  max(0, i - 1)

proc level*(s: TrackerSong, t: float, channel: int): float32 =
  ## The channel's VU level at t, 0..1.
  let i = int(t / VuStep) * s.channels + channel
  if i < 0 or i >= s.vu.len or channel >= s.channels: 0 else: s.vu[i].float32 / 255
