## System fonts the UI borrows glyphs from when IBM Plex has none (kana,
## kanji, hanzi, hangul, other scripts): see glyphcache. Linux asks
## fontconfig (loaded at run time, like fontlist); Windows tries the fonts
## every install ships in %WINDIR%\Fonts.
##
## Han characters look different per region (Japanese, Simplified and
## Traditional Chinese, Korean forms), so the candidates are ranked by a
## language: the font families made for it come first.

import std/[os, unicode]
when not defined(windows): import std/[algorithm, strutils]

type
  FontFace* = object
    path*: string
    index*: int       ## the face in a .ttc/.otc collection

const
  ## Families with the region's own Han forms, best first (Linux and Windows names).
  PreferredFamilies = [
    ("ja", @["Noto Sans CJK JP", "Source Han Sans JP", "Source Han Sans", "Noto Sans JP",
             "IPAexGothic", "IPAGothic", "VL Gothic", "TakaoGothic", "Yu Gothic", "Meiryo",
             "MS Gothic"]),
    ("zh-cn", @["Noto Sans CJK SC", "Source Han Sans SC", "Source Han Sans CN", "Noto Sans SC",
                "WenQuanYi Micro Hei", "WenQuanYi Zen Hei", "Microsoft YaHei", "SimHei",
                "Droid Sans Fallback"]),
    ("zh-tw", @["Noto Sans CJK TC", "Source Han Sans TC", "Source Han Sans TW", "Noto Sans TC",
                "Microsoft JhengHei", "Noto Sans CJK HK", "WenQuanYi Micro Hei"]),
    ("zh-hk", @["Noto Sans CJK HK", "Source Han Sans HK", "Noto Sans HK", "Noto Sans CJK TC",
                "Source Han Sans TC", "Microsoft JhengHei"]),
    ("ko", @["Noto Sans CJK KR", "Source Han Sans KR", "Source Han Sans K", "Noto Sans KR",
             "NanumGothic", "Malgun Gothic", "Gulim"])]

proc preferred(lang: string): seq[string] =
  for (l, families) in PreferredFamilies:
    if l == lang: return families

proc isKana*(r: Rune): bool =
  let c = r.int
  c in 0x3040 .. 0x30FF or c in 0x31F0 .. 0x31FF or c in 0xFF66 .. 0xFF9F

proc isHangul*(r: Rune): bool =
  let c = r.int
  c in 0x1100 .. 0x11FF or c in 0x3130 .. 0x318F or c in 0xAC00 .. 0xD7AF

proc isCjk*(r: Rune): bool =
  ## Han ideographs and the CJK punctuation, symbols and full-width forms
  ## shared by the CJK languages, whose looks depend on the language.
  let c = r.int
  c in 0x2E80 .. 0x2FFF or c in 0x3000 .. 0x303F or c in 0x3190 .. 0x31EF or
    c in 0x3200 .. 0x33FF or c in 0x3400 .. 0x4DBF or c in 0x4E00 .. 0x9FFF or
    c in 0xF900 .. 0xFAFF or c in 0xFE30 .. 0xFE4F or c in 0xFF00 .. 0xFF65 or
    c in 0xFFE0 .. 0xFFEF or c in 0x20000 .. 0x3FFFF

when defined(windows):
  proc GetUserDefaultUILanguage(): uint16 {.stdcall, dynlib: "kernel32", importc.}

proc localeCjkLang*(): string =
  ## The CJK language of the user's locale, "" when it's none of them.
  when defined(windows):
    case GetUserDefaultUILanguage().int
    of 0x0411: "ja"
    of 0x0412: "ko"
    of 0x0404: "zh-tw"
    of 0x0C04, 0x1404: "zh-hk"
    of 0x0804, 0x1004: "zh-cn"
    else: ""
  else:
    var loc = ""
    for v in ["LC_ALL", "LC_CTYPE", "LANG"]:
      loc = getEnv(v)
      if loc.len > 0: break
    loc = loc.toLowerAscii.replace('-', '_')
    if loc.startsWith("ja"): "ja"
    elif loc.startsWith("ko"): "ko"
    elif loc.startsWith("zh_tw"): "zh-tw"
    elif loc.startsWith("zh_hk") or loc.startsWith("zh_mo"): "zh-hk"
    elif loc.startsWith("zh"): "zh-cn"
    else: ""

