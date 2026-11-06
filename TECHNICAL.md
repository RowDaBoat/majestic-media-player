# Majestic Media Player: technical notes

## Installing

| Command | What it does |
|---|---|
| `./install.sh` | Build and install for the current user (`~/.local`, no root needed) |
| `./install.sh --system` | Build, then install for all users under `/usr/local` (uses `sudo`) |
| `./install.sh --uninstall` | Remove the per-user install (add `--system` for the system-wide one) |

The script installs any missing packages with `pacman` (on CachyOS / Arch),
builds the player and installs it. To update, `git pull` and run
`./install.sh` again.

What gets installed (`PREFIX` is `~/.local` or `/usr/local`):

- `PREFIX/bin/majestic-media-player`: the player (a single self-contained binary)
- `PREFIX/share/applications/majestic-media-player.desktop`: the launcher entry,
  which also registers the player in "Open With" for common video and audio types
- `PREFIX/share/icons/hicolor/scalable/apps/majestic-media-player.svg`: the icon

The launcher entry points to the binary by its full path, so it starts even if
`~/.local/bin` isn't on your `PATH`. Afterwards the installer refreshes the
desktop and KDE menu caches so the entry shows up without logging out.

Files can also be passed on the command line (`majestic-media-player a.mkv`),
but that's optional. Without them it opens empty and you use File ▸ Open.

## Building manually

```sh
sudo pacman -S --needed nim git base-devel mpv libx11 libxrandr kdialog
make                                   # fetches pinned deps into ./vendor, then compiles
make run                               # run from the source tree
make install                           # per-user install, same as ./install.sh
sudo make install PREFIX=/usr/local    # system-wide (run `make` as yourself first)
make install DESTDIR=pkgdir PREFIX=/usr  # staged install for packaging
```

`make uninstall` (with the same `PREFIX`) removes it again.

`make` prints one line per step (each dependency being cloned, then Nim's
module checking, C compilation and linking), each with the time elapsed since
the build started, a progress bar and the amount downloaded or compiled, so
finished steps stay on screen. In a terminal the current step's line and an
overall bar underneath update live; when the output is piped or logged, each
line is printed once its step is done.

`kdialog` provides the native file dialogs (`zenity` works as a fallback; with
neither, the desktop's own through the xdg-desktop-portal's FileChooser).
Dependencies are pinned in `deps.lock` and cloned by `tools/fetch_deps.sh`, so
builds don't depend on whatever is in `~/.nimble`.

### Windows

