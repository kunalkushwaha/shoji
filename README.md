# shoji

**A real web browser in your terminal, drawn by WebKit — no Chrome.**

*Shoji* (障子) is the translucent paper screen in a wooden frame: the light and the world
outside show through it. Here, web pages show through your terminal.

For terminals that speak the kitty graphics protocol: Ghostty, kitty, WezTerm. macOS for now.

```sh
shoji https://example.com
shoji ./report.html --offline
```

## Install

Needs macOS 13+ and a terminal with the kitty graphics protocol (Ghostty, kitty, WezTerm).

From a release (one universal binary for Apple Silicon and Intel):

```sh
gh release download --repo kunalkushwaha/shoji --pattern '*.tar.gz'
tar -xzf shoji-*-macos-universal.tar.gz
install shoji-*/shoji ~/.local/bin/        # or anywhere on your PATH
```

From source (Xcode's Swift; no other dependencies):

```sh
git clone https://github.com/kunalkushwaha/shoji && cd shoji
swift build -c release
ln -s "$PWD/.build/release/shoji" ~/.local/bin/shoji
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

## For agents: `shoji ctl`

Drive a page from the shell — made for coding agents like Claude Code, which can then
read what a page says and look at it:

```sh
shoji ctl open ./index.html          # starts a headless browser on first use, waits for the load
shoji ctl click "#email"             # by CSS selector (or: click <x> <y>)
shoji ctl type "me@example.com"
shoji ctl key Enter
shoji ctl text "#msg"                # the page's (or an element's) text
shoji ctl eval "document.title"      # any JavaScript, result as JSON
shoji ctl screenshot /tmp/page.png   # what's in view, as a PNG
shoji ctl scroll bottom · status · back · wait "#loaded" · quit
```

The headless browser quits after 30 idle minutes. `--name` keeps several apart;
`--offline` (when it starts) blocks everything remote.

## Inside Neovim

`shoji --embed` draws a live page in a Neovim window through unicode placeholders
(the window's buffer holds the placeholder grid; frames reach the terminal through
`nvim_ui_send`). The Neovim side lives in the dotfiles (`Space m w` / `:Shoji`). An
embedded page also answers `shoji ctl --name <buffer's b:shoji>`, so an agent can
read and drive the very page you're looking at.

**Private:** nothing is stored between runs. **`--offline`:** every request that isn't a
local file is blocked by WebKit itself, so local reports and prototypes can't phone home.

## How it works

A `WKWebView` lives in an off-screen window (kept live with WebKit's occlusion check
turned off), is snapshotted when it changes, and each frame is handed to the terminal
as raw pixels through a temp file — no image data goes through the terminal stream. The
image is created once; after that only the rows that changed are written into it in place,
inside a synchronized update, so nothing flickers and typing or hovering sends little.
Mouse reports (SGR with pixel coordinates) and keys become `NSEvent`s for the page.
Measurements behind each choice: [docs/research.md](docs/research.md).

## Status

Early prototype. Not yet: right-click menus, tabs, downloads, WebGL/video capture,
hover inside Neovim, tmux, Linux (WPE WebKit).
