// WhisperKit wrapper of the caption helper: load a prepared model, decode one window, download + prewarm.

import CoreML
import Foundation
import MeetingNotesCaptionKit
import WhisperKit

final class CaptionEngine: @unchecked Sendable {
    let model: String
    let compute: String
    let loadSec: Double
    private let kit: WhisperKit

    static func computeUnits(_ name: String) -> MLComputeUnits {
        switch name {
        case "cpu": return .cpuOnly
        case "gpu": return .cpuAndGPU
        case "all": return .all
        default: return .cpuAndNeuralEngine  // "ane": keeps the GPU free for the call and MLX
        }
    }

    /// Loads `model` from `directory` (no network once prepared; the tokenizer is cached there too).
    init(model: String, directory: URL, compute: String, prewarm: Bool = false) async throws {
        self.model = model
        self.compute = compute
        let units = Self.computeUnits(compute)
        let options = ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: units, textDecoderCompute: units)
        let config = WhisperKitConfig(
            modelFolder: CaptionModels.modelFolder(model, in: directory).path, tokenizerFolder: directory,
            computeOptions: options, verbose: false, logLevel: .error, prewarm: prewarm, load: true, download: false)
        let t0 = Date()
        kit = try await WhisperKit(config)
        loadSec = Date().timeIntervalSince(t0)
    }

    /// Decodes a window. `language` nil = detect first (restricted to vi/en: anything else falls back to `prior`).
    func decode(_ audio: [Float], language: String?, prior: String) async throws -> (pieces: [CaptionPiece], language: String) {
        var chosen = language ?? prior
        if language == nil, let detected = try? await kit.detectLangauge(audioArray: audio).language,
           detected == "vi" || detected == "en" {
            chosen = detected
        }
        return (try await run(audio, language: chosen), chosen)
    }

    private func run(_ audio: [Float], language: String) async throws -> [CaptionPiece] {
        let duration = Double(audio.count) / Double(CaptionWire.sampleRate)
        return Self.pieces(try await kit.transcribe(audioArray: audio, decodeOptions: options(language: language)))
            .filter { $0.start < duration - 0.1 }
            .map { CaptionPiece(start: $0.start, end: min($0.end, duration), text: $0.text) }
    }

    private func options(language: String) -> DecodingOptions {
        DecodingOptions(
            verbose: false, task: .transcribe, language: language, temperature: 0, temperatureFallbackCount: 1,
            usePrefillPrompt: true, detectLanguage: false, skipSpecialTokens: true, withoutTimestamps: false,
            suppressBlank: true, compressionRatioThreshold: 2.4, logProbThreshold: -1.0, firstTokenLogProbThreshold: -1.5,
            noSpeechThreshold: 0.6, concurrentWorkerCount: 1)
    }

    private static func pieces(_ results: [TranscriptionResult]) -> [CaptionPiece] {
        results.flatMap(\.segments)
            .filter { !($0.noSpeechProb > 0.6 && $0.avgLogprob < -0.7) && $0.compressionRatio <= 2.6 }
            .map { CaptionPiece(start: Double($0.start), end: Double($0.end), text: $0.text) }
    }

    /// Downloads the pinned model (no token) into `directory`, loads it once (tokenizer download, Core ML / Neural
    /// Engine specialization) and writes the ready marker. Progress goes to `report` (fraction 0...1, phase).
    static func prepare(model: String, directory: URL, compute: String, report: @escaping @Sendable (Double, String) -> Void) async throws -> Double {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hub = HubApiWrapper(downloadBase: directory, hfToken: nil, endpoint: nil)
        report(0, "listing")
        _ = try await hub.snapshot(from: HubApiWrapper.Repo(id: CaptionModels.repo), revision: CaptionModels.revision,
                                   matching: ["\(model)/*"]) { progress in
            report(0.85 * progress.fractionCompleted, "downloading")
        }
        report(0.85, "compiling")
        let engine = try await CaptionEngine(model: model, directory: directory, compute: compute, prewarm: true)
        try CaptionModels.readyMarkerData(model: model, loadSec: engine.loadSec)
            .write(to: CaptionModels.readyMarker(model, in: directory), options: .atomic)
        report(1, "ready")
        return engine.loadSec
    }
}
