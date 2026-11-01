## OpenGL plumbing for video: mpv renders into an offscreen texture, which is
## then drawn as an arbitrarily transformed quad (pan/rotate/scale).

import opengl, vmath, bumpy
import mpv

when defined(windows):
  proc GetProcAddress(m: pointer, name: cstring): pointer {.stdcall, importc, dynlib: "kernel32".}
  proc LoadLibraryA(name: cstring): pointer {.stdcall, importc, dynlib: "kernel32".}
  # Looked up once the program runs, not as it loads: opengl32.dll may be
  # Mesa's by then (gpumem).
  var
    opengl32: pointer
    wglGetProcAddress: proc (name: cstring): pointer {.stdcall.}

  proc mpvGetProcAddress(ctx: pointer, name: cstring): pointer {.cdecl.} =
    # wglGetProcAddress only knows extensions and GL > 1.1; the rest (and
    # some drivers' "failure" values 1, 2, 3, -1) mean: ask opengl32.dll.
    if opengl32 == nil:
      opengl32 = LoadLibraryA("opengl32.dll")
      wglGetProcAddress = cast[typeof(wglGetProcAddress)](GetProcAddress(opengl32, "wglGetProcAddress"))
    result = wglGetProcAddress(name)
    if cast[int](result) in [-1, 0, 1, 2, 3]:
      result = GetProcAddress(opengl32, name)
else:
  proc glXGetProcAddressARB(name: cstring): pointer {.importc, dynlib: "libGL.so.1".}

  proc mpvGetProcAddress(ctx: pointer, name: cstring): pointer {.cdecl.} =
    glXGetProcAddressARB(name)

type
  VideoTarget* = object
    fbo*, tex*: GLuint
    w*, h*: int

  QuadRenderer* = object
    program: GLuint
    vao, vbo: GLuint
    uViewport, uTex, uAlpha, uPremul: GLint
    sphere: GLuint            ## 360° program: equirectangular texture -> camera view
    sViewport, sTex, sTanHalf, sRot, sBounds, sEye: GLint
    mesh: GLuint              ## 360° program for a picture with its own mesh
    mTex, mTanHalf, mRot, mEye: GLint
    meshVao, meshVbo, meshEbo: GLuint
    meshCount: GLsizei        ## indices to draw
    meshKey*: string          ## what mesh was set, for the caller to compare

  SphereView* = object
    ## What the 360° pass needs: camera, picture layout on the sphere.
    yaw*, pitch*, fov*: float32   ## degrees; fov is vertical
    poseYaw*, posePitch*, poseRoll*: float32
    bounds*: array[4, float32]    ## crop fractions: left, right, top, bottom
    eye*: array[4, float32]       ## texture rect of the eye shown: x, y, w, h

proc createRenderContext*(h: MpvHandle, blockForTargetTime = true): MpvRenderContext =
  var
    initParams = MpvOpenGlInitParams(getProcAddress: mpvGetProcAddress)
    apiType = "opengl".cstring
    advanced: cint = 1
    blockFlag: cint = cint(blockForTargetTime)
    params = [
      MpvRenderParam(kind: rpApiType, data: apiType),
      MpvRenderParam(kind: rpOpenGlInitParams, data: initParams.addr),
      MpvRenderParam(kind: rpAdvancedControl, data: advanced.addr),
      MpvRenderParam(kind: rpBlockForTargetTime, data: blockFlag.addr),
      MpvRenderParam(kind: rpInvalid, data: nil)
    ]
  check mpv_render_context_create(result.addr, h, params[0].addr), "render context"

proc update*(ctx: MpvRenderContext): uint64 =
  ## What changed; a player has no context until it opens something with a
  ## video track (see Player.initRender), and nothing changes then.
  if ctx != nil: result = mpv_render_context_update(ctx)

proc reportSwap*(ctx: MpvRenderContext) =
  if ctx != nil: mpv_render_context_report_swap(ctx)

proc nextFrameTarget*(ctx: MpvRenderContext): int64 =
  ## Target display time (mpv_get_time_ns clock) of the queued frame, or 0
  ## when it should be shown right away.
  if ctx == nil: return 0
  var info: MpvRenderFrameInfo
  if mpv_render_context_get_info(ctx, MpvRenderParam(kind: rpNextFrameInfo, data: info.addr)) < 0:
    return 0
  if (info.flags and MpvFrameInfoPresent) == 0: return 0
  info.targetTime

