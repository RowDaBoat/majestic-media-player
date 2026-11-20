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
Each is made a dialog of the player's X11 window so the window manager keeps it
in front, even of an On Top player (KWin's focus-stealing prevention otherwise
opened it behind): kdialog runs on X11 (`QT_QPA_PLATFORM=xcb`) with `--attach`,
zenity (GTK 4, whose `--attach` does nothing) on X11 (`GDK_BACKEND=x11`) and the
player sets `WM_TRANSIENT_FOR` on its window (found by `_NET_WM_PID`) and
activates it, and the portal gets an `x11:` parent handle. On Windows the
common dialogs are owned by the player, and made topmost while it is (an owned
window that isn't falls behind a topmost owner).
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

- HDR video (`setHdrOpts`, for the players and the seek preview): mpv's render API draws with vo_gpu, not vo_gpu_next, so Dolby Vision's per-scene mapping isn't applied (mpv reports an iPhone recording, HEVC HLG with Dolby Vision profile 8.4, as `dolbyvision/bt.2020/pq`, but vo_gpu goes back to the HLG underneath). Its default HDR-to-SDR curve keeps HLG's reference white (203 nits) at full white, so an iPhone video's lit walls, skies and screens crowd near white: brighter and more washed out than on the phone. `tone-mapping=hable` lowers the whole curve to make room for the highlights. Measured on 35 iPhone 13 Pro Max frames (day, night, indoor) against libplacebo with the Dolby Vision metadata applied (FFmpeg's `libplacebo` filter, as vo_gpu_next draws it), rendered through the render API the way the app does (`tmp/iphone/shot2.c`, a headless EGL harness, and its `runvar.sh`/`score3.py`): the default was +18 levels (of 255) too bright on average, hable is within 2 and halves the mean difference; reinhard 0.25 ties, the BT.2390 curve at any `target-peak` doesn't help, and `target-peak` would darken SDR video too. Only HDR goes through the curve: SDR video renders the same to the byte.
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
  button (as a wide bar shows them) and the menus their right-click opens (Play Options, Pause Options, Stop Options,
  Repeat Options, Quality, ReplayGain); "Status Bar", with the timestamp's right-click menu ("Timestamp") and the bar's own;
  "Playlist › Playing Item", the playlist's right-click menu on the entry playing, built with its
  playlist moved into the live fields (`stashTab`/`unstashTab`, and back) and that entry alone
  selected, each item doing `showPlaying` before its action, as right-clicking it would (left
  out while synchronized and another playlist is shown, as showing that one is refused);
  "Play › Disable Audio" and "Play › Disable Video", palette-only toggles that set the track to
  None and back to the one turned off (`palTrackBefore`, by file: in another file, the first
  track); and the commands that only have a key (`PaletteKeyOnly`, run through `runAction`), filed under the
  menu of their key group. The right-click menus come from `buildMenu` called with `ctxMenu` set
  to each one, restored afterwards.
  Submenus are palette items too: running one opens it in the palette (`palTrail`, the label and
  index of each submenu down to it, so one whose label shows a value, "Pre-amp: +3 dB", is still
  found after picking a value in it), and Backspace in an empty search or the button left of the
  field goes back (`palBack`, the search as it was). Lists (`MenuNode.listed`, set with
  `markListed` in `buildMenu`: recent files, tracks, chapters, bookmarks, players,
  visualizer presets, stream qualities, numeric steps) show only inside their own submenu; other
  items also show in searches from above, the Run menu's command lines included. Run commands
  starting with "Join" are also found as "Concatenate ..." (`PaletteWordAliases`). A column (Quality's Video and Audio) counts as part of
  its menu. With nothing typed it lists the open submenu's own items, at the top after the
  commands run lately (`paletteRecent` in the config, keyed "Menu › Item").
  Open Recent keeps 50 files (`MaxRecent`); the menu shows the latest 15 (`MenuRecent`), the
  palette all of them (`palBuilding` is set while `paletteRoot` calls `buildMenu`). Del removes
  the highlighted item when it has a `remove` (the menu's ×), at once, unless the search field
  has text after its caret for Del to delete.
  Matching is `keymap.searchScore`: every typed word (or its singular) must begin a word of the
  label or of its path and keys, or stand for a synonym of a label word (the F1 window's synonym
  tables); label matches rank first, submenus get a bonus, and the track submenus
  (`PaletteFavored`) a bigger one, so "audio" and "subtitle" find them first.
  Enter on a check or radio item runs it and keeps the palette open; any other command closes it
  first, since it may open a dialog.
  "Change Visualizer" (also found as "Switch Visualizer", `PaletteAliases`) is an empty submenu in
  the tree whose items `paletteFind` makes itself from the presets turned on (and the one
  playing only when it's on: presets turned off never appear there), each carrying its preset id (`PaletteItem.id`, part of `paletteKey`, since two
  folders can hold presets of the same name). While it is open (`palAvsList`), it opens on the
  preset playing, scrolled to the middle (`palCenter`); moving the highlight plays that preset
  without saving (`paletteAvsPreview`), a search plays its top result once typing has paused for
  `PaletteAvsTypeDelay` (1 s, `palAvsTypedAt`), and Enter or a click keeps the preset and closes
  the palette. Leaving any other way (Esc, F3, Backspace or the back button, a click outside,
  the visualizer hiding) plays the preset from before it opened again (`paletteAvsCancel`). The last search is kept and selected when it opens again.
  It is drawn inside the main window (not a popup window like the menus), so its text field is
  an ordinary `textField` (`framed = false`, over its own rounded ground) taking the main
  window's keys; `handleKeys` hands every key to `paletteKeys` while it is open.
  It opens with its top-left corner at the mouse (`palAnchor`, asked of the X server
  by `pointerPos` in `showPalette`, since a key can open it before any motion event), kept 4 px
  inside the window. The bottom is clamped as though all 12 rows showed, so the field doesn't
  move as typing changes how many do; when the window is too short, the rows that fit show.
  It is styled after Blender's menu search: rounded corners (`ui.roundRect`, which also draws
  its soft shadow through a wide feather), a darker ground (`colSearchBg`), a magnifier in the
  field, the highlighted row filled with `colSearchSel` under white text, and a ▸ (the
  `arrow16` icon, as the font lacks U+25B8) after each menu of a path. A path too wide for its
  row drops its outer menus into "…" first, then shortens the innermost one.
- vsync is disabled on purpose: with NVIDIA under XWayland, a vsync'd
  `glXSwapBuffers` can block for seconds when the window is hidden. Video frames
  are paced from mpv's frame timing instead; the compositor prevents tearing.
- The player starts with `__NV_DISABLE_EXPLICIT_SYNC=1` on Linux (`src/gpumem.nim`,
  unless already set). With explicit sync, NVIDIA's `glXSwapBuffers` waits in
  `drmSyncobjTimelineWait` for XWayland to release a buffer; one release never
  came and the UI froze for good with the window visible (driver 610.43).
  Without it the driver makes no syncobj calls at all (counted with gdb
  `dprintf`s on libdrm's `drmSyncobj*`; an `LD_PRELOAD` shim sees none,
  as the driver looks them up itself). A nested KWin never shows the
  difference: its virtual backend offers no explicit sync.
- On Windows, menus are never-activated popup windows sharing the main GL
  context the same way; moving the window by the video is done by the player
  itself, so playback doesn't stall during a drag.
- Settings and recent files live in `~/.config/majestic-media-player/config.json`
  (`%APPDATA%\majestic-media-player\config.json` on Windows);
  remembered playback positions (View ▸ Options ▸ Player) in `positions.json` next to it.
  With Remember time on, playlist and Library rows of files in it show in pale red
  (`colRemembered`, `colRememberedDim` for dim columns); `autosave` reloads the file when its
  time changes, so other players' saves show too. Forget Remembered Time, on top of both
  file menus when the selection has such files, is contextual (purple, `markContextual`) like
  every menu item that is there only for what's open or picked; it drops those files' times; forgetting the file playing sets
  `App.forgotPath`, which keeps `savePosition` from remembering it again until it's opened anew.
  Each running player saves the whole config, so only the one whose Options
  changed the keys writes them: the others keep the file's keys and pick them up.
- Subtitle delay keys (`kaSubEarlier`/`kaSubLater`, `-` and `=`): `shiftSubDelay` moves the file's
  own shift (`SubLayout.delay`, ms) by Options' Delay step (`subDelayStep`, 50 ms) and remembers it
  per file in `subdelays.json` (dropped at 0), as Shift+Numpad +/- does sizes in `subscales.json`;
  `syncSettings` hands mpv `sub-delay` = Options' Delay + the shift, and the OSD shows that sum.
  The keys go by place, not by symbol: they're the two right of 0 on any layout (`'` and `¡` on
  Spanish). Windows windy already reads every key by scancode; on X11 `patches/windy.patch` reads
  the punctuation keys (`- = [ ] ; ' `` ` `` \ , . /`) by evdev keycode (`positionalKeys`), and a
  key elsewhere whose symbol is one of them (Spanish `-`, by the right Shift) presses nothing.
  Letters and digits still go by the layout's symbol on X11. Test kit: `tmp/subdelay/` (nested
  KWin with a Spanish layout, `kw.sh`, `run.sh BIN CFG SCRIPT`; libei keys 12/13/53; `dump sub-delay`).
- Modifiers held as a window gains focus (`syncModifiers`, every 30 ms for the focused window, from
  the main loop): Ctrl, Shift and Alt follow the system's modifier state, not only key events.
  Coming from a native Wayland window, Xwayland often knows a held modifier only as modifier state:
  windy's FocusIn keymap read (`XQueryKeymap`) misses it, and the X server then drops its release
  too. Windows windy forgets every key on WM_SETFOCUS. X11's windy `Window` keeps its own
  `buttonDown`, not `state.buttonDown` as on Windows. Test kit: `tmp/focusmods/` (`test.sh BIN
  KEYCODE [close]`, `WL=1` for a kcalc window instead of a plain X one; `moddump` step).
- The playlist remembers the M3U/PLS file it was loaded from or last saved to (`App.plFile`,
  kept across restarts as `playlistFile`); opening files anew starts a playlist in no file.
  With the panel's Autosave checked (`playlistAutosave`, the files it's on for), `autosavePlaylist`
  compares the entries with those last written four times a second and rewrites the file when they
  differ, so every edit path (adding, removing, sorting, a YouTube playlist being listed) is caught
  without hooks. Ticking it on a playlist in no file asks where to save it first. It's greyed out for
  a read-only file (`access(W_OK)`, rechecked on each check), while synchronized, and for a playlist
  in no file holding a YouTube playlist link not yet listed, until it's saved to a file.
- Panel keyboard focus: the playlists' side column, the playlist's entries, the libraries' column
  and the Library's files take the arrow keys (`plSideKeys`, `plArrows`, `libCatKeys`, `libArrows`;
  `panelStop` reads which) once clicked or reached with Tab / Shift+Tab (`panelTab` cycles
  `panelStops`: those shown, the side column only with Playlists in a Side Column, unless a command
  is bound to that combo), and keep them wherever the pointer goes until Escape or a click elsewhere
  (`focusPanel(psNone)`); Escape releases them before it leaves full screen. In a list Up/Down move
  the selection (the playlist also plays it with Enter); in a column Up/Down/Home/End show another
  playlist or pick another library (`libPick`, as a click does) and Enter goes on to its list. F2 in
  the libraries' column types over the library's name in its row (`startLibRename`/`endLibRename`,
  focus id `lib-rename`, checked by `validLibraryName` like Options > Libraries; the search's within:
  and exclude: tags follow); anywhere else in the Library F2 does nothing, not even Rename Playlist. The
  holder shows a `colAccentDim` edge round its list or column, drawn after both panels, and a
  `colAccent` outline on the row the arrows move from. `panelsdump` (MMP_SCRIPT) prints the state.
