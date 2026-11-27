// `shoji ctl`: drive a browser from the shell (made for coding agents).
//
//   shoji ctl open <url|file>           load, wait, print title and address
//   shoji ctl snapshot [--view] [--text] outline with ids: button "Sign up" [e3]
//                                       (--view: only what's on screen; --text: paragraphs too)
//   shoji ctl click <target>            target: an id from the snapshot (e3), visible text
//                                       ("Sign up"), or a CSS selector (#go); or: click <x> <y>
//   shoji ctl fill <target> <text>      set a text field's value (input/change events fire)
//   shoji ctl select <target> <option>  pick an option of a <select>
//   shoji ctl check|uncheck <target>
//   shoji ctl type <text> · key <Enter|Tab|Escape|…>    into the focused element, as keystrokes
//   shoji ctl text [selector] · html [selector] · eval <js>
//   shoji ctl console [--level error] · errors · network [--failed]   (add --all: earlier pages too)
//   shoji ctl screenshot [file.png] [--full] [--retina]
//   shoji ctl dialog accept [text] | dismiss    how confirm()/prompt() are answered
//   shoji ctl scroll <px|top|bottom> · wait [selector] [--timeout S]
//   shoji ctl status | back | forward | reload | quit
//
// A headless browser is started on first use (one per --name; it quits after
// 30 idle minutes). --offline applies when it's started. --json prints replies raw.
import Foundation

