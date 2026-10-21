// Opt-in live transcript while recording: worker event routing, start/stop, setting toggle (Controller).

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
        }
    }

    /// A recording started: clears the previous transcript and, when the setting is on, starts live
    /// a few seconds later if the same recording is still running.
    func startLiveSoon(folder: URL, delay: TimeInterval = AppController.liveStartDelay) {
        liveStartWork?.cancel()
        liveStartWork = nil
        live.clear()
        guard Settings.liveTranscription else { return }
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

    /// Stop or discard: asks the live job to end (nothing is sent when live is off).
    func stopLive(hide: Bool = false) {
        liveStartWork?.cancel()
        liveStartWork = nil
        live.stop(hide: hide)
    }

    /// Settings toggle; applies to the recording in progress too.
    func setLiveTranscription(_ enabled: Bool) {
        Settings.liveTranscription = enabled
        if enabled {
            guard machine.phase.isActive, !live.isActive, let folder = session?.folder else { return }
            startLiveSoon(folder: folder, delay: 0.5)
        } else {
            stopLive(hide: true)
        }
    }
}
