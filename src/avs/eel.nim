# Ported from Advanced Visualization Studio 2.81d, Copyright 2005 Nullsoft, Inc.
# BSD license: assets/licenses/AVS-Nullsoft-BSD.txt

## EEL, the expression language of AVS presets, as AVS 2.81d's NS-EEL runs it.
##
## NS-EEL compiled each statement to x86 code working on pointers to doubles:
## a variable evaluates to its own address and an operator writes its result
## to the next slot of a scratch table, so operands are read when the operator
## runs (`a + assign(a, 5)` adds 5 to 5). The code here keeps that model, with
## each node a closure returning a pointer, and keeps NS-EEL's quirks, as
## presets were written against them:
##  - the lexer is NS-EEL's own DFA (its tables are copied below), so `dh` is
##    a hex constant (hex digits ending in h, worth 16 times their value, a bug
##    of its translator) and any character it doesn't know fails the code;
##  - code is split into statements at every `;`, an assignment can only start
##    a statement, and one bad statement discards the whole code;
##  - variable names count only their first 8 characters, case-insensitively;
##  - `if` runs only the branch it takes; values within 0.00001 of zero (and
##    NaN) are false; comparisons are true for NaN; `%` rounds both sides to
##    integers (round-half-even) and divides unsigned by at least 1;
##  - `min` / `max` are averaged as x87 code did, `invsqrt` is the float trick.

import std/[math, strutils]

const
  TempSpace = 2048            ## NSEEL_MAX_TEMPSPACE_ENTRIES
  MegabufBlocks = 64
  MegabufItems = 16384
  CloseFact = 0.00001
  LoopMax = 4096              ## NSEEL_LOOPFUNC_SUPPORT_MAXLEN

type
  Node = proc (): ptr float64 {.closure.}

  VarBlock = ref array[64, float64]
  MegaBlock = ref array[MegabufItems, float64]

  EelVm* = ref object
    ## A variable context (NSEEL_VMCTX): an effect's code sections share one.
    keys: seq[string]
    slots: seq[ptr float64]
    blocks: seq[VarBlock]
    retired: seq[VarBlock]    ## kept alive after a reset, as code may still point there
    megabuf: array[MegabufBlocks, MegaBlock]

  EelCode* = ref object
    stmts: seq[Node]
    keep: seq[ref float64]    ## constants' storage

  EelEnv* = object
    ## What AVS's own functions read, set by the engine before code runs.
    visdata*: ptr array[2, array[2, array[576, int8]]]  ## [spectrum|wave][channel][i]
    tickMs*: uint32           ## GetTickCount()
    posMs*: float64           ## playback position, for gettime(-1)
    lenSec*: float64          ## length, for gettime(-2)
    mouseX*, mouseY*: float64 ## -1..1 over the frame
    mouseButtons*: int        ## bit 0 left, 1 right, 2 middle
    keyDown*: proc (vk: int): bool {.closure, gcsafe.}

var
  tmp {.threadvar.}: array[TempSpace + 64, float64]
  esi {.threadvar.}: int
  globalRegs* {.threadvar.}: array[100, float64]
  gmegabuf {.threadvar.}: array[MegabufBlocks, MegaBlock]
  errorSlot {.threadvar.}: float64
  env* {.threadvar.}: EelEnv
  randState {.threadvar.}: uint32
  lastError* {.threadvar.}: string  ## the statement that failed last

# --- the C library's rand(), as AVS's threads had it -------------------------

proc csrand*(seed: uint32) = randState = seed

proc crand*(): int =
  ## MSVC's rand(): 0..32767.
  randState = randState * 214013'u32 + 2531011'u32
  int((randState shr 16) and 0x7fff)

# --- x87 conversions ---------------------------------------------------------

proc c_nearbyint(x: float64): float64 {.importc: "nearbyint", header: "<math.h>".}

proc fistp32*(x: float64): int32 =
  ## x87 fistp to a dword: round half to even, out of range is 0x80000000.
  if x.isNaN: return low(int32)
  let r = c_nearbyint(x)
  if r < -2147483648.0 or r > 2147483647.0: low(int32) else: int32(r)

