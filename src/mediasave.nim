## File > Save: the media playing, saved whole to a file the user picks. A
## file on disk (or a link the media cache holds all of) is copied a piece at
## a time, playing going on meanwhile; any other link is downloaded with
## yt-dlp, as its hook streams it (best video and audio, in an .mkv or .mp4
## with its subtitles and chapters). Styled subtitles (srv3) go into an .mkv
## last, with ffmpeg: an .mp4 can't hold them.

import std/[os, osproc, strutils, times]
import srv3, ytdlp

type
  SaveJob* = ref object
    dest*: string             ## the file it makes
    error*: string            ## why it failed; "" while it hasn't
    warning*: string          ## what's missing from a file it did save
    done*: bool               ## finished, well or not
    src, part: string         ## copying: from where, and the file being written
    fin, fout: File
    size, copied: int64
    dl: YtJob                 ## downloading
    styled: seq[StyledTrack]  ## subtitles to add once the file's there
    mux: Process              ## adding them
    started: Time

const
  Chunk = 1 shl 20
  PollBudget = 0.008          ## seconds a poll may spend copying

proc safeName*(title: string): string =
  ## title as a file name: characters no file system takes go.
  for c in title:
    result.add(if c in {'/', '\\', ':', '*', '?', '"', '<', '>', '|'} or c < ' ': '_' else: c)
  result = result.strip(chars = {' ', '.'})
  if result.len == 0: result = "media"

proc fail(j: SaveJob, msg: string) =
  if j.fin != nil: j.fin.close()
  if j.fout != nil: j.fout.close()
  j.fin = nil
  j.fout = nil
  if j.part.len > 0:
    try: removeFile(j.part)
    except OSError: discard
  j.error = msg
  j.done = true

proc addStyled(j: SaveJob) =
  ## The file's there: ends the job, adding the styled subtitles first, as
  ## the first subtitle tracks.
  if j.styled.len == 0:
    j.done = true
    return
  j.dl = nil
  j.part = j.dest & ".part"
  var args = @["-v", "error", "-y", "-i", j.dest]
  for t in j.styled: args.add ["-i", t.path]
  args.add ["-map", "0:v?", "-map", "0:a?"]
  for i in 1 .. j.styled.len: args.add ["-map", $i]
  args.add ["-map", "0:s?", "-map", "0:t?", "-c", "copy"]
  for i, t in j.styled:
    args.add ["-metadata:s:s:" & $i, "language=" & t.lang, "-metadata:s:s:" & $i, "title=" & t.title]
  args.add ["-f", "matroska", j.part]
  try: j.mux = startProcess("ffmpeg", args = args, options = {poUsePath, poStdErrToStdOut, poDaemon})
  except OSError:
    j.warning = "no styled subtitles: ffmpeg can't be run"
    j.done = true

proc copying*(src, dest: string, styled: seq[StyledTrack] = @[]): SaveJob =
  ## Copies src to dest, written as dest.part until all of it is.
  result = SaveJob(src: src, dest: dest, part: dest & ".part", styled: styled)
  if src.absolutePath == dest.absolutePath or
     fileExists(dest) and (try: sameFile(src, dest) except OSError: false):
    result.fail("it's the file itself")
    return
  try:
    result.size = getFileSize(src)
    createDir(dest.parentDir)
  except OSError as e:
    result.fail(e.msg)
    return
  if not open(result.fin, src, fmRead):
    result.fail("cannot read " & src.extractFilename)
  elif not open(result.fout, result.part, fmWrite):
    result.fail("cannot write " & dest.extractFilename)

