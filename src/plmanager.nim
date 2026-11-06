## The playlist manager's data: named playlists with their own entries,
## selection, playlist file and undo history, kept in playlists.json.
##
## Several players may run at once and each saves its playlists, so a save
## merges by playlist: the ones this player changed (or made, or closed) go
## in as it has them, the rest stay as the file has them, another player's
## changes included.

import std/[os, tables, times, sets, random]
import jsony
import config

const
  DefaultName* = "Default"        ## the scratch playlist, where opened files go
  NewName* = "New Playlist"
  UndoSteps = 100                 ## a playlist's undo steps kept, at most
  UndoEntries = 200_000           ## and their entries, all told
  ClosedKept* = 20                ## closed playlists Restore can bring back

type
  UndoStep* = object
    label*: string                ## what it undoes, "Remove 3 items"
    entries*: seq[string]
    selected*: int
    marks*: seq[int]

  PlaylistTab* = object
    ## A playlist. While it's the one shown, the App's playlist fields hold
    ## its entries, selection, file and scroll, and these are stale.
    id*: int                      ## unique across runs and players, never 0
    name*: string
    scratch*: bool                ## the Default playlist: opening files replaces it
    entries*: seq[string]
    index*: int                   ## the entry playing, in the playing playlist only; else -1
    selected*: int
    marks*: seq[int]
    scroll*: float32
    reveal*, follow*: bool
    file*: string                 ## the M3U/PLS file it's bound to, "" for none
    fileList*: seq[string]        ## the entries as last read from or written to it
    fileWritable*, autosaveFailed*, online*: bool
    dir*: int                     ## ping-pong: the way it goes next
    undo*, redo*: seq[UndoStep]
    closedAt*: int                ## where it was, once closed (Restore puts it back there)
    columns*: seq[PlaylistField]  ## its own columns, left to right ("Override columns
                                  ## for this playlist"); empty: the config's
    columnWidths*: Table[string, float]  ## and their widths resized by hand

  SavedPlaylist* = object
    id*: int
    name*: string
    scratch*: bool
    entries*: seq[string]
    index*: int                   ## the entry playing as it was saved, else -1
    selected*: int
    file*: string
    columns*: seq[PlaylistField]  ## its own columns; empty: the config's
    columnWidths*: Table[string, float]

  PlaylistStore* = object
    playlists*: seq[SavedPlaylist]
    shown*: int                   ## the id of the playlist shown
    playing*: int                 ## and of the one playing, 0 for none
    titles*: Table[string, string]  ## the links' titles
    listed*: seq[string]          ## YouTube playlist links already listed

proc newHook*(p: var SavedPlaylist) =
  p = SavedPlaylist(index: -1, selected: -1)

var idRand = initRand(int64(epochTime() * 1e6) xor (getCurrentProcessId().int64 shl 40))

proc newPlaylistId*(): int =
  ## Random, so players making playlists at the same time don't clash.
  idRand.rand(1 .. int(int32.high))

proc newTab*(name: string, scratch = false, id = 0): PlaylistTab =
  PlaylistTab(id: (if id != 0: id else: newPlaylistId()), name: name, scratch: scratch,
    index: -1, selected: -1, dir: 1)

proc toTab*(s: SavedPlaylist): PlaylistTab =
  result = newTab(s.name, s.scratch, s.id)
  result.entries = s.entries
  result.selected = if s.selected in 0 ..< s.entries.len: s.selected else: -1
  (result.columns, result.columnWidths) = (s.columns, s.columnWidths)

proc toSaved*(t: PlaylistTab, entries: seq[string], index, selected: int): SavedPlaylist =
  SavedPlaylist(id: t.id, name: t.name, scratch: t.scratch, entries: entries,
    index: index, selected: selected, file: t.file, columns: t.columns,
    columnWidths: t.columnWidths)

proc trimUndo*(steps: var seq[UndoStep]) =
  ## Oldest first out, past the limits.
  var total = 0
  for s in steps: total += s.entries.len
  while steps.len > UndoSteps or (steps.len > 1 and total > UndoEntries):
    total -= steps[0].entries.len
    steps.delete(0)

proc uniqueName*(names: openArray[string], base: string): string =
  ## base, or "base (2)", "base (3)"... whichever no playlist has.
  result = base
  var n = 1
  while result in names:
    inc n
    result = base & " (" & $n & ")"

# --- playlists.json ------------------------------------------------------------

var
  lastSynced: PlaylistStore       ## as this player last read or wrote it
  storeStamp: Time                ## the file then

proc storePath(): string = configDir() / "playlists.json"

proc fileTime(): Time =
  try: getLastModificationTime(storePath()) except OSError: Time()

proc readStore(): tuple[ok: bool, store: PlaylistStore] =
  let path = storePath()
  if not fileExists(path): return
  try: result = (true, readFile(path).fromJson(PlaylistStore))
  except CatchableError as e:
    stderr.writeLine "playlists: ignoring unreadable ", path, ": ", e.msg

proc loadPlaylists*(): tuple[ok: bool, store: PlaylistStore] =
  ## The saved playlists; ok is false when there's no file yet.
  result = readStore()
  lastSynced = result.store
  storeStamp = fileTime()

proc mergeStore*(mine, before, disk: PlaylistStore): PlaylistStore =
  ## mine: this player's playlists now; before: as it last read or wrote
  ## them; disk: the file now. A playlist this player didn't touch since
  ## keeps the file's version; one only the file has is another player's
  ## new playlist, unless this player had it and closed it.
  result = mine
  result.playlists.setLen 0
  var was, onDisk: Table[int, SavedPlaylist]
  for p in before.playlists: was[p.id] = p
  for p in disk.playlists: onDisk[p.id] = p
  var mineIds: HashSet[int]
  for p in mine.playlists:
    mineIds.incl p.id
    let touched = p.id notin was or was[p.id] != p
    result.playlists.add(if touched or p.id notin onDisk: p else: onDisk[p.id])
  for p in disk.playlists:
    if p.id notin mineIds and p.id notin was: result.playlists.add p
  # Titles and listed links for what's in the playlists, this player's first.
  var links: HashSet[string]
  for p in result.playlists:
    for e in p.entries: links.incl e
  result.titles.clear()
  for src in [disk.titles, mine.titles]:
    for k, v in src:
      if k in links: result.titles[k] = v
  result.listed.setLen 0
  for src in [mine.listed, disk.listed]:
    for l in src:
      if l in links and l notin result.listed: result.listed.add l

proc savePlaylists*(s: PlaylistStore) =
  ## Writes only when this player's playlists changed since it last read or
  ## wrote the file, merged with what other players wrote meanwhile.
  if s == lastSynced: return
  var disk = lastSynced
  if fileTime() != storeStamp:
    let (ok, d) = readStore()
    disk = if ok: d else: PlaylistStore()
  let merged = mergeStore(s, lastSynced, disk)
  try:
    createDir(configDir())
    writeAtomic(storePath(), merged.toJson)
    lastSynced = s
    storeStamp = fileTime()
  except CatchableError as e:
    stderr.writeLine "playlists: cannot save ", storePath(), ": ", e.msg