proc fistp64(x: float64): int64 =
  if x.isNaN: return low(int64)
  let r = c_nearbyint(x)
  if r < -9.223372036854775808e18 or r >= 9.223372036854775808e18: low(int64) else: int64(r)

template slot(): ptr float64 =
  let p = addr tmp[esi]
  inc esi
  p

proc lt(a, b: float64): bool {.inline.} =
  ## x87 fcomp's C0: below, or unordered.
  a < b or a.isNaN or b.isNaN

proc truthy(x: float64): bool {.inline.} = not lt(abs(x), CloseFact)
proc nonzero(x: float64): bool {.inline.} = abs(x) > CloseFact

proc x87sin(x: float64): float64 =
  if abs(x) >= 9.223372036854775808e18: x else: sin(x)
proc x87cos(x: float64): float64 =
  if abs(x) >= 9.223372036854775808e18: x else: cos(x)
proc x87tan(x: float64): float64 =
  if abs(x) >= 9.223372036854775808e18: x else: sin(x) / cos(x)

proc invsqrt(x: float64): float64 =
  var f = float32(x)
  var i = cast[int32](f)
  i = 0x5f3759df'i32 - (i shr 1)
  let y = float64(cast[float32](i))
  (((x * -0.5) * y) * y + 1.5) * y

# --- variables ---------------------------------------------------------------

proc keyOf(name: string): string =
  result = newString(min(name.len, 8))
  for i in 0 ..< result.len:
    let c = name[i]
    result[i] = if c in {'A'..'Z'}: chr(ord(c) + 32) else: c

proc isReg(name: string): int =
  ## reg00..reg99 are global registers: their index, else -1.
  if name.len == 5 and name[0] in {'r', 'R'} and name[1] in {'e', 'E'} and
     name[2] in {'g', 'G'} and name[3] in {'0'..'9'} and name[4] in {'0'..'9'}:
    return (ord(name[3]) - 48) * 10 + ord(name[4]) - 48
  -1

proc findVar(vm: EelVm, name: string): ptr float64 =
  let k = keyOf(name)
  for i, key in vm.keys:
    if key == k: return vm.slots[i]
  nil

proc addVar(vm: EelVm, name: string): ptr float64 =
  let n = vm.slots.len
  if n mod 64 == 0:
    vm.blocks.add new(VarBlock)
  result = addr vm.blocks[^1][n mod 64]
  vm.keys.add keyOf(name)
  vm.slots.add result

proc reg*(vm: EelVm, name: string): ptr float64 =
  ## NSEEL_VM_regvar: the variable's storage, created if new.
  let r = isReg(name)
  if r >= 0: return addr globalRegs[r]
  result = vm.findVar(name)
  if result == nil: result = vm.addVar(name)

proc resetVars*(vm: EelVm) =
  ## AVS_EEL_IF_resetvars: forgets every variable and the megabuf.
  vm.retired.add vm.blocks
  vm.blocks.setLen 0
  vm.keys.setLen 0
  vm.slots.setLen 0
  for b in vm.megabuf.mitems: b = nil

proc newEelVm*(): EelVm = EelVm()

proc resetGlobals*() =
  for r in globalRegs.mitems: r = 0
  for b in gmegabuf.mitems: b = nil

proc megabufAt(blocks: var array[MegabufBlocks, MegaBlock], which: float64): ptr float64 =
  let wf = which + 0.0001
  if wf.isNaN or wf >= 2147483648.0 or wf <= -2147483649.0: return addr errorSlot
  let w = int(wf)  # C truncation
  let b = w div MegabufItems
  if w >= 0 and b < MegabufBlocks:
    if blocks[b] == nil: blocks[b] = new(MegaBlock)
    return addr blocks[b][w mod MegabufItems]
  addr errorSlot

# --- AVS's functions -----------------------------------------------------------

proc toCInt(x: float64): int =
  ## C's (int) cast, MSVC's _ftol: truncation, garbage out of range.
  if x.isNaN or x >= 2147483648.0 or x <= -2147483649.0: return low(int32)
  int(x)

