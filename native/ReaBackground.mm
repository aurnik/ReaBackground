// ReaBackground — show a video or image BEHIND REAPER's arrange view.
//
// REAPER paints the arrange into a swell CAMetalLayer texture. We make that
// layer non-opaque and, right before every present, turn pixels of the theme's
// background key colour transparent, so a sibling view underneath (an
// AVPlayerLayer or an image layer) shows through while items/grid/cursors stay on top.
//
// Two hook points are needed because swell presents from two paths:
//  * WM_PAINT: hooked WndProc keys the texture after REAPER's paint handler.
//  * GetDC()/ReleaseDC() (Metal mode 2, used e.g. for the play cursor): no
//    WM_PAINT; swell queues the view and later calls -swellDrawMetal:, which
//    copies the persistent texture to a drawable and presents. We swizzle it
//    and key the dirty rect before the original runs.
// The mode-2 texture persists across paints, so the keying pass is idempotent:
// already-transparent pixels (0x00000000) and our own semi-transparent outputs
// are left alone.
//
// Translucent theme overlays (time selection, mute) change the background
// colour so it no longer matches the key; those pixels are mapped to
// semi-transparent shading instead (near-key tint and explicit secondary keys),
// so the overlay still reads over the video.
//
// Relies on swell internals (m_metal_texture / m_use_metal ivars and the
// swellDrawMetal: selector of SWELL_hwndChild); validated against WDL swell-dlg.mm.

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#include <mach/mach_time.h>
#include <unistd.h>
#include <atomic>
#include <string>
#include <vector>

#include "swell.h"
#include "reaper_plugin.h"

static reaper_plugin_info_t *g_rec = NULL;
static HWND     g_main      = NULL;

// Hooks into the arrange view while enabled.
static HWND     g_arrange   = NULL;
static WNDPROC  g_origProc  = NULL;
static IMP      g_origDrawMetal = NULL;
static Method   g_drawMetalMethod = NULL;
static bool     g_enabled   = false;
static unsigned g_keyRGB    = 0xFF00FF;
static int      g_tolerance = 0;
static std::vector<unsigned> g_buf;   // scratch for keyed pixels

// Media behind the arrange.
static NSView   *g_backView   = nil;
static AVPlayer *g_player     = nil;
static CALayer  *g_mediaLayer = nil;   // AVPlayerLayer for a video, a plain layer holding the image otherwise
static bool     g_visible = true;      // media layer shown
static double   g_panX = 0, g_panY = 0;   // -1..1: which part of the cropped video shows
static CGSize   g_videoSize = { 16, 9 };

// Playback sync.
static bool     g_playing    = false;
static float    g_rate       = 1.0f;
static std::atomic<bool> g_seeking(false);
static double   g_seekIssuedMs = 0;
static double   g_seekLead   = 0;      // how far ahead to aim a seek so it lands on time
static bool     g_leadPending = false; // a seek was issued; learn from where it landed

// Diagnostics shown by the script's stats line.
static int      g_paintCount = 0;
static int      g_seekCount  = 0;
static int      g_seekTimeouts = 0;    // seeks whose completion never arrived within a second
static double   g_lastDrift  = 0;      // player time minus target, last Sync while playing
static double   g_lastKeyMs = 0;
static char     g_lastMode = 'w';      // last keying: 'w' a write, 'f' the whole texture
static long     g_lastPx = 0;          // pixels keyed by it

// ---- Keying on write. swell writes REAPER's pixels into its Metal texture
// with replaceRegion: and blits the texture to the drawable on its own queue,
// unsynchronised with those CPU writes: a blit still in flight can pick up a
// write made after it was committed. So the texture must never hold an unkeyed
// pixel. It is isa-swizzled into a subclass whose replaceRegion: keys the bytes
// on the way in and whose getBytes: hands swell the source colours back for
// its alpha blends.
static bool g_inReplace = false;      // our own write, or the 4-argument form calling the 6-argument one
static bool g_inRead = false;
static id   g_trackedTex = nil;       // unretained; checked by identity and class
static Ivar g_texIvar = NULL;
typedef void (*ReplaceIMP4)(id, SEL, MTLRegion, NSUInteger, const void *, NSUInteger);
typedef void (*ReplaceIMP6)(id, SEL, MTLRegion, NSUInteger, NSUInteger, const void *, NSUInteger, NSUInteger);
typedef void (*GetBytesIMP4)(id, SEL, void *, NSUInteger, MTLRegion, NSUInteger);
typedef void (*GetBytesIMP6)(id, SEL, void *, NSUInteger, NSUInteger, MTLRegion, NSUInteger, NSUInteger);
static ReplaceIMP4  g_origReplace4  = NULL;
static ReplaceIMP6  g_origReplace6  = NULL;
static GetBytesIMP4 g_origGetBytes4 = NULL;
static GetBytesIMP6 g_origGetBytes6 = NULL;

// REAPER exports used for exact overlay prediction and auto-start.
class LICE_IBitmap;
typedef unsigned int LICE_pixel;
static LICE_IBitmap *(*p_LICE_CreateBitmap)(int, int, int) = NULL;
static void (*p_LICE_Clear)(LICE_IBitmap *, LICE_pixel) = NULL;
static void (*p_LICE_FillRect)(LICE_IBitmap *, int, int, int, int, LICE_pixel, float, int) = NULL;
static LICE_pixel (*p_LICE_GetPixel)(LICE_IBitmap *, int, int) = NULL;
static void (*p_LICE__Destroy)(LICE_IBitmap *) = NULL;
static const char *(*p_GetExtState)(const char *, const char *) = NULL;
static void (*p_SetExtState)(const char *, const char *, const char *, bool) = NULL;
static void (*p_Main_OnCommand)(int, int) = NULL;
static const char *(*p_GetResourcePath)() = NULL;
static int (*p_AddRemoveReaScript)(bool, int, const char *, bool) = NULL;
static bool (*p_AddExtensionsMainMenu)() = NULL;

// Secondary keys: colours REAPER produces by blending an overlay (time
// selection, mute) over the background. Matched with a per-channel tolerance
// and replaced by a premultiplied semi-transparent pixel so the overlay still
// shades the video. Our own outputs are recognised so the pass stays idempotent.
struct SecKey { int r, g, b, tol; unsigned out; };
static std::vector<SecKey>   g_sec;
static std::vector<unsigned> g_outs;
static std::vector<unsigned> g_outSrc;   // source 0xRRGGBB for each entry of g_outs
static void AUBG_ClearKeys();

// Near-key shading: pixels close to the key but not equal are the background
// with a translucent overlay (time selection etc.) blended over it by REAPER.
// Rather than predicting the blend, keep the deviation from the key as a tint
// (amplified by gain) and output it at a fixed opacity.
static int      g_nearTol  = 0;
static unsigned g_nearA    = 0;     // output alpha byte, never 0 or 0xFF
static double   g_nearGain = 1.0;

