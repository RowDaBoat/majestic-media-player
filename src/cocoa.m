// macOS (Cocoa) helpers behind cocoa.nim: what xwin_x11, dialogs_unix,
// inhibit_dbus and mediactl_mpris do on Linux. Plain C entry points so Nim
// can import them without an Objective-C bridge. Compiled with ARC.
//
// Screen coordinates ("global pixels") follow the X11/Win32 convention the
// rest of the app expects: origin at the top-left of the primary screen, y
// down, in points times the primary screen's backing scale (the patched
// Windy's Window.pos uses the same).

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/message.h>
#include <dlfcn.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// --- coordinates --------------------------------------------------------------

static NSRect primaryFrame(void) {
  NSArray<NSScreen *> *screens = [NSScreen screens];
  return screens.count > 0 ? screens[0].frame : NSMakeRect(0, 0, 1920, 1080);
}

double mmpScale(void) {
  NSArray<NSScreen *> *screens = [NSScreen screens];
  return screens.count > 0 ? screens[0].backingScaleFactor : 1.0;
}

// A Cocoa rect (points, y up) as a global pixel rect.
static void toPixels(NSRect r, int *x, int *y, int *w, int *h) {
  double s = mmpScale();
  NSRect p = primaryFrame();
  *x = (int)lround(r.origin.x * s);
  *y = (int)lround((p.origin.y + p.size.height - r.origin.y - r.size.height) * s);
  *w = (int)lround(r.size.width * s);
  *h = (int)lround(r.size.height * s);
}

// A global pixel rect as a Cocoa rect.
static NSRect fromPixels(int x, int y, int w, int h) {
  double s = mmpScale();
  NSRect p = primaryFrame();
  return NSMakeRect(x / s, p.origin.y + p.size.height - (y + h) / s, w / s, h / s);
}

void mmpFramePos(void *win, int *x, int *y) {
  int w, h;
  toPixels(((__bridge NSWindow *)win).frame, x, y, &w, &h);
}

void mmpMoveFrame(void *win, int x, int y) {
  // fromPixels of an empty rect: its top-left corner as a Cocoa point.
  [(__bridge NSWindow *)win setFrameTopLeftPoint:fromPixels(x, y, 0, 0).origin];
}

int mmpMonitorCount(void) { return (int)[NSScreen screens].count; }

void mmpMonitor(int i, int *x, int *y, int *w, int *h) {
  NSArray<NSScreen *> *screens = [NSScreen screens];
  if (i < 0 || i >= (int)screens.count) { *x = *y = 0; *w = 1920; *h = 1080; return; }
  toPixels(screens[i].frame, x, y, w, h);
}

void mmpPointer(int *x, int *y) {
  NSPoint m = [NSEvent mouseLocation];
  int w, h;
  toPixels(NSMakeRect(m.x, m.y, 0, 0), x, y, &w, &h);
}

unsigned long mmpPressedButtons(void) { return [NSEvent pressedMouseButtons]; }
unsigned long mmpModifiers(void) { return [NSEvent modifierFlags]; }

// --- windows --------------------------------------------------------------------

void mmpActivate(void *win) {
  NSWindow *w = (__bridge NSWindow *)win;
  [NSApp activateIgnoringOtherApps:YES];
  if (w.isMiniaturized) [w deminiaturize:nil];
  [w makeKeyAndOrderFront:nil];
}

void mmpSetDecorated(void *win, int on) {
  // Swaps the title bar in or out keeping the content where it is.
  NSWindow *w = (__bridge NSWindow *)win;
  NSRect content = [w contentRectForFrameRect:w.frame];
  NSWindowStyleMask keep = w.styleMask & (NSWindowStyleMaskResizable | NSWindowStyleMaskFullScreen);
  NSWindowStyleMask mask = on
    ? NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
    : NSWindowStyleMaskBorderless | NSWindowStyleMaskMiniaturizable;
  // Borderless but resizable: macOS still resizes it from its edges.
  [w setStyleMask:mask | keep | NSWindowStyleMaskResizable];
  [w setFrame:[w frameRectForContentRect:content] display:YES];
  [w setMovableByWindowBackground:NO];
}

