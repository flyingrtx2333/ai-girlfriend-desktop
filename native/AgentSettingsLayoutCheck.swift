import AppKit

@MainActor private final class AgentSettingsScrollCheckDocument: NSView {
    let documentFlipped: Bool
    init(_ height: CGFloat, flipped: Bool = true) { documentFlipped = flipped; super.init(frame: NSRect(x: 0, y: 0, width: 200, height: height)) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { documentFlipped }
}

@MainActor private func checkSettingsScrollChaining() -> [String: Bool] {
    let outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 200)), document = AgentSettingsScrollCheckDocument(600)
    document.setFrameSize(NSSize(width: 500, height: 600)); outer.documentView = document
    let inner = NSScrollView(frame: NSRect(x: 10, y: 10, width: 200, height: 100)), rows = AgentSettingsScrollCheckDocument(100)
    document.addSubview(inner); inner.documentView = rows
    func move(_ scroll: NSScrollView, bottom: Bool) {
        let bounds = scroll.documentView!.bounds
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom ? bounds.maxY - scroll.documentVisibleRect.height : bounds.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    func target(_ dy: CGFloat, dx: CGFloat = 0, modifiers: NSEvent.ModifierFlags = [], hit: NSView? = nil) -> NSScrollView? {
        AgentSettingsScroll.target(from: hit ?? rows, within: outer, dx: dx, dy: dy, modifiers: modifiers)
    }
    var checks: [String: Bool] = [:]
    checks["shortNestedListHandsDownwardWheelToSettings"] = target(-40) === outer
    move(outer, bottom: true)
    checks["shortNestedListHandsUpwardWheelToSettings"] = target(40) === outer
    rows.setFrameSize(NSSize(width: 200, height: 600)); move(inner, bottom: false)
    checks["longNestedListKeepsAvailableDownwardWheel"] = target(-40) == nil
    checks["longNestedListAtTopHandsUpwardWheelToSettings"] = target(40) === outer
    move(outer, bottom: false); move(inner, bottom: true)
    checks["longNestedListAtBottomHandsDownwardWheelToSettings"] = target(-40) === outer
    checks["longNestedListKeepsAvailableReverseWheel"] = target(40) == nil
    move(outer, bottom: true)
    checks["allScrollViewsAtBoundaryKeepNativeEvent"] = target(-40) == nil
    move(outer, bottom: false)
    checks["modifiedWheelKeepsNativeControlBehavior"] = [NSEvent.ModifierFlags.shift, .control, .option, .command].allSatisfy { target(-40, modifiers: $0) == nil }
    checks["horizontalAndZeroWheelKeepNativeBehavior"] = target(-40, dx: 50) == nil && target(0) == nil
    let slider = NSSlider(); rows.addSubview(slider)
    checks["valueControlKeepsItsWheelEvent"] = target(-40, hit: slider) == nil
    checks["wheelOutsideSettingsIsNotRouted"] = target(-40, hit: NSView()) == nil
    let unflipped = AgentSettingsScrollCheckDocument(600, flipped: false); inner.documentView = unflipped
    move(inner, bottom: false)
    let first = target(-40, hit: unflipped) === outer && target(40, hit: unflipped) == nil
    move(outer, bottom: true); move(inner, bottom: true)
    checks["unflippedDocumentUsesItsNativeCoordinateDirection"] = first && target(40, hit: unflipped) === outer && target(-40, hit: unflipped) == nil
    return checks
}

