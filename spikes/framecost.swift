// Spike 2: what does one frame cost? Snapshot a live page at a terminal pane's
// size, then encode it the ways the kitty graphics protocol accepts:
//   PNG (f=100), raw RGBA (f=32), raw RGBA + zlib (f=32,o=z)
// and report time and bytes for each (bytes = what goes to the terminal; base64
// adds a third when sent inline). Run: framecost <width_pt> <height_pt>
import AppKit
import WebKit
import Compression

let W = Double(CommandLine.arguments.count > 2 ? CommandLine.arguments[1] : "1200")!
let H = Double(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "800")!
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let page = """
<html><head><meta charset="utf-8"><style>
body { font: 15px/1.5 -apple-system; margin: 32px; color: #1f2328; }
.card { border: 1px solid #d0d7de; border-radius: 12px; padding: 16px; margin: 12px 0; }
</style></head><body><h1>Frame cost test</h1>
\(String(repeating: "<div class=card><b>Section</b><p>Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam.</p><svg width=300 height=60><rect width=300 height=60 rx=8 fill=#4f8ef7 /></svg></div>", count: 12))
</body></html>
"""

func ms(_ t: Date) -> String { String(format: "%5.1f ms", Date().timeIntervalSince(t) * 1000) }

final class Spike: NSObject, WKNavigationDelegate {
  let web: WKWebView
  let window: NSWindow
  override init() {
    let frame = NSRect(x: 0, y: 0, width: W, height: H)
    window = NSWindow(contentRect: frame.offsetBy(dx: -30000, dy: -30000), styleMask: [.borderless],
                      backing: .buffered, defer: false)
    web = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
    super.init()
    web.navigationDelegate = self
    window.contentView = web
    window.orderFront(nil)
    web.loadHTMLString(page, baseURL: nil)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.run(round: 1) }
  }

  func run(round: Int) {
    let t0 = Date()
    let cfg = WKSnapshotConfiguration()
    cfg.rect = web.bounds
    web.takeSnapshot(with: cfg) { img, _ in
      guard let img = img, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }
      let snap = ms(t0)
      // raw RGBA pixels
      let t1 = Date()
      let w = cg.width, h = cg.height
      var raw = [UInt8](repeating: 0, count: w * h * 4)
      let ctx = CGContext(data: &raw, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
      let rawT = ms(t1)
      // zlib (kitty o=z is zlib/deflate)
      let t2 = Date()
      let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: raw.count)
      let zlen = compression_encode_buffer(dst, raw.count, raw, raw.count, nil, COMPRESSION_ZLIB)
      dst.deallocate()
      let zT = ms(t2)
      // PNG
      let t3 = Date()
      let rep = NSBitmapImageRep(cgImage: cg)
      let png = rep.representation(using: .png, properties: [:])!
      let pngT = ms(t3)
      if round == 2 {   // round 1 warms up caches
        print("pane \(Int(W))x\(Int(H)) pt -> \(w)x\(h) px")
        print("  snapshot           \(snap)")
        print("  raw RGBA  (f=32)   \(rawT)   \(raw.count / 1024) KB")
        print("  zlib RGBA (o=z)    \(zT)   \(zlen / 1024) KB")
        print("  PNG       (f=100)  \(pngT)   \(png.count / 1024) KB")
        exit(0)
      }
      self.run(round: round + 1)
    }
  }
}

let spike = Spike()
DispatchQueue.main.asyncAfter(deadline: .now() + 20) { print("timeout"); exit(1) }
app.run()
