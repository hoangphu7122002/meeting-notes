import AppKit
import CoreAudio

/// Polls CoreAudio process objects (macOS 14.2+) for known meeting apps that capture microphone input.
final class MeetingDetector {
    struct App: Hashable {
        let name: String
        let bundleID: String
    }

    /// Bundle ID prefixes (exact match or followed by ".", e.g. `com.google.Chrome.helper`).
    static let knownApps: [(prefix: String, name: String)] = [
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams2", "Teams"),
        ("com.microsoft.teams", "Teams"),
        ("com.cisco.webexmeetingsapp", "Webex"),
        ("Cisco-Systems.Spark", "Webex"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.hnc.Discord", "Discord"),
        ("com.google.Chrome", "Chrome"),
        ("com.apple.Safari", "Safari"),
        ("com.apple.WebKit.GPU", "Safari"),
        ("company.thebrowser.Browser", "Arc"),
        ("com.microsoft.edgemac", "Edge"),
        ("com.brave.Browser", "Brave"),
        ("org.mozilla.firefox", "Firefox"),
    ]

    /// Called on the main queue when an app starts / stops using the microphone.
    var onStart: ((App) -> Void)?
    var onStop: ((App) -> Void)?
    /// Main-queue snapshot of apps currently using the microphone.
    private(set) var activeApps: [App] = []

    private let queue = DispatchQueue(label: "meetingnotes.detector", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var active: [String: App] = [:]  // queue-confined, keyed by app name

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    func start(interval: TimeInterval = 3) {
        guard timer == nil, Self.isSupported else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: interval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.async { self.active = [:] }
        activeApps = []
    }

    static func match(bundleID: String) -> String? {
        knownApps.first { bundleID == $0.prefix || bundleID.hasPrefix($0.prefix + ".") }?.name
    }

    private func poll() {
        let ownPID = getpid()
        var current: [String: App] = [:]
        for process in Self.processesCapturingInput() where process.pid != ownPID {
            if let name = Self.match(bundleID: process.bundleID), current[name] == nil {
                current[name] = App(name: name, bundleID: process.bundleID)
            }
        }
        let started = current.filter { active[$0.key] == nil }.map(\.value)
        let stopped = active.filter { current[$0.key] == nil }.map(\.value)
        active = current
        let snapshot = current.values.sorted { $0.name < $1.name }
        DispatchQueue.main.async {
            guard self.timer != nil else { return }
            self.activeApps = snapshot
            stopped.forEach { self.onStop?($0) }
            started.forEach { self.onStart?($0) }
        }
    }

    // MARK: - CoreAudio

    static func processesCapturingInput() -> [(pid: pid_t, bundleID: String)] {
        guard #available(macOS 14.2, *) else { return [] }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        ids = Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))

        return ids.compactMap { id in
            guard readUInt32(id, kAudioProcessPropertyIsRunningInput) == 1 else { return nil }
            var pid: pid_t = -1
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectGetPropertyData(id, &pidAddress, 0, nil, &pidSize, &pid)
            var bundleID = readString(id, kAudioProcessPropertyBundleID) ?? ""
            if bundleID.isEmpty, pid > 0 {
                bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            }
            return (pid, bundleID)
        }
    }

    private static func readUInt32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func readString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