- The playlist panel's bottom line (`drawStatus` in `playlistPanel`), across the panel under the
  rows and the side column, the body's `colPanel` (not the header's `colPanelRaised`), as tall as
  the Library's (`LibraryStatusH`): the selected entries and their total length (`plSelectionLine`,
  `selectionLine`: "N items selected, 12:34", each copy of a file counted, the lengths the Duration
  column shows, `+` while some entries aren't probed yet; "Nothing selected"). It's drawn after the
  rows, so a click's or a key's new selection shows the same frame. A file dropped on it
  (`dropFiles`) and Library rows let go over it go at the end of the playlist; a right-click on it
  opens no menu (the rows' would pick a row scrolled out of view under it).
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
  widths of its own (`PlaylistTab.columns`/`columnWidths`/`columnOrder`, saved in `playlists.json`,
  copied by Duplicate), starting as the shared ones (`playlistColumns`/`playlistColumnWidths`/
  `playlistColumnOrder` in the config); unchecking it drops them. Column code goes through
  `plColumns`/`plColumnWidths`/`plColumnOrder`, which pick the set in use, and `saveColumns`, which
  saves it where it's kept; Show milliseconds stays shared. The header menus (the playlist's and the
  Library's, `libraryColumnOrder`) list every column in the header's order, a hidden one where it was
  when last shown: the `*ColumnOrder` lists keep the hidden ones' places (`columnOrder` in config.nim
  merges one with the shown columns), `toggleColumn` shows a column back at its place, and a header
  drag (`moveColumn`) moves the column in the order too, before the one it now precedes, leaving
  the hidden ones where they are.
  Playlist groups (the column header's Show groups, `playlistGroups`, shared by every playlist):
  a header row over each run of consecutive entries whose `playlistGroupPattern` reads the same,
  as foobar2000 groups them (the same album twice apart gets two headers). The pattern is foobar2000
  title formatting, written by `formatTitle` in folderpics.nim (the folder pictures' evaluator in
  display mode: a missing field reads `?`, slashes are kept); the default
  `%artist% - [%year% - ]%album%` drops the year and its dash when the file has none. The fields come
  from the probed `MediaInfo` (artist, album, title, year, track, disc) plus the file name fields;
  each file's text is cached in `plGroupLabels` with the tags it was made from. `buildPlaylistView`
  lays out `plLines` (entries >= 0, headers `-(g + 1)` into `plGroups`) and `plLineOf` each frame
  the panel is drawn; a file not probed yet stays in the run above it, so headers don't flicker
  while the probe catches up. Everything that turned a y into an entry or back goes through
  `plLineCount`/`plEntryLine`/`plLineEntry`, and drops through `plGapAt`/`plGapLine` (a group's first
  entry drops above its header), falling back to one row per entry when the view is stale or groups
  are off. A header click selects its entries (Ctrl adds or drops them, Shift extends), a drag moves
  them as a row drag does, a double-click plays the first, a right-click selects them for the menu.
  Grouping pattern... opens Options > Player > Playlists, where an empty pattern means the default.
  Column widths (the playlist's and the Library's): `columnWidths` lays them out from the panel's
  width alone, so resizing the panel never changes what a later resize gives. The number columns
  (`elastic` false: Duration, Size, Track...) keep their width, set by hand or natural (their widest
  text); the text columns (Name, Filename, Artist, Album) share what those leave in proportion to
  their weights (`columnWeight`: the width set by hand, else 240 for Name/Filename, 120 for the
  others), none under `PlaylistMinTextW` (`spreadWeights`). With no text column shown, the room the
  number columns don't need stays empty. Only a panel too narrow for that narrows the text columns
  further (to `columnFloor`), then the number columns. A header edge drag (`startColumnDrag`,
  `dragWidths`, `dragColumn`, state in `ColumnDrag`, computed from the press) keeps the columns left
  of the edge, so the edge follows the pointer: the text columns right of it give or take the width
  in proportion; without any, the empty room does, then the number columns right of it (the next
  one first), and narrowing gives the next column the width. Only the columns it changes are written
  (`setWidths`: a text column's as the weight that lays it out that wide at the press's
  `textScale`), so laid out again every column is as dragged and nothing cut by a narrow panel gets
  saved. A double-click on an edge (`fitColumn`, `libFitColumn`, both through `fitWidths`) fits the
  column to the rows in view: a number column trades width with the text columns (all, in
  proportion; with none, with the empty room), a text column with the other text columns (one
  alone fills the rest, so it doesn't fit). The last column's edge is the panel's while text
  columns fill it; with none shown, a drag there moves into the empty room. Older versions stretched
  the last column into the slack and saved every column as drawn: their number columns' widths are
  dropped once at start (`numberWidthsDropped`). `tmp/flexcols/check.sh` checks these on random
  cases against the procs extracted from the source (`run.sh` and `celldump` for the real app).
- The side column (playlist/library) and the video frame share a window resize Majestic didn't
  ask for (`flexPanel` each frame, telling the edges apart by the window's left edge on screen,
  `flexX`). Dragging the right edge resizes the side column, the left edge the video frame
  (`edgeFlexedPanel`); narrowing, once that one is at its narrowest (`PlaylistMinWidth`, or half of
  `MinWindow` for the video frame, as the column's grip leaves it), the other narrows. Any other
  resize (both edges moving: maximizing, tiling, and the half second after restoring) goes by
  `flexedPanel`: a wider window's room goes to whichever is wider (the video frame on a tie); on a
  narrower one, the wider gives its width down to the other's, then both narrow alike. A width
  that arrives a moment before the window says it's maximized is redone that way (`flexFromW`).
  Majestic's own resizes (`ownResize`: showing or hiding the column, fitting the window to the
  video, compact mode, leaving full screen) leave it alone. Maximized, its width is kept in
  `maxPanelW`, the config keeping the normal window's. While the column shows, the window doesn't
  ask the WM to keep the video's aspect (a right edge's drag doesn't resize the video frame).
  The tab menu's "Playlists in a Side Column" (`playlistTabsSide`) draws the playlists as a list left
  of the entries instead (`playlistSide`), with the same clicks, drags and drops; it fills the same
  `tabRects`/`tabPlus`/`tabStrip`, so file drops, row drags and right-clicks treat both alike. The
  column's right edge resizes it (`playlistSideWidth`), it scrolls when the playlists overflow
  (`tabScroll`, the shown one kept in view through `tabSeen`), and the toggle widens or narrows the
  panel by its width so the entries keep their room.
  Script commands: `tabdump`, `tabrects`, `tabnew`, `tabshow`, `tabclose`, `tabrestore`, `tabrename`,
  `tabmove`, `tabsend`, `tabctx`, `tabaction label`, `plmark`, `act <command id>`, `next`, `prev`, `eof`, `colctx x y
  field`, `colaction label`, `coldump`, `celldump` (columns as drawn, side column and video widths),
  `plgroupdump` (the groups and rows drawn).
- With "Same player for each media file" (the default), a running player listens
  on `$XDG_RUNTIME_DIR/majestic-media-player.sock` and files opened from the
  file manager are handed to it instead of starting a second window. On
  Windows it listens on a loopback TCP port, written to
  `%TEMP%\majestic-media-player.sock`. The shield button (left of the volume, also
  File > Shield From Files Opened Elsewhere; off in every new player, `setShield`) closes that listener, so the next launch
  finds nobody and becomes a player of its own, listening in turn. Unshielding
  listens again; a player that's unshielded but not listening (another one was
  first) retries every 2 s from the main loop, taking over once that one quits.
  Several files selected in a file manager can start one player each, all at
  once (Windows Explorer does that), in no set order. A launch lock
  (`lockLaunch`: a named mutex on Windows, `flock` on the socket path's `.lock`
  elsewhere) lets one launch at a time look for a running player and, finding
  none, start listening, so the others find it. `openFromOutside` turns
  launches less than 2 s apart (`OutsideGap`) into one playlist sorted by name,
  playing the top entry; a single launch with several files keeps their order.
  On Windows the open verb carries `MultiSelectModel=Player`: without it Explorer
  offers a `"%1"` command for at most 15 selected files, and Enter does nothing
  past that. `registerApp` writes it, and `updateRegistration` adds it at startup
  to an association an older version of the same executable made.
  `tmp/multi/shelltest.ps1` opens a folder's files at once through the shell's
  open verb, as Explorer does, with isolated config and socket folders.
  Debug scripts share files only with `MMP_INSTANCE_DIR` set (the socket's
  folder); `tmp/inst/burst.sh` starts one scripted player per file at once.
- Options ▸ Formats writes file associations to `~/.config/mimeapps.list`.
- Options pages never scroll: everything on a page must fit the window (`OptionsSize`, in UI
  units, so at any UI scale); only lists inside a page (Formats, Keys, Media Cache, Libraries) and
  the search's results scroll. A page that grows past it is split by topic into another page
  (Playback > Audio Files gave its covers and visualizer pages of their own: Covers, Visualizer). `draw` records each
  page's height and room (`fit`) and writes to stderr when one is taller; script command `optfit`
  lists them all.
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
- The UI atlas is prebuilt with Latin and basic Cyrillic only. Any other character (kana, kanji,
  hanzi, hangul, Greek, Thai, symbols...) is added the first time text is measured or drawn
  (`src/glyphcache.nim`, called by `ui.nim`'s text helpers): from Plex when it has the glyph,
  else from a system font (`src/fallbackfonts.nim`: fontconfig's fonts with that character on
  Linux, ranked; a fixed list of `%WINDIR%\Fonts` files on Windows). Han characters take the
  text's language: Japanese when it has kana, Korean with hangul, else the locale's CJK
  language (Simplified Chinese when it has none), so the JP/SC/TC/HK/KR face of e.g. Noto Sans
  CJK is picked by family name (fontconfig's `lang` doesn't tell them apart). A character keeps
  the form it was first drawn in. All Silky contexts share the atlas; it grows up to 8192²
  (later glyphs draw as "?") and each context re-uploads it at its next `endUi`, through the
  `atlasSyncHook` in `patches/silky.patch`. No shaping: Arabic and Indic scripts draw unjoined.
  System fonts are read with pixie's own OpenType parser, which `patches/pixie.patch` fixes for
  CFF fonts: Private DICT offsets were read as float32 and lost their last bit past 16 MiB
  (Noto Serif CJK Medium/SemiBold: garbage dicts, then an IndexDefect or a segfault the
  first time a character sent the fallback to them), operand 28 was read unsigned, DICT and
  INDEX reads weren't bounds-checked, and one operand value called `quit()`. A face pixie
  still can't read is skipped (`loadFace` and `draws` also catch Index/RangeDefect).
  Emoji (`isEmoji`: Unicode's Emoji_Presentation and the emoji planes, so ★ or ♪ stay text)
  come from a color emoji font, which pixie can't draw (`src/emojifont.nim`): CBDT/CBLC PNG
  strikes (Noto Color Emoji), the biggest scaled down, or COLR v0/CPAL layers filled with
  pixie (Segoe UI Emoji, Twemoji Mozilla). They're atlas glyphs with `colored` set, which
  Silky's drawText draws untinted (white at the text's alpha). Sequences aren't joined (no
  GSUB): a ZWJ family draws as its people, a flag as two letters, a skin tone as a swatch.
  A UI scaling change rebuilds the atlas and the glyphs are added again as needed.

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
  While the next local file opens, the chart drawn last stays up (`chartHeld`) until that file
  shows its own chart or turns out to have none (or a picture): a module's chart opens only
  once mpv names the format (`file-format`), and in between the frame showed the visualizer.
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
- Westwood Studios' `.aud` sound (Command & Conquer, Red Alert...; `src/wsaud.nim`). FFmpeg's
  wsaud demuxer plays it, but guesses its length from the bit rate (chunk headers counted:
  ~1.5% long; the header's unpacked size is right, `audLength`), and IMA ADPCM (codec 99)
  carries the decoder's step index from chunk to chunk with nothing in the file to resume from:
  after a seek FFmpeg starts again at step 0 and the sound plays ~30 dB quieter until a quiet
  passage happens to bring the two back together. So an IMA file opens as `mmpaud://N`
  (`prepare`): its bytes read on the app's thread into a slot (the same unchanged file keeps its
  slot: queueGapless asks every 0.25 s), decoded from the start when mpv opens the stream, on
  mpv's thread, into a 16-bit WAV held in memory (C heap, as the other streams), nibble for
  nibble as FFmpeg does (bit-exact against `ffmpeg -f s16le` on Red Alert's 40 songs and a
  stereo one: each byte two samples of one channel, the channels taking turns). Seeks land on
  the sample at full loudness; gapless, reverse play and Ping-Pong turns take it like a file.
  Westwood SND1 (codec 1) starts each chunk afresh, so FFmpeg plays it, opened as an EDL of the
  header's length. The playlist's and Library's probes and Media Info take the header's length.
  `nim c -r src/wsaud.nim FILE.aud OUT.raw` decodes a file as the stream holds it.
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
  album, track number, year and disc number (`REM DISCNUMBER`) from the sheet. EDL still passes on the file's chapters at the
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
  ReplayGain Values, for the selected local files; the controls' ReplayGain button (and Play >
  ReplayGain, the same menu: `replayGainMenu`) has Analyze
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
  album gains once all are, both on the measuring thread (a file that keeps no tags gets them
  in its .m2c, below; MIDI files are measured from FluidSynth's render with the SoundFont they
  play with, midistream's `renderOpen`, not ffmpeg's libmodplug): TagLib rewrites a FLAC (or any file)
  without padding room for the new fields whole, 0.2-2 s for a 100 MB file, and doing that for
  an album on the main thread froze the window after the last file. `RgJob.poll` only copies
  the thread's results under the lock. The thread is one for every job, started with the first and
  never ended: the next job's start frees what the last one left under the lock, and Nim hands a
  block back to the heap of the thread that allocated it, which a thread per job took with it (a
  crash on the third job under `GLIBC_TUNABLES=glibc.pthread.stack_cache_size=0`, at random
  otherwise). `RgJob.writing` marks the album's writing, which the
  status bar shows as "Applying ReplayGain". Tagged files leave the probe cache so the playlist reads them
  again. mpv reads a file's values only on opening it, so the open file, when tagged, opens again
  where it is (`reopenHere`, as the tag editor does) once the job ends (once for an album's track
  and album gains), or right after Remove ReplayGain Values when mpv had values for it; the
  button and the menus show mpv's values, which are the new ones from then on. Matches ffmpeg's
  `ebur128` filter (stereo, 5.1, MP3/FLAC/M4A/Ogg/Opus, and two files joined for album gain).
  Script command `plselectall` selects the whole playlist for testing it.
