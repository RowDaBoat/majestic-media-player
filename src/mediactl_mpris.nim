## MPRIS (org.mpris.MediaPlayer2) on the session bus, included by mediactl.nim.
## Plasma ties a player to its window by the process id and DesktopEntry.
## libdbus is loaded at run time: without it (or a session bus) this is a no-op.
## The connection is private, so inhibit_dbus's blocking calls on the shared
## one can't take messages meant for this one. It closes as the process exits,
## which also gives up the bus name.

import std/[dynlib, os, unicode]

type
  DBusError = object
    name, message: cstring
    bits: cuint
    padding: pointer
  Conn = pointer
  Msg = pointer
  Iter = array[16, pointer]  ## DBusMessageIter: 72 bytes, opaque, kept on the stack

  MediaControls* = ref object
    conn: Conn
    named: bool              ## on the bus under the player's name, see update
    state: MediaState
    trackNo: int             ## makes mpris:trackid, one per file opened
    stateAt: float           ## when state.position was taken
    pending: seq[MediaCommand]

const
  BusSession = 0.cint
  NameDoNotQueue = 4.cuint
  NamePrimaryOwner = 1.cint
  MsgMethodCall = 1.cint
  TArray = 'a'.cint
  TBool = 'b'.cint
  TDict = 'e'.cint
  TDouble = 'd'.cint
  TInt64 = 'x'.cint
  TPath = 'o'.cint
  TString = 's'.cint
  TVariant = 'v'.cint
  ObjectPath = "/org/mpris/MediaPlayer2"
  RootIface = "org.mpris.MediaPlayer2"
  PlayerIface = "org.mpris.MediaPlayer2.Player"
  PropsIface = "org.freedesktop.DBus.Properties"
  IntrospectIface = "org.freedesktop.DBus.Introspectable"
  NoTrack = "/org/mpris/MediaPlayer2/TrackList/NoTrack"
  RootProps = ["CanQuit", "CanRaise", "HasTrackList", "Identity", "DesktopEntry",
               "SupportedUriSchemes", "SupportedMimeTypes"]
  PlayerProps = ["PlaybackStatus", "Rate", "Metadata", "Volume", "Position", "MinimumRate",
                 "MaximumRate", "CanGoNext", "CanGoPrevious", "CanPlay", "CanPause",
                 "CanSeek", "CanControl"]
  SeekedMargin = 0.5  ## seconds off the expected position that count as a seek
  Introspection = """<node>
<interface name="org.freedesktop.DBus.Introspectable">
<method name="Introspect"><arg type="s" direction="out"/></method></interface>
<interface name="org.freedesktop.DBus.Properties">
<method name="Get"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
<method name="GetAll"><arg type="s" direction="in"/><arg type="a{sv}" direction="out"/></method>
<method name="Set"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/></method>
<signal name="PropertiesChanged"><arg type="s"/><arg type="a{sv}"/><arg type="as"/></signal></interface>
<interface name="org.mpris.MediaPlayer2">
<method name="Raise"/><method name="Quit"/>
<property name="CanQuit" type="b" access="read"/><property name="CanRaise" type="b" access="read"/>
<property name="HasTrackList" type="b" access="read"/><property name="Identity" type="s" access="read"/>
<property name="DesktopEntry" type="s" access="read"/><property name="SupportedUriSchemes" type="as" access="read"/>
<property name="SupportedMimeTypes" type="as" access="read"/></interface>
<interface name="org.mpris.MediaPlayer2.Player">
<method name="Next"/><method name="Previous"/><method name="Pause"/><method name="PlayPause"/>
<method name="Stop"/><method name="Play"/>
<method name="Seek"><arg type="x" direction="in"/></method>
<method name="SetPosition"><arg type="o" direction="in"/><arg type="x" direction="in"/></method>
<method name="OpenUri"><arg type="s" direction="in"/></method>
<signal name="Seeked"><arg type="x"/></signal>
<property name="PlaybackStatus" type="s" access="read"/><property name="Rate" type="d" access="read"/>
<property name="Metadata" type="a{sv}" access="read"/><property name="Volume" type="d" access="readwrite"/>
<property name="Position" type="x" access="read"/><property name="MinimumRate" type="d" access="read"/>
<property name="MaximumRate" type="d" access="read"/><property name="CanGoNext" type="b" access="read"/>
<property name="CanGoPrevious" type="b" access="read"/><property name="CanPlay" type="b" access="read"/>
<property name="CanPause" type="b" access="read"/><property name="CanSeek" type="b" access="read"/>
<property name="CanControl" type="b" access="read"/></interface></node>"""

