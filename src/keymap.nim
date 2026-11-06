## Rebindable keyboard shortcuts (Options > Player > Keys). Every command has
## default keys; the config keeps only the ones the user changed, as text
## like "Ctrl+Shift+O", several keys joined by '|' ("" = no key).

import std/[strutils, tables, sequtils]
import windy
import config

type
  KeyMod* = enum
    kmCtrl, kmShift, kmAlt

  KeyCombo* = object
    mods*: set[KeyMod]
    key*: Button                  ## ButtonUnknown = no key

  KeyGroup* = enum
    kgFile = "File"
    kgPlayback = "Playback"
    kgNavigate = "Navigate"
    kgSubtitles = "Subtitles"
    kgView = "View"
    kgPlaylist = "Playlist"
    kgPan = "Pan, Rotate & Zoom"

  KeyAction* = enum
    ## The string is the command's id in the config.
    kaOpenFile = "open-file"
    kaLoadSubtitle = "load-subtitle"
    kaLoadAudio = "load-audio"
    kaOpenClipboard = "open-clipboard"
    kaCopyClipboard = "copy-clipboard"
    kaCopyTimeLink = "copy-time-link"
    kaClose = "close"
    kaSave = "save"
    kaScreenshot = "screenshot"
    kaProperties = "properties"
    kaExit = "exit"
    kaPlayPause = "play-pause"
    kaStop = "stop"
    kaFrameForward = "frame-forward"
    kaFrameBack = "frame-back"
    kaFaster = "faster"
    kaSlower = "slower"
    kaRepeatForever = "repeat-forever"
    kaRepeatPingPong = "repeat-ping-pong"
    kaVolumeUp = "volume-up"
    kaVolumeDown = "volume-down"
    kaMute = "mute"
    kaNextAudio = "next-audio"
    kaPrevAudio = "previous-audio"
    kaNextSub = "next-subtitle"
    kaPrevSub = "previous-subtitle"
    kaJumpForward = "jump-forward"
    kaJumpBack = "jump-back"
    kaGoBeginning = "go-to-beginning"
    kaGoEnd = "go-to-end"
    kaSeek10 = "seek-10", kaSeek20 = "seek-20", kaSeek30 = "seek-30",
    kaSeek40 = "seek-40", kaSeek50 = "seek-50", kaSeek60 = "seek-60", kaSeek70 = "seek-70",
    kaSeek80 = "seek-80", kaSeek90 = "seek-90"
    kaNextChapter = "next-chapter"
    kaPrevChapter = "previous-chapter"
    kaNextFile = "next-file"
    kaPrevFile = "previous-file"
    kaAddBookmark = "add-bookmark"
    kaRemoveFromPlaylist = "remove-from-playlist"
    kaSubTopLeft = "sub-top-left", kaSubTop = "sub-top", kaSubTopRight = "sub-top-right",
    kaSubLeft = "sub-left", kaSubCenter = "sub-center", kaSubRight = "sub-right",
    kaSubBottomLeft = "sub-bottom-left", kaSubBottom = "sub-bottom",
    kaSubBottomRight = "sub-bottom-right"
    kaSubUp = "sub-move-up"
    kaSubDown = "sub-move-down"
    kaSubMoveLeft = "sub-move-left"
    kaSubMoveRight = "sub-move-right"
    kaSubBigger = "sub-bigger"
    kaSubSmaller = "sub-smaller"
    kaCompact = "compact-mode"
    kaSeekBar = "seek-bar"
    kaControls = "controls"
    kaStatus = "status"
    kaPlaylist = "playlist"
    kaFindPlaylist = "find-in-playlist"
    kaNewPlaylist = "new-playlist"
    kaClosePlaylist = "close-playlist"
    kaRestorePlaylist = "restore-playlist"
    kaRenamePlaylist = "rename-playlist"
    kaNextPlaylist = "next-playlist"
    kaPrevPlaylist = "previous-playlist"
    kaShowPlaying = "show-playing-playlist"
    kaUndoPlaylist = "undo-playlist"
    kaRedoPlaylist = "redo-playlist"
    kaQueue = "queue"
    kaUnqueue = "unqueue"
    kaRunLog = "run-log"
    kaShowOsd = "show-osd"
    kaFullScreen = "full-screen"
    kaOptions = "options"
    kaShortcuts = "shortcuts"
    kaCommandPalette = "command-palette"
    kaCenter = "center"
    kaMoveUp = "move-up"
    kaMoveDown = "move-down"
    kaMoveLeft = "move-left"
    kaMoveRight = "move-right"
    kaRotate0 = "rotate-0"
    kaRotateCw = "rotate-cw"
    kaRotateCcw = "rotate-ccw"
    kaRestoreSize = "restore-size"
    kaSizeUp = "increase-size"
    kaSizeDown = "decrease-size"
    kaWidthUp = "increase-width"
    kaWidthDown = "decrease-width"
    kaHeightUp = "increase-height"
    kaHeightDown = "decrease-height"
    kaPanReset = "pan-reset"

  ActionInfo* = tuple
    group: KeyGroup
    label: string                 ## sentence case, for Options and the F1 window
    hint: string                  ## Title Case, for the status bar
    default: string               ## keys joined by '|'