- The playlist's Properties (its menu's Properties... or Shift+Enter on the playlist's arrows,
  for the selected local files, opening on Metadata; window in `src/tagdlg.nim`): tags read and written with TagLib's C bindings (`src/tagedit.nim`,
  libtag_c loaded at run time, as libopenmpt is; without it tags are read with ffprobe and edits go
  to a .m2c, below).
  Fields are TagLib's property map, one list for every format (TITLE, ALBUMARTIST, TRACKNUMBER,
  free-form keys such as MOOD), which TagLib maps onto ID3v2 frames, Vorbis comments, MP4 atoms
  and so on; several values show joined by "; ", except in free text (COMMENT, LYRICS...).
  Totals get rows of their own: "3/12" (ID3v2, MP4, ASF) is split on reading and joined on
  writing, Vorbis/APE files keep TRACKTOTAL/DISCTOTAL (or the TOTALTRACKS spelling they had).
  Two TagLib quirks: a tracker tag has every field even when empty, so a value is set before
  others are appended; and an XM save can report failure after writing, so success is judged
  by reading the file back. Tracker modules are never written all the same: saving one, TagLib
  rewrites its sample and instrument names (where the comment lives) and drops their
  non-ASCII characters (seen on an IT: "§" lines zeroed); their tags go to a .m2c (below). MIDI files show their own text
  events (copyright, track names, lyrics, markers; RIFF MIDI's INFO), not ffprobe's, which
  reads them through libmodplug and makes fields up. The grid compares only the files edits
  go to; a field they don't agree on shows <multiple values> and is left alone unless edited.
  In the grid, Shift+Enter keeps the value and edits the next field (Add field's name after the
  last; from the value box too, where Enter is a line break). It sets `editNext` and the edit
  starts a frame later, so the same Enter can't reach the new field's text box and end it.
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
  build has no TagLib yet, so its edits all go to .m2c files. Script commands: `tags` opens it for
  the selection, `tagtab`, `tagset FIELD value`, `tagpattern`, `tagfill`, `tagnumber`,
  `tagdetail i`, `tagapply`, `tagok`, and `tagdump` (every file's fields and the player's state).
- Majestic Meta Container (`.m2c`, `src/m2c.nim`): tags for files whose own can't be written
  (Westwood `.aud`, MIDI, tracker modules even though TagLib reads them, whatever TagLib can't
  open, and every file without TagLib: `keepsNoTags` in `src/m2c.nim`), in a
  file in the m2c subfolder of their folder: `<folder>/m2c/<file name>.m2c` for
  `<folder>/<file name>` (`sidePath`).
  The extension was picked for being free: `.met` (eMule, OS/2 metafiles), `.mmd` (Mermaid),
  `.mif` (MapInfo), `.mei` (music scores), `.mmf` (SMAF audio FFmpeg plays), `.m2t` (HDV
  video) and others were taken; `.m2c`'s only other use is IBM VoiceType's obsolete files.
  The format, UTF-8 text, one field per line:
  ```
  # Majestic Meta Container 1
  TITLE=Bog
  ARTIST=Frank Klepacki
  COMMENT=First line\nSecond line
  DATE=
  ```
  Keys are TagLib's property names, upper case (read in any case); a key again adds a value;
  `KEY=` with nothing after it clears a field the file holds itself (a module's title); `\\`,
  `\n`, `\r` are escapes; spaces around keys and values don't count; `#` lines are comments;
  a BOM and CRLF are fine. Properties (an entry's `side`) shows the file's own fields with the
  .m2c's over them (`overlay`), and saving writes only what isn't the file's own as it has it,
  plus the clears (a module's message isn't copied), so a file's own read-only fields can be
  replaced or added to; totals keep fields of their own
  (TRACKTOTAL, DISCTOTAL); nothing left removes the .m2c, and the m2c folder once empty. It's
  written to a dot-file in the m2c folder and renamed over it. Any file's .m2c counts wherever
  tags are read, created or not by Properties: mpv's (or ffprobe's) tags with it laid over them
  (`overlay`, values joined by "; ", whatever the file's key case) for the playlist's columns
  (`Prober`, failed opens included: mpv can't open a MIDI file alone), the Library
  (`probeFile`, likewise), Media Info, folder pictures' fields, and for the file playing,
  read once per file (`playingSide`), the window title (Options' media title) and the media
  controls, and the tracker chart's header (title, a module's tracker name: `draw`'s `side`).
  Saving one reopens nothing: the title and media controls take it at once, the
  playlist's columns through `retag`, and the Library reads the file again (`reprobe`: no file
  touched on the main thread; a reading under way when it changed is dropped, `stale`). The
  Library notes each .m2c's time (`LibFile.sideTime`, checked only in folders that have an
  m2c folder), so one edited by hand is read again at the next walk. Script command `m2cdump`
  prints the tags the playlist, the Library, the window title and the media controls have.
  ReplayGain lives there too (REPLAYGAIN_{TRACK,ALBUM}_{GAIN,PEAK}, as in tags): the
  playlist's Analyze and Apply and Remove ReplayGain Values write the .m2c of such a file
  (`usesSide`, on the measuring thread; the rest of it kept), allowed without TagLib for them
  (`canWriteGain`). mpv reads only a file's own values, and the streams (mmpaud, mmpmidi,
  mmpmod) carry none, so the player applies a .m2c's itself: `rgFor` works out the gain mpv
  would (track or album, pre-amp, held under the peak with Prevent Clipping) and gives it as
  `replaygain-fallback` with `replaygain=no`, which mpv then applies alone; a .m2c that clears
  REPLAYGAIN_TRACK_GAIN gets the "without ReplayGain" gain. Every file opens with its options
  as per-file options (`rgOpts`: load, the gapless queue, reopen), so its first samples, and
  a gapless change to or from such a file, are at its level; `syncSettings` pushes them
  again when the file or the settings change (key: settings, path, `sideGain`), onto the
  standby and loop sound too. The button and menus show the .m2c's values (`currentRg`);
  saving or removing them reopens nothing. Measured: an .aud played with a .m2c's -4.67 dB
  is at the level of the same sound as a FLAC with -4.67 dB in its own tags (both 0.6 dB
  under nominal: the output's gain steps, at volume 40 through PulseAudio, not ReplayGain's).

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
  (Options > Playback > Visualizer, and the Visualizers window's bottom bar, `aaBeat`; 100 by
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
  Visualizer and the Visualizers context menu, a column there. Each tick feeds the audio
  (`setAudio`: a beat found waits for the next step, the spectrum keeps its peaks till then, as
  main.cpp's render() did between frames) and adds rate/60 to an accumulator; a step is taken at
  1, and below 60 what's shown is the last two steps blended by the remainder (`blendFrames`), a
  step behind, so the picture moves every tick. A new preset or size starts again from a step.
  Presets: Winamp's own (assets/avs/, in the binary) and the presets folder (config dir `avs/`,
  any depth), picked from the video's right-click menu; the one in use is `avsPreset`.
  Visualizer > Visualizers... (`src/avsdlg.nim`, a window beside the player like the
  Equalizer's, but resizable: `placeDialog`'s `minSize` keeps it from going below `AvsMinSize`,
  where the toolbar still fits with the search field at its old smallest (the hint goes first), and the size it was left at returns next time,
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
  changes the grid; Next and Previous, past their history, keep the listed order. Right-clicks open context menus: on
  rows (highlighting a row outside the highlighted ones alone first, without playing it) Play,
  Turn On/Off, Rating, Frame Rate, Open Containing Directory, Copy Path, Add..., Remove, Show Hidden and Sort By; on the
  header the sorting; under the rows Add..., Show Hidden and Sort By. Presets turned off are
  hidden from the grid unless the toolbar's Show hidden checkbox (or the menus' Show Hidden,
  `avsShowHidden`, off by default) is ticked, so unticking a row takes it out at once; the count
  adds how many are hidden when there's room. The header's checkbox turns every preset shown off
  with one click, but on only with three in quick succession (`countClick`, 0.4 s apart): that
  would lose which were off, while turning all off is undone by turning them on. A click short of
  three shows "Triple-click to turn every preset on" beside it at once for 1.5 s (`nudgeUntil`,
  the app drawing until then), and clicks within 0.5 s after the third are ignored, so a fourth
  of the same burst doesn't turn them off again. They are a second `MenuSystem`
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
  Above it, Cycle presets: the video menu's Visualizer > Cycle Presets (`avsCycle`, off by
  default; the OSD says how it cycles when turned on) changes the preset by itself (`cycleAvs`,
  from `pollAvs`), in `avsCycleOrder`'s order: Incremental and Decremental step the listed order
  (not the grid's sort), Shuffle every preset turned on once in a random order
  (`avsShuffled`, the round so far; a new round never starts with the one playing). When:
  once per song (`avsCyclePerSong`: as the path the visualizer shows for changes, followed with
  cycling off too, so turning it on mid-song waits for the next one; Repeat File's loops aren't
  new songs), else after `avsCycleSeconds` (5 to 3600, 30 by default) of the preset showing
  unpaused, counted from frame to frame (gaps over 0.5 s left out) and from 0 again whenever the
  preset changes, by hand too. Automatic changes save `avsPreset` but show no OSD. Follow, at
  the row's right end (`avsCycleFollow`, off by default, so a highlight made to rate or turn off
  rows isn't taken away), makes each automatic change `jumpTo` its preset: highlighted alone and
  centered in the grid unless already in view. The row's labels are short ("s") so it fits at
  `AvsMinSize`.
  The menu's Previous goes back through the presets shown (`avsBack`, up to `AvsHistoryMax`),
  however they came (cycling, Random, a highlighted row: `noteAvs` notes each change from
  `pollAvs`), and Next goes forward again through the ones Previous left (`avsForward`); any
  other change forgets the way forward. Presets turned off or gone are passed over. Past the
  history's start Previous takes the listed order, Next retracing it; past its end Next does.
  Script commands: `avslist`, `avshi i` (highlight; after `avslist`), `avstoggle i`, `avsrate i quarters`, `avsfps i rate`,
  `avssort column [desc]`, `avsctx rows|header|empty x y`, `avsadd paths`, `avsremove i`,
  `avsstep 1|-1|0`, `avsfind text` (as typed in the search), `avsdump` (also whether the window
  is open, the search, the beat threshold and sensitivity, the cycling settings, its clock,
  shuffle round and the grid's highlight).
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
- Covers: mpv finds the picture named after an audio file itself (`cover-art-auto`, with `cover-art-whitelist` emptied). Options' folder pictures are the app's (`folderpics.nim`, `addFolderPicture` in the `on_preloaded` hook, adding the picture found as an album-art track, or taking mpv's when it's the same file): foobar2000-style patterns, one per line, tried top to bottom until one finds a picture, relative to the file's folder (`art/*front*.*`, `../folder.*`, `%album%.*`, `jk_$substr(%filename%,1,4)_5_b.png`, `[...]`). `*`/`?` are wildcards only where the line writes them (a field's value is literal, its slashes become `_`), every segment matches letter case aside, a folder's matches go in name order, and only picture files (`ImageExtensions`) count. A line naming a field the file doesn't have (from mpv's `metadata`, outside `[...]` or a `$if` branch not taken) or an unknown function is skipped, so `%album%.*` never becomes `.*`; a line whose last segment has no `.`, `*` or `?` gets `.*` (the old names, `folder`). The patterns are module state shared by every player (the standby swaps with the main one). `pickCover` chooses among the pictures in the `on_preloaded` hook (`coverTrack`): the one named after it with Show Front Cover (file) (`showFileCover`, `Player.fileCover`), else the front cover inside (picture types read by `coverart.nim`, as mpv takes the first), else the folder picture. With Show Front Cover (file) off, the named one is never shown: if it's the only picture, the file gets `vid=no`, or mpv would take it.
- Moving covers (animated GIF, APNG, WebP): mpv shows a picture track's first frame only, so it still shows that (the window fits it, and screenshots and video filters see it) while `animpic.nim` decodes the picture and the app draws the frame due over the picture's rect (`drawAnim`), panned, rotated and sized with it. The picture comes from the file beside (track codec `gif`, `apng` or `webp`), a quick cover's own file, or for one inside the file from its ID3v2 or FLAC picture by its place among them, read only when their count matches mpv's tracks. GIFs are `gifanim.nim`'s: pixie's decoder doesn't lay frames over the one before (most GIFs store only what changed) and turns a disposal-2 frame into a blank one. APNG frames are made into PNGs of their own (the file's IHDR at the frame's size, its PLTE/tRNS, the frame's IDAT/fdAT data) for pixie's decoder, then laid on with their blend and dispose ops; 16-bit and interlaced APNGs, which pixie can't read, stay still. FFmpeg can't decode an animated WebP at all (it skips ANMF chunks, so not even the first frame), so those go through libwebp's `WebPAnimDecoder` (`libwebpdemux`, `dlopen`ed: bundled in the AppImage, not shipped on Windows yet, where an animated WebP can't be shown). Frames are decoded as they come due, at the picture's own delays (10 ms or less taken as a tenth, as browsers do), playing or paused, and kept once composed while all of them fit 64 MiB; a bigger one composes each frame again every time around (~2 ms for an 800x800 GIF). The OSD goes to the OSD layer meanwhile (`osdApart`), as mpv's own is in the picture underneath.
- Video frame clicks: a click plays or pauses on the button's release (`videoPress`), so a double-click's first click has already done that by the time `DoubleClick` arrives (on X11 with the second release). The double-click undoes it (`togglePlay` again, the "Paused" OSD cleared) when that click came less than a second before (`videoClickAt`), then toggles full screen; a click on a stopped or ended file (which starts it over) isn't undone. `playdump` (MMP_SCRIPT) prints paused, stopped, full screen and the time. Test kit: `tmp/dblfs/` (`run.sh BIN NAME`, real double-click through libei).
- Quick covers: a picture file dropped on the video frame, or pasted with Ctrl+V (a file on the clipboard, or a picture itself: a browser's Copy Image, read with `wl-paste`, `xclip` or windy on Windows), while the file playing shows no picture of its own (`quickCoverAllowed`: sound alone, a cover, or a video with its track off) is added as an album-art track titled "Quick cover" (`addQuickCover`, a file-local `vid`; the render context is made first, as a file opened without video has none). An animated WebP is added as a PNG of its first frame (in the cache, `quickCoverStill`) and moves through `animpic`. Elsewhere, or on a playing video, a dropped or pasted picture opens as before. Show Quick Cover switches between it and what showed before (`qcPrevVid`), at once: mpv takes a moment to set a picture up again (~0.25 s for a 6000x6000 JPEG), so once the quick cover first shows the app takes it as mpv decoded it (`screenshot-raw video`, asked for in the background with `takeShot`: synchronous it deadlocks, as libmpv's video output takes it through the renderer, our main thread; shrunk to 2048 pixels a side) and draws that (`qcBridge`) from Show until 0.1 s after mpv's video is set up again (`Player.videoConfigs`); a moving one's frames are kept while it's hidden (`animStash`). `pollQuickCover` reads only the track list mpv sent: a property read every frame waits while mpv sets a picture up, and held up the very frames meant to cover that wait. The front cover settings leave it alone (`pickCover` skips a shown one, `coverPictures` never counts it). It goes once another file opens or this one opens again (`pollQuickCover`), unless Save Quick Cover keeps it in `quickcovers.json` (file -> picture, read from where it is): the `on_preloaded` hook then adds it as the file opens (`Player.quickCoverFor`), before mpv shows another picture. Pasted pictures are kept in the config folder's `quickcovers/` (named by their bytes) and deleted once nothing shows or keeps them. Clipboard bytes are read with `startProcess`, not `execCmdEx`, which rejoins lines with "\n" and breaks a PNG's signature. windy's X11 `getClipboardString` waited forever when the owner refused the text (only a picture on the clipboard): `patches/windy.patch` takes a refusal as no text and gives up after 2 s.
- Reverse playback (the Play button, `playButton`): while `Player.backward` the button shows `playrev` (the play symbol mirrored) in cyan (`colLoop`), and a click turns forward (playing if paused). Its right-click menu (`cmPlay`) has Enable reverse playback (`reversePlayback`, off at every start unless its Always is on): with it on, a click while playing forward turns backward (not in a synchronize group, whose clock only runs forward). Playing backward needs what Ping-Pong does (`backwardReady`). A file's reading (`Player.setDemuxing`, `DemuxMode`): mpv's demuxer thread misses the call to read further back now and then once it has read to a file's end (a turn there stood still 1–2.5 s, for good with mpv's cache on, as for a network or FUSE drive), so whatever plays backward is read in mpv's core (`dmThreadless`, cache off: the standby facing backward, `standbyDemux`; sound alone, which turns around itself at once, opened so by `playIndex` or reopened so when reverse playback is turned on with it open); but read that way nothing is read ahead, and on a slow drive playing forward stood still at each hiccup (tmp/slowfs: a FUSE drive at 40 MB/s with 0.3 s hiccups, 111–564 ms stand-stills), so a video playing forward reads ahead as with reverse playback off (`dmAhead`), the standby playing it backward. When it has to turn itself (the standby not to be had: an A-B loop, a file's very end, Ping-Pong's fallbacks, paused), `turnSelf` opens it again facing backward, read in mpv's core (`reopenHere`'s `back`; during a seek or an opening, once that's done: `selfTurnAfter`). mpv's seekable cache would keep what it read, but a seek into the kept end of a file (its last keyframe's span) never gets going, one stream waiting on the other, which gets no new packet (demux.c's "delaying stream"), a threadless core spinning for good; and `drop-buffers` before such a seek leaves the decoders reading the emptied demuxer before the seek runs, which spins too (tmp/rvs/eofprobe.py, sblat.py). `pingPong` keeps `hwdec` off (`softDecode`) while a ping-pong loop is on or playing backward. Links keep the demuxer thread and cache (streaming needs them), and two things let them keep up backward: YouTube sends a request left open to the file's end slowly (~0.25 MB/s, plenty forward, but each step back needs seconds of the stream at once) and a bounded one at full speed, so FFmpeg asks in 10 MiB pieces (`stream-lavf-o` `request_size`, as yt-dlp does: forward, streams buffer faster too); and once it runs out of what it has read, mpv goes back `demuxer-backward-playback-step` (60 s by default) and reads all of it before playing on, which `Player.setBackward` (`setBackStep`) makes ~4 MB of a link (5–60 s, by its bitrate). Before, a link played backward stood still for 5–14 s at each step, or for good. A file reads fast enough, but what's read waits in mpv's packet queue (150 MiB): 60 s of a file over ~20 Mbps (a screen recording) filled it, and backward playback stood still for good ("Backward playback is likely stuck/broken now"), the standby's turn too slow and the player turning itself hanging in mpv's core. Without a cache, mpv drops every packet before the one it reads, the very ones it wants next backward: each span of the video, and each batch of the sound, reads its step again. mpv's batch of sound is 10 packets, a fifth of a second of AAC or MP3: by far most of those reads (an OBS recording: 125 in 20 s). `Player.backBatches` (applied as tracks are known, `applyBatches`, to a threadless player): ~a second of sound by the codec's packet size, 10–100 packets, for codecs whose every packet is a keyframe (TrueHD's keyframes are its sync frames, ~15 a second: 1024 of them overflowed mpv's queue; mpv takes 1024 at most), 22 reads in 20 s; and a video of keyframes alone (`IntraCodecs`: ProRes, APV, DNxHD, MJPEG...), decoded one frame at a time with the decoder flushed after each, used one of its threads (ProRes 1080p60 at 173 Mbps played backward at 0.88x, APV stood still 0.1 s at each step), so 8 frames at a time (as long as that fits twice in the reversal buffer; 30 stood still 70 ms at each batch, none of it shown before it's all decoded), and the keyframe bridge stays off for it (`Player.intraVideo`). So a file's step is ~40 MB by its size over its length, 2–15 s (keyframes further apart take two goes; mpv can't play the step it went back for before it's read it all, in its core: ProRes, 5 s stood still 0.13-0.2 s), 10 s while its length isn't known; for a video of keyframes alone 0.25–1 s, set again as its tracks are known (read back 8 times a second, ProRes at 2 s stood still ~70 ms each second, at 1 s never); `sendStandby` sets it again once the standby has the file's path (it was set for the one before). Turning a video backward itself (`turnHere`), hardware decoding goes off in the same command list (`Player.turnAt`'s `soft`): a hardware decoder can't hold a span's frames ("No decoder surfaces left") and failing over on its own stopped the picture for a few tenths of a second. A keyframe span's frames wait in `video-reversal-buffer`, raised from 1 GiB to an eighth of the RAM (6 GiB at most; only what a span holds is taken): a 4K60 span is ~3.7 GB, and frames that don't fit are dropped, the picture standing still and then jumping. `pingPong` turns forward only when a loop goes off, so a backward the button set lasts. Reaching the start backward outside a ping-pong loop, `handleEof` turns forward and pauses there. Playing, the button's turns come at once (next entry: from the spot heard; a video's as soon as the standby has its picture there, ~0.2-0.35 s for 1080p with keyframes 8 s apart); the button shows the way playback is about to go (`heading`), and a second click before a video's turn calls it off. Under it, Always (`reversePlaybackAlways`, saved) keeps it on from one session to the next; turning Always on first asks, in a Yes/Cancel window (`showConfirm`, `ovConfirm`, a reusable question window whose text takes blank-line paragraphs and `- ` bullet points, wrapped in full, the window as tall as they need: `confirmLayout`), warning in plain words of more RAM and video memory (each video loaded up to three times: the standby and the keyframe bridge), and more CPU and GPU work. Yes turns both on; turning Enable reverse playback off turns Always off too, and Always goes off without asking. Script command: `playbtn` (a click); `acmenu play`/`acaction play` for the menu; `cfmdump`/`cfmanswer yes|cancel` for the question window.
- Seamless turns (`turnTick` and the procs before it; `Player.setTurnFades`, `Player.heardPos`): mpv turns around with a seek that drops the sound queued for its output: a 40–65 ms jump with a click, and in a ping-pong loop with video 20–40 ms of silence. The Play button's turns (`turnTo`, with Enable reverse playback on) come at once instead, as a turn that waits for a crossfade can't: mpv has ~0.44 s of the sound filtered ahead of what's heard (0.2 s `audio-buffer`, 0.1 s PulseAudio's buffer and the queues between), out of any fade's reach. Without a picture the playing player turns itself (`turnHere`, `Player.turnAt`): direction and an exact seek to the spot heard (`heardNow`: `audio-pts` as of now) go to mpv in one command list (`set play-direction ...; seek ... absolute exact`), as mpv makes its own seek for a turn the moment the direction changes (to its time, ~60 ms behind what's heard) before taking a seek sent after it, then seeks again (a few tenths of a second more with a picture, and now and then a packet further on). mpv drops the sound it has queued, and threadless, the sound going the other way follows with no gap, within a fraction of a millisecond of the spot heard (FLAC, MP3, AAC; now and then a PipeWire cycle, 21 ms, later as the drop lands; MP3 going forward again starts after its decoder's 10-30 ms warm-up). Being the mirror image of what was heard, the wave carries on unbroken: no fade (a fade-in from silence would only break it, by a simulation on music, `tmp/revsnd/clicksim.py`), except when the sound isn't mirrored exactly (`smeared`: the equalizer, or pitch correction at another speed): it fades in over `TurnHereFade` (10 ms) then. With a picture, the playing player turning itself would stop sound and picture while mpv decodes back from the keyframe before the spot (0.3-0.5 s for 3 s of 1080p H.264), so the standby is kept parked (`parkTick`, `park`, `tnParking`/`tnParked`): the file open, threadless, facing the other way, paused (the player a turn took over from stays as the next one's, as it is). A click sends it (`seekTurn`) to where playback will be once it's there: the sound heard plus its learned seek time (`tnSeekPrep`, up at once when slower, down slowly; ~0.15-0.2 s for that 1080p file) and `TurnSeekMargin`, plus `TurnOpenExtra` when it has the file to open. The spot is put on the start of a frame, on the grid of the one shown (`frameRate`), the standby sent a little inside it: mpv starts the sound with the frame holding the spot, up to a frame's time away. Its sound fades in from wherever it starts (`setTurnFades`' `startIn`: `afade` by sample from the filters' first, made anew by the seek), and once the sound heard gets there (a short sleep closes the last pass), the playing player pauses, its sound breaking off, and the standby plays on (`seekOver`): within ~5-20 ms (an audio cycle). A standby slower than 2.5 s, or one that can't serve, gives the turn to `turnHere`; pausing meanwhile turns it the plain way (silent). Ping-Pong's turns (`pingPongTurn`: at B or A, or `TurnEdge`/`TurnEdgeEnd` inside a file's start and end) go to the standby (`planTurn`). Opened facing the other way (threadless; `hwdec` off backward) a run-up past the turning point, it gets `@turn` in its `af`: an `afade` in centered on the turning point, silent before it (afade takes no negative times, and backward mpv's times are negated: `asetpts` shifts them by `TurnShift` around it). It's set playing that run-up ahead, less its learned start delay (`tnDelays`, by direction, picture and file edge), and `alignTurn` measures how far it is from the playing player's mirror image (the sum of both `audio-pts` stays twice the turning point; within ~0.2 ms of recordings), then moves it to the sample while it's still silent: `atrim=start_sample` when late, `adelay` + `aformat` + `asetpts` when early. (`adelay` takes planar formats only, and filters putting out another format than they get have mpv reopen its output, losing ~0.27 s with `gapless-audio=no`: hence `aformat` back to `Player.turnFormat`; files afade can't take turn the plain way. A speed change can't do it: mpv filters in ~0.1 s bursts, so how much one covers is unknown.) The playing player's fade-out goes into its `af` (`armTurn`) at least `TurnArm` before the turning point, as mpv filters ~0.3 s ahead of what's heard; changing `af` is seamless, and mpv keeps unchanged filters (the equalizer's) running. The crossfade is 5 ms once lined up, 20 ms otherwise or with the equalizer on (IIR filters on reversed sound don't give the mirror image of their forward output, ~1 ms apart: a short crossfade leaves a hole on a steady tone), 80 ms with pitch correction at another speed (scaletempo2 builds its sound from ~20 ms pieces and can skip a shorter fade). At the turning point the standby takes over the picture (`turnOver`); the old player plays on unheard until its fade-out has been heard (`heardPos`: the picture's time runs ahead at higher speeds) and waits paused as the next standby. Every seek clears a player's fades first (`clearTurnFades`), as a seek recreates the filters from `af`. A turn's fade-in leaves `af` once heard (`tnFadeIn`), counted from its seek's restart: before that, the player's time is still the old way's. At a file's end the standby can't be lined up in time (sent backward, mpv starts from the start of the packet holding that point, up to ~0.1 s short, and not from the last 60 ms), so turns there land within a PipeWire cycle behind a 20 ms crossfade. Turns go the plain way when the standby can't serve (a loop's standby or loop sound, step frames, links, a synchronize group, too close to a file's ends) or isn't ready in time; seeking, stopping or opening a file calls a turn off, and pausing makes the Play button's turn at once (silent then). `MMP_TRACE_TURNS=1` prints each turn's steps to stderr.
- Seamless A-B loops (`seamlessLoop`, `standbyStep`, `takeOver`; `sb*` fields): the standby waits paused before A and takes over at B, the old player going back to wait (loops up to `LoopSoundMax`, 60 s, get their sound from the loop sound instead). Swapping the two players' mutes at B left a silence as long as the output's latency (~90 ms on a null sink, `tmp/abgap`): a mute only reaches sound mpv hasn't handed to its output yet, and the old player's seek back drops what it has queued. Now the sound changes hands as a seamless turn's does: the standby gets `@turn` with an `afade` in centered on A before every seek that sends it to wait (`standbyAt`'s `fadeIn`), is unmuted just before it starts its run-up (silent before A), and waits `StandbyRunUp` (1 s) before A, less for loops too short to leave its seek time (`loopRunUp`). Its start is timed by the sound heard (`heardNow`; the picture ran ~40 ms ahead of it), `LoopLate` later than learned, so `alignLoop` can measure it against the playing player (`loopLate`: both `audio-pts`) and put it in line by dropping samples only (`atrim`): `adelay`'s held silence would be lost once the fade-in leaves `af`, a skip. The first measurement sets both players' `startDelay`. The playing player's fade-out at B goes in at least `LoopArm` before B (`loopFades`; kept while paused: an `af` change as playback resumed held its sound back 0.3 s), and the player taken over from plays on unheard until it's been heard (`sbDraining`). Measured on the user's 865 s loop: the seam within ~1 ms on both sides of a 20 ms crossfade, both sides bit-exact to the file, at the same gain. A run-up cut short (paused or sought within it) is sent again as long as there's time for (`sbPrep`, its learned seek time), unaligned (tens of milliseconds within the crossfade); too close to B (`sbMissed`), mpv's own jump does it. `tmp/abgap`: `run.sh BIN TAG STEPS LEN` records the null sink, `ana.py` lists silences, `seam.py CAP A B` finds the seam against the decoded file, `sides.py` fits each side.
- Keyframe bridge (`bridgeFrames` and the procs before it; `rb*` fields): played backward, mpv decodes a keyframe's whole span before showing the last of its frames, and starts on a span only once the span after it has all been shown (`f_decoder_wrapper`'s reversal queue). So at every keyframe the picture stood still while it decoded, then skipped frames to catch up, the sound playing on: ~0.1 s for 1080p60 with keyframes 4 s apart, 0.3-0.35 s for 4K60, ~0.25 s each second for 1080p60 AV1, longer for the first keyframe after a turn or a seek (mpv reads back from there too: ~0.3-0.65 s for 1080p60). Nothing in mpv starts that decoding sooner: its decoder thread (`vd-queue-enable`) leaves backward playback threadless broken (no picture, or an abort). Instead, a player of its own, without sound (`a.rb`, `newPlayer`'s `pictureOnly`: no scripts, paused, speed 100; made in ~3 ms the first time it's wanted), takes the frames just before the keyframe playback goes back to next, ahead of time, as step frames are taken (`takeBridgeFrame`, in the GL pass, the time and the picture both new before one's kept): a keyframe seek (`absolute+keyframes`) from the shown frame's time finds the keyframe (`rbK`), another from just before it the one before (`rbBefore`): the span between (`rbSpan`) is what the player decodes there, and the longer it is, the longer it stands still (4K HEVC 10-bit: ~0.1 s a second of span, 1 s for 8.5 s; learned to cover only the stand-stills seen, the bridge fell 0.3-0.5 s short at long spans, the AV1 clip 0.2-0.5 s). An exact seek goes to `rbRate` (stand-still per second of span, learned: up at once but at most 1.6 times, down slowly, 0.01-0.5) times 1.25 the span, plus two frames, before it (0.25-3 s; the span unknown, `rbNeed`, learned as a time; both anew for each file, `rbLearnt`, generous until then: 4K stands still ten times as long as 1080p; at least `BridgeFirst`, 0.7 s, for the first keyframe after a turn or a seek), a third of a frame off the frames' grid (until it lands, mpv tells the spot asked for as its time), going forward, hardware decoding as set, and `frame-step` takes it on to `BridgeAfter` (3) frames past the keyframe, a texture each frame at the window's video size (within Options > System's memory for loop frames, the ones furthest back let go first), with a few of its pixels (`pictureSig`: a 32x18 nearest blit read back). ~0.1-0.25 s for 1080p, 0.4-0.6 s for 4K; spans shorter than that can't be bridged (`too slow` in the trace). While a video that could play backward plays (`backwardReady`, a local file), the bridge player has it open, paused: setting up its picture (its render context, ~0.1 s in the window's thread) is better done at opening than at the turn; unused `ContextIdle`, its file and render context go. mpv tells a frame's time (`time-pos`) as it hands the frame on, up to two frames before it's drawn (one waits in its output's queue, one for the window), so the playing player's picture is told apart by its pixels: near the keyframe each new picture it draws (`rbPicAt`, and when it was due, `rbPicDue`, from `frameDue`) gets a `pictureSig`, found among the bridge's (`bridgeMatch`: the same frame differs by rounding only, ~0.03 a value between hardware and software AV1 decoding; the next, in a still scene, by ~0.1). No new picture `BridgeLate` (1.25) frames after the last was due, and none waiting, it stands still (`rbStaleAt`; not sooner: the player's last picture before standing still is nearly always the frame after the keyframe, but mpv doesn't always stand still there, a short span decoded in time, and taking over as that's drawn showed the keyframe's picture after a newer one of the player's, a step back): the clock (`bridgeClock`, mpv's clock, which reading waits on nothing: the playing player's core is busy decoding, and any sync call to it would hold up the window) runs on from that picture's time and due time, and the bridge frame due by it is shown (`bridgeDue`, `rbShow`, in `drawVideo`), from the one right after the player's last; that one not found, it's taken as a frame before the time told, and only frames past that time are shown (an older picture after a newer one would be worse than a frame skipped). Past the bridge's earliest, that one's held. The player's own pictures come back (`bridgeCaughtUp`, asked again right after each one's drawn, so the next isn't missed) once one's at or past the frame due (by its pixels, or else two frames before the time told, the most it can be), or as soon as it draws again with nothing of the bridge's due (it didn't stand still after all), or after `BridgeStale` (3 s). Checked on a clip with each frame's number in its top rows (`tmp/rvs/numclip2.mkv`; `tmp/rvs/mkcheck.sh` builds with every picture drawn read back, `MMP_TRACE_TURNS=1 RBCHECK=1`, `tmp/rvs/chk.py` lists steps back, skips and hand-overs): over 60 hand-overs, each picture in order, none skipped or out of order. Ping-Pong A-B loops skip a keyframe before A (playback turns before it). The standby can't take the frames: parked for a turn, its sound makes every step wait ~60 ms, and its sound turned off and on again (`aid`) left the next seek's decoding broken (AV1 hardware decoding "No sequence header available", failing over and setting up Vulkan in the window's GL pass, ~0.35 s). The system media controls' title, artist and album are observed (`Player.info`), not asked for: a sync read waited out a keyframe's decoding in the main loop (0.2-0.3 s for 4K). With `MMP_TRACE_TURNS=1`, each frame shown is traced (`shown 0|1 TIME`: the player's own, by the time told, or a bridge frame), and the bridge's fills and stand-stills; `tmp/rvs/back.py` reads that for the Play button's turn (click to the first frame going backward) and the freezes, skips and steps back after it (by the times told: the player's own lag their pictures), `tmp/rvs/suite.sh` runs five videos backward, `tmp/rvs/bigsuite.sh` six big ones (ProRes, APV, an OBS recording, 4K HEVC and HDR films; `BIGDIR` for tmp/slowfs's slow drive); `MMP_NO_BRIDGE=1` shows mpv's stand-stills as they are.
- Stop / Pause after current (the Stop and Pause buttons' right-click menus, `cmStop`/`cmPause`): `afterCurrent` (session only, one of the two at a time) is read by `afterEof` before anything else. Stop runs `stop` there (no queue, no next entry, no After playback action); Pause lets the usual next entry open and pauses it right after `playIndex` (`pauseOnLoad` pauses it again when it has loaded and sends the synchronize group `pause` instead of `play`; Play clears it), and with Repeat File seeks the file back to 0, paused. While either is on, `applyLoop` leaves `loop-file` off so Repeat File reaches its end, a ping-pong file ends at its forward end, and the gapless queue and a short file's delay stand aside. Each goes off once used unless its "Preserve the above after current" (`stopAfterKeep`/`pauseAfterKeep`, saved) is on. The button shows a dot (`dot6`) at its symbol's top right while on: white, indigo (`colAccent`) when preserved. Script commands: `acmenu`, `acaction`, `acdump`.
- Gapless audio: `gapless-audio` stays `no` (in gapless mode mpv reports the end with ~0.25 s still queued, which opening the next file would cut off), except when mpv has the next file itself. In the last 15 s of an audio file (an audio extension or a cue track) played straight through, `queueGapless` appends the entry `afterEof` would play (the playlist's next, the first when repeating the playlist, or the folder's next with Play next file in the folder) to mpv's playlist and turns gapless on (`weak`: a change of sample rate or channels still reopens the output, with a short gap); `prefetch-playlist` opens it ahead. Videos, the queue, loops, ping-pong, a short file's delay, Stop or Pause after current and synchronized slaves keep the app's own path. mpv then goes on by itself; `Player.wentOn` takes the new path from the `end-file` event and `adoptGapless` runs `playIndex` without opening the file (`adopting`). `handleEof` stands aside while a file is queued, as `eof-reached` can show for a moment before mpv moves on. Gapless is turned off again only once the new file plays (`settled`): turned off while mpv changes files, the new file's audio setup would drop the sound still queued.
- Seek bar clicks: a click seeks exactly once, on press, so the picture never visits the keyframe before the spot; dragging seeks to keyframes between marks and exactly on a mark snapped to. `Player.landOn` keeps the time shown (seek bar, status bar, OSD) on an exact seek's target until `landingOn` sees it land: mpv's `time-pos` stays the old one for a while, and a keyframe's after an earlier seek.
- Paused on the sound alone (no video, or a cover), mpv's `time-pos` after an exact seek is the output's, short of the spot by what it buffered (0.1-0.2 s), though playing goes on from the spot: `Player.soundHold` keeps the time sought until playing or another jump. Exact seeks give mpv the time to the microsecond, so a bookmark's sample or frame is where they land.
- Waveform seek bar (its menu's Waveform; `src/waveform.nim`): the sound playing is decoded on a worker thread, by ffmpeg into a float WAV on a pipe (the audio track picked, `-map 0:a:N` counting the file's own audio tracks; an added track's file; a cue track's stretch via `-ss`/`-t`) or for MIDI by FluidSynth with its SoundFont. Each of 32768 buckets (1 ms at least) keeps the highest sample and the RMS of every channel; `pollWaveform` takes them in as they come, so it fills from the left, and keeps the last four decoded whole. Links show the plain bar. Its top edge, dragged up, makes the bar taller (`waveformHeight`), never shorter than the plain bar; turning it on or off resizes the window by the difference, as View > Seek Bar does.
- Show Marks off hides chapters, bookmarks and loop marks unless the loop is active (both marks set and on), and they are neither snapped to nor picked by the seek bar's menu; the hover label still names the chapter it's in.
- Synchronized frame steps: the master steps and names the time it landed on; slaves go to the frame that puts them at that time plus their offset rather than stepping themselves, so they can't drift at either end of a file. A slave's press only asks the master. A slave's offset is signed: positive is ahead of the master, negative behind it (it waits at its start until the master gets that far).
- Frame steps: mpv's `frame-back-step` decodes from the previous keyframe on every press, so
  it scales with keyframe spacing. While paused, the hidden standby player steps through the
  frames around the position (up to `loopFramesMB`) and each is kept in a texture; a step shows
  another texture and the main player follows with a coalesced exact seek, so `Player.timePos`
  is held (`holdTime`) meanwhile. A frame is only kept once mpv has given both its new time and
  a new picture: they arrive separately, in either order. The window refills near its edges.
  Links, 360° video, A-B loops and CPU rendering use the plain mpv step, as does a press in the
  second or so after pausing, before the frames are in.
- Sample steps (`sampleStep`): with no video track on (or only a cover), `,` and `.` pause and
  seek exactly one sample back or on, at the decoded rate (`audio-params/samplerate`). mpv
  drops the decoded samples before the time asked for, rounding down, so the seek goes a quarter
  sample in (9 decimals). A step counts from where playing would go on, never from mpv's
  paused time alone: after a seek made while paused, mpv's `time-pos` (and `audio-pts`) is
  short of it by the audio output's latency (~0.1 s: `playing_audio_pts` takes off
  `ao_get_delay`, which counts the device's latency while nothing plays), so counting from it
  went back ~0.1 s with either key. In order: the sample last stepped to (`ssAt`), while nothing
  else moved the player and it hasn't played since (`Player.resumes`); else the last jump's
  target (`Player.noteTarget`/`heldTarget`, set by exact, relative and percent seeks, Stop and
  chapter jumps), until mpv's own time (`mpvTime`) goes past it: `hr-seek=default` makes every
  seek exact on the sound alone, relative ones from mpv's lagging time, and a chapter jump lands
  on the first chapter start at or after mpv's time; else `timePos` (pausing while playing has
  no lag). FFmpeg's module seeks land on a row's start instead, usually after the target
  (`modstream.landsAt` asks libopenmpt the same), so a module FFmpeg plays is opened again as a
  module stream (`streamModule`, as the tracker button's settings do) at the sample: its seeks
  are exact. Verified with a ramp signal (each sample's value its index) through a PipeWire
  null sink (`ao=pcm` and `ao=null` have no latency and hide the lag): the first sample heard
  on resuming is the one stepped to, after paused seeks, arrow keys, Stop, steps while playing
  and fast or slow presses (`tmp/sstep/case.sh`).
- 360° links: `detectSphere` needs a file, so `Player.findSphere` asks yt-dlp's JSON
  (`linkSphere`), per format and not per video: YouTube renders a 360° video's lesser DASH
  formats through a fixed camera. Those are noted as nothing, and so are its HLS formats, which
  stay on the sphere, except on VR180, where they're flat too. `meshHls` covers that: only a
  mesh format's header tells VR180 (a mesh per eye), read with curl, mpv's demuxers skip it.
  Meshes aren't an approximation: EAC and VR180's warped layout are both drawn from the mesh
  itself (`drawMesh`). Saved parts note their `Seg.sphere`, as opening them skips yt-dlp.
  ffmpeg drops meshes when merging, and needs `-strict -2` for an `.mp4`'s sv3d: a downloaded
  mesh video, or `equi` in `.mp4`, comes out flat.
- Saved parts' seek entries (`src/mkvcues.nim`): mpv's `dump-cache` writes a link's saved parts
  through FFmpeg's Matroska muxer, whose Cues list the video's keyframes only. With the video track
  off (a quick cover or the visualizer showing, Video Track None), mpv's `demux_mkv` seeks by the
  audio track's entries, and finds the one it keeps for the file's first block (audio): every seek
  went back to the file's start, and hr-seek decoded all the sound up to the spot (0.65 s at 10
  minutes in plain mpv, 3 s in the app at 12 minutes, more the further in). `playSaved`, and File >
  Save before copying a saved file, run `indexAudio` on the files first, once a session each: a
  CuePoint per cluster for every audio track the Cues leave out, at its first block's time. The new
  Cues go where the old ones were (FFmpeg writes them last, the SeekHead keeps pointing there) and
  the Segment's size grows to match; nothing else in the file changes. A file mpv is still writing
  (its Segment size unknown) or laid out otherwise is left as it is.
- Library (`src/library.nim`; the panel is `libraryPanel`, Options > Libraries `librariesPage`, Custom...
  `src/libtypes.nim`): libraries are `cfg.libraries` (name, paths, kind audio/video/all/custom with
  `exts`, hidden), seeded once with Video, Music (the XDG folders) and Sounds (`/usr/share/sounds`,
  `%WINDIR%\Media`). Every library feeds one index (`LibIndex`): their paths are roots, normalized
  without touching the disk; folders inside another listed folder aren't walked again, only checked,
  and each walk keeps the files of every library's types, so a folder is read once however many
  libraries list it. A library's view (`members`) is a filter over the index: inside its folders and of
  its types, or listed itself, minus paths found missing (their files stay in the index, tags and all,
  for when the drive comes back). The index is saved to `~/.cache/majestic-media-player/library.json`
  (saved while nothing plays, 20 s after a change, else after 10 min, and at exit), read on a thread
  when the panel or the Options page is first shown, then every path is walked again; a file whose size
  and time are unchanged keeps its tags.
  Nothing touches a library path on the main thread (Options' missing/not responding comes from the
  index, file dialogs start at home unless the path was found): a share that stops answering would
  block any call into it. Walkers (three at work at once) and a tag reader are threads started as
  needed and never ended (see the ReplayGain note on Nim's allocator); they post events under a lock
  that `poll` swaps out (under 0.1 ms per call while a share hangs). A walker or reader that shows no
  sign of life for 8 s is marked not responding, its path says so, and another thread takes the rest
  of the work (12 threads at most, ever); a path whose walk is still going or stuck isn't walked again,
  so rescans don't pile up threads on it. A walk posts what it found before each folder, so files
  listed before a folder that hangs still show. Tags are read by a headless mpv with no track picked
  (nothing decoded) in its `on_preloaded` hook, as with no track mpv gives up before `file-loaded`;
  one that doesn't answer in 10 s is left behind (closing it would wait too) and after two such files
  a root's others are left unread. Workers run at `SCHED_IDLE` with the idle I/O class (Windows:
  background mode), and while a file plays (or is paused partway) the reader rests 120 ms between
  files. The rows in view are read first. The panel's list is rebuilt when the library, sorting or
  index changes (now and then while files and tags pour in, less often while playing); typing in the
  search only filters the sorted libraries (each file's lower-case search text is cached). At exit the
  windows are unmapped before the process ends: a thread stuck in a share keeps a process alive until
  the share answers, and its windows would stay up, frozen.
  The panel's bottom line shows the selection on the left, as the playlist's does (`libSelectionLine`:
  "N files selected" and their total length, `+` while some files' tags aren't read yet), and on the
  right, right-aligned, the files listed and their length or the scan's state (`libraryStatus`);
  short of room each keeps half, or more where the other needs less. It has a bar on the right while
  a scan or the tag reading is under way (`libraryStatus`'s progress). A walk is measured against the files the index had under the folder
  as it began (`RootInfo.expected`, the last walk's or the saved index's; `scanProgress` sums the
  folders walked since the scan began, `runFrom`); with none known (a folder never walked, the saved
  index still loading) the bar slides back and forth, redrawn at 30 fps (`libBarSliding`). Tag
  reading is the tags read since it last ran out of files against those and the ones left
  (`readProgress`, `readDone`). Left of the bar are the percentage and, from two seconds in, the
  time left (`libTimeLeft`: the time spent against the progress made since that scan or reading was
  first seen, `App.libEta`, remade once a second; the time first, then the percentage, dropped when
  the panel is narrow), and right of it an X that cancels (`LibIndex.cancelScan`): the walkers stop
  at their next check (every folder and every 64 entries; `Shared.cancelGen`, walks up to that
  generation), the tag readers' queue is emptied and nothing more is queued (`stopped`, cleared by
  the next walk: Rescan, a path added, the next launch). A cancelled walk keeps the files it found
  and drops none for not being found; its folder goes back to its state before the walk
  (`RootInfo.prior`). A walk stuck on a dead share can't be stopped: its folder is marked
  `cancelled` until its thread returns, and a Rescan meanwhile walks it then (`rewalk`). Kits:
  `tmp/libprog/progtest.nim`, `tmp/lib/canceltest.nim` (cancel during loading, mid-walk, Rescan
  right after, tag reading).
  The libraries' column is a tree (`libTreeRows`, `LibNode`): All, then each library with the
  folders holding files it lists, made from the index alone, never the disk (`folderTree`: a
  library's listed folders, those inside another being its subfolders, and below them every folder
  a member file lies in, in natural name order, with file counts for the tooltip). A library of one
  folder shows that folder's subfolders straight under its name. The trees are made again as the
  rows are (at once for files gone, now and then while files pour in; `refreshLibraryTrees`).
  A click on a row picks it (`libPick(lib, folder)`: `libraryFolder` beside `libraryShown`), a click
  on its arrow or a double-click on it expands or collapses it (`libraryExpanded`, keys
  `"<library>\n<folder>"`, renamed with the library by `renamedInTree`); collapsing a node holding
  the folder picked picks the node. A folder picked lists the library's files in it and below
  (`libraryRows` keeps those `under` it while the search's `within:` is that library alone and it
  has one `in:` tag); another library (a click, the search's `within:` tag) leaves the folder. Right/Left expand and collapse in the
  column (again: the first folder, the one holding it). A folder's menu (`lcFolder`) plays its files
  or adds them to the playlist (`libFolderPaths`, sorted as the list), opens the folder or copies
  its path.
  Opening or closing a folder, in the tree or a Group by Folder header, unfolds over `FoldTime`
  (0.16 s, eased out): `FoldAnim` (one per column, `libFoldTree`/`libFoldFiles`) keeps the closing
  folder's rows in the list until it's done (`libTreeRows(drawn = true)`, `buildLibraryView`), and
  `FoldMap` places the rows: those under the folder show as far as it's open (clipped), the rows
  after it follow its edge (`rowY`, `rowAt` back from a scroll position). The arrow turns from right
  to down in `FoldFrames` atlas images (`fold0`..`fold9`, 20 px, made in `addIcons`; Silky can't
  rotate an image). With Group by Folder, the header of the folder at the top sticks there once
  scrolled past, pushed up by the next folder's header; a click on it collapses that folder and
  scrolls to it, and keyboard reveal keeps the cursor row below it.
  A folder header shows its label as breadcrumbs (`libCrumbs`: the label's parts, each with the
  folder it names, counted up from the group's `dir`, its first file's folder): crumbs pointed at
  their end (the `crumbtip` atlas image, `CrumbTip` × `CrumbH`), the next one's notch the same image
  in the header's colour, the pointed ends drawn last over it. Too many for the room, the first ones
  go into a "…" crumb (lit when it hides the folder picked). The crumb of the folder picked in the
  libraries' column is lit purple (`libCrumbCurrent`; a whole library picked: its listed folders). A
  click on a crumb goes to its folder (`libGoToFolder`: the library listed if it shows it, else the
  first library in the column that does; the folders holding it expanded, then `libPick`); a click
  elsewhere on the header collapses or expands it.
  Its columns are the playlist's (`PlaylistField`), laid out by the same `layoutCells`
  (`columnWidths`) with the library's own set and widths (`libraryColumns`, `libraryColumnWidths`,
  `libraryShowMillis`): a header click sorts (again: the other way, `librarySort` keeps the field), a
  drag moves the column, its edge resizes it, a double-click there fits it (`libFitColumn`), and the
  header's menu picks the columns. Cell text comes from the index alone (`libCellText`; track, disc
  and year from the tags), never the disk. Group by Folder (that menu, `libraryGroupFolders`) puts the
  files under a header per folder, relative to the longest listed folder holding them and led by its
  name ("Music / Album"; `groupRows`, a stable sort by that label, so the sorting holds within each):
  the drawn rows are `libView`, a header being `-(group + 1)`; selection, Shift ranges and the arrow
  keys skip headers (`libFileRow`). A click on a header collapses or expands its folder
  (`libToggleGroup`), and the files area's and header's menus have Collapse All Groups and Expand
  All Groups (`libCollapseAll`): `libraryCollapsed` keeps the collapsed headers' labels, and
  `buildLibraryView` leaves their files out of `libView`, dropping them from the selection (Select
  All and Ctrl+A take the files shown). Play in New Player (Shift+Enter) starts this program with
  `--new-player` and the files, which never hands them to a running player.
  A press on a selected file starts a drag of the selection (`"librow"`, `libDrag`; the files go in
  `rowDragPaths` with `rowDragTab` 0, as no playlist's). Let go over the playlist panel
  (`plPanelRect`, the header and the space below the rows included) they go in at the row boundary
  under the pointer (`libAddToPlaylist`), the top above the rows, the end below them; its tabs and +
  take them as rows dragged from another playlist (`dropRows`, held over a tab shows it). Let go over
  the part of the video frame no panel or bar covers (`videoClearRect`, outlined with "Play N files"
  while over it), they play as a double-click plays them (`libPlay`).
  Search tags are split at commas only (quotes are characters): `within:`/`exclude:` (libraries: a
  name, or every name it begins), `in:` (folders, any of the `in:` tags: `folderValue` makes the
  value lower case, splits it at either slash and drops commas, and it matches when those names run
  on in the file's folders, `dirsOf`: the outermost listed folder's own name and those below it down
  to the file's, `/music/artist/album/`, cached per file beside the free text; so `in:Album`,
  `in:Artist/Album` and `in:Music/Artist` all work; an absolute path takes what's `under` it),
  `hidden`, `size`/`bitrate`/`dimension` + `exactly`/`biggerthan`/`smallerthan`
  (`1.5GB` covers what rounds to it; K/M/G are 1024s for sizes, 1000s for bit rates; a dimension is
  `WxH` or one number for the shorter side, `1080p`, `4k`), `dc:` (date created, `parseCreated`: a date
  to the year, month, day, hour, minute or second, digits run together, `20251010`, or split by anything,
  `2025-10-10 14:30`, in local time, standing for that whole span; `after:`/`>` past its end,
  `before:`/`<` before its start, `>=`/`<=` taking it in; aliases `date created:`, `created:`; the
  file's birth time, `LibFile.ctime`, read by the walk with `statx` on Linux and from `FileInfo` on
  Windows, the last change standing in where the file system keeps none; an index saved before it has
  0 there until the next walk fills it in), `format:`, `filename contains:`, `path:`,
  any other `field:` (the tags mpv reports, `artist` also matching album artist), free text at
  the start of a word (`hasWordStart`: after a space, punctuation or `_`, or between letters and
  digits, so `oni` finds `Oni` but not `Electronic`, which buried what was looked for under
  hundreds of rows; in scripts without spaces, Chinese, Japanese, Korean, Thai and the like,
  anywhere) in the
  name, title, artist, album and folders (`foldersOf`: those below the outermost listed folder
  holding the file, `Artist/Album`, so a search can span them; the listed folder's own name is
  left out, as every file in it would match; a file listed alone, its folder's name). The suggestions offer library names after `within:`/`exclude:`, the
  folders of the libraries searched after `in:` (`folderTag`, depth first), and the tag names
  otherwise. The libraries' column and the search's scope tags go together: a click on a library
  makes the first `within:` tag name it (added in front when there's none) and takes the `in:`
  tags out; a click on a folder (a breadcrumb too) also makes the first `in:` tag name it (added
  after `within:`), as `folderTag` writes it: its names from the library's listed folder down,
  that folder's own name first when the library lists several; All takes both kinds out
  (`withScope`, other tags kept in their order). As the search changes the column follows it
  (`syncLibraryShown`): a `within:` naming a library lists it, none lists All; the first `in:` picks
  the folder of the library listed it names, else the only one whose names end with it (`in:Album 1`
  for `Artist/Album 1`), the folders holding it expanded (`libRevealFolder`); until the index is
  read at launch it keeps trying each frame. A library or folder listed without a tag, as older
  versions saved it, gets one. Searches saved when `in:` named libraries have those tags made
  `within:` once (`withinFromIn`, `librarySearchWithin`). Renaming a library renames it in the search's tags (`renamedInSearch`).
  The search field is a `textField` with `chips` (`libSearchChip`: `hidden` and a key with a value
  are tags, `within:` ones `ckScope`). The text stays the plain comma-separated string; only drawing,
  hit-testing and caret moves change (`fieldPieces` cuts it into runs drawn as typed and chips).
  A tag a comma ends is drawn as a chip (unfocused, the last one too), its key dimmer than its
  value, `within:` ones blue; the comma and the spaces after it aren't drawn and the caret never stops
  in them (`pastChipTag`: Left lands at the tag's end, Right past them). With the caret in a tag
  (clicked, or moved there by the keys) or the selection starting inside it, the chip opens: an
  outline around the text being edited. Focusing the field (a click off any chip, Tab, Ctrl+F)
  selects only the free text (`freeText`: the last run of parts that aren't tags), so typing
  keeps the tags; a click on a chip goes straight into it. While focused, a single click places
  the caret, a double-click selects everything after the first `within:` tag (`afterScope`; all of it
  without one), a triple-click everything. Backspace right after a chip selects it, a second one
  deletes it; Delete at the end of a tag does nothing, as it would take the comma no one sees.
  `panelsdump` prints the field's selection (`sel=anchor..caret`). Test kit: `tmp/chips/t1.sh`
  (real clicks and keys in a nested KWin, dumps every 0.25 s, a screenshot a second).
  Test kits: `tmp/lib/libtest.nim` (scanning, search, rescans, saved index),
  `tmp/lib/hangtest.nim` with `tmp/lib/hang/hangfs` (a FUSE folder whose calls never return; kill
  it by PID to release the test), `tmp/lib/bigtest.nim` (20 000 files), `tmp/libt/run.sh` (GUI), `tmp/libtree/run.sh` (nested folders, the tree).
  Script commands: `libshow`, `libdump`, `libsearch`, `libpick`, `libnode`/`libtoggle` (`Library|folder`), `libtreedump`, `libgroup` (a group's label), `libscroll` (rows), `libselect`, `libctx`/`libaction`,
  `optlib`, `optlibnew`, `optlibitem`, `optlibadd`, `optlibctx`/`optlibaction`, `optlibmenu`,
  `libtypes`, `libtypesclose`.

- Run menu file lists (`cmdlines.nim`'s Run window section, `listSeed`, `execute`): a reference card whose content is `files` (Commands window: Reference > Files) is a list of files chosen on run, in the order the Run window's list gives them. The list: click, Ctrl+click and Shift+click select; dragging the selected files moves them (a line shows where, the list scrolls past its ends); with the list focused Up/Down/Home/End move (Shift selecting as they go), and as in the playlist Ctrl+Shift with them moves the selected files, Delete removes them, Ctrl+A selects all; Add... takes several files, a drop from a file manager (`pickWin.onFileDrop`, gathered like the main window's) goes in at the boundary under the pointer, a folder adding its media files in name order; Sort sorts by name, numbers by value (descending when sorted already; only the selection when two or more are selected). Rows show each file's length and picture size as shown (`MediaInfo.shownW`/`shownH`: rotation and pixel aspect applied), probed in the background before the playlist's (`probePickFiles`). A list starts with the playlist's selection when two or more files are selected (a link: its saved file, else left out), else the files it last ran with that still exist, else the file playing. Picks hold a list as its paths, a line each (paths with line breaks are left out). Pass as (`CmdPart.list`): `args`, a bash array expanded as `"${name[@]}"`; `ffconcat` (ffmpeg's concat demuxer script, `'\''` for a quote) or `lines`, a file `execute` writes to the temp folder, deleted when the run ends (`RunEntry.temps`). Run is refused with an empty list, and when a path card names one of the listed files (`sameFile` too): `ffmpeg -y` would write over a file it's still reading.
- Open in a new player (`CmdPart.play`, path cards; Commands window and the Run window's checkbox under a path row): once the run succeeds, the files those cards name that exist play in a player of their own (`libPlayNew`). The Run window's choice is kept in runvalues.json (`RunValue.play`) while the card's own setting stays what it was then (`playDefault`); values kept before there was a choice (`hasPlay` false) use the card's.
- Join videos presets (the text is `tmp/join/join.txt` and `fast.txt`; `tmp/join/genpresets.py` writes them into `assets/presets/commandlines.json`, `tmp/join/composetest` checks `compose` gives them back): Join videos re-encodes (x264 CRF 18, AAC 192k, MP4 with faststart). The first file with a picture sets the size (shown size: pixel aspect and rotation applied, even) and frame rate (`avg_frame_rate`, else `r_frame_rate`, else 30; at most 240). Each file becomes one segment exactly its container's duration long: the picture fitted inside (bars around), at that rate, its last frame repeated and cut to the whole frames that fit (`tpad`, `trim=end_frame`: `trim=duration` keeps a frame starting before the end, and `concat` stretches a segment to its longest stream, so chapters drifted ~30 ms per file); the sound at 48 kHz stereo, padded with silence and cut to the duration. A file without a picture is black (cover art doesn't count: stream `V`), without sound silent; with no sound in any file there's no sound track. Each file is a chapter named after it (an ffmetadata input, `=;#\` escaped; `-map_metadata` takes that input, as `-1` would drop the chapter titles); a last `fps` keeps the output at a constant rate. A file whose length can't be read stops the run (`color` and `anullsrc` would never end), as does an output that is one of the files (`-ef`). Checked sample-exact: each source's tone starts at its chapter mark (`tmp/join/check.py`), 40 files too. The fast preset joins with the concat demuxer and `-c copy` into MKV, refused unless every file's streams match the first's (codec, profile, size, pixel format, rate, channels); each AAC file's priming adds ~21 ms. Kits: `tmp/join/` (`run.sh OUT FILE...` runs a preset's text, `media/` mixed sizes, rates, rotation, pixel aspect, 5.1, no sound, no picture), `tmp/joinui/` (`kw.sh`, `run.sh BIN NAME STEPS`, `t5.sh BIN`: real clicks, drags and keys on the list through libei).
  Script commands: `cmdnew title`, `cmdtext text`, `cmdselect name`, `cmdfiles name [args|ffconcat|lines]`, `cmdplaypath name 0|1 [default]`, `pickfiles row a|b|...`, `pickdropfiles x y a|b|...`, `pickmark row k...`, `pickmove row at`, `pickstep row dir`, `picksort row`, `pickremove row`, `pickplay row 0|1`, `pickdump`, `rundump` (with each run's output).

## Source layout

| File | Purpose |
|---|---|
| `src/majestic.nim` | App state, menus, layout, panels, main loop |
| `src/player.nim` | mpv playback instance, thumbnail-preview instance, folder helpers |
| `src/waveform.nim` | The seek bar's waveform: the sound playing decoded on a thread into each bucket's peak and RMS |
| `src/ytboard.nim` | YouTube storyboards for seek bar previews: fetched left to right into the cache, shown by the preview instance |
| `src/mkvcues.nim` | Seek entries for the sound of a link's saved parts (FFmpeg's Cues list the video only) |
| `src/srv3.nim` | YouTube's styled subtitles (srv3): fetched into the cache (the hook's links, `fmt=srv3`), turned into ASS, put in place of the plain tracks; File > Save muxes them into an .mkv with ffmpeg |
| `src/tracker.nim` | A tracker module's patterns and play order through libopenmpt (loaded at run time) |
| `src/trackerchart.nim` | The tracker chart drawn in the video frame |
| `src/modstream.nim` | A module played through libopenmpt as a WAV stream mpv reads, for pitch shift and unstretched samples |
| `src/midistream.nim`, `src/fluidsynth.nim` | MIDI files played through FluidSynth as a WAV stream mpv reads; the SoundFont lookup |
| `src/wsaud.nim` | Westwood .aud: IMA ADPCM decoded from the start into a WAV stream mpv reads (seeks at full loudness), true lengths |
| `src/rgscan.nim` | ReplayGain measured (ffmpeg decoding, BS.1770 loudness on a thread) and written to the selected files' tags |
| `src/tagedit.nim` | Tags read and written through TagLib's C bindings (loaded at run time) |
| `src/cue.nim` | Cue sheets: parsed, their audio file found, tracks as playlist entries played through EDL |
| `src/plmanager.nim` | The playlists' data: tabs, undo steps, playlists.json and its merge between players |
| `src/tagdlg.nim` | The playlist's Properties window: the tag grid, Autofill, Details |
| `src/m2c.nim` | Majestic Meta Container (.m2c): tags, ReplayGain included, for files that can't keep any, in an m2c subfolder; read, written and laid over the file's own |
| `src/library.nim` | The libraries' index: paths walked and tags read on worker threads, the saved index, search tags, sorting |
| `src/libtypes.nim` | Options > Libraries > Custom...: a library's file types |
| `src/midisong.nim` | MIDI and HMI files as timed messages (HMI through SOS's sequencer), and the chart's rows |
| `src/midichart.nim` | A MIDI song laid out for the tracker chart |
| `src/avs/` | AVS 2.81d ported: `eel.nim` (the expression language), `core.nim` (pixels, blends, lines), `list.nim` (effect lists, presets), the effects (`render*`, `trans*`, `misc`, `text` (Render / Text and its fonts), `apes*`), `engine.nim` (audio to visdata, beats, frames) |
| `src/avsdlg.nim` | Visualizer > Visualizers...: the presets' grid, turned on or off, hidden, added and removed, searched |
| `src/avsview.nim`, `src/audiotap.nim` | The visualizer in the video frame (its worker thread, presets, texture); this process's sound, recorded from the sound server |
| `src/videogl.nim` | mpv → texture rendering and the transformed video quad |
| `src/coverart.nim`, `src/animpic.nim`, `src/gifanim.nim` | The pictures inside an audio file (their types and bytes); a moving cover's frames (GIF, APNG, WebP) |
| `src/folderpics.nim` | Options' folder pictures: foobar2000-style patterns (fields, `$substr` and friends, wildcards, subfolders) to the picture beside an audio file |
| `src/cmdlines.nim`, `src/runlog.nim` | The Run menu: the Commands window (command lines of text and cards, composed into bash), the Run window (times, values, rectangles, paths, file lists); the run log |
| `src/menutree.nim` | Menu bar / popup / context-menu system |
| `src/options.nim` | Options window (page tree and pages) |
| `src/assoc*.nim` | File associations (XDG mimeapps.list / Windows registry / macOS Launch Services) |
| `src/appimage.nim` | Running as an AppImage: its file, for restarts and updates, and its launcher entry |
| `src/portal.nim` | xdg-desktop-portal requests over libdbus (color picker, file dialog fallback) |
| `src/instance.nim`, `src/peers.nim`, `src/ipc.nim` | Single-instance hand-over, Synchronize links, local sockets |
| `src/syncdlg.nim` | Synchronize ▸ Properties window (masters, slaves, offset, looping) |
| `src/mediactl*.nim` | Task bar media controls (MPRIS / Windows thumbnail toolbar / macOS Now Playing and media keys) |
| `src/ui.nim` | Widget helpers on top of Silky's drawing primitives |
| `src/crashlog.nim` | Writes Nim's report of an unhandled exception or fatal signal to `crash.log`, with the app's state |
| `src/glyphcache.nim`, `src/fallbackfonts.nim`, `src/emojifont.nim` | Characters the UI atlas lacks, rasterized on demand from Plex or a system font chosen per language; color emoji from CBDT or COLR fonts |
| `src/xwin*.nim`, `src/win32api.nim` | X11 / Win32 / Cocoa helpers (drag, on-top, aspect hints, monitors, menu popup windows) |
| `src/cocoa.m`, `src/cocoa.nim` | macOS: every Cocoa call (windows, popups, file panels, Now Playing, Launch Services, the visualizer's audio tap), compiled from Objective-C |
| `src/modkeys.nim` | The shortcut modifier: Ctrl, and Cmd as well on macOS, where shortcuts show as "Cmd+" |
| `src/dylibs.nim` | Library names to load at run time, under Homebrew's folders too on macOS |
| `src/config.nim`, `src/dialogs*.nim`, `src/theme.nim`, `src/icons.nim` | Settings, file dialogs (kdialog/zenity/portal, Windows common dialogs, macOS open/save panels), palette, vector icons |

## Debugging

- **Crashes** (an unhandled exception such as an `IndexDefect`, or a segfault) are appended to
  `crash.log` in the config folder (`~/.config/majestic-media-player/`,
  `%APPDATA%\majestic-media-player\` on Windows), and the error dialog / stderr says so.
  Each entry has the version, the build's compile time, Nim's report and, for crashes on the main
  thread, the state: the open file, the panels and overlay shown, the focused control and the keys
  and buttons pressed in the frame that crashed. Release builds have no stack trace (only the
  `raise` site, often a stdlib proc), so the state is what points at the code. Turning
  `--stackTrace:on --lineTrace:on` on for releases was measured at 30–45 % slower AVS frames, and
  still 12–30 % with the AVS modules pushed off: the frames come from the system module's inline
  procs (`+%`, ORC's reference counting), which the app's modules can't turn off. For a full trace,
  build `-d:release --stackTrace:on --lineTrace:on` and reproduce with the state as a guide.
  The writer clears Nim's error flag first: with goto exceptions it stays set while the unhandled
  exception is reported, and every call that can raise would return at once. It also turns ORC's
  cycle collector off first: a segfault inside the collector (a ref counted on two threads) leaves
  the broken cell among its roots, and the next ref the writer dropped ran the collector on it
  again, a second segfault with nothing saved. On Linux, another crash while it writes goes to a
  handler that allocates nothing: it notes in the log and on stderr how far the report got, then
  ends with the signal's default action (a core dump). A crash that left no `crash.log` still has
  a native stack in `coredumpctl info <pid>` (the binary isn't stripped).
- Text fields read the selection where they use it, never once per frame: keys pressed during a
  slow frame arrive together, and Ctrl+A then Backspace once deleted the pre-Ctrl+A selection
  (`IndexDefect` in `strutils.delete` when the caret was at the end).
- `MMP_DEBUG=1` prints mpv's log to stderr.
- `MMP_SCRIPT` drives the UI for automated checks, e.g.
  `MMP_SCRIPT="1:open ~/v.mkv;3:menu 1;3.5:shot /tmp/view.png;4:quit"`.
  Commands: `open`, `menu <bar> [sub...]`, `ctx x y [seek]`, `frame 0|1` (a frame step, 1 forward), `close`, `mouse x y|off`,
  `overlay <name>`, `optpage <page>`, `focus <field id>`, `type <text>`, `action Menu/Sub/Item`, `fs 0|1`, `seek t`, `pause`,
  `size w h`, `set prop value`, `dump props...`, `shot file.png`, `stall ms`, `quit`.
  `shot` also writes each open menu popup as `file-menuN.png`. `stall` blocks the main thread
  like one slow frame: real keys pressed meanwhile all reach the next frame together.
