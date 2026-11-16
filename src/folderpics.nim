## Options' folder pictures: which picture beside an audio file is its cover.
## Each line is a pattern, tried top to bottom until one finds a picture,
## written as foobar2000's album art search patterns are:
##
##   art/*front*.*            subfolders, * and ? wildcards (letter case aside)
##   ../folder.*              a folder up (CD1/, CD2/ under the album's)
##   %album%.*                the file's tags and %filename%, %directoryname%...
##   jk_$substr(%filename%,1,4)_5_b.png   functions: $substr, $left, $lower...
##   [%album% - ]cover.*      [...] left out when its fields are missing
##   folder                   no extension: any picture's (Majestic's old names)
##
## A line naming a field the file doesn't have (outside [...]) is skipped.
## A field's own *, ? and / are taken literally: only the line's are wildcards.
##
## formatTitle writes text to show with the same language (the playlist's
## group headers).

import std/[os, strutils, tables, unicode, algorithm]
from config import ImageExtensions

type
  PChar = tuple[c: char, wild: bool]   ## a pattern byte: wild for the line's * and ?
  Value = object
    text: seq[PChar]
    truth: bool       ## for [...] and $if: a field in it was found
    missing: bool     ## a field it needs wasn't found
  Parser = object
    s: string
    i: int
    field: proc (name: string): tuple[value: string, found: bool]
    display: bool     ## text to show (formatTitle): a missing field is "?",
                      ## slashes kept

proc lit(s: string): seq[PChar] =
  for c in s: result.add (c, false)

proc plain(v: Value): string =
  for p in v.text: result.add p.c

proc runeSlice(s: string, first, last: int): string =
  ## Characters first to last, from 1, both included (foobar's $substr).
  let r = s.toRunes
  let a = max(first, 1) - 1
  let b = min(last, r.len) - 1
  if b < a: "" else: $r[a .. b]

proc toInt(s: string): int =
  try: parseInt(s.strip) except ValueError: 0

proc parseSeq(p: var Parser, stop: set[char]): Value

proc parseField(p: var Parser): Value =
  ## At the % opening it.
  inc p.i
  let start = p.i
  while p.i < p.s.len and p.s[p.i] != '%': inc p.i
  let name = p.s[start ..< p.i]
  if p.i < p.s.len: inc p.i
  let (v, found) = p.field(name)
  if p.display:
    return Value(text: lit(if found: v else: "?"), truth: found, missing: not found)
  # A value's slashes would reach into folders: a file name can't hold one.
  Value(text: lit(v.multiReplace(("/", "_"), ("\\", "_"))), truth: found, missing: not found)

proc call(name: string, args: seq[Value]): Value =
  template arg(n: int): string = (if n < args.len: args[n].plain else: "")
  var missing = false
  for a in args: missing = missing or a.missing
  let truth = args.len > 0 and args[0].truth
  case name.toLowerAscii
  of "if":
    # $if(cond, then[, else]): the condition's missing fields don't count.
    let pick = if truth: 1 else: 2
    if pick < args.len: return Value(text: args[pick].text, truth: args[pick].truth,
                                     missing: args[pick].missing)
    return Value()
  of "if2":
    # $if2(a, b): a if found, else b.
    if truth: return args[0]
    if args.len > 1: return args[1]
    return Value()
  of "if3":
    # $if3(a, b, ..., else): the first found.
    for i, a in args:
      if a.truth or i == args.high: return a
    return Value()
  of "substr": result.text = lit(arg(0).runeSlice(arg(1).toInt, arg(2).toInt))
  of "left", "cut": result.text = lit(arg(0).runeSlice(1, arg(1).toInt))
  of "right":
    let r = arg(0).toRunes
    let n = clamp(arg(1).toInt, 0, r.len)
    result.text = lit($r[r.len - n .. ^1])
  of "lower": result.text = lit(unicode.toLower(arg(0)))
  of "upper": result.text = lit(unicode.toUpper(arg(0)))
  of "trim": result.text = lit(unicode.strip(arg(0)))
  of "replace":
    # $replace(s, a, b[, c, d...]): each a by its b.
    var s = arg(0)
    var i = 1
    while i + 1 < args.len:
      if arg(i).len > 0: s = s.replace(arg(i), arg(i + 1))
      i += 2
    result.text = lit(s)
  of "num":
    # $num(n, len): n padded with zeros to len digits.
    let n = arg(0).toInt
    result.text = lit(align($abs(n), arg(1).toInt, '0'))
    if n < 0: result.text.insert(('-', false), 0)
  of "pad":
    result.text = lit(alignLeft(arg(0), arg(1).toInt, (if arg(2).len > 0: arg(2)[0] else: ' ')))
  else: return Value(missing: true)  # unknown: the line finds nothing
  result.truth = truth
  result.missing = missing

