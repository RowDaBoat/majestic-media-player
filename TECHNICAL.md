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

`kdialog` provides the native file dialogs (`zenity` works as a fallback).
Dependencies are pinned in `deps.lock` and cloned by `tools/fetch_deps.sh`, so
builds don't depend on whatever is in `~/.nimble`.

### Windows

`./install.sh` (from Git Bash) fetches the pinned dependencies and a prebuilt
libmpv (unpacked with [7-Zip](https://7-zip.org)), builds
`majestic-media-player.exe` and installs it with `libmpv-2.dll` to
`%LOCALAPPDATA%\Programs\Majestic Media Player`, plus a Start menu shortcut.
`./install.sh --uninstall` removes it again.

| Command | What it does |
|---|---|
| `tools/windows.sh build` | Build `majestic-media-player.exe` in the source tree |
| `tools/windows.sh run [files]` | Build and run it |
| `tools/windows.sh debug` | Unoptimized build with stack traces |
| `tools/windows.sh install` / `uninstall` | Same as `./install.sh` / `--uninstall` |

The Run menu runs its command lines with Git for Windows' bash (set
`MMP_BASH` to use another).

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
- The UI font is IBM Plex Sans (SIL Open Font License), embedded in the binary.

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
| `src/videogl.nim` | mpv → texture rendering and the transformed video quad |
| `src/menutree.nim` | Menu bar / popup / context-menu system |
| `src/options.nim` | Options window (page tree and pages) |
| `src/assoc*.nim` | File associations (XDG mimeapps.list / Windows registry) |
| `src/instance.nim`, `src/peers.nim`, `src/ipc.nim` | Single-instance hand-over, Synchronize links, local sockets |
| `src/syncdlg.nim` | Synchronize ▸ Properties window (masters, slaves, offset, looping) |
| `src/ui.nim` | Widget helpers on top of Silky's drawing primitives |
| `src/xwin*.nim`, `src/win32api.nim` | X11 / Win32 helpers (drag, on-top, aspect hints, monitors, menu popup windows) |
| `src/config.nim`, `src/dialogs*.nim`, `src/theme.nim`, `src/icons.nim` | Settings, file dialogs (kdialog/zenity, Windows common dialogs), palette, vector icons |

## Debugging

- `MMP_DEBUG=1` prints mpv's log to stderr.
- `MMP_SCRIPT` drives the UI for automated checks, e.g.
  `MMP_SCRIPT="1:open ~/v.mkv;3:menu 1;3.5:shot /tmp/view.png;4:quit"`.
  Commands: `open`, `menu <bar> [sub...]`, `ctx x y [seek]`, `frame 0|1` (a frame step, 1 forward), `close`, `mouse x y|off`,
  `overlay <name>`, `optpage <page>`, `focus <field id>`, `type <text>`, `action Menu/Sub/Item`, `fs 0|1`, `seek t`, `pause`,
  `size w h`, `set prop value`, `dump props...`, `shot file.png`, `quit`.
  `shot` also writes each open menu popup as `file-menuN.png`.
