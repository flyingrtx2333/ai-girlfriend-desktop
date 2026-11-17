import AppKit

@MainActor extension AppDelegate {
    struct MCPRecoveryFixture: Codable {
        var first: String, second: String, serverA: String, serverB: String
        var mainWindow: String, childWindow: String, secondPage: String, secondPageHash: String
        var project: String
    }
    func runMCPRecoveryCheck(_ output: URL, interactive: Bool = false) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        let stage = CommandLine.arguments.firstIndex(of: "--recovery-stage").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "seed"
        func editor(_ window: ControlWindow) throws -> AgentMCPContentWindow {
            guard let value = window.taskWorkspace.currentController as? AgentMCPContentWindow else { throw PetError("MCP 资料未进入实际任务工作区") }; return value
        }
        func idle(_ page: AgentMCPContentWindow) async throws {
            let deadline = Date().addingTimeInterval(50)
            while page.hasPendingOperation && Date() < deadline { await wait(0.03) }
            guard !page.hasPendingOperation else { throw PetError("MCP 资料操作未完成") }
        }
        func select(_ page: AgentMCPContentWindow, kind: Int, key: String, contains: String) async throws {
            page.checkAction("", kind: kind); try await idle(page)
            guard let rows = page.workspaceReadback()["rows"] as? [[String: Any]],
                  let index = rows.firstIndex(where: { ($0[key] as? String)?.contains(contains) == true }) else { throw PetError("实际连接器未提供指定资料：" + contains) }
            page.checkAction("", row: index)
        }
        func rejected(_ name: String, _ action: () throws -> Void) {
            do { try action(); checks[name] = false } catch { checks[name] = true }
        }
        func position(_ page: AgentMCPContentWindow, field: String, location: Int, length: Int) -> Bool {
            let value = page.checkInputView(field)
            return value["location"] as? Int == location && value["length"] as? Int == length && value["focused"] as? Bool == true
        }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统不可用") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("参数恢复验收禁止模型请求") }
            let library = tasks.mcp, fixtureURL = output.appendingPathComponent("mcp-recovery-fixture.json")
            let fixture: MCPRecoveryFixture
            if stage == "seed" {
                let configuration = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("fixtures.json"))) as? [String: Any] ?? [:]
                guard let node = configuration["node"] as? String, let entry = configuration["serverEntry"] as? String else { throw PetError("缺少公开 MCP 服务器") }
                func server(_ name: String) throws -> AgentMCPServer {
                    let value: [String: Any] = ["name": name, "type": "stdio", "command": node, "args": [entry], "env": [:], "timeoutSeconds": 45]
                    return try library.save(String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self))
                }
                let a = try server("公开 MCP · 甲"), b = try server("公开 MCP · 乙")
                let project = output.appendingPathComponent("public-mcp-project")
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try Data("PUBLIC_MCP_RECOVERY_SOURCE_592\n".utf8).write(to: project.appendingPathComponent("README.md"))
                let first = tasks.create(title: "参数恢复 · 无工作区", mode: .agent, workMode: .general), second = tasks.create(title: "参数恢复 · 第二任务", workspace: project.path)
                for id in [first, second] { tasks.update(id) { $0.draft = "保留任务原输入 PUBLIC_MCP_INPUT_137" } }
                control.showAgentTask(first); control.show(tab: "chat"); control.presentMCPContent(taskID: first, serverID: a.id)
                let main = try editor(control); main.checkAction("connect"); try await idle(main)
                try await select(main, kind: 1, key: "uriTemplate", contains: "/text/")
                main.checkAction("", resourceURI: "demo://resource/dynamic/text/3")
                try await select(main, kind: 2, key: "name", contains: "resource-prompt")
                main.checkAction("", values: ["resourceType": "Text", "resourceId": "2"])
                if !interactive { _ = main.checkInputView("resourceType", selection: NSRange(location: 1, length: 2)) }
                main.selectRequestedServer(b.id); main.checkAction("connect"); try await idle(main)
                try await select(main, kind: 2, key: "name", contains: "resource-prompt")
                main.checkAction("", values: ["resourceType": "Text", "resourceId": "5"])
                if !interactive { _ = main.checkInputView("resourceId", selection: NSRange(location: 0, length: 1)) }
                main.selectRequestedServer(a.id); try await idle(main)
                try await select(main, kind: 2, key: "name", contains: "resource-prompt")
                checks["sameWindowRetainsThreeIndependentForms"] = try AgentMCPContentWindow.recoveryState(main.captureWorkspaceRecovery()).drafts.count == 3
                checks["connectorSwitchRestoresOriginalArguments"] = (main.workspaceReadback()["fields"] as? [String: String]) == ["resourceType": "Text", "resourceId": "2"]
                if !interactive { await wait(0.05); checks["connectorSwitchRestoresOwnSelectionAndFocus"] = position(main, field: "resourceType", location: 1, length: 2) }
                control.showAgentTask(second); control.presentMCPContent(taskID: second, serverID: b.id)
                let other = try editor(control); other.checkAction("connect"); try await idle(other)
                try await select(other, kind: 2, key: "name", contains: "resource-prompt")
                other.checkAction("", values: ["resourceType": "Text", "resourceId": "4"])
                if !interactive { _ = other.checkInputView("resourceId", selection: NSRange(location: 0, length: 1)) }
                control.showAgentTask(first); control.show(tab: "chat")
                openTaskWindow(first, from: control)
                guard let child = additionalTaskWindows.last else { throw PetError("独立任务窗口未创建") }
                child.presentMCPContent(taskID: first, serverID: a.id)
                let childPage = try editor(child); childPage.checkAction("connect"); try await idle(childPage)
                try await select(childPage, kind: 2, key: "name", contains: "resource-prompt")
                childPage.checkAction("", values: ["resourceType": "Text", "resourceId": "6"])
                if !interactive { _ = childPage.checkInputView("resourceType", selection: NSRange(location: 0, length: 4)) }
                guard await flushWorkspaceWindows(), let mainID = control.workspaceSession?.id, let childID = child.workspaceSession?.id,
                      let secondTab = control.taskWorkspace.recoveryLayouts.first(where: { $0.taskID == second })?.tabs.first(where: { $0.root == "mcp" }) else { throw PetError("MCP 参数恢复记录未保存") }
                let secondPage = store.directory.appendingPathComponent("workspace-recovery/" + mainID + "/pages/" + secondTab.id + ".json")
                fixture = .init(first: first, second: second, serverA: a.id, serverB: b.id, mainWindow: mainID, childWindow: childID,
                    secondPage: secondPage.path, secondPageHash: AgentFiles.hash(try Data(contentsOf: secondPage)), project: project.path)
                try JSONEncoder().encode(fixture).write(to: fixtureURL, options: .atomic)
                checks["separateTaskAndWindowKeepOwnArguments"] = (other.workspaceReadback()["fields"] as? [String: String])?["resourceId"] == "4" && (childPage.workspaceReadback()["fields"] as? [String: String])?["resourceId"] == "6"
                checks["allThreeEditorsEligibleForPreservedQuit"] = control.workspaceSession?.preservedEditors.count == 2 && child.workspaceSession?.preservedEditors.count == 1
                checks["noWorkspaceTaskOwnsItsParameterDrafts"] = tasks.task(first)?.workspace == nil && main.workspaceHasUnsavedChanges
            } else {
                fixture = try JSONDecoder().decode(MCPRecoveryFixture.self, from: Data(contentsOf: fixtureURL))
                control.show(tab: "chat"); restoreAdditionalWorkspaceWindows()
                guard await flushWorkspaceWindows(), let child = additionalTaskWindows.first(where: { $0.workspaceSession?.id == fixture.childWindow }) else { throw PetError("MCP 窗口恢复未完成") }
                let main = try editor(control), childPage = try editor(child)
                var expectedMain = ["resourceType": "Text", "resourceId": "2"]
                let expectedFile = output.appendingPathComponent("ui-expected-arguments.json")
                if interactive, FileManager.default.fileExists(atPath: expectedFile.path) {
                    expectedMain = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: expectedFile))
                    guard Set(expectedMain.keys) == ["resourceType", "resourceId"] else { throw PetError("实际窗口输入期望格式无效") }
                }
                checks["restoredMainArgumentsVisibleBeforeConnecting"] = (main.workspaceReadback()["fields"] as? [String: String]) == expectedMain
                checks["restoredChildArgumentsRemainIndependent"] = (childPage.workspaceReadback()["fields"] as? [String: String])?["resourceId"] == "6"
                if !interactive {
                    await wait(0.05)
                    checks["coldMainRestoresSelectionAndInputFocus"] = position(main, field: "resourceType", location: 1, length: 2)
                    checks["coldChildRestoresIndependentSelectionAndInputFocus"] = position(childPage, field: "resourceType", location: 0, length: 4)
                }
                checks["restartDoesNotAutomaticallyConnect"] = [main, childPage].allSatisfy { $0.workspaceReadback()["connected"] as? Bool == false }
                checks["restoredPreviewCannotBeReusedBeforeCatalogValidation"] = [main, childPage].allSatisfy { $0.workspaceReadback()["promptText"] as? String == "" && $0.workspaceReadback()["readEnabled"] as? Bool == false && $0.workspaceReadback()["restoredSelectionPending"] as? Bool == true }
                let coldPage = try JSONDecoder().decode(AgentWorkspaceRecovery.Page.self, from: Data(contentsOf: URL(fileURLWithPath: fixture.secondPage)))
                checks["unmaterializedTaskKeepsItsUnsavedRecoveryPage"] = control.taskWorkspace.recoveryController(taskID: fixture.second, root: .mcpContent) == nil && coldPage.dirty && coldPage.taskID == fixture.second
                control.showAgentTask(fixture.second); control.show(tab: "chat"); guard await flushWorkspaceWindows() else { throw PetError("第二任务恢复未结束") }
                if stage == "unavailable" {
                    checks["disabledConnectorKeepsUnmaterializedTaskAndDirtyTab"] = control.taskWorkspace.recoveryController(taskID: fixture.second, root: .mcpContent) == nil && (control.taskWorkspace.checkState()["tabLabels"] as? [String])?.contains("• MCP 资料") == true
                    checks["failedRestoreKeepsOriginalPageBytes"] = try AgentFiles.hash(Data(contentsOf: URL(fileURLWithPath: fixture.secondPage))) == fixture.secondPageHash
                } else {
                    let other = try editor(control)
                    checks["secondTaskRestoresOwnConnectorAndArguments"] = other.workspaceReadback()["serverID"] as? String == fixture.serverB && (other.workspaceReadback()["fields"] as? [String: String])?["resourceId"] == "4"
                    checks["secondTaskRemainsDisconnected"] = other.workspaceReadback()["connected"] as? Bool == false
                    if !interactive {
                        await wait(0.05)
                        checks["secondTaskRestoresIndependentSelectionAndInputFocus"] = position(other, field: "resourceId", location: 0, length: 1)
                        let original = try other.captureWorkspaceRecovery()
                        func altered(_ change: (inout [String: Any]) -> Void) throws -> AgentWorkspaceRecovery.Page {
                            var page = original, value = try JSONSerialization.jsonObject(with: page.state) as! [String: Any]
                            change(&value); page.state = try JSONSerialization.data(withJSONObject: value); return page
                        }
                        rejected("futureFormVersionRejected") { _ = try AgentMCPContentWindow.recoveryState(altered { $0["version"] = 2 }) }
                        rejected("unknownStateFieldRejected") { _ = try AgentMCPContentWindow.recoveryState(altered { $0["future"] = true }) }
                        rejected("wrongTaskCannotRestoreParameters") { var page = original; page.taskID = fixture.first; try other.restoreWorkspaceRecovery(page) }
                        rejected("changedConnectorRevisionCannotRestoreParameters") { try other.restoreWorkspaceRecovery(altered { $0["serverRevision"] = UUID().uuidString }) }
                        checks["oldDraftWithoutViewRemainsReadable"] = try AgentMCPContentWindow.recoveryState(altered { $0["view"] = nil }).view == nil
                        func changedView(_ change: (inout [String: Any]) -> Void) throws -> AgentWorkspaceRecovery.Page {
                            try altered { state in var view = state["view"] as! [String: Any]; change(&view); state["view"] = view }
                        }
                        rejected("futureInputViewVersionRejected") { _ = try AgentMCPContentWindow.recoveryState(changedView { $0["version"] = 2 }) }
                        rejected("unknownInputViewFieldRejected") { _ = try AgentMCPContentWindow.recoveryState(changedView { $0["future"] = true }) }
                        rejected("negativeCatalogPositionRejected") { _ = try AgentMCPContentWindow.recoveryState(changedView { $0["listY"] = -1 }) }
                        rejected("unknownFocusedParameterRejected") { try other.restoreWorkspaceRecovery(changedView { $0["focus"] = "field:missing" }) }
                        func changedTextView(_ change: (inout [String: Any]) -> Void) throws -> AgentWorkspaceRecovery.Page {
                            try changedView { view in
                                var forms = view["forms"] as! [String: Any], form = forms.values.first as! [String: Any], fields = form["fields"] as! [String: Any], text = fields["resourceId"] as! [String: Any]
                                change(&text); fields["resourceId"] = text; form["fields"] = fields; forms[forms.keys.first!] = form; view["forms"] = forms
                            }
                        }
                        rejected("changedInputHashRejected") { try other.restoreWorkspaceRecovery(changedTextView { $0["hash"] = String(repeating: "0", count: 64) }) }
                        rejected("changedInputLengthRejected") { _ = try AgentMCPContentWindow.recoveryState(changedTextView { $0["count"] = 100 }) }
                        rejected("overflowInputSelectionRejected") { _ = try AgentMCPContentWindow.recoveryState(changedTextView { $0["selections"] = [["location": 100, "length": 1]] }) }
                        rejected("unknownTextViewFieldRejected") { _ = try AgentMCPContentWindow.recoveryState(changedTextView { $0["future"] = true }) }
                        checks["rejectedInputPositionLeavesCurrentFocusAndSelection"] = position(other, field: "resourceId", location: 0, length: 1)
                        checks["rejectedRestoreKeepsCurrentArguments"] = (other.workspaceReadback()["fields"] as? [String: String])?["resourceId"] == "4"
                    }
                }
                control.showAgentTask(fixture.first); control.show(tab: "chat"); guard await flushWorkspaceWindows() else { throw PetError("原参数页恢复未结束") }
                if stage != "unavailable", !interactive {
                    await wait(0.05)
                    checks["returningToTaskRestoresOriginalInputFocus"] = position(main, field: "resourceType", location: 1, length: 2)
                    main.checkAction("connect"); try await idle(main)
                    await wait(0.05)
                    checks["manualReconnectRetainsInputSelectionAndFocus"] = position(main, field: "resourceType", location: 1, length: 2)
                    checks["manualConnectValidatesAndRestoresSelectedPrompt"] = main.workspaceReadback()["restoredSelectionPending"] as? Bool == false && main.workspaceReadback()["selectedName"] as? String == "resource-prompt" && (main.workspaceReadback()["fields"] as? [String: String])?["resourceId"] == "2"
                    main.checkAction("read"); try await idle(main)
                    let protocolReadback = main.workspaceReadback()
                    report["restoredProtocolReadback"] = protocolReadback
                    checks["actualProtocolPreviewUsesRestoredArguments"] = (protocolReadback["previewText"] as? String)?.contains("Resource 2:") == true && (protocolReadback["promptText"] as? String)?.contains("demo://resource/dynamic/text/2") == true
                    try await select(main, kind: 1, key: "uriTemplate", contains: "/text/")
                    checks["otherKindRetainsExpandedTemplateURI"] = main.workspaceReadback()["uri"] as? String == "demo://resource/dynamic/text/3"
                    main.selectRequestedServer(fixture.serverB); main.checkAction("connect"); try await idle(main)
                    try await select(main, kind: 2, key: "name", contains: "resource-prompt")
                    checks["otherConnectorRetainsOwnArgumentDraft"] = (main.workspaceReadback()["fields"] as? [String: String])?["resourceId"] == "5"
                    main.selectRequestedServer(fixture.serverA); try await idle(main)
                    try await select(main, kind: 2, key: "name", contains: "resource-prompt")
                    guard await flushWorkspaceWindows(), let tab = control.taskWorkspace.recoveryLayouts.first(where: { $0.taskID == fixture.first })?.tabs.first(where: { $0.root == "mcp" }) else { throw PetError("原参数未保存") }
                    let path = store.directory.appendingPathComponent("workspace-recovery/" + fixture.mainWindow + "/pages/" + tab.id + ".json")
                    let bytes = try Data(contentsOf: path)
                    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
                    main.checkAction("", values: ["resourceId": "LAST_EDIT_PUBLIC_821"])
                    checks["readOnlyPageRejectsLatestParameterCheckpoint"] = !(await control.flushWorkspaceRecovery())
                    checks["failedCheckpointPreservesPreviousPageAndNewInput"] = try Data(contentsOf: path) == bytes && (main.workspaceReadback()["fields"] as? [String: String])?["resourceId"] == "LAST_EDIT_PUBLIC_821"
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                    checks["sameLastEditRetriesAfterPermissionRestores"] = await control.flushWorkspaceRecovery()
                    main.checkAction("", values: ["resourceId": "2"])
                    guard await flushWorkspaceWindows() else { throw PetError("原公开参数未恢复") }
                }
            }
            checks["allTaskComposerDraftsRemainExact"] = [fixture.first, fixture.second].allSatisfy { tasks.task($0)?.draft == "保留任务原输入 PUBLIC_MCP_INPUT_137" }
            checks["sourceReadmeRemainsExact"] = try String(contentsOf: URL(fileURLWithPath: fixture.project).appendingPathComponent("README.md"), encoding: .utf8) == "PUBLIC_MCP_RECOVERY_SOURCE_592\n"
            var ownedProcesses = Set<pid_t>()
            for window in taskControls { for (_, _, controller) in window.taskWorkspace.recoveryEditors {
                guard let page = controller as? AgentMCPContentWindow, let owner = page.workspaceReadback()["sessionOwner"] as? String else { continue }
                for server in [fixture.serverA, fixture.serverB] {
                    if let pid = await library.processID(server, owner: owner) { ownedProcesses.insert(pid) }
                }
            } }
            report["ownedMCPProcessIDs"] = ownedProcesses.sorted()
            if !interactive {
                library.disconnect()
                let deadline = Date().addingTimeInterval(5)
                while ownedProcesses.contains(where: { kill($0, 0) == 0 }) && Date() < deadline { await wait(0.03) }
                checks["ownedConnectorProcessesExit"] = ownedProcesses.allSatisfy { kill($0, 0) != 0 }
            } else {
                control.window?.makeKeyAndOrderFront(nil)
                if CommandLine.arguments.contains("--inactive-confirm-ui") {
                    NSApp.deactivate(); await wait(0.05)
                    checks["inactiveConfirmationFixtureStartsInactive"] = !NSApp.isActive
                }
            }
            checks["allRecoverySnapshotsCurrent"] = await flushWorkspaceWindows()
            checks["modelRuntimeMakesNoRequest"] = requests == 0
            report["fixture"] = fixtureURL.path; report["mainWorkspace"] = control.taskWorkspace.checkState()
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["modelRequests"] = requests; report["stage"] = stage; report["appPID"] = getpid()
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(interactive ? "mcp-recovery-ui-ready.json" : "mcp-recovery-report.json"))
    }
}
