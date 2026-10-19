import AppKit
import SwiftUI
import UserNotifications

/// Entry point: a window-style menu bar extra plus the Settings scene.
@main
struct HogCatcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = HogMonitor.shared

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(monitor)
        } label: {
            Image(nsImage: FlameIcon.image(active: !monitor.activeHogs.isEmpty))
                .accessibilityLabel(monitor.activeHogs.isEmpty ? "HogCatcher: calm" : "HogCatcher: hog detected")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(monitor)
        }
    }
}

/// Builds the menu bar flame: a template (gray) glyph when calm, orange when a hog is active.
enum FlameIcon {
    static func image(active: Bool) -> NSImage {
        let base = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "HogCatcher") ?? NSImage()
        guard active else {
            base.isTemplate = true
            return base
        }
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
        let tinted = base.withSymbolConfiguration(config) ?? base
        tinted.isTemplate = false
        return tinted
    }
}

/// Starts monitoring, registers notification actions and routes their responses.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private enum Action {
        static let quit = "QUIT"
        static let ignore = "IGNORE_TODAY"
        static let never = "NEVER_WARN"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let quit = UNNotificationAction(identifier: Action.quit, title: "Quit App", options: [.destructive])
        let ignore = UNNotificationAction(identifier: Action.ignore, title: "Ignore for Today")
        let never = UNNotificationAction(identifier: Action.never, title: "Never Warn")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: HogMonitor.category, actions: [quit, ignore, never],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: HogMonitor.infoCategory, actions: [ignore, never],
                                   intentIdentifiers: []),
        ])
        Task { @MainActor in
            let monitor = HogMonitor.shared
            if UserDefaults.standard.bool(forKey: Prefs.notifications) { monitor.requestNotificationPermission() }
            monitor.start()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        guard let key = info["key"] as? String else { completionHandler(); return }
        let name = info["name"] as? String ?? key
        let pid = (info["pid"] as? Int).map { pid_t($0) }
        Task { @MainActor in
            let monitor = HogMonitor.shared
            switch action {
            case Action.quit: if let pid { monitor.quit(pid: pid, name: name) }
            case Action.ignore: monitor.ignoreToday(key: key)
            case Action.never: monitor.allow(key: key, name: name)
            default: break
            }
            completionHandler()
        }
    }
}
