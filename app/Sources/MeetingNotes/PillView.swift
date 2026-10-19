import AppKit
import MeetingNotesCore
import SwiftUI

struct PillActions {
    let sizeChanged: (CGSize) -> Void
    let expand: () -> Void
    let collapse: () -> Void
    let dragChanged: () -> Void
    let dragEnded: () -> Void
    let editingChanged: (Bool) -> Void
}

enum PillPalette {
    static let background = Color(white: 0.09).opacity(0.94)
    static let stroke = Color.white.opacity(0.13)
    static let recording = Color(red: 1, green: 0.27, blue: 0.23)
    static let paused = Color(red: 1, green: 0.72, blue: 0.2)
    static let ok = Color(red: 0.3, green: 0.85, blue: 0.45)
    static let secondary = Color.white.opacity(0.6)
}

/// Root of the pill panel: collapsed capsule or expanded card. No repeating animations anywhere.
struct PillRootView: View {
    @ObservedObject var app: AppController
    @ObservedObject var ui: PillUIModel
    let clock: ClockModel
    let levels: LevelModel
    let actions: PillActions

    var body: some View {
        // The capsule never moves: expanding adds the card above it (the panel is bottom-anchored),
        // so a button under the cursor stays under the cursor.
        VStack(spacing: 6) {
            if ui.expanded {
                ExpandedCard(app: app, clock: clock, levels: levels, actions: actions)
            }
            CollapsedPill(app: app, clock: clock, levels: levels, actions: actions)
        }
        .environment(\.colorScheme, .dark)
        .padding(4)
        .reportSize(actions.sizeChanged)
    }
}

private extension View {
    func panelDrag(_ actions: PillActions) -> some View {
        gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { _ in actions.dragChanged() }
            .onEnded { _ in actions.dragEnded() })
    }
}

// MARK: - Collapsed

struct CollapsedPill: View {
    @ObservedObject var app: AppController
    let clock: ClockModel
    let levels: LevelModel
    let actions: PillActions

    var body: some View {
        HStack(spacing: 8) { content }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule().fill(PillPalette.background))
            .overlay(Capsule().strokeBorder(PillPalette.stroke))
            .contentShape(Capsule())
            .onTapGesture { actions.expand() }
            .panelDrag(actions)
            .help(helpText)
    }

    private var helpText: String {
        let start = app.hotkey.map { " (\($0.display))" } ?? ""
        let pause = app.pauseHotkey.map { " · pause \($0.display)" } ?? ""
        return "Meeting Notes – start/stop\(start)\(pause). Drag to move."
    }

    @ViewBuilder private var content: some View {
        switch app.pill {
        case .idle(let attention):
            if attention {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PillPalette.paused)
                Text("Permissions")
            } else {
                Image(systemName: "mic").foregroundStyle(PillPalette.secondary)
            }
            Button("Start") { app.startRecording(source: .pill) }
                .buttonStyle(PillButtonStyle(kind: .compact))
                .disabled(!app.machine.isEnabled(.start))
        case .starting:
            Circle().fill(Color.gray).frame(width: 8, height: 8)
            Text("Starting…")
        case .recording:
            Circle().fill(PillPalette.recording).frame(width: 9, height: 9)
            ElapsedText(clock: clock)
            MiniBars(levels: levels)
        case .paused:
            Image(systemName: "pause.fill").foregroundStyle(PillPalette.paused)
            Text("Paused").foregroundStyle(PillPalette.paused)
            ElapsedText(clock: clock).foregroundStyle(PillPalette.secondary)
        case .stopping:
            Image(systemName: "square.and.arrow.down").foregroundStyle(PillPalette.secondary)
            Text("Saving…")
        case .processing(let snapshot):
            if snapshot.waiting != nil {
                Image(systemName: "clock").foregroundStyle(PillPalette.secondary)
                Text("Notes queued")
            } else {
                ProgressRing(value: snapshot.overall)
                Text("Writing notes… \(snapshot.percent)%").monospacedDigit()
            }
        case .ready(let info):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(PillPalette.ok)
            Text(info.hasNotes ? "Notes ready" : "Recording saved")
        case .error(let error):
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(PillPalette.recording)
            Text(Format.clip(error.message, 34))
        }
    }
}

