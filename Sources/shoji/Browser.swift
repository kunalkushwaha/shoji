// The browser core: a live WKWebView in an off-screen window. It knows nothing
// about terminals; frames go to a Display, input comes in through its API (from
// the terminal UI, from Neovim, or from the control socket).
#if os(macOS)
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

/// Debug log, only when SHOJI_LOG=<file> is set.
let debugLog: FileHandle? = {
  guard let p = ProcessInfo.processInfo.environment["SHOJI_LOG"] else { return nil }
  FileManager.default.createFile(atPath: p, contents: nil)
  return FileHandle(forWritingAtPath: p)
}()
private let logStart = Date()
func log(_ s: String) {
  debugLog?.write(String(format: "%7.3f ", Date().timeIntervalSince(logStart)).data(using: .utf8)! + (s + "\n").data(using: .utf8)!)
}

enum MouseAction { case press, release, move, wheelUp, wheelDown }

final class Browser: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
  let display: Display
  let offline: Bool
  let scale: Double
  let window: PageWindow
  let web: WKWebView
  private var observers: [NSKeyValueObservation] = []
  var onStatus: (() -> Void)?
  var lastActivity = Date()

  // frames
  private var lastFrame: [UInt8] = []
  private var capturing = false
  private var activeUntil = Date()          // capture fast until then
  private var lastIdleCheck = Date.distantPast

  // mouse state
  private var leftDown = false
  private var lastPress = (time: Date.distantPast, x: 0.0, y: 0.0, count: 0)

  init(display: Display, offline: Bool, rules: WKContentRuleList?) {
    self.display = display
    self.offline = offline
    scale = Double(NSScreen.main?.backingScaleFactor ?? 2)
    let size = Browser.pointSize(display.pagePixels, scale: scale)
    window = PageWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                        styleMask: [.borderless], backing: .buffered, defer: false)
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()          // private by default
    if let rules = rules { config.userContentController.add(rules) }
    config.userContentController.addUserScript(WKUserScript(source: pageWorldScript, injectionTime: .atDocumentStart,
                                                            forMainFrameOnly: false, in: .page))
    config.userContentController.addUserScript(WKUserScript(source: helperScript, injectionTime: .atDocumentStart,
                                                            forMainFrameOnly: true, in: Browser.helperWorld))
    web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
    super.init()
    web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    web.navigationDelegate = self
    web.uiDelegate = self
    config.userContentController.add(self, name: "shojiFocus")
    config.userContentController.add(self, name: "shojiWake")
    config.userContentController.add(self, name: "shojiLog")
    Browser.keepAliveOffScreen(web)
    window.contentView = web
    window.acceptsMouseMovedEvents = true
    window.orderFront(nil)
    window.makeKey()
    window.makeFirstResponder(web)
    observers = [
      web.observe(\.title) { [weak self] _, _ in self?.statusChanged() },
      web.observe(\.url) { [weak self] _, _ in self?.statusChanged() },
      web.observe(\.isLoading) { [weak self] _, _ in self?.statusChanged(); self?.wake() },
    ]
    if display.wantsFrames {
      Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
    }
    log("page \(size.width)x\(size.height) pt, scale \(scale)")
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

  static func pointSize(_ px: (width: Int, height: Int), scale: Double) -> NSSize {
    NSSize(width: max(100, Double(px.width) / scale), height: max(100, Double(px.height) / scale))
  }

  private func statusChanged() {
    display.status(title: web.title ?? "", url: web.url?.absoluteString ?? "", loading: web.isLoading)
    onStatus?()
  }

  // MARK: navigation

  func load(_ target: String) {
    var s = target.trimmingCharacters(in: .whitespaces)
    let path = (s as NSString).expandingTildeInPath
    if !s.contains("://"), FileManager.default.fileExists(atPath: path) {
      let url = URL(fileURLWithPath: path).standardizedFileURL
      web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    } else if s.hasPrefix("file://"), let url = URL(string: s) {
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

  /// The display's page area changed size (in device pixels).
  func resized() {
    let size = Browser.pointSize(display.pagePixels, scale: scale)
    window.setContentSize(size)
    web.frame = NSRect(origin: .zero, size: size)
    display.resetFrame()
    lastFrame = []
    wake()
  }

  // MARK: frames

  /// Capture fast for a while (after input, loads, or when the page changes).
  func wake(for seconds: Double = 0.8) {
    lastActivity = Date()
    activeUntil = max(activeUntil, Date().addingTimeInterval(seconds))
  }

  private func tick() {
    let now = Date()
    if now < activeUntil || now.timeIntervalSince(lastIdleCheck) > 2.0 {
      lastIdleCheck = now
      capture()
    }
  }

  private func capture() {
    guard !capturing, display.ready else { return }
    capturing = true
    let cfg = WKSnapshotConfiguration()
    cfg.rect = web.bounds
    web.takeSnapshot(with: cfg) { [weak self] image, _ in
      guard let self = self else { return }
      self.capturing = false
      guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
            var px = Browser.rgba(cg) else { return }
      let w = cg.width, h = cg.height
      let changed = Browser.changedRows(old: self.lastFrame, new: px, width: w, height: h)
      if changed.isEmpty { return }                  // nothing changed: send nothing
      swap(&self.lastFrame, &px)
      let full = self.lastFrame.withUnsafeBytes { self.display.showFrame(rgba: $0, width: w, height: h, changedRows: changed) }
      log(full ? "frame \(w)x\(h) full" : "frame rows \(changed.lowerBound)..<\(changed.upperBound) of \(h)")
      self.activeUntil = max(self.activeUntil, Date().addingTimeInterval(0.3))   // still changing: keep up
    }
  }

  /// Pixels of an image as RGBA bytes.
  static func rgba(_ cg: CGImage) -> [UInt8]? {
    let w = cg.width, h = cg.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return px
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

  // MARK: input (page coordinates are CSS pixels from the top-left of the view)

  func key(_ k: Key) {
    switch k {
    case .text(let s): typeText(s)
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
    wake()
  }

  /// Plain ASCII as key presses; other text (input methods: Japanese etc.) as
  /// committed text, the way an IME delivers it.
  func typeText(_ s: String) {
    if s.unicodeScalars.allSatisfy({ $0.isASCII }) {
      for ch in s {
        if ch == "\n" || ch == "\r" { sendKey("\r", code: 36) } else { sendKey(String(ch), code: 0) }
      }
    } else {
      (web as NSView as? NSTextInputClient)?.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    wake()
  }

  private func fn(_ k: Int) -> String { String(Character(UnicodeScalar(UInt32(k))!)) }

  private func sendKey(_ chars: String, code: UInt16) {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, characters: chars,
                                  charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
        if type == .keyDown { web.keyDown(with: e) } else { web.keyUp(with: e) }
      }
    }
  }

  func mouse(_ action: MouseAction, x: Double, y: Double) {
    let loc = NSPoint(x: x, y: web.bounds.height - y)     // window coordinates: origin bottom-left
    switch action {
    case .wheelUp, .wheelDown:
      scroll(by: action == .wheelUp ? -60 : 60, at: loc)
    case .press:
      let now = Date()
      let near = abs(lastPress.x - x) < 4 && abs(lastPress.y - y) < 4
      let count = (now.timeIntervalSince(lastPress.time) < 0.35 && near) ? lastPress.count + 1 : 1
      lastPress = (now, x, y, count)
      leftDown = true
      sendMouse(.leftMouseDown, loc, clicks: count)
    case .release:
      leftDown = false
      sendMouse(.leftMouseUp, loc, clicks: lastPress.count)
    case .move:
      sendMouse(leftDown ? .leftMouseDragged : .mouseMoved, loc, clicks: 0)
    }
    wake()
  }

  func click(x: Double, y: Double) {
    mouse(.press, x: x, y: y)
    mouse(.release, x: x, y: y)
  }

  /// Scroll by CSS pixels (positive = down), as a real wheel would.
  func scroll(by dy: Double, at point: NSPoint? = nil) {
    let loc = point ?? NSPoint(x: web.bounds.midX, y: web.bounds.midY)
    if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                        wheel1: Int32(-dy.rounded()), wheel2: 0, wheel3: 0) {
      cg.location = CGPoint(x: loc.x, y: loc.y)
      if let e = NSEvent(cgEvent: cg) { web.scrollWheel(with: e) }
    }
    wake()
  }

  /// Mouse events go straight to the web view's handlers (as WebKitTestRunner,
  /// Bun and warpweb do): through the window, AppKit treats a click on an
  /// inactive window as "activate the window" and the page never sees it.
  private func sendMouse(_ type: NSEvent.EventType, _ loc: NSPoint, clicks: Int) {
    guard let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                     clickCount: clicks, pressure: type == .leftMouseDown ? 1 : 0) else { return }
    switch type {
    case .leftMouseDown: web.mouseDown(with: e)
    case .leftMouseUp: web.mouseUp(with: e)
    case .leftMouseDragged: web.mouseDragged(with: e)
    default: web.mouseMoved(with: e)
    }
  }

  // MARK: reading the page

  func eval(_ js: String, _ done: @escaping (Any?, String?) -> Void) {
    web.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
      switch result {
      case .success(let v): done(v, nil)
      case .failure(let e): done(nil, (e as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? e.localizedDescription)
      }
    }
  }

  /// A PNG of the whole page: the view is made as tall as the page (up to 16000
  /// CSS pixels) for the picture, then put back.
  func screenshotFull(to path: String, scale outScale: Double, _ done: @escaping ([String: Any]) -> Void) {
    eval("return [document.documentElement.scrollHeight, window.scrollY]") { v, _ in
      let a = v as? [Any] ?? []
      let height = min(16000, max(self.web.bounds.height, (a.first as? NSNumber)?.doubleValue ?? 0))
      let scroll = (a.count > 1 ? a[1] as? NSNumber : nil)?.doubleValue ?? 0
      let saved = self.web.frame
      self.window.setContentSize(NSSize(width: saved.width, height: height))
      self.web.frame = NSRect(x: 0, y: 0, width: saved.width, height: height)
      self.eval("window.scrollTo(0, 0); return 0") { _, _ in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
          self.screenshot(to: path, scale: outScale) { result in
            self.window.setContentSize(saved.size)
            self.web.frame = saved
            self.eval("window.scrollTo(0, \(scroll)); return 0") { _, _ in }
            self.display.resetFrame()
            self.wake()
            done(result)
          }
        }
      }
    }
  }

  /// A PNG of what's in view. scale 1 = CSS pixels (smaller files), 2 = Retina.
  func screenshot(to path: String, scale outScale: Double, _ done: @escaping ([String: Any]) -> Void) {
    let cfg = WKSnapshotConfiguration()
    cfg.rect = web.bounds
    web.takeSnapshot(with: cfg) { image, error in
      guard let image = image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return done(["ok": false, "error": "snapshot failed: \(String(describing: error))"])
      }
      let w = Int(self.web.bounds.width * outScale), h = Int(self.web.bounds.height * outScale)
      guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        return done(["ok": false, "error": "no bitmap"])
      }
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
      NSGraphicsContext.current?.imageInterpolation = .high
      NSGraphicsContext.current?.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
      NSGraphicsContext.restoreGraphicsState()
      guard let png = rep.representation(using: .png, properties: [:]) else {
        return done(["ok": false, "error": "PNG encoding failed"])
      }
      do {
        try png.write(to: URL(fileURLWithPath: path))
        done(["ok": true, "path": path, "width": w, "height": h])
      } catch {
        done(["ok": false, "error": "\(error)"])
      }
    }
  }

  // MARK: WebKit delegates

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    if message.name == "shojiWake" { wake(for: 0.5); return }
    if message.name == "shojiLog", var entry = message.body as? [String: Any] {
      if !message.frameInfo.isMainFrame { entry["frame"] = message.frameInfo.request.url?.absoluteString ?? "frame" }
      record(entry)
      return
    }
    if message.name == "shojiFocus", let editable = message.body as? Bool {
      log("focus editable=\(editable)")
      display.focusChanged(editable: editable)
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    log("loaded \(webView.url?.absoluteString ?? "") \"\(webView.title ?? "")\"")
    statusChanged()
    wake(for: 1.5)
  }

  /// A new page: forget the previous one's error and alert; mark it in the log.
  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    lastError = nil
    lastDialog = nil
    record(["k": "navigation", "url": webView.url?.absoluteString ?? ""])
    if let st = pendingStatus { record(["k": "network", "type": "document", "url": st.url, "status": st.status]); pendingStatus = nil }
  }

  /// The page's own HTTP status (for the network log).
  func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
               decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    if navigationResponse.isForMainFrame, let r = navigationResponse.response as? HTTPURLResponse {
      pendingStatus = (r.url?.absoluteString ?? "", r.statusCode)
    }
    decisionHandler(.allow)
  }
  private var pendingStatus: (url: String, status: Int)?

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    lastError = error.localizedDescription
    statusChanged()
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    lastError = error.localizedDescription
    record(["k": "network", "type": "document", "url": (error as NSError).userInfo[NSURLErrorFailingURLStringErrorKey] as? String ?? "",
            "failed": true, "error": error.localizedDescription])
    statusChanged()
  }
  var lastError: String?

  /// Links that open a new window (target=_blank, window.open) load here instead.
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
    return nil
  }

  /// JavaScript alert(): there's no dialog to show, so note it and carry on.
  func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
    log("alert: \(message)")
    lastDialog = message
    record(["k": "dialog", "type": "alert", "text": message])
    completionHandler()
  }
  var lastDialog: String?

  /// confirm() and prompt(): answered by the dialog policy (accept by default;
  /// `shoji ctl dialog dismiss` / `dialog accept <text>` changes it).
  var dialogAccept = true
  var dialogText: String?

  func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
    lastDialog = message
    record(["k": "dialog", "type": "confirm", "text": message, "answer": dialogAccept ? "OK" : "Cancel"])
    completionHandler(dialogAccept)
  }

  func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
    lastDialog = prompt
    let answer = dialogAccept ? (dialogText ?? defaultText ?? "") : nil
    record(["k": "dialog", "type": "prompt", "text": prompt, "answer": answer ?? "(cancelled)"])
    completionHandler(answer)
  }

  // MARK: page log (console, errors, network, dialogs) for agents

  static let helperWorld = WKContentWorld.world(name: "shoji")
  private(set) var pageLog: [[String: Any]] = []
  private var logStart = Date()

  func record(_ entry: [String: Any]) {
    var e = entry
    e["t"] = (Date().timeIntervalSince(logStart) * 1000).rounded() / 1000
    pageLog.append(e)
    if pageLog.count > 1000 { pageLog.removeFirst(pageLog.count - 1000) }
  }

  /// Entries since the current page started (or all of them).
  func logEntries(all: Bool) -> [[String: Any]] {
    if all { return pageLog }
    guard let i = pageLog.lastIndex(where: { $0["k"] as? String == "navigation" }) else { return pageLog }
    return Array(pageLog[(i + 1)...])
  }

  /// Run JavaScript in shoji's isolated world (the outline and actions live there).
  func evalHelper(_ js: String, _ args: [String: Any] = [:], _ done: @escaping (Any?, String?) -> Void) {
    web.callAsyncJavaScript(js, arguments: args, in: nil, in: Browser.helperWorld) { result in
      switch result {
      case .success(let v): done(v, nil)
      case .failure(let e): done(nil, (e as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? e.localizedDescription)
      }
    }
  }
}

/// zlib (RFC 1950) for inline terminal frames. Apple's .zlib is raw DEFLATE (RFC 1951),
/// so this adds zlib's 2-byte header and Adler-32 trailer, as kitty's o=z expects.
func zlibCompress(_ d: Data) -> Data? {
  guard let raw = try? (d as NSData).compressed(using: .zlib) as Data else { return nil }
  var a: UInt32 = 1, b: UInt32 = 0
  d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
    var i = 0
    while i < p.count {                                  // blocks of 5552 keep the sums in 32 bits
      let end = min(i + 5552, p.count)
      while i < end { a &+= UInt32(p[i]); b &+= a; i += 1 }
      a %= 65521; b %= 65521
    }
  }
  var out = Data([0x78, 0x5e])                           // deflate, 32K window, default level
  out.reserveCapacity(raw.count + 6)
  out.append(raw)
  let adler = (b << 16) | a
  out.append(contentsOf: [UInt8(adler >> 24), UInt8(adler >> 16 & 0xff), UInt8(adler >> 8 & 0xff), UInt8(adler & 0xff)])
  return out
}

#endif
