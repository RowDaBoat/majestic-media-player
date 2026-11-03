#!/usr/bin/env bash
# Linux AppImage build, run as root in an Arch Linux container (what the
# Linux workflow does; locally: docker/podman run --rm -v "$PWD:/src" -w /src
# docker.io/library/archlinux:latest tools/appimage.sh all).
#   tools/appimage.sh deps         install the pinned packages below
#   tools/appimage.sh build        compile majestic-media-player
#   tools/appimage.sh bundle NAME  make NAME.AppImage from the build
#   tools/appimage.sh all NAME     the three of them
#   tools/appimage.sh licenses [APPDIR]  rewrite assets/licenses/appimage for
#                                  the packages in APPDIR (vendor/appimage/AppDir),
#                                  or else those it would hold (after a bump of ARCH_DATE)
# Everything comes from Arch's archive as it was on ARCH_DATE, the way the
# Windows build pins its libmpv: the same mpv, FFmpeg and Mesa every build,
# and the licenses in assets/licenses (appimage/README.txt) stay true.
# Arch, not CachyOS or another derivative: their packages may need a newer
# CPU than the people running the AppImage have.
# quick-sharun (pinned below, checksummed) puts each library the program
# needs in the AppImage, glibc and Mesa too, so it runs on any distribution
# whatever its own versions; NVIDIA's driver comes from the system.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

ARCH_DATE=2026/11/02
QUICK_SHARUN_URL=https://raw.githubusercontent.com/pkgforge-dev/Anylinux-AppImages/2176169d9e7d7ff011f56748ef79a061a0663670/useful-tools/quick-sharun.sh
QUICK_SHARUN_SHA256=b8c62cec6d1351206e5edb6c273c6e5ca723196465581ffca500ee7ce37e43a4
BIN=majestic-media-player
# What runs inside the AppImage: the player's libraries (libmpv and what it
# links; libopenmpt and libdbus, loaded at run time), the programs it starts
# (ffprobe for Properties, ffmpeg to save clips, curl for links and updates;
# a desktop may have none of them) and the GPU drivers.
RUNTIME_PKGS=(mpv libopenmpt dbus ffmpeg curl mesa vulkan-radeon vulkan-intel
              vulkan-icd-loader intel-media-driver libglvnd)
BUILD_PKGS=(base-devel git nim libx11 libxrandr file patchelf strace xorg-server-xvfb)
INDEX=$ROOT/assets/licenses/appimage/INDEX.txt
# Never in a release: not redistributable.
NONFREE=(libfdk-aac faac nvidia-utils cuda)

deps() {
  # The archive's snapshot, for every package; -uu moves the container's
  # newer ones back to it.
  echo "Server = https://archive.archlinux.org/repos/$ARCH_DATE/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist
  sed -i 's/^CheckSpace/#CheckSpace/' /etc/pacman.conf
  # The archive is slow to answer at times.
  local try
  for try in 1 2 3 4 5; do
    pacman -Syyuu --noconfirm --needed "${BUILD_PKGS[@]}" "${RUNTIME_PKGS[@]}" && break
    (( try < 5 )) || exit 1
    echo "pacman failed; trying again in $((try * 20)) s" >&2
    sleep $((try * 20))
  done
  # The checkout belongs to another user in a container.
  git config --global --add safe.directory '*'
}

build() {
  make --no-print-directory
  # quick-sharun deploys from where a package would install it.
  install -Dm755 "$BIN" /usr/bin/"$BIN"
}

# owned_pkgs FILE... -> the Arch packages owning them, one per line.
owned_pkgs() {
  local f
  for f in "$@"; do pacman -Qqo "$f" 2>/dev/null || true; done | sort -u
}

