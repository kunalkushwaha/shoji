# shoji on Linux — requirements and findings

Written 2026-11-27 as the hand-off for the Linux port, from the macOS implementation
(0.2.0) and research. The port is done (released in 0.3.0): see the milestone and phase
results below, and the README for installing.
Read the [README](../README.md) and [research.md](research.md) first.

## Why Linux

Coding agents mostly run in Linux containers and CI. There, the only real option today
is headless Chromium (Playwright, Puppeteer, Chrome DevTools MCP): hundreds of MB to
download, ~270–380 MB per page in memory ([performance.md](performance.md)). A shoji
headless mode on WPE WebKit would give agents the same `shoji ctl` interface with a
smaller engine. The terminal and Neovim modes matter less on Linux (they're mostly used
over SSH from a desktop) and come second.

## Requirements

### Phase 1 — headless mode for agents (the goal)

1. `shoji --headless` and `shoji ctl …` work on Linux with **the same commands, options
   and output** as on macOS: open, snapshot (`--view`, `--text`, `--max`), click / fill /
   select / check / uncheck (targets: snapshot ids, visible text, CSS selectors, x y),
   type, key, scroll, text, html, eval, console, errors, network (`--failed`, `--all`),
   dialog, screenshot (`--full`, `--retina`), wait, status, back, forward, reload, quit;
   `--name`, `--offline`, `--json`; the browser starts on first `ctl` use and quits after
   30 idle minutes.
2. **`tests/agent_test.py` passes unchanged** (38 checks). It's the acceptance test.
3. **Offline:** `--offline` blocks every request that isn't `file:`, `data:`, `blob:` or
   `about:` inside the engine (content filter), and blocked requests show up in `errors`.
4. **Private:** nothing stored between runs (ephemeral network session, no disk cache).
5. **No telemetry, no network** except what the page itself loads.
6. **Packaging:** a Docker image (agents use it with no setup) and a tarball with the
   binary. Document the runtime packages.
7. **Numbers:** run `bench/measure.py`'s equivalent against headless Chromium in the same
   container and record memory, startup and CPU in `performance.md`.

### Phase 2 — terminal and Neovim modes

8. `shoji <url>` in a kitty-graphics terminal (Ghostty and kitty on Linux, WezTerm), same
   keys, top bar, window title, partial in-place frame updates (`a=f,r=1,X=1` inside
   `?2026`).
9. **Over SSH**: shared memory (`t=s`) and temp files (`t=t`) don't cross machines, so
   frames must also go **inline** (`t=d,f=32,o=z`, 4096-byte base64 chunks with `m=1`).
   Detect locality (an `a=q` query with `t=t` fails remotely) and fall back. macOS needs
   this too — implement it in the shared code.
10. `--embed` for Neovim (unicode placeholders, JSON lines on stdin/stdout) unchanged;
    the Neovim side (Lua, see [neovim.md](neovim.md)) needs no changes.

### Not required

WebKitGTK / X11 / Wayland windows, older WPE APIs (libwpe + WPEBackend-fdo), Alpine/musl.

## What carries over unchanged

| File | Contents | On Linux |
|---|---|---|
| `PageScripts.swift` | JavaScript put into pages: focus, change wake-ups, console/errors/network capture (page world); snapshot, targets, fill/select/check (isolated world) | **as is** — WPE has the same `window.webkit.messageHandlers.<name>.postMessage` bridge and isolated worlds |
| `Control.swift` | JSON command protocol, control socket (Unix domain), line reader | as is, except `DispatchSource` scheduling (see *Main loop*) |
| `Ctl.swift` | `shoji ctl` client, output formatting, auto-start | replace `_NSGetExecutablePath` (`/proc/self/exe`) and check `POSIX_SPAWN_SETSID` (glibc ≥ 2.26 has it) |
| `Input.swift` | terminal input decoder (SGR mouse incl. pixels, keys, UTF-8, replies) | as is |
| `Display.swift` | kitty graphics commands (create once, edit rows in place), embed JSON events | as is, plus the inline transport (req. 9) |
| `Terminal.swift` | raw mode, sizes, top bar, title | as is (termios/ioctl via Glibc) |
| `main.swift` | modes, offline rule list (JSON), signals | rules JSON as is; the run loop changes |
| `Browser.swift` | **the WebKit engine** | **rewrite against WPE** (below) |

