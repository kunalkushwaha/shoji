// The browser: a live WKWebView in an off-screen window, drawn into the terminal.
import AppKit
import WebKit

/// Borderless windows can't take keyboard focus unless they say so.
/// It also always reports itself visible, key and on a screen: WebKit decides
/// whether to run animation frames and show focus from these (an off-screen
/// window has no screen, and on some macOS versions the display link then never
/// fires). Same approach as Bun.WebView and warpweb.
final class PageWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
  override var isVisible: Bool { true }
  override var isKeyWindow: Bool { true }
  override var screen: NSScreen? { NSScreen.main }
}

/// Debug log, only when WKTERM_LOG=<file> is set.
let debugLog: FileHandle? = {
  guard let p = ProcessInfo.processInfo.environment["WKTERM_LOG"] else { return nil }
  FileManager.default.createFile(atPath: p, contents: nil)
  return FileHandle(forWritingAtPath: p)
}()
private let logStart = Date()
func log(_ s: String) {
  debugLog?.write(String(format: "%7.3f ", Date().timeIntervalSince(logStart)).data(using: .utf8)! + (s + "\n").data(using: .utf8)!)
}

final class Browser: NSObject, WKNavigationDelegate, WKUIDelegate {
  let term: Terminal
  let offline: Bool
  let scale: Double
  let window: PageWindow
  let web: WKWebView
  private var observers: [NSKeyValueObservation] = []

  // frames
  private var lastFrame: [UInt8] = []
  private var capturing = false
  private var activeUntil = Date()          // capture fast until then
  private var lastIdleCheck = Date.distantPast

  // address bar
  private var editing = false
  private var typed = ""

  // mouse state
  private var leftDown = false
  private var lastPress = (time: Date.distantPast, x: 0.0, y: 0.0, count: 0)

