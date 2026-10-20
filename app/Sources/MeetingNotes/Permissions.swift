import AppKit
import AVFoundation
import CoreGraphics
import IOKit.ps
import MeetingNotesCore
import MeetingNotesUI
import ScreenCaptureKit

enum Permissions {
    static var microphone: PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// Screen & System Audio Recording (needed by ScreenCaptureKit for system audio), fast path only.
    /// `CGPreflightScreenCaptureAccess` can stay false on macOS 15 while capture works, so a false
    /// here is confirmed with `probeScreenCapture()` before telling the user it is missing.
    static var screenCapturePreflight: Bool { CGPreflightScreenCaptureAccess() }

    struct ScreenCaptureProbe: Sendable {
        var granted: Bool
        /// SCShareableContent answered: ScreenCaptureKit really has access.
        var shareableOK: Bool
        var displays: Int
        /// The failure was a TCC denial (not some other ScreenCaptureKit error).
        var declined: Bool
        var error: String?
    }

    /// Asks ScreenCaptureKit itself. Success means system audio capture is allowed whatever the
    /// preflight says; only a "user declined" error counts as denied, other errors fall back to the preflight.
    static func probeScreenCapture() async -> ScreenCaptureProbe {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return ScreenCaptureProbe(granted: true, shareableOK: true, displays: content.displays.count, declined: false, error: nil)
        } catch {
            let declined = isPermissionError(error)
            return ScreenCaptureProbe(granted: declined ? false : CGPreflightScreenCaptureAccess(), shareableOK: false,
                                      displays: 0, declined: declined,
                                      error: "\((error as NSError).domain) \((error as NSError).code): \(error.localizedDescription)")
        }
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SCStreamErrorDomain && nsError.code == SCStreamError.userDeclined.rawValue
    }

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
