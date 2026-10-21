// Launch-at-login toggle over SMAppService (Settings).

import Foundation
import MeetingNotesCore
import ServiceManagement

public enum LoginItem {
    public static var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    public static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return tr(.loginEnabled)
        case .requiresApproval: return tr(.loginNeedsApproval)
        case .notRegistered: return tr(.loginOff)
        case .notFound: return tr(.loginUnavailable)
        @unknown default: return tr(.loginUnknown)
        }
    }

    public static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
