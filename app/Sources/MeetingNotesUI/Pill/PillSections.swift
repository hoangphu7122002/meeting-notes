// Per-state sections of the expanded card: idle, recording, processing, ready, error (Pill).

import MeetingNotesCore
import SwiftUI

struct IdleSection: View {
    @ObservedObject var state: AppState
    let commands: any AppCommands
    let attention: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if attention {
                Text(tr(.permissionsAttention)).foregroundStyle(Palette.warning).fixedSize(horizontal: false, vertical: true)
                Button(tr(.actionPermissionsEllipsis)) { commands.showMainWindow() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
            }
            if let name = state.detectedAppName {
                Text(tr(.appUsingMic, name)).foregroundStyle(Palette.secondary)
            }
            Button {
                commands.startRecording(source: .pill)
            } label: {
                Label(tr(.actionStartRecording), systemImage: "record.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(kind: .record))
            .disabled(!state.machine.isEnabled(.start))
            .help(state.hotkey.map { "\(tr(.actionStartRecording)) (\($0.display))" } ?? tr(.actionStartRecording))
            HStack(spacing: 6) {
                if state.lastResult != nil {
                    Button(tr(.actionOpenLastNotes)) { commands.openLastNotes() }.buttonStyle(PillButtonStyle(kind: .secondary))
                }
                Button(tr(.actionHideHour)) { commands.hidePillForAnHour() }.buttonStyle(PillButtonStyle(kind: .secondary))
                Spacer(minLength: 0)
                Button(action: commands.showSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(PillButtonStyle(kind: .icon))
                    .help(tr(.actionSettings))
            }
            if let hint = state.hotkeyHint {
                Text(hint).foregroundStyle(Palette.secondary).lineLimit(1)
            }
        }
    }
}

struct RecordingSection: View {
    @ObservedObject var state: AppState
    let commands: any AppCommands
    let actions: PillActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TitleField(text: $state.titleDraft, onEditingChanged: actions.editingChanged, onCommit: commands.commitTitle)
                .frame(height: 26)
            MeterRow(label: tr(.me), levels: state.levels, isMe: true, warning: state.micWarning)
            MeterRow(label: tr(.them), levels: state.levels, isMe: false, warning: state.systemWarning)
            if state.machine.confirmingDiscard {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr(.discardQuestion)).foregroundStyle(Palette.recording).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Button(tr(.discardConfirm)) { commands.perform(.confirmDiscard, source: .pill) }
                            .buttonStyle(PillButtonStyle(kind: .destructive))
                        Button(tr(.discardKeep)) { commands.perform(.cancelDiscard, source: .pill) }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                    }
                }
            } else {
                HStack(spacing: 6) {
                    if state.pill == .paused {
                        Button {
                            commands.perform(.resume, source: .pill)
                        } label: { Label(tr(.actionResume), systemImage: "play.fill") }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                            .help(state.pauseHotkey.map { "\(tr(.actionResume)) (\($0.display))" } ?? tr(.actionResume))
                    } else {
                        Button {
                            commands.perform(.pause, source: .pill)
                        } label: { Label(tr(.actionPause), systemImage: "pause.fill") }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                            .help(state.pauseHotkey.map { "\(tr(.actionPause)) (\($0.display))" } ?? tr(.actionPause))
                    }
                    Button {
                        commands.perform(.stop, source: .pill)
                    } label: { Label(state.stopLabel, systemImage: "stop.fill") }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                        .help(state.hotkey.map { "\(state.stopLabel) (\($0.display))" } ?? state.stopLabel)
                    Spacer(minLength: 0)
                    Button { commands.perform(.requestDiscard, source: .pill) } label: { Image(systemName: "trash") }
                        .buttonStyle(PillButtonStyle(kind: .icon))
                        .help(tr(.actionDiscard))
                }
            }
            ForEach(state.recordingWarnings.prefix(2), id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Palette.warning).lineLimit(1).truncationMode(.tail).help(warning)
            }
        }
    }
}

