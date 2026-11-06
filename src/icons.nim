## Vector icons rasterized into the Silky atlas at startup (white; tinted when drawn).

import std/math
import pixie, silky

const musicPath* = "M12 3v10.55c-.59-.34-1.27-.55-2-.55-2.21 0-4 1.79-4 4s1.79 4 4 4 4-1.79 4-4V7h4V3h-6z"
const crownPath* = "M5 16L3 5l5.5 5L12 4l3.5 6L21 5l-2 11H5zm14 3c0 .6-.4 1-1 1H6c-.6 0-1-.4-1-1v-1h14v1z"

const iconPaths = {
  "play": (24, "M8 5v14l11-7z"),
  "pause": (24, "M6 5h4v14H6zM14 5h4v14h-4z"),
  "stop": (24, "M6 6h12v12H6z"),
  "prev": (24, "M6 6h2v12H6zM9.5 12L18 18V6z"),
  "next": (24, "M16 6h2v12h-2zM6 18l8.5-6L6 6z"),
  "loop": (24, "M7 7h10v3l4-4-4-4v3H5v6h2V7zm10 10H7v-3l-4 4 4 4v-3h12v-6h-2v4z"),
  "slower": (24, "M11 18V6l-8.5 6zM20.5 18V6L12 12z"),
  "faster": (24, "M3.5 18l8.5-6L3.5 6zM13 18l8.5-6L13 6z"),
  "check": (24, "M9 16.2L4.8 12l-1.4 1.4L9 19 21 7l-1.4-1.4z"),
  "radio": (24, "M12 7.5a4.5 4.5 0 1 1 0 9a4.5 4.5 0 1 1 0-9z"),
  "arrow": (24, "M9.5 7l5 5-5 5z"),
  "arrowleft": (24, "M14.5 7l-5 5 5 5z"),
  "expand": (24, "M7 9.5l5 5 5-5z"),
  "chevup": (24, "M7.4 15.4L12 10.8l4.6 4.6L18 14l-6-6-6 6z"),
  "chevdown": (24, "M7.4 8.6L12 13.2l4.6-4.6L18 10l-6 6-6-6z"),
  "search": (24, "M15.5 14h-.8l-.3-.3c1-1.1 1.6-2.6 1.6-4.2C16 5.9 13.1 3 9.5 3S3 5.9 3 9.5 5.9 16 9.5 16c1.6 0 3.1-.6 4.2-1.6l.3.3v.8l5 5 1.5-1.5-5-5zm-6 0C7 14 5 12 5 9.5S7 5 9.5 5 14 7 14 9.5 12 14 9.5 14z"),
  "film": (24, "M18 4l2 4h-3l-2-4h-2l2 4h-3l-2-4H8l2 4H7L5 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V4h-4z"),
  "music": (24, musicPath),
  "nofile": (24, "M6 2c-1.1 0-2 .9-2 2v16c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V8l-6-6H6zm7 7V3.5L18.5 9H13z"),
  "mono": (24, "M3 9v6h4l5 5V4L7 9H3zm11-1v8c1.7-.8 3-2.3 3-4s-1.3-3.2-3-4z"),
  "nosound": (24, "M3 9v6h4l5 5V4L7 9H3zM14.5 9.5l1.4-1.4 2.1 2.1 2.1-2.1 1.4 1.4-2.1 2.1 2.1 2.1-1.4 1.4-2.1-2.1-2.1 2.1-1.4-1.4 2.1-2.1z"),
  "stereo": (32, "M14 9v6h-3l-4 5V4l4 5zM5 8v8c-1.7-.8-3-2.3-3-4s1.3-3.2 3-4zM18 9v6h3l4 5V4l-4 5zM27 8v8c1.7-.8 3-2.3 3-4s-1.3-3.2-3-4z"),
  "volume": (24, "M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z"),
  "playlist": (24, "M3 10h11v2H3zm0-4h11v2H3zm0 8h7v2H3zm13-1v8l6-4z"),
  "crown": (24, crownPath),
  "terminal": (24, "M20 4H4c-1.11 0-2 .9-2 2v12c0 1.1.89 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.89-2-2-2zm0 14H4V8h16v10zm-2-1h-6v-2h6v2zM7.5 17l-1.41-1.41L8.67 13l-2.59-2.59L7.5 9l4 4-4 4z"),
  "rect": (24, "M3 5h18v14H3zM5 7v10h14V7z"),
  "rectoff": (24, "M3 5h18v14H3zM5 7v10h14V7zM3.4 2l18.6 18.6-1.4 1.4L2 3.4z"),
  "folder": (24, "M20 6h-8l-2-2H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm0 12H4V8h16v10z"),
  "plus": (24, "M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"),
  "eyedropper": (24, "M20.71 5.63l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-3.12 3.12-1.93-1.91-1.41 1.41 1.42 1.42L3 16.25V21h4.75l8.92-8.92 1.42 1.42 1.41-1.41-1.92-1.92 3.12-3.12c.4-.4.4-1.03.01-1.42zM6.92 19L5 17.08l8.06-8.06 1.92 1.92L6.92 19z"),
  "gear": (24, "M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"),
  "lock": (24, "M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm-6 9c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zm3.1-9H8.9V6c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2z"),
  "unlock": (24, "M12 17c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm6-9h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6h1.9c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm0 12H6V10h12v10z"),
  "tracker": (24, "M3 3h5v2H3zM10 3h4v2h-4zM16 3h5v2h-5zM3 6.5h5v2H3zM10 6.5h4v2h-4zM16 6.5h5v2h-5zM2 10.5h20v3H2zM3 15.5h5v2H3zM10 15.5h4v2h-4zM16 15.5h5v2h-5zM3 19h5v2H3zM10 19h4v2h-4zM16 19h5v2h-5z"),
  # The speaker, with a level between up and down arrows: gain set per file.
  "replaygain": (24, "M2 9v6h4l5 5V4L6 9H2zM18 3l3.5 4.5h-7zM18 21l3.5-4.5h-7zM14.5 11h7v2h-7z"),
  "equalizer": (24,"M10 20h4V4h-4v16zm-6 0h4v-8H4v8zM16 9v11h4V9h-4z"),
  "shield": (24, "M12 1L3 5v6c0 5.55 3.84 10.74 9 12 5.16-1.26 9-6.45 9-12V5l-9-4z"),
  "star": (24, "M12 17.27L18.18 21l-1.64-7.03L22 9.24l-7.19-.61L12 2 9.19 8.63 2 9.24l5.46 4.73L5.82 21z"),
  "close": (24, "M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"),
}

