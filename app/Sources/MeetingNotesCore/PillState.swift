import Foundation

public enum PermissionKind: String, CaseIterable, Equatable, Sendable {
    case microphone, screenCapture, notifications
}

/// Authorization state of one permission, as shown in the UI.
public enum PermissionStatus: Equatable, Sendable {
    case granted, denied, notDetermined, unavailable

    public func label(_ lang: UILanguage = L10n.language) -> String {
        switch self {
        case .granted: return tr(.permAllowed, lang: lang)
        case .denied: return tr(.permDenied, lang: lang)
        case .notDetermined: return tr(.permNotDetermined, lang: lang)
        case .unavailable: return tr(.permUnavailable, lang: lang)
        }
    }
}

/// The result shown in the "Done" state.
public struct ReadyInfo: Equatable, Sendable {
    public var folder: String
    public var title: String
    /// notes.md path, nil when only audio was saved (manual "Create notes" mode).
    public var notesPath: String?

    public init(folder: String, title: String, notesPath: String?) {
        self.folder = folder
        self.title = title
        self.notesPath = notesPath
    }

    public var hasNotes: Bool { notesPath != nil }
}

public enum PillErrorAction: Equatable, Sendable {
    case retry(folder: String)
    case openSettings(PermissionKind)
    case none
}

public struct PillError: Equatable, Sendable {
    public var message: String
    public var action: PillErrorAction

    public init(_ message: String, action: PillErrorAction = .none) {
        self.message = message
        self.action = action
    }
}

/// Everything the floating pill can show. Derived from the recorder, the job queue and transient results.
public enum PillState: Equatable, Sendable {
    /// `attention`: a permission needs fixing.
    case idle(attention: Bool)
    case starting
    case recording
    case paused
    case stopping
    case processing(ProcessingSnapshot)
    case ready(ReadyInfo)
    case error(PillError)

    /// Priority: an active recording > error > processing > ready > idle.
    public static func derive(
        phase: RecorderPhase, error: PillError?, processing: ProcessingSnapshot?, ready: ReadyInfo?,
        permissionsNeedAttention: Bool
    ) -> PillState {
        switch phase {
        case .starting: return .starting
        case .recording: return .recording
        case .paused: return .paused
        case .stopping: return .stopping
        case .idle: break
        }
        if let error { return .error(error) }
        if let processing { return .processing(processing) }
        if let ready { return .ready(ready) }
        return .idle(attention: permissionsNeedAttention)
    }

    /// State label of the pill and the main window header.
    public func label(_ lang: UILanguage = L10n.language) -> String {
        switch self {
        case .idle(let attention): return tr(attention ? .statePermissionsNeeded : .stateReady, lang: lang)
        case .starting: return tr(.stateStarting, lang: lang)
        case .recording: return tr(.stateRecording, lang: lang)
        case .paused: return tr(.statePaused, lang: lang)
        case .stopping: return tr(.stateSaving, lang: lang)
        case .processing(let snapshot):
            return snapshot.waiting != nil ? tr(.stateWaiting, lang: lang) : tr(.stateProcessingPercent, lang: lang, snapshot.percent)
        case .ready(let info): return tr(info.hasNotes ? .stateDone : .stateRecordingSaved, lang: lang)
        case .error: return tr(.stateError, lang: lang)
        }
    }

    /// Value of `state` in state.json.
    public var name: String {
        switch self {
        case .idle: return "idle"
        case .starting: return "starting"
        case .recording: return "recording"
        case .paused: return "paused"
        case .stopping: return "stopping"
        case .processing: return "processing"
        case .ready: return "ready"
        case .error: return "error"
        }
    }

    /// Recording or paused: the pill must stay visible.
    public var isCapturing: Bool {
        switch self {
        case .starting, .recording, .paused, .stopping: return true
        default: return false
        }
    }

    public var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
}
