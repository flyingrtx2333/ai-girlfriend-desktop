import Foundation

enum AgentVoiceCommand: Equatable {
    case newTask(draft: String)
    case stopTask

    static let phrases = ["新建任务", "创建任务", "停止当前任务", "中断当前任务", "取消当前任务"]

    static func parse(_ transcript: String) -> Self? {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let opening = #"^(?:(?:请|帮我|麻烦你|先|马上|立刻)\s*){0,3}"#
        let ending = #"(?:\s*(?:一下|吧|呀|啊|谢谢))?[。！!.]*$"#
        if text.range(of: opening + #"(?:停止|中断|取消)(?:当前|这[个项])?任务"# + ending, options: .regularExpression) != nil {
            return .stopTask
        }
        let create = opening + #"(?:新建|创建)(?:一个)?(?:新)?任务"#
        if text.range(of: create + ending, options: .regularExpression) != nil { return .newTask(draft: "") }
        let details = #"\s*(?:[,，:：]\s*(?:内容是\s*[:：]?\s*)?|内容是\s*[:：]?\s*)"#
        guard let prefix = text.range(of: create + details, options: .regularExpression) else { return nil }
        let draft = String(text[prefix.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return draft.isEmpty ? nil : .newTask(draft: draft)
    }
}

struct AgentVoiceTarget {
    weak var window: ControlWindow?
    let taskID: String?
}

@MainActor extension AppDelegate {
    func rememberAgentVoiceTarget() {
        guard usesAgent else { return }
        let owner = inputControl
        agentVoiceTarget = AgentVoiceTarget(window: owner, taskID: owner.agentTaskID)
    }

    func handleAgentVoice(_ text: String) {
        let target = agentVoiceTarget
        agentVoiceTarget = nil
        let command = AgentVoiceCommand.parse(text)
        if let target, let owner = target.window, owner === inputControl, owner.agentTaskID == target.taskID {
            switch command {
            case .newTask(let draft):
                voiceWake.resetConversation()
                if owner.createAgentTask(draft: draft.isEmpty ? nil : draft) {
                    if owner.sideTaskTabID == nil { owner.show(tab: "chat") }
                    showBubble(draft.isEmpty ? "已新建任务" : "已新建任务，草稿待发送", duration: 2.5)
                } else { showBubble("新建任务未完成，请检查当前窗口", duration: 2.5) }
                return
            case .stopTask:
                voiceWake.resetConversation()
                guard let id = target.taskID, let runtime = agentRuntime, let task = runtime.store.task(id), !task.archived,
                      runtime.isBusy(id) || task.status == .waiting || task.queuedRun != nil else {
                    showBubble("当前任务未在执行", duration: 2.5)
                    return
                }
                cancelConversation(taskID: id, userInterrupt: true)
                showBubble("已中断任务", duration: 2.5)
                return
            case nil:
                if let id = target.taskID, agentRuntime?.isRunning(id) != true, send(text, taskID: id) { return }
            }
        }
        voiceWake.resetConversation()
        if command != nil {
            showBubble("任务窗口已变化，请重新说出指令", duration: 2.5)
        } else {
            let saved = keepAgentVoiceDraft(text, taskID: target?.taskID)
            showBubble(saved ? "语音已加入原任务草稿" : "语音草稿未保存，请重试", duration: 2.5)
        }
    }

    @discardableResult func keepAgentVoiceDraft(_ text: String, taskID: String?) -> Bool {
        guard let id = taskID, let tasks = agentStore, let record = tasks.task(id), !record.archived, record.kind != "hook" else { return false }
        if let owner = taskControls.first(where: { $0.voiceDraftTaskID == id }) { return owner.keepInterruptedVoiceDraft(text) }
        let draft = [record.draft ?? "", text].filter { !$0.isEmpty }.joined(separator: "\n")
        tasks.update(id, persist: false) { $0.draft = draft }
        guard tasks.task(id)?.draft == draft else { return false }
        do { try tasks.save(id); return true }
        catch { return false }
    }
}
