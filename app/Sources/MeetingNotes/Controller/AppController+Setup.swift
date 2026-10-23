// First-run setup of the packaged app (release dmg): wiring between SetupRunner, the main window and the
// one-heavy-job rule (Controller). Dev and shared installs never create a runner.

import AppKit
import MeetingNotesCore
import MeetingNotesUI

extension AppController {
    /// Packaged app only: loads what setup already finished and shows the card when something is left.
    func launchSetup() {
        guard AppInfo.isPackaged else { return }
        let runner = SetupRunner()
        setupRunner = runner
        state.appLocation = AppLocation.classify(bundlePath: Bundle.main.bundlePath, home: NSHomeDirectory())
        state.setupSummaryModel = Settings.summaryModel.model
        runner.onChange = { [weak self] machine in
            guard let self, self.state.setup != machine else { return }
            self.state.setup = machine
        }
        runner.onComplete = { [weak self] in self?.ui?.showToast(tr(.setupComplete)) }
        state.setup = runner.machine
        updateSetupBusy()
        if runner.machine.phase == .running { runner.start() }  // after an update: refresh the runtime by itself
    }

    /// A recording or a running notes job pauses setup (one heavy job at a time); called from `refresh()`.
    func updateSetupBusy() {
        guard let setupRunner else { return }
        setupRunner.setBusy(isCapturing ? .recording : (jobs.current != nil ? .processing : nil))
    }

    /// Back in the app after opening or installing Ollama: check again by itself.
    func setupAppBecameActive() {
        guard let setupRunner, setupRunner.machine.phase == .blocked,
              case .needsUser = setupRunner.machine.state(.ollama) else { return }
        setupRunner.start()
    }

    func setupAction(_ action: SetupAction) {
        guard let setupRunner else { return }
        switch action {
        case .start:
            state.setupSummaryModel = Settings.summaryModel.model
            setupRunner.start()
        case .cancel:
            setupRunner.cancel()
        case .downloadOllama:
            NSWorkspace.shared.open(SetupProbe.ollamaDownloadURL)
        case .openOllama:
            if let app = SetupProbe.ollamaApp {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                setupRunner.recheckSoon()
            }
        case .copyBrewCommand:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(SetupProbe.brewCommand, forType: .string)
        }
    }
}
