import Foundation

public enum RecorderPhase: String, Equatable, Sendable {
    case idle, starting, recording, paused, stopping

    /// Capture exists (running or paused).
    public var isActive: Bool { self == .recording || self == .paused }
}

/// User-visible recorder actions (buttons and menu items).
public enum RecorderAction: CaseIterable, Sendable {
    case start, pause, resume, stop, discard
}

public enum RecorderCommand: Equatable, Sendable {
    case start, stop, pause, resume
    /// Start/stop hotkey (⌃⌥⌘R).
    case toggleRecording
    /// Pause/resume hotkey (⌃⌥⌘P).
    case togglePause
    case requestDiscard, confirmDiscard, cancelDiscard
}

/// Side effect the app must perform after a command.
public enum RecorderEffect: Equatable, Sendable {
    case none, startCapture, stopCapture, pauseCapture, resumeCapture, discardCapture
}

/// Results of asynchronous capture work, fed back into the machine.
public enum RecorderEvent: Equatable, Sendable {
    case started, startFailed, finished
}

public struct RecorderOutcome: Equatable, Sendable {
    public var effect: RecorderEffect
    public var toast: String?

    public init(_ effect: RecorderEffect, toast: String? = nil) {
        self.effect = effect
        self.toast = toast
    }
}

/// Recorder lifecycle. Guarantees a single recording: start is ignored unless idle, stop/pause/discard
/// only act on an active recording, and discard needs an explicit confirmation.
public struct RecorderMachine: Equatable, Sendable {
    public private(set) var phase: RecorderPhase
    public private(set) var confirmingDiscard = false

    public init(phase: RecorderPhase = .idle) {
        self.phase = phase
    }

    public func isEnabled(_ action: RecorderAction) -> Bool {
        switch action {
        case .start: return phase == .idle
        case .pause: return phase == .recording
        case .resume: return phase == .paused
        case .stop, .discard: return phase.isActive
        }
    }

    public mutating func handle(_ command: RecorderCommand) -> RecorderOutcome {
        switch command {
        case .start:
            switch phase {
            case .idle:
                phase = .starting
                return RecorderOutcome(.startCapture)
            case .starting, .recording, .paused:
                return RecorderOutcome(.none, toast: "Already recording")
            case .stopping:
                return RecorderOutcome(.none, toast: "Still saving the last recording")
            }
        case .stop:
            guard phase.isActive else { return RecorderOutcome(.none, toast: phase == .idle ? "Not recording" : nil) }
            phase = .stopping
            confirmingDiscard = false
            return RecorderOutcome(.stopCapture, toast: "Stopped – creating notes…")
        case .toggleRecording:
            switch phase {
            case .idle: return handle(.start)
            case .recording, .paused: return handle(.stop)
            case .starting, .stopping: return RecorderOutcome(.none)
            }
        case .pause:
            switch phase {
            case .recording:
                phase = .paused
                return RecorderOutcome(.pauseCapture, toast: "Paused")
            case .paused: return RecorderOutcome(.none, toast: "Already paused")
            default: return RecorderOutcome(.none, toast: "Not recording")
            }
        case .resume:
            switch phase {
            case .paused:
                phase = .recording
                return RecorderOutcome(.resumeCapture, toast: "Resumed")
            case .recording: return RecorderOutcome(.none, toast: "Already recording")
            default: return RecorderOutcome(.none, toast: "Not recording")
            }
        case .togglePause:
            switch phase {
            case .recording: return handle(.pause)
            case .paused: return handle(.resume)
            default: return RecorderOutcome(.none, toast: "Not recording")
            }
        case .requestDiscard:
            guard phase.isActive else { return RecorderOutcome(.none) }
            confirmingDiscard = true
            return RecorderOutcome(.none)
        case .confirmDiscard:
            guard confirmingDiscard, phase.isActive else {
                confirmingDiscard = false
                return RecorderOutcome(.none)
            }
            confirmingDiscard = false
            phase = .stopping
            return RecorderOutcome(.discardCapture)
        case .cancelDiscard:
            confirmingDiscard = false
            return RecorderOutcome(.none)
        }
    }

    public mutating func apply(_ event: RecorderEvent) {
        switch event {
        case .started:
            if phase == .starting { phase = .recording }
        case .startFailed:
            if phase == .starting { phase = .idle }
        case .finished:
            phase = .idle
            confirmingDiscard = false
        }
    }
}
