// The Linux engine: WPE WebKit 2.54+ with WPEPlatform's headless display.
// See include/shoji_wpe.h for the API and docs/linux.md for why it's shaped this way.
#ifdef __linux__
#include "shoji_wpe.h"
#include <wpe/webkit.h>
#include <wpe/wpe-platform.h>
#include <wpe/headless/wpe-headless.h>
#include <glib-unix.h>
#include <png.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <zlib.h>

struct ShojiEngine {
  WebKitWebView *web;
  WPEView *view;
  WPEDisplay *display;
  ShojiCallbacks cb;
  int width, height;
  double scale;
  guint32 last_time;
};

static guint32 event_time(ShojiEngine *e) {
  guint32 t = (guint32)(g_get_monotonic_time() / 1000);
  if (t <= e->last_time) t = e->last_time + 1;     // strictly increasing, so press counts work
  return e->last_time = t;
}

// ---- content filter (offline rules) ----

typedef struct { shoji_filter_cb cb; void *ctx; } FilterReq;

static void filter_saved(GObject *store, GAsyncResult *r, gpointer d) {
  FilterReq *q = d;
  GError *err = NULL;
  WebKitUserContentFilter *f = webkit_user_content_filter_store_save_finish(WEBKIT_USER_CONTENT_FILTER_STORE(store), r, &err);
  q->cb(q->ctx, f, err ? err->message : NULL);
  if (err) g_error_free(err);
  g_object_unref(store);
  g_free(q);
}

void shoji_compile_filter(const char *identifier, const char *rules_json, shoji_filter_cb cb, void *ctx) {
  char *dir = g_build_filename(g_get_tmp_dir(), "shoji-filters", NULL);
  WebKitUserContentFilterStore *store = webkit_user_content_filter_store_new(dir);
  g_free(dir);
  FilterReq *q = g_new(FilterReq, 1);
  *q = (FilterReq){ cb, ctx };
  GBytes *src = g_bytes_new(rules_json, strlen(rules_json));
  webkit_user_content_filter_store_save(store, identifier, src, NULL, filter_saved, q);
  g_bytes_unref(src);
}

// ---- signals ----

static void on_notify(GObject *o, GParamSpec *p, gpointer d) {
  ShojiEngine *e = d;
  if (e->cb.status) e->cb.status(e->cb.ctx);
}

static void on_load_changed(WebKitWebView *v, WebKitLoadEvent ev, gpointer d) {
  ShojiEngine *e = d;
  if (ev == WEBKIT_LOAD_COMMITTED && e->cb.committed) e->cb.committed(e->cb.ctx, webkit_web_view_get_uri(v));
  if (ev == WEBKIT_LOAD_FINISHED && e->cb.finished) e->cb.finished(e->cb.ctx);
}

static gboolean on_load_failed(WebKitWebView *v, WebKitLoadEvent ev, char *uri, GError *err, gpointer d) {
  ShojiEngine *e = d;
  // a navigation replaced by another one isn't an error worth reporting
  if (g_error_matches(err, WEBKIT_NETWORK_ERROR, WEBKIT_NETWORK_ERROR_CANCELLED)) return FALSE;
  if (e->cb.failed) e->cb.failed(e->cb.ctx, uri, err->message, ev == WEBKIT_LOAD_STARTED);
  return FALSE;
}

static gboolean on_decide_policy(WebKitWebView *v, WebKitPolicyDecision *dec, WebKitPolicyDecisionType type, gpointer d) {
  ShojiEngine *e = d;
  if (type != WEBKIT_POLICY_DECISION_TYPE_RESPONSE) return FALSE;     // default handling
  WebKitResponsePolicyDecision *rd = WEBKIT_RESPONSE_POLICY_DECISION(dec);
  if (webkit_response_policy_decision_is_main_frame_main_resource(rd) && e->cb.response) {
    WebKitURIResponse *res = webkit_response_policy_decision_get_response(rd);
    e->cb.response(e->cb.ctx, webkit_uri_response_get_uri(res), (int) webkit_uri_response_get_status_code(res));
  }
  return FALSE;
}

typedef struct { ShojiEngine *e; char *name; } MsgHandler;
static void on_named_message(WebKitUserContentManager *m, JSCValue *v, gpointer d) {
  MsgHandler *h = d;
  if (!h->e->cb.message) return;
  char *json = jsc_value_to_json(v, 0);
  h->e->cb.message(h->e->cb.ctx, h->name, json ? json : "null");
  g_free(json);
}

