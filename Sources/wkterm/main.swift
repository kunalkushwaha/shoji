// wkterm: a WebKit browser drawn in a kitty-graphics terminal (Ghostty, kitty, WezTerm).
//
//   wkterm <url | file> [--offline]
//
// Keys: Ctrl+L address · Ctrl+R reload · Ctrl+B back · Ctrl+N forward · Ctrl+Q quit.
// Mouse: click, drag, hover, wheel. --offline blocks every request that isn't a
// local file. Nothing is stored (private session).
import AppKit
import WebKit

var args = Array(CommandLine.arguments.dropFirst())
let offline = args.contains("--offline")
args.removeAll { $0.hasPrefix("--") }
let target = args.first ?? "about:blank"
// test hook: --exit-after=SECONDS quits on its own
let exitAfter = CommandLine.arguments.first { $0.hasPrefix("--exit-after=") }.flatMap { Double($0.split(separator: "=")[1]) }

guard let term = Terminal() else {
  FileHandle.standardError.write("wkterm needs a terminal\n".data(using: .utf8)!)
  exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)   // no Dock icon, never steals focus

var browser: Browser?
var parser = InputParser()

func start(rules: WKContentRuleList?) {
  term.enter()
  let b = Browser(term: term, offline: offline, rules: rules)
  browser = b
  b.drawBar()
  if target != "about:blank" { b.load(target) }
  if let s = exitAfter { DispatchQueue.main.asyncAfter(deadline: .now() + s) { b.quit() } }

  // terminal input -> page
  let input = DispatchSource.makeReadSource(fileDescriptor: term.fd, queue: .main)
  input.setEventHandler {
    var buf = [UInt8](repeating: 0, count: 65536)
    let n = read(term.fd, &buf, buf.count)
    if n <= 0 { return }
    for ev in parser.feed(Array(buf[0..<n])) { b.handle(ev) }
  }
  input.resume()
  sources.append(input)

  // terminal resized
  signal(SIGWINCH, SIG_IGN)
  let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
  winch.setEventHandler { b.resized() }
  winch.resume()
  sources.append(winch)

  for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler { b.quit() }
    s.resume()
    sources.append(s)
  }
}
var sources: [DispatchSourceProtocol] = []

if offline {
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
    guard let list = list else {
      FileHandle.standardError.write("offline rules failed: \(String(describing: error))\n".data(using: .utf8)!)
      exit(1)
    }
    start(rules: list)
  }
} else {
  start(rules: nil)
}
app.run()
