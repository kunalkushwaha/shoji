# wkterm

**A real web browser in your terminal, drawn by WebKit — no Chrome.**
For terminals that speak the kitty graphics protocol: Ghostty, kitty, WezTerm. macOS for now.

```sh
swift build -c release
.build/release/wkterm https://example.com
.build/release/wkterm ./report.html --offline
```

The page is live: scripts and animations run, and you click, scroll, hover and type into
it with the mouse and keyboard. Frames are sent only when the page changes.

| Keys | |
|---|---|
| `Ctrl+L` | type an address (or search words) |
| `Ctrl+R` | reload |
| `Ctrl+B` / `Ctrl+N` | back / forward |
| `Ctrl+Q` | quit |

The top bar's ◀ ▶ ⟳ are clickable; click the address to edit it.

**Private:** nothing is stored between runs. **`--offline`:** every request that isn't a
local file is blocked by WebKit itself, so local reports and prototypes can't phone home.

## How it works

A `WKWebView` lives in an off-screen window (kept live with WebKit's occlusion check
turned off), is snapshotted when it changes, and each frame is handed to the terminal
as raw pixels through a temp file — no image data goes through the terminal stream.
Mouse reports (SGR with pixel coordinates) and keys become `NSEvent`s for the page.
Measurements behind each choice: [docs/research.md](docs/research.md).

## Status

Early prototype. Not yet: right-click menus, tabs, downloads, dirty-region updates,
use inside Neovim/tmux (unicode placeholders), Linux (WPE WebKit).
