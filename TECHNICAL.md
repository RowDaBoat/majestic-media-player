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
- Menus are override-redirect X11 popup windows (no frame, taskbar entry or
  focus, like a toolkit's menus), so they can extend past the main window.
  They are drawn with the main window's GL context and the same Silky atlas.
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
- With "Same player for each media file" (the default), a running player listens
  on `$XDG_RUNTIME_DIR/majestic-media-player.sock` and files opened from the
  file manager are handed to it instead of starting a second window. On
  Windows it listens on a loopback TCP port, written to
  `%TEMP%\majestic-media-player.sock`.
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
  libopenmpt can't say which row plays at a time, so a second copy renders the song silently at
  8 kHz, 4 ms of work per frame (a whole song takes 5–500 ms), noting when each order/row
  starts and every channel's VU every 5 ms. The chart finds the row by `time-pos`, run on
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

- Render contexts: each costs ~200 MiB of video memory on NVIDIA (the CUDA context of its
  hardware decoding), so none is made at startup. A player gets one in its `on_preloaded` hook,
  as mpv's video would fail without it, if the file has a video track or is a link; the seek
  preview on its first request. The standby's and the preview's are freed after `ContextIdle`
  seconds unused; the playing player's stays. `render` and `update` take a nil context.

- The end of a file: once the video runs out, mpv's `time-pos` is the sound's, behind by the audio output's latency, then wherever the sound stopped (short of the last frame or past it), and `frame-back-step` from there finds the last frame again. So `Player` ignores small steps back near the end of forward playback, and `settleEnd` pins the position to the last frame on EOF (`pinEnd`, until the next jump). The seek bar counts that frame as 100%.
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
| `src/videogl.nim` | mpv → texture rendering and the transformed video quad |
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