@MainActor extension AppDelegate {
    func prepareSettingsLayoutUI(_ output: URL, tasks: AgentStore, runtime: AgentRuntime, taskID: String) throws {
        guard let workspace = tasks.task(taskID)?.workspace else { throw PetError("缺少设置布局验收项目") }
        func handler(_ name: String, _ command: String = "/usr/bin/true") -> [String: Any] { ["name": name, "type": "command", "command": command, "args": []] }
        let global: [String: Any] = ["hooks": [
            "SessionStart": [["hooks": [handler("会话准备")]]],
            "SubagentStart": [["hooks": [handler("子任务记录")]]],
            "UserPromptSubmit": [["hooks": [handler("提示词记录")]]],
            "PostToolUse": [["matcher": "Read", "hooks": [handler("用户工具记录")]]],
            "Stop": [["hooks": [handler("响应校验"), handler("响应完成记录")]]]
        ]]
        let project: [String: Any] = ["hooks": ["PostToolUse": [["matcher": "Edit|Write", "hooks": [handler("项目工具记录")]]]]]
        for (isProject, value) in [(false, global), (true, project)] {
            let current = try tasks.hooks.document(project: isProject, workspace: workspace)
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            try tasks.hooks.save(String(decoding: data, as: UTF8.self), project: isProject, workspace: workspace, expectedHash: current.1)
        }
        guard let home = tasks.hooks.sharedHome else { throw PetError("缺少独立共享配置目录") }
        let shared: [String: Any] = ["hooks": ["SessionStart": [["hooks": [handler("共享会话目录", "/usr/bin/pwd")]]]]]
        let files = try AgentFiles(workspace: home.path), file = try files.resolve(".qoder/settings.json")
        guard !FileManager.default.fileExists(atPath: file.path) else { throw PetError("共享验收配置已存在") }
        try files.writeData(JSONSerialization.data(withJSONObject: shared, options: [.prettyPrinted, .sortedKeys]), to: file, permissions: 0o600)
        let hooks = try tasks.hooks.catalog(workspace: workspace)
        guard hooks.count == 8, Set(hooks.map(\.event)).count == 5, hooks.allSatisfy({ !tasks.hooks.enabled($0) && $0.diagnostic == nil }) else { throw PetError("公开 Hooks 示例未正确载入或存在已启用处理器") }
        guard runtime.submit("这是设置布局验收的公开用户消息，未调用模型。", taskID: taskID, startImmediately: false) else { throw PetError(runtime.submissionError ?? "用户消息未保存") }
        tasks.update(taskID) { $0.draft = "设置布局验收的未发送草稿。" }
        let result: [String: Any] = ["taskID": taskID, "workspace": workspace, "handlers": hooks.map { ["id": $0.id, "event": $0.event.rawValue, "name": $0.name, "scope": $0.scope, "source": $0.source] }, "modelRequests": 0]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("settings-layout-fixtures.json"))
    }

    func runSettingsLayoutCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        do {
            ensureAgent()
            guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("缺少独立任务存储") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("设置布局验收禁止模型请求") }
            let id = try await prepareSettingsPagesCheck(output, tasks: tasks)
            try prepareSettingsLayoutUI(output, tasks: tasks, runtime: runtime, taskID: id)
            control.showAgentTask(id)
            func fingerprints() throws -> [String: String] {
                var result: [String: String] = [:]
                let roots = [store.directory, URL(fileURLWithPath: tasks.task(id)!.workspace!)] + (tasks.hooks.sharedHome.map { [$0] } ?? [])
                for root in roots {
                    let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
                    while let file = files?.nextObject() as? URL {
                        if (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true { result[file.path] = AgentFiles.hash(try Data(contentsOf: file)) }
                    }
                }
                return result
            }
            let before = try fingerprints(), layout = await control.checkSettingsPageLayout()
            checks.merge(layout["checks"] as? [String: Bool] ?? [:]) { _, next in next }; report["frames"] = layout["frames"]
            checks.merge(checkSettingsScrollChaining()) { _, next in next }
            let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 764, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            let page = AgentSettingsPageHost(); host.contentView = page
            let manager = AgentHookWindow(service: tasks.hooks, workspace: tasks.task(id)?.workspace)
            guard page.show(category: "hooks", identity: id, scope: "设置项目", make: { _ in manager }) else { throw PetError("分组页面未载入") }
            host.contentView?.layoutSubtreeIfNeeded()
            checks.merge(try manager.checkGroupedPresentation()) { _, next in next }
            checks["hookGroupsRemainInSettingsHost"] = manager.presentingWindow === host && manager.pageContentView?.window === host && manager.window?.isVisible == false
            checks["groupedPageCanLeaveNormally"] = page.leave()
            checks["browsingPagesPreservesAllStoredFiles"] = try fingerprints() == before
            checks["publicUserMessageHasNoAssistantOrUsage"] = tasks.task(id)?.messages.count == 1 && tasks.task(id)?.messages.first?.role == "user" && tasks.task(id)?.inputTokens == 0 && tasks.task(id)?.outputTokens == 0
            report["success"] = checks.count == 59 && checks.values.allSatisfy { $0 }
        } catch { report["error"] = error.localizedDescription; report["success"] = false }
        report["checks"] = checks; report["modelRequests"] = requests; report["appPID"] = getpid()
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("settings-layout-report.json"))
    }
}
