// Milestone 1 for the Linux port: prove WPE WebKit (2.54, WPEPlatform headless) can do
// what shoji's agent mode needs. Checks, in order:
//   1. user scripts in the page world and an isolated world ("shoji"), a script
//      message back to C, and a value returned by call_async_javascript_function
//   2. requestAnimationFrame rate on a headless view (is it throttled?), and a
//      snapshot written as PNG
//   3. a synthetic click through wpe_view_event changes the page
//
//   cc engine_spike.c $(pkg-config --cflags --libs wpe-webkit-2.0 wpe-platform-headless-2.0 libpng) -o engine_spike
//   ./engine_spike out.png
#include <wpe/webkit.h>
#include <wpe/wpe-platform.h>
#include <wpe/headless/wpe-headless.h>
#include <png.h>
#include <stdio.h>
#include <string.h>

static GMainLoop *loop;
static WebKitWebView *web;
static const char *png_path;
static int failures;
static gint64 t0;

#define W 1024
#define H 640

static void check(gboolean ok, const char *what) {
  printf("%s %s\n", ok ? "PASS" : "FAIL", what);
  if (!ok) failures++;
}

static double now_ms(void) { return (g_get_monotonic_time() - t0) / 1000.0; }

static const char *page =
  "<!doctype html><html><body style='margin:0;font:20px sans-serif;background:#f3f0e8'>"
  "<h1 id=title style='margin:20px'>shoji on WPE</h1>"
  "<button id=btn style='position:absolute;left:40px;top:120px;width:200px;height:60px;font-size:20px'"
  " onclick=\"this.textContent='clicked'; document.getElementById('msg').textContent='button was clicked (trusted=' + event.isTrusted + ')'\">Click me</button>"
  "<p id=msg style='position:absolute;left:40px;top:200px'>not clicked</p>"
  "<div id=box style='position:absolute;left:300px;top:120px;width:80px;height:80px;background:#c0392b'></div>"
  "<script>"
  "  window.rafCount = 0; (function f(){ window.rafCount++; "
  "    document.getElementById('box').style.transform='rotate('+(window.rafCount*3)+'deg)'; requestAnimationFrame(f); })();"
  "  setTimeout(function(){ console.log('timer ran'); }, 10);"
  "</script></body></html>";

// page world: reports itself through a script message (like shojiLog on macOS)
static const char *page_world_script =
  "window.webkit.messageHandlers.shojiLog.postMessage({k:'console', text:'page-world script ran', url: location.href});";

// isolated world: defines a helper the page can't see (like shoji's snapshot helper)
static const char *helper_script =
  "window.__shoji = { outline: function(){ return { title: document.title || document.querySelector('h1').textContent,"
  " buttons: Array.from(document.querySelectorAll('button')).map(function(b){ return b.textContent; }),"
  " pageSeesHelper: false }; } };";

static void on_message(WebKitUserContentManager *m, JSCValue *v, gpointer data) {
  char *json = jsc_value_to_json(v, 0);
  printf("  message shojiLog: %s (%.0f ms)\n", json, now_ms());
  check(json && strstr(json, "page-world script ran") != NULL, "page-world user script posts a script message");
  g_free(json);
}

// ---- PNG ----
static gboolean write_png(const char *path, const guint8 *bgra, int w, int h, int stride) {
  FILE *f = fopen(path, "wb");
  if (!f) return FALSE;
  png_structp p = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
  png_infop info = png_create_info_struct(p);
  if (setjmp(png_jmpbuf(p))) { fclose(f); return FALSE; }
  png_init_io(p, f);
  png_set_IHDR(p, info, w, h, 8, PNG_COLOR_TYPE_RGBA, PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);
  png_write_info(p, info);
  guint8 *row = g_malloc(w * 4);
  for (int y = 0; y < h; y++) {
    const guint8 *s = bgra + y * stride;
    for (int x = 0; x < w; x++) {          // premultiplied BGRA (cairo ARGB32, little endian) -> RGBA
      guint8 b = s[4*x], g = s[4*x+1], r = s[4*x+2], a = s[4*x+3];
      row[4*x] = r; row[4*x+1] = g; row[4*x+2] = b; row[4*x+3] = a;
    }
    png_write_row(p, row);
  }
  png_write_end(p, NULL);
  png_destroy_write_struct(&p, &info);
  g_free(row);
  fclose(f);
  return TRUE;
}

// ---- steps ----
static void step_click(void);
static void step_after_click(void);

