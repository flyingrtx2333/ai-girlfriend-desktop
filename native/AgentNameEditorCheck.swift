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
        defer { control.window?.cancelAgentDialog(); agentRuntime?.stopAll() }
        func find<T: NSView>(_ type: T.Type, in view: NSView?, matching predicate: (T) -> Bool) -> T? {
            guard let view else { return nil }; if let value = view as? T, predicate(value) { return value }
            for child in view.subviews { if let value = find(type, in: child, matching: predicate) { return value } }; return nil
        }
        func field(_ name: String, _ sheet: AgentDialogController) throws -> NSTextField {
            guard let value = find(NSTextField.self, in: sheet.view, matching: { $0.accessibilityLabel() == name }) else { throw PetError("缺少命名字段：" + name) }; return value
        }
        func click(_ title: String, _ sheet: AgentDialogController) throws {
            guard let value = find(NSButton.self, in: sheet.view, matching: { $0.title == title }) else { throw PetError("缺少命名操作：" + title) }; value.performClick(nil)
        }
        func closed(_ host: NSWindow) async throws {
            let limit = Date().addingTimeInterval(5)
            while host.agentDialog != nil, Date() < limit { await wait(0.02) }
            guard host.agentDialog == nil else { throw PetError("命名表单未关闭") }
            await wait(0.05)
        }
        func record(_ file: URL) throws -> Data {
            var value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            value["title"] = nil; value["updated"] = nil
            return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        }
        func contrast(_ front:NSColor,_ back:NSColor,_ view:NSView) -> CGFloat {
            var foreground:NSColor?, background:NSColor?
            view.effectiveAppearance.performAsCurrentDrawingAppearance { foreground = front.usingColorSpace(.sRGB); background = back.usingColorSpace(.sRGB) }
            guard let a = foreground, let b = background else { return 0 }
            func luminance(_ values:[CGFloat]) -> CGFloat { zip(values,[CGFloat(0.2126),0.7152,0.0722]).reduce(0) { $0 + ($1.0 <= 0.04045 ? $1.0/12.92 : pow(($1.0+0.055)/1.055,2.4))*$1.1 } }
            let alpha = a.alphaComponent, backgroundRGB = [b.redComponent,b.greenComponent,b.blueComponent]
            let frontRGB = zip([a.redComponent,a.greenComponent,a.blueComponent],backgroundRGB).map{$0*alpha+$1*(1-alpha)}
            let x = luminance(frontRGB), y = luminance(backgroundRGB); return (max(x,y)+0.05)/(min(x,y)+0.05)
        }
        do {
            checks.merge(try await checkDialogEditingIsolation()) { _, next in next }
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
            guard let sheet = host.agentDialog else { throw PetError("任务名称表单未打开") }
            await wait(0.05)
            let input = try field("任务名称", sheet), originalFocus = input.currentEditor()
            checks["renameUsesStyledOwnedCardWithSelectedInput"] = host.isVisible && sheet.isVisible && sheet.view.window === host && host.attachedSheet == nil && sheet.view is AgentThemeView && NSApp.modalWindow == nil && originalFocus != nil && input.stringValue == "项目说明"
            checks["nameInputBoundaryVisibleBeforeTyping"] = input.isBezeled && (input.layer?.borderWidth ?? 0) >= 1
            if let cancel = find(NSButton.self, in: sheet.view, matching: { $0.title == "取消" }) {
                host.makeFirstResponder(cancel); await wait(0.05)
                checks["nameFocusBoundaryClearsWhenFocusMoves"] = input.layer?.borderWidth == 0
                host.makeFirstResponder(input); await wait(0.05)
                checks["nameFocusBoundaryRestoresWithoutTyping"] = input.currentEditor() != nil && (input.layer?.borderWidth ?? 0) >= 1
            }
            let inheritedAppearance = sheet.view.appearance; var actionContrasts:[String:[String:CGFloat]] = [:]
            for look in [NSAppearance.Name.aqua,.darkAqua] {
                sheet.view.appearance = NSAppearance(named:look); await wait(0.05)
                var values:[String:CGFloat] = [:]
                for title in ["取消","保存"] {
                    if let button = find(NSButton.self,in:sheet.view,matching:{$0.title == title}), let foreground = button.attributedTitle.attribute(.foregroundColor,at:0,effectiveRange:nil) as? NSColor {
                        let fill = AgentThemeContext.resolve(title == "保存" ? AgentWorkbenchTheme.accent : AgentWorkbenchTheme.subtle,in:button)
                        values[title] = contrast(foreground,fill,button)
                    }
                }
                checks["actualDialogActionTextContrast-" + look.rawValue] = values.count == 2 && values.values.allSatisfy{$0 >= 4.5}; actionContrasts[look.rawValue] = values
            }
            sheet.view.appearance = inheritedAppearance; await wait(0.05); report["actualDialogActionContrasts"] = actionContrasts
            let navigationBefore = tasks.tasks.map(\.id), selectedBefore = tasks.selectedID
            control.performShortcut(.newTask); control.performShortcut(.switchTask)
            checks["dialogBlocksBackgroundTaskShortcuts"] = !control.canPerformShortcut(.newTask) && !control.canPerformShortcut(.switchTask) && tasks.tasks.map(\.id) == navigationBefore && tasks.selectedID == selectedBefore
            checks["parentCloseKeepsOpenNameEditor"] = !control.windowShouldClose(host) && host.agentDialog === sheet
            for (name, size) in [("normal", NSSize(width: 1200, height: 774)), ("narrow", NSSize(width: 780, height: 540))] {
                host.setContentSize(size); sheet.view.layoutSubtreeIfNeeded()
                let root = sheet.view, actions = ["取消", "保存"].compactMap { title in find(NSButton.self, in: root, matching: { $0.title == title }) }
                let area = host.contentView!.bounds, card = host.contentView!.convert(sheet.view.bounds, from: sheet.view)
                checks["cardStaysCentered-" + name] = abs(card.midX-area.midX) < 0.6 && abs(card.midY-area.midY) < 0.6
                checks["nameEditorFits-" + name] = !input.hasAmbiguousLayout && abs(sheet.cardFrame.width - 384) < 1 && input.bounds.width >= 320 && input.bounds.height >= 30 && actions.count == 2 && ([input] + actions).allSatisfy { root.bounds.contains(root.convert($0.bounds, from: $0)) && $0.visibleRect.height >= $0.bounds.height - 1 }
            }
            input.stringValue = "   "; try click("保存", sheet)
            checks["invalidNameRetainsInputAndInlineErrorWithoutWrites"] = try host.agentDialog === sheet && input.stringValue == "   " && field("名称保存状态", sheet).stringValue.contains("120") && Data(contentsOf: taskFile) == before && Data(contentsOf: index) == indexBefore
            let error = try field("名称保存状态", sheet)
            checks["inlineErrorExpandsFormWithoutClippingControls"] = !error.isHidden && error.visibleRect.height >= error.bounds.height - 1 && sheet.view.bounds.contains(sheet.view.convert(error.bounds, from: error))
            input.stringValue = "尚未保存的名称"; try click("取消", sheet); try await closed(host)
            checks["cancelLeavesTaskAndIndexByteIdentical"] = try Data(contentsOf: taskFile) == before && Data(contentsOf: index) == indexBefore
            control.checkNameEditor("task", id: id)
            guard let savedSheet = host.agentDialog else { throw PetError("无法重开命名表单") }
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
            guard let staleSheet = host.agentDialog else { throw PetError("缺少冲突表单") }
            try field("任务名称", staleSheet).stringValue = "保留冲突填写"
            tasks.update(id) { $0.draft = "另一个窗口保存的输入" }; let changed = try Data(contentsOf: taskFile), changedIndex = try Data(contentsOf: index)
            try click("保存", staleSheet)
            checks["staleTaskCannotOverwriteNewDraftAndRetainsName"] = try field("名称保存状态", staleSheet).stringValue.contains("已变化") && field("任务名称", staleSheet).stringValue == "保留冲突填写" && Data(contentsOf: taskFile) == changed && Data(contentsOf: index) == changedIndex
            try click("取消", staleSheet); try await closed(host)
            control.checkNameEditor("task", id: id)
            guard let failedSheet = host.agentDialog else { throw PetError("缺少保存失败表单") }
            try field("任务名称", failedSheet).stringValue = "保留未写入的名称"
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: taskFile.path)
            try click("保存", failedSheet)
            checks["writeFailureKeepsEditorCacheTaskAndIndex"] = try !field("名称保存状态", failedSheet).stringValue.isEmpty && field("任务名称", failedSheet).stringValue == "保留未写入的名称" && tasks.task(id)?.title == "审阅项目说明" && Data(contentsOf: taskFile) == changed && Data(contentsOf: index) == changedIndex
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: taskFile.path)
            try click("取消", failedSheet); try await closed(host)
            control.checkNameEditor("task", id: id)
            guard let runningSheet = host.agentDialog else { throw PetError("缺少执行状态表单") }
            try field("任务名称", runningSheet).stringValue = "保留运行中的填写"; tasks.update(id) { $0.status = .running }
            let running = try Data(contentsOf: taskFile), runningIndex = try Data(contentsOf: index)
            try click("保存", runningSheet)
            checks["taskStartingAfterOpenCannotBeRenamed"] = try field("名称保存状态", runningSheet).stringValue.contains("运行") && field("任务名称", runningSheet).stringValue == "保留运行中的填写" && Data(contentsOf: taskFile) == running && Data(contentsOf: index) == runningIndex
            try click("取消", runningSheet); try await closed(host); tasks.update(id) { $0.status = .ready }
            let orgBefore = try Data(contentsOf: organization), taskBeforeGroups = try Data(contentsOf: taskFile)
            control.checkNameEditor("group", id: nil)
            guard let groupSheet = host.agentDialog else { throw PetError("分组表单未打开") }
            try field("分组名称", groupSheet).stringValue = "已有分组"; try click("保存", groupSheet)
            checks["duplicateGroupStaysInEditorWithoutOrganizationWrite"] = try field("名称保存状态", groupSheet).stringValue.contains("已存在") && field("分组名称", groupSheet).stringValue == "已有分组" && Data(contentsOf: organization) == orgBefore
            try field("分组名称", groupSheet).stringValue = "新建的分组"; try click("保存", groupSheet); try await closed(host)
            checks["newGroupAndCustomViewPersistTogether"] = tasks.organization.customGroups(.coding, tasks: tasks.tasks).contains { $0.name == "新建的分组" } && tasks.organization.taskView(.coding).grouping == .custom
            control.checkNameEditor("group", id: group)
            guard let renameGroup = host.agentDialog else { throw PetError("分组重命名未打开") }
            try field("分组名称", renameGroup).stringValue = "审阅分组"; try click("保存", renameGroup); try await closed(host)
            checks["groupRenamePreservesMembershipAndTaskBytes"] = try tasks.organization.customGroups(.coding, tasks: tasks.tasks).first { $0.id == group }.map { $0.name == "审阅分组" && $0.taskIDs == [id] } == true && Data(contentsOf: taskFile) == taskBeforeGroups
            control.checkNameEditor("group", id: group)
            guard let staleGroup = host.agentDialog else { throw PetError("分组冲突表单未打开") }
            try field("分组名称", staleGroup).stringValue = "保留分组填写"; try tasks.organization.sort(.name, mode: .coding); let newerOrg = try Data(contentsOf: organization)
            try click("保存", staleGroup)
            checks["organizationChangeRejectsStaleEditorWithoutLosingInput"] = try field("名称保存状态", staleGroup).stringValue.contains("已变化") && field("分组名称", staleGroup).stringValue == "保留分组填写" && Data(contentsOf: organization) == newerOrg
            try click("取消", staleGroup); try await closed(host)
            for (mode, directory, label, name) in [(AgentWorkMode.coding, path, "工作区名称", "审阅工作区"), (.general, folder, "文件夹名称", "审阅资料夹")] {
                let readme = URL(fileURLWithPath: directory).appendingPathComponent("README.md"), projectBytes = try Data(contentsOf: readme)
                control.checkNameEditor("directory", id: directory, mode: mode)
                guard let directorySheet = host.agentDialog else { throw PetError("目录名称表单未打开") }
                let directoryInput = try field(label, directorySheet); directoryInput.stringValue = String(repeating: "长", count: 81); try click("保存", directorySheet)
                checks["directoryErrorRetainsInput-" + mode.rawValue] = try directoryInput.stringValue.count == 81 && field("工作区保存状态", directorySheet).stringValue.contains("80")
                directoryInput.stringValue = name; try click("保存", directorySheet); try await closed(host)
                checks["directoryRenameIsDisplayOnly-" + mode.rawValue] = try tasks.organization.name(directory, mode: mode) == name && Data(contentsOf: readme) == projectBytes && Data(contentsOf: taskFile) == taskBeforeGroups
            }
            control.showAgentTask(none); control.checkNameEditor("task", id: none)
            guard let noneSheet = host.agentDialog else { throw PetError("无工作区问答名称表单未打开") }
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