proc getvis(off: int, bc0, bw0, ch, xorv: int): float64 =
  if env.visdata == nil: return 0
  if ch != 0 and ch != 1 and ch != 2: return 0
  let v = cast[ptr UncheckedArray[uint8]](env.visdata)
  var bw = bw0
  var bc = bc0
  if bw < 1: bw = 1
  bc -= bw div 2
  if bc < 0:
    bw += bc
    bc = 0
  if bc > 575: bc = 575
  if bc + bw > 576: bw = 576 - bc
  var accum = 0
  if ch == 0:
    for x in 0 ..< bw:
      accum += (int(v[off + bc] xor uint8(xorv))) - xorv
      accum += (int(v[off + bc + 576] xor uint8(xorv))) - xorv
      inc bc
    return accum.float64 / (bw.float64 * 255.0)
  let o = if ch == 2: off + 576 else: off
  for x in 0 ..< bw:
    accum += (int(v[o + bc] xor uint8(xorv))) - xorv
    inc bc
  accum.float64 / (bw.float64 * 127.5)

proc getspec(band, bandw, chan: float64): float64 =
  getvis(0, toCInt(band * 576.0), toCInt(bandw * 576.0), toCInt(chan + 0.5), 0) * 0.5

proc getosc(band, bandw, chan: float64): float64 =
  getvis(576 * 2, toCInt(band * 576.0), toCInt(bandw * 576.0), toCInt(chan + 0.5), 128)

proc gettime(sc: float64): float64 =
  let ispos = sc > -1.001 and sc < -0.999
  if ispos or (sc > -2.001 and sc < -1.999):
    if ispos: return float64(int(env.posMs)) / 1000.0
    return float64(int(env.lenSec))
  env.tickMs.float64 / 1000.0 - sc

proc getkbmouse(which: float64): float64 =
  let w = toCInt(which + 0.5)
  if w > 5:
    return (if env.keyDown != nil and env.keyDown(w): 1.0 else: 0.0)
  case w
  of 1: env.mouseX
  of 2: env.mouseY
  of 3: float64(env.mouseButtons and 1)
  of 4: float64((env.mouseButtons shr 1) and 1)
  of 5: float64((env.mouseButtons shr 2) and 1)
  else: 0.0

# --- the lexer: NS-EEL's DFA ---------------------------------------------------

