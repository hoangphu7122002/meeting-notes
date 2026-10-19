import Carbon.HIToolbox
import SwiftUI

/// Parsed hotkey such as `ctrl+opt+cmd+r` (modifiers: ctrl/control, opt/option/alt, shift, cmd/command;
/// key: a-z, 0-9, f1-f12, space).
struct HotKeySpec {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let display: String
    let keyEquivalent: KeyEquivalent?
    let eventModifiers: SwiftUI.EventModifiers

    static func parse(_ text: String) -> HotKeySpec? {
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
        var events: SwiftUI.EventModifiers = []
        var display = ""
        if control { carbon |= UInt32(controlKey); events.insert(.control); display += "⌃" }
        if option { carbon |= UInt32(optionKey); events.insert(.option); display += "⌥" }
        if shift { carbon |= UInt32(shiftKey); events.insert(.shift); display += "⇧" }
        if command { carbon |= UInt32(cmdKey); events.insert(.command); display += "⌘" }
        return HotKeySpec(keyCode: UInt32(key.code), carbonModifiers: carbon, display: display + key.label,
                          keyEquivalent: key.equivalent, eventModifiers: events)
    }

    private struct Key {
        let code: Int
        let label: String
        let equivalent: KeyEquivalent?
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
            table[name] = Key(code: code, label: name.uppercased(), equivalent: KeyEquivalent(Character(name)))
        }
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (index, code) in functionKeys.enumerated() {
            table["f\(index + 1)"] = Key(code: code, label: "F\(index + 1)", equivalent: nil)
        }
        table["space"] = Key(code: kVK_Space, label: "Space", equivalent: .space)
        return table
    }()
}

/// System-wide hotkey via Carbon `RegisterEventHotKey` (no Accessibility permission required).
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    private let id: UInt32
    private var ref: EventHotKeyRef?

    /// Returns nil when the combination cannot be registered (e.g. already taken by another app).
    init?(spec: HotKeySpec, handler: @escaping () -> Void) {
        Self.installHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D4E_484B), id: id)  // 'MNHK'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(spec.keyCode, spec.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        self.ref = ref
        Self.handlers[id] = handler
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKey.handlers[id]?() }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
