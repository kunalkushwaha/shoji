// The Linux engine: WPE WebKit (WPEPlatform, headless display) behind a small C API.
// Swift's BrowserWPE.swift is the only caller; GObject, GLib and GVariant details
// stay in shoji_wpe.c. Everything runs on the main thread, in GLib's main loop.
#pragma once
#ifdef __linux__
#include <stdint.h>

typedef struct ShojiEngine ShojiEngine;

/// What the engine reports back. `ctx` is the Swift Browser.
typedef struct {
  void *ctx;
  /// title, uri or loading changed
  void (*status)(void *ctx);
  /// a new page committed (its address)
  void (*committed)(void *ctx, const char *uri);
  void (*finished)(void *ctx);
  /// a load failed; provisional = before anything of the page was shown
  void (*failed)(void *ctx, const char *uri, const char *error, int provisional);
  /// the main document's HTTP response
  void (*response)(void *ctx, const char *uri, int status);
  /// a script message from the page: name and its body as JSON
  void (*message)(void *ctx, const char *name, const char *json);
  /// alert/confirm/prompt (type 0/1/2). Return 1 to accept; for a prompt, set *answer
  /// to a malloc'd string (or leave NULL for the default text).
  int (*dialog)(void *ctx, int type, const char *message, const char *default_text, char **answer);
} ShojiCallbacks;

/// A compiled content filter (the offline rules), or NULL.
typedef void ShojiFilter;
typedef void (*shoji_filter_cb)(void *ctx, ShojiFilter *filter, const char *error);
/// Compile Safari content-blocker JSON (asynchronous; the store lives in a temp dir).
void shoji_compile_filter(const char *identifier, const char *rules_json, shoji_filter_cb cb, void *ctx);

ShojiEngine *shoji_engine_new(int width, int height, ShojiFilter *filter, const char *user_agent,
                              const char *page_script, const char *helper_script, const char *helper_world,
                              const char *const *message_names, int n_message_names, ShojiCallbacks callbacks);

void shoji_engine_load_uri(ShojiEngine *e, const char *uri);
void shoji_engine_go_back(ShojiEngine *e);
void shoji_engine_go_forward(ShojiEngine *e);
void shoji_engine_reload(ShojiEngine *e);
void shoji_engine_stop(ShojiEngine *e);
/// The current state; the strings belong to the engine (valid until the next change).
const char *shoji_engine_uri(ShojiEngine *e);
const char *shoji_engine_title(ShojiEngine *e);
int shoji_engine_is_loading(ShojiEngine *e);
int shoji_engine_can_go_back(ShojiEngine *e);
int shoji_engine_can_go_forward(ShojiEngine *e);
int shoji_engine_width(ShojiEngine *e);
int shoji_engine_height(ShojiEngine *e);
void shoji_engine_resize(ShojiEngine *e, int width, int height);

/// Run an async function body (awaits promises). world NULL = the page's own.
/// The result comes back as JSON (NULL for undefined), or an error message.
typedef void (*shoji_result_cb)(void *ctx, const char *json, const char *error);
void shoji_engine_eval(ShojiEngine *e, const char *body, const char *world, shoji_result_cb cb, void *ctx);

/// Input. Coordinates are CSS pixels from the view's top-left.
/// kind: 0 press, 1 release, 2 move (button 1 held: drag)
void shoji_engine_mouse(ShojiEngine *e, int kind, double x, double y, int press_count, int button_held);
/// Scroll by CSS pixels (positive = down) at x, y.
void shoji_engine_scroll(ShojiEngine *e, double dx, double dy, double x, double y);
/// A key press + release. keyval: an X keysym (0xff0d Return, … or a Unicode keysym).
void shoji_engine_key(ShojiEngine *e, unsigned keyval);
/// Text as typed: one key press per character.
void shoji_engine_type_text(ShojiEngine *e, const char *utf8);

/// Pixels of the view (visible) or the whole document (full), as premultiplied BGRA.
typedef void (*shoji_pixels_cb)(void *ctx, const uint8_t *bgra, int width, int height, int stride, const char *error);
void shoji_engine_snapshot(ShojiEngine *e, int full, shoji_pixels_cb cb, void *ctx);
/// Write premultiplied BGRA as a PNG, scaled to out_w x out_h (bilinear). Returns 1 on success.
int shoji_write_png(const char *path, const uint8_t *bgra, int width, int height, int stride, int out_w, int out_h);

/// GLib's main loop, also draining Dispatch's main queue (so DispatchQueue.main,
/// asyncAfter and DispatchSources on .main work unchanged).
void shoji_loop_run(void);
void shoji_loop_quit(void);

/// Terminal size (ioctl is variadic, so Swift can't call it directly).
int shoji_winsize(int fd, int *rows, int *cols, int *xpixel, int *ypixel);

#endif