proc ensureSize*(t: var VideoTarget, w, h: int) =
  let w = max(w, 1)
  let h = max(h, 1)
  if t.fbo != 0 and t.w == w and t.h == h:
    return
  if t.fbo == 0:
    glGenFramebuffers(1, t.fbo.addr)
    glGenTextures(1, t.tex.addr)
  t.w = w
  t.h = h
  glBindTexture(GL_TEXTURE_2D, t.tex)
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, w.GLsizei, h.GLsizei, 0,
    GL_RGBA, GL_UNSIGNED_BYTE, nil)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
  glBindTexture(GL_TEXTURE_2D, 0)
  glBindFramebuffer(GL_FRAMEBUFFER, t.fbo)
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, t.tex, 0)
  glBindFramebuffer(GL_FRAMEBUFFER, 0)

proc free*(t: var VideoTarget) =
  ## Deletes the target's texture and framebuffer (GL context current).
  if t.fbo != 0:
    glDeleteFramebuffers(1, t.fbo.addr)
    glDeleteTextures(1, t.tex.addr)
  t = VideoTarget()

proc render*(ctx: MpvRenderContext, t: VideoTarget, untimed = false) =
  ## Renders the current mpv frame into the target texture; `untimed`, not
  ## waiting for the time it's due.
  if ctx == nil: return
  var
    fbo = MpvOpenGlFbo(fbo: t.fbo.cint, w: t.w.cint, h: t.h.cint)
    flip: cint = 0
    blockFlag: cint = 0
    params = [
      MpvRenderParam(kind: rpOpenGlFbo, data: fbo.addr),
      MpvRenderParam(kind: rpFlipY, data: flip.addr),
      MpvRenderParam(kind: if untimed: rpBlockForTargetTime else: rpInvalid, data: blockFlag.addr),
      MpvRenderParam(kind: rpInvalid, data: nil)
    ]
  discard mpv_render_context_render(ctx, params[0].addr)
  glBindFramebuffer(GL_FRAMEBUFFER, 0)

const
  vertSrc = """
#version 410 core
layout(location = 0) in vec2 pos;
layout(location = 1) in vec2 uv;
uniform vec2 viewport;
out vec2 vUv;
void main() {
  vUv = uv;
  gl_Position = vec4(pos.x / viewport.x * 2.0 - 1.0, 1.0 - pos.y / viewport.y * 2.0, 0.0, 1.0);
}
"""
  fragSrc = """
#version 410 core
in vec2 vUv;
uniform sampler2D tex;
uniform float alpha;
uniform bool premul;    // keep the texture's (premultiplied) alpha
out vec4 color;
void main() {
  vec4 t = texture(tex, vUv);
  color = (premul ? t : vec4(t.rgb, 1.0)) * alpha;
}
"""

  sphereFragSrc = """
#version 410 core
in vec2 vUv;
uniform sampler2D tex;
uniform vec2 tanHalf;   // tan of half the field of view, x and y
uniform mat3 rot;       // view ray -> sphere direction
uniform vec4 bounds;    // crop of the full sphere: left, right, top, bottom
uniform vec4 eye;       // texture rect holding the picture: x, y, w, h
out vec4 color;
const float PI = 3.14159265358979;
void main() {
  vec3 d = normalize(rot * vec3((vUv.x * 2.0 - 1.0) * tanHalf.x,
                                (1.0 - vUv.y * 2.0) * tanHalf.y, 1.0));
  // Equirectangular: u follows longitude (0.5 straight ahead, right is +),
  // v latitude (0 at the zenith).
  vec2 full = vec2(atan(d.x, d.z) / (2.0 * PI) + 0.5, 0.5 - asin(clamp(d.y, -1.0, 1.0)) / PI);
  vec2 span = vec2(1.0 - bounds.x - bounds.y, 1.0 - bounds.z - bounds.w);
  vec2 uv = (full - bounds.xz) / span;
  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
    color = vec4(0.0, 0.0, 0.0, 1.0);
    return;
  }
  // u jumps from 1 to 0 behind the viewer: take the gradient of whichever
  // wrapping is continuous there, or that column samples the smallest mip.
  float u2 = fract(full.x + 0.5);
  float dux = abs(dFdx(full.x)) < abs(dFdx(u2)) ? dFdx(full.x) : dFdx(u2);
  float duy = abs(dFdy(full.x)) < abs(dFdy(u2)) ? dFdy(full.x) : dFdy(u2);
  vec2 k = eye.zw / span;
  color = vec4(textureGrad(tex, eye.xy + uv * eye.zw,
                           vec2(dux, dFdx(full.y)) * k, vec2(duy, dFdy(full.y)) * k).rgb, 1.0);
}
"""

  meshVertSrc = """
#version 410 core
layout(location = 0) in vec3 pos;
layout(location = 1) in vec2 uv;
uniform vec2 tanHalf;   // tan of half the field of view, x and y
uniform mat3 rot;       // view ray -> sphere direction
uniform vec4 eye;       // texture rect holding the picture: x, y, w, h
out vec2 vUv;
void main() {
  // Meshes look down -z; a picture's v goes up, the texture's down.
  vec3 p = vec3(pos.xy, -pos.z) * rot;
  vUv = eye.xy + vec2(uv.x, 1.0 - uv.y) * eye.zw;
  gl_Position = vec4(p.xy / tanHalf, 0.0, p.z);
}
"""

  meshFragSrc = """
#version 410 core
in vec2 vUv;
uniform sampler2D tex;
out vec4 color;
void main() {
  color = vec4(texture(tex, vUv).rgb, 1.0);
}
"""