const
  Actions*: array[KeyAction, ActionInfo] = [
    (kgFile, "Open file", "Open File", "Ctrl+O"),
    (kgFile, "Load subtitle file", "Load Subtitle", "Ctrl+Shift+O"),
    (kgFile, "Load audio file", "Load Audio", ""),
    (kgFile, "Open from clipboard", "Open From Clipboard", "Ctrl+V"),
    (kgFile, "Copy to clipboard", "Copy to Clipboard", "Ctrl+C"),
    (kgFile, "Copy YouTube link at current time", "Copy Link at Time", "Ctrl+Shift+C"),
    (kgFile, "Close", "Close", "Ctrl+X"),
    (kgFile, "Save", "Save", "Ctrl+S"),
    (kgFile, "Save screenshot", "Screenshot", "Alt+I"),
    (kgFile, "Properties", "Properties", ""),
    (kgFile, "Exit", "Exit", "Alt+X"),
    (kgPlayback, "Play / Pause", "Play/Pause", "Space"),
    (kgPlayback, "Stop", "Stop", ""),
    (kgPlayback, "Frame forward", "Frame Forward", "."),
    (kgPlayback, "Frame back", "Frame Back", ","),
    (kgPlayback, "Fast-forward", "Fast-Forward", "Shift+."),
    (kgPlayback, "Slow down", "Slow Down", "Shift+,"),
    (kgPlayback, "Repeat forever", "Repeat Forever", ""),
    (kgPlayback, "Repeat ping-pong", "Repeat Ping-Pong", ""),
    (kgPlayback, "Volume up", "Volume Up", "Up"),
    (kgPlayback, "Volume down", "Volume Down", "Down"),
    (kgPlayback, "Mute", "Mute", "Ctrl+M"),
    (kgPlayback, "Next audio track", "Next Audio Track", "A"),
    (kgPlayback, "Previous audio track", "Previous Audio Track", "Shift+A"),
    (kgPlayback, "Next subtitle track", "Next Subtitle Track", "S"),
    (kgPlayback, "Previous subtitle track", "Previous Subtitle Track", "Shift+S"),
    (kgNavigate, "Jump forward", "Jump Forward", "Right"),
    (kgNavigate, "Jump back", "Jump Back", "Left"),
    (kgNavigate, "Go to beginning", "Go To Beginning", "Home|0"),
    (kgNavigate, "Go to last frame", "Go To Last Frame", "End"),
    (kgNavigate, "Jump to 10%", "Jump To 10%", "1"),
    (kgNavigate, "Jump to 20%", "Jump To 20%", "2"),
    (kgNavigate, "Jump to 30%", "Jump To 30%", "3"),
    (kgNavigate, "Jump to 40%", "Jump To 40%", "4"),
    (kgNavigate, "Jump to 50%", "Jump To 50%", "5"),
    (kgNavigate, "Jump to 60%", "Jump To 60%", "6"),
    (kgNavigate, "Jump to 70%", "Jump To 70%", "7"),
    (kgNavigate, "Jump to 80%", "Jump To 80%", "8"),
    (kgNavigate, "Jump to 90%", "Jump To 90%", "9"),
    (kgNavigate, "Next chapter", "Next Chapter", "Ctrl+Right"),
    (kgNavigate, "Previous chapter", "Previous Chapter", "Ctrl+Left"),
    (kgNavigate, "Next file", "Next File", "Page Down"),
    (kgNavigate, "Previous file", "Previous File", "Page Up"),
    (kgNavigate, "Add bookmark", "Add Bookmark", "Insert"),
    (kgNavigate, "Remove bookmark here or selected playlist item", "Remove Bookmark Or Playlist Item", "Delete"),
    (kgSubtitles, "Align top left", "Align Top Left", "Shift+Numpad 7"),
    (kgSubtitles, "Align top", "Align Top", "Shift+Numpad 8"),
    (kgSubtitles, "Align top right", "Align Top Right", "Shift+Numpad 9"),
    (kgSubtitles, "Align left", "Align Left", "Shift+Numpad 4"),
    (kgSubtitles, "Align center", "Align Center", "Shift+Numpad 5"),
    (kgSubtitles, "Align right", "Align Right", "Shift+Numpad 6"),
    (kgSubtitles, "Align bottom left", "Align Bottom Left", "Shift+Numpad 1"),
    (kgSubtitles, "Align bottom", "Align Bottom", "Shift+Numpad 2"),
    (kgSubtitles, "Align bottom right", "Align Bottom Right", "Shift+Numpad 3"),
    (kgSubtitles, "Move up", "Move Subtitles Up", "Shift+Up"),
    (kgSubtitles, "Move down", "Move Subtitles Down", "Shift+Down"),
    (kgSubtitles, "Move left", "Move Subtitles Left", "Shift+Left"),
    (kgSubtitles, "Move right", "Move Subtitles Right", "Shift+Right"),
    (kgSubtitles, "Bigger", "Bigger Subtitles", "Shift+Numpad +"),
    (kgSubtitles, "Smaller", "Smaller Subtitles", "Shift+Numpad -"),
    (kgView, "Compact mode", "Compact Mode", "Ctrl+1"),
    (kgView, "Seek bar", "Seek Bar", "Ctrl+2"),
    (kgView, "Controls", "Controls", "Ctrl+3"),
    (kgView, "Status", "Status", "Ctrl+4"),
    (kgView, "Playlist", "Playlist", "Ctrl+5"),
    (kgView, "Find in playlist", "Find in Playlist", "Ctrl+F"),
    (kgPlaylist, "New playlist", "New Playlist", "Ctrl+N"),
    (kgPlaylist, "Close playlist", "Close Playlist", "Ctrl+W"),
    (kgPlaylist, "Restore closed playlist", "Restore Playlist", "Ctrl+Shift+T"),
    (kgPlaylist, "Rename playlist", "Rename Playlist", "F2"),
    (kgPlaylist, "Next playlist", "Next Playlist", "Ctrl+Tab"),
    (kgPlaylist, "Previous playlist", "Previous Playlist", "Ctrl+Shift+Tab"),
    (kgPlaylist, "Show playing playlist", "Show Playing Playlist", ""),
    (kgPlaylist, "Undo playlist change", "Undo", "Ctrl+Z"),
    (kgPlaylist, "Redo playlist change", "Redo", "Ctrl+Y|Ctrl+Shift+Z"),
    (kgPlaylist, "Add selection to playback queue", "Queue", "Q"),
    (kgPlaylist, "Remove selection from playback queue", "Unqueue", "Shift+Q"),
    (kgView, "Run log", "Run Log", "Ctrl+6"),
    (kgView, "Show OSD", "Show OSD", ""),
    (kgView, "Full screen", "Fullscreen", "Alt+Enter"),
    (kgView, "Options", "Options", "O"),
    (kgView, "Keyboard shortcuts", "Keyboard Shortcuts", "F1"),
    (kgView, "Command palette", "Command Palette", "F3"),
    (kgPan, "Center", "Center", "Numpad 5"),
    (kgPan, "Move up", "Move Up", "Numpad 8"),
    (kgPan, "Move down", "Move Down", "Numpad 2"),
    (kgPan, "Move left", "Move Left", "Numpad 4"),
    (kgPan, "Move right", "Move Right", "Numpad 6"),
    (kgPan, "0 degrees", "Reset Rotation", "Alt+Numpad 5"),
    (kgPan, "Rotate clockwise", "Rotate CW", "Alt+Numpad 6"),
    (kgPan, "Rotate counter-clockwise", "Rotate CCW", "Alt+Numpad 4"),
    (kgPan, "Restore size", "Reset Size", "Ctrl+Numpad 5"),
    (kgPan, "Increase size", "+Size", "Ctrl+Numpad 9"),
    (kgPan, "Decrease size", "-Size", "Ctrl+Numpad 3"),
    (kgPan, "Increase width", "+Width", "Ctrl+Numpad 6"),
    (kgPan, "Decrease width", "-Width", "Ctrl+Numpad 4"),
    (kgPan, "Increase height", "+Height", "Ctrl+Numpad 8"),
    (kgPan, "Decrease height", "-Height", "Ctrl+Numpad 2"),
    (kgPan, "Reset", "Reset Pan, Rotate & Zoom", "")]

  SeekActions* = [kaSeek10, kaSeek20, kaSeek30, kaSeek40, kaSeek50,
                 kaSeek60, kaSeek70, kaSeek80, kaSeek90]
  SubAlignActions* = [kaSubTopLeft, kaSubTop, kaSubTopRight, kaSubLeft, kaSubCenter,
                      kaSubRight, kaSubBottomLeft, kaSubBottom, kaSubBottomRight]
  SubMoveActions* = [kaSubUp, kaSubDown, kaSubMoveLeft, kaSubMoveRight]

  ## Keys that can't be bound: modifiers on their own, locks, and Escape,
  ## which always closes dialogs and leaves full screen.
  Unbindable = {KeyLeftShift, KeyRightShift, KeyLeftControl, KeyRightControl,
                KeyLeftAlt, KeyRightAlt, KeyLeftSuper, KeyRightSuper, KeyCapsLock,
                KeyNumLock, KeyEscape}
  BindableKeys* = {Key0 .. NumpadEqual} - Unbindable