static void eval_world(const char *body, const char *world, GAsyncReadyCallback cb) {
  webkit_web_view_call_async_javascript_function(web, body, -1, NULL, world, NULL, NULL, cb, NULL);
}

static JSCValue *finish(GAsyncResult *r, char **err) {
  GError *e = NULL;
  JSCValue *v = webkit_web_view_call_async_javascript_function_finish(web, r, &e);
  if (e) { *err = g_strdup(e->message); g_error_free(e); }
  return v;
}

static void on_snapshot(GObject *o, GAsyncResult *r, gpointer d) {
  GError *e = NULL;
  WebKitImage *img = webkit_web_view_get_snapshot_finish(web, r, &e);
  if (!img) { check(FALSE, "snapshot"); printf("  %s\n", e ? e->message : "?"); step_click(); return; }
  int w = webkit_image_get_width(img), h = webkit_image_get_height(img);
  guint stride = webkit_image_get_stride(img);
  GBytes *b = webkit_image_as_bytes(img);
  gsize n; const guint8 *px = g_bytes_get_data(b, &n);
  printf("  snapshot %dx%d stride %u, %zu bytes (%.0f ms)\n", w, h, stride, n, now_ms());
  check(w > 0 && h > 0 && write_png(png_path, px, w, h, stride), "snapshot written as PNG");
  g_object_unref(img);
  step_click();
}

static void on_raf(GObject *o, GAsyncResult *r, gpointer d) {
  char *err = NULL;
  JSCValue *v = finish(r, &err);
  double fps = v ? jsc_value_to_double(v) : 0;
  printf("  requestAnimationFrame: %.1f per second over 2 s%s%s\n", fps, err ? " — " : "", err ? err : "");
  check(fps > 50, "requestAnimationFrame runs at full rate on the headless view (not throttled)");
  webkit_web_view_get_snapshot(web, WEBKIT_SNAPSHOT_REGION_VISIBLE, WEBKIT_SNAPSHOT_OPTIONS_NONE, NULL, on_snapshot, NULL);
}

static void on_helper(GObject *o, GAsyncResult *r, gpointer d) {
  char *err = NULL;
  JSCValue *v = finish(r, &err);
  char *json = v ? jsc_value_to_json(v, 0) : NULL;
  printf("  isolated world returned: %s%s\n", json ? json : "(null)", err ? err : "");
  check(json && strstr(json, "Click me") != NULL, "isolated-world helper returns a value to C");
  g_free(json);
  // the page world must not see the helper
  eval_world("return typeof window.__shoji", NULL, (GAsyncReadyCallback) ({
    void f(GObject *o2, GAsyncResult *r2, gpointer d2) {
      char *e2 = NULL; JSCValue *v2 = finish(r2, &e2);
      char *s = v2 ? jsc_value_to_string(v2) : g_strdup("?");
      check(g_strcmp0(s, "undefined") == 0, "page world can't see the isolated world's helper");
      g_free(s);
      // promise awaited + rAF rate over 2 s, measured in the page
      eval_world("const a = window.rafCount; await new Promise(r => setTimeout(r, 2000)); return (window.rafCount - a) / 2;",
                 NULL, on_raf);
    }
    f; }));
}

static void step_click(void) {
  WPEView *view = webkit_web_view_get_wpe_view(web);
  double x = 140, y = 150;   // middle of the button
  guint32 t = (guint32)(g_get_monotonic_time() / 1000);
  WPEEvent *ev;
  ev = wpe_event_pointer_move_new(WPE_EVENT_POINTER_MOVE, view, WPE_INPUT_SOURCE_MOUSE, t, 0, x, y, 0, 0);
  wpe_view_event(view, ev); wpe_event_unref(ev);
  ev = wpe_event_pointer_button_new(WPE_EVENT_POINTER_DOWN, view, WPE_INPUT_SOURCE_MOUSE, t, 0, 1, x, y, 1);
  wpe_view_event(view, ev); wpe_event_unref(ev);
  ev = wpe_event_pointer_button_new(WPE_EVENT_POINTER_UP, view, WPE_INPUT_SOURCE_MOUSE, t + 50, 0, 1, x, y, 0);
  wpe_view_event(view, ev); wpe_event_unref(ev);
  g_timeout_add(300, (GSourceFunc) ({ gboolean f(gpointer d) { step_after_click(); return G_SOURCE_REMOVE; } f; }), NULL);
}

