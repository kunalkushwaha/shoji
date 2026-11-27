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

enum InputEvent { case key(Key), mouse(Mouse) }

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
        if pending[i + 1] == UInt8(ascii: "[") {
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
