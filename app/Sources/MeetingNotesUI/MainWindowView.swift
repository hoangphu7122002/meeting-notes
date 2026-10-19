import AppKit
import MeetingNotesCore
import SwiftUI

/// The app's home: recorder controls, title, meters, processing, recent meetings and permissions.
public struct MainWindowView: View {
    @ObservedObject var state: AppState
    let commands: any AppCommands
    let editingChanged: (Bool) -> Void
    /// False for previews: lays the whole content out without a scroll view.
    let scrollable: Bool

    public init(state: AppState, commands: any AppCommands, editingChanged: @escaping (Bool) -> Void, scrollable: Bool = true) {
        self.state = state
        self.commands = commands
        self.editingChanged = editingChanged
        self.scrollable = scrollable
    }

    public var body: some View {
        Localized {
            if scrollable {
                ScrollView { content }
            } else {
                content
            }
        }
        .frame(minWidth: 440, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity, alignment: .top)
        .background(Palette.windowBackground)
    }

    private var permissionsMissing: Bool { state.microphone != .granted || state.screenCapture != .granted }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if state.systemAudioMissing { SystemAudioBanner(state: state, commands: commands) }
            if state.showGettingStarted { GettingStartedCard(commands: commands) }
            RecorderCard(state: state, commands: commands, editingChanged: editingChanged)
            switch state.pill {
            case .processing(let snapshot): ProcessingCard(snapshot: snapshot, commands: commands)
            case .ready(let info): ReadyCard(info: info, commands: commands)
            case .error(let error): ErrorCard(error: error, commands: commands)
            default: EmptyView()
            }
            // Missing permissions come first; once granted the checklist moves below the meetings.
            if permissionsMissing { PermissionsCard(state: state, commands: commands) }
            RecentsCard(state: state, commands: commands)
            if !permissionsMissing { PermissionsCard(state: state, commands: commands) }
            Footer(state: state, commands: commands)
        }
        .font(.system(size: 13))
        .padding(20)
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Banner

struct SystemAudioBanner: View {
    @ObservedObject var state: AppState
    let commands: any AppCommands

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Palette.warning)
            VStack(alignment: .leading, spacing: 8) {
                Text(tr(.systemAudioBanner))
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(tr(.relaunchNote)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(tr(.actionOpenSettings)) { commands.openPermissionSettings(.screenCapture) }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(nsColor: .systemOrange))
                    Button(tr(.actionRelaunch)) { commands.relaunch() }
                        .disabled(!state.canRelaunch)
                        .help(state.canRelaunch ? tr(.relaunchNote) : tr(.relaunchBlocked))
                }
                .controlSize(.regular)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.warning.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.warning.opacity(0.6), lineWidth: 1))
    }
}

struct GettingStartedCard: View {
    let commands: any AppCommands

    var body: some View {
        SectionCard(tr(.gettingStartedHeading)) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach([Tr.gettingStarted1, .gettingStarted2, .gettingStarted3], id: \.self) { key in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Palette.secondary)
                        Text(tr(key)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Spacer()
                Button(tr(.actionGotIt)) { commands.dismissGettingStarted() }
            }
        }
    }
}

// MARK: - Recorder

struct RecorderCard: View {
    @ObservedObject var state: AppState
    let commands: any AppCommands
    let editingChanged: (Bool) -> Void

    var body: some View {
        SectionCard {
            header
            if state.hasTitleTarget {
                TitleField(text: $state.titleDraft, style: .window, onEditingChanged: editingChanged, onCommit: commands.commitTitle)
                    .frame(height: 28)
            }
            if state.machine.phase.isActive {
                VStack(alignment: .leading, spacing: 8) {
                    MeterRow(label: tr(.me), levels: state.levels, isMe: true, warning: state.micWarning, labelWidth: 90, barHeight: 8)
                    MeterRow(label: tr(.them), levels: state.levels, isMe: false, warning: state.systemWarning, labelWidth: 90, barHeight: 8)
                }
                .padding(.vertical, 2)
            }
            if state.machine.confirmingDiscard {
                DiscardConfirm(commands: commands)
            } else {
                controls
            }
            ForEach(state.recordingWarnings.prefix(3), id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Palette.warning).lineLimit(2).fixedSize(horizontal: false, vertical: true).help(warning)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            stateIcon.font(.system(size: 22)).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(headerLabel).font(.system(size: 20, weight: .semibold)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 12)
            if state.machine.phase.isActive || state.machine.phase == .stopping {
                ElapsedText(clock: state.clock)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(state.machine.phase == .paused ? Palette.paused : Palette.label)
                    .fixedSize()
            }
        }
    }

