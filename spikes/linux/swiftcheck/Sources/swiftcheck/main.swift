// Swift drives WPE through the C shim, with Swift closures as callbacks and
// Foundation JSON on the results — the shape the real Linux engine will have.
import CShim
import Foundation

final class Box<T> { let value: T; init(_ v: T) { value = v } }
typealias Done = (Any?, String?) -> Void

final class Engine {
  let raw: OpaquePointer
  private var onLoad: (() -> Void)?
  init?(width: Int, height: Int, helper: String, world: String) {
    guard let e = shoji_engine_new(Int32(width), Int32(height), helper, world) else { return nil }
    raw = e
  }
  func loaded(_ f: @escaping () -> Void) {
    onLoad = f
    shoji_engine_on_loaded(raw, { ctx in Unmanaged<Engine>.fromOpaque(ctx!).takeUnretainedValue().onLoad?() },
                           Unmanaged.passUnretained(self).toOpaque())
  }
  func loadHTML(_ html: String, base: String) { shoji_engine_load_html(raw, html, base) }
  func eval(_ js: String, world: String? = nil, _ done: @escaping Done) {
    let ctx = Unmanaged.passRetained(Box(done)).toOpaque()
    shoji_engine_eval(raw, js, world, { ctx, json, err in
      let done = Unmanaged<Box<Done>>.fromOpaque(ctx!).takeRetainedValue().value
      let value = json.flatMap { try? JSONSerialization.jsonObject(with: Data(String(cString: $0).utf8), options: [.fragmentsAllowed]) }
      done(value, err.map { String(cString: $0) })
    }, ctx)
  }
  func click(x: Double, y: Double) { shoji_engine_click(raw, x, y) }
}

func after(_ ms: UInt32, _ f: @escaping () -> Void) {
  shoji_loop_after(ms, { ctx in Unmanaged<Box<() -> Void>>.fromOpaque(ctx!).takeRetainedValue().value() },
                   Unmanaged.passRetained(Box(f)).toOpaque())
}

var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "PASS" : "FAIL", what); if !ok { failures += 1 } }

guard let engine = Engine(width: 800, height: 600,
                          helper: "window.__shoji = { buttons: () => [...document.querySelectorAll('button')].map(b => b.textContent) };",
                          world: "shoji") else { print("FAIL engine"); exit(1) }
engine.loaded {
  engine.eval("return { title: document.title, answer: 6 * 7 }") { v, e in
    let d = v as? [String: Any]
    check((d?["answer"] as? NSNumber)?.intValue == 42 && d?["title"] as? String == "from swift", "Swift gets a JS object back as a dictionary")
    engine.eval("return __shoji.buttons()", world: "shoji") { v, _ in
      check((v as? [String]) == ["Press"], "isolated-world helper from Swift")
      engine.click(x: 60, y: 30)
      after(200) {
        engine.eval("return document.body.dataset.clicked") { v, _ in
          check(v as? String == "yes", "click from Swift reaches the page")
          engine.eval("throw new Error('boom')") { _, e in
            check(e?.contains("boom") == true, "JS exceptions come back as errors")
            print(failures == 0 ? "SWIFT + WPE OK" : "SWIFT + WPE: \(failures) failure(s)")
            shoji_loop_quit()
          }
        }
      }
    }
  }
}
engine.loadHTML("<title>from swift</title><button style='position:absolute;left:10px;top:10px;width:100px;height:40px' onclick='document.body.dataset.clicked=\"yes\"'>Press</button>",
                base: "file:///check/")
after(20000) { print("TIMEOUT"); exit(1) }
shoji_loop_run()
exit(failures == 0 ? 0 : 1)