static double now_ms()
{
  static mach_timebase_info_data_t tb;
  if (!tb.denom) mach_timebase_info(&tb);
  return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

static int ivar_char(id obj, const char *name, int fallback)
{
  Ivar iv = class_getInstanceVariable([obj class], name);
  if (!iv) return fallback;
  return *((char *)(void *)obj + ivar_getOffset(iv));
}

static void raw_getBytes(id<MTLTexture> tex, void *out, NSUInteger bpr, MTLRegion r);

// Per-channel bitmasks over the colour table (our own outputs first, then the
// secondary keys): a pixel can match entry i only if bit i is set for all three
// of its channels, so the per-pixel cost is three loads however long the table.
static uint64_t g_maskR[256], g_maskG[256], g_maskB[256];
static unsigned g_tableN = 0;
static unsigned char g_nearMap[3][256];   // channel value -> premultiplied near-key output channel

static void rebuild_key_tables()
{
  memset(g_maskR, 0, sizeof(g_maskR)); memset(g_maskG, 0, sizeof(g_maskG)); memset(g_maskB, 0, sizeof(g_maskB));
  unsigned n = 0;
  for (size_t i = 0; i < g_outs.size() && n < 64; ++i, ++n)
  {
    const unsigned v = g_outs[i];
    const uint64_t bit = 1ull << n;
    g_maskR[(v >> 16) & 0xFF] |= bit; g_maskG[(v >> 8) & 0xFF] |= bit; g_maskB[v & 0xFF] |= bit;
  }
  for (size_t i = 0; i < g_sec.size() && n < 64; ++i, ++n)
  {
    const SecKey &k = g_sec[i];
    const uint64_t bit = 1ull << n;
    for (int c = k.r - k.tol; c <= k.r + k.tol; ++c) if (c >= 0 && c < 256) g_maskR[c] |= bit;
    for (int c = k.g - k.tol; c <= k.g + k.tol; ++c) if (c >= 0 && c < 256) g_maskG[c] |= bit;
    for (int c = k.b - k.tol; c <= k.b + k.tol; ++c) if (c >= 0 && c < 256) g_maskB[c] |= bit;
  }
  g_tableN = n;
  const unsigned key = g_keyRGB & 0xFFFFFF;
  const int k[3] = { (int)(key >> 16) & 0xFF, (int)(key >> 8) & 0xFF, (int)key & 0xFF };
  for (int ch = 0; ch < 3; ++ch)
    for (int c = 0; c < 256; ++c)
    {
      int t = k[ch] + (int)((c - k[ch]) * g_nearGain);
      t = t < 0 ? 0 : t > 255 ? 255 : t;
      g_nearMap[ch][c] = (unsigned char)(t * (int)g_nearA / 255);
    }
}

static inline bool table_match(uint64_t m, unsigned v, int r, int g, int b, unsigned *out)
{
  const unsigned nout = (unsigned)g_outs.size();
  while (m)
  {
    const unsigned i = (unsigned)__builtin_ctzll(m);
    m &= m - 1;
    if (i < nout) { if (v == g_outs[i]) { *out = v; return true; } }
    else
    {
      const SecKey &k = g_sec[i - nout];
      if (abs(r - k.r) <= k.tol && abs(g - k.g) <= k.tol && abs(b - k.b) <= k.tol) { *out = k.out; return true; }
    }
  }
  return false;
}

// Keys n pixels (BGRA8 in memory == 0xAARRGGBB little-endian, same as LICE)
// from src to dst, which may be the same buffer: the key colour becomes
// transparent, table colours their output, near-key colours the amplified
// deviation at the near alpha, and everything else opaque (the alpha bytes
// swell writes are not meaningful).
static void key_pixels(unsigned *dst, const unsigned *src, size_t n)
{
  const unsigned key = g_keyRGB & 0xFFFFFF;
  const int kr = (key >> 16) & 0xFF, kg = (key >> 8) & 0xFF, kb = key & 0xFF;
  const int tol = g_tolerance, nearTol = g_nearTol;
  const unsigned nearA = g_nearA, nearSpan = 2u * (unsigned)nearTol;
  const bool table = g_tableN > 0;
  for (size_t i = 0; i < n; ++i)
  {
    const unsigned v = src[i];
    if (v == 0 || (v & 0xFFFFFF) == key) { dst[i] = 0; continue; }
    const int r = (v >> 16) & 0xFF, g = (v >> 8) & 0xFF, b = v & 0xFF;
    if (tol > 0 && abs(r - kr) <= tol && abs(g - kg) <= tol && abs(b - kb) <= tol) { dst[i] = 0; continue; }
    if (table)
    {
      const uint64_t m = g_maskR[r] & g_maskG[g] & g_maskB[b];
      unsigned o;
      if (m && table_match(m, v, r, g, b, &o)) { dst[i] = o; continue; }
    }
    if (nearTol > 0)
    {
      // Our own near-key output: premultiplied, so every channel <= alpha.
      if ((v >> 24) == nearA && (unsigned)r <= nearA && (unsigned)g <= nearA && (unsigned)b <= nearA) { dst[i] = v; continue; }
      if ((unsigned)(r - kr + nearTol) <= nearSpan && (unsigned)(g - kg + nearTol) <= nearSpan && (unsigned)(b - kb + nearTol) <= nearSpan)
      {
        dst[i] = (nearA << 24) | ((unsigned)g_nearMap[0][r] << 16) | ((unsigned)g_nearMap[1][g] << 8) | g_nearMap[2][b];
        continue;
      }
    }
    dst[i] = v | 0xFF000000;
  }
}

// Keys a w x h block whose source rows are bpr bytes apart into tightly packed
// dst. A full arrange repaint is a few million pixels, so big blocks are split
// across cores; small ones (cursor strips, scrollbars) stay on this thread.
static void key_rows(unsigned *dst, const unsigned char *src, NSUInteger bpr, int w, int h)
{
  if ((long)w * h < 262144 || h < 32)
  {
    for (int y = 0; y < h; ++y) key_pixels(dst + (size_t)y * w, (const unsigned *)(src + y * bpr), w);
    return;
  }
  const int bands = h < 256 ? 4 : 8;
  dispatch_apply(bands, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^(size_t i) {
    const int y0 = (int)(h * (long)i / bands), y1 = (int)(h * (long)(i + 1) / bands);
    for (int y = y0; y < y1; ++y) key_pixels(dst + (size_t)y * w, (const unsigned *)(src + y * bpr), w);
  });
}

// Keys the whole texture in place: for a texture swell created and wrote to
// before it was hooked.
static void key_full(id<MTLTexture> tex)
{
  const int w = (int)tex.width, h = (int)tex.height;
  g_buf.resize((size_t)w * h);
  const MTLRegion region = MTLRegionMake2D(0, 0, w, h);
  raw_getBytes(tex, g_buf.data(), w * 4, region);
  key_rows(g_buf.data(), (const unsigned char *)g_buf.data(), w * 4, w, h);
  g_inReplace = true;
  [tex replaceRegion:region mipmapLevel:0 withBytes:g_buf.data() bytesPerRow:w * 4];
  g_inReplace = false;
}

static void note_keyed(long px, double ms, char mode)
{
  g_lastPx = px; g_lastKeyMs = ms; g_lastMode = mode;
}

// The texture's replaceRegion: with the pixels keyed on the way in. The base
// 4-argument form calls the 6-argument one on the object, hence the guard.
static void tracked_replace4(id self, SEL _cmd, MTLRegion r, NSUInteger lvl, const void *b, NSUInteger bpr)
{
  if (g_inReplace) { g_origReplace4(self, _cmd, r, lvl, b, bpr); return; }
  const double t0 = now_ms();
  const int w = (int)r.size.width, h = (int)r.size.height;
  g_buf.resize((size_t)w * h);
  key_rows(g_buf.data(), (const unsigned char *)b, bpr, w, h);
  g_inReplace = true;
  g_origReplace4(self, _cmd, r, lvl, g_buf.data(), (NSUInteger)w * 4);
  g_inReplace = false;
  note_keyed((long)w * h, now_ms() - t0, 'w');
}
static void tracked_replace6(id self, SEL _cmd, MTLRegion r, NSUInteger lvl, NSUInteger slice, const void *b, NSUInteger bpr, NSUInteger bpi)
{
  if (g_inReplace) { g_origReplace6(self, _cmd, r, lvl, slice, b, bpr, bpi); return; }
  const double t0 = now_ms();
  const int w = (int)r.size.width, h = (int)r.size.height;
  g_buf.resize((size_t)w * h);
  key_rows(g_buf.data(), (const unsigned char *)b, bpr, w, h);
  g_inReplace = true;
  g_origReplace6(self, _cmd, r, lvl, slice, g_buf.data(), (NSUInteger)w * 4, (NSUInteger)w * 4 * h);
  g_inReplace = false;
  note_keyed((long)w * h, now_ms() - t0, 'w');
}

// swell reads the texture back to alpha-blend themed images (scrollbars,
// buttons) over what is there. Keyed pixels would make those blends land on
// transparent black or on shaded output, so a readback gets the source colours
// restored: key pixels exactly, secondary keys from the table, near-key pixels
// by inverting the amplification (to within a level or two).
static void unkey_pixels(unsigned *p, size_t n)
{
  const unsigned key = g_keyRGB & 0xFFFFFF, keyOpaque = 0xFF000000 | key;
  const int kr = (key >> 16) & 0xFF, kg = (key >> 8) & 0xFF, kb = key & 0xFF;
  for (; n--; ++p)
  {
    const unsigned v = *p, a = v >> 24;
    if (a == 0xFF) continue;
    if (v == 0) { *p = keyOpaque; continue; }
    bool done = false;
    for (size_t i = 0; i < g_outs.size(); ++i) if (g_outs[i] == v) { *p = 0xFF000000 | g_outSrc[i]; done = true; break; }
    if (done || g_nearTol <= 0 || a != g_nearA) continue;
    int ch[3] = { (int)((v >> 16) & 0xFF), (int)((v >> 8) & 0xFF), (int)(v & 0xFF) };
    const int k[3] = { kr, kg, kb };
    for (int c = 0; c < 3; ++c)
    {
      const int t = (ch[c] * 255 + (int)g_nearA / 2) / (int)g_nearA;             // un-premultiply
      int d = (int)lround((t - k[c]) / g_nearGain);
      int o = k[c] + d;
      ch[c] = o < 0 ? 0 : o > 255 ? 255 : o;
    }
    *p = 0xFF000000 | (ch[0] << 16) | (ch[1] << 8) | ch[2];
  }
}

static void tracked_getBytes4(id self, SEL _cmd, void *out, NSUInteger bpr, MTLRegion r, NSUInteger lvl)
{
  const bool outer = !g_inRead;
  g_inRead = true;
  g_origGetBytes4(self, _cmd, out, bpr, r, lvl);
  if (outer)
  {
    g_inRead = false;
    for (NSUInteger y = 0; y < r.size.height; ++y) unkey_pixels((unsigned *)((char *)out + y * bpr), r.size.width);
  }
}
static void tracked_getBytes6(id self, SEL _cmd, void *out, NSUInteger bpr, NSUInteger bpi, MTLRegion r, NSUInteger lvl, NSUInteger slice)
{
  const bool outer = !g_inRead;
  g_inRead = true;
  g_origGetBytes6(self, _cmd, out, bpr, bpi, r, lvl, slice);
  if (outer)
  {
    g_inRead = false;
    for (NSUInteger y = 0; y < r.size.height; ++y) unkey_pixels((unsigned *)((char *)out + y * bpr), r.size.width);
  }
}

// Our own readbacks want the keyed pixels as they are (the base method calls
// the six-argument form on the object, so the guard covers the nested hook).
static void raw_getBytes(id<MTLTexture> tex, void *out, NSUInteger bpr, MTLRegion r)
{
  const bool was = g_inRead;
  g_inRead = true;
  [tex getBytes:out bytesPerRow:bpr fromRegion:r mipmapLevel:0];
  g_inRead = was;
}

static const char *TRACKED_PREFIX = "AUBG_Tracked_";

// Identity alone is not enough: swell may free the texture and allocate the
// next one at the same address.
static bool is_tracked(id tex)
{
  return tex && tex == g_trackedTex && !strncmp(class_getName(object_getClass(tex)), TRACKED_PREFIX, strlen(TRACKED_PREFIX));
}

static bool track_texture(id tex)
{
  if (!tex) return false;
  if (is_tracked(tex)) return true;
  Class base = object_getClass(tex);
  if (!strncmp(class_getName(base), TRACKED_PREFIX, strlen(TRACKED_PREFIX))) { g_trackedTex = tex; return true; }
  SEL s4 = @selector(replaceRegion:mipmapLevel:withBytes:bytesPerRow:);
  SEL s6 = @selector(replaceRegion:mipmapLevel:slice:withBytes:bytesPerRow:bytesPerImage:);
  SEL g4 = @selector(getBytes:bytesPerRow:fromRegion:mipmapLevel:);
  SEL g6 = @selector(getBytes:bytesPerRow:bytesPerImage:fromRegion:mipmapLevel:slice:);
  Method m4 = class_getInstanceMethod(base, s4), m6 = class_getInstanceMethod(base, s6);
  Method r4 = class_getInstanceMethod(base, g4), r6 = class_getInstanceMethod(base, g6);
  if (!m4 || !m6 || !r4 || !r6) return false;
  char name[256];
  snprintf(name, sizeof(name), "%s%s", TRACKED_PREFIX, class_getName(base));
  Class sub = objc_getClass(name);
  if (!sub)
  {
    sub = objc_allocateClassPair(base, name, 0);
    if (!sub) return false;
    class_addMethod(sub, s4, (IMP)tracked_replace4, method_getTypeEncoding(m4));
    class_addMethod(sub, s6, (IMP)tracked_replace6, method_getTypeEncoding(m6));
    class_addMethod(sub, g4, (IMP)tracked_getBytes4, method_getTypeEncoding(r4));
    class_addMethod(sub, g6, (IMP)tracked_getBytes6, method_getTypeEncoding(r6));
    objc_registerClassPair(sub);
  }
  g_origReplace4 = (ReplaceIMP4)method_getImplementation(m4);
  g_origReplace6 = (ReplaceIMP6)method_getImplementation(m6);
  g_origGetBytes4 = (GetBytesIMP4)method_getImplementation(r4);
  g_origGetBytes6 = (GetBytesIMP6)method_getImplementation(r6);
  object_setClass(tex, sub);
  g_trackedTex = tex;
  return true;
}

static void untrack_texture(id tex)
{
  if (tex && tex == g_trackedTex)
  {
    Class c = object_getClass(tex);
    if (!strncmp(class_getName(c), TRACKED_PREFIX, strlen(TRACKED_PREFIX))) object_setClass(tex, class_getSuperclass(c));
  }
  g_trackedTex = nil;
}

// A texture swell has just created holds what it wrote before we hooked it:
// track it and key it whole, before swell's first blit of it.
static void ensure_keyed(NSView *view)
{
  id<MTLTexture> tex = g_texIvar ? object_getIvar(view, g_texIvar) : nil;
  if (!tex || is_tracked(tex) || !track_texture(tex)) return;
  const double t0 = now_ms();
  key_full(tex);
  note_keyed((long)tex.width * tex.height, now_ms() - t0, 'f');
}

// Aspect-fills the video into the root layer, shifted by the pan within the
// cropped range (pan ±1 = the video's edge becomes visible). Done by hand
// rather than with videoGravity so the crop can be offset.
static void layout_player()
{
  if (!g_mediaLayer || !g_backView) return;
  CALayer *root = [g_backView layer];
  const CGSize b = root.bounds.size;
  if (b.width <= 0 || b.height <= 0 || g_videoSize.width <= 0 || g_videoSize.height <= 0) return;
  const double s = fmax(b.width / g_videoSize.width, b.height / g_videoSize.height);
  const double fw = g_videoSize.width * s, fh = g_videoSize.height * s;
  const double py = root.geometryFlipped ? g_panY : -g_panY;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  g_mediaLayer.frame = CGRectMake((b.width - fw) / 2 * (1 + g_panX), (b.height - fh) / 2 * (1 + py), fw, fh);
  [CATransaction commit];
}

static void sync_back_view(NSView *arrange)
{
  if (!g_backView) return;
  NSRect f = [arrange frame];
  if (NSEqualRects(f, [g_backView frame])) return;
  [g_backView setFrame:f];
  layout_player();
}

static LRESULT hook_proc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam)
{
  LRESULT r = g_origProc(hwnd, msg, wParam, lParam);
  if (msg == WM_PAINT && g_enabled)
  {
    NSView *view = (NSView *)hwnd;
    ensure_keyed(view);
    sync_back_view(view);
    ++g_paintCount;
  }
  return r;
}

