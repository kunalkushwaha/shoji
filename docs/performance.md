# Performance

Measured 2026-11-27 on an Apple Silicon Mac (macOS 27.2), shoji 0.1.0 next to Google
Chrome 158 in headless mode — the engine KittyBrowser, awrit and similar terminal
browsers run on. Re-run with `python3 -I bench/measure.py`.

## Memory

macOS "footprint" (what Activity Monitor shows), summed over every process involved:
shoji plus WebKit's helper processes, or Chrome's whole process tree. Same pages, same
1280×800 viewport, after the page has settled.

| Page | shoji | headless Chrome | shoji saves |
|---|---|---|---|
| tiny page (example.com) | **77 MB** · 4 processes | 267 MB · 12 processes | 190 MB (71%) |
| Wikipedia article | **218 MB** · 4 processes | 351 MB · 12 processes | 133 MB (38%) |
| local page with JavaScript | **212 MB** · 4 processes | 377 MB · 12 processes | 165 MB (44%) |

What the page itself needs (its DOM, images, scripts) costs about the same in any engine;
the saving is the browser around it: Chrome's browser, GPU, network and utility
processes against WebKit's three small helpers, which macOS shares between apps.

## Disk

| | |
|---|---|
| shoji | **0.4 MB** (Apple Silicon) · 0.8 MB universal binary |
| Chrome | 1.5 GB app |

shoji has no engine to ship: WebKit is part of macOS.

## Speed and CPU

| | |
|---|---|
| Start → page loaded | 0.7 s (local page, tiny page) · 1.8 s (Wikipedia, over the network) |
| Animated page, drawn in the terminal | **30 fps**, 34% of one core (full Retina pane, 2560×1530 px) |
| Static page, idle | **0.9% of one core** |
| A change on an idle page appears after | ≈ 0.1 s |
| One frame: snapshot · handover to Ghostty | ≈ 3 ms · < 1 ms (shared memory) / 2 ms (temp file) |
| Typing / hover updates | only the changed rows are sent (e.g. 24 of 1512 rows per keystroke) |

Idle cost is low because the page tells shoji when it changes (DOM edits, animations and
transitions starting); shoji only takes a picture then, plus a check every 2 s for changes
it can't see. Frame-level measurements are in [research.md](research.md).

## Caveats

- One machine, one run per number; memory moves by a few MB between runs.
- shoji's WebKit helpers are found by diffing the process list before and after start;
  another app starting WebKit at the same moment would be counted too.
- Chrome was measured headless with a fresh profile; a Chrome you already run for daily
  browsing would add only a renderer per tab (but it isn't in your terminal).

## Linux

Measured 2026-11-27 in Docker on x86_64 (Ryzen 7 PRO 7840U), shoji 0.2.0 on WPE WebKit
2.54.3 next to Debian's Chromium 156 in headless mode, in the same container
(`bench/Dockerfile.bench`, `bench/measure_linux.py`). Two runs; numbers moved by a few MB.

Memory per page, summed over every process involved, after the page settled.
**PSS** counts all memory, with shared pages split between the processes that use them;
**own** is anonymous memory only (heaps, JIT, buffers) — closest to macOS's footprint,
which leaves out library code.

| Page | shoji PSS · own | headless Chromium PSS · own |
|---|---|---|
| tiny page (example.com) | **340 MB · 148 MB** · 3 processes | 411 MB · 160 MB · 9 processes |
| Wikipedia article | **450 MB · 243 MB** · 3 processes | 479 MB · 215 MB · 9 processes |
| local page with JavaScript | **327 MB · 139 MB** · 3 processes | 419 MB · 165 MB · 9 processes |

| Disk | shoji | Chromium |
|---|---|---|
| Container image (Debian testing, fonts-dejavu) | **755 MB** · 287 MB download | 961 MB · 385 MB download |
| Engine package | 127 MB (`libwpewebkit-2.0-1`) | 324 MB (`chromium`) |
| Binary | 58 MB (Swift runtime linked in) · 22 MB tarball | — |

Start → page loaded: 0.6 s (local page, tiny page), 2.0 s (Wikipedia, over the network).

**Why the saving is smaller than on macOS.** On macOS, WebKit is part of the system and
draws with the GPU; its libraries are shared with every app. In a container, WPE draws
through Mesa's software GL (llvmpipe): LLVM and gallium are loaded in two processes and
the web process holds ~80 MB of GL buffers and compiled shaders. WPE has no setting to
draw without EGL (without Mesa it aborts: "Could not create EGL display"), and Mesa's
simpler `softpipe` driver uses more memory (+150 MB). Chromium, in contrast, also renders
in software here, so both pay for it. Where shoji clearly wins on Linux: a third of the
processes, a smaller image, and no Node/Playwright needed to drive it.

