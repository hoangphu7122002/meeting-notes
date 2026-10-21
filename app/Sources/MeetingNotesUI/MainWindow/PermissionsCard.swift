// Main window permissions list and the 5 s audio check (MainWindow).

import MeetingNotesCore
import SwiftUI

struct PermissionsCard: View {
    @ObservedObject var state: AppState
    let commands: any AppCommands

    var body: some View {
        SectionCard(tr(.permissionsHeading)) {
            PermissionRow(title: tr(.microphone), detail: tr(.micDetail), status: state.microphone) {
                commands.fixPermission(.microphone)
            }
            Divider()
            PermissionRow(title: tr(.systemAudio), detail: tr(.systemAudioDetail), status: state.screenCapture) {
                commands.fixPermission(.screenCapture)
            }
            Divider()
            PermissionRow(title: tr(.notificationsOptional), detail: tr(.notificationsDetail), status: state.notifications,
                          optional: true) {
                commands.fixPermission(.notifications)
            }
            Divider()
            AudioTestRow(state: state, commands: commands)
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let status: PermissionStatus
    var optional = false
    let fix: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 17)).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                Text(status.label()).font(.system(size: 12, weight: .medium)).foregroundStyle(color)
            }
            Spacer(minLength: 8)
            if status == .notDetermined {
                Button(tr(.actionAllow), action: fix)
            } else if status == .denied {
                Button(tr(.actionFix), action: fix)
            }
        }
    }

    private var icon: String {
        switch status {
        case .granted: return "checkmark.circle.fill"
        case .unavailable: return "minus.circle"
        default: return optional ? "circle.dashed" : "exclamationmark.circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .granted: return Palette.ok
        case .unavailable: return Palette.secondary
        default: return optional ? Palette.secondary : Palette.warning
        }
    }
}

struct AudioTestRow: View {
    @ObservedObject var state: AppState
    let commands: any AppCommands

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Palette.secondary).font(.system(size: 15)).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr(.audioTestHeading)).font(.system(size: 13, weight: .semibold))
                    Text(tr(.audioTestHint)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(state.audioTest.running ? tr(.actionTesting) : tr(.actionRunTest)) { commands.runAudioTest() }
                    .disabled(state.audioTest.running || state.isCapturing)
            }
            if state.audioTest.running {
                VStack(spacing: 6) {
                    TestMeter(label: tr(.me), value: state.audioTest.me)
                    TestMeter(label: tr(.them), value: state.audioTest.them)
                }
                .padding(.leading, 30)
            }
            ForEach(state.audioTest.result, id: \.self) { line in
                Text(line).padding(.leading, 30).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct TestMeter: View {
    let label: String
    let value: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 90, alignment: .leading)
            MeterBar(value: value, height: 8)
        }
    }
}
