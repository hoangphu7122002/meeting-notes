// Meeting detection: offers to start notes when a meeting app uses the mic (Controller).

import AppKit
import MeetingNotesCore
import MeetingNotesUI

extension AppController {
    func meetingAppStarted(_ app: MeetingDetector.App) {
        guard Settings.detectionEnabled, machine.phase == .idle else { return }
        if let until = Settings.detectionSnoozeUntil, until > Date() { return }
        detectedApp = app
        ui?.showDetectionCard(app)
    }

    func meetingAppStopped(_ app: MeetingDetector.App) {
        guard detectedApp == app else { return }
        detectedApp = nil
        ui?.showDetectionCard(nil)
    }

    func detectionStart() {
        let app = detectedApp
        ui?.showDetectionCard(nil)
        startRecording(app: app, source: .detection)
    }

    func detectionDismiss(snooze: Bool) {
        if snooze { Settings.detectionSnoozeUntil = Date().addingTimeInterval(3600) }
        detectedApp = nil
        ui?.showDetectionCard(nil)
    }

    func setDetectionEnabled(_ enabled: Bool) {
        Settings.detectionEnabled = enabled
        if enabled {
            detector.start()
        } else {
            detector.stop()
            detectionDismiss(snooze: false)
        }
    }
}
