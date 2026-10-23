import Foundation

/// One step of the packaged app's first-run setup, in the order they run.
public enum SetupStep: String, CaseIterable, Codable, Sendable {
    /// Copy the bundled pipeline, `uv sync` it with a managed Python (from the bundled uv.lock).
    case runtime
    /// Whisper + speaker-embedding weights (`meeting-notes setup --only speech`).
    case speech
    /// FluidAudio diarization models, downloaded and compiled (`--only diarization`).
    case diarization
    /// Ollama running on 127.0.0.1:11434: detected only; never installed by the app.
    case ollama
    /// The summary model pulled into Ollama (`--only summary`).
    case summary

    /// Approximate download, for the "≈ 3.4 GB" label and the byte-weighted overall progress.
    public var downloadBytes: Int64 {
        switch self {
        case .runtime: return 380_000_000
        case .speech: return 491_000_000
        case .diarization: return 21_000_000
        case .ollama: return 0
        case .summary: return 2_500_000_000
        }
    }

    /// `meeting-notes setup --only <name>` for the pipeline steps.
    public var pipelineStep: String? {
        switch self {
        case .speech: return "speech"
        case .diarization: return "diarization"
        case .summary: return "summary"
        case .runtime, .ollama: return nil
        }
    }

    public static var totalDownloadBytes: Int64 { allCases.reduce(0) { $0 + $1.downloadBytes } }
}

/// Is Ollama there? Decides what the Ollama step asks the user to do.
public enum OllamaAvailability: Equatable, Sendable {
    case running
    /// Installed (Ollama.app or the `ollama` CLI) but not answering: the user opens it.
    case notRunning(hasApp: Bool)
    /// Not installed: the user downloads it from ollama.com (or uses Homebrew). The app never installs it.
    case missing

    public static func classify(reachable: Bool, hasApp: Bool, hasCLI: Bool) -> OllamaAvailability {
        if reachable { return .running }
        return hasApp || hasCLI ? .notRunning(hasApp: hasApp) : .missing
    }
}

public enum SetupStepState: Equatable, Sendable {
    case pending
    /// fraction nil = indeterminate.
    case running(fraction: Double?, detail: String?)
    case done
    case failed(String)
    /// Only the Ollama step: the user has to install or open Ollama, then press "Check again".
    case needsUser(OllamaAvailability)
}

/// Why setup waits: one heavy job at a time, and a recording or a notes job always wins.
public enum SetupWaitReason: Equatable, Sendable { case recording, processing }

public enum SetupPhase: Equatable, Sendable {
    /// Not started by the user yet (first launch: shows "Set up").
    case notStarted
    case running
    /// Paused automatically while recording or creating notes; resumes by itself.
    case waiting(SetupWaitReason)
    /// Cancelled by the user; resumable ("Continue").
    case paused
    /// A step failed or needs the user (Ollama); "Retry" / "Check again".
    case blocked
    case complete
}

/// The first-run setup as a pure state machine. The app's `SetupRunner` asks `nextStep`, runs it (a process, or the
/// Ollama probe) and reports back; cancelling, a recording or a notes job puts the running step back to pending,
/// so every step is resumable (downloads continue where they stopped: uv cache, Hugging Face `.incomplete`, Ollama).
public struct SetupMachine: Equatable, Sendable {
    public private(set) var states: [SetupStep: SetupStepState]
    public private(set) var phase: SetupPhase

    public init(done: Set<SetupStep> = [], started: Bool = false) {
        var states: [SetupStep: SetupStepState] = [:]
        for step in SetupStep.allCases { states[step] = done.contains(step) ? .done : .pending }
        self.states = states
        phase = .notStarted
        if isAllDone { phase = .complete } else if started { phase = .running }
    }

    public func state(_ step: SetupStep) -> SetupStepState { states[step] ?? .pending }

    public var isAllDone: Bool { SetupStep.allCases.allSatisfy { state($0) == .done } }

    /// The step being run, if any.
    public var current: SetupStep? {
        SetupStep.allCases.first { if case .running = state($0) { return true } else { return false } }
    }