The offline rules are Safari content-blocker JSON; WPE's `WebKitUserContentFilterStore`
compiles the same format.

## Engine mapping: macOS WebKit → WPE WebKit

WPE WebKit ≥ 2.54 with **WPEPlatform** (the new platform API; stable default since 2.54,
libwpe/fdo deprecated). C/GObject API, pkg-config `wpe-webkit-2.0` and `wpe-platform-2.0`.

| shoji needs | macOS (Browser.swift) | WPE |
|---|---|---|
| a web view without a screen | `WKWebView` in an off-screen `NSWindow` + private `_setWindowOcclusionDetectionEnabled:NO` and a window subclass forcing visible/key (so rAF and timers run) | `WebKitWebView` on the **headless display** (`wpe_display_headless_new()` / `WPE_PLATFORM=headless`). Make sure its `WPEView` is mapped/visible so pages aren't throttled — no private API needed |
| private session | `WKWebsiteDataStore.nonPersistent()` | `webkit_network_session_new_ephemeral()` |
| scripts at document start, page world + isolated world | `WKUserScript(…, in: .page / .world(name: "shoji"))` | `webkit_user_script_new()` / `webkit_user_script_new_for_world(…, "shoji")` + `webkit_user_content_manager_add_script()` |
| messages from pages (`shojiFocus`, `shojiWake`, `shojiLog`) | `WKScriptMessageHandler` | `webkit_user_content_manager_register_script_message_handler(mgr, name, NULL)` + `script-message-received::<name>` signal (message is a `JSCValue`) |
| run JS, await promises, in a world | `callAsyncJavaScript(_:arguments:in:in:)` | `webkit_web_view_call_async_javascript_function(view, body, -1, args, world_name, …)` (args as `GVariant` dict) |
| offline content rules | `WKContentRuleListStore` | `webkit_user_content_filter_store_save()` → `webkit_user_content_manager_add_filter()` |
| load / commit / finish / fail | `WKNavigationDelegate` | `load-changed`, `load-failed` signals |
| main document HTTP status | `decidePolicyFor navigationResponse` | `decide-policy` with `WEBKIT_POLICY_DECISION_TYPE_RESPONSE` → `webkit_response_policy_decision_get_response()` |
| alert / confirm / prompt | `WKUIDelegate` panels | `script-dialog` signal (`webkit_script_dialog_get_dialog_type`, `…_confirm_set_confirmed`, `…_prompt_set_text`) |
| `target=_blank` into the same view | `createWebViewWith` | `create` signal |
| title / url / loading | KVO | `notify::title`, `notify::uri`, `notify::is-loading` |
| frames | `takeSnapshot` on a timer + row diff | a **custom `WPEView`** whose `render_buffer` gets every frame as `WPEBufferSHM` (software) or DMA-BUF; `wpe_buffer_import_to_pixels()` gives the bytes; answer with `wpe_view_buffer_rendered()` / `…_released()`. Frames arrive only when the page paints, so the polling and the `shojiWake` heuristics aren't needed for the frame loop |
| screenshot PNG (`ctl screenshot`, `--full`) | `takeSnapshot` | the last buffer → PNG (any encoder: cairo, libpng, or a small zlib PNG writer); `--full`: resize the view to the page height like macOS does |
| mouse / wheel / keys | `NSEvent` straight to the view's responder methods | `wpe_view_event()` with `wpe_event_pointer_button_new`, `…_pointer_move_new`, `…_scroll_new`, `…_keyboard_new` (X keysyms + keycodes; map shoji's `Key` enum and ASCII); text from input methods: check WPE's input-method API, or fall back to key events per character |
| device scale | `NSScreen.backingScaleFactor` | the view/display scale (`--scale`, default 1 headless; the terminal's cell pixels in terminal mode) |

## Main loop

macOS runs everything on AppKit's run loop and `DispatchQueue.main` (`asyncAfter`,
`DispatchSource` for stdin, sockets, signals, timers). WPE needs a **GLib main loop**. On
Linux, `DispatchQueue.main` is not driven by GLib. Pick one loop and route everything
through it — suggested: run `GMainLoop`, and replace main-queue scheduling with a small
`Loop` abstraction (`after(seconds:)`, `onReadable(fd:)`, `onSignal(_:)`, `every(_:)`)
implemented with `g_timeout_add`, `g_unix_fd_add`, `g_unix_signal_add` on Linux and
Dispatch on macOS. Most of the work is mechanical once the abstraction exists.

