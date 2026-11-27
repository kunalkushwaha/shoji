// Commands: one JSON object per line, one JSON reply per line. Used by Neovim
// (over the job's stdin/stdout) and by agents (over a Unix socket, through
// `wkterm ctl`). See README for the command list.
import AppKit
import WebKit

typealias Reply = ([String: Any]) -> Void

final class Controller {
  let browser: Browser
  weak var embed: EmbedDisplay?
  weak var headless: HeadlessDisplay?
  var lastCommand = Date()

  init(browser: Browser) { self.browser = browser }

  func handle(_ req: [String: Any], _ reply: @escaping Reply) {
    lastCommand = Date()
    let cmd = req["cmd"] as? String ?? ""
    let b = browser
    log("cmd \(req)")
    switch cmd {
    case "open":
      guard let url = req["url"] as? String else { return reply(err("open needs url")) }
      b.lastError = nil
      b.load(url)
      afterNavigation(req, reply)
    case "back": b.web.goBack(); afterNavigation(req, reply)
    case "forward": b.web.goForward(); afterNavigation(req, reply)
    case "reload": b.web.reload(); afterNavigation(req, reply)
    case "stop": b.web.stopLoading(); reply(["ok": true])
    case "status": status(reply)
    case "text":
      let sel = req["selector"] as? String
      evalJS(sel == nil ? "return document.body ? document.body.innerText : ''"
                        : "const e = document.querySelector(\(jsString(sel!))); return e ? e.innerText : null", reply) { v in
        guard let s = v as? String else { return err("no element matches \(sel ?? "")") }
        return ["ok": true, "text": s]
      }
    case "html":
      let sel = req["selector"] as? String
      evalJS(sel == nil ? "return document.documentElement.outerHTML"
                        : "const e = document.querySelector(\(jsString(sel!))); return e ? e.outerHTML : null", reply) { v in
        guard let s = v as? String else { return err("no element matches \(sel ?? "")") }
        return ["ok": true, "html": s]
      }
    case "eval":
      guard let js = req["js"] as? String else { return reply(err("eval needs js")) }
      // the last expression's value, awaiting promises
      evalJS("return await eval(\(jsString(js)))", reply) { v in ["ok": true, "result": jsonSafe(v)] }
    case "click":
      if let sel = req["selector"] as? String {
        let js = """
        const e = document.querySelector(\(jsString(sel)));
        if (!e) return null;
        e.scrollIntoView({block: 'center', inline: 'center'});
        const r = e.getBoundingClientRect();
        return {x: r.left + r.width / 2, y: r.top + r.height / 2, tag: e.tagName.toLowerCase(),
                text: (e.innerText || e.value || '').trim().slice(0, 80)};
        """
        b.eval(js) { v, e in
          guard let o = v as? [String: Any], let x = o["x"] as? Double, let y = o["y"] as? Double else {
            return reply(err(e ?? "no element matches \(sel)"))
          }
          b.click(x: x, y: y)
          self.settle(req) { reply(["ok": true, "x": x, "y": y, "tag": o["tag"] ?? "", "text": o["text"] ?? ""]) }
        }
      } else if let p = point(req) {
        b.click(x: p.x, y: p.y)
        settle(req) { reply(["ok": true, "x": p.x, "y": p.y]) }
      } else {
        reply(err("click needs a selector or x/y"))
      }
    case "mouse":
      guard let p = point(req) else { return reply(err("mouse needs x/y or col/row")) }
      let kinds: [String: MouseAction] = ["press": .press, "release": .release, "move": .move,
                                          "wheelup": .wheelUp, "wheeldown": .wheelDown]
      guard let a = kinds[(req["kind"] as? String ?? "").lowercased()] else { return reply(err("unknown mouse kind")) }
      b.mouse(a, x: p.x, y: p.y)
      reply(["ok": true])
    case "scroll":
      if let to = req["to"] as? String {
        evalJS("window.scrollTo(0, \(to == "top" ? "0" : "document.documentElement.scrollHeight")); return window.scrollY", reply) { v in
          ["ok": true, "scrollY": v ?? 0]
        }
        b.wake()
      } else {
        let pages = req["pages"] as? Double
        let dy = req["dy"] as? Double ?? (pages.map { $0 * b.web.bounds.height * 0.9 } ?? b.web.bounds.height * 0.9)
        b.scroll(by: dy)
        settle(req, 0.25) { self.status(reply) }
      }
    case "type":
      guard let text = req["text"] as? String else { return reply(err("type needs text")) }
      b.typeText(text)
      settle(req) { reply(["ok": true]) }
    case "key":
      guard let k = keyNamed(req["key"] as? String ?? "") else { return reply(err("unknown key \(req["key"] ?? "")")) }
      b.key(k)
      settle(req) { reply(["ok": true]) }
    case "resize":
      if let e = embed {
        e.cols = req["cols"] as? Int ?? e.cols
        e.rows = req["rows"] as? Int ?? e.rows
        e.cellWidth = req["cellWidth"] as? Double ?? e.cellWidth
        e.cellHeight = req["cellHeight"] as? Double ?? e.cellHeight
      } else if let h = headless, let w = req["width"] as? Double, let ht = req["height"] as? Double {
        h.size = (Int(w * b.scale), Int(ht * b.scale))
      }
      b.resized()
      reply(["ok": true, "width": b.web.bounds.width, "height": b.web.bounds.height])
    case "screenshot":
      let path = req["path"] as? String ?? (NSTemporaryDirectory() + "wkterm-\(Int(Date().timeIntervalSince1970)).png")
      b.screenshot(to: path, scale: req["scale"] as? Double ?? 1, reply)
    case "wait":
      let timeout = req["timeout"] as? Double ?? 10
      if let sel = req["selector"] as? String {
        waitFor(selector: sel, until: Date().addingTimeInterval(timeout), reply)
      } else {
        waitForLoad(until: Date().addingTimeInterval(timeout)) { ok in
          ok ? self.status(reply) : reply(err("timed out waiting for the page to load"))
        }
      }
    case "quit":
      reply(["ok": true])
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { exit(0) }
    default:
      reply(err("unknown command \(cmd)"))
    }
  }