proc keyName*(b: Button): string =
  case b
  of Key0 .. Key9: $(b.ord - Key0.ord)
  of KeyA .. KeyZ: $chr(ord('A') + b.ord - KeyA.ord)
  of KeyF1 .. KeyF12: "F" & $(b.ord - KeyF1.ord + 1)
  of Numpad0 .. Numpad9: "Numpad " & $(b.ord - Numpad0.ord)
  of KeyBacktick: "`"
  of KeyMinus: "-"
  of KeyEqual: "="
  of KeyBackspace: "Backspace"
  of KeyTab: "Tab"
  of KeyLeftBracket: "["
  of KeyRightBracket: "]"
  of KeyBackslash: "\\"
  of KeySemicolon: ";"
  of KeyApostrophe: "'"
  of KeyEnter: "Enter"
  of KeyComma: ","
  of KeyPeriod: "."
  of KeySlash: "/"
  of KeySpace: "Space"
  of KeyMenu: "Menu"
  of KeyDelete: "Delete"
  of KeyHome: "Home"
  of KeyEnd: "End"
  of KeyInsert: "Insert"
  of KeyPageUp: "Page Up"
  of KeyPageDown: "Page Down"
  of KeyUp: "Up"
  of KeyDown: "Down"
  of KeyLeft: "Left"
  of KeyRight: "Right"
  of KeyPrintScreen: "Print Screen"
  of KeyScrollLock: "Scroll Lock"
  of KeyPause: "Pause"
  of NumpadDecimal: "Numpad ."
  of NumpadEnter: "Numpad Enter"
  of NumpadAdd: "Numpad +"
  of NumpadSubtract: "Numpad -"
  of NumpadMultiply: "Numpad *"
  of NumpadDivide: "Numpad /"
  of NumpadEqual: "Numpad ="
  else: ""

