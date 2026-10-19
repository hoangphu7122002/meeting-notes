import AppKit
import MeetingNotesCore
import SwiftUI

public struct SettingsView: View {
    @ObservedObject var state: AppState
    let commands: any AppCommands
    let detectionSupported: Bool

    @ObservedObject private var language = LanguageModel.shared
    @State private var showInDock = Settings.showInDock
    @State private var showRecordingPill = Settings.showRecordingPill
    @State private var showIdlePill = Settings.showIdlePill
    @State private var detection = Settings.detectionEnabled
    @State private var mode = Settings.createNotesMode
    @State private var model = Settings.summaryModel
    @State private var silenceMinutes = Settings.autoStopSilenceMinutes
    @State private var stopOnCallEnd = Settings.autoStopOnCallEnd
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginStatus = LoginItem.statusText
    @State private var loginError: String?

    public init(state: AppState, commands: any AppCommands, detectionSupported: Bool) {
        self.state = state
        self.commands = commands
        self.detectionSupported = detectionSupported
    }

    public var body: some View {
        Localized {
            Form {
                Section(tr(.sectionGeneral)) {
                    Picker(tr(.language), selection: Binding(get: { language.current }, set: { commands.setLanguage($0) })) {
                        ForEach(UILanguage.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Toggle(tr(.launchAtLogin), isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, value in
                            do {
                                try LoginItem.set(value)
                                loginError = nil
                            } catch {
                                loginError = error.localizedDescription
                            }
                            loginStatus = LoginItem.statusText
                        }
                    Text(tr(.loginItemStatus, loginStatus)).font(.caption).foregroundStyle(.secondary)
                    if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
                    Button(tr(.actionPermissionsEllipsis)) { commands.showMainWindow() }
                    LabeledContent(tr(.version), value: AppInfo.versionString)
                }
                Section(tr(.sectionRecording)) {
                    Toggle(tr(.suggestRecording), isOn: $detection)
                        .onChange(of: detection) { _, value in commands.setDetectionEnabled(value) }
                    if !detectionSupported { Text(tr(.detectionRequires)).foregroundStyle(.secondary) }
                    Picker(tr(.stopAfterSilence), selection: $silenceMinutes) {
                        Text(tr(.off)).tag(0)
                        ForEach([5, 10, 15, 30, 60], id: \.self) { Text(tr(.durMinutes, $0)).tag($0) }
                    }
                    .onChange(of: silenceMinutes) { _, value in Settings.autoStopSilenceMinutes = value }
                    Toggle(tr(.offerStopOnCallEnd), isOn: $stopOnCallEnd)
                        .onChange(of: stopOnCallEnd) { _, value in Settings.autoStopOnCallEnd = value }
                    LabeledContent(tr(.hotkeyStartStopLabel), value: state.hotkey?.display ?? tr(.hotkeyNone))
                    LabeledContent(tr(.hotkeyPauseLabel), value: state.pauseHotkey?.display ?? tr(.hotkeyNone))
                    if let error = state.hotkeyError { Text(error).foregroundStyle(.orange) }
                    Text(tr(.hotkeyChangeHint, AppInfo.bundleID))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Section(tr(.sectionNotes)) {
                    Picker(tr(.createNotesLabel), selection: $mode) {
                        ForEach(CreateNotesMode.allCases, id: \.self) { Text($0.title()).tag($0) }
                    }
                    .onChange(of: mode) { _, value in commands.setCreateNotesMode(value) }
                    Picker(tr(.summaryModelLabel), selection: $model) {
                        ForEach(SummaryModel.allCases, id: \.self) { Text($0.title()).tag($0) }
                    }
                    .onChange(of: model) { _, value in commands.setSummaryModel(value) }
                    LabeledContent(tr(.notesFolder)) {
                        Text((state.notesDir.path as NSString).abbreviatingWithTildeInPath).textSelection(.enabled)
                    }
                    HStack {
                        Button(tr(.actionChange)) { commands.chooseNotesFolder() }
                        Button(tr(.actionUseDefault)) { commands.resetNotesFolder() }
                            .disabled(state.notesDir.standardizedFileURL == Settings.defaultNotesDir.standardizedFileURL)
                        Button(tr(.actionOpen)) { commands.openNotesFolder() }
                    }
                }
                Section(tr(.sectionControls)) {
                    Toggle(tr(.showInDock), isOn: $showInDock)
                        .onChange(of: showInDock) { _, value in commands.setShowInDock(value) }
                    Toggle(tr(.showPillRecording), isOn: $showRecordingPill)
                        .onChange(of: showRecordingPill) { _, _ in
                            commands.setPillVisibility(whileRecording: showRecordingPill, whenIdle: showIdlePill)
                        }
                    Toggle(tr(.showPillIdle), isOn: $showIdlePill)
                        .onChange(of: showIdlePill) { _, _ in
                            commands.setPillVisibility(whileRecording: showRecordingPill, whenIdle: showIdlePill)
                        }
                    Button(tr(.actionResetPillPosition)) { commands.resetPillPosition() }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 540, height: 640)
    }
}
