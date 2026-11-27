// The browser core on Linux: WPE WebKit on a headless display, through the C engine
// in Sources/CShojiWPE. Same API as the macOS Browser (Browser.swift), so Controller,
// the displays and the terminal UI work on both.
#if os(Linux)
import CShojiWPE
import Foundation

/// Debug log, only when SHOJI_LOG=<file> is set.
let debugLog: FileHandle? = {
  guard let p = ProcessInfo.processInfo.environment["SHOJI_LOG"] else { return nil }
  FileManager.default.createFile(atPath: p, contents: nil)
  return FileHandle(forWritingAtPath: p)
}()
private let logStart = Date()
func log(_ s: String) {
  debugLog?.write(Data((String(format: "%7.3f ", Date().timeIntervalSince(logStart)) + s + "\n").utf8))
}

enum MouseAction { case press, release, move, wheelUp, wheelDown }

/// The view's size in CSS pixels.
struct Bounds {
  var width: Double, height: Double
  var midX: Double { width / 2 }
  var midY: Double { height / 2 }
}

/// What the macOS code reaches as `browser.web` (a WKWebView there).
final class WebView {
  fileprivate var engine: OpaquePointer!
  var url: URL? { shoji_engine_uri(engine).flatMap { URL(string: String(cString: $0)) } }
  var title: String? { shoji_engine_title(engine).map { String(cString: $0) } }
  var isLoading: Bool { shoji_engine_is_loading(engine) != 0 }
  var canGoBack: Bool { shoji_engine_can_go_back(engine) != 0 }
  var canGoForward: Bool { shoji_engine_can_go_forward(engine) != 0 }
  var bounds: Bounds { Bounds(width: Double(shoji_engine_width(engine)), height: Double(shoji_engine_height(engine))) }
  func goBack() { shoji_engine_go_back(engine) }
  func goForward() { shoji_engine_go_forward(engine) }
  func reload() { shoji_engine_reload(engine) }
  func stopLoading() { shoji_engine_stop(engine) }
}

/// Holds a Swift value for a C callback's context pointer.
private final class Box<T> { let value: T; init(_ v: T) { value = v } }
private func retained<T>(_ v: T) -> UnsafeMutableRawPointer { Unmanaged.passRetained(Box(v)).toOpaque() }
private func take<T>(_ p: UnsafeMutableRawPointer?) -> T { Unmanaged<Box<T>>.fromOpaque(p!).takeRetainedValue().value }

typealias OfflineRules = UnsafeMutableRawPointer

/// The offline rules (Safari content-blocker JSON) compiled for WPE.
func compileOfflineRules(_ done: @escaping (OfflineRules?) -> Void) {
  guard offline else { return done(nil) }
  shoji_compile_filter("shoji-offline-v1", offlineRulesJSON, { ctx, filter, error in
    let done: (OfflineRules?) -> Void = take(ctx)
    guard let filter = filter else { fail("offline rules failed: \(error.map { String(cString: $0) } ?? "?")") }
    done(filter)
  }, retained(done))
}

let userAgent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

final class Browser {
  let display: Display
  let offline: Bool
  /// Device pixels per CSS pixel. Headless WPE draws at 1.
  let scale: Double
  let web = WebView()
  var onStatus: (() -> Void)?
  var lastActivity = Date()
  var lastError: String?
  var lastDialog: String?

  // frames (terminal and Neovim)
  private var lastFrame: [UInt8] = []
  private var capturing = false
  private var activeUntil = Date()
  private var lastIdleCheck = Date.distantPast
  private var frameTimer: DispatchSourceTimer?

  // mouse state
  private var leftDown = false
  private var lastPress = (time: Date.distantPast, x: 0.0, y: 0.0, count: 0)