@MainActor private func checkDialogEditingIsolation() async throws -> [String: Bool] {
    var checks: [String: Bool] = [:], closed = 0
    let owner = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 780, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    owner.isReleasedWhenClosed = false
    let root = AgentThemeView(fill: AgentWorkbenchTheme.surface), original = NSTextView(frame: NSRect(x: 20, y: 20, width: 400, height: 100))
    original.isRichText = false; original.string = "原输入：中文 🧭"; root.addSubview(original)
    let backgroundDefault = NSButton(title: "背景默认操作", target: nil, action: nil); root.addSubview(backgroundDefault)
    owner.contentView = root; owner.defaultButtonCell = backgroundDefault.cell as? NSButtonCell
    owner.makeKeyAndOrderFront(nil); owner.makeFirstResponder(original)
    defer { owner.cancelAgentDialog(); owner.close() }
    let beforeEditor = original
    beforeEditor.allowsUndo = true; beforeEditor.setSelectedRange(NSRange(location: (beforeEditor.string as NSString).length, length: 0))
    beforeEditor.insertText("继续", replacementRange: beforeEditor.selectedRange()); beforeEditor.breakUndoCoalescing()
    try await Task.sleep(for: .milliseconds(50))
    let expected = beforeEditor.string, selection = NSRange(location: 2, length: 3), originalUndo = beforeEditor.undoManager
    beforeEditor.setSelectedRange(selection)
    let editor = AgentNameEditor(title: "公开隔离检查", label: "隔离名称", value: "原名称", save: { _ in }, onClose: { closed += 1 })
    editor.begin(in: owner)
    guard let dialogEditor = owner.firstResponder as? NSTextView else { throw PetError("弹窗输入未获得字段编辑器") }
    checks["dialogStartsWithActualInitialTextAndTextContainer"] = dialogEditor.textContainer != nil && dialogEditor.string == "原名称"
    checks["dialogUsesSeparateFieldEditorAndUndoManager"] = dialogEditor !== beforeEditor && dialogEditor.undoManager !== originalUndo && originalUndo?.canUndo == true
    checks["dialogHidesBackgroundFromAccessibility"] = original.isAccessibilityHidden() && editor.view.isAccessibilityModal() && owner.agentDialog === editor && owner.attachedSheet == nil
    checks["dialogExposesActualModalAccessibilityElement"] = editor.view.isAccessibilityElement() && editor.view.accessibilityRole() == .sheet && editor.view.isAccessibilityModal()
    checks["dialogReplacesBackgroundDefaultButton"] = owner.defaultButtonCell !== backgroundDefault.cell && owner.defaultButtonCell?.title == "保存"
    checks["dialogDisablesOwnerCloseButton"] = owner.standardWindowButton(.closeButton)?.isEnabled == false
    dialogEditor.insertText("仅弹窗修改", replacementRange: dialogEditor.selectedRange()); dialogEditor.breakUndoCoalescing()
    try await Task.sleep(for: .milliseconds(50))
    let undoItem = NSMenuItem(title: "撤销", action: Selector("undo:"), keyEquivalent: "z")
    let redoItem = NSMenuItem(title: "重做", action: Selector("redo:"), keyEquivalent: "z")
    checks["dialogMenuUndoTargetsIsolatedEditor"] = (NSApp.target(forAction: undoItem.action!) as? NSTextView) === dialogEditor && dialogEditor.validateUserInterfaceItem(undoItem)
    let undoSent = NSApp.sendAction(undoItem.action!, to: nil, from: undoItem)
    checks["dialogMenuUndoRestoresNameWithoutChangingDraft"] = undoSent && dialogEditor.string == "原名称" && beforeEditor.string == expected
    checks["dialogMenuRedoTargetsIsolatedEditor"] = (NSApp.target(forAction: redoItem.action!) as? NSTextView) === dialogEditor && dialogEditor.validateUserInterfaceItem(redoItem) && !dialogEditor.validateUserInterfaceItem(undoItem)
    let redoSent = NSApp.sendAction(redoItem.action!, to: nil, from: redoItem)
    checks["dialogMenuRedoRestoresOnlyNameEdit"] = redoSent && dialogEditor.string == "仅弹窗修改" && beforeEditor.string == expected
    _ = NSApp.sendAction(undoItem.action!, to: nil, from: undoItem)
    checks["dialogUndoCannotChangeOriginalText"] = dialogEditor.string == "原名称" && beforeEditor.string == expected
    let dialogSelection = NSRange(location: 1, length: 1); dialogEditor.setSelectedRange(dialogSelection); editor.focusDialog()
    checks["refocusingDialogDoesNotResetCurrentSelection"] = owner.firstResponder === dialogEditor && dialogEditor.selectedRange() == dialogSelection && dialogEditor.string == "原名称"
    let other = AgentNameEditor(title: "不会嵌套", label: "第二名称", value: "", save: { _ in }, onClose: {})
    other.begin(in: owner)
    checks["secondDialogCannotReplaceActiveForm"] = owner.agentDialog === editor && !other.isVisible
    if let delegate = NSApp.delegate as? AppDelegate { checks["applicationQuitKeepsActiveDialog"] = delegate.applicationShouldTerminate(NSApp) == .terminateCancel }
    editor.cancel()
    checks["cancelRestoresOriginalTextAndSelection"] = owner.firstResponder === beforeEditor && beforeEditor.string == expected && beforeEditor.selectedRange() == selection
    checks["cancelRestoresBackgroundAccessibilityAndDefault"] = !original.isAccessibilityHidden() && owner.defaultButtonCell === backgroundDefault.cell && !owner.hasBlockingDialog && closed == 1
    checks["cancelRestoresOwnerCloseButton"] = owner.standardWindowButton(.closeButton)?.isEnabled == true
    originalUndo?.undo()
    checks["originalUndoStillWorksAfterDialogCancellation"] = beforeEditor.string == "原输入：中文 🧭"
    // A standard single-line field ends its native edit when focus leaves it.
    // Preserve its value and caret; the composer above keeps its full undo stack.
    let field = NSTextField(frame: NSRect(x: 20, y: 140, width: 400, height: 32)); field.stringValue = "保留设置字段 🧭"; root.addSubview(field)
    owner.makeFirstResponder(field); field.selectText(nil)
    guard let fieldEditor = field.currentEditor() as? NSTextView else { throw PetError("设置字段未获得编辑焦点") }
    fieldEditor.setSelectedRange(selection)
    let second = AgentNameEditor(title: "设置字段焦点", label: "临时名称", value: "临时输入", save: { _ in }, onClose: {})
    second.begin(in: owner); second.cancel()
    checks["stockTextFieldRetainsValueCaretAndNativeFieldEditor"] = field.currentEditor() === fieldEditor && owner.firstResponder === fieldEditor && field.stringValue == "保留设置字段 🧭" && fieldEditor.selectedRange() == selection
    var savedByKey: [String] = [], shortcutCloses = 0
    let shortcutEditor = AgentNameEditor(title: "快捷保存验收", label: "快捷保存名称", value: "快捷保存原名称", save: { savedByKey.append($0) }, onClose: { shortcutCloses += 1 })
    for round in 1...2 {
        shortcutEditor.begin(in: owner)
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: owner.windowNumber, context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1) else { throw PetError("无法创建快捷保存验收事件") }
        NSApp.postEvent(event, atStart: true)
        let deadline = Date().addingTimeInterval(3)
        while shortcutEditor.isVisible, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        checks["commandSaveInvokesActualActionAfterDefaultCellSetup-\(round)"] = !shortcutEditor.isVisible && shortcutCloses == round && savedByKey == Array(repeating: "快捷保存原名称", count: round)
        if shortcutEditor.isVisible { shortcutEditor.cancel() }
    }
    return checks
}