func runControlClient(_ args: [String]) -> Never {
  let rest = positional(args)
  guard let cmd = rest.first else { fail("usage: shoji ctl <open|text|click|type|key|scroll|eval|screenshot|wait|status|…> [args]") }
  let a = Array(rest.dropFirst())
  let raw = args.contains("--json")
  var req: [String: Any] = ["cmd": cmd]

  switch cmd {
  case "open":
    guard let u = a.first else { fail("ctl open <url|file>") }
    // make a relative file path absolute (the browser runs elsewhere)
    let p = (u as NSString).expandingTildeInPath
    req["url"] = FileManager.default.fileExists(atPath: p) && !u.contains("://")
      ? URL(fileURLWithPath: p).standardizedFileURL.absoluteString : u
  case "text", "html":
    if let s = a.first { req["selector"] = s }
  case "click":
    if a.count == 2, let x = Double(a[0]), let y = Double(a[1]) { req["x"] = x; req["y"] = y }
    else if !a.isEmpty { req["target"] = a.joined(separator: " ") }
    else { fail("ctl click <e12 | \"visible text\" | css selector> | <x> <y>") }
  case "snapshot":
    if args.contains("--text") { req["text"] = true }
    if args.contains("--view") { req["view"] = true }
    if let m = option("--max").flatMap(Int.init) { req["max"] = m }
  case "fill", "select":
    guard a.count >= 2 else { fail("ctl \(cmd) <target> <value>") }
    req["target"] = a[0]
    req["value"] = a.dropFirst().joined(separator: " ")
  case "check", "uncheck":
    guard !a.isEmpty else { fail("ctl \(cmd) <target>") }
    req["target"] = a.joined(separator: " ")
  case "console", "errors", "network":
    if args.contains("--all") { req["all"] = true }
    if args.contains("--clear") { req["clear"] = true }
    if args.contains("--failed") { req["failed"] = true }
    if let l = option("--level") { req["level"] = l }
  case "dialog":
    req["action"] = a.first ?? "accept"
    if a.count > 1 { req["text"] = a.dropFirst().joined(separator: " ") }
  case "type":
    guard !a.isEmpty else { fail("ctl type <text>") }
    req["text"] = a.joined(separator: " ")
  case "key":
    guard let k = a.first else { fail("ctl key <name>") }
    req["key"] = k
  case "scroll":
    if let s = a.first {
      if s == "top" || s == "bottom" { req["to"] = s } else if let d = Double(s) { req["dy"] = d }
    }
  case "eval":
    guard !a.isEmpty else { fail("ctl eval <js>") }
    req["js"] = a.joined(separator: " ")
  case "screenshot":
    if let p = a.first { req["path"] = URL(fileURLWithPath: (p as NSString).expandingTildeInPath).path }
    if args.contains("--retina") { req["scale"] = 2.0 }
    if args.contains("--full") { req["full"] = true }
  case "wait":
    if let s = a.first { req["selector"] = s }
    if let t = option("--timeout").flatMap(Double.init) { req["timeout"] = t }
  case "status", "back", "forward", "reload", "stop", "quit", "start":
    break
  default:
    fail("unknown command: \(cmd)")
  }

  let path = socketPath(name: name)
  var fd = connectSocket(path)
  if fd < 0 {
    if cmd == "quit" || cmd == "status" && args.contains("--no-start") { fail("no shoji running (name \(name))") }
    startHeadless()
    let deadline = Date().addingTimeInterval(8)
    while fd < 0 && Date() < deadline { usleep(100_000); fd = connectSocket(path) }
    if fd < 0 { fail("couldn't start a headless shoji") }
  }
  if cmd == "start" { print("running (\(path))"); exit(0) }

  let line = jsonLine(req)
  _ = line.withUnsafeBytes { write(fd, $0.baseAddress, line.count) }
  var buf: [UInt8] = []
  var chunk = [UInt8](repeating: 0, count: 65536)
  while !buf.contains(0x0a) {
    let n = read(fd, &chunk, chunk.count)
    if n <= 0 { break }
    buf += chunk[0..<n]
  }
  close(fd)
  guard let reply = parseLine(String(decoding: buf, as: UTF8.self)) else { fail("no reply") }
  if raw {
    print(String(decoding: buf, as: UTF8.self), terminator: "")
    exit(reply["ok"] as? Bool == false ? 1 : 0)
  }
  if reply["ok"] as? Bool == false { fail("error: \(reply["error"] ?? "unknown")") }

  switch cmd {
  case "text": print(reply["text"] as? String ?? "")
  case "html": print(reply["html"] as? String ?? "")
  case "eval":
    let v = reply["result"] ?? NSNull()
    if let s = v as? String { print(s) }
    else if let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .prettyPrinted, .withoutEscapingSlashes]) {
      print(String(decoding: d, as: UTF8.self))
    }
  case "screenshot": print(reply["path"] as? String ?? "")
  case "click", "check", "uncheck":
    var line = cmd == "click" ? "clicked" : (reply["changed"] as? Bool == false ? "already \(cmd)ed" : "\(cmd)ed")
    if let w = reply["what"] as? String, !w.isEmpty { line += " " + w } else if cmd == "click" { line += " at \(reply["x"] ?? ""),\(reply["y"] ?? "")" }
    if let c = reply["covered"] as? String { line += " (covered by \(c): clicked by script)" }
    print(line)
  case "snapshot":
    let title = reply["title"] as? String ?? "", url = reply["url"] as? String ?? ""
    print("\(title.isEmpty ? "(no title)" : title) — \(url)")
    if let y = reply["scrollY"], let h = reply["pageHeight"] { print("scroll \(y) of \(h)\n") }
    for l in reply["lines"] as? [String] ?? [] { print(l) }
    let shown = (reply["shown"] as? NSNumber)?.intValue ?? 0, total = (reply["total"] as? NSNumber)?.intValue ?? 0
    if total > shown { print("… \(total - shown) more (use --max)") }
    if (reply["lines"] as? [String] ?? []).contains(where: { $0.hasSuffix("↓") || $0.hasSuffix("↑") }) {
      print("(↓ below / ↑ above the view; clicking scrolls to it)")
    }
  case "fill":
    print("filled \(reply["what"] ?? "") = \"\(reply["value"] ?? "")\"")
  case "select":
    print("selected \"\(reply["selected"] ?? "")\" in \(reply["what"] ?? "")")
  case "dialog":
    print("dialogs: \(reply["dialogs"] ?? "")")
  case "console", "errors", "network":
    let entries = reply["entries"] as? [[String: Any]] ?? []
    if entries.isEmpty { print("(none since the page loaded\(args.contains("--all") ? "" : "; --all for earlier pages"))") }
    for e in entries { print(formatEntry(e)) }
  case "open", "back", "forward", "reload", "status", "scroll", "wait":
    if let t = reply["title"] as? String { print(t.isEmpty ? "(no title)" : t) }
    if let u = reply["url"] as? String { print(u) }
    if let y = reply["scrollY"], let h = reply["pageHeight"] { print("scroll \(y) of \(h)") }
    if let e = reply["error"] as? String { print("error: \(e)") }
    if let al = reply["lastAlert"] as? String { print("alert: \(al)") }
    if reply["title"] == nil && reply["url"] == nil { print("ok") }
  default: print("ok")
  }
  exit(0)
}

