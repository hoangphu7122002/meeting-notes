import MeetingNotesCore
import SwiftUI

/// The app's home: recorder controls, title, meters, processing, recent meetings and permissions.
public struct MainWindowView: View {
    @ObservedObject var state: AppState
    let commands: any AppCommands
    let editingChanged: (Bool) -> Void
    /// False for previews: lays the whole content out without a scroll view.
    let scrollable: Bool

    public init(state: AppState, commands: any AppCommands, editingChanged: @escaping (Bool) -> Void, scrollable: Bool = true) {
        self.state = state
        self.commands = commands
        self.editingChanged = editingChanged
        self.scrollable = scrollable
    }

    public var body: some View {
        Localized {
            if scrollable {
                ScrollView { content }
            } else {
                content
            }
        }
        .frame(minWidth: 440, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity, alignment: .top)
        .background(Palette.windowBackground)
    }

    private var permissionsMissing: Bool { state.microphone != .granted || state.screenCapture != .granted }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if state.systemAudioMissing { SystemAudioBanner(state: state, commands: commands) }
            if let setup = state.setup, setup.phase != .complete {
                SetupCard(machine: setup, location: state.appLocation, summaryModel: state.setupSummaryModel, commands: commands)
            }
            if state.showGettingStarted { GettingStartedCard(commands: commands) }
            RecorderCard(state: state, commands: commands, editingChanged: editingChanged)
            switch state.pill {
            case .processing(let snapshot): ProcessingCard(snapshot: snapshot, commands: commands)
            case .ready(let info): ReadyCard(info: info, commands: commands)
            case .error(let error): ErrorCard(error: error, commands: commands)
            default: EmptyView()
            }
            // Missing permissions come first; once granted the checklist moves below the meetings.
            if permissionsMissing { PermissionsCard(state: state, commands: commands) }
            RecentsCard(state: state, commands: commands)
            if !permissionsMissing { PermissionsCard(state: state, commands: commands) }
            Footer(state: state, commands: commands)
        }
        .font(.system(size: 13))
        .padding(20)
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}
