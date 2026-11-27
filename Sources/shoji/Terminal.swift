// The terminal side (standalone mode): raw mode, sizes, the top bar, and the
// terminal's own input (address bar, mouse in pixels) turned into browser calls.
import Foundation
#if os(Linux)
import CShojiWPE
#endif

final class Terminal {
  let fd: Int32
  private var saved = termios()
  private(set) var rows = 24, cols = 80
  private(set) var pixelWidth = 0, pixelHeight = 0      // text area, device pixels
  var cellWidth: Double { cols > 0 && pixelWidth > 0 ? Double(pixelWidth) / Double(cols) : 16 }
  var cellHeight: Double { rows > 0 && pixelHeight > 0 ? Double(pixelHeight) / Double(rows) : 34 }

  init?() {
    fd = open("/dev/tty", O_RDWR)
    if fd < 0 { return nil }
    tcgetattr(fd, &saved)
    refreshSize()
  }

  func refreshSize() {
    #if os(Linux)
    var r: Int32 = 0, c: Int32 = 0, xp: Int32 = 0, yp: Int32 = 0
    if shoji_winsize(fd, &r, &c, &xp, &yp) == 0 {
      rows = Int(r); cols = Int(c); pixelWidth = Int(xp); pixelHeight = Int(yp)
    }
    #else
    var ws = winsize()
    if ioctl(fd, TIOCGWINSZ, &ws) == 0 {
      rows = Int(ws.ws_row); cols = Int(ws.ws_col)
      pixelWidth = Int(ws.ws_xpixel); pixelHeight = Int(ws.ws_ypixel)
    }
    #endif
  }

  func write(_ s: String) {
    let data = Array(s.utf8)
    data.withUnsafeBytes { buf in
      var off = 0
      while off < buf.count {
        #if os(Linux)
        let n = Glibc.write(fd, buf.baseAddress! + off, buf.count - off)
        #else
        let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
        #endif
        if n <= 0 { break }
        off += n
      }
    }
  }

  /// Raw input, alternate screen, no cursor; mouse: buttons + motion (1003),
  /// SGR (1006) with pixel coordinates (1016).
  func enter() {
    var raw = saved
    cfmakeraw(&raw)
    tcsetattr(fd, TCSANOW, &raw)
    // save the window title (xterm title stack) so leaving can put it back
    write("\u{1b}[22;2t\u{1b}[?1049h\u{1b}[?25l\u{1b}[2J\u{1b}[?1003h\u{1b}[?1006h\u{1b}[?1016h")
  }

  func leave() {
    write("\u{1b}_Ga=d,d=A,q=2\u{1b}\\")                     // remove our images
    write("\u{1b}[?1016l\u{1b}[?1006l\u{1b}[?1003l\u{1b}[?25h\u{1b}[?1049l\u{1b}[23;2t")
    tcsetattr(fd, TCSANOW, &saved)
  }

  /// The window (and tab) title: the page title, or its address while it has none.
  func title(_ s: String) {
    let clean = s.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }.map(String.init).joined()
    write("\u{1b}]2;\(clean.isEmpty ? "shoji" : clean + " · shoji")\u{07}")
  }

  /// The top bar: ◀ ▶ ⟳, then the title/address (or the address being typed).
  func bar(_ text: String, editing: Bool, loading: Bool, offline: Bool) {
    let buttons = " ◀  ▶  \(loading ? "✕" : "⟳")  "
    let tag = offline ? " offline " : ""
    let room = max(0, cols - buttons.count - tag.count - 1)
    var body = text
    if body.count > room { body = String(body.prefix(max(0, room - 1))) + "…" }
    body += String(repeating: " ", count: max(0, room - body.count))
    let barStyle = "\u{1b}[48;2;43;43;43m\u{1b}[38;2;204;204;204m"
    let field = editing ? "\u{1b}[48;2;31;31;31m\u{1b}[38;2;255;255;255m" : barStyle
    let tagStyle = "\u{1b}[48;2;137;209;133m\u{1b}[38;2;31;31;31m"
    write("\u{1b}[1;1H" + barStyle + buttons + field + body + barStyle + " " + tagStyle + tag + "\u{1b}[0m")
  }
}

