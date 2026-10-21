// Hotkeys, URL scheme commands and pill visibility (Controller).

import AppKit
import MeetingNotesCore
import MeetingNotesUI

extension AppController {
    func registerHotKeys() {
        hotKeys = []
        hotkeyError = nil
        hotkey = register(Settings.hotkey, fallback: HotKeySpec.defaultRecord, command: .toggleRecording)
        pauseHotkey = register(Settings.pauseHotkey, fallback: HotKeySpec.defaultPause, command: .togglePause)
    }

    private func register(_ text: String, fallback: String, command: RecorderCommand) -> HotKeySpec? {
        var spec = HotKeySpec.parse(text)
        if spec == nil {
            hotkeyError = tr(.hotkeyInvalid, text, fallback)
            spec = HotKeySpec.parse(fallback)
        }
        guard let spec else { return nil }
        if let registration = HotKey(spec: spec, handler: { [weak self] in
            MainActor.assumeIsolated { self?.perform(command, source: .hotkey) }
        }) {
            hotKeys.append(registration)
        } else {
            hotkeyError = tr(.hotkeyUnavailable, spec.display)
        }
        return spec
    }

    func handle(_ command: URLCommand) {
        switch command {
        case .start: startRecording(source: .url)
        case .stop: perform(.stop, source: .url)
        case .pause: perform(.pause, source: .url)
        case .resume: perform(.resume, source: .url)
        case .toggle: perform(.toggleRecording, source: .url)
        case .show: ui?.showMainWindow()
        }
    }

    func hidePillForAnHour() {
        Settings.pillHiddenUntil = Date().addingTimeInterval(3600)
        scheduleIdlePillReshow()
        ui?.hidePill()
        ui?.showToast(tr(.toastHiddenHour))
    }

    func unhidePill() {
        Settings.pillHiddenUntil = nil
        idlePillTimer?.cancel()
    }

    func scheduleIdlePillReshow() {
        idlePillTimer?.cancel()
        guard let until = Settings.pillHiddenUntil, until > Date() else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                Settings.pillHiddenUntil = nil
                self?.ui?.pillStateChanged()
            }
        }
        idlePillTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + until.timeIntervalSinceNow + 1, execute: item)
    }
}