static gboolean on_script_dialog(WebKitWebView *v, WebKitScriptDialog *dialog, gpointer d) {
  ShojiEngine *e = d;
  WebKitScriptDialogType t = webkit_script_dialog_get_dialog_type(dialog);
  int type = t == WEBKIT_SCRIPT_DIALOG_ALERT ? 0 : t == WEBKIT_SCRIPT_DIALOG_CONFIRM ? 1
           : t == WEBKIT_SCRIPT_DIALOG_PROMPT ? 2 : 3;
  if (type == 3) { webkit_script_dialog_confirm_set_confirmed(dialog, TRUE); return TRUE; }   // before-unload: leave
  const char *def = type == 2 ? webkit_script_dialog_prompt_get_default_text(dialog) : NULL;
  char *answer = NULL;
  int accept = e->cb.dialog ? e->cb.dialog(e->cb.ctx, type, webkit_script_dialog_get_message(dialog), def, &answer) : 1;
  if (type == 1) webkit_script_dialog_confirm_set_confirmed(dialog, accept);
  if (type == 2) {
    // a prompt that's dismissed returns null to the page
    if (accept) webkit_script_dialog_prompt_set_text(dialog, answer ? answer : (def ? def : ""));
    else webkit_script_dialog_close(dialog);
  }
  free(answer);
  return TRUE;
}

/// target=_blank and window.open: load here instead of opening a window.
static WebKitWebView *on_create(WebKitWebView *v, WebKitNavigationAction *action, gpointer d) {
  WebKitURIRequest *req = webkit_navigation_action_get_request(action);
  if (req && webkit_uri_request_get_uri(req)) webkit_web_view_load_uri(v, webkit_uri_request_get_uri(req));
  return NULL;
}

// ---- the view ----

ShojiEngine *shoji_engine_new(int width, int height, ShojiFilter *filter, const char *user_agent,
                              const char *page_script, const char *helper_script, const char *helper_world,
                              const char *const *names, int n_names, ShojiCallbacks callbacks) {
  GError *err = NULL;
  ShojiEngine *e = g_new0(ShojiEngine, 1);
  e->cb = callbacks;
  e->scale = 1;
  e->display = wpe_display_headless_new();
  if (!wpe_display_connect(e->display, &err)) {
    g_printerr("shoji: headless display: %s\n", err->message);
    g_error_free(err);
    g_free(e);
    return NULL;
  }

  WebKitUserContentManager *ucm = webkit_user_content_manager_new();
  if (page_script)
    webkit_user_content_manager_add_script(ucm, webkit_user_script_new(page_script,
        WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES, WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, NULL, NULL));
  if (helper_script)
    webkit_user_content_manager_add_script(ucm, webkit_user_script_new_for_world(helper_script,
        WEBKIT_USER_CONTENT_INJECT_TOP_FRAME, WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, helper_world, NULL, NULL));
  for (int i = 0; i < n_names; i++) {
    MsgHandler *h = g_new(MsgHandler, 1);
    *h = (MsgHandler){ e, g_strdup(names[i]) };
    webkit_user_content_manager_register_script_message_handler(ucm, names[i], NULL);
    char *sig = g_strdup_printf("script-message-received::%s", names[i]);
    g_signal_connect(ucm, sig, G_CALLBACK(on_named_message), h);
    g_free(sig);
  }
  if (filter) webkit_user_content_manager_add_filter(ucm, (WebKitUserContentFilter *) filter);

  WebKitSettings *settings = webkit_settings_new();
  if (user_agent) webkit_settings_set_user_agent(settings, user_agent);
  webkit_settings_set_allow_file_access_from_file_urls(settings, TRUE);
  webkit_settings_set_javascript_can_open_windows_automatically(settings, TRUE);
  webkit_settings_set_enable_developer_extras(settings, FALSE);

  // private by default: nothing is written to disk
  WebKitNetworkSession *session = webkit_network_session_new_ephemeral();

  e->web = g_object_new(WEBKIT_TYPE_WEB_VIEW, "display", e->display, "network-session", session,
                        "user-content-manager", ucm, "settings", settings, NULL);
  g_object_unref(session);
  g_object_unref(ucm);
  g_object_unref(settings);
  e->view = webkit_web_view_get_wpe_view(e->web);
  shoji_engine_resize(e, width, height);
  wpe_view_focus_in(e->view);

  g_signal_connect(e->web, "notify::title", G_CALLBACK(on_notify), e);
  g_signal_connect(e->web, "notify::uri", G_CALLBACK(on_notify), e);
  g_signal_connect(e->web, "notify::is-loading", G_CALLBACK(on_notify), e);
  g_signal_connect(e->web, "load-changed", G_CALLBACK(on_load_changed), e);
  g_signal_connect(e->web, "load-failed", G_CALLBACK(on_load_failed), e);
  g_signal_connect(e->web, "decide-policy", G_CALLBACK(on_decide_policy), e);
  g_signal_connect(e->web, "script-dialog", G_CALLBACK(on_script_dialog), e);
  g_signal_connect(e->web, "create", G_CALLBACK(on_create), e);
  return e;
}

