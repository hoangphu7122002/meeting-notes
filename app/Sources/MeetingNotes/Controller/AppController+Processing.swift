// Processing queue: job lifecycle, ready/error pill, relaunch helpers (Controller).

import AppKit
import MeetingNotesCore
import MeetingNotesUI

extension AppController {
    func retry(folder: URL) {
        error = nil
        jobs.enqueue(folder: folder, title: MeetingFolders.title(of: folder), explicit: true)
        refresh()
    }

    func createNotes(folder: URL) {
        hideReady()
        jobs.enqueue(folder: folder, title: MeetingFolders.title(of: folder), explicit: true)
        refresh()
    }

    func cancelProcessing() {
        if jobs.current != nil { ui?.showToast(tr(.toastCancelling)) }
        jobs.cancelCurrent()
    }

    func processWaitingNow() { jobs.startWaitingNow() }

    func jobFinished(_ job: JobQueue.Job, _ outcome: JobOutcome) {
        finishedJobs[job.id] = (job.folder, { if case .done = outcome { return true } else { return false } }())
        if case .done = outcome {} else if let pending = pendingTitles.removeValue(forKey: job.id) {
            applyTitle(pending, folder: job.folder)  // failed or cancelled: keep the user's title for the retry
        }
        switch outcome {
        case let .done(folder, notes, title):
            let url = URL(fileURLWithPath: folder, isDirectory: true)
            var finalTitle = title ?? job.title
            if let pending = pendingTitles.removeValue(forKey: job.id), pending != finalTitle {
                finalTitle = pending
                applyTitle(pending, folder: url)
                jobs.enqueue(folder: url, title: pending, from: "render", explicit: true)
            }
            let info = ReadyInfo(folder: folder, title: finalTitle, notesPath: notes)
            lastResult = info
            Settings.lastNotesFolder = url
            if MeetingFolders.key(job.originalFolder) != MeetingFolders.key(url) {
                ui?.notesFolderMoved(from: job.originalFolder, to: url)
            }
            ui?.reloadNotes(url)
            if job.from == "render" {
                if let shown = readyShown, MeetingFolders.key(URL(fileURLWithPath: shown.folder)) == MeetingFolders.key(job.originalFolder) {
                    readyShown = info
                }
            } else {
                showReady(info)
                notifier.notesReady(title: finalTitle, folder: url)
            }
        case let .failed(message):
            error = PillError(tr(.errProcessingFailed, Format.clip(message, 160)), action: .retry(folder: job.folder.path))
        case .cancelled:
            ui?.showToast(tr(.toastProcessingCancelled))
        }
        refresh()
    }

    func showReady(_ info: ReadyInfo) {
        readyShown = info
        scheduleReadyCollapse(after: 6)
    }

    private func scheduleReadyCollapse(after seconds: Double) {
        readyTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.readyShown != nil else { return }
                if self.ui?.isPillExpanded == true {
                    self.scheduleReadyCollapse(after: 3)
                } else {
                    self.hideReady()
                    self.refresh()
                }
            }
        }
        readyTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func hideReady() {
        readyTimer?.cancel()
        readyTimer = nil
        readyShown = nil
    }

    func dismissError() {
        error = nil
        refresh()
    }

    func dismissReady() {
        hideReady()
        refresh()
    }

    func performErrorAction() {
        guard case .error(let pillError) = pill else { return }
        switch pillError.action {
        case .retry(let folder): retry(folder: URL(fileURLWithPath: folder, isDirectory: true))
        case .openSettings(let kind):
            Permissions.openSettings(kind)
            ui?.showMainWindow()
            dismissError()
        case .none: dismissError()
        }
    }
}
