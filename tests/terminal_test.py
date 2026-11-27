"""shoji's terminal mode against a fake kitty-graphics terminal (a pty). Checks that
frames arrive and draw the page, inline (as over SSH or from a container) and as temp
files, that a click on the terminal reaches the page, and that later frames send only
the rows that changed. Run: python3 -I tests/terminal_test.py [shoji]"""
import base64, fcntl, socket, functools, http.server, json, os, pty, re, select, shutil, struct, subprocess, sys
import termios, threading, time, zlib

SHOJI = sys.argv[1] if len(sys.argv) > 1 else shutil.which("shoji")
HERE = os.path.dirname(os.path.abspath(__file__))
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=os.path.join(HERE, "fixtures"))
http.server.SimpleHTTPRequestHandler.log_message = lambda *a: None
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = "http://127.0.0.1:%d/" % srv.server_address[1]
ROWS, COLS, CW, CH = 40, 120, 10, 20                 # cells, and pixels per cell

failures = 0
def check(label, cond, detail=""):
    global failures
    print(("  ok  " if cond else "  FAIL") + "  " + label + ("" if cond else "\n        " + str(detail)[:400]))
    failures += 0 if cond else 1

class FakeKitty:
    """Enough of a kitty-graphics terminal: answers the transport probe, keeps image 1's
    pixels from a=T / a=f commands (inline chunks, zlib, or temp files)."""
    def __init__(self, probe_answer, extra_env=None, tty_pixels=True):
        self.probe_answer = probe_answer          # "OK", an error, or None (silent)
        self.tty_pixels = tty_pixels              # False: like `docker run -t`, the tty has no pixel size
        self.name = "term-%d-%s" % (os.getpid(), (probe_answer or "silent")[:2])
        env = dict(os.environ, **(extra_env or {}))
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execve(SHOJI, ["shoji", BASE + "app.html", "--control", "--name", self.name], env)
        px = (COLS * CW, ROWS * CH) if tty_pixels else (0, 0)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, *px))
        self.buf, self.chunks, self.pending_keys = b"", [], None
        self.img, self.w, self.h = None, 0, 0
        self.commands, self.bytes_in = [], 0

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if not r: continue
            try: data = os.read(self.fd, 1 << 20)
            except OSError: return
            self.bytes_in += len(data)
            if b"\x1b[14t" in data:                     # text area size in pixels
                os.write(self.fd, b"\x1b[4;%d;%dt" % (ROWS * CH, COLS * CW))
            self.buf += data
            self.parse()

    def parse(self):
        while True:
            m = re.search(rb"\x1b_G(.*?)\x1b\\", self.buf, re.S)
            if not m: break
            self.buf = self.buf[m.end():]
            body = m.group(1)
            keys, _, payload = body.partition(b";")
            kv = dict(p.split(b"=", 1) for p in keys.split(b",") if b"=" in p)
            self.command({k.decode(): v.decode() for k, v in kv.items()}, payload)
        if len(self.buf) > 1 << 16 and b"\x1b_G" not in self.buf[-(1 << 16):]:
            self.buf = self.buf[-(1 << 16):]

    def command(self, kv, payload):
        if kv.get("a") == "q":
            if self.probe_answer is not None:
                os.write(self.fd, b"\x1b_Gi=" + kv.get("i", "0").encode() + b";" + self.probe_answer.encode() + b"\x1b\\")
            return
        if self.pending_keys is None:
            if kv.get("a") not in ("T", "f"): return       # deletes etc.
            self.pending_keys, self.chunks = kv, []
        self.chunks.append(payload)
        if kv.get("m") == "1": return
        keys, data = self.pending_keys, b"".join(self.chunks)
        self.pending_keys = None
        if keys.get("t") == "t":
            path = base64.b64decode(data).decode()
            with open(path, "rb") as f: px = f.read()
            os.unlink(path)
        else:
            px = base64.b64decode(data)
            if keys.get("o") == "z": px = zlib.decompress(px)
        w, h = int(keys["s"]), int(keys["v"])
        self.commands.append((keys["a"], keys.get("t"), keys.get("o"), int(keys.get("y", 0)), h, len(data)))
        if keys["a"] == "T":
            self.img, self.w, self.h = bytearray(px), w, h
        elif self.img is not None:
            y, stride = int(keys.get("y", 0)), self.w * 4
            self.img[y * stride:(y + h) * stride] = px

    def ctl(self, *a):
        """A ctl command, reading the terminal meanwhile (a real terminal never stops reading;
        if we did, shoji's writes would block once the pty's buffer is full)."""
        p = subprocess.Popen([SHOJI, "ctl", "--name", self.name, "--json", *a], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True)
        end = time.time() + 30
        while p.poll() is None and time.time() < end:
            self.pump(0.05)
        out = p.communicate(timeout=5)[0]
        return json.loads(out) if out.strip() else {}

    def scale(self):
        """Device pixels per CSS pixel: 1 on Linux (unless SHOJI_SCALE), 2 on a Retina Mac."""
        return self.w / self.ctl("eval", "window.innerWidth")["result"]

    def screenshot(self, path, scale):
        """ctl screenshot at a given scale, straight through the control socket."""
        sock = os.path.join(os.environ.get("TMPDIR", "/tmp"), "shoji-%s.sock" % self.name)
        c = socket.socket(socket.AF_UNIX)
        c.connect(sock)
        c.sendall(json.dumps({"cmd": "screenshot", "path": path, "scale": scale}).encode() + b"\n")
        buf = b""
        while not buf.endswith(b"\n"):
            self.pump(0.02)
            c.settimeout(0.05)
            try: buf += c.recv(65536)
            except socket.timeout: pass
        c.close()
        return json.loads(buf)

    def click(self, x, y, scale=1):
        """A left click at page CSS pixels (the page starts one row down)."""
        px, py = int(x * scale), int(y * scale) + CH
        os.write(self.fd, b"\x1b[<0;%d;%dM\x1b[<0;%d;%dm" % (px, py, px, py))

    def quit(self):
        os.write(self.fd, b"\x11")                     # Ctrl+Q
        self.pump(1)
        try: os.kill(self.pid, 9)
        except ProcessLookupError: pass

