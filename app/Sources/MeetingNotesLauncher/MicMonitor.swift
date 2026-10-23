// Default-input "running somewhere" listener and a one-shot list of processes capturing input (Launcher).
// Event-driven: CoreAudio calls back on the main queue; nothing polls.

import AppKit
import CoreAudio

final class MicMonitor {
    /// Main queue: the default input device went from idle to running (some process opened the mic).
    var onStarted: (() -> Void)?
    /// Main queue: the default input device went from running to idle.
    var onStopped: (() -> Void)?

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private var wasRunning = false

    func start() {
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.attach() }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
            defaultListener = block
        }
        attach()
    }

    /// True while any process captures from the default input device.
    var isRunning: Bool {
        guard device != kAudioObjectUnknown else { return false }
        return Self.readUInt32(device, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1
    }

    /// Bundle IDs of processes capturing microphone input now (CoreAudio process objects, macOS 14.2+).
    static func captureBundleIDs() -> [String] {
        guard #available(macOS 14.2, *) else { return [] }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).compactMap { id in
            guard readUInt32(id, kAudioProcessPropertyIsRunningInput) == 1 else { return nil }
            if let bundleID = readString(id, kAudioProcessPropertyBundleID), !bundleID.isEmpty { return bundleID }
            var pid: pid_t = -1
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = Self.address(kAudioProcessPropertyPID)
            _ = AudioObjectGetPropertyData(id, &pidAddress, 0, nil, &pidSize, &pid)
            return pid > 0 ? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier : nil
        }
    }

    // MARK: - Private

    private func attach() {
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        if let deviceListener, device != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, deviceListener)
        }
        deviceListener = nil
        device = Self.defaultInputDevice()
        wasRunning = isRunning
        guard device != kAudioObjectUnknown else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.runningChanged() }
        if AudioObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr {
            deviceListener = block
        }
    }

    private func runningChanged() {
        let running = isRunning
        defer { wasRunning = running }
        if running && !wasRunning { onStarted?() }  // rising edge only: stopping never opens the app
        if !running && wasRunning { onStopped?() }
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