struct ElapsedText: View {
    @ObservedObject var clock: ClockModel

    var body: some View {
        Text(clock.elapsed).monospacedDigit()
    }
}

/// Five bars scaled by the louder of the two tracks (updated <= 12 fps while visible).
struct MiniBars: View {
    @ObservedObject var levels: LevelModel
    private static let shape: [CGFloat] = [0.45, 0.75, 1, 0.75, 0.45]

    var body: some View {
        let level = CGFloat(max(levels.me, levels.them))
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 3, height: max(3, 16 * Self.shape[index] * level))
            }
        }
        .frame(height: 16)
    }
}

/// Thin determinate bar (pure SwiftUI, no animation).
struct ProgressBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(color).frame(width: proxy.size.width * CGFloat(min(max(value, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}

/// Determinate ring (no spinning animation).
struct ProgressRing: View {
    let value: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.2), lineWidth: 2.5)
            Circle().trim(from: 0, to: max(0.02, min(1, value)))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14)
    }
}

// MARK: - Expanded

struct ExpandedCard: View {
    @ObservedObject var app: AppController
    let clock: ClockModel
    let levels: LevelModel
    let actions: PillActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch app.pill {
            case .idle(let attention): IdleSection(app: app, attention: attention)
            case .starting, .stopping: Text(app.pill == .starting ? "Starting capture…" : "Saving the recording…")
                .foregroundStyle(PillPalette.secondary)
            case .recording, .paused: RecordingSection(app: app, levels: levels, actions: actions)
            case .processing(let snapshot): ProcessingSection(app: app, snapshot: snapshot, actions: actions)
            case .ready(let info): ReadySection(app: app, info: info, actions: actions)
            case .error(let error): ErrorSection(app: app, error: error)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.white)
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(PillPalette.background))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(PillPalette.stroke))
    }

    private var header: some View {
        HStack(spacing: 8) {
            stateIcon
            Text(app.pill.label).font(.system(size: 17, weight: .semibold))
            Spacer(minLength: 8)
            if app.pill == .recording || app.pill == .paused {
                ElapsedText(clock: clock)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(app.pill == .paused ? PillPalette.paused : .white)
            }
            Button(action: actions.collapse) {
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(PillButtonStyle(kind: .icon))
            .help("Collapse")
        }
        .contentShape(Rectangle())
        .panelDrag(actions)
    }

    @ViewBuilder private var stateIcon: some View {
        switch app.pill {
        case .recording: Circle().fill(PillPalette.recording).frame(width: 10, height: 10)
        case .paused: Image(systemName: "pause.circle.fill").foregroundStyle(PillPalette.paused)
        case .processing(let snapshot): ProgressRing(value: snapshot.overall)
        case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(PillPalette.ok)
        case .error: Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(PillPalette.recording)
        case .idle(let attention):
            Image(systemName: attention ? "exclamationmark.triangle.fill" : "mic.circle")
                .foregroundStyle(attention ? PillPalette.paused : PillPalette.secondary)
        default: Image(systemName: "ellipsis.circle").foregroundStyle(PillPalette.secondary)
        }
    }
}