proc compile(kind: GLenum, src: string): GLuint =
  result = glCreateShader(kind)
  var s = src.cstring
  glShaderSource(result, 1, cast[cstringArray](s.addr), nil)
  glCompileShader(result)
  var ok: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, ok.addr)
  if ok == 0:
    var log = newString(1024)
    var length: GLsizei
    glGetShaderInfoLog(result, 1024, length.addr, log.cstring)
    log.setLen(length)
    raise newException(ValueError, "shader compile failed: " & log)

proc newQuadRenderer*(): QuadRenderer =
  result.program = glCreateProgram()
  glAttachShader(result.program, compile(GL_VERTEX_SHADER, vertSrc))
  glAttachShader(result.program, compile(GL_FRAGMENT_SHADER, fragSrc))
  glLinkProgram(result.program)
  result.uViewport = glGetUniformLocation(result.program, "viewport")
  result.uTex = glGetUniformLocation(result.program, "tex")
  result.uAlpha = glGetUniformLocation(result.program, "alpha")
  result.uPremul = glGetUniformLocation(result.program, "premul")
  result.sphere = glCreateProgram()
  glAttachShader(result.sphere, compile(GL_VERTEX_SHADER, vertSrc))
  glAttachShader(result.sphere, compile(GL_FRAGMENT_SHADER, sphereFragSrc))
  glLinkProgram(result.sphere)
  result.sViewport = glGetUniformLocation(result.sphere, "viewport")
  result.sTex = glGetUniformLocation(result.sphere, "tex")
  result.sTanHalf = glGetUniformLocation(result.sphere, "tanHalf")
  result.sRot = glGetUniformLocation(result.sphere, "rot")
  result.sBounds = glGetUniformLocation(result.sphere, "bounds")
  result.sEye = glGetUniformLocation(result.sphere, "eye")
  result.mesh = glCreateProgram()
  glAttachShader(result.mesh, compile(GL_VERTEX_SHADER, meshVertSrc))
  glAttachShader(result.mesh, compile(GL_FRAGMENT_SHADER, meshFragSrc))
  glLinkProgram(result.mesh)
  result.mTex = glGetUniformLocation(result.mesh, "tex")
  result.mTanHalf = glGetUniformLocation(result.mesh, "tanHalf")
  result.mRot = glGetUniformLocation(result.mesh, "rot")
  result.mEye = glGetUniformLocation(result.mesh, "eye")
  glGenVertexArrays(1, result.vao.addr)
  glGenBuffers(1, result.vbo.addr)
  glBindVertexArray(result.vao)
  glBindBuffer(GL_ARRAY_BUFFER, result.vbo)
  glBufferData(GL_ARRAY_BUFFER, 24 * sizeof(float32), nil, GL_DYNAMIC_DRAW)
  glEnableVertexAttribArray(0)
  glVertexAttribPointer(0, 2, cGL_FLOAT, GL_FALSE, 4 * sizeof(float32), nil)
  glEnableVertexAttribArray(1)
  glVertexAttribPointer(1, 2, cGL_FLOAT, GL_FALSE, 4 * sizeof(float32),
    cast[pointer](2 * sizeof(float32)))
  glBindVertexArray(0)

