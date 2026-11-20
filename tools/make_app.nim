## Writes the macOS app bundle's Info.plist and icon set (PNGs for iconutil)
## into a bundle being put together by tools/macos_app.sh.
##   nim r tools/make_app.nim <App.app> <executable name>

import std/[os, strutils]
import pixie, pixie/fileformats/svg
import ../src/config

const BundleId = "com.github.arkl1te.majestic-media-player"

proc xml(s: string): string =
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"))

proc docType(name, rank: string, utis, exts: openArray[string]): string =
  ## A CFBundleDocumentTypes entry: the player opens (views) these types.
  result = "    <dict>\n" &
    "      <key>CFBundleTypeName</key><string>" & xml(name) & "</string>\n" &
    "      <key>CFBundleTypeRole</key><string>Viewer</string>\n" &
    "      <key>LSHandlerRank</key><string>" & rank & "</string>\n"
  if utis.len > 0:
    result.add "      <key>LSItemContentTypes</key><array>"
    for u in utis: result.add "<string>" & u & "</string>"
    result.add "</array>\n"
  if exts.len > 0:
    result.add "      <key>CFBundleTypeExtensions</key><array>"
    for e in exts: result.add "<string>" & e & "</string>"
    result.add "</array>\n"
  result.add "    </dict>\n"

let app = paramStr(1)
let exe = paramStr(2)
let root = currentSourcePath().parentDir.parentDir
let version = readFile(root / "VERSION").strip

# Icons: iconutil wants icon_NxN.png and icon_NxN@2x.png from 16 to 512.
let svgData = readFile(root / "assets/desktop/majestic-media-player.svg")
let iconset = app / "Contents/Resources/majestic-media-player.iconset"
createDir(iconset)
for s in [16, 32, 128, 256, 512]:
  for k in [1, 2]:
    let px = s * k
    let name = "icon_" & $s & "x" & $s & (if k == 2: "@2x" else: "") & ".png"
    newImage(parseSvg(svgData, px, px)).writeFile(iconset / name)

let plist = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Majestic Media Player</string>
  <key>CFBundleDisplayName</key><string>Majestic Media Player</string>
  <key>CFBundleIdentifier</key><string>""" & BundleId & """</string>
  <key>CFBundleExecutable</key><string>""" & exe & """</string>
  <key>CFBundleIconFile</key><string>majestic-media-player</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>""" & version & """</string>
  <key>CFBundleVersion</key><string>""" & version & """</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>The visualizer shows the sound the player is playing.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
""" & docType("Video", "Alternate", ["public.movie", "public.audiovisual-content"], VideoExtensions) &
  docType("Audio", "Alternate", ["public.audio"], AudioExtensions) &
  docType("Music module", "Default", [], TrackerExtensions) &
  docType("MIDI song", "Alternate", ["public.midi-audio"], MidiExtensions) & """  </array>
</dict>
</plist>
"""
writeFile(app / "Contents/Info.plist", plist)
writeFile(app / "Contents/PkgInfo", "APPL????")
