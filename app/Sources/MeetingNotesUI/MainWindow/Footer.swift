// Main window footer buttons (MainWindow).

import SwiftUI
import MeetingNotesCore

struct Footer: View {
    @ObservedObject var state: AppState
    let commands: any AppCommands

    var body: some View {
        HStack(spacing: 10) {
            Button { commands.showSettings() } label: { Label(tr(.actionSettingsEllipsis), systemImage: "gearshape") }
            Button { commands.openNotesFolder() } label: { Label(tr(.notesFolder), systemImage: "folder") }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }
}
