import AppKit

@MainActor final class AgentQuestionAutoSkip {
    struct Request: Equatable {
        let taskID: String, approvalID: String, callID: String, signature: String
        let interacted: Bool
    }
    private struct Waiting {
        var request: Request, focused: Bool, since: TimeInterval, cancelled = false
    }
    static let foregroundSeconds: TimeInterval = 150, backgroundSeconds: TimeInterval = 90
    private let runtime: AgentRuntime, enabled: () -> Bool, focused: (String) -> Bool, interaction: (NSEvent) -> [String], now: () -> TimeInterval
    private var waiting: [String: Waiting] = [:], timer: Timer?, monitor: Any?, refreshing = false
    init(runtime: AgentRuntime, enabled: @escaping () -> Bool, focused: @escaping (String) -> Bool, interaction: @escaping (NSEvent) -> [String], now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.runtime = runtime; self.enabled = enabled; self.focused = focused; self.interaction = interaction; self.now = now
    }
    static func request(_ task: AgentTaskRecord) -> Request? {
        guard !task.archived, task.kind != "hook", task.status == .waiting, task.queuedCount == 0,
              let call = task.pendingCalls.first, call.name == "ask_user",
              let approval = task.approvals.last(where: { $0.call.id == call.id && $0.decision == nil }),
              approval.call.name == call.name, approval.call.arguments == call.arguments,
              approval.workspace == task.workspace, approval.gitDirectory == nil else { return nil }
        return Request(taskID: task.id, approvalID: approval.id, callID: call.id, signature: AgentAttentionItem.requestSignature(approval), interacted: approval.autoSkipCancelled == true)
    }
    static func containsInteraction(_ event: NSEvent, views: [NSView]) -> Bool {
        guard let window = event.window, let content = window.contentView else { return false }
        let target = event.type == .keyDown ? window.firstResponder as? NSView : content.hitTest(content.convert(event.locationInWindow, from: nil))
        guard let target else { return false }
        return views.contains { $0.window === window && !$0.isHiddenOrHasHiddenAncestor && (target === $0 || target.isDescendant(of: $0)) }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        waiting.removeAll()
    }
    func refresh() {
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
        guard enabled() else { stop(); return }
        let time = now(), requests = runtime.store.tasks.filter { $0.status == .waiting && !$0.archived }.compactMap { runtime.store.task($0.id).flatMap(Self.request) }
        let ids = Set(requests.map(\.approvalID)); waiting = waiting.filter { ids.contains($0.key) }
        for request in requests {
            let front = focused(request.taskID)
            var value = waiting[request.approvalID] ?? Waiting(request: request, focused: front, since: time)
            if value.request != request { value = Waiting(request: request, focused: front, since: time) }
            if value.focused != front { value.focused = front; value.since = time }
            value.cancelled = value.cancelled || request.interacted
            if !value.cancelled, time - value.since >= (front ? Self.foregroundSeconds : Self.backgroundSeconds) {
                value.cancelled = true; waiting[request.approvalID] = value
                _ = runtime.skipQuestion(request)
            }
            waiting[request.approvalID] = value
        }
        if waiting.values.contains(where: { !$0.cancelled }) {
            if timer == nil {
                let value = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
                RunLoop.main.add(value, forMode: .common); timer = value
            }
            if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
                    if let self { activity(interactingWith: interaction(event)) }; return event
                }
            }
        } else {
            timer?.invalidate(); timer = nil
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
    }
    func activity(interactingWith taskIDs: [String]) {
        let time = now()
        for id in taskIDs { runtime.questionInteraction(id) }
        for (id, var value) in waiting where focused(value.request.taskID) { value.since = time; waiting[id] = value }
        refresh()
    }
    func readback() -> [String: Any] {
        ["enabled": enabled(), "timerRunning": timer?.isValid == true, "localMonitor": monitor != nil,
         "foregroundSeconds": Self.foregroundSeconds, "backgroundSeconds": Self.backgroundSeconds,
         "waiting": waiting.values.sorted { $0.request.taskID < $1.request.taskID }.map { value in
             ["taskID": value.request.taskID, "approvalID": value.request.approvalID, "focused": value.focused, "cancelled": value.cancelled,
              "elapsed": max(0, now() - value.since), "limit": value.focused ? Self.foregroundSeconds : Self.backgroundSeconds] as [String: Any]
         }]
    }
}
