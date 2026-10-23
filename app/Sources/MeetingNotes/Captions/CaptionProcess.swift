// The MeetingNotesCaptions helper process: serve (audio in, caption events out) or --prepare (progress) (Captions).

import Foundation
import MeetingNotesCaptionKit
import MeetingNotesCore
import MeetingNotesUI

/// One helper process. Audio lines are written on a private serial queue (two capture taps never interleave) and
/// dropped when the helper falls behind; events and termination are delivered on the main queue.
final class CaptionProcess: @unchecked Sendable {
    /// Audio lines waiting to be written beyond this are dropped (display-only captions).
    static let maxQueued = 64

    let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let writer = DispatchQueue(label: "meetingnotes.captions.writer", qos: .utility)
    private let lock = NSLock()
    private var queued = 0
    private var closed = false

    /// `onLine` gets each stdout line (serve: events; prepare: the final JSON), `onError` each stderr line.
    init(helper: String, arguments: [String], log: URL,
         onLine: @escaping @MainActor (String) -> Void, onError: @escaping @MainActor (String) -> Void,
         onExit: @escaping @MainActor (Int32) -> Void) throws {
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = arguments
        process.environment = CaptionHelper.environment(ProcessInfo.processInfo.environment)
        process.qualityOfService = .utility
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let outLines = LineBuffer(), errLines = LineBuffer()
        let logHandle = Self.openLog(log)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let lines = outLines.append(data).compactMap { String(data: $0, encoding: .utf8) }
            DispatchQueue.main.async { MainActor.assumeIsolated { lines.forEach(onLine) } }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            try? logHandle?.write(contentsOf: data)
            let lines = errLines.append(data).compactMap { String(data: $0, encoding: .utf8) }
            DispatchQueue.main.async { MainActor.assumeIsolated { lines.forEach(onError) } }
        }
        process.terminationHandler = { process in
            let status = process.terminationStatus
            try? logHandle?.close()
            DispatchQueue.main.async { MainActor.assumeIsolated { onExit(status) } }
        }
        try? logHandle?.write(contentsOf: Data("\n=== \(Date()) \(CaptionModels.helperName) \(arguments.joined(separator: " ")) ===\n".utf8))
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    /// Thread-safe; drops the line when the helper is behind or gone.
    func send(_ command: CaptionCommand) {
        let accept = lock.withLock { () -> Bool in
            guard !closed, queued < Self.maxQueued else { return false }
            queued += 1
            return true
        }
        guard accept else { return }
        let handle = input.fileHandleForWriting
        writer.async {
            try? handle.write(contentsOf: command.line())  // SIGPIPE is ignored by the app
            self.lock.withLock { self.queued -= 1 }
        }
    }

    /// Asks the helper to quit (closes stdin), terminating it if it is still running after `grace` seconds.
    func stop(grace: Double = 2) {
        let already = lock.withLock { () -> Bool in
            defer { closed = true }
            return closed
        }
        guard !already else { return }
        let handle = input.fileHandleForWriting, process = self.process
        writer.async {
            try? handle.write(contentsOf: CaptionCommand.quit.line())
            try? handle.close()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            if process.isRunning { process.terminate() }
        }
    }

    private static func openLog(_ url: URL) -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }
}