struct IdleSection: View {
    @ObservedObject var app: AppController
    let attention: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if attention {
                Text("Microphone or system audio access needs attention.")
                    .foregroundStyle(PillPalette.paused)
                Button("Fix permissions…") { app.ui?.showOnboarding() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
            }
            if let detected = app.detectedApp {
                Text("\(detected.name) is using the microphone.").foregroundStyle(PillPalette.secondary)
            }
            Button {
                app.startRecording(source: .pill)
            } label: {
                Label("Start recording", systemImage: "record.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(kind: .primary))
            .disabled(!app.machine.isEnabled(.start))
            .help(app.hotkey.map { "Start recording (\($0.display))" } ?? "Start recording")
            HStack(spacing: 6) {
                if app.lastResult != nil {
                    Button("Open last notes") { app.openLastNotes() }.buttonStyle(PillButtonStyle(kind: .secondary))
                }
                Button("Hide for 1 hour") { app.hidePillForAnHour() }.buttonStyle(PillButtonStyle(kind: .secondary))
                Button {
                    app.ui?.showSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(PillButtonStyle(kind: .icon))
                .help("Settings")
            }
            HotkeyHint(app: app)
        }
    }
}

struct HotkeyHint: View {
    @ObservedObject var app: AppController

    var body: some View {
        let parts = [app.hotkey.map { "\($0.display) start/stop" }, app.pauseHotkey.map { "\($0.display) pause" }].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(PillPalette.secondary)
        }
    }
}

struct RecordingSection: View {
    @ObservedObject var app: AppController
    let levels: LevelModel
    let actions: PillActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TitleField(text: $app.titleDraft, onEditingChanged: actions.editingChanged, onCommit: { app.commitTitle() })
                .frame(height: 24)
            MeterRow(label: "Me", levels: levels, isMe: true, warning: micWarning)
            MeterRow(label: "Them", levels: levels, isMe: false, warning: systemWarning)
            if app.machine.confirmingDiscard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Discard recording? This deletes the audio.").foregroundStyle(PillPalette.recording)
                    HStack {
                        Button("Yes, discard") { app.perform(.confirmDiscard, source: .pill) }
                            .buttonStyle(PillButtonStyle(kind: .destructive))
                        Button("No") { app.perform(.cancelDiscard, source: .pill) }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                    }
                }
            } else {
                HStack(spacing: 6) {
                    if app.pill == .paused {
                        Button {
                            app.perform(.resume, source: .pill)
                        } label: { Label("Resume", systemImage: "play.fill") }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                            .help(app.pauseHotkey.map { "Resume (\($0.display))" } ?? "Resume")
                    } else {
                        Button {
                            app.perform(.pause, source: .pill)
                        } label: { Label("Pause", systemImage: "pause.fill") }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                            .help(app.pauseHotkey.map { "Pause (\($0.display))" } ?? "Pause")
                    }
                    Button {
                        app.perform(.stop, source: .pill)
                    } label: { Label(Settings.createNotesMode == .manual ? "Stop & save" : "Stop & create notes", systemImage: "stop.fill") }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                        .help(app.hotkey.map { "Stop and create notes (\($0.display))" } ?? "Stop and create notes")
                    Button("Discard") { app.perform(.requestDiscard, source: .pill) }
                        .buttonStyle(PillButtonStyle(kind: .plain))
                }
            }
            ForEach(app.recordingWarnings.prefix(2), id: \.self) { warning in
                Label(Format.clip(warning, 80), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(PillPalette.paused).lineLimit(2)
            }
        }
    }

    private var micWarning: String? {
        app.micAvailable ? nil : "Microphone not recording – check permission or input device"
    }

    private var systemWarning: String? {
        switch app.systemAudio {
        case .ok: return nil
        case .notPermitted: return "System audio not permitted – others won't be recorded"
        case .silent: return app.pill == .paused ? nil : "No sound from others for 10 s+"
        }
    }
}

struct MeterRow: View {
    let label: String
    @ObservedObject var levels: LevelModel
    let isMe: Bool
    let warning: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(label).font(.system(size: 12, weight: .medium)).frame(width: 40, alignment: .leading)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(warning == nil ? PillPalette.ok : PillPalette.paused)
                        .frame(width: max(0, 270 * CGFloat(isMe ? levels.me : levels.them)))
                }
                .frame(width: 270, height: 6)
            }
            if let warning {
                Text(warning).font(.system(size: 11)).foregroundStyle(PillPalette.paused).padding(.leading, 48)
            }
        }
    }
}

