import AppKit
import MeetingNotesCore
import MeetingNotesUI
import SwiftUI

/// Owns every window and panel: main window, pill, toast, cards, status item, settings, notes viewers.
@MainActor
final class UIHub: NSObject, UIPresenter, NSWindowDelegate {
    let controller: AppController
    let pill: PillWindowController
    /// Rebuilds the app's main menu (after a language change).
    var onLanguageChanged: (() -> Void)?
    private let toast = ToastPanel()
    private let detectionCard = CardPanel()
    private let autoStopCard = CardPanel()
    private let autoStopModel = AutoStopModel()
    private var statusItem: StatusItemController?
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var viewers: [String: (window: NSWindow, model: NotesViewerModel)] = [:]
    private var windowEditingTitle = false

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
        pill.update()
        statusItem?.update()
    }

    // MARK: - UIPresenter

    var isPillExpanded: Bool { pill.isExpanded }
    var isEditingTitle: Bool { pill.ui.editingTitle || windowEditingTitle }

    var isMainWindowVisible: Bool {
        guard let mainWindow else { return false }
        return mainWindow.isVisible && !mainWindow.isMiniaturized
    }

    func showToast(_ text: String) {
        toast.show(text, above: pill.restingFrame)
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
        detectionCard.show({ sizeChanged in
            DetectionCardView(
                appName: app.name,
                onStart: { [weak self] in self?.controller.detectionStart() },
                onNotNow: { [weak self] in self?.controller.detectionDismiss(snooze: false) },
                onSnooze: { [weak self] in self?.controller.detectionDismiss(snooze: true) },
                sizeChanged: sizeChanged)
        }, placement: .topRight)
    }

    func showAutoStopCard(_ prompt: AutoStopPrompt?) {
        guard let prompt else {
            autoStopCard.hide()
            return
        }
        autoStopModel.prompt = prompt
        if !autoStopCard.isVisible {
            let model = autoStopModel
            autoStopCard.show({ sizeChanged in
                AutoStopCardView(
                    model: model,
                    onStop: { [weak self] in self?.controller.autoStopNow() },
                    onKeep: { [weak self] in self?.controller.keepRecording() },
                    sizeChanged: sizeChanged)
            }, placement: .above(pill.restingFrame))
        }
    }

    func showControls(expand: Bool) {
        pill.show(expand: expand)
    }

    func hidePill() { pill.collapse() }

    func endTitleEditing() {
        pill.panel.makeFirstResponder(nil)
        if windowEditingTitle { mainWindow?.makeFirstResponder(nil) }
    }

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

    func languageChanged() {
        settingsWindow?.title = tr(.settingsWindowTitle)
        statusItem?.update(force: true)
        onLanguageChanged?()
    }

    // MARK: - Main window

    /// The app's home window: launch, Dock click / reopen, `meetingnotes://show`, menus.
    func showMainWindow() {
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
            window.title = "Meeting Notes"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 440, height: 480)
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("MainWindow")
            mainWindow = window
        }
        guard let window = mainWindow else { return }
        // Built on show and released on close, so a closed window costs nothing.
        window.hostContentIfNeeded {
            let view = MainWindowView(state: controller.state, commands: controller,
                                      editingChanged: { [weak self] editing in self?.windowTitleEditing(editing) })
            let hosting = NSHostingView(rootView: view)
            hosting.sizingOptions = [.minSize]
            return hosting
        }
        present(window)
        mainWindowVisibilityChanged()
    }

    private func windowTitleEditing(_ editing: Bool) {
        windowEditingTitle = editing
        if editing { controller.titleEditingBegan() }
    }

    private func mainWindowVisibilityChanged() {
        let visible = isMainWindowVisible && (mainWindow?.occlusionState.contains(.visible) ?? false)
        controller.setMeterVisible("window", visible)
        if visible { controller.reloadRecents() }
    }

    // MARK: - Other windows

    func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(state: controller.state, commands: controller, detectionSupported: MeetingDetector.isSupported)
            settingsWindow = makeWindow(title: tr(.settingsWindowTitle), view: view, resizable: false)
        }
        present(settingsWindow)
    }

    func openNotes(_ folder: URL) {
        let key = MeetingFolders.key(folder)
        if let existing = viewers[key] {
            existing.model.load()
            present(existing.window)
            return
        }
        let model = NotesViewerModel(folder: folder)
        let window = makeWindow(title: model.title, view: NotesView(model: model, commands: controller), resizable: true)
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 640), styleMask: style, backing: .buffered, defer: true)
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

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === mainWindow {
            if windowEditingTitle { window.makeFirstResponder(nil) }
            windowEditingTitle = false
            controller.setMeterVisible("window", false)
            // Release the view tree after the close finishes.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let window = self?.mainWindow, !window.isVisible else { return }
                    window.contentView = nil
                }
            }
        } else if window === settingsWindow {
            settingsWindow = nil
        } else if let entry = viewers.first(where: { $0.value.window === window }) {
            entry.value.model.stop()
            viewers[entry.key] = nil
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow else { return }
        controller.refreshPermissions()
        mainWindowVisibilityChanged()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow else { return }
        mainWindowVisibilityChanged()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow else { return }
        mainWindowVisibilityChanged()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow else { return }
        mainWindowVisibilityChanged()
    }
}
