// The app's notifications (Sankalp, 2 Nov 2026): a transcription or an export that ends, and the chat's Claude finishing
// what it was asked, each as a macOS notification with the project's title, shown even while the app is in front. A
// click on one brings that project's tab to the front. Turned off with Notifications in App settings. A build that is
// not inside an app bundle (swift build, the snapshot runs) sends none, since macOS only notifies for an app.
import AppKit
import ReelCore
import UserNotifications

@MainActor enum Notify {
  static let key = "notifications"
  static var on: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
  static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" && ProcessInfo.processInfo.environment["REEL_EDITOR_SNAPSHOT"] == nil }
  private static let delegate = NotifyDelegate()

  // Asks macOS once for leave to notify; afterwards System Settings, Notifications, Reel Editor holds the answer.
  static func setUp() {
    guard available else { return }
    let c = UNUserNotificationCenter.current()
    c.delegate = delegate
    c.requestAuthorization(options: [.alert, .sound]) { granted, _ in Log.write("app", "notifications", extra: ["granted": .bool(granted)]) }
  }

  static func send(_ title: String, _ body: String, project: String?) {
    guard available, on else { return }
    let c = UNMutableNotificationContent()
    c.title = title
    c.body = String(body.prefix(240))
    c.sound = .default
    if let project { c.userInfo = ["project": project] }
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
  }

  // A project's title as the tabs show it.
  static func title(_ project: String?) -> String { project.map { AppModel.shared.titles[$0] ?? $0 } ?? "Reel Editor" }
}

final class NotifyDelegate: NSObject, UNUserNotificationCenterDelegate {
  // Shown as a banner while the app is in front too: Claude finishing is worth seeing wherever Sankalp is looking.
  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
    done([.banner, .list, .sound])
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
    let project = response.notification.request.content.userInfo["project"] as? String
    Task { @MainActor in
      NSApp.activate(ignoringOtherApps: true)
      if let project { AppModel.shared.refresh(); if AppModel.shared.projects.contains(project) { AppModel.shared.open(project) } }
    }
    done()
  }
}