`./install.sh` (from Git Bash) fetches the pinned dependencies and prebuilt
libmpv, Mesa and libopenmpt (unpacked with [7-Zip](https://7-zip.org)), builds
`majestic-media-player.exe` and installs it with their DLLs and a `licenses`
folder to `%LOCALAPPDATA%\Programs\Majestic Media Player`, plus a Start menu
shortcut. `./install.sh --uninstall` removes it again.

What ships is put together by `tools/windows.sh stage DIR`, for the install and
the release zip alike. `assets/licenses/README.txt` says what each DLL is, its
license and where its source is; libopenmpt's license files come from its own
package. Update it whenever a pinned URL in `tools/windows.sh` changes:
libmpv-2.dll is GPLv3 (FFmpeg there is `--enable-gpl --enable-version3`), and
the README offers its source, so the build it names must be the one shipped.
`assets/licenses/libmpv/` holds the license files of the 89 libraries in that
libmpv build, collected once at the commits it was built from (`INDEX.txt`):
collect them again for a new libmpv.

| Command | What it does |
|---|---|
| `tools/windows.sh build` | Build `majestic-media-player.exe` in the source tree |
| `tools/windows.sh run [files]` | Build and run it |
| `tools/windows.sh debug` | Unoptimized build with stack traces |
| `tools/windows.sh install` / `uninstall` | Same as `./install.sh` / `--uninstall` |
| `tools/windows.sh stage DIR` | Copy what ships (exe, DLLs, `cpu\`, `licenses\`) into DIR |

The Run menu runs its command lines with Git for Windows' bash (set
`MMP_BASH` to use another).

### Linux AppImage

`tools/appimage.sh all` makes `majestic-media-player-VERSION-x86_64.AppImage`,
run as root in an Arch Linux container (`.github/workflows/linux.yml` does it
on every push and adds it to the release on a `v*` tag; locally:
`docker run --rm -v "$PWD:/src" -w /src docker.io/library/archlinux:latest tools/appimage.sh all`).
Vanilla Arch, not CachyOS: CachyOS's packages are built for newer CPUs
(x86-64-v3/v4) and would crash on older ones.

Every package comes from the Arch Linux Archive as of `ARCH_DATE` in the
script, as the Windows build pins its libmpv URL: the same mpv, FFmpeg and
Mesa every build. The pinned
[quick-sharun](https://github.com/pkgforge-dev/Anylinux-AppImages) (commit and
checksum in the script) puts every library the player loads in the AppImage,
glibc and Mesa included, with sharun to load them, so it runs on any
distribution whatever its own versions (NVIDIA's driver is the system's).
It also bundles ffmpeg, ffprobe and curl, which the player starts and a
desktop may lack; the AppImage's `bin` comes first on its `PATH`. Programs the
player starts from the system get the system's environment back
(anylinux.so), not the AppImage's library paths.

Running from an AppImage (`src/appimage.nim`: `APPIMAGE` set and the program
inside `APPDIR`), what outlives the temporary mount points at the
`.AppImage` file instead: a restart (onto the CPU, into an update), Help >
Check for Updates (downloads the release's `-x86_64.AppImage` next to it and
renames it over it, same name, so launchers and associations stay valid), and
the launcher entry Options > Formats writes to
`~/.local/share/applications` before making it the default (marked
`X-Majestic-AppImage`; one from `make install` or a package is left alone).
Startup rewrites a marked entry when the AppImage moved.

Licenses ship in the AppImage's `share/licenses/majestic-media-player/`,
copied from `assets/licenses` by the script's `stage`: the files the Windows
build has where they cover a package (`libmpv/<library>`, `Mesa.txt`,
`LLVM.txt`, `mpv-Copyright.txt`, `GPL-3.0.txt`), and `assets/licenses/appimage/`
for what only the AppImage holds: `README.txt` (the AppImage's, shipped at the
top), `INDEX.txt` (each package, its version, license and which file covers
it), `AppImage-tools.txt` (sharun, uruntime, anylinux.so: MIT), a folder per
package Arch ships license files for, `common/` (standard texts for packages
without any) and `manual/` (notices written by hand from a package's source,
kept by the script). Nothing is fetched to make it: `tools/appimage.sh licenses`
rewrites the folder from the installed packages, after a bump of `ARCH_DATE`;
commit what it writes. The build fails when the AppImage holds a package (or
version) `INDEX.txt` lacks or has no text for, or a non-redistributable one;
the failed run's `licenses-appimage` artifact is the folder rewritten for what
it held, to commit.

| Command | What it does |
|---|---|
| `tools/appimage.sh deps` | Install the pinned packages (the archive is slow: retried) |
| `tools/appimage.sh build` | Compile, then install the binary to `/usr/bin` for quick-sharun |
| `tools/appimage.sh bundle NAME` | Make `NAME.AppImage` |
| `tools/appimage.sh all [NAME]` | The three of them |
| `tools/appimage.sh licenses [APPDIR]` | Rewrite `assets/licenses/appimage/` for the packages in APPDIR, or else those it would hold |

## Notes

- Windowing helpers Windy lacks live in `src/xwin_x11.nim` and
  `src/xwin_win32.nim`, behind the same interface (`src/xwin.nim`).
- Windy (Silky's windowing layer) is X11-only on Linux, so the player runs
  through XWayland on a Wayland session. Window dragging, always-on-top and
  aspect-locked resizing use EWMH/ICCCM hints, which KWin honours.
- Windows set `_NET_WM_SYNC_REQUEST_COUNTER` before they are mapped
  (`patches/windy.patch`). KWin on an X11 session (Plasma 5 distributions,
  Linux Mint with KDE) reads the counter while managing a window and shows the
  window after the client answers a first sync request. A counter set after
  mapping made it wait for an answer to a request it never sent, so the window
  stayed invisible (only taskbar thumbnails showed it). Format-32 properties
  are written as C longs, one per item: counting 4-byte items doubled the
  count and read past the data (the counter used to look like an extended,
  two-counter one to Mutter/Muffin).
- Menus are override-redirect X11 popup windows (no frame, taskbar entry or
  focus, like a toolkit's menus), so they can extend past the main window.
  They are drawn with the main window's GL context and the same Silky atlas.
- The command palette (F3, Help > Command Palette; `paletteOverlay` and its neighbours) searches
  one menu tree, `paletteRoot`, rebuilt every frame like the menus (about 0.4 ms), so checkmarks
  and dynamic lists are always current. The tree holds the menu bar's menus; the right-click
  menu's contextual (purple) items under "Right-Click Menu"; "Controls", with every controls bar
  button (as a wide bar shows them) and the menus their right-click opens (Repeat Options,
  Quality, ReplayGain); "Status Bar", with the timestamp's right-click menu ("Timestamp") and the bar's own;
  "Playlist › Playing Item", the playlist's right-click menu on the entry playing, built with its
  playlist moved into the live fields (`stashTab`/`unstashTab`, and back) and that entry alone
  selected, each item doing `showPlaying` before its action, as right-clicking it would (left
  out while synchronized and another playlist is shown, as showing that one is refused); and the
  commands that only have a key (`PaletteKeyOnly`, run through `runAction`), filed under the
  menu of their key group. The right-click menus come from `buildMenu` called with `ctxMenu` set
  to each one, restored afterwards.
  Submenus are palette items too: running one opens it in the palette (`palTrail`, the label and
  index of each submenu down to it, so one whose label shows a value, "Pre-amp: +3 dB", is still
  found after picking a value in it), and Backspace in an empty search or the button left of the
  field goes back (`palBack`, the search as it was). Lists (`MenuNode.listed`, set with
  `markListed` in `buildMenu`: recent files, tracks, chapters, bookmarks, players, command lines,
  visualizer presets, stream qualities, numeric steps) show only inside their own submenu; other
  items also show in searches from above. A column (Quality's Video and Audio) counts as part of
  its menu. With nothing typed it lists the open submenu's own items, at the top after the
  commands run lately (`paletteRecent` in the config, keyed "Menu › Item").
  Matching is `keymap.searchScore`: every typed word (or its singular) must begin a word of the
  label or of its path and keys, or stand for a synonym of a label word (the F1 window's synonym
  tables); label matches rank first, submenus get a bonus, and the track submenus
  (`PaletteFavored`) a bigger one, so "audio" and "subtitle" find them first.
  Enter on a check or radio item runs it and keeps the palette open; any other command closes it
  first, since it may open a dialog. The last search is kept and selected when it opens again.
  It is drawn inside the main window (not a popup window like the menus), so its text field is
  an ordinary `textField` taking the main window's keys; `handleKeys` hands every key to
  `paletteKeys` while it is open.
- vsync is disabled on purpose: with NVIDIA under XWayland, a vsync'd
  `glXSwapBuffers` can block for seconds when the window is hidden. Video frames
  are paced from mpv's frame timing instead; the compositor prevents tearing.
- On Windows, menus are never-activated popup windows sharing the main GL
  context the same way; moving the window by the video is done by the player
  itself, so playback doesn't stall during a drag.
- Settings and recent files live in `~/.config/majestic-media-player/config.json`
  (`%APPDATA%\majestic-media-player\config.json` on Windows);
  remembered playback positions (View ▸ Options ▸ Player) in `positions.json` next to it.
  Each running player saves the whole config, so only the one whose Options
  changed the keys writes them: the others keep the file's keys and pick them up.
- The playlist remembers the M3U/PLS file it was loaded from or last saved to (`App.plFile`,
  kept across restarts as `playlistFile`); opening files anew starts a playlist in no file.
  With the panel's Autosave checked (`playlistAutosave`, the files it's on for), `autosavePlaylist`
  compares the entries with those last written four times a second and rewrites the file when they
  differ, so every edit path (adding, removing, sorting, a YouTube playlist being listed) is caught
  without hooks. Ticking it on a playlist in no file asks where to save it first. It's greyed out for
  a read-only file (`access(W_OK)`, rechecked on each check), while synchronized, and for a playlist
  in no file holding a YouTube playlist link not yet listed, until it's saved to a file.
- Several playlists (`src/plmanager.nim`, tabs drawn by `playlistTabs`): the one shown lives in
  `App.playlist` and the `pl*` fields as before, so the editing, columns, search and Properties code
  is unchanged; the others wait in `App.tabs`, the shown one's slot there stale. `stashTab`/`unstashTab`
  move the fields in and out, and `inTab(i): body` runs code on another playlist as if shown (next,
  previous and the end of a file go through `inPlaying`, a YouTube listing into the playlist it was
  started from, Save Playlist's answer into the one it was asked from). Never call `showTab` inside
  `inTab`: the swap back would undo it. Only the playing playlist (`tabPlaying`) has `plIndex` set;
  `playingEntry`/`playingCount` read it from any view. Files opened go into the Default playlist
  (`scratch`, replaced each time, emptied by Close; renaming it makes it the user's own), so
  another playlist is never replaced; the folder walk of a lone file plays there too. Load Playlist
  makes a playlist bound to the file. Undo keeps whole snapshots per playlist (`undoPoint`, called by
  every edit before it changes anything; 100 steps or 200 000 entries). The playback queue holds
  playlist id, entry and position (the position only as a hint), and is consumed by the end of a file
  and Next. All playlists go to `playlists.json` whatever Remember playlist says (it only empties
  Default at start); a save writes only when this player's playlists changed and merges by playlist
  id with what other players wrote meanwhile (`mergeStore`), so two running players don't undo each
  other's playlists. The config's `playlist` fields are read once into Default, then emptied.
  The column header's "Override columns for this playlist" gives the shown playlist columns and
  widths of its own (`PlaylistTab.columns`/`columnWidths`, saved in `playlists.json`, copied by
  Duplicate), starting as the shared ones (`playlistColumns`/`playlistColumnWidths` in the config);
  unchecking it drops them. Column code goes through `plColumns`/`plColumnWidths`, which pick the
  set in use, and `saveColumns`, which saves it where it's kept; Show milliseconds stays shared.
  The tab menu's "Playlists in a Side Column" (`playlistTabsSide`) draws the playlists as a list left
  of the entries instead (`playlistSide`), with the same clicks, drags and drops; it fills the same
  `tabRects`/`tabPlus`/`tabStrip`, so file drops, row drags and right-clicks treat both alike. The
  column's right edge resizes it (`playlistSideWidth`), it scrolls when the playlists overflow
  (`tabScroll`, the shown one kept in view through `tabSeen`), and the toggle widens or narrows the
  panel by its width so the entries keep their room.
  Script commands: `tabdump`, `tabrects`, `tabnew`, `tabshow`, `tabclose`, `tabrestore`, `tabrename`,
  `tabmove`, `tabsend`, `tabctx`, `tabaction label`, `plmark`, `act <command id>`, `next`, `prev`, `eof`, `colctx x y
  field`, `colaction label`, `coldump`.
- With "Same player for each media file" (the default), a running player listens
  on `$XDG_RUNTIME_DIR/majestic-media-player.sock` and files opened from the
  file manager are handed to it instead of starting a second window. On
  Windows it listens on a loopback TCP port, written to
  `%TEMP%\majestic-media-player.sock`. The shield button (left of the volume,
  off in every new player, `setShield`) closes that listener, so the next launch
  finds nobody and becomes a player of its own, listening in turn. Unshielding
  listens again; a player that's unshielded but not listening (another one was
  first) retries every 2 s from the main loop, taking over once that one quits.
- Options ▸ Formats writes file associations to `~/.config/mimeapps.list`.
  Associations are per MIME type, so extensions that share one (mp4, m4v, f4v)
  are checked together. Unchecking removes the player from the default list,
  and the previous default takes over again. On Windows they go to the
  registry under `HKEY_CURRENT_USER`; an app the user picked in Settings ▸
  Default apps still wins there, and the Formats page says so.
- `src/mediactl*.nim` puts Play/Pause, Previous and Next in the desktop's task bar.
  On Linux that's MPRIS on the session bus, which Plasma's task manager shows in
  a window's tooltip, tying the player to the window by process id and
  `DesktopEntry`. On Windows it's
  `ITaskbarList3` thumbnail toolbar buttons. `MediaState` follows the Controls
  bar's buttons, read four times a second; commands run from the main loop.
- The UI font is IBM Plex Sans (SIL Open Font License), embedded in the binary; the tracker
  chart's cells use IBM Plex Mono (same license).

- Tracker modules (`TrackerExtensions` in `src/config.nim`) need no code of their own to play:
  mpv opens them with FFmpeg's libopenmpt demuxer (Arch's ffmpeg is built with it, and so is
  shinchiro's Windows libmpv), found by content, not extension. The list is libopenmpt's own minus
  extensions other formats use (`.ppm`, `.stp`, `.amf`, `.mdl`, `.sfx`...), so a folder of
  images or CAD files doesn't fill the playlist. The demuxer hands mpv rendered 48 kHz float PCM,
  so Properties and the playlist's bit rate skip the stream's figures (3 Mb/s "lossless") for the
  file's own; the module's kind comes from its extension, as FFmpeg doesn't pass libopenmpt's on.
  Formats offers only `AssocTrackerExtensions`, and on Linux only their `audio/` types: `*.mod`
  is also `application/x-object`. Subsongs aren't offered: FFmpeg plays the default one.
- Tracker chart: FFmpeg keeps its libopenmpt module to itself, so `src/tracker.nim` opens the
  file again with libopenmpt, `dlopen`ed (no chart without it). On Windows that's the official
  `libopenmpt.dll` with its four `openmpt-*.dll` helpers, shipped beside the exe: libmpv's copy
  is linked in statically, with nothing exported.
  libopenmpt can't say which row plays at a time, so a second copy renders the song silently,
  4 ms of work per frame (a whole song takes ~10 ms–1 s), noting when each order/row
  starts and every channel's VU every 5 ms. It renders at 48 kHz, the rate the song plays at:
  libopenmpt rounds each tick to whole frames of its rate, so rows timed at 8 kHz drifted
  from the sound (1.2 s by the end of UT's Botmca9.umx). Nearest-sample interpolation keeps
  that cheap without changing rows or levels. The row libopenmpt reports past the end is the
  song's restart row, never heard, so it isn't marked. The chart finds the row by `time-pos`, run on
  between its updates (`TrackerChart.clock`). A speed change makes `time-pos` jump (mpv counts
  the buffered sound at the new speed: 1×→2× drops it 0.3 s, then it leaps 0.65 s ahead), so
  the clock runs on at the speed and eases toward `time-pos` over ~0.5 s, snapping only
  after a seek or loop. The chart lays rows out in pattern order around it,
  so jumps show as jumps; between two consecutive rows it glides. Cells come from libopenmpt's
  own formatter at the widest of 0/10/6/3 characters (then the smaller font) that fits every
  channel. Redraws are capped at 144 fps while it plays (~10% of a core).
- Tracker button (controls bar, beside the equalizer, while a module plays): a panel with a
  pitch shift in semitones and "Stretch sample playback". FFmpeg's libopenmpt demuxer takes no
  settings (only `sample_rate`, `layout`, `subsong`), so once either differs from the default the
  module is reopened where it is as `mmpmod://N` (`src/modstream.nim`, `p.source`): a WAV
  stream (48 kHz float stereo) that libopenmpt renders as mpv reads it, through
  `mpv_stream_cb_add_ro`. Its bytes match FFmpeg's rendering, so the song's time, seek bar and
  chart are unchanged. A seek renders on from where libopenmpt lands (a row start) to the exact
  frame. Both settings are libopenmpt's `play.pitch_factor`: 2^(semitones/12), and with
  stretching off also divided by the speed while mpv resamples (`audio-pitch-correction=no`).
  The tempo follows the speed but samples keep their length and pitch (1.5×: 10 s of song in
  6.66 s, same pitch). mpv reads 0.5–1.5 s ahead, so a factor change of over 2% seeks to the
  position to start a fresh read; a synchronized slave's speed nudges just wait for it. mpv
  reports a cache for the stream, which the status bar and seek bar ignore.
  libopenmpt refuses pitch factors over 4 and keeps the old one (so below 0.25×, or 0.5× at +12,
  samples went flat and slowed with the speed). Past 4 the stream takes tempo 1/2^k: libopenmpt
  renders 2^k frames per stream frame at pitch factor/2^k, still at 48 kHz, and a Kaiser-windowed
  sinc (16 stream frames each side) decimates them. At 48 kHz each tick gets exactly 2^k times
  its frames at tempo 1, so the song keeps the stream's time to the frame; lowering libopenmpt's
  rate instead (the same frames otherwise) rounds the ticks differently and drifts ~1 ms per
  second in some modules. Seeks go at tempo 1 (libopenmpt's seconds are the song's only there),
  and a change of k waits for a seek, as a new tempo mid-tick would put the rest of that tick off.
  Stream callbacks (this one and `mmpmidi://`) keep their memory on the C heap (`streamAlloc0`,
  `streamCreate`, `streamFree` in `src/mpv.nim`), never Nim's allocator: mpv opens a stream on a
  short-lived thread of its own and closes it on another, and Nim hands a freed block back to the
  heap of the thread that allocated it, which went with that thread (a crash when glibc has
  unmapped the dead thread's stack, else a write into reused memory). Reproduce with
  `GLIBC_TUNABLES=glibc.pthread.stack_cache_size=0`, which unmaps a finished thread at once.
- MIDI files (`.mid`, `.midi`, `.rmi`, `.kar`, `.hmi`, `.xmi`): mpv has no synthesizer (FFmpeg's
  libmodplug loader plays them with no proper instruments), so they always open as `mmpmidi://N`
  (`src/midistream.nim`), a 48 kHz float WAV stream that libfluidsynth (`dlopen`ed,
  `src/fluidsynth.nim`) renders as mpv reads it. They need a SoundFont (`.sf2`/`.sf3`): the first
  in the file's folder, else Options > Audio Files > SoundFont (`soundFontFor`). With neither, or
  without libfluidsynth, the file opens as `mmpmidi://0`, which fails, and the status bar says why.
  `src/midisong.nim` turns the file into timed messages: a standard file's tracks merged through its
  tempo map. Each message plays at its frame between rendered slices; a seek resets the synth
  and replays every message before the spot except notes (so programs and controllers hold, while
  notes held across it are dropped; it converges on an unbroken render within seconds, the reverb
  and chorus phase aside). A synth (and the SoundFont, ~60 ms for 150 MB) per stream; gain 0.2,
  FluidSynth's default. Creating FluidSynth settings probes every ALSA device and fills stderr, so
  its audio drivers are limited to the file writer first and its log is silenced.
  HMI songs (Human Machine Interfaces' SOS, `HMI-MIDISONG061595`, e.g. Abuse's) are played through
  as SOS 4 does on a General MIDI device, reverse engineered from the Abuse CD's `ABUSE.EXE`
  (Watcom LE with debug symbols: `sosMIDIProcessSong_`, `sosMIDIProcessEvent_`, `sosMIDIMapTrack_`,
  `sosMIDIAcquireChannel_`, `sosMIDIBranchSong_`...). The song header's +0xD4 is the timer rate
  (120 Hz in Abuse) and +0xE4/+0xE8 the track count and table; a track's +0x57 is its data,
  +0x79 its channel, +0x99 eight device tags (0xA000: GM/MPU-401/AWE32, 0xA002: OPL2/3, else the
  exact driver), +0x63 its branch table, +0x7D its controller state (indexed by the song's
  +0x26 table). Each tick: queued note-offs first, then each track while its delta (a big-endian
  VLQ) has run out. A note-on carries its length (VLQ) and ends length + 1 ticks later, sent as a
  note-on of velocity 0, and only while its track has a channel. Tracks start without one:
  controller 105 takes one from the driver's pool (channels 0-8, 10-15 in order; 9 for drums)
  and replays Reset All Controllers plus the track's stored state; 105 = 0 gives it back. Other
  HMI controllers (103/104 restore masks, 106/107 locks and priority, 108 cut the channel's queued
  notes, 119 trigger) aren't sent. Controller 7 is scaled by song, master and driver volume, and
  on the drum channel scales note velocities too. Meta events `FE 10` (a restore point: count,
  (controller, value) pairs, the song tick), `FE 11`/`13` track branch/loop end, `FE 12`/`14`
  loop starts (reload the count), `FE 15`/`16` song loop end/branch (every track jumps to its
  branch-table entry of the same id, cutting its notes, restoring the point's controllers, and
  coming back if it had ended); `FF 2F` ends a track. SOS tests a restore mask by bit
  `ctl & 0x20` (a bug: always bit 0). The driver's reset sends All Notes Off, volume 0 and Reset
  All Controllers to the pool's channels. Every Abuse song loops forever; it plays its loop
  twice, then fades out over 8 s (the stream's fade). Abuse itself plays music only on GM-class
  cards: its OPL path needs `music/melodic.bnk` and `drum.bnk`, which it never shipped.
  XMI songs (Miles Sound System's Extended MIDI, e.g. Theme Hospital's): the first `EVNT` chunk
  of `FORM XDIR`/`CAT XMID`, at a fixed 120 Hz: a delay is the sum of the bytes under 0x80 before
  an event, a note-on carries its length (VLQ; its note-off goes before anything else at that
  tick), no running status. The file's tempo was applied when it was made (times rounded down to
  ticks), so its tempo and time signature only place the chart's beats. Controllers 110-120 are
  AIL's (120 is its branch index, not All Sound Off) and aren't sent; FOR (116) / NEXT (117 >= 64)
  loops repeat, forever ones twice and then a fade, as HMI's. `TIMB` (MT-32 timbres) is unused.
- MIDI chart: the tracker chart, fed by `src/midichart.nim` instead of libopenmpt (`TrackerSong`
  with `cellsOf`, `patRows`, `patBeats`, `labels`, `info`; the header tells bars and rows).
  Each bar is a pattern and each 16th note a row (16th triplets when clearly more notes start on
  those), from the file's tempo map and time signatures (an XMI's tempo events);
  an HMI song keeps neither, so its rows come from the period its note starts line up best with
  (circular mean, 40–200 ms), 16 to a bar. Each channel takes as many columns as it plays notes at
  once (8 at most): a note keeps its column until it ends (`===` there when nothing starts). Cells
  read note, program and velocity (or less, narrower). Levels: velocity times volume and
  expression, sinking while held, gone 0.25 s after the note.
- Cue sheets (`src/cue.nim`): an album ripped to one audio file with a `.cue` beside it plays as
  its tracks. `expandPaths` (Open File, Open Directory, drops, M3U/PLS entries) runs its files
  through `withCueTracks`: a `.cue`, or an audio file a sheet in its folder names, becomes one
  playlist entry per track, `<sheet>.cue#<track number>`, once however many sheets name the file
  (rippers leave `album.flac.cue` and `album.wav.cue`; the one whose FILE exists is used). A FILE
  that isn't there (`album.wav`, compressed to FLAC afterwards) is looked for under its own name,
  then the sheet's (`album.wav.cue` -> `album.wav`, `album`), with any audio extension. Text that
  isn't valid UTF-8 is read as Windows-1252. Sheets of several FILEs (a file per track) are
  ignored: those files play as they are. A track plays (`playIndex`) and is probed (`Prober`) as
  an EDL timeline of its stretch of the file (`cueSource`: `edl://!no_chapters;%len%file,start,length`,
  no length for the last), so time, duration, seeking, the seek bar and the end are the track's;
  it opens with `force-media-title` set to the track's title, and the probe takes title, artist,
  album, track number and year from the sheet. EDL still passes on the file's chapters at the
  album's times, so `parseChapters` drops them for a track. Opening one track entry (Open Recent)
  opens its whole sheet, playing from it. Properties, Copy to Clipboard and the task bar's URL
  use the audio file (`cueFile`). Tracks are separate files to mpv: there's a short gap between
  them, as between any two files.
- ReplayGain (Options > Playback > ReplayGain, the controls' button while a local file with
  sound is open, the playlist menu's submenu): mpv's own `replaygain`, `replaygain-preamp`,
  `replaygain-clip` and `replaygain-fallback`, set on the player, the standby and the loop sound
  alike (`syncSettings`; also in `MirroredProps`), and applied by mpv live, mid-file. Playback
  scans nothing: mpv reads `REPLAYGAIN_*` tags (ID3 `TXXX`, Vorbis comments, APE, MP4 freeform) and
  reports them per audio track as `track-list/N/replaygain-{track,album}-{gain,peak}`, giving the
  track's for missing album values (`ReplayGain` in `src/player.nim`, from `track-list` and the
  playlist's probe). mpv applies the fallback gain even with `replaygain=no`, so it's sent as 0
  while ReplayGain is off. The button is purple while on for a file without values and blue
  while the file's values apply; its menu shows them and the gain applied (`ReplayGain.applied`:
  gain + pre-amp, capped at -20·log10(peak) with Prevent clipping). Script commands: `rg` opens
  the menu, `rgaction Label/Sub` picks an item (`playlist/...` for the playlist's), `rgmenu
  [playlist]` lists the items, `rgdump` prints the settings and each player's properties.
- Analyzing ReplayGain into tags (the playlist menu's ReplayGain > Analyze and Apply as Tracks
  (track gains only) / Analyze and Apply as Album (track gains plus one album gain) / Remove
  ReplayGain Values, for the selected local files; the controls' ReplayGain button has Analyze
  and Apply as Track and Remove ReplayGain Values for the open file, disabled for a cue sheet's
  track, which has no tags of its own; `src/rgscan.nim`): a
  thread runs `ffmpeg -map 0:a:0 -c:a pcm_f32le -f wav -` per file (the WAV header gives the
  rate and, for more than two channels, the channel mask) and measures it as BS.1770-4 / EBU
  R128 asks: K-weighting (libebur128's coefficients for any rate), 400 ms blocks every 100 ms,
  the -70 LUFS gate then 10 LU under the mean, surrounds weighted 1.41 and LFE left out. Gain
  = -18 LUFS - loudness; peak = highest sample. Album loudness gates every file's blocks
  together (what one long file would give), so each file's blocks are kept. TagLib
  (`src/tagedit.nim`) writes `REPLAYGAIN_{TRACK,ALBUM}_{GAIN,PEAK}` ("-6.54 dB", "0.988831"),
  or for `.opus` `R128_{TRACK,ALBUM}_GAIN` (Q7.8 relative to -23 LUFS, RFC 7845) with any
  `REPLAYGAIN_*` removed; mpv reads both. Track gains are written as each file is measured,
  album gains once all are, both on the measuring thread: TagLib rewrites a FLAC (or any file)
  without padding room for the new fields whole, 0.2-2 s for a 100 MB file, and doing that for
  an album on the main thread froze the window after the last file. `RgJob.poll` only copies
  the thread's results under the lock. The thread is one for every job, started with the first and
  never ended: the next job's start frees what the last one left under the lock, and Nim hands a
  block back to the heap of the thread that allocated it, which a thread per job took with it (a
  crash on the third job under `GLIBC_TUNABLES=glibc.pthread.stack_cache_size=0`, at random
  otherwise). `RgJob.writing` marks the album's writing, which the
  status bar shows as "Applying ReplayGain". Tagged files leave the probe cache so the playlist reads them
  again; the open file's values change in mpv only when it's opened again. Matches ffmpeg's
  `ebur128` filter (stereo, 5.1, MP3/FLAC/M4A/Ogg/Opus, and two files joined for album gain).
  Script command `plselectall` selects the whole playlist for testing it.
- The playlist's Properties (its menu's Properties..., for the selected local files; window in
  `src/tagdlg.nim`): tags read and written with TagLib's C bindings (`src/tagedit.nim`,
  libtag_c loaded at run time, as libopenmpt is; without it tags show read-only, from ffprobe).
  Fields are TagLib's property map, one list for every format (TITLE, ALBUMARTIST, TRACKNUMBER,
  free-form keys such as MOOD), which TagLib maps onto ID3v2 frames, Vorbis comments, MP4 atoms
  and so on; several values show joined by "; ", except in free text (COMMENT, LYRICS...).
  Totals get rows of their own: "3/12" (ID3v2, MP4, ASF) is split on reading and joined on
  writing, Vorbis/APE files keep TRACKTOTAL/DISCTOTAL (or the TOTALTRACKS spelling they had).
  Two TagLib quirks: a tracker tag has every field even when empty, so a value is set before
  others are appended; and an XM save can report failure after writing, so success is judged
  by reading the file back. Tracker modules are read-only all the same: saving one, TagLib
  rewrites its sample and instrument names (where the comment lives) and drops their
  non-ASCII characters (seen on an IT: "§" lines zeroed). MIDI files show their own text
  events (copyright, track names, lyrics, markers; RIFF MIDI's INFO), not ffprobe's, which
  reads them through libmodplug and makes fields up. The grid compares only the files edits
  go to; a field they don't agree on shows <multiple values> and is left alone unless edited.
  Autofill matches a pattern (`%field%`, `%_%` to skip, `/` per folder) against the file
  names, each field as short as the rest allows; text ending the pattern ends the match, the
  rest of the name left unread ("%title% Original" on "Song Original Mix") (the last eight patterns used are in the
  field's dropdown, Down opens it, × forgets one; `tagPatterns`); its preview's columns are
  resized by their header edges, double-click fits one (`tagColumnWidths`, by field; the
  last column fills the rest); track numbers go top to bottom in playlist order. Details lists ffprobe's report, a module's libopenmpt metadata, message and sample /
  instrument / channel names (`moduleDetails` in `src/tracker.nim`), and a MIDI file's texts.
  On OK or Apply the files changed are written; their bookmarks and saved equalizer move to
  their new `mediaKey` (it hashes the file's first and last 64 KiB, which tags change), the
  playlist's cached fields take the written ones (`MediaInfo.retag`: rows and columns change
  at once, no new probe), and the file playing opens again where it is (paused or not, its
  added tracks kept) for mpv to read its new tags; the window title follows on that reopen. The AppImage bundles libtag_c; the Windows
  build has no TagLib yet, so it shows tags read-only. Script commands: `tags` opens it for
  the selection, `tagtab`, `tagset FIELD value`, `tagpattern`, `tagfill`, `tagnumber`,
  `tagdetail i`, `tagapply`, `tagok`, and `tagdump` (every file's fields and the player's state).

- Visualizer (sound without a picture, `showVisualizer`): AVS 2.81d (Nullsoft's 2005 BSD release,
  visbot/vis_avs) ported to Nim in `src/avs/`, a software renderer as AVS was: 32-bit 0x00RRGGBB
  frames, each effect rendering the frame into itself or into the second buffer. It follows the
  original down to its quirks, since presets were tuned against them: blends as the MMX build did
  them (MMX block blends shift by 8 and touch the top byte, BLEND_MUL/line blends use the /255
  table), C's float/int casts (`ftol`: truncation, 0x80000000 out of range), 32-bit wrapping in
  the fixed-point effects (Dynamic Movement's grid and its reads past the grid's end into the
  interpolation rows), statics shared between instances (Mirror, Multi Delay), Video Delay
  keeping 10 frames until its dialog would set its delay. EEL (`src/avs/eel.nim`) is NS-EEL as it
  ran: its lexer's own DFA tables (so `dh` is a hex constant worth 16 times its value), statements
  split at every `;`, one bad statement discarding the code, names counting 8 characters,
  pointer-valued operands (`a + assign(a, 5)` adds 5 to 5), x87 rounding for `%`, `&`, `|` and
  `loop`, NaN counting as true for comparisons and false for `if`. Effects with unknown ids, and
  third-party APEs not ported (Nullsoft TV, Flock Off: no source or binary survives), render
  nothing. Render / Text (`text.nim`, r_text.cpp) keeps GDI's logic (the clip color, words picked
  on beats or frame counts, the redraw test that leaves the last word up through a blank) but draws
  with pixie, antialiased against the clip color, from the font file the system matches to the
  saved LOGFONT (fontconfig on Linux with a few Windows-name aliases, GDI's own font data on
  Windows); a symbol-charset font's bytes are its U+F0xx glyphs, and without the font installed
  the substitute draws the bytes as CP1252. `$(playpos)`/`$(playlen)`/`$(regNN)` work, `$(title)`
  is empty. Texer II, Texer, Convolution Filter, Add Borders and Picture II (`apes3.nim`) follow
  grandchild's port; Texer II's and the Convolution Filter's MMX are reproduced per byte (top byte
  included, the Convolution's generated code with its right column and bottom row clamped one
  short, its bias counted 256 times, "absolute" only clearing the sign bit), checked bit for bit
  against grandchild's code built for 32-bit x86. The Convolution adds its four 16-bit lanes as one
  64-bit word a whole row at a time when no lane can pass 65535 (every saved kernel), pixel by pixel
  otherwise and where in-place writes are read back. Texer images, and Picture II's, are looked up
  as AVS found them in its folder, where every pack's images sat side by side: the preset's folder
  and up to three above it, any letter case, then anywhere in its collection, the folder three
  above it (never the home folder or above; read breadth first, at most 100,000 entries, the index
  kept 30 s) (`findPresetFile`, `presetDir` set by `loadPresetData`). Texer II without one uses its
  built-in blurred circle, and so does Texer when its named image is nowhere (it drew nothing,
  blanking presets whose pack images went missing). BMPs are read by `bmp.nim`, not pixie, which
  refuses RLE4/RLE8, 16-bit and some 4-bit files that Windows' LoadImage read (Whacko AVS 6's
  sprites are RLE8): every header, palette depth, bitfields and RLE, 5-bit colors widened by
  repeating their bits as GDI does. Color Map (an APE) follows
  grandchild's rewrite (vis_avs, BSD), with its gradients run from the first color to the next.
  Jheriko's Multi Filter (`apes2.nim`) follows it too: chrome folds each byte at 128 (2c below,
  510 − 2c from it) once, twice or three times; "infinite root + border" whitens every non-black
  pixel and the ones above and left of it; toggle on beat flips it on and off each beat.
  FyrewurX (Nullsoft's fyrewurx.ape, binary only) is a look-alike of our own in `apes2.nim`, not
  a port: its config is enabled and a 0x00RRGGBB color (the default 0x285080, dark blue); beats
  launch rockets (4 at most) that burst at their peak into 50 to 90 falling, fading sparks, drawn
  as streaks added onto the frame whatever the line blend mode, as its presets rely on (Tribute
  to Yathosho's 0x010203 sparks lift pixels past a Color Clip into Water; others stack copies).
  Winamp gave AVS 576 waveform samples (8-bit) and 576 spectrum values per channel: here the
  newest 576 samples at 44.1 kHz and a Hann-windowed 1024-point FFT spread over 576 bands,
  tilted up to x6 toward the top as music's highs are faint, through AVS's log table. Beats are
  main.cpp's detector on the waveform; smart beat (bpm.cpp) was off by default and isn't ported.
  A beat is a level (the louder channel's summed |samples|) 1/16 over its recent peaks' and over
  a floor, main.cpp's 576 * 16 (an average of 16/128, -18 dBFS): quiet music, ReplayGain's
  lowered tracks and many modules never reach it, so it's `avsBeatThreshold` percent of that
  (Options > Audio files > Visualizer, and the Visualizers window's bottom bar, `aaBeat`; 100 by
  default; 0: any sound). How far over the peaks is `avsBeatSensitivity` (same places, %):
  `marginFor` makes 100 main.cpp's 1/16, 200 none (about twice the beats on soundtracks
  measured), 300 1/16 under (4 to 13 a second), 0 twice main.cpp's. Both are Winamp's at 100,
  bit for bit: 1.0625 is exact, so int(p * 1.0625) is main.cpp's (p * 34) div 32. Presets' own beats (Custom
  BPM, an effect list's `beat`, code testing getosc/getspec) don't go through it.
  The engine runs on a thread of its own (`src/avsview.nim`), ticking up to 60 times a second
  (`MaxFps`) while it shows, at most 960 pixels wide (wider frames scale up), and keeps the
  picture across a resize. AVS had no frame clock: main.cpp slept 5 ms after each frame (10 to
  16 ms on Windows then), and presets move a set amount per frame (`e=e+0.039` in code, a Blitter
  Feedback zoom, a Blur, Water's ripples), so ones made on slow computers race at 60 (degnic's
  Hellhammer 8 at about twice their speed). Their steps can't be scaled by the time passed (code
  and feedback effects aren't linear in it), so a preset steps `rateOf` times a second instead:
  Frame Rate (60 down to 10, `avsFrameRates` by preset, 60 left out) in the video menu's
  Visualizer Preset and the Visualizers context menu, a column there. Each tick feeds the audio
  (`setAudio`: a beat found waits for the next step, the spectrum keeps its peaks till then, as
  main.cpp's render() did between frames) and adds rate/60 to an accumulator; a step is taken at
  1, and below 60 what's shown is the last two steps blended by the remainder (`blendFrames`), a
  step behind, so the picture moves every tick. A new preset or size starts again from a step.
  Presets: Winamp's own (assets/avs/, in the binary) and the presets folder (config dir `avs/`,
  any depth), picked from the video's right-click menu; the one in use is `avsPreset`.
  Visualizer Preset > Visualizers... (`src/avsdlg.nim`, a window beside the player like the
  Equalizer's, but resizable: `placeDialog`'s `minSize` keeps it from going below `AvsMinSize`,
  where the toolbar and the hint still fit, and the size it was left at returns next time,
  `avsWindowW`/`avsWindowH` in UI units; on X11 dialog windows get `keepContentsOnResize`,
  north-west bit gravity and a panel-colored background, as X's defaults blank the whole window
  black at each resize step until the next frame is put in, and a resize draws at once)
  lists them all with a checkbox each: presets turned off (`avsDisabled`) leave
  the menu's list and are skipped by `step` and `randomPreset`, so by Next, Previous, Random and
  anything else that picks one. Highlighting a row plays it, off or not. Add... copies .avs files
  into the presets folder, at its top, and Add Folder... every one in a folder into a folder of its
  name there, laid out as they were, looking into its subfolders too while Include subfolders is on
  (`avsAddSubfolders`, the default; the folder's own presets otherwise); `addAvs` expands folders the
  same for MMP_SCRIPT's `avsadd`. `importPreset` loads each preset (on the main thread, run never)
  to learn the images it uses (`findPresetFile` notes them in `presetFilesFound`, `presetFiles`) and
  copies them along, at their paths under the folder taken from, or beside the preset when they were
  found outside it; a file already there with the same bytes counts as the copy, and a different one
  makes the preset "NAME (2).avs" (an image is then left out). Presets already in the presets folder
  aren't copied. One that can't be copied is listed where it is (`avsAdded`), as every added one was
  before; `copyAddedAvs` copies those in when the presets are first listed, laid out as under the
  folder they all came from (each under its own folder's name when that's home or above it), moving
  what's kept by preset (turned off, rating, frame rate, date, the one in use) to the copies
  (`renameAvs`). Remove forgets an added one or hides a folder one (`avsHidden`), deleting nothing; built-in ones can only be turned off. Its columns (name, author from "X -
  Y" names, effect count and first Comment effect, read with the engine's own `loadPreset` on
  the main thread, which runs nothing; size, date, location) resize by their header edges,
  double-click fits one (`avsColumnWidths`). The Rating column is five stars filled like a bar,
  a quarter of a star per step: `avsStarRatings` keeps 1 to 20 quarters by preset (unrated ones left
  out, kept after a Remove so an added-back preset gets its rating again). A click sets the
  quarters up to the pointer, rounded up (each star centered in an equal fifth of the column, a
  quarter of that slot per step, so a wider column is easier to aim at), on every highlighted row when clicked on one; left of
  the first star, or again on the rating the rows all have, it takes the rating off. Hovering
  previews the rating in a lighter color. Ratings from before quarters (`avsRatings`, in
  fifths) are read into the nearest quarter, at least one, when the config loads.
  A header click sorts by its column, a second click the other way (`avsSort`,
  `avsSortDescending`); ties keep the listed order. The Added column is when each preset file was
  first listed (`avsAddedDates`, stamped on each rescan for files without one, reset by Add... and
  Add Folder..., dropped by Remove; built-in ones have none), so sorting by it ascending, the default, is the
  order presets are listed in: those listed before dates were kept share one date. Sorting only
  changes the grid; Next and Previous keep the listed order. Right-clicks open context menus: on
  rows (highlighting a row outside the highlighted ones alone first, without playing it) Play,
  Turn On/Off, Rating, Frame Rate, Open Containing Directory, Copy Path, Add..., Remove and Sort By; on the
  header the sorting; under the rows Add... and Sort By. They are a second `MenuSystem`
  (`avsMenus`) on the Visualizers window, its popups drawn with the main window's GL context
  (`renderPopups`' `main`) and closed like the main ones when its window loses focus.
  The search field at the toolbar's right end (Ctrl+F; `parseSearch`/`matches`) shows only the
  presets matching every word of it, as the grid draws, so the count, the header checkbox, Ctrl+A
  and the highlight (rows left out lose it) all go by the presets found. A word is found, any
  case, in the name (so the author and title of "X - Y" names) or the file name (a built-in
  one's: the asset it came from); "quotes" keep a phrase, and `author:`, `title:`, `name:` and
  `file:` look in that alone. Ratings: `***`/`★★★` or `3 stars` (3 to 3.75), `3.5*` (exactly),
  `4+`, `>=3.5`, `<2`, `rating:2`, `unrated` and `rated`; a bare number stays text ("brainbug
  2"). Esc empties the search, only an empty one closes the window; Enter leaves the field and
  plays the first preset found unless one found is highlighted, Down goes on into the rows. The
  search isn't saved. With it the toolbar's preset count moved to the bottom, by Close, the hint
  wrapping onto a second line when narrow. The bottom bar starts with Beat threshold and
  Sensitivity, the same `avsBeatThreshold` and `avsBeatSensitivity` as Options' (read from the
  config every frame, saved on each change); the hint leaves when narrower than 140.
  Script commands: `avslist`, `avshi i` (highlight; after `avslist`), `avstoggle i`, `avsrate i quarters`, `avsfps i rate`,
  `avssort column [desc]`, `avsctx rows|header|empty x y`, `avsadd paths`, `avsremove i`,
  `avsstep 1|-1|0`, `avsfind text` (as typed in the search), `avsdump` (also whether the window
  is open, the search, the beat threshold and sensitivity).
- Audio tap (`src/audiotap.nim`): mpv gives its clients no samples, so on Linux libpulse
  (`dlopen`ed, PipeWire's pulse server too) records the monitor of each playback stream of this
  process (`application.process.id`), as pavucontrol's meters do: what goes out, in time with
  the sound, whatever plays it (files, links, modules, MIDI). Streams are followed through
  sink-input events (a new file can bring a new stream); the standby's are silent, so they're
  summed in. The callbacks run on libpulse's thread and use only C memory. The samples are
  after mpv's volume, cubic, so the visualizer divides by (volume/100)^3; muted there's nothing.
  Stalled streams (paused) count as silence after 150 ms. Windows (10 2004+): WASAPI process
  loopback (`VAD\Process_Loopback`, `ActivateAudioInterfaceAsync` from Mmdevapi.dll at run
  time) records this process's tree as 44.1 kHz 16-bit stereo, polled every 5 ms on a thread of
  its own, through raw COM vtables; its completion handler only sets an event. Before 2004
  there's no loopback for a process, and the visualizer gets silence. Not yet run on Windows.
- Render contexts: each costs ~200 MiB of video memory on NVIDIA (the CUDA context of its
  hardware decoding), so none is made at startup. A player gets one in its `on_preloaded` hook,
  as mpv's video would fail without it, if the file has a video track or is a link; the seek
  preview on its first request. The standby's and the preview's are freed after `ContextIdle`
  seconds unused; the playing player's stays. `render` and `update` take a nil context.

- The end of a file: once the video runs out, mpv's `time-pos` is the sound's, behind by the audio output's latency, then wherever the sound stopped (short of the last frame or past it), and `frame-back-step` from there finds the last frame again. So `Player` ignores small steps back near the end of forward playback, and `settleEnd` pins the position to the last frame on EOF (`pinEnd`, until the next jump). The seek bar counts that frame as 100%.
- Video track choices: a track picked or turned off (Play > Video Track, the standby's mirroring, a reopen or a resume) goes to `file-local-options/vid`, so it lasts for that file only; mpv's runtime `vid` would hold for every file opened after. Always Disable (`noVideo` in the config) never sets mpv's own `vid` either: a runtime `vid` set while a file has a file-local one is put back to the old value when that file ends. Instead `Player.noVideo` makes the `on_preloaded` hook set a file-local `vid=no` on each file before mpv picks tracks, unless the file is audio with a cover; toggling it sets the open file's to `no` or `auto`.
- Covers: mpv finds the pictures beside an audio file itself (`cover-art-auto`: one named after it, and Options' folder names as `cover-art-whitelist`) and `pickCover` chooses among them and those inside the file in the `on_preloaded` hook (`coverTrack`): the one named after it with Show Front Cover (file) (`showFileCover`, `Player.fileCover`), else the front cover inside (picture types read by `coverart.nim`, as mpv takes the first), else the first folder picture. With Show Front Cover (file) off, the named one is never shown: if it's the only picture, the file gets `vid=no`, or mpv would take it.
- Moving covers (animated GIF, APNG, WebP): mpv shows a picture track's first frame only, so it still shows that (the window fits it, and screenshots and video filters see it) while `animpic.nim` decodes the picture and the app draws the frame due over the picture's rect (`drawAnim`), panned, rotated and sized with it. The picture comes from the file beside (track codec `gif`, `apng` or `webp`), a quick cover's own file, or for one inside the file from its ID3v2 or FLAC picture by its place among them, read only when their count matches mpv's tracks. GIFs are `gifanim.nim`'s: pixie's decoder doesn't lay frames over the one before (most GIFs store only what changed) and turns a disposal-2 frame into a blank one. APNG frames are made into PNGs of their own (the file's IHDR at the frame's size, its PLTE/tRNS, the frame's IDAT/fdAT data) for pixie's decoder, then laid on with their blend and dispose ops; 16-bit and interlaced APNGs, which pixie can't read, stay still. FFmpeg can't decode an animated WebP at all (it skips ANMF chunks, so not even the first frame), so those go through libwebp's `WebPAnimDecoder` (`libwebpdemux`, `dlopen`ed: bundled in the AppImage, not shipped on Windows yet, where an animated WebP can't be shown). Frames are decoded as they come due, at the picture's own delays (10 ms or less taken as a tenth, as browsers do), playing or paused, and kept once composed while all of them fit 64 MiB; a bigger one composes each frame again every time around (~2 ms for an 800x800 GIF). The OSD goes to the OSD layer meanwhile (`osdApart`), as mpv's own is in the picture underneath.
- Quick covers: a picture file dropped on the video frame, or pasted with Ctrl+V (a file on the clipboard, or a picture itself: a browser's Copy Image, read with `wl-paste`, `xclip` or windy on Windows), while the file playing shows no picture of its own (`quickCoverAllowed`: sound alone, a cover, or a video with its track off) is added as an album-art track titled "Quick cover" (`addQuickCover`, a file-local `vid`; the render context is made first, as a file opened without video has none). An animated WebP is added as a PNG of its first frame (in the cache, `quickCoverStill`) and moves through `animpic`. Elsewhere, or on a playing video, a dropped or pasted picture opens as before. Show Quick Cover switches between it and what showed before (`qcPrevVid`), at once: mpv takes a moment to set a picture up again (~0.25 s for a 6000x6000 JPEG), so once the quick cover first shows the app takes it as mpv decoded it (`screenshot-raw video`, asked for in the background with `takeShot`: synchronous it deadlocks, as libmpv's video output takes it through the renderer, our main thread; shrunk to 2048 pixels a side) and draws that (`qcBridge`) from Show until 0.1 s after mpv's video is set up again (`Player.videoConfigs`); a moving one's frames are kept while it's hidden (`animStash`). `pollQuickCover` reads only the track list mpv sent: a property read every frame waits while mpv sets a picture up, and held up the very frames meant to cover that wait. The front cover settings leave it alone (`pickCover` skips a shown one, `coverPictures` never counts it). It goes once another file opens or this one opens again (`pollQuickCover`), unless Save Quick Cover keeps it in `quickcovers.json` (file -> picture, read from where it is): the `on_preloaded` hook then adds it as the file opens (`Player.quickCoverFor`), before mpv shows another picture. Pasted pictures are kept in the config folder's `quickcovers/` (named by their bytes) and deleted once nothing shows or keeps them. Clipboard bytes are read with `startProcess`, not `execCmdEx`, which rejoins lines with "\n" and breaks a PNG's signature. windy's X11 `getClipboardString` waited forever when the owner refused the text (only a picture on the clipboard): `patches/windy.patch` takes a refusal as no text and gives up after 2 s.
- Gapless audio: `gapless-audio` stays `no` (in gapless mode mpv reports the end with ~0.25 s still queued, which opening the next file would cut off), except when mpv has the next file itself. In the last 15 s of an audio file (an audio extension or a cue track) played straight through, `queueGapless` appends the entry `afterEof` would play (the playlist's next, the first when repeating the playlist, or the folder's next with Play next file in the folder) to mpv's playlist and turns gapless on (`weak`: a change of sample rate or channels still reopens the output, with a short gap); `prefetch-playlist` opens it ahead. Videos, the queue, loops, ping-pong, a short file's delay and synchronized slaves keep the app's own path. mpv then goes on by itself; `Player.wentOn` takes the new path from the `end-file` event and `adoptGapless` runs `playIndex` without opening the file (`adopting`). `handleEof` stands aside while a file is queued, as `eof-reached` can show for a moment before mpv moves on. Gapless is turned off again only once the new file plays (`settled`): turned off while mpv changes files, the new file's audio setup would drop the sound still queued.
- Seek bar clicks: a click seeks exactly once, on press, so the picture never visits the keyframe before the spot; dragging seeks to keyframes between marks and exactly on a mark snapped to. `Player.landOn` keeps the time shown (seek bar, status bar, OSD) on an exact seek's target until `landingOn` sees it land: mpv's `time-pos` stays the old one for a while, and a keyframe's after an earlier seek.
- Synchronized frame steps: the master steps and names the time it landed on; slaves go to the frame that puts them at that time plus their offset rather than stepping themselves, so they can't drift at either end of a file. A slave's press only asks the master. A slave's offset is signed: positive is ahead of the master, negative behind it (it waits at its start until the master gets that far).
- Frame steps: mpv's `frame-back-step` decodes from the previous keyframe on every press, so
  it scales with keyframe spacing. While paused, the hidden standby player steps through the
  frames around the position (up to `loopFramesMB`) and each is kept in a texture; a step shows
  another texture and the main player follows with a coalesced exact seek, so `Player.timePos`
  is held (`holdTime`) meanwhile. A frame is only kept once mpv has given both its new time and
  a new picture: they arrive separately, in either order. The window refills near its edges.
  Links, 360° video, A-B loops and CPU rendering use the plain mpv step, as does a press in the
  second or so after pausing, before the frames are in.
- 360° links: `detectSphere` needs a file, so `Player.findSphere` asks yt-dlp's JSON
  (`linkSphere`), per format and not per video: YouTube renders a 360° video's lesser DASH
  formats through a fixed camera. Those are noted as nothing, and so are its HLS formats, which
  stay on the sphere, except on VR180, where they're flat too. `meshHls` covers that: only a
  mesh format's header tells VR180 (a mesh per eye), read with curl, mpv's demuxers skip it.
  Meshes aren't an approximation: EAC and VR180's warped layout are both drawn from the mesh
  itself (`drawMesh`). Saved parts note their `Seg.sphere`, as opening them skips yt-dlp.
  ffmpeg drops meshes when merging, and needs `-strict -2` for an `.mp4`'s sv3d: a downloaded
  mesh video, or `equi` in `.mp4`, comes out flat.

## Source layout

| File | Purpose |
|---|---|
| `src/majestic.nim` | App state, menus, layout, panels, main loop |
| `src/player.nim` | mpv playback instance, thumbnail-preview instance, folder helpers |
| `src/ytboard.nim` | YouTube storyboards for seek bar previews: fetched left to right into the cache, shown by the preview instance |
| `src/srv3.nim` | YouTube's styled subtitles (srv3): fetched into the cache (the hook's links, `fmt=srv3`), turned into ASS, put in place of the plain tracks; File > Save muxes them into an .mkv with ffmpeg |
| `src/tracker.nim` | A tracker module's patterns and play order through libopenmpt (loaded at run time) |
| `src/trackerchart.nim` | The tracker chart drawn in the video frame |
| `src/modstream.nim` | A module played through libopenmpt as a WAV stream mpv reads, for pitch shift and unstretched samples |
| `src/midistream.nim`, `src/fluidsynth.nim` | MIDI files played through FluidSynth as a WAV stream mpv reads; the SoundFont lookup |
| `src/rgscan.nim` | ReplayGain measured (ffmpeg decoding, BS.1770 loudness on a thread) and written to the selected files' tags |
| `src/tagedit.nim` | Tags read and written through TagLib's C bindings (loaded at run time) |
| `src/cue.nim` | Cue sheets: parsed, their audio file found, tracks as playlist entries played through EDL |
| `src/plmanager.nim` | The playlists' data: tabs, undo steps, playlists.json and its merge between players |
| `src/tagdlg.nim` | The playlist's Properties window: the tag grid, Autofill, Details |
| `src/midisong.nim` | MIDI and HMI files as timed messages (HMI through SOS's sequencer), and the chart's rows |
| `src/midichart.nim` | A MIDI song laid out for the tracker chart |
| `src/avs/` | AVS 2.81d ported: `eel.nim` (the expression language), `core.nim` (pixels, blends, lines), `list.nim` (effect lists, presets), the effects (`render*`, `trans*`, `misc`, `text` (Render / Text and its fonts), `apes*`), `engine.nim` (audio to visdata, beats, frames) |
| `src/avsdlg.nim` | Visualizer Preset > Visualizers...: the presets' grid, turned on or off, added and removed, searched |
| `src/avsview.nim`, `src/audiotap.nim` | The visualizer in the video frame (its worker thread, presets, texture); this process's sound, recorded from the sound server |
| `src/videogl.nim` | mpv → texture rendering and the transformed video quad |
| `src/coverart.nim`, `src/animpic.nim`, `src/gifanim.nim` | The pictures inside an audio file (their types and bytes); a moving cover's frames (GIF, APNG, WebP) |
| `src/menutree.nim` | Menu bar / popup / context-menu system |
| `src/options.nim` | Options window (page tree and pages) |
| `src/assoc*.nim` | File associations (XDG mimeapps.list / Windows registry) |
| `src/appimage.nim` | Running as an AppImage: its file, for restarts and updates, and its launcher entry |
| `src/portal.nim` | xdg-desktop-portal requests over libdbus (color picker, file dialog fallback) |
| `src/instance.nim`, `src/peers.nim`, `src/ipc.nim` | Single-instance hand-over, Synchronize links, local sockets |
| `src/syncdlg.nim` | Synchronize ▸ Properties window (masters, slaves, offset, looping) |
| `src/mediactl*.nim` | Task bar media controls (MPRIS / Windows thumbnail toolbar) |
| `src/ui.nim` | Widget helpers on top of Silky's drawing primitives |
| `src/xwin*.nim`, `src/win32api.nim` | X11 / Win32 helpers (drag, on-top, aspect hints, monitors, menu popup windows) |
| `src/config.nim`, `src/dialogs*.nim`, `src/theme.nim`, `src/icons.nim` | Settings, file dialogs (kdialog/zenity/portal, Windows common dialogs), palette, vector icons |

## Debugging

- `MMP_DEBUG=1` prints mpv's log to stderr.
- `MMP_SCRIPT` drives the UI for automated checks, e.g.
  `MMP_SCRIPT="1:open ~/v.mkv;3:menu 1;3.5:shot /tmp/view.png;4:quit"`.
  Commands: `open`, `menu <bar> [sub...]`, `ctx x y [seek]`, `frame 0|1` (a frame step, 1 forward), `close`, `mouse x y|off`,
  `overlay <name>`, `optpage <page>`, `focus <field id>`, `type <text>`, `action Menu/Sub/Item`, `fs 0|1`, `seek t`, `pause`,
  `size w h`, `set prop value`, `dump props...`, `shot file.png`, `quit`.
  `shot` also writes each open menu popup as `file-menuN.png`.
