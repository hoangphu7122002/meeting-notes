// AppCommands implementation: what the views and menus can ask the controller to do (Controller).

import AppKit
import MeetingNotesCore
import MeetingNotesUI

extension AppController: AppCommands {
    func openNotes(_ folder: URL) { ui?.openNotes(folder) }
    func showSettings() { ui?.showSettings() }
    func showMainWindow() { ui?.showMainWindow() }
    func resetPillPosition() { ui?.resetPillPosition() }
    func setShowInDock(_ show: Bool) { ui?.setShowInDock(show) }

    func setPillVisibility(whileRecording: Bool, whenIdle: Bool) {
        Settings.showRecordingPill = whileRecording
        Settings.showIdlePill = whenIdle
        if whenIdle { unhidePill() }
        ui?.pillStateChanged()
    }

    func setLanguage(_ language: UILanguage) {
        guard language != L10n.language else { return }
        Settings.uiLanguage = language
        LanguageModel.shared.set(language)
        refresh()
        ui?.languageChanged()
    }

    func dismissGettingStarted() {
        Settings.onboardingDone = true
        state.showGettingStarted = false
    }

    /// Requests a permission that was never asked, otherwise opens its System Settings pane.
    func fixPermission(_ kind: PermissionKind) {
        switch kind {
        case .microphone:
            guard Permissions.microphone == .notDetermined else { return Permissions.openSettings(.microphone) }
            Task { @MainActor in
                _ = await Permissions.requestMicrophone()
                refreshPermissions()
            }
        case .screenCapture:
            // Shows the system prompt once; afterwards only System Settings can change it.
            if !Permissions.requestScreenCapture() { Permissions.openSettings(.screenCapture) }
            refreshPermissions()
        case .notifications:
            guard state.notifications == .notDetermined else { return Permissions.openSettings(.notifications) }
            notifier.requestAuthorization { [weak self] _ in self?.refreshPermissions() }
        }
    }

    func openPermissionSettings(_ kind: PermissionKind) { Permissions.openSettings(kind) }

    /// Restarts the app so macOS applies a newly granted Screen & System Audio Recording permission.
    /// Only while idle with no notes job (see `RelaunchPolicy`).
    func relaunch() {
        guard state.canRelaunch else {
            ui?.showToast(tr(.relaunchBlocked))
            return
        }
        let path = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        // Waits (max ~10 s) for this process to exit, then opens a fresh instance.
        let script = "for i in $(seq 1 50); do kill -0 \(pid) 2>/dev/null || break; sleep 0.2; done; sleep 0.3; /usr/bin/open -n -a \"$0\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, path]
        do {
            try process.run()
        } catch {
            ui?.showToast(error.localizedDescription)
            return
        }
        NSApp.terminate(nil)
    }

    /// Captures mic + system audio for 5 s and plays a system sound from a separate process
    /// (captured despite `excludesCurrentProcessAudio`). Nothing is written to disk.
    func runAudioTest() {
        guard !state.audioTest.running else { return }
        guard machine.phase == .idle else {
            state.audioTest = AudioTestState(result: [tr(.testStopFirst)])
            return
        }
        state.audioTest = AudioTestState(running: true)
        let micSink = MeterSink()
        let systemSink = MeterSink()
        let mic = MicRecorder(sink: micSink)
        let system = SystemAudioCapture(sink: systemSink)
        Task { @MainActor in
            var micError: String?
            var systemFailed = false
            if await MicRecorder.ensurePermission() {
                do { try mic.start() } catch { micError = error.localizedDescription }
            } else {
                micError = tr(.micAccessDenied)
            }
            do {
                try await system.start()
                screenCaptureVerified = true
            } catch {
                systemFailed = true
                if Permissions.isPermissionError(error) { screenCaptureVerified = false }
            }
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.state.audioTest.me = LevelMeter.displayValue(micSink.meter.level())
                    self?.state.audioTest.them = LevelMeter.displayValue(systemSink.meter.level())
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = ["/System/Library/Sounds/Glass.aiff"]
            try? player.run()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            timer.invalidate()
            mic.stop()
            await system.stop()
            let me = micError.map { tr(.testMeError, $0) }
                ?? (micSink.peakDB > -60 ? tr(.testMeOK, Int(micSink.peakDB)) : tr(.testMeSilent))
            let them = systemFailed ? tr(.testThemNotPermitted)
                : (systemSink.peakDB > -60 ? tr(.testThemOK) : tr(.testThemSilent))
            state.audioTest = AudioTestState(result: [me, them])
            refreshPermissions()
        }
    }
}
