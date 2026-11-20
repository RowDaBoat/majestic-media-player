## The font families installed on the system (Options > Subtitles > Default's
## Font list). Linux asks fontconfig, loaded at run time like libass finds it;
## Windows asks GDI. Both are what mpv's libass picks fonts from.

import std/[algorithm, sets, strutils]

when defined(windows):
  import win32api

  type
    LogFontW = object
      lfHeight, lfWidth, lfEscapement, lfOrientation, lfWeight: int32
      lfItalic, lfUnderline, lfStrikeOut, lfCharSet, lfOutPrecision,
        lfClipPrecision, lfQuality, lfPitchAndFamily: uint8
      lfFaceName: array[32, uint16]
    FontEnumProc = proc (lf: ptr LogFontW, tm: pointer, kind: DWORD, data: LPARAM): int32 {.stdcall.}

  const DefaultCharset = 1'u8

  proc EnumFontFamiliesExW(hdc: HDC, lf: ptr LogFontW, cb: FontEnumProc, data: LPARAM,
                           flags: DWORD): int32 {.stdcall, dynlib: "gdi32", importc.}

  proc addFamily(lf: ptr LogFontW, tm: pointer, kind: DWORD, data: LPARAM): int32 {.stdcall.} =
    let name = $cast[WideCString](lf.lfFaceName[0].addr)
    if name.len > 0 and name[0] != '@':  # '@': the vertical-writing twin
      cast[ptr seq[string]](data)[].add name
    1

  proc familyNames(): seq[string] =
    let dc = GetDC(0)
    if dc == 0: return
    var lf = LogFontW(lfCharSet: DefaultCharset)
    discard EnumFontFamiliesExW(dc, lf.addr, addFamily, cast[LPARAM](result.addr), 0)
    discard ReleaseDC(0, dc)

else:
  import std/dynlib
  import dylibs

  type
    FcFontSet = object
      nfont, sfont: cint
      fonts: ptr UncheckedArray[pointer]

  proc familyNames(): seq[string] =
    var lib: LibHandle
    for n in libNames(when defined(macosx): ["libfontconfig.1.dylib", "libfontconfig.dylib"]
                      else: ["libfontconfig.so.1", "libfontconfig.so"]):
      lib = loadLib(n)
      if lib != nil: break
    if lib == nil: return
    defer: unloadLib(lib)
    let
      fcInit = cast[proc (): cint {.cdecl.}](lib.symAddr("FcInit"))
      patternCreate = cast[proc (): pointer {.cdecl.}](lib.symAddr("FcPatternCreate"))
      patternDestroy = cast[proc (p: pointer) {.cdecl.}](lib.symAddr("FcPatternDestroy"))
      objectSetCreate = cast[proc (): pointer {.cdecl.}](lib.symAddr("FcObjectSetCreate"))
      objectSetAdd = cast[proc (os: pointer, name: cstring): cint {.cdecl.}](lib.symAddr("FcObjectSetAdd"))
      objectSetDestroy = cast[proc (os: pointer) {.cdecl.}](lib.symAddr("FcObjectSetDestroy"))
      fontList = cast[proc (config, p, os: pointer): ptr FcFontSet {.cdecl.}](lib.symAddr("FcFontList"))
      fontSetDestroy = cast[proc (fs: ptr FcFontSet) {.cdecl.}](lib.symAddr("FcFontSetDestroy"))
      getString = cast[proc (p: pointer, obj: cstring, n: cint, s: ptr cstring): cint {.cdecl.}](
        lib.symAddr("FcPatternGetString"))
    if fcInit.isNil or patternCreate.isNil or patternDestroy.isNil or objectSetCreate.isNil or
       objectSetAdd.isNil or objectSetDestroy.isNil or fontList.isNil or fontSetDestroy.isNil or
       getString.isNil or fcInit() == 0:
      return
    let pat = patternCreate()
    let os = objectSetCreate()
    discard objectSetAdd(os, "family")
    let fs = fontList(nil, pat, os)
    if fs != nil:
      for i in 0 ..< fs.nfont:
        var s: cstring
        # The first family name; later ones are the same family in other languages.
        if getString(fs.fonts[i], "family", 0, s.addr) == 0 and s != nil:
          result.add $s
      fontSetDestroy(fs)
    objectSetDestroy(os)
    patternDestroy(pat)

proc systemFonts*(): seq[string] =
  ## Installed font families, sorted case-insensitively, each once.
  var seen: HashSet[string]
  for name in familyNames():
    let n = name.strip
    if n.len > 0 and not seen.containsOrIncl(n.toLowerAscii): result.add n
  result.sort(proc (a, b: string): int = cmpIgnoreCase(a, b))
