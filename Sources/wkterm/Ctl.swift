// `wkterm ctl`: drive a browser from the shell (made for coding agents).
//
//   wkterm ctl open <url|file>         load, wait, print title and address
//   wkterm ctl text [selector]         the page's (or an element's) text
//   wkterm ctl html [selector]
//   wkterm ctl click <selector>        or: click <x> <y>   (CSS pixels)
//   wkterm ctl type <text>             into the focused element
//   wkterm ctl key <Enter|Tab|Escape|Backspace|Up|Down|PageDown|…>
//   wkterm ctl scroll <px|top|bottom>  (default: one screen down)
//   wkterm ctl eval <js>               value of the last expression, as JSON
//   wkterm ctl screenshot [file.png] [--retina]
//   wkterm ctl wait [selector] [--timeout S]
//   wkterm ctl status | back | forward | reload | quit
//
// A headless browser is started on first use (one per --name; it quits after
// 30 idle minutes). --offline applies when it's started. --json prints replies raw.
import Foundation

func runControlClient(_ args: [String]) -> Never {
  let rest = positional(args)
  guard let cmd = rest.first else { fail("usage: wkterm ctl <open|text|click|type|key|scroll|eval|screenshot|wait|status|…> [args]") }
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
    else if let s = a.first { req["selector"] = s }
    else { fail("ctl click <selector> | <x> <y>") }
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
    if cmd == "quit" || cmd == "status" && args.contains("--no-start") { fail("no wkterm running (name \(name))") }
    startHeadless()
    let deadline = Date().addingTimeInterval(8)
    while fd < 0 && Date() < deadline { usleep(100_000); fd = connectSocket(path) }
    if fd < 0 { fail("couldn't start a headless wkterm") }
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
  case "click":
    let what = [reply["tag"], reply["text"]].compactMap { $0 as? String }.filter { !$0.isEmpty }
    print("clicked" + (what.isEmpty ? " at \(reply["x"] ?? "")," + "\(reply["y"] ?? "")" : " <\(what[0])>" + (what.count > 1 ? " \"\(what[1])\"" : "")))
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

func connectSocket(_ path: String) -> Int32 {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0, var addr = unixAddress(path) else { return -1 }
  let r = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
  }
  if r != 0 { close(fd); return -1 }
  return fd
}

/// Start `wkterm --headless` detached (own session, no terminal), so it outlives
/// this command and the shell that ran it.
func startHeadless() {
  var exe = [CChar](repeating: 0, count: 4096)
  var size = UInt32(exe.count)
  _NSGetExecutablePath(&exe, &size)
  var args = [String(cString: exe), "--headless", "--name", name]
  if offline { args.append("--offline") }
  var attr = posix_spawnattr_t(bitPattern: 0)
  posix_spawnattr_init(&attr)
  posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
  var actions = posix_spawn_file_actions_t(bitPattern: 0)
  posix_spawn_file_actions_init(&actions)
  for fd: Int32 in [0, 1, 2] {
    posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
  }
  var cargs = args.map { strdup($0) } + [nil]
  var pid = pid_t()
  posix_spawn(&pid, cargs[0], &actions, &attr, &cargs, environ)
  cargs.forEach { free($0) }
}
