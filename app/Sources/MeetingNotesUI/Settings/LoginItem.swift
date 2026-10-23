// Launch-at-login toggle over SMAppService (Settings).

import Foundation
import MeetingNotesCore
import ServiceManagement

public enum LoginItem {
    public static var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .off
        case .notFound: return .unavailable
        @unknown default: return .unknown
        }
    }

    public static var isEnabled: Bool { state.isOn }

    public static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// System Settings › General › Login Items (where a "needs approval" item is allowed).
    public static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
