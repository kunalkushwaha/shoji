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

## Open questions

- Flicker when replacing image `i=1` each frame (needs eyes on a real session).
- Right-click / context menus: a native menu in an off-screen window would block; needs
  WebKit's context-menu delegate or suppression.
- Dirty regions: send only the part of the frame that changed (kitty supports placing
  sub-images) to cut cost for typing/hover.
- Shared memory from Swift needs a tiny C shim (`shm_open` is variadic).
- Inside Neovim / tmux: unicode placeholders (`U=1`) — supported by Ghostty, not yet used.
- Linux: WPE WebKit.
