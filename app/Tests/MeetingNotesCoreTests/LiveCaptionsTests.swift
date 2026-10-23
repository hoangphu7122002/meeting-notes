import Foundation
import MeetingNotesCaptionKit
import Testing
@testable import MeetingNotesCore

@Suite("Live captions (design B) merged with design A")
struct LiveCaptionsTests {
    func caption(_ track: String, _ seq: Int, _ start: Double, _ end: Double, _ text: String, final: Bool) -> CaptionEvent {
        .caption(CaptionSegment(track: track, seq: seq, start: start, end: end, text: text, isFinal: final, language: "vi"))
    }

    func aSegment(_ track: String, _ seq: Int, _ start: Double, _ end: Double, _ text: String) -> WorkerEvent {
        .liveSegment(job: "live-1", LiveSegment(track: track, speaker: track == "mic" ? "Me" : "Others", seq: seq,
                                                start: start, end: end, language: "vi", text: text))
    }

    @Test func hypothesisIsReplacedThenConfirmed() {
        var captions = LiveCaptions()
        check(captions.apply(caption("mic", 0, 1, 2, "xin", final: false)))
        check(captions.apply(caption("mic", 0, 1, 3, "xin chào", final: false)))
        #expect(captions.drafts(covering: nil).map(\.text) == ["xin chào"])
        check(captions.apply(caption("mic", 0, 1, 3, "xin chào mọi người", final: true)))
        #expect(captions.hypotheses.isEmpty)
        #expect(captions.drafts(covering: nil).map(\.text) == ["xin chào mọi người"])
        #expect(captions.phase == .running)
        // An empty hypothesis clears the track's draft.
        check(captions.apply(caption("system", 0, 4, 5, "hello", final: false)))
        check(captions.apply(caption("system", 0, 5, 5, "", final: false)))
        #expect(captions.drafts(covering: nil).map(\.text) == ["xin chào mọi người"])
    }

    @Test func designATextReplacesCoveredCaptions() {
        var captions = LiveCaptions(phase: .running)
        captions.apply(caption("mic", 0, 1, 4, "bản nháp một", final: true))
        captions.apply(caption("mic", 1, 4.5, 7, "bản nháp hai", final: true))
        captions.apply(caption("system", 0, 2, 5, "remote draft", final: true))
        captions.apply(caption("mic", 2, 8, 9, "đang nói", final: false))
        var transcript = LiveTranscript(job: "live-1")
        #expect(captions.drafts(covering: transcript).count == 4)
        // A's chunk for mic 0.8-4.2 lands: the first mic caption goes, the rest stay as drafts.
        transcript.apply(aSegment("mic", 0, 0.8, 4.2, "Bản chính xác một."))
        #expect(captions.drafts(covering: transcript).map(\.text) == ["remote draft", "bản nháp hai", "đang nói"])
        // A moved past 7 s on the mic track: everything before its frontier is covered, other tracks are not.
        transcript.apply(aSegment("mic", 1, 4.4, 7.1, "Bản chính xác hai."))
        #expect(captions.drafts(covering: transcript).map(\.text) == ["remote draft", "đang nói"])
    }

    @Test func displayAppendsDraftsAfterDesignA() {
        var transcript = LiveTranscript(job: "live-1")
        transcript.apply(aSegment("system", 0, 0, 3, "Câu chính xác."))
        var captions = LiveCaptions(phase: .running)
        captions.apply(caption("system", 0, 0.5, 2.5, "câu nháp cũ", final: true))
        captions.apply(caption("mic", 0, 4, 6, "câu mới", final: true))
        captions.apply(caption("mic", 1, 6.2, 7, "đang", final: false))
        let lines = LiveDisplay.lines(transcript: transcript, captions: captions, count: 3, polished: true)
        #expect(lines.map(\.text) == ["Câu chính xác.", "câu mới", "đang"])
        #expect(lines.map(\.isDraft) == [false, true, true])
        #expect(LiveDisplay.lines(transcript: nil, captions: captions, count: 1, polished: false).map(\.text) == ["đang"])
        #expect(LiveDisplay.lines(transcript: transcript, captions: nil, count: 3, polished: false).map(\.isDraft) == [false])
    }

