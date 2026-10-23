import Foundation

/// Per-user runtime of the packaged app (release dmg): everything the first-run setup creates, in one folder that
/// is never inside the signed bundle, so updates and uninstall are simple.
///
///     ~/Library/Application Support/MeetingNotes/runtime/
///       pipeline/            copy of the bundled pipeline source (Contents/Resources/pipeline) + its .venv
///       python/              uv-managed Python 3.12 (python-build-standalone)
///       bin/uv               copy of the bundled uv
///       cache/uv             uv's wheel cache
///       models/              huggingface/hub (whisper, embeddings) and fluidaudio (diarization)
///       shared-install.json  marker (`"mode": "packaged"`): PipelineLocator and the pipeline's config/install.py
///       setup-state.json     which setup steps finished, for which app version (`SetupRecord`)
public struct RuntimeLayout: Equatable, Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// The runtime inside the app's Application Support folder.
    public init(supportDir: URL) { root = supportDir.appendingPathComponent("runtime", isDirectory: true) }

    public var pipelineDir: URL { root.appendingPathComponent("pipeline", isDirectory: true) }
    public var venvDir: URL { pipelineDir.appendingPathComponent(".venv", isDirectory: true) }
    public var cli: URL { venvDir.appendingPathComponent("bin/meeting-notes") }
    public var pythonDir: URL { root.appendingPathComponent("python", isDirectory: true) }
    public var uvPath: URL { root.appendingPathComponent("bin/uv") }
    public var uvCacheDir: URL { root.appendingPathComponent("cache/uv", isDirectory: true) }
    public var modelsDir: URL { root.appendingPathComponent("models", isDirectory: true) }
    public var hubCacheDir: URL { modelsDir.appendingPathComponent("huggingface/hub", isDirectory: true) }
    public var fluidAudioDir: URL { modelsDir.appendingPathComponent("fluidaudio", isDirectory: true) }
    public var markerURL: URL { root.appendingPathComponent(PipelineLocator.markerName) }
    public var stateURL: URL { root.appendingPathComponent("setup-state.json") }

    /// Entries of the bundled pipeline copied into `pipelineDir` (everything else there, e.g. `.venv`, is kept).
    public static let pipelineEntries = ["pyproject.toml", "uv.lock", ".python-version", "src"]

    /// `shared-install.json` for this runtime (same keys as a shared install, plus `mode` and `app_version`).
    public func marker(appPath: String, appVersion: String, date: Date = Date()) -> Data {
        let fields: [String: Any] = [
            "version": 1,
            "mode": "packaged",
            "root": root.path,
            "pipeline_dir": pipelineDir.path,
            "uv_path": uvPath.path,
            "models_dir": modelsDir.path,
            "hf_hub_cache": hubCacheDir.path,
            "app": appPath,
            "app_version": appVersion,
            "installed": ISO8601DateFormatter().string(from: date),
        ]
        return (try? JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// Environment for `uv sync` of the runtime: a managed Python in `python/`, the wheel cache in `cache/uv`, never
    /// the user's virtualenv or a Homebrew Python. Values for these keys in `base` are replaced.
    public func syncEnvironment(_ base: [String: String]) -> [String: String] {
        var env = base
        env.removeValue(forKey: "VIRTUAL_ENV")
        env.removeValue(forKey: "UV_PROJECT_ENVIRONMENT")
        env["UV_PYTHON_INSTALL_DIR"] = pythonDir.path
        env["UV_PYTHON_PREFERENCE"] = "only-managed"
        env["UV_CACHE_DIR"] = uvCacheDir.path
        env["UV_NO_PROGRESS"] = "1"
        return env
    }

    /// `uv sync` arguments: exactly the bundled lockfile, no dev tools, bytecode compiled once.
    public var syncArguments: [String] {
        ["sync", "--project", pipelineDir.path, "--frozen", "--no-dev", "--compile-bytecode"]
    }
}

/// What the first-run setup has finished (`runtime/setup-state.json`). The runtime step is tied to the app version
/// (an update ships new pipeline code); model steps are not (weights stay valid across updates).
public struct SetupRecord: Codable, Equatable, Sendable {
    public var runtimeVersion: String?
    public var done: [String]
    public var completedOnce: Bool

    public init(runtimeVersion: String? = nil, done: [String] = [], completedOnce: Bool = false) {
        self.runtimeVersion = runtimeVersion
        self.done = done
        self.completedOnce = completedOnce
    }

    public static func parse(_ data: Data?) -> SetupRecord {
        guard let data, let record = try? JSONDecoder().decode(SetupRecord.self, from: data) else { return SetupRecord() }
        return record
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// Steps that need no work now. `runtimeReady` = the marker and the environment's CLI exist on disk.
    /// Ollama and its model are probed live by the setup, so they are never "done" from the record alone,
    /// except the summary model once it was pulled (Ollama keeps it).
    public func doneSteps(appVersion: String, runtimeReady: Bool) -> Set<SetupStep> {
        var result = Set<SetupStep>()
        if runtimeReady, runtimeVersion == appVersion { result.insert(.runtime) }
        for step in [SetupStep.speech, .diarization, .summary] where done.contains(step.rawValue) { result.insert(step) }
        if result.contains(.summary) { result.insert(.ollama) }
        return result
    }

    public mutating func markDone(_ step: SetupStep, appVersion: String) {
        if step == .runtime { runtimeVersion = appVersion }
        if !done.contains(step.rawValue) { done.append(step.rawValue) }
    }
}

/// Where the app bundle runs from. Gatekeeper's App Translocation (a quarantined app opened in place) and a
/// mounted dmg are read-only, random or temporary paths: permissions and Launch at Login need a stable one.
public enum AppLocation: Equatable, Sendable {
    case applications, translocated, diskImage, elsewhere

    public static func classify(bundlePath: String, home: String) -> AppLocation {
        let path = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
        if path.contains("/AppTranslocation/") { return .translocated }
        if path.hasPrefix("/Volumes/") { return .diskImage }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let homeApps = URL(fileURLWithPath: home).appendingPathComponent("Applications").standardizedFileURL.path
        return parent == "/Applications" || parent == homeApps ? .applications : .elsewhere
    }

    public var isStable: Bool { self == .applications }
}