/// Standalone mode: the page below a one-row top bar, input from the terminal.
final class TerminalDisplay: Display {
  let term: Terminal
  let image = KittyImage(id: 1, virtual: false)
  weak var browser: Browser?
  var offline = false
  private var editing = false
  private var typed = ""
  private var lastStatus = (title: "", url: "", loading: false)

  init(term: Terminal) { self.term = term }

  var pagePixels: (width: Int, height: Int) {
    (Int(Double(term.cols) * term.cellWidth), Int(Double(term.rows - 1) * term.cellHeight))
  }
  var wantsFrames: Bool { true }
  var ready: Bool { true }

  func showFrame(rgba: UnsafeRawBufferPointer, width: Int, height: Int, changedRows: Range<Int>) -> Bool {
    var full = false
    if let cmd = image.command(rgba: rgba, width: width, height: height, changedRows: changedRows,
                               cols: term.cols, rows: term.rows - 1, cursorRow: 2, full: &full) {
      term.write(cmd)
    }
    return full
  }

  func resetFrame() { image.reset() }

  func status(title: String, url: String, loading: Bool) {
    if title != lastStatus.title || (title.isEmpty && url != lastStatus.url) {
      term.title(title.isEmpty ? url : title)
    }
    lastStatus = (title, url, loading)
    drawBar()
  }

  func drawBar() {
    let text: String
    if editing {
      text = " " + typed + "▏"
    } else {
      text = " " + (lastStatus.title.isEmpty ? lastStatus.url : "\(lastStatus.title) — \(lastStatus.url)")
    }
    term.bar(text, editing: editing, loading: lastStatus.loading, offline: offline)
  }

  func resized() {
    term.refreshSize()
    term.write("\u{1b}[2J")
    browser?.resized()
    drawBar()
  }

  func quit() {
    term.leave()
    exit(0)
  }

  // MARK: terminal input

  func handle(_ ev: InputEvent) {
    guard let b = browser else { return }
    log("input \(ev)")
    switch ev {
    case .key(let k): key(k, b)
    case .mouse(let m): mouse(m, b)
    }
  }

  private func startEditing(_ b: Browser) {
    editing = true
    typed = b.web.url?.absoluteString ?? ""
    drawBar()
  }

  private func key(_ k: Key, _ b: Browser) {
    if case .ctrl("q") = k { quit() }   // always quits, even while typing an address
    if editing {
      switch k {
      case .text(let s): typed += s
      case .backspace: if !typed.isEmpty { typed.removeLast() }
      case .enter: editing = false; b.load(typed)
      case .escape, .ctrl("l"): editing = false
      default: break
      }
      drawBar()
      return
    }
    switch k {
    case .ctrl("l"): startEditing(b)
    case .ctrl("r"): b.web.reload()
    case .ctrl("b"): b.web.goBack()
    case .ctrl("n"): b.web.goForward()
    default: b.key(k)
    }
  }

  private func mouse(_ m: Mouse, _ b: Browser) {
    let barHeight = term.cellHeight
    if m.y < barHeight {                                  // the top bar
      if m.kind == .press && m.button == 0 {
        switch Int(m.x / term.cellWidth) {
        case 0...2: b.web.goBack()
        case 3...5: b.web.goForward()
        case 6...8: if b.web.isLoading { b.web.stopLoading() } else { b.web.reload() }
        default: startEditing(b)
        }
      }
      return
    }
    // terminal pixels -> page CSS pixels
    let x = m.x / b.scale, y = (m.y - barHeight) / b.scale
    switch m.kind {
    case .wheelUp: b.mouse(.wheelUp, x: x, y: y)
    case .wheelDown: b.mouse(.wheelDown, x: x, y: y)
    case .press where m.button == 0: b.mouse(.press, x: x, y: y)
    case .release: b.mouse(.release, x: x, y: y)
    case .motion: b.mouse(.move, x: x, y: y)
    default: break   // right/middle: ignored for now (a native context menu would block)
    }
  }
}