proc parseFunc(p: var Parser): Value =
  ## At the $ opening it.
  inc p.i
  let start = p.i
  while p.i < p.s.len and p.s[p.i] notin {'(', ')', ',', '$', '%', '[', ']', '\''}: inc p.i
  let name = p.s[start ..< p.i]
  if p.i >= p.s.len or p.s[p.i] != '(':
    return Value(text: lit("$" & name))  # no call: as written
  inc p.i
  var args: seq[Value]
  while true:
    args.add p.parseSeq({',', ')'})
    if p.i >= p.s.len: break
    let c = p.s[p.i]
    inc p.i
    if c == ')': break
  call(name, args)

proc parseSeq(p: var Parser, stop: set[char]): Value =
  ## Up to one of stop (left there) or the end.
  while p.i < p.s.len and p.s[p.i] notin stop:
    let c = p.s[p.i]
    case c
    of '%':
      let v = p.parseField
      result.text.add v.text
      result.truth = result.truth or v.truth
      result.missing = result.missing or v.missing
    of '$':
      let v = p.parseFunc
      result.text.add v.text
      result.truth = result.truth or v.truth
      result.missing = result.missing or v.missing
    of '[':
      inc p.i
      let v = p.parseSeq({']'})
      if p.i < p.s.len: inc p.i
      if v.truth and not v.missing: result.text.add v.text
      result.truth = result.truth or v.truth
    of '\'':
      # 'text' as written ('' a quote).
      inc p.i
      if p.i < p.s.len and p.s[p.i] == '\'':
        result.text.add ('\'', false)
        inc p.i
      else:
        while p.i < p.s.len and p.s[p.i] != '\'':
          result.text.add (p.s[p.i], false)
          inc p.i
        if p.i < p.s.len: inc p.i
    else:
      result.text.add (c, c in {'*', '?'})
      inc p.i

proc evaluate*(pattern: string,
               field: proc (name: string): tuple[value: string, found: bool]):
               tuple[text: string, wild: seq[bool], ok: bool] =
  ## The pattern with its fields and functions done: the text and which of
  ## its bytes are wildcards; not ok when a field it needs is missing.
  var p = Parser(s: pattern, field: field)
  let v = p.parseSeq({})
  if v.missing: return
  for c in v.text:
    result.text.add c.c
    result.wild.add c.wild
  result.ok = true

proc formatTitle*(pattern: string,
                  field: proc (name: string): tuple[value: string, found: bool]): string =
  ## The pattern as text to show, foobar2000's title formatting: a field the
  ## file doesn't have reads "?" ([...] around it leaves it out), * and ? are
  ## plain characters.
  var p = Parser(s: pattern, field: field, display: true)
  p.parseSeq({}).plain

# --- matching -------------------------------------------------------------------

type Seg = tuple[text: string, wild: seq[bool]]

proc globMatch(name: string, seg: Seg): bool =
  ## name against seg's * and ?, letter case aside, character by character.
  var pat: seq[tuple[r: Rune, wild: bool]]
  var i = 0
  while i < seg.text.len:
    let n = max(1, seg.text.runeLenAt(i))
    pat.add (unicode.toLower(seg.text.runeAt(i)), seg.wild[i])
    i += n
  var str: seq[Rune]
  for r in name.runes: str.add unicode.toLower(r)
  var (pi, si, star, mark) = (0, 0, -1, 0)
  while si < str.len:
    if pi < pat.len and pat[pi].wild and pat[pi].r == Rune('*'):
      star = pi
      mark = si
      inc pi
    elif pi < pat.len and ((pat[pi].wild and pat[pi].r == Rune('?')) or pat[pi].r == str[si]):
      inc pi
      inc si
    elif star >= 0:
      pi = star + 1
      inc mark
      si = mark
    else: return false
  while pi < pat.len and pat[pi].wild and pat[pi].r == Rune('*'): inc pi
  pi == pat.len

proc isWild(seg: Seg): bool = true in seg.wild

proc entries(dir: string, files: bool): seq[string] =
  ## dir's files (or folders) by name, letter case aside.
  try:
    for kind, f in walkDir(dir, relative = true):
      if files and kind in {pcFile, pcLinkToFile}: result.add f
      elif not files and kind in {pcDir, pcLinkToDir}: result.add f
  except OSError: discard
  result.sort(proc (a, b: string): int =
    result = cmp(unicode.toLower(a), unicode.toLower(b))
    if result == 0: result = cmp(a, b))

