"""How light is shoji? Memory, startup and CPU, next to headless Chrome (the engine
KittyBrowser, awrit and similar tools run on). macOS. Run:

    python3 -I bench/measure.py [path/to/shoji]

Memory is the macOS "footprint" (what Activity Monitor shows), summed over every
process involved: shoji + WebKit's helper processes, or Chrome's whole process tree.
Pages: a tiny page, a real article (Wikipedia), and a local page with JavaScript.
"""
import os, re, shutil, subprocess, sys, tempfile, time, pty, select, fcntl, termios, struct

SHOJI = sys.argv[1] if len(sys.argv) > 1 else shutil.which("shoji") or ".build/release/shoji"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
HERE = os.path.dirname(os.path.abspath(__file__))
PAGES = [
    ("tiny page (example.com)", "https://example.com"),
    ("Wikipedia article", "https://en.wikipedia.org/wiki/Shoji"),
    ("local page with JavaScript", "file://" + os.path.join(HERE, "page.html")),
]

def sh(*a, **kw):
    return subprocess.run(a, capture_output=True, text=True, **kw).stdout

def footprint_mb(pid):
    out = sh("footprint", str(pid))
    m = re.search(r"Footprint:\s*([\d.]+)\s*(KB|MB|GB)", out)
    if not m:
        return 0.0
    v = float(m.group(1))
    return v / 1024 if m.group(2) == "KB" else v * 1024 if m.group(2) == "GB" else v

def webkit_pids():
    return set(int(p) for p in sh("pgrep", "-f", "com.apple.WebKit").split())

def descendants(root):
    rows = [l.split() for l in sh("ps", "-A", "-o", "pid=,ppid=").splitlines()]
    kids, out, todo = {}, [], [root]
    for pid, ppid in ((int(a), int(b)) for a, b in rows):
        kids.setdefault(ppid, []).append(pid)
    while todo:
        p = todo.pop()
        out.append(p)
        todo += kids.get(p, [])
    return out

def cpu_seconds(pids):
    total = 0.0
    for p in pids:
        t = sh("ps", "-o", "time=", "-p", str(p)).strip()
        if not t:
            continue
        parts = [float(x) for x in t.replace("-", ":").split(":")]
        while len(parts) < 3:
            parts.insert(0, 0)
        total += parts[-3] * 3600 + parts[-2] * 60 + parts[-1]
    return total

# --- shoji, headless ---------------------------------------------------------
def measure_shoji(url):
    name = "bench-%d" % os.getpid()
    before = webkit_pids()
    t0 = time.time()
    sh(SHOJI, "ctl", "--name", name, "open", url, timeout=60)
    load = time.time() - t0
    time.sleep(3)                                   # settle
    pid = int(sh("pgrep", "-f", "--", "--headless --name " + name).split()[0])
    helpers = webkit_pids() - before
    mb = footprint_mb(pid) + sum(footprint_mb(p) for p in helpers)
    sh(SHOJI, "ctl", "--name", name, "quit")
    time.sleep(1)
    return mb, load, 1 + len(helpers)

# --- headless Chrome -----------------------------------------------------------
def measure_chrome(url):
    profile = tempfile.mkdtemp(prefix="shoji-bench-chrome-")
    p = subprocess.Popen([CHROME, "--headless=new", "--user-data-dir=" + profile, "--window-size=1280,800",
                          "--no-first-run", "--no-default-browser-check", url],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(8)                                   # load + settle
    pids = descendants(p.pid)
    mb = sum(footprint_mb(x) for x in pids)
    p.terminate()
    try:
        p.wait(10)
    except subprocess.TimeoutExpired:
        p.kill()
    shutil.rmtree(profile, ignore_errors=True)
    return mb, len(pids)

# --- CPU while drawing in a terminal (shoji's own terminal mode, in a pty) -----
def measure_cpu(url, seconds=10):
    before = webkit_pids()
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(SHOJI, ["shoji", url, "--offline"])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 160, 2560, 1530))
    os.kill(pid, 28)
    def drain(t):
        end = time.time() + t
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.05)
            if r:
                try: os.read(fd, 1 << 20)
                except OSError: return
    drain(4)                                        # load, first frames
    pids = [pid] + list(webkit_pids() - before)
    c0, t0 = cpu_seconds(pids), time.time()
    drain(seconds)
    c1, t1 = cpu_seconds(pids), time.time()
    os.write(fd, b"\x11")                           # Ctrl+Q
    drain(1)
    try: os.kill(pid, 9)
    except ProcessLookupError: pass
    return 100 * (c1 - c0) / (t1 - t0)

if __name__ == "__main__":
    print(f"shoji: {SHOJI}\n")
    print("| Page | shoji | headless Chrome | shoji startup → loaded |")
    print("|---|---|---|---|")
    for label, url in PAGES:
        s_mb, load, s_n = measure_shoji(url)
        c_mb, c_n = measure_chrome(url) if os.path.exists(CHROME) else (0, 0)
        print(f"| {label} | **{s_mb:.0f} MB** ({s_n} processes) | {c_mb:.0f} MB ({c_n} processes) | {load:.2f} s |")
    print()
    static = "file://" + os.path.join(HERE, "static.html")
    print(f"CPU, static page, idle in a terminal:      {measure_cpu(static):.1f}% of one core")
    print(f"CPU, animated page, drawing in a terminal: {measure_cpu(PAGES[2][1]):.1f}% of one core")