  // MARK: helpers

  /// A page position from x/y (CSS pixels) or col/row (Neovim cells).
  private func point(_ req: [String: Any]) -> (x: Double, y: Double)? {
    if let x = req["x"] as? Double, let y = req["y"] as? Double { return (x, y) }
    if let c = req["col"] as? Double, let r = req["row"] as? Double, let e = embed {
      return ((c + 0.5) * e.cellWidth / browser.scale, (r + 0.5) * e.cellHeight / browser.scale)
    }
    return nil
  }

  private func evalJS(_ js: String, _ reply: @escaping Reply, _ map: @escaping (Any?) -> [String: Any]) {
    browser.eval(js) { v, e in reply(e != nil ? err(e!) : map(v)) }
  }

  func status(_ reply: @escaping Reply) {
    let b = browser
    b.eval("return [window.scrollY, document.documentElement.scrollHeight, window.innerWidth, window.innerHeight]") { v, _ in
      let a = v as? [Any] ?? []
      var out: [String: Any] = ["ok": true, "url": b.web.url?.absoluteString ?? "", "title": b.web.title ?? "",
                                "loading": b.web.isLoading, "canGoBack": b.web.canGoBack, "canGoForward": b.web.canGoForward]
      if a.count == 4 { out["scrollY"] = a[0]; out["pageHeight"] = a[1]; out["viewport"] = [a[2], a[3]] }
      if let e = b.lastError { out["error"] = e }
      if let d = b.lastDialog { out["lastAlert"] = d }
      reply(out)
    }
  }

  /// After open/back/forward/reload: wait for the page (unless "wait": false).
  private func afterNavigation(_ req: [String: Any], _ reply: @escaping Reply) {
    if req["wait"] as? Bool == false { return reply(["ok": true]) }
    // give WebKit a moment to start loading before checking isLoading
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      self.waitForLoad(until: Date().addingTimeInterval(req["timeout"] as? Double ?? 20)) { ok in
        ok ? self.status(reply) : reply(err("timed out loading"))
      }
    }
  }

  private func waitForLoad(until deadline: Date, _ done: @escaping (Bool) -> Void) {
    if !browser.web.isLoading {
      // let scripts and first paint settle
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done(true) }
    } else if Date() > deadline {
      done(false)
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.waitForLoad(until: deadline, done) }
    }
  }

  private func waitFor(selector: String, until deadline: Date, _ reply: @escaping Reply) {
    browser.eval("return !!document.querySelector(\(jsString(selector)))") { v, _ in
      if v as? Bool == true { return reply(["ok": true]) }
      if Date() > deadline { return reply(err("timed out waiting for \(selector)")) }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.waitFor(selector: selector, until: deadline, reply) }
    }
  }

  /// Let the page react (and a navigation start) before replying.
  private func settle(_ req: [String: Any], _ seconds: Double = 0.2, _ then: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
      if self.browser.web.isLoading {
        self.waitForLoad(until: Date().addingTimeInterval(20)) { _ in then() }
      } else {
        then()
      }
    }
  }
}

