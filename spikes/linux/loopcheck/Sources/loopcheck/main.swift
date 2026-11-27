import CLoop
import Foundation
var events: [String] = []
func note(_ s: String) { events.append(s); print("  \(s)", Thread.isMainThread ? "(main thread)" : "(OTHER THREAD)") }
DispatchQueue.main.async { note("main.async before loop") }
DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { note("main.asyncAfter 0.2 s") }
var fds: [Int32] = [0, 0]; pipe(&fds)
let src = DispatchSource.makeReadSource(fileDescriptor: fds[0], queue: .main)
src.setEventHandler { var b = [UInt8](repeating: 0, count: 8); _ = read(fds[0], &b, 8); note("DispatchSource read on main") }
src.resume()
let timer = DispatchSource.makeTimerSource(queue: .main)
var ticks = 0
timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
timer.setEventHandler { ticks += 1; if ticks == 5 { note("DispatchSource timer ticked 5x") } }
timer.resume()
loop_glib_timeout(100, { _ in
  note("GLib timeout")
  DispatchQueue.global().async { _ = write(fds[1], "x", 1); DispatchQueue.main.async { note("main.async from a background thread") } }
}, nil)
loop_glib_timeout(600, { _ in loop_quit() }, nil)
let t0 = Date()
loop_run()
let want = ["main.async before loop", "GLib timeout", "DispatchSource timer ticked 5x", "DispatchSource read on main", "main.async from a background thread", "main.asyncAfter 0.2 s"]
let ok = Set(want).isSubset(of: Set(events))
print(ok ? "DISPATCH-IN-GLIB OK" : "MISSING: \(Set(want).subtracting(events))", String(format: "(%.2f s)", Date().timeIntervalSince(t0)))
exit(ok ? 0 : 1)
