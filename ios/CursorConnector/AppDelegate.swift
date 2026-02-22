import UIKit

/// Handles background URLSession completion so the system can snapshot the app after we process prompt-stream events.
class AppDelegate: NSObject, UIApplicationDelegate {
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
}
