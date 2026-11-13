import AppKit
import UserNotifications

@MainActor final class AgentAutomationNotifications: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String) -> Void)?
    var preferences: () -> AgentGeneralSettings.Settings = { .init() }
    var isTaskFocused: (String) -> Bool = { _ in NSApp.isActive }
    var taskRecord: ((String) -> AgentTaskRecord?)?
    var allowsSystemDelivery = true
    var postForCheck: ((UNNotificationRequest) -> Void)?
    private var seenRequests = Set<String>(), seenCompletions: [String: String] = [:]
    private var posted: [String] = [], openedTask: String?
    override init() { super.init(); UNUserNotificationCenter.current().delegate = self }
    func request() async throws -> Bool {
        guard allowsSystemDelivery else { throw PetError("独立验收模式未启用系统通知") }
        return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    private func send(_ id: String, title: String, body: String, taskID: String?, eligible: () -> Bool = { true }) async throws {
        guard eligible() else { return }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
        if let taskID { content.userInfo["task_id"] = taskID }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        if CommandLine.arguments.contains("--general-settings-check"), let postForCheck { postForCheck(request); return }
        guard allowsSystemDelivery else { throw PetError("独立验收模式未启用系统通知") }
        let center = UNUserNotificationCenter.current(), settings = await center.notificationSettings()
        guard [.authorized, .provisional].contains(settings.authorizationStatus) else { throw PetError("请先允许系统通知") }
        guard eligible() else { return }; try await center.add(request)
        if CommandLine.arguments.contains("--manual-ui") { posted.append(id); posted = Array(posted.suffix(32)) }
    }
    private func enqueue(_ id: String, title: String, body: String, taskID: String?, eligible: @escaping () -> Bool) {
        Task { try? await send(id, title: title, body: body, taskID: taskID, eligible: eligible) }
    }
    func completed(_ task: AgentTaskRecord) {
        guard !task.archived, task.status == .completed, task.agent?.ownerID == nil, task.automation == nil, task.kind != "hook",
              let message = task.messages.last(where: { $0.role == "assistant" && !$0.content.isEmpty }), seenCompletions[task.id] != message.id else { return }
        seenCompletions[task.id] = message.id
        enqueue("completion." + task.id + "." + message.id, title: task.title, body: "本轮已完成", taskID: task.id) { [weak self] in
            guard let self else { return false }
            if let taskRecord { guard let current = taskRecord(task.id), !current.archived, current.status == .completed, current.messages.last(where: { $0.role == "assistant" && !$0.content.isEmpty })?.id == message.id else { return false } }
            return preferences().completionNotifications.allows(focused: isTaskFocused(task.id))
        }
    }
    func pending(_ task: AgentTaskRecord) {
        guard !task.archived, task.status == .waiting, task.kind != "hook", let call = task.pendingCalls.first,
              let approval = task.approvals.last(where: { $0.decision == nil && $0.call.id == call.id && $0.call.arguments == call.arguments && $0.workspace == task.workspace }) else { return }
        let question = call.name == "ask_user"
        notifyRequest(task, key: approval.id, question: question) { [weak self] in
            guard let record = self?.taskRecord?(task.id) else { return self?.taskRecord == nil }
            return !record.archived && record.status == .waiting && record.pendingCalls.first?.id == call.id && record.approvals.contains { $0.id == approval.id && $0.decision == nil }
        }
    }
    func question(_ task: AgentTaskRecord, requestID: String, isCurrent: @escaping () -> Bool) { notifyRequest(task, key: "mcp." + requestID, question: true, isCurrent: isCurrent) }
    private func notifyRequest(_ task: AgentTaskRecord, key: String, question: Bool, isCurrent: @escaping () -> Bool) {
        guard !task.archived, seenRequests.insert(task.id + "." + key).inserted else { return }
        enqueue("request." + task.id + "." + key, title: task.title, body: question ? "等待你回答问题" : "需要你批准操作", taskID: task.id) { [weak self] in
            guard let self else { return false }; return (question ? preferences().questionNotifications : preferences().approvalNotifications) && isCurrent()
        }
    }
    func post(_ run: AgentAutomationRun) {
        enqueue(run.id + "." + run.status.rawValue, title: run.name, body: run.status.title + (run.detail.isEmpty ? "" : " · " + String(run.detail.prefix(120))), taskID: run.taskID) { [weak self] in
            guard let self else { return false }; return preferences().completionNotifications.allows(focused: run.taskID.map(isTaskFocused) ?? false)
        }
    }
    func test(taskID: String?) async throws { try await send("test." + UUID().uuidString, title: "小鲸", body: "通知已就绪", taskID: taskID) }
    func verificationReadback() async -> [String: Any] {
        guard ["--general-settings-check", "--manual-ui"].contains(where: CommandLine.arguments.contains) else { return [:] }
        let center = UNUserNotificationCenter.current(), authorization = await center.notificationSettings().authorizationStatus
        let delivered = await center.deliveredNotifications()
        return ["authorization": authorization.rawValue, "systemDeliveryEnabled": allowsSystemDelivery, "postedIDs": posted, "openedTaskID": openedTask ?? "", "delivered": delivered.map { ["id": $0.request.identifier, "taskID": $0.request.content.userInfo["task_id"] as? String ?? "", "title": $0.request.content.title] }]
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .list, .sound]) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["task_id"] as? String
        Task { @MainActor [weak self] in if let id { self?.openedTask = id; self?.onOpen?(id) }; completionHandler() }
    }
}
