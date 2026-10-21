import MeetingNotesCore
import SwiftUI

/// Panel-level callbacks of the pill (geometry, hover, dragging), implemented by the pill controller.
public struct PillActions {
    public let sizeChanged: (CGSize) -> Void
    public let expand: () -> Void
    public let collapse: () -> Void
    public let dragChanged: () -> Void
    public let dragEnded: () -> Void
    public let editingChanged: (Bool) -> Void

    public init(sizeChanged: @escaping (CGSize) -> Void, expand: @escaping () -> Void, collapse: @escaping () -> Void,
                dragChanged: @escaping () -> Void, dragEnded: @escaping () -> Void, editingChanged: @escaping (Bool) -> Void) {
        self.sizeChanged = sizeChanged
        self.expand = expand
        self.collapse = collapse
        self.dragChanged = dragChanged
        self.dragEnded = dragEnded
        self.editingChanged = editingChanged
    }

    public static let none = PillActions(sizeChanged: { _ in }, expand: {}, collapse: {}, dragChanged: {}, dragEnded: {},
                                         editingChanged: { _ in })
}

@MainActor
public final class PillUIModel: ObservableObject {
    @Published public var expanded = false
    @Published public var editingTitle = false
    public init() {}
}

/// Root of the pill panel: the collapsed pill, with the expanded card or the warning badge above it.
/// The panel takes this view's fitting size and keeps its bottom-center fixed, so the collapsed pill
/// never moves and a button under the cursor stays under the cursor. No repeating animations.
public struct PillRootView: View {
    @ObservedObject var state: AppState
    @ObservedObject var ui: PillUIModel
    let commands: any AppCommands
    let actions: PillActions

    public init(state: AppState, ui: PillUIModel, commands: any AppCommands, actions: PillActions) {
        self.state = state
        self.ui = ui
        self.commands = commands
        self.actions = actions
    }

    public var body: some View {
        Localized {
            VStack(spacing: PillLayout.spacing) {
                if ui.expanded {
                    ExpandedCard(state: state, commands: commands, actions: actions)
                } else if let warning = state.pillWarning {
                    WarningBadge(warning: warning, onTap: commands.showMainWindow)
                }
                CollapsedPill(state: state, commands: commands, actions: actions)
            }
        }
        .onFittingSizeChange(actions.sizeChanged)
    }
}

extension View {
    func panelDrag(_ actions: PillActions) -> some View {
        gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { _ in actions.dragChanged() }
            .onEnded { _ in actions.dragEnded() })
    }
}