var
  lib: LibHandle
  errorInit: proc (e: ptr DBusError) {.cdecl.}
  errorFree: proc (e: ptr DBusError) {.cdecl.}
  busGetPrivate: proc (kind: cint, e: ptr DBusError): Conn {.cdecl.}
  requestName: proc (c: Conn, name: cstring, flags: cuint, e: ptr DBusError): cint {.cdecl.}
  setExitOnDisconnect: proc (c: Conn, exit: cint) {.cdecl.}
  readWrite: proc (c: Conn, timeout: cint): cint {.cdecl.}
  popMessage: proc (c: Conn): Msg {.cdecl.}
  send: proc (c: Conn, m: Msg, serial: pointer): cint {.cdecl.}
  flush: proc (c: Conn) {.cdecl.}
  connUnref: proc (c: Conn) {.cdecl.}
  connClose: proc (c: Conn) {.cdecl.}
  newReturn: proc (call: Msg): Msg {.cdecl.}
  newError: proc (call: Msg, name, text: cstring): Msg {.cdecl.}
  newSignal: proc (path, iface, name: cstring): Msg {.cdecl.}
  msgType: proc (m: Msg): cint {.cdecl.}
  msgInterface: proc (m: Msg): cstring {.cdecl.}
  msgMember: proc (m: Msg): cstring {.cdecl.}
  msgUnref: proc (m: Msg) {.cdecl.}
  iterInit: proc (m: Msg, it: ptr Iter): cint {.cdecl.}
  iterInitAppend: proc (m: Msg, it: ptr Iter) {.cdecl.}
  iterArgType: proc (it: ptr Iter): cint {.cdecl.}
  iterGet: proc (it: ptr Iter, value: pointer) {.cdecl.}
  iterNext: proc (it: ptr Iter): cint {.cdecl.}
  iterRecurse: proc (it, sub: ptr Iter) {.cdecl.}
  iterAppend: proc (it: ptr Iter, kind: cint, value: pointer): cint {.cdecl.}
  iterOpen: proc (it: ptr Iter, kind: cint, sig: cstring, sub: ptr Iter): cint {.cdecl.}
  iterClose: proc (it, sub: ptr Iter): cint {.cdecl.}

proc loadDbus(): bool =
  if lib != nil: return true
  lib = loadLib("libdbus-1.so.3")
  if lib == nil: lib = loadLib("libdbus-1.so")
  if lib == nil: return false
  template sym(v, name: untyped) =
    v = cast[typeof(v)](lib.symAddr(name))
    if v == nil:
      unloadLib(lib)
      lib = nil
      return false
  sym(errorInit, "dbus_error_init")
  sym(errorFree, "dbus_error_free")
  sym(busGetPrivate, "dbus_bus_get_private")
  sym(requestName, "dbus_bus_request_name")
  sym(setExitOnDisconnect, "dbus_connection_set_exit_on_disconnect")
  sym(readWrite, "dbus_connection_read_write")
  sym(popMessage, "dbus_connection_pop_message")
  sym(send, "dbus_connection_send")
  sym(flush, "dbus_connection_flush")
  sym(connUnref, "dbus_connection_unref")
  sym(connClose, "dbus_connection_close")
  sym(newReturn, "dbus_message_new_method_return")
  sym(newError, "dbus_message_new_error")
  sym(newSignal, "dbus_message_new_signal")
  sym(msgType, "dbus_message_get_type")
  sym(msgInterface, "dbus_message_get_interface")
  sym(msgMember, "dbus_message_get_member")
  sym(msgUnref, "dbus_message_unref")
  sym(iterInit, "dbus_message_iter_init")
  sym(iterInitAppend, "dbus_message_iter_init_append")
  sym(iterArgType, "dbus_message_iter_get_arg_type")
  sym(iterGet, "dbus_message_iter_get_basic")
  sym(iterNext, "dbus_message_iter_next")
  sym(iterRecurse, "dbus_message_iter_recurse")
  sym(iterAppend, "dbus_message_iter_append_basic")
  sym(iterOpen, "dbus_message_iter_open_container")
  sym(iterClose, "dbus_message_iter_close_container")
  true