    private var headerLabel: String {
        switch state.machine.phase {
        case .recording: return tr(.stateRecording)
        case .paused: return tr(.statePausedLong)
        case .starting: return tr(.stateStarting)
        case .stopping: return tr(.stateSaving)
        case .idle:
            if case .idle(let attention) = state.pill, attention { return tr(.statePermissionsNeeded) }
            if state.processing != nil { return tr(.stateWritingNotes) }
            return tr(.stateReady)
        }
    }

    private var subtitle: String? {
        if state.machine.phase == .idle {
            if let name = state.detectedAppName { return tr(.appUsingMic, name) }
            if case .idle(true) = state.pill { return tr(.permissionsAttention) }
            return state.processing == nil ? tr(.idleHint) : nil
        }
        return nil
    }

    @ViewBuilder private var stateIcon: some View {
        switch state.machine.phase {
        case .recording: Image(systemName: "record.circle.fill").foregroundStyle(Palette.recording)
        case .paused: Image(systemName: "pause.circle.fill").foregroundStyle(Palette.paused)
        case .starting, .stopping: Image(systemName: "ellipsis.circle").foregroundStyle(Palette.secondary)
        case .idle:
            if case .idle(true) = state.pill {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
            } else if let snapshot = state.processing, snapshot.waiting == nil {
                ProgressRing(value: snapshot.overall, size: 22)
            } else {
                Image(systemName: "mic.circle.fill").foregroundStyle(Palette.secondary)
            }
        }
    }

    private var controls: some View {
        let machine = state.machine
        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Button { commands.startRecording(source: .window) } label: {
                    ButtonLabel(title: tr(.actionStartRecording), icon: "record.circle", hotkey: state.hotkey?.display)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(nsColor: .systemRed))
                .disabled(!machine.isEnabled(.start))
                if machine.phase == .paused {
                    Button { commands.perform(.resume, source: .window) } label: {
                        ButtonLabel(title: tr(.actionResume), icon: "play.fill", hotkey: state.pauseHotkey?.display)
                    }
                } else {
                    Button { commands.perform(.pause, source: .window) } label: {
                        ButtonLabel(title: tr(.actionPause), icon: "pause.fill", hotkey: state.pauseHotkey?.display)
                    }
                    .disabled(!machine.isEnabled(.pause))
                }
            }
            GridRow {
                Button { commands.perform(.stop, source: .window) } label: {
                    ButtonLabel(title: state.stopLabel, icon: "stop.fill", hotkey: state.hotkey?.display)
                }
                .disabled(!machine.isEnabled(.stop))
                Button { commands.perform(.requestDiscard, source: .window) } label: {
                    ButtonLabel(title: tr(.actionDiscardEllipsis), icon: "trash", hotkey: nil)
                }
                .disabled(!machine.isEnabled(.discard))
            }
        }
        .controlSize(.large)
    }
}

/// Full-width button label: icon, title and the hotkey on the trailing side.
struct ButtonLabel: View {
    let title: String
    let icon: String
    let hotkey: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if let hotkey {
                Text(hotkey).font(.system(size: 12, weight: .regular)).opacity(0.65).fixedSize()
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct DiscardConfirm: View {
    let commands: any AppCommands

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(tr(.discardQuestion), systemImage: "trash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.recording)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(role: .destructive) { commands.perform(.confirmDiscard, source: .window) } label: {
                    Text(tr(.discardConfirm)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(nsColor: .systemRed))
                Button { commands.perform(.cancelDiscard, source: .window) } label: {
                    Text(tr(.discardKeep)).frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)
            }
            .controlSize(.large)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.recording.opacity(0.1)))
    }
}

// MARK: - Processing, ready, error

struct ProcessingCard: View {
    let snapshot: ProcessingSnapshot
    let commands: any AppCommands

