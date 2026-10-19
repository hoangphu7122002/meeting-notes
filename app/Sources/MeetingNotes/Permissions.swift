import AppKit
import AVFoundation
import CoreGraphics
import IOKit.ps
import MeetingNotesCore
import MeetingNotesUI

enum Permissions {
    static var microphone: PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// Screen & System Audio Recording (needed by ScreenCaptureKit for system audio).
    static var screenCapture: Bool { CGPreflightScreenCaptureAccess() }

    static var allGranted: Bool { microphone == .granted && screenCapture }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Shows the system prompt once; afterwards macOS only allows changing it in System Settings.
    @discardableResult
    static func requestScreenCapture() -> Bool { CGRequestScreenCaptureAccess() }

    static func openSettings(_ kind: PermissionKind) {
        let anchor: String
        switch kind {
        case .microphone: anchor = "Privacy_Microphone"
        case .screenCapture: anchor = "Privacy_ScreenCapture"
        case .notifications:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum HostClock {
    /// Host-clock seconds (same clock as AVAudioTime host times and ScreenCaptureKit timestamps).
    static func now() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
}

/// Inputs of the "When idle and plugged in" processing mode.
enum PowerState {
    static var onACPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }

    /// Seconds since the last keyboard/mouse input.
    static var idleSeconds: Double {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }
}
