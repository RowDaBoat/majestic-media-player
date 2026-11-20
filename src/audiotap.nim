## What the player is playing, as samples: the visualizer's audio.
##
## Linux: libpulse (`dlopen`ed; PipeWire's pulse server too) records the
## monitor of each of this process's playback streams (sink inputs), as
## pavucontrol's level meters do, so the samples are the ones going out:
## after mpv's volume and filters, in time with the sound. Streams come and go
## with files (mpv opens one per audio output), followed through the server's
## sink-input events. The callbacks run on libpulse's thread and touch only
## C memory.
##
## Windows (10 2004+): WASAPI's process loopback records this process's
## sound (mpv's output, its children's too) on a thread of its own, polled
## every 5 ms. Older Windows hands back silence.
##
## macOS (14.2+): a Core Audio process tap on this process's sound, kept in
## cocoa.m (it resamples to TapRate itself). Older macOS hands back silence.

import std/[locks, monotimes, times, os]

const
  RingFrames* = 8192          ## per stream, stereo
  MaxStreams = 8
  TapRate* = 44100            ## what Winamp's visualizers saw

type
  Slot = object
    tap: ptr TapState         ## back to the tap, for callbacks given the slot
    index: int
    used, connected: bool
    input, sink: uint32
    stream: pointer
    ring: array[RingFrames * 2, float32]
    written: int              ## frames ever written
    lastWrite: int64          ## monotonic ns

  TapState = object
    lock: Lock
    lib, ml, ctx: pointer
    pid: array[24, char]
    slots: array[MaxStreams, Slot]
    ready: bool
    quit: bool                ## Windows: the capture thread stops

  AudioTap* = ptr TapState

when defined(macosx):
  import cocoa

