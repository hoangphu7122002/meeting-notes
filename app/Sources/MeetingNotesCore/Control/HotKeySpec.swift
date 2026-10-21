import Carbon.HIToolbox

/// Parsed hotkey such as `ctrl+opt+cmd+r` (modifiers: ctrl/control, opt/option/alt, shift, cmd/command;
/// key: a-z, 0-9, f1-f12, space). At least one of ctrl/opt/cmd is required.
public struct HotKeySpec: Equatable, Sendable {
    public let keyCode: UInt32
    public let carbonModifiers: UInt32
    /// e.g. "⌃⌥⌘R".
    public let display: String
    /// Menu key equivalent (lowercase character), nil for keys menus cannot show.
    public let keyEquivalent: String?
    public let control: Bool
    public let option: Bool
    public let shift: Bool
    public let command: Bool

    public static let defaultRecord = "ctrl+opt+cmd+r"
    public static let defaultPause = "ctrl+opt+cmd+p"

    public static func parse(_ text: String) -> HotKeySpec? {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, let key = keys[keyName] else { return nil }
        var control = false, option = false, shift = false, command = false
        for modifier in parts.dropLast() {
            switch modifier {
            case "ctrl", "control", "⌃": control = true
            case "opt", "option", "alt", "⌥": option = true
            case "shift", "⇧": shift = true
            case "cmd", "command", "⌘": command = true
            default: return nil
            }
        }
        guard control || option || command else { return nil }

        var carbon: UInt32 = 0
        var display = ""
        if control { carbon |= UInt32(controlKey); display += "⌃" }
        if option { carbon |= UInt32(optionKey); display += "⌥" }
        if shift { carbon |= UInt32(shiftKey); display += "⇧" }
        if command { carbon |= UInt32(cmdKey); display += "⌘" }
        return HotKeySpec(keyCode: UInt32(key.code), carbonModifiers: carbon, display: display + key.label,
                          keyEquivalent: key.equivalent, control: control, option: option, shift: shift, command: command)
    }

    private struct Key {
        let code: Int
        let label: String
        let equivalent: String?
    }

    private static let keys: [String: Key] = {
        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
            ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
            ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
            ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
            ("z", kVK_ANSI_Z), ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
            ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8),
            ("9", kVK_ANSI_9),
        ]
        var table: [String: Key] = [:]
        for (name, code) in letters {
            table[name] = Key(code: code, label: name.uppercased(), equivalent: name)
        }
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (index, code) in functionKeys.enumerated() {
            table["f\(index + 1)"] = Key(code: code, label: "F\(index + 1)", equivalent: nil)
        }
        table["space"] = Key(code: kVK_Space, label: "Space", equivalent: " ")
        return table
    }()
}
