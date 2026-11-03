#!/usr/bin/env bash
# Windows build and install, run from Git Bash (what `make` does elsewhere).
#   tools/windows.sh build       fetch deps + libmpv, compile majestic-media-player.exe
#   tools/windows.sh debug       same, unoptimized with stack traces and a console
#   tools/windows.sh run         build, then start it
#   tools/windows.sh install     build, then install for the current user
#   tools/windows.sh uninstall   remove the install, its shortcut and file associations
#   tools/windows.sh stage DIR   copy what ships (exe, DLLs, cpu\, licenses\) into DIR
# Requires: nim >= 2.2, git, and Visual Studio (or its Build Tools) with the
# C++ workload; Nim finds it by itself. libmpv comes prebuilt from the pinned
# release below, unpacked with 7-Zip; so does Mesa's software OpenGL (cpu\),
# which renders on the CPU when the GPU's memory is full (Options > System),
# and libopenmpt, which the tracker chart reads modules with (mpv has its own
# copy built in, which nothing else can call). Their licenses go in licenses\
# (assets/licenses/README.txt): keep it in step when changing a pinned version.
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/progress.sh

BIN=majestic-media-player.exe
LIBMPV_URL=https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20261005/mpv-dev-x86_64-20261005-git-c152964208.7z
LIBMPV_DIR=vendor/libmpv
MESA_URL=https://github.com/pal1000/mesa-dist-win/releases/download/26.2.4/mesa3d-26.2.4-release-msvc.7z
MESA_DIR=vendor/mesa
MESA_DLLS=(opengl32.dll libgallium_wgl.dll)
OPENMPT_URL=https://lib.openmpt.org/files/libopenmpt/dev/libopenmpt-0.8.9+release.dev.windows.vs2022.zip
OPENMPT_SHA256=a23e375e576e3a6997ffeeb6cf34488e9020e2a5d8226856b02628b6a87c5e8e
OPENMPT_DIR=vendor/libopenmpt
# libopenmpt.dll won't load without the others.
OPENMPT_DLLS=(libopenmpt.dll openmpt-mpg123.dll openmpt-ogg.dll openmpt-vorbis.dll openmpt-zlib.dll)
APP_DIR="${LOCALAPPDATA:?}/Programs/Majestic Media Player"
SHORTCUT="${APPDATA:?}/Microsoft/Windows/Start Menu/Programs/Majestic Media Player.lnk"

find_7z() {
  local c
  for c in 7z 7za "$PROGRAMFILES/7-Zip/7z.exe" "$(dirname "$(command -v nim)")/7zG.exe"; do
    if command -v "$c" >/dev/null 2>&1 || [[ -x $c ]]; then echo "$c"; return; fi
  done
  echo "7-Zip not found: install it (https://7-zip.org) to unpack libmpv" >&2
  exit 1
}

fetch_libmpv() {
  # The URL is the version: a different one means fetch again.
  if [[ -f $LIBMPV_DIR/libmpv-2.dll && $(cat "$LIBMPV_DIR/.url" 2>/dev/null) == "$LIBMPV_URL" ]]; then
    return
  fi
  rm -rf "$LIBMPV_DIR"
  mkdir -p "$LIBMPV_DIR"
  pb_download "libmpv" "$LIBMPV_URL" "$LIBMPV_DIR/mpv-dev.7z"
  local sz
  sz=$(find_7z)
  (cd "$LIBMPV_DIR" && "$sz" x -y mpv-dev.7z >/dev/null)
  rm "$LIBMPV_DIR/mpv-dev.7z"
  [[ -f $LIBMPV_DIR/libmpv-2.dll ]] || { echo "libmpv-2.dll missing from the archive" >&2; exit 1; }
  echo "$LIBMPV_URL" > "$LIBMPV_DIR/.url"
  pb_finish "libmpv ready."
}

fetch_mesa() {
  if [[ -f $MESA_DIR/opengl32.dll && $(cat "$MESA_DIR/.url" 2>/dev/null) == "$MESA_URL" ]]; then
    return
  fi
  rm -rf "$MESA_DIR"
  mkdir -p "$MESA_DIR"
  pb_download "Mesa" "$MESA_URL" "$MESA_DIR/mesa.7z"
  local sz d
  sz=$(find_7z)
  for d in "${MESA_DLLS[@]}"; do
    (cd "$MESA_DIR" && "$sz" e -y mesa.7z "x64/$d" >/dev/null)
    [[ -f $MESA_DIR/$d ]] || { echo "$d missing from the Mesa archive" >&2; exit 1; }
  done
  rm "$MESA_DIR/mesa.7z"
  echo "$MESA_URL" > "$MESA_DIR/.url"
  pb_finish "Mesa ready."
}

