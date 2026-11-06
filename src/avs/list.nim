# Ported from Advanced Visualization Studio 2.81d, Copyright 2005 Nullsoft, Inc.
# BSD license: assets/licenses/AVS-Nullsoft-BSD.txt

## Effect lists (r_list.cpp), the effect registry and the preset file reader.

import std/tables
import core

const
  ListId* = 0xfffffffe'u32
  DllRenderBase* = 16384
  ExtSig = "AVS 2.8+ Effect List Config"

type
  EffectList* = ref object of Effect
    isRoot*: bool
    children*: seq[Effect]
    thisfb: seq[uint32]
    lw, lh: int
    mode*: int32
    inblendval, outblendval: int32
    bufferin, bufferout: int32
    ininvert, outinvert: int32
    useCode: int32
    code: array[2, string]
    compiled: array[2, EelCode]
    inited, needRecompile: bool
    vBeat, vAlphain, vAlphaout, vEnabled, vClear, vW, vH: ptr float64
    beatRender, beatRenderFrames: int32
    fakeEnabled: int32
    saved: array[NBuf, GlobalBuffer]  ## the root's own buffers, swapped in while it renders
    savedOthers: array[NBuf, GlobalBuffer]
    nsaved: bool

  UnknownEffect* = ref object of Effect
    id*: int
    name*: string

  Creator* = proc (): Effect {.nimcall.}

var
  builtins {.threadvar.}: Table[int, Creator]
  apes {.threadvar.}: Table[string, Creator]
  resetVarsOnRecompile* {.threadvar.}: bool

proc registerEffect*(index: int, c: Creator) = builtins[index] = c
proc registerApe*(name: string, c: Creator) = apes[name] = c

method desc*(e: UnknownEffect): string =
  if e.name.len > 0: "Unknown (" & e.name & ")" else: "Unknown (" & $e.id & ")"

proc newEffectList*(root = false): EffectList =
  EffectList(isRoot: root, inblendval: 128, outblendval: 128, beatRenderFrames: 1,
             needRecompile: true, vm: newEelVm())

method desc*(e: EffectList): string = (if e.isRoot: "Main" else: "Effect list")