// Swizzled -[SWELL_hwndChild swellDrawMetal:]. forRect is in view points
// (NULL = everything); the texture may be 2x on retina.
static void swz_swellDrawMetal(id self, SEL _cmd, const RECT *forRect)
{
  if (g_enabled && (HWND)self == g_arrange)
  {
    NSView *view = (NSView *)self;
    ensure_keyed(view);
    sync_back_view(view);
  }
  ((void (*)(id, SEL, const RECT *))g_origDrawMetal)(self, _cmd, forRect);
}

static void close_video()
{
  g_seeking = false;
  if (g_player) { [g_player pause]; [g_player release]; g_player = nil; }
  if (g_mediaLayer) { [g_mediaLayer removeFromSuperlayer]; [g_mediaLayer release]; g_mediaLayer = nil; }
  g_playing = false;
}

static void disable()
{
  close_video();
  AUBG_ClearKeys();
  if (g_drawMetalMethod && g_origDrawMetal)
  {
    method_setImplementation(g_drawMetalMethod, g_origDrawMetal);
    g_drawMetalMethod = NULL;
    g_origDrawMetal = NULL;
  }
  if (g_arrange && g_origProc)
  {
    SetWindowLong(g_arrange, GWL_WNDPROC, (LONG_PTR)g_origProc);
    NSView *view = (NSView *)g_arrange;
    untrack_texture(g_texIvar ? object_getIvar(view, g_texIvar) : nil);
    [(id)view setOpaque:YES];
    if ([view layer]) [view layer].opaque = YES;
    InvalidateRect(g_arrange, NULL, FALSE);
  }
  if (g_backView) { [g_backView removeFromSuperview]; [g_backView release]; g_backView = nil; }
  g_origProc = NULL;
  g_arrange  = NULL;
  g_texIvar  = NULL;
  g_enabled  = false;
}

// The layer behind the video shows the theme's track background colour, so the
// opacity slider fades the video into the normal arrange look.
static void set_root_color(unsigned rgb)
{
  if (!g_backView) return;
  CGColorRef c = CGColorCreateGenericRGB(((rgb >> 16) & 0xFF) / 255.0, ((rgb >> 8) & 0xFF) / 255.0, (rgb & 0xFF) / 255.0, 1.0);
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [g_backView layer].backgroundColor = c;
  [CATransaction commit];
  CGColorRelease(c);
}

