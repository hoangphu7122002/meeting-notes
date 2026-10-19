import Foundation
import Testing
@testable import MeetingNotesCore

@Suite("Recorder state machine")
struct RecorderMachineTests {
    @Test func startOnlyWhenIdle() {
        for phase in [RecorderPhase.starting, .recording, .paused, .stopping] {
            let machine = RecorderMachine(phase: phase)
            #expect(!machine.isEnabled(.start), "start must be disabled while \(phase)")
        }
        #expect(RecorderMachine().isEnabled(.start))
    }

    @Test func secondStartIsIgnoredWithToast() {
        var machine = RecorderMachine()
        check(machine.handle(.start).effect == .startCapture)
        check(machine.handle(.start) == RecorderOutcome(.none, toast: "Already recording"))
        machine.apply(.started)
        #expect(machine.phase == .recording)
        check(machine.handle(.start) == RecorderOutcome(.none, toast: "Already recording"))
        _ = machine.handle(.pause)
        check(machine.handle(.start) == RecorderOutcome(.none, toast: "Already recording"))
        #expect(machine.phase == .paused)
    }

    @Test func toggleHotkeyStartsAndStops() {
        var machine = RecorderMachine()
        check(machine.handle(.toggleRecording).effect == .startCapture)
        // Pressed again while still starting: ignored, never a second recording.
        check(machine.handle(.toggleRecording).effect == .none)
        machine.apply(.started)
        let stop = machine.handle(.toggleRecording)
        #expect(stop.effect == .stopCapture)
        #expect(stop.toast == "Stopped – creating notes…")
        #expect(machine.phase == .stopping)
        machine.apply(.finished)
        #expect(machine.phase == .idle)
    }

    @Test func toggleStopsWhilePaused() {
        var machine = RecorderMachine(phase: .paused)
        check(machine.handle(.toggleRecording).effect == .stopCapture)
    }

    @Test func cannotStartWhileStopping() {
        var machine = RecorderMachine(phase: .stopping)
        check(machine.handle(.start).effect == .none)
        check(machine.handle(.toggleRecording).effect == .none)
        #expect(machine.phase == .stopping)
    }

    @Test func pauseHotkeyOnlyInRecordingOrPaused() {
        var idle = RecorderMachine()
        check(idle.handle(.togglePause) == RecorderOutcome(.none, toast: "Not recording"))
        var stopping = RecorderMachine(phase: .stopping)
        check(stopping.handle(.togglePause).effect == .none)

        var machine = RecorderMachine(phase: .recording)
        check(machine.handle(.togglePause) == RecorderOutcome(.pauseCapture, toast: "Paused"))
        #expect(machine.phase == .paused)
        #expect(machine.isEnabled(.resume) && !machine.isEnabled(.pause))
        check(machine.handle(.togglePause) == RecorderOutcome(.resumeCapture, toast: "Resumed"))
        #expect(machine.phase == .recording)
    }

    @Test func discardRequiresConfirmation() {
        var machine = RecorderMachine(phase: .recording)
        check(machine.handle(.confirmDiscard).effect == .none, "confirm without request does nothing")
        check(machine.handle(.requestDiscard).effect == .none)
        #expect(machine.confirmingDiscard)
        #expect(machine.phase == .recording)
        _ = machine.handle(.cancelDiscard)
        #expect(!machine.confirmingDiscard)
        check(machine.handle(.confirmDiscard).effect == .none)

        _ = machine.handle(.requestDiscard)
        check(machine.handle(.confirmDiscard).effect == .discardCapture)
        #expect(machine.phase == .stopping)
    }

    @Test func discardNotAvailableWhenIdle() {
        var machine = RecorderMachine()
        #expect(!machine.isEnabled(.discard))
        _ = machine.handle(.requestDiscard)
        #expect(!machine.confirmingDiscard)
    }

    @Test func startFailureReturnsToIdle() {
        var machine = RecorderMachine()
        _ = machine.handle(.start)
        machine.apply(.startFailed)
        #expect(machine.phase == .idle)
    }
}

@Suite("Pill state")
struct PillStateTests {
    let snapshot = ProcessingSnapshot(job: "j1", folder: "/tmp/m", title: "Standup")
    let ready = ReadyInfo(folder: "/tmp/m", title: "Standup", notesPath: "/tmp/m/notes.md")

    @Test func recordingWinsOverEverything() {
        let state = PillState.derive(phase: .recording, error: PillError("x"), processing: snapshot, ready: ready,
                                     permissionsNeedAttention: true)
        #expect(state == .recording)
        #expect(PillState.derive(phase: .paused, error: nil, processing: snapshot, ready: nil, permissionsNeedAttention: false) == .paused)
    }

