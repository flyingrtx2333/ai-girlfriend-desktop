import AppKit

@MainActor extension AppDelegate {
    func prepareNameEditorUI(_ output: URL, seed: Bool) throws {
        guard !CommandLine.arguments.contains("--live-agent"), !CommandLine.arguments.contains("--attention-live-ui") else { throw PetError("命名表单验收不调用模型") }
        ensureAgent(); guard let tasks = agentStore else { throw PetError("任务系统不可用") }
        let file = output.appendingPathComponent("name-editor-fixtures.json")
        if seed {
            let coding = output.appendingPathComponent("Alpha"), general = output.appendingPathComponent("资料")
            for folder in [coding, general] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false); try Data("# 保留项目正文\n".utf8).write(to: folder.appendingPathComponent("README.md")) }
            let task = tasks.create(title: "项目说明", workspace: coding.path), other = tasks.create(title: "文件夹说明", workspace: general.path, mode: .ask, workMode: .general), none = tasks.create(title: "无工作区问答", mode: .ask)
            for id in [task, other, none] { tasks.update(id) { $0.draft = "保留命名验收输入"; $0.messages = [AgentMessage(role: "user", content: "仅用于本地命名验收的公开记录")]; $0.events = [AgentEvent(kind: "note", title: "保留事件", detail: "公开验收内容", status: "success")] } }
            let group = try tasks.organization.saveCustomGroup(name: "资料分组", mode: .coding)
            _ = try tasks.organization.saveCustomGroup(name: "已有分组", mode: .coding)
            try tasks.organization.assignTask(task, group: group, mode: .coding, tasks: tasks.tasks)
            let metadata: [String: Any] = ["taskID": task, "generalTaskID": other, "noneTaskID": none, "groupID": group, "workspace": coding.path, "folder": general.path]
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: file)
        }
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: String]
        guard let id = value?["taskID"], tasks.task(id) != nil else { throw PetError("未找到原命名验收任务") }
        control.showAgentTask(id)
    }

    func runNameEditorCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        defer { if let sheet = control.window?.attachedSheet { sheet.sheetParent?.endSheet(sheet) }; agentRuntime?.stopAll() }
        func find<T: NSView>(_ type: T.Type, in view: NSView?, matching predicate: (T) -> Bool) -> T? {
            guard let view else { return nil }; if let value = view as? T, predicate(value) { return value }
            for child in view.subviews { if let value = find(type, in: child, matching: predicate) { return value } }; return nil
        }
        func field(_ name: String, _ sheet: NSWindow) throws -> NSTextField {
            guard let value = find(NSTextField.self, in: sheet.contentView, matching: { $0.accessibilityLabel() == name }) else { throw PetError("缺少命名字段：" + name) }; return value
        }
        func click(_ title: String, _ sheet: NSWindow) throws {
            guard let value = find(NSButton.self, in: sheet.contentView, matching: { $0.title == title }) else { throw PetError("缺少命名操作：" + title) }; value.performClick(nil)
        }
        func closed(_ host: NSWindow) async throws {
            let limit = Date().addingTimeInterval(5)
            while host.attachedSheet != nil, Date() < limit { await wait(0.02) }
            guard host.attachedSheet == nil else { throw PetError("命名表单未关闭") }
            await wait(0.05)
        }
        func record(_ file: URL) throws -> Data {
            var value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            value["title"] = nil; value["updated"] = nil
            return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        }
        do {
            try prepareNameEditorUI(output, seed: true)
            guard let tasks = agentStore, let runtime = agentRuntime, let host = control.window else { throw PetError("任务系统不可用") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("命名表单验收禁止模型请求") }
            checks["isolatedWorkbenchWithoutModelAccess"] = usesAgent && tasks.extensions.sharedHome?.resolvingSymlinksInPath() == output.appendingPathComponent("shared-home").resolvingSymlinksInPath()
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("name-editor-fixtures.json"))) as! [String: String]
            let id = fixture["taskID"]!, none = fixture["noneTaskID"]!, group = fixture["groupID"]!, path = fixture["workspace"]!, folder = fixture["folder"]!
            control.show(tab: "chat"); await wait(0.1)
            let taskFile = tasks.directory.appendingPathComponent(id + ".json"), index = tasks.directory.appendingPathComponent("index.json"), organization = tasks.directory.deletingLastPathComponent().appendingPathComponent("organization.json")
            let before = try Data(contentsOf: taskFile), indexBefore = try Data(contentsOf: index), bodyBefore = try record(taskFile), activity = tasks.tasks.first { $0.id == id }?.activityAt
            control.checkNameEditor("task", id: id)
            guard let sheet = host.attachedSheet else { throw PetError("任务名称表单未打开") }
            await wait(0.05)
            let input = try field("任务名称", sheet), originalFocus = input.currentEditor()
            checks["renameUsesStyledOwnedSheetWithSelectedInput"] = host.isVisible && sheet.isVisible && sheet.contentView is AgentThemeView && NSApp.modalWindow == nil && originalFocus != nil && input.stringValue == "项目说明"
            checks["parentCloseKeepsOpenNameEditor"] = !control.windowShouldClose(host) && host.attachedSheet === sheet
            for (name, size) in [("normal", NSSize(width: 1200, height: 774)), ("narrow", NSSize(width: 780, height: 540))] {
                host.setContentSize(size); sheet.contentView?.layoutSubtreeIfNeeded()
                checks["nameEditorFits-" + name] = !input.hasAmbiguousLayout && input.bounds.width >= 360 && input.bounds.height >= 30 && sheet.frame.width <= host.frame.width && sheet.contentView!.bounds.height >= 200
            }
            input.stringValue = "   "; try click("保存", sheet)
            checks["invalidNameRetainsInputAndInlineErrorWithoutWrites"] = try host.attachedSheet === sheet && input.stringValue == "   " && field("名称保存状态", sheet).stringValue.contains("120") && Data(contentsOf: taskFile) == before && Data(contentsOf: index) == indexBefore
            input.stringValue = "尚未保存的名称"; try click("取消", sheet); try await closed(host)
            checks["cancelLeavesTaskAndIndexByteIdentical"] = try Data(contentsOf: taskFile) == before && Data(contentsOf: index) == indexBefore
            control.checkNameEditor("task", id: id)
            guard let savedSheet = host.attachedSheet else { throw PetError("无法重开命名表单") }
            try field("任务名称", savedSheet).stringValue = "  审阅项目说明  "; try click("保存", savedSheet); try await closed(host)
            checks["saveChangesOnlyTitleAndUpdateDate"] = try record(taskFile) == bodyBefore && tasks.task(id)?.title == "审阅项目说明" && tasks.tasks.first { $0.id == id }?.title == "审阅项目说明" && tasks.tasks.first { $0.id == id }?.activityAt == activity
            checks["taskRenameKeepsPrivateFilePermissions"] = try FileManager.default.attributesOfItem(atPath: taskFile.path)[.posixPermissions] as? NSNumber == 0o600
            let renamed = try Data(contentsOf: taskFile), renamedIndex = try Data(contentsOf: index)
            try tasks.renameTask(id, title: "审阅项目说明", expectedHash: tasks.recordVersion(id))
            checks["unchangedNameDoesNotWriteOrChangeTimestamps"] = try Data(contentsOf: taskFile) == renamed && Data(contentsOf: index) == renamedIndex
            for (key, value) in [("overlong", String(repeating: "界", count: 121)), ("control", "不应\n截断")] {
                do { try tasks.renameTask(id, title: value, expectedHash: tasks.recordVersion(id)); checks["rejects-" + key] = false }
                catch { checks["rejects-" + key] = try error.localizedDescription.contains("120") && Data(contentsOf: taskFile) == renamed && Data(contentsOf: index) == renamedIndex }
            }
            control.checkNameEditor("task", id: id)
            guard let staleSheet = host.attachedSheet else { throw PetError("缺少冲突表单") }
            try field("任务名称", staleSheet).stringValue = "保留冲突填写"
            tasks.update(id) { $0.draft = "另一个窗口保存的输入" }; let changed = try Data(contentsOf: taskFile), changedIndex = try Data(contentsOf: index)
            try click("保存", staleSheet)
            checks["staleTaskCannotOverwriteNewDraftAndRetainsName"] = try field("名称保存状态", staleSheet).stringValue.contains("已变化") && field("任务名称", staleSheet).stringValue == "保留冲突填写" && Data(contentsOf: taskFile) == changed && Data(contentsOf: index) == changedIndex
            try click("取消", staleSheet); try await closed(host)
            control.checkNameEditor("task", id: id)
            guard let failedSheet = host.attachedSheet else { throw PetError("缺少保存失败表单") }
            try field("任务名称", failedSheet).stringValue = "保留未写入的名称"
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: taskFile.path)
            try click("保存", failedSheet)
            checks["writeFailureKeepsEditorCacheTaskAndIndex"] = try !field("名称保存状态", failedSheet).stringValue.isEmpty && field("任务名称", failedSheet).stringValue == "保留未写入的名称" && tasks.task(id)?.title == "审阅项目说明" && Data(contentsOf: taskFile) == changed && Data(contentsOf: index) == changedIndex
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: taskFile.path)
            try click("取消", failedSheet); try await closed(host)
            control.checkNameEditor("task", id: id)
            guard let runningSheet = host.attachedSheet else { throw PetError("缺少执行状态表单") }
            try field("任务名称", runningSheet).stringValue = "保留运行中的填写"; tasks.update(id) { $0.status = .running }
            let running = try Data(contentsOf: taskFile), runningIndex = try Data(contentsOf: index)
            try click("保存", runningSheet)
            checks["taskStartingAfterOpenCannotBeRenamed"] = try field("名称保存状态", runningSheet).stringValue.contains("运行") && field("任务名称", runningSheet).stringValue == "保留运行中的填写" && Data(contentsOf: taskFile) == running && Data(contentsOf: index) == runningIndex
            try click("取消", runningSheet); try await closed(host); tasks.update(id) { $0.status = .ready }
            let orgBefore = try Data(contentsOf: organization), taskBeforeGroups = try Data(contentsOf: taskFile)
            control.checkNameEditor("group", id: nil)
            guard let groupSheet = host.attachedSheet else { throw PetError("分组表单未打开") }
            try field("分组名称", groupSheet).stringValue = "已有分组"; try click("保存", groupSheet)
            checks["duplicateGroupStaysInEditorWithoutOrganizationWrite"] = try field("名称保存状态", groupSheet).stringValue.contains("已存在") && field("分组名称", groupSheet).stringValue == "已有分组" && Data(contentsOf: organization) == orgBefore
            try field("分组名称", groupSheet).stringValue = "新建的分组"; try click("保存", groupSheet); try await closed(host)
            checks["newGroupAndCustomViewPersistTogether"] = tasks.organization.customGroups(.coding, tasks: tasks.tasks).contains { $0.name == "新建的分组" } && tasks.organization.taskView(.coding).grouping == .custom
            control.checkNameEditor("group", id: group)
            guard let renameGroup = host.attachedSheet else { throw PetError("分组重命名未打开") }
            try field("分组名称", renameGroup).stringValue = "审阅分组"; try click("保存", renameGroup); try await closed(host)
            checks["groupRenamePreservesMembershipAndTaskBytes"] = try tasks.organization.customGroups(.coding, tasks: tasks.tasks).first { $0.id == group }.map { $0.name == "审阅分组" && $0.taskIDs == [id] } == true && Data(contentsOf: taskFile) == taskBeforeGroups
            control.checkNameEditor("group", id: group)
            guard let staleGroup = host.attachedSheet else { throw PetError("分组冲突表单未打开") }
            try field("分组名称", staleGroup).stringValue = "保留分组填写"; try tasks.organization.sort(.name, mode: .coding); let newerOrg = try Data(contentsOf: organization)
            try click("保存", staleGroup)
            checks["organizationChangeRejectsStaleEditorWithoutLosingInput"] = try field("名称保存状态", staleGroup).stringValue.contains("已变化") && field("分组名称", staleGroup).stringValue == "保留分组填写" && Data(contentsOf: organization) == newerOrg
            try click("取消", staleGroup); try await closed(host)
            for (mode, directory, label, name) in [(AgentWorkMode.coding, path, "工作区名称", "审阅工作区"), (.general, folder, "文件夹名称", "审阅资料夹")] {
                let readme = URL(fileURLWithPath: directory).appendingPathComponent("README.md"), projectBytes = try Data(contentsOf: readme)
                control.checkNameEditor("directory", id: directory, mode: mode)
                guard let directorySheet = host.attachedSheet else { throw PetError("目录名称表单未打开") }
                let directoryInput = try field(label, directorySheet); directoryInput.stringValue = String(repeating: "长", count: 81); try click("保存", directorySheet)
                checks["directoryErrorRetainsInput-" + mode.rawValue] = try directoryInput.stringValue.count == 81 && field("工作区保存状态", directorySheet).stringValue.contains("80")
                directoryInput.stringValue = name; try click("保存", directorySheet); try await closed(host)
                checks["directoryRenameIsDisplayOnly-" + mode.rawValue] = try tasks.organization.name(directory, mode: mode) == name && Data(contentsOf: readme) == projectBytes && Data(contentsOf: taskFile) == taskBeforeGroups
            }
            control.showAgentTask(none); control.checkNameEditor("task", id: none)
            guard let noneSheet = host.attachedSheet else { throw PetError("无工作区问答名称表单未打开") }
            try field("任务名称", noneSheet).stringValue = "命名后的无工作区问答"; try click("保存", noneSheet); try await closed(host)
            checks["chatWithoutWorkspaceCanRenameAndKeepDraft"] = tasks.task(none)?.title == "命名后的无工作区问答" && tasks.task(none)?.workspace == nil && tasks.task(none)?.mode == .ask && tasks.task(none)?.draft == "保留命名验收输入"
            let reopened = AgentStore(directory: tasks.directory.deletingLastPathComponent(), legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            checks["reopenKeepsNamesDraftsEventsAndGroupMembership"] = reopened.task(id)?.title == "审阅项目说明" && reopened.task(id)?.draft == "另一个窗口保存的输入" && reopened.task(id)?.events.first?.title == "保留事件" && reopened.organization.name(path, mode: .coding) == "审阅工作区" && reopened.organization.customGroups(.coding, tasks: reopened.tasks).first { $0.id == group }?.taskIDs == [id] && reopened.organization.taskView(.coding).grouping == .custom
            checks["noModelRequestsOrReceipts"] = requests == 0 && tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { $0.inputTokens == 0 && $0.outputTokens == 0 && $0.modelReceipts?.isEmpty != false && !$0.messages.contains { $0.role == "assistant" } }
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }; report["modelRequests"] = requests; report["appPID"] = getpid()
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("name-editor-report.json"))
    }
}