when defined(linux):
  proc dlopen(path: cstring, mode: cint): pointer {.importc, header: "<dlfcn.h>".}
  proc dlsym(h: pointer, name: cstring): pointer {.importc, header: "<dlfcn.h>".}
  proc strcmp(a, b: cstring): cint {.importc, header: "<string.h>".}
  proc getpid(): cint {.importc, header: "<unistd.h>".}

  type
    PaSampleSpec {.bycopy.} = object
      format: cint
      rate: uint32
      channels: uint8
    PaBufferAttr {.bycopy.} = object
      maxlength, tlength, prebuf, minreq, fragsize: uint32
    CtxCb = proc (c: pointer, ud: pointer) {.cdecl.}
    SubCb = proc (c: pointer, t: cint, idx: uint32, ud: pointer) {.cdecl.}
    InfoCb = proc (c: pointer, info: pointer, eol: cint, ud: pointer) {.cdecl.}
    ReadCb = proc (s: pointer, nbytes: csize_t, ud: pointer) {.cdecl.}
    StateCb = proc (s: pointer, ud: pointer) {.cdecl.}

  var
    paMlNew: proc (): pointer {.cdecl.}
    paMlGetApi: proc (m: pointer): pointer {.cdecl.}
    paMlStart: proc (m: pointer): cint {.cdecl.}
    paMlStop: proc (m: pointer) {.cdecl.}
    paMlFree: proc (m: pointer) {.cdecl.}
    paMlLock: proc (m: pointer) {.cdecl.}
    paMlUnlock: proc (m: pointer) {.cdecl.}
    paCtxNew: proc (api: pointer, name: cstring): pointer {.cdecl.}
    paCtxConnect: proc (c: pointer, server: cstring, flags: cint, api: pointer): cint {.cdecl.}
    paCtxDisconnect: proc (c: pointer) {.cdecl.}
    paCtxUnref: proc (c: pointer) {.cdecl.}
    paCtxGetState: proc (c: pointer): cint {.cdecl.}
    paCtxSetStateCb: proc (c: pointer, cb: CtxCb, ud: pointer) {.cdecl.}
    paCtxSetSubscribeCb: proc (c: pointer, cb: SubCb, ud: pointer) {.cdecl.}
    paCtxSubscribe: proc (c: pointer, mask: cint, cb: pointer, ud: pointer): pointer {.cdecl.}
    paCtxSinkInputList: proc (c: pointer, cb: InfoCb, ud: pointer): pointer {.cdecl.}
    paCtxSinkInput: proc (c: pointer, idx: uint32, cb: InfoCb, ud: pointer): pointer {.cdecl.}
    paCtxSinkByIndex: proc (c: pointer, idx: uint32, cb: InfoCb, ud: pointer): pointer {.cdecl.}
    paOpUnref: proc (o: pointer) {.cdecl.}
    paProplistGets: proc (p: pointer, key: cstring): cstring {.cdecl.}
    paStreamNew: proc (c: pointer, name: cstring, ss: ptr PaSampleSpec, map: pointer): pointer {.cdecl.}
    paStreamSetMonitor: proc (s: pointer, idx: uint32): cint {.cdecl.}
    paStreamSetReadCb: proc (s: pointer, cb: ReadCb, ud: pointer) {.cdecl.}
    paStreamSetStateCb: proc (s: pointer, cb: StateCb, ud: pointer) {.cdecl.}
    paStreamConnectRecord: proc (s: pointer, dev: cstring, attr: ptr PaBufferAttr, flags: cint): cint {.cdecl.}
    paStreamPeek: proc (s: pointer, data: ptr pointer, n: ptr csize_t): cint {.cdecl.}
    paStreamDrop: proc (s: pointer): cint {.cdecl.}
    paStreamDisconnect: proc (s: pointer): cint {.cdecl.}
    paStreamUnref: proc (s: pointer) {.cdecl.}
    paStreamGetState: proc (s: pointer): cint {.cdecl.}

  const
    SampleFloat32le = 5
    StreamAdjustLatency = 8192
    StreamDontMove = 512
    MaskSinkInput = 4
    CtxReady = 4
    EvFacilityMask = 0x0f
    EvTypeMask = 0x30
    EvSinkInput = 2
    EvNew = 0
    EvChange = 0x10
    EvRemove = 0x20
    StreamCreating = 1
    StreamReady = 2
    StreamFailed = 3
    StreamTerminated = 4
    NoIndex = high(uint32)    ## PA_INVALID_INDEX

  proc loadPulse(t: AudioTap): bool =
    t.lib = dlopen("libpulse.so.0", 2)
    if t.lib == nil: return false
    template get(v: untyped, name: string) =
      v = cast[typeof(v)](dlsym(t.lib, name))
      if v == nil: return false
    get(paMlNew, "pa_threaded_mainloop_new")
    get(paMlGetApi, "pa_threaded_mainloop_get_api")
    get(paMlStart, "pa_threaded_mainloop_start")
    get(paMlStop, "pa_threaded_mainloop_stop")
    get(paMlFree, "pa_threaded_mainloop_free")
    get(paMlLock, "pa_threaded_mainloop_lock")
    get(paMlUnlock, "pa_threaded_mainloop_unlock")
    get(paCtxNew, "pa_context_new")
    get(paCtxConnect, "pa_context_connect")
    get(paCtxDisconnect, "pa_context_disconnect")
    get(paCtxUnref, "pa_context_unref")
    get(paCtxGetState, "pa_context_get_state")
    get(paCtxSetStateCb, "pa_context_set_state_callback")
    get(paCtxSetSubscribeCb, "pa_context_set_subscribe_callback")
    get(paCtxSubscribe, "pa_context_subscribe")
    get(paCtxSinkInputList, "pa_context_get_sink_input_info_list")
    get(paCtxSinkInput, "pa_context_get_sink_input_info")
    get(paCtxSinkByIndex, "pa_context_get_sink_info_by_index")
    get(paOpUnref, "pa_operation_unref")
    get(paProplistGets, "pa_proplist_gets")
    get(paStreamNew, "pa_stream_new")
    get(paStreamSetMonitor, "pa_stream_set_monitor_stream")
    get(paStreamSetReadCb, "pa_stream_set_read_callback")
    get(paStreamSetStateCb, "pa_stream_set_state_callback")
    get(paStreamConnectRecord, "pa_stream_connect_record")
    get(paStreamPeek, "pa_stream_peek")
    get(paStreamDrop, "pa_stream_drop")
    get(paStreamDisconnect, "pa_stream_disconnect")
    get(paStreamUnref, "pa_stream_unref")
    get(paStreamGetState, "pa_stream_get_state")
    true

  # pa_sink_input_info / pa_sink_info fields (64-bit layout of libpulse's ABI)
  const
    SiIndex = 0
    SiSink = 24
    SiProplist = 344
    SkIndex = 8
    SkMonitorName = 312

  proc u32At(p: pointer, off: int): uint32 = cast[ptr uint32](cast[uint](p) + uint(off))[]
  proc ptrAt(p: pointer, off: int): pointer = cast[ptr pointer](cast[uint](p) + uint(off))[]

  proc onDropState(st: pointer, ud: pointer) {.cdecl.} =
    ## A stream let go of while the server was still making it: closed as
    ## soon as it's made. (The context holds it until it ends.)
    if paStreamGetState(st) == StreamReady:
      paStreamSetStateCb(st, nil, nil)
      discard paStreamDisconnect(st)

  proc release(t: AudioTap, i: int) =
    ## Drops slot i's stream (mainloop locked or in a callback).
    let s = addr t.slots[i]
    if s.stream != nil:
      paStreamSetReadCb(s.stream, nil, nil)
      # pa_stream_disconnect refuses a stream still being made: left as it
      # was, it would record (into libpulse's buffer) for good.
      if paStreamGetState(s.stream) == StreamCreating:
        paStreamSetStateCb(s.stream, onDropState, nil)
      else:
        paStreamSetStateCb(s.stream, nil, nil)
        discard paStreamDisconnect(s.stream)
      paStreamUnref(s.stream)
    acquire(t.lock)
    s.used = false
    s.connected = false
    s.stream = nil
    release(t.lock)

  proc onRead(st: pointer, nbytes: csize_t, ud: pointer) {.cdecl.} =
    let i = cast[ptr Slot](ud).index
    let t = cast[ptr Slot](ud).tap
    var data: pointer
    var n: csize_t
    while paStreamPeek(st, addr data, addr n) == 0 and n > 0:
      if data != nil:
        let frames = int(n) div 8
        let f = cast[ptr UncheckedArray[float32]](data)
        acquire(t.lock)
        let s = addr t.slots[i]
        for k in 0 ..< frames:
          let w = (s.written mod RingFrames) * 2
          s.ring[w] = f[k * 2]
          s.ring[w + 1] = f[k * 2 + 1]
          inc s.written
        if s.written == frames: stderr.writeLine "AVSTRACE tap first data slot ", i  # AVSTRACE
        s.lastWrite = getMonoTime().ticks
        release(t.lock)
      discard paStreamDrop(st)

  proc onStreamState(st: pointer, ud: pointer) {.cdecl.} =
    let i = cast[ptr Slot](ud).index
    let t = cast[ptr Slot](ud).tap
    let state = paStreamGetState(st)
    if state == StreamFailed or state == StreamTerminated:
      if t.slots[i].stream == st: t.release(i)

  proc onSink(c: pointer, info: pointer, eol: cint, ud: pointer) {.cdecl.} =
    ## The sink a stream of ours plays to: record its monitor of that stream.
    if eol != 0 or info == nil: return
    let s = cast[ptr Slot](ud)
    # An answer for the sink it was on before it moved: the next one's due.
    if not s.used or s.stream != nil or u32At(info, SkIndex) != s.sink: return
    let monitor = cast[cstring](ptrAt(info, SkMonitorName))
    var spec = PaSampleSpec(format: SampleFloat32le, rate: TapRate, channels: 2)
    let st = paStreamNew(c, "Majestic visualizer", addr spec, nil)
    if st == nil: return
    discard paStreamSetMonitor(st, s.input)
    paStreamSetReadCb(st, onRead, ud)
    paStreamSetStateCb(st, onStreamState, ud)
    var attr = PaBufferAttr(maxlength: high(uint32), tlength: high(uint32), prebuf: high(uint32),
                            minreq: high(uint32), fragsize: 512 * 8)
    if paStreamConnectRecord(st, monitor, addr attr, StreamAdjustLatency or StreamDontMove) != 0:
      paStreamUnref(st)
      return
    s.stream = st
    s.connected = true
    stderr.writeLine "AVSTRACE tap recording monitor ", monitor, " of input ", s.input  # AVSTRACE

  proc onSinkInput(c: pointer, info: pointer, eol: cint, ud: pointer) {.cdecl.} =
    ## A playback stream: ours when its client's process is this one.
    if eol != 0 or info == nil: return
    let t = cast[AudioTap](ud)
    let pl = ptrAt(info, SiProplist)
    if pl == nil: return
    let pid = paProplistGets(pl, "application.process.id")
    if pid == nil or strcmp(pid, cast[cstring](addr t.pid[0])) != 0: return
    let idx = u32At(info, SiIndex)
    let sink = u32At(info, SiSink)
    stderr.writeLine "AVSTRACE tap sink-input ", idx, " sink ", sink  # AVSTRACE
    var slot = -1
    for i in 0 ..< MaxStreams:
      if t.slots[i].used and t.slots[i].input == idx:
        if t.slots[i].sink == sink: return  # nothing new
        t.release(i)                       # moved to another sink: follow it
        slot = i
        break
    if slot < 0:
      for i in 0 ..< MaxStreams:
        if not t.slots[i].used:
          slot = i
          break
    if slot < 0: return
    acquire(t.lock)
    let s = addr t.slots[slot]
    s.used = true
    s.connected = false
    s.input = idx
    s.sink = sink
    s.stream = nil
    s.written = 0
    release(t.lock)
    # A new stream is told of before it's linked, with no sink: recorded once
    # it has one (the server would answer for its default sink meanwhile).
    if sink == NoIndex: return
    let o = paCtxSinkByIndex(c, sink, onSink, s)
    if o != nil: paOpUnref(o)

  proc onEvent(c: pointer, ev: cint, idx: uint32, ud: pointer) {.cdecl.} =
    let t = cast[AudioTap](ud)
    if (ev and EvFacilityMask) != EvSinkInput: return
    case ev and EvTypeMask
    of EvRemove:
      for i in 0 ..< MaxStreams:
        if t.slots[i].used and t.slots[i].input == idx: t.release(i)
    of EvNew, EvChange:
      let o = paCtxSinkInput(c, idx, onSinkInput, ud)
      if o != nil: paOpUnref(o)
    else: discard

  proc onContext(c: pointer, ud: pointer) {.cdecl.} =
    let t = cast[AudioTap](ud)
    if paCtxGetState(c) == CtxReady and not t.ready:
      t.ready = true
      paCtxSetSubscribeCb(c, onEvent, ud)
      var o = paCtxSubscribe(c, MaskSinkInput, nil, nil)
      if o != nil: paOpUnref(o)
      o = paCtxSinkInputList(c, onSinkInput, ud)
      if o != nil: paOpUnref(o)