proc shortKeyName*(b: Button): string =
  ## Compact form for the status bar's key caps.
  case b
  of KeyUp: "↑"
  of KeyDown: "↓"
  of KeyLeft: "←"
  of KeyRight: "→"
  of KeyPageUp: "PgUp"
  of KeyPageDown: "PgDn"
  of KeyInsert: "Ins"
  of KeyDelete: "Del"
  of KeyPrintScreen: "PrtSc"
  of KeyScrollLock: "ScrLk"
  of Numpad0 .. NumpadEqual: keyName(b).replace("Numpad ", "Num")
  else: keyName(b)

proc `$`*(k: KeyCombo): string =
  if k.key == ButtonUnknown: return ""
  if kmCtrl in k.mods: result.add "Ctrl+"
  if kmShift in k.mods: result.add "Shift+"
  if kmAlt in k.mods: result.add "Alt+"
  result.add keyName(k.key)

proc parseCombo*(s: string): KeyCombo =
  ## "Ctrl+Shift+O" -> combo; anything unreadable is no key.
  var rest = s.strip
  while true:
    let low = rest.toLowerAscii
    if low.startsWith("ctrl+"): result.mods.incl kmCtrl; rest = rest[5 .. ^1]
    elif low.startsWith("shift+"): result.mods.incl kmShift; rest = rest[6 .. ^1]
    elif low.startsWith("alt+"): result.mods.incl kmAlt; rest = rest[4 .. ^1]
    else: break
  for b in BindableKeys:
    if cmpIgnoreCase(keyName(b), rest) == 0:
      result.key = b
      return
  result = KeyCombo()

