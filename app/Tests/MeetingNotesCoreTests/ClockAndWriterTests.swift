import AVFoundation
import Foundation
import Testing
@testable import MeetingNotesCore

@Suite("RecordingClock")
struct RecordingClockTests {
    @Test func noPauses() {
        let clock = RecordingClock(startHost: 100)
        #expect(clock.recordedTime(atHost: 105) == 5)
        #expect(clock.recordedDuration(atHost: 112) == 12)
        #expect(clock.segment(atHost: 105)?.limit == nil)
    }

    @Test func multiplePauses() {
        let clock = RecordingClock(startHost: 0)
        #expect(clock.pause(atHost: 10))
        #expect(!clock.pause(atHost: 11), "already paused")
        #expect(clock.recordedTime(atHost: 12) == nil)
        #expect(clock.recordedDuration(atHost: 14) == 10)
        #expect(clock.resume(atHost: 15))
        #expect(clock.recordedTime(atHost: 20) == 15)
        #expect(clock.pause(atHost: 30))  // recorded 25
        #expect(clock.resume(atHost: 40))
        #expect(clock.recordedTime(atHost: 50) == 35)
        #expect(clock.recordedDuration(atHost: 50) == 35)
        #expect(clock.pausedDuration(atHost: 50) == 15)

        let pauses = clock.pauseList
        #expect(pauses.count == 2)
        #expect(pauses[0].atRecorded == 10 && pauses[0].wallDuration(nowHost: 50) == 5)
        #expect(pauses[1].atRecorded == 25 && pauses[1].wallDuration(nowHost: 50) == 10)

        // Timestamps before a pause know where their segment ends.
        #expect(clock.segment(atHost: 8) == RecordingClock.Segment(time: 8, limit: 10))
        #expect(clock.segment(atHost: 29) == RecordingClock.Segment(time: 24, limit: 25))
        // Inside a finished pause: dropped.
        #expect(clock.recordedTime(atHost: 35) == nil)
    }

    @Test func stopWhilePaused() {
        let clock = RecordingClock(startHost: 0)
        clock.pause(atHost: 10)
        clock.stop(atHost: 20)
        #expect(clock.recordedDuration(atHost: 30) == 10)
        #expect(clock.recordedTime(atHost: 25) == nil)
        #expect(!clock.resume(atHost: 21))
        #expect(clock.pauseList.first?.wallDuration(nowHost: 999) == 10, "an open pause ends at stop")
        #expect(clock.pausedDuration(atHost: 999) == 10)
    }

    @Test func stopEndsSegment() {
        let clock = RecordingClock(startHost: 0)
        clock.stop(atHost: 30)
        #expect(clock.segment(atHost: 29.9)?.limit == 30)
        #expect(clock.recordedTime(atHost: 30) == nil)
        #expect(clock.recordedDuration(atHost: 99) == 30)
    }
}

@Suite("TrackWriter alignment")
struct TrackWriterTests {
    /// Feeds `seconds` of a constant signal in buffers of `chunk` frames, starting at host time `from`.
    static func feed(_ writer: TrackWriter, rate: Double, from: Double, seconds: Double, chunk: Int, value: Float = 0.25) {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        var host = from
        let total = Int(seconds * rate)
        var written = 0
        while written < total {
            let frames = min(chunk, total - written)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            buffer.floatChannelData![0].update(repeating: value, count: frames)
            writer.append(buffer, hostSeconds: host)
            host += Double(frames) / rate
            written += frames
        }
    }

