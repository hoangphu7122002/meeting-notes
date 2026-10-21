// Meeting title editing and applying titles to sessions and jobs (Controller).

import AppKit
import MeetingNotesCore
import MeetingNotesUI

extension AppController {
    /// Commits `titleDraft` to the meeting the pill currently shows.
    /// What the title field edits; captured when editing begins so a state change mid-edit
    /// (job finished, next job started) cannot redirect the title to another meeting.
    enum TitleTarget {
        case session(RecordingSession)
        case job(id: String, folder: URL)
        case ready(ReadyInfo)
    }

    func titleEditingBegan() { editTarget = currentTitleTarget() }

    private func currentTitleTarget() -> TitleTarget? {
        switch pill {
        case .starting, .recording, .paused, .stopping:
            return session.map { .session($0) }
        case .processing(let snapshot):
            return .job(id: snapshot.job, folder: URL(fileURLWithPath: snapshot.folder, isDirectory: true))
        case .ready(let info):
            return .ready(info)
        default:
            return nil
        }
    }

    /// Commits `titleDraft` to the meeting that was shown when editing began.
    func commitTitle() {
        let target = editTarget ?? currentTitleTarget()
        editTarget = nil
        let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let target else {
            syncTitleDraft(force: true)
            return
        }
        switch target {
        case .session(let recording):
            recording.setTitle(title)
        case let .job(id, folder):
            if jobs.current?.id == id {
                pendingTitles[id] = title  // applied after the job, then re-rendered
            } else if let finished = finishedJobs[id] {
                applyTitle(title, folder: finished.folder)
                if finished.hasNotes { jobs.enqueue(folder: finished.folder, title: title, from: "render", explicit: true) }
            } else {
                applyTitle(title, folder: folder)  // not started yet: the pipeline reads it
                jobs.retitleQueued(folder: folder, title: title)
            }
        case .ready(let info):
            guard title != info.title else { break }
            let folder = URL(fileURLWithPath: info.folder, isDirectory: true)
            applyTitle(title, folder: folder)
            if readyShown?.folder == info.folder { readyShown?.title = title }
            if lastResult?.folder == info.folder { lastResult?.title = title }
            if info.hasNotes {
                jobs.enqueue(folder: folder, title: title, from: "render", explicit: true)
            }
        }
        writeState()
        refresh()
        reloadRecents()
    }

    func applyTitle(_ title: String, folder: URL) {
        let url = folder.appendingPathComponent("meeting.json")
        do {
            let data = try MeetingRecord.updatingTitle(Data(contentsOf: url), title: title)
            try data.write(to: url, options: .atomic)
        } catch {
            ui?.showToast(tr(.toastCouldNotRename, error.localizedDescription))
        }
    }

    private func titleTarget() -> (key: String, title: String)? {
        switch pill {
        case .starting, .recording, .paused, .stopping:
            guard let session else { return nil }
            return (MeetingFolders.key(session.folder), session.title)
        case .processing(let snapshot):
            return ("job:" + snapshot.job, pendingTitles[snapshot.job] ?? snapshot.title)
        case .ready(let info):
            return (MeetingFolders.key(URL(fileURLWithPath: info.folder)), info.title)
        default:
            return nil
        }
    }

    func syncTitleDraft(force: Bool = false) {
        guard let target = titleTarget() else {
            titleTargetKey = nil
            return
        }
        if force || (target.key != titleTargetKey && ui?.isEditingTitle != true) {
            titleTargetKey = target.key
            if titleDraft != target.title { titleDraft = target.title }
        }
    }
}
