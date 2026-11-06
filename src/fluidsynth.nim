## libfluidsynth, loaded at run time: the synthesizer MIDI files play
## through (midistream). Without it, MIDI files don't play.
##
## Settings are made after limiting FluidSynth's audio drivers to its file
## writer: creating them otherwise probes every ALSA device, which fills
## stderr with ALSA's complaints. Its log is silenced too.

import std/dynlib

type
  Settings* = pointer
  Synth* = pointer
  Api* = object
    newSettings*: proc (): Settings {.cdecl.}
    deleteSettings*: proc (s: Settings) {.cdecl.}
    setnum*: proc (s: Settings, name: cstring, v: cdouble): cint {.cdecl.}
    setint*: proc (s: Settings, name: cstring, v: cint): cint {.cdecl.}
    newSynth*: proc (s: Settings): Synth {.cdecl.}
    deleteSynth*: proc (s: Synth) {.cdecl.}
    sfload*: proc (s: Synth, path: cstring, reset: cint): cint {.cdecl.}
    noteon*: proc (s: Synth, ch, key, vel: cint): cint {.cdecl.}
    noteoff*: proc (s: Synth, ch, key: cint): cint {.cdecl.}
    cc*: proc (s: Synth, ch, num, val: cint): cint {.cdecl.}
    programChange*: proc (s: Synth, ch, prog: cint): cint {.cdecl.}
    pitchBend*: proc (s: Synth, ch, val: cint): cint {.cdecl.}
    channelPressure*: proc (s: Synth, ch, val: cint): cint {.cdecl.}
    keyPressure*: proc (s: Synth, ch, key, val: cint): cint {.cdecl.}
    sysex*: proc (s: Synth, data: cstring, len: cint, resp: cstring, resplen: ptr cint,
                  handled: ptr cint, dryrun: cint): cint {.cdecl.}
    systemReset*: proc (s: Synth): cint {.cdecl.}
    allSoundsOff*: proc (s: Synth, ch: cint): cint {.cdecl.}
    writeFloat*: proc (s: Synth, len: cint, lout: pointer, loff, lincr: cint,
                       rout: pointer, roff, rincr: cint): cint {.cdecl.}

var
  api*: Api
  tried, ok: bool

proc load*(): bool =
  ## libfluidsynth's functions, false when it's missing.
  if tried: return ok
  tried = true
  let names = when defined(windows): @["libfluidsynth-3.dll", "fluidsynth.dll"]
              elif defined(macosx): @["libfluidsynth.3.dylib", "libfluidsynth.dylib"]
              else: @["libfluidsynth.so.3", "libfluidsynth.so"]
  var lib: LibHandle
  for n in names:
    lib = loadLib(n)
    if lib != nil: break
  if lib == nil: return false
  template sym(field, name: untyped) =
    let p = lib.symAddr(name)
    if p == nil: return false
    api.field = cast[typeof(api.field)](p)
  sym newSettings, "new_fluid_settings"
  sym deleteSettings, "delete_fluid_settings"
  sym setnum, "fluid_settings_setnum"
  sym setint, "fluid_settings_setint"
  sym newSynth, "new_fluid_synth"
  sym deleteSynth, "delete_fluid_synth"
  sym sfload, "fluid_synth_sfload"
  sym noteon, "fluid_synth_noteon"
  sym noteoff, "fluid_synth_noteoff"
  sym cc, "fluid_synth_cc"
  sym programChange, "fluid_synth_program_change"
  sym pitchBend, "fluid_synth_pitch_bend"
  sym channelPressure, "fluid_synth_channel_pressure"
  sym keyPressure, "fluid_synth_key_pressure"
  sym sysex, "fluid_synth_sysex"
  sym systemReset, "fluid_synth_system_reset"
  sym allSoundsOff, "fluid_synth_all_sounds_off"
  sym writeFloat, "fluid_synth_write_float"
  let register = cast[proc (drivers: ptr cstring): cint {.cdecl.}](
    lib.symAddr("fluid_audio_driver_register"))
  if register != nil:
    var drivers = [cstring"file", nil]
    discard register(drivers[0].addr)
  let setLog = cast[proc (level: cint, f, data: pointer): pointer {.cdecl.}](
    lib.symAddr("fluid_set_log_function"))
  if setLog != nil:
    for level in 0 .. 4: discard setLog(level.cint, nil, nil)
  ok = true
  true