void mmpSetOnTop(void *win, int on) {
  ((__bridge NSWindow *)win).level = on ? NSFloatingWindowLevel : NSNormalWindowLevel;
}

void mmpSetMinSize(void *win, int w, int h) {
  NSWindow *nw = (__bridge NSWindow *)win;
  double s = nw.backingScaleFactor;
  nw.contentMinSize = NSMakeSize(w / s, h / s);
}

void mmpSetDialogFor(void *win, void *parent) {
  // Cocoa has no modality short of a modal session, which would stop the
  // main loop; the app raises its modal dialogs again itself. Dialogs may
  // show over the main window in full screen.
  NSWindow *w = (__bridge NSWindow *)win;
  w.collectionBehavior |= NSWindowCollectionBehaviorFullScreenAuxiliary;
  (void)parent;
}

void mmpPlaceDialog(void *win, int x, int y, int w, int h, int minW, int minH) {
  NSWindow *nw = (__bridge NSWindow *)win;
  double s = mmpScale();
  NSSize size = NSMakeSize(w / s, h / s);
  if (minW > 0 && minH > 0) {
    nw.contentMinSize = NSMakeSize(minW / s, minH / s);
    nw.contentMaxSize = NSMakeSize(FLT_MAX, FLT_MAX);
  } else {
    nw.contentMinSize = size;
    nw.contentMaxSize = size;
  }
  [nw setContentSize:size];
  NSRect top = fromPixels(x, y, 0, 0);
  [nw setFrameTopLeftPoint:top.origin];
}

void mmpDisableVsync(void *win) {
  NSView *v = ((__bridge NSWindow *)win).contentView;
  if ([v isKindOfClass:[NSOpenGLView class]]) {
    GLint zero = 0;
    [[(NSOpenGLView *)v openGLContext] setValues:&zero forParameter:NSOpenGLContextParameterSwapInterval];
  }
}

// Moves (edge < 0) or resizes the window from edge by following the pointer
// until the left button is released. Runs its own event loop, as the window
// server does for a title-bar drag. Edges as xwin's WindowEdge: TopLeft, Top,
// TopRight, Right, BottomRight, Bottom, BottomLeft, Left.
void mmpTrackWindow(void *win, int edge) {
  NSWindow *w = (__bridge NSWindow *)win;
  NSRect start = w.frame;
  NSPoint m0 = [NSEvent mouseLocation];
  NSSize minFrame = [w frameRectForContentRect:NSMakeRect(0, 0, w.contentMinSize.width,
                                                          w.contentMinSize.height)].size;
  BOOL left = edge == 0 || edge == 6 || edge == 7;
  BOOL right = edge == 2 || edge == 3 || edge == 4;
  BOOL top = edge == 0 || edge == 1 || edge == 2;
  BOOL bottom = edge == 4 || edge == 5 || edge == 6;
  while ([NSEvent pressedMouseButtons] & 1) {
    NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp
                                    untilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]
                                       inMode:NSEventTrackingRunLoopMode
                                      dequeue:YES];
    if (e != nil && e.type == NSEventTypeLeftMouseUp) break;
    NSPoint m = [NSEvent mouseLocation];
    double dx = m.x - m0.x, dy = m.y - m0.y;
    NSRect f = start;
    if (edge < 0) {
      f.origin.x += dx;
      f.origin.y += dy;
      [w setFrameOrigin:f.origin];
      continue;
    }
    if (left) {
      dx = fmin(dx, start.size.width - minFrame.width);
      f.origin.x += dx;
      f.size.width -= dx;
    }
    if (right) f.size.width = fmax(minFrame.width, f.size.width + dx);
    if (top) f.size.height = fmax(minFrame.height, f.size.height + dy);
    if (bottom) {
      dy = fmin(dy, start.size.height - minFrame.height);
      f.origin.y += dy;
      f.size.height -= dy;
    }
    [w setFrame:f display:YES];
  }
}