struct ProcessingSection: View {
    @ObservedObject var app: AppController
    let snapshot: ProcessingSnapshot
    let actions: PillActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TitleField(text: $app.titleDraft, onEditingChanged: actions.editingChanged, onCommit: { app.commitTitle() })
                .frame(height: 24)
            if let waiting = snapshot.waiting {
                Text(waiting).foregroundStyle(PillPalette.secondary)
                HStack(spacing: 6) {
                    Button("Create notes now") { app.processWaitingNow() }.buttonStyle(PillButtonStyle(kind: .primary))
                    Button("Cancel") { app.cancelProcessing() }.buttonStyle(PillButtonStyle(kind: .secondary))
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(snapshot.displayStages, id: \.name) { stage in
                        StageRow(stage: stage, finishing: snapshot.isFinishing && stage.name == "summarize")
                    }
                    if snapshot.isFinishing {
                        Text("Finishing…").font(.system(size: 11)).foregroundStyle(PillPalette.secondary).padding(.leading, 24)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    ProgressBar(value: snapshot.overall, color: .white)
                    HStack {
                        Text("\(snapshot.percent)%").monospacedDigit()
                        if let eta = Format.eta(snapshot.etaSec) { Text("· \(eta)").foregroundStyle(PillPalette.secondary) }
                    }
                    .font(.system(size: 12))
                    if let message = snapshot.message {
                        Text(Format.clip(message, 60)).font(.system(size: 11)).foregroundStyle(PillPalette.secondary).lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    if snapshot.partialNotes != nil {
                        Button("Open transcript") { app.ui?.openNotes(URL(fileURLWithPath: snapshot.folder, isDirectory: true)) }
                            .buttonStyle(PillButtonStyle(kind: .primary))
                    }
                    Button("Cancel") { app.cancelProcessing() }.buttonStyle(PillButtonStyle(kind: .secondary))
                }
            }
            if snapshot.queued > 0 {
                Text("\(snapshot.queued) more meeting\(snapshot.queued == 1 ? "" : "s") queued")
                    .font(.system(size: 11)).foregroundStyle(PillPalette.secondary)
            }
        }
    }
}

struct StageRow: View {
    let stage: StageProgress
    let finishing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                icon.frame(width: 16)
                Text(stage.title).fontWeight(stage.status == .running ? .semibold : .regular)
                    .foregroundStyle(stage.status == .pending ? PillPalette.secondary : .white)
                Spacer()
                if let elapsed = stage.elapsedSec, stage.status == .done {
                    Text(Format.duration(elapsed)).font(.system(size: 11)).foregroundStyle(PillPalette.secondary).monospacedDigit()
                } else if stage.status == .skipped {
                    Text("cached").font(.system(size: 11)).foregroundStyle(PillPalette.secondary)
                }
            }
            if stage.status == .running, !finishing {
                ProgressBar(value: stage.fraction, color: PillPalette.ok).padding(.leading, 24)
            }
        }
    }

    @ViewBuilder private var icon: some View {
        switch stage.status {
        case .done, .skipped: Image(systemName: "checkmark.circle.fill").foregroundStyle(PillPalette.ok)
        case .running: Image(systemName: "circle.circle.fill").foregroundStyle(.white)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(PillPalette.paused)
        case .pending: Image(systemName: "circle").foregroundStyle(PillPalette.secondary)
        }
    }
}

struct ReadySection: View {
    @ObservedObject var app: AppController
    let info: ReadyInfo
    let actions: PillActions

    var body: some View {
        let folder = URL(fileURLWithPath: info.folder, isDirectory: true)
        VStack(alignment: .leading, spacing: 10) {
            TitleField(text: $app.titleDraft, onEditingChanged: actions.editingChanged, onCommit: { app.commitTitle() })
                .frame(height: 24)
            if info.hasNotes {
                HStack(spacing: 6) {
                    Button("Open notes") { app.ui?.openNotes(folder) }.buttonStyle(PillButtonStyle(kind: .primary))
                    Button("Show in Finder") { app.reveal(folder) }.buttonStyle(PillButtonStyle(kind: .secondary))
                    Button("Copy summary") { app.copySummary(folder: folder) }.buttonStyle(PillButtonStyle(kind: .secondary))
                }
            } else {
                Text("Audio saved. Notes are created when you ask.").foregroundStyle(PillPalette.secondary)
                HStack(spacing: 6) {
                    Button("Create notes") { app.createNotes(folder: folder) }.buttonStyle(PillButtonStyle(kind: .primary))
                    Button("Show in Finder") { app.reveal(folder) }.buttonStyle(PillButtonStyle(kind: .secondary))
                }
            }
        }
    }
}

