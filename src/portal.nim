## The desktop's xdg-desktop-portal over D-Bus, for what the player asks the
## desktop to do on its behalf: pick a color on the screen (screenpick) or a
## file when there's neither kdialog nor zenity (dialogs_unix). A request
## returns an object path at once; the answer comes later as a Response
## signal on it, polled once per frame, so the window keeps drawing meanwhile.
## libdbus is loaded at run time: without it, a session bus or the portal,
## requests simply fail.

when not defined(windows):
  import std/dynlib

  type
    DBusError* = object
      name*, message*: cstring
      bits: cuint
      padding: pointer
    Iter* = array[16, uint64]  ## DBusMessageIter (72 bytes on 64-bit), opaque
    Conn = pointer
    Msg* = pointer

  const
    BusSession = 0.cint
    TypeInvalid* = 0.cint
    TypeByte* = 'y'.cint
    TypeBool* = 'b'.cint
    TypeString* = 's'.cint
    TypeUint32* = 'u'.cint
    TypeObjectPath* = 'o'.cint
    TypeDouble* = 'd'.cint
    TypeArray* = 'a'.cint
    TypeVariant* = 'v'.cint
    TypeStruct* = 'r'.cint
    TypeDictEntry* = 'e'.cint
    TimeoutMs = 5000.cint
    Dest = "org.freedesktop.portal.Desktop"
    Request = "org.freedesktop.portal.Request"

  var
    lib: LibHandle
    errorInit: proc (e: ptr DBusError) {.cdecl.}
    errorFree: proc (e: ptr DBusError) {.cdecl.}
    busGetPrivate: proc (kind: cint, e: ptr DBusError): Conn {.cdecl.}
    setExitOnDisconnect: proc (c: Conn, exit: cint) {.cdecl.}
    addMatch: proc (c: Conn, rule: cstring, e: ptr DBusError) {.cdecl.}
    newMethodCall: proc (dest, path, iface, meth: cstring): Msg {.cdecl.}
    getArgs: proc (m: Msg, e: ptr DBusError, first: cint): cint {.cdecl, varargs.}
    sendBlocking: proc (c: Conn, m: Msg, timeout: cint, e: ptr DBusError): Msg {.cdecl.}
    readWrite: proc (c: Conn, timeout: cint): cint {.cdecl.}
    popMessage: proc (c: Conn): Msg {.cdecl.}
    isSignal: proc (m: Msg, iface, name: cstring): cint {.cdecl.}
    getPath: proc (m: Msg): cstring {.cdecl.}
    unref*: proc (m: Msg) {.cdecl.}
    iterInit*: proc (m: Msg, it: ptr Iter): cint {.cdecl.}
    iterInitAppend: proc (m: Msg, it: ptr Iter) {.cdecl.}
    iterAppendBasic*: proc (it: ptr Iter, kind: cint, value: pointer): cint {.cdecl.}
    iterOpen*: proc (it: ptr Iter, kind: cint, sig: cstring, sub: ptr Iter): cint {.cdecl.}
    iterClose*: proc (it: ptr Iter, sub: ptr Iter): cint {.cdecl.}
    iterArgType*: proc (it: ptr Iter): cint {.cdecl.}
    iterRecurse*: proc (it: ptr Iter, sub: ptr Iter) {.cdecl.}
    iterNext*: proc (it: ptr Iter): cint {.cdecl.}
    iterGetBasic*: proc (it: ptr Iter, value: pointer) {.cdecl.}

    conn: Conn
    failed: bool       ## no libdbus or no session bus; don't retry
    pending: seq[Msg]  ## Responses popped while polling for another request

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
    sym(setExitOnDisconnect, "dbus_connection_set_exit_on_disconnect")
    sym(addMatch, "dbus_bus_add_match")
    sym(newMethodCall, "dbus_message_new_method_call")
    sym(getArgs, "dbus_message_get_args")
    sym(sendBlocking, "dbus_connection_send_with_reply_and_block")
    sym(readWrite, "dbus_connection_read_write")
    sym(popMessage, "dbus_connection_pop_message")
    sym(isSignal, "dbus_message_is_signal")
    sym(getPath, "dbus_message_get_path")
    sym(unref, "dbus_message_unref")
    sym(iterInit, "dbus_message_iter_init")
    sym(iterInitAppend, "dbus_message_iter_init_append")
    sym(iterAppendBasic, "dbus_message_iter_append_basic")
    sym(iterOpen, "dbus_message_iter_open_container")
    sym(iterClose, "dbus_message_iter_close_container")
    sym(iterArgType, "dbus_message_iter_get_arg_type")
    sym(iterRecurse, "dbus_message_iter_recurse")
    sym(iterNext, "dbus_message_iter_next")
    sym(iterGetBasic, "dbus_message_iter_get_basic")
    true

  proc connect(): bool =
    ## A connection of its own: the shared one belongs to the inhibitor's
    ## blocking calls, and this one pops every message that comes in.
    if conn != nil: return true
    if failed: return false
    if not loadDbus():
      failed = true
      return false
    var err: DBusError
    errorInit(addr err)
    conn = busGetPrivate(BusSession, addr err)
    if conn == nil:
      stderr.writeLine "portal: no session bus: ", err.message
      errorFree(addr err)
      failed = true
      return false
    setExitOnDisconnect(conn, 0)
    # Before any call: the answer may come before the call returns its path.
    addMatch(conn, "type='signal',sender='" & Dest & "',interface='" & Request &
      "',member='Response'", addr err)
    if err.name != nil:
      stderr.writeLine "portal: ", err.message
      errorFree(addr err)
    true

  proc request*(iface, meth: string, args: proc (it: ptr Iter)): string =
    ## Calls org.freedesktop.portal.<iface>.<meth>, `args` appending its
    ## arguments; the request's object path, for pollResponse, or "" when the
    ## desktop can't be asked.
    if not connect(): return ""
    let msg = newMethodCall(Dest, "/org/freedesktop/portal/desktop",
      cstring("org.freedesktop.portal." & iface), cstring(meth))
    if msg == nil: return ""
    var it: Iter
    iterInitAppend(msg, addr it)
    args(addr it)
    var err: DBusError
    errorInit(addr err)
    let reply = sendBlocking(conn, msg, TimeoutMs, addr err)
    unref(msg)
    if reply == nil:
      stderr.writeLine "portal: ", iface, ".", meth, ": ", err.message
      errorFree(addr err)
      return ""
    var path: cstring
    if getArgs(reply, addr err, TypeObjectPath, addr path, TypeInvalid) == 0:
      stderr.writeLine "portal: ", iface, ".", meth, ": ", err.message
      errorFree(addr err)
      unref(reply)
      return ""
    result = $path
    unref(reply)

  proc pollResponse*(handle: string): Msg =
    ## The Response(u response, a{sv} results) to the request at `handle`
    ## once it came, else nil; the caller unrefs it.
    if handle.len == 0 or conn == nil: return nil
    discard readWrite(conn, 0)
    while true:
      let m = popMessage(conn)
      if m == nil: break
      if isSignal(m, Request, "Response") != 0: pending.add m
      else: unref(m)
    for i, m in pending:
      if $getPath(m) == handle:
        pending.delete(i)
        return m

  proc appendString*(it: ptr Iter, s: string) =
    var c = cstring(s)
    discard iterAppendBasic(it, TypeString, addr c)

  template dictEntry*(opts: ptr Iter, key, sig: string, body: untyped) =
    ## An a{sv} entry: `body` appends the value through `value` (a ptr Iter).
    block:
      var entry, v: Iter
      discard iterOpen(opts, TypeDictEntry, nil, addr entry)
      appendString(addr entry, key)
      discard iterOpen(addr entry, TypeVariant, sig, addr v)
      let value {.inject.} = addr v
      body
      discard iterClose(addr entry, addr v)
      discard iterClose(opts, addr entry)

  proc responseCode*(m: Msg, results: var Iter): uint32 =
    ## Response's code (0 success, 1 cancelled, 2 failed), with `results`
    ## on the a{sv} that follows it.
    var it: Iter
    if iterInit(m, addr it) == 0 or iterArgType(addr it) != TypeUint32: return 2
    iterGetBasic(addr it, addr result)
    if iterNext(addr it) == 0 or iterArgType(addr it) != TypeArray: return 2
    iterRecurse(addr it, addr results)

  proc findResult*(results: ptr Iter, key: string, value: var Iter): bool =
    ## Puts `value` on the variant's content under `key` in a{sv} results.
    while iterArgType(results) == TypeDictEntry:
      var entry: Iter
      iterRecurse(results, addr entry)
      var k: cstring
      iterGetBasic(addr entry, addr k)
      if $k == key and iterNext(addr entry) != 0 and iterArgType(addr entry) == TypeVariant:
        iterRecurse(addr entry, addr value)
        return true
      discard iterNext(results)
