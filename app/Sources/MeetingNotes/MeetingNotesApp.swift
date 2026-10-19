import SwiftUI

struct MeetingNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: appDelegate.state)
        } label: {
            MenuBarLabel(state: appDelegate.state)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // No Dock icon even when run unbundled (`swift run`); the bundle sets LSUIElement too.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.launch()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard state.needsGracefulShutdown else {
            state.shutdownNow()
            return .terminateNow
        }
        Task {
            await state.prepareForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

// MARK: - Menu bar label

struct MenuBarLabel: View {
    @ObservedObject var state: AppState

    var body: some View {
        if state.isRecording {
            HStack(spacing: 4) {
                Image(nsImage: Self.redDot)
                Text(state.elapsedText).monospacedDigit()
            }
        } else if let processing = state.processing {
            HStack(spacing: 4) {
                Image(systemName: "gearshape.2")
                Text(processing.percentText).monospacedDigit()
            }
        } else if state.phase == .starting {
            Image(systemName: "ellipsis.circle")
        } else {
            Image(systemName: state.detectedApp == nil ? "waveform" : "waveform.circle.fill")
        }
    }

    private static let redDot: NSImage = {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }()
}

// MARK: - Menu

struct MenuContent: View {
    @ObservedObject var state: AppState

    var body: some View {
        recordingSection
        Divider()
        statusSection
        Divider()
        recentsSection
        Button("Open Notes Folder") { state.openNotesFolder() }
        Divider()
        settingsMenu
        Divider()
        Button("Quit Meeting Notes") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder private var recordingSection: some View {
        switch state.phase {
        case .idle:
            Button("Start Recording") { state.toggleRecording() }
                .hotkeyShortcut(state.hotkey)
            if let app = state.detectedApp {
                Text("Meeting detected: \(app.name)")
                Button("Record \(app.name) Meeting") { state.startFromDetection(appName: app.name) }
            }
        case .starting:
            Text("Starting recording…")
        case .recording:
            Button("Stop Recording (\(state.elapsedText))") { state.toggleRecording() }
                .hotkeyShortcut(state.hotkey)
            if let folder = state.recordingFolder {
                Text("Recording to \(folder.lastPathComponent)")
            }
        case .stopping:
            Text("Finishing recording…")
        }
        ForEach(state.recordingWarnings, id: \.self) { warning in
            Label(Self.clip(warning), systemImage: "exclamationmark.triangle")
        }
    }

    @ViewBuilder private var statusSection: some View {
        if let processing = state.processing {
            Text("Processing \(processing.folder.lastPathComponent)")
            Text(Self.clip(processing.summary))
        } else {
            Text("No processing in progress")
        }
        if !state.queuedFolders.isEmpty {
            Text("\(state.queuedFolders.count) more queued")
        }
        if let error = state.lastError {
            Label(Self.clip(error), systemImage: "xmark.octagon")
            Button("Clear Error") { state.lastError = nil }
        }
    }

    @ViewBuilder private var recentsSection: some View {
        Section("Recent Meetings") {
            if state.recents.isEmpty {
                Text("No meetings yet")
            }
            ForEach(state.recents) { meeting in
                Menu("\(Self.clip(meeting.title, 48)) — \(meeting.status.label)") {
                    Button("Open Notes") { state.open(meeting.notesURL) }
                        .disabled(!meeting.hasNotes)
                    Button("Show in Finder") { state.reveal(meeting.url) }
                    Button("Reprocess") { state.enqueue(meeting.url) }
                        .disabled(meeting.isBusy)
                    if meeting.hasLog {
                        Button("Show Pipeline Log") { state.open(meeting.logURL) }
                    }
                    if case .failed(let error?) = meeting.status {
                        Divider()
                        Text(Self.clip(error))
                    }
                }
            }
        }
    }

    private var settingsMenu: some View {
        Menu("Settings") {
            Toggle("Launch at Login", isOn: Binding(get: { state.loginItemEnabled }, set: { state.setLaunchAtLogin($0) }))
            Text("Login item: \(state.loginItemStatus)")
            if let error = state.loginItemError {
                Text(Self.clip("Login item error: \(error)"))
            }
            Divider()
            Toggle("Detect Meetings", isOn: Binding(get: { state.detectionEnabled }, set: { state.setDetectionEnabled($0) }))
            if !MeetingDetector.isSupported {
                Text("Meeting detection requires macOS 14.2")
            }
            Divider()
            Text("Notes folder: \((state.notesDir.path as NSString).abbreviatingWithTildeInPath)")
            Button("Change Notes Folder…") { state.chooseNotesFolder() }
            Button("Use Default Notes Folder") { state.resetNotesFolder() }
                .disabled(state.notesDir.standardizedFileURL == Settings.defaultNotesDir.standardizedFileURL)
            Divider()
            Text("Hotkey: \(state.hotkey?.display ?? "none")")
            Text("Version \(AppInfo.versionString)")
        }
        .onAppear { state.refreshLoginItem() }
    }

    private static func clip(_ text: String, _ limit: Int = 90) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        return single.count > limit ? String(single.prefix(limit - 1)) + "…" : single
    }
}

private extension View {
    @ViewBuilder func hotkeyShortcut(_ spec: HotKeySpec?) -> some View {
        if let spec, let key = spec.keyEquivalent {
            keyboardShortcut(key, modifiers: spec.eventModifiers)
        } else {
            self
        }
    }
}
