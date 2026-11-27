// Where frames go: the terminal itself, Neovim (through its job's stdout), or
// nowhere (headless, for agents).
import Foundation

protocol Display: AnyObject {
  /// The page area in device pixels.
  var pagePixels: (width: Int, height: Int) { get }
  var wantsFrames: Bool { get }
  /// False until the display knows its size (Neovim sends it after start).
  var ready: Bool { get }
  /// Show a frame; returns true if it was sent in full.
  @discardableResult
  func showFrame(rgba: UnsafeRawBufferPointer, width: Int, height: Int, changedRows: Range<Int>) -> Bool
  func resetFrame()
  func status(title: String, url: String, loading: Bool)
  /// A text field (input, textarea, contenteditable) gained or lost focus.
  func focusChanged(editable: Bool)
}

extension Display {
  func focusChanged(editable: Bool) {}
}

/// Builds kitty graphics commands for one image: created once, then only the
/// changed rows written into it in place (a=f,r=1,X=1). Re-sending an image id
/// would delete its placement first, so updates never do that. Pixels go as a
/// temp file the terminal reads and deletes (t=t), never through the stream.
final class KittyImage {
  let id: Int
  let virtual: Bool                 // unicode placeholders (U=1) instead of a cursor placement
  private var placed: (w: Int, h: Int, cols: Int, rows: Int)?
  private var seq = 0
  private let pid = ProcessInfo.processInfo.processIdentifier

  init(id: Int, virtual: Bool) { self.id = id; self.virtual = virtual }

  func reset() { placed = nil }

  /// The escape sequence for this frame, or nil if the pixels couldn't be written.
  /// `full` is set when the whole image was (re)created.
  func command(rgba: UnsafeRawBufferPointer, width: Int, height: Int, changedRows: Range<Int>,
               cols: Int, rows: Int, cursorRow: Int, full: inout Bool) -> String? {
    full = placed == nil || placed!.w != width || placed!.h != height || placed!.cols != cols || placed!.rows != rows
    let band = full ? 0..<height : changedRows
    let stride = width * 4
    let slice = UnsafeRawBufferPointer(rebasing: rgba[(band.lowerBound * stride)..<(band.upperBound * stride)])
    seq += 1
    let path = "/tmp/tty-graphics-protocol-shoji-\(pid)-\(id)-\(seq % 8).rgba"
    guard FileManager.default.createFile(atPath: path, contents: Data(slice)) else { return nil }
    let file = Data(path.utf8).base64EncodedString()
    var out = "\u{1b}[?2026h"
    if full {
      if placed != nil { out += "\u{1b}_Ga=d,d=I,i=\(id),q=2\u{1b}\\" }
      if virtual {
        out += "\u{1b}_Ga=T,U=1,i=\(id),q=2,t=t,f=32,s=\(width),v=\(height),c=\(cols),r=\(rows);\(file)\u{1b}\\"
      } else {
        out += "\u{1b}[\(cursorRow);1H\u{1b}_Ga=T,i=\(id),p=1,q=2,t=t,f=32,s=\(width),v=\(height),c=\(cols),r=\(rows),C=1;\(file)\u{1b}\\"
      }
      placed = (width, height, cols, rows)
    } else {
      out += "\u{1b}_Ga=f,i=\(id),r=1,X=1,q=2,t=t,f=32,x=0,y=\(band.lowerBound),s=\(width),v=\(band.count);\(file)\u{1b}\\"
    }
    return out + "\u{1b}[?2026l"
  }

  func deleteCommand() -> String { "\u{1b}_Ga=d,d=I,i=\(id),q=2\u{1b}\\" }
}

/// Frames for Neovim: printed as JSON lines on stdout for the Lua side to pass to
/// the terminal (nvim_ui_send), shown through unicode placeholders the Lua side
/// draws in a buffer with this image id as their colour.
final class EmbedDisplay: Display {
  let image: KittyImage
  var cols = 0, rows = 0
  var cellWidth = 0.0, cellHeight = 0.0
  var wantsFrames: Bool { true }
  var ready: Bool { cols > 0 && rows > 0 && cellWidth > 0 }
  var pagePixels: (width: Int, height: Int) {
    ready ? (Int(Double(cols) * cellWidth), Int(Double(rows) * cellHeight)) : (1280, 800)
  }

  init(imageId: Int) { image = KittyImage(id: imageId, virtual: true) }

  func showFrame(rgba: UnsafeRawBufferPointer, width: Int, height: Int, changedRows: Range<Int>) -> Bool {
    var full = false
    if let cmd = image.command(rgba: rgba, width: width, height: height, changedRows: changedRows,
                               cols: cols, rows: rows, cursorRow: 1, full: &full) {
      Output.event(["ui": cmd])
    }
    return full
  }

  func resetFrame() { image.reset() }

  func status(title: String, url: String, loading: Bool) {
    Output.event(["status": ["title": title, "url": url, "loading": loading]])
  }

  /// Neovim sends keys to the page only while a text field has focus.
  func focusChanged(editable: Bool) {
    Output.event(["focus": ["editable": editable]])
  }
}

/// No display: for agents driving the page through the control socket.
final class HeadlessDisplay: Display {
  var size: (width: Int, height: Int)
  init(width: Int, height: Int) { size = (width, height) }
  var pagePixels: (width: Int, height: Int) { size }
  var wantsFrames: Bool { false }
  var ready: Bool { true }
  func showFrame(rgba: UnsafeRawBufferPointer, width: Int, height: Int, changedRows: Range<Int>) -> Bool { false }
  func resetFrame() {}
  func status(title: String, url: String, loading: Bool) {}
}

/// Remove this process's frame files the terminal hasn't read (on exit).
func cleanupFrameFiles() {
  let prefix = "tty-graphics-protocol-shoji-\(getpid())-"
  for f in (try? FileManager.default.contentsOfDirectory(atPath: "/tmp")) ?? [] where f.hasPrefix(prefix) {
    try? FileManager.default.removeItem(atPath: "/tmp/" + f)
  }
}

/// JSON lines on stdout (embed mode), written whole so lines never interleave.
enum Output {
  static func event(_ obj: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
    data.append(0x0a)
    FileHandle.standardOutput.write(data)
  }
}
