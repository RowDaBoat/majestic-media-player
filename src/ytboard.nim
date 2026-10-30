## A YouTube video's storyboard, for the seek bar's previews: its sheets of
## little frames, fetched with curl one at a time from the video's start into
## the cache folder, in the background once the link has loaded. Named .jpg by
## YouTube but WebP, which pixie can't read: the preview's mpv shows them,
## cropped to a frame (Preview.showImage).

import std/[os, osproc, algorithm, math, strformat, times]
import ytdlp

const
  MaxFails = 3     ## sheets failing in a row (expired links) end the fetching
  MaxVideos = 100  ## videos whose sheets the cache keeps

type
  BoardJob* = ref object
    id*: string               ## the video's
    board*: Storyboard
    have: seq[bool]           ## by sheet: fetched
    next: int                 ## the sheet being fetched, or to fetch
    fails: int                ## in a row
    p: Process                ## nil while none is fetching

proc boardsDir(): string = getCacheDir("majestic-media-player") / "storyboards"

proc sheetPath(j: BoardJob, i: int): string = boardsDir() / j.id / $i & ".webp"

proc running*(j: BoardJob): bool = j != nil and j.p != nil

proc fetchNext(j: BoardJob) =
  while j.next < j.have.len and j.have[j.next]: inc j.next
  if j.next >= j.have.len: return
  try:
    # -g: the links are to take as they are.
    j.p = startProcess("curl", args = ["-fsLg", "--max-time", "15", "-o",
      j.sheetPath(j.next) & ".part", j.board.sheets[j.next].url],
      options = {poUsePath, poStdErrToStdOut, poDaemon})
  except OSError:
    j.next = j.have.len

proc trimCache() =
  ## Only the videos last played keep their sheets.
  var dirs: seq[(Time, string)]
  try:
    for kind, d in walkDir(boardsDir()):
      if kind == pcDir: dirs.add (d.getLastModificationTime, d)
    dirs.sort(Descending)
    for (_, d) in dirs[min(MaxVideos, dirs.len) .. ^1]: removeDir(d)
  except OSError: discard

proc fetchBoard*(id: string, board: Storyboard): BoardJob =
  ## Starts fetching the sheets not in the cache yet.
  result = BoardJob(id: id, board: board, have: newSeq[bool](board.sheets.len))
  for i in 0 ..< board.sheets.len: result.have[i] = fileExists(result.sheetPath(i))
  try:
    createDir(boardsDir() / id)
    setLastModificationTime(boardsDir() / id, getTime())
  except OSError: return
  trimCache()
  result.fetchNext()

proc poll*(j: BoardJob): bool =
  ## True when a sheet just came in.
  if not j.running or j.p.running: return false
  let code = j.p.peekExitCode
  j.p.close()
  j.p = nil
  let path = j.sheetPath(j.next)
  if code == 0:
    try:
      moveFile(path & ".part", path)
      j.have[j.next] = true
      j.fails = 0
      result = true
    except OSError: inc j.fails
  else: inc j.fails
  discard tryRemoveFile(path & ".part")
  inc j.next
  if j.fails >= MaxFails: j.next = j.have.len
  j.fetchNext()

proc tile*(j: BoardJob, t: float): tuple[sheet, crop: string] =
  ## The sheet with the frame at time t and where the frame is in it (a
  ## video-crop value); no sheet while it isn't in. A sheet's frames fill it
  ## row by row, the last sheet's only as far as they go.
  let b = j.board
  var start = 0.0
  for i, s in b.sheets:
    if t < start + s.duration or i == b.sheets.high:
      if not j.have[i]: return
      let frames = clamp(ceil(s.duration * b.fps - 0.001).int, 1, b.columns * b.rows)
      let n = clamp(int((t - start) * b.fps), 0, frames - 1)
      let (x, y) = (n mod b.columns * b.width, n div b.columns * b.height)
      return (j.sheetPath(i), &"{b.width}x{b.height}+{x}+{y}")
    start += s.duration

proc cancel*(j: BoardJob) =
  if not j.running: return
  try: j.p.terminate(); j.p.close()
  except OSError: discard
  j.p = nil
  discard tryRemoveFile(j.sheetPath(j.next) & ".part")