void shoji_engine_load_uri(ShojiEngine *e, const char *uri) { webkit_web_view_load_uri(e->web, uri); }
void shoji_engine_go_back(ShojiEngine *e) { webkit_web_view_go_back(e->web); }
void shoji_engine_go_forward(ShojiEngine *e) { webkit_web_view_go_forward(e->web); }
void shoji_engine_reload(ShojiEngine *e) { webkit_web_view_reload(e->web); }
void shoji_engine_stop(ShojiEngine *e) { webkit_web_view_stop_loading(e->web); }
const char *shoji_engine_uri(ShojiEngine *e) { return webkit_web_view_get_uri(e->web); }
const char *shoji_engine_title(ShojiEngine *e) { return webkit_web_view_get_title(e->web); }
int shoji_engine_is_loading(ShojiEngine *e) { return webkit_web_view_is_loading(e->web); }
int shoji_engine_can_go_back(ShojiEngine *e) { return webkit_web_view_can_go_back(e->web); }
int shoji_engine_can_go_forward(ShojiEngine *e) { return webkit_web_view_can_go_forward(e->web); }
int shoji_engine_width(ShojiEngine *e) { return e->width; }
int shoji_engine_height(ShojiEngine *e) { return e->height; }

void shoji_engine_resize(ShojiEngine *e, int width, int height) {
  e->width = width < 100 ? 100 : width;
  e->height = height < 100 ? 100 : height;
  WPEToplevel *top = wpe_view_get_toplevel(e->view);
  if (top) wpe_toplevel_resize(top, e->width, e->height);
  else wpe_view_resized(e->view, e->width, e->height);
}

void shoji_engine_set_scale(ShojiEngine *e, double scale) {
  e->scale = scale > 0 ? scale : 1;
  webkit_web_view_set_zoom_level(e->web, e->scale);
}

// ---- JavaScript ----

typedef struct { ShojiEngine *e; shoji_result_cb cb; void *ctx; } EvalReq;

static void eval_done(GObject *o, GAsyncResult *r, gpointer d) {
  EvalReq *q = d;
  GError *err = NULL;
  JSCValue *v = webkit_web_view_call_async_javascript_function_finish(q->e->web, r, &err);
  char *json = NULL;
  if (v && !jsc_value_is_undefined(v)) json = jsc_value_to_json(v, 0);
  q->cb(q->ctx, json, err ? err->message : NULL);
  g_free(json);
  if (err) g_error_free(err);
  if (v) g_object_unref(v);
  g_free(q);
}

void shoji_engine_eval(ShojiEngine *e, const char *body, const char *world, shoji_result_cb cb, void *ctx) {
  EvalReq *q = g_new(EvalReq, 1);
  *q = (EvalReq){ e, cb, ctx };
  webkit_web_view_call_async_javascript_function(e->web, body, -1, NULL, world, NULL, NULL, eval_done, q);
}

// ---- input ----

static void send(ShojiEngine *e, WPEEvent *ev) {
  if (!ev) return;
  wpe_view_event(e->view, ev);
  wpe_event_unref(ev);
}

void shoji_engine_mouse(ShojiEngine *e, int kind, double x, double y, int press_count, int held) {
  guint32 t = event_time(e);
  x *= e->scale; y *= e->scale;
  WPEModifiers held_mod = held ? WPE_MODIFIER_POINTER_BUTTON1 : 0;
  switch (kind) {
  case 0:
    send(e, wpe_event_pointer_move_new(WPE_EVENT_POINTER_MOVE, e->view, WPE_INPUT_SOURCE_MOUSE, t, 0, x, y, 0, 0));
    send(e, wpe_event_pointer_button_new(WPE_EVENT_POINTER_DOWN, e->view, WPE_INPUT_SOURCE_MOUSE, t, 0, WPE_BUTTON_PRIMARY,
                                         x, y, press_count < 1 ? 1 : press_count));
    break;
  case 1:   // a release carries no press count (WPE asserts)
    send(e, wpe_event_pointer_button_new(WPE_EVENT_POINTER_UP, e->view, WPE_INPUT_SOURCE_MOUSE, t, WPE_MODIFIER_POINTER_BUTTON1,
                                         WPE_BUTTON_PRIMARY, x, y, 0));
    break;
  default:
    send(e, wpe_event_pointer_move_new(WPE_EVENT_POINTER_MOVE, e->view, WPE_INPUT_SOURCE_MOUSE, t, held_mod, x, y, 0, 0));
  }
}

