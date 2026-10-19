import AppKit
import MeetingNotesCore
import SwiftUI
import UserNotifications

/// Permission checklist + a 5 s capture test (nothing written to disk).
@MainActor
final class OnboardingModel: ObservableObject {
    @Published private(set) var microphone = Permissions.microphone
    @Published private(set) var screenCapture = Permissions.screenCapture
    @Published private(set) var notifications: UNAuthorizationStatus?
    @Published private(set) var testing = false
    @Published private(set) var testMe: Double = 0
    @Published private(set) var testThem: Double = 0
    @Published private(set) var testResult: String?

    private let controller: AppController
    private var testTimer: Timer?

    init(controller: AppController) {
        self.controller = controller
        refresh()
    }

    func refresh() {
        microphone = Permissions.microphone
        screenCapture = Permissions.screenCapture
        controller.notifier.status { [weak self] status in self?.notifications = status }
        controller.refreshPermissions()
    }

    func requestMicrophone() {
        if microphone == .notDetermined {
            Task { @MainActor in
                _ = await Permissions.requestMicrophone()
                refresh()
            }
        } else {
            Permissions.openSettings(.microphone)
        }
    }

    func requestScreenCapture() {
        if !Permissions.requestScreenCapture() { Permissions.openSettings(.screenCapture) }
        refresh()
    }

    func requestNotifications() {
        if notifications == .notDetermined {
            controller.notifier.requestAuthorization { [weak self] _ in self?.refresh() }
        } else {
            Permissions.openSettings(.notifications)
        }
    }

    /// Captures mic + system audio for 5 s and plays a system sound from a separate process
    /// (captured despite `excludesCurrentProcessAudio`).
    func runTest() {
        guard !testing, controller.machine.phase == .idle else {
            testResult = "Stop the recording first."
            return
        }
        testing = true
        testResult = nil
        testMe = 0
        testThem = 0
        let micSink = MeterSink()
        let systemSink = MeterSink()
        let mic = MicRecorder(sink: micSink)
        let system = SystemAudioCapture(sink: systemSink)
        Task { @MainActor in
            var micError: String?
            var systemError: String?
            if await MicRecorder.ensurePermission() {
                do { try mic.start() } catch { micError = error.localizedDescription }
            } else {
                micError = "Microphone access denied"
            }
            do { try await system.start() } catch { systemError = "System audio not permitted" }
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.testMe = LevelMeter.displayValue(micSink.meter.level())
                    self?.testThem = LevelMeter.displayValue(systemSink.meter.level())
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            testTimer = timer
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = ["/System/Library/Sounds/Glass.aiff"]
            try? player.run()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            timer.invalidate()
            testTimer = nil
            mic.stop()
            await system.stop()
            let me = micError ?? (micSink.peakDB > -60 ? "Me: OK (level \(Int(micSink.peakDB)) dB)" : "Me: silent – check the input device")
            let them = systemError ?? (systemSink.peakDB > -60 ? "Them: OK (heard the test sound)" : "Them: nothing heard – check Screen & System Audio Recording")
            testResult = "\(micError.map { "Me: \($0)" } ?? me)\n\(them)"
            testMe = 0
            testThem = 0
            testing = false
            refresh()
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var controller: AppController
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Set up Meeting Notes").font(.title2.weight(.semibold))
                Text("Everything runs on this Mac. Grant two permissions, then test them.").foregroundStyle(.secondary)

                PermissionCard(
                    title: "Microphone", detail: "Records your voice (\"Me\").",
                    status: model.microphone.text, granted: model.microphone == .granted,
                    action: model.microphone == .notDetermined ? "Request" : "Open Settings", perform: model.requestMicrophone)
                PermissionCard(
                    title: "Screen & System Audio Recording",
                    detail: "Records the other participants (\"Them\"). Only audio is captured. After enabling it, quit and reopen Meeting Notes.",
                    status: model.screenCapture ? "Allowed" : "Not allowed", granted: model.screenCapture,
                    action: "Open Settings", perform: model.requestScreenCapture)
                PermissionCard(
                    title: "Notifications (optional)", detail: "\"Notes ready\" banners. The pill shows the same.",
                    status: notificationText, granted: model.notifications == .authorized,
                    action: model.notifications == .notDetermined ? "Request" : "Open Settings", perform: model.requestNotifications)

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Test (5 s)").font(.headline)
                            Spacer()
                            Button(model.testing ? "Testing…" : "Run test", action: model.runTest).disabled(model.testing)
                        }
                        Text("Records nothing to disk. Plays a short sound to check system audio.").font(.caption).foregroundStyle(.secondary)
                        TestMeter(label: "Me", value: model.testMe)
                        TestMeter(label: "Them", value: model.testThem)
                        if let result = model.testResult { Text(result).font(.callout) }
                    }
                    .padding(4)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("How it works").font(.headline)
                        Text("• A small pill sits at the bottom of the screen. Hover or click it to open it; recording only starts or stops through its labelled buttons (Start, Pause, Stop & create notes, Discard).")
                        Text("• Hotkeys: \(controller.hotkey?.display ?? "⌃⌥⌘R") start/stop, \(controller.pauseHotkey?.display ?? "⌃⌥⌘P") pause/resume.")
                        Text("• Right-click the Dock icon for the same controls. The menu bar icon is optional.")
                        Text("• After you stop, notes are written in the background; the pill shows each step.")
                    }
                    .font(.callout)
                    .padding(4)
                }

                HStack {
                    Spacer()
                    Button("Done", action: onDone).keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 520, height: 640)
    }

    private var notificationText: String {
        switch model.notifications {
        case .authorized, .provisional: return "Allowed"
        case .denied: return "Not allowed"
        case .notDetermined: return "Not asked yet"
        default: return "Unavailable"
        }
    }
}

struct PermissionCard: View {
    let title: String
    let detail: String
    let status: String
    let granted: Bool
    let action: String
    let perform: () -> Void

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(granted ? .green : .orange).font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(status).font(.caption).foregroundStyle(granted ? .green : .orange)
                }
                Spacer()
                if !granted { Button(action, action: perform) }
            }
            .padding(4)
        }
    }
}

struct TestMeter: View {
    let label: String
    let value: Double

    var body: some View {
        HStack {
            Text(label).frame(width: 44, alignment: .leading)
            ProgressView(value: value).progressViewStyle(.linear)
        }
    }
}