struct ErrorSection: View {
    @ObservedObject var app: AppController
    let error: PillError

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(error.message).lineLimit(5).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                switch error.action {
                case .retry:
                    Button("Retry") { app.performErrorAction() }.buttonStyle(PillButtonStyle(kind: .primary))
                    Text("Audio is kept.").font(.system(size: 11)).foregroundStyle(PillPalette.secondary)
                case .openSettings:
                    Button("Open System Settings") { app.performErrorAction() }.buttonStyle(PillButtonStyle(kind: .primary))
                case .none:
                    EmptyView()
                }
                Spacer()
                Button("Dismiss") { app.dismissError() }.buttonStyle(PillButtonStyle(kind: .secondary))
            }
        }
    }
}

// MARK: - Controls

struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive, plain, compact, icon }
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .fixedSize()
            .font(.system(size: kind == .compact ? 12 : 13, weight: kind == .primary ? .semibold : .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .icon ? 6 : (kind == .compact ? 9 : 11))
            .padding(.vertical, kind == .compact ? 3 : 6)
            .background(RoundedRectangle(cornerRadius: kind == .compact ? 10 : 8, style: .continuous).fill(background))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .black
        case .destructive: return .white
        case .plain: return PillPalette.recording
        default: return .white
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return .white
        case .destructive: return PillPalette.recording
        case .plain, .icon: return .clear
        case .secondary, .compact: return Color.white.opacity(0.14)
        }
    }
}

/// Single-line title editor. An AppKit field so only clicking it makes the panel key.
struct TitleField: NSViewRepresentable {
    @Binding var text: String
    let onEditingChanged: (Bool) -> Void
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = "Meeting title"
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor(white: 1, alpha: 0.09)
        field.textColor = .white
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.toolTip = "Meeting title (used for the notes and the folder name)"
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TitleField

        init(_ parent: TitleField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) { parent.onEditingChanged(true) }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        private var original = ""

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onCommit()
            parent.onEditingChanged(false)
        }

        func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool {
            original = (control as? NSTextField)?.stringValue ?? ""
            return true
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)), let field = control as? NSTextField {
                field.stringValue = original  // Esc reverts
                parent.text = original
                control.window?.makeFirstResponder(nil)
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                control.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }
    }
}

// MARK: - Cards

struct CardChrome<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) { content }
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .padding(14)
            .frame(width: 330, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(PillPalette.background))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(PillPalette.stroke))
            .environment(\.colorScheme, .dark)
            .padding(4)
    }
}

struct DetectionCardView: View {
    let appName: String
    let onStart: () -> Void
    let onNotNow: () -> Void
    let onSnooze: () -> Void

    var body: some View {
        CardChrome {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "waveform.circle.fill").foregroundStyle(PillPalette.recording).font(.system(size: 18))
                Text("\(appName) is using the microphone — Start notes?").font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Tell participants you're taking notes.").font(.system(size: 11)).foregroundStyle(PillPalette.secondary)
            HStack(spacing: 6) {
                Button("Start", action: onStart).buttonStyle(PillButtonStyle(kind: .primary))
                Button("Not now", action: onNotNow).buttonStyle(PillButtonStyle(kind: .secondary))
                Button("Snooze 1 h", action: onSnooze).buttonStyle(PillButtonStyle(kind: .secondary))
            }
        }
    }
}

@MainActor
final class AutoStopModel: ObservableObject {
    @Published var prompt = AutoStopPrompt(reason: "", remaining: 60, appEnded: false)
}

struct AutoStopCardView: View {
    @ObservedObject var model: AutoStopModel
    let onStop: () -> Void
    let onKeep: () -> Void

    var body: some View {
        CardChrome {
            Text("Meeting seems to have ended — stopping in \(model.prompt.remaining) s")
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
            Text(model.prompt.reason + ". The audio is kept and notes are created.")
                .font(.system(size: 11)).foregroundStyle(PillPalette.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Stop now", action: onStop).buttonStyle(PillButtonStyle(kind: .primary))
                Button("Keep recording", action: onKeep).buttonStyle(PillButtonStyle(kind: .secondary))
            }
        }
    }
}