  init(display: Display, offline: Bool, rules: OfflineRules?) {
    self.display = display
    self.offline = offline
    scale = 1
    let size = Browser.pointSize(display.pagePixels, scale: scale)
    let me = Unmanaged.passUnretained(self).toOpaque()
    let callbacks = ShojiCallbacks(
      ctx: me,
      status: { ctx in Browser.from(ctx).statusChanged() },
      committed: { ctx, uri in Browser.from(ctx).committed(uri.map { String(cString: $0) } ?? "") },
      finished: { ctx in Browser.from(ctx).finished() },
      failed: { ctx, uri, error, provisional in
        Browser.from(ctx).failed(uri.map { String(cString: $0) } ?? "", error.map { String(cString: $0) } ?? "failed",
                                 provisional: provisional != 0)
      },
      response: { ctx, uri, status in
        // HTTP only, as on macOS (file: and data: have no status)
        if status > 0 { Browser.from(ctx).pendingStatus = (uri.map { String(cString: $0) } ?? "", Int(status)) }
      },
      message: { ctx, name, json in
        Browser.from(ctx).message(String(cString: name!), json.map { String(cString: $0) } ?? "null")
      },
      dialog: { ctx, type, message, defaultText, answer in
        Browser.from(ctx).dialog(Int(type), message.map { String(cString: $0) } ?? "",
                                 defaultText.map { String(cString: $0) }, answer)
      })
    let names = ["shojiFocus", "shojiWake", "shojiLog"]
    var cNames = names.map { UnsafePointer(strdup($0)) }
    let engine = cNames.withUnsafeMutableBufferPointer { buf in
      shoji_engine_new(Int32(size.width), Int32(size.height), rules, userAgent, pageWorldScript, helperScript, "shoji",
                       buf.baseAddress, Int32(names.count), callbacks)
    }
    cNames.forEach { free(UnsafeMutablePointer(mutating: $0)) }
    guard let engine = engine else { fail("shoji: WPE WebKit couldn't start (see the message above)") }
    web.engine = engine
    if display.wantsFrames {
      let t = DispatchSource.makeTimerSource(queue: .main)
      t.schedule(deadline: .now(), repeating: 1.0 / 30)
      t.setEventHandler { [weak self] in self?.tick() }
      t.resume()
      frameTimer = t
    }
    log("page \(size.width)x\(size.height) css px, scale \(scale)")
  }

  private static func from(_ ctx: UnsafeMutableRawPointer?) -> Browser {
    Unmanaged<Browser>.fromOpaque(ctx!).takeUnretainedValue()
  }

  static func pointSize(_ px: (width: Int, height: Int), scale: Double) -> (width: Int, height: Int) {
    (max(100, Int(Double(px.width) / scale)), max(100, Int(Double(px.height) / scale)))
  }

  private func statusChanged() {
    display.status(title: web.title ?? "", url: web.url?.absoluteString ?? "", loading: web.isLoading)
    onStatus?()
    if web.isLoading { wake() }
  }

  // MARK: navigation

  func load(_ target: String) {
    var s = target.trimmingCharacters(in: .whitespaces)
    let path = (s as NSString).expandingTildeInPath
    if !s.contains("://"), FileManager.default.fileExists(atPath: path) {
      s = URL(fileURLWithPath: path).standardizedFileURL.absoluteString
    } else if !s.contains("://") {
      s = s.contains(".") && !s.contains(" ") ? "https://" + s
        : "https://duckduckgo.com/html/?q=" + (s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s)
    }
    shoji_engine_load_uri(web.engine, s)
    wake()
  }

  /// The display's page area changed size (in device pixels).
  func resized() {
    let size = Browser.pointSize(display.pagePixels, scale: scale)
    shoji_engine_resize(web.engine, Int32(size.width), Int32(size.height))
    display.resetFrame()
    lastFrame = []
    wake()
  }

