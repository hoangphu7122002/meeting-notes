// Protocol of the UI surfaces the controller drives; implemented by UIHub (Controller).

import AppKit
import MeetingNotesCore
import MeetingNotesUI

/// UI surfaces the controller drives (implemented by `UIHub`).
@MainActor
protocol UIPresenter: AnyObject {
    func showToast(_ text: String)
    func pillStateChanged()
    func showDetectionCard(_ app: MeetingDetector.App?)
    func showAutoStopCard(_ prompt: AutoStopPrompt?)
    func openNotes(_ folder: URL)
    func notesFolderMoved(from: URL, to: URL)
    func reloadNotes(_ folder: URL)
    func showMainWindow()
    func showSettings()
    func showControls(expand: Bool)
    func hidePill()
    func endTitleEditing()
    func languageChanged()
    func setShowInDock(_ show: Bool)
    func resetPillPosition()
    var isPillExpanded: Bool { get }
    var isEditingTitle: Bool { get }
    /// The main window is on screen (recents are only read while it is).
    var isMainWindowVisible: Bool { get }
}
