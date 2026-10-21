// Actions the views can trigger; implemented by the app controller (State).

import Foundation
import MeetingNotesCore

/// Actions the views can trigger (implemented by the app controller, a no-op in previews).
@MainActor
public protocol AppCommands: AnyObject {
    func perform(_ command: RecorderCommand, source: ActionSource)
    func startRecording(source: ActionSource)
    func titleEditingBegan()
    func commitTitle()
    func processWaitingNow()
    func cancelProcessing()
    func performErrorAction()
    func dismissError()
    func openNotes(_ folder: URL)
    func reveal(_ url: URL)
    func openInDefaultApp(_ url: URL)
    func copySummary(folder: URL)
    func createNotes(folder: URL)
    func retry(folder: URL)
    func openLastNotes()
    func openNotesFolder()
    func hidePillForAnHour()
    func showSettings()
    func showMainWindow()
    func fixPermission(_ kind: PermissionKind)
    func openPermissionSettings(_ kind: PermissionKind)
    func runAudioTest()
    func dismissGettingStarted()
    func relaunch()
    func setLanguage(_ language: UILanguage)
    func setDetectionEnabled(_ enabled: Bool)
    func setCreateNotesMode(_ mode: CreateNotesMode)
    func setSummaryModel(_ model: SummaryModel)
    func setLiveTranscription(_ enabled: Bool)
    func chooseNotesFolder()
    func resetNotesFolder()
    func setShowInDock(_ show: Bool)
    func setPillVisibility(whileRecording: Bool, whenIdle: Bool)
    func resetPillPosition()
}