// Returns the swell Metal mode of the arrange view (1 = direct, 2 = full
// pipeline) on success, or a negative error code.
static int AUBG_Enable(int enable, int key_rgb, int tolerance)
{
  if (!enable) { disable(); return 0; }
  if (g_enabled) disable();

  HWND arrange = GetDlgItem(g_main, 1000);
  if (!arrange) return -1;
  NSView *view = (NSView *)arrange;

  const int metal = ivar_char(view, "m_use_metal", -99);
  if (metal == -99) return -3;          // swell internals changed
  if (metal <= 0)   return -4;          // non-Metal renderer: nothing to key
  g_texIvar = class_getInstanceVariable([view class], "m_metal_texture");
  if (!g_texIvar) return -3;

  g_drawMetalMethod = class_getInstanceMethod([view class], @selector(swellDrawMetal:));
  if (!g_drawMetalMethod) return -3;

  g_origProc = (WNDPROC)SetWindowLong(arrange, GWL_WNDPROC, (LONG_PTR)hook_proc);
  if (!g_origProc) { g_drawMetalMethod = NULL; return -2; }
  g_origDrawMetal = method_setImplementation(g_drawMetalMethod, (IMP)swz_swellDrawMetal);

  g_arrange   = arrange;
  g_keyRGB    = (unsigned)key_rgb;
  g_tolerance = tolerance;

  [(id)view setOpaque:NO];
  if ([view layer]) [view layer].opaque = NO;

  // Layer-hosting view behind the arrange; the media layer lives in it.
  g_backView = [[NSView alloc] initWithFrame:[view frame]];
  CALayer *root = [CALayer layer];
  [g_backView setLayer:root];
  set_root_color(g_keyRGB);
  [g_backView setWantsLayer:YES];
  [[view superview] addSubview:g_backView positioned:NSWindowBelow relativeTo:view];

  g_enabled = true;
  InvalidateRect(arrange, NULL, FALSE);
  return metal;
}

// Opacity of the video over the background-coloured root layer: 1 shows it
// fully, 0 only the track background colour. The media layer's own opacity,
// one full-size layer less than a tint layer on top.
static void AUBG_SetOpacity(double o)
{
  if (!g_mediaLayer) return;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  g_mediaLayer.opacity = (float)(o < 0 ? 0 : o > 1 ? 1 : o);
  [CATransaction commit];
}

static void AUBG_SetPan(double x, double y)
{
  g_panX = x < -1 ? -1 : x > 1 ? 1 : x;
  g_panY = y < -1 ? -1 : y > 1 ? 1 : y;
  layout_player();
}

// ---- Still images, via ImageIO. Properties of the first image in a file
// (autoreleased), nil when the file is not an image (video files included).
static NSDictionary *image_props(const char *path)
{
  if (!path || !*path) return nil;
  CGImageSourceRef src = CGImageSourceCreateWithURL((CFURLRef)[NSURL fileURLWithPath:@(path)], NULL);
  if (!src) return nil;
  NSDictionary *props = (NSDictionary *)CGImageSourceCopyPropertiesAtIndex(src, 0, NULL);
  CFRelease(src);
  if (props && [props[(id)kCGImagePropertyPixelWidth] doubleValue] <= 0) { [props release]; props = nil; }
  return [props autorelease];
}

