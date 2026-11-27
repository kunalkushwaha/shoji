// Spike 4: can we drive an off-screen WKWebView with synthetic events?
// Click a button, focus a text field and type (including Japanese text through
// the input path), scroll with the wheel. Prints what the page saw.
import AppKit
import WebKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let page = """
<html><head><meta charset="utf-8"></head><body style="margin:0;font:16px -apple-system;height:4000px">
<button id="b" style="position:absolute;left:100px;top:100px;width:200px;height:60px"
  onclick="this.dataset.n = (+this.dataset.n || 0) + 1">click me</button>
<input id="t" style="position:absolute;left:100px;top:200px;width:300px;height:40px">
<a id="l" href="#second" style="position:absolute;left:100px;top:280px">link</a>
<div id="second" style="position:absolute;top:3000px">second</div>
</body></html>
"""

final class KeyWindow: NSWindow {   // borderless windows can't take keyboard focus by default
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

func setOcclusionDetection(_ web: WKWebView, _ on: Bool) {
  let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
  guard let m = class_getInstanceMethod(WKWebView.self, sel) else { return }
  typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
  unsafeBitCast(method_getImplementation(m), to: Setter.self)(web, sel, on)
}

final class Spike: NSObject, WKNavigationDelegate {
  let web: WKWebView
  let window: KeyWindow
  override init() {
    let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    window = KeyWindow(contentRect: frame.offsetBy(dx: -30000, dy: -30000), styleMask: [.borderless],
                       backing: .buffered, defer: false)
    web = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
    super.init()
    setOcclusionDetection(web, false)
    web.navigationDelegate = self
    window.contentView = web
    window.orderFront(nil)
    web.loadHTMLString(page, baseURL: URL(string: "about:blank"))
  }

  // page coordinates (top-left origin, CSS px) -> window coordinates (bottom-left origin)
  func windowPoint(_ x: Double, _ y: Double) -> NSPoint { NSPoint(x: x, y: web.bounds.height - y) }

  func mouse(_ type: NSEvent.EventType, _ x: Double, _ y: Double) {
    let e = NSEvent.mouseEvent(with: type, location: windowPoint(x, y), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
    window.sendEvent(e)
  }

  func click(_ x: Double, _ y: Double) { mouse(.leftMouseDown, x, y); mouse(.leftMouseUp, x, y) }

  func type(_ text: String) {
    for ch in text {
      for t in [NSEvent.EventType.keyDown, .keyUp] {
        let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: window.windowNumber, context: nil, characters: String(ch),
                                 charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: 0)!
        window.sendEvent(e)
      }
    }
  }

  func insertText(_ text: String) {   // the IME path: committed text arrives via NSTextInputClient
    (web as NSView as? NSTextInputClient)?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
  }

  func scroll(_ dy: Int32) {
    let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)!
    cg.location = CGPoint(x: 400, y: 300)
    if let e = NSEvent(cgEvent: cg) { web.scrollWheel(with: e) }
  }

  func state(_ label: String, then: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
      self.web.evaluateJavaScript("JSON.stringify({clicks: +document.getElementById('b').dataset.n || 0, text: document.getElementById('t').value, focus: document.activeElement.id, scrollY: Math.round(scrollY), hash: location.hash})") { r, _ in
        print("\(label): \(r ?? "nil")")
        then()
      }
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    window.makeKey()
    window.makeFirstResponder(web)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      self.click(200, 130); self.click(200, 130)
      self.state("after 2 clicks on the button") {
        self.click(250, 220); self.type("hello")
        self.state("after clicking the field and typing 'hello'") {
          self.insertText(" 日本語")
          self.state("after IME-style insert of ' 日本語'") {
            self.scroll(-400)
            self.state("after wheel scroll") {
              exit(0)
            }
          }
        }
      }
    }
  }
}

let spike = Spike()
DispatchQueue.main.asyncAfter(deadline: .now() + 20) { print("timeout"); exit(1) }
app.run()
