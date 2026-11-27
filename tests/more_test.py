"""More of shoji's agent commands than agent_test.py covers: typing and keys (also
non-ASCII), scrolling, history, eval, wait, local files, screenshots and --offline.
Run: python3 -I tests/more_test.py [shoji]"""
import http.server, json, os, shutil, struct, subprocess, sys, tempfile, threading, functools, zlib

SHOJI = sys.argv[1] if len(sys.argv) > 1 else shutil.which("shoji")
HERE = os.path.dirname(os.path.abspath(__file__))
NAME = "more-%d" % os.getpid()
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=os.path.join(HERE, "fixtures"))
http.server.SimpleHTTPRequestHandler.log_message = lambda *a: None
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = "http://127.0.0.1:%d/" % srv.server_address[1]

def ctl(*a, raw=False, name=NAME):
    r = subprocess.run([SHOJI, "ctl", "--name", name, *(["--json"] if raw else []), *a], capture_output=True, text=True, timeout=60)
    return json.loads(r.stdout) if raw else (r.stdout + r.stderr).strip()

def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    return struct.unpack(">II", head[16:24]) if head[:8] == b"\x89PNG\r\n\x1a\n" else (0, 0)

def png_pixel(path, x, y):
    """RGBA of one pixel (8-bit RGBA, non-interlaced PNGs, as shoji writes them)."""
    data = open(path, "rb").read()
    w, h = struct.unpack(">II", data[16:24])
    pos, idat = 8, b""
    while pos < len(data):
        n = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        if kind == b"IDAT": idat += data[pos + 8:pos + 8 + n]
        pos += 12 + n
    raw, stride, prev, rows = zlib.decompress(idat), w * 4, bytearray(w * 4), []
    for r in range(y + 1):
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
        prev = line
    return tuple(prev[x * 4:x * 4 + 4])

failures = 0
def check(label, cond, detail=""):
    global failures
    print(("  ok  " if cond else "  FAIL") + "  " + label + ("" if cond else "\n        " + str(detail)[:400]))
    failures += 0 if cond else 1

tmp = tempfile.mkdtemp()
try:
    ctl("open", BASE + "app.html")
    ctl("click", "Full name")
    ctl("type", "Gracx")
    ctl("key", "Backspace")
    ctl("type", "e Hopper")
    v = ctl("eval", "document.querySelector('#fullname').value")
    check("type and Backspace into the focused field", v.strip('"') == "Grace Hopper", v)
    ctl("eval", "document.querySelector('#fullname').value = ''; 1")
    ctl("click", "Full name")
    ctl("type", "日本語 ok")
    v = ctl("eval", "document.querySelector('#fullname').value")
    check("type non-ASCII text (Japanese)", "日本語 ok" in v, v)
    ctl("key", "Tab")
    v = ctl("eval", "document.activeElement && document.activeElement.id")
    check("Tab moves the focus", v.strip('"') == "country", v)

    r = ctl("eval", "new Promise(r => setTimeout(() => r(6 * 7), 50))", raw=True)
    check("eval awaits a promise", r.get("result") == 42, r)
    r = ctl("eval", "nonexistent_thing.x", raw=True)
    check("eval reports exceptions", r.get("ok") is False and "nonexistent_thing" in r.get("error", ""), r)

    ctl("scroll", "top")
    r = ctl("scroll", "400", raw=True)
    check("scroll by pixels moves the page down", 300 <= (r.get("scrollY") or 0) <= 500, r)
    r = ctl("scroll", "bottom", raw=True)
    check("scroll bottom", (r.get("scrollY") or 0) > 1000, r)

    r = ctl("status", raw=True)
    check("status has url, title and viewport", r.get("url", "").endswith("app.html") and r.get("title") and r.get("viewport"), r)

    ctl("eval", "setTimeout(() => { const d = document.createElement('div'); d.id = 'late'; document.body.append(d); }, 500); 1")
    r = ctl("wait", "#late", raw=True)
    check("wait for a selector that appears later", r.get("ok") is True, r)

    # history
    page = os.path.join(tmp, "local page.html")
    with open(page, "w") as f:
        f.write("<title>Local</title><h1 style='background:#ff0000;margin:0;height:200px'>a local file</h1>")
    r = ctl("open", page, raw=True)
    check("open a local file (relative to the shell)", r.get("title") == "Local" and r.get("url", "").startswith("file://"), r)
    r = ctl("back", raw=True)
    check("back", r.get("url", "").endswith("app.html"), r)
    r = ctl("forward", raw=True)
    check("forward", r.get("title") == "Local", r)
    r = ctl("reload", raw=True)
    check("reload", r.get("title") == "Local", r)

    shot = os.path.join(tmp, "view.png")
    r = ctl("screenshot", shot, raw=True)
    w, h = png_size(shot)
    check("screenshot: a PNG of the view", r.get("ok") and (w, h) == (r.get("width"), r.get("height")) and w >= 800, (r, w, h))
    px = png_pixel(shot, 700, 150)       # right of the heading text
    check("screenshot: colours are right (red heading)", px[0] > 240 and px[1] < 20 and px[2] < 20 and px[3] == 255, px)
    retina = os.path.join(tmp, "retina.png")
    ctl("screenshot", retina, "--retina")
    check("screenshot --retina: twice the size", png_size(retina) == (2 * w, 2 * h), (png_size(retina), w, h))

    blank = os.path.join(tmp, "blank.html")
    with open(blank, "w") as f:
        f.write("<title>Links</title><a href='%sapp.html' target='_blank'>new window</a>" % BASE)
    ctl("open", blank)
    ctl("click", "new window")
    r = ctl("status", raw=True)
    check("target=_blank opens in the same view", r.get("url", "").endswith("app.html"), r)
finally:
    ctl("quit")

# --offline: a separate browser started with the rules
OFF = NAME + "-offline"
try:
    page = os.path.join(tmp, "offline.html")
    with open(page, "w") as f:
        f.write("<title>Offline</title><img src='%sfixture.png'><link rel=stylesheet href='%sapp.css'>"
                "<script>fetch('%sdata.json').then(() => document.title = 'leaked', () => document.title = 'blocked')</script>"
                % (BASE, BASE, BASE))
    subprocess.run([SHOJI, "ctl", "--name", OFF, "--offline", "open", page], capture_output=True, text=True, timeout=60)
    t = ctl("eval", "document.title", name=OFF)
    check("--offline: the page loads, its fetch is blocked", t.strip('"') == "blocked", t)
    errs = ctl("errors", name=OFF)
    check("--offline: blocked requests show up in errors", "fixture.png" in errs or "data.json" in errs, errs)
    r = ctl("open", BASE + "app.html", raw=True, name=OFF)
    check("--offline: a remote page doesn't load", r.get("title") != "Account settings", r)
finally:
    ctl("quit", name=OFF)
    srv.shutdown()
    shutil.rmtree(tmp, ignore_errors=True)
print("\n%s" % ("all passed" if failures == 0 else "%d failed" % failures))
sys.exit(1 if failures else 0)
