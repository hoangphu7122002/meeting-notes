// Floating detection / auto-stop card panel (Presentation).

import AppKit
import MeetingNotesCore
import MeetingNotesUI
import SwiftUI

/// Small floating card at the top-right of the screen or above the pill.
@MainActor
final class CardPanel {
    enum Placement {
        case topRight
        case above(NSRect)
    }

    private let panel = FloatingPanel(size: CGSize(width: 340, height: 120))
    private var placement = Placement.topRight
    private var fittedSize: () -> CGSize = { CGSize(width: 340, height: 120) }

    var isVisible: Bool { panel.isVisible }

    /// `make` builds the card with the size callback to wire into its `onFittingSizeChange`.
    func show<Content: View>(_ make: (@escaping (CGSize) -> Void) -> Content, placement: Placement) {
        self.placement = placement
        let content = make { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.place() } }
        }
        let hosting = FittingHostingView(rootView: content)
        fittedSize = { [weak hosting] in hosting?.fittedSize ?? CGSize(width: 340, height: 120) }
        panel.contentView = hosting
        place()
        panel.orderFrontRegardless()
    }

    func move(to placement: Placement) {
        self.placement = placement
        place()
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        // Release the content later: hide() usually runs inside one of its own button actions.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.panel.isVisible else { return }
                self.panel.contentView = nil
                self.fittedSize = { CGSize(width: 340, height: 120) }
            }
        }
    }

    private func place() {
        let size = fittedSize()
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame: CGRect
        switch placement {
        case .topRight:
            frame = CGRect(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16, width: size.width, height: size.height)
        case .above(let pill):
            frame = PillLayout.frame(size: size, anchor: CGPoint(x: pill.midX, y: pill.maxY + 10), visible: visible)
        }
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }
}
