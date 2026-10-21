// Host clock and power/idle state inputs (System).

import AVFoundation
import CoreGraphics
import IOKit.ps

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
