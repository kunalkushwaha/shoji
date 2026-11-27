// The narrow C API Swift calls; all GObject/GLib details stay in shoji_wpe.c.
#pragma once
typedef struct ShojiEngine ShojiEngine;
typedef void (*shoji_void_cb)(void *ctx);
typedef void (*shoji_result_cb)(void *ctx, const char *json, const char *error);

ShojiEngine *shoji_engine_new(int width, int height, const char *helper_script, const char *helper_world);
void shoji_engine_on_loaded(ShojiEngine *e, shoji_void_cb cb, void *ctx);
void shoji_engine_load_html(ShojiEngine *e, const char *html, const char *base_uri);
void shoji_engine_eval(ShojiEngine *e, const char *body, const char *world, shoji_result_cb cb, void *ctx);
void shoji_engine_click(ShojiEngine *e, double x, double y);
void shoji_loop_after(unsigned ms, shoji_void_cb cb, void *ctx);
void shoji_loop_run(void);
void shoji_loop_quit(void);