proc upload(q: QuadRenderer, corners: array[4, Vec2]) =
  let uvs = [vec2(0, 0), vec2(1, 0), vec2(1, 1), vec2(0, 1)]
  var data: array[24, float32]
  var i = 0
  for idx in [0, 1, 2, 0, 2, 3]:
    data[i] = corners[idx].x; data[i+1] = corners[idx].y
    data[i+2] = uvs[idx].x; data[i+3] = uvs[idx].y
    i += 4
  glBindVertexArray(q.vao)
  glBindBuffer(GL_ARRAY_BUFFER, q.vbo)
  glBufferSubData(GL_ARRAY_BUFFER, 0, sizeof(data), data[0].addr)

proc draw*(q: QuadRenderer, tex: GLuint, corners: array[4, Vec2], viewport: Vec2, alpha = 1.0'f32,
           premul = false) =
  ## Draws a texture onto a quad given by its corners in window pixels:
  ## top-left, top-right, bottom-right, bottom-left (as the image should look).
  ## mpv renders into the FBO with flip_y=0, which stores the image top row
  ## first (v=0 is the top of the picture). `premul` blends a texture with
  ## premultiplied alpha over what's there instead of covering it.
  glViewport(0, 0, viewport.x.GLsizei, viewport.y.GLsizei)
  let blend = glIsEnabled(GL_BLEND)
  var funcs: array[4, GLint]  # restored after: the UI draws with its own
  if premul:
    for i, e in [GL_BLEND_SRC_RGB, GL_BLEND_DST_RGB, GL_BLEND_SRC_ALPHA, GL_BLEND_DST_ALPHA]:
      glGetIntegerv(e, funcs[i].addr)
    glEnable(GL_BLEND)
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
  glUseProgram(q.program)
  glUniform2f(q.uViewport, viewport.x, viewport.y)
  glUniform1i(q.uTex, 0)
  glUniform1f(q.uAlpha, alpha)
  glUniform1i(q.uPremul, GLint(premul))
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, tex)
  q.upload(corners)
  glDrawArrays(GL_TRIANGLES, 0, 6)
  glBindVertexArray(0)
  glBindTexture(GL_TEXTURE_2D, 0)
  glUseProgram(0)
  if premul:
    glBlendFuncSeparate(funcs[0].GLenum, funcs[1].GLenum, funcs[2].GLenum, funcs[3].GLenum)
    if not blend.bool: glDisable(GL_BLEND)

proc rectCorners*(pos, size: Vec2): array[4, Vec2] =
  [pos, pos + vec2(size.x, 0), pos + size, pos + vec2(0, size.y)]

proc rotX(a: float32): Mat3 =
  let (c, s) = (cos(a), sin(a))
  mat3(1, 0, 0, 0, c, s, 0, -s, c)

proc rotY(a: float32): Mat3 =
  let (c, s) = (cos(a), sin(a))
  mat3(c, 0, -s, 0, 1, 0, s, 0, c)

proc rotZ(a: float32): Mat3 =
  let (c, s) = (cos(a), sin(a))
  mat3(c, s, 0, -s, c, 0, 0, 0, 1)

proc viewRot(v: SphereView): Mat3 =
  ## View ray -> sphere direction.
  let d = PI.float32 / 180
  # Camera: yaw turns right, pitch looks up. The pose rotates the picture on
  # the sphere, so view rays turn back by it.
  let cam = rotY(v.yaw * d) * rotX(-v.pitch * d)
  let pose = rotY(-v.poseYaw * d) * rotX(-v.posePitch * d) * rotZ(v.poseRoll * d)
  pose.inverse * cam

proc setMesh*(q: var QuadRenderer, vertices: openArray[float32], indices: openArray[uint32]) =
  ## The mesh drawMesh draws (spherical.MeshPart).
  if q.meshVao == 0:
    glGenVertexArrays(1, q.meshVao.addr)
    glGenBuffers(1, q.meshVbo.addr)
    glGenBuffers(1, q.meshEbo.addr)
  glBindVertexArray(q.meshVao)
  glBindBuffer(GL_ARRAY_BUFFER, q.meshVbo)
  glBufferData(GL_ARRAY_BUFFER, vertices.len * sizeof(float32), vertices[0].unsafeAddr, GL_STATIC_DRAW)
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, q.meshEbo)
  glBufferData(GL_ELEMENT_ARRAY_BUFFER, indices.len * sizeof(uint32), indices[0].unsafeAddr, GL_STATIC_DRAW)
  glEnableVertexAttribArray(0)
  glVertexAttribPointer(0, 3, cGL_FLOAT, GL_FALSE, 5 * sizeof(float32), nil)
  glEnableVertexAttribArray(1)
  glVertexAttribPointer(1, 2, cGL_FLOAT, GL_FALSE, 5 * sizeof(float32),
    cast[pointer](3 * sizeof(float32)))
  glBindVertexArray(0)
  glBindBuffer(GL_ARRAY_BUFFER, 0)
  q.meshCount = indices.len.GLsizei

