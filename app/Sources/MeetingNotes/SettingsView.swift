import AppKit
import MeetingNotesCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: AppController
    let hub: UIHub

    @State private var showInDock = Settings.showInDock
    @State private var showIdlePill = Settings.showIdlePill
    @State private var detection = Settings.detectionEnabled
    @State private var mode = Settings.createNotesMode
    @State private var model = Settings.summaryModel
    @State private var silenceMinutes = Settings.autoStopSilenceMinutes
    @State private var stopOnCallEnd = Settings.autoStopOnCallEnd
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginStatus = LoginItem.statusText
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Recording") {
                Toggle("Suggest recording when a meeting app uses the microphone", isOn: $detection)
                    .onChange(of: detection) { _, value in controller.setDetectionEnabled(value) }
                if !MeetingDetector.isSupported { Text("Meeting detection requires macOS 14.2").foregroundStyle(.secondary) }
                Picker("Stop after silence", selection: $silenceMinutes) {
                    Text("Off").tag(0)
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
                }
                .onChange(of: silenceMinutes) { _, value in Settings.autoStopSilenceMinutes = value }
                Toggle("Offer to stop when the meeting app releases the microphone", isOn: $stopOnCallEnd)
                    .onChange(of: stopOnCallEnd) { _, value in Settings.autoStopOnCallEnd = value }
                LabeledContent("Start / stop", value: controller.hotkey?.display ?? "none")
                LabeledContent("Pause / resume", value: controller.pauseHotkey?.display ?? "none")
                if let error = controller.hotkeyError { Text(error).foregroundStyle(.orange) }
                Text("Change with `defaults write \(AppInfo.bundleID) hotkey \"ctrl+opt+cmd+r\"` (or `pauseHotkey`), then relaunch.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section("Notes") {
                Picker("Create notes", selection: $mode) {
                    ForEach(CreateNotesMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .onChange(of: mode) { _, value in controller.setCreateNotesMode(value) }
                Picker("Summary model", selection: $model) {
                    ForEach(SummaryModel.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .onChange(of: model) { _, value in controller.setSummaryModel(value) }
                LabeledContent("Notes folder") {
                    Text((controller.notesDir.path as NSString).abbreviatingWithTildeInPath).textSelection(.enabled)
                }
                HStack {
                    Button("Change…") { controller.chooseNotesFolder() }
                    Button("Use default") { controller.resetNotesFolder() }
                        .disabled(controller.notesDir.standardizedFileURL == Settings.defaultNotesDir.standardizedFileURL)
                    Button("Open") { controller.openNotesFolder() }
                }
            }
            Section("Controls") {
                Toggle("Show in Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { _, value in hub.setShowInDock(value) }
                Toggle("Show pill when idle", isOn: $showIdlePill)
                    .onChange(of: showIdlePill) { _, value in
                        Settings.showIdlePill = value
                        if value { controller.unhidePill() }
                        hub.pillStateChanged()
                    }
                Button("Reset pill position") { hub.resetPillPosition() }
            }
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in
                        do {
                            try LoginItem.set(value)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                        loginStatus = LoginItem.statusText
                    }
                Text("Login item: \(loginStatus)").font(.caption).foregroundStyle(.secondary)
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
                Button("Permissions…") { hub.showOnboarding() }
                LabeledContent("Version", value: AppInfo.versionString)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 620)
    }
}
