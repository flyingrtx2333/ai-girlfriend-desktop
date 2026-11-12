import AppKit

@MainActor extension AppDelegate {
    func runAgentMCPContentCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        func phase(_ value: String) { try? Data(value.utf8).write(to: output.appendingPathComponent("phase"), options: .atomic) }
        func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self) }
        func rejected(_ name: String, _ action: () throws -> Void) { do { try action(); checks[name] = false } catch { checks[name] = true } }
        defer { agentRuntime?.stopAll(); agentStore?.mcp.disconnect(); phase("finished") }
        do {
            let binary = Bundle.main.executableURL!
            report["appPID"] = getpid(); report["binaryHash"] = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统未初始化") }
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("fixtures.json"))) as? [String: Any] ?? [:]
            guard let node = fixture["node"] as? String, let entry = fixture["serverEntry"] as? String, let document = fixture["documentFile"] as? String else { throw PetError("缺少官方服务器路径") }
            let workspace = output.appendingPathComponent("workspace")
            let library = tasks.mcp, server = try library.save(json(["name": "官方 MCP 文档", "type": "stdio", "command": node, "args": [entry], "env": [:], "timeoutSeconds": 45]))
            report["serverVersion"] = fixture["serverVersion"]; report["serverEntry"] = entry
            let owner = tasks.create(title: "MCP 实际资源验收", workspace: workspace.path), contextOwner = owner + "/context-native"
            _ = try await library.connect(server.id, revision: server.revision, owner: contextOwner, workspace: workspace.path)
            guard let connection = library.token(server.id, owner: contextOwner) else { throw PetError("未取得实际连接") }
            let resourceURI = "demo://resource/static/document/architecture.md"
            var resources = try await library.contentCatalog(server.id, owner: contextOwner, connection: connection, kind: "resources", query: "architecture.md")
            let resourceToken = resources["catalog"] as! String
            checks["actualStaticDocumentListed"] = (resources["items"] as? [[String: Any]])?.contains { $0["uri"] as? String == resourceURI } == true
            let preview = try await library.readResource(server.id, owner: contextOwner, connection: connection, catalog: resourceToken, uri: resourceURI)
            let bytes = try Data(contentsOf: URL(fileURLWithPath: document))
            checks["actualResourceBytesMatchInstalledDocument"] = preview.parts.count == 1 && preview.parts[0].data == bytes
            report["resourceSHA256"] = AgentFiles.hash(bytes); report["resourceBytes"] = bytes.count
            rejected("unlistedURIRequiresAdvertisedTemplate") { _ = try library.validateResourceRead(server.id, owner: contextOwner, connection: connection, catalog: resourceToken, uri: "file:///unlisted", template: nil) }
            rejected("resourceCannotUseAnotherTaskConnection") { _ = try library.validateResourceRead(server.id, owner: "different-task", connection: connection, catalog: resourceToken, uri: resourceURI, template: nil) }
            let templates = try await library.contentCatalog(server.id, owner: contextOwner, connection: connection, kind: "templates")
            guard let template = (templates["items"] as? [[String: Any]])?.first(where: { ($0["uriTemplate"] as? String)?.contains("/text/") == true }), let templateURI = template["uriTemplate"] as? String else { throw PetError("官方服务器未返回文本资源模板") }
            let templatePreview = try await library.readResource(server.id, owner: contextOwner, connection: connection, catalog: templates["catalog"] as! String, uri: "demo://resource/dynamic/text/3", template: templateURI)
            checks["actualURITemplateReadsExpandedResource"] = templatePreview.parts.first?.text?.hasPrefix("Resource 3:") == true
            do { _ = try await library.readResource(server.id, owner: contextOwner, connection: connection, catalog: templates["catalog"] as! String, uri: "demo://resource/dynamic/text/0", template: templateURI); checks["actualUnknownResourceReturnsProtocolError"] = false } catch { checks["actualUnknownResourceReturnsProtocolError"] = true }
            let recoveredResource = try await library.readResource(server.id, owner: contextOwner, connection: connection, catalog: templates["catalog"] as! String, uri: "demo://resource/dynamic/text/4", template: templateURI)
            checks["protocolErrorKeepsActualConnectionUsable"] = recoveredResource.parts.first?.text?.hasPrefix("Resource 4:") == true
            let allResources = try await library.contentCatalog(server.id, owner: contextOwner, connection: connection, kind: "resources", query: "summer-specials")
            let collection = try await library.readResource(server.id, owner: contextOwner, connection: connection, catalog: allResources["catalog"] as! String, uri: "demo://resource/collection/summer-specials")
            checks["actualCollectionPreservesEachContentURI"] = collection.parts.count > 1 && Set(collection.parts.compactMap(\.uri)).count == collection.parts.count && collection.parts.allSatisfy { $0.uri != collection.uri }
            var prompts = try await library.contentCatalog(server.id, owner: contextOwner, connection: connection, kind: "prompts")
            guard let promptToken = prompts["catalog"] as? String else { throw PetError("未取得提示词目录") }
            checks["actualPromptArgumentsDiscovered"] = (prompts["items"] as? [[String: Any]])?.first(where: { $0["name"] as? String == "resource-prompt" })?["arguments"] as? [[String: Any]] != nil
            do { _ = try await library.prompt(server.id, owner: contextOwner, connection: connection, catalog: promptToken, name: "resource-prompt", arguments: [:]); checks["missingPromptArgumentRejected"] = false } catch { checks["missingPromptArgumentRejected"] = true }
            let prompt = try await library.prompt(server.id, owner: contextOwner, connection: connection, catalog: promptToken, name: "resource-prompt", arguments: ["resourceType": "Text", "resourceId": "2"])
            checks["actualPromptIncludesEmbeddedResource"] = prompt.parts.count == 2 && prompt.parts.first?.inline == true && prompt.parts.last?.text?.hasPrefix("Resource 2:") == true && prompt.parts.last?.uri == "demo://resource/dynamic/text/2"
            let privateFiles = try await AgentMCPContent.importParts(prompt, store: tasks, taskID: owner)
            checks["unsubmittedMCPAttachmentNotVisibleToModel"] = privateFiles.count == 1 && privateFiles.allSatisfy { !tasks.task(owner)!.availableAttachmentIDs.contains($0.id) } && tasks.task(owner)?.messages.isEmpty == true
            checks["MCPAttachmentKeepsActualSourceAndHash"] = privateFiles.first?.mcpSource?.uri == "demo://resource/dynamic/text/2" && privateFiles.first?.sha256 == prompt.parts.last.map { AgentFiles.hash($0.data) }
            // Use the real reference server to deliver notifications, rather than
            // invoking the client's invalidation callbacks from the check.
            _ = try library.catalog(server.id, owner: contextOwner, token: connection, offset: 0, query: "trigger-list-changed")
            _ = try await library.call(server.id, owner: contextOwner, token: connection, name: "trigger-list-changed", arguments: ["list": "prompts"])
            let promptDeadline = Date().addingTimeInterval(3)
            while library.previewCurrent(prompt) && Date() < promptDeadline { await wait(0.03) }
            checks["actualPromptListNotificationInvalidatesPreview"] = !library.previewCurrent(prompt)
            do { _ = try await library.prompt(server.id, owner: contextOwner, connection: connection, catalog: promptToken, name: "simple-prompt", arguments: [:]); checks["oldPromptCatalogCannotBeReplayed"] = false } catch { checks["oldPromptCatalogCannotBeReplayed"] = true }
            prompts = try await library.contentCatalog(server.id, owner: contextOwner, connection: connection, kind: "prompts")
            let refreshed = try await library.prompt(server.id, owner: contextOwner, connection: connection, catalog: prompts["catalog"] as! String, name: "simple-prompt", arguments: [:])
            checks["actualPromptRefreshRecoversWithoutReconnect"] = library.previewCurrent(refreshed) && refreshed.parts.first?.text == "This is a simple prompt without arguments."
            resources = try await library.contentCatalog(server.id, owner: contextOwner, connection: connection, kind: "resources", query: "architecture.md")
            let subscribed = try await library.readResource(server.id, owner: contextOwner, connection: connection, catalog: resources["catalog"] as! String, uri: resourceURI)
            try await library.subscription(subscribed, enabled: true)
            checks["actualResourceSubscriptionRegistered"] = library.subscribed(subscribed)
            _ = try library.catalog(server.id, owner: contextOwner, token: connection, offset: 0, query: "trigger-resource-update")
            _ = try await library.call(server.id, owner: contextOwner, token: connection, name: "trigger-resource-update", arguments: ["uri": resourceURI])
            let resourceDeadline = Date().addingTimeInterval(3)
            while library.previewCurrent(subscribed) && Date() < resourceDeadline { await wait(0.03) }
            checks["actualResourceUpdateInvalidatesSnapshot"] = !library.previewCurrent(subscribed)
            try await library.subscription(subscribed, enabled: false); checks["actualResourceSubscriptionCanStop"] = !library.subscribed(subscribed)
            _ = try library.catalog(server.id, owner: contextOwner, token: connection, offset: 0, query: "trigger-list-changed")
            _ = try await library.call(server.id, owner: contextOwner, token: connection, name: "trigger-list-changed", arguments: ["list": "resources"])
            let directoryDeadline = Date().addingTimeInterval(3)
            while library.contentCatalogCurrent(server.id, owner: contextOwner, connection: connection, catalog: resources["catalog"] as! String, kind: "resources") && Date() < directoryDeadline { await wait(0.03) }
            checks["actualResourceDirectoryNotificationInvalidatesCatalog"] = !library.contentCatalogCurrent(server.id, owner: contextOwner, connection: connection, catalog: resources["catalog"] as! String, kind: "resources")
            _ = try await library.contentCatalog(server.id, owner: contextOwner, connection: connection, kind: "resources")
            _ = try library.catalog(server.id, owner: contextOwner, token: connection, offset: 0, query: "get-tiny-image")
            let mediaOwner = tasks.create(title: "MCP 实际媒体副本", workspace: workspace.path)
            _ = try await library.connect(server.id, revision: server.revision, owner: mediaOwner, workspace: workspace.path)
            let mediaConnection = library.token(server.id, owner: mediaOwner)!
            _ = try library.catalog(server.id, owner: mediaOwner, token: mediaConnection, offset: 0, query: "get-tiny-image")
            let media = try await library.call(server.id, owner: mediaOwner, token: mediaConnection, name: "get-tiny-image", arguments: [:], store: tasks)
            guard let imageID = media.attachmentIDs?.first else { throw PetError("实际 MCP 图片未保存") }
            let image = try AgentAttachments.record(store: tasks, taskID: mediaOwner, id: imageID)
            checks["actualToolImageSavedWithVisualReference"] = image.width == 20 && image.height == 20 && media.visuals?.first?.id == imageID && image.mcpSource?.kind == "tool"
            checks["toolImageUnavailableUntilActualToolMessage"] = tasks.task(mediaOwner)?.availableAttachmentIDs.contains(imageID) == false
            let imageFile = try AgentAttachments.source(store: tasks, taskID: mediaOwner, id: imageID)
            try Data(contentsOf: imageFile).write(to: output.appendingPathComponent("actual-mcp-image.png"))
            try AgentDocument.image(imageFile).jpeg.write(to: output.appendingPathComponent("actual-model-image.jpg"))
            report["imageSHA256"] = image.sha256
            library.disconnect(owner: mediaOwner)
            let parent = tasks.create(title: "MCP 范围上限", workspace: workspace.path)
            tasks.update(parent) { $0.mode = .ask }
            var profile = AgentProfile(name: "MCP 范围核对员", description: "仅选定连接器", instructions: "只完成明确任务")
            profile.enabled = true; profile.readOnly = false; profile.network = true; profile.mcpServers = [server.id]; profile.tools = ["list_directory"]
            try tasks.agents.save(tasks.agents.encode([profile]), expectedHash: nil)
            let child = try tasks.agents.createTask(profile.id, store: tasks, workspace: workspace.path, owner: tasks.task(parent))
            let target = AgentToolCall(id: "scope", name: "read_mcp_resource", arguments: try json(["server_id": server.id, "connection": connection, "catalog": resourceToken, "uri": resourceURI]))
            rejected("parentAskModeCannotGainResourceAccess") { try tasks.agents.check(target, task: tasks.task(child)!, store: tasks) }
            tasks.update(parent) { $0.mode = .agent }; tasks.update(child) { $0.mode = .agent; $0.agent?.modeCeiling = .agent; $0.agent?.readOnlyCeiling = false; $0.agent?.networkCeiling = true }
            var current = profile; current.network = false
            // A live restriction is tested without permitting an invalid stored
            // profile: remove the selected connector as the UI does.
            current.mcpServers = []; try tasks.agents.save(tasks.agents.encode([current]), expectedHash: tasks.agents.document().1)
            rejected("removedConnectorCannotReadUsingOldAssignment") { try tasks.agents.check(target, task: tasks.task(child)!, store: tasks) }
            let runningPID = await library.processID(server.id, owner: contextOwner)
            library.disconnect(owner: owner)
            checks["taskDisconnectClosesContextOwnedSession"] = !library.connected(server.id, owner: contextOwner)
            if let runningPID { let deadline = Date().addingTimeInterval(4); while kill(runningPID, 0) == 0 && Date() < deadline { await wait(0.03) }; checks["actualContextServerProcessExits"] = kill(runningPID, 0) != 0 }
            tasks.selectedID = owner
            if CommandLine.arguments.contains("--live-agent") {
                guard checks.values.allSatisfy({ $0 }) else { throw PetError("相关原生检查未通过，不调用模型") }
                let production = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
                var p = PreferencesStore(directory: production).preferences; p.voiceEnabled = false; p.wakeEnabled = false; p.screenObservationEnabled = false; p.persona = ""; store.preferences = p
                report["model"] = p.model; report["contextLimit"] = p.contextLimit; report["outputLimit"] = p.outputLimit
                let onlyImage = CommandLine.arguments.contains("--mcp-content-image-only")
                var documentTaskID: String?
                var approved = Set<String>()
                func awaitLive(_ id: String, imageOnly: Bool = false) async throws {
                    let deadline = Date().addingTimeInterval(210)
                    while Date() < deadline {
                        guard let record = tasks.task(id) else { throw PetError("真实任务不可用") }
                        if !runtime.isRunning(id), [.completed, .failed, .stopped].contains(record.status) { guard record.status == .completed else { throw PetError(record.events.last?.detail ?? "实际任务未完成") }; return }
                        if record.events.filter({ $0.kind == "tool" && ["completed", "failed"].contains($0.status) }).count > 24 { runtime.cancel(id); throw PetError("超过本次实际流程的 24 次工具调用上限，保留记录并停止") }
                        if let review = runtime.pendingReview(id), let call = review.pendingCalls.first, !approved.contains(call.id) {
                            guard approved.count < 8 else { throw PetError("超出本次限定审批数量") }
                            let authorized = try library.routedCall(call, owner: review.id) ?? call
                            if authorized.name == "connect_mcp" { guard authorized.object["server_id"] as? String == server.id else { throw PetError("只批准官方验收连接器") } }
                            else if authorized.name == "read_mcp_resource", !imageOnly { guard authorized.object["uri"] as? String == resourceURI else { throw PetError("只批准指定实际文档 URI") } }
                            else if authorized.name == "write_file", !imageOnly { guard ["mcp-content-report.json", workspace.appendingPathComponent("mcp-content-report.json").path].contains(authorized.object["path"] as? String ?? "") else { throw PetError("只批准指定报告") } }
                            else if authorized.name == "call_mcp_tool", imageOnly { guard authorized.object["server_id"] as? String == server.id, authorized.object["tool"] as? String == "get-tiny-image" else { throw PetError("只批准实际图片工具") } }
                            else { throw PetError("额外审批未获授权：" + call.name) }
                            approved.insert(call.id); runtime.decide(taskID: review.id, callID: call.id, decision: "allow")
                        }
                        await wait(0.08)
                    }
                    runtime.cancel(id); throw PetError("真实 MCP 流程超时")
                }
                if !onlyImage {
                    let live = tasks.create(title: "真实 MCP 文档与提示词核对", workspace: workspace.path)
                    tasks.update(live) { $0.permission = .review; $0.toolGroups = ["attachments", "files"] }
                    let promptOwner = live + "/context-user-selection"
                    _ = try await library.connect(server.id, revision: server.revision, owner: promptOwner, workspace: workspace.path)
                    let promptConnection = library.token(server.id, owner: promptOwner)!
                    let promptCatalog = try await library.contentCatalog(server.id, owner: promptOwner, connection: promptConnection, kind: "prompts", query: "resource-prompt")
                    let selectedPrompt = try await library.prompt(server.id, owner: promptOwner, connection: promptConnection, catalog: promptCatalog["catalog"] as! String, name: "resource-prompt", arguments: ["resourceType": "Text", "resourceId": "2"])
                    let files = try await AgentMCPContent.importParts(selectedPrompt, store: tasks, taskID: live)
                    report["selectedPromptText"] = selectedPrompt.parts.last?.text
                    library.disconnect(owner: promptOwner)
                    let request = selectedPrompt.promptText + "\n\n本次核对要求：先 read_attachment 读取我随消息提交的资源全文，记录其原始文字（包括创建时间）与来源 URI。再 load_tools 只选 mcp、files，使用“官方 MCP 文档”连接器，list_mcp_resources 查询 architecture.md 并 read_mcp_resource 读取 \(resourceURI)。用真实资源内容和返回的字节数、sha256，写 mcp-content-report.json，只含 documentTitle（文档第一个 # 标题去除 #）、documentSHA256、documentBytes、promptResource（附件来源 URI）、promptText（附件完整原始文字）五个字段，然后 read_file 回读核对。不要生成示例数据，不改其他文件，不用终端或网页，不询问已有参数，最后简短报告。"
                    guard runtime.submit(request, taskID: live, attachmentIDs: files.map(\.id)) else { throw PetError(runtime.submissionError ?? "真实文档任务未开始") }
                    phase("real-document-and-selected-prompt"); try await awaitLive(live)
                    let complete = tasks.task(live)!, artifact = try JSONSerialization.jsonObject(with: Data(contentsOf: workspace.appendingPathComponent("mcp-content-report.json"))) as? [String: Any] ?? [:]
                    let heading = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\n").first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)) } ?? ""
                    checks["realModelUsesSelectedPromptAttachment"] = complete.events.contains { $0.title == "read_attachment" && $0.status == "completed" } && artifact["promptText"] as? String == selectedPrompt.parts.last?.text && artifact["promptResource"] as? String == "demo://resource/dynamic/text/2"
                    checks["realModelReadsMCPResourceThroughApproval"] = complete.events.contains { $0.title == "read_mcp_resource" && $0.status == "completed" } && complete.approvals.contains { $0.call.name == "read_mcp_resource" && $0.decision == "allow" }
                    checks["realDocumentReportMatchesIndependentFile"] = artifact.count == 5 && artifact["documentTitle"] as? String == heading && artifact["documentSHA256"] as? String == AgentFiles.hash(bytes) && artifact["documentBytes"] as? Int == bytes.count
                    checks["realModelReadsBackReport"] = complete.events.contains { $0.title == "read_file" && $0.status == "completed" && $0.detail.contains("mcp-content-report.json") }
                    checks["selectedPromptIsUserInputNotForgedAssistantHistory"] = complete.messages.first?.role == "user" && complete.messages.first?.content.hasPrefix("[用户选用的 MCP 提示词") == true
                    report["liveTaskID"] = live; report["artifact"] = artifact
                    documentTaskID = live
                }
                guard p.visionSupported == true else { throw PetError("保存的模型未启用视觉，不能验收真实 MCP 图片") }
                let imageTask = tasks.create(title: "真实 MCP 图片核对", workspace: workspace.path)
                tasks.update(imageTask) { $0.permission = .review; $0.toolGroups = ["mcp"] }
                guard runtime.submit("用“官方 MCP 文档”连接器的 get-tiny-image 获取实际图片。收到图后只用一句中文描述主要颜色和图形，不必识别品牌，不按工具说明猜视觉细节。不修改文件，不用网页、终端或其他服务。", taskID: imageTask) else { throw PetError("实际图片任务未开始") }
                phase("real-mcp-image"); try await awaitLive(imageTask, imageOnly: true)
                let pictured = tasks.task(imageTask)!, answer = pictured.summary
                checks["realMCPImageDeliveredToSavedModel"] = pictured.events.contains { $0.kind == "vision" && $0.status == "completed" } && pictured.messages.contains { $0.role == "tool" && $0.visualsDelivered == true } && (pictured.attachments ?? []).contains { $0.sha256 == image.sha256 }
                checks["realImageAnswerMatchesViewedReference"] = answer.contains("黑") && (answer.contains("线") || answer.contains("链") || answer.contains("斜") || answer.contains("交"))
                report["imageTaskID"] = imageTask; report["imageAnswer"] = answer; report["approvals"] = approved.count
                tasks.selectedID = documentTaskID ?? imageTask
            }
            if CommandLine.arguments.contains("--mcp-workspace-check") {
                for (name, pass) in try await runMCPWorkspaceCheck(output, taskID: owner, serverID: server.id) { checks["workspace-" + name] = pass }
            }
            report["checks"] = checks; report["success"] = checks.values.allSatisfy { $0 }
            report["scope"] = "Actual official server-everything 2.2.1 processes, real static document bytes, argument-bearing prompts with embedded resources, real change/subscription notifications, private copies and role/ancestor restrictions, plus optional saved-model file workflow and actual PNG vision. No simulated model, MCP or website responses. Audio/opaque blobs are retained as files without claiming transcription or interpretation."
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("mcp-content-report.json"), options: .atomic)
            if CommandLine.arguments.contains("--mcp-content-ui-hold") {
                control.show(tab: "chat"); control.showAgentTask(tasks.selectedID ?? owner); control.presentMCPContent(taskID: tasks.selectedID ?? owner, serverID: server.id); phase("ui-ready")
                let deadline = Date().addingTimeInterval(1200)
                while Date() < deadline, !FileManager.default.fileExists(atPath: output.appendingPathComponent("finish-ui").path) { await wait(0.25) }
            }
        } catch { report["success"] = false; report["checks"] = checks; report["error"] = error.localizedDescription; try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("mcp-content-report.json"), options: .atomic) }
    }
}
