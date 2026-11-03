Majestic Media Player for Linux (AppImage): licenses
====================================================

Majestic Media Player itself is under the ISC license (Majestic-Media-Player.txt).
The AppImage comes with the libraries and programs below, each under its own
license. They are separate files, used unchanged, and you may replace any of
them with another build (extract the AppImage with --appimage-extract).


The libraries and programs: Arch Linux packages
-----------------------------------------------
Everything the player runs with (libmpv and FFmpeg, glibc, Mesa, libopenmpt,
and ffmpeg, ffprobe and curl, which it starts) comes unchanged from Arch Linux's
packages as they were on the date in appimage/INDEX.txt. That file lists each
package with its version, its license and where the license text is in this
folder:

  libmpv/<library>     the same library's license as in the Windows build
  Mesa.txt, LLVM.txt   Mesa (with its Vulkan drivers) and LLVM
  mpv-Copyright.txt    mpv
  appimage/<package>   the license files Arch ships with the package
  appimage/common/     standard license texts (LGPL, ...) for packages that
                       ship none of their own
  appimage/manual/     notices Arch's package doesn't carry, from the
                       package's source

License:  The libmpv in it is GNU General Public License, version 3 (GPL-3.0.txt):
          mpv is GPLv2-or-later (mpv-Copyright.txt), and Arch's FFmpeg is
          configured with --enable-gpl --enable-version3, x264, x265 and
          Rubber Band, which makes it as a whole GPLv3.
Source:   https://gitlab.archlinux.org/archlinux/packaging/packages/<package>
          (each package's PKGBUILD, naming its upstream source and patches);
          the built packages as of that date:
          https://archive.archlinux.org/repos/ (by date) and
          https://archive.archlinux.org/packages/

You may ask for the complete corresponding source of any GPL or LGPL library
shipped here, for at least three years from the release you got it with, by
opening an issue on Majestic Media Player's GitHub repository.


What makes it an AppImage
-------------------------
uruntime, sharun, anylinux.so and cross-libc-dlopen, under the MIT license
(appimage/AppImage-tools.txt).


Fonts inside majestic-media-player
----------------------------------
IBM Plex Sans and IBM Plex Mono, SIL Open Font License 1.1 (IBM-Plex-OFL.txt).
Source: https://github.com/IBM/plex