    var body: some View {
        SectionCard(snapshot.waiting == nil ? tr(.processingHeading) : tr(.waitingHeading)) {
            if let waiting = snapshot.waiting {
                Text(waiting).foregroundStyle(Palette.secondary)
                HStack(spacing: 8) {
                    Button(tr(.actionCreateNotesNow)) { commands.processWaitingNow() }.buttonStyle(.borderedProminent)
                    Button(tr(.actionCancel)) { commands.cancelProcessing() }
                }
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(snapshot.displayStages, id: \.name) { stage in
                        StageRow(stage: stage, finishing: snapshot.isFinishing && stage.name == "summarize")
                    }
                    if snapshot.isFinishing {
                        Text(tr(.finishing)).foregroundStyle(Palette.secondary).padding(.leading, 24)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    ProgressBar(value: snapshot.overall, color: Color.accentColor, height: 6)
                    HStack(spacing: 4) {
                        Text("\(snapshot.percent)%").monospacedDigit().fontWeight(.medium)
                        if let eta = Format.eta(snapshot.etaSec) { Text("· \(eta)").foregroundStyle(Palette.secondary) }
                        Spacer(minLength: 8)
                        if let message = snapshot.message {
                            Text(message).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.tail).help(message)
                        }
                    }
                }
                HStack(spacing: 8) {
                    if snapshot.partialNotes != nil {
                        Button(tr(.actionOpenTranscript)) { commands.openNotes(URL(fileURLWithPath: snapshot.folder, isDirectory: true)) }
                            .buttonStyle(.borderedProminent)
                    }
                    Button(tr(.actionCancel)) { commands.cancelProcessing() }
                    Spacer(minLength: 8)
                    if snapshot.queued > 0 {
                        Text(snapshot.queued == 1 ? tr(.queuedOne) : tr(.queuedMany, snapshot.queued)).foregroundStyle(Palette.secondary)
                    }
                }
            }
        }
    }
}

struct ReadyCard: View {
    let info: ReadyInfo
    let commands: any AppCommands

    var body: some View {
        let folder = URL(fileURLWithPath: info.folder, isDirectory: true)
        SectionCard(info.hasNotes ? tr(.readyHeading) : tr(.stateRecordingSaved)) {
            if !info.hasNotes { Text(tr(.audioSavedManual)).foregroundStyle(Palette.secondary) }
            HStack(spacing: 8) {
                if info.hasNotes {
                    Button(tr(.actionOpenNotes)) { commands.openNotes(folder) }.buttonStyle(.borderedProminent)
                    Button(tr(.actionCopySummary)) { commands.copySummary(folder: folder) }
                } else {
                    Button(tr(.actionCreateNotes)) { commands.createNotes(folder: folder) }.buttonStyle(.borderedProminent)
                }
                Button(tr(.actionShowInFinder)) { commands.reveal(folder) }
            }
        }
    }
}

struct ErrorCard: View {
    let error: PillError
    let commands: any AppCommands

    var body: some View {
        SectionCard(tr(.stateError)) {
            Label {
                Text(error.message).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Palette.recording)
            }
            HStack(spacing: 8) {
                switch error.action {
                case .retry:
                    Button(tr(.actionRetry)) { commands.performErrorAction() }.buttonStyle(.borderedProminent)
                    Text(tr(.audioKept)).foregroundStyle(Palette.secondary)
                case .openSettings:
                    Button(tr(.actionOpenSystemSettings)) { commands.performErrorAction() }.buttonStyle(.borderedProminent)
                case .none:
                    EmptyView()
                }
                Spacer(minLength: 8)
                Button(tr(.actionDismiss)) { commands.dismissError() }
            }
        }
    }
}

// MARK: - Recent meetings

struct RecentsCard: View {
    @ObservedObject var state: AppState
    let commands: any AppCommands

    var body: some View {
        SectionCard(tr(.recentHeading), accessory: {
            Button(tr(.actionOpenNotesFolder)) { commands.openNotesFolder() }.buttonStyle(.link)
        }) {
            if state.recents.isEmpty {
                Text(tr(.noMeetingsYet)).foregroundStyle(Palette.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(state.recents.enumerated()), id: \.element.id) { index, meeting in
                        if index > 0 { Divider().padding(.leading, 30) }
                        RecentRow(meeting: meeting, percent: percent(for: meeting), commands: commands)
                    }
                }
            }
        }
    }

    private func percent(for meeting: RecentMeeting) -> Int? {
        guard meeting.status == .processing, let snapshot = state.processing, snapshot.waiting == nil else { return nil }
        return snapshot.percent
    }
}

struct RecentRow: View {
    let meeting: RecentMeeting
    let percent: Int?
    let commands: any AppCommands

