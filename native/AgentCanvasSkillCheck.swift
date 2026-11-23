import AppKit

@MainActor extension AppDelegate {
    private struct SkillFormFixture: Codable {
        let taskID: String, other: String, id: String, tabID: String, windowID: String
        let original: String, changed: String, input: String, phrase: String
    }
    func runCanvasSkillFormCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], modelRequests = 0
        let stage = CommandLine.arguments.last ?? "seed"
        let fixturePath = output.appendingPathComponent("skill-form-fixture.json")
        do {
            ensureAgent()
            guard let tasks = agentStore, let runtime = agentRuntime, let host = control.window,
                  tasks.hooks.sharedHome == output.appendingPathComponent("shared-home") else { throw PetError("画布打包验收未隔离") }
            runtime.modelRequestCheck = { modelRequests += 1; throw PetError("画布打包验收禁止模型请求") }
            let workspace = control.taskWorkspace, storage = AgentWorkspaceRecovery(profile: store.directory)
            let destination = output.appendingPathComponent("packages", isDirectory: true)
            func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
            func inForm<T: NSView>(_ type: T.Type, _ form: AgentCanvasSkillWindow, label: String) throws -> T {
                guard let view = form.pageContentView, let result = allViews(view).compactMap({ $0 as? T }).first(where: { $0.accessibilityLabel() == label }) else {
                    throw PetError("原表单缺少 " + label)
                }
                return result
            }
            func action(_ name: String, _ form: AgentCanvasSkillWindow) throws -> NSButton {
                guard let view = form.pageContentView, let result = allViews(view).compactMap({ $0 as? NSButton }).first(where: { $0.title == name }) else { throw PetError("缺少打包操作 " + name) }
                return result
            }
            func enter(_ text: String, in field: NSTextField, form: AgentCanvasSkillWindow) {
                if let editor = field.currentEditor() as? NSTextView {
                    editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                } else {
                    field.stringValue = text
                    form.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
                }
            }
            func showField(_ view: NSView, in scroll: NSScrollView) {
                guard let document = scroll.documentView else { return }
                let y = document.convert(view.bounds, from: view).minY - 14
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(y, document.bounds.height - scroll.contentSize.height))))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            func screenshot(_ name: String) throws {
                guard let view = host.contentView, host.isVisible else { throw PetError("实际打包窗未显示") }
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw PetError("打包窗截图尺寸不可用") }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PetError("打包窗截图无法输出") }
                try png.write(to: output.appendingPathComponent(name + ".png"))
            }
            func checkpoint(_ fixture: SkillFormFixture) async throws -> AgentWorkspaceRecovery.Page {
                guard await flushWorkspaceWindows(), let page = try storage.loadPage(windowID: fixture.windowID, pageID: fixture.tabID, taskID: fixture.taskID) else {
                    throw PetError("画布打包表单未写入原标签")
                }
                return page.saved.value
            }
            func fullyVisible(_ view: NSView) -> Bool { !view.isHiddenOrHasHiddenAncestor && view.bounds.width > 0 && view.visibleRect.height + 1 >= view.bounds.height && view.visibleRect.width + 1 >= view.bounds.width }

            host.appearance = NSAppearance(named: .darkAqua); host.setContentSize(NSSize(width: 780, height: 540))
            let fixture: SkillFormFixture
            if stage == "seed" {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                let duplicate = destination.appendingPathComponent("already-there", isDirectory: true)
                try FileManager.default.createDirectory(at: duplicate, withIntermediateDirectories: false)
                try Data("保留已存在目录\n".utf8).write(to: duplicate.appendingPathComponent("sentinel.txt"))
                let task = tasks.create(title: "画布草稿恢复 · 无工作区问答", mode: .ask, workMode: .general), other = tasks.create(title: "独立任务", mode: .ask, workMode: .general)
                tasks.update(task) { $0.draft = "原工作台输入" }; tasks.update(other) { $0.draft = "另一任务输入" }
                let original = "export default function Canvas(){return <main><h1>公开画布 B 版本一</h1><button>公开控件</button></main>}"
                let record = try tasks.canvases.create(title: "公开画布 B", source: original, taskID: task)
                control.showAgentTask(task); control.show(tab: "chat")
                let editor = try await tasks.canvases.show(record.id, taskID: task)
                guard let windowID = control.workspaceSession?.id,
                      let tabID = workspace.recoveryLayouts.first(where: { $0.taskID == task })?.tabs.first(where: { $0.root == "canvas:" + record.id })?.id else {
                    throw PetError("无法读取原画布标签编号")
                }
                let phrase = "继续这里 😀", input = (1...38).map { $0 == 17 ? phrase : "第 \($0) 行使用实际数据与 Markdown 表格" }.joined(separator: "\n")
                fixture = .init(taskID: task, other: other, id: record.id, tabID: tabID, windowID: windowID, original: original,
                    changed: original.replacingOccurrences(of: "版本一", with: "版本二"), input: input, phrase: phrase)
                await editor.checkWorkspaceSource(action: "skill")
                guard let form = workspace.currentController as? AgentCanvasSkillWindow else { throw PetError("打包入口未打开工作区表单") }
                await wait(0.12)
                let export = try action("打包", form), name = try inForm(NSTextField.self, form, label: "画布 Skill 名称")
                let formatting = try inForm(NSTextView.self, form, label: "画布 Skill 格式约定"), formScroll = try inForm(NSScrollView.self, form, label: "画布 Skill 配置")
                let directory = try inForm(NSTextField.self, form, label: "画布 Skill 保存目录")
                checks["rightPageUsesSharedFieldsAndNoFloatingModal"] = form.settingsHostWindow === host && form.window?.isVisible != true && host.attachedSheet == nil &&
                    name is AgentDialogTextField && fullyVisible(export) && formScroll.documentView?.bounds.height ?? 0 > formScroll.contentSize.height
                try screenshot("skill-form-narrow-top")
                enter(destination.path, in: directory, form: form); enter("../invalid", in: name, form: form)
                export.performClick(nil)
                checks["invalidNameStaysInlineWithAllFieldsPreserved"] = try workspace.currentController === form && !form.captureDraft().status.isEmpty && form.captureDraft().destination == destination.path
                let choose = try inForm(NSButton.self, form, label: "选择 Skill 保存目录")
                showField(directory, in: formScroll); choose.performClick(nil); await wait(0.25)
                let picker = host.attachedSheet as? NSOpenPanel
                picker?.cancel(nil)
                await wait(0.12)
                checks["nativeFolderSheetBelongsToTaskAndCancelPreservesFields"] = try picker != nil && host.attachedSheet == nil &&
                    workspace.currentController === form && form.captureDraft().destination == destination.path && form.captureDraft().specification.name == "../invalid"
                host.makeFirstResponder(formatting)
                formatting.insertText(input, replacementRange: NSRange(location: 0, length: formatting.string.utf16.count))
                formatting.setSelectedRange((input as NSString).range(of: phrase)); formatting.scrollRangeToVisible(formatting.selectedRange())
                host.contentView?.layoutSubtreeIfNeeded(); showField(formatting, in: formScroll)
                checks["longEditorAndWholePageScrollWhilePrimaryActionStaysVisible"] = formatting.enclosingScrollView?.contentView.bounds.minY ?? 0 > 0 && formScroll.contentView.bounds.minY > 0 && fullyVisible(export)
                try screenshot("skill-form-narrow-long")
                do { try tasks.setArchived([task], archived: true); checks["archiveProtectsPendingForm"] = false }
                catch { checks["archiveProtectsPendingForm"] = tasks.task(task)?.archived == false && workspace.currentController === form }
                control.showAgentTask(other); control.showAgentTask(task)
                await wait(0.12)
                let page = try await checkpoint(fixture), recovered = try AgentCanvasWindow.recoveryState(page)
                guard let draft = recovered.skill else { throw PetError("打包正文未保存") }
                checks["windowCheckpointKeepsExactSourceAndAllInput"] = page.dirty && draft.sourceHash == record.hash && draft.specification.formatting == input &&
                    draft.destination == destination.path && draft.specification.name == "../invalid" && draft.focus == .formatting && draft.scrollY > 0
                checks["normalQuitCanPreserveParentAndChild"] = [ObjectIdentifier(editor), ObjectIdentifier(form)].allSatisfy { control.workspaceSession?.preservedEditors.contains($0) == true }
                var foreign = recovered; foreign.skill?.canvasID = UUID().uuidString
                var invalid = page; invalid.state = try JSONEncoder().encode(foreign)
                do { _ = try AgentCanvasWindow.recoveryState(invalid); checks["wrongCanvasCannotUseDraft"] = false }
                catch { checks["wrongCanvasCannotUseDraft"] = true }
                try JSONEncoder().encode(fixture).write(to: fixturePath, options: .atomic)
            } else {
                fixture = try JSONDecoder().decode(SkillFormFixture.self, from: Data(contentsOf: fixturePath))
                control.show(tab: "chat")
                guard await flushWorkspaceWindows(), control.agentTaskID == fixture.taskID,
                      let editor = workspace.rootController(.canvas(fixture.id)) as? AgentCanvasWindow else { throw PetError("原工作区标签未恢复") }
                if stage == "completed" {
                    let page = try await checkpoint(fixture)
                    checks["finishedPackageDoesNotRestoreAConsumedDraft"] = try workspace.currentController === editor && !page.dirty && AgentCanvasWindow.recoveryState(page).skill == nil
                } else {
                    guard let form = workspace.currentController as? AgentCanvasSkillWindow else { throw PetError("跨启动没有读回打包页") }
                    await wait(0.16)
                    let formatting = try inForm(NSTextView.self, form, label: "画布 Skill 格式约定"), name = try inForm(NSTextField.self, form, label: "画布 Skill 名称")
                    let outer = try inForm(NSScrollView.self, form, label: "画布 Skill 配置"), export = try action("打包", form)
                    checks["reopenKeepsDraftUTF16SelectionAndFieldFocus"] = formatting.string == fixture.input &&
                        formatting.selectedRange() == (fixture.input as NSString).range(of: fixture.phrase) && host.firstResponder === formatting &&
                        formatting.enclosingScrollView?.contentView.bounds.minY ?? 0 > 0 && outer.contentView.bounds.minY > 0
                    try screenshot("skill-form-reopened-narrow")
                    formatting.insertText("已接着编辑 ✅", replacementRange: formatting.selectedRange())
                    host.setContentSize(NSSize(width: 1320, height: 800)); host.appearance = NSAppearance(named: .aqua)
                    let before = try tasks.canvases.source(fixture.id, taskID: fixture.taskID)
                    let next = try tasks.canvases.update(fixture.id, source: fixture.changed, expected: before.record.hash, taskID: fixture.taskID)
                    export.performClick(nil)
                    let adopt = try action("使用当前版本", form)
                    let existing = try FileManager.default.contentsOfDirectory(atPath: destination.path)
                    checks["changedSourceBlocksExportAndShowsExplicitVersionChoice"] = !export.isEnabled && fullyVisible(adopt) &&
                        existing == ["already-there"]
                    try screenshot("skill-form-wide-version-conflict")
                    adopt.performClick(nil); enter("already-there", in: name, form: form); export.performClick(nil)
                    checks["existingDestinationStaysIntactAndFormCanRetry"] = try workspace.currentController === form &&
                        Data(contentsOf: destination.appendingPathComponent("already-there/sentinel.txt")) == Data("保留已存在目录\n".utf8) && !form.captureDraft().status.isEmpty
                    let reviewed = try form.captureDraft()
                    checks["explicitVersionChangeKeepsTheDraft"] = reviewed.sourceHash == next.hash &&
                        reviewed.specification.formatting == fixture.input.replacingOccurrences(of: fixture.phrase, with: "已接着编辑 ✅")
                    enter("public-canvas-skill", in: name, form: form); export.performClick(nil)
                    let page = try await checkpoint(fixture), source = destination.appendingPathComponent("public-canvas-skill/references/template.canvas.tsx")
                    checks["actualExportReturnsToTheOriginalCanvasAndClearsDraft"] = try workspace.currentController === editor && !page.dirty &&
                        AgentCanvasWindow.recoveryState(page).skill == nil && Data(contentsOf: source) == Data(fixture.changed.utf8)
                    try screenshot("skill-form-returned-canvas")
                }
            }
            checks["originalTaskInputsAndModelReceiptsStayExact"] = modelRequests == 0 && tasks.task(fixture.taskID)?.draft == "原工作台输入" &&
                tasks.task(fixture.other)?.draft == "另一任务输入" && [fixture.taskID, fixture.other].allSatisfy { (tasks.task($0)?.modelReceipts ?? []).isEmpty }
        } catch { report["error"] = error.localizedDescription }
        report["appPID"] = getpid(); report["stage"] = stage; report["modelRequests"] = modelRequests; report["checks"] = checks
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && modelRequests == 0
        try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("skill-form-report.json"), options: .atomic)
    }

    func runAgentCanvasSkillCheck(_ output: URL) async {
        let fm = FileManager.default
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        func call(_ name: String, _ args: [String: Any]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)) }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务运行时不可用") }
            try write(["appPID": getpid(), "arguments": CommandLine.arguments], "canvas-skill-process.json")
            let seed = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("source.json"))) as! [String: String]
            guard let sourceID = seed["taskID"], let original = tasks.task(sourceID), original.status == .completed, let sourceCanvas = original.canvases?.first else { throw PetError("需要已有真实模型完成的画布任务") }
            let source = try tasks.canvases.source(sourceCanvas.id, taskID: sourceID), previousReceipts = original.modelReceipts?.count ?? 0
            guard previousReceipts > 0 else { throw PetError("来源没有实际模型请求记录") }
            let nativeFile = output.appendingPathComponent("canvas-skill-native-report.json")
            if fm.fileExists(atPath: nativeFile.path) {
                let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: nativeFile)) as! [String: Any]
                guard saved["success"] as? Bool == true, saved["sourceHash"] as? String == source.record.hash, let values = saved["checks"] as? [String: Bool] else { throw PetError("原生复用检查未通过，不能跳过") }; checks = values
            } else {
            let specification = AgentCanvasSkillSpecification(name: "native-canvas-package", trigger: "根据实际销售数据生成画布", sources: "当前项目 sales.csv 的 item 和 amount", formatting: "金额两位小数，保留全部、仅B、图表与明细")
            let rendered = try await tasks.canvases.execute(call("canvas_inspect", ["id": sourceCanvas.id]), task: original)
            report["actualPreviewInspection"] = rendered.text
            checks["actualPreviewUsesRenderedCanvasAndCurrentSourceHash"] = !rendered.failed && tasks.canvases.previewImage(sourceCanvas, taskID: sourceID) != nil && !tasks.canvases.previewSignature(sourceCanvas, taskID: sourceID).isEmpty
            checks["nativePreviewDoesNotAddModelContextAttachmentsOrReceipts"] = tasks.task(sourceID)?.attachments?.count == original.attachments?.count && tasks.task(sourceID)?.modelReceipts?.count == previousReceipts
            let resources = try tasks.canvases.skillResources(sourceCanvas.id, taskID: sourceID, expected: source.record.hash, specification: specification)
            checks["packageContainsOnlyWorkflowAndExactActualModelSource"] = Set(resources.keys) == Set(["SKILL.md", "references/template.canvas.tsx"]) && resources["references/template.canvas.tsx"] == Data(source.code.utf8)
            do { _ = try tasks.canvases.skillResources(sourceCanvas.id, taskID: sourceID, expected: "stale", specification: specification); checks["staleCanvasCannotBePackaged"] = false } catch { checks["staleCanvasCannotBePackaged"] = true }
            var invalid = specification; invalid.name = "../outside"
            do { _ = try tasks.canvases.skillResources(sourceCanvas.id, taskID: sourceID, expected: source.record.hash, specification: invalid); checks["skillNameCannotEscapeChosenFolder"] = false } catch { checks["skillNameCannotEscapeChosenFolder"] = true }
            let folder: URL
            let existingFolder = output.appendingPathComponent(specification.name)
            if fm.fileExists(atPath: existingFolder.path) {
                guard try AgentExtensions.resourceData(AgentFiles(workspace: existingFolder.path)) == resources else { throw PetError("先前打包内容已变化，未覆盖") }; folder = existingFolder
            } else { folder = try tasks.canvases.exportSkill(sourceCanvas.id, taskID: sourceID, expected: source.record.hash, specification: specification, parent: output) }
            do { _ = try tasks.canvases.exportSkill(sourceCanvas.id, taskID: sourceID, expected: source.record.hash, specification: specification, parent: output); checks["existingPackageIsNotOverwritten"] = false } catch { checks["existingPackageIsNotOverwritten"] = try Data(contentsOf: folder.appendingPathComponent("SKILL.md")) == resources["SKILL.md"] }
            let imported: AgentExtensionItem
            if let existing = try tasks.extensions.catalog(workspace: original.workspace).first(where: { $0.name == specification.name && $0.kind == .skill }) { imported = existing }
            else { imported = try await tasks.extensions.importItem(folder, kind: .skill, project: false, workspace: original.workspace) }
            checks["exportedPackageMatchesActualImportedSkillResources"] = try AgentExtensions.resourceData(AgentFiles(workspace: imported.root.path)) == resources
            let link = output.appendingPathComponent("canvas-linked-package")
            if !fm.fileExists(atPath: link.path) { try fm.createSymbolicLink(at: link, withDestinationURL: folder) }
            var linked = specification; linked.name = link.lastPathComponent
            do { _ = try tasks.canvases.exportSkill(sourceCanvas.id, taskID: sourceID, expected: source.record.hash, specification: linked, parent: output); checks["exportDoesNotFollowExistingDirectoryLink"] = false } catch { checks["exportDoesNotFollowExistingDirectoryLink"] = true }
            guard let fork = tasks.fork(sourceID) else { throw PetError("预览任务分支失败") }
            let forked = try tasks.canvases.update(sourceCanvas.id, source: source.code + "\n// independent preview version\n", expected: source.record.hash, taskID: fork)
            checks["changedSourceRejectsEarlierPreviewAndOriginalRemainsValid"] = tasks.canvases.previewImage(forked, taskID: fork) == nil && tasks.canvases.previewImage(sourceCanvas, taskID: sourceID) != nil
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("画布预览或 Skill 原生检查未通过") }
            try write(["success": true, "checks": checks, "sourceHash": source.record.hash], nativeFile.lastPathComponent)
            }
            tasks.canvases.closeAll(); control.showAgentTask(sourceID); control.show(tab: "chat")
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("画布预览或 Skill 原生检查未通过") }
            try write(["phase": "package-and-import", "sourceTaskID": sourceID, "sourceCanvasID": sourceCanvas.id, "sourceHash": source.record.hash, "appPID": getpid()], "canvas-skill-ui-ready.json")
            if CommandLine.arguments.contains("--live-agent") {
                let start = output.appendingPathComponent("start-canvas-skill-live"), startDeadline = Date().addingTimeInterval(1200)
                while Date() < startDeadline, !fm.fileExists(atPath: start.path) { await wait(0.1) }
                guard fm.fileExists(atPath: start.path) else { throw PetError("等待真实 Skill 打包及导入超时") }
                guard let selected = try tasks.extensions.catalog(workspace: output.appendingPathComponent("repo").path).first(where: { $0.kind == .skill && $0.name == "weekly-sales-panel" }) else { throw PetError("真实界面尚未导入 weekly-sales-panel") }
                let exported = output.appendingPathComponent("weekly-sales-panel"), importedFiles = try AgentExtensions.resourceData(AgentFiles(workspace: selected.root.path)), exportedFiles = try AgentExtensions.resourceData(AgentFiles(workspace: exported.path))
                checks["actualUIPackageAndImportedTemplateMatchOriginalSource"] = importedFiles == exportedFiles && importedFiles["references/template.canvas.tsx"] == Data(source.code.utf8)
                var preferences = PreferencesStore(directory: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")).preferences
                let configured = ["context": preferences.contextLimit, "output": preferences.outputLimit]
                preferences.contextTokens = max(32768, preferences.contextTokens); preferences.replyTokens = max(2048, preferences.replyTokens); preferences.voiceEnabled = false; preferences.wakeEnabled = false; preferences.screenObservationEnabled = false; store.preferences = preferences
                report["preferences"] = ["saved": configured, "actual": ["context": preferences.contextLimit, "output": preferences.outputLimit], "productionSettingsWritten": false]
                let owner = output.appendingPathComponent("canvas-skill-live-task.json"), id: String
                let intent = "/skill:weekly-sales-panel 使用当前项目 sales.csv 重新生成销售画布，核对合计、行数及全部、仅B两种筛选。保留模板布局和交互，不修改输入文件。"
                if fm.fileExists(atPath: owner.path) {
                    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: owner)) as! [String: String]
                    guard let previous = saved["taskID"], tasks.task(previous)?.messages.first(where: \.isHumanInput)?.content == intent else { throw PetError("原真实 Skill 任务不存在，不能替换") }; id = previous
                    if tasks.task(id)?.status != .completed { runtime.start(id) }
                } else {
                    let profile = AgentProfile(name: "实际画布 Skill", description: "读取实际输入并复用画布工作流", instructions: "遵循选定 Skill，读取当前实际数据并核对画布。", tools: ["read_file", "list_directory"] + AgentCanvas.tools, readOnly: false, network: false, enabled: true, skills: [selected.id])
                    let (_, version) = try tasks.agents.document(), values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try tasks.agents.list() + [profile]))
                    try tasks.agents.save(String(decoding: try JSONSerialization.data(withJSONObject: ["agents": values]), as: UTF8.self), expectedHash: version)
                    id = try tasks.agents.createTask(profile.id, store: tasks, workspace: output.appendingPathComponent("repo").path); tasks.update(id) { $0.title = "画布 Skill 实际复用" }
                    guard runtime.submit(intent, taskID: id) else { throw PetError("真实 Skill 任务未开始：" + (runtime.submissionError ?? "")) }
                    try write(["taskID": id, "originalInputID": tasks.task(id)?.messages.first(where: \.isHumanInput)?.id ?? ""], owner.lastPathComponent)
                }
                var approvals = 0
                func approve() throws {
                    guard let task = tasks.task(id), task.status == .waiting, let call = task.pendingCalls.first else { return }
                    guard AgentCanvas.writes.contains(call.name), approvals < 16, call.name == "canvas_create" ? (task.canvases ?? []).isEmpty : task.canvases?.first?.id == call.object["id"] as? String else { throw PetError("真实 Skill 模型提出预期外审批") }
                    runtime.decide(taskID: id, callID: call.id, decision: "allow"); approvals += 1
                }
                let deadline = Date().addingTimeInterval(300)
                while Date() < deadline {
                    try approve(); let task = tasks.task(id)!
                    if task.status == .completed && !runtime.isExecuting(id) { break }
                    if [.failed, .stopped].contains(task.status), !runtime.isExecuting(id) { throw PetError("真实 Skill 任务失败：" + (task.events.last?.detail ?? "")) }; await wait(0.1)
                }
                guard let task = tasks.task(id), task.status == .completed, let canvas = task.canvases?.first else { throw PetError("真实 Skill 任务未完成") }
                let window = try await tasks.canvases.show(canvas.id, taskID: id), observed = try await window.inspect(), text = observed["text"] as? String ?? ""
                checks["actualModelRegeneratesWithDifferentCurrentCsvValues"] = text.contains("49.50") && text.contains("7.65") && !text.contains("19.90") && (observed["bar_count"] as? Int) == 3 && (observed["table_row_count"] as? Int) == 3
                checks["actualModelLoadsSkillAndReadsTemplateResource"] = task.activeSkills?.contains(where: { $0.id == selected.id }) == true && task.events.contains { $0.title == "read_skill_resource" && $0.status == "completed" }
                checks["reusedCanvasHasActualInlineSnapshot"] = tasks.canvases.previewImage(canvas, taskID: id) != nil
                let exportedHTML = try window.exportHTML(try tasks.canvases.source(canvas.id, taskID: id).code)
                try exportedHTML.write(to: output.appendingPathComponent("reused-canvas.html"), options: .atomic)
                report["export"] = ["file": "reused-canvas.html", "sha256": AgentFiles.hash(exportedHTML)]
                tasks.canvases.closeAll(); control.showAgentTask(id); control.show(tab: "chat")
                try write(["phase": "reused", "taskID": id, "canvasID": canvas.id, "sourceHash": canvas.hash, "appPID": getpid()], "canvas-skill-ui-ready.json")
                if CommandLine.arguments.contains("--hold-ui") {
                    let deadline = Date().addingTimeInterval(1200)
                    while Date() < deadline, !fm.fileExists(atPath: output.appendingPathComponent("finish-canvas-skill-ui").path) { try approve(); await wait(0.1) }
                }
                if let currentWindow = tasks.canvases.windows.values.first(where: { $0.taskID == id }) { report["renderedAfterUI"] = try await currentWindow.inspect() }
                let final = tasks.task(id)!
                report["live"] = ["taskID": id, "canvasID": canvas.id, "sourceHash": final.canvases?.first?.hash ?? "", "model": preferences.model, "requests": final.modelReceipts?.count ?? 0, "inputTokens": final.inputTokens, "outputTokens": final.outputTokens, "renderedBeforeUI": observed, "skillID": selected.id, "approvals": final.approvals.filter { $0.decision == "allow" }.count]
            }
            let retainedHash = try tasks.canvases.source(sourceCanvas.id, taskID: sourceID).record.hash
            checks["originalRealModelMessagesAndReceiptsPreserved"] = tasks.task(sourceID)?.messages.map(\.id) == original.messages.map(\.id) && tasks.task(sourceID)?.modelReceipts?.count == previousReceipts && retainedHash == source.record.hash
            report["source"] = ["taskID": sourceID, "canvasID": sourceCanvas.id, "sourceHash": source.record.hash, "previousActualRequests": previousReceipts]
            report["checks"] = checks; report["success"] = checks.values.allSatisfy { $0 }; try write(report, "canvas-skill-report.json")
            tasks.canvases.closeAll(); runtime.stopAll()
        } catch { report["success"] = false; report["checks"] = checks; report["error"] = error.localizedDescription; try? write(report, "canvas-skill-report.json"); agentRuntime?.stopAll() }
    }
}