proc newMediaControls*(window: Window): MediaControls =
  result = MediaControls()
  if not loadDbus(): return
  var err: DBusError
  errorInit(addr err)
  let conn = busGetPrivate(BusSession, addr err)
  if conn == nil:
    stderr.writeLine "mpris: no session bus: ", err.message
    errorFree(addr err)
    return
  # A bus connection exits the process when the bus goes away by default.
  setExitOnDisconnect(conn, 0)
  result.conn = conn

proc disconnect(c: MediaControls) =
  connClose(c.conn)
  connUnref(c.conn)
  c.conn = nil

proc takeName(c: MediaControls) =
  ## Named per process, as MPRIS asks of players with several instances.
  var err: DBusError
  errorInit(addr err)
  let name = RootIface & ".majestic_media_player.instance" & $getCurrentProcessId()
  if requestName(c.conn, name.cstring, NameDoNotQueue, addr err) == NamePrimaryOwner:
    c.named = true
  else:
    stderr.writeLine "mpris: cannot own ", name
    errorFree(addr err)
    c.disconnect()

# --- writing values -------------------------------------------------------------

proc putBasic[T](it: var Iter, kind: cint, value: T) =
  var v = value
  discard iterAppend(addr it, kind, addr v)

proc putText(it: var Iter, kind: cint, s: string) =
  ## D-Bus refuses invalid UTF-8, which a Linux file name may be.
  var clean = s
  while true:
    let bad = clean.validateUtf8
    if bad < 0: break
    clean[bad] = '?'
  it.putBasic(kind, clean.cstring)

template container(it: var Iter, kind: cint, sig: cstring, sub, body: untyped) =
  var sub: Iter
  discard iterOpen(addr it, kind, sig, addr sub)
  body
  discard iterClose(addr it, addr sub)

template variant(it: var Iter, sig: cstring, sub, body: untyped) =
  it.container(TVariant, sig, sub, body)

template dictEntry(dict: var Iter, key: string, sig: cstring, sub, body: untyped) =
  dict.container(TDict, nil, entry):
    entry.putText(TString, key)
    entry.variant(sig, sub, body)

proc putBoolVariant(it: var Iter, on: bool) =
  it.variant("b", sub): sub.putBasic(TBool, uint32(on))

proc putDoubleVariant(it: var Iter, v: float) =
  it.variant("d", sub): sub.putBasic(TDouble, v.cdouble)

proc putStrings(it: var Iter, items: openArray[string]) =
  it.container(TArray, "s", arr):
    for s in items: arr.putText(TString, s)

proc micros(seconds: float): int64 = int64(seconds * 1e6)

proc trackId(c: MediaControls): string =
  if c.state.url.len == 0: NoTrack else: "/org/mpris/MediaPlayer2/Track/" & $c.trackNo

proc putMetadata(c: MediaControls, it: var Iter) =
  let s = c.state
  it.variant("a{sv}", sub):
    sub.container(TArray, "{sv}", dict):
      dict.dictEntry("mpris:trackid", "o", v): v.putText(TPath, c.trackId)
      if s.duration > 0:
        dict.dictEntry("mpris:length", "x", v): v.putBasic(TInt64, s.duration.micros)
      if s.url.len > 0:
        dict.dictEntry("xesam:url", "s", v): v.putText(TString, s.url)
      if s.title.len > 0:
        dict.dictEntry("xesam:title", "s", v): v.putText(TString, s.title)
      if s.album.len > 0:
        dict.dictEntry("xesam:album", "s", v): v.putText(TString, s.album)
      if s.artist.len > 0:
        dict.dictEntry("xesam:artist", "as", v): v.putStrings([s.artist])