proc parseCombos*(s: string): seq[KeyCombo] =
  for part in s.split('|'):
    let k = parseCombo(part)
    if k.key != ButtonUnknown and k notin result: result.add k

proc defaults*(a: KeyAction): seq[KeyCombo] = parseCombos(Actions[a].default)

proc combos*(c: Config, a: KeyAction): seq[KeyCombo] =
  parseCombos(c.keys.getOrDefault($a, Actions[a].default))

proc keyText*(c: Config, a: KeyAction): string =
  ## The action's first key as menus show it, "" when it has none.
  let ks = c.combos(a)
  if ks.len > 0: $ks[0] else: ""

proc keysText*(c: Config, a: KeyAction, sep = " / "): string =
  ## All of the action's keys, "Home / 0".
  c.combos(a).mapIt($it).join(sep)

proc isDefault*(c: Config, a: KeyAction): bool =
  c.combos(a) == a.defaults

proc setCombos*(c: var Config, a: KeyAction, ks: seq[KeyCombo]) =
  ## Stores only what differs from the defaults.
  if ks == a.defaults: c.keys.del($a)
  else: c.keys[$a] = ks.mapIt($it).join("|")

proc setCombo*(c: var Config, a: KeyAction, k: KeyCombo) =
  ## Makes k the action's only key (none for an empty combo).
  c.setCombos(a, if k.key == ButtonUnknown: @[] else: @[k])

proc removeCombo*(c: var Config, a: KeyAction, k: KeyCombo) =
  c.setCombos(a, c.combos(a).filterIt(it != k))

proc actionsUsing*(c: Config, k: KeyCombo): seq[KeyAction] =
  if k.key == ButtonUnknown: return
  for a in KeyAction:
    if k in c.combos(a): result.add a

proc keyClashes*(c: Config): set[KeyAction] =
  ## The commands sharing a key with another command.
  var seen: seq[(KeyCombo, KeyAction)]
  for a in KeyAction:
    for k in c.combos(a):
      for (other, b) in seen:
        if other == k: result.incl {a, b}
      seen.add (k, a)

proc heldMods*(w: Window): set[KeyMod] =
  if w.buttonDown[KeyLeftControl] or w.buttonDown[KeyRightControl]: result.incl kmCtrl
  if w.buttonDown[KeyLeftShift] or w.buttonDown[KeyRightShift]: result.incl kmShift
  if w.buttonDown[KeyLeftAlt] or w.buttonDown[KeyRightAlt]: result.incl kmAlt

proc pressedKey*(w: Window): Button =
  ## A bindable key pressed this frame, or ButtonUnknown.
  for b in BindableKeys:
    if w.buttonPressed[b]: return b
  ButtonUnknown

proc pressedAction*(c: Config, w: Window): tuple[ok: bool, action: KeyAction] =
  ## The command whose key combination was pressed this frame, if any. The
  ## modifiers must match exactly; Enter also answers to Numpad Enter.
  let pressed = w.buttonPressed
  if pressed.len == 0: return
  let mods = w.heldMods
  for a in KeyAction:
    for k in c.combos(a):
      if k.mods != mods: continue
      if pressed[k.key] or (k.key == KeyEnter and pressed[NumpadEnter]):
        return (true, a)

# --- search ----------------------------------------------------------------

