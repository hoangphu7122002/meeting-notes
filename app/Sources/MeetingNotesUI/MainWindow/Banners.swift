// Main window banners: system audio problem and getting-started card (MainWindow).

import MeetingNotesCore
import SwiftUI

struct SystemAudioBanner: View {
    @ObservedObject var state: AppState
    let commands: any AppCommands

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Palette.warning)
            VStack(alignment: .leading, spacing: 8) {
                Text(tr(.systemAudioBanner))
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(tr(.relaunchNote)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(tr(.actionOpenSettings)) { commands.openPermissionSettings(.screenCapture) }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(nsColor: .systemOrange))
                    Button(tr(.actionRelaunch)) { commands.relaunch() }
                        .disabled(!state.canRelaunch)
                        .help(state.canRelaunch ? tr(.relaunchNote) : tr(.relaunchBlocked))
                }
                .controlSize(.regular)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.warning.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.warning.opacity(0.6), lineWidth: 1))
    }
}

struct GettingStartedCard: View {
    let commands: any AppCommands

    var body: some View {
        SectionCard(tr(.gettingStartedHeading)) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach([Tr.gettingStarted1, .gettingStarted2, .gettingStarted3], id: \.self) { key in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Palette.secondary)
                        Text(tr(key)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Spacer()
                Button(tr(.actionGotIt)) { commands.dismissGettingStarted() }
            }
        }
    }
}