// Decodes an image rotated per its EXIF orientation and scaled down to fit
// max_w x max_h (0 = unlimited). Caller releases. NULL if not an image.
static CGImageRef image_fit(const char *path, int max_w, int max_h)
{
  NSDictionary *props = image_props(path);
  if (!props) return NULL;
  CGImageSourceRef src = CGImageSourceCreateWithURL((CFURLRef)[NSURL fileURLWithPath:@(path)], NULL);
  if (!src) return NULL;
  double w = [props[(id)kCGImagePropertyPixelWidth] doubleValue], h = [props[(id)kCGImagePropertyPixelHeight] doubleValue];
  if ([props[(id)kCGImagePropertyOrientation] intValue] >= 5) std::swap(w, h);
  double s = 1;
  if (max_w > 0 && w > max_w) s = max_w / w;
  if (max_h > 0 && h * s > max_h) s = max_h / h;
  NSMutableDictionary *opts = [NSMutableDictionary dictionaryWithDictionary:@{
    (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES, (id)kCGImageSourceCreateThumbnailWithTransform: @YES }];
  if (s < 1) opts[(id)kCGImageSourceThumbnailMaxPixelSize] = @((int)ceil(fmax(w, h) * s));
  CGImageRef img = CGImageSourceCreateThumbnailAtIndex(src, 0, (CFDictionaryRef)opts);
  CFRelease(src);
  return img;
}

static bool write_image(CGImageRef img, NSString *path, bool png)
{
  NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
  NSData *data = png ? [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                     : [rep representationUsingType:NSBitmapImageFileTypeJPEG properties:@{ NSImageCompressionFactor: @0.9 }];
  [rep release];
  return [data writeToFile:path atomically:YES];
}

static int AUBG_IsImage(const char *path) { return image_props(path) ? 1 : 0; }

// Copies an image into the library as dst_base.png (when it has alpha) or
// dst_base.jpg, upright and at most 3840 px on either side. Returns the
// extension written, or "" if the source is not an image.
static const char *AUBG_ImportImage(const char *src, const char *dst_base)
{
  if (!src || !dst_base || !*dst_base) return "";
  @autoreleasepool
  {
    NSDictionary *props = image_props(src);
    CGImageRef img = props ? image_fit(src, 3840, 3840) : NULL;
    if (!img) return "";
    const bool png = [props[(id)kCGImagePropertyHasAlpha] boolValue];
    const bool ok = write_image(img, [NSString stringWithFormat:@"%s.%s", dst_base, png ? "png" : "jpg"], png);
    CGImageRelease(img);
    return !ok ? "" : png ? "png" : "jpg";
  }
}

// Loads a video file into an AVPlayerLayer (aspect-fill, muted), or an image
// file into a plain layer, behind the arrange.
static int AUBG_OpenVideo(const char *path, double opacity)
{
  if (!g_enabled || !g_backView || !path || !*path) return 0;
  close_video();

  NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
  if (![[NSFileManager defaultManager] fileExistsAtPath:[url path]]) return 0;

  if (CGImageRef img = image_fit(path, 0, 0))
  {
    CALayer *layer = [[CALayer alloc] init];
    layer.contents = (id)img;
    layer.contentsGravity = kCAGravityResize;
    layer.minificationFilter = kCAFilterTrilinear;
    g_videoSize = CGSizeMake(CGImageGetWidth(img), CGImageGetHeight(img));
    CGImageRelease(img);
    g_mediaLayer = layer;
    [[g_backView layer] addSublayer:g_mediaLayer];
    layout_player();
    g_visible = true;
    AUBG_SetOpacity(opacity);
    return 1;
  }

  g_player = [[AVPlayer alloc] initWithURL:url];
  g_player.muted = YES;
  g_player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
  if ([g_player respondsToSelector:@selector(setAutomaticallyWaitsToMinimizeStalling:)])
    g_player.automaticallyWaitsToMinimizeStalling = NO;

  AVAssetTrack *track = [[[AVURLAsset URLAssetWithURL:url options:nil] tracksWithMediaType:AVMediaTypeVideo] firstObject];
  g_videoSize = CGSizeMake(16, 9);
  if (track)
  {
    CGSize n = CGSizeApplyAffineTransform(track.naturalSize, track.preferredTransform);
    if (fabs(n.width) > 0 && fabs(n.height) > 0) g_videoSize = CGSizeMake(fabs(n.width), fabs(n.height));
  }
  AVPlayerLayer *playerLayer = [[AVPlayerLayer playerLayerWithPlayer:g_player] retain];
  playerLayer.videoGravity = AVLayerVideoGravityResize;
  g_mediaLayer = playerLayer;
  [[g_backView layer] addSublayer:g_mediaLayer];
  layout_player();
  g_visible = true;
  AUBG_SetOpacity(opacity);
  return 1;
}

static void AUBG_SetRate(double rate) { g_rate = rate > 0 ? (float)rate : 1.0f; }

// Issues a seek unless one is pending. A completion that never arrives would
// otherwise block seeking forever, so a pending seek expires after a second.
static bool issue_seek(double target, CMTime tol)
{
  if (g_seeking.load() && now_ms() - g_seekIssuedMs > 1000) { g_seeking = false; ++g_seekTimeouts; }
  if (g_seeking.exchange(true)) return false;
  const double d = CMTimeGetSeconds(g_player.currentItem.duration);
  if (d > 0.2 && target > d - 0.1) target = d - 0.1;   // never park at the item end
  if (target < 0) target = 0;
  g_seekIssuedMs = now_ms();
  ++g_seekCount;
  [g_player seekToTime:CMTimeMakeWithSeconds(target, 600) toleranceBefore:tol toleranceAfter:tol
       completionHandler:^(BOOL) { g_seeking = false; }];
  return true;
}

// Keeps the player in step with REAPER: seeks when stopped or drifting,
// plays/pauses on transport changes, hides the media when out of range.
static void AUBG_Sync(double time, int playing, int visible)
{
  if (!g_mediaLayer) return;
  if ((visible != 0) != g_visible)
  {
    g_visible = visible != 0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    g_mediaLayer.hidden = !g_visible;
    [CATransaction commit];
  }
  if (!g_player) return;
  if (!visible) { if (g_playing) { [g_player pause]; g_playing = false; } return; }

  const double cur = CMTimeGetSeconds([g_player currentTime]);
  // The player pauses itself at the end of the item, so trust its rate rather
  // than our own flag; and never queue a second seek while one is in flight,
  // or a player that cannot keep up degrades into a slideshow of seeks.
  const bool rolling = g_player.rate != 0;
  if (playing)
  {
    const double drift = cur - time;   // > 0: player ahead of REAPER
    g_lastDrift = drift;
    if (!rolling || fabs(drift) > 0.5)
    {
      // A seek lands late by its decode time, so aim ahead by the lead learnt
      // from previous landings. A frame of tolerance keeps it cheap.
      if (issue_seek(time + g_seekLead, CMTimeMake(1, 30))) g_leadPending = true;
      if (!rolling) [g_player setRate:g_rate];
    }
    else
    {
      if (g_leadPending && !g_seeking)
      {
        g_leadPending = false;
        g_seekLead = fmin(0.5, fmax(0.0, g_seekLead - drift * 0.7));
      }
      // Small drift is absorbed by running slightly fast or slow rather than
      // by seeking, which would only land late again.
      float want = g_rate;
      if (fabs(drift) > 0.015) want = g_rate * (float)(1.0 - fmax(-0.1, fmin(0.1, drift * 0.5)));
      if (fabsf(g_player.rate - want) > 0.002f) [g_player setRate:want];
    }
    g_playing = true;
  }
  else
  {
    if (rolling) [g_player pause];
    g_playing = false;
    if (fabs(cur - time) > 0.001) issue_seek(time, kCMTimeZero);
  }
}

static void AUBG_ClearKeys() { g_sec.clear(); g_outs.clear(); g_outSrc.clear(); g_nearTol = 0; rebuild_key_tables(); }

// src_rgb: colour as REAPER draws it (0xRRGGBB). Pixels within tolerance per
// channel are replaced by out_rgb at out_alpha (0..1), premultiplied.
static int AUBG_AddKey(int src_rgb, int tolerance, int out_rgb, double out_alpha)
{
  if (out_alpha < 0) out_alpha = 0;
  if (out_alpha > 1) out_alpha = 1;
  const unsigned a = (unsigned)(out_alpha * 255.0 + 0.5);
  unsigned out = 0;
  if (a)
  {
    const unsigned r = ((out_rgb >> 16) & 0xFF) * a / 255, g = ((out_rgb >> 8) & 0xFF) * a / 255, b = (out_rgb & 0xFF) * a / 255;
    out = (a << 24) | (r << 16) | (g << 8) | b;
  }
  SecKey k = { (src_rgb >> 16) & 0xFF, (src_rgb >> 8) & 0xFF, src_rgb & 0xFF, tolerance < 0 ? 0 : tolerance, out };
  g_sec.push_back(k);
  if (out) { g_outs.push_back(out); g_outSrc.push_back((unsigned)src_rgb & 0xFFFFFF); }
  rebuild_key_tables();
  return (int)g_sec.size();
}

// tolerance 0 disables. opacity 0..1 is the output alpha; gain amplifies the
// colour deviation from the key so a faint theme tint stays visible.
static void AUBG_SetNearKey(int tolerance, double opacity, double gain)
{
  g_nearTol = tolerance < 0 ? 0 : tolerance;
  int a = (int)(opacity * 255.0 + 0.5);
  g_nearA = a < 1 ? 1 : a > 254 ? 254 : a;
  g_nearGain = gain;
}

static void AUBG_SetKey(int key_rgb, int tolerance)
{
  g_keyRGB = (unsigned)key_rgb;
  g_tolerance = tolerance;
  rebuild_key_tables();
  set_root_color(g_keyRGB);
  if (g_arrange) InvalidateRect(g_arrange, NULL, FALSE);
}

// Blends overlay_rgb over bg_rgb exactly as REAPER draws a theme element with
// the given draw mode (theme *_drawmode / *_mode value: LICE blit mode in the
// low byte, alpha*256 in the next byte), using REAPER's own LICE. Returns the
// resulting 0xRRGGBB, or -1 if the LICE exports are unavailable.
static int AUBG_BlendColor(int bg_rgb, int overlay_rgb, int drawmode)
{
  if (!p_LICE_CreateBitmap || !p_LICE_Clear || !p_LICE_FillRect || !p_LICE_GetPixel || !p_LICE__Destroy) return -1;
  LICE_IBitmap *bm = p_LICE_CreateBitmap(0, 1, 1);
  if (!bm) return -1;
  p_LICE_Clear(bm, 0xFF000000u | (unsigned)bg_rgb);
  p_LICE_FillRect(bm, 0, 0, 1, 1, 0xFF000000u | (unsigned)overlay_rgb, ((drawmode >> 8) & 0xFF) / 256.0f, drawmode & 0xFF);
  const int out = (int)(p_LICE_GetPixel(bm, 0, 0) & 0xFFFFFF);
  p_LICE__Destroy(bm);
  return out;
}

// ---- File picker. A modeless NSOpenPanel: a modal one (GetUserFileNameForRead)
// stalls every script's defer loop while ReaImGui's housekeeping keeps running,
// which destroys other scripts' contexts. The script polls PickState.
enum { PK_IDLE = 0, PK_OPEN = 1, PK_DONE = 2, PK_CANCELLED = -1 };
static NSOpenPanel *g_openPanel = nil;
static std::atomic<int> g_pickState(PK_IDLE);
static std::string g_pickedPath;

static int AUBG_PickFile(const char *message)
{
  if (g_pickState.load() == PK_OPEN)
  {
    if (g_openPanel) [g_openPanel makeKeyAndOrderFront:nil];
    return 0;
  }
  NSOpenPanel *panel = [[NSOpenPanel openPanel] retain];
  panel.canChooseFiles = YES;
  panel.canChooseDirectories = NO;
  panel.allowsMultipleSelection = NO;
  panel.allowedFileTypes = @[@"mov", @"mp4", @"m4v", @"mpg", @"mpeg", @"m2v", @"avi", @"3gp", @"mts", @"m2ts",
                             @"jpg", @"jpeg", @"png", @"gif", @"heic", @"heif", @"tif", @"tiff", @"bmp", @"webp"];
  panel.prompt = @"Import";
  if (message && *message) panel.message = [NSString stringWithUTF8String:message];
  g_openPanel = panel;
  g_pickedPath.clear();
  g_pickState.store(PK_OPEN);
  // Script windows float above REAPER; the panel must sit above them too.
  panel.level = NSModalPanelWindowLevel;
  [panel beginWithCompletionHandler:^(NSModalResponse r) {
    if (r == NSModalResponseOK && panel.URL.path) g_pickedPath = panel.URL.path.UTF8String;
    g_pickState.store(r == NSModalResponseOK && !g_pickedPath.empty() ? PK_DONE : PK_CANCELLED);
    g_openPanel = nil;
    [panel release];
  }];
  [NSApp activateIgnoringOtherApps:YES];
  [panel makeKeyAndOrderFront:nil];
  return 1;
}

// 1 while the panel is open, 2 once a file was chosen, -1 if it was cancelled;
// a final state is reported once and then resets to 0.
static int AUBG_PickState()
{
  int st = g_pickState.load();
  if (st == PK_DONE || st == PK_CANCELLED) g_pickState.store(PK_IDLE);
  return st;
}
static const char *AUBG_PickedPath() { return g_pickedPath.c_str(); }

static double AUBG_ProbeDuration(const char *path)
{
  if (!path || !*path) return 0;
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:path]] options:nil];
  const CMTime d = asset.duration;
  return CMTIME_IS_NUMERIC(d) ? CMTimeGetSeconds(d) : 0;
}