# bundled_pkgs APPDIR -> "package version" for each Arch package with a file
# in the AppImage (sharun, dash and anylinux.so aside: AppImage-tools.txt).
bundled_pkgs() {
  local appdir=$1 f rel owner
  find "$appdir/shared" "$appdir/lib" "$appdir/share" -type f 2>/dev/null | while read -r f; do
    rel=${f#"$appdir"/shared/}
    rel=${rel#"$appdir"/}
    owner=""
    case $rel in
      share/licenses/*) ;;  # the ones staged here
      bin/*|share/*) owner=$(pacman -Qqo "/usr/$rel" 2>/dev/null || true) ;;
      lib/*) owner=$(pacman -Qqo "/usr/$rel" 2>/dev/null ||
                     find /usr/lib -name "${f##*/}" -exec pacman -Qqo {} + 2>/dev/null | head -1 || true) ;;
    esac
    if [[ -n $owner ]]; then echo "$owner"; fi
  done | sort -u | while read -r p; do pacman -Q "$p"; done
}

# linked_pkgs -> "package version" for what the AppImage holds, worked out
# without one: the programs and libraries named in bundle(), the GPU and
# audio plugins quick-sharun adds, and every library they link.
linked_pkgs() {
  local files=() f
  files+=(/usr/bin/{"$BIN",ffmpeg,ffprobe,curl} /usr/lib/{libopenmpt.so.0,libdbus-1.so.3,libfontconfig.so.1})
  for f in /usr/lib/dri/*.so /usr/lib/gbm/*.so /usr/lib/libvulkan_*.so /usr/lib/libgallium*.so \
           /usr/lib/lib{EGL,GLX}_mesa.so.0 /usr/lib/lib{GL,EGL,GLX,OpenGL,vulkan}.so.1 \
           /usr/lib/pipewire-0.3/*.so /usr/lib/spa-0.2/*/*.so /usr/lib/pulseaudio/*.so; do
    [[ -e $f ]] && files+=("$f")
  done
  {
    owned_pkgs "${files[@]}"
    for f in "${files[@]}"; do
      ldd "$f" 2>/dev/null | awk '$3 ~ /^\// { print $3 } $1 ~ /^\// { print $1 }'
    done | sort -u | while read -r f; do owned_pkgs "$f"; done
  } | sort -u | while read -r f; do pacman -Q "$f"; done
}

# Packages whose license is already in assets/licenses for the Windows build:
# that file or folder, relative to it. The rest have theirs in appimage/.
shared_license() {
  local p=$1 alias
  case $p in
    mpv) echo "mpv-Copyright.txt GPL-3.0.txt"; return ;;
    mesa|vulkan-radeon|vulkan-intel|vulkan-mesa-implicit-layers) echo "Mesa.txt"; return ;;
    llvm-libs) echo "LLVM.txt"; return ;;
  esac
  case $p in  # Arch's name -> the Windows build's
    libjpeg-turbo) alias=libjpeg ;;      libogg) alias=ogg ;;
    libvorbis) alias=vorbis ;;           zimg) alias=libzimg ;;
    srt) alias=libsrt ;;                 svt-av1) alias=svtav1 ;;
    openal) alias=openal-soft ;;         sdl2|sdl2-compat) alias=libsdl2 ;;
    vulkan-icd-loader) alias=vulkan ;;   libnghttp2) alias=nghttp2 ;;
    libnghttp3) alias=nghttp3 ;;         libngtcp2) alias=ngtcp2 ;;
    zvbi) alias=libzvbi ;;               *) alias=$p ;;
  esac
  if [[ -d $ROOT/assets/licenses/libmpv/$alias ]]; then echo "libmpv/$alias"; fi
}

licenses() {
  # appimage/INDEX.txt: each package, its version, its license and where the
  # license is (relative to assets/licenses, as in the AppImage). A folder
  # per package not covered by the Windows build's files, as Arch ships it;
  # common/ for the standard texts (LGPL...) of those without one.
  local dir=$ROOT/assets/licenses/appimage p v lic where id
  mkdir -p "$dir"
  # Kept: README.txt, AppImage-tools.txt and manual/ (notices Arch doesn't
  # ship, written by hand: manual/<package>/).
  find "$dir" -mindepth 1 -maxdepth 1 ! -name README.txt ! -name AppImage-tools.txt \
    ! -name manual -exec rm -rf {} +
  mkdir -p "$dir/common"
  {
    echo "# Arch Linux packages in the AppImage, as of $ARCH_DATE (tools/appimage.sh licenses)."
    echo "# Tab-separated: package, version, license, where its license is (relative"
    echo "# to the licenses folder). Source: see README.txt."
  } > "$INDEX"
  { if [[ -n ${1:-} ]]; then bundled_pkgs "$1"; else linked_pkgs; fi; } | while read -r p v; do
    lic=$(pacman -Qi "$p" | sed -n 's/^Licenses *: //p' | sed 's/  */ /g')
    where=$(shared_license "$p")
    if [[ -z $where && -d $dir/manual/$p ]]; then where=appimage/manual/$p; fi
    if [[ -z $where && -d /usr/share/licenses/$p ]]; then
      cp -rL "/usr/share/licenses/$p" "$dir/$p"
      where=appimage/$p
    fi
    if [[ -z $where ]]; then
      # Standard licenses: their texts. Older packages name them the old
      # way (GPL, LGPL3...): the versions their sources say.
      for id in $(grep -oE '[A-Za-z0-9.+-]+' <<< "$lic"); do
        case $id in
          GPL) id=GPL-2.0-or-later ;;    GPL2) id=GPL-2.0-or-later ;;
          LGPL) id=LGPL-2.1-or-later ;;  LGPL3) id=LGPL-3.0-or-later ;;
          Apache) id=Apache-2.0 ;;
        esac
        case $id in
          AND|OR|WITH|custom*|LicenseRef*) ;;
          GPL-3.0*) where+=" GPL-3.0.txt" ;;
          *) if [[ -f /usr/share/licenses/spdx/$id.txt ]]; then
               cp "/usr/share/licenses/spdx/$id.txt" "$dir/common/"
               where+=" appimage/common/$id.txt"
             fi ;;
        esac
      done
      where=${where# }
    fi
    printf '%s\t%s\t%s\t%s\n' "$p" "$v" "$lic" "${where:-MISSING}" >> "$INDEX"
  done
  echo "Wrote $INDEX: $(grep -vc '^#' "$INDEX") packages."
  if grep -q $'\tMISSING$' "$INDEX"; then
    echo "No license text found for these; add it to $dir by hand:" >&2
    grep $'\tMISSING$' "$INDEX" | cut -f1,3 >&2
  fi
}