    @Test func errorThenProcessingThenReadyThenIdle() {
        let error = PillError("Processing failed", action: .retry(folder: "/tmp/m"))
        #expect(PillState.derive(phase: .idle, error: error, processing: snapshot, ready: ready, permissionsNeedAttention: false) == .error(error))
        #expect(PillState.derive(phase: .idle, error: nil, processing: snapshot, ready: ready, permissionsNeedAttention: false) == .processing(snapshot))
        #expect(PillState.derive(phase: .idle, error: nil, processing: nil, ready: ready, permissionsNeedAttention: false) == .ready(ready))
        #expect(PillState.derive(phase: .idle, error: nil, processing: nil, ready: nil, permissionsNeedAttention: true) == .idle(attention: true))
    }

    @Test func labels() {
        var processing = snapshot
        processing.overall = 0.427
        #expect(PillState.processing(processing).label == "Processing 42%")
        #expect(PillState.ready(ready).label == "Done")
        #expect(PillState.idle(attention: false).label == "Ready")
        #expect(PillState.paused.name == "paused")
    }
}

@Suite("URL commands and hotkeys")
struct ParsingTests {
    @Test func urlCommands() {
        #expect(URLCommand(string: "meetingnotes://start") == .start)
        #expect(URLCommand(string: "meetingnotes://STOP") == .stop)
        #expect(URLCommand(string: "meetingnotes:pause") == .pause)
        #expect(URLCommand(string: "meetingnotes:///resume") == .resume)
        #expect(URLCommand(string: "meetingnotes://toggle/") == .toggle)
        #expect(URLCommand(string: "meetingnotes://show") == .show)
        #expect(URLCommand(string: "meetingnotes://explode") == nil)
        #expect(URLCommand(string: "https://start") == nil)
    }

    @Test func hotkeys() throws {
        let record = try #require(HotKeySpec.parse("ctrl+opt+cmd+r"))
        #expect(record.display == "⌃⌥⌘R")
        #expect(record.keyEquivalent == "r")
        #expect(record.control && record.option && record.command && !record.shift)
        #expect(HotKeySpec.parse("cmd+shift+f5")?.display == "⇧⌘F5")
        #expect(HotKeySpec.parse("shift+r") == nil, "needs ctrl, opt or cmd")
        #expect(HotKeySpec.parse("ctrl+hyper+r") == nil)
        #expect(HotKeySpec.parse("ctrl+opt+cmd+p")?.display == "⌃⌥⌘P")
    }
}

@Suite("Formatting")
struct FormattingTests {
    @Test func elapsed() {
        #expect(Format.elapsed(0) == "00:00")
        #expect(Format.elapsed(187.9) == "03:07")
        #expect(Format.elapsed(3723) == "1:02:03")
    }

    @Test func eta() {
        #expect(Format.eta(nil) == nil)
        #expect(Format.eta(20) == "less than a minute left")
        #expect(Format.eta(100) == "about 2 min left")
        #expect(Format.eta(60) == "about 1 min left")
        #expect(Format.eta(3900) == "about 1 h 5 min left")
    }
}

@Suite("Silence auto-stop")
struct SilenceTrackerTests {
    @Test func firesOnceAfterLimit() {
        var tracker = SilenceTracker(thresholdDB: -50, limit: 15 * 60)
        var fired: [Double] = []
        for second in stride(from: 0.0, through: 1000, by: 1) where tracker.update(now: second, levelDB: -70) {
            fired.append(second)
        }
        #expect(fired == [900])
    }

    @Test func soundResetsTheWindow() {
        var tracker = SilenceTracker(limit: 10)
        for second in 0..<9 { check(!tracker.update(now: Double(second), levelDB: -80)) }
        check(!tracker.update(now: 9, levelDB: -20))  // someone spoke
        for second in 10..<20 { check(!tracker.update(now: Double(second), levelDB: -80)) }
        check(tracker.update(now: 20, levelDB: -80))
        #expect(tracker.silentDuration(now: 20) == 10)
    }

    @Test func disabledWithZeroLimit() {
        var tracker = SilenceTracker(limit: 0)
        for second in 0..<100 { check(!tracker.update(now: Double(second), levelDB: -90)) }
    }

    @Test func resetRestartsCount() {
        var tracker = SilenceTracker(limit: 5)
        for second in 0..<5 { _ = tracker.update(now: Double(second), levelDB: -90) }
        check(tracker.update(now: 5, levelDB: -90))
        tracker.reset()
        check(!tracker.update(now: 6, levelDB: -90))
        check(tracker.update(now: 11, levelDB: -90))
    }

    @Test func createNotesModes() {
        #expect(CreateNotesMode.rightAway.canStart(onACPower: false, idleSeconds: 0))
        #expect(!CreateNotesMode.whenIdle.canStart(onACPower: true, idleSeconds: 60))
        #expect(!CreateNotesMode.whenIdle.canStart(onACPower: false, idleSeconds: 600))
        #expect(CreateNotesMode.whenIdle.canStart(onACPower: true, idleSeconds: 200))
        #expect(!CreateNotesMode.manual.canStart(onACPower: true, idleSeconds: 999))
        #expect(CreateNotesMode.rightAway.priority == "low")
        #expect(SummaryModel.light.model == "qwen3:4b")
    }
}
