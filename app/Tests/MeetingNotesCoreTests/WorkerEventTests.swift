import Foundation
import Testing
@testable import MeetingNotesCore

@Suite("Worker events")
struct WorkerEventTests {
    let lines = [
        #"{"event": "worker", "status": "ready", "pid": 4242}"#,
        #"{"event": "stage", "stage": "prepare", "status": "start", "message": "", "overall": 0.0, "eta_sec": 120.5, "job": "j1"}"#,
        #"{"event": "stage", "stage": "prepare", "status": "done", "message": "", "overall": 0.03, "elapsed_sec": 1.2, "eta_sec": 118.0, "job": "j1"}"#,
        #"{"event": "stage", "stage": "diarize", "status": "skipped", "message": "exists", "overall": 0.28, "elapsed_sec": null, "eta_sec": 90.0, "job": "j1"}"#,
        #"{"event": "stage", "stage": "transcribe", "status": "start", "message": "", "overall": 0.28, "eta_sec": 90.0, "job": "j1"}"#,
        #"{"event": "progress", "stage": "transcribe", "fraction": 0.5, "message": "block 3/6", "overall": 0.49, "eta_sec": 61.0, "job": "j1"}"#,
        #"{"event": "partial", "folder": "/n/2026 Meeting", "notes": "/n/2026 Meeting/notes.md", "elapsed_sec": 30.1, "job": "j1"}"#,
        #"{"event": "warning", "stage": "summarize", "message": "Summary failed: timeout", "job": "j1"}"#,
        #"{"event": "done", "folder": "/n/2026 Budget review", "notes": "/n/2026 Budget review/notes.md", "title": "Budget review", "overall": 1.0, "timings": {"prepare": 1.2}, "total_sec": 80.2, "job": "j1"}"#,
        #"{"event": "job_end", "job": "j1", "exit": 0}"#,
    ]

