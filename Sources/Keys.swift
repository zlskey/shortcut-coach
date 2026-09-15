import Foundation

/// A suggestion shown to the user: "you did <action> with the mouse, next time press <keys>".
struct Hint: Equatable {
    var action: String
    var keys: [String]          // e.g. ["⌘", "⇧", "N"]
    var note: String? = nil     // extra tip, e.g. "hold ⌥⇧ for finer steps"
    var appName: String? = nil

    /// Stable identity used for stats and muting (independent of app).
    var id: String { "\(action)|\(keys.joined())" }
    var keysText: String { keys.joined() }
}

/// Turns the raw AXMenuItemCmd* attributes into readable key caps.
enum KeyFormatter {
    // AXMenuItemCmdModifiers bits (Carbon kMenu*Modifier), plus bit 16 for the Globe (fn)
    // key, which macOS uses for full screen and window tiling and which is not documented
    // anywhere: "Exit Full Screen" reports 24 (globe + no command) and "Fill" reports 28
    // (globe + control + no command).
    private static let shiftBit = 1, optionBit = 2, controlBit = 4, noCommandBit = 8, globeBit = 16

    static func keys(cmdChar: String?, virtualKey: Int?, glyph: Int?, modifiers: Int?) -> [String]? {
        var key: String?
        if let c = cmdChar, !c.isEmpty { key = charName(c) }
        if key == nil, let g = glyph, g > 0 { key = glyphNames[g] }
        if key == nil, let vk = virtualKey { key = virtualKeyNames[vk] }
        guard let key else { return nil }

        let m = modifiers ?? 0
        var out: [String] = []
        if m & globeBit != 0 { out.append("🌐") }   // Apple writes it first: "Globe–Control–F"
        if m & controlBit != 0 { out.append("⌃") }
        if m & optionBit != 0 { out.append("⌥") }
        if m & shiftBit != 0 { out.append("⇧") }
        if m & noCommandBit == 0 { out.append("⌘") }
        out.append(key)
        return out
    }

    private static func charName(_ c: String) -> String? {
        guard let scalar = c.unicodeScalars.first else { return nil }
        switch scalar.value {
        case 0x20: return "Space"
        case 0x08, 0x7F: return "⌫"
        case 0x0D, 0x03: return "↩"
        case 0x09: return "⇥"
        case 0x1B: return "⎋"
        case 0xF700: return "↑"
        case 0xF701: return "↓"
        case 0xF702: return "←"
        case 0xF703: return "→"
        case 0xF704...0xF71B: return "F\(scalar.value - 0xF704 + 1)"
        case 0xF728: return "⌦"
        case 0xF729: return "↖"
        case 0xF72B: return "↘"
        case 0xF72C: return "⇞"
        case 0xF72D: return "⇟"
        default: return c.uppercased()
        }
    }

    // Carbon kMenu*Glyph values
    private static let glyphNames: [Int: String] = [
        0x02: "⇥", 0x03: "⇤", 0x04: "⌤", 0x09: "Space", 0x0A: "⌦", 0x0B: "↩", 0x0C: "↩",
        0x17: "⌫", 0x1B: "⎋", 0x1C: "⌧", 0x62: "⇞", 0x63: "⇪", 0x64: "←", 0x65: "→",
        0x66: "↖", 0x67: "?⃝", 0x68: "↑", 0x69: "↘", 0x6A: "↓", 0x6B: "⇟",
        0x6F: "F1", 0x70: "F2", 0x71: "F3", 0x72: "F4", 0x73: "F5", 0x74: "F6", 0x75: "F7",
        0x76: "F8", 0x77: "F9", 0x78: "F10", 0x79: "F11", 0x7A: "F12",
        0x87: "F13", 0x88: "F14", 0x89: "F15", 0x8C: "⏏",
    ]

    // Only non-character keys; letter keys come through cmdChar.
    private static let virtualKeyNames: [Int: String] = [
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x24: "↩", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x35: "⎋", 0x75: "⌦",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑", 0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟",
    ]

    static func normalize(_ title: String) -> String {
        title.replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