void mmpSetDiagonalCursor(int nwse) {
  // AppKit's own diagonal resize cursors are private; fall back to a cross.
  SEL sel = NSSelectorFromString(nwse ? @"_windowResizeNorthWestSouthEastCursor"
                                      : @"_windowResizeNorthEastSouthWestCursor");
  NSCursor *c = nil;
  if ([NSCursor respondsToSelector:sel]) {
    c = ((NSCursor * (*)(id, SEL))objc_msgSend)([NSCursor class], sel);
  }
  [(c ?: [NSCursor crosshairCursor]) set];
}

void *mmpGlProc(const char *name) {
  static void *lib;
  if (lib == NULL) lib = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY);
  return lib ? dlsym(lib, name) : NULL;
}

// --- pictures and popups --------------------------------------------------------

typedef struct {
  int activity, leftPressed, leftReleased, anyPressed;
} MmpInput;

// Shows a picture put in from outside as its layer's contents. Over a
// window's GL view it lets every event through to it (passThrough); as a
// popup's whole content it collects pointer events into `input`.
@interface MmpPictureView : NSView
@property BOOL passThrough;
@property MmpInput input;
@end

@implementation MmpPictureView
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.wantsLayer = YES;
    self.layer.contentsGravity = kCAGravityResize;
    self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  }
  return self;
}
- (BOOL)isOpaque { return YES; }
- (NSView *)hitTest:(NSPoint)p { return self.passThrough ? nil : [super hitTest:p]; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (void)updateTrackingAreas {
  for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
  if (!self.passThrough) {
    [self addTrackingArea:[[NSTrackingArea alloc]
      initWithRect:NSZeroRect
           options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                   NSTrackingActiveAlways | NSTrackingInVisibleRect
             owner:self userInfo:nil]];
  }
  [super updateTrackingAreas];
}
- (void)touch { MmpInput i = self.input; i.activity = 1; self.input = i; }
- (void)mouseMoved:(NSEvent *)e { [self touch]; }
- (void)mouseDragged:(NSEvent *)e { [self touch]; }
- (void)mouseEntered:(NSEvent *)e { [self touch]; }
- (void)mouseExited:(NSEvent *)e { [self touch]; }
- (void)mouseDown:(NSEvent *)e {
  MmpInput i = self.input; i.activity = i.leftPressed = i.anyPressed = 1; self.input = i;
}
- (void)mouseUp:(NSEvent *)e {
  MmpInput i = self.input; i.activity = i.leftReleased = 1; self.input = i;
}
- (void)rightMouseDown:(NSEvent *)e {
  MmpInput i = self.input; i.activity = i.anyPressed = 1; self.input = i;
}
- (void)otherMouseDown:(NSEvent *)e {
  MmpInput i = self.input; i.activity = 1; if (e.buttonNumber == 2) i.anyPressed = 1; self.input = i;
}
- (void)scrollWheel:(NSEvent *)e { [self touch]; }

- (void)putPixels:(const unsigned char *)bgra width:(int)w height:(int)h {
  if (w <= 0 || h <= 0) return;
  CFDataRef data = CFDataCreate(NULL, bgra, (CFIndex)w * h * 4);
  CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGImageRef img = CGImageCreate(w, h, 8, 32, (size_t)w * 4, cs,
    kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst, provider, NULL, false,
    kCGRenderingIntentDefault);
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  self.layer.contents = (__bridge id)img;
  [CATransaction commit];
  CGImageRelease(img);
  CGColorSpaceRelease(cs);
  CGDataProviderRelease(provider);
  CFRelease(data);
}
@end

// A borderless window that never takes the keyboard, so clicking a menu
// leaves the main window focused.
@interface MmpPopup : NSWindow
@end
@implementation MmpPopup
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

void *mmpPopupNew(unsigned char r, unsigned char g, unsigned char b) {
  MmpPopup *w = [[MmpPopup alloc] initWithContentRect:NSMakeRect(0, 0, 1, 1)
                                            styleMask:NSWindowStyleMaskBorderless
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
  w.releasedWhenClosed = NO;
  w.level = NSPopUpMenuWindowLevel;
  w.hasShadow = YES;
  w.opaque = YES;
  w.backgroundColor = [NSColor colorWithSRGBRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:1];
  w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                         NSWindowCollectionBehaviorFullScreenAuxiliary |
                         NSWindowCollectionBehaviorTransient;
  w.acceptsMouseMovedEvents = YES;
  MmpPictureView *v = [[MmpPictureView alloc] initWithFrame:NSMakeRect(0, 0, 1, 1)];
  w.contentView = v;
  return (__bridge_retained void *)w;
}

void mmpPopupShow(void *p, int x, int y, int w, int h) {
  MmpPopup *pw = (__bridge MmpPopup *)p;
  NSRect r = fromPixels(x, y, w, h);
  if (!NSEqualRects(pw.frame, r)) [pw setFrame:r display:NO];
  if (!pw.isVisible) [pw orderFrontRegardless];
}

void mmpPopupHide(void *p) {
  MmpPopup *pw = (__bridge MmpPopup *)p;
  if (pw.isVisible) [pw orderOut:nil];
}

void mmpPopupPut(void *p, int w, int h, const unsigned char *bgra) {
  MmpPopup *pw = (__bridge MmpPopup *)p;
  [(MmpPictureView *)pw.contentView putPixels:bgra width:w height:h];
}

void mmpPopupTakeInput(void *p, MmpInput *into) {
  MmpPictureView *v = (MmpPictureView *)((__bridge MmpPopup *)p).contentView;
  MmpInput i = v.input;
  into->activity |= i.activity;
  into->leftPressed |= i.leftPressed;
  into->leftReleased |= i.leftReleased;
  into->anyPressed |= i.anyPressed;
  v.input = (MmpInput){0};
}

void mmpWindowPut(void *win, int w, int h, const unsigned char *bgra) {
  // Over the window's own (unused) GL view: a picture view letting events by.
  NSView *content = ((__bridge NSWindow *)win).contentView;
  MmpPictureView *pic = nil;
  for (NSView *sub in content.subviews) {
    if ([sub isKindOfClass:[MmpPictureView class]]) pic = (MmpPictureView *)sub;
  }
  if (pic == nil) {
    pic = [[MmpPictureView alloc] initWithFrame:content.bounds];
    pic.passThrough = YES;
    [content addSubview:pic];
  }
  [pic putPixels:bgra width:w height:h];
}

// --- file dialogs ---------------------------------------------------------------

@interface MmpDialog : NSObject
@property BOOL done;
@property NSMutableArray<NSString *> *paths;
@end
@implementation MmpDialog
@end

static NSString *str(const char *s) { return s ? [NSString stringWithUTF8String:s] : @""; }

// kind: 0 open files, 1 open file, 2 open folder, 3 save file. exts: the
// allowed extensions (none: any file).
void *mmpDialogStart(int kind, const char *title, const char *startPath,
                     const char **exts, int extCount) {
  MmpDialog *d = [MmpDialog new];
  d.paths = [NSMutableArray array];
  NSString *start = str(startPath);
  BOOL isDir = NO;
  if (start.length > 0) [[NSFileManager defaultManager] fileExistsAtPath:start isDirectory:&isDir];
  NSString *folder = (start.length == 0 || isDir) ? start : start.stringByDeletingLastPathComponent;
  NSString *name = (start.length == 0 || isDir) ? @"" : start.lastPathComponent;
  NSMutableArray<NSString *> *types = [NSMutableArray array];
  for (int i = 0; i < extCount; i++) [types addObject:str(exts[i])];

  NSSavePanel *panel;
  if (kind == 3) {
    panel = [NSSavePanel savePanel];
    panel.canCreateDirectories = YES;
    if (name.length > 0) panel.nameFieldStringValue = name;
  } else {
    NSOpenPanel *open = [NSOpenPanel openPanel];
    open.canChooseFiles = kind != 2;
    open.canChooseDirectories = kind == 2;
    open.allowsMultipleSelection = kind == 0;
    panel = open;
  }
  panel.title = str(title);
  panel.message = str(title);
  if (types.count > 0 && kind != 2) panel.allowedFileTypes = types;
  if (folder.length > 0) panel.directoryURL = [NSURL fileURLWithPath:folder isDirectory:YES];

  [NSApp activateIgnoringOtherApps:YES];
  [panel beginWithCompletionHandler:^(NSModalResponse result) {
    if (result == NSModalResponseOK) {
      if (kind == 3) {
        if (panel.URL.path) [d.paths addObject:panel.URL.path];
      } else {
        for (NSURL *u in ((NSOpenPanel *)panel).URLs) {
          if (u.path) [d.paths addObject:u.path];
        }
      }
    }
    d.done = YES;
  }];
  return (__bridge_retained void *)d;
}

int mmpDialogDone(void *d) { return ((__bridge MmpDialog *)d).done; }
int mmpDialogCount(void *d) { return (int)((__bridge MmpDialog *)d).paths.count; }
const char *mmpDialogPath(void *d, int i) {
  return ((__bridge MmpDialog *)d).paths[i].UTF8String;
}
void mmpDialogFree(void *d) { (void)(__bridge_transfer MmpDialog *)d; }

// --- keeping the display awake --------------------------------------------------

static IOPMAssertionID assertion;
static BOOL asserted;

void mmpInhibit(int on) {
  if (on && !asserted) {
    asserted = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep,
      kIOPMAssertionLevelOn, CFSTR("Playing video"), &assertion) == kIOReturnSuccess;
  } else if (!on && asserted) {
    IOPMAssertionRelease(assertion);
    asserted = NO;
  }
}

// --- media keys and Now Playing ------------------------------------------------

// Commands as mediactl's MediaCommandKind.
enum { McPlay, McPause, McPlayPause, McStop, McNext, McPrevious, McSeekBy, McSeekTo };

typedef struct { int kind; double value; } MmpMediaCommand;

static NSMutableArray<NSValue *> *mediaQueue;

static void queueCommand(int kind, double value) {
  MmpMediaCommand c = {kind, value};
  [mediaQueue addObject:[NSValue valueWithBytes:&c objCType:@encode(MmpMediaCommand)]];
}

void mmpMediaInit(void) {
  if (mediaQueue != nil) return;
  mediaQueue = [NSMutableArray array];
  MPRemoteCommandCenter *cc = [MPRemoteCommandCenter sharedCommandCenter];
  struct { MPRemoteCommand *cmd; int kind; } simple[] = {
    {cc.playCommand, McPlay}, {cc.pauseCommand, McPause},
    {cc.togglePlayPauseCommand, McPlayPause}, {cc.stopCommand, McStop},
    {cc.nextTrackCommand, McNext}, {cc.previousTrackCommand, McPrevious},
  };
  for (size_t i = 0; i < sizeof simple / sizeof simple[0]; i++) {
    int kind = simple[i].kind;
    [simple[i].cmd addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
      queueCommand(kind, 0);
      return MPRemoteCommandHandlerStatusSuccess;
    }];
  }
  [cc.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
    queueCommand(McSeekTo, ((MPChangePlaybackPositionCommandEvent *)e).positionTime);
    return MPRemoteCommandHandlerStatusSuccess;
  }];
}

