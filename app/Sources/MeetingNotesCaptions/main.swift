// MeetingNotesCaptions: live captions while recording (design B, display only) with WhisperKit on the Neural Engine.
//   MeetingNotesCaptions --models DIR [--model NAME] [--compute ane|all|gpu|cpu]   serve: JSON lines on stdin/stdout
//   MeetingNotesCaptions --prepare --models DIR [--model NAME]                      download (no token) + first load
// Protocol: MeetingNotesCaptionKit/CaptionWire.swift. Spawned by the app (LiveCaptioner), bundled in
// MeetingNotes.app/Contents/MacOS by scripts/build-app.sh. Never writes transcripts: the pipeline stays authoritative.
import Foundation
import MeetingNotesCaptionKit

let version = "whisperkit-1.1.1"

struct Options {
    var models: String?
    var model = CaptionModels.defaultModel
    var compute = "ane"
    var prepare = false
}

/// Prints `progress <fraction> <phase>` on stderr when the phase changes or the fraction moves by >= 1 %.
final class ProgressPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var last = (phase: "", fraction: -1.0)

    func report(_ fraction: Double, _ phase: String) {
        lock.lock()
        defer { lock.unlock() }
        guard phase != last.phase || fraction - last.fraction >= 0.01 else { return }
        last = (phase, fraction)
        FileHandle.standardError.write((CaptionProgress(fraction: fraction, phase: phase).line + "\n").data(using: .utf8)!)
    }
}

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

func parse(_ args: [String]) -> Options {
    var o = Options()
    var i = 0
    func value() -> String {
        i += 1
        guard i < args.count else { fail("missing value for \(args[i - 1])") }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--models": o.models = value()
        case "--model": o.model = value()
        case "--compute": o.compute = value()
        case "--prepare": o.prepare = true
        case "-h", "--help": fail("usage: MeetingNotesCaptions --models DIR [--model NAME] [--compute ane|all|gpu|cpu] [--prepare]", code: 0)
        default: fail("unexpected argument: \(args[i])")
        }
        i += 1
    }
    guard o.models != nil else { fail("--models DIR is required") }
    guard ["ane", "all", "gpu", "cpu"].contains(o.compute) else { fail("bad --compute \(o.compute)") }
    return o
}

// The repo is ungated: never send a Hugging Face token (WhisperKit's hub client would read it from the environment).
for key in ["HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "HUGGINGFACE_HUB_TOKEN"] { unsetenv(key) }
setpriority(PRIO_PROCESS, 0, 5)

let opts = parse(Array(CommandLine.arguments.dropFirst()))
let directory = URL(fileURLWithPath: opts.models!, isDirectory: true)

if opts.prepare {
    // WhisperKit's hub client trusts NWPathMonitor, which can report "offline" for a moment at process start and
    // then refuses to download; this documented switch disables that check (it also prints a token notice line).
    setenv("CI_DISABLE_NETWORK_MONITOR", "1", 1)
    do {
        let printer = ProgressPrinter()
        let loadSec = try await CaptionEngine.prepare(model: opts.model, directory: directory, compute: opts.compute) {
            printer.report($0, $1)
        }
        let line = try JSONSerialization.data(withJSONObject: ["version": version, "model": opts.model, "load_sec": loadSec],
                                              options: [.sortedKeys])
        FileHandle.standardOutput.write(line + Data([0x0A]))
        exit(0)
    } catch {
        fail("MeetingNotesCaptions --prepare: \(error.localizedDescription)", code: 1)
    }
}

guard CaptionModels.isReady(opts.model, in: directory, fileExists: FileManager.default.fileExists(atPath:)) else {
    Output.send(.error("model \(opts.model) is not prepared in \(directory.path)"))
    exit(3)
}
do {
    let engine = try await CaptionEngine(model: opts.model, directory: directory, compute: opts.compute)
    await CaptionServer(engine: engine).run()
    exit(0)
} catch {
    Output.send(.error("load failed: \(error.localizedDescription)"))
    exit(1)
}
