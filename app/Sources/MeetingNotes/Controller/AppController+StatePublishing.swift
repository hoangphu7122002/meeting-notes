// Derived pill state and the state.json snapshot for 'meeting-notes ctl status' (Controller).

import AppKit
import MeetingNotesCore
import MeetingNotesUI

extension AppController {
    /// Recomputes the pill state; cheap, called after every change.
    func refresh() {
        let next = PillState.derive(phase: machine.phase, error: error, processing: jobs.displaySnapshot, ready: readyShown,
                                    permissionsNeedAttention: permissionsNeedAttention)
        let kindChanged = next.name != pill.name || next.isIdle != pill.isIdle
        if next != pill { pill = next }
        let jobsActive = jobs.count > 0
        if state.jobsActive != jobsActive { state.jobsActive = jobsActive }
        syncTitleDraft()
        writeState()
        updateLevelTimer()
        if kindChanged { reloadRecents() }
        ui?.pillStateChanged()
    }

    /// Re-reads the recent meetings list, only while the main window shows it.
    func reloadRecents() {
        guard ui?.isMainWindowVisible == true else { return }
        let list = recents()
        if state.recents != list { state.recents = list }
    }

    var processingSnapshot: ProcessingSnapshot? {
        if case .processing(let snapshot) = pill { return snapshot }
        return jobs.displaySnapshot
    }

    func recents() -> [RecentMeeting] {
        let snapshot = jobs.displaySnapshot
        let context = Recents.Context(
            recording: session?.folder,
            processing: snapshot?.waiting == nil ? snapshot.map { URL(fileURLWithPath: $0.folder) } : nil,
            processingPercent: snapshot?.percent,
            jobActive: jobs.current != nil,
            queued: jobs.queued.map(\.folder))
        return Recents.load(dir: notesDir, context: context)
    }

    func writeState() {
        let snapshot = jobs.displaySnapshot
        var parts: [String] = [pill.name, "\(jobs.queued.count)"]
        parts.append(session?.folder.path ?? "")
        parts.append(session?.title ?? "")
        parts.append(snapshot?.folder ?? "")
        parts.append(snapshot?.currentStage ?? "")
        parts.append(snapshot?.waiting ?? "")
        let key = parts.joined(separator: "|")
        let now = Date()
        if key == lastStateKey {
            // Progress-only change: at most once per 2 s.
            guard snapshot != nil, now.timeIntervalSince(lastStateWrite) >= 2 else { return }
        }
        lastStateKey = key
        lastStateWrite = now
        var title: String?
        var folder: String?
        switch pill {
        case .starting, .recording, .paused, .stopping:
            title = session?.title
            folder = session?.folder.path
        case .processing(let s):
            title = s.title
            folder = s.folder
        case .ready(let info):
            title = info.title
            folder = info.folder
        default:
            break
        }
        let status = AppStatusSnapshot(
            state: pill.name, title: title, folder: folder, startedAt: session?.startedAt,
            elapsedSec: session?.recordedSeconds, paused: machine.phase == .paused,
            processing: snapshot.map { .init(folder: $0.folder, stage: $0.waiting == nil ? $0.currentStage : "waiting",
                                             overall: $0.overall, etaSec: $0.etaSec) },
            queue: jobs.queued.count, updatedAt: now)
        writeStateFile(status)
    }

    func writeStateFile(_ status: AppStatusSnapshot, sync: Bool = false) {
        guard let data = try? status.jsonData() else { return }
        let url = AppInfo.stateFile
        let write: @Sendable () -> Void = {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        if sync { stateQueue.sync(execute: write) } else { stateQueue.async(execute: write) }
    }
}
