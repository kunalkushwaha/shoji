#include "cloop.h"
#include <glib.h>
#include <glib-unix.h>
extern int _dispatch_get_main_queue_handle_4CF(void);
extern void _dispatch_main_queue_callback_4CF(void *msg);
static GMainLoop *loop;
static gboolean drain(gint fd, GIOCondition c, gpointer d) { _dispatch_main_queue_callback_4CF(NULL); return G_SOURCE_CONTINUE; }
void loop_run(void) {
  loop = g_main_loop_new(NULL, FALSE);
  g_unix_fd_add(_dispatch_get_main_queue_handle_4CF(), G_IO_IN, drain, NULL);
  _dispatch_main_queue_callback_4CF(NULL);   // anything queued before the loop started
  g_main_loop_run(loop);
}
void loop_quit(void) { g_main_loop_quit(loop); }
typedef struct { void (*cb)(void *); void *ctx; } T;
static gboolean fire(gpointer d) { T *t = d; t->cb(t->ctx); g_free(t); return G_SOURCE_REMOVE; }
void loop_glib_timeout(unsigned ms, void (*cb)(void *), void *ctx) { T *t = g_new(T, 1); t->cb = cb; t->ctx = ctx; g_timeout_add(ms, fire, t); }
