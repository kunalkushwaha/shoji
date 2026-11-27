// Decoding what the terminal sends: SGR mouse reports with pixel coordinates,
// special keys, control keys and (UTF-8) text.
import Foundation

enum Key {
  case text(String)          // printable text, possibly from an input method
  case enter, tab, backspace, escape, delete
  case up, down, left, right, home, end, pageUp, pageDown
  case ctrl(Character)       // Ctrl+letter, lower-case
}

enum MouseKind { case press, release, motion, wheelUp, wheelDown }

struct Mouse {
  let kind: MouseKind
  let button: Int            // 0 left, 1 middle, 2 right, 3 none (motion)
  let x: Double, y: Double   // device pixels in the text area, 0-based
  let shift: Bool, alt: Bool, ctrl: Bool
}

/// reply: a kitty graphics reply from the terminal (what follows "\u{1b}_G", e.g. "i=31;OK").
/// textAreaPixels: the answer to CSI 14 t (the text area's size in pixels).
enum InputEvent { case key(Key), mouse(Mouse), reply(String), textAreaPixels(width: Int, height: Int) }

struct InputParser {
  private var pending: [UInt8] = []

  mutating func feed(_ bytes: [UInt8]) -> [InputEvent] {
    pending += bytes
    var out: [InputEvent] = []
    var i = 0
    var text: [UInt8] = []
    func flushText() {
      if !text.isEmpty { out.append(.key(.text(String(decoding: text, as: UTF8.self)))); text.removeAll() }
    }
    while i < pending.count {
      let b = pending[i]
      if b == 0x1b {
        flushText()
        // lone ESC at the end of a read = the Escape key
        if i + 1 >= pending.count { out.append(.key(.escape)); i += 1; continue }
        let kind = pending[i + 1]
        if kind == UInt8(ascii: "_") || kind == UInt8(ascii: "P") || kind == UInt8(ascii: "]") {
          // a terminal reply (kitty graphics, DCS, OSC): skip to its terminator
          var j = i + 2
          var end: Int? = nil
          while j < pending.count {
            if pending[j] == 0x07 { end = j + 1; break }                                   // BEL (OSC)
            if pending[j] == 0x1b, j + 1 < pending.count, pending[j + 1] == UInt8(ascii: "\\") { end = j + 2; break }
            j += 1
          }
          guard let e = end else { break }   // incomplete: wait for the rest
          if kind == UInt8(ascii: "_"), i + 2 < pending.count, pending[i + 2] == UInt8(ascii: "G") {
            let bodyEnd = pending[e - 1] == 0x07 ? e - 1 : e - 2
            out.append(.reply(String(decoding: pending[(i + 3)..<max(i + 3, bodyEnd)], as: UTF8.self)))
          }
          i = e
          continue
        }
        if kind == UInt8(ascii: "[") {
          guard let (ev, len) = parseCSI(Array(pending[(i + 2)...])) else { break }   // incomplete: wait
          if let ev = ev { out.append(ev) }
          i += 2 + len
          continue
        }
        out.append(.key(.escape)); i += 1; continue
      }
      switch b {
      case 0x0d: flushText(); out.append(.key(.enter))
      case 0x09: flushText(); out.append(.key(.tab))
      case 0x7f, 0x08: flushText(); out.append(.key(.backspace))
      case 0x01...0x1a: flushText(); out.append(.key(.ctrl(Character(UnicodeScalar(b + 0x60)))))
      default: text.append(b)
      }
      i += 1
    }
    // an unfinished UTF-8 character at the very end waits for the next read
    let tail = Self.incompleteUTF8Tail(text)
    let keep = Array(text.suffix(tail))
    text.removeLast(tail)
    flushText()
    pending = keep + Array(pending[min(i, pending.count)...])
    return out
  }

  /// How many trailing bytes form an incomplete UTF-8 character (0 if none).
  static func incompleteUTF8Tail(_ t: [UInt8]) -> Int {
    var cont = 0, idx = t.count - 1
    while idx >= 0, cont < 3, (t[idx] & 0xC0) == 0x80 { cont += 1; idx -= 1 }
    guard idx >= 0 else { return 0 }
    let lead = t[idx]
    let need = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
    return need > cont + 1 ? cont + 1 : 0
  }

  /// Parse after "ESC [". Returns (event or nil if ignored, bytes consumed) or nil if incomplete.
  private func parseCSI(_ s: [UInt8]) -> (InputEvent?, Int)? {
    var j = 0
    while j < s.count, !(0x40...0x7e).contains(s[j]) { j += 1 }
    guard j < s.count else { return nil }
    let final = s[j]
    let params = String(decoding: s[0..<j], as: UTF8.self)
    let len = j + 1
    if params.hasPrefix("<"), final == UInt8(ascii: "M") || final == UInt8(ascii: "m") {
      let nums = params.dropFirst().split(separator: ";").compactMap { Int($0) }
      guard nums.count == 3 else { return (nil, len) }
      let cb = nums[0]
      let mods = (shift: cb & 4 != 0, alt: cb & 8 != 0, ctrl: cb & 16 != 0)
      let x = Double(nums[1] - 1), y = Double(nums[2] - 1)
      let kind: MouseKind
      if cb & 64 != 0 { kind = (cb & 1) == 0 ? .wheelUp : .wheelDown }
      else if cb & 32 != 0 { kind = .motion }
      else { kind = final == UInt8(ascii: "M") ? .press : .release }
      return (.mouse(Mouse(kind: kind, button: cb & 3, x: x, y: y, shift: mods.shift, alt: mods.alt, ctrl: mods.ctrl)), len)
    }
    if final == UInt8(ascii: "t"), params.hasPrefix("4;") {
      let nums = params.split(separator: ";").compactMap { Int($0) }
      if nums.count == 3 { return (.textAreaPixels(width: nums[2], height: nums[1]), len) }
      return (nil, len)
    }
    switch final {
    case UInt8(ascii: "A"): return (.key(.up), len)
    case UInt8(ascii: "B"): return (.key(.down), len)
    case UInt8(ascii: "C"): return (.key(.right), len)
    case UInt8(ascii: "D"): return (.key(.left), len)
    case UInt8(ascii: "H"): return (.key(.home), len)
    case UInt8(ascii: "F"): return (.key(.end), len)
    case UInt8(ascii: "~"):
      switch params {
      case "3": return (.key(.delete), len)
      case "5": return (.key(.pageUp), len)
      case "6": return (.key(.pageDown), len)
      case "1", "7": return (.key(.home), len)
      case "4", "8": return (.key(.end), len)
      default: return (nil, len)
      }
    default: return (nil, len)   // anything else (replies, focus events…) is ignored
    }
  }
}
