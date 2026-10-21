// MeetingDetector: CoreAudio process-object queries (Capture).

import AppKit
import CoreAudio

extension MeetingDetector {
    struct KnownProcess {
        let object: AudioObjectID
        let pid: pid_t
        let app: App
        let runningInput: Bool
    }

    static func knownProcesses() -> [KnownProcess] {
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

    static func defaultInputDevice() -> AudioObjectID {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
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
