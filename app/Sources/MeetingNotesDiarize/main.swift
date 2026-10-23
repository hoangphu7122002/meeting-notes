// MeetingNotesDiarize: offline speaker diarization of one audio file with FluidAudio (Core ML port of pyannote community-1).
//   MeetingNotesDiarize <audio.wav> [--models DIR] [--rttm PATH] [--threshold X] [--min-speakers N] [--max-speakers N]
//              [--num-speakers N] [--compute all|cpu|cpu-gpu|cpu-ane]
//   MeetingNotesDiarize --prepare [--models DIR]      download (no token) + compile models, then exit
// Helper for the pipeline's opt-in `diarization_engine = "fluidaudio"` (adapters/outbound/fluidaudio_diarizer.py).
// Prints one JSON object on stdout: {version, load_sec, diarize_sec, audio_sec, speakers, segments: [{start, end, speaker}]}.
import AVFoundation
import CoreML
import FluidAudio
import Foundation

let version = "fluidaudio-0.17.7"

struct Options {
    var input: String?
    var prepareOnly = false
    var models: String?
    var rttm: String?
    var threshold: Double?
    var minSpeakers: Int?
    var maxSpeakers: Int?
    var numSpeakers: Int?
    var compute = "all"
}

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

func parse(_ args: [String]) -> Options {
    var o = Options()
    var i = 0
    func int() -> Int {
        let v = value()
        guard let n = Int(v) else { fail("bad value \(v) for \(args[i - 1])") }
        return n
    }
    func value() -> String {
        i += 1
        guard i < args.count else { fail("missing value for \(args[i - 1])") }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--prepare": o.prepareOnly = true
        case "--models": o.models = value()
        case "--rttm": o.rttm = value()
        case "--threshold": let v = value(); guard let t = Double(v) else { fail("bad --threshold \(v)") }; o.threshold = t
        case "--min-speakers": o.minSpeakers = int()
        case "--max-speakers": o.maxSpeakers = int()
        case "--num-speakers": o.numSpeakers = int()
        case "--compute": o.compute = value()
        case "-h", "--help": fail("usage: MeetingNotesDiarize <audio.wav> [--models DIR] [--rttm PATH] [--threshold X] "
            + "[--min-speakers N] [--max-speakers N] [--num-speakers N] [--compute all|cpu|cpu-gpu|cpu-ane] | --prepare", code: 0)
        default:
            if args[i].hasPrefix("-") || o.input != nil { fail("unexpected argument: \(args[i])") }
            o.input = args[i]
        }
        i += 1
    }
    if !o.prepareOnly && o.input == nil { fail("no input file") }
    return o
}

func computeUnits(_ name: String) -> MLComputeUnits {
    switch name {
    case "cpu": return .cpuOnly
    case "cpu-gpu": return .cpuAndGPU
    case "cpu-ane": return .cpuAndNeuralEngine
    case "all": return .all
    default: fail("bad --compute \(name)")
    }
}

func emit(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

let opts = parse(Array(CommandLine.arguments.dropFirst()))
var config = OfflineDiarizerConfig()
if let t = opts.threshold { config.clustering.threshold = t }
config.clustering.minSpeakers = opts.minSpeakers
config.clustering.maxSpeakers = opts.maxSpeakers
config.clustering.numSpeakers = opts.numSpeakers
let mlConfig = MLModelConfiguration()
mlConfig.computeUnits = computeUnits(opts.compute)
let modelsDir = opts.models.map { URL(fileURLWithPath: $0, isDirectory: true) }

do {
    let t0 = Date()
    let manager = OfflineDiarizerManager(config: config)
    try await manager.prepareModels(directory: modelsDir, configuration: mlConfig)
    let loadSec = Date().timeIntervalSince(t0)
    if opts.prepareOnly {
        emit(["version": version, "load_sec": loadSec, "segments": []])
        exit(0)
    }
    let url = URL(fileURLWithPath: opts.input!)
    let file = try AVAudioFile(forReading: url)
    let audioSec = Double(file.length) / file.fileFormat.sampleRate
    let t1 = Date()
    let result = try await manager.process(url)
    let diarizeSec = Date().timeIntervalSince(t1)
    let segments = result.segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
    if let rttm = opts.rttm {
        let name = url.deletingPathExtension().lastPathComponent
        let lines = segments.map {
            String(format: "SPEAKER %@ 1 %.3f %.3f <NA> <NA> %@ <NA> <NA>", name,
                   Double($0.startTimeSeconds), Double($0.durationSeconds), $0.speakerId)
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: rttm, atomically: true, encoding: .utf8)
    }
    emit([
        "version": version, "load_sec": loadSec, "diarize_sec": diarizeSec, "audio_sec": audioSec,
        "speakers": Set(segments.map(\.speakerId)).count,
        "segments": segments.map {
            ["start": Double($0.startTimeSeconds), "end": Double($0.endTimeSeconds), "speaker": $0.speakerId]
        },
    ])
} catch {
    fail("MeetingNotesDiarize: \(error)", code: 1)
}
