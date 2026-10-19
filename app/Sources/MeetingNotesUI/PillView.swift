import AppKit
import MeetingNotesCore
import SwiftUI

/// Panel-level callbacks of the pill (geometry, hover, dragging), implemented by the pill controller.
public struct PillActions {
    public let sizeChanged: (CGSize) -> Void
    public let expand: () -> Void
    public let collapse: () -> Void
    public let dragChanged: () -> Void
    public let dragEnded: () -> Void
    public let editingChanged: (Bool) -> Void

    public init(sizeChanged: @escaping (CGSize) -> Void, expand: @escaping () -> Void, collapse: @escaping () -> Void,
                dragChanged: @escaping () -> Void, dragEnded: @escaping () -> Void, editingChanged: @escaping (Bool) -> Void) {
        self.sizeChanged = sizeChanged
        self.expand = expand
        self.collapse = collapse
        self.dragChanged = dragChanged
        self.dragEnded = dragEnded
        self.editingChanged = editingChanged
    }

    public static let none = PillActions(sizeChanged: { _ in }, expand: {}, collapse: {}, dragChanged: {}, dragEnded: {},
                                         editingChanged: { _ in })
}

@MainActor
public final class PillUIModel: ObservableObject {
    @Published public var expanded = false
    @Published public var editingTitle = false
    public init() {}
}

/// Root of the pill panel: the collapsed pill, with the expanded card or the warning badge above it.
/// The panel takes this view's fitting size and keeps its bottom-center fixed, so the collapsed pill
/// never moves and a button under the cursor stays under the cursor. No repeating animations.
public struct PillRootView: View {
    @ObservedObject var state: AppState
    @ObservedObject var ui: PillUIModel
    let commands: any AppCommands
    let actions: PillActions

    public init(state: AppState, ui: PillUIModel, commands: any AppCommands, actions: PillActions) {
        self.state = state
        self.ui = ui
        self.commands = commands
        self.actions = actions
    }

    public var body: some View {
        Localized {
            VStack(spacing: PillLayout.spacing) {
                if ui.expanded {
                    ExpandedCard(state: state, commands: commands, actions: actions)
                } else if let warning = state.pillWarning {
                    WarningBadge(warning: warning, onTap: commands.showMainWindow)
                }
                CollapsedPill(state: state, commands: commands, actions: actions)
            }
        }
        .onFittingSizeChange(actions.sizeChanged)
    }
}

private extension View {
    func panelDrag(_ actions: PillActions) -> some View {
        gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { _ in actions.dragChanged() }
            .onEnded { _ in actions.dragEnded() })
    }
}

// MARK: - Warning badge

/// One-line warning above the collapsed pill; the full text is the tooltip. Click opens the main window.
struct WarningBadge: View {
    let warning: PillWarning
    let onTap: () -> Void

    var body: some View {
        Label {
            Text(warning.short).lineLimit(1).truncationMode(.tail)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Palette.label)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .frame(maxWidth: PillLayout.badgeMaxWidth)
        .background(SurfaceBackground(shape: Capsule(style: .circular), tint: Palette.warning))
        .contentShape(Capsule(style: .circular))
        .onTapGesture(perform: onTap)
        .help(warning.full)
    }
}

// MARK: - Collapsed

struct CollapsedPill: View {
    @ObservedObject var state: AppState
    let commands: any AppCommands
    let actions: PillActions