int mmpMediaPoll(MmpMediaCommand *out) {
  if (mediaQueue.count == 0) return 0;
  [mediaQueue[0] getValue:out];
  [mediaQueue removeObjectAtIndex:0];
  return 1;
}

// status: 0 stopped, 1 paused, 2 playing (mediactl's MediaStatus).
void mmpMediaUpdate(int status, const char *title, const char *artist, const char *album,
                    double position, double duration, double rate,
                    int canPlay, int canPause, int canSeek, int canNext, int canPrevious) {
  MPRemoteCommandCenter *cc = [MPRemoteCommandCenter sharedCommandCenter];
  cc.playCommand.enabled = canPlay;
  cc.pauseCommand.enabled = canPause;
  cc.togglePlayPauseCommand.enabled = canPlay || canPause;
  cc.nextTrackCommand.enabled = canNext;
  cc.previousTrackCommand.enabled = canPrevious;
  cc.changePlaybackPositionCommand.enabled = canSeek;
  MPNowPlayingInfoCenter *np = [MPNowPlayingInfoCenter defaultCenter];
  if (status == 0) {
    np.nowPlayingInfo = nil;
    np.playbackState = MPNowPlayingPlaybackStateStopped;
    return;
  }
  NSMutableDictionary *info = [NSMutableDictionary dictionary];
  info[MPMediaItemPropertyTitle] = str(title);
  if (artist && *artist) info[MPMediaItemPropertyArtist] = str(artist);
  if (album && *album) info[MPMediaItemPropertyAlbumTitle] = str(album);
  if (duration > 0) info[MPMediaItemPropertyPlaybackDuration] = @(duration);
  info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(position);
  info[MPNowPlayingInfoPropertyPlaybackRate] = @(status == 2 ? rate : 0.0);
  np.nowPlayingInfo = info;
  np.playbackState = status == 2 ? MPNowPlayingPlaybackStatePlaying : MPNowPlayingPlaybackStatePaused;
}