    /// What the runner should start now: the first unfinished step, while running and nothing else runs.
    public var nextStep: SetupStep? {
        guard phase == .running, current == nil else { return nil }
        return SetupStep.allCases.first { state($0) == .pending }
    }

    /// "Set up" / "Continue" / "Retry" / "Check again": failed and needs-user steps are tried again.
    public mutating func start() {
        guard phase != .complete else { return }
        for step in SetupStep.allCases {
            switch state(step) {
            case .failed, .needsUser: states[step] = .pending
            default: break
            }
        }
        phase = .running
        finishIfDone()
    }

    /// The user cancelled: the running step stops (back to pending) and nothing starts until "Continue".
    public mutating func cancel() {
        switch phase {
        case .running, .waiting: break
        default: return
        }
        resetCurrent()
        phase = .paused
    }

    /// Recording or processing started (reason) or ended (nil). Only a running setup waits; it resumes by itself.
    public mutating func setBusy(_ reason: SetupWaitReason?) {
        switch (phase, reason) {
        case (.running, .some(let reason)):
            resetCurrent()
            phase = .waiting(reason)
        case (.waiting, .some(let reason)):
            phase = .waiting(reason)
        case (.waiting, .none):
            phase = .running
        default:
            break
        }
    }

    public mutating func stepStarted(_ step: SetupStep) {
        guard phase == .running, state(step) == .pending else { return }
        states[step] = .running(fraction: nil, detail: nil)
    }

    /// Progress of the running step; nil keeps the previous value (a message without a fraction, or vice versa).
    public mutating func progress(_ step: SetupStep, fraction: Double?, detail: String?) {
        guard case .running(let oldFraction, let oldDetail) = state(step) else { return }
        let clamped = fraction.map { min(max($0, 0), 1) }
        states[step] = .running(fraction: clamped ?? oldFraction, detail: detail ?? oldDetail)
    }

    public mutating func finished(_ step: SetupStep) {
        guard case .running = state(step) else { return }
        states[step] = .done
        finishIfDone()
    }

    public mutating func failed(_ step: SetupStep, message: String) {
        guard case .running = state(step) else { return }
        states[step] = .failed(message)
        phase = .blocked
    }

    /// Result of the Ollama probe (the `.ollama` step).
    public mutating func ollama(_ availability: OllamaAvailability) {
        guard case .running = state(.ollama) else { return }
        if availability == .running {
            finished(.ollama)
        } else {
            states[.ollama] = .needsUser(availability)
            phase = .blocked
        }
    }

    /// A stopped process (cancel, recording) put its step back; the runner calls this when the process ends
    /// without a result while the machine still shows it running.
    public mutating func interrupted(_ step: SetupStep) {
        guard case .running = state(step) else { return }
        states[step] = .pending
    }

    /// Overall progress, weighted by download size (finished = 1, running = its fraction or 0).
    public var overallFraction: Double {
        let total = Double(SetupStep.totalDownloadBytes)
        guard total > 0 else { return 0 }
        let doneBytes = SetupStep.allCases.reduce(0.0) { sum, step in
            switch state(step) {
            case .done: return sum + Double(step.downloadBytes)
            case .running(let fraction, _): return sum + Double(step.downloadBytes) * (fraction ?? 0)
            default: return sum
            }
        }
        return min(max(doneBytes / total, 0), 1)
    }

    /// Bytes still to download (rough, for the button label).
    public var remainingBytes: Int64 {
        SetupStep.allCases.reduce(0) { $0 + (state($1) == .done ? 0 : $1.downloadBytes) }
    }

    private mutating func resetCurrent() {
        if let step = current { states[step] = .pending }
    }

    private mutating func finishIfDone() {
        if isAllDone { phase = .complete }
    }
}

/// One `meeting-notes setup --json` stdout line: `{"event":"setup","step","status","message"?,"fraction"?}`.
public struct SetupLine: Equatable, Sendable {
    public let step: String
    public let status: String
    public let message: String?
    public let fraction: Double?

    public init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["event"] as? String == "setup",
              let step = object["step"] as? String, let status = object["status"] as? String else { return nil }
        self.step = step
        self.status = status
        message = object["message"] as? String
        fraction = (object["fraction"] as? NSNumber)?.doubleValue
    }
}