  // MARK: frames

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
    shoji_engine_snapshot(web.engine, 0, { ctx, bgra, w, h, stride, _ in
      let b: Browser = take(ctx)
      b.capturing = false
      guard let bgra = bgra, w > 0, h > 0 else { return }
      var px = Browser.rgba(bgra, width: Int(w), height: Int(h), stride: Int(stride))
      let changed = Browser.changedRows(old: b.lastFrame, new: px, width: Int(w), height: Int(h))
      if changed.isEmpty { return }
      swap(&b.lastFrame, &px)
      let full = b.lastFrame.withUnsafeBytes { b.display.showFrame(rgba: $0, width: Int(w), height: Int(h), changedRows: changed) }
      log(full ? "frame \(w)x\(h) full" : "frame rows \(changed.lowerBound)..<\(changed.upperBound) of \(h)")
      b.activeUntil = max(b.activeUntil, Date().addingTimeInterval(0.3))
    }, retained(self))
  }

  /// Premultiplied BGRA (cairo order) to RGBA rows without padding, as the kitty protocol takes them.
  static func rgba(_ src: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: width * height * 4)
    out.withUnsafeMutableBufferPointer { dst in
      for y in 0..<height {
        let s = src + y * stride
        let d = dst.baseAddress! + y * width * 4
        for x in 0..<width {
          d[4 * x] = s[4 * x + 2]; d[4 * x + 1] = s[4 * x + 1]; d[4 * x + 2] = s[4 * x]; d[4 * x + 3] = s[4 * x + 3]
        }
      }
    }
    return out
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
    let keyval: UInt32
    switch k {
    case .text(let s): typeText(s); return
    case .enter: keyval = 0xff0d
    case .tab: keyval = 0xff09
    case .backspace: keyval = 0xff08
    case .escape: keyval = 0xff1b
    case .delete: keyval = 0xffff
    case .up: keyval = 0xff52
    case .down: keyval = 0xff54
    case .left: keyval = 0xff51
    case .right: keyval = 0xff53
    case .home: keyval = 0xff50
    case .end: keyval = 0xff57
    case .pageUp: keyval = 0xff55
    case .pageDown: keyval = 0xff56
    case .ctrl: return
    }
    shoji_engine_key(web.engine, keyval)
    wake()
  }

  func typeText(_ s: String) {
    shoji_engine_type_text(web.engine, s)
    wake()
  }

  func mouse(_ action: MouseAction, x: Double, y: Double) {
    switch action {
    case .wheelUp, .wheelDown:
      scroll(by: action == .wheelUp ? -60 : 60, at: (x, y))
    case .press:
      let now = Date()
      let near = abs(lastPress.x - x) < 4 && abs(lastPress.y - y) < 4
      let count = (now.timeIntervalSince(lastPress.time) < 0.35 && near) ? lastPress.count + 1 : 1
      lastPress = (now, x, y, count)
      leftDown = true
      shoji_engine_mouse(web.engine, 0, x, y, Int32(count), 1)
    case .release:
      leftDown = false
      shoji_engine_mouse(web.engine, 1, x, y, 0, 0)
    case .move:
      shoji_engine_mouse(web.engine, 2, x, y, 0, leftDown ? 1 : 0)
    }
    wake()
  }

  func click(x: Double, y: Double) {
    mouse(.press, x: x, y: y)
    mouse(.release, x: x, y: y)
  }

  /// Scroll by CSS pixels (positive = down), as a real wheel would.
  func scroll(by dy: Double, at point: (x: Double, y: Double)? = nil) {
    let p = point ?? (web.bounds.midX, web.bounds.midY)
    shoji_engine_scroll(web.engine, 0, dy, p.x, p.y)
    wake()
  }

  // MARK: reading the page

  func eval(_ js: String, _ done: @escaping (Any?, String?) -> Void) {
    run(js, world: nil, done)
  }

  /// Run JavaScript in shoji's isolated world (the outline and actions live there).
  /// Arguments become constants in the function body, as callAsyncJavaScript does on macOS.
  func evalHelper(_ js: String, _ args: [String: Any] = [:], _ done: @escaping (Any?, String?) -> Void) {
    var prefix = ""
    for (k, v) in args {
      let data = (try? JSONSerialization.data(withJSONObject: [v], options: [.fragmentsAllowed])) ?? Data("[null]".utf8)
      let json = String(decoding: data, as: UTF8.self)
      prefix += "const \(k) = \(json)[0];\n"
    }
    run(prefix + js, world: "shoji", done)
  }

  private func run(_ js: String, world: String?, _ done: @escaping (Any?, String?) -> Void) {
    shoji_engine_eval(web.engine, js, world, { ctx, json, error in
      let done: (Any?, String?) -> Void = take(ctx)
      if let error = error { return done(nil, String(cString: error)) }
      guard let json = json else { return done(nil, nil) }
      let v = try? JSONSerialization.jsonObject(with: Data(String(cString: json).utf8), options: [.fragmentsAllowed])
      done(v is NSNull ? nil : v, nil)
    }, retained(done))
  }

  /// A PNG of what's in view. scale 1 = CSS pixels, 2 = twice the size (macOS: Retina).
  func screenshot(to path: String, scale outScale: Double, _ done: @escaping ([String: Any]) -> Void) {
    snapshotPNG(full: false, path: path, scale: outScale, done)
  }

  /// A PNG of the whole page (WebKit renders the full document; up to 16000 CSS pixels tall).
  func screenshotFull(to path: String, scale outScale: Double, _ done: @escaping ([String: Any]) -> Void) {
    snapshotPNG(full: true, path: path, scale: outScale) { [weak self] r in
      self?.display.resetFrame()
      self?.wake()
      done(r)
    }
  }

  private func snapshotPNG(full: Bool, path: String, scale outScale: Double, _ done: @escaping ([String: Any]) -> Void) {
    let req: (String, Double, ([String: Any]) -> Void) = (path, outScale / scale, done)
    shoji_engine_snapshot(web.engine, full ? 1 : 0, { ctx, bgra, w, h, stride, error in
      let (path, factor, done): (String, Double, ([String: Any]) -> Void) = take(ctx)
      guard let bgra = bgra, w > 0, h > 0 else {
        return done(["ok": false, "error": "snapshot failed: \(error.map { String(cString: $0) } ?? "?")"])
      }
      let srcH = min(Int(h), 16000)
      let ow = Int((Double(w) * factor).rounded()), oh = Int((Double(srcH) * factor).rounded())
      if shoji_write_png(path, bgra, w, Int32(srcH), stride, Int32(ow), Int32(oh)) != 0 {
        done(["ok": true, "path": path, "width": ow, "height": oh])
      } else {
        done(["ok": false, "error": "couldn't write \(path)"])
      }
    }, retained(req))
  }

  // MARK: engine events

  private var pendingStatus: (url: String, status: Int)?

  private func committed(_ uri: String) {
    lastError = nil
    lastDialog = nil
    record(["k": "navigation", "url": uri])
    if let st = pendingStatus { record(["k": "network", "type": "document", "url": st.url, "status": st.status]); pendingStatus = nil }
  }

  private func finished() {
    log("loaded \(web.url?.absoluteString ?? "") \"\(web.title ?? "")\"")
    statusChanged()
    wake(for: 1.5)
  }

  private func failed(_ uri: String, _ error: String, provisional: Bool) {
    lastError = error
    if provisional { record(["k": "network", "type": "document", "url": uri, "failed": true, "error": error]) }
    statusChanged()
  }

  private func message(_ name: String, _ json: String) {
    let body = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
    switch name {
    case "shojiWake": wake(for: 0.5)
    case "shojiLog": if let entry = body as? [String: Any] { record(entry) }
    case "shojiFocus":
      if let editable = body as? Bool {
        log("focus editable=\(editable)")
        display.focusChanged(editable: editable)
      }
    default: break
    }
  }

  /// confirm() and prompt() are answered by the dialog policy (accept by default;
  /// `shoji ctl dialog dismiss` / `dialog accept <text>` changes it). alert() is noted.
  var dialogAccept = true
  var dialogText: String?

  private func dialog(_ type: Int, _ message: String, _ defaultText: String?,
                      _ answer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    lastDialog = message
    switch type {
    case 0:
      log("alert: \(message)")
      record(["k": "dialog", "type": "alert", "text": message])
      return 1
    case 1:
      record(["k": "dialog", "type": "confirm", "text": message, "answer": dialogAccept ? "OK" : "Cancel"])
      return dialogAccept ? 1 : 0
    default:
      let text = dialogAccept ? (dialogText ?? defaultText ?? "") : nil
      record(["k": "dialog", "type": "prompt", "text": message, "answer": text ?? "(cancelled)"])
      if let t = text { answer?.pointee = strdup(t) }
      return dialogAccept ? 1 : 0
    }
  }

  // MARK: page log (console, errors, network, dialogs) for agents

  private(set) var pageLog: [[String: Any]] = []
  private var logStart = Date()

  func record(_ entry: [String: Any]) {
    var e = entry
    e["t"] = (Date().timeIntervalSince(logStart) * 1000).rounded() / 1000
    pageLog.append(e)
    if pageLog.count > 1000 { pageLog.removeFirst(pageLog.count - 1000) }
  }

  func logEntries(all: Bool) -> [[String: Any]] {
    if all { return pageLog }
    guard let i = pageLog.lastIndex(where: { $0["k"] as? String == "navigation" }) else { return pageLog }
    return Array(pageLog[(i + 1)...])
  }
}
#endif