proc putProp(c: MediaControls, it: var Iter, name: string) =
  let s = c.state
  case name
  of "CanQuit", "CanRaise", "CanControl": it.putBoolVariant(true)
  of "HasTrackList": it.putBoolVariant(false)
  of "Identity":
    it.variant("s", v): v.putText(TString, "Majestic Media Player")
  of "DesktopEntry":
    it.variant("s", v): v.putText(TString, "majestic-media-player")
  of "SupportedUriSchemes", "SupportedMimeTypes":  # nothing: OpenUri is optional
    it.variant("as", v): v.putStrings([])
  of "PlaybackStatus":
    it.variant("s", v): v.putText(TString, $s.status)
  of "Rate": it.putDoubleVariant(s.rate)
  of "MinimumRate": it.putDoubleVariant(0.1)
  of "MaximumRate": it.putDoubleVariant(100)
  of "Volume": it.putDoubleVariant(s.volume)
  of "Metadata": c.putMetadata(it)
  of "Position":
    it.variant("x", v): v.putBasic(TInt64, s.position.micros)
  of "CanGoNext": it.putBoolVariant(s.canGoNext)
  of "CanGoPrevious": it.putBoolVariant(s.canGoPrevious)
  of "CanPlay": it.putBoolVariant(s.canPlay)
  of "CanPause": it.putBoolVariant(s.canPause)
  of "CanSeek": it.putBoolVariant(s.canSeek)
  else: discard

proc putProps(c: MediaControls, it: var Iter, names: openArray[string]) =
  ## An a{sv} of the named properties.
  it.container(TArray, "{sv}", dict):
    for name in names:
      dict.container(TDict, nil, entry):
        entry.putText(TString, name)
        c.putProp(entry, name)

# --- calls ------------------------------------------------------------------------

proc reply(c: MediaControls, m: Msg) =
  if m != nil:
    discard send(c.conn, m, nil)
    msgUnref(m)

proc replyEmpty(c: MediaControls, call: Msg) = c.reply(newReturn(call))

proc replyError(c: MediaControls, call: Msg, name, text: string) =
  c.reply(newError(call, name.cstring, text.cstring))

proc nextString(it: var Iter): string =
  ## The string at it, stepping past it; "" when it holds something else.
  let kind = iterArgType(addr it)
  if kind == TString or kind == TPath:
    var s: cstring
    iterGet(addr it, addr s)
    result = $s
  discard iterNext(addr it)

proc propNames(iface: string): seq[string] =
  case iface
  of RootIface: @RootProps
  of PlayerIface: @PlayerProps
  else: @[]

proc handleProps(c: MediaControls, call: Msg, member: string) =
  var args: Iter
  if iterInit(call, addr args) == 0:
    c.replyError(call, "org.freedesktop.DBus.Error.InvalidArgs", "arguments needed")
    return
  let names = args.nextString.propNames
  case member
  of "GetAll":
    let m = newReturn(call)
    if m == nil: return
    var it: Iter
    iterInitAppend(m, addr it)
    c.putProps(it, names)
    c.reply(m)
  of "Get":
    let name = args.nextString
    if name notin names:
      c.replyError(call, "org.freedesktop.DBus.Error.UnknownProperty", name)
      return
    let m = newReturn(call)
    if m == nil: return
    var it: Iter
    iterInitAppend(m, addr it)
    c.putProp(it, name)
    c.reply(m)
  of "Set":
    let name = args.nextString
    var value: Iter
    iterRecurse(addr args, addr value)
    if name == "Volume" and iterArgType(addr value) == TDouble:
      var v: cdouble
      iterGet(addr value, addr v)
      c.pending.add MediaCommand(kind: mcVolume, value: v.float)
      c.replyEmpty(call)
    else:
      c.replyError(call, "org.freedesktop.DBus.Error.PropertyReadOnly", name)
  else:
    c.replyError(call, "org.freedesktop.DBus.Error.UnknownMethod", member)

proc handlePlayer(c: MediaControls, call: Msg, member: string) =
  proc simple(kind: MediaCommandKind) = c.pending.add MediaCommand(kind: kind)
  case member
  of "Play": simple(mcPlay)
  of "Pause": simple(mcPause)
  of "PlayPause": simple(mcPlayPause)
  of "Stop": simple(mcStop)
  of "Next": simple(mcNext)
  of "Previous": simple(mcPrevious)
  of "OpenUri": discard  # no schemes advertised
  of "Seek", "SetPosition":
    var args: Iter
    if iterInit(call, addr args) != 0:
      # A position meant for the track before is stale: the spec says to ignore it.
      let stale = member == "SetPosition" and args.nextString != c.trackId
      if iterArgType(addr args) == TInt64 and not stale:
        var us: int64
        iterGet(addr args, addr us)
        c.pending.add MediaCommand(kind: if member == "Seek": mcSeekBy else: mcSeekTo,
                                   value: us.float / 1e6)
  else:
    c.replyError(call, "org.freedesktop.DBus.Error.UnknownMethod", member)
    return
  c.replyEmpty(call)