// ---- Transcode (single slot). The completion handler runs on an arbitrary
// queue and only touches the atomics, the error string under its lock and the
// files on disk, so finishing never depends on Lua polling.
enum { TX_IDLE = 0, TX_RUNNING = 1, TX_DONE = 2, TX_FAILED = -1 };
static AVAssetExportSession *g_export = nil;
static std::atomic<int> g_txStatus(TX_IDLE);
static NSLock *g_txLock = nil;
static std::string g_txErr;
static char g_txErrOut[1024];

static void tx_set_error(NSString *msg)
{
  [g_txLock lock];
  g_txErr = msg ? [msg UTF8String] : "unknown error";
  [g_txLock unlock];
}

// Writes one frame of a video, or a still image, as JPEG (fit within
// max_w x max_h). time < 0 = middle of the video.
static int AUBG_Frame(const char *path, const char *out, double time, int max_w, int max_h)
{
  if (!path || !out) return 0;
  @autoreleasepool
  {
    if (CGImageRef img = image_fit(path, max_w > 0 ? max_w : 1280, max_h > 0 ? max_h : 720))
    {
      const bool ok = write_image(img, @(out), false);
      CGImageRelease(img);
      return ok ? 1 : 0;
    }
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@(path)] options:nil];
    const double dur = CMTimeGetSeconds(asset.duration);
    if (!(dur > 0)) return 0;
    if (time < 0) time = dur / 2;
    if (time > dur) time = dur;
    AVAssetImageGenerator *gen = [[AVAssetImageGenerator alloc] initWithAsset:asset];
    gen.appliesPreferredTrackTransform = YES;
    gen.maximumSize = CGSizeMake(max_w > 0 ? max_w : 1280, max_h > 0 ? max_h : 720);
    gen.requestedTimeToleranceBefore = CMTimeMake(1, 10);
    gen.requestedTimeToleranceAfter = CMTimeMake(1, 10);
    CGImageRef img = [gen copyCGImageAtTime:CMTimeMakeWithSeconds(time, 600) actualTime:NULL error:NULL];
    [gen release];
    if (!img) return 0;
    const bool ok = write_image(img, @(out), false);
    CGImageRelease(img);
    return ok ? 1 : 0;
  }
}

// Returns 1 on start, -1 bad input, -2 already running, -3 dst exists, -4 unsupported source.
static int AUBG_TranscodeStart(const char *src, const char *dst, double in_sec, double out_sec)
{
  if (!src || !*src || !dst || !*dst) return -1;
  if (g_txStatus.load() == TX_RUNNING) return -2;
  if (!g_txLock) g_txLock = [[NSLock alloc] init];
  if (g_export) { [g_export release]; g_export = nil; }
  NSString *dstPath = [NSString stringWithUTF8String:dst];
  NSString *partPath = [dstPath stringByAppendingString:@".part.mp4"];
  NSFileManager *fm = [NSFileManager defaultManager];
  if ([fm fileExistsAtPath:dstPath]) return -3;
  [fm removeItemAtPath:partPath error:nil];

  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:src]] options:nil];
  if (![asset isExportable] || [[asset tracksWithMediaType:AVMediaTypeVideo] count] == 0) return -4;
  AVAssetExportSession *session = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPreset1280x720];
  if (!session) return -4;
  session.outputFileType = AVFileTypeMPEG4;
  session.outputURL = [NSURL fileURLWithPath:partPath];
  session.shouldOptimizeForNetworkUse = YES;
  if (in_sec > 0 || out_sec > 0)
  {
    const CMTime start = CMTimeMakeWithSeconds(in_sec > 0 ? in_sec : 0, 600);
    const CMTime end = out_sec > 0 ? CMTimeMakeWithSeconds(out_sec, 600) : asset.duration;
    session.timeRange = CMTimeRangeFromTimeToTime(start, end);
  }
  g_export = session;
  g_txErr.clear();
  g_txStatus.store(TX_RUNNING);
  [dstPath retain]; [partPath retain];
  [session exportAsynchronouslyWithCompletionHandler:^{
    NSFileManager *fm2 = [NSFileManager defaultManager];
    if (session.status == AVAssetExportSessionStatusCompleted)
    {
      NSError *err = nil;
      if ([fm2 moveItemAtPath:partPath toPath:dstPath error:&err]) g_txStatus.store(TX_DONE);
      else { tx_set_error([err localizedDescription]); [fm2 removeItemAtPath:partPath error:nil]; g_txStatus.store(TX_FAILED); }
    }
    else
    {
      [fm2 removeItemAtPath:partPath error:nil];
      if (session.status == AVAssetExportSessionStatusCancelled) g_txStatus.store(TX_IDLE);
      else { tx_set_error([session.error localizedDescription]); g_txStatus.store(TX_FAILED); }
    }
    [dstPath release]; [partPath release];
  }];
  return 1;
}

// 0 idle, 1 running, 2 done, -1 failed. Done/failed persist until the next start.
static int AUBG_TranscodeStatus()
{
  const int st = g_txStatus.load();
  if (st != TX_RUNNING && g_export) { [g_export release]; g_export = nil; }
  return st;
}

static double AUBG_TranscodeProgress()
{
  return (g_txStatus.load() == TX_RUNNING && g_export) ? g_export.progress : (g_txStatus.load() == TX_DONE ? 1.0 : 0.0);
}

static const char *AUBG_TranscodeError()
{
  if (!g_txLock) return "";
  [g_txLock lock];
  snprintf(g_txErrOut, sizeof(g_txErrOut), "%s", g_txErr.c_str());
  [g_txLock unlock];
  return g_txErrOut;
}

static void AUBG_TranscodeCancel()
{
  if (g_txStatus.load() == TX_RUNNING && g_export) [g_export cancelExport];
}

// ---- Script launcher. ReaBackground.lua is the single user-facing action; it
// hosts the engine and the settings window. While it runs it registers its
// command id here, so re-running the action (or the Extensions menu item) is
// turned into a "show window" request instead of REAPER's relaunch prompt.
#define EXT_SECTION "ReaBackground"
#define SCRIPT_NAME "ReaBackground.lua"
static int g_scriptCmd = 0;   // command id of the running script instance, 0 when not running
static int g_openCmd   = 0;   // our native "open settings" command (Extensions menu)

static void AUBG_SetScript(int cmd_id) { g_scriptCmd = cmd_id; }

// Finds the installed script: the path it recorded on its last run, else a
// shallow search of the Scripts folder (first launch after a ReaPack install).
static std::string find_script()
{
  if (!p_GetExtState || !p_GetResourcePath) return "";
  const char *saved = p_GetExtState(EXT_SECTION, "script_path");
  if (saved && *saved && access(saved, R_OK) == 0) return saved;
  NSString *root = [NSString stringWithFormat:@"%s/Scripts", p_GetResourcePath()];
  NSDirectoryEnumerator *e = [[NSFileManager defaultManager] enumeratorAtPath:root];
  for (NSString *rel in e)
  {
    if ([e level] > 4) { [e skipDescendants]; continue; }
    if ([[rel lastPathComponent] isEqualToString:@SCRIPT_NAME])
      return [[root stringByAppendingPathComponent:rel] UTF8String];
  }
  return "";
}

static void launch_script(bool headless)
{
  if (!p_AddRemoveReaScript || !p_Main_OnCommand || !p_SetExtState) return;
  const std::string path = find_script();
  if (path.empty()) return;
  const int id = p_AddRemoveReaScript(true, 0, path.c_str(), true);
  if (id <= 0) return;
  if (headless) p_SetExtState(EXT_SECTION, "headless", "1", false);
  p_Main_OnCommand(id, 0);
}

static void open_settings()
{
  if (g_scriptCmd && p_SetExtState) p_SetExtState(EXT_SECTION, "show", "1", false);
  else launch_script(false);
}

static bool hookcommand(int command, int)
{
  if (command && command == g_scriptCmd) { open_settings(); return true; }
  if (command && command == g_openCmd)   { open_settings(); return true; }
  return false;
}

static void menuhook(const char *menuidstr, HMENU menu, int flag)
{
  if (flag != 0 || !g_openCmd || strcmp(menuidstr, "Main extensions")) return;
  MENUITEMINFO mi = { sizeof(mi) };
  mi.fMask = MIIM_TYPE | MIIM_ID;
  mi.fType = MFT_STRING;
  mi.wID = g_openCmd;
  mi.dwTypeData = (char *)"ReaBackground...";
  InsertMenuItem(menu, GetMenuItemCount(menu), TRUE, &mi);
}

// Auto-start: ~2 s after REAPER loads the extension, run the script without
// its window if the user enabled it.
static CFAbsoluteTime g_loadTime = 0;
static bool g_autostartDone = false;
static void autostart_timer()
{
  if (g_autostartDone || CFAbsoluteTimeGetCurrent() - g_loadTime < 2.0) return;
  g_autostartDone = true;
  if (g_rec) g_rec->Register("-timer", (void *)autostart_timer);
  if (!p_GetExtState) return;
  const char *on = p_GetExtState(EXT_SECTION, "autostart");
  if (on && !strcmp(on, "1") && !g_scriptCmd) launch_script(true);
}

