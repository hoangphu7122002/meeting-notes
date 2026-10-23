// Recorder commands: start, pause, resume, stop, discard (Controller).

import AppKit
import MeetingNotesCore
import MeetingNotesUI

extension AppController {
    /// Single entry point for start/stop/pause/resume/discard from every surface.
    func perform(_ command: RecorderCommand, source: ActionSource) {
        if source == .hotkey, command == .toggleRecording {
            guard Date().timeIntervalSince(lastHotkeyToggle) > 0.8 else { return }
            lastHotkeyToggle = Date()
        }
        if command == .stop || command == .toggleRecording, ui?.isEditingTitle == true {
            ui?.endTitleEditing()  // commits the title being typed before the recording ends
        }
        let outcome = machine.handle(command)
        var toast = outcome.toast.map { tr($0) }
        switch outcome.effect {
        case .startCapture:
            toast = nil  // "Recording started" once capture runs
            jobs.recordingActive = true  // no new job may start while the capture starts
            beginRecording(source: source)
        case .stopCapture:
            let manual = Settings.createNotesMode == .manual
            if manual { toast = tr(.toastStoppedSaved) }
            if source == .autoStop { toast = tr(manual ? .toastMeetingEndedSaved : .toastMeetingEndedCreating) }
            finishRecording()
        case .pauseCapture:
            session?.pause()
            captioner.recordingPausedOrResumed()
            dismissAutoStop()
            tick()
        case .resumeCapture:
            session?.resume()
            captioner.recordingPausedOrResumed()
            silence.reset()
            systemSilence.reset()
        case .discardCapture:
            discardRecording()
        case .none:
            break
        }
        if let toast, source.showsToast { ui?.showToast(toast) }
        refresh()
    }

    func startRecording(source: ActionSource) { startRecording(app: nil, source: source) }

    func startRecording(app: MeetingDetector.App?, source: ActionSource) {
        if machine.phase == .idle { pendingStart = (app, source) }
        perform(.start, source: source)
    }

    private func beginRecording(source: ActionSource) {
        let app = pendingStart?.app ?? detectedApp ?? detector.activeApps.first
        pendingStart = nil
        let options = RecordingSession.Options.from(appHint: app?.name)
        let dir = notesDir
        error = nil
        hideReady()
        detectedApp = nil
        ui?.showDetectionCard(nil)
        Task { @MainActor in
            var folder: URL?
            do {
                let created = try MeetingFolders.create(in: dir)
                folder = created
                let session = try await RecordingSession.start(folder: created, options: options)
                self.session = session
                session.onWarningsChanged = { [weak self] warnings in self?.recordingWarnings = warnings }
                recordingWarnings = session.warnings
                machine.apply(.started)
                titleDraft = session.title
                titleTargetKey = MeetingFolders.key(created)
                jobs.recordingActive = true
                systemAudio = session.systemAudioAvailable ? .ok : .notPermitted
                if session.systemAudioAvailable { screenCaptureVerified = true }
                micAvailable = session.micWriter != nil
                silence = SilenceTracker(thresholdDB: -50, limit: Double(Settings.autoStopSilenceMinutes * 60))
                systemSilence = SilenceTracker(thresholdDB: -50, limit: 10)
                detector.watch(Settings.autoStopOnCallEnd ? app : nil)
                clock.elapsed = Format.elapsed(0)
                startTicker()
                startLiveSoon(folder: created)
                if source.showsToast { ui?.showToast(tr(.toastRecordingStarted)) }
            } catch {
                if let folder { MeetingFolders.removeIfEmpty(folder) }
                machine.apply(.startFailed)
                jobs.recordingActive = false
                let micDenied = Permissions.microphone == .denied
                self.error = PillError(tr(.errCouldNotStart, Format.clip(error.localizedDescription, 120)),
                                       action: micDenied ? .openSettings(.microphone) : .none)
                if source.showsToast { ui?.showToast(tr(.toastCouldNotStart)) }
            }
            refreshPermissions()
            refresh()
        }
    }

    private func finishRecording() {
        stopLive()  // before the stop/enqueue work, so the Stop-time job reuses the warm worker
        guard let session else {
            machine.apply(.finished)
            return
        }
        stopTicker()
        dismissAutoStop()
        detector.watch(nil)
        finishTask = Task { @MainActor in
            let result = await session.stop()
            self.session = nil
            machine.apply(.finished)
            resetLevels()
            recordingWarnings = []
            if !result.hasAudio {
                error = PillError(tr(.errNoAudio),
                                  action: permissionsNeedAttention ? .openSettings(Permissions.microphone == .granted ? .screenCapture : .microphone) : .none)
            } else if Settings.createNotesMode == .manual {
                showReady(ReadyInfo(folder: result.folder.path, title: result.title, notesPath: nil))
            } else {
                jobs.enqueue(folder: result.folder, title: result.title, explicit: false)
            }
            jobs.recordingActive = false
            detector.rescan()
            refresh()
        }
    }

    private func discardRecording() {
        stopLive()
        guard let session else {
            machine.apply(.finished)
            return
        }
        stopTicker()
        dismissAutoStop()
        detector.watch(nil)
        finishTask = Task { @MainActor in
            do {
                try await session.discard()
                ui?.showToast(tr(.toastDiscarded))
            } catch {
                self.error = PillError(tr(.errCouldNotDelete, error.localizedDescription))
            }
            self.session = nil
            machine.apply(.finished)
            resetLevels()
            recordingWarnings = []
            jobs.recordingActive = false
            detector.rescan()
            refresh()
        }
    }
}