## Suggested code structure

- `protocol Engine` for what `Controller`, the displays and the input paths call today
  on `Browser` (load, back/forward/reload, evalPage/evalHelper, key/typeText/mouse/
  scroll/click, screenshot(full:), page log, dialogs, status callbacks, resize, frames).
- `Sources/shoji/Engine+WebKitMac.swift` (today's `Browser`) under `#if os(macOS)`,
  `Engine+WPE.swift` under `#if os(Linux)`.
- `Package.swift`: a `systemLibrary` target `CWPE` with `pkgConfig: "wpe-webkit-2.0"`
  (and `wpe-platform-2.0`), used only on Linux; a thin C shim header if some GObject
  macros or variadic functions (e.g. `g_signal_connect`) don't import cleanly into Swift.
- Keep `PageScripts.swift`, the protocol and `tests/agent_test.py` shared — they define
  "same behaviour on both".

## Where WPE is packaged (repology, 2026-11-27)

| Distribution | wpewebkit | Usable |
|---|---|---|
| Debian 14 forky (testing), sid | 2.54.3 | **yes** |
| Arch Linux (extra) | 2.54.3 | yes |
| Terra (Fedora-based, third party) | 2.54.2 | probably |
| Guix | 2.50.3 | WPEPlatform not yet the stable default |
| Debian 13 trixie (stable) | 2.48.3 | no (older platform API) |
| Alpine 3.18–3.21 | 2.40.5 | no |
| Ubuntu (newest listed: 22.04) | 2.36.0 | no |
| Fedora (official), Homebrew on Linux, nixpkgs | not listed | — |

So: **base the Docker image on `debian:testing`** (or sid), and document Arch. Ubuntu and
Debian stable users run the image. Supporting the old libwpe/fdo API would be a second
engine path — out of scope unless there's demand.

Swift on Linux: the swift.org toolchains (Debian 12 and Ubuntu builds) or the official
`swift` Docker images; check that a toolchain installs on Debian testing (or build in a
`swift` image and copy the binary into a `debian:testing` runtime image with the WPE
runtime packages).

## Risks

1. **WPEPlatform is new:** details may change between 2.54 and later; pin the version in
   the image and keep the engine code small.
2. **Frames:** whether headless WPEPlatform hands SHM buffers by default (software
   rendering) or needs DMA-BUF/EGL — check early; a container has no GPU.
3. **Throttling:** confirm a headless view counts as visible (rAF and timers at full rate);
   the macOS test page in `spikes/throttle.swift` shows how to measure it.
4. **Input:** key mapping (keysyms), text from input methods, `isTrusted` of synthetic
   events, double clicks.
5. **Swift ↔ GObject:** signals with typed callbacks, `GVariant` arguments, reference
   counting — a C shim may be simpler for a few calls.
6. **Main loop:** mixing Dispatch and GLib leads to hangs; route through one loop.

## First milestone (≈ 1 day): prove the engine

In a `debian:testing` container with WPE 2.54 and a Swift toolchain:

1. A WebKitWebView on the headless display loads a page, runs a user script in an
   isolated world, receives a script message, and returns a value from
   `call_async_javascript_function`.
2. A frame buffer is received and written as a PNG; requestAnimationFrame runs at
   ~60 fps on `spikes`' test page (no throttling).
3. A synthetic click on a button changes the page.

If all three work, the rest is porting (estimate: phase 1 ≈ 3–4 days, phase 2 ≈ 2–3 days).

## First milestone: done (2026-11-27)

Run on Debian testing (WPE WebKit 2.54.3) in Docker, x86_64. Everything in
`spikes/linux/`:

```sh
cd spikes/linux
docker build -t shoji-linux-dev   -f Dockerfile.dev .     # WPE 2.54 + C tools
docker build -t shoji-linux-swift -f Dockerfile.swift .   # + Swift 6.3
docker run --rm -e WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 -v "$PWD":/src shoji-linux-dev sh -c \
  'cc engine_spike.c $(pkg-config --cflags --libs wpe-webkit-2.0 wpe-platform-headless-2.0 libpng) -o out/engine_spike && cd out && ./engine_spike spike.png'
docker run --rm -e WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 -v "$PWD/swiftcheck":/src -w /src shoji-linux-swift \
  sh -c 'swift build -c release && .build/release/swiftcheck'
```

| Check | Result |
|---|---|
| WebKitWebView on `wpe_display_headless_new()` (no compositor, no GPU) | works; the view is mapped and visible from the start |
| user script in the page world posts a script message to C | works (~150 ms after start) |
| helper in an isolated world (`"shoji"`), value back through `call_async_javascript_function` (awaits promises) | works; the page world can't see the helper |
| requestAnimationFrame on the headless view | **57.5/s** — not throttled, no private API or tricks needed |
| screenshot | `webkit_web_view_get_snapshot()` returns a `WebKitImage` with raw pixels (premultiplied BGRA, cairo ARGB32 order); written as PNG with libpng, colours correct |
| synthetic click through `wpe_view_event()` | changes the page, and the event is **trusted** (`isTrusted=true`) |
| Swift 6.3 drives WPE through a C shim (`swiftcheck/`) | works: Swift closures as callbacks, JS results as Foundation values, JS exceptions as errors |

Whole C spike, start to finish: 2.5 s (2 of them measuring rAF).

### What changed in the plan

- **Screenshots need no custom `WPEView`.** `webkit_web_view_get_snapshot()` (with
  `WEBKIT_SNAPSHOT_REGION_FULL_DOCUMENT` for `--full`) covers phase 1. The custom
  view with `render_buffer` is only needed for phase 2's live frame stream.
- **Engine in C, Swift on top.** GObject signals, `GVariant` and async callbacks are
  natural in C; Swift sees ~20 plain functions (`spikes/linux/swiftcheck/Sources/CShim`).
  `CWPE` is a `systemLibrary` target with `pkgConfig: "wpe-webkit-2.0"`; the headless
  and platform APIs live in the same `libWPEWebKit-2.0.so`.
- **Build the Linux engine next to the macOS code** (`#if os(Linux)`), not as a
  refactor of it: the macOS build can't be compiled or tested from Linux. Do the shared
  `Engine` protocol cleanup on a Mac where both builds can be checked. Today
  `Control.swift` and `Terminal.swift` call `browser.web` directly about 20 times
  (back/forward/reload/stop, url/title/isLoading/canGoBack, bounds) and `Control.swift`
  imports AppKit and WebKit — those are the calls the protocol has to cover.

### Findings to carry into the port

1. **WebKit's sandbox in Docker.** WPE runs its web process under bubblewrap. In a
   default container that fails (`bwrap: Creating new namespace failed`) and the UI
   process aborts. Unconfined seccomp/AppArmor/systempaths still isn't enough
   (`bwrap: loopback: Failed RTM_NEWADDR`); only `--privileged` works. Decision for the
   image: the container is the sandbox — set `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1`
   in the image (what Playwright's Chromium images do with `--no-sandbox`). On a plain
   Linux host keep the sandbox on; Ubuntu 24.04 restricts unprivileged user namespaces
   (`kernel.apparmor_restrict_unprivileged_userns=1`), so test there separately.
2. **Swift on Debian testing.** swift.org has no Debian 13/testing build; the Debian 12
   toolchain works, but `swift-build` needs `libxml2.so.2` and testing ships
   `libxml2.so.16`. `Dockerfile.swift` installs bookworm's `libxml2` alongside (different
   package name, pinned low). The compiled shoji binary doesn't need it — the runtime
   image stays plain `debian:testing` + `libwpewebkit-2.0-1`.
3. **Button-up events must have press count 0** (`wpe_event_pointer_button_new(UP, …, 0)`);
   WPE asserts otherwise. Double clicks: press count 2 on the second DOWN
   (`wpe_view_compute_press_count()` exists for this).
4. **Load base URI:** `load_html(html, "file:///…/")` gives the page a `file:` origin,
   so the offline rules' `^file:` allowance applies to it.
5. Runtime size: `libwpewebkit-2.0-1` is ~127 MB installed (plus GLib, libsoup,
   GStreamer pulled in as dependencies — measure the final image).

## Phase 1: done (2026-11-27)

`shoji ctl` / `--headless` on Linux, same commands and output as macOS.

- `tests/agent_test.py`: **38/38** on Linux (in the dev container and in the final image,
  as a non-root user). `tests/more_test.py` (new, 20 checks — typing incl. Japanese, keys,
  Tab, eval/promises/exceptions, scroll, wait, history, local files, screenshots and
  colours, `--retina`, `target=_blank`, `--offline`): **20/20**.
- `Dockerfile` (two stages: Swift build → plain `debian:testing` runtime), 755 MB on disk,
  287 MB download. `scripts/dist-linux.sh` → 22 MB tarball, tested on a bare Debian
  testing with only the runtime packages.
- Numbers next to headless Chromium: [performance.md](performance.md#linux).

### How it's built

| | |
|---|---|
| `Sources/CShojiWPE/` | the engine in C (~400 lines): headless display, web view, scripts in both worlds, message handlers, dialogs, content filter, `create` → same view, input events, snapshots, PNG writer, GLib loop |
| `Sources/CWPE/` | `systemLibrary`, `pkgConfig: "wpe-webkit-2.0"`; only a dependency on Linux (`TargetDependencyCondition`) |
| `Sources/shoji/BrowserWPE.swift` | `#if os(Linux)`: the same API as the macOS `Browser` (incl. a `web` object with `url`, `title`, `isLoading`, `canGoBack`, `bounds`, `goBack()`, …), so `Controller`, the displays and the terminal UI compile unchanged |
| shared files | `#if os(macOS)` guards only: imports, `NSApplication`, `NSScreen` scale, the idle `Timer`, `app.run()`, `_NSGetExecutablePath`, `ioctl`/`Darwin.write`, `SOCK_STREAM`. macOS code paths are unchanged. Built and tested on a Mac at 86ca865 (see below) |

**Main loop:** GLib's `GMainLoop` runs, and Dispatch's main queue is drained from it through
libdispatch's eventfd (`_dispatch_get_main_queue_handle_4CF` /
`_dispatch_main_queue_callback_4CF`, what CoreFoundation's run loop uses on Linux). So
`DispatchQueue.main`, `asyncAfter` and every `DispatchSource` on `.main` work unchanged —
the `Loop` abstraction proposed above wasn't needed (`spikes/linux/loopcheck`).

### Found while porting

1. **Runtime packages:** `libwpewebkit-2.0-1` doesn't pull in **`libgles2`** (the web process
   aborts loading `libGLESv2.so.2`) or **`shared-mime-info`** (without it every local file is
   shown as plain text).
2. **Mesa is required:** WPE draws through EGL; without Mesa it aborts ("Could not create EGL
   display"). In a container that's llvmpipe — most of the memory difference to macOS.
3. **Scrolling:** a precise scroll event moves 2.5 CSS px per unit of delta, opposite in sign;
   and a following "scroll stop" event makes WPE add momentum that flings the page to the
   end. shoji sends delta/2.5, no stop event (measured exact for 60, 100, 400, −200 px).
4. **Typing** non-ASCII text works as key events with Unicode keysyms (`0x01000000 + code
   point`); Japanese arrives intact. Keycodes come from WPE's keymap.
5. **Clicks are trusted** (`isTrusted=true`), and press counts give double clicks.
6. `call_async_javascript_function` args: shoji passes them as `const` declarations in the
   body (JSON), not as a `GVariant` dictionary — same effect as macOS's `arguments:`.
7. **Swift**: `--static-swift-stdlib` makes the binary independent of a Swift install
   (58 MB, most of it Foundation's ICU data).

## Phase 2: terminal mode (2026-11-27)

`shoji <url>` on Linux, tested against a fake kitty terminal in a pty
(`tests/terminal_test.py`, 35 checks, 6 scenarios): the terminal's picture is compared
with `ctl screenshot` of the same page, clicks go through SGR pixel mouse reports, later
frames must be `a=f` row updates.

- **Inline frames (requirement 9), shared code:** at start `TerminalDisplay.probe()` asks
  the terminal to load a 1x1 image from a temp file (`a=q,t=t`). `OK` → temp files as
  before; an error (SSH, shoji in a container, a sandboxed terminal) → `t=d` inline, in
  4096-byte chunks (`m=1`), zlib-compressed (`o=z`; on macOS Foundation's raw DEFLATE plus
  zlib's header and Adler-32 trailer). No reply in 1 s → temp files. `SHOJI_FRAMES=inline|file` overrides. The input
  parser now passes kitty replies on (`InputEvent.reply`) instead of dropping them.
  On the test page, 10–12 MB of pixels went as 0.1 MB.
- **`docker run -t` gives the tty rows and columns but no pixel size** (0x0). shoji then asks the terminal (`CSI 14 t` → `CSI 4;h;w t`) at start and after each resize.
- **Real terminal:** works in Ghostty (snap) on Ubuntu 24.04 at 125% scaling, with
  `docker run --rm -it -e SHOJI_SCALE=1.25 shoji <url>` — frames inline from the
  container (confirmed by Kunal, 2026-11-27).
- **HiDPI:** `SHOJI_SCALE` (terminal mode only) is applied as WebKit page zoom; the view
  stays in device pixels, the page lays out in CSS pixels (1200 px at 1.25 → 960), and
  the engine scales mouse positions and scroll deltas (both are device pixels in WPE).
  Linux has no reliable way to read the screen's scale from inside a terminal.

- **macOS check (2026-11-27):** the `linux` branch built on an Apple Silicon Mac (macOS
  27.2.1, Swift 6.4.2, Command Line Tools). agent_test, more_test and terminal_test all
  pass (terminal_test in 66 s). The first run found two Linux-only terminal paths (the
  pixel-size query and zlib inline frames), now shared — fixed in 86ca865.

- **`--embed` (Neovim):** `tests/embed_test.py` plays Neovim's side of the JSON-lines
  protocol (see [neovim.md](neovim.md)) and decodes the graphics commands
  Neovim would pass on: ready/resize, unicode-placeholder placement over the window's
  cells, status and focus events, col/row clicks, typing (incl. Japanese), changed-row
  updates, scrolling, the wheel, `shoji ctl --name` on the embedded page, and the image
  removed when Neovim closes the job. All pass on Linux with temp files, with
  `SHOJI_FRAMES=inline` (now honoured by `--embed`: zlib inline frames for Neovim over SSH
  or shoji in a container) and at `SHOJI_SCALE=2`. Not tried with a real Neovim here:
  this machine's Neovim (0.9.5) predates `nvim_ui_send`.
- **Messages from iframes** now name their frame in the log (`(in frame …)`), as on
  macOS. WPE's script messages carry no frame info, so the page script adds
  `location.href` itself when it runs inside a frame (more_test checks it).
- **Where it runs (2026-11-27):** WPE WebKit 2.54 with the 2.0 API is packaged by Debian
  testing/sid and Arch only. Ubuntu 26.04 and Fedora 45 don't package WPE at all,
  Debian 13 has 2.48. The tarball's binary also needs glibc 2.43 (Debian testing).
  **Decision: on Linux, shoji is supported through the Docker image.** The tarball is
  a convenience for Debian testing / Arch.
- **WebKit's sandbox on a host:** Ubuntu 24.04+ blocks unprivileged user namespaces
  (`kernel.apparmor_restrict_unprivileged_userns = 1`): on this Ubuntu 24.04 machine both
  `bwrap --unshare-user` and `unshare -Ur` are refused, so WebKit's bubblewrap sandbox
  can't start without an AppArmor profile granting `userns` (as Ubuntu ships for
  Chrome and Epiphany). In Docker the same restriction (plus Docker's seccomp and masked
  /proc) is why the image turns the sandbox off.

- **Native packages (2026-11-28):** `scripts/dist-linux.sh [tar] [deb] [arch]` builds, all
  in Docker: the tarball and a `.deb` from the Debian testing build (Depends:
  `libc6 (>= 2.43)`, `libwpewebkit-2.0-1 (>= 2.54)`, `libgles2`, `libpng16-16t64`, `zlib1g`,
  `shared-mime-info`), and an Arch package made by `makepkg` from `packaging/arch/PKGBUILD`
  in an `archlinux` container, against Arch's own wpewebkit 2.54.3 and glibc 2.44 (Swift
  from swift.org there; AUR's `swift-bin` on a real Arch machine). Checked: each installs
  into a fresh container with the distro's package manager (the `.deb` with
  `--no-install-recommends`, so `Depends` alone is enough), and agent_test, more_test
  and embed_test all pass against the installed `/usr/bin/shoji` as a normal user.
  The repository is public and Apache-2.0 licensed, and the PKGBUILD carries the v0.3.0
  tarball's checksum, so it can go to the AUR as is.

### Not done yet

- `aarch64`: packages and a multi-arch (`amd64` + `arm64`) image. This machine has no
  arm64 emulation for Docker. `dist-linux.sh` builds for the machine it runs on, so an
  arm64 Linux host (a Koala VM on an Apple Silicon Mac, or GitHub's arm64 runners) gets
  the arm64 `.deb` and Arch package (Arch Linux ARM: another base image). Publishing the
  image to ghcr.io needs Kunal's OK.

## Test plan

- `python3 tests/agent_test.py /path/to/shoji` in the container (all 38 checks).
- Offline: the blocked-requests check (see README) shows the blocked image, CSS and fetch.
- Memory/startup/CPU next to headless Chromium in the same container.
- Phase 2: Ghostty on Linux locally (temp-file/shm frames) and over SSH from a Mac
  (inline frames), the Neovim embed over SSH.

## References

- WPEPlatform stable default (2.54): https://wpewebkit.org/blog/2026-10-06-wpe-platform.html
- WPE 2.52 notes (building without libwpe/fdo): https://wpewebkit.org/blog/2026-03-18-wpewebkit-2.52.html
- `WPEView` (render_buffer, buffers, events): https://github.com/WebKit/WebKit/blob/main/Source/WebKit/WPEPlatform/wpe/WPEView.h
- WebKit API reference (WPE): https://webkitgtk.org/reference/wpe-webkit-2.0/stable/ (WebKitWebView, WebKitUserContentManager, WebKitUserContentFilterStore, WebKitScriptDialog)
- Kitty graphics protocol (inline transfer, chunking): https://sw.kovidgoyal.net/kitty/graphics-protocol/
- Package versions: https://repology.org/project/wpewebkit/versions
- Prior art on WPE + kitty (unfinished): https://github.com/Irvinwop/Mux
