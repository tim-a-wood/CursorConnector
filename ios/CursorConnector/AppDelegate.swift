import UIKit
import UserNotifications

/// Handles background URLSession completion so the system can snapshot the app after we process prompt-stream events.
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        requestNotificationPermission()
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == "com.cursorconnector.prompt-stream" else {
            completionHandler()
            return
        }
        CompanionAPI.backgroundSessionCompletionHandler = completionHandler
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
}

// MARK: - Agent completion notification

extension AppDelegate {
    /// Schedules a local notification when a Cursor agent request completes. Call from the stream's onComplete callback.
    static func notifyAgentRequestComplete(error: Error?) {
        let content = UNMutableNotificationContent()
        content.title = "Cursor Agent"
        content.body = error == nil
            ? "Request complete."
            : "Request failed: \(error!.localizedDescription)"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }
}