const
  Flex: array[37, int8] = [
    1'i8, 18, 17, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 4, 5,
    5, 4, 4, 3, 3, 3, 3, 4, 0, 4, 5, 0, 5, 4, 1, 3, 0, 2, -1, 1, -1]
  Nlex: array[525, uint8] = [
    36'u8, 36, 36, 36, 36, 36, 36, 36, 36, 1, 36, 36, 36, 36, 36, 36,
    36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36,
    1, 36, 36, 36, 36, 9, 8, 36, 6, 5, 11, 13, 3, 12, 19, 10,
    30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 36, 2, 36, 4, 36, 36,
    36, 29, 29, 29, 29, 29, 29, 18, 18, 18, 18, 18, 18, 18, 18, 18,
    18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 36, 36, 36, 36, 18,
    36, 29, 29, 29, 29, 29, 23, 18, 18, 18, 18, 18, 18, 18, 18, 18,
    18, 18, 18, 18, 18, 18, 14, 18, 18, 18, 18, 36, 7, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 36, 36, 36, 36, 36, 36, 36, 17, 17,
    17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17,
    17, 17, 17, 17, 17, 17, 17, 17, 36, 36, 36, 36, 17, 36, 17, 17,
    17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17,
    17, 17, 17, 17, 17, 17, 17, 17, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 36, 36, 36, 36, 36, 36, 36, 16, 16, 16, 16, 16, 16, 16,
    16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16,
    16, 16, 16, 36, 36, 36, 36, 16, 36, 16, 16, 16, 16, 16, 16, 16,
    16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16,
    16, 16, 16, 22, 22, 22, 22, 22, 22, 22, 22, 22, 22, 21, 21, 21,
    21, 21, 21, 21, 21, 21, 21, 36, 20, 26, 26, 26, 26, 26, 26, 26,
    26, 26, 26, 36, 36, 36, 36, 36, 36, 36, 25, 25, 25, 25, 25, 25,
    36, 24, 36, 36, 36, 36, 36, 36, 20, 36, 36, 36, 36, 36, 36, 36,
    36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 25, 25, 25, 25, 25, 25,
    36, 24, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 36, 36, 36, 36,
    36, 36, 36, 28, 28, 28, 28, 28, 28, 36, 27, 36, 36, 36, 36, 36,
    36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36,
    36, 36, 36, 28, 28, 28, 28, 28, 28, 31, 27, 35, 35, 35, 35, 35,
    35, 35, 35, 35, 35, 36, 36, 36, 36, 36, 36, 36, 34, 34, 34, 33,
    34, 34, 36, 32, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36,
    36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 34, 34, 34, 33,
    34, 34, 36, 32, 34, 34, 34, 34, 34, 34, 34, 34, 34, 34, 36, 36,
    36, 36, 36, 36, 36, 34, 34, 34, 34, 34, 34, 36, 32, 36, 36, 36,
    36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36,
    36, 36, 36, 36, 36, 34, 34, 34, 34, 34, 34, 36, 32]
  M = 255'u8  # the check table's -1
  Clex: array[525, uint8] = [
    M, M, M, M, M, M, M, M, M, 0, M, M, M, M, M, M,
    M, M, M, M, M, M, M, M, M, M, M, M, M, M, M, M,
    0, M, M, M, M, 0, 0, M, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, M, 0, M, 0, M, M,
    M, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, M, M, M, M, 0,
    M, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, M, 0, 14, 14, 14,
    14, 14, 14, 14, 14, 14, 14, M, M, M, M, M, M, M, 14, 14,
    14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
    14, 14, 14, 14, 14, 14, 14, 14, M, M, M, M, 14, M, 14, 14,
    14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
    14, 14, 14, 14, 14, 14, 14, 14, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, M, M, M, M, M, M, M, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, M, M, M, M, 15, M, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 20, 20, 20,
    20, 20, 20, 20, 20, 20, 20, M, 19, 23, 23, 23, 23, 23, 23, 23,
    23, 23, 23, M, M, M, M, M, M, M, 23, 23, 23, 23, 23, 23,
    M, 23, M, M, M, M, M, M, 19, M, M, M, M, M, M, M,
    M, M, M, M, M, M, M, M, M, M, 23, 23, 23, 23, 23, 23,
    M, 23, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, M, M, M, M,
    M, M, M, 26, 26, 26, 26, 26, 26, M, 26, M, M, M, M, M,
    M, M, M, M, M, M, M, M, M, M, M, M, M, M, M, M,
    M, M, M, 26, 26, 26, 26, 26, 26, 30, 26, 30, 30, 30, 30, 30,
    30, 30, 30, 30, 30, M, M, M, M, M, M, M, 30, 30, 30, 30,
    30, 30, M, 30, M, M, M, M, M, M, M, M, M, M, M, M,
    M, M, M, M, M, M, M, M, M, M, M, M, 30, 30, 30, 30,
    30, 30, M, 30, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33, M, M,
    M, M, M, M, M, 33, 33, 33, 33, 33, 33, M, 33, M, M, M,
    M, M, M, M, M, M, M, M, M, M, M, M, M, M, M, M,
    M, M, M, M, M, 33, 33, 33, 33, 33, 33, M, 33]
  Dlex: array[36, uint8] = [
    36'u8, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36,
    15, 14, 14, 36, 36, 20, 19, 14, 14, 23, 15, 15, 26, 23, 36, 19,
    36, 36, 33, 30]
  Blex: array[37, int] = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 77, 152,
    0, 0, 0, 227, 237, 0, 0, 249, 0, 0, 306, 0, 0, 0, 363, 0,
    0, 420, 0, 0, 0]
  EndState = 36
  NxtMax = 524
  TokenBuf = 100              ## llbuf: longer tokens are cut

proc move(c, st0: int): int =
  var st = st0
  while true:
    let base = Blex[st] + c
    if base <= NxtMax and int(Clex[base]) == st: return int(Nlex[base])
    if st != EndState: st = int(Dlex[st])
    else: return -1

type
  TokKind = enum tkEnd, tkError, tkValue, tkIdent, tkPunct
  Token = object
    kind: TokKind
    text: string
    action: int
    ch: char