    var body: some View {
        HStack(spacing: 10) {
            icon.font(.system(size: 15)).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail).help(meeting.title)
                HStack(spacing: 4) {
                    Text(details).lineLimit(1).layoutPriority(1)
                    Text("·")
                    Text(meeting.status.label(percent: percent)).foregroundStyle(statusColor).lineLimit(1).truncationMode(.tail)
                }
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 8)
            primaryAction
            Button { commands.reveal(meeting.url) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help(tr(.actionShowInFinder))
        }
        .padding(.vertical, 7)
        .contextMenu {
            if meeting.hasNotes { Button(tr(.actionOpenNotes)) { commands.openNotes(meeting.url) } }
            Button(tr(.actionShowInFinder)) { commands.reveal(meeting.url) }
            if meeting.status == .done { Button(tr(.actionReprocess)) { commands.retry(folder: meeting.url) } }
            if meeting.hasLog { Button(tr(.actionShowLog)) { commands.openInDefaultApp(meeting.logURL) } }
        }
    }

    private var details: String {
        let date = meeting.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.language.locale))
        guard let duration = meeting.durationSec, duration > 0 else { return date }
        return tr(.recentDuration, date, Format.duration(duration))
    }

    @ViewBuilder private var primaryAction: some View {
        switch meeting.status {
        case .failed:
            Button(tr(.actionRetry)) { commands.retry(folder: meeting.url) }.controlSize(.small)
        case .notProcessed, .cancelled:
            Button(tr(.actionCreateNotes)) { commands.createNotes(folder: meeting.url) }.controlSize(.small)
        default:
            if meeting.hasNotes {
                Button(tr(.actionOpenNotes)) { commands.openNotes(meeting.url) }.controlSize(.small)
            }
        }
    }

    private var statusColor: Color {
        switch meeting.status {
        case .failed: return Palette.recording
        case .processing, .recording: return Palette.label
        default: return Palette.secondary
        }
    }

    @ViewBuilder private var icon: some View {
        switch meeting.status {
        case .done: Image(systemName: "doc.text.fill").foregroundStyle(Color.accentColor)
        case .processing, .queued: Image(systemName: "hourglass").foregroundStyle(Palette.secondary)
        case .recording: Image(systemName: "record.circle.fill").foregroundStyle(Palette.recording)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.recording)
        case .cancelled, .notProcessed: Image(systemName: "waveform").foregroundStyle(Palette.secondary)
        }
    }
}

// MARK: - Permissions

struct PermissionsCard: View {
    @ObservedObject var state: AppState
    let commands: any AppCommands

    var body: some View {
        SectionCard(tr(.permissionsHeading)) {
            PermissionRow(title: tr(.microphone), detail: tr(.micDetail), status: state.microphone) {
                commands.fixPermission(.microphone)
            }
            Divider()
            PermissionRow(title: tr(.systemAudio), detail: tr(.systemAudioDetail), status: state.screenCapture) {
                commands.fixPermission(.screenCapture)
            }
            Divider()
            PermissionRow(title: tr(.notificationsOptional), detail: tr(.notificationsDetail), status: state.notifications,
                          optional: true) {
                commands.fixPermission(.notifications)
            }
            Divider()
            AudioTestRow(state: state, commands: commands)
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let status: PermissionStatus
    var optional = false
    let fix: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 17)).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                Text(status.label()).font(.system(size: 12, weight: .medium)).foregroundStyle(color)
            }
            Spacer(minLength: 8)
            if status == .notDetermined {
                Button(tr(.actionAllow), action: fix)
            } else if status == .denied {
                Button(tr(.actionFix), action: fix)
            }
        }
    }

    private var icon: String {
        switch status {
        case .granted: return "checkmark.circle.fill"
        case .unavailable: return "minus.circle"
        default: return optional ? "circle.dashed" : "exclamationmark.circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .granted: return Palette.ok
        case .unavailable: return Palette.secondary
        default: return optional ? Palette.secondary : Palette.warning
        }
    }
}

struct AudioTestRow: View {
    @ObservedObject var state: AppState
    let commands: any AppCommands

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Palette.secondary).font(.system(size: 15)).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr(.audioTestHeading)).font(.system(size: 13, weight: .semibold))
                    Text(tr(.audioTestHint)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(state.audioTest.running ? tr(.actionTesting) : tr(.actionRunTest)) { commands.runAudioTest() }
                    .disabled(state.audioTest.running || state.isCapturing)
            }
            if state.audioTest.running {
                VStack(spacing: 6) {
                    TestMeter(label: tr(.me), value: state.audioTest.me)
                    TestMeter(label: tr(.them), value: state.audioTest.them)
                }
                .padding(.leading, 30)
            }
            ForEach(state.audioTest.result, id: \.self) { line in
                Text(line).padding(.leading, 30).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct TestMeter: View {
    let label: String
    let value: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 90, alignment: .leading)
            MeterBar(value: value, height: 8)
        }
    }
}

// MARK: - Footer

struct Footer: View {
    @ObservedObject var state: AppState
    let commands: any AppCommands

    var body: some View {
        HStack(spacing: 10) {
            Button { commands.showSettings() } label: { Label(tr(.actionSettingsEllipsis), systemImage: "gearshape") }
            Button { commands.openNotesFolder() } label: { Label(tr(.notesFolder), systemImage: "folder") }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }
}