void shoji_engine_scroll(ShojiEngine *e, double dx, double dy, double x, double y) {
  guint32 t = event_time(e);
  x *= e->scale; y *= e->scale;
  dx *= e->scale; dy *= e->scale;      // deltas are in view (device) pixels, like the position
  send(e, wpe_event_pointer_move_new(WPE_EVENT_POINTER_MOVE, e->view, WPE_INPUT_SOURCE_MOUSE, t, 0, x, y, 0, 0));
  // Measured on WPE 2.54 (headless): a precise scroll event moves the page 2.5 device px per
  // unit of delta, opposite in sign (negative = down). No "scroll stop" event after it:
  // WPE treats that as the end of a swipe and adds momentum, flinging the page.
  const double px_per_unit = 2.5;
  send(e, wpe_event_scroll_new(e->view, WPE_INPUT_SOURCE_MOUSE, t, 0, -dx / px_per_unit, -dy / px_per_unit, TRUE, FALSE, x, y));
}

void shoji_engine_key(ShojiEngine *e, unsigned keyval) {
  WPEKeymap *keymap = wpe_display_get_keymap(e->display);
  WPEKeymapEntry *entries = NULL;
  guint n = 0;
  guint keycode = 0;
  WPEModifiers mods = 0;
  if (keymap && wpe_keymap_get_entries_for_keyval(keymap, keyval, &entries, &n) && n > 0) {
    keycode = entries[0].keycode;
    if (entries[0].level == 1) mods = WPE_MODIFIER_KEYBOARD_SHIFT;
  }
  g_free(entries);
  guint32 t = event_time(e);
  send(e, wpe_event_keyboard_new(WPE_EVENT_KEYBOARD_KEY_DOWN, e->view, WPE_INPUT_SOURCE_KEYBOARD, t, mods, keycode, keyval));
  send(e, wpe_event_keyboard_new(WPE_EVENT_KEYBOARD_KEY_UP, e->view, WPE_INPUT_SOURCE_KEYBOARD, event_time(e), mods, keycode, keyval));
}

/// Unicode to X keysym: Latin-1 maps to itself, everything else to 0x01000000 + code point.
static unsigned keysym_for(gunichar c) {
  if (c == '\n' || c == '\r') return 0xff0d;
  if (c == '\t') return 0xff09;
  if ((c >= 0x20 && c <= 0x7e) || (c >= 0xa0 && c <= 0xff)) return c;
  return 0x01000000 | c;
}

void shoji_engine_type_text(ShojiEngine *e, const char *utf8) {
  for (const char *p = utf8; p && *p; p = g_utf8_next_char(p)) shoji_engine_key(e, keysym_for(g_utf8_get_char(p)));
}

// ---- pixels ----

typedef struct { ShojiEngine *e; shoji_pixels_cb cb; void *ctx; } SnapReq;

static void snapshot_done(GObject *o, GAsyncResult *r, gpointer d) {
  SnapReq *q = d;
  GError *err = NULL;
  WebKitImage *img = webkit_web_view_get_snapshot_finish(q->e->web, r, &err);
  if (!img) {
    q->cb(q->ctx, NULL, 0, 0, 0, err ? err->message : "snapshot failed");
  } else {
    GBytes *bytes = webkit_image_as_bytes(img);
    gsize n;
    const guint8 *px = g_bytes_get_data(bytes, &n);
    q->cb(q->ctx, px, webkit_image_get_width(img), webkit_image_get_height(img), (int) webkit_image_get_stride(img), NULL);
    g_object_unref(img);
  }
  if (err) g_error_free(err);
  g_free(q);
}

void shoji_engine_snapshot(ShojiEngine *e, int full, shoji_pixels_cb cb, void *ctx) {
  SnapReq *q = g_new(SnapReq, 1);
  *q = (SnapReq){ e, cb, ctx };
  webkit_web_view_get_snapshot(e->web, full ? WEBKIT_SNAPSHOT_REGION_FULL_DOCUMENT : WEBKIT_SNAPSHOT_REGION_VISIBLE,
                               WEBKIT_SNAPSHOT_OPTIONS_NONE, NULL, snapshot_done, q);
}