proc clearfb(e: EffectList): bool = (e.mode and 1) != 0
proc blendin(e: EffectList): int = int((e.mode shr 8) and 31)
proc blendout(e: EffectList): int = int(((e.mode shr 16) and 31) xor 1)
proc extendedSize(e: EffectList): int = int((cast[uint32](e.mode) and 0xFF000000'u32) shr 24)
proc enabled(e: EffectList): bool = ((e.mode and 2) xor 2) != 0 or e.fakeEnabled > 0

const NamedApeToBuiltin = [
  ("Winamp Brightness APE v1", 22), ("Winamp Interleave APE v1", 23),
  ("Winamp Grain APE v1", 24), ("Winamp ClearScreen APE v1", 25),
  ("Nullsoft MIRROR v1", 26), ("Winamp Starfield v1", 27), ("Winamp Text v1", 28),
  ("Winamp Bump v1", 29), ("Winamp Mosaic v1", 30), ("Winamp AVIAPE v1", 32),
  ("Nullsoft Picture Rendering v1", 34), ("Winamp Interf APE v1", 41)]

proc createEffect(index: int, name: string): Effect =
  ## C_RLibrary::CreateRenderer.
  if name.len == 0:
    if index in builtins: return builtins[index]()
    if cast[uint32](index) == ListId: return newEffectList()
  else:
    if name in apes: return apes[name]()
    for (n, i) in NamedApeToBuiltin:
      if n == name and i in builtins: return builtins[i]()
  UnknownEffect(id: index, name: name)

proc loadCode(e: EffectList, d: openArray[byte]) =
  var pos = 0
  if d.len - pos >= 4:
    e.useCode = getInt(d, pos)
    pos += 4
    e.code[0] = loadString(d, pos)
    e.code[1] = loadString(d, pos)

method load*(e: EffectList, d: openArray[byte]) =
  var pos = 0
  if pos < d.len:
    e.mode = int32(d[pos])
    inc pos
  if (e.mode and 0x80) != 0:
    e.mode = (e.mode and not 0x80'i32) or getInt(d, pos)
    pos += 4
  let ext = e.extendedSize + 5
  if ext > 5:
    if pos < ext: (e.inblendval = getInt(d, pos); pos += 4)
    if pos < ext: (e.outblendval = getInt(d, pos); pos += 4)
    if pos < ext: (e.bufferin = getInt(d, pos); pos += 4)
    if pos < ext: (e.bufferout = getInt(d, pos); pos += 4)
    if pos < ext: (e.ininvert = getInt(d, pos); pos += 4)
    if pos < ext: (e.outinvert = getInt(d, pos); pos += 4)
    if pos < ext - 4: (e.beatRender = getInt(d, pos); pos += 4)
    if pos < ext - 4: (e.beatRenderFrames = getInt(d, pos); pos += 4)
  e.useCode = 0
  e.code = ["", ""]
  while pos < d.len:
    if pos + 4 > d.len: break
    var index = int(getInt(d, pos))
    pos += 4
    var name = ""
    if index >= DllRenderBase:
      if pos + 32 > d.len: break
      name = cString(d, pos, 32)
      pos += 32
    if pos + 4 > d.len: break
    let l = int(getInt(d, pos))
    pos += 4
    if pos + l > d.len or l < 0: break
    if ext > 5 and index >= DllRenderBase and name == ExtSig:
      e.loadCode(d.toOpenArray(pos, pos + l - 1))
    else:
      let fx = createEffect(index, name)
      if fx != nil:
        fx.load(d.toOpenArray(pos, pos + l - 1))
        e.children.add fx
    pos += l
  e.needRecompile = true

proc swapIn(e: EffectList) =
  ## set_n_Context: the root's buffers become the global ones.
  if not e.isRoot or e.nsaved: return
  e.nsaved = true
  for i in 0 ..< NBuf:
    swap(e.savedOthers[i], globalBuffers[i])
    swap(globalBuffers[i], e.saved[i])

proc swapOut(e: EffectList) =
  if not e.isRoot or not e.nsaved: return
  e.nsaved = false
  for i in 0 ..< NBuf:
    swap(e.saved[i], globalBuffers[i])
    swap(globalBuffers[i], e.savedOthers[i])

proc depthof(c: uint32, inv: int32): int {.inline.} =
  let r = int(max(max(c and 0xFF, (c and 0xFF00) shr 8), (c and 0xFF0000) shr 16))
  if inv != 0: 255 - r else: r

proc blendInto(o, tfb: Pixels, w, h, mode, val: int, buffer, invert: int32) =
  ## The blend modes shared by input and output: o = mode(o, tfb).
  let n = w * h
  case mode
  of 1: copyPixels(o, tfb, n)
  of 2: avgBlock(o, tfb, n)
  of 3:
    for i in 0 ..< n: o[i] = blendMax(o[i], tfb[i])
  of 4: addBlock(o, tfb, n)
  of 5:
    for i in 0 ..< n: o[i] = blendSub(o[i], tfb[i])
  of 6:
    for i in 0 ..< n: o[i] = blendSub(tfb[i], o[i])
  of 7:
    var y = h div 2
    var off = 0
    while y > 0:
      copyMem(o[off].addr, tfb[off].addr, w * 4)
      off += w * 2
      dec y
  of 8:
    for y in 0 ..< h:
      let r = y and 1
      for k in 0 ..< w div 2: o[y * w + r + 2 * k] = tfb[y * w + r + 2 * k]
  of 9:
    for i in 0 ..< n: o[i] = o[i] xor tfb[i]
  of 10: adjBlock(o, tfb, o, n, val)
  of 11: mulBlock(o, tfb, n)
  of 13:
    for i in 0 ..< n: o[i] = blendMin(o[i], tfb[i])
  of 12:
    let buf = getGlobalBuffer(w, h, buffer, false)
    if buf != nil:
      for i in 0 ..< n: o[i] = blendAdj(tfb[i], o[i], depthof(buf[i], invert))
  else: discard

method render*(e: EffectList, vis: var VisData, isBeat0: int32, fb, fbout: Pixels,
               w, h: int): int =
  var isBeat = isBeat0
  let preinit = (isBeat and BeatPreinit) != 0
  if isBeat != 0 and e.beatRender != 0: e.fakeEnabled = e.beatRenderFrames
  var useEnabled = e.enabled
  var useIn = e.inblendval
  var useOut = e.outblendval
  var useClear = e.clearfb
  if not e.isRoot and e.useCode != 0:
    if e.needRecompile:
      if e.vBeat == nil or resetVarsOnRecompile:
        e.vm.resetVars()
        e.vBeat = e.vm.reg("beat")
        e.vAlphain = e.vm.reg("alphain")
        e.vAlphaout = e.vm.reg("alphaout")
        e.vEnabled = e.vm.reg("enabled")
        e.vClear = e.vm.reg("clear")
        e.vW = e.vm.reg("w")
        e.vH = e.vm.reg("h")
        e.inited = false
      e.needRecompile = false
      for i in 0 .. 1: e.compiled[i] = e.vm.compile(e.code[i])
    e.vBeat[] = (if (isBeat and 1) != 0 and not preinit: 1.0 else: 0.0)
    e.vEnabled[] = (if useEnabled: 1.0 else: 0.0)
    e.vW[] = w.float64
    e.vH[] = h.float64
    e.vClear[] = (if useClear: 1.0 else: 0.0)
    e.vAlphain[] = useIn.float64 / 255.0
    e.vAlphaout[] = useOut.float64 / 255.0
    if e.compiled[0] != nil and not e.inited:
      e.compiled[0].run()
      e.inited = true
    e.compiled[1].run()
    if not preinit:
      isBeat = (if e.vBeat[] > 0.1 or e.vBeat[] < -0.1: 1 else: 0)
    useIn = int32(clamp(ftol(e.vAlphain[] * 255.0), 0, 255))
    useOut = int32(clamp(ftol(e.vAlphaout[] * 255.0), 0, 255))
    useEnabled = e.vEnabled[] > 0.1 or e.vEnabled[] < -0.1
    useClear = e.vClear[] > 0.1 or e.vClear[] < -0.1

  if e.isRoot or (useEnabled and e.blendin == 1 and e.blendout == 1):
    var s = 0
    let saveMode = lineBlendMode
    e.thisfb = @[]
    if useClear and (e.isRoot or e.blendin != 1): clearPixels(fb, w * h)
    if not preinit:
      lineBlendMode = 0
      e.swapIn()
    for fx in e.children:
      let t = fx.render(vis, isBeat, (if s != 0: fbout else: fb), (if s != 0: fb else: fbout), w, h)
      if (t and 1) != 0: s = s xor 1
      if not preinit:
        if (t and RetSetBeat) != 0: isBeat = 1
        if (t and RetClearBeat) != 0: isBeat = 0
    if not preinit:
      lineBlendMode = saveMode
      e.swapOut()
    dec e.fakeEnabled
    return s

  if not useEnabled:
    e.thisfb = @[]
    return 0
  dec e.fakeEnabled

  if e.lw != w or e.lh != h or e.thisfb.len == 0:
    e.thisfb = newSeq[uint32](w * h)
    e.lw = w
    e.lh = h
  let tf = pixelsOf(e.thisfb)
  if useClear: clearPixels(tf, w * h)

  if not preinit:
    e.swapIn()
    var bi = e.blendin
    if bi == 10 and useIn >= 255: bi = 1
    blendInto(tf, fb, w, h, bi, useIn, e.bufferin, e.ininvert)
    e.swapOut()

  var s = 0
  let saveMode = lineBlendMode
  if not preinit: lineBlendMode = 0
  for fx in e.children:
    let t = fx.render(vis, isBeat, (if s != 0: fbout else: tf), (if s != 0: tf else: fbout), w, h)
    if (t and 1) != 0: s = s xor 1
    if not preinit:
      if (t and RetSetBeat) != 0: isBeat = 1
      if (t and RetClearBeat) != 0: isBeat = 0
  if not preinit: lineBlendMode = saveMode

  if not preinit:
    if s != 0: copyPixels(tf, fbout, w * h)
    let src = if s != 0: fbout else: tf
    e.swapIn()
    var bo = e.blendout
    if bo == 10 and useOut >= 255: bo = 1
    if bo == 1 and s != 0:
      e.swapOut()
      return 1
    blendInto(fb, src, w, h, bo, useOut, e.bufferout, e.outinvert)
    e.swapOut()
  0

# --- preset files -----------------------------------------------------------------

const PresetSig = "Nullsoft AVS Preset 0.2\x1a"

proc loadPreset*(data: openArray[byte]): EffectList =
  ## A root list from an .avs file's bytes, nil if it isn't one.
  let n = PresetSig.len
  if data.len <= n + 2: return nil
  for i in 0 ..< n - 2:
    if data[i] != byte(PresetSig[i]): return nil
  if data[n - 2] < byte('1') or data[n - 2] > byte('2') or data[n - 1] != 0x1a: return nil
  result = newEffectList(root = true)
  result.load(data.toOpenArray(n, min(data.len, 1024 * 1024) - 1))

proc freeBuffers*(e: EffectList) =
  for b in e.saved.mitems: b = GlobalBuffer()