// --- the visualizer's sound -----------------------------------------------------

// A Core Audio process tap (macOS 14.2+) on this process's own output, the
// counterpart of WASAPI's process loopback on Windows: mpv's sound after its
// volume and filters. It feeds a private aggregate device whose IO block
// resamples to the visualizer's rate into a ring read by mmpTapLatest. The
// process only shows up in Core Audio once it has played something, so a
// failed start is retried now and then while the visualizer asks for sound.
// macOS asks the user once for permission to capture audio.

#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <os/lock.h>
#include <time.h>

enum { TapRingFrames = 8192, TapRate = 44100 };

static struct {
  os_unfair_lock lock;
  float ring[TapRingFrames * 2];
  long written;            // frames ever written
  uint64_t lastWrite;      // CLOCK_UPTIME_RAW ns
  double pos;              // next output sample, in input frames from the buffer start
  float prevL, prevR;      // the previous buffer's last frame
} tapRing = {OS_UNFAIR_LOCK_INIT};

static BOOL tapWanted, tapRunning;
static uint64_t tapTriedAt;
static AudioObjectID tapID = kAudioObjectUnknown, tapAggregate = kAudioObjectUnknown;
static AudioDeviceIOProcID tapProc;
static dispatch_queue_t tapQueue;

static uint64_t nowNs(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static void tapFeed(const AudioBufferList *in, double rate) {
  if (in->mNumberBuffers == 0 || rate <= 0) return;
  // Stereo mixdown: one interleaved buffer, or one buffer per channel.
  const AudioBuffer *b0 = &in->mBuffers[0];
  BOOL interleaved = in->mNumberBuffers == 1;
  UInt32 ch = interleaved ? MAX(b0->mNumberChannels, 1) : 1;
  long n = b0->mDataByteSize / (sizeof(float) * ch);
  const float *l = b0->mData;
  const float *r = in->mNumberBuffers > 1 ? in->mBuffers[1].mData : l;
  if (l == NULL || r == NULL || n <= 0) return;
  UInt32 stride = interleaved ? ch : 1;
  UInt32 rOff = interleaved && ch > 1 ? 1 : 0;
  BOOL silent = YES;
  for (long i = 0; i < n * stride && silent; i++) silent = l[i] == 0;
  os_unfair_lock_lock(&tapRing.lock);
  if (!silent) {
    // Linear interpolation from the device's rate to TapRate.
    double step = rate / TapRate;
    double pos = tapRing.pos;
    while (pos <= n - 1) {
      long i = (long)floor(pos);
      double f = pos - i;
      float l0 = i < 0 ? tapRing.prevL : l[i * stride];
      float r0 = i < 0 ? tapRing.prevR : r[i * stride + rOff];
      float l1 = f > 0 ? l[(i + 1) * stride] : l0;
      float r1 = f > 0 ? r[(i + 1) * stride + rOff] : r0;
      long w = (tapRing.written % TapRingFrames) * 2;
      tapRing.ring[w] = (float)(l0 + (l1 - l0) * f);
      tapRing.ring[w + 1] = (float)(r0 + (r1 - r0) * f);
      tapRing.written++;
      pos += step;
    }
    tapRing.pos = pos - n;
    tapRing.lastWrite = nowNs();
  }
  tapRing.prevL = l[(n - 1) * stride];
  tapRing.prevR = r[(n - 1) * stride + rOff];
  os_unfair_lock_unlock(&tapRing.lock);
}

static void tapTeardown(void) {
  if (tapAggregate != kAudioObjectUnknown) {
    if (tapProc != NULL) {
      AudioDeviceStop(tapAggregate, tapProc);
      AudioDeviceDestroyIOProcID(tapAggregate, tapProc);
      tapProc = NULL;
    }
    AudioHardwareDestroyAggregateDevice(tapAggregate);
    tapAggregate = kAudioObjectUnknown;
  }
  if (tapID != kAudioObjectUnknown) {
    if (@available(macOS 14.2, *)) AudioHardwareDestroyProcessTap(tapID);
    tapID = kAudioObjectUnknown;
  }
  tapRunning = NO;
}

static NSString *defaultOutputUID(void) {
  AudioObjectPropertyAddress a = {kAudioHardwarePropertyDefaultSystemOutputDevice,
    kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  AudioDeviceID dev = kAudioObjectUnknown;
  UInt32 size = sizeof dev;
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, &dev) != noErr)
    return nil;
  a.mSelector = kAudioDevicePropertyDeviceUID;
  CFStringRef uid = NULL;
  size = sizeof uid;
  if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &uid) != noErr || uid == NULL) return nil;
  return (__bridge_transfer NSString *)uid;
}

