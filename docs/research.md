# Research notes

Measured on an Apple Silicon Mac (macOS 27.2, Ghostty 1.4, 2026-11-27). Each claim
below comes from a spike in `spikes/` that you can re-run.

## 1. Keeping an off-screen page alive (`spikes/throttle.swift`)

WebKit pauses pages it thinks nobody can see. Counted over 2 seconds on a test page:

| Window setup | requestAnimationFrame | 10 ms timer ticks | `visibilityState` |
|---|---|---|---|
| off-screen (−30000, −30000) | **0** | 2 | hidden |
| never ordered in | 0 | 2 | hidden |
| off-screen + `ProcessInfo.beginActivity` | 0 | 2 | hidden |
| on screen, alpha 0, on top | 126 (63 fps) | 175 | visible |
| on screen, alpha 0, **behind other windows** | 0 | 2 | hidden |
| off-screen + `_setWindowOcclusionDetectionEnabled:NO` | **126** | 175 | visible |
| same, with `YES` (control) | 0 | 2 | hidden |
| never ordered in + `…:NO` | 0 | 3 | hidden |

**Result:** a borderless window ordered in but off-screen, with WebKit's private
`-[WKWebView _setWindowOcclusionDetectionEnabled:]` set to NO, keeps the page fully live
(animation frames, timers, `visible`). It must be called with a real `BOOL` (typed IMP
call), not `perform(_:with:)`. Public fallback (a transparent window kept on top) breaks
as soon as another window covers it, so it isn't one. Pages still load and draw without
the private call; only animations/timers stall.

## 2. Cost of a frame (`spikes/framecost.swift`)

`WKWebView.takeSnapshot` on a live page, then the encodings the kitty protocol accepts:

| Pane (device px) | snapshot | → raw RGBA | zlib RGBA (`o=z`) | PNG (`f=100`) |
|---|---|---|---|---|
| 1600×1200 | 1.8 ms | 1.8 ms · 7.5 MB | 16 ms · 82 KB | 10.6 ms · 131 KB |
| 2400×1600 | 2.6 ms | 2.7 ms · 15 MB | 25 ms · 106 KB | 17 ms · 180 KB |
| 3400×2000 | 4.6 ms | 4.9 ms · 26 MB | 42 ms · 141 KB | 29 ms · 262 KB |

**Result:** capturing is cheap; encoding is what costs. Raw pixels handed over by
file or shared memory avoid encoding entirely.

## 3. What Ghostty 1.4 accepts (`spikes/probe.py`, run inside Ghostty)

- Kitty graphics `a=q` → OK for: direct PNG, direct RGBA, direct RGBA + zlib, file
  (`t=f`), temp file (`t=t`), **shared memory (`t=s`)**, unicode placeholders (`U=1`).
- DECRQM: SGR mouse 1006, **SGR-Pixels 1016**, any-motion 1003 all recognised.
- Kitty keyboard protocol supported (`CSI ? u` answers).
- Cell size `CSI 16 t` → 16×34 px; text area `CSI 14 t` → 1632×1088 px (device pixels).
- Replacing image `i=1` in place, 1200×800 RGBA, time until the terminal's OK:

| Transport | median | worst |
|---|---|---|
| shared memory (`t=s`) | **0.6 ms** | 0.9 ms |
| temp file (`t=t`) | 2.2 ms | 2.7 ms |
| zlib inline (`o=z`) | 3.6 ms* | 4.5 ms |

\* flat-colour test frames compress unusually well; real pages cost the zlib time in §2.

**Result:** a frame of a full Retina pane costs ≈ 3 ms snapshot + 3 ms pixel read +
<1 ms handover ≈ under 10 ms locally. Inline zlib remains the fallback for SSH.

## 4. Driving the page (`spikes/input.swift`)

Synthetic `NSEvent`s into the off-screen window (made key-capable by overriding
`canBecomeKey`):

| Sent | Page saw |
|---|---|
| 2 × leftMouseDown/Up on a button | `clicks: 2` |
| click a text field, keyDown/Up "hello" | focused, value `hello` |
| `NSTextInputClient.insertText(" 日本語")` (the input-method path) | value `hello 日本語` |
| `CGEvent` pixel scroll wheel → `scrollWheel(with:)` | `scrollY: 400` |

**Result:** clicks, focus, typing, IME text and scrolling all work without a visible window.

## 5. Prototype end to end

`wkterm /tmp/anim.html --offline` in a 122×38 Ghostty window: page sized from the
terminal's pixel size (976×629 pt at 2×), loaded in 0.23 s, **29 fps** sustained on an
animated page, frames sent only when the page changed.

## 6. In-place updates (`a=f`) — confirmed in Ghostty 1.4