when defined(windows):
  const
    LangFiles = [
      ("ja", @["YuGothR.ttc", "meiryo.ttc", "msgothic.ttc"]),
      ("zh-cn", @["msyh.ttc", "simhei.ttf", "simsun.ttc"]),
      ("zh-tw", @["msjh.ttc", "mingliu.ttc"]),
      ("zh-hk", @["msjh.ttc", "mingliu.ttc"]),
      ("ko", @["malgun.ttf", "gulim.ttc"])]
    OtherFiles = ["segoeui.ttf", "seguisym.ttf", "arial.ttf", "Nirmala.ttc", "Nirmala.ttf",
                  "LeelawUI.ttf", "ebrima.ttf", "gadugi.ttf", "himalaya.ttf", "javatext.ttf",
                  "mmrtext.ttf", "monbaiti.ttf", "msyi.ttf", "phagspa.ttf", "taile.ttf",
                  "seguiemj.ttf", "tahoma.ttf"]

  proc candidates*(r: Rune, lang: string, mono = false, emoji = false): seq[FontFace] =
    ## Fonts that may draw r, best first; the caller checks each has it.
    ## emoji: the color emoji font first.
    let dir = getEnv("WINDIR", "C:\\Windows") / "Fonts"
    var names: seq[string]
    if emoji: names.add "seguiemj.ttf"
    for (l, files) in LangFiles:
      if l == lang: names.add files
    for name in OtherFiles:
      if name notin names: names.add name
    for (l, files) in LangFiles:
      if l != lang:
        for f in files:
          if f notin names: names.add f
    for name in names:
      let p = dir / name
      if fileExists(p): result.add FontFace(path: p, index: 0)

