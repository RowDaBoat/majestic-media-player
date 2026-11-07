## macOS side of assoc.nim (included there): Launch Services' default app per
## type (UTI), so extensions sharing one (mpg, mpeg) move together. Only the
## app bundle can be a default: run from the bare binary, nothing can be
## checked.

import cocoa

proc bundleId(): string =
  var buf: array[256, char]
  if mmpBundleId(cast[cstring](buf[0].addr), buf.len.cint) != 0:
    result = $cast[cstring](buf[0].addr)

proc uti(ext: string): string =
  var buf: array[256, char]
  if mmpUtiForExt(ext.cstring, cast[cstring](buf[0].addr), buf.len.cint) != 0:
    result = $cast[cstring](buf[0].addr)

proc loadAssocItems*(): seq[AssocItem] =
  let bundled = bundleId().len > 0
  for (exts, video) in [(@VideoExtensions, true), (@AudioExtensions, false),
                        (@AssocTrackerExtensions, false)]:
    for ext in exts:
      var it = AssocItem(ext: ext, video: video)
      let t = if bundled: uti(ext) else: ""
      if t.len > 0:
        it.mimes = @[t]
        it.current = mmpIsDefaultFor(t.cstring) != 0
      it.checked = it.current
      result.add it
  result.sort(proc (x, y: AssocItem): int = cmp(x.ext, y.ext))

proc applyAssociations*(items: var seq[AssocItem]): string =
  ## Makes the app the default for checked types; unchecked ones go to another
  ## app that opens them. Returns an error, or "".
  if bundleId().len == 0: return "only the app bundle can open files from Finder"
  for it in items.mitems:
    if it.checked == it.current: continue
    for t in it.mimes:
      let err = mmpSetDefaultFor(t.cstring, it.checked.cint)
      if err != 0: return "Launch Services error " & $err & " for ." & it.ext
    it.current = it.checked

proc userOverrides*(items: seq[AssocItem]): seq[string] =
  ## Launch Services' default is the user's choice itself.
  discard
