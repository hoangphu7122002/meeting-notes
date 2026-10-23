// The expanded card above the pill; picks the section for the current state (Pill).

import MeetingNotesCore
import SwiftUI

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
            if attention {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
            } else {
                BrandGlyphIcon(size: 18)
            }
        default: Image(systemName: "ellipsis.circle").foregroundStyle(Palette.secondary)
        }
    }
}
