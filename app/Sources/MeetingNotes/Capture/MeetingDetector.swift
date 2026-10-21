import AppKit
import CoreAudio

/// Event-driven detection of known meeting apps using the microphone (CoreAudio process objects, macOS 14.2+).
///
/// No polling while idle: property listeners on the default input device (`DeviceIsRunningSomewhere`),
/// the default-input selection, the process object list and each known app's `IsRunningInput` trigger a
/// debounced rescan. While recording, `watch(_:)` also arms a cheap 15 s safety rescan, because our own
/// capture keeps the input device running.
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

    /// Main queue: a known app started a microphone session.
    var onStart: ((App) -> Void)?
    /// Main queue: a known app stopped using the microphone.
    var onStop: ((App) -> Void)?
    /// Main queue: the watched app stopped using the microphone (confirmed after a few seconds).
    var onWatchedAppEnded: ((App) -> Void)?
    /// Main-queue snapshot of known apps currently using the microphone.
    private(set) var activeApps: [App] = []

    private let queue = DispatchQueue(label: "meetingnotes.detector", qos: .utility)
    // Queue-confined state.
    private var running = false
    private var active: [String: App] = [:]
    private var inputDevice = AudioObjectID(kAudioObjectUnknown)
    private var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var scanScheduled = false
    private var watched: App?
    private var watchMissingSince: Date?
    private var safetyTimer: DispatchSourceTimer?
    private var confirmWork: DispatchWorkItem?

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    static func match(bundleID: String) -> String? {
        knownApps.first { bundleID == $0.prefix || bundleID.hasPrefix($0.prefix + ".") }?.name
    }

    func start() {
        guard Self.isSupported else { return }
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.addSystemListeners()
            self.attachInputDevice()
            self.scan()
        }
    }

    func stop() {
        queue.async {
            guard self.running else { return }
            self.running = false
            self.removeAllListeners()
            self.active = [:]
            self.watched = nil
            self.stopSafetyTimer()
            DispatchQueue.main.async { self.activeApps = [] }
        }
    }

    /// While recording: report when `app` stops using the microphone. nil stops watching.
    func watch(_ app: App?) {
        queue.async {
            self.watched = app
            self.watchMissingSince = nil
            if app != nil, self.running {
                self.startSafetyTimer()
            } else {
                self.stopSafetyTimer()
            }
        }
    }

    /// Re-reads the process list (e.g. after our own recording stopped).
    func rescan() {
        queue.async { if self.running { self.scheduleScan() } }
    }

    // MARK: - Scanning (queue)

    private func scheduleScan(after delay: Double = 0.5) {
        guard !scanScheduled else { return }
        scanScheduled = true
        queue.asyncAfter(deadline: .now() + delay) {
            self.scanScheduled = false
            if self.running { self.scan() }
        }
    }

    private func scan() {
        let ownPID = getpid()
        let processes = Self.knownProcesses()
        updateProcessListeners(Set(processes.map(\.object)))

        var current: [String: App] = [:]
        for process in processes where process.pid != ownPID && process.runningInput {
            if current[process.app.name] == nil { current[process.app.name] = process.app }
        }
        let started = current.filter { active[$0.key] == nil }.map(\.value)
        let stopped = active.filter { current[$0.key] == nil }.map(\.value)
        active = current
        let snapshot = current.values.sorted { $0.name < $1.name }

        var ended: App?
        if let watched {
            if current[watched.name] != nil {
                watchMissingSince = nil
            } else if let since = watchMissingSince {
                if Date().timeIntervalSince(since) >= 6 {
                    ended = watched
                    self.watched = nil
                    watchMissingSince = nil
                    stopSafetyTimer()
                }
            } else {
                // Confirm a few seconds later: apps briefly drop the mic when switching devices.
                watchMissingSince = Date()
                confirmWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.running, self.watched != nil else { return }
                    self.scan()
                }
                confirmWork = work
                queue.asyncAfter(deadline: .now() + 7, execute: work)
            }
        }

        DispatchQueue.main.async {
            self.activeApps = snapshot
            stopped.forEach { self.onStop?($0) }
            started.forEach { self.onStart?($0) }
            if let ended { self.onWatchedAppEnded?(ended) }
        }
    }

    private func startSafetyTimer() {
        guard safetyTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(3))
        timer.setEventHandler { [weak self] in self?.scheduleScan(after: 0) }
        timer.resume()
        safetyTimer = timer
    }

    private func stopSafetyTimer() {
        safetyTimer?.cancel()
        safetyTimer = nil
    }

    // MARK: - Listeners (queue)

    private func addSystemListeners() {
        let selectors = [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyProcessObjectList]
        for selector in selectors {
            var address = Self.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, self.running else { return }
                if selector == kAudioHardwarePropertyDefaultInputDevice { self.attachInputDevice() }
                self.scheduleScan()
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block) == noErr {
                systemListeners.append((address, block))
            }
        }
    }

    private func attachInputDevice() {
        if let deviceListener, inputDevice != kAudioObjectUnknown {
            var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(inputDevice, &address, queue, deviceListener)
        }
        deviceListener = nil
        inputDevice = Self.defaultInputDevice()
        guard inputDevice != kAudioObjectUnknown else { return }
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleScan() }
        if AudioObjectAddPropertyListenerBlock(inputDevice, &address, queue, block) == noErr {
            deviceListener = block
        }
    }

    private func updateProcessListeners(_ objects: Set<AudioObjectID>) {
        guard #available(macOS 14.2, *) else { return }
        var address = Self.address(kAudioProcessPropertyIsRunningInput)
        for (object, block) in processListeners where !objects.contains(object) {
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
            processListeners[object] = nil
        }
        for object in objects where processListeners[object] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleScan() }
            if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
                processListeners[object] = block
            }
        }
    }

    private func removeAllListeners() {
        for (address, block) in systemListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
        systemListeners = []
        if let deviceListener, inputDevice != kAudioObjectUnknown {
            var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(inputDevice, &address, queue, deviceListener)
        }
        deviceListener = nil
        updateProcessListeners([])
    }

    // MARK: - CoreAudio

    private struct KnownProcess {
        let object: AudioObjectID
        let pid: pid_t
        let app: App
        let runningInput: Bool
    }

    private static func knownProcesses() -> [KnownProcess] {
        guard #available(macOS 14.2, *) else { return [] }
        return processObjects().compactMap { id in
            let pid = readPID(id)
            var bundleID = readString(id, kAudioProcessPropertyBundleID) ?? ""
            if bundleID.isEmpty, pid > 0 {
                bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            }
            guard let name = match(bundleID: bundleID) else { return nil }
            return KnownProcess(object: id, pid: pid, app: App(name: name, bundleID: bundleID),
                                runningInput: readUInt32(id, kAudioProcessPropertyIsRunningInput) == 1)
        }
    }

    /// Debug aid (`--list-mic-clients`): every process currently capturing microphone input.
    static func processesCapturingInput() -> [(pid: pid_t, bundleID: String)] {
        guard #available(macOS 14.2, *) else { return [] }
        return processObjects().compactMap { id in
            guard readUInt32(id, kAudioProcessPropertyIsRunningInput) == 1 else { return nil }
            let pid = readPID(id)
            var bundleID = readString(id, kAudioProcessPropertyBundleID) ?? ""
            if bundleID.isEmpty, pid > 0 {
                bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            }
            return (pid, bundleID)
        }
    }

    @available(macOS 14.2, *)
    private static func processObjects() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func defaultInputDevice() -> AudioObjectID {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func readPID(_ id: AudioObjectID) -> pid_t {
        guard #available(macOS 14.2, *) else { return -1 }
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        var address = address(kAudioProcessPropertyPID)
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &pid)
        return pid
    }

    private static func readUInt32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func readString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
