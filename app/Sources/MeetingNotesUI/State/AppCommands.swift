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
    func setLiveMode(_ mode: LiveMode)
    func chooseNotesFolder()
    func resetNotesFolder()
    func setShowInDock(_ show: Bool)
    func setPillVisibility(whileRecording: Bool, whenIdle: Bool)
    func resetPillPosition()
    /// First-run setup card buttons (default implementation: no-op).
    func setupAction(_ action: SetupAction)
}

/// Buttons of the first-run setup card.
public enum SetupAction: Sendable {
    /// Set up / Continue / Retry / Check again.
    case start
    case cancel
    /// Opens https://ollama.com/download in the browser (the official installer; the app never installs Ollama).
    case downloadOllama
    /// Opens the installed Ollama.app.
    case openOllama
    /// Copies the Homebrew alternative to the clipboard.
    case copyBrewCommand
}

public extension AppCommands {
    /// Default: no-op (previews, tests). The app controller implements it.
    func setupAction(_ action: SetupAction) {}
}