static BOOL tapSetUp(void) {
  if (@available(macOS 14.2, *)) {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyTranslatePIDToProcessObject,
      kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    pid_t pid = getpid();
    AudioObjectID process = kAudioObjectUnknown;
    UInt32 size = sizeof process;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof pid, &pid, &size,
                                   &process) != noErr || process == kAudioObjectUnknown)
      return NO;  // nothing played yet
    NSString *output = defaultOutputUID();
    if (output == nil) return NO;

    CATapDescription *desc = [[CATapDescription alloc] initStereoMixdownOfProcesses:@[@(process)]];
    desc.name = @"Majestic Media Player visualizer";
    desc.privateTap = YES;
    desc.muteBehavior = CATapUnmuted;
    if (AudioHardwareCreateProcessTap(desc, &tapID) != noErr) {
      tapID = kAudioObjectUnknown;
      return NO;
    }
    NSDictionary *agg = @{
      @(kAudioAggregateDeviceNameKey): @"Majestic Media Player visualizer",
      @(kAudioAggregateDeviceUIDKey): [NSUUID UUID].UUIDString,
      @(kAudioAggregateDeviceMainSubDeviceKey): output,
      @(kAudioAggregateDeviceIsPrivateKey): @YES,
      @(kAudioAggregateDeviceIsStackedKey): @NO,
      @(kAudioAggregateDeviceTapAutoStartKey): @YES,
      @(kAudioAggregateDeviceSubDeviceListKey): @[@{@(kAudioSubDeviceUIDKey): output}],
      @(kAudioAggregateDeviceTapListKey): @[@{
        @(kAudioSubTapDriftCompensationKey): @YES,
        @(kAudioSubTapUIDKey): desc.UUID.UUIDString}],
    };
    if (AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)agg, &tapAggregate) != noErr) {
      tapAggregate = kAudioObjectUnknown;
      tapTeardown();
      return NO;
    }
    AudioStreamBasicDescription fmt = {0};
    a.mSelector = kAudioTapPropertyFormat;
    size = sizeof fmt;
    if (AudioObjectGetPropertyData(tapID, &a, 0, NULL, &size, &fmt) != noErr ||
        fmt.mFormatID != kAudioFormatLinearPCM || !(fmt.mFormatFlags & kAudioFormatFlagIsFloat) ||
        fmt.mBitsPerChannel != 32) {
      tapTeardown();
      return NO;
    }
    double rate = fmt.mSampleRate;
    if (tapQueue == nil)
      tapQueue = dispatch_queue_create("majestic.visualizer.tap", DISPATCH_QUEUE_SERIAL);
    if (AudioDeviceCreateIOProcIDWithBlock(&tapProc, tapAggregate, tapQueue,
          ^(const AudioTimeStamp *now, const AudioBufferList *in, const AudioTimeStamp *inTime,
            AudioBufferList *out, const AudioTimeStamp *outTime) {
            tapFeed(in, rate);
          }) != noErr) {
      tapProc = NULL;
      tapTeardown();
      return NO;
    }
    if (AudioDeviceStart(tapAggregate, tapProc) != noErr) {
      tapTeardown();
      return NO;
    }
    tapRunning = YES;
    return YES;
  }
  return NO;
}

