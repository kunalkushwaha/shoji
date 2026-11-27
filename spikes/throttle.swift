// Spike 1: does WebKit keep a page "alive" (animation frames, timers, visible)
// when its window isn't really on screen? Run: throttle <mode>
//   offscreen        window far off-screen (what html-snapshot does)
//   alpha0           on screen, fully transparent, click-through
//   alpha001         on screen, 1% opaque, click-through
//   alpha0-behind    on screen, transparent, ordered behind all other windows
//   ordered-out      window never shown
//   offscreen+activity   off-screen + ProcessInfo.beginActivity (no App Nap)
//   offscreen+spi    off-screen + WKWebView _windowOcclusionDetectionEnabled = NO (private)
//   offscreen+spi-yes   control: same call with YES
// Prints: rAF callbacks and 10 ms interval ticks counted over 2 s, visibilityState,
// and how long a full-size takeSnapshot takes.
import AppKit
import WebKit

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "offscreen"
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let page = """
<html><body style="margin:0;background:linear-gradient(#fff,#ddd);height:3000px">
<script>
window.counts = { raf: 0, tick: 0 };
function frame() { counts.raf++; requestAnimationFrame(frame); }
requestAnimationFrame(frame);
setInterval(() => counts.tick++, 10);
</script></body></html>
"""

final class Spike: NSObject, WKNavigationDelegate {
  let web: WKWebView
  let window: NSWindow
  var activity: NSObjectProtocol?

  override init() {
    let frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    let onScreen = mode.hasPrefix("alpha")   // alpha0, alpha001, alpha0-behind
    let origin = onScreen ? NSPoint(x: 100, y: 100) : NSPoint(x: -30000, y: -30000)
    window = NSWindow(contentRect: NSRect(origin: origin, size: frame.size), styleMask: [.borderless],
                      backing: .buffered, defer: false)
    web = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
    super.init()
    web.navigationDelegate = self
    window.contentView = web
    window.ignoresMouseEvents = true
    if mode == "alpha0" { window.alphaValue = 0 }
    if mode == "alpha001" { window.alphaValue = 0.01 }
    if mode == "offscreen+activity" {
      activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                       reason: "terminal browser")
    }
    if mode.hasPrefix("offscreen+spi") {
      // call -[WKWebView _setWindowOcclusionDetectionEnabled:(BOOL)] with a real BOOL
      let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
      if let m = class_getInstanceMethod(WKWebView.self, sel) {
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        let set = unsafeBitCast(method_getImplementation(m), to: Setter.self)
        let value = mode == "offscreen+spi-yes"   // control: YES should keep throttling
        set(web, sel, value)
        print("spi: _setWindowOcclusionDetectionEnabled(\(value))")
      } else {
        print("spi: not available")
      }
    }
    if mode == "alpha0-behind" { window.alphaValue = 0; window.orderBack(nil) }
    else if mode != "ordered-out" { window.orderFront(nil) }
    web.loadHTMLString(page, baseURL: nil)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      webView.evaluateJavaScript("counts.raf = 0; counts.tick = 0; 0") { _, _ in
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
          webView.evaluateJavaScript("JSON.stringify([counts.raf, counts.tick, document.visibilityState, document.hasFocus()])") { r, _ in
            let occ = self.window.occlusionState.contains(.visible) ? "visible" : "occluded"
            print("\(mode): raf+tick+visibility over 2s = \(r ?? "nil")  window: \(occ)")
            self.timeSnapshot()
          }
        }
      }
    }
  }

  func timeSnapshot() {
    let t0 = Date()
    let cfg = WKSnapshotConfiguration()
    cfg.rect = web.bounds
    web.takeSnapshot(with: cfg) { img, err in
      let ms = Int(Date().timeIntervalSince(t0) * 1000)
      print("  takeSnapshot 1200x800pt: \(ms) ms, image=\(img.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil \(String(describing: err))")")
      exit(0)
    }
  }
}

let spike = Spike()
DispatchQueue.main.asyncAfter(deadline: .now() + 15) { print("\(mode): timeout"); exit(1) }
app.run()
