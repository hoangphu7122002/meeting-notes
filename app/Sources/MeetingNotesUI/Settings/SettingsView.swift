// Settings window: Basics · During meetings · After meetings · Advanced (collapsed). Rules in `SettingsRules` (Core).

import AppKit
import MeetingNotesCore
import SwiftUI

public struct SettingsView: View {
    @ObservedObject var state: AppState
    let commands: any AppCommands
    let detectionSupported: Bool
    let memoryGB: Double
    let version: String
    let defaultNotesDir: URL
    /// Window height: the three basic groups fit, Advanced scrolls when opened. nil = fill (previews).
    let height: CGFloat?

    @ObservedObject private var language = LanguageModel.shared
    @State private var login: LoginItemState
    @State private var loginError: String?
    @State private var detection: Bool
    @State private var silenceMinutes: Int
    @State private var stopOnCallEnd: Bool
    @State private var mode: CreateNotesMode
    @State private var model: SummaryModel
    @State private var liveTranscription: Bool
    @State private var livePolish: Bool
    @State private var showInDock: Bool
    @State private var pillMode: PillMode
    @State private var advancedOpen: Bool

    public init(state: AppState, commands: any AppCommands, detectionSupported: Bool, values: SettingsValues? = nil,
                memoryGB: Double = SettingsValues.physicalMemoryGB, version: String = AppInfo.versionString,
                defaultNotesDir: URL = Settings.defaultNotesDir, advancedOpen: Bool = false, height: CGFloat? = 760) {
        self.state = state
        self.commands = commands
        self.detectionSupported = detectionSupported
        self.memoryGB = memoryGB
        self.version = version
        self.defaultNotesDir = defaultNotesDir
        self.height = height
        let values = values ?? .current()
        _login = State(initialValue: values.login)
        _detection = State(initialValue: values.detection)
        _silenceMinutes = State(initialValue: values.silenceMinutes)
        _stopOnCallEnd = State(initialValue: values.stopOnCallEnd)
        _mode = State(initialValue: values.createNotesMode)
        _model = State(initialValue: values.summaryModel)
        _liveTranscription = State(initialValue: values.liveTranscription)
        _livePolish = State(initialValue: values.livePolish)
        _showInDock = State(initialValue: values.showInDock)
        _pillMode = State(initialValue: values.pillMode)
        _advancedOpen = State(initialValue: advancedOpen)
    }

    private var env: SettingsEnvironment {
        SettingsEnvironment(detectionSupported: detectionSupported, physicalMemoryGB: memoryGB,
                            microphone: state.microphone, screenCapture: state.screenCapture)
    }

