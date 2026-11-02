import AppKit
import UserNotifications

/// `menuhub://` commands for the helper scripts in ~/.local/bin:
///   menuhub://refresh                          re-read disk and VPN state now
///   menuhub://notify?title=…&body=…&href=…     notification; clicking opens href
final class URLCommands: NSObject, UNUserNotificationCenterDelegate {
    static let shared = URLCommands()

    func start() {
        UNUserNotificationCenter.current().delegate = self
    }

    func handle(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        switch url.host {
        case "refresh":
            StorageModel.shared.refresh()
            VPNModel.shared.refresh()
            // Connect/disconnect takes a few seconds to land in the VPN logs.
            for delay in [3.0, 8.0, 15.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { VPNModel.shared.refresh() }
            }
        case "notify":
            notify(title: value("title") ?? "MenuHub", body: value("body") ?? "", href: value("href"))
        default:
            break
        }
    }

    private func notify(title: String, body: String, href: String?) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if let href { content.userInfo = ["href": href] }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let href = response.notification.request.content.userInfo["href"] as? String, let url = URL(string: href) {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }
}
