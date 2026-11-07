#!/usr/bin/env bash
# One-step installer for Majestic Media Player.
#   ./install.sh             build and install for the current user (~/.local)
#   ./install.sh --system    build, then install to /usr/local (asks for sudo)
#   ./install.sh --uninstall [--system]
set -euo pipefail
cd "$(dirname "$0")"

# Windows (Git Bash): per-user install, no options.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    if [[ ${1:-} == --uninstall ]]; then exec tools/windows.sh uninstall; fi
    exec tools/windows.sh install ;;
esac

prefix="$HOME/.local"
sudo=""
action=install
for arg in "$@"; do
  case "$arg" in
    --system)    prefix=/usr/local; sudo=sudo ;;
    --uninstall) action=uninstall ;;
    -h|--help)   sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ $action == uninstall ]]; then
  $sudo make --no-print-directory uninstall PREFIX="$prefix"
  echo "Uninstalled from $prefix."
  exit 0
fi

# Build/runtime dependencies. On Arch-based systems, offer to install missing ones.
pkgs=(nim git base-devel mpv libx11 libxrandr kdialog)
if [[ $(uname -s) == Darwin ]]; then
  # macOS: libmpv from Homebrew; the compiler from the Xcode command line tools.
  pkgs=(nim git "Xcode command line tools (xcode-select --install)" "mpv (brew install mpv)")
  if command -v brew >/dev/null && ! brew list --versions mpv >/dev/null; then
    echo "Installing mpv with Homebrew"
    brew install mpv
  fi
  for c in nim git make cc; do
    command -v "$c" >/dev/null || { echo "missing '$c' — install: ${pkgs[*]}" >&2; exit 1; }
  done
elif command -v pacman >/dev/null; then
  missing=()
  for p in "${pkgs[@]}"; do
    pacman -Qq "$p" >/dev/null 2>&1 || pacman -Qqg "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if (( ${#missing[@]} )); then
    echo "Installing missing packages: ${missing[*]}"
    sudo pacman -S --needed "${missing[@]}"
  fi
else
  for c in nim git make cc; do
    command -v "$c" >/dev/null || { echo "missing '$c' — install: ${pkgs[*]} (or your distro's equivalents)" >&2; exit 1; }
  done
fi

# Build as the current user (never as root), then install.
make --no-print-directory
$sudo make --no-print-directory install PREFIX="$prefix"