const
  ## Words that mean the same thing when searching for a command.
  Synonyms = [
    @["move", "pan", "grab", "nudge"],
    @["zoom", "scale", "size", "resize", "magnify"],
    @["repeat", "replay", "loop"],
    @["jump", "seek", "skip", "go to"],
    @["play", "pause", "resume"],
    @["stop", "halt"],
    @["volume", "loud", "sound"],
    @["mute", "silence", "quiet"],
    @["subtitle", "sub", "caption", "cc"],
    @["audio", "sound", "dub", "language"],
    @["screenshot", "snapshot", "capture", "picture"],
    @["full screen", "fullscreen", "maximize"],
    @["exit", "quit"],
    @["close", "unload", "eject"],
    @["open", "load", "browse"],
    @["rotate", "turn", "spin", "degrees", "angle"],
    @["faster", "speed", "rate", "accelerate"],
    @["slower", "speed", "rate", "slow motion"],
    @["frame", "step"],
    @["bookmark", "mark", "marker"],
    @["chapter", "section", "part"],
    @["file", "media"],
    @["playlist", "queue", "list"],
    @["undo", "revert"],
    @["tab", "playlist"],
    @["options", "settings", "preferences", "config"],
    @["properties", "info", "information", "details", "metadata"],
    @["keyboard shortcuts", "help", "keys", "hotkeys"],
    @["osd", "overlay", "on-screen"],
    @["beginning", "start", "0%", "rewind"],
    @["copy", "clipboard"],
    @["bigger", "larger", "increase"],
    @["smaller", "decrease"],
    @["align", "position", "place"],
    @["controls", "buttons", "toolbar"],
    @["status", "status bar"],
    @["timestamp", "time"]]
  ## Words that also find other commands, but not the other way round.
  Aliases = [
    ("reset", @["center", "0 degrees", "restore", "default"]),
    ("restore", @["reset"]),
    ("zoom", @["width", "height"]),
    ("scale", @["width", "height"]),
    ("next", @["forward"]),
    ("previous", @["back", "prior"]),
    ("hide", @["seek bar", "controls", "status", "playlist", "run log", "show"]),
    ("toggle", @["show", "seek bar", "controls", "status", "playlist", "run log", "full screen"])]

proc alternatives(word: string): seq[string] =
  ## word and what it stands for. A word of three letters or more also
  ## stands for the synonyms of the words it begins, for search-as-you-type.
  result = @[word]
  proc has(term: string): bool =
    term == word or (word.len >= 3 and term.startsWith(word))
  for g in Synonyms:
    if g.anyIt(has(it)):
      for t in g:
        if t notin result: result.add t
  for (w, terms) in Aliases:
    if has(w):
      for t in terms:
        if t notin result: result.add t

proc hasWordStart(hay, term: string): bool =
  ## term occurs in hay at the start of a word ("move" in "Move up", not in
  ## "Remove").
  var i = hay.find(term)
  while i >= 0:
    if i == 0 or not hay[i - 1].isAlphaNumeric: return true
    i = hay.find(term, i + 1)

proc matchesSearch*(c: Config, a: KeyAction, search: string): bool =
  ## Every word of search begins a word of the command's name, group or
  ## keys; or one of its synonyms begins a word of the name.
  let label = Actions[a].label.toLowerAscii
  let hay = label & " " & ($Actions[a].group).toLowerAscii & " " & c.keysText(a).toLowerAscii
  for word in strutils.splitWhitespace(search.toLowerAscii):
    if not hay.hasWordStart(word) and not word.alternatives.anyIt(label.hasWordStart(it)):
      return false
  true

proc searchScore*(label, context, search: string): int =
  ## How well search finds a menu command named label, with context (its
  ## menu path and keys) around it; -1 when it doesn't. Each word of search
  ## must begin a word of the label or the context, or one of its synonyms a
  ## word of the label; failing that, a word of three letters or more may sit
  ## inside a word of the label ("screen" in "Fullscreen"). A plural word
  ## also finds its singular ("subtitles": "Subtitle Track"). Words found in
  ## the label count most, at its start more still.
  let words = strutils.splitWhitespace(search.toLowerAscii)
  if words.len == 0: return 0
  let label = label.toLowerAscii
  let context = context.toLowerAscii
  proc forms(word: string): seq[string] =
    result = @[word]
    if word.len > 3 and word.endsWith("s"): result.add word[0 ..< ^1]
  proc bySynonym(fs: seq[string]): bool =
    for f in fs:
      if f.alternatives.anyIt(label.hasWordStart(it)): return true
  for i, word in words:
    let fs = word.forms
    if fs.anyIt(label.hasWordStart(it)):
      result += 100
      if i == 0 and fs.anyIt(label.startsWith(it)): result += 30
    elif fs.anyIt(context.hasWordStart(it)): result += 40
    elif fs.bySynonym: result += 30
    elif word.len >= 3 and fs.anyIt(it in label): result += 10
    else: return -1
  let whole = words.join(" ")
  if whole.forms.anyIt(label == it): result += 200
  elif whole.forms.anyIt(label.startsWith(it)): result += 60
