import Foundation
import MeetingNotesCaptionKit

/// The `MeetingNotesCaptions` helper (live captions, design B): where it is, where its models go, how it is started,
/// and when it must pause. The app's live rules apply: pause at critical memory pressure or on battery.
public enum CaptionHelper {
    /// The bundled helper next to the app executable, else a dev build next to the pipeline (`app/.build`).
    public static func path(executableURL: URL?, pipelineDir: String?, isExecutable: (String) -> Bool) -> String? {
        var candidates: [String] = []
        if let executableURL {
            candidates.append(executableURL.deletingLastPathComponent().appendingPathComponent(CaptionModels.helperName).path)
        }
        if let pipelineDir {
            let app = URL(fileURLWithPath: pipelineDir).deletingLastPathComponent().appendingPathComponent("app/.build")
            candidates += ["release", "debug"].map { app.appendingPathComponent("\($0)/\(CaptionModels.helperName)").path }
        }
        return candidates.first(where: isExecutable)
    }

    /// The install's `models/` next to `pipeline/` (repo, shared store or packaged runtime).
    public static func pipelineModels(pipelineDir: String?) -> URL? {
        pipelineDir.map { URL(fileURLWithPath: $0).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("models", isDirectory: true) }
    }

    /// The helper never needs a token (ungated repo): tokens are removed from its environment.
    public static func environment(_ base: [String: String]) -> [String: String] {
        var env = base
        for key in ["HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "HUGGINGFACE_HUB_TOKEN"] { env.removeValue(forKey: key) }
        return env
    }

    public static func serveArguments(models: URL, model: String) -> [String] {
        ["--models", models.path, "--model", model, "--compute", "ane"]
    }

    public static func prepareArguments(models: URL, model: String) -> [String] {
        ["--prepare"] + serveArguments(models: models, model: model)
    }

    /// Why captions must pause now, or nil. Mirrors design A (`live_pause_pressure` default critical,
    /// `live_on_battery` default false): critical pressure pauses; A's own deferral for memory/battery pauses too; on
    /// battery captions run only while A reports running (the user allowed `live_on_battery`).
    public static func pauseReason(memoryCritical: Bool, onBattery: Bool, liveStatus: LiveStatus?) -> String? {
        if memoryCritical { return "memory" }
        if let status = liveStatus, status.state == "deferred", let reason = status.reason, reason == "memory" || reason == "battery" {
            return reason
        }
        if onBattery, liveStatus?.state != "running" { return "battery" }
        return nil
    }
}

/// Download/prepare state of the caption model (Settings help line and pill).
public enum CaptionModelState: Equatable, Sendable {
    case unknown, missing, ready
    case preparing(Double?)
    case failed(String)

    public var isReady: Bool { self == .ready }
}