    var body: some View {
        HStack(spacing: 10) { content }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.label)
            .padding(.leading, 16)
            .padding(.trailing, trailingPadding)
            .frame(minWidth: PillLayout.collapsedMinWidth, maxWidth: PillLayout.collapsedMaxWidth)
            .frame(height: PillLayout.collapsedHeight)
            .background(SurfaceBackground(shape: Capsule(style: .circular)))
            .contentShape(Capsule(style: .circular))
            .onTapGesture { actions.expand() }
            .panelDrag(actions)
            .help(helpText)
    }

    /// Buttons sit closer to the rounded end than text does.
    private var trailingPadding: CGFloat {
        switch state.pill {
        case .idle, .paused, .ready: return 8
        default: return 16
        }
    }

    private var helpText: String {
        [state.pill.label(), state.hotkeyHint, tr(.pillHelp)].compactMap { $0 }.joined(separator: "\n")
    }

    private var stateLabel: some View {
        Text(state.pill.label()).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
    }

    @ViewBuilder private var content: some View {
        switch state.pill {
        case .idle(let attention):
            if attention {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
                stateLabel
                Spacer(minLength: 8)
                Button(tr(.actionFix)) { commands.showMainWindow() }
                    .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
            } else {
                Image(systemName: "mic.fill").foregroundStyle(Palette.secondary)
                stateLabel
                Spacer(minLength: 8)
            }
            Button(tr(.actionStartRecording)) { commands.startRecording(source: .pill) }
                .buttonStyle(PillButtonStyle(kind: .record, size: .small))
                .disabled(!state.machine.isEnabled(.start))
        case .starting:
            Image(systemName: "ellipsis.circle").foregroundStyle(Palette.secondary)
            stateLabel
            Spacer(minLength: 8)
        case .recording:
            Circle().fill(Palette.recording).frame(width: 10, height: 10)
            stateLabel
            Spacer(minLength: 8)
            ElapsedText(clock: state.clock).font(.system(size: 15, weight: .semibold)).fixedSize()
            MiniMeters(state: state, levels: state.levels)
        case .paused:
            Image(systemName: "pause.fill").foregroundStyle(Palette.paused)
            stateLabel.foregroundStyle(Palette.paused)
            ElapsedText(clock: state.clock).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.secondary).fixedSize()
            Spacer(minLength: 8)
            Button(tr(.actionResume)) { commands.perform(.resume, source: .pill) }
                .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
        case .stopping:
            Image(systemName: "square.and.arrow.down").foregroundStyle(Palette.secondary)
            stateLabel
            Spacer(minLength: 8)
        case .processing(let snapshot):
            if snapshot.waiting != nil {
                Image(systemName: "clock").foregroundStyle(Palette.secondary)
            } else {
                ProgressRing(value: snapshot.overall)
            }
            stateLabel.monospacedDigit()
            Spacer(minLength: 8)
            if snapshot.waiting == nil, let eta = Format.eta(snapshot.etaSec) {
                Text(eta).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.tail).frame(maxWidth: 140, alignment: .trailing)
            }
        case .ready(let info):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ok)
            stateLabel
            Text(info.title).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: 110, alignment: .leading).help(info.title)
            Spacer(minLength: 8)
            if info.hasNotes {
                Button(tr(.actionOpenNotes)) { commands.openNotes(URL(fileURLWithPath: info.folder, isDirectory: true)) }
                    .buttonStyle(PillButtonStyle(kind: .primary, size: .small))
            } else {
                Button(tr(.actionCreateNotes)) { commands.createNotes(folder: URL(fileURLWithPath: info.folder, isDirectory: true)) }
                    .buttonStyle(PillButtonStyle(kind: .primary, size: .small))
            }
        case .error(let error):
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Palette.recording)
            stateLabel
            Text(error.message).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: 220, alignment: .leading).help(error.message)
            Spacer(minLength: 0)
        }
    }
}

/// Two small Me/Them meters (updated <= 12 fps while visible and recording).
struct MiniMeters: View {
    @ObservedObject var state: AppState
    @ObservedObject var levels: LevelModel

    var body: some View {
        HStack(spacing: 8) {
            meter(icon: "person.fill", value: levels.me, warning: !state.micAvailable, name: tr(.me))
            meter(icon: "person.2.fill", value: levels.them, warning: state.systemAudio != .ok, name: tr(.them))
        }
    }

    private func meter(icon: String, value: Double, warning: Bool, name: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(warning ? Palette.warning : Palette.secondary)
            MeterBar(value: value, warning: warning, height: 5).frame(width: 28)
        }
        .help(name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
    }
}

// MARK: - Expanded

struct ExpandedCard: View {
    @ObservedObject var state: AppState
    let commands: any AppCommands
    let actions: PillActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch state.pill {
            case .idle(let attention): IdleSection(state: state, commands: commands, attention: attention)
            case .starting: Text(tr(.startingCapture)).foregroundStyle(Palette.secondary)
            case .stopping: Text(tr(.savingRecording)).foregroundStyle(Palette.secondary)
            case .recording, .paused: RecordingSection(state: state, commands: commands, actions: actions)
            case .processing(let snapshot): ProcessingSection(state: state, snapshot: snapshot, commands: commands, actions: actions)
            case .ready(let info): ReadySection(state: state, info: info, commands: commands, actions: actions)
            case .error(let error): ErrorSection(error: error, commands: commands)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Palette.label)
        .padding(16)
        .frame(width: PillLayout.expandedWidth, alignment: .leading)
        .background(SurfaceBackground(shape: RoundedRectangle(cornerRadius: PillLayout.cornerRadius, style: .continuous)))
    }

    private var header: some View {
        HStack(spacing: 8) {
            stateIcon
            Text(state.pill.label()).font(.system(size: 17, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            if state.pill == .recording || state.pill == .paused {
                ElapsedText(clock: state.clock)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(state.pill == .paused ? Palette.paused : Palette.label)
                    .fixedSize()
            }
            Button(action: commands.showMainWindow) {
                Image(systemName: "macwindow").font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(PillButtonStyle(kind: .icon))
            .help(tr(.openWindowHelp))
            Button(action: actions.collapse) {
                Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(PillButtonStyle(kind: .icon))
            .help(tr(.actionCollapse))
        }
        .contentShape(Rectangle())
        .panelDrag(actions)
    }

    @ViewBuilder private var stateIcon: some View {
        switch state.pill {
        case .recording: Circle().fill(Palette.recording).frame(width: 10, height: 10)
        case .paused: Image(systemName: "pause.circle.fill").foregroundStyle(Palette.paused)
        case .processing(let snapshot): ProgressRing(value: snapshot.overall)
        case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ok)
        case .error: Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Palette.recording)
        case .idle(let attention):
            Image(systemName: attention ? "exclamationmark.triangle.fill" : "mic.circle")
                .foregroundStyle(attention ? Palette.warning : Palette.secondary)
        default: Image(systemName: "ellipsis.circle").foregroundStyle(Palette.secondary)
        }
    }
}

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