func err(_ s: String) -> [String: Any] { ["ok": false, "error": s] }

func keyNamed(_ name: String) -> Key? {
  switch name.lowercased() {
  case "enter", "return": return .enter
  case "tab": return .tab
  case "backspace": return .backspace
  case "escape", "esc": return .escape
  case "delete": return .delete
  case "up", "arrowup": return .up
  case "down", "arrowdown": return .down
  case "left", "arrowleft": return .left
  case "right", "arrowright": return .right
  case "home": return .home
  case "end": return .end
  case "pageup": return .pageUp
  case "pagedown": return .pageDown
  default: return nil
  }
}

/// A JavaScript string literal.
func jsString(_ s: String) -> String {
  let data = try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed])
  let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
  return String(arr.dropFirst().dropLast())
}

/// JavaScript results as JSON-safe values.
func jsonSafe(_ v: Any?) -> Any {
  guard let v = v else { return NSNull() }
  if v is NSNull || v is String || v is NSNumber { return v }
  if let a = v as? [Any] { return a.map { jsonSafe($0) } }
  if let d = v as? [String: Any] { return d.mapValues { jsonSafe($0) } }
  return "\(v)"
}

// MARK: line transport

/// Reads JSON lines from a file descriptor (Neovim's stdin, or a socket).
final class LineReader {
  private var buffer: [UInt8] = []
  private let source: DispatchSourceRead
  init(fd: Int32, onLine: @escaping (String) -> Void, onClose: @escaping () -> Void) {
    source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
    source.setEventHandler { [unowned self] in
      var chunk = [UInt8](repeating: 0, count: 65536)
      let n = read(fd, &chunk, chunk.count)
      if n <= 0 { self.source.cancel(); onClose(); return }
      self.buffer += chunk[0..<n]
      while let nl = self.buffer.firstIndex(of: 0x0a) {
        let line = String(decoding: self.buffer[..<nl], as: UTF8.self)
        self.buffer.removeSubrange(...nl)
        if !line.trimmingCharacters(in: .whitespaces).isEmpty { onLine(line) }
      }
    }
    source.resume()
  }
}

func parseLine(_ line: String) -> [String: Any]? {
  (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
}

func jsonLine(_ obj: [String: Any]) -> Data {
  var d = (try? JSONSerialization.data(withJSONObject: jsonSafe(obj), options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
  d.append(0x0a)
  return d
}

/// The control socket: a Unix socket only this user can open.
final class ControlServer {
  let path: String
  private var listenSource: DispatchSourceRead?
  private var readers: [Int32: LineReader] = [:]
  let handler: ([String: Any], @escaping Reply) -> Void

  init(path: String, handler: @escaping ([String: Any], @escaping Reply) -> Void) {
    self.path = path
    self.handler = handler
  }

  func start() -> Bool {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0, var addr = unixAddress(path) else { return false }
    let ok = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard ok == 0, listen(fd, 16) == 0 else { close(fd); return false }
    chmod(path, 0o600)
    let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
    src.setEventHandler { [unowned self] in
      let c = accept(fd, nil, nil)
      guard c >= 0 else { return }
      self.readers[c] = LineReader(fd: c, onLine: { line in
        guard let req = parseLine(line) else {
          let d = jsonLine(["ok": false, "error": "not JSON"]); _ = d.withUnsafeBytes { write(c, $0.baseAddress, d.count) }
          return
        }
        self.handler(req) { r in
          let d = jsonLine(r)
          _ = d.withUnsafeBytes { write(c, $0.baseAddress, d.count) }
        }
      }, onClose: { [unowned self] in
        close(c)
        self.readers[c] = nil
      })
    }
    src.resume()
    listenSource = src
    return true
  }
}

func unixAddress(_ path: String) -> sockaddr_un? {
  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8)
  guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
  withUnsafeMutableBytes(of: &addr.sun_path) { buf in
    for (i, b) in bytes.enumerated() { buf[i] = b }
    buf[bytes.count] = 0
  }
  return addr
}

func socketPath(name: String) -> String {
  NSTemporaryDirectory() + "wkterm-\(name).sock"
}
