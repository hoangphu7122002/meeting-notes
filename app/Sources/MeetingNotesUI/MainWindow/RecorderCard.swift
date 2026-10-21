// Main window recorder card: start/pause/stop controls, title field, meters (MainWindow).

import MeetingNotesCore
import SwiftUI

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
