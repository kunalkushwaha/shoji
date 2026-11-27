#pragma once
// Run GLib's main loop and drain Dispatch's main queue from it (what CoreFoundation
// does on Linux: libdispatch exposes the main queue as an eventfd).
void loop_run(void);
void loop_quit(void);
void loop_glib_timeout(unsigned ms, void (*cb)(void *), void *ctx);