else:
  import std/dynlib
  import dylibs

  type
    FcFontSet = object
      nfont, sfont: cint
      fonts: ptr UncheckedArray[pointer]

    Fc = object
      ok: bool
      patternCreate: proc (): pointer {.cdecl.}
      patternDestroy: proc (p: pointer) {.cdecl.}
      patternAddCharSet: proc (p: pointer, obj: cstring, cs: pointer): cint {.cdecl.}
      charSetCreate: proc (): pointer {.cdecl.}
      charSetAddChar: proc (cs: pointer, c: uint32): cint {.cdecl.}
      charSetDestroy: proc (cs: pointer) {.cdecl.}
      objectSetCreate: proc (): pointer {.cdecl.}
      objectSetAdd: proc (os: pointer, name: cstring): cint {.cdecl.}
      objectSetDestroy: proc (os: pointer) {.cdecl.}
      fontList: proc (config, p, os: pointer): ptr FcFontSet {.cdecl.}
      fontSetDestroy: proc (fs: ptr FcFontSet) {.cdecl.}
      getString: proc (p: pointer, obj: cstring, n: cint, s: ptr cstring): cint {.cdecl.}
      getInteger: proc (p: pointer, obj: cstring, n: cint, i: ptr cint): cint {.cdecl.}

  var fc: Fc
  var fcTried = false

  proc loadFc(): bool =
    if fcTried: return fc.ok
    fcTried = true
    var lib: LibHandle
    for n in libNames(when defined(macosx): ["libfontconfig.1.dylib", "libfontconfig.dylib"]
                      else: ["libfontconfig.so.1", "libfontconfig.so"]):
      lib = loadLib(n)
      if lib != nil: break
    if lib == nil: return false
    template sym(field, name: untyped) =
      fc.field = cast[typeof(fc.field)](lib.symAddr(name))
      if fc.field.isNil: return false
    let fcInit = cast[proc (): cint {.cdecl.}](lib.symAddr("FcInit"))
    if fcInit.isNil or fcInit() == 0: return false
    sym(patternCreate, "FcPatternCreate")
    sym(patternDestroy, "FcPatternDestroy")
    sym(patternAddCharSet, "FcPatternAddCharSet")
    sym(charSetCreate, "FcCharSetCreate")
    sym(charSetAddChar, "FcCharSetAddChar")
    sym(charSetDestroy, "FcCharSetDestroy")
    sym(objectSetCreate, "FcObjectSetCreate")
    sym(objectSetAdd, "FcObjectSetAdd")
    sym(objectSetDestroy, "FcObjectSetDestroy")
    sym(fontList, "FcFontList")
    sym(fontSetDestroy, "FcFontSetDestroy")
    sym(getString, "FcPatternGetString")
    sym(getInteger, "FcPatternGetInteger")
    fc.ok = true  # the library stays loaded: it's asked again for each new script
    true

  proc candidates*(r: Rune, lang: string, mono = false, emoji = false): seq[FontFace] =
    ## Installed fonts that have r, best first: the language's own
    ## families, then regular upright sans faces (mono ones when mono).
    ## emoji: emoji families first, else last.
    if not loadFc(): return
    let pat = fc.patternCreate()
    let cs = fc.charSetCreate()
    discard fc.charSetAddChar(cs, r.uint32)
    discard fc.patternAddCharSet(pat, "charset", cs)
    fc.charSetDestroy(cs)
    let os = fc.objectSetCreate()
    for o in ["family", "file", "index", "weight", "slant", "spacing", "fontformat"]:
      discard fc.objectSetAdd(os, o.cstring)
    let fs = fc.fontList(nil, pat, os)
    let prefs = preferred(lang)
    var ranked: seq[tuple[score: seq[int], family: string, face: FontFace]]
    if fs != nil:
      for i in 0 ..< fs.nfont:
        let p = fs.fonts[i]
        var file, family, format: cstring
        var index, weight, slant, spacing: cint
        if fc.getString(p, "file", 0, file.addr) != 0 or file == nil: continue
        let path = $file
        if path.splitFile.ext.toLowerAscii notin [".ttf", ".otf", ".ttc", ".otc"]: continue
        if fc.getString(p, "fontformat", 0, format.addr) == 0 and format != nil and
           $format notin ["TrueType", "CFF"]: continue
        discard fc.getInteger(p, "index", 0, index.addr)
        if (index shr 16) != 0: continue  # a variable font's named instance
        if fc.getString(p, "family", 0, family.addr) != 0 or family == nil: family = ""
        if fc.getInteger(p, "weight", 0, weight.addr) != 0: weight = 80
        if fc.getInteger(p, "slant", 0, slant.addr) != 0: slant = 0
        if fc.getInteger(p, "spacing", 0, spacing.addr) != 0: spacing = 0
        let name = $family
        var pref = prefs.len
        for j, f in prefs:
          if cmpIgnoreCase(f, name) == 0: pref = j; break
        let lower = name.toLowerAscii
        let serif = int("serif" in lower or "mincho" in lower or "ming" in lower or
                        "song" in lower or "batang" in lower)
        let isMono = spacing >= 100 or "mono" in lower
        let emojiRank = int(("emoji" in lower) != emoji)
        let score =
          if emoji: @[emojiRank, pref, serif, int(slant != 0), abs(weight.int - 80)]
          else: @[pref, int(isMono != mono), serif, int(slant != 0), abs(weight.int - 80),
                  emojiRank]
        ranked.add (score, name, FontFace(path: path, index: index.int and 0xFFFF))
      fc.fontSetDestroy(fs)
    fc.objectSetDestroy(os)
    fc.patternDestroy(pat)
    ranked.sort(proc (a, b: typeof(ranked[0])): int =
      for i in 0 ..< a.score.len:
        result = cmp(a.score[i], b.score[i])
        if result != 0: return
      result = cmp(a.family, b.family)
      if result == 0: result = cmp(a.face.path, b.face.path))
    for c in ranked: result.add c.face