proc scan(s: string, pos: var int): Token =
  ## The next token of s from pos (NS-EEL's yylex).
  while true:
    let start = pos
    var st = 0
    var final = -1
    var finalEnd = start
    var cur = start
    var eof = false
    while true:
      if Flex[st] != -1:
        final = int(Flex[st])
        finalEnd = cur
      var c: int
      if cur - start >= TokenBuf: c = -1
      elif cur >= s.len or ord(s[cur]) >= 128 or s[cur] == '\0':
        c = -1
        eof = true
      else: c = ord(s[cur])
      if c < 0: break
      inc cur
      st = move(c, st)
      if st == -1: break
    let text = s[start ..< finalEnd]
    pos = finalEnd
    if final == 1 and text.len == 0:
      # Nothing matched: the end, or a character the language doesn't have.
      return Token(kind: if eof: tkEnd else: tkError)
    case final
    of 0, 1, 2, 3: return Token(kind: tkValue, text: text, action: final)
    of 4, 5: return Token(kind: tkIdent, text: text)
    of 6..17: return Token(kind: tkPunct, ch: "+-*/%&|()=,;"[final - 6])
    of 18: continue  # white space
    else: return Token(kind: tkError)

proc cAtoi(s: string): int32 =
  ## MSVC atoi: digits after optional space/sign, wrapping.
  var i = 0
  while i < s.len and s[i] in {' ', '\t'}: inc i
  var neg = false
  if i < s.len and s[i] in {'+', '-'}:
    neg = s[i] == '-'
    inc i
  var v: uint32 = 0
  while i < s.len and s[i] in {'0'..'9'}:
    v = v * 10 + uint32(ord(s[i]) - 48)
    inc i
  result = cast[int32](if neg: 0'u32 - v else: v)

proc cAtof(s: string): float64 =
  ## strtod on the longest valid prefix ("1.5e" reads 1.5).
  var t = s
  while t.len > 0:
    try:
      return parseFloat(t)
    except ValueError:
      t.setLen t.len - 1
  0.0

proc hexValue(s: string): float64 =
  var v: int32 = 0
  for c in s:
    let d = case c
      of '0'..'9': ord(c) - 48
      of 'A'..'F': ord(c) - 55
      of 'a'..'f': ord(c) - 87
      else: -1
    if d < 0: break
    v = v +% int32(d)
    v = v shl 4
  v.float64

# --- the parser and code generator ---------------------------------------------

type
  FnKind = enum
    fIf, fLoop, fSin, fCos, fTan, fAsin, fAcos, fAtan, fAtan2, fSqr, fSqrt, fPow,
    fExp, fLog, fLog10, fAbs, fMin, fMax, fSigmoid, fSign, fRand, fBand, fBor,
    fBnot, fEqual, fBelow, fAbove, fFloor, fCeil, fInvsqrt, fAssign, fExec2,
    fExec3, fGetosc, fGetspec, fGettime, fGetkbmouse, fSetmousepos, fMegabuf,
    fGmegabuf

const FnTable: array[FnKind, (string, int)] = [
  ("if", 3), ("loop", 2), ("sin", 1), ("cos", 1), ("tan", 1), ("asin", 1),
  ("acos", 1), ("atan", 1), ("atan2", 2), ("sqr", 1), ("sqrt", 1), ("pow", 2),
  ("exp", 1), ("log", 1), ("log10", 1), ("abs", 1), ("min", 2), ("max", 2),
  ("sigmoid", 2), ("sign", 1), ("rand", 1), ("band", 2), ("bor", 2), ("bnot", 1),
  ("equal", 2), ("below", 2), ("above", 2), ("floor", 1), ("ceil", 1),
  ("invsqrt", 1), ("assign", 2), ("exec2", 2), ("exec3", 3), ("getosc", 3),
  ("getspec", 3), ("gettime", 1), ("getkbmouse", 1), ("setmousepos", 2),
  ("megabuf", 1), ("gmegabuf", 1)]

type
  Parser = object
    s: string
    pos: int
    tok: Token
    vm: EelVm
    code: EelCode
    ops: int                  ## computTableTop
    failed: bool

proc next(p: var Parser) = p.tok = scan(p.s, p.pos)

proc fail(p: var Parser) = p.failed = true

proc isPunct(p: Parser, c: char): bool = p.tok.kind == tkPunct and p.tok.ch == c

proc expect(p: var Parser, c: char) =
  if p.isPunct(c): p.next() else: p.fail()

proc constNode(p: var Parser, v: float64): Node =
  let r = new float64
  r[] = v
  p.code.keep.add r
  result = proc (): ptr float64 = addr r[]

proc varNode(p: ptr float64): Node =
  result = proc (): ptr float64 = p

proc lookupFn(name: string): int =
  for k, f in FnTable:
    if f[0].len == name.len:
      var same = true
      for i in 0 ..< name.len:
        let c = if name[i] in {'A'..'Z'}: chr(ord(name[i]) + 32) else: name[i]
        if c != f[0][i]:
          same = false
          break
      if same: return ord(k)
  -1

proc binOp(op: char, a, b: Node): Node =
  case op
  of '+': (proc (): ptr float64 =
    let x = a(); let y = b(); let r = slot(); r[] = y[] + x[]; r)
  of '-': (proc (): ptr float64 =
    let x = a(); let y = b(); let r = slot(); r[] = x[] - y[]; r)
  of '*': (proc (): ptr float64 =
    let x = a(); let y = b(); let r = slot(); r[] = x[] * y[]; r)
  of '/': (proc (): ptr float64 =
    let x = a(); let y = b(); let r = slot(); r[] = x[] / y[]; r)
  of '%': (proc (): ptr float64 =
    let x = a(); let y = b()
    let r = slot()
    let d = cast[uint32](fistp32((abs(y[] - 1.0) + y[] + 1.0) * 0.5))
    let n = cast[uint32](fistp32(x[]))
    r[] = float64(cast[int32](n mod d))
    r)
  of '&': (proc (): ptr float64 =
    let x = a(); let y = b(); let r = slot()
    r[] = float64(fistp64(y[]) and fistp64(x[])); r)
  else: (proc (): ptr float64 =
    let x = a(); let y = b(); let r = slot()
    r[] = float64(fistp64(y[]) or fistp64(x[])); r)

template fn1(a: Node, body: untyped): Node =
  (proc (): ptr float64 =
    let pa {.inject.} = a()
    let r = slot()
    let x {.inject.} = pa[]
    r[] = body
    r)

template fn2(a, b: Node, body: untyped): Node =
  (proc (): ptr float64 =
    let pa {.inject.} = a()
    let pb {.inject.} = b()
    let r = slot()
    let x {.inject.} = pa[]
    let y {.inject.} = pb[]
    r[] = body
    r)

proc callNode(p: var Parser, k: FnKind, args: seq[Node]): Node =
  let vm = p.vm
  case k
  of fIf:
    let (c, t, e) = (args[0], args[1], args[2])
    result = proc (): ptr float64 =
      if truthy(c()[]): t() else: e()
  of fLoop:
    let (n, body) = (args[0], args[1])
    result = proc (): ptr float64 =
      result = n()
      var cnt = fistp32(result[])
      if cnt < 1: return
      if cnt > LoopMax: cnt = LoopMax
      for i in 0 ..< cnt:
        let save = esi
        result = body()
        esi = save
  of fSin: result = fn1(args[0], x87sin(x))
  of fCos: result = fn1(args[0], x87cos(x))
  of fTan: result = fn1(args[0], x87tan(x))
  of fAsin: result = fn1(args[0], arcsin(x))
  of fAcos: result = fn1(args[0], arccos(x))
  of fAtan: result = fn1(args[0], arctan(x))
  of fAtan2: result = fn2(args[0], args[1], arctan2(x, y))
  of fSqr: result = fn1(args[0], x * x)
  of fSqrt: result = fn1(args[0], sqrt(abs(x)))
  of fPow: result = fn2(args[0], args[1], pow(x, y))
  of fExp: result = fn1(args[0], exp(x))
  of fLog: result = fn1(args[0], ln(x))
  of fLog10: result = fn1(args[0], log10(x))
  of fAbs: result = fn1(args[0], abs(x))
  of fMin: result = fn2(args[0], args[1], ((x - abs(y - x)) + y) * 0.5)
  of fMax: result = fn2(args[0], args[1], ((x + abs(y - x)) + y) * 0.5)
  of fSigmoid:
    result = fn2(args[0], args[1]):
      (let t = 1.0 + exp(-x * y); if nonzero(t): 1.0 / t else: 0.0)
  of fSign:
    let a = args[0]
    result = proc (): ptr float64 =
      let pa = a()
      let bits = cast[uint64](pa[])
      if (bits and 0x7fffffffffffffff'u64) == 0: return pa
      let r = slot()
      r[] = if (bits shr 63) != 0: -1.0 else: 1.0
      r
  of fRand:
    let a = args[0]
    result = proc (): ptr float64 =
      let pa = a()
      let r = slot()
      if pa[] < 1.0: pa[] = 1.0
      let m = toCInt(if pa[] > 1.0: pa[] else: 1.0)  # MSVC's max macro
      r[] = float64(if m == low(int32): crand() else: crand() mod m)
      r
  of fBand: result = fn2(args[0], args[1], (if nonzero(x) and nonzero(y): 1.0 else: 0.0))
  of fBor: result = fn2(args[0], args[1], (if nonzero(x) or nonzero(y): 1.0 else: 0.0))
  of fBnot: result = fn1(args[0], (if lt(abs(x), CloseFact): 1.0 else: 0.0))
  of fEqual: result = fn2(args[0], args[1], (if lt(abs(y - x), CloseFact): 1.0 else: 0.0))
  of fBelow: result = fn2(args[0], args[1], (if lt(x, y): 1.0 else: 0.0))
  of fAbove: result = fn2(args[0], args[1], (if lt(y, x): 1.0 else: 0.0))
  of fFloor: result = fn1(args[0], floor(x))
  of fCeil: result = fn1(args[0], ceil(x))
  of fInvsqrt: result = fn1(args[0], invsqrt(x))
  of fAssign:
    let (d, s) = (args[0], args[1])
    result = proc (): ptr float64 =
      let pd = d()
      let ps = s()
      pd[] = ps[]
      ps
  of fExec2:
    let (a, b) = (args[0], args[1])
    result = proc (): ptr float64 =
      discard a()
      b()
  of fExec3:
    let (a, b, c) = (args[0], args[1], args[2])
    result = proc (): ptr float64 =
      discard a()
      discard b()
      c()
  of fGetosc:
    result = proc (): ptr float64 =
      let x = args[0](); let y = args[1](); let z = args[2]()
      let r = slot(); r[] = getosc(x[], y[], z[]); r
  of fGetspec:
    result = proc (): ptr float64 =
      let x = args[0](); let y = args[1](); let z = args[2]()
      let r = slot(); r[] = getspec(x[], y[], z[]); r
  of fGettime: result = fn1(args[0], gettime(x))
  of fGetkbmouse: result = fn1(args[0], getkbmouse(x))
  of fSetmousepos: result = fn2(args[0], args[1], 0.0)
  of fMegabuf:
    let a = args[0]
    result = proc (): ptr float64 = megabufAt(vm.megabuf, a()[])
  of fGmegabuf:
    let a = args[0]
    result = proc (): ptr float64 = megabufAt(gmegabuf, a()[])

proc expr(p: var Parser, minPrec: int): Node

proc identNode(p: var Parser, name: string): Node =
  ## A name the lexer found: a register, a known variable, else a new one.
  let r = isReg(name)
  if r >= 0: return varNode(addr globalRegs[r])
  let v = p.vm.findVar(name)
  if v != nil: return varNode(v)
  varNode(p.vm.addVar(name))

proc classify(p: Parser, name: string): int =
  ## -1: a variable, else the function (variables are looked up first).
  if isReg(name) >= 0 or p.vm.findVar(name) != nil: return -1
  lookupFn(name)

proc primary(p: var Parser): Node =
  if p.failed: return nil
  case p.tok.kind
  of tkValue:
    let v = case p.tok.action
      of 0: hexValue(p.tok.text)
      of 3: cAtof(p.tok.text)
      else: cAtoi(p.tok.text).float64
    p.next()
    return p.constNode(v)
  of tkIdent:
    let name = p.tok.text
    let f = p.classify(name)
    p.next()
    if f < 0: return p.identNode(name)
    let k = FnKind(f)
    p.expect('(')
    var args: seq[Node]
    for i in 0 ..< FnTable[k][1]:
      if i > 0: p.expect(',')
      args.add p.expr(0)
      if p.failed: return nil
    p.expect(')')
    if p.failed: return nil
    inc p.ops
    return p.callNode(k, args)
  of tkPunct:
    case p.tok.ch
    of '(':
      p.next()
      result = p.expr(0)
      p.expect(')')
    of '-':
      p.next()
      let a = p.primary()
      if p.failed: return nil
      inc p.ops
      result = proc (): ptr float64 =
        let pa = a()
        let r = slot()
        r[] = cast[float64](cast[uint64](pa[]) xor 0x8000000000000000'u64)
        r
    of '+':
      p.next()
      result = p.primary()
      inc p.ops
    else: p.fail()
  else: p.fail()

proc prec(p: Parser): int =
  if p.tok.kind != tkPunct: return -1
  case p.tok.ch
  of '|': 1
  of '&': 2
  of '+', '-': 3
  of '*', '/', '%': 4
  else: -1

proc expr(p: var Parser, minPrec: int): Node =
  result = p.primary()
  while not p.failed:
    let pr = p.prec()
    if pr < 0 or pr < minPrec: break
    let op = p.tok.ch
    p.next()
    let rhs = p.expr(pr + 1)
    if p.failed: return nil
    inc p.ops
    result = binOp(op, result, rhs)

proc statement(p: var Parser): Node =
  p.next()
  if p.tok.kind == tkIdent and p.classify(p.tok.text) < 0:
    # Look past the name for '=': an assignment starts the statement.
    let save = (p.pos, p.tok)
    let name = p.tok.text
    p.next()
    if p.isPunct('='):
      p.next()
      let target = p.identNode(name)
      let value = p.expr(0)
      if p.failed: return nil
      inc p.ops
      result = proc (): ptr float64 =
        let d = target()
        let s = value()
        d[] = s[]
        s
    else:
      (p.pos, p.tok) = save
      result = p.expr(0)
  else:
    result = p.expr(0)
  if not p.failed and p.tok.kind != tkEnd: p.fail()

proc preprocess(s: string): string =
  ## NS-EEL's preprocessCode: comments out, $PI/$E/$PHI in, line breaks to spaces.
  var i = 0
  template at(k: int): char = (if i + k < s.len: s[i + k] else: '\0')
  while i < s.len and s[i] != '\0':
    if s[i] == '/':
      if at(1) == '/':
        i += 2
        while i < s.len and s[i] notin {'\0', '\r', '\n'}: inc i
      elif at(1) == '*':
        i += 2
        while i < s.len and s[i] != '\0' and (s[i] != '*' or at(1) != '/'): inc i
        if i < s.len and s[i] != '\0': i += 2
      else:
        result.add s[i]
        inc i
    elif s[i] == '$':
      if at(1) in {'p', 'P'} and at(2) in {'i', 'I'}:
        i += 3
        result.add "3.141592653589793"
      elif at(1) in {'e', 'E'}:
        i += 2
        result.add "2.71828183"
      if at(1) in {'p', 'P'} and at(2) in {'h', 'H'} and at(3) in {'i', 'I'}:
        i += 4
        result.add "1.61803399"
      else:
        if i >= s.len or s[i] == '\0': break  # copied the end: the string ends
        result.add s[i]
        inc i
    else:
      let c = s[i]
      result.add(if c in {'\r', '\n', '\t'}: ' ' else: c)
      inc i

proc compile*(vm: EelVm, src: string): EelCode =
  ## NSEEL_code_compile: nil when there's nothing to run or a statement fails.
  if src.len == 0: return nil
  let text = preprocess(src)
  let code = EelCode()
  var i = 0
  while i < text.len:
    while i < text.len and text[i] in {';', ' '}: inc i
    if i >= text.len: break
    let start = i
    while i < text.len and text[i] != ';': inc i
    var p = Parser(s: text[start ..< i], vm: vm, code: code)
    if i < text.len: inc i
    let n = p.statement()
    if p.failed or n == nil or p.ops > TempSpace - 16 - 4:
      lastError = p.s
      return nil
    code.stmts.add n
  if code.stmts.len == 0: return nil
  code

proc run*(code: EelCode) =
  ## NSEEL_code_execute.
  if code == nil: return
  for s in code.stmts:
    esi = 0
    discard s()
