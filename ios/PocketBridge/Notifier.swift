import UserNotifications

/// Local notifications for finished recordings and a low Pocket battery.
enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    static func recordingReady(_ recording: Recording) {
        let body = recording.summary.split(separator: "\n").first.map(String.init) ?? "Transcript ready."
        post(id: "recording-\(recording.id)", title: recording.title, body: body)
    }
}

/// Shows notifications while the app is open too.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