when defined(windows):
  type
    Guid {.bycopy.} = object
      d1: uint32
      d2, d3: uint16
      d4: array[8, uint8]
    WaveFormatEx {.bycopy, packed.} = object
      tag, channels: uint16
      rate, avgBytes: uint32
      blockAlign, bits, cbSize: uint16
    ActivationParams {.bycopy.} = object
      kind: int32             ## AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK
      pid: uint32
      mode: int32             ## PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE
    PropVariant {.bycopy.} = object
      vt, r1, r2, r3: uint16
      size: uint32
      pad: uint32
      data: pointer
    Vtbl = ptr UncheckedArray[pointer]
    ComObj = object
      vtbl: Vtbl
    Com = ptr ComObj
    Handler = object
      vtbl: Vtbl
      event: pointer

  proc CoInitializeEx(r: pointer, flags: uint32): int32 {.stdcall, importc, dynlib: "ole32.dll".}
  proc CoUninitialize() {.stdcall, importc, dynlib: "ole32.dll".}
  proc CreateEventW(a: pointer, manual, initial: int32, name: pointer): pointer {.stdcall, importc, dynlib: "kernel32.dll".}
  proc SetEvent(h: pointer): int32 {.stdcall, importc, dynlib: "kernel32.dll".}
  proc WaitForSingleObject(h: pointer, ms: uint32): uint32 {.stdcall, importc, dynlib: "kernel32.dll".}
  proc CloseHandle(h: pointer): int32 {.stdcall, importc, dynlib: "kernel32.dll".}
  proc LoadLibraryA(name: cstring): pointer {.stdcall, importc, dynlib: "kernel32.dll".}
  proc GetProcAddress(m: pointer, name: cstring): pointer {.stdcall, importc, dynlib: "kernel32.dll".}
  proc GetCurrentProcessId(): uint32 {.stdcall, importc, dynlib: "kernel32.dll".}

  const
    IidUnknown = Guid(d1: 0x00000000, d2: 0x0000, d3: 0x0000, d4: [0xC0'u8, 0, 0, 0, 0, 0, 0, 0x46])
    IidAudioClient = Guid(d1: 0x1CB9AD4C, d2: 0xDBFA, d3: 0x4C32, d4: [0xB1'u8, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2])
    IidCaptureClient = Guid(d1: 0xC8ADBD64'u32, d2: 0xE71E, d3: 0x48A0, d4: [0xA4'u8, 0xDE, 0x18, 0x5C, 0x39, 0x5C, 0xD3, 0x17])
    IidCompletion = Guid(d1: 0x41D949AB, d2: 0x9862, d3: 0x444A, d4: [0x80'u8, 0xF6, 0xC2, 0x61, 0x33, 0x4D, 0xA5, 0xEB])
    IidAgile = Guid(d1: 0x94EA2B94'u32, d2: 0xE9CC, d3: 0x49E0, d4: [0xC0'u8, 0xFF, 0xEE, 0x64, 0xCA, 0x8F, 0x5B, 0x90])
    LoopbackPath = "VAD\\Process_Loopback"
    ENoInterface = 0x80004002'u32
    StreamLoopback = 0x00020000'u32
    BufferSilent = 0x2'u32

  proc sameGuid(a, b: ptr Guid): bool = equalMem(a, b, sizeof(Guid))

  proc hQuery(this: ptr Handler, riid: ptr Guid, obj: ptr pointer): int32 {.stdcall.} =
    if sameGuid(riid, unsafeAddr IidUnknown) or sameGuid(riid, unsafeAddr IidCompletion) or
       sameGuid(riid, unsafeAddr IidAgile):
      obj[] = this
      return 0
    obj[] = nil
    cast[int32](ENoInterface)
  proc hAddRef(this: ptr Handler): uint32 {.stdcall.} = 1
  proc hRelease(this: ptr Handler): uint32 {.stdcall.} = 1
  proc hCompleted(this: ptr Handler, op: pointer): int32 {.stdcall.} =
    # On a COM worker thread: only wake ours.
    discard SetEvent(this.event)
    0

  var
    handlerVtbl = [cast[pointer](hQuery), cast[pointer](hAddRef), cast[pointer](hRelease),
                   cast[pointer](hCompleted)]
    capThread: Thread[AudioTap]

  template call(o: Com, slot: int, T: typedesc): untyped = cast[T](o.vtbl[slot])

  proc release(o: Com) =
    if o != nil: discard call(o, 2, proc (t: Com): uint32 {.stdcall.})(o)

  proc wideOf(s: string): seq[uint16] =
    for c in s: result.add uint16(ord(c))
    result.add 0

  proc capture(t: AudioTap) {.thread.} =
    # The COM calls go through vtable pointers the effect system can't see into.
    {.cast(gcsafe).}:
      discard CoInitializeEx(nil, 0)  # multithreaded
      let lib = LoadLibraryA("Mmdevapi.dll")
      let activate = if lib == nil: nil else: GetProcAddress(lib, "ActivateAudioInterfaceAsync")
      if activate == nil:
        CoUninitialize()
        return
      type ActivateFn = proc (path: ptr uint16, riid: ptr Guid, params: ptr PropVariant,
                              handler: pointer, op: ptr Com): int32 {.stdcall.}
      var params = ActivationParams(kind: 1, pid: GetCurrentProcessId(), mode: 0)
      var pv = PropVariant(vt: 65, size: uint32(sizeof(ActivationParams)), data: addr params)  # VT_BLOB
      var handler = Handler(vtbl: cast[Vtbl](addr handlerVtbl[0]), event: CreateEventW(nil, 0, 0, nil))
      var path = wideOf(LoopbackPath)
      var op: Com
      var client, cap: Com
      block setup:
        if cast[ActivateFn](activate)(addr path[0], unsafeAddr IidAudioClient, addr pv,
                                      addr handler, addr op) < 0 or op == nil: break setup
        if WaitForSingleObject(handler.event, 5000) != 0: break setup
        var hr: int32
        var unk: Com
        if call(op, 3, proc (o: Com, hr: ptr int32, unk: ptr Com): int32 {.stdcall.})(op, addr hr, addr unk) < 0 or
           hr < 0 or unk == nil: break setup
        client = unk
        # The loopback takes the format it's asked for: 16-bit stereo, as
        # Microsoft's sample asks.
        var wf = WaveFormatEx(tag: 1, channels: 2, rate: TapRate, avgBytes: TapRate * 4,
                              blockAlign: 4, bits: 16, cbSize: 0)
        if call(client, 3, proc (o: Com, mode, flags: uint32, dur, period: int64, fmt: ptr WaveFormatEx,
                                 session: pointer): int32 {.stdcall.})(client, 0, StreamLoopback,
                                 2_000_000, 0, addr wf, nil) < 0: break setup
        var c: Com
        if call(client, 14, proc (o: Com, riid: ptr Guid, p: ptr Com): int32 {.stdcall.})(
            client, unsafeAddr IidCaptureClient, addr c) < 0 or c == nil: break setup
        cap = c
        if call(client, 10, proc (o: Com): int32 {.stdcall.})(client) < 0: break setup
        let getBuffer = call(cap, 3, proc (o: Com, data: ptr pointer, frames: ptr uint32, flags: ptr uint32,
                                           pos, qpc: pointer): int32 {.stdcall.})
        let releaseBuffer = call(cap, 4, proc (o: Com, frames: uint32): int32 {.stdcall.})
        let nextPacket = call(cap, 5, proc (o: Com, frames: ptr uint32): int32 {.stdcall.})
        while not t.quit:
          var n: uint32
          while nextPacket(cap, addr n) >= 0 and n > 0:
            var data: pointer
            var frames, flags: uint32
            if getBuffer(cap, addr data, addr frames, addr flags, nil, nil) < 0: break
            let src = cast[ptr UncheckedArray[int16]](data)
            acquire(t.lock)
            let s = addr t.slots[0]
            s.used = true
            for k in 0 ..< int(frames):
              let w = (s.written mod RingFrames) * 2
              if (flags and BufferSilent) != 0 or data == nil:
                s.ring[w] = 0
                s.ring[w + 1] = 0
              else:
                s.ring[w] = src[k * 2].float32 / 32768
                s.ring[w + 1] = src[k * 2 + 1].float32 / 32768
              inc s.written
            s.lastWrite = getMonoTime().ticks
            release(t.lock)
            discard releaseBuffer(cap, frames)
          sleep(5)
        discard call(client, 11, proc (o: Com): int32 {.stdcall.})(client)  # Stop
      release(cap)
      release(client)
      release(op)
      if handler.event != nil: discard CloseHandle(handler.event)
      CoUninitialize()

proc startTap*(): AudioTap =
  ## Starts following this process's sound; nil without a sound server.
  result = cast[AudioTap](allocShared0(sizeof(TapState)))
  initLock(result.lock)
  for i in 0 ..< MaxStreams:
    result.slots[i].tap = result
    result.slots[i].index = i
  when defined(linux):
    let t = result
    if not t.loadPulse():
      deinitLock(t.lock)
      deallocShared(t)
      return nil
    let pid = $getpid()
    for i, c in pid: t.pid[i] = c
    t.ml = paMlNew()
    if t.ml == nil: return
    t.ctx = paCtxNew(paMlGetApi(t.ml), "Majestic Media Player visualizer")
    if t.ctx == nil: return
    paCtxSetStateCb(t.ctx, onContext, t)
    if paCtxConnect(t.ctx, nil, 0, nil) < 0: return
    discard paMlStart(t.ml)
  elif defined(windows):
    createThread(capThread, capture, result)
  elif defined(macosx):
    mmpTapStart()

proc stopTap*(t: AudioTap) =
  if t == nil: return
  when defined(linux):
    if t.ml != nil:
      paMlLock(t.ml)
      for i in 0 ..< MaxStreams:
        if t.slots[i].used: t.release(i)
      if t.ctx != nil:
        paCtxDisconnect(t.ctx)
        paCtxUnref(t.ctx)
      paMlUnlock(t.ml)
      paMlStop(t.ml)
      paMlFree(t.ml)
  elif defined(windows):
    t.quit = true
    joinThread(capThread)
  elif defined(macosx):
    mmpTapStop()
  deinitLock(t.lock)
  deallocShared(t)

proc latest*(t: AudioTap, left, right: var openArray[float32]): bool =
  ## The newest left.len frames, every stream of ours summed, older first;
  ## false (and silence) when nothing's playing.
  for v in left.mitems: v = 0
  for v in right.mitems: v = 0
  if t == nil: return false
  let n = min(left.len, right.len)
  when defined(macosx):
    if n == 0: return false
    return mmpTapLatest(left[0].addr, right[0].addr, n.cint) != 0
  let now = getMonoTime().ticks
  acquire(t.lock)
  for s in t.slots.mitems:
    # A corked (paused) stream sends nothing: past 150 ms its last samples are stale.
    if not s.used or s.written == 0 or now - s.lastWrite > 150_000_000: continue
    result = true
    for k in 0 ..< n:
      let f = s.written - n + k
      if f < 0: continue
      let r = (f mod RingFrames) * 2
      left[k] += s.ring[r]
      right[k] += s.ring[r + 1]
  release(t.lock)
