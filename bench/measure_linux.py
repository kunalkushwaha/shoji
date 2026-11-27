"""How light is shoji on Linux? Memory and startup next to headless Chromium, in the
same container. Run (see docs/performance.md):

    docker build -t shoji . && docker build -t shoji-bench -f bench/Dockerfile.bench .
    docker run --rm shoji-bench

Memory is PSS (proportional set size: shared pages split between the processes that
map them), summed over every process involved: shoji and WebKit's helper processes,
or Chromium's whole process tree. Same pages, same 1280x800 viewport, after the page
has settled.
"""
import json, os, shutil, subprocess, sys, tempfile, time

SHOJI = sys.argv[1] if len(sys.argv) > 1 else shutil.which("shoji")
CHROMIUM = shutil.which("chromium")
HERE = os.path.dirname(os.path.abspath(__file__))
PAGES = [
    ("tiny page (example.com)", "https://example.com"),
    ("Wikipedia article", "https://en.wikipedia.org/wiki/Shoji"),
    ("local page with JavaScript", "file://" + os.path.join(HERE, "page.html")),
]

def sh(*a, **kw):
    return subprocess.run(a, capture_output=True, text=True, **kw).stdout

def mem_mb(pid):
    """(PSS, anonymous PSS) in MB. Anonymous memory is the process's own (heaps, JIT,
    buffers), closest to the macOS "footprint" used on macOS: it leaves out library code."""
    pss = anon = 0.0
    try:
        with open("/proc/%d/smaps_rollup" % pid) as f:
            for line in f:
                if line.startswith("Pss:"):
                    pss = int(line.split()[1]) / 1024
                elif line.startswith("Pss_Anon:"):
                    anon = int(line.split()[1]) / 1024
    except OSError:
        pass
    return pss, anon

def total(pids):
    m = [mem_mb(p) for p in pids]
    return sum(a for a, _ in m), sum(b for _, b in m)

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

def measure_shoji(url):
    name = "bench-%d" % os.getpid()
    t0 = time.time()
    sh(SHOJI, "ctl", "--name", name, "open", url, timeout=60)
    load = time.time() - t0
    time.sleep(3)                                   # settle
    pid = int(sh("pgrep", "-f", "--", "--headless --name " + name).split()[0])
    pids = descendants(pid)
    mb = total(pids)
    sh(SHOJI, "ctl", "--name", name, "quit")
    time.sleep(1)
    return mb, load, len(pids)

def measure_chromium(url):
    profile = tempfile.mkdtemp(prefix="shoji-bench-chromium-")
    # --no-sandbox: as in every container image that runs Chromium (and shoji's WebKit sandbox is off too)
    p = subprocess.Popen([CHROMIUM, "--headless=new", "--no-sandbox", "--user-data-dir=" + profile,
                          "--window-size=1280,800", "--no-first-run", "--no-default-browser-check",
                          "--remote-debugging-port=0", url],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(8)                                   # load + settle
    pids = descendants(p.pid)
    mb = total(pids)
    p.terminate()
    try:
        p.wait(10)
    except subprocess.TimeoutExpired:
        p.kill()
    shutil.rmtree(profile, ignore_errors=True)
    return mb, len(pids)

if __name__ == "__main__":
    print("shoji: %s · %s" % (SHOJI, sh(SHOJI, "--version").strip()))
    print("chromium: %s\n" % (sh(CHROMIUM, "--version").strip() if CHROMIUM else "not installed"))
    print("PSS (all memory, shared pages split) · own memory (anonymous: heaps, JIT, buffers)\n")
    print("| Page | shoji PSS · own | headless Chromium PSS · own | shoji start → loaded |")
    print("|---|---|---|---|")
    for label, url in PAGES:
        (s_pss, s_anon), load, s_n = measure_shoji(url)
        (c_pss, c_anon), c_n = measure_chromium(url) if CHROMIUM else ((0, 0), 0)
        print("| %s | **%.0f MB · %.0f MB** (%d processes) | %.0f MB · %.0f MB (%d processes) | %.2f s |"
              % (label, s_pss, s_anon, s_n, c_pss, c_anon, c_n, load))
