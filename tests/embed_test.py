"""shoji --embed, the Neovim mode, without Neovim: this test plays Neovim's side of the
JSON-lines protocol (docs/neovim.md) and decodes the kitty graphics
commands that Neovim would hand to the terminal through nvim_ui_send.
Run: python3 -I tests/embed_test.py [shoji]"""
import base64, functools, http.server, json, os, queue, shutil, subprocess, sys, threading, time, zlib

SHOJI = sys.argv[1] if len(sys.argv) > 1 else shutil.which("shoji")
HERE = os.path.dirname(os.path.abspath(__file__))
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=os.path.join(HERE, "fixtures"))
http.server.SimpleHTTPRequestHandler.log_message = lambda *a: None
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = "http://127.0.0.1:%d/" % srv.server_address[1]
IMAGE_ID = 0xEE1234                     # the image id is also the placeholder colour
COLS, ROWS, CW, CH = 120, 39, 10, 20    # Neovim window in cells, cell size in pixels

failures = 0
def check(label, cond, detail=""):
    global failures
    print(("  ok  " if cond else "  FAIL") + "  " + label + ("" if cond else "\n        " + str(detail)[:400]))
    failures += 0 if cond else 1


class FakeNeovim:
    """Starts `shoji --embed` as a Neovim plugin would (jobstart) and keeps what it says."""

    def __init__(self, name, extra_env=None):
        self.name = name
        self.p = subprocess.Popen([SHOJI, "--embed", "--image-id", str(IMAGE_ID), "--name", name, BASE + "app.html"],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                  env=dict(os.environ, **(extra_env or {})))
        self.events, self.replies, self.next_id = queue.Queue(), {}, 0
        self.status, self.focus, self.ready = {}, [], False
        self.ui, self.commands = [], []                     # raw ui strings; decoded graphics commands
        self.img, self.w, self.h, self.pending, self.chunks = None, 0, 0, None, []
        self.lock = threading.Lock()
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        for line in self.p.stdout:
            try: ev = json.loads(line)
            except ValueError: continue
            with self.lock:
                if "ui" in ev: self.ui.append(ev["ui"]); self.graphics(ev["ui"])
                elif "status" in ev: self.status = ev["status"]
                elif "focus" in ev: self.focus.append(ev["focus"].get("editable"))
                elif "ready" in ev: self.ready = True
                elif "reply" in ev and "id" in ev["reply"]: self.replies[ev["reply"]["id"]] = ev["reply"]

    def graphics(self, s):
        """The kitty commands in one ui string (APC _G … ESC \\), applied to our copy of the image."""
        pos = 0
        while True:
            a = s.find("\x1b_G", pos)
            if a < 0: return
            b = s.find("\x1b\\", a)
            body, pos = s[a + 3:b], b + 2
            keys, _, payload = body.partition(";")
            kv = dict(p.split("=", 1) for p in keys.split(",") if "=" in p)
            if self.pending is None:
                if kv.get("a") not in ("T", "f"):
                    self.commands.append((kv.get("a"), kv.get("d"), kv.get("i")))
                    continue
                self.pending, self.chunks = kv, []
            self.chunks.append(payload)
            if kv.get("m") == "1": continue
            k, data = self.pending, "".join(self.chunks).encode()
            self.pending = None
            if k.get("t") == "t":
                path = base64.b64decode(data).decode()
                with open(path, "rb") as f: px = f.read()
            else:
                px = base64.b64decode(data)
                if k.get("o") == "z": px = zlib.decompress(px)
            w, h = int(k["s"]), int(k["v"])
            self.commands.append(k)
            if k["a"] == "T":
                self.img, self.w, self.h = bytearray(px), w, h
            elif self.img is not None:
                y, stride = int(k.get("y", 0)), self.w * 4
                self.img[y * stride:(y + h) * stride] = px

    def send(self, msg, wait=True, timeout=30):
        self.next_id += 1
        msg = dict(msg, id=self.next_id)
        self.p.stdin.write((json.dumps(msg) + "\n").encode()); self.p.stdin.flush()
        if not wait: return None
        end = time.time() + timeout
        while time.time() < end:
            with self.lock:
                if msg["id"] in self.replies: return self.replies.pop(msg["id"])
            time.sleep(0.02)
        return {"timeout": msg}

    def until(self, cond, timeout=15):
        end = time.time() + timeout
        while time.time() < end:
            with self.lock:
                if cond(): return True
            time.sleep(0.05)
        return False

    def eval(self, js):
        return self.send({"cmd": "eval", "js": js}).get("result")

    def cell(self, selector, scale):
        """The Neovim cell (col, row) over an element's centre, as a mouse click there would give."""
        x, y = self.eval("(() => { const r = document.querySelector(%s).getBoundingClientRect(); "
                         "return [r.x + r.width / 2, r.y + r.height / 2] })()" % json.dumps(selector))
        return int(x * scale / CW), int(y * scale / CH)

    def close(self):
        """Neovim closes the job's stdin (wk_stop): shoji removes its image and exits."""
        try: self.p.stdin.close()
        except OSError: pass
        try: return self.p.wait(5)
        except subprocess.TimeoutExpired:
            self.p.kill(); return None