/// One line per log entry: console output, errors, requests, dialogs.
func formatEntry(_ e: [String: Any]) -> String {
  let t = String(format: "%6.2fs", (e["t"] as? NSNumber)?.doubleValue ?? 0)
  let frame = (e["frame"] as? String).map { "  (in frame \($0))" } ?? ""
  switch e["k"] as? String ?? "" {
  case "console":
    return "\(t) \((e["level"] as? String ?? "info").padding(toLength: 5, withPad: " ", startingAt: 0)) \(e["text"] ?? "")\(frame)"
  case "error":
    var s = "\(t) ERROR \(e["text"] ?? "")\(frame)"
    if let st = e["stack"] as? String, !st.isEmpty { s += "\n" + st.split(separator: "\n").prefix(4).map { "         " + $0 }.joined(separator: "\n") }
    return s
  case "network":
    let url = e["url"] as? String ?? ""
    let type = e["type"] as? String ?? ""
    var extra: [String] = [type]
    if let ms = e["ms"] { extra.append("\(ms) ms") }
    if let sz = e["size"] as? NSNumber, sz.intValue > 0 { extra.append("\(sz.intValue / 1024) KB") }
    if e["failed"] as? Bool == true {
      return "\(t) FAIL  \(url)  (\(type): \(e["error"] ?? "failed"))\(frame)"
    }
    let status = (e["status"] as? NSNumber).map { "\($0)" } ?? "   "
    let method = e["method"] as? String ?? "GET"
    return "\(t) \(method) \(status) \(url)  (\(extra.joined(separator: ", ")))\(frame)"
  case "dialog":
    return "\(t) \(e["type"] ?? "dialog") \"\(e["text"] ?? "")\"" + ((e["answer"] as? String).map { " → \($0)" } ?? "")
  case "navigation":
    return "── page: \(e["url"] ?? "")"
  default:
    return "\(t) \(e)"
  }
}

func connectSocket(_ path: String) -> Int32 {
  let fd = socket(AF_UNIX, sockStream, 0)
  guard fd >= 0, var addr = unixAddress(path) else { return -1 }
  let r = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
  }
  if r != 0 { close(fd); return -1 }
  return fd
}

/// Start `shoji --headless` detached (own session, no terminal), so it outlives
/// this command and the shell that ran it.
func startHeadless() {
  var exe = [CChar](repeating: 0, count: 4096)
  #if os(Linux)
  let n = readlink("/proc/self/exe", &exe, exe.count - 1)
  if n > 0 { exe[n] = 0 }
  var args = [String(cString: exe), "--headless", "--name", name]
  if offline { args.append("--offline") }
  var attr = posix_spawnattr_t()
  posix_spawnattr_init(&attr)
  posix_spawnattr_setflags(&attr, Int16(0x80))          // POSIX_SPAWN_SETSID (glibc 2.26+)
  var actions = posix_spawn_file_actions_t()
  #else
  var size = UInt32(exe.count)
  _NSGetExecutablePath(&exe, &size)
  var args = [String(cString: exe), "--headless", "--name", name]
  if offline { args.append("--offline") }
  var attr = posix_spawnattr_t(bitPattern: 0)
  posix_spawnattr_init(&attr)
  posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
  var actions = posix_spawn_file_actions_t(bitPattern: 0)
  #endif
  posix_spawn_file_actions_init(&actions)
  for fd: Int32 in [0, 1, 2] {
    posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
  }
  var cargs = args.map { strdup($0) } + [nil]
  var pid = pid_t()
  posix_spawn(&pid, cargs[0]!, &actions, &attr, &cargs, environ)
  cargs.forEach { free($0) }
}