check_licenses() {
  # Every package in the AppImage is in the index, for the same version and
  # with its license text; and nothing that can't be shipped.
  local appdir=$1 p v n missing=() bad=()
  while read -r p v; do
    for n in "${NONFREE[@]}"; do
      if [[ $p == "$n" ]]; then bad+=("$p"); fi
    done
    awk -F'\t' -v p="$p" -v v="$v" '$1 == p && $2 == v && $4 != "MISSING" { f = 1 } END { exit !f }' \
      "$INDEX" || missing+=("$p $v")
  done < <(bundled_pkgs "$appdir")
  if (( ${#bad[@]} )); then
    echo "Not redistributable, but in the AppImage: ${bad[*]}" >&2
    exit 1
  fi
  if (( ${#missing[@]} )); then
    printf 'No license in %s for (tools/appimage.sh licenses %s rewrites it; commit that):\n' \
      "${INDEX#"$ROOT"/}" "${appdir#"$ROOT"/}" >&2
    printf '  %s\n' "${missing[@]}" >&2
    exit 1
  fi
}

stage() {
  # The licenses that ship: the files shared with the Windows build that
  # the index names, and appimage/ (README.txt at the top).
  local dest=$1 a=$ROOT/assets/licenses f
  mkdir -p "$dest"
  cp "$a/appimage/README.txt" "$dest/README.txt"
  cp "$a/IBM-Plex-OFL.txt" "$dest/"
  cp "$ROOT/LICENSE" "$dest/Majestic-Media-Player.txt"
  cp -r "$a/appimage" "$dest/appimage"
  rm "$dest/appimage/README.txt"
  for f in $(grep -v '^#' "$INDEX" | cut -f4 | tr ' ' '\n' | grep -v '^appimage/' | sort -u || true); do
    mkdir -p "$dest/$(dirname "$f")"
    cp -r "$a/$f" "$dest/$f"
  done
}

bundle() {
  local name=${1:?usage: tools/appimage.sh bundle NAME}
  local work=$ROOT/vendor/appimage
  rm -rf "$work"
  mkdir -p "$work"
  curl -fsSL -o "$work/quick-sharun" "$QUICK_SHARUN_URL"
  if [[ $(sha256sum "$work/quick-sharun" | cut -d' ' -f1) != "$QUICK_SHARUN_SHA256" ]]; then
    echo "quick-sharun doesn't match its pinned checksum" >&2
    exit 1
  fi
  chmod +x "$work/quick-sharun"
  (
    cd "$work"
    export APPDIR=$work/AppDir OUTPATH=$work/out
    export DESKTOP=$ROOT/assets/desktop/$BIN.desktop
    export ICON=$ROOT/assets/desktop/$BIN.svg
    export DEPLOY_OPENGL=1 DEPLOY_VULKAN=1 DEPLOY_PULSE=1 DEPLOY_PIPEWIRE=1
    # Run for a few seconds to see what it loads at run time, besides
    # what's named here.
    export STRACE_BINARY=$BIN
    ./quick-sharun /usr/bin/"$BIN" /usr/bin/ffmpeg /usr/bin/ffprobe /usr/bin/curl \
      /usr/lib/libopenmpt.so.0 /usr/lib/libdbus-1.so.3 /usr/lib/libfontconfig.so.1
    # The player's own updater (Help > Check for Updates) replaces the
    # AppImage, so no update information: tools reading it would look for
    # .zsync files the releases don't have.
    check_licenses "$APPDIR"
    stage "$APPDIR/share/licenses/$BIN"
    env -u GITHUB_REPOSITORY UPINFO= ./quick-sharun --make-appimage
  )
  local out
  out=$(ls "$work"/out/*.AppImage)
  mv "$out" "$ROOT/$name.AppImage"
  echo "Made $name.AppImage."
}

case "${1:-}" in
  deps)     deps ;;
  build)    build ;;
  bundle)   bundle "${2:-}" ;;
  all)      deps; build; bundle "${2:-$BIN-$(cat VERSION)-$(uname -m)}" ;;
  licenses) licenses "${2:-}" ;;
  *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