    public var body: some View {
        Localized {
            Form {
                Section(tr(.groupBasics)) { basics }
                Section(tr(.groupDuringMeeting)) { duringMeeting }
                Section(tr(.groupAfterMeeting)) { afterMeeting }
                Section {
                    DisclosureGroup(isExpanded: $advancedOpen) { advanced } label: { Text(tr(.groupAdvanced)) }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 540, height: height)
    }

    // MARK: - Groups

    @ViewBuilder private var basics: some View {
        if SettingsRules.showsSetupLink(state.setup) {
            LabeledContent {
                Button(tr(.actionOpenSetup)) { commands.showMainWindow() }
            } label: {
                SettingLabel(tr(.setupUnfinished), help: tr(.helpSetupUnfinished), warning: true)
            }
        }
        let missing = SettingsRules.missingPermissions(env)
        if !missing.isEmpty {
            LabeledContent {
                HStack {
                    ForEach(missing, id: \.self) { kind in
                        Button(tr(kind == .microphone ? .actionGrantMicrophone : .actionGrantSystemAudio)) {
                            commands.fixPermission(kind)
                        }
                    }
                }
            } label: {
                SettingLabel(tr(.missingPermissions), help: tr(.helpMissingPermissions), warning: true)
            }
        }
        Picker(selection: Binding(get: { language.current }, set: { commands.setLanguage($0) })) {
            ForEach(UILanguage.allCases, id: \.self) { Text($0.displayName).tag($0) }
        } label: {
            SettingLabel(tr(.language), help: tr(.helpLanguage))
        }
        Toggle(isOn: Binding(get: { login.isOn }, set: setLaunchAtLogin)) {
            SettingLabel(tr(.launchAtLogin), help: loginError ?? login.note.map { tr($0) } ?? tr(.helpLaunchAtLogin),
                         warning: loginError != nil || login.note != nil)
        }
        .disabled(!login.canToggle)
        if login == .requiresApproval {
            HStack {
                Spacer()
                Button(tr(.actionOpenLoginItems)) { LoginItem.openSystemSettings() }
            }
        }
    }

    @ViewBuilder private var duringMeeting: some View {
        Toggle(isOn: $detection) {
            SettingLabel(tr(.suggestRecording), help: tr(SettingsRules.detectionHelp(env)))
        }
        .disabled(!detectionSupported)
        .onChange(of: detection) { _, value in commands.setDetectionEnabled(value) }

        Toggle(isOn: $stopOnCallEnd) {
            SettingLabel(tr(.stopOnCallEnd), help: tr(SettingsRules.stopOnCallEndHelp(detection: detection, env)))
        }
        .disabled(!SettingsRules.stopOnCallEndEnabled(detection: detection, env))
        .onChange(of: stopOnCallEnd) { _, value in Settings.autoStopOnCallEnd = value }

        Picker(selection: $silenceMinutes) {
            ForEach(SettingsRules.silenceChoices(current: silenceMinutes), id: \.self) {
                Text(SettingsRules.silenceTitle($0)).tag($0)
            }
        } label: {
            SettingLabel(tr(.stopAfterSilence), help: tr(SettingsRules.silenceHelp(minutes: silenceMinutes)))
        }
        .onChange(of: silenceMinutes) { _, value in Settings.autoStopSilenceMinutes = value }

        LabeledContent {
            Text(state.hotkeyHint ?? tr(.hotkeyNone)).foregroundStyle(Palette.secondary).textSelection(.enabled)
        } label: {
            SettingLabel(tr(.shortcutsLabel), help: state.hotkeyError ?? tr(.helpShortcuts), warning: state.hotkeyError != nil)
        }
    }

    @ViewBuilder private var afterMeeting: some View {
        Picker(selection: $mode) {
            ForEach(CreateNotesMode.allCases, id: \.self) { Text($0.title()).tag($0) }
        } label: {
            SettingLabel(tr(.createNotesLabel), help: tr(SettingsRules.createNotesHelp(mode)))
        }
        .onChange(of: mode) { _, value in commands.setCreateNotesMode(value) }

        let summaryHelp = SettingsRules.summaryHelp(model, env)
        Picker(selection: $model) {
            ForEach(SummaryModel.allCases, id: \.self) { Text($0.title()).tag($0) }
        } label: {
            SettingLabel(tr(.summaryModelLabel), help: tr(summaryHelp, Int(memoryGB.rounded())),
                         warning: summaryHelp == .helpSummaryLowMemory)
        }
        .onChange(of: model) { _, value in commands.setSummaryModel(value) }

        LabeledContent {
            HStack {
                if !isDefaultFolder { Button(tr(.actionUseDefault)) { commands.resetNotesFolder() } }
                Button(tr(.actionOpen)) { commands.openNotesFolder() }
                Button(tr(.actionChange)) { commands.chooseNotesFolder() }
            }
        } label: {
            SettingLabel(tr(.saveLocation), help: (state.notesDir.path as NSString).abbreviatingWithTildeInPath)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder private var advanced: some View {
        Toggle(isOn: $liveTranscription) {
            SettingLabel(tr(.liveTranscriptionToggle), help: tr(.liveTranscriptionCaption))
        }
        .onChange(of: liveTranscription) { _, value in commands.setLiveTranscription(value) }

        Toggle(isOn: $livePolish) {
            SettingLabel(tr(.livePolishToggle), help: tr(.livePolishCaption))
        }
        .padding(.leading, 16)
        .disabled(!SettingsRules.polishEnabled(live: liveTranscription))
        .onChange(of: livePolish) { _, value in Settings.livePolish = value }

        Picker(selection: $pillMode) {
            ForEach(PillMode.allCases, id: \.self) { Text($0.title()).tag($0) }
        } label: {
            SettingLabel(tr(.pillLabel), help: tr(SettingsRules.pillHelp(pillMode)))
        }
        .onChange(of: pillMode) { _, value in
            commands.setPillVisibility(whileRecording: value.whileRecording, whenIdle: value.whenIdle)
        }
        HStack {
            Spacer()
            Button(tr(.actionResetPosition)) { commands.resetPillPosition() }
                .disabled(!SettingsRules.resetPillPositionEnabled(pillMode))
        }

        Toggle(isOn: $showInDock) {
            SettingLabel(tr(.showInDock), help: tr(.helpDock))
        }
        .onChange(of: showInDock) { _, value in commands.setShowInDock(value) }

        LabeledContent(tr(.version), value: version)
    }

    // MARK: - Helpers

    private var isDefaultFolder: Bool {
        state.notesDir.standardizedFileURL == defaultNotesDir.standardizedFileURL
    }

    private func setLaunchAtLogin(_ value: Bool) {
        do {
            try LoginItem.set(value)
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        login = LoginItem.state
    }
}
