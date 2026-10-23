// Opt-in live transcript while recording: worker event routing, start/stop, fast captions, mode setting (Controller).

import Foundation
import MeetingNotesCore
import MeetingNotesUI

extension AppController {
    /// Delay after capture started: the provisional meeting.json and the first audio exist by then.
    nonisolated static let liveStartDelay: TimeInterval = 3

    /// Routes worker output: `live-` jobs to the live transcriber, other job events to the queue,
    /// worker status and termination to both.
    func setupWorkerRouting() {
        worker.onEvent = { [weak self] event in
            guard let self else { return }
            if case .worker = event {
                self.jobs.handle(event)
                self.live.handle(event)
            } else if LiveTranscriber.isLiveJob(event.job) {
                self.live.handle(event)
            } else {
                self.jobs.handle(event)
            }
        }
        worker.onTerminate = { [weak self] in
            self?.jobs.workerTerminated()
            self?.live.workerTerminated()
        }
        live.onChange = { [weak self] transcript in
            guard let self, self.state.liveTranscript != transcript else { return }
            self.state.liveTranscript = transcript
            self.applyCaptionGate()
        }
        captioner.onChange = { [weak self] captions in
            guard let self, self.state.liveCaptions != captions else { return }
            self.state.liveCaptions = captions
        }
        captioner.onModelState = { [weak self] model in self?.state.captionModel = model }
        if Settings.liveMode == .fast { captioner.refreshModelState() }
    }

    /// A recording started: clears the previous transcript and, when the setting is on, starts live
    /// a few seconds later if the same recording is still running.
    func startLiveSoon(folder: URL, delay: TimeInterval = AppController.liveStartDelay) {
        liveStartWork?.cancel()
        liveStartWork = nil
        live.clear()
        guard Settings.liveTranscription else { return }
        startCaptionsIfWanted()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.liveStartWork = nil
                guard Settings.liveTranscription, self.machine.phase.isActive,
                      let current = self.session?.folder, MeetingFolders.key(current) == MeetingFolders.key(folder) else { return }
                self.live.start(folder: folder)
            }
        }
        liveStartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Stop or discard: asks the live job to end (nothing is sent when live is off). Captions always disappear.
    func stopLive(hide: Bool = false) {
        liveStartWork?.cancel()
        liveStartWork = nil
        live.stop(hide: hide)
        stopCaptions()
    }

    /// Settings › Live transcript (fast captions / accurate / off); applies to the recording in progress too.
    func setLiveMode(_ mode: LiveMode) {
        Settings.liveMode = mode
        if mode.captions { captioner.prepareModel() }  // first enable: download now, with progress
        guard machine.phase.isActive, let folder = session?.folder else { return }
        if !mode.live {
            stopLive(hide: true)
            return
        }
        if !live.isActive { startLiveSoon(folder: folder, delay: 0.5) }
        if mode.captions { startCaptionsIfWanted() } else { stopCaptions() }
    }

    // MARK: - Fast captions (design B)

    func startCaptionsIfWanted() {
        guard Settings.liveMode == .fast, machine.phase.isActive, let session, !captioner.isActive else { return }
        captioner.start(taps: session.captionTaps)
        captionGateTimer?.invalidate()
        captionGateTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyCaptionGate() }
        }
        applyCaptionGate()
    }

    func stopCaptions() {
        captionGateTimer?.invalidate()
        captionGateTimer = nil
        captioner.stop(hide: true)
    }

    /// Live pause rules for captions: critical memory pressure, battery, or design A deferring for either.
    func applyCaptionGate() {
        captioner.applyGate(memoryCritical: memoryPressure.isCritical, onBattery: !PowerState.onACPower,
                            liveStatus: state.liveTranscript?.status)
    }
}
