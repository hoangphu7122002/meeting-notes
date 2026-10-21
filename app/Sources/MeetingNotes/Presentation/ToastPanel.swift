// Brief toast panel above the pill (Presentation).

import AppKit
import MeetingNotesCore
import MeetingNotesUI
import SwiftUI

/// Brief message above the pill (~1.5 s, one fade, no loops).
@MainActor
final class ToastPanel {
    private let panel = FloatingPanel()
    private let model = ToastModel()
    private var hosting: FittingHostingView<ToastView>!
    private var hideWork: DispatchWorkItem?
    private var anchorFrame: NSRect = .zero

    init() {
        panel.ignoresMouseEvents = true
        hosting = FittingHostingView(rootView: ToastView(model: model, sizeChanged: { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.place() } }
        }))
        panel.contentView = hosting
    }

    func show(_ text: String, above frame: NSRect) {
        anchorFrame = frame
        model.text = text
        place()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        // The new text is laid out in the next update pass; re-fit after it.
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.place() } }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.2
                    self.panel.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated { if self.panel.alphaValue == 0 { self.panel.orderOut(nil) } }
                })
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    private func place() {
        let size = hosting.fittedSize
        let anchor = CGPoint(x: anchorFrame.midX, y: anchorFrame.maxY + 8)
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchorFrame.midX, y: anchorFrame.minY)) } ?? NSScreen.main
        let frame = PillLayout.frame(size: size, anchor: anchor, visible: screen?.visibleFrame)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }
}