void mmpTapStart(void) {
  tapWanted = YES;
  tapTriedAt = nowNs();
  if (!tapRunning) tapSetUp();
}

void mmpTapStop(void) {
  tapWanted = NO;
  tapTeardown();
}

// The newest n frames (older first) into left and right; 0, and silence,
// when nothing has played for 150 ms.
int mmpTapLatest(float *left, float *right, int n) {
  for (int k = 0; k < n; k++) left[k] = right[k] = 0;
  if (tapWanted && !tapRunning && nowNs() - tapTriedAt > 1000000000ull) {
    tapTriedAt = nowNs();
    tapSetUp();
  }
  int fresh = 0;
  os_unfair_lock_lock(&tapRing.lock);
  if (tapRing.written > 0 && nowNs() - tapRing.lastWrite < 150000000ull) {
    fresh = 1;
    for (int k = 0; k < n; k++) {
      long f = tapRing.written - n + k;
      if (f < 0) continue;
      long r = (f % TapRingFrames) * 2;
      left[k] = tapRing.ring[r];
      right[k] = tapRing.ring[r + 1];
    }
  }
  os_unfair_lock_unlock(&tapRing.lock);
  return fresh;
}

// --- file associations ----------------------------------------------------------

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// The app's bundle identifier; empty when not running from the app bundle.
int mmpBundleId(char *buf, int len) {
  NSString *bid = [NSBundle mainBundle].bundleIdentifier;
  if (bid == nil || [NSBundle mainBundle].bundleURL == nil ||
      ![[NSBundle mainBundle].bundlePath hasSuffix:@".app"]) { buf[0] = 0; return 0; }
  strlcpy(buf, bid.UTF8String, len);
  return 1;
}