struct ProcessingSection: View {
    @ObservedObject var state: AppState
    let snapshot: ProcessingSnapshot
    let commands: any AppCommands
    let actions: PillActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TitleField(text: $state.titleDraft, onEditingChanged: actions.editingChanged, onCommit: commands.commitTitle)
                .frame(height: 26)
            if let waiting = snapshot.waiting {
                Text(waiting).foregroundStyle(Palette.secondary)
                HStack(spacing: 6) {
                    Button(tr(.actionCreateNotesNow)) { commands.processWaitingNow() }.buttonStyle(PillButtonStyle(kind: .primary))
                    Button(tr(.actionCancel)) { commands.cancelProcessing() }.buttonStyle(PillButtonStyle(kind: .secondary))
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(snapshot.displayStages, id: \.name) { stage in
                        StageRow(stage: stage, finishing: snapshot.isFinishing && stage.name == "summarize")
                    }
                    if snapshot.isFinishing {
                        Text(tr(.finishing)).foregroundStyle(Palette.secondary).padding(.leading, 24)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    ProgressBar(value: snapshot.overall)
                    HStack(spacing: 4) {
                        Text("\(snapshot.percent)%").monospacedDigit()
                        if let eta = Format.eta(snapshot.etaSec) { Text("· \(eta)").foregroundStyle(Palette.secondary) }
                    }
                    .lineLimit(1)
                    if let message = snapshot.message {
                        Text(message).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.tail).help(message)
                    }
                }
                HStack(spacing: 6) {
                    if snapshot.partialNotes != nil {
                        Button(tr(.actionOpenTranscript)) { commands.openNotes(URL(fileURLWithPath: snapshot.folder, isDirectory: true)) }
                            .buttonStyle(PillButtonStyle(kind: .primary))
                    }
                    Button(tr(.actionCancel)) { commands.cancelProcessing() }.buttonStyle(PillButtonStyle(kind: .secondary))
                }
            }
            if snapshot.queued > 0 {
                Text(snapshot.queued == 1 ? tr(.queuedOne) : tr(.queuedMany, snapshot.queued)).foregroundStyle(Palette.secondary)
            }
        }
    }
}

struct ReadySection: View {
    @ObservedObject var state: AppState
    let info: ReadyInfo
    let commands: any AppCommands
    let actions: PillActions

    var body: some View {
        let folder = URL(fileURLWithPath: info.folder, isDirectory: true)
        VStack(alignment: .leading, spacing: 10) {
            TitleField(text: $state.titleDraft, onEditingChanged: actions.editingChanged, onCommit: commands.commitTitle)
                .frame(height: 26)
            if info.hasNotes {
                HStack(spacing: 6) {
                    Button(tr(.actionOpenNotes)) { commands.openNotes(folder) }.buttonStyle(PillButtonStyle(kind: .primary))
                    Button(tr(.actionCopySummary)) { commands.copySummary(folder: folder) }.buttonStyle(PillButtonStyle(kind: .secondary))
                    Spacer(minLength: 0)
                    Button { commands.reveal(folder) } label: { Image(systemName: "folder") }
                        .buttonStyle(PillButtonStyle(kind: .icon)).help(tr(.actionShowInFinder))
                }
            } else {
                Text(tr(.audioSavedManual)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button(tr(.actionCreateNotes)) { commands.createNotes(folder: folder) }.buttonStyle(PillButtonStyle(kind: .primary))
                    Button(tr(.actionShowInFinder)) { commands.reveal(folder) }.buttonStyle(PillButtonStyle(kind: .secondary))
                }
            }
        }
    }
}

struct ErrorSection: View {
    let error: PillError
    let commands: any AppCommands

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(error.message).lineLimit(5).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack(spacing: 6) {
                switch error.action {
                case .retry:
                    Button(tr(.actionRetry)) { commands.performErrorAction() }.buttonStyle(PillButtonStyle(kind: .primary))
                    Text(tr(.audioKept)).foregroundStyle(Palette.secondary).lineLimit(1)
                case .openSettings:
                    Button(tr(.actionOpenSystemSettings)) { commands.performErrorAction() }.buttonStyle(PillButtonStyle(kind: .primary))
                case .none:
                    EmptyView()
                }
                Spacer(minLength: 6)
                Button(tr(.actionDismiss)) { commands.dismissError() }.buttonStyle(PillButtonStyle(kind: .secondary))
            }
        }
    }
}