def rgba_png(path):
    """Decode shoji's PNG (8-bit RGBA, non-interlaced) to raw RGBA."""
    data = open(path, "rb").read()
    w, h = struct.unpack(">II", data[16:24])
    pos, idat = 8, b""
    while pos < len(data):
        n = struct.unpack(">I", data[pos:pos + 4])[0]
        if data[pos + 4:pos + 8] == b"IDAT": idat += data[pos + 8:pos + 8 + n]
        pos += 12 + n
    raw, stride, prev, out = zlib.decompress(idat), w * 4, bytearray(w * 4), bytearray()
    for r in range(h):
        f, line = raw[r * (stride + 1)], bytearray(raw[r * (stride + 1) + 1:(r + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - 4] if i >= 4 else 0
            b, c = prev[i], prev[i - 4] if i >= 4 else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        out += line; prev = line
    return w, h, out

def similar(a, b, step=97):
    """Share of sampled pixels that match (within 8 per channel)."""
    n = same = 0
    for i in range(0, min(len(a), len(b)) - 4, 4 * step):
        n += 1
        same += all(abs(a[i + k] - b[i + k]) <= 8 for k in range(3))
    return same / max(n, 1)

def run(label, probe_answer, expect_transfer, extra_env=None, tty_pixels=True):
    print("\n%s" % label)
    t = FakeKitty(probe_answer, extra_env, tty_pixels)
    try:
        t.pump(6)                                       # load, first frames
        check("a full frame arrived", t.img is not None and t.w == COLS * CW and t.h == (ROWS - 1) * CH,
              (t.w, t.h, t.commands[:3]))
        if t.img is None: return
        first = t.commands[0]
        check("frames go as %s" % expect_transfer,
              (first[1], first[2]) == {"inline": ("d", "z"), "temp files": ("t", None)}[expect_transfer], first)
        sc = t.scale()
        shot = "/tmp/shoji-term-test-%d.png" % os.getpid()
        r = t.screenshot(shot, sc)
        t.pump(1)
        w, h, ref = rgba_png(shot)
        os.unlink(shot)
        check("the terminal's picture is the page (%dx%d)" % (w, h), (w, h) == (t.w, t.h) and similar(t.img, ref) > 0.97,
              ((w, h), (t.w, t.h), similar(t.img, ref) if (w, h) == (t.w, t.h) else None))
        # a click through the terminal's mouse reports
        p = t.ctl("eval", "(() => { const r = document.querySelector('#save').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2] })()")["result"]
        t.ctl("eval", "document.querySelector('#fullname').value = 'Terminal'; 1")
        before = len(t.commands)
        t.click(*p, scale=sc)
        t.pump(2)
        out = t.ctl("text", "#out").get("text", "")
        check("a click in the terminal reaches the page", out.startswith("Saved Terminal"), out)
        later = t.commands[before:]
        check("after the click, only changed rows are sent (a=f)",
              later and all(c[0] == "f" for c in later) and max(c[4] for c in later) < t.h, later[:4])
        r2 = "/tmp/shoji-term-test2-%d.png" % os.getpid()
        t.screenshot(r2, sc)
        t.pump(1)
        _, _, ref2 = rgba_png(r2)
        os.unlink(r2)
        check("the picture follows the page after the click", similar(t.img, ref2) > 0.97, similar(t.img, ref2))
        if expect_transfer == "inline":
            raw = sum(c[4] * t.w * 4 for c in t.commands)
            print("        %d frames, %.1f MB of pixels sent as %.1f MB" % (len(t.commands), raw / 1e6, t.bytes_in / 1e6))
    finally:
        t.quit()

def run_scaled(scale=1.25):
    print("\nSHOJI_SCALE=%s (HiDPI screen)" % scale)
    t = FakeKitty("ENOENT:No such file", {"SHOJI_SCALE": str(scale)})
    try:
        t.pump(6)
        w = t.ctl("eval", "window.innerWidth").get("result")
        check("the page is laid out in CSS pixels (%d / %s)" % (COLS * CW, scale), w == round(COLS * CW / scale), w)
        check("the terminal still gets device pixels", t.w == COLS * CW, t.w)
        p = t.ctl("eval", "(() => { const r = document.querySelector('#save').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2] })()")["result"]
        t.ctl("eval", "document.querySelector('#fullname').value = 'Scaled'; 1")
        # the terminal reports device pixels: CSS pixels times the scale
        px, py = int(p[0] * scale), int(p[1] * scale) + CH
        os.write(t.fd, b"\x1b[<0;%d;%dM\x1b[<0;%d;%dm" % (px, py, px, py))
        t.pump(2)
        out = t.ctl("text", "#out").get("text", "")
        check("a click in device pixels lands on the right element", out.startswith("Saved Scaled"), out)
        t.ctl("scroll", "top")
        r = t.ctl("scroll", "300")
        check("scroll 300 moves 300 CSS pixels", abs((r.get("scrollY") or 0) - 300) <= 2, r)
        r = t.ctl("click", "Save")
        check("ctl click by text (CSS pixels) lands", r.get("ok") and t.ctl("text", "#out").get("text", "").startswith("Saved"), r)
    finally:
        t.quit()

try:
    if sys.platform.startswith("linux"): run_scaled()      # SHOJI_SCALE is Linux-only (macOS uses the screen's)
    run("terminal can't read our files (SSH, container): inline", "ENOENT:No such file or directory", "inline")
    run("terminal reads our files (local): temp files", "OK", "temp files")
    run("terminal doesn't answer the probe: temp files, as before", None, "temp files")
    run("SHOJI_FRAMES=inline", "OK", "inline", {"SHOJI_FRAMES": "inline"})
    run("docker run -t: no pixel size on the tty, asked from the terminal", "ENOENT:No such file", "inline", tty_pixels=False)
finally:
    srv.shutdown()
print("\n%s" % ("all passed" if failures == 0 else "%d failed" % failures))
sys.exit(1 if failures else 0)