fetch_libopenmpt() {
  if [[ -f $OPENMPT_DIR/libopenmpt.dll && $(cat "$OPENMPT_DIR/.url" 2>/dev/null) == "$OPENMPT_URL" ]]; then
    return
  fi
  rm -rf "$OPENMPT_DIR"
  mkdir -p "$OPENMPT_DIR/licenses"
  pb_download "libopenmpt" "$OPENMPT_URL" "$OPENMPT_DIR/libopenmpt.zip"
  if [[ $(sha256sum "$OPENMPT_DIR/libopenmpt.zip" | cut -d' ' -f1) != "$OPENMPT_SHA256" ]]; then
    echo "libopenmpt.zip doesn't match its pinned checksum" >&2
    exit 1
  fi
  local sz d
  sz=$(find_7z)
  for d in "${OPENMPT_DLLS[@]}"; do
    (cd "$OPENMPT_DIR" && "$sz" e -y libopenmpt.zip "bin/amd64/$d" >/dev/null)
    [[ -f $OPENMPT_DIR/$d ]] || { echo "$d missing from the libopenmpt archive" >&2; exit 1; }
  done
  # Its license and those of the libraries in the openmpt-*.dll files.
  (cd "$OPENMPT_DIR/licenses" && "$sz" e -y ../libopenmpt.zip LICENSE.txt "Licenses/*" >/dev/null)
  [[ -f $OPENMPT_DIR/licenses/License.mpg123.txt ]] || { echo "libopenmpt's licenses missing" >&2; exit 1; }
  rm "$OPENMPT_DIR/libopenmpt.zip"
  echo "$OPENMPT_URL" > "$OPENMPT_DIR/.url"
  pb_finish "libopenmpt ready."
}

resources() {
  # The icon Explorer shows for the .exe. rc.exe ships with the Windows SDK;
  # without it the program still builds, just with the generic icon.
  local rc
  rc=$(ls -d "${PROGRAMFILES_X86:-/c/Program Files (x86)}"/Windows\ Kits/10/bin/10.*/x64/rc.exe 2>/dev/null | sort -V | tail -1)
  if [[ -z $rc ]]; then
    echo "rc.exe (Windows SDK) not found: building without the icon" >&2
    return
  fi
  "$rc" -nologo -fo vendor/majestic.res "$(cygpath -w assets/windows/majestic-media-player.rc)" >/dev/null
  echo "--passL:$(cygpath -w vendor/majestic.res)"
}

build() {
  fetch_libmpv
  fetch_mesa
  fetch_libopenmpt
  local res=()
  mapfile -t res < <(resources)
  # --app:gui: no console window. MSVC via Nim's vccexe, which locates Visual
  # Studio itself.
  ./tools/build.sh nim c --cc:vcc "${res[@]}" "$@" -o:"$BIN" src/majestic.nim
  cp "$LIBMPV_DIR/libmpv-2.dll" .
  cp "${OPENMPT_DLLS[@]/#/$OPENMPT_DIR/}" .
  mkdir -p cpu
  cp "${MESA_DLLS[@]/#/$MESA_DIR/}" cpu/
}

stage() {
  # What ships, as built: the program, its DLLs and every license that comes with them.
  local dest=${1:?usage: tools/windows.sh stage DIR}
  mkdir -p "$dest/cpu" "$dest/licenses/libopenmpt"
  cp "$BIN" libmpv-2.dll "${OPENMPT_DLLS[@]}" "$dest/"
  cp cpu/* "$dest/cpu/"
  cp -r assets/licenses/* "$dest/licenses/"
  # The AppImage's (tools/appimage.sh).
  rm -rf "$dest/licenses/appimage"
  cp LICENSE "$dest/licenses/Majestic-Media-Player.txt"
  cp "$OPENMPT_DIR"/licenses/* "$dest/licenses/libopenmpt/"
}

install_app() {
  build -d:release --app:gui
  stage "$APP_DIR"
  local exe
  exe=$(cygpath -w "$APP_DIR/$BIN")
  powershell -NoProfile -Command "
    \$s = (New-Object -ComObject WScript.Shell).CreateShortcut('$(cygpath -w "$SHORTCUT")')
    \$s.TargetPath = '$exe'
    \$s.WorkingDirectory = '$(cygpath -w "$APP_DIR")'
    \$s.Description = 'Majestic Media Player'
    \$s.Save()"
  echo "Installed $(cygpath -w "$APP_DIR")\\$BIN — find it in the Start menu as 'Majestic Media Player'."
  echo "Make it the default player in Options > Formats, or right-click a video > Open with."
}

uninstall_app() {
  rm -rf "$APP_DIR"
  rm -f "$SHORTCUT"
  # What Options > Formats registered (see src/assoc_win32.nim).
  local k
  for k in 'HKCU\Software\Classes\MajesticMediaPlayer.Media' \
           "HKCU\\Software\\Classes\\Applications\\$BIN" \
           'HKCU\Software\MajesticMediaPlayer'; do
    reg delete "$k" /f >/dev/null 2>&1 || true
  done
  reg delete 'HKCU\Software\RegisteredApplications' /v 'Majestic Media Player' /f >/dev/null 2>&1 || true
  powershell -NoProfile -Command "
    Get-ChildItem 'HKCU:\Software\Classes' -ErrorAction SilentlyContinue |
      Where-Object { \$_.PSChildName -like '.*' } | ForEach-Object {
        if (\$_.GetValue('') -eq 'MajesticMediaPlayer.Media') { Remove-ItemProperty \$_.PSPath -Name '(default)' -ErrorAction SilentlyContinue }
        Remove-ItemProperty (Join-Path \$_.PSPath 'OpenWithProgids') -Name 'MajesticMediaPlayer.Media' -ErrorAction SilentlyContinue
      }"
  echo "Uninstalled."
}

case "${1:-build}" in
  build)     build -d:release --app:gui ;;
  debug)     build -d:debug --debugger:native --stackTrace:on --lineTrace:on ;;
  run)       build -d:release --app:gui; ./"$BIN" "${@:2}" ;;
  install)   install_app ;;
  uninstall) uninstall_app ;;
  stage)     stage "${2:-}" ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