static double AUBG_GetDuration()
{
  if (!g_player || !g_player.currentItem) return 0;
  const CMTime d = g_player.currentItem.duration;
  return CMTIME_IS_NUMERIC(d) ? CMTimeGetSeconds(d) : 0;
}

// ---- Diagnostics, shown in the settings window's footer while Alt is held.
static int AUBG_AltDown()
{
  return ([NSEvent modifierFlags] & NSEventModifierFlagOption) ? 1 : 0;
}

// Size of the area the video fills (the arrange view, in points); "" when disabled.
static const char *AUBG_ViewSize()
{
  static char buf[64];
  if (!g_enabled || !g_arrange) return "";
  NSRect f = [(NSView *)g_arrange frame];
  snprintf(buf, sizeof(buf), "%d,%d", (int)f.size.width, (int)f.size.height);
  return buf;
}

// "drift_ms|seeks|player_rate|lead_ms|key_ms|mode|paints|pending|timeouts|px"
static const char *AUBG_Stats()
{
  static char buf[160];
  snprintf(buf, sizeof(buf), "%.0f|%d|%.3f|%.0f|%.2f|%c|%d|%d|%d|%ld", g_lastDrift * 1000, g_seekCount,
           g_player ? g_player.rate : 0.0f, g_seekLead * 1000, g_lastKeyMs, g_lastMode, g_paintCount,
           g_seeking.load() ? 1 : 0, g_seekTimeouts, g_lastPx);
  return buf;
}

// "x,y: AARRGGBB*n ..." for the 9x9 texture pixels under the mouse when it is
// over the arrange, most frequent first; empty otherwise. Alpha tells how a
// pixel was classified: 00 key, FF untouched, the near-key or a table alpha.
static const char *AUBG_Probe()
{
  static char buf[512];
  buf[0] = 0;
  id<MTLTexture> tex = (g_arrange && g_texIvar) ? object_getIvar((id)g_arrange, g_texIvar) : nil;
  if (!tex) return buf;
  NSView *view = (NSView *)g_arrange;
  NSWindow *win = [view window];
  if (!win) return buf;
  NSPoint p = [view convertPoint:[win mouseLocationOutsideOfEventStream] fromView:nil];
  const NSRect bounds = [view bounds];
  if (![view isFlipped]) p.y = bounds.size.height - p.y;
  const int tw = (int)tex.width, th = (int)tex.height;
  if (bounds.size.width < 1 || p.x < 0 || p.y < 0 || p.x >= bounds.size.width || p.y >= bounds.size.height) return buf;
  const int sc = tw >= (int)bounds.size.width * 2 ? 2 : 1;
  RECT cr; GetClientRect(g_arrange, &cr);
  const bool nc = p.x >= cr.right || p.y >= cr.bottom;
  int x = (int)p.x * sc - 4, y = (int)p.y * sc - 4, w = 9, h = 9;
  if (x < 0) { w += x; x = 0; }
  if (y < 0) { h += y; y = 0; }
  if (x + w > tw) w = tw - x;
  if (y + h > th) h = th - y;
  if (w < 1 || h < 1) return buf;
  unsigned px[81];
  raw_getBytes(tex, px, w * 4, MTLRegionMake2D(x, y, w, h));
  struct { unsigned v, n; } hist[81];
  int hn = 0;
  for (int i = 0; i < w * h; ++i)
  {
    int j = 0;
    while (j < hn && hist[j].v != px[i]) ++j;
    if (j == hn) { hist[hn].v = px[i]; hist[hn].n = 0; ++hn; }
    ++hist[j].n;
  }
  for (int i = 1; i < hn; ++i)
    for (int j = i; j > 0 && hist[j].n > hist[j - 1].n; --j) std::swap(hist[j], hist[j - 1]);
  char *o = buf, *e = buf + sizeof(buf) - 1;
  o += snprintf(o, e - o, "%d,%d%s of %dx%d:", (int)p.x * sc, (int)p.y * sc, nc ? " nc" : "", tw, th);
  for (int i = 0; i < hn && i < 6 && o < e - 16; ++i) o += snprintf(o, e - o, " %08X*%u", hist[i].v, hist[i].n);
  return buf;
}

// ReaScript vararg thunks
static void *va_AUBG_Enable(void **a, int)
{
  return (void *)(INT_PTR)AUBG_Enable((int)(INT_PTR)a[0], (int)(INT_PTR)a[1], (int)(INT_PTR)a[2]);
}
static void *va_AUBG_OpenVideo(void **a, int)
{
  return (void *)(INT_PTR)AUBG_OpenVideo((const char *)a[0], a[1] ? *(double *)a[1] : 0.0);
}
static void *va_AUBG_Sync(void **a, int)
{
  AUBG_Sync(a[0] ? *(double *)a[0] : 0.0, (int)(INT_PTR)a[1], (int)(INT_PTR)a[2]);
  return NULL;
}
static void *va_AUBG_ClearKeys(void **, int) { AUBG_ClearKeys(); return NULL; }
static void *va_AUBG_AddKey(void **a, int)
{
  return (void *)(INT_PTR)AUBG_AddKey((int)(INT_PTR)a[0], (int)(INT_PTR)a[1], (int)(INT_PTR)a[2], a[3] ? *(double *)a[3] : 0.0);
}
static void *va_AUBG_SetNearKey(void **a, int)
{
  AUBG_SetNearKey((int)(INT_PTR)a[0], a[1] ? *(double *)a[1] : 0.0, a[2] ? *(double *)a[2] : 1.0);
  return NULL;
}
static void *va_AUBG_SetKey(void **a, int) { AUBG_SetKey((int)(INT_PTR)a[0], (int)(INT_PTR)a[1]); return NULL; }
static void *va_AUBG_BlendColor(void **a, int)
{
  return (void *)(INT_PTR)AUBG_BlendColor((int)(INT_PTR)a[0], (int)(INT_PTR)a[1], (int)(INT_PTR)a[2]);
}
static void *va_AUBG_ProbeDuration(void **a, int) { static double r; r = AUBG_ProbeDuration((const char *)a[0]); return &r; }
static void *va_AUBG_Frame(void **a, int)
{
  return (void *)(INT_PTR)AUBG_Frame((const char *)a[0], (const char *)a[1], a[2] ? *(double *)a[2] : -1.0,
                                     (int)(INT_PTR)a[3], (int)(INT_PTR)a[4]);
}
static void *va_AUBG_TranscodeStart(void **a, int)
{
  return (void *)(INT_PTR)AUBG_TranscodeStart((const char *)a[0], (const char *)a[1],
                                               a[2] ? *(double *)a[2] : 0.0, a[3] ? *(double *)a[3] : 0.0);
}
static void *va_AUBG_TranscodeStatus(void **, int)   { return (void *)(INT_PTR)AUBG_TranscodeStatus(); }
static void *va_AUBG_TranscodeProgress(void **, int) { static double r; r = AUBG_TranscodeProgress(); return &r; }
static void *va_AUBG_TranscodeError(void **, int)    { return (void *)AUBG_TranscodeError(); }
static void *va_AUBG_TranscodeCancel(void **, int)   { AUBG_TranscodeCancel(); return NULL; }
static void *va_AUBG_SetScript(void **a, int) { AUBG_SetScript((int)(INT_PTR)a[0]); return NULL; }
static void *va_AUBG_SetRate(void **a, int)   { AUBG_SetRate(a[0] ? *(double *)a[0] : 1.0); return NULL; }
static void *va_AUBG_SetOpacity(void **a, int)   { AUBG_SetOpacity(a[0] ? *(double *)a[0] : 0.0); return NULL; }
static void *va_AUBG_SetPan(void **a, int)
{
  AUBG_SetPan(a[0] ? *(double *)a[0] : 0.0, a[1] ? *(double *)a[1] : 0.0);
  return NULL;
}
static void *va_AUBG_AltDown(void **, int)    { return (void *)(INT_PTR)AUBG_AltDown(); }
static void *va_AUBG_ViewSize(void **, int)   { return (void *)AUBG_ViewSize(); }
static void *va_AUBG_PickFile(void **a, int)  { return (void *)(INT_PTR)AUBG_PickFile((const char *)a[0]); }
static void *va_AUBG_PickState(void **, int)  { return (void *)(INT_PTR)AUBG_PickState(); }
static void *va_AUBG_PickedPath(void **, int) { return (void *)AUBG_PickedPath(); }
static void *va_AUBG_IsImage(void **a, int)     { return (void *)(INT_PTR)AUBG_IsImage((const char *)a[0]); }
static void *va_AUBG_ImportImage(void **a, int) { return (void *)AUBG_ImportImage((const char *)a[0], (const char *)a[1]); }
static void *va_AUBG_Stats(void **, int)      { return (void *)AUBG_Stats(); }
static void *va_AUBG_Probe(void **, int)      { return (void *)AUBG_Probe(); }
static void *va_AUBG_GetDuration(void **, int)  { static double r; r = AUBG_GetDuration();  return &r; }

