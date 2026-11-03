## Picks a color anywhere on the screen (Options > Subtitles' color picker).
## On Linux the desktop does it through the xdg-desktop-portal's
## Screenshot.PickColor (KDE and GNOME show their own magnifier, on X11 and
## Wayland alike; a Wayland app can't read other windows' pixels itself).
## The answer comes later, polled once per frame (portal.nim); without
## libdbus, a session bus or the portal, picking is simply unavailable.

type
  ScreenPick* = enum
    spIdle       ## nothing asked
    spWaiting    ## the desktop is letting the user pick
    spPicked     ## a color came back
    spCancelled  ## the user backed out
    spFailed     ## the desktop couldn't do it

when defined(windows):
  proc startScreenPick*(): bool = false
  proc pollScreenPick*(rgb: var (float, float, float)): ScreenPick = spIdle
else:
  import portal

  var handle: string  ## the pending request's object path, "" when none

  proc startScreenPick*(): bool =
    ## Asks the desktop to let the user pick a color; false when it can't.
    handle = request("Screenshot", "PickColor", proc (it: ptr Iter) =
      appendString(it, "")  # no parent window handle
      var opts: Iter
      discard iterOpen(it, TypeArray, "{sv}", addr opts)  # no options
      discard iterClose(it, addr opts))
    handle.len > 0

  proc readColor(m: Msg, rgb: var (float, float, float)): ScreenPick =
    ## results["color"]: a (ddd) of 0..1.
    var results, variant, st: Iter
    let code = responseCode(m, results)
    if code == 1: return spCancelled
    if code != 0 or not findResult(addr results, "color", variant) or
       iterArgType(addr variant) != TypeStruct: return spFailed
    iterRecurse(addr variant, addr st)
    var c: array[3, float64]
    for i in 0 .. 2:
      if iterArgType(addr st) != TypeDouble: return spFailed
      iterGetBasic(addr st, addr c[i])
      discard iterNext(addr st)
    rgb = (c[0].float, c[1].float, c[2].float)
    spPicked

  proc pollScreenPick*(rgb: var (float, float, float)): ScreenPick =
    ## Once per frame after startScreenPick: spWaiting until the answer came.
    if handle.len == 0: return spIdle
    let m = pollResponse(handle)
    if m == nil: return spWaiting
    result = readColor(m, rgb)
    unref(m)
    handle = ""
