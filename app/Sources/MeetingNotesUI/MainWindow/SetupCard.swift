// First-run setup of the packaged app: one button, then each step with its progress (MainWindow).

import AppKit
import MeetingNotesCore
import SwiftUI

struct SetupCard: View {
    let machine: SetupMachine
    let location: AppLocation
    let summaryModel: String
    let commands: any AppCommands

    var body: some View {
        SectionCard(tr(.setupHeading)) {
            if !location.isStable { LocationWarning() }
            Text(tr(.setupIntro, SetupFormat.bytes(SetupStep.totalDownloadBytes)))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(SetupStep.allCases, id: \.self) { step in
                    SetupStepRow(step: step, state: machine.state(step), summaryModel: summaryModel, commands: commands)
                }
            }
            if machine.phase != .notStarted && machine.phase != .complete {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressBar(value: machine.overallFraction, color: Color.accentColor, height: 6)
                    Text("\(Int((machine.overallFraction * 100).rounded()))%").monospacedDigit().fontWeight(.medium)
                }
            }
            if let note = phaseNote { Text(note).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true) }
            buttons
            Text(tr(.setupGatekeeperNote)).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var phaseNote: String? {
        switch machine.phase {
        case .waiting(.recording): return tr(.setupWaitingRecording)
        case .waiting(.processing): return tr(.setupWaitingProcessing)
        case .paused: return tr(.setupPaused)
        case .complete: return tr(.setupComplete)
        default: return nil
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 8) {
            switch machine.phase {
            case .notStarted:
                Button(tr(.actionSetUp, SetupFormat.bytes(machine.remainingBytes))) { commands.setupAction(.start) }
                    .buttonStyle(.borderedProminent)
            case .running, .waiting:
                Button(tr(.actionCancel)) { commands.setupAction(.cancel) }
            case .paused:
                Button(tr(.actionContinueSetup)) { commands.setupAction(.start) }.buttonStyle(.borderedProminent)
            case .blocked:
                if case .needsUser = machine.state(.ollama) {
                    Button(tr(.actionCheckAgain)) { commands.setupAction(.start) }.buttonStyle(.borderedProminent)
                } else {
                    Button(tr(.actionRetry)) { commands.setupAction(.start) }.buttonStyle(.borderedProminent)
                }
            case .complete:
                EmptyView()
            }
        }
    }
}

private struct LocationWarning: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
            Text(tr(.setupMoveToApplications)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SetupStepRow: View {
    let step: SetupStep
    let state: SetupStepState
    let summaryModel: String
    let commands: any AppCommands

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium)
                    if step.downloadBytes > 0 {
                        Text("~\(SetupFormat.bytes(step.downloadBytes))").foregroundStyle(Palette.secondary).monospacedDigit()
                    }
                }
                detail
            }
            Spacer(minLength: 8)
        }
    }

    private var title: String {
        switch step {
        case .runtime: return tr(.setupStepRuntime)
        case .speech: return tr(.setupStepSpeech)
        case .diarization: return tr(.setupStepDiarization)
        case .ollama: return tr(.setupStepOllama)
        case .summary: return tr(.setupStepSummary, summaryModel)
        }
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ok)
        case .running(let fraction, _): ProgressRing(value: fraction ?? 0.05)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.warning)
        case .needsUser: Image(systemName: "hand.raised.circle.fill").foregroundStyle(Palette.warning)
        case .pending: Image(systemName: "circle").foregroundStyle(Palette.secondary)
        }
    }

    @ViewBuilder private var detail: some View {
        switch state {
        case .running(let fraction, let detail):
            if let fraction { ProgressBar(value: fraction, color: Color.accentColor, height: 4).frame(maxWidth: 260) }
            Text(detail ?? tr(.setupWorking)).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                .lineLimit(1).truncationMode(.middle)
        case .failed(let message):
            Text(tr(.setupFailed, message)).font(.system(size: 11)).foregroundStyle(Palette.warning)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        case .needsUser(let availability):
            OllamaHelp(availability: availability, commands: commands)
        case .done, .pending:
            EmptyView()
        }
    }
}

private struct OllamaHelp: View {
    let availability: OllamaAvailability
    let commands: any AppCommands

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch availability {
            case .missing:
                Text(tr(.setupOllamaMissing)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(tr(.actionDownloadOllama)) { commands.setupAction(.downloadOllama) }
                    Button(tr(.actionCopyBrewCommand)) { commands.setupAction(.copyBrewCommand) }
                }
            case .notRunning(let hasApp):
                Text(tr(.setupOllamaNotRunning)).fixedSize(horizontal: false, vertical: true)
                if hasApp {
                    Button(tr(.actionOpenOllama)) { commands.setupAction(.openOllama) }
                } else {
                    Button(tr(.actionCopyBrewCommand)) { commands.setupAction(.copyBrewCommand) }
                }
            case .running:
                EmptyView()
            }
        }
        .font(.system(size: 12))
    }
}

enum SetupFormat {
    /// "3.4 GB" / "3,4 GB", "380 MB" (decimal units, separator of the UI language).
    static func bytes(_ count: Int64) -> String {
        let text = count >= 1_000_000_000
            ? String(format: "%.1f GB", Double(count) / 1e9)
            : String(format: "%.0f MB", (Double(count) / 1e6).rounded())
        return L10n.language == .vi ? text.replacingOccurrences(of: ".", with: ",") : text
    }
}