#define REG_API(name, ret, argtypes, argnames, help) \
  rec->Register("API_" #name, (void *)name); \
  rec->Register("APIvararg_" #name, (void *)va_##name); \
  rec->Register("APIdef_" #name, (void *)(ret "\0" argtypes "\0" argnames "\0" help));

extern "C" __attribute__((visibility("default")))
int ReaperPluginEntry(REAPER_PLUGIN_HINSTANCE hInstance, reaper_plugin_info_t *rec)
{
  if (!rec)
  {
    disable();
    if (g_openPanel) [g_openPanel cancel:nil];
    AUBG_TranscodeCancel();
    if (g_rec)
    {
      if (!g_autostartDone) g_rec->Register("-timer", (void *)autostart_timer);
      g_rec->Register("-hookcommand", (void *)hookcommand);
      g_rec->Register("-hookcustommenu", (void *)menuhook);
    }
    g_rec = NULL;
    return 0;
  }
  if (rec->caller_version != REAPER_PLUGIN_VERSION || !rec->GetFunc) return 0;
  g_rec = rec;
  g_main = rec->hwnd_main;
  *(void **)&p_LICE_CreateBitmap = rec->GetFunc("LICE_CreateBitmap");
  *(void **)&p_LICE_Clear        = rec->GetFunc("LICE_Clear");
  *(void **)&p_LICE_FillRect     = rec->GetFunc("LICE_FillRect");
  *(void **)&p_LICE_GetPixel     = rec->GetFunc("LICE_GetPixel");
  *(void **)&p_LICE__Destroy     = rec->GetFunc("LICE__Destroy");
  *(void **)&p_GetExtState       = rec->GetFunc("GetExtState");
  *(void **)&p_SetExtState       = rec->GetFunc("SetExtState");
  *(void **)&p_Main_OnCommand    = rec->GetFunc("Main_OnCommand");
  *(void **)&p_GetResourcePath   = rec->GetFunc("GetResourcePath");
  *(void **)&p_AddRemoveReaScript = rec->GetFunc("AddRemoveReaScript");
  *(void **)&p_AddExtensionsMainMenu = rec->GetFunc("AddExtensionsMainMenu");

  g_openCmd = rec->Register("command_id", (void *)"AUBG_OPEN_SETTINGS");
  rec->Register("hookcommand", (void *)hookcommand);
  if (p_AddExtensionsMainMenu) p_AddExtensionsMainMenu();
  rec->Register("hookcustommenu", (void *)menuhook);
  g_loadTime = CFAbsoluteTimeGetCurrent();
  rec->Register("timer", (void *)autostart_timer);

  REG_API(AUBG_Enable, "int", "int,int,int", "enable,key_rgb,tolerance",
          "Make arrange-view pixels within tolerance of key_rgb (0xRRGGBB) transparent as they are drawn, "
          "and place a layer-hosting view filled with the key colour behind the arrange. "
          "Returns swell Metal mode (1 or 2) or a negative error.");
  REG_API(AUBG_OpenVideo, "int", "const char*,double", "path,opacity",
          "Show a video (aspect-fill, muted) or a still image behind the arrange at the given opacity over the track background colour. Requires AUBG_Enable.");
  REG_API(AUBG_Sync, "void", "double,int,int", "time,playing,visible",
          "Seek/play/pause the video to match REAPER. time is seconds into the video.");
  REG_API(AUBG_ClearKeys, "void", "", "", "Remove all secondary keys.");
  REG_API(AUBG_AddKey, "int", "int,int,int,double", "src_rgb,tolerance,out_rgb,out_alpha",
          "Secondary key: arrange pixels within tolerance (per channel) of src_rgb are replaced by out_rgb at out_alpha "
          "(semi-transparent, so the video shows through a shaded overlay). Returns the number of secondary keys.");
  REG_API(AUBG_SetNearKey, "void", "int,double,double", "tolerance,opacity,gain",
          "Pixels within tolerance (per channel) of the key, but not equal to it, are treated as background shaded by a "
          "translucent overlay: the deviation from the key is amplified by gain and output at opacity (0..1). 0 disables.");
  REG_API(AUBG_SetKey, "void", "int,int", "key_rgb,tolerance", "Change the key colour while enabled.");
  REG_API(AUBG_BlendColor, "int", "int,int,int", "bg_rgb,overlay_rgb,drawmode",
          "Blend overlay_rgb over bg_rgb exactly as REAPER draws a theme element with the given *_drawmode/*_mode value "
          "(LICE mode in the low byte, alpha*256 in the next). Returns 0xRRGGBB, or -1 if unavailable.");
  REG_API(AUBG_ProbeDuration, "double", "const char*", "path", "Duration of a video file in seconds (0 if unreadable).");
  REG_API(AUBG_Frame, "int", "const char*,const char*,double,int,int", "path,out_jpg,time,max_w,max_h",
          "Write the frame at time (seconds; <0 = middle) of a video, or a still image, to out_jpg, scaled to fit max_w x max_h. Returns 1 on success.");
  REG_API(AUBG_IsImage, "int", "const char*", "path", "1 if the file is a still image ImageIO can decode.");
  REG_API(AUBG_ImportImage, "const char*", "const char*,const char*", "src,dst_base",
          "Copy an image into the library as dst_base.png (if it has alpha) or dst_base.jpg, upright and at most 3840 px per side. "
          "Returns the extension written, or \"\" if src is not an image.");
  REG_API(AUBG_TranscodeStart, "int", "const char*,const char*,double,double", "src,dst,in_sec,out_sec",
          "Start transcoding src to dst (1280x720 H.264 mp4) in the background, optionally trimmed to [in_sec,out_sec] "
          "(out_sec <= 0 = end). Returns 1, or -1 bad input, -2 already running, -3 dst exists, -4 unsupported source.");
  REG_API(AUBG_TranscodeStatus, "int", "", "", "0 idle, 1 running, 2 done, -1 failed (see AUBG_TranscodeError).");
  REG_API(AUBG_TranscodeProgress, "double", "", "", "Transcode progress 0..1.");
  REG_API(AUBG_TranscodeError, "const char*", "", "", "Error message of the last failed transcode.");
  REG_API(AUBG_TranscodeCancel, "void", "", "", "Cancel the running transcode; the partial file is deleted.");
  REG_API(AUBG_SetScript, "void", "int", "cmd_id",
          "Called by ReaBackground.lua with its command id while running (0 on exit), so re-running the action or "
          "choosing Extensions > ReaBackground shows its window instead of relaunching it.");
  REG_API(AUBG_SetRate, "void", "double", "rate", "Playback rate used while REAPER plays (project play rate).");
  REG_API(AUBG_SetOpacity, "void", "double", "opacity", "Video opacity (0..1) over the track background colour; changed live.");
  REG_API(AUBG_SetPan, "void", "double,double", "x,y",
          "Which part of the aspect-fill-cropped video shows, -1..1 per axis (0 centred, -1/1 the left/top or right/bottom edge); changed live.");
  REG_API(AUBG_AltDown, "int", "", "", "Debug: 1 while the Option key is held, whichever window has focus.");
  REG_API(AUBG_ViewSize, "const char*", "", "", "Size in points of the arrange area the video fills, as \"w,h\" (\"\" while disabled).");
  REG_API(AUBG_PickFile, "int", "const char*", "message", "Open a non-blocking video/image file chooser. Returns 1 if opened, 0 if one is already open.");
  REG_API(AUBG_PickState, "int", "", "", "File chooser state: 0 idle, 1 open, 2 chosen (see AUBG_PickedPath), -1 cancelled. 2 and -1 are reported once.");
  REG_API(AUBG_PickedPath, "const char*", "", "", "Path chosen in the last completed AUBG_PickFile.");
  REG_API(AUBG_Stats, "const char*", "", "", "Diagnostics: drift_ms|seeks|player_rate|lead_ms|key_ms|mode|paints|seek_pending|seek_timeouts|keyed_px.");
  REG_API(AUBG_Probe, "const char*", "", "", "Debug: texture pixels (AARRGGBB*count) under the mouse when it is over the arrange, after keying.");
  REG_API(AUBG_GetDuration, "double", "", "", "Video duration in seconds (0 until loaded).");
  return 1;
}
