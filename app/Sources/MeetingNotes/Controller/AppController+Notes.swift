// Opening notes and Finder, notes folder and settings changes (Controller).

import AppKit
import MeetingNotesCore
import MeetingNotesUI

extension AppController {
    func openLastNotes() {
        if let lastResult, FileManager.default.fileExists(atPath: lastResult.folder) {
            ui?.openNotes(URL(fileURLWithPath: lastResult.folder, isDirectory: true))
        } else if let recent = recents().first(where: { $0.hasNotes }) {
            ui?.openNotes(recent.url)
        } else {
            ui?.showToast(tr(.toastNoNotes))
        }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func openInDefaultApp(_ url: URL) { NSWorkspace.shared.open(url) }

    func copySummary(folder: URL) {
        let summaryURL = folder.appendingPathComponent(".work/summary.json")
        var text: String?
        if let data = try? Data(contentsOf: summaryURL), let summary = try? JSONDecoder().decode(MeetingSummary.self, from: data) {
            text = summary.plainText()
        }
        if text?.isEmpty ?? true {
            text = try? String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8)
        }
        guard let text, !text.isEmpty else {
            ui?.showToast(tr(.toastNoSummary))
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ui?.showToast(tr(.toastSummaryCopied))
    }

    func openNotesFolder() {
        try? FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(notesDir)
    }

    func setCreateNotesMode(_ mode: CreateNotesMode) {
        Settings.createNotesMode = mode
        state.createNotesMode = mode
        jobs.pump()
        refresh()
    }

    func setSummaryModel(_ model: SummaryModel) {
        Settings.summaryModel = model
    }

    func chooseNotesFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = tr(.actionUseFolder)
        panel.directoryURL = notesDir
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Settings.notesDir = url
        notesDir = Settings.notesDir
    }

    func resetNotesFolder() {
        Settings.notesDir = Settings.defaultNotesDir
        notesDir = Settings.notesDir
    }
}
