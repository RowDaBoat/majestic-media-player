## Options > System > Rendering: video memory left on the GPU, and the
## software renderer (Mesa's llvmpipe) taking the GPU's place when it has
## too little. The GL driver is picked once, as the window opens, so going
## from one to the other is a restart (relaunch).

import std/[os, dynlib, strutils]
import config

const
  # A video takes up 550-750 MiB, and pausing one ~200 more (the standby).
  StartVram* = 1024'i64 shl 20  ## free at start for the GPU (Prefer GPU, Adaptive)
  ReturnVram* = 1536'i64 shl 20 ## free for a while to go back to the GPU from the CPU
  LowVram* = 256'i64 shl 20    ## Adaptive: free under this for a while, to the CPU
  RenderArg* = "--render="      ## a restart's renderer: "--render=cpu" / "--render=gpu"
  SoftwareMark = "MMP_SOFTWARE_GL"  ## set along with useSoftwareGl's settings

type
  NvmlMemory = object
    total, free, used: culonglong

  NvmlInit = proc (): cint {.cdecl, gcsafe.}
  NvmlHandle = proc (index: cuint, dev: ptr pointer): cint {.cdecl, gcsafe.}
  NvmlMemInfo = proc (dev: pointer, mem: ptr NvmlMemory): cint {.cdecl, gcsafe.}

var
  nvmlTried: bool
  nvmlDev: pointer
  nvmlMem: NvmlMemInfo
  amdCard: string               ## /sys/class/drm/cardN/device of a discrete AMD GPU
  amdTried: bool

proc openNvml(): bool =
  ## NVIDIA's management library (ships with the driver): asks the GPU
  ## itself, so it works whatever renders (the software renderer too).
  if nvmlTried: return nvmlDev != nil
  nvmlTried = true
  let names = when defined(windows):
                @["nvml.dll", getEnv("ProgramFiles") / "NVIDIA Corporation" / "NVSMI" / "nvml.dll"]
              else: @["libnvidia-ml.so.1", "libnvidia-ml.so"]
  for name in names:
    let lib = loadLib(name)
    if lib == nil: continue
    let init = cast[NvmlInit](lib.symAddr("nvmlInit_v2"))
    let handle = cast[NvmlHandle](lib.symAddr("nvmlDeviceGetHandleByIndex_v2"))
    nvmlMem = cast[NvmlMemInfo](lib.symAddr("nvmlDeviceGetMemoryInfo"))
    var dev: pointer
    if init != nil and handle != nil and nvmlMem != nil and init() == 0 and
       handle(0, dev.addr) == 0:
      nvmlDev = dev
      return true
    unloadLib(lib)
  false

proc readInt(path: string): int64 =
  try: parseBiggestInt(readFile(path).strip) except CatchableError: -1

proc openAmd(): bool =
  ## amdgpu's counters; an integrated GPU (a small carve-out) doesn't count.
  when defined(linux):
    if not amdTried:
      amdTried = true
      var best = 0'i64
      for dir in walkDirs("/sys/class/drm/card*"):
        let dev = dir / "device"
        let total = readInt(dev / "mem_info_vram_total")
        if total >= 2'i64 shl 30 and total > best and fileExists(dev / "mem_info_vram_used"):
          best = total
          amdCard = dev
  amdCard.len > 0

proc freeVram*(): int64 =
  ## Video memory left on the GPU, bytes; -1 when there's no telling.
  # Tests: MMP_FREE_VRAM names a file holding the MB left, read each time.
  if existsEnv("MMP_FREE_VRAM"):
    return readInt(getEnv("MMP_FREE_VRAM")) shl 20
  if openNvml():
    var m: NvmlMemory
    if nvmlMem(nvmlDev, m.addr) == 0: return m.free.int64
  elif openAmd():
    let total = readInt(amdCard / "mem_info_vram_total")
    let used = readInt(amdCard / "mem_info_vram_used")
    if total > 0 and used >= 0: return total - used
  -1

proc outOfMemory*(text: string): bool =
  ## An mpv error line telling of the GPU out of memory (CUDA, Vulkan, GL).
  let t = text.toLowerAscii
  "out_of_memory" in t or "out of memory" in t or "out_of_device_memory" in t

proc useSoftwareGl(): bool =
  ## Has the window's GL be Mesa's software renderer; must run before the
  ## window opens. False when there's none to use.
  putEnv(SoftwareMark, "1")
  putEnv("GALLIUM_DRIVER", "llvmpipe")  # not Mesa's d3d12 (on the GPU)
  when defined(windows):
    # Mesa's opengl32.dll, kept apart (tools/windows.sh): loaded first, it's
    # the one every later LoadLibrary("opengl32.dll") gets. Its
    # libgallium_wgl.dll comes from its own folder.
    proc LoadLibraryExW(name: WideCString, file: pointer, flags: uint32): pointer {.
      stdcall, importc, dynlib: "kernel32".}
    const LoadWithAlteredSearchPath = 0x8'u32
    let dll = getAppDir() / "cpu" / "opengl32.dll"
    fileExists(dll) and LoadLibraryExW(newWideCString(dll), nil, LoadWithAlteredSearchPath) != nil
  else:
    # libglvnd picks the vendor by these when GLX first meets the display.
    putEnv("__GLX_VENDOR_LIBRARY_NAME", "mesa")
    putEnv("LIBGL_ALWAYS_SOFTWARE", "1")
    true

proc useGpuGl() =
  ## Undoes useSoftwareGl's settings, which a restart onto the GPU inherits.
  if existsEnv(SoftwareMark):
    for v in [SoftwareMark, "GALLIUM_DRIVER", "__GLX_VENDOR_LIBRARY_NAME", "LIBGL_ALWAYS_SOFTWARE"]:
      delEnv(v)

proc restartedOnto*(): string =
  ## What a restart (watchVram) went over to: "cpu", "gpu"; "" when none did.
  for p in commandLineParams():
    if p.startsWith(RenderArg): result = p[RenderArg.len .. ^1]

proc pickCpu(mode: RenderMode): bool =
  ## Whether this run renders on the CPU: a restart says which; else
  ## Options > System > Rendering, and the GPU's memory left.
  if mode == rdCpu: return true
  case restartedOnto()
  of "cpu": true
  of "gpu": false
  else:
    let free = freeVram()
    free >= 0 and free < StartVram

# Chosen as the program starts, before anything loads a GL library (on
# Windows, the opengl package loads opengl32.dll as its module starts:
# majestic.nim imports this module first).
let
  startMode = loadConfig().renderMode
  cpuWanted* = pickCpu(startMode)
    ## rendering and decoding on the CPU, as chosen at start
  softwareGl* = if cpuWanted: useSoftwareGl() else: (useGpuGl(); false)
    ## the window's GL is the software renderer (else the GPU's, even when
    ## cpuWanted: on Windows without Mesa's DLLs, decoding alone moves)
  startedLow* = cpuWanted and startMode != rdCpu
    ## on the CPU for want of video memory, for now

proc stripRenderArgs*(params: seq[string]): seq[string] =
  for p in params:
    if not p.startsWith(RenderArg): result.add p
