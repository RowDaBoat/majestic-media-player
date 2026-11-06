## A file's tags, read and written with TagLib's C bindings (libtag_c),
## loaded at run time: without them, Properties shows tags read-only.
##
## Tags are TagLib's property map: one unified list of fields (TITLE, ARTIST,
## TRACKNUMBER...) that TagLib maps onto each format's own (ID3v2 frames,
## Vorbis comments, MP4 atoms, APE items...). A field may hold several values.
## Fields the format can't hold are dropped by TagLib on save; `save` reads
## the file back to tell which.

import std/[dynlib, strutils, tables, os]
when defined(windows): import std/widestrs

type
  TagFile = pointer
  Api = object
    fileNew: proc (path: cstring): TagFile {.cdecl.}
    fileNewW: proc (path: WideCString): TagFile {.cdecl.}
    fileFree: proc (f: TagFile) {.cdecl.}
    isValid: proc (f: TagFile): cint {.cdecl.}
    save: proc (f: TagFile): cint {.cdecl.}
    propKeys: proc (f: TagFile): cstringArray {.cdecl.}
    propGet: proc (f: TagFile, key: cstring): cstringArray {.cdecl.}
    propSet: proc (f: TagFile, key, value: cstring) {.cdecl.}
    propAppend: proc (f: TagFile, key, value: cstring) {.cdecl.}
    propFree: proc (p: cstringArray) {.cdecl.}
    unicode: proc (on: cint) {.cdecl.}

  Tags* = Table[string, seq[string]]  ## upper-case field -> its values

  TagRead* = object
    ok*: bool                 ## TagLib opened the file
    tags*: Tags

var
  api: Api
  tried, ok: bool

proc load*(): bool =
  ## libtag_c's functions, false when it's missing.
  if tried: return ok
  tried = true
  let names = when defined(windows): @["tag_c.dll", "libtag_c.dll", "libtag_c-2.dll"]
              elif defined(macosx): @["libtag_c.2.dylib", "libtag_c.dylib"]
              else: @["libtag_c.so.2", "libtag_c.so"]
  var lib: LibHandle
  for n in names:
    lib = loadLib(n)
    if lib != nil: break
  if lib == nil: return false
  template sym(field, name: untyped) =
    let p = lib.symAddr(name)
    if p == nil: return false
    api.field = cast[typeof(api.field)](p)
  when defined(windows): sym fileNewW, "taglib_file_new_wchar"
  else: sym fileNew, "taglib_file_new"
  sym fileFree, "taglib_file_free"
  sym isValid, "taglib_file_is_valid"
  sym save, "taglib_file_save"
  sym propKeys, "taglib_property_keys"
  sym propGet, "taglib_property_get"
  sym propSet, "taglib_property_set"
  sym propAppend, "taglib_property_set_append"
  sym propFree, "taglib_property_free"
  sym unicode, "taglib_set_strings_unicode"
  api.unicode(1)
  ok = true
  true

proc available*(): bool = load()

proc open(path: string): TagFile =
  if not load() or not fileExists(path): return nil
  result = when defined(windows): api.fileNewW(newWideCString(path))
           else: api.fileNew(path.cstring)
  if result != nil and api.isValid(result) == 0:
    api.fileFree(result)
    result = nil

proc strings(p: cstringArray): seq[string] =
  if p == nil: return
  var i = 0
  while p[i] != nil:
    result.add $p[i]
    inc i
  api.propFree(p)

proc readOpen(f: TagFile): Tags =
  for k in strings(api.propKeys(f)):
    result[k.toUpperAscii] = strings(api.propGet(f, k.cstring))

proc readTags*(path: string): TagRead =
  ## The file's fields, ok false when TagLib is missing or can't open it.
  let f = open(path)
  if f == nil: return
  defer: api.fileFree(f)
  TagRead(ok: true, tags: readOpen(f))

proc writeTags*(path: string, tags: Tags): tuple[ok: bool, dropped: seq[string], error: string] =
  ## Makes the file's fields exactly tags (fields missing from it are
  ## removed); dropped: fields the format couldn't keep.
  let f = open(path)
  if f == nil: return (false, @[], "TagLib can't open this file")
  var saved: bool
  try:
    let old = readOpen(f)
    for k in old.keys:
      if k notin tags or tags[k].len == 0: api.propSet(f, k.cstring, nil)
    for k, vs in tags:
      if vs.len == 0 or old.getOrDefault(k) == vs: continue
      # Set, then append: some tags (trackers') always have every field, so
      # appending to a removed one would add to an empty value.
      api.propSet(f, k.cstring, vs[0].cstring)
      for v in vs[1 .. ^1]: api.propAppend(f, k.cstring, v.cstring)
    saved = api.save(f) != 0
  finally:
    api.fileFree(f)
  # Read back: what the format didn't take. A save reported failed counts as
  # done when the fields did get written (TagLib can fail after writing).
  let back = readTags(path)
  for k, vs in tags:
    if vs.len > 0 and k notin back.tags: result.dropped.add k
  if not saved:
    var same = back.ok
    for k, vs in tags:
      if vs.len > 0 and k in back.tags and back.tags[k] != vs: same = false
    if not same or result.dropped.len > 0:
      return (false, @[], "the file couldn't be written (is it read-only?)")
  result.ok = true
