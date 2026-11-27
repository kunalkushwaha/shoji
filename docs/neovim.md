# shoji inside Neovim (`--embed`)

`shoji --embed` runs a page for an editor: it talks JSON lines on stdin/stdout and
hands back kitty graphics commands for the editor to pass on to the terminal. The page
then shows in a Neovim window through **unicode placeholders**, so it scrolls, splits
and moves with the window like text. You need:

- a terminal with the kitty graphics protocol and unicode placeholders (Ghostty, kitty);
- a Neovim with `nvim_ui_send` (it writes raw escape sequences to the terminal);
- a small Lua plugin that does the editor side, as described below. No ready-made plugin
  is published yet; `tests/embed_test.py` plays the same role and is a working reference.

## Starting it

```sh
shoji --embed --image-id 15597569 --name nvim-1234-5 [--offline] <url or file>
```

- `--image-id`: the kitty image id. Pick one per page and use it as the placeholder
  colour too (below).
- `--name`: the page also answers `shoji ctl --name <name> …`, so an agent can read and
  drive the page you're looking at.
- `--offline`: block every request that isn't a local file (good for opening local HTML).
- `SHOJI_FRAMES=inline` in the environment when the terminal can't read shoji's temp
  files: Neovim over SSH, or shoji in a container.

Closing shoji's stdin makes it remove its image and exit.

## shoji → editor (stdout, one JSON object per line)

| Event | What to do |
|---|---|
| `{"ready": true}` | send the window's size (`resize`, below) |
| `{"ui": "<escape sequences>"}` | pass the string to the terminal: `vim.api.nvim_ui_send(ev.ui)` |
| `{"status": {"title", "url", "loading"}}` | show it (e.g. in the window bar) |
| `{"focus": {"editable": true\|false}}` | a text field gained/lost focus: send typed keys to the page while it's true |
| `{"reply": {…, "id": n}}` | the answer to a command that carried `"id": n` |

## editor → shoji (stdin, one JSON object per line)

```json
{"cmd": "resize", "cols": 120, "rows": 40, "cellWidth": 10, "cellHeight": 20}
{"cmd": "mouse", "kind": "press", "col": 12, "row": 3}
{"cmd": "type", "text": "hello"}
{"cmd": "key", "key": "Enter"}
{"cmd": "scroll", "dy": 80}
{"cmd": "open", "url": "https://example.com", "wait": false}
{"cmd": "blur"}
```

- `resize`: the window in cells, and the cell size in pixels. Send it on `ready` and
  whenever the window changes size.
- `mouse`: `kind` is `press`, `release`, `move` (drag), `wheelup` or `wheeldown`;
  `col`/`row` are 0-based cells inside the window. shoji turns them into page pixels.
- `type` / `key`: text as keystrokes, and named keys (`Enter`, `Tab`, `Backspace`,
  `Escape`, arrows, `Home`, `End`, `PageUp`, `PageDown`, `Space`, or one character).
- `scroll`: `dy` in pixels, `pages` (±1), or `to` = `top` / `bottom`.
- Every `shoji ctl` command works here too (`back`, `forward`, `reload`, `status`,
  `eval`, `snapshot`, …), with the same fields as its control-socket request.

## The window's buffer

Fill the buffer with one placeholder per cell: `U+10EEEE`, then two combining
diacritics for the cell's row and column (the kitty protocol's diacritics table:
`U+0305`, `U+030D`, `U+030E`, … for 0, 1, 2, …). Give the whole grid a highlight whose
foreground colour is the image id (`#EE0001` for id `0xEE0001`). The terminal then draws
the image over exactly those cells. Turn off line numbers, the sign column and wrapping
in that window so the grid isn't shifted.