// The type macOS gives files with this extension (a dynamic "dyn." one for
// extensions it doesn't know).
int mmpUtiForExt(const char *ext, char *buf, int len) {
  buf[0] = 0;
  if (@available(macOS 11.0, *)) {
    UTType *t = [UTType typeWithFilenameExtension:str(ext)];
    if (t == nil) return 0;
    strlcpy(buf, t.identifier.UTF8String, len);
    return 1;
  }
  return 0;
}

// Whether the app is the default for opening the type.
int mmpIsDefaultFor(const char *uti) {
  NSString *bid = [NSBundle mainBundle].bundleIdentifier;
  if (bid == nil) return 0;
  CFStringRef h = LSCopyDefaultRoleHandlerForContentType((__bridge CFStringRef)str(uti), kLSRolesAll);
  if (h == NULL) return 0;
  BOOL same = [(__bridge_transfer NSString *)h caseInsensitiveCompare:bid] == NSOrderedSame;
  return same;
}

// Makes the app the type's default (on), or hands it to another app that
// opens it (off): the first other handler macOS lists. 0, or an OSStatus.
int mmpSetDefaultFor(const char *uti, int on) {
  NSString *bid = [NSBundle mainBundle].bundleIdentifier;
  if (bid == nil) return -1;
  static BOOL registered;
  if (!registered) {
    LSRegisterURL((__bridge CFURLRef)[NSBundle mainBundle].bundleURL, true);
    registered = YES;
  }
  CFStringRef type = (__bridge CFStringRef)str(uti);
  NSString *handler = bid;
  if (!on) {
    handler = nil;
    NSArray *all = (__bridge_transfer NSArray *)LSCopyAllRoleHandlersForContentType(type, kLSRolesAll);
    for (NSString *h in all) {
      if ([h caseInsensitiveCompare:bid] != NSOrderedSame) { handler = h; break; }
    }
    if (handler == nil) return 0;  // nothing else opens it: leave it
  }
  return (int)LSSetDefaultRoleHandlerForContentType(type, kLSRolesAll, (__bridge CFStringRef)handler);
}
