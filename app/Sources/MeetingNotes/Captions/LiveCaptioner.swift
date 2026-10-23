// Fast live captions (design B): model download on first use, helper lifecycle, pause rules (Captions).

import Foundation
import MeetingNotesCaptionKit
import MeetingNotesCore
import MeetingNotesUI

/// Runs the `MeetingNotesCaptions` helper while a recording is in progress and the live mode is "fast captions".
/// Display-only: captions go to `AppState.liveCaptions`, nothing is written. Design A (`LiveTranscriber`) runs as
/// before and replaces captions with its text. A missing model is downloaded first (progress in Settings and pill).
@MainActor
final class LiveCaptioner {
    var onChange: ((LiveCaptions?) -> Void)?
    var onModelState: ((CaptionModelState) -> Void)?

    static let maxRestarts = 3
    let model = CaptionModels.defaultModel

    private(set) var captions: LiveCaptions? {
        didSet { if captions != oldValue { onChange?(captions) } }
    }
    private(set) var modelState: CaptionModelState = .unknown {
        didSet { if modelState != oldValue { onModelState?(modelState) } }
    }
    private var wanted = false
    private var taps: [CaptionTap] = []
    private var helper: CaptionProcess?
    private var preparer: CaptionProcess?
    private var restarts = 0
    private var pauseReason: String?

    var isActive: Bool { wanted }

    private var fileExists: (String) -> Bool { { FileManager.default.fileExists(atPath: $0) } }

    var modelsDir: URL {
        CaptionModels.directory(pipelineModels: CaptionHelper.pipelineModels(pipelineDir: Settings.pipelineDir),
                                userModels: AppInfo.supportDir.appendingPathComponent("models", isDirectory: true),
                                model: model, fileExists: fileExists,
                                isWritable: { FileManager.default.isWritableFile(atPath: $0) })
    }

    var helperPath: String? {
        CaptionHelper.path(executableURL: Bundle.main.executableURL, pipelineDir: Settings.pipelineDir) {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    func refreshModelState() {
        guard preparer == nil else { return }
        modelState = CaptionModels.isReady(model, in: modelsDir, fileExists: fileExists) ? .ready : .missing
    }

    /// Downloads and prepares the model (first enable); no-op when ready or already running.
    func prepareModel() {
        refreshModelState()
        guard modelState != .ready, preparer == nil else { return }
        guard let helper = helperPath else {
            modelState = .failed("helper missing")
            return fail("helper missing")
        }
        modelState = .preparing(nil)
        do {
            preparer = try CaptionProcess(
                helper: helper, arguments: CaptionHelper.prepareArguments(models: modelsDir, model: model),
                log: AppInfo.logsDir.appendingPathComponent("captions.log"), onLine: { _ in },
                onError: { [weak self] line in
                    guard let self, let progress = CaptionProgress.parse(line) else { return }
                    self.modelState = .preparing(progress.fraction)
                    if case .preparing = self.captions?.phase { self.captions?.phase = .preparing(progress.fraction) }
                },
                onExit: { [weak self] status in self?.prepared(status: status) })
        } catch {
            preparer = nil
            fail(error.localizedDescription)
        }
    }

    /// A recording started (or the mode switched to fast captions while recording).
    func start(taps: [CaptionTap]) {
        stop(hide: true)
        wanted = true
        restarts = 0
        pauseReason = nil
        self.taps = taps
        refreshModelState()
        if modelState == .ready {
            captions = LiveCaptions(phase: .starting)
            launch()
        } else {
            captions = LiveCaptions(phase: .preparing(nil))
            prepareModel()
        }
    }

    /// Stop, discard or mode change. `hide` also removes the captions from the pill.
    func stop(hide: Bool) {
        wanted = false
        for tap in taps { tap.isEnabled = false; tap.onAudio = nil }
        taps = []
        helper?.stop()
        helper = nil
        if hide { captions = nil }
    }

    /// Pause/resume of the recording: buffered audio and captions are dropped (recorded time jumps).
    func recordingPausedOrResumed() {
        helper?.send(.reset(track: nil))
        captions?.clear()
    }

    /// Applies the live pause rules; called on a timer while recording and when design A reports its status.
    func applyGate(memoryCritical: Bool, onBattery: Bool, liveStatus: LiveStatus?) {
        guard wanted else { return }
        let reason = CaptionHelper.pauseReason(memoryCritical: memoryCritical, onBattery: onBattery, liveStatus: liveStatus)
        guard reason != pauseReason else { return }
        pauseReason = reason
        if let reason {
            for tap in taps { tap.isEnabled = false }
            helper?.stop()  // frees its memory; restarted when the condition clears
            helper = nil
            captions?.phase = .paused(reason)
            captions?.clear()
        } else if modelState == .ready {
            captions?.phase = .starting
            launch()
        }
    }

    // MARK: - Private

    private func launch() {
        guard wanted, pauseReason == nil, helper == nil else { return }
        guard let path = helperPath else { return fail("helper missing") }
        do {
            let process = try CaptionProcess(
                helper: path, arguments: CaptionHelper.serveArguments(models: modelsDir, model: model),
                log: AppInfo.logsDir.appendingPathComponent("captions.log"),
                onLine: { [weak self] line in self?.handle(line) }, onError: { _ in },
                onExit: { [weak self] status in self?.helperExited(status) })
            helper = process
            for tap in taps {
                tap.onAudio = { [weak process] track, start, samples in
                    process?.send(.audio(track: track, start: start, samples: samples))
                }
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func handle(_ line: String) {
        guard let event = CaptionEvent.parse(line) else { return }
        switch event {
        case .ready:
            for tap in taps { tap.isEnabled = true }
            restarts = 0
        case let .error(message):
            if helper?.isRunning != true { return fail(message) }
        default:
            break
        }
        captions?.apply(event)
    }

    private func helperExited(_ status: Int32) {
        guard wanted, pauseReason == nil, helper != nil, helper?.isRunning != true else { return }
        helper = nil
        for tap in taps { tap.isEnabled = false }
        restarts += 1
        guard restarts <= Self.maxRestarts else { return fail("exit \(status)") }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(restarts)) { [weak self] in
            MainActor.assumeIsolated { self?.launch() }
        }
    }

    private func prepared(status: Int32) {
        preparer = nil
        refreshModelState()
        guard modelState == .ready else { return fail(status == 0 ? "model incomplete" : "download failed (\(status))") }
        if wanted {
            captions = LiveCaptions(phase: .starting)
            launch()
        }
    }

    private func fail(_ message: String) {
        if case .preparing = modelState { modelState = .failed(message) }
        if wanted { captions?.phase = .failed(message) }
        helper?.stop()
        helper = nil
        for tap in taps { tap.isEnabled = false }
    }
}