proc renderIcon*(path: string, viewBox, size: int, color = color(1, 1, 1, 1)): Image =
  ## viewBox is the square (or 32x24 for wide icons) design grid width.
  let wide = viewBox == 32
  let h = size
  let w = if wide: size * 4 div 3 else: size
  result = newImage(w, h)
  let s = size.float32 / 24
  result.fillPath(parsePath(path), color, scale(vec2(s, s)))

proc namedIcon*(name: string, size: int): Image =
  ## One of iconPaths on its own, for use outside the atlas.
  for (n, icon) in iconPaths:
    if n == name: return renderIcon(icon[1], icon[0], size)

proc ringIcon(size: int): Image =
  ## Radio button outline.
  result = newImage(size, size)
  let ctx = newContext(result)
  ctx.strokeStyle = color(1, 1, 1, 1)
  let k = size / 16
  ctx.lineWidth = 1.5 * k
  ctx.strokeCircle(circle(vec2(size / 2, size / 2), size / 2 - 1.5 * k))

proc tri(path: Path, a, b, c: Vec2) =
  path.moveTo(a); path.lineTo(b); path.lineTo(c); path.closePath()

proc mouseIcon*(size: int, button, motion: string): Image =
  ## Blender-style mouse for the status bar's hints: outlined body with the
  ## used button ("left", "right" or "middle") filled. `motion` ("v" or "h")
  ## adds a double arrow to its right for wheel and drag gestures.
  let k = size / 16
  let w = if motion.len > 0: int(round(23 * k)) else: size
  result = newImage(w, size)
  let white = color(1, 1, 1, 1)
  let body = newPath()
  body.roundedRect(rect(3.5 * k, 1 * k, 9 * k, 14 * k), 4.5 * k, 4.5 * k, 4 * k, 4 * k)
  let wheel = newPath()
  wheel.roundedRect(rect(6.75 * k, 2.75 * k, 2.5 * k, 4 * k), 1.25 * k, 1.25 * k, 1.25 * k, 1.25 * k)
  if button in ["left", "right"]:
    let fill = newImage(w, size)
    let part = newPath()
    part.rect(if button == "left": rect(0, 0, 8 * k, 7.5 * k) else: rect(8 * k, 0, 8 * k, 7.5 * k))
    fill.fillPath(part, white)
    let mask = newImage(w, size)
    mask.fillPath(body, white)
    fill.draw(mask, blendMode = MaskBlend)
    # Keep the wheel's outline readable on top of the filled button.
    let gap = newPath()
    gap.roundedRect(rect(6 * k, 2 * k, 4 * k, 5.5 * k), 2 * k, 2 * k, 2 * k, 2 * k)
    let cut = newImage(w, size)
    cut.fillPath(gap, white)
    fill.draw(cut, blendMode = SubtractMaskBlend)
    result.draw(fill)
  let lw = 1.2 * k
  result.strokePath(body, white, strokeWidth = lw)
  let lines = newPath()
  lines.moveTo(3.5 * k, 7.5 * k); lines.lineTo(12.5 * k, 7.5 * k)
  lines.moveTo(8 * k, 1 * k); lines.lineTo(8 * k, 2.75 * k)
  lines.moveTo(8 * k, 6.75 * k); lines.lineTo(8 * k, 7.5 * k)
  result.strokePath(lines, white, strokeWidth = lw)
  if button == "middle": result.fillPath(wheel, white)
  result.strokePath(wheel, white, strokeWidth = lw)
  if motion.len > 0:
    let arrow = newPath()
    if motion == "v":
      arrow.rect(rect(17.4 * k, 4 * k, 1.2 * k, 8 * k))
      arrow.tri(vec2(18 * k, 1 * k), vec2(20.5 * k, 4.5 * k), vec2(15.5 * k, 4.5 * k))
      arrow.tri(vec2(18 * k, 15 * k), vec2(20.5 * k, 11.5 * k), vec2(15.5 * k, 11.5 * k))
    else:
      arrow.rect(rect(17 * k, 7.4 * k, 3 * k, 1.2 * k))
      arrow.tri(vec2(14.5 * k, 8 * k), vec2(17.5 * k, 5.5 * k), vec2(17.5 * k, 10.5 * k))
      arrow.tri(vec2(22.5 * k, 8 * k), vec2(19.5 * k, 5.5 * k), vec2(19.5 * k, 10.5 * k))
    result.fillPath(arrow, white)