proc isPicture(name: string): bool =
  name.splitFile.ext.toLowerAscii.strip(chars = {'.'}) in ImageExtensions

proc search(dirs: seq[string], segs: seq[Seg]): string =
  ## The first picture down segs from dirs.
  var dirs = dirs
  for k, seg in segs:
    let last = k == segs.high
    var next: seq[string]
    for d in dirs:
      if not last and not seg.isWild and seg.text in [".", ".."]:
        next.add(if seg.text == ".": d else: d.parentDir)
        continue
      for name in entries(d, files = last):
        if not globMatch(name, seg): continue
        if last:
          if name.isPicture: return d / name
        else: next.add d / name
    dirs = next
    if dirs.len == 0: return ""

proc splitSegs(text: string, wild: seq[bool]): seq[Seg] =
  ## By / and \ (the line's: a field's became _), empty ones dropped.
  var cur: Seg
  for i, c in text:
    if c in {'/', '\\'}:
      if cur.text.len > 0: result.add cur
      cur = default(Seg)
    else:
      cur.text.add c
      cur.wild.add wild[i]
  if cur.text.len > 0: result.add cur

proc lastSegment(pattern: string): string =
  let i = max(pattern.rfind('/'), pattern.rfind('\\'))
  pattern[i + 1 .. ^1]

proc findPicture*(pattern, mediaPath: string,
                  field: proc (name: string): tuple[value: string, found: bool]): string =
  ## The picture pattern finds for the file at mediaPath, "" for none.
  var (text, wild, ok) = evaluate(pattern.strip, field)
  if not ok or text.strip.len == 0: return ""
  # Without an extension, any picture's: "folder" as "folder.*".
  let tail = pattern.strip.lastSegment
  if '.' notin tail and '*' notin tail and '?' notin tail:
    text.add ".*"
    wild.add [false, true]
  var base = mediaPath.parentDir
  var rest = (text, wild)
  if text.startsWith("~") and (text.len == 1 or text[1] in {'/', '\\'}):
    base = getHomeDir()
    rest = (text[1 .. ^1], wild[1 .. ^1])
  elif text.startsWith("/") or text.startsWith("\\"):
    base = "/"
  elif text.len >= 2 and text[1] == ':' and text[0] in Letters:
    base = text[0 .. 1] & "\\"
    rest = (text[2 .. ^1], wild[2 .. ^1])
  let segs = splitSegs(rest[0], rest[1])
  if segs.len == 0: return ""
  search(@[base], segs)

proc fieldKey(s: string): string =
  ## A tag's name as compared: lower case, no spaces or underscores.
  for c in s.toLowerAscii:
    if c notin {' ', '_', '-'}: result.add c

const TagAliases = {
  "albumartist": @["albumartist", "artist"],
  "artist": @["artist", "albumartist", "performer"],
  "tracknumber": @["track", "tracknumber"],
  "track": @["track", "tracknumber"],
  "discnumber": @["disc", "discnumber", "disk"],
  "disc": @["disc", "discnumber", "disk"],
  "date": @["date", "year"],
  "year": @["date", "year"]}.toTable

proc fileFields*(mediaPath: string, tags: Table[string, string]):
                 proc (name: string): tuple[value: string, found: bool] =
  ## The fields of the file at mediaPath with tags (its own names, any case).
  var byKey: Table[string, string]
  for k, v in tags:
    if v.strip.len > 0 and k.fieldKey notin byKey: byKey[k.fieldKey] = v.strip
  let (dir, name, ext) = mediaPath.splitFile
  result = proc (field: string): tuple[value: string, found: bool] =
    let key = field.fieldKey
    case key
    of "filename": return (name, true)
    of "filenameext": return (name & ext, true)
    of "ext": return (ext.strip(chars = {'.'}), true)
    of "directoryname", "foldername": return (dir.lastPathPart, true)
    else: discard
    for k in TagAliases.getOrDefault(key, @[key]):
      if k in byKey:
        var v = byKey[k]
        if key in ["tracknumber", "discnumber"]:
          v = v.split('/')[0].strip
          if key == "tracknumber" and v.len == 1 and v[0] in Digits: v = "0" & v
        elif key == "year": v = v[0 ..< min(4, v.len)]
        return (v, true)
    ("", false)

proc findFolderPicture*(patterns: openArray[string], mediaPath: string,
                        tags: Table[string, string]): string =
  ## The first line of patterns that finds a picture for the file at
  ## mediaPath: that picture, "" for none.
  let field = fileFields(mediaPath, tags)
  for pat in patterns:
    if pat.strip.len == 0: continue
    result = findPicture(pat, mediaPath, field)
    if result.len > 0: return
