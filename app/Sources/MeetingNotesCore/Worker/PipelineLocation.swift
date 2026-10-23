import Foundation

/// Where the pipeline worker lives and how it is launched (`uv run --project <dir> meeting-notes worker`).
///
/// Per-user (dev) install: Info.plist `MNPipelineDir` / `MNUvPath`, baked by scripts/build-app.sh.
/// Shared install (`scripts/install.sh --shared`): pipeline, venv, uv and models live in a world-readable directory
/// (default /Users/Shared/MeetingNotes) with `shared-install.json` next to `pipeline/`. Other accounts cannot write
/// there, so the worker runs the prebuilt environment as is (`UV_NO_SYNC`, `UV_FROZEN`) and uses the shared uv.
public struct PipelineLocation: Equatable, Sendable {
    public let pipelineDir: String
    public let uvPath: String
    public let shared: Bool

    public init(pipelineDir: String, uvPath: String, shared: Bool) {
        self.pipelineDir = pipelineDir
        self.uvPath = uvPath
        self.shared = shared
    }
}

public enum PipelineLocator {
    public static let sharedRoot = "/Users/Shared/MeetingNotes"
    public static let markerName = "shared-install.json"
    public static let defaultUvPath = "/opt/homebrew/bin/uv"

    /// Fields of `shared-install.json` the app reads.
    public struct Marker: Decodable, Equatable, Sendable {
        public let pipelineDir: String?
        public let uvPath: String?

        enum CodingKeys: String, CodingKey {
            case pipelineDir = "pipeline_dir"
            case uvPath = "uv_path"
        }

        public static func parse(_ data: Data?) -> Marker? {
            guard let data else { return nil }
            return try? JSONDecoder().decode(Marker.self, from: data)
        }
    }

    /// Pipeline dir: user override, Info.plist, `MN_PIPELINE_DIR`, then the shared install's marker.
    /// uv: user override, the shared install's uv (when the pipeline is shared), Info.plist, Homebrew.
    /// `readFile` returns a file's contents or nil (tests inject it).
    public static func resolve(pipelineOverride: String?, pipelineInfo: String?, pipelineEnv: String?,
                               uvOverride: String?, uvInfo: String?,
                               sharedRoot: String = sharedRoot,
                               readFile: (String) -> Data?) -> PipelineLocation? {
        let fallbackMarker = Marker.parse(readFile(markerPath(inRoot: sharedRoot)))
        guard let dir = nonEmpty(pipelineOverride) ?? nonEmpty(pipelineInfo) ?? nonEmpty(pipelineEnv)
            ?? nonEmpty(fallbackMarker?.pipelineDir) else { return nil }
        let marker = Marker.parse(readFile(markerPath(forPipeline: dir)))
        let shared = marker != nil
        let uv = nonEmpty(uvOverride) ?? (shared ? nonEmpty(marker?.uvPath) : nil) ?? nonEmpty(uvInfo) ?? defaultUvPath
        return PipelineLocation(pipelineDir: dir, uvPath: uv, shared: shared)
    }

    /// The marker sits in the parent of `pipeline/` (the install root).
    public static func markerPath(forPipeline dir: String) -> String {
        URL(fileURLWithPath: dir).standardizedFileURL.deletingLastPathComponent().appendingPathComponent(markerName).path
    }

    public static func markerPath(inRoot root: String) -> String {
        URL(fileURLWithPath: root).appendingPathComponent(markerName).path
    }

    /// Worker environment for a shared install: never sync or re-lock the shared, read-only environment, never
    /// download a Python. Values already set are kept; a per-user install is unchanged.
    public static func workerEnvironment(_ environment: [String: String], location: PipelineLocation) -> [String: String] {
        guard location.shared else { return environment }
        var result = environment
        for (key, value) in ["UV_NO_SYNC": "1", "UV_FROZEN": "1", "UV_PYTHON_DOWNLOADS": "never"]
        where (result[key] ?? "").isEmpty {
            result[key] = value
        }
        return result
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}
