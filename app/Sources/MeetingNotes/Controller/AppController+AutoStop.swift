// Auto-stop on silence or when the meeting app ends (Controller).

import AppKit
import MeetingNotesCore
import MeetingNotesUI

extension AppController {
    func promptAutoStop(_ prompt: AutoStopPrompt) {
        autoStop = prompt
        ui?.showAutoStopCard(prompt)
    }

    func dismissAutoStop() {
        guard autoStop != nil else { return }
        autoStop = nil
        ui?.showAutoStopCard(nil)
    }

    func autoStopNow() {
        dismissAutoStop()
        perform(.stop, source: .autoStop)
    }

    func keepRecording() {
        dismissAutoStop()
        silence.reset()
    }

    func watchedAppEnded(_ app: MeetingDetector.App) {
        guard machine.phase == .recording, autoStop == nil, Settings.autoStopOnCallEnd else { return }
        promptAutoStop(AutoStopPrompt(reason: tr(.autoStopAppEnded, app.name), remaining: 60, appEnded: true))
    }
}