  init(term: Terminal, offline: Bool, rules: WKContentRuleList?) {
    self.term = term
    self.offline = offline
    scale = Double(NSScreen.main?.backingScaleFactor ?? 2)
    let size = Browser.pageSize(term, scale: scale)
    window = PageWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                        styleMask: [.borderless], backing: .buffered, defer: false)
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()          // private by default
    if let rules = rules { config.userContentController.add(rules) }
    web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
    super.init()
    web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    web.navigationDelegate = self
    web.uiDelegate = self
    Browser.keepAliveOffScreen(web)
    window.contentView = web
    window.acceptsMouseMovedEvents = true
    window.orderFront(nil)
    window.makeKey()
    window.makeFirstResponder(web)
    observers = [
      web.observe(\.title) { [weak self] _, _ in self?.drawBar() },
      web.observe(\.url) { [weak self] _, _ in self?.drawBar() },
      web.observe(\.isLoading) { [weak self] _, _ in self?.drawBar(); self?.wake() },
    ]
    Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
    log("terminal \(term.cols)x\(term.rows) cells, \(term.pixelWidth)x\(term.pixelHeight) px, cell \(term.cellWidth)x\(term.cellHeight); scale \(scale); page \(size.width)x\(size.height) pt")
  }

  /// WebKit pauses pages whose window can't be seen (no animation frames, slow
  /// timers). Turning off its window-occlusion check keeps the page live while
  /// the window sits off-screen. Private API; without it pages still load and
  /// draw, but animations stall.
  static func keepAliveOffScreen(_ web: WKWebView) {
    setPrivateBool(web, "_setWindowOcclusionDetectionEnabled:", false)
    // and don't let WebKit suppress the "hidden" page's process
    setPrivateBool(web.configuration.preferences, "_setPageVisibilityBasedProcessSuppressionEnabled:", false)
  }

  /// Call a private `-(void)set…:(BOOL)` if this WebKit has it.
  static func setPrivateBool(_ obj: NSObject, _ selector: String, _ value: Bool) {
    let sel = NSSelectorFromString(selector)
    guard obj.responds(to: sel), let m = class_getInstanceMethod(type(of: obj), sel) else {
      log("private API missing: \(selector)")
      return
    }
    typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
    unsafeBitCast(method_getImplementation(m), to: Setter.self)(obj, sel, value)
  }

  /// The page area (all rows but the top bar) in points.
  static func pageSize(_ term: Terminal, scale: Double) -> NSSize {
    let w = Double(term.cols) * term.cellWidth / scale
    let h = Double(term.rows - 1) * term.cellHeight / scale
    return NSSize(width: max(100, w), height: max(100, h))
  }

  func load(_ target: String) {
    var s = target.trimmingCharacters(in: .whitespaces)
    let path = (s as NSString).expandingTildeInPath
    if FileManager.default.fileExists(atPath: path) {
      let url = URL(fileURLWithPath: path).standardizedFileURL
      web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    } else {
      if !s.contains("://") {
        s = s.contains(".") && !s.contains(" ") ? "https://" + s
          : "https://duckduckgo.com/html/?q=" + (s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s)
      }
      if let url = URL(string: s) { web.load(URLRequest(url: url)) }
    }
    wake()
  }

  func resized() {
    term.refreshSize()
    let size = Browser.pageSize(term, scale: scale)
    window.setContentSize(size)
    web.frame = NSRect(origin: .zero, size: size)
    term.write("\u{1b}[2J")
    term.resetFrame()
    lastFrame = []
    drawBar()
    wake()
  }

  // MARK: frames

  /// Capture fast for a while (after input, loads, or when the page changes).
  func wake(for seconds: Double = 0.8) {
    activeUntil = max(activeUntil, Date().addingTimeInterval(seconds))
  }

  private func tick() {
    let now = Date()
    if now < activeUntil || now.timeIntervalSince(lastIdleCheck) > 0.5 {
      lastIdleCheck = now
      capture()
    }
  }

  private func capture() {
    guard !capturing else { return }
    capturing = true
    let cfg = WKSnapshotConfiguration()
    cfg.rect = web.bounds
    web.takeSnapshot(with: cfg) { [weak self] image, _ in
      guard let self = self else { return }
      self.capturing = false
      guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
      let w = cg.width, h = cg.height
      var px = [UInt8](repeating: 0, count: w * h * 4)
      guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
      ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
      let changed = Browser.changedRows(old: self.lastFrame, new: px, width: w, height: h)
      if changed.isEmpty { return }                  // nothing changed: send nothing
      self.lastFrame = px
      let full = px.withUnsafeBytes { self.term.showFrame(rgba: $0, width: w, height: h, changedRows: changed) }
      log(full ? "frame \(w)x\(h) full" : "frame rows \(changed.lowerBound)..<\(changed.upperBound) of \(h)")
      self.wake(for: 0.3)                            // still changing (animation?): keep up
    }
  }

  /// The band of rows that differs between two frames (all rows if sizes differ).
  static func changedRows(old: [UInt8], new: [UInt8], width: Int, height: Int) -> Range<Int> {
    let stride = width * 4
    guard old.count == new.count else { return 0..<height }
    return old.withUnsafeBytes { a in
      new.withUnsafeBytes { b in
        func same(_ r: Int) -> Bool { memcmp(a.baseAddress! + r * stride, b.baseAddress! + r * stride, stride) == 0 }
        var top = 0
        while top < height && same(top) { top += 1 }
        if top == height { return 0..<0 }
        var bottom = height - 1
        while bottom > top && same(bottom) { bottom -= 1 }
        return top..<(bottom + 1)
      }
    }
  }

  // MARK: top bar

  func drawBar() {
    let text: String
    if editing {
      text = " " + typed + "▏"
    } else {
      let title = web.title ?? ""
      let url = web.url?.absoluteString ?? ""
      text = " " + (title.isEmpty ? url : "\(title) — \(url)")
    }
    term.bar(text, editing: editing, loading: web.isLoading, offline: offline)
  }

  // MARK: input

  func handle(_ ev: InputEvent) {
    log("input \(ev)")
    switch ev {
    case .key(let k): key(k)
    case .mouse(let m): mouse(m)
    }
    wake()
  }

  private func key(_ k: Key) {
    if editing {
      switch k {
      case .text(let s): typed += s
      case .backspace: if !typed.isEmpty { typed.removeLast() }
      case .enter: editing = false; load(typed)
      case .escape, .ctrl("l"): editing = false
      default: break
      }
      drawBar()
      return
    }
    switch k {
    case .ctrl("q"): quit()
    case .ctrl("l"): editing = true; typed = web.url?.absoluteString ?? ""; drawBar()
    case .ctrl("r"): web.reload()
    case .ctrl("b"): web.goBack()
    case .ctrl("n"): web.goForward()
    case .text(let s):
      if s.unicodeScalars.allSatisfy({ $0.isASCII }) {
        for ch in s { sendKey(String(ch), code: 0) }
      } else {
        // text from an input method (Japanese etc.): insert it as committed text
        (web as NSView as? NSTextInputClient)?.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0))
      }
    case .enter: sendKey("\r", code: 36)
    case .tab: sendKey("\t", code: 48)
    case .backspace: sendKey("\u{7f}", code: 51)
    case .escape: sendKey("\u{1b}", code: 53)
    case .delete: sendKey(fn(NSDeleteFunctionKey), code: 117)
    case .up: sendKey(fn(NSUpArrowFunctionKey), code: 126)
    case .down: sendKey(fn(NSDownArrowFunctionKey), code: 125)
    case .left: sendKey(fn(NSLeftArrowFunctionKey), code: 123)
    case .right: sendKey(fn(NSRightArrowFunctionKey), code: 124)
    case .home: sendKey(fn(NSHomeFunctionKey), code: 115)
    case .end: sendKey(fn(NSEndFunctionKey), code: 119)
    case .pageUp: sendKey(fn(NSPageUpFunctionKey), code: 116)
    case .pageDown: sendKey(fn(NSPageDownFunctionKey), code: 121)
    case .ctrl: break
    }
  }

  private func fn(_ k: Int) -> String { String(Character(UnicodeScalar(UInt32(k))!)) }

  private func sendKey(_ chars: String, code: UInt16) {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, characters: chars,
                                  charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
        window.sendEvent(e)
      }
    }
  }

  private func mouse(_ m: Mouse) {
    let barHeight = term.cellHeight
    if m.y < barHeight {                                  // the top bar
      if m.kind == .press && m.button == 0 {
        let col = Int(m.x / term.cellWidth)
        switch col {
        case 0...2: web.goBack()
        case 3...5: web.goForward()
        case 6...8: if web.isLoading { web.stopLoading() } else { web.reload() }
        default: editing = true; typed = web.url?.absoluteString ?? ""; drawBar()
        }
      }
      return
    }
    // terminal pixels -> page points (window coordinates have their origin bottom-left)
    let px = m.x / scale, py = (m.y - barHeight) / scale
    let loc = NSPoint(x: px, y: web.bounds.height - py)
    switch m.kind {
    case .wheelUp, .wheelDown:
      let dy: Int32 = m.kind == .wheelUp ? 60 : -60
      if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0),
         let e = NSEvent(cgEvent: cg) {
        web.scrollWheel(with: e)
      }
    case .press where m.button == 0:
      let now = Date()
      let near = abs(lastPress.x - px) < 4 && abs(lastPress.y - py) < 4
      let count = (now.timeIntervalSince(lastPress.time) < 0.35 && near) ? lastPress.count + 1 : 1
      lastPress = (now, px, py, count)
      leftDown = true
      sendMouse(.leftMouseDown, loc, clicks: count)
    case .release where m.button == 0 || leftDown:
      leftDown = false
      sendMouse(.leftMouseUp, loc, clicks: lastPress.count)
    case .motion:
      sendMouse(leftDown ? .leftMouseDragged : .mouseMoved, loc, clicks: 0)
    default:
      break   // right/middle buttons: ignored for now (a context menu would block)
    }
  }

  private func sendMouse(_ type: NSEvent.EventType, _ loc: NSPoint, clicks: Int) {
    if let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                  clickCount: clicks, pressure: type == .leftMouseDown ? 1 : 0) {
      window.sendEvent(e)
    }
  }

  func quit() {
    term.leave()
    exit(0)
  }

  // MARK: WebKit delegates

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    log("loaded \(webView.url?.absoluteString ?? "") \"\(webView.title ?? "")\"")
    drawBar(); wake(for: 1.5)
  }

  /// Links that open a new window (target=_blank, window.open) load here instead.
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
    return nil
  }
}
