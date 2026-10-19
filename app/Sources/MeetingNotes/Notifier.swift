import AppKit
import UserNotifications

/// User notifications: meeting detected (with a "Start recording" action), notes ready, failures.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let meetingCategory = "MEETING_DETECTED"
    static let startAction = "START_RECORDING"
    static let notesCategory = "NOTES_READY"
    static let meetingRequestID = "meeting-detected"

    /// Called on the main queue with the detected app name.
    var onStartRecording: ((String?) -> Void)?
    private(set) var isAuthorized = false

    private var center: UNUserNotificationCenter? { AppInfo.isBundled ? .current() : nil }

    func setup() {
        guard let center else { return }
        center.delegate = self
        let start = UNNotificationAction(identifier: Self.startAction, title: "Start recording", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.meetingCategory, actions: [start], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.notesCategory, actions: [], intentIdentifiers: [], options: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { self.isAuthorized = granted }
        }
    }

    func meetingDetected(appName: String) {
        post(id: Self.meetingRequestID, title: "Meeting detected — start recording?",
             body: "\(appName) is using the microphone.", category: Self.meetingCategory, info: ["app": appName])
    }

    func clearMeetingDetected() {
        center?.removeDeliveredNotifications(withIdentifiers: [Self.meetingRequestID])
        center?.removePendingNotificationRequests(withIdentifiers: [Self.meetingRequestID])
    }

    func notesReady(title: String, notesPath: String) {
        post(id: UUID().uuidString, title: "Notes ready: \(title)", body: "Click to open the notes.",
             category: Self.notesCategory, info: ["notes": notesPath])
    }

    func failure(title: String, message: String) {
        post(id: UUID().uuidString, title: title, body: String(message.prefix(200)), category: nil, info: [:])
    }

    private func post(id: String, title: String, body: String, category: String?, info: [String: String]) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = info
        if let category { content.categoryIdentifier = category }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let action = response.actionIdentifier
        let app = content.userInfo["app"] as? String
        let notes = content.userInfo["notes"] as? String
        let isMeeting = content.categoryIdentifier == Self.meetingCategory
        DispatchQueue.main.async {
            if isMeeting, action == Self.startAction {
                self.onStartRecording?(app)
            } else if let notes, action == UNNotificationDefaultActionIdentifier {
                NSWorkspace.shared.open(URL(fileURLWithPath: notes))
            }
        }
        completionHandler()
    }
}
