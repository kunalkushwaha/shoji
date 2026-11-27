// The terminal side: raw mode, sizes, kitty graphics frames, the top bar.
import Foundation

final class Terminal {
  let fd: Int32
  private var saved = termios()
  private(set) var rows = 24, cols = 80
  private(set) var pixelWidth = 0, pixelHeight = 0      // text area, device pixels
  var cellWidth: Double { cols > 0 ? Double(pixelWidth) / Double(cols) : 8 }
  var cellHeight: Double { rows > 0 ? Double(pixelHeight) / Double(rows) : 16 }
  private var frameSeq = 0
  let pid = ProcessInfo.processInfo.processIdentifier

  init?() {
    fd = open("/dev/tty", O_RDWR)
    if fd < 0 { return nil }
    tcgetattr(fd, &saved)
    refreshSize()
  }

  func refreshSize() {
    var ws = winsize()
    if ioctl(fd, TIOCGWINSZ, &ws) == 0 {
      rows = Int(ws.ws_row); cols = Int(ws.ws_col)
      pixelWidth = Int(ws.ws_xpixel); pixelHeight = Int(ws.ws_ypixel)
    }
  }

  func write(_ s: String) {
    let data = Array(s.utf8)
    data.withUnsafeBytes { buf in
      var off = 0
      while off < buf.count {
        let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
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
    write("\u{1b}[?1049h\u{1b}[?25l\u{1b}[2J\u{1b}[?1003h\u{1b}[?1006h\u{1b}[?1016h")
  }

  func leave() {
    write("\u{1b}_Ga=d,d=A,q=2\u{1b}\\")                     // remove our images
    write("\u{1b}[?1016l\u{1b}[?1006l\u{1b}[?1003l\u{1b}[?25h\u{1b}[?1049l")
    tcsetattr(fd, TCSANOW, &saved)
  }

  /// Show one frame of RGBA pixels below the top bar, replacing the previous one.
  /// Sent as a temp file the terminal reads and deletes (t=t): no pixels go through
  /// the terminal stream. The image is fitted to the page area's cells (c=, r=).
  func showFrame(rgba: UnsafeRawBufferPointer, width: Int, height: Int) {
    frameSeq += 1
    let path = "/tmp/tty-graphics-protocol-wkterm-\(pid)-\(frameSeq % 4).rgba"
    guard FileManager.default.createFile(atPath: path, contents: Data(rgba)) else { return }
    let b64 = Data(path.utf8).base64EncodedString()
    write("\u{1b}[2;1H\u{1b}_Ga=T,i=1,p=1,q=2,t=t,f=32,s=\(width),v=\(height),c=\(cols),r=\(rows - 1),C=1;\(b64)\u{1b}\\")
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
