// Main window cards for the processing, ready and error states (MainWindow).

import MeetingNotesCore
import SwiftUI

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