static void on_after_click(GObject *o, GAsyncResult *r, gpointer d) {
  char *err = NULL;
  JSCValue *v = finish(r, &err);
  char *s = v ? jsc_value_to_string(v) : NULL;
  printf("  after click: \"%s\"\n", s ? s : (err ? err : "?"));
  check(s && strstr(s, "button was clicked") != NULL, "synthetic click through wpe_view_event changes the page");
  check(s && strstr(s, "trusted=true") != NULL, "the click is a trusted event");
  g_free(s);
  // second picture, after the click
  char *p2 = g_strdup_printf("%.*s-clicked.png", (int)(strlen(png_path) - 4), png_path);
  png_path = p2;
  webkit_web_view_get_snapshot(web, WEBKIT_SNAPSHOT_REGION_VISIBLE, WEBKIT_SNAPSHOT_OPTIONS_NONE, NULL,
    (GAsyncReadyCallback) ({ void f(GObject *o3, GAsyncResult *r3, gpointer d3) {
      GError *e = NULL; WebKitImage *img = webkit_web_view_get_snapshot_finish(web, r3, &e);
      if (img) { gsize n; const guint8 *px = g_bytes_get_data(webkit_image_as_bytes(img), &n);
        write_png(png_path, px, webkit_image_get_width(img), webkit_image_get_height(img), webkit_image_get_stride(img)); }
      printf("\n%s: %d failure(s) (%.0f ms total)\n", failures ? "MILESTONE 1 NOT MET" : "MILESTONE 1 MET", failures, now_ms());
      g_main_loop_quit(loop);
    } f; }), NULL);
}

static void step_after_click(void) {
  eval_world("return document.getElementById('msg').textContent", NULL, on_after_click);
}

static void on_load(WebKitWebView *v, WebKitLoadEvent ev, gpointer d) {
  if (ev != WEBKIT_LOAD_FINISHED) return;
  printf("  loaded \"%s\" (%.0f ms)\n", webkit_web_view_get_title(v) ? webkit_web_view_get_title(v) : "", now_ms());
  eval_world("return window.__shoji.outline()", "shoji", on_helper);
}

static gboolean on_timeout(gpointer d) {
  printf("TIMEOUT: the spike didn't finish in 30 s\n");
  failures++;
  g_main_loop_quit(loop);
  return G_SOURCE_REMOVE;
}

int main(int argc, char **argv) {
  png_path = argc > 1 ? argv[1] : "spike.png";
  t0 = g_get_monotonic_time();
  loop = g_main_loop_new(NULL, FALSE);

  GError *e = NULL;
  WPEDisplay *display = wpe_display_headless_new();
  if (!wpe_display_connect(display, &e)) { printf("FAIL headless display: %s\n", e->message); return 1; }

  WebKitNetworkSession *session = webkit_network_session_new_ephemeral();
  WebKitUserContentManager *ucm = webkit_user_content_manager_new();
  webkit_user_content_manager_add_script(ucm, webkit_user_script_new(page_world_script,
      WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES, WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, NULL, NULL));
  webkit_user_content_manager_add_script(ucm, webkit_user_script_new_for_world(helper_script,
      WEBKIT_USER_CONTENT_INJECT_TOP_FRAME, WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, "shoji", NULL, NULL));
  webkit_user_content_manager_register_script_message_handler(ucm, "shojiLog", NULL);
  g_signal_connect(ucm, "script-message-received::shojiLog", G_CALLBACK(on_message), NULL);

  web = g_object_new(WEBKIT_TYPE_WEB_VIEW, "display", display, "network-session", session,
                     "user-content-manager", ucm, NULL);
  WPEView *view = webkit_web_view_get_wpe_view(web);
  check(view != NULL, "web view on the headless display has a WPEView");
  WPEToplevel *top = wpe_view_get_toplevel(view);
  if (top) wpe_toplevel_resize(top, W, H);
  printf("  view %dx%d, scale %.1f, mapped %d, visible %d\n", wpe_view_get_width(view), wpe_view_get_height(view),
         wpe_view_get_scale(view), wpe_view_get_mapped(view), wpe_view_get_visible(view));
  wpe_view_focus_in(view);

  g_signal_connect(web, "load-changed", G_CALLBACK(on_load), NULL);
  webkit_web_view_load_html(web, page, "file:///spike/");
  g_timeout_add_seconds(30, on_timeout, NULL);
  g_main_loop_run(loop);
  return failures ? 1 : 0;
}