Re-sending an image id deletes its placements before the new data is shown (kitty spec;
Ghostty `graphics_storage.zig` `addImage`), so it can flicker. Ghostty 1.4 implements
animation frames, and **`a=f,r=1,X=1,x,y,s,v` edits the root frame in place** keeping the
placement. Probed: create `a=T` → OK, edit a 400×50 band → OK; synchronized output
(`?2026`) supported. wkterm now creates the image once and writes only the changed rows
(row-by-row diff of successive snapshots) inside `?2026`. On the animated test page:
1 full frame + 185 partial, 29 fps, average band 369 of 1258 rows.

## 7. From the literature (sourced brief, 2026-11-27)

- **Ghostty v1.4.0** (source): media `t=d/f/t/s` all enabled; `t=t` only under the temp dir
  with `tty-graphics-protocol` in the path; `t=s` uses `shm_open` then always unlinks;
  macOS shm names ≤ 31 chars. Max 10000 px per side, 400 MB per image, 320 MB storage per
  screen, 65 MiB per payload. `U=1` placeholders supported. Mouse 1000/1002/1003/1006/1016,
  kitty keyboard (all flags). `TIOCGWINSZ` pixels include padding; `CSI 16 t` gives the
  real cell size — prefer it. *Unverified:* an edit may re-upload the whole texture.
- **kitty:** reference implementation. **WezTerm:** media parse, animation partial,
  **no `U=1`** yet (PR #7924), some deletes unhandled.
- **WebKit visibility** (`PageClientImplMac.mm isViewVisible`): visible only if the view is
  in a window, `window.isVisible`, and not occluded (checked only while
  `_windowOcclusionDetectionEnabled`). Hidden → rAF suspended, CSS/SVG animations paused,
  `visibilityState: hidden`. Also RunningBoard throttling and hidden-page timer
  throttling. SPI (in headers since 10.12): `_windowOcclusionDetectionEnabled`,
  `_overrideDeviceScaleFactor`, `WKPreferences._pageVisibilityBasedProcessSuppressionEnabled`.
- **Bun.WebView's recipe** (used here in part): occlusion detection off, process
  suppression off, window overriding `isVisible`/`isKeyWindow`/`screen` (an off-screen
  window has `screen == nil`, and on macOS 13/14 the display link then never fires).
- **takeSnapshot** is a software re-paint in the web process: it **misses WebGL and
  video**. ScreenCaptureKit captures those but needs Screen Recording permission.
  `render(in:)` on the layer: unreliable.
- **Input:** WebKitTestRunner, Bun and warpweb call responder methods on the view;
  mouse moves via SPI `_simulateMouseMove:` (macOS 13+) or tracking-area owners;
  text via `insertText:`. **Risk:** a focused password field turns on system-wide
  secure input (`EnableSecureEventInput`) because the window claims to be key.

### Prior art

| Project | Engine | Frames to the terminal | Notes |
|---|---|---|---|
| KittyBrowser | headless Chrome (CDP screencast) | changed rectangles, `t=t` or zlib | typing over ssh 110 → 72 ms with diffing; Chrome's ~50 ms frame pacing dominates |
| awrit | Electron offscreen paint | `t=s` shm, `a=f`+`a=c` | kitty only |
| Carbonyl | Chromium fork | text/block characters | 60 fps claim, no image protocol |
| Browsh | headless Firefox | text/blocks | |
| **warpweb** | **WKWebView** | `t=s` (PNG fallback) | experimental, 4 commits, targets Warp; tabs, downloads; no offline mode or agent control stated |
| Bun.WebView | WKWebView | `shmem` screenshots for kitty | a runtime API, not a browser |
| Mux | WPE | kitty | unfinished |

**Where wkterm differs:** Ghostty-first, offline mode enforced by WebKit, private by
default, partial in-place updates, and (planned) agent control and use inside Neovim.

### Linux

WPEPlatform is the stable default since WPE 2.54 (libwpe/fdo deprecated). Headless
platform built in; frames via a custom `WPEView` `render_buffer` (DMA-BUF or SHM),
`wpe_buffer_import_to_pixels`; input via `wpe_view_event`. No visibility workarounds needed.

## Open questions

- Flicker: addressed with in-place edits + synchronized output; needs eyes on a real session.
- Right-click / context menus: a native menu in an off-screen window would block; needs
  WebKit's context-menu delegate or suppression.
- Dirty regions: done as a row band; column-narrowing and scroll-shifting (KittyBrowser)
  would cut more.
- WebGL / video: not captured by takeSnapshot; ScreenCaptureKit as an opt-in.
- Secure input: a focused password field may enable system-wide secure input.
- Cell size: use `CSI 16 t` instead of `TIOCGWINSZ` (which includes padding).
- Shared memory from Swift needs a tiny C shim (`shm_open` is variadic).
- Inside Neovim / tmux: unicode placeholders (`U=1`) — supported by Ghostty, not yet used.
- Linux: WPE WebKit.
