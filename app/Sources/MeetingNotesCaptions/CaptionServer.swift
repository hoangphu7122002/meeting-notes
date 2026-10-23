// Serve mode of the caption helper: stdin audio commands -> per-track windows -> WhisperKit -> caption events.

import Foundation
import MeetingNotesCaptionKit

/// Commands read from stdin on a background thread; the decode loop drains them.
final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [CaptionCommand] = []
    private(set) var closed = false

    func start() {
        let thread = Thread { [self] in
            while let line = readLine(strippingNewline: true) {
                guard let command = CaptionCommand.parse(line) else { continue }
                lock.withLock { commands.append(command) }
                if command == .quit { break }
            }
            lock.withLock { closed = true }
        }
        thread.qualityOfService = .utility
        thread.start()
    }

    func drain() -> (commands: [CaptionCommand], closed: Bool) {
        lock.withLock {
            defer { commands = [] }
            return (commands, closed)
        }
    }
}

enum Output {
    private static let lock = NSLock()

    static func send(_ event: CaptionEvent) {
        let data = event.line()
        lock.withLock { FileHandle.standardOutput.write(data) }
    }
}

final class CaptionServer {
    let engine: CaptionEngine
    private var tracks: [String: CaptionTrack] = [:]
    private var priors: [String: String] = [:]
    private let inbox = Inbox()
    private var lastStatus = Date.distantPast
    private var behind = false

    init(engine: CaptionEngine) {
        self.engine = engine
    }

    func run() async {
        inbox.start()
        Output.send(.ready(model: engine.model, compute: engine.compute, loadSec: engine.loadSec))
        while true {
            let (commands, closed) = inbox.drain()
            for command in commands {
                switch command {
                case let .audio(track, start, samples):
                    var state = tracks[track] ?? CaptionTrack(name: track)
                    emit(state.append(start: start, samples: samples.map { Float($0) / 32768 }))
                    tracks[track] = state
                case let .reset(track):
                    for name in tracks.keys where track == nil || track == name {
                        emit(tracks[name]!.reset())
                    }
                case .quit:
                    return finish()
                }
            }
            if closed && commands.isEmpty { return finish() }
            for name in tracks.keys { emit(tracks[name]!.idle()) }
            reportStatus()
            // The track with the most undecoded voiced audio goes first (one decode at a time).
            guard let name = tracks.filter({ $0.value.needsDecode }).max(by: { $0.value.pendingSec < $1.value.pendingSec })?.key else {
                try? await Task.sleep(nanoseconds: 40_000_000)
                continue
            }
            await decode(name)
        }
    }

    private func decode(_ name: String) async {
        guard let track = tracks[name] else { return }
        let (audio, start) = track.beginDecode()
        do {
            let result = try await engine.decode(audio, language: track.language, prior: priors[name] ?? "vi")
            priors[name] = result.language
            emit(tracks[name]!.apply(result.pieces, start: start, count: audio.count, language: result.language))
        } catch {
            Output.send(.error("decode failed: \(error.localizedDescription)"))
            emit(tracks[name]!.reset())
        }
    }

    private func emit(_ segments: [CaptionSegment]) {
        for segment in segments { Output.send(.caption(segment)) }
    }

    private func reportStatus() {
        guard Date().timeIntervalSince(lastStatus) >= 2 else { return }
        lastStatus = Date()
        let lag = tracks.values.map(\.pendingSec).max() ?? 0
        let nowBehind = lag > 4
        guard nowBehind != behind || nowBehind else { return }
        behind = nowBehind
        Output.send(.status(state: nowBehind ? "behind" : "running", lagSec: lag))
    }

    private func finish() {
        for name in tracks.keys { emit(tracks[name]!.closeUtterance()) }
    }
}