/// One RGBA pixel of premultiplied BGRA at (x, y), un-premultiplied.
static inline void px_at(const uint8_t *bgra, int stride, int x, int y, double out[4]) {
  const uint8_t *s = bgra + (size_t) y * stride + (size_t) x * 4;
  double a = s[3];
  if (a == 0) { out[0] = out[1] = out[2] = out[3] = 0; return; }
  out[0] = s[2] * 255.0 / a; out[1] = s[1] * 255.0 / a; out[2] = s[0] * 255.0 / a; out[3] = a;
}

int shoji_write_png(const char *path, const uint8_t *bgra, int w, int h, int stride, int ow, int oh) {
  if (ow <= 0 || oh <= 0) { ow = w; oh = h; }
  FILE *f = fopen(path, "wb");
  if (!f) return 0;
  png_structp p = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
  png_infop info = png_create_info_struct(p);
  uint8_t *row = malloc((size_t) ow * 4);
  if (setjmp(png_jmpbuf(p))) { free(row); png_destroy_write_struct(&p, &info); fclose(f); return 0; }
  png_init_io(p, f);
  png_set_IHDR(p, info, ow, oh, 8, PNG_COLOR_TYPE_RGBA, PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);
  png_write_info(p, info);
  for (int y = 0; y < oh; y++) {
    for (int x = 0; x < ow; x++) {
      double c[4];
      if (ow == w && oh == h) {
        px_at(bgra, stride, x, y, c);
      } else {   // bilinear
        double sx = (x + 0.5) * w / ow - 0.5, sy = (y + 0.5) * h / oh - 0.5;
        int x0 = sx < 0 ? 0 : (int) sx, y0 = sy < 0 ? 0 : (int) sy;
        int x1 = x0 + 1 < w ? x0 + 1 : x0, y1 = y0 + 1 < h ? y0 + 1 : y0;
        double fx = sx - x0, fy = sy - y0;
        if (fx < 0) fx = 0;
        if (fy < 0) fy = 0;
        double a[4], b[4], cc[4], d[4];
        px_at(bgra, stride, x0, y0, a); px_at(bgra, stride, x1, y0, b);
        px_at(bgra, stride, x0, y1, cc); px_at(bgra, stride, x1, y1, d);
        for (int k = 0; k < 4; k++) c[k] = (a[k] * (1 - fx) + b[k] * fx) * (1 - fy) + (cc[k] * (1 - fx) + d[k] * fx) * fy;
      }
      for (int k = 0; k < 4; k++) row[x * 4 + k] = (uint8_t) (c[k] > 255 ? 255 : c[k] < 0 ? 0 : c[k] + 0.5);
    }
    png_write_row(p, row);
  }
  png_write_end(p, NULL);
  png_destroy_write_struct(&p, &info);
  free(row);
  fclose(f);
  return 1;
}

// ---- main loop ----

// libdispatch exposes its main queue as an eventfd; CoreFoundation's run loop drains
// it the same way on Linux. With this, DispatchQueue.main runs inside GLib's loop.
extern int _dispatch_get_main_queue_handle_4CF(void);
extern void _dispatch_main_queue_callback_4CF(void *msg);

static GMainLoop *main_loop;

static gboolean drain_dispatch(gint fd, GIOCondition c, gpointer d) {
  _dispatch_main_queue_callback_4CF(NULL);
  return G_SOURCE_CONTINUE;
}

void shoji_loop_run(void) {
  main_loop = g_main_loop_new(NULL, FALSE);
  g_unix_fd_add(_dispatch_get_main_queue_handle_4CF(), G_IO_IN, drain_dispatch, NULL);
  _dispatch_main_queue_callback_4CF(NULL);
  g_main_loop_run(main_loop);
}

void shoji_loop_quit(void) { if (main_loop) g_main_loop_quit(main_loop); }

int shoji_zlib(const uint8_t *src, size_t n, uint8_t **out, size_t *out_n) {
  uLongf len = compressBound(n);
  *out = malloc(len);
  if (!*out) return -1;
  if (compress2(*out, &len, src, n, 1) != Z_OK) { free(*out); *out = NULL; return -1; }
  *out_n = len;
  return 0;
}

int shoji_winsize(int fd, int *rows, int *cols, int *xpixel, int *ypixel) {
  struct winsize ws;
  if (ioctl(fd, TIOCGWINSZ, &ws) != 0) return -1;
  *rows = ws.ws_row; *cols = ws.ws_col; *xpixel = ws.ws_xpixel; *ypixel = ws.ws_ypixel;
  return 0;
}

#endif
