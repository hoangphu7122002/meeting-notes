import AppKit
import UserNotifications

/// Optional "Notes ready" notifications. Never asks for permission by itself (onboarding does).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let notesCategory = "NOTES_READY"

    /// Called on the main queue with the meeting folder when a "Notes ready" notification is clicked.
    var onOpenNotes: ((URL) -> Void)?

    private var center: UNUserNotificationCenter? { AppInfo.isBundled ? .current() : nil }

    func setup() {
        guard let center else { return }
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.notesCategory, actions: [], intentIdentifiers: [], options: []),
        ])
    }

    /// Main-queue callback with the current authorization status (nil when unavailable, e.g. unbundled).
    func status(_ completion: @escaping (UNAuthorizationStatus?) -> Void) {
        guard let center else {
            completion(nil)
            return
        }
        center.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async { completion(status) }
        }
    }

    func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        guard let center else {
            completion(false)
            return
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func notesReady(title: String, folder: URL) {
        guard let center else { return }
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "Notes ready: \(title)"
            content.body = "Click to open the notes."
            content.userInfo = ["folder": folder.path]
            content.categoryIdentifier = Self.notesCategory
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let folder = response.notification.request.content.userInfo["folder"] as? String
        if let folder, response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async { self.onOpenNotes?(URL(fileURLWithPath: folder, isDirectory: true)) }
        }
        completionHandler()
    }
}