proc downloading*(exe, url, dest: string, cookies = "", format = "bv*+ba/b",
                  styled: seq[StyledTrack] = @[]): SaveJob =
  ## Downloads url with yt-dlp; dest's extension (.mp4, else .mkv) picks the
  ## container, and dest becomes the file it makes.
  let ext = if dest.splitFile.ext.toLowerAscii == ".mp4": "mp4" else: "mkv"
  let (dir, name, _) = dest.splitFile
  result = SaveJob(dest: dir / name & "." & ext, started: getTime(), styled: styled)
  try: createDir(dir)
  except OSError as e:
    result.fail(e.msg)
    return
  var skip: seq[string]
  for t in styled: skip.add t.lang
  result.dl = download(exe, url, dir, name.replace("%", "%%") & ".%(ext)s", ext, cookies, format, skip)

proc running*(j: SaveJob): bool = j != nil and not j.done

proc progress*(j: SaveJob): float =
  ## Percent done; -1 while unknown.
  if j.dl != nil: j.dl.progress
  elif j.size > 0: j.copied.float * 100 / j.size.float
  else: -1

proc bytes*(j: SaveJob): tuple[done, total: int64] =
  ## Bytes saved, of how many (0: unknown).
  if j.dl != nil: (j.dl.bytes, j.dl.total) else: (j.copied, j.size)

proc stage*(j: SaveJob): tuple[step, steps: int] =
  ## Downloading video and audio apart, then merging them: which of those
  ## it's on; steps 0 otherwise.
  if j.dl != nil and j.dl.steps > 0: (clamp(j.dl.step, 1, j.dl.steps), j.dl.steps)
  else: (0, 0)

proc poll*(j: SaveJob): bool =
  ## Copies on or reads yt-dlp's progress. True when anything changed.
  if not j.running: return
  if j.mux != nil:
    if j.mux.running: return
    let code = j.mux.peekExitCode
    j.mux.close()
    j.mux = nil
    try:
      if code == 0: moveFile(j.part, j.dest)
      else:
        removeFile(j.part)
        j.warning = "no styled subtitles: ffmpeg failed"
    except OSError as e: j.warning = "no styled subtitles: " & e.msg
    j.done = true
    return true
  if j.dl != nil:
    result = j.dl.poll()
    if not j.dl.running:
      if j.dl.code == 0 and fileExists(j.dest): j.addStyled()
      elif j.dl.code == 0: j.fail("yt-dlp made no " & j.dest.extractFilename)
      else: j.fail(j.dl.errorText)
    return
  var buf = newSeq[byte](Chunk)
  let start = epochTime()
  while epochTime() - start < PollBudget:
    let n = try: j.fin.readBuffer(buf[0].addr, Chunk) except IOError: -1
    if n < 0:
      j.fail("cannot read " & j.src.extractFilename)
      return true
    if n > 0 and (try: j.fout.writeBuffer(buf[0].addr, n) != n except IOError: true):
      j.fail("cannot write " & j.dest.extractFilename & " (disk full?)")
      return true
    j.copied += n
    result = true
    if n < Chunk:  # the end
      j.fin.close()
      j.fout.close()
      j.fin = nil
      j.fout = nil
      try: moveFile(j.part, j.dest)
      except OSError as e:
        j.fail(e.msg)
        return
      j.addStyled()
      return

proc cancel*(j: SaveJob) =
  if not j.running: return
  if j.mux != nil:
    try: j.mux.terminate(); discard j.mux.waitForExit(); j.mux.close()
    except OSError: discard
    j.mux = nil
  if j.dl != nil:
    j.dl.stop()
    # What it left: the streams it downloads apart (name.f<format>.<ext>,
    # .part while downloading) and the merge (name.temp.<ext>).
    let (dir, name, _) = j.dest.splitFile
    try:
      for kind, f in walkDir(dir):
        let n = f.extractFilename
        if kind != pcFile or not n.startsWith(name & "."): continue
        let rest = n[name.len + 1 .. ^1]
        if (rest.startsWith("f") or rest.startsWith("temp.")) and
           getLastModificationTime(f) >= j.started: removeFile(f)
    except OSError: discard
  j.fail("cancelled")
