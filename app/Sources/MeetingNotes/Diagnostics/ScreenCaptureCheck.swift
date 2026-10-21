import AppKit
import CoreGraphics
import Foundation
import MeetingNotesUI
import ScreenCaptureKit

/// Hidden diagnostic: `MeetingNotes --check-screen-capture <file>`.
enum ScreenCaptureCheck {
    static func runAndExit(writingTo url: URL) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let probe = await Permissions.probeScreenCapture()
            let lines = [
                "time: \(ISO8601DateFormatter().string(from: Date()))",
                "pid: \(getpid())",
                "version: \(AppInfo.versionString)",
                "bundle: \(Bundle.main.bundleIdentifier ?? "-") \(Bundle.main.bundlePath)",
                "CGPreflightScreenCaptureAccess: \(CGPreflightScreenCaptureAccess())",
                "SCShareableContent: \(probe.shareableOK ? "ok (\(probe.displays) displays)" : "failed: \(probe.error ?? "-")")",
                "result: \(probe.granted ? "granted" : "denied")",
            ]
            try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            exit(probe.granted ? 0 : 1)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { exit(3) }
        app.run()
        exit(0)
    }
}
