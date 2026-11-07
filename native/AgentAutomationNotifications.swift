import AppKit
import UserNotifications

@MainActor final class AgentAutomationNotifications: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String) -> Void)?
    override init() { super.init(); UNUserNotificationCenter.current().delegate = self }
    func request() async throws -> Bool { try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    func post(_ run: AgentAutomationRun) {
        Task {
            let center = UNUserNotificationCenter.current(), settings = await center.notificationSettings()
            guard [.authorized, .provisional].contains(settings.authorizationStatus) else { return }
            let content = UNMutableNotificationContent(); content.title = run.name; content.body = run.status.title + (run.detail.isEmpty ? "" : " · " + String(run.detail.prefix(120)))
            if let task = run.taskID { content.userInfo["task_id"] = task }; content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: run.id + "." + run.status.rawValue, content: content, trigger: nil))
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .list, .sound]) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["task_id"] as? String
        Task { @MainActor [weak self] in if let id { self?.onOpen?(id) }; completionHandler() }
    }
}
