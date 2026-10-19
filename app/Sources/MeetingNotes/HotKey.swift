import AppKit
import Carbon.HIToolbox
import MeetingNotesCore
import MeetingNotesUI

/// System-wide hotkey via Carbon `RegisterEventHotKey` (no Accessibility permission required).
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    let spec: HotKeySpec
    private let id: UInt32
    private var ref: EventHotKeyRef?

    /// Returns nil when the combination cannot be registered (e.g. already taken by another app).
    init?(spec: HotKeySpec, handler: @escaping () -> Void) {
        Self.installHandlerIfNeeded()
        self.spec = spec
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

extension NSMenuItem {
    /// Shows a global hotkey next to a menu item.
    func setHotKey(_ spec: HotKeySpec?) {
        guard let spec, let key = spec.keyEquivalent else { return }
        keyEquivalent = key
        var mask: NSEvent.ModifierFlags = []
        if spec.control { mask.insert(.control) }
        if spec.option { mask.insert(.option) }
        if spec.shift { mask.insert(.shift) }
        if spec.command { mask.insert(.command) }
        keyEquivalentModifierMask = mask
    }
}
