// Thread-safe helpers of WorkerClient: stdout line splitting and the stderr log sink (Pipeline).

import Foundation
import MeetingNotesCore
import MeetingNotesUI

/// Splits a byte stream into lines (thread-safe).
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func append(_ data: Data) -> [Data] {
        lock.withLock {
            pending.append(data)
            var lines: [Data] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[pending.startIndex..<newline])
                pending.removeSubrange(pending.startIndex...newline)
                if !line.isEmpty { lines.append(line) }
            }
            return lines
        }
    }
}

/// stderr destination: the current job's pipeline.app.log, otherwise the shared worker log (thread-safe).
final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?

    func setFile(_ url: URL?, header: String?) {
        lock.withLock {
            try? handle?.close()
            handle = Self.open(url ?? AppInfo.logsDir.appendingPathComponent("worker.log"))
            if let header { try? handle?.write(contentsOf: Data(header.utf8)) }
        }
    }

    func write(_ data: Data) {
        lock.withLock {
            if handle == nil { handle = Self.open(AppInfo.logsDir.appendingPathComponent("worker.log")) }
            try? handle?.write(contentsOf: data)
        }
    }

    private static func open(_ url: URL) -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }
}