    static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.fileFormat.sampleRate
    }

    @Test func twoTracksStayAlignedAcrossPause() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let start = 1000.0
        let clock = RecordingClock(startHost: start)
        let mic = TrackWriter(url: dir.appendingPathComponent("mic.wav"), label: "mic", clock: clock)
        let system = TrackWriter(url: dir.appendingPathComponent("system.wav"), label: "system", clock: clock)

        // Mic starts immediately at 48 kHz; system audio 0.3 s later at 44.1 kHz with other buffer sizes.
        // Each source delivers one buffer straddling the pause and keeps delivering for a moment after it.
        Self.feed(mic, rate: 48_000, from: start, seconds: 10.05, chunk: 4096)
        Self.feed(system, rate: 44_100, from: start + 0.3, seconds: 9.8, chunk: 1024)
        clock.pause(atHost: start + 10)
        // Buffers captured during the pause are dropped.
        Self.feed(mic, rate: 48_000, from: start + 10.2, seconds: 2, chunk: 4096)
        clock.resume(atHost: start + 40)  // 30 s paused
        // After resume both sources restart with different latencies (gaps get silence).
        Self.feed(mic, rate: 48_000, from: start + 40.25, seconds: 5, chunk: 4096)
        Self.feed(system, rate: 44_100, from: start + 40.6, seconds: 4.5, chunk: 1024)
        let stopHost = start + 45.3
        clock.stop(atHost: stopHost)
        let end = clock.recordedDuration(atHost: stopHost)
        #expect(abs(end - 15.3) < 1e-9)

        let micStats = mic.finish(endTime: end)
        let systemStats = system.finish(endTime: end)
        #expect(micStats.error == nil && systemStats.error == nil)
        #expect(micStats.droppedBuffers > 0, "buffers inside the pause are dropped")

        let micOffset = try #require(micStats.startOffset)
        let systemOffset = try #require(systemStats.startOffset)
        #expect(abs(micOffset - 0) < 0.001)
        #expect(abs(systemOffset - 0.3) < 0.001)

        // Both tracks end at the same recorded time; the 30 s pause is not in the files.
        let micEnd = micOffset + (try Self.duration(of: mic.url))
        let systemEnd = systemOffset + (try Self.duration(of: system.url))
        #expect(abs(micEnd - systemEnd) < 0.02, "mic ends at \(micEnd), system at \(systemEnd)")
        #expect(abs(micEnd - 15.3) < 0.02)
        #expect(micStats.peak > 0.2)
    }

    @Test func dropsEverythingWhilePaused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = RecordingClock(startHost: 0)
        clock.pause(atHost: 0)
        let writer = TrackWriter(url: dir.appendingPathComponent("a.wav"), label: "a", clock: clock)
        Self.feed(writer, rate: 16_000, from: 0.1, seconds: 1, chunk: 1600)
        let stats = writer.finish(endTime: nil)
        #expect(stats.frames == 0)
        #expect(stats.droppedBuffers == 10)
    }

    @Test func levelMeter() {
        let meter = LevelMeter()
        meter.update(rms: 0.1, now: 10)
        #expect(meter.level(now: 10.1) == 0.1)
        #expect(meter.level(now: 20) == 0, "stale level reads as silence")
        #expect(abs(meter.takeWindowMaxDB() - -20) < 0.01)
        #expect(meter.takeWindowMaxDB() == LevelMeter.floorDB)
    }
}

@Suite("meeting.json")
struct MeetingRecordTests {
    @Test func encodesPausesAndDurations() throws {
        var record = MeetingRecord(title: "Zoom meeting", titleSource: "app", appHint: "Zoom",
                                   startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        record.endedAt = Date(timeIntervalSince1970: 1_700_000_100)
        record.durationSec = 70
        record.wallDurationSec = 100
        record.tracks["mic"] = .init(file: "mic.wav", startOffsetSec: 0.0123, sampleRate: 48_000, device: "MacBook Mic")
        record.pauses = [.init(atSec: 10, durationSec: 30, startedAt: Date(timeIntervalSince1970: 1_700_000_010))]
        let object = try #require(JSONSerialization.jsonObject(with: record.jsonData()) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        #expect(object["title_source"] as? String == "app")
        #expect((object["duration_sec"] as? NSNumber)?.doubleValue == 70)
        #expect((object["wall_duration_sec"] as? NSNumber)?.doubleValue == 100)
        let pauses = try #require(object["pauses"] as? [[String: Any]])
        #expect((pauses[0]["at_sec"] as? NSNumber)?.doubleValue == 10)
        #expect((pauses[0]["duration_sec"] as? NSNumber)?.doubleValue == 30)
        #expect(pauses[0]["started_at"] is String)
        let mic = try #require((object["tracks"] as? [String: Any])?["mic"] as? [String: Any])
        #expect((mic["start_offset_sec"] as? NSNumber)?.doubleValue == 0.012)
        #expect(object["ended_at"] is String)
        #expect(object["warnings"] is [Any])
    }

    @Test func titleUpdateKeepsOtherFields() throws {
        let original = #"{"version":1,"title":"Meeting","title_source":"default","tracks":{"mic":{"file":"mic.m4a"}},"custom":5}"#
        let updated = try MeetingRecord.updatingTitle(Data(original.utf8), title: "Budget review")
        let object = try #require(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        #expect(object["title"] as? String == "Budget review")
        #expect(object["title_source"] as? String == "user")
        #expect(object["custom"] as? Int == 5)
        #expect(((object["tracks"] as? [String: Any])?["mic"] as? [String: Any])?["file"] as? String == "mic.m4a")
    }

    @Test func stateFile() throws {
        let snapshot = AppStatusSnapshot(state: "processing", processing: .init(folder: "/x", stage: "transcribe", overall: 0.42, etaSec: 95),
                                         queue: 1)
        let object = try #require(JSONSerialization.jsonObject(with: snapshot.jsonData()) as? [String: Any])
        #expect(object["state"] as? String == "processing")
        #expect(object["title"] is NSNull)
        #expect((object["processing"] as? [String: Any])?["stage"] as? String == "transcribe")
        #expect(object["queue"] as? Int == 1)
        let idle = try #require(JSONSerialization.jsonObject(with: AppStatusSnapshot(state: "idle").jsonData()) as? [String: Any])
        #expect(idle["processing"] is NSNull)
    }
}
