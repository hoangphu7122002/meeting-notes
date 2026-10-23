import Foundation

/// Whether a running worker may take the next job instead of being respawned, so its warm models are reused.
///
/// The worker's environment is `priority|model`. The model must always match. Priority must match too, except
/// for an explicit job (Retry, "Create notes now"): it takes any running worker, because a respawn would drop
/// models the pipeline may still hold warm (`keep_models_warm = "auto"`) and pay the import + load again.
public enum WorkerReuse {
    public static func key(priority: String, model: String) -> String { "\(priority)|\(model)" }

    public static func canReuse(runningKey: String?, priority: String, model: String, explicit: Bool) -> Bool {
        guard let runningKey else { return false }
        if runningKey == key(priority: priority, model: model) { return true }
        guard explicit, let bar = runningKey.firstIndex(of: "|") else { return false }
        return runningKey[runningKey.index(after: bar)...] == model
    }
}
