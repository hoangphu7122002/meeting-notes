// Main window list of recent meetings (MainWindow).

import MeetingNotesCore
import SwiftUI

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