def run(label, extra_env=None, inline=False):
    print(label)
    n = FakeNeovim("embed-%d-%d" % (os.getpid(), int(time.time() * 1000) % 100000), extra_env)
    try:
        check("says ready", n.until(lambda: n.ready, 20), "no ready event")
        r = n.send({"cmd": "resize", "cols": COLS, "rows": ROWS, "cellWidth": CW, "cellHeight": CH})
        check("resize to the window's cells", r.get("ok") is True, r)
        check("status events: title and address, loaded",
              n.until(lambda: n.status.get("title") and not n.status.get("loading") and n.status.get("url", "").endswith("app.html")),
              n.status)
        check("a frame arrives", n.until(lambda: n.img is not None, 15), n.commands[:3])
        first = next((c for c in n.commands if isinstance(c, dict) and c.get("a") == "T"), {})
        check("placed with unicode placeholders over the window (U=1, c/r = cells, the given id)",
              first.get("U") == "1" and first.get("i") == str(IMAGE_ID) and first.get("c") == str(COLS)
              and first.get("r") == str(ROWS), first)
        scale = n.w / (n.eval("window.innerWidth") or 1)
        check("the picture fills the window (cols x cell width)", (n.w, n.h) == (COLS * CW, ROWS * CH), (n.w, n.h, scale))
        want = ("d", "z") if inline else ("t", None)
        check("frames go as " + ("inline, zlib" if inline else "temp files"), (first.get("t"), first.get("o")) == want, first)
        # the first frame can come before the page has painted: wait for a painted one
        colours = lambda: len(set(bytes(n.img[i:i + 4]) for i in range(0, len(n.img), 4 * 97)))
        check("the picture is the page (not blank)", n.until(lambda: colours() > 3, 10), colours())

        col, row = n.cell("#fullname", scale)
        n.send({"cmd": "mouse", "kind": "press", "col": col, "row": row})
        n.send({"cmd": "mouse", "kind": "release", "col": col, "row": row})
        check("a click (col/row) on a field reports focus: editable", n.until(lambda: True in n.focus, 5), n.focus)
        before = len(n.commands)
        n.send({"cmd": "type", "text": "Adx"})
        n.send({"cmd": "key", "key": "Backspace"})
        n.send({"cmd": "type", "text": "a 日本"})
        v = n.eval("document.querySelector('#fullname').value")
        check("typing reaches the field (Backspace, non-ASCII)", v == "Ada 日本", v)
        check("typing sends only changed rows (a=f)",
              n.until(lambda: any(isinstance(c, dict) and c.get("a") == "f" and int(c["v"]) < n.h
                                  for c in n.commands[before:]), 5), n.commands[before:before + 3])
        n.send({"cmd": "blur"})
        check("blur reports focus: not editable", n.until(lambda: n.focus and n.focus[-1] is False, 5), n.focus)

        n.send({"cmd": "scroll", "to": "top"})
        r = n.send({"cmd": "scroll", "dy": 400})
        check("scroll by pixels (j/k, Ctrl+D)", 300 <= (r.get("scrollY") or 0) <= 500, r)
        y0 = r.get("scrollY") or 0
        n.send({"cmd": "mouse", "kind": "wheeldown", "col": 10, "row": 10})
        time.sleep(0.4)
        y1 = n.eval("window.scrollY") or 0
        check("the mouse wheel scrolls the page", y1 > y0, (y0, y1))

        n.send({"cmd": "scroll", "to": "top"})
        col, row = n.cell("#save", scale)
        n.send({"cmd": "mouse", "kind": "press", "col": col, "row": row})
        n.send({"cmd": "mouse", "kind": "release", "col": col, "row": row})
        time.sleep(0.3)
        out = n.eval("document.querySelector('#out').textContent")
        check("a click on a button lands", (out or "").startswith("Saved"), out)

        c = subprocess.run([SHOJI, "ctl", "--name", n.name, "--json", "status"], capture_output=True, text=True, timeout=30)
        st = json.loads(c.stdout or "{}")
        check("shoji ctl --name drives the embedded page", st.get("url", "").endswith("app.html"), c.stdout + c.stderr)

        r = n.send({"cmd": "open", "url": BASE + "app.html#again"})
        r = n.send({"cmd": "back"})
        check("history commands (b/f)", r.get("ok") is True, r)
    finally:
        code = n.close()
    deletes = [c for c in n.commands if isinstance(c, tuple) and c[0] == "d" and c[2] == str(IMAGE_ID)]
    check("closing stdin removes the image and exits", code == 0 and deletes, (code, n.commands[-2:]))
    print("        %d frames, %d graphics commands" % (sum(1 for c in n.commands if isinstance(c, dict)), len(n.commands)))


try:
    run("embed (Neovim), temp files")
    run("embed, SHOJI_FRAMES=inline (Neovim over SSH, shoji in a container)", {"SHOJI_FRAMES": "inline"}, inline=True)
    if sys.platform.startswith("linux"):
        run("embed, SHOJI_SCALE=2 (HiDPI)", {"SHOJI_SCALE": "2"})
finally:
    srv.shutdown()
print("\n%s" % ("all passed" if failures == 0 else "%d failed" % failures))
sys.exit(1 if failures else 0)
