// The collapsed floating pill with its mini meters and warning badge (Pill).

import MeetingNotesCore
import SwiftUI

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