    @Test func applyLineAndClear() {
        var captions = LiveCaptions()
        check(captions.apply(line: #"{"event":"ready","model":"m","compute":"ane","load_sec":1}"#))
        #expect(captions.phase == .running)
        check(captions.apply(line: #"{"event":"caption","track":"mic","seq":0,"start":1,"end":2,"text":"a","final":true}"#))
        check(!captions.apply(line: "garbage"))
        captions.clear()
        #expect(captions.isEmpty)
    }

    @Test func oldFinalsArePruned() {
        var captions = LiveCaptions(phase: .running)
        captions.apply(caption("mic", 0, 1, 2, "old", final: true))
        captions.apply(caption("mic", 1, 400, 401, "new", final: true))
        #expect(captions.finals.count == 1)
    }
}

@Suite("Live mode setting and caption helper rules")
struct LiveModeTests {
    @Test func modeMapsToTheTwoKeys() {
        #expect(LiveMode(live: false, captions: true) == .off)
        #expect(LiveMode(live: true, captions: true) == .fast)
        #expect(LiveMode(live: true, captions: false) == .accurate)
        #expect(LiveMode.fast.live && LiveMode.fast.captions)
        #expect(LiveMode.accurate.live && !LiveMode.accurate.captions)
        #expect(!LiveMode.off.live)
        // Off keeps the previous caption choice for the next time live is turned on.
        #expect(LiveMode.off.captionsKey(previous: false) == false)
        #expect(LiveMode.off.captionsKey(previous: true) == true)
        #expect(LiveMode.accurate.captionsKey(previous: true) == false)
    }

    @Test func helpLineFollowsModeAndModelState() {
        #expect(SettingsRules.liveModeHelp(.off, model: .ready, lang: .en) == tr(.helpLiveOff, lang: .en))
        #expect(SettingsRules.liveModeHelp(.accurate, model: .missing, lang: .en) == tr(.helpLiveAccurate, lang: .en))
        #expect(SettingsRules.liveModeHelp(.fast, model: .ready, lang: .en).contains("\(CaptionModels.downloadMB(CaptionModels.defaultModel)) MB"))
        #expect(SettingsRules.liveModeHelp(.fast, model: .preparing(0.425), lang: .en) == "Downloading the caption model… 50%")
        #expect(SettingsRules.liveModeHelp(.fast, model: .preparing(0.9), lang: .en) == tr(.captionsPreparing, lang: .en))
        #expect(SettingsRules.liveModeWarning(.fast, model: .failed("x")))
        #expect(!SettingsRules.liveModeWarning(.accurate, model: .failed("x")))
    }

    @Test func pauseRulesMirrorDesignA() {
        let running = LiveStatus(state: "running")
        #expect(CaptionHelper.pauseReason(memoryCritical: true, onBattery: false, liveStatus: running) == "memory")
        #expect(CaptionHelper.pauseReason(memoryCritical: false, onBattery: false, liveStatus: nil) == nil)
        #expect(CaptionHelper.pauseReason(memoryCritical: false, onBattery: false,
                                          liveStatus: LiveStatus(state: "deferred", reason: "memory")) == "memory")
        #expect(CaptionHelper.pauseReason(memoryCritical: false, onBattery: false,
                                          liveStatus: LiveStatus(state: "deferred", reason: "cpu")) == nil)
        #expect(CaptionHelper.pauseReason(memoryCritical: false, onBattery: true, liveStatus: nil) == "battery")
        // On battery only when design A runs there too (the user set live_on_battery).
        #expect(CaptionHelper.pauseReason(memoryCritical: false, onBattery: true, liveStatus: running) == nil)
    }

    @Test func helperLookupAndEnvironment() {
        let exe = URL(fileURLWithPath: "/Applications/MeetingNotes.app/Contents/MacOS/MeetingNotes")
        let bundled = "/Applications/MeetingNotes.app/Contents/MacOS/MeetingNotesCaptions"
        #expect(CaptionHelper.path(executableURL: exe, pipelineDir: "/r/pipeline", isExecutable: { $0 == bundled }) == bundled)
        #expect(CaptionHelper.path(executableURL: exe, pipelineDir: "/r/pipeline",
                                   isExecutable: { $0 == "/r/app/.build/release/MeetingNotesCaptions" })
                == "/r/app/.build/release/MeetingNotesCaptions")
        #expect(CaptionHelper.path(executableURL: nil, pipelineDir: nil, isExecutable: { _ in true }) == nil)
        let env = CaptionHelper.environment(["HF_TOKEN": "secret", "HUGGING_FACE_HUB_TOKEN": "s", "PATH": "/bin"])
        #expect(env == ["PATH": "/bin"])
        #expect(CaptionHelper.prepareArguments(models: URL(fileURLWithPath: "/m"), model: "x")
                == ["--prepare", "--models", "/m", "--model", "x", "--compute", "ane"])
    }

    @Test func modelDirectoryPrefersAReadySharedStore() {
        let shared = URL(fileURLWithPath: "/Users/Shared/MeetingNotes/models")
        let user = URL(fileURLWithPath: "/Users/me/Library/Application Support/MeetingNotes/models")
        let model = CaptionModels.defaultModel
        let sharedReady = CaptionModels.readyMarker(model, in: shared.appendingPathComponent("whisperkit")).path
        // Prefetched by the shared install's owner: used read-only by every account.
        #expect(CaptionModels.directory(pipelineModels: shared, userModels: user, model: model,
                                        fileExists: { $0 == sharedReady }, isWritable: { _ in false }).path
                == "/Users/Shared/MeetingNotes/models/whisperkit")
        // Not ready and not writable (another account's store): download into this account's folder.
        #expect(CaptionModels.directory(pipelineModels: shared, userModels: user, model: model,
                                        fileExists: { _ in false }, isWritable: { _ in false }).path
                == user.appendingPathComponent("whisperkit").path)
        // Dev / owner: the install's models dir is writable.
        #expect(CaptionModels.directory(pipelineModels: shared, userModels: user, model: model,
                                        fileExists: { _ in false }, isWritable: { _ in true }).lastPathComponent == "whisperkit")
        #expect(CaptionHelper.pipelineModels(pipelineDir: "/r/pipeline")?.path == "/r/models")
    }
}
