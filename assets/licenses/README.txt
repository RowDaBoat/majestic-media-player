Majestic Media Player for Windows: licenses
============================================

Majestic Media Player itself is under the ISC license (Majestic-Media-Player.txt).
It comes with the libraries below, each under its own license. They are separate
files, used unchanged, and you may replace any of them with another build.


libmpv-2.dll: mpv, with FFmpeg and the libraries it is built with
------------------------------------------------------------------
License:  GNU General Public License, version 3 (GPL-3.0.txt).
          mpv is GPLv2-or-later (mpv-Copyright.txt); this build includes FFmpeg
          configured with --enable-gpl --enable-version3, x264, x265 and
          Rubber Band, which makes the DLL as a whole GPLv3.
Build:    shinchiro/mpv-winbuild-cmake, release 20261005, recipe commit
          05a60b3cfd04e3e3b89918f4a27f3dde2935dff2, mpv commit c152964208.
Source:   https://github.com/mpv-player/mpv/tree/c152964208
          https://github.com/shinchiro/mpv-winbuild-cmake/tree/05a60b3cfd04e3e3b89918f4a27f3dde2935dff2
          (packages/*.cmake there names every library in it and where it comes from)
          https://github.com/shinchiro/mpv-winbuild-cmake/releases/tag/20261005
Includes: 89 libraries (FFmpeg, x264, x265, dav1d, libass, FreeType, OpenSSL...).
          Each one's license files, as of this build, are in libmpv\, listed
          with their source and commit in libmpv\INDEX.txt.

You may ask for the complete corresponding source of libmpv-2.dll as shipped
here, for at least three years from the release you got it with, by opening
an issue on Majestic Media Player's GitHub repository.


libopenmpt.dll, openmpt-*.dll: libopenmpt 0.8.9 (the tracker chart)
--------------------------------------------------------------------
From:     https://lib.openmpt.org/files/libopenmpt/dev/libopenmpt-0.8.9+release.dev.windows.vs2022.zip
          (the official build, unchanged). Source, with the mpg123, ogg, vorbis and zlib it
          was built from: https://lib.openmpt.org/files/libopenmpt/src/libopenmpt-0.8.9+release.msvc.zip
Licenses (libopenmpt/, copied from that package):
  libopenmpt.dll       BSD-3-Clause (LICENSE.txt, License.mpt.BSD-3-Clause.txt,
                       License.mpt.BSL-1.0.txt)
  openmpt-mpg123.dll   mpg123: GNU LGPL 2.1 (License.mpg123.txt, License.mpg123.Authors.txt)
                       Source: in libopenmpt's source package above (include/mpg123/).
  openmpt-ogg.dll      libogg: BSD-3-Clause (License.ogg.txt)
  openmpt-vorbis.dll   libvorbis: BSD-3-Clause (License.Vorbis.txt)
  openmpt-zlib.dll     zlib: zlib license (License.zlib.txt)


cpu\opengl32.dll, cpu\libgallium_wgl.dll: Mesa 26.2.4 (software OpenGL)
-------------------------------------------------------------------------
From:     https://github.com/pal1000/mesa-dist-win/releases/tag/26.2.4 (MSVC build)
License:  Mostly MIT; some files Apache-2.0, BSL-1.0 or SGI-B-2.0 (Mesa.txt).
          Source: https://gitlab.freedesktop.org/mesa/mesa/-/tree/mesa-26.2.4
Includes: LLVM 23.1.2 (85ac560262434c9ccfc0c183ec22d4138ed647fb), Apache-2.0 with
          LLVM exceptions (LLVM.txt). Source: https://github.com/llvm/llvm-project


Fonts inside majestic-media-player.exe
--------------------------------------
IBM Plex Sans and IBM Plex Mono, SIL Open Font License 1.1 (IBM-Plex-OFL.txt).
Source: https://github.com/IBM/plex

The visualizer (Advanced Visualization Studio) and its built-in presets
-----------------------------------------------------------------------
AVS 2.81d by Nullsoft, ported, and the Winamp presets that came with it:
BSD-style license (AVS-Nullsoft-BSD.txt). Source: https://github.com/visbot/vis_avs
