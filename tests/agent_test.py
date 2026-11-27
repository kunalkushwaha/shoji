"""End-to-end test of shoji's agent commands. Run: python3 -I tests/agent_test.py [shoji]"""
import http.server, json, os, shutil, subprocess, sys, threading, functools

SHOJI = sys.argv[1] if len(sys.argv) > 1 else shutil.which("shoji")
HERE = os.path.dirname(os.path.abspath(__file__))
NAME = "test-%d" % os.getpid()
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=os.path.join(HERE, "fixtures"))
http.server.SimpleHTTPRequestHandler.log_message = lambda *a: None
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = "http://127.0.0.1:%d/" % srv.server_address[1]

def ctl(*a, raw=False):
    r = subprocess.run([SHOJI, "ctl", "--name", NAME, *(["--json"] if raw else []), *a], capture_output=True, text=True, timeout=60)
    return json.loads(r.stdout) if raw else (r.stdout + r.stderr).strip()

failures = 0
def check(label, cond, detail=""):
    global failures
    print(("  ok  " if cond else "  FAIL") + "  " + label + ("" if cond else "\n        " + str(detail)[:400]))
    failures += 0 if cond else 1

try:
    ctl("open", BASE + "app.html")
    snap = ctl("snapshot", raw=True)
    lines = snap["lines"]
    print("\n".join("    " + l for l in lines[:14]))
    check("snapshot lists the heading", any(l.startswith('heading "Account settings"') for l in lines), lines)
    check("snapshot names fields by their labels", any(l.startswith('textbox "Full name"') for l in lines), lines)
    check("snapshot shows the select's choice", any('combobox "Country' in l and 'selected="Japan"' in l for l in lines), lines)
    check("snapshot marks things below the view", any(l.startswith('button "Bottom button"') and l.endswith("↓") for l in lines), lines)
    ref = next(l.split("[")[1].split("]")[0] for l in lines if l.startswith('textbox "Full name"'))

    check("fill by id", "Ada" in ctl("fill", ref, "Ada Lovelace"))
    check("select by label text", "India" in ctl("select", "Country", "India"))
    check("check by label text", ctl("check", "Send me news").startswith("checked"))
    check("check again is a no-op", ctl("check", "Send me news").startswith("already"))
    check("fill an editable area", "hello" in ctl("fill", "Bio", "hello there"))
    check("click by visible text", ctl("click", "Save").startswith("clicked"))
    out = ctl("text", "#out")
    check("the page saw all of it", out == "Saved Ada Lovelace / India / news=true / bio=hello there", out)

    r = ctl("click", "Bottom button")
    check("click scrolls an off-screen element into view", ctl("text", "#out") == "bottom clicked", r)
    r = ctl("click", "Accept cookies")
    check("click a real button on an overlay", r.startswith("clicked"), r)

    ctl("click", "#boom")
    errs = ctl("errors")
    print("\n".join("    " + l for l in errs.splitlines()))
    check("errors: uncaught exception with location", "undefined_function_call" in errs and "app.html:" in errs, errs)
    check("errors: console.error", "about to fail" in errs, errs)
    check("errors: unhandled promise rejection", "background job failed" in errs, errs)
    check("errors: 404 request", "404" in errs and "nope.json" in errs, errs)
    check("errors: broken image", "missing.png" in errs, errs)

    cons = ctl("console")
    check("console: log with an object", 'app started {"version":2}' in cons, cons)
    check("console: warning", "warn  deprecated option used" in cons, cons)
    check("console: async log", "data 3" in cons, cons)
    net = ctl("network")
    check("network: page status", "GET 200 " + BASE + "app.html" in net, net)
    check("network: fetch with status and time", "200 " + BASE + "data.json" in net and "fetch" in net, net)
    check("network --failed: only failures", "data.json" not in ctl("network", "--failed"))

    check("confirm accepted by default", ctl("click", "Delete account") and ctl("text", "#out") == "deleted")
    ctl("dialog", "dismiss")
    ctl("click", "Delete account")
    check("dialog dismiss answers Cancel", ctl("text", "#out") == "kept")
    check("dialogs appear in the console log", 'confirm "Really delete?" → Cancel' in ctl("console"))

    path = "/tmp/shoji-test-full.png"
    r = ctl("screenshot", path, "--full", raw=True)
    check("full-page screenshot is taller than the view", r.get("height", 0) > 2000, r)

    check("stale ids are reported", "take a new snapshot" in ctl("click", "e999"))
    check("unknown text is reported", "nothing named" in ctl("click", "No such button"))
finally:
    ctl("quit")
    srv.shutdown()
print("\n%s" % ("all passed" if failures == 0 else "%d failed" % failures))
sys.exit(1 if failures else 0)
