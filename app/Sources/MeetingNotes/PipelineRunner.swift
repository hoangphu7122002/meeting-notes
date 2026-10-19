import Foundation

/// Runs `uv run --project <pipeline> meeting-notes process <folder> --json` and streams its JSON-lines events.
final class PipelineRunner {
    struct Event {
        let kind: String
        let stage: String?
        let status: String?
        let message: String?
        let fraction: Double?
        let overall: Double?
        let folder: String?
        let notes: String?
        let title: String?

        init?(line: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let kind = object["event"] as? String else { return nil }
            self.kind = kind
            stage = object["stage"] as? String
            status = object["status"] as? String
            message = object["message"] as? String
            fraction = (object["fraction"] as? NSNumber)?.doubleValue
            overall = (object["overall"] as? NSNumber)?.doubleValue
            folder = object["folder"] as? String
            notes = object["notes"] as? String
            title = object["title"] as? String
        }
    }

    struct Result {
        var exitCode: Int32 = -1
        var done: Event?
        var lastError: String?
    }

    let uvPath: String
    let pipelineDir: String
    private var process: Process?

    init(uvPath: String, pipelineDir: String) {
        self.uvPath = uvPath
        self.pipelineDir = pipelineDir
    }

    /// `onEvent` and `completion` are called on the main queue, in order.
    func run(folder: URL, onEvent: @escaping (Event) -> Void, completion: @escaping (Result) -> Void) throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: uvPath) else { throw AppError("uv not found at \(uvPath)") }
        guard fm.fileExists(atPath: pipelineDir) else { throw AppError("Pipeline folder not found: \(pipelineDir)") }

        let logURL = folder.appendingPathComponent("pipeline.app.log")
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        let log = try FileHandle(forWritingTo: logURL)
        log.seekToEndOfFile()
        log.write(Data("\n=== \(Date()) meeting-notes process ===\n".utf8))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["run", "--project", pipelineDir, "meeting-notes", "process", folder.path, "--json"]
        process.currentDirectoryURL = URL(fileURLWithPath: pipelineDir)
        var environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? log.close()
            throw error
        }
        self.process = process

        let reader = stdout.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            var result = Result()
            var pending = Data()

            func handle(_ line: Data) {
                guard !line.isEmpty else { return }
                guard let event = Event(line: line) else {
                    log.write(Data("[stdout] ".utf8) + line + Data("\n".utf8))
                    return
                }
                if event.kind == "done" { result.done = event }
                if event.kind == "error" { result.lastError = event.message ?? result.lastError }
                DispatchQueue.main.async { onEvent(event) }
            }

            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = Data(pending[pending.startIndex..<newline])
                    pending.removeSubrange(pending.startIndex...newline)
                    handle(line)
                }
            }
            handle(pending)
            process.waitUntilExit()
            try? log.close()
            result.exitCode = process.terminationStatus
            let final = result
            DispatchQueue.main.async { completion(final) }
        }
    }

    func terminate() {
        if let process, process.isRunning { process.terminate() }
    }
}
