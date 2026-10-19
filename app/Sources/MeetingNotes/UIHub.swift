import AppKit
import MeetingNotesCore
import SwiftUI

/// Owns every window and panel: pill, toast, cards, status item, settings, onboarding, notes viewers.
@MainActor
final class UIHub: NSObject, UIPresenter, NSWindowDelegate {
    let controller: AppController
    let pill: PillWindowController
    private let toast = ToastPanel()
    private let detectionCard = CardPanel()
    private let autoStopCard = CardPanel()
    private let autoStopModel = AutoStopModel()
    private var statusItem: StatusItemController?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var onboardingModel: OnboardingModel?
    private var viewers: [String: (window: NSWindow, model: NotesViewerModel)] = [:]

    init(controller: AppController) {
        self.controller = controller
        pill = PillWindowController(controller: controller)
        super.init()
        pill.onFrameChange = { [weak self] frame in
            guard let self, self.autoStopCard.isVisible else { return }
            self.autoStopCard.move(to: .above(frame))
        }
    }

    func start() {
        statusItem = StatusItemController(controller: controller, hub: self)
        pill.show(expand: true)
        statusItem?.update()
    }

    // MARK: - UIPresenter

    var isPillExpanded: Bool { pill.isExpanded }
    var isEditingTitle: Bool { pill.ui.editingTitle }

    func showToast(_ text: String) {
        toast.show(text, above: pill.isVisible ? pill.frame : NSRect(x: pill.frame.midX, y: pill.frame.minY, width: 0, height: 0))
    }

    func pillStateChanged() {
        pill.update()
        statusItem?.update()
    }

    func showDetectionCard(_ app: MeetingDetector.App?) {
        guard let app else {
            detectionCard.hide()
            return
        }
        detectionCard.show(DetectionCardView(
            appName: app.name,
            onStart: { [weak self] in self?.controller.detectionStart() },
            onNotNow: { [weak self] in self?.controller.detectionDismiss(snooze: false) },
            onSnooze: { [weak self] in self?.controller.detectionDismiss(snooze: true) }), placement: .topRight)
    }

    func showAutoStopCard(_ prompt: AutoStopPrompt?) {
        guard let prompt else {
            autoStopCard.hide()
            return
        }
        autoStopModel.prompt = prompt
        if !autoStopCard.isVisible {
            autoStopCard.show(AutoStopCardView(
                model: autoStopModel,
                onStop: { [weak self] in self?.controller.autoStopNow() },
                onKeep: { [weak self] in self?.controller.keepRecording() }), placement: .above(pill.frame))
        }
    }

    func showControls(expand: Bool) {
        pill.show(expand: expand)
    }

    func hidePill() { pill.collapse() }

    func endTitleEditing() { pill.panel.makeFirstResponder(nil) }

    func resetPillPosition() {
        pill.resetPosition()
        pill.show(expand: false)
    }

    func setShowInDock(_ show: Bool) {
        Settings.showInDock = show
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        if !show { NSApp.activate(ignoringOtherApps: true) }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Windows

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "Meeting Notes Settings", view: SettingsView(controller: controller, hub: self),
                                        resizable: false)
        }
        present(settingsWindow)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let model = OnboardingModel(controller: controller)
            onboardingModel = model
            let view = OnboardingView(model: model, controller: controller, onDone: { [weak self] in
                Settings.onboardingDone = true
                self?.onboardingWindow?.close()
            })
            onboardingWindow = makeWindow(title: "Meeting Notes Setup", view: view, resizable: false)
        }
        onboardingModel?.refresh()
        present(onboardingWindow)
    }

    func openNotes(_ folder: URL) {
        let key = MeetingFolders.key(folder)
        if let existing = viewers[key] {
            existing.model.load()
            present(existing.window)
            return
        }
        let model = NotesViewerModel(folder: folder)
        let window = makeWindow(title: model.title, view: NotesView(model: model, controller: controller), resizable: true)
        window.setContentSize(NSSize(width: 720, height: 760))
        window.setFrameAutosaveName("NotesViewer")
        viewers[key] = (window, model)
        present(window)
    }

    func notesFolderMoved(from: URL, to: URL) {
        guard let entry = viewers.removeValue(forKey: MeetingFolders.key(from)) else { return }
        entry.model.setFolder(to)
        viewers[MeetingFolders.key(to)] = entry
    }

    func reloadNotes(_ folder: URL) {
        viewers[MeetingFolders.key(folder)]?.model.scheduleReload()
    }

    private func makeWindow<V: View>(title: String, view: V, resizable: Bool) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600), styleMask: style, backing: .buffered, defer: true)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.delegate = self
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === onboardingWindow {
            Settings.onboardingDone = true
            onboardingWindow = nil
            onboardingModel = nil
        } else if window === settingsWindow {
            settingsWindow = nil
        } else if let entry = viewers.first(where: { $0.value.window === window }) {
            entry.value.model.stop()
            viewers[entry.key] = nil
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === onboardingWindow { onboardingModel?.refresh() }
    }
}