proc handle(c: MediaControls, call: Msg) =
  let iface = $msgInterface(call)
  let member = $msgMember(call)
  case iface
  of PropsIface: c.handleProps(call, member)
  of PlayerIface: c.handlePlayer(call, member)
  of RootIface:
    case member
    of "Raise": c.pending.add MediaCommand(kind: mcRaise)
    of "Quit": c.pending.add MediaCommand(kind: mcQuit)
    else: discard
    c.replyEmpty(call)
  of IntrospectIface:
    let m = newReturn(call)
    if m == nil: return
    var it: Iter
    iterInitAppend(m, addr it)
    it.putText(TString, Introspection)
    c.reply(m)
  else:
    c.replyError(call, "org.freedesktop.DBus.Error.UnknownInterface", iface)

proc poll*(c: MediaControls): seq[MediaCommand] =
  ## Answers the calls that came in; returns what they asked of the player.
  ## Never waits on the bus.
  if c.conn == nil: return
  if readWrite(c.conn, 0) == 0:  # the bus went away
    c.disconnect()
    return
  var answered = false
  while true:
    let m = popMessage(c.conn)
    if m == nil: break
    if msgType(m) == MsgMethodCall:
      c.handle(m)
      answered = true
    msgUnref(m)
  if answered: flush(c.conn)
  result = move c.pending

# --- signals ----------------------------------------------------------------------

proc emitChanged(c: MediaControls, names: openArray[string]) =
  let m = newSignal(ObjectPath, PropsIface, "PropertiesChanged")
  if m == nil: return
  var it: Iter
  iterInitAppend(m, addr it)
  it.putText(TString, PlayerIface)
  c.putProps(it, names)
  it.putStrings([])
  c.reply(m)

proc emitSeeked(c: MediaControls) =
  let m = newSignal(ObjectPath, PlayerIface, "Seeked")
  if m == nil: return
  var it: Iter
  iterInitAppend(m, addr it)
  it.putBasic(TInt64, c.state.position.micros)
  c.reply(m)

proc update*(c: MediaControls, s: MediaState, time: float) =
  ## Tells the bus what changed since the last call. Position changes aren't
  ## signalled as it plays, only when it jumps from where it should have got to.
  ## The name is taken on the first call, so nothing can read the state before
  ## there is one: Plasma listens for changes only after reading it all, and
  ## would never hear what changed in between.
  if c.conn == nil: return
  if not c.named:
    c.state = s
    c.stateAt = time
    if s.url.len > 0: c.trackNo = 1
    c.takeName()
    return
  let o = c.state
  let newTrack = s.url != o.url
  if newTrack: inc c.trackNo
  let expected = o.position +
    (if o.status == msPlaying: (time - c.stateAt) * o.rate else: 0)
  let seeked = abs(s.position - expected) > SeekedMargin
  c.state = s
  c.stateAt = time
  var names: seq[string]
  if s.status != o.status: names.add "PlaybackStatus"
  if newTrack or s.title != o.title or s.artist != o.artist or s.album != o.album or
     s.duration != o.duration: names.add "Metadata"
  if s.rate != o.rate: names.add "Rate"
  if s.volume != o.volume: names.add "Volume"
  if s.canGoNext != o.canGoNext: names.add "CanGoNext"
  if s.canGoPrevious != o.canGoPrevious: names.add "CanGoPrevious"
  if s.canPlay != o.canPlay: names.add "CanPlay"
  if s.canPause != o.canPause: names.add "CanPause"
  if s.canSeek != o.canSeek: names.add "CanSeek"
  if names.len > 0: c.emitChanged(names)
  if seeked: c.emitSeeked()
  if names.len > 0 or seeked: flush(c.conn)