# Status bar hint key -> (atlas image, button, motion).
const mouseIcons* = {
  "LMB": ("mouse-lmb16", "left", ""),
  "RMB": ("mouse-rmb16", "right", ""),
  "MMB": ("mouse-mmb16", "middle", ""),
  "Wheel": ("mouse-wheel16", "middle", "v"),
  "Drag": ("mouse-drag16", "left", "h"),
  "MDrag": ("mouse-mdrag16", "middle", "h"),
}

proc addIcons*(builder: AtlasBuilder, scale = 1'f32) =
  ## Names keep the nominal size; images are rasterized at size * scale.
  proc px(size: int): int = int(round(size.float32 * scale))
  for (name, spec) in iconPaths:
    for size in [16, 20]:
      let img = renderIcon(spec[1], spec[0], px(size))
      discard builder.addImage(name & $size, img)
  discard builder.addImage("ring16", ringIcon(px(16)))
  for (_, spec) in mouseIcons:
    discard builder.addImage(spec[0], mouseIcon(px(16), spec[1], spec[2]))

proc appIcon*(): Image =
  ## Window icon: accent crown on a dark rounded tile.
  result = newImage(64, 64)
  let ctx = newContext(result)
  ctx.fillStyle = parseHtmlColor("#17181c")
  ctx.fillRoundedRect(rect(0, 0, 64, 64), 14)
  result.fillPath(parsePath(crownPath), parseHtmlColor("#9d8cff"),
    translate(vec2(8, 6)) * scale(vec2(2, 2)))