proc drawMesh*(q: QuadRenderer, tex: GLuint, area: Rect, viewport: Vec2, v: SphereView,
               fresh: bool) =
  ## The camera view of a texture laid out by the mesh set, over `area`
  ## (window pixels); what the mesh leaves out, as a VR180's back, is black.
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, tex)
  if fresh: glGenerateMipmap(GL_TEXTURE_2D)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR.GLint)
  glClearColor(0, 0, 0, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  var rot = v.viewRot
  let ty = tan(clamp(v.fov, 1, 170) * PI.float32 / 360)
  glViewport(GLint(area.x), GLint(viewport.y - area.y - area.h), area.w.GLsizei, area.h.GLsizei)
  glUseProgram(q.mesh)
  glUniform1i(q.mTex, 0)
  glUniform2f(q.mTanHalf, ty * area.w / max(1, area.h), ty)
  glUniformMatrix3fv(q.mRot, 1, GL_FALSE, cast[ptr GLfloat](rot.addr))
  glUniform4f(q.mEye, v.eye[0], v.eye[1], v.eye[2], v.eye[3])
  glBindVertexArray(q.meshVao)
  glDrawElements(GL_TRIANGLES, q.meshCount, GL_UNSIGNED_INT, nil)
  glBindVertexArray(0)
  glViewport(0, 0, viewport.x.GLsizei, viewport.y.GLsizei)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
  glBindTexture(GL_TEXTURE_2D, 0)
  glUseProgram(0)

proc drawSphere*(q: QuadRenderer, tex: GLuint, area: Rect, viewport: Vec2, v: SphereView,
                 fresh: bool) =
  ## Draws the camera view of an equirectangular texture over `area` (window
  ## pixels). A wide view minifies the texture, so it gets mipmaps, rebuilt
  ## when `fresh` (a new frame was rendered into it).
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, tex)
  if fresh: glGenerateMipmap(GL_TEXTURE_2D)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR.GLint)
  # A full mono sphere wraps around seamlessly behind the viewer.
  let wrap = if v.eye[2] == 1 and v.bounds[0] + v.bounds[1] == 0: GL_REPEAT else: GL_CLAMP_TO_EDGE
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, wrap.GLint)
  var rot = v.viewRot
  let ty = tan(clamp(v.fov, 1, 170) * PI.float32 / 360)
  glViewport(0, 0, viewport.x.GLsizei, viewport.y.GLsizei)
  glUseProgram(q.sphere)
  glUniform2f(q.sViewport, viewport.x, viewport.y)
  glUniform1i(q.sTex, 0)
  glUniform2f(q.sTanHalf, ty * area.w / max(1, area.h), ty)
  glUniformMatrix3fv(q.sRot, 1, GL_FALSE, cast[ptr GLfloat](rot.addr))
  glUniform4f(q.sBounds, v.bounds[0], v.bounds[1], v.bounds[2], v.bounds[3])
  glUniform4f(q.sEye, v.eye[0], v.eye[1], v.eye[2], v.eye[3])
  q.upload(rectCorners(area.xy, area.wh))
  glDrawArrays(GL_TRIANGLES, 0, 6)
  glBindVertexArray(0)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
  glBindTexture(GL_TEXTURE_2D, 0)
  glUseProgram(0)

proc transformedCorners*(center, size: Vec2, angleDeg: float32): array[4, Vec2] =
  let
    a = angleDeg * PI.float32 / 180
    c = cos(a)
    s = sin(a)
    hx = size.x / 2
    hy = size.y / 2
  for i, p in [vec2(-hx, -hy), vec2(hx, -hy), vec2(hx, hy), vec2(-hx, hy)]:
    result[i] = center + vec2(p.x * c - p.y * s, p.x * s + p.y * c)
