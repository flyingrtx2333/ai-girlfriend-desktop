import AppKit

@MainActor extension AppDelegate {
    func runMCPWorkspaceCheck(_ output: URL, taskID: String, serverID: String) async throws -> [String: Bool] {
        guard !CommandLine.arguments.contains("--live-agent"), let tasks = agentStore, let runtime = agentRuntime else { throw PetError("MCP 工作区检查不调用模型") }
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        runtime.modelRequestCheck = { requests += 1; throw PetError("MCP 工作区检查禁止模型请求") }
        func settled(_ page: AgentMCPContentWindow) async throws {
            let end = Date().addingTimeInterval(45)
            while page.hasPendingOperation && Date() < end { await wait(0.03) }
            guard !page.hasPendingOperation else { throw PetError("MCP 页面操作未结束") }
        }
        func state(_ page: AgentMCPContentWindow) -> [String: Any] { page.workspaceReadback() }
        func select(_ page: AgentMCPContentWindow, kind: Int, query: String) async throws {
            page.checkAction("", kind: kind); try await settled(page)
            page.checkAction("", query: query); try await settled(page)
            guard !(state(page)["rows"] as? [[String: Any]] ?? []).isEmpty else { throw PetError("官方服务器目录中未找到 " + query) }
            page.checkAction("", row: 0)
        }
        tasks.update(taskID) { $0.draft = "保留 MCP 任务输入。" }
        let other = tasks.create(title: "无工作区的 MCP 资料", mode: .agent, workMode: .general)
        tasks.update(other) { $0.draft = "保留另一任务输入。" }
        try JSONSerialization.data(withJSONObject: ["taskID": taskID, "otherID": other, "serverID": serverID], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("mcp-workspace-fixtures.json"))
        control.showAgentTask(taskID); control.show(tab: "chat"); control.presentMCPContent(taskID: taskID, serverID: serverID)
        let host = control.taskWorkspace
        guard let page = host.currentController as? AgentMCPContentWindow else { throw PetError("MCP 资料未进入任务工作区") }
        checks["catalogUsesOriginalTaskWindow"] = host.selectedRoot == .mcpContent && page.presentingWindow === control.window && page.window?.isVisible == false
        checks["firstEntryFocusBelongsToVisiblePage"] = state(page)["focusInPage"] as? Bool == true
        page.checkAction("connect"); try await settled(page)
        checks["actualSessionConnected"] = state(page)["connected"] as? Bool == true
        try await select(page, kind: 0, query: "architecture.md"); page.checkAction("read"); try await settled(page)
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("fixtures.json"))) as! [String: Any]
        let document = try String(contentsOfFile: fixture["documentFile"] as! String, encoding: .utf8)
        checks["completeInstalledDocumentInPreview"] = (state(page)["previewText"] as? String)?.contains(document) == true
        checks["completedReadKeepsKeyboardInPage"] = state(page)["focusInPage"] as? Bool == true
        page.checkAction("focus-preview"); page.checkAction("read"); try await settled(page)
        checks["previewRereadDoesNotStealBodyFocus"] = state(page)["previewFocused"] as? Bool == true
        checks["readOnlyPreviewDoesNotMarkParametersDirty"] = !page.workspaceHasUnsavedChanges
        let sessionOwner = state(page)["sessionOwner"] as? String
        control.presentMCPContent(taskID: taskID, serverID: serverID)
        checks["reentryKeepsPageSessionAndPreview"] = host.currentController === page && state(page)["sessionOwner"] as? String == sessionOwner && (state(page)["previewText"] as? String)?.contains(document) == true

        for (appearance, theme) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            control.window?.appearance = NSAppearance(named: theme)
            for (name, size) in [("split", NSSize(width: 1200, height: 774)), ("narrow", NSSize(width: 800, height: 550))] {
                control.window?.setContentSize(size); control.window?.contentView?.layoutSubtreeIfNeeded(); page.pageDidLayout(); await wait(0.05); control.window?.contentView?.layoutSubtreeIfNeeded()
                let value = state(page); report[appearance + "-" + name] = value
                for (key, pass) in value["checks"] as? [String: Bool] ?? [:] { checks[appearance + "-" + name + "-" + key] = pass }
            }
        }
        control.window?.setContentSize(NSSize(width: 1200, height: 774)); control.window?.contentView?.layoutSubtreeIfNeeded()
        host.checkExpand(); await wait(0.05); control.window?.contentView?.layoutSubtreeIfNeeded(); page.pageDidLayout(); await wait(0.05)
        checks["expandedCatalogAndPreviewUseHorizontalLayout"] = state(page)["narrow"] as? Bool == false
        report["expanded"] = state(page); host.checkExpand()
        page.checkAction("add"); try await settled(page)
        checks["resourceAddedOnlyToOriginalTask"] = tasks.task(taskID)?.draft == "保留 MCP 任务输入。" && !(tasks.task(taskID)?.draftAttachmentIDs ?? []).isEmpty && tasks.task(other)?.draftAttachmentIDs?.isEmpty != false
        checks["completedAddKeepsKeyboardInPage"] = state(page)["focusInPage"] as? Bool == true

        try await select(page, kind: 1, query: "text")
        page.checkAction("", resourceURI: "demo://resource/dynamic/text/3")
        checks["editedTemplateURIIsProtected"] = page.workspaceHasUnsavedChanges
        try await select(page, kind: 0, query: "architecture.md")
        try await select(page, kind: 1, query: "text")
        checks["templateURIKeptAcrossCatalogSwitch"] = state(page)["uri"] as? String == "demo://resource/dynamic/text/3"
        page.checkAction("read"); try await settled(page)
        checks["actualExpandedTemplateResourceInPreview"] = (state(page)["previewText"] as? String)?.contains("Resource 3: This is a plaintext resource created at ") == true
        page.checkAction("add"); try await settled(page)
        checks["templateAddClearsParameterDraft"] = state(page)["inserted"] as? Bool == true && !page.workspaceHasUnsavedChanges

        try await select(page, kind: 2, query: "resource-prompt")
        page.checkAction("", values: ["resourceType": "Text", "resourceId": "2"])
        let arguments = state(page)["fields"] as? [String: String]
        checks["editedPromptParametersAreUnsaved"] = page.workspaceHasUnsavedChanges && arguments?["resourceId"] == "2"
        control.presentTaskContext(section: 0)
        checks["detailsUseExistingWorkspaceAlongsideMCP"] = host.selectedRoot == .context && (host.checkState()["roots"] as? [String])?.contains("mcp") == true
        control.presentMCPContent(taskID: taskID)
        checks["tabReturnKeepsUnsentParameters"] = host.currentController === page && state(page)["fields"] as? [String: String] == arguments
        try await select(page, kind: 0, query: "architecture.md")
        try await select(page, kind: 2, query: "resource-prompt")
        checks["catalogSwitchKeepsPerPromptParameters"] = state(page)["fields"] as? [String: String] == arguments && page.workspaceHasUnsavedChanges

        control.presentMCPContent(taskID: other, serverID: serverID)
        guard let second = host.currentController as? AgentMCPContentWindow else { throw PetError("无工作区页面未显示") }
        second.checkAction("connect"); try await settled(second)
        checks["noWorkspaceUsesIndependentActualSession"] = tasks.task(other)?.workspace == nil && second !== page && state(second)["connected"] as? Bool == true && state(second)["sessionOwner"] as? String != sessionOwner
        control.presentMCPContent(taskID: taskID)
        checks["taskReturnKeepsArgumentsConnectionAndInput"] = host.currentController === page && state(page)["fields"] as? [String: String] == arguments && state(page)["connected"] as? Bool == true && tasks.task(other)?.draft == "保留另一任务输入。"
        page.checkAction("read")
        checks["pendingPromptReadLocksParameters"] = page.hasPendingOperation && state(page)["parametersEditable"] as? Bool == false
        try await settled(page)
        checks["completedPromptReadRestoresParameters"] = state(page)["parametersEditable"] as? Bool == true
        checks["actualParameterizedPromptInPreview"] = (state(page)["previewText"] as? String)?.contains("Resource 2: This is a plaintext resource created at ") == true
        let promptText = state(page)["promptText"] as? String ?? ""
        page.checkAction("add"); try await settled(page)
        checks["promptAddedToOriginalDraftAndMarksSaved"] = !promptText.isEmpty && tasks.task(taskID)?.draft?.hasPrefix("保留 MCP 任务输入。") == true && tasks.task(taskID)?.draft?.hasSuffix(promptText) == true && !page.workspaceHasUnsavedChanges
        checks["otherTaskDraftAndAttachmentsUnaffected"] = tasks.task(other)?.draft == "保留另一任务输入。" && tasks.task(other)?.draftAttachmentIDs?.isEmpty != false
        let files = tasks.task(taskID)?.draftAttachmentIDs ?? []; report["attachmentIDs"] = files
        host.checkClose(.mcpContent); await wait(0.1)
        checks["closeDisconnectsOnlyOriginalPage"] = state(page)["closed"] as? Bool == true && state(page)["connected"] as? Bool == false && state(second)["connected"] as? Bool == true
        control.presentMCPContent(taskID: taskID, serverID: serverID)
        checks["closedPageReopensWithNewOwner"] = host.currentController !== page && (host.currentController as? AgentMCPContentWindow)?.workspaceReadback()["sessionOwner"] as? String != sessionOwner
        checks["zeroModelRequests"] = requests == 0
        report["checks"] = checks; report["success"] = checks.values.allSatisfy { $0 }; report["modelRequests"] = requests
        report["taskID"] = taskID; report["otherID"] = other; report["sessionOwner"] = sessionOwner
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("mcp-workspace-report.json"), options: .atomic)
        return checks
    }
}
