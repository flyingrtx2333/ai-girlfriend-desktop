import AppKit

@MainActor extension AppDelegate {
    private struct WorkspaceEditorFixture: Codable {
        let tasks: [String: String]
        let windows: [String: String]
        let drafts: [String: AgentWorkspaceEditorDraft]
    }

    func runWorkspaceEditorDraftCheck(_ output: URL) async {
        let args = CommandLine.arguments
        let stage = args.firstIndex(of: "--recovery-stage").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "seed"
        let fixtureURL = output.appendingPathComponent("workspace-editor-draft-fixture.json")
        let finalName = "Alpha 已保存的工作区"
        let externalName = "Beta 另一窗口已保存的文件夹"
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        func find<T: NSView>(_ root: NSView, _ type: T.Type, where matches: (T) -> Bool) -> T? {
            if let view = root as? T, !view.isHiddenOrHasHiddenAncestor, matches(view) { return view }
            for child in root.subviews {
                if let result = find(child, type, where: matches) { return result }
            }
            return nil
        }
        func button(_ editor: AgentWorkspaceEditor, _ label: String) throws -> NSButton {
            guard let result = find(editor.view, NSButton.self, where: {
                $0.isEnabled && ($0.title == label || $0.accessibilityLabel() == label)
            }) else { throw PetError("缺少工作区操作 " + label) }
            return result
        }
        func typeName(_ editor: AgentWorkspaceEditor, _ text: String) throws -> NSTextView {
            editor.focusName(selectAll: true)
            guard let input = find(editor.view, NSTextField.self, where: { $0.identifier?.rawValue == "workspace-editor-name" }),
                  let textView = input.currentEditor() as? NSTextView else { throw PetError("工作区名称未获得焦点") }
            textView.insertText(text, replacementRange: textView.selectedRange())
            return textView
        }
        func snapshot(_ owner: ControlWindow) throws -> AgentWorkspaceEditorDraft {
            guard let draft = owner.captureWorkspaceEditorDraft() else { throw PetError("未捕获工作区设置草稿") }
            return draft
        }
        func render(_ host: NSWindow, _ name: String) throws {
            guard let content = host.contentView else { throw PetError("缺少验收窗口") }
            content.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw PetError("验收窗口图像不可用") }
            bitmap.size = content.bounds.size
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PetError("验收窗口图像编码失败") }
            try png.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
        }
        func errorText(_ editor: AgentWorkspaceEditor) -> String {
            find(editor.view, NSTextField.self, where: { $0.accessibilityLabel() == "工作区保存状态" })?.stringValue ?? ""
        }
        do {
            ensureAgent()
            guard let tasks = agentStore, let runtime = agentRuntime, workspaceRecoveryEnabled,
                  tasks.extensions.sharedHome?.standardizedFileURL == output.appendingPathComponent("shared-home").standardizedFileURL else {
                throw PetError("工作区设置续编验收只允许独立目录")
            }
            runtime.modelRequestCheck = { requests += 1; throw PetError("恢复验收禁止模型请求") }
            let organization = store.directory.appendingPathComponent("organization.json")
            let journal = AgentWorkspaceRecovery(profile: store.directory)

            if stage == "seed" {
                var owners: [String: String] = [:], windows: [String: String] = [:], drafts: [String: AgentWorkspaceEditorDraft] = [:]
                func setup(_ role: String, mode: AgentWorkMode, count: Int) throws -> [String] {
                    let root = output.appendingPathComponent(role)
                    let folders = [root] + (1..<count).map { output.appendingPathComponent(role + "-source-" + String($0)) }
                    for folder in folders {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                        try Data(("# Public " + folder.lastPathComponent + "\n").utf8).write(to: folder.appendingPathComponent("README.md"))
                    }
                    try tasks.organization.register(root.path, mode: mode)
                    guard let entry = tasks.organization.entry(root.path, mode: mode, tasks: tasks.tasks) else { throw PetError("工作区样例未注册") }
                    try tasks.organization.editWorkspace(entry, name: role + " 原配置", icon: .folder, color: .forest,
                        folders: folders.map(\.path), primary: root.path, tasks: tasks.tasks)
                    owners[role] = try tasks.createWorkspaceTask(root.path, mode: mode, title: role + " 工作区续编", taskMode: .ask, draft: "PUBLIC_COMPOSER_" + role)
                    return folders.map(\.path)
                }
                let alphaSources = try setup("Alpha", mode: .coding, count: 2)
                let betaSources = try setup("Beta", mode: .general, count: 16)
                guard let alphaID = owners["Alpha"], let betaID = owners["Beta"] else { throw PetError("缺少公开任务") }
                owners["Other"] = tasks.create(title: "无工作区公开问答", mode: .ask, workMode: .general, draft: "PUBLIC_COMPOSER_Other")
                control.showAgentTask(alphaID); control.show(tab: "chat")
                openTaskWindow(betaID, from: control)
                guard let child = additionalTaskWindows.last, let alphaHost = control.window, let betaHost = child.window else {
                    throw PetError("缺少原任务窗口")
                }
                alphaHost.setContentSize(NSSize(width: 1320, height: 800))
                betaHost.setContentSize(NSSize(width: 780, height: 540))
                child.showAttentionPage()
                let before = try Data(contentsOf: organization)
                child.checkNameEditor("directory", id: betaSources[0], mode: .general)
                guard let beta = child.workspaceEditor else { throw PetError("通用文件夹编辑未打开") }
                _ = try typeName(beta, "Beta 未保存的文件夹")
                try button(beta, "图标：咖啡").performClick(nil)
                try button(beta, "颜色：琥珀").performClick(nil)
                try button(beta, "设为主文件夹：" + betaSources[15]).performClick(nil)
                try button(beta, "移除源文件夹：" + betaSources[4]).performClick(nil)
                guard let scroll = find(beta.view, NSScrollView.self, where: { $0.accessibilityLabel() == "工作区设置" }) else { throw PetError("缺少工作区滚动表单") }
                betaHost.makeFirstResponder(nil); betaHost.contentView?.layoutSubtreeIfNeeded()
                AgentSettingsRecovery.restoreScroll(360, to: scroll)

                alphaHost.makeKeyAndOrderFront(nil)
                control.checkNameEditor("directory", id: alphaSources[0])
                guard let alpha = control.workspaceEditor else { throw PetError("编程工作区编辑未打开") }
                try button(alpha, "图标：小猫").performClick(nil)
                try button(alpha, "颜色：紫色").performClick(nil)
                try button(alpha, "设为主文件夹：" + alphaSources[1]).performClick(nil)
                let invalidName = "续编😀" + String(repeating: "公开", count: 40)
                let field = try typeName(alpha, invalidName)
                field.setSelectedRange(NSRange(location: 0, length: 4))
                try button(alpha, "保存").performClick(nil)
                guard await flushWorkspaceWindows(), let a = control.workspaceSession?.id, let b = child.workspaceSession?.id else {
                    throw PetError("工作区草稿未写入恢复区")
                }
                windows = ["Alpha": a, "Beta": b]
                drafts = ["Alpha": try snapshot(control), "Beta": try snapshot(child)]
                guard let first = drafts["Alpha"], let second = drafts["Beta"] else { throw PetError("缺少草稿记录") }
                checks["seedUsesActualFieldEditorAndKeepsInvalidRawInput"] = first.name == invalidName && first.nameFocused &&
                    first.selection?.range == NSRange(location: 0, length: 4) && first.feedback?.contains("80") == true
                checks["secondWindowStoresScrollAndReturnPage"] = !second.nameFocused && second.scrollY > 0 &&
                    second.returnPage == "attention" && second.folders.count == 15 && second.primary == betaSources[15]
                checks["bothSnapshotsHaveDirectoryIdentities"] = first.folderIdentities.count == 2 && second.folderIdentities.count == 15
                checks["bothWindowsReadyForNormalQuit"] = control.workspaceSession?.preservedEditors.contains(ObjectIdentifier(alpha)) == true &&
                    child.workspaceSession?.preservedEditors.contains(ObjectIdentifier(beta)) == true
                checks["checkpointDoesNotModifyOrganization"] = try Data(contentsOf: organization) == before
                do {
                    try control.requireTaskDeletionAllowed([alphaID])
                    checks["ownerDeletionProtectedWhileDraftOpen"] = false
                } catch { checks["ownerDeletionProtectedWhileDraftOpen"] = error.localizedDescription.contains("工作区设置草稿") }
                try JSONEncoder().encode(WorkspaceEditorFixture(tasks: owners, windows: windows, drafts: drafts)).write(to: fixtureURL, options: .atomic)
            } else {
                let fixture = try JSONDecoder().decode(WorkspaceEditorFixture.self, from: Data(contentsOf: fixtureURL))
                control.show(tab: "chat"); restoreAdditionalWorkspaceWindows()
                guard await flushWorkspaceWindows(), let child = additionalTaskWindows.first(where: { $0.workspaceSession?.id == fixture.windows["Beta"] }),
                      let a = fixture.drafts["Alpha"], let b = fixture.drafts["Beta"], let alphaHost = control.window, let betaHost = child.window else {
                    throw PetError("原工作区窗口未恢复")
                }
                func config(_ value: AgentWorkspaceEditorDraft) -> AgentDirectoryEntry? {
                    tasks.organization.entry(value.original.path, mode: value.original.mode, tasks: tasks.tasks)
                }
                checks["originalWindowAndTaskOwners"] = control.workspaceSession?.id == fixture.windows["Alpha"] &&
                    control.agentTaskID == fixture.tasks["Alpha"] && child.agentTaskID == fixture.tasks["Beta"]
                checks["originalComposerInputsAndEmptyHistories"] = fixture.tasks.allSatisfy { role, id in
                    tasks.task(id)?.draft == "PUBLIC_COMPOSER_" + role && tasks.task(id)?.messages.isEmpty == true &&
                        tasks.task(id)?.mode == .ask
                }
                if stage == "reopen" {
                    guard let alpha = control.workspaceEditor, let beta = child.workspaceEditor else { throw PetError("原窗口没有打开续编页面") }
                    alphaHost.makeKeyAndOrderFront(nil)
                    let first = try snapshot(control), second = try snapshot(child)
                    func sameForm(_ actual: AgentWorkspaceEditorDraft, _ saved: AgentWorkspaceEditorDraft) -> Bool {
                        actual.name == saved.name && actual.icon == saved.icon && actual.color == saved.color &&
                        actual.folders == saved.folders && actual.primary == saved.primary && actual.context == saved.context &&
                        actual.original == saved.original && actual.folderIdentities == saved.folderIdentities
                    }
                    checks["rawNamesPalettesAndFolderRowsRestore"] = sameForm(first, a) && sameForm(second, b)
                    checks["originalFocusSelectionAndScrollRestore"] = first.nameFocused && first.selection == a.selection &&
                        !second.nameFocused && second.scrollY > 0 && abs(second.scrollY - b.scrollY) < 1 && second.returnPage == "attention"
                    report["seedScroll"] = b.scrollY; report["recoveredScroll"] = second.scrollY
                    checks["draftsAreInlineAndNoNativeDialogIsBlocking"] = alpha.isPageVisible && beta.isPageVisible &&
                        alphaHost.attachedSheet == nil && betaHost.attachedSheet == nil && NSApp.modalWindow == nil
                    checks["bothRecoveryIssuesVisible"] = errorText(alpha).contains("暂不可用") && errorText(beta).contains("配置已变化")
                    alphaHost.appearance = NSAppearance(named: .aqua); betaHost.appearance = NSAppearance(named: .darkAqua)
                    try render(alphaHost, "alpha-restored-light")
                    try render(betaHost, "beta-restored-dark")
                    let before = try Data(contentsOf: organization)
                    try button(alpha, "保存").performClick(nil)
                    checks["offlineSourceCannotSave"] = try errorText(alpha).contains("暂不可用") && Data(contentsOf: organization) == before
                    let source = URL(fileURLWithPath: a.primary)
                    let moved = output.appendingPathComponent("alpha-source-offline")
                    let replacement = output.appendingPathComponent("alpha-source-replacement")
                    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
                    try button(alpha, "保存").performClick(nil)
                    checks["samePathReplacementCannotSave"] = try errorText(alpha).contains("已被替换") && Data(contentsOf: organization) == before
                    try FileManager.default.moveItem(at: source, to: replacement)
                    try FileManager.default.moveItem(at: moved, to: source)
                    try button(alpha, "保存").performClick(nil)
                    checks["reconnectedFolderStillRequiresValidName"] = try errorText(alpha).contains("80") && snapshot(control).name == a.name &&
                        Data(contentsOf: organization) == before
                    try tasks.organization.sort(.name, mode: .coding)
                    _ = try typeName(alpha, finalName)
                    try button(alpha, "保存").performClick(nil)
                    let saved = config(a)
                    checks["explicitSaveAppliesOnlyOriginalWorkspaceEvenAfterUnrelatedEdit"] = control.workspaceEditor == nil &&
                        saved?.name == finalName && saved?.icon == a.icon && saved?.color == a.color && saved?.sourceFolders == a.folders &&
                        saved?.primary == a.primary && config(b)?.name == externalName && fixture.tasks["Alpha"].flatMap(tasks.task)?.workspace == a.original.primary
                    let after = try Data(contentsOf: organization)
                    try button(beta, "保存").performClick(nil)
                    checks["staleConfigurationCannotOverwriteAndKeepsDraft"] = try Data(contentsOf: organization) == after &&
                        snapshot(child).name == b.name && errorText(beta).contains("配置已变化")
                    try button(beta, "取消").performClick(nil)
                    checks["cancelReturnsToOriginalInbox"] = child.workspaceEditor == nil && child.captureAttentionRecovery()?.active == true
                } else {
                    guard stage == "closed" else { throw PetError("未知的工作区恢复验收阶段") }
                    checks["completedEditorsDoNotReopen"] = control.workspaceEditor == nil && child.workspaceEditor == nil &&
                        config(a)?.name == finalName && config(b)?.name == externalName
                }
                guard await flushWorkspaceWindows() else { throw PetError("保存后恢复区未更新") }
                var empty = true
                for id in fixture.windows.values {
                    if let saved = try journal.loadWorkspaceEditorDrafts(windowID: id), !saved.value.drafts.isEmpty { empty = false }
                }
                checks["saveAndCancelClearOnlyTheirRecoveryRecords"] = empty
            }
        } catch {
            report["error"] = error.localizedDescription
            for window in taskControls {
                if let editor = window.workspaceEditor { (try? button(editor, "取消"))?.performClick(nil) }
            }
        }
        checks["noModelRequests"] = requests == 0
        report["checks"] = checks; report["modelRequests"] = requests; report["pid"] = getpid()
        if let binary = Bundle.main.executableURL {
            report["binarySHA256"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
        }
        report["success"] = report["error"] == nil && checks.values.allSatisfy { $0 }
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) {
            try? bytes.write(to: output.appendingPathComponent("workspace-editor-draft-" + stage + ".json"), options: .atomic)
        }
    }
}
