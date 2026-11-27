"""Spike 3: ask the terminal (run inside Ghostty) what it supports, and how fast
frames go through. Writes results to the log file given as argv[1].

Kitty graphics: a=q queries for each transmission medium / format; then timed
a=T transmissions replacing one image id (the browser's frame loop).
Also: DECRQM for SGR mouse (1006) and SGR-Pixels (1016), kitty keyboard (CSI ? u),
cell size (CSI 16 t), window size in pixels (CSI 14 t).
"""
import base64, os, select, sys, termios, time, tty, zlib
from multiprocessing import shared_memory

LOG = open(sys.argv[1], "w")
def log(*a):
    print(*a, file=LOG, flush=True)

fd = os.open("/dev/tty", os.O_RDWR)
old = termios.tcgetattr(fd)
tty.setraw(fd)

def send(s):
    os.write(fd, s if isinstance(s, bytes) else s.encode())

def read_for(timeout):
    out, end = b"", time.time() + timeout
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], max(0, end - time.time()))
        if not r:
            break
        out += os.read(fd, 65536)
    return out

def read_reply(timeout):
    """Read until one graphics reply (ESC _G ... ESC \\) arrives, or timeout."""
    out, end = b"", time.time() + timeout
    while time.time() < end and b"\x1b\\" not in out:
        r, _, _ = select.select([fd], [], [], max(0, end - time.time()))
        if not r:
            break
        out += os.read(fd, 65536)
    return out

def gfx(control, payload=b""):
    return b"\x1b_G" + control.encode() + b";" + payload + b"\x1b\\"

W, H = 64, 48
rgba = bytes([30, 120, 240, 255]) * (W * H)
png = base64.b64decode(  # 1x1 PNG
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")

try:
    # --- capability queries (a=q never displays anything) ---
    queries = {
        "direct PNG (t=d,f=100)": gfx("a=q,i=901,t=d,f=100", base64.b64encode(png)),
        "direct RGBA (t=d,f=32)": gfx(f"a=q,i=902,t=d,f=32,s={W},v={H}", base64.b64encode(rgba)),
        "direct RGBA zlib (o=z)": gfx(f"a=q,i=903,t=d,f=32,o=z,s={W},v={H}", base64.b64encode(zlib.compress(rgba))),
    }
    path = "/tmp/wk-probe-frame.rgba"
    open(path, "wb").write(rgba)
    queries["file (t=f)"] = gfx(f"a=q,i=904,t=f,f=32,s={W},v={H}", base64.b64encode(path.encode()))
    tpath = "/tmp/tty-graphics-protocol-wk-probe.rgba"
    open(tpath, "wb").write(rgba)
    queries["temp file (t=t)"] = gfx(f"a=q,i=905,t=t,f=32,s={W},v={H}", base64.b64encode(tpath.encode()))
    shm = shared_memory.SharedMemory(create=True, size=len(rgba))
    shm.buf[: len(rgba)] = rgba
    name = "/" + shm.name.lstrip("/")
    queries["shared memory (t=s)"] = gfx(f"a=q,i=906,t=s,f=32,s={W},v={H},S={len(rgba)}", base64.b64encode(name.encode()))
    queries["unicode placeholder (U=1)"] = gfx(f"a=q,i=907,t=d,f=32,s={W},v={H},U=1", base64.b64encode(rgba))
    for label, q in queries.items():
        send(q)
        resp = read_for(0.4).decode(errors="replace").replace("\x1b", "ESC")
        log(f"{label:32s} -> {resp or '(no reply)'}")
    try:
        shm.close(); shm.unlink()
    except Exception:
        pass

    # --- terminal modes and sizes ---
    for label, q in [("SGR mouse 1006", "\x1b[?1006$p"), ("SGR-Pixels 1016", "\x1b[?1016$p"),
                     ("any-motion 1003", "\x1b[?1003$p"), ("kitty keyboard", "\x1b[?u"),
                     ("cell size px (16t)", "\x1b[16t"), ("text area px (14t)", "\x1b[14t")]:
        send(q)
        resp = read_for(0.3).decode(errors="replace").replace("\x1b", "ESC")
        log(f"{label:32s} -> {resp or '(no reply)'}")

    # --- frame loop timing: replace image 1 in place, wait for each OK ---
    send("\x1b[2J\x1b[H")
    w, h = 1200, 800
    frames = [bytes([(n * 20) % 255, 100, 255 - (n * 20) % 255, 255]) * (w * h) for n in range(12)]
    for method in ["zlib direct", "temp file", "shared memory"]:
        times = []
        for n, px in enumerate(frames):
            t0 = time.time()
            if method == "zlib direct":
                data = base64.b64encode(zlib.compress(px, 1))
                chunks = [data[i:i + 4096] for i in range(0, len(data), 4096)]
                for i, c in enumerate(chunks):
                    more = 1 if i < len(chunks) - 1 else 0
                    ctl = f"a=T,i=1,p=1,f=32,o=z,s={w},v={h},C=1,m={more}" if i == 0 else f"m={more}"
                    send(gfx(ctl, c))
            elif method == "temp file":
                p = f"/tmp/tty-graphics-protocol-wk-frame{n}.rgba"
                open(p, "wb").write(px)
                send(gfx(f"a=T,i=1,p=1,t=t,f=32,s={w},v={h},C=1", base64.b64encode(p.encode())))
            else:
                m = shared_memory.SharedMemory(create=True, size=len(px))
                m.buf[: len(px)] = px
                nm = "/" + m.name.lstrip("/")
                send(gfx(f"a=T,i=1,p=1,t=s,f=32,s={w},v={h},S={len(px)},C=1", base64.b64encode(nm.encode())))
                m.close()   # the terminal unlinks it after reading
            resp = read_reply(2.0)
            times.append((time.time() - t0) * 1000)
            if b"OK" not in resp:
                log(f"  {method} frame {n}: reply {resp!r}")
        times.sort()
        log(f"1200x800 RGBA via {method:14s} -> median {times[len(times)//2]:6.1f} ms, worst {times[-1]:6.1f} ms per frame")
    send(gfx("a=d,d=A"))
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
    log("done")