    @Test func decodesSampleLines() throws {
        let events = lines.compactMap(WorkerEvent.init(line:))
        #expect(events.count == lines.count)
        #expect(events[0] == .worker(status: "ready", message: nil))
        #expect(events[2] == .stage(job: "j1", stage: "prepare", status: "done", elapsedSec: 1.2, etaSec: 118, overall: 0.03, message: nil))
        #expect(events[5] == .progress(job: "j1", stage: "transcribe", fraction: 0.5, overall: 0.49, etaSec: 61, message: "block 3/6"))
        #expect(events[6] == .partial(job: "j1", folder: "/n/2026 Meeting", notes: "/n/2026 Meeting/notes.md"))
        #expect(events[8] == .done(job: "j1", folder: "/n/2026 Budget review", notes: "/n/2026 Budget review/notes.md",
                                   title: "Budget review", totalSec: 80.2))
        #expect(events[9] == .jobEnd(job: "j1", exit: 0))
        #expect(WorkerEvent(line: #"{"event": "cancelled", "stage": "diarize", "folder": "/n/x", "message": "Processing cancelled", "job": "j2"}"#)
            == .cancelled(job: "j2", folder: "/n/x"))
        #expect(WorkerEvent(line: #"{"event": "worker", "status": "exit", "idle_min": 1.0}"#) == .worker(status: "exit", message: nil))
        #expect(WorkerEvent(line: "not json") == nil)
        #expect(WorkerEvent(line: #"{"no_event": 1}"#) == nil)
    }

    @Test func foldsIntoSnapshot() {
        var snapshot = ProcessingSnapshot(job: "j1", folder: "/n/2026 Meeting", title: "Meeting")
        for line in lines { if let event = WorkerEvent(line: line) { snapshot.apply(event) } }
        #expect(snapshot.overall == 1)
        #expect(snapshot.folder == "/n/2026 Budget review")
        #expect(snapshot.title == "Budget review")
        #expect(snapshot.partialNotes == "/n/2026 Meeting/notes.md")
        #expect(snapshot.warnings == ["Summary failed: timeout"])
        #expect(snapshot.stages.first { $0.name == "prepare" }?.elapsedSec == 1.2)
        #expect(snapshot.stages.first { $0.name == "diarize" }?.status == .skipped)
        #expect(snapshot.displayStages.map(\.name) == ["prepare", "diarize", "transcribe", "summarize"])
    }

    @Test func progressAndEta() {
        var snapshot = ProcessingSnapshot(job: "j1", folder: "/f", title: "t")
        for line in lines.prefix(6) { if let event = WorkerEvent(line: line) { snapshot.apply(event) } }
        #expect(snapshot.currentStage == "transcribe")
        #expect(snapshot.percent == 49)
        #expect(snapshot.etaSec == 61)
        #expect(Format.eta(snapshot.etaSec, .en) == "about 1 min left")
        #expect(snapshot.stages.first { $0.name == "transcribe" }?.status == .running)
        #expect(snapshot.stages.first { $0.name == "transcribe" }?.fraction == 0.5)
        #expect(snapshot.partialNotes == nil)
    }

    @Test func ignoresOtherJobs() {
        var snapshot = ProcessingSnapshot(job: "j1", folder: "/f", title: "t")
        let other = WorkerEvent.progress(job: "j9", stage: "transcribe", fraction: 0.9, overall: 0.9, etaSec: 1, message: nil)
        check(!snapshot.apply(other))
        #expect(snapshot.overall == 0)
    }

    @Test func outcomes() {
        let done = WorkerEvent(line: lines[8])
        #expect(JobOutcome.from(exit: 0, done: done, lastError: nil)
            == .done(folder: "/n/2026 Budget review", notes: "/n/2026 Budget review/notes.md", title: "Budget review"))
        #expect(JobOutcome.from(exit: 3, done: nil, lastError: nil) == .cancelled)
        #expect(JobOutcome.from(exit: 1, done: nil, lastError: "Ollama is not reachable") == .failed(message: "Ollama is not reachable"))
        if case .failed = JobOutcome.from(exit: 2, done: nil, lastError: nil) {} else { Issue.record("exit 2 must fail") }
    }

    @Test func commands() throws {
        let line = WorkerEvent.Command.process(job: "j1", folder: "/n/a b", from: "render")
        #expect(line.hasSuffix("\n"))
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])
        #expect(object == ["cmd": "process", "job": "j1", "folder": "/n/a b", "from": "render"])
        #expect(WorkerEvent.Command.cancel == "{\"cmd\":\"cancel\"}\n")
    }
}

@Suite("Notes document")
struct NotesDocumentTests {
    @Test func groupsParagraphsAndPauses() throws {
        let json = """
        {"title": "Sync", "duration_sec": 100, "speakers": ["Me", "Speaker 2"],
         "pauses": [{"at_sec": 20, "duration_sec": 60, "started_at": "x"}],
         "segments": [
          {"start": 0, "end": 5, "speaker": "Me", "track": "mic", "language": "en", "text": "Hello"},
          {"start": 5, "end": 9, "speaker": "Me", "track": "mic", "language": "en", "text": "there."},
          {"start": 10, "end": 15, "speaker": "Speaker 2", "track": "system", "language": "en", "text": "Hi"},
          {"start": 25, "end": 30, "speaker": "Speaker 2", "track": "system", "language": "en", "text": "Back again"}
         ]}
        """
        let transcript = try JSONDecoder().decode(Transcript.self, from: Data(json.utf8))
        let blocks = transcript.blocks()
        #expect(blocks.count == 4)
        #expect(blocks[0] == .paragraph(id: 0, speaker: "Me", start: 0, text: "Hello there."))
        #expect(blocks[2] == .pause(id: 2, at: 20, duration: 60))
        #expect(transcript.blocks(filter: "again").count == 1)
    }

    @Test func summaryPlainText() throws {
        let json = #"{"title": "Plan", "summary": ["A"], "decisions": [], "action_items": [{"task": "Ship", "owner": "Me", "due": "Friday"}], "open_questions": ["Why?"]}"#
        let summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))
        #expect(summary.plainText(.en).contains("- [ ] Ship (Me, due Friday)"))
        #expect(summary.plainText(.en).contains("Open questions\n- Why?"))
    }
}
