// One low-priority child process of the first-run setup, plus the probes it needs (Setup).

import Foundation
import MeetingNotesCore
import MeetingNotesUI

/// A setup command run at low priority (`nice 10`, utility QoS): stdout lines go to `onLine`, stderr to
/// ~/Library/Logs/MeetingNotes/setup.log (its last line is kept for the step's detail). `stop()` interrupts it;
/// the completion is then never called, so a stopped step never reports a result.
@MainActor
final class SetupProcess {
    private let process = Process()
    private var stopped = false
    private(set) var lastErrorLine: String?

    init(executable: URL, arguments: [String], environment: [String: String],
         onLine: @escaping @MainActor (Data) -> Void, completion: @escaping @MainActor (Int32) -> Void) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        process.arguments = ["-n", "10", executable.path] + arguments
        process.environment = environment
        process.qualityOfService = .utility
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let output = Pipe(), errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors

        let lines = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let parsed = lines.append(data)
            DispatchQueue.main.async { MainActor.assumeIsolated { parsed.forEach(onLine) } }
        }
        let log = Self.logSink()
        let errorLines = LineBuffer()
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            log.write(data)
            guard let last = errorLines.append(data).last, let text = String(data: last, encoding: .utf8) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.lastErrorLine = Self.clean(text) } }
        }
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.stopped else { return }
                    completion(status)
                }
            }
        }
        log.write(Data("\n== \(Date()) \(executable.lastPathComponent) \(arguments.joined(separator: " "))\n".utf8))
        try process.run()
    }

    /// Cancel: SIGINT, then SIGTERM after 3 s (by this process only). Downloads resume on the next run.
    func stop() {
        stopped = true
        guard process.isRunning else { return }
        process.interrupt()
        let process = self.process
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            if process.isRunning { process.terminate() }
        }
    }

    private static func logSink() -> LogSink {
        let sink = LogSink()
        sink.setFile(AppInfo.logsDir.appendingPathComponent("setup.log"), header: nil)
        return sink
    }

    /// One line for the UI: no ANSI codes, collapsed whitespace, short.
    static func clean(_ text: String) -> String {
        let noAnsi = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        return String(noAnsi.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(160))
    }
}

enum SetupProbe {
    static let ollamaVersionURL = URL(string: "http://127.0.0.1:11434/api/version")!
    static let ollamaDownloadURL = URL(string: "https://ollama.com/download/mac")!
    static let brewCommand = "brew install ollama && brew services start ollama"

    /// Ollama answering on loopback, installed as an app, or as a CLI (Homebrew).
    static func ollama() async -> OllamaAvailability {
        var request = URLRequest(url: ollamaVersionURL)
        request.timeoutInterval = 2
        let reachable = (try? await URLSession.shared.data(for: request)).map { ($0.1 as? HTTPURLResponse)?.statusCode == 200 } ?? false
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let hasApp = ollamaApp != nil
        let hasCLI = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "\(home)/.local/bin/ollama"]
            .contains { fm.isExecutableFile(atPath: $0) }
        return OllamaAvailability.classify(reachable: reachable, hasApp: hasApp, hasCLI: hasCLI)
    }

    static var ollamaApp: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications/Ollama.app", "\(home)/Applications/Ollama.app"]
            .first { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Total size of the files under `dirs` (progress of a download into them). Runs off the main thread.
    nonisolated static func size(of dirs: [URL]) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for dir in dirs {
            guard let items = fm.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { continue }
            for case let url as URL in items {
                let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
            }
        }
        return total
    }
}
