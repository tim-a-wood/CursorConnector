import UIKit
import UserNotifications

/// Handles background URLSession completion and notification presentation (including in foreground).
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
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

    // MARK: - UNUserNotificationCenterDelegate

    /// Show notifications even when the app is in the foreground (banner + sound + badge).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .list, .sound, .badge])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }
}

// MARK: - Agent completion notification

extension AppDelegate {
    /// Schedules a local notification when a Cursor agent request completes.
    /// When `fromBackgroundSession` is true (completion delivered by background URLSession delegate, e.g. after app was suspended or relaunched), always notifies including for cancellation (-999), since that may be due to suspend rather than user cancel.
    /// When false, skips notification for cancellation (-999) to avoid spurious "Request failed" when the user cancelled in-app.
    static func notifyAgentRequestComplete(error: Error?, fromBackgroundSession: Bool = false) {
        if !fromBackgroundSession, let error = error, Self.isCancelledError(error) {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Cursor Agent"
        if let err = error {
            content.body = Self.isCancelledError(err)
                ? "Request was interrupted while the app was in the background."
                : "Request failed: \(err.localizedDescription)"
        } else {
            content.body = "Request complete."
        }
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Returns true for NSURLErrorCancelled (-999); used to avoid showing cancellation as a failure in UI and to skip completion notifications.
    static func isCancelledError(_ error: Error) -> Bool {
        if (error as NSError).code == NSURLErrorCancelled { return true }
        if (error as? URLError)?.code == .cancelled { return true }
        return false
    }

    /// Schedules a local notification when a TestFlight upload completes. Call after buildAndUploadTestFlight succeeds.
    static func notifyTestFlightUploadComplete(buildNumber: String?) {
        let content = UNMutableNotificationContent()
        content.title = "TestFlight"
        let buildLabel = buildNumber.map { "Build \($0) " } ?? ""
        content.body = "\(buildLabel)uploaded to App Store Connect. Processing usually takes 5–30 minutes; then install from the TestFlight app."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "testflight-upload-\(buildNumber ?? UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }
}
