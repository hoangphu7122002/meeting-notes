import Foundation

/// Caption model choice and where its files live (shared by the app and the helper).
///
/// Models come from the ungated Hugging Face repo `argmaxinc/whisperkit-coreml` at a pinned commit (no token), plus
/// the matching `openai/whisper-*` tokenizer, into `<models>/whisperkit/`:
///     models/argmaxinc/whisperkit-coreml/<model>/   Core ML encoder/decoder/mel (WhisperKit layout)
///     models/openai/whisper-<size>/tokenizer.json
///     ready-<model>.json                             written by `--prepare` after a full download + first load
public enum CaptionModels {
    /// Chosen by `docs/research/realtime-feasibility.md` section 11 (quality vs latency/RAM on M1 Pro).
    public static let defaultModel = "openai_whisper-small_216MB"
    public static let candidates = ["openai_whisper-tiny", "openai_whisper-base", "openai_whisper-small",
                                    "openai_whisper-small_216MB", "openai_whisper-large-v3-v20240930_turbo_632MB"]
    public static let repo = "argmaxinc/whisperkit-coreml"
    /// Commit of `argmaxinc/whisperkit-coreml` the helper downloads (2026-08-19).
    public static let revision = "0f63a7800b00dd0226abd051b906c246e1907482"
    public static let helperName = "MeetingNotesCaptions"
    public static let directoryName = "whisperkit"

    /// Approximate download size in MB (UI copy).
    public static func downloadMB(_ model: String) -> Int {
        switch model {
        case "openai_whisper-tiny": return 77
        case "openai_whisper-base": return 147
        case "openai_whisper-small": return 486
        case "openai_whisper-small_216MB": return 217
        case "openai_whisper-large-v3-v20240930_turbo_632MB": return 646
        default: return 250
        }
    }

    public static func modelFolder(_ model: String, in directory: URL) -> URL {
        directory.appendingPathComponent("models/\(repo)/\(model)", isDirectory: true)
    }

    public static func readyMarker(_ model: String, in directory: URL) -> URL {
        directory.appendingPathComponent("ready-\(model).json")
    }

    public static func readyMarkerData(model: String, loadSec: Double, date: Date = Date()) -> Data {
        let object: [String: Any] = ["model": model, "repo": repo, "revision": revision, "load_sec": loadSec,
                                     "prepared": ISO8601DateFormatter().string(from: date)]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// The model is downloaded and was loaded once (`--prepare` finished) in `directory`.
    public static func isReady(_ model: String, in directory: URL, fileExists: (String) -> Bool) -> Bool {
        fileExists(readyMarker(model, in: directory).path)
    }

    /// Where captions keep their models. `pipelineModels` = the install's `models/` (repo, shared store or packaged
    /// runtime, next to `pipeline/`); `userModels` = this account's Application Support fallback. A ready store wins
    /// (shared install: prefetched by its owner); otherwise the first writable one is used for the download.
    public static func directory(pipelineModels: URL?, userModels: URL, model: String,
                                 fileExists: (String) -> Bool, isWritable: (String) -> Bool) -> URL {
        let shared = pipelineModels?.appendingPathComponent(directoryName, isDirectory: true)
        let user = userModels.appendingPathComponent(directoryName, isDirectory: true)
        for candidate in [shared, user].compactMap({ $0 }) where isReady(model, in: candidate, fileExists: fileExists) {
            return candidate
        }
        if let shared, let parent = pipelineModels, isWritable(fileExists(shared.path) ? shared.path : parent.path) {
            return shared
        }
        return user
    }
}
