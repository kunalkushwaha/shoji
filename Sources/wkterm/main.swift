// wkterm: a WebKit browser drawn in a kitty-graphics terminal (Ghostty, kitty, WezTerm).
//
//   wkterm <url | file> [--offline] [--name N]       browse in this terminal
//   wkterm --headless [url] [--offline] [--name N]    no display: driven by `wkterm ctl`
//   wkterm --embed --image-id ID [--offline] [url]    inside Neovim (JSON lines on stdin/stdout)
//   wkterm ctl [--name N] [--offline] [--json] <command> [args]
//
// Terminal keys: Ctrl+L address · Ctrl+R reload · Ctrl+B back · Ctrl+N forward · Ctrl+Q quit.
// --offline blocks every request that isn't a local file. Nothing is stored.
import AppKit
import WebKit

let argv = Array(CommandLine.arguments.dropFirst())

func flag(_ name: String) -> Bool { argv.contains(name) }
func option(_ name: String) -> String? {
  if let i = argv.firstIndex(of: name), i + 1 < argv.count { return argv[i + 1] }
  if let a = argv.first(where: { $0.hasPrefix(name + "=") }) { return String(a.dropFirst(name.count + 1)) }
  return nil
}
func positional(_ args: [String]) -> [String] {
  var out: [String] = [], skip = false
  for a in args {
    if skip { skip = false; continue }
    if ["--name", "--image-id", "--size", "--idle-exit"].contains(a) { skip = true; continue }
    if a.hasPrefix("--") { continue }
    out.append(a)
  }
  return out
}
func fail(_ s: String) -> Never {
  FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
  exit(1)
}

let name = option("--name") ?? "default"
let offline = flag("--offline")

if argv.first == "ctl" {
  runControlClient(Array(argv.dropFirst()))   // never returns
}

// MARK: browser modes

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)   // no Dock icon, never steals focus
var keep: [AnyObject] = []             // keeps sources and readers alive
var sources: [DispatchSourceProtocol] = []

func compileOfflineRules(_ done: @escaping (WKContentRuleList?) -> Void) {
  guard offline else { return done(nil) }
  // Block everything, then allow local files and inline data.
  let rules = """
  [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
   {"trigger":{"url-filter":"^file:"},"action":{"type":"ignore-previous-rules"}},
   {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
   {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}},
   {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}}]
  """
  WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "wkterm-offline-v1",
                                                          encodedContentRuleList: rules) { list, error in
    guard let list = list else { fail("offline rules failed: \(String(describing: error))") }
    done(list)
  }
}

func onSignals(_ sigs: [Int32], _ handler: @escaping () -> Void) {
  for sig in sigs {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler(handler: handler)
    s.resume()
    sources.append(s)
  }
}

/// Also serve the control socket (agents can drive a visible browser too).
func serveControl(_ c: Controller) {
  let server = ControlServer(path: socketPath(name: name)) { req, reply in c.handle(req, reply) }
  if server.start() { keep.append(server) }
}

let target = positional(argv).first

if flag("--headless") {
  // MARK: headless, for agents
  let size = (option("--size") ?? "1280x800").split(separator: "x").compactMap { Double($0) }
  let scale = Double(NSScreen.main?.backingScaleFactor ?? 2)
  let display = HeadlessDisplay(width: Int((size.first ?? 1280) * scale), height: Int((size.last ?? 800) * scale))
  compileOfflineRules { rules in
    let b = Browser(display: display, offline: offline, rules: rules)
    let c = Controller(browser: b)
    c.headless = display
    keep += [b, c]
    serveControl(c)
    if let t = target { b.load(t) }
    // quit when unused, so an agent's browser doesn't linger in memory
    let idle = Double(option("--idle-exit") ?? "30") ?? 30
    Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
      if Date().timeIntervalSince(c.lastCommand) > idle * 60 { unlink(socketPath(name: name)); exit(0) }
    }
    onSignals([SIGINT, SIGTERM, SIGHUP]) { unlink(socketPath(name: name)); exit(0) }
  }
} else if flag("--embed") {
  // MARK: inside Neovim
  guard let id = option("--image-id").flatMap(Int.init) else { fail("--embed needs --image-id") }
  let display = EmbedDisplay(imageId: id)
  compileOfflineRules { rules in
    let b = Browser(display: display, offline: offline, rules: rules)
    let c = Controller(browser: b)
    c.embed = display
    keep += [b, c]
    let reader = LineReader(fd: 0, onLine: { line in
      guard let req = parseLine(line) else { return }
      c.handle(req) { r in
        var out = r
        if let id = req["id"] { out["id"] = id }
        Output.event(["reply": out])
      }
    }, onClose: {
      Output.event(["ui": display.image.deleteCommand()])
      exit(0)                                   // Neovim closed the job
    })
    keep.append(reader)
    // agents can drive the page you're looking at: wkterm ctl --name <name> …
    if option("--name") != nil { serveControl(c) }
    if let t = target { b.load(t) }
    Output.event(["ready": true])
    onSignals([SIGINT, SIGTERM, SIGHUP]) { exit(0) }
  }
} else {
  // MARK: in this terminal
  guard let term = Terminal() else { fail("wkterm needs a terminal") }
  let display = TerminalDisplay(term: term)
  display.offline = offline
  // test hook: --exit-after=SECONDS quits on its own
  let exitAfter = option("--exit-after").flatMap(Double.init)
  compileOfflineRules { rules in
    term.enter()
    let b = Browser(display: display, offline: offline, rules: rules)
    display.browser = b
    let c = Controller(browser: b)
    keep += [b, c]
    if flag("--control") { serveControl(c) }
    display.drawBar()
    if let t = target { b.load(t) }
    if let s = exitAfter { DispatchQueue.main.asyncAfter(deadline: .now() + s) { display.quit() } }

    var parser = InputParser()
    let input = DispatchSource.makeReadSource(fileDescriptor: term.fd, queue: .main)
    input.setEventHandler {
      var buf = [UInt8](repeating: 0, count: 65536)
      let n = read(term.fd, &buf, buf.count)
      if n <= 0 { return }
      for ev in parser.feed(Array(buf[0..<n])) { display.handle(ev) }
    }
    input.resume()
    sources.append(input)

    signal(SIGWINCH, SIG_IGN)
    let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
    winch.setEventHandler { display.resized() }
    winch.resume()
    sources.append(winch)
    onSignals([SIGINT, SIGTERM, SIGHUP]) { display.quit() }
  }
}
app.run()
