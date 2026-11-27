#include "shoji_wpe.h"
#include <wpe/webkit.h>
#include <wpe/wpe-platform.h>
#include <wpe/headless/wpe-headless.h>

struct ShojiEngine {
  WebKitWebView *web;
  shoji_void_cb loaded_cb; void *loaded_ctx;
};
static GMainLoop *loop;

static void on_load(WebKitWebView *v, WebKitLoadEvent ev, gpointer d) {
  ShojiEngine *e = d;
  if (ev == WEBKIT_LOAD_FINISHED && e->loaded_cb) e->loaded_cb(e->loaded_ctx);
}

ShojiEngine *shoji_engine_new(int width, int height, const char *helper, const char *world) {
  GError *err = NULL;
  WPEDisplay *display = wpe_display_headless_new();
  if (!wpe_display_connect(display, &err)) { g_printerr("headless display: %s\n", err->message); return NULL; }
  WebKitUserContentManager *ucm = webkit_user_content_manager_new();
  if (helper) webkit_user_content_manager_add_script(ucm, webkit_user_script_new_for_world(helper,
      WEBKIT_USER_CONTENT_INJECT_TOP_FRAME, WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, world, NULL, NULL));
  ShojiEngine *e = g_new0(ShojiEngine, 1);
  e->web = g_object_new(WEBKIT_TYPE_WEB_VIEW, "display", display,
                        "network-session", webkit_network_session_new_ephemeral(), "user-content-manager", ucm, NULL);
  WPEToplevel *top = wpe_view_get_toplevel(webkit_web_view_get_wpe_view(e->web));
  if (top) wpe_toplevel_resize(top, width, height);
  g_signal_connect(e->web, "load-changed", G_CALLBACK(on_load), e);
  return e;
}

void shoji_engine_on_loaded(ShojiEngine *e, shoji_void_cb cb, void *ctx) { e->loaded_cb = cb; e->loaded_ctx = ctx; }
void shoji_engine_load_html(ShojiEngine *e, const char *html, const char *base) { webkit_web_view_load_html(e->web, html, base); }

typedef struct { ShojiEngine *e; shoji_result_cb cb; void *ctx; } EvalReq;
static void eval_done(GObject *o, GAsyncResult *r, gpointer d) {
  EvalReq *q = d; GError *err = NULL;
  JSCValue *v = webkit_web_view_call_async_javascript_function_finish(q->e->web, r, &err);
  char *json = v ? jsc_value_to_json(v, 0) : NULL;
  q->cb(q->ctx, json, err ? err->message : NULL);
  g_free(json); if (err) g_error_free(err); if (v) g_object_unref(v); g_free(q);
}
void shoji_engine_eval(ShojiEngine *e, const char *body, const char *world, shoji_result_cb cb, void *ctx) {
  EvalReq *q = g_new(EvalReq, 1); *q = (EvalReq){ e, cb, ctx };
  webkit_web_view_call_async_javascript_function(e->web, body, -1, NULL, world, NULL, NULL, eval_done, q);
}

void shoji_engine_click(ShojiEngine *e, double x, double y) {
  WPEView *view = webkit_web_view_get_wpe_view(e->web);
  guint32 t = (guint32)(g_get_monotonic_time() / 1000);
  WPEEvent *ev = wpe_event_pointer_button_new(WPE_EVENT_POINTER_DOWN, view, WPE_INPUT_SOURCE_MOUSE, t, 0, 1, x, y, 1);
  wpe_view_event(view, ev); wpe_event_unref(ev);
  ev = wpe_event_pointer_button_new(WPE_EVENT_POINTER_UP, view, WPE_INPUT_SOURCE_MOUSE, t + 30, 0, 1, x, y, 0);
  wpe_view_event(view, ev); wpe_event_unref(ev);
}

typedef struct { shoji_void_cb cb; void *ctx; } After;
static gboolean after_fire(gpointer d) { After *a = d; a->cb(a->ctx); g_free(a); return G_SOURCE_REMOVE; }
void shoji_loop_after(unsigned ms, shoji_void_cb cb, void *ctx) {
  After *a = g_new(After, 1); *a = (After){ cb, ctx }; g_timeout_add(ms, after_fire, a);
}
void shoji_loop_run(void) { if (!loop) loop = g_main_loop_new(NULL, FALSE); g_main_loop_run(loop); }
void shoji_loop_quit(void) { if (loop) g_main_loop_quit(loop); }
