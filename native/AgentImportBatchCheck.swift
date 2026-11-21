import AppKit

@MainActor extension AppDelegate {
    func checkSSHImportWindow(_ output: URL, tasks: AgentStore, binaryHash: String) async throws {
        let navigation = output.appendingPathComponent("ssh-window-navigation.json")
        let reopening = FileManager.default.fileExists(atPath: navigation.path)
        guard let window = control.window, let content = window.contentView else { throw PetError("设置窗口不可用") }
        let size = reopening ? NSSize(width: 1320, height: 800) : NSSize(width: 780, height: 540)
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
        window.makeKeyAndOrderFront(nil)

        func find<T: NSView>(_ view: NSView, _ type: T.Type, _ match: (T) -> Bool) -> T? {
            guard !view.isHiddenOrHasHiddenAncestor else { return nil }
            if let result = view as? T, match(result) { return result }
            for child in view.subviews {
                if let result = find(child, type, match) { return result }
            }
            return nil
        }
        func button(_ title: String) throws -> NSButton {
            guard let control = find(content, NSButton.self, { $0.title == title && $0.isEnabled }) else { throw PetError("缺少导入操作 " + title) }
            return control
        }
        func settle(_ pending: () -> Bool) async throws {
            let limit = Date().addingTimeInterval(60)
            while pending(), Date() < limit { await wait(0.05) }
            guard !pending() else { throw PetError("SSH 窗口操作未结束") }
        }
        func chooseSSH(_ route: AgentImportRoute) throws {
            guard control.showSettingsCategory("imports"),
                  let location = find(content, NSSegmentedControl.self, { $0.accessibilityIdentifier() == "import-location" }),
                  let action = location.action,
                  let source = find(content, NSSegmentedControl.self, { $0.accessibilityIdentifier() == "import-sources" }),
                  let choose = source.action else { throw PetError("缺少 SSH 导入入口") }
            location.selectedSegment = 1
            NSApp.sendAction(action, to: location.target, from: location)
            source.selectedSegment = AgentImportSource.allCases.firstIndex(of: route.source) ?? 0
            NSApp.sendAction(choose, to: source.target, from: source)
            guard let host = find(content, NSTextField.self, { $0.accessibilityIdentifier() == "import-ssh-host" }),
                  let directory = find(content, NSTextField.self, { $0.accessibilityIdentifier() == "import-ssh-directory" }) else { throw PetError("缺少 SSH 来源字段") }
            host.stringValue = route.sshHost ?? ""
            directory.stringValue = route.root
            directory.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: directory))
        }
        func openCategory(_ category: AgentImportCategory) throws {
            let id = "import-category-" + category.rawValue
            guard let row = find(content, NSButton.self, { $0.accessibilityIdentifier() == id && $0.isEnabled }) else {
                throw PetError("缺少导入类别 " + category.title)
            }
            row.performClick(nil)
        }
        func detectSSH(_ route: AgentImportRoute) throws {
            try chooseSSH(route)
            try openCategory(route.category)
            try button("重新检测").performClick(nil)
        }
        var checks: [String: Bool] = [:]
        var requests = 0
        agentRuntime?.modelRequestCheck = { requests += 1; throw PetError("SSH 窗口检查无需模型") }
        let importer = tasks.dataImport
        let root = output.appendingPathComponent("Codex '公开样例'")
        let route = AgentImportRoute(source: .codex, category: .tasks, root: root.path, workspace: nil, sshHost: "whale-import")
        if CommandLine.arguments.contains("--ssh-skills-import-check") {
            let skills = AgentImportRoute(source: .codex, category: .skills, root: root.path, workspace: nil, sshHost: route.sshHost)
            let memory = AgentImportRoute(source: .codex, category: .memory, root: root.path, workspace: nil, sshHost: route.sshHost)
            let phase = output.appendingPathComponent("ssh-skills-paused.json"), fm = FileManager.default
            let release = root.appendingPathComponent("skills/release-check")
            let changed = root.appendingPathComponent(".agents/skills/source-changed/references/version.md")
            func write(_ value: [String: Any], to file: URL) throws {
                try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: file, options: .atomic)
            }
            func resources(_ folder: URL) throws -> [String: Data] {
                try AgentExtensions.resourceData(AgentFiles(workspace: folder.path))
            }
            if !fm.fileExists(atPath: phase.path) {
                try chooseSSH(route)
                try button("检测可导入内容").performClick(nil)
                try await settle { importer.scanning || importer.preview(for: skills) == nil }
                let records = importer.preview(for: skills)?.records ?? [], available = records.filter { $0.issue == nil }
                checks["overviewDetectsTasksMemoryAndSkills"] = importer.preview(for: route)?.available.count == 2 &&
                    importer.preview(for: memory)?.available.count == 1 && available.count == 2
                checks["modernAndLegacySkillDirectoriesAreDetected"] = Set(available.map(\.title)) == ["release-check", "source-changed"]
                checks["unsafeAndOversizedPackagesAreReportedIndependently"] = records.count == 6 &&
                    records.contains { $0.title == "link-resource" && $0.issue?.contains("符号链接") == true } &&
                    records.contains { $0.title == "private-resource" && $0.issue?.contains("受保护") == true } &&
                    records.contains { $0.title == "large-file" && $0.issue?.contains("2 MB") == true } &&
                    records.contains { $0.title == "large-package" && $0.issue?.contains("20 MB") == true }
                guard let index = records.firstIndex(where: { $0.title == "release-check" }) else {
                    throw PetError(importer.preview(for: skills)?.issue ?? "缺少 SSH Skill 预览")
                }
                let expected = try resources(release), selected = records[index]
                checks["wholePackageDigestCoversOnlyPackagedFiles"] = expected.count == 4 && selected.skill?.fileCount == expected.count &&
                    selected.sourceHash == AgentExtensions.digest(expected)
                try openCategory(.skills)
                guard let list = find(content, NSTableView.self, { $0.accessibilityLabel() == "可导入Skills" }) else { throw PetError("缺少 Skills 预览列表") }
                list.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                content.layoutSubtreeIfNeeded()
                let detail = find(content, NSTextView.self, { $0.accessibilityLabel() == "导入预览" })
                let confirm = try button("导入 5 项")
                checks["narrowReviewShowsOriginResourceCountAndConfirm"] = detail?.string.contains("whale-import:" + release.path) == true &&
                    detail?.string.contains("4 个文件") == true && confirm.visibleRect.width >= confirm.bounds.width - 1 &&
                    confirm.visibleRect.height >= confirm.bounds.height - 1 && find(content, NSButton.self, { $0.title == "来源文件" }) == nil
                checks["reviewedSkillSelectionIsSaved"] = control.captureSettingsNavigation()?.dataImport?.routes
                    .first(where: { $0.route == skills })?.checked?.count == 2
                try button("返回导入").performClick(nil)
                let notify = importer.onChange
                importer.onChange = { [weak importer] in
                    notify?()
                    if let importer, importer.batch?.state == "running", importer.batch?.items.filter({ $0.state == "imported" }).count == 3 {
                        importer.pause()
                    }
                }
                defer { importer.onChange = notify }
                try button("导入 5 项").performClick(nil)
                try await settle { importer.active || importer.batch == nil }
                guard let batch = importer.batch, batch.state == "paused" else { throw PetError("SSH Skills 混合批次没有暂停") }
                checks["tasksAndMemoryCompleteBeforePausedSkills"] = batch.items.filter { $0.state == "imported" && $0.record.category != .skills }.count == 3 &&
                    batch.items.filter { $0.state == "pending" && batch.route(for: $0) == skills }.count == 2
                try Data("技能资源在预览后更新\n".utf8).write(to: changed)
                try write(["batch": batch.id, "pid": getpid(), "checks": checks, "modelRequests": requests], to: phase)
                return
            }
            let initial = try JSONSerialization.jsonObject(with: Data(contentsOf: phase)) as? [String: Any] ?? [:]
            checks = initial["checks"] as? [String: Bool] ?? [:]
            checks["restartRestoresOriginalSkillSourceAndSelection"] = initial["pid"] as? Int != Int(getpid()) &&
                importer.batch?.id == initial["batch"] as? String && importer.unfinished &&
                importer.batch?.items.filter { $0.state == "pending" && $0.record.category == .skills && $0.record.sshHost == route.sshHost }.count == 2
            guard control.showSettingsCategory("imports") else { throw PetError("不能恢复 SSH Skills 导入页") }
            try button("继续导入").performClick(nil)
            try await settle { importer.active }
            guard let completed = importer.batch, let copied = completed.items.first(where: { $0.record.title == "release-check" }),
                  let stale = completed.items.first(where: { $0.record.title == "source-changed" }) else { throw PetError("缺少 SSH Skills 恢复结果") }
            let installed = try AgentSkillImport.destinationURL(copied.record, store: tasks)
            let currentResources = try resources(installed), originalResources = try resources(release)
            checks["globalInstallKeepsAllNestedBinaryAndTextResources"] = copied.state == "imported" && currentResources == originalResources
            checks["changedResourceSkipsOnlyTheOriginalSkill"] = completed.state == "completed" && stale.state == "failed" &&
                stale.detail.contains("资源已变化") && (try? AgentSkillImport.destinationURL(stale.record, store: tasks)) == nil &&
                completed.items.filter { $0.state == "imported" }.count == 4
            let script = try AgentFiles(workspace: installed.path).entryMetadata(installed.appendingPathComponent("scripts/check.sh"))
            checks["importOnlyCopiesScriptBytes"] = script.permissions == 0o600 &&
                !fm.fileExists(atPath: output.appendingPathComponent("unexpected-script-output").path)
            try detectSSH(skills)
            try await settle { importer.scanning || importer.preview(for: skills) == nil }
            checks["rescanningFindsInstalledDigestAndNewSourceVersion"] = importer.preview(for: skills)?.records.contains {
                $0.title == "release-check" && $0.issue == "已经导入"
            } == true && importer.preview(for: skills)?.available.count == 1
            try button("返回导入").performClick(nil)

            let qoderRoot = output.appendingPathComponent("Qoder 会话"), project = output.appendingPathComponent("本机 Skill 项目")
            let qoder = AgentImportRoute(source: .qoder, category: .skills, root: qoderRoot.path, workspace: project.path, sshHost: route.sshHost)
            try fm.createDirectory(at: project, withIntermediateDirectories: true)
            try tasks.organization.register(project.path, mode: .coding)
            try chooseSSH(qoder)
            try openCategory(.skills)
            guard let picker = find(content, NSPopUpButton.self, { $0.accessibilityLabel() == "Skills目标" }),
                  let destination = picker.itemArray.first(where: { $0.representedObject as? String == project.path }), let action = picker.action else {
                throw PetError("SSH Skills 缺少项目目标选择")
            }
            picker.select(destination)
            NSApp.sendAction(action, to: picker.target, from: picker)
            checks["navigationKeepsSelectedProjectWithRemoteSkillSource"] = control.captureSettingsNavigation()?.dataImport?.routes.contains { $0.route == qoder } == true
            try button("重新检测").performClick(nil)
            try await settle { importer.scanning || importer.preview(for: qoder) == nil }
            guard let preview = importer.preview(for: qoder), preview.available.count == 1,
                  let item = preview.records.first(where: { $0.title == "project-brief" && $0.issue == nil }) else {
                throw PetError(importer.preview(for: qoder)?.issue ?? "缺少 Qoder 项目 Skill")
            }
            try button("导入 1 项").performClick(nil)
            try await settle { importer.active }
            let target = try AgentSkillImport.destinationURL(item, store: tasks)
            let qoderSource = qoderRoot.appendingPathComponent(".qoder/skills/交付 '简报'")
            let projectResources = try resources(target), expectedResources = try resources(qoderSource)
            let global = try tasks.extensions.catalog(workspace: nil).map(\.name)
            let local = try tasks.extensions.catalog(workspace: project.path).first { $0.name == item.title }
            checks["qoderPackageAppearsInOnlyTheChosenProject"] = importer.batch?.items.first?.state == "imported" &&
                projectResources == expectedResources && local?.managed == true && local?.scope == "项目" && !global.contains(item.title)
            let profile = tasks.directory.deletingLastPathComponent()
            checks["noTransferScratchRemains"] = try !fm.contentsOfDirectory(atPath: profile.path).contains { $0.hasPrefix("ssh-import-transfer-") }
            let success = checks.values.allSatisfy { $0 } && requests == 0 && initial["modelRequests"] as? Int == 0
            try write(["checks": checks, "binaryHash": binaryHash, "appPID": getpid(), "modelRequests": requests, "success": success],
                      to: output.appendingPathComponent("ssh-skills-report.json"))
            guard success else { throw PetError("SSH Skills 导入检查失败") }
            return
        }
        if CommandLine.arguments.contains("--ssh-memory-import-check") {
            let memory = AgentImportRoute(source: .codex, category: .memory, root: root.path, workspace: nil, sshHost: route.sshHost)
            let phase = output.appendingPathComponent("ssh-memory-paused.json")
            let primary = root.appendingPathComponent("memories_v2/MEMORY.md")
            let summary = root.appendingPathComponent("memories/memory_summary.md")
            let fm = FileManager.default
            func installed(_ record: AgentImportCandidate) throws -> Data {
                try AgentMemoryImport.destinationURLs(record, store: tasks).reduce(into: Data()) { $0.append(try Data(contentsOf: $1)) }
            }
            func write(_ value: [String: Any], to url: URL) throws {
                try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
            }
            if !fm.fileExists(atPath: phase.path) {
                try chooseSSH(route)
                let categories = AgentImportCategory.allCases.filter { category in
                    find(content, NSButton.self, { $0.accessibilityIdentifier() == "import-category-" + category.rawValue }) != nil
                }
                checks["overviewShowsSupportedSSHCategories"] = Set(categories) == Set([.tasks, .memory, .skills])
                try button("检测可导入内容").performClick(nil)
                try await settle { importer.scanning || importer.preview(for: memory) == nil }
                let records = importer.preview(for: memory)?.records ?? [], valid = records.filter { $0.issue == nil }
                let confirm = try button("导入 4 项")
                checks["oneScanShowsBothCategories"] = importer.preview(for: route)?.available.count == 2 && valid.count == 2 && confirm.isEnabled
                let previousPaths = Set([primary.path, summary.path])
                checks["codexOnlyReadsDurableMarkdownAndReportsInvalidFiles"] = Set(valid.map(\.file)) == previousPaths && records.count == 4 &&
                    records.contains { $0.issue?.contains("UTF-8") == true } && records.contains { $0.issue?.contains("4 MB") == true }
                guard let index = records.firstIndex(where: { $0.file == primary.path }) else { throw PetError("缺少 SSH 主记忆预览") }
                let expected = try Data(contentsOf: primary)
                checks["previewHashesTheExactBytesAndPlansTopics"] = records[index].rawHash == AgentFiles.hash(expected) &&
                    records[index].memory?.parts.count == AgentMemoryImport.split(expected).count && records[index].sshHost == route.sshHost
                try openCategory(.memory)
                guard let list = find(content, NSTableView.self, { $0.accessibilityLabel() == "可导入记忆" }) else { throw PetError("缺少 SSH 记忆列表") }
                list.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                let detail = find(content, NSTextView.self, { $0.accessibilityLabel() == "导入预览" })
                let saved = control.captureSettingsNavigation()?.dataImport
                checks["previewShowsRemoteOriginAndGlobalTarget"] = detail?.string.contains("whale-import:" + primary.path) == true &&
                    detail?.string.contains("全局记忆") == true && find(content, NSButton.self, { $0.title == "来源文件" }) == nil
                checks["navigationKeepsBothReviewedRoutes"] = saved?.category == .memory && saved?.ssh == true &&
                    saved?.routes.first(where: { $0.route == memory })?.checked?.count == 2 &&
                    saved?.routes.first(where: { $0.route == route })?.checked?.count == 2
                try button("返回导入").performClick(nil)
                let notify = importer.onChange
                importer.onChange = { [weak importer] in
                    notify?()
                    if let importer, importer.batch?.state == "running", importer.batch?.items.filter({ $0.state == "imported" }).count == 2 {
                        importer.pause()
                    }
                }
                defer { importer.onChange = notify }
                try button("导入 4 项").performClick(nil)
                try await settle { importer.active || importer.batch == nil }
                guard let batch = importer.batch, batch.state == "paused" else { throw PetError("SSH 混合批次没有暂停") }
                checks["pausingAfterTasksFreezesBothMemories"] = batch.items.filter { $0.state == "imported" && batch.route(for: $0) == route }.count == 2 &&
                    batch.items.filter { $0.state == "pending" && batch.route(for: $0) == memory }.count == 2
                try Data("预览后修改的公开来源\n".utf8).write(to: summary)
                try write(["batch": batch.id, "pid": getpid(), "checks": checks], to: phase)
                return
            }
            let initial = try JSONSerialization.jsonObject(with: Data(contentsOf: phase)) as? [String: Any] ?? [:]
            checks = initial["checks"] as? [String: Bool] ?? [:]
            checks["anotherProcessRestoresPausedRemoteBatch"] = initial["pid"] as? Int != Int(getpid()) &&
                importer.batch?.id == initial["batch"] as? String && importer.unfinished && importer.batch?.state == "paused"
            guard control.showSettingsCategory("imports") else { throw PetError("不能恢复 SSH 导入页") }
            try button("继续导入").performClick(nil)
            try await settle { importer.active }
            guard let completed = importer.batch, let main = completed.items.first(where: { $0.record.file == primary.path }),
                  let changed = completed.items.first(where: { $0.record.file == summary.path }) else { throw PetError("缺少 SSH 恢复结果") }
            let imported = try installed(main.record), expected = try Data(contentsOf: primary)
            checks["globalMemoryRetainsExactBytesAfterRestart"] = main.state == "imported" && imported == expected
            let rejected = try installed(changed.record)
            checks["changedRemoteMemoryIsRejectedWithoutBlockingTheBatch"] = completed.state == "completed" && changed.state == "failed" &&
                changed.detail.contains("来源记忆已更新") && rejected.isEmpty
            checks["restoringDoesNotReimportTheCompletedTasks"] = tasks.tasks.filter { $0.importOrigin?.sshHost == route.sshHost }.count == 2

            let qoderRoot = output.appendingPathComponent("Qoder 项目别名")
            let project = output.appendingPathComponent("本机目标项目")
            let qoder = AgentImportRoute(source: .qoder, category: .memory, root: qoderRoot.path, workspace: nil, sshHost: route.sshHost)
            let target = AgentImportRoute(source: .qoder, category: .memory, root: qoder.root, workspace: project.path, sshHost: qoder.sshHost)
            try fm.createDirectory(at: project, withIntermediateDirectories: true)
            try tasks.organization.register(project.path, mode: .coding)
            try detectSSH(qoder)
            try await settle { importer.scanning || importer.preview(for: qoder) == nil }
            checks["qoderProjectAliasRequiresLocalProjectTarget"] = importer.preview(for: qoder)?.issue?.contains("选择目标项目") == true
            guard let picker = find(content, NSPopUpButton.self, { $0.accessibilityLabel() == "记忆目标" }),
                  let item = picker.itemArray.first(where: { $0.representedObject as? String == project.path }),
                  let action = picker.action else { throw PetError("SSH 记忆缺少项目目标选择") }
            picker.select(item)
            NSApp.sendAction(action, to: picker.target, from: picker)
            checks["navigationKeepsRemoteHostAndLocalProject"] = control.captureSettingsNavigation()?.dataImport?.routes.contains { $0.route == target } == true
            try button("重新检测").performClick(nil)
            try await settle { importer.scanning || importer.preview(for: target) == nil }
            guard let records = importer.preview(for: target)?.records, records.count == 1, let record = records.first, record.issue == nil else {
                throw PetError(importer.preview(for: target)?.issue ?? "Qoder 项目记忆预览有误")
            }
            try button("导入 1 项").performClick(nil)
            try await settle { importer.active }
            let bytes = try installed(record), global = try AgentMemory.importDestination(store: tasks, workspace: nil).folder
            let sourceBytes = try Data(contentsOf: qoderRoot.appendingPathComponent("memory/项目约定.md"))
            checks["qoderMemoryIsOnlyWrittenToTheChosenProject"] = importer.batch?.items.first?.state == "imported" &&
                bytes == sourceBytes && !fm.fileExists(atPath: global.appendingPathComponent("项目约定.md").path)
            let profile = tasks.directory.deletingLastPathComponent()
            checks["noTransferScratchRemains"] = try !fm.contentsOfDirectory(atPath: profile.path).contains { $0.hasPrefix("ssh-import-transfer-") }
            let success = checks.values.allSatisfy { $0 } && requests == 0
            try write(["checks": checks, "binaryHash": binaryHash, "appPID": getpid(), "modelRequests": requests, "success": success],
                      to: output.appendingPathComponent("ssh-memory-report.json"))
            guard success else { throw PetError("SSH 记忆导入检查失败") }
            return
        }
        if CommandLine.arguments.contains("--ssh-import-stream-check") {
            struct Fixture: Decodable {
                struct Record: Decodable { let id: String; let sha256: String }
                let bytes: Int
                let records: [Record]
            }
            let fixtureURL = output.deletingLastPathComponent().appendingPathComponent("large-fixture.json")
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
            let marker = output.appendingPathComponent("slow-stream-ready.json")
            let slow = AgentImportRoute(source: .codex, category: .tasks, root: output.appendingPathComponent("Slow read").path,
                                       workspace: nil, sshHost: route.sshHost)
            try detectSSH(slow)
            try await settle { !FileManager.default.fileExists(atPath: marker.path) }
            let stop = try button("停止检测")
            content.layoutSubtreeIfNeeded()
            checks["stopAvailableInNarrowWindowDuringRealTransfer"] = importer.canStopScan(for: slow) && stop.visibleRect.width >= stop.bounds.width - 1 &&
                find(content, NSButton.self, { $0.accessibilityIdentifier() == "import-ssh-confirm" && $0.isEnabled }) == nil
            if let pixels = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: pixels)
                try pixels.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("ssh-stream-scanning.png"))
            }
            let requested = Date()
            stop.performClick(nil)
            try await settle { importer.scanning }
            checks["stopDiscardsIncompletePreviewAndReleasesScan"] = Date().timeIntervalSince(requested) < 5 && importer.stoppedScan == slow &&
                importer.preview(for: slow) == nil && !importer.active && find(content, NSTextField.self, { $0.stringValue == "已停止检测" }) != nil
            try button("重新检测").performClick(nil)
            try await settle { importer.scanning || importer.preview(for: slow) == nil }
            checks["sameSourceCanRetryAfterCancellation"] = importer.preview(for: slow)?.available.count == 1 && importer.stoppedScan == nil

            try button("返回导入").performClick(nil)
            try detectSSH(route)
            try await settle { importer.scanning || importer.preview(for: route) == nil }
            let records = importer.preview(for: route)?.records ?? []
            checks["largeArchiveShowsEveryValidRecordAndItsHash"] = fixture.bytes > 256 * 1024 * 1024 &&
                records.filter { $0.issue == nil }.count == fixture.records.count + 2 && fixture.records.allSatisfy { wanted in
                    records.contains { $0.sourceID.lowercased() == wanted.id.lowercased() && $0.rawHash == wanted.sha256 && $0.issue == nil }
                }
            guard let last = fixture.records.last, let index = records.firstIndex(where: { $0.sourceID.lowercased() == last.id.lowercased() }),
                  let list = find(content, NSTableView.self, { $0.accessibilityLabel() == "可导入任务记录" }) else { throw PetError(importer.preview(for: route)?.issue ?? "缺少大档案预览") }
            let selected = records[index]
            try button("全选").performClick(nil)
            list.scrollRowToVisible(index)
            guard let choice = list.view(atColumn: 0, row: index, makeIfNecessary: true) as? NSButton else { throw PetError("缺少大档案勾选入口") }
            choice.performClick(nil)
            try button("导入 1 项").performClick(nil)
            try await settle { importer.active || importer.batch == nil }
            let saved = try importer.sourceURL(selected.targetID)
            let files = try AgentFiles(workspace: saved.deletingLastPathComponent().path)
            let copiedHash = try files.fileHash(saved)
            checks["onlyTheSelectedLargeRecordIsCopiedIntact"] = importer.batch?.items.count == 1 && importer.batch?.items.first?.state == "imported" &&
                copiedHash == last.sha256 && tasks.task(selected.targetID)?.messages.last?.content == "文档全文已保留"
            let profile = tasks.directory.deletingLastPathComponent()
            checks["scanAndCancellationLeaveNoTransferFiles"] = try !FileManager.default.contentsOfDirectory(atPath: profile.path)
                .contains { $0.hasPrefix("ssh-import-transfer-") }
            let report: [String: Any] = ["appPID": getpid(), "binaryHash": binaryHash, "archiveBytes": fixture.bytes, "windowSize": [size.width, size.height],
                "checks": checks, "modelRequests": requests, "sourceSHA256": copiedHash, "success": checks.values.allSatisfy { $0 } && requests == 0]
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                .write(to: output.appendingPathComponent("ssh-stream-report.json"), options: .atomic)
            return
        }
        if reopening {
            let saved = try JSONDecoder().decode(AgentSettingsRecovery.Navigation.self, from: Data(contentsOf: navigation))
            try control.materializeSettingsNavigation(saved)
            await wait(0.2)
            let actual = control.captureSettingsNavigation()?.dataImport
            checks["restoresTheOriginalSourceAndSingleChoice"] = actual?.category == .tasks && actual?.ssh == true && actual?.routes.first(where: { $0.route == route })?.checked?.count == 1
            checks["openingThePageDoesNotConnect"] = importer.preview(for: route) == nil && !importer.scanning
            try button("重新检测").performClick(nil)
        } else {
            try detectSSH(route)
        }
        try await settle { importer.scanning || importer.preview(for: route) == nil }
        guard let records = importer.preview(for: route)?.records,
              let archiveIndex = records.firstIndex(where: \.archived),
              let choiceIndex = records.firstIndex(where: { $0.file.hasSuffix("/reviewed.jsonl") }),
              let list = find(content, NSTableView.self, { $0.accessibilityLabel() == "可导入任务记录" }) else { throw PetError(importer.preview(for: route)?.issue ?? "缺少远端记录预览") }
        let chosen = records[choiceIndex]
        if !reopening {
            guard let archive = list.view(atColumn: 0, row: archiveIndex, makeIfNecessary: true) as? NSButton else { throw PetError("缺少归档记录复选框") }
            archive.performClick(nil)
            list.selectRowIndexes(IndexSet(integer: choiceIndex), byExtendingSelection: false)
        }
        content.layoutSubtreeIfNeeded()
        guard let confirm = find(content, NSButton.self, { $0.accessibilityIdentifier() == "import-ssh-confirm" }),
              let detail = find(content, NSTextView.self, { $0.accessibilityLabel() == "导入预览" }) else { throw PetError("缺少页首确认或来源预览") }
        checks["usesRequestedWindowSize"] = window.frame.size == size
        checks["confirmationIsVisibleWithThePreviewExpanded"] = confirm.isEnabled && confirm.title == "导入 1 项" && confirm.bounds.height >= 26 &&
            confirm.visibleRect.height >= confirm.bounds.height - 1 && confirm.visibleRect.width >= confirm.bounds.width - 1
        checks["previewShowsTheOriginalRecordAndHost"] = list.selectedRow == choiceIndex && detail.string.contains(chosen.title) && detail.string.contains("whale-import:" + chosen.file)
        if reopening {
            confirm.performClick(nil)
            try await settle { importer.active || importer.batch == nil }
            let url = try importer.sourceURL(chosen.targetID)
            let bytes = try Data(contentsOf: url)
            checks["onlyTheReviewedItemIsImportedThroughThePage"] = importer.batch?.items.count == 1 && importer.batch?.items.first?.state == "imported" &&
                tasks.task(chosen.targetID)?.importOrigin?.sshHost == "whale-import" && AgentFiles.hash(bytes) == chosen.rawHash &&
                tasks.task(records[archiveIndex].targetID) == nil
        } else {
            guard let state = control.captureSettingsNavigation(), state.dataImport?.reading?.recordID == chosen.id else { throw PetError("预览续读记录缺失") }
            try JSONEncoder().encode(state).write(to: navigation, options: .atomic)
        }
        let success = checks.values.allSatisfy { $0 } && requests == 0
        let result: [String: Any] = ["appPID": getpid(), "binaryHash": binaryHash, "checks": checks, "width": size.width, "height": size.height,
            "success": success, "modelRequests": requests]
        let name = reopening ? "ssh-window-reopened.json" : "ssh-window-narrow.json"
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent(name), options: .atomic)
        guard success else { throw PetError("SSH 窗口检查失败：" + checks.filter { !$0.value }.keys.sorted().joined(separator: "、")) }
    }

    func checkSSHImport(_ output: URL, tasks: AgentStore, binaryHash: String) async throws {
        let importer = tasks.dataImport, fm = FileManager.default
        let codexRoot = output.appendingPathComponent("Codex '公开样例'")
        let qoderRoot = output.appendingPathComponent("Qoder 会话")
        let oldFile = codexRoot.appendingPathComponent("sessions/reviewed.jsonl")
        let original = try Data(contentsOf: oldFile)
        let remote = AgentImportRoute(source: .codex, category: .tasks, root: codexRoot.path, workspace: nil, sshHost: "whale-import")
        let local = AgentImportRoute(source: .codex, category: .tasks, root: codexRoot.path, workspace: nil)
        let qoder = AgentImportRoute(source: .qoder, category: .tasks, root: qoderRoot.path, workspace: nil, sshHost: "whale-import")
        var checks: [String: Bool] = [:]
        func finish(_ service: AgentDataImport) async throws {
            let end = Date().addingTimeInterval(20)
            while service.active, Date() < end { await wait(0.05) }
            guard !service.active else { throw PetError("SSH 导入批次仍在运行") }
        }

        for (alias, issue) in [("whale-unverified", "尚未验证"), ("whale-changed", "密钥已变化")] {
            var test = remote; test.sshHost = alias
            await importer.detect([test])
            checks[alias] = importer.preview(for: test)?.issue?.contains(issue) == true && importer.preview(for: test)?.available.isEmpty == true
        }
        await importer.detect([remote]); await importer.detect([local])
        let records = importer.preview(for: remote)?.records ?? []
        let available = records.filter { $0.issue == nil }
        guard let reviewed = available.first(where: { $0.file == oldFile.path }),
              let archived = available.first(where: \.archived) else { throw PetError(importer.preview(for: remote)?.issue ?? "未读回两份 SSH 来源") }
        checks["remoteAndLocalPreviewsStayDistinct"] = importer.preview(for: local)?.records.contains { $0.sourceID == reviewed.sourceID && $0.id != reviewed.id && $0.targetID != reviewed.targetID } == true
        checks["scanSkipsLinksAndReportsBrokenAndOversizedRecords"] = available.count == 2 && records.count == 4 &&
            records.contains { $0.issue?.contains("64 MB") == true } && records.contains { $0.issue == "来源第1行不是有效记录" } &&
            !records.contains { $0.file.hasSuffix("link.jsonl") }
        checks["quotedSourceReadsOriginalBytes"] = reviewed.rawHash == AgentFiles.hash(original)
        try (original + Data("\n".utf8)).write(to: oldFile)
        try importer.begin([remote: [reviewed.id]]); try await finish(importer)
        checks["changedSourceIsNeverInstalled"] = tasks.task(reviewed.targetID) == nil && importer.batch?.items.first?.detail.contains("远端来源已更新") == true
        try original.write(to: oldFile)
        await importer.detect([remote])
        let selection = tasks.selectedID
        let changed = importer.onChange
        importer.onChange = {
            changed?()
            if importer.batch?.state == "running", importer.batch?.items.contains(where: { $0.state == "imported" }) == true { importer.pause() }
        }
        try importer.begin([remote: [reviewed.id, archived.id]]); try await finish(importer)
        importer.onChange = changed
        let reopened = AgentStore(directory: output.appendingPathComponent("profile"), legacy: [], extensionHome: tasks.extensions.sharedHome)
        let resumed = reopened.dataImport
        checks["batchRestoresExactSourceWithOneItemPending"] = resumed.batch?.state == "paused" && resumed.batch?.items.filter { $0.state == "pending" }.count == 1 && resumed.batch.map { batch in batch.items.allSatisfy { batch.route(for: $0) == remote } } == true
        resumed.resume(); try await finish(resumed)
        let task = reopened.task(reviewed.targetID), archivedTask = reopened.task(archived.targetID)
        let replica = try Data(contentsOf: resumed.sourceURL(reviewed.targetID))
        checks["resumedBatchImportsExactOriginalAndArchiveState"] = resumed.batch?.state == "completed" && resumed.batch?.items.allSatisfy { $0.state == "imported" } == true && replica == original && archivedTask?.archived == true
        checks["remoteWorkspaceDoesNotResolveOnThisMac"] = task?.workspace == nil && task?.importOrigin?.originalWorkspace == output.path && task?.importOrigin?.sshHost == remote.sshHost && task?.importOrigin?.sourceFile == oldFile.path
        checks["importIsStoppedAndKeepsOriginalTaskSelected"] = task?.status == .stopped && task?.permission == .review && reopened.selectedID == selection
        await resumed.detect([qoder])
        guard let qoderRecord = resumed.preview(for: qoder)?.records.first(where: { $0.issue == nil }) else { throw PetError(resumed.preview(for: qoder)?.issue ?? "未读回 Qoder SSH 来源") }
        try resumed.begin([qoder: [qoderRecord.id]]); try await finish(resumed)
        checks["qoderConversationBranchAndCopyAreImported"] = reopened.task(qoderRecord.targetID)?.messages.map(\.content) == ["Qoder 远端公开问题", "Qoder 远端公开答复"] && resumed.batch?.items.first?.state == "imported"
        await resumed.detect([remote])
        checks["rescanningFindsBothImportedRecords"] = resumed.preview(for: remote)?.records.filter { $0.issue == "已经导入" }.count == 2
        checks["successfulAndFailedTransfersRemoveTemporaryCopies"] = try !fm.contentsOfDirectory(atPath: reopened.directory.deletingLastPathComponent().path).contains { $0.hasPrefix("ssh-import-transfer-") }
        let success = checks.values.allSatisfy { $0 }
        let result: [String: Any] = ["checks": checks, "success": success, "binaryHash": binaryHash, "appPID": getpid()]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("ssh-import-report.json"), options: .atomic)
        guard success else { throw PetError("SSH 导入检查失败：" + checks.filter { !$0.value }.keys.sorted().joined(separator: "、")) }
    }

    func checkMixedImport(_ output: URL, tasks: AgentStore, binaryHash: String) async throws {
        let files = FileManager.default, importer = tasks.dataImport
        let phase = output.appendingPathComponent("mixed-import-paused.json")
        let project = output.appendingPathComponent("Project"), codex = output.appendingPathComponent("Source tasks")
        let memory = output.appendingPathComponent("Source memories"), skills = output.appendingPathComponent("Source skills")
        let route = AgentImportRoute(source: .codex, category: .tasks, root: codex.path, workspace: nil)
        let memoryRoute = AgentImportRoute(source: .codex, category: .memory, root: memory.path, workspace: project.path)
        let skillRoute = AgentImportRoute(source: .codex, category: .skills, root: skills.path, workspace: nil)
        let expectedRoutes: Set<AgentImportRoute> = [route, memoryRoute, skillRoute]
        let missing = AgentImportRoute(source: .codex, category: .connectors, root: output.appendingPathComponent("Missing source").path, workspace: nil)
        let changed = memory.appendingPathComponent("changed.md")
        let publicText = Data("公开验收记忆 M-507\n".utf8), skillText = Data("---\nname: imported-public-skill\ndescription: 公开验收技能\n---\n只查看公开文件。\n".utf8)
        func write(_ value: [String: Any], to url: URL) throws {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
        }
        func finish() async throws {
            let end = Date().addingTimeInterval(30)
            while importer.active, Date() < end { await wait(0.05) }
            guard !importer.active else { throw PetError("混合导入仍在处理") }
        }
        var checks: [String: Bool] = [:]
        if !files.fileExists(atPath: phase.path) {
            let sessions = codex.appendingPathComponent("sessions"), skill = skills.appendingPathComponent("imported-public-skill")
            for folder in [project, memory, sessions, skill] { try files.createDirectory(at: folder, withIntermediateDirectories: true) }
            try tasks.organization.register(project.path, mode: .coding)
            for title in ["公开会话 A-102", "公开会话 B-205"] {
                let id = UUID().uuidString
                let records: [[String: Any]] = [
                    ["type": "session_meta", "payload": ["id": id, "cwd": project.path], "timestamp": "2026-11-19T01:00:00Z"],
                    ["type": "event_msg", "payload": ["type": "user_message", "message": title], "timestamp": "2026-11-19T01:00:01Z"]
                ]
                let body = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
                try Data((body + "\n").utf8).write(to: sessions.appendingPathComponent("rollout-" + id + ".jsonl"))
            }
            try publicText.write(to: memory.appendingPathComponent("public.md"))
            try Data("将修改的验收样例\n".utf8).write(to: changed)
            try skillText.write(to: skill.appendingPathComponent("SKILL.md"))
            await importer.detect([route, memoryRoute, missing, skillRoute])
            let tasksFound = importer.preview(for: route)?.records.filter { $0.issue == nil } ?? []
            let memories = importer.preview(for: memoryRoute)?.available ?? [], selectedSkills = importer.preview(for: skillRoute)?.available ?? []
            checks["sameScanKeepsIndependentCountsAndErrors"] = tasksFound.count == 2 && memories.count == 2 && selectedSkills.count == 1 && importer.preview(for: missing)?.issue != nil
            guard let selected = tasksFound.first(where: { $0.title == "公开会话 A-102" }) else { throw PetError("缺少公开会话") }
            let wrongTarget = AgentImportRoute(source: .codex, category: .memory, root: memory.path, workspace: nil)
            do { try importer.begin([route: [selected.id], wrongTarget: memories]); checks["batchRejectsUnscannedTarget"] = false }
            catch { checks["batchRejectsUnscannedTarget"] = importer.batch == nil }
            let wrongSource = AgentImportRoute(source: .qoder, category: .memory, root: memory.path, workspace: project.path)
            do { try importer.begin([route: [selected.id], wrongSource: memories]); checks["batchRejectsAnotherSource"] = false }
            catch { checks["batchRejectsAnotherSource"] = importer.batch == nil }
            let notify = importer.onChange
            importer.onChange = { [weak importer] in
                notify?()
                if let importer, importer.batch?.state == "running", importer.batch?.items.first?.state == "imported" { importer.pause() }
            }
            try importer.begin([route: [selected.id], memoryRoute: memories, skillRoute: selectedSkills])
            try await finish(); importer.onChange = notify
            let batch = importer.batch
            checks["oneQueueKeepsSelectionAndThreeSourceRoots"] = batch?.items.count == 4 && batch.map { value in Set(value.items.map { value.route(for: $0) }) } == expectedRoutes
            checks["pauseAfterTaskKeepsSelectedMemoryAndSkill"] = batch?.state == "paused" && batch?.items.first?.state == "imported" && batch?.items.dropFirst().allSatisfy { $0.state == "pending" } == true
            try Data("源文件在暂停后变化\n".utf8).write(to: changed)
            try publicText.write(to: memory.appendingPathComponent("after-pause.md"))
            try write(["checks": checks, "hash": binaryHash, "pid": getpid(), "taskID": selected.targetID], to: phase)
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("混合导入暂停检查未通过") }
            return
        }
        let first = try JSONSerialization.jsonObject(with: Data(contentsOf: phase)) as? [String: Any] ?? [:]
        checks = first["checks"] as? [String: Bool] ?? [:]
        let resumed = importer.batch
        checks["freshProcessRecoversSameBatchAndScopes"] = first["hash"] as? String == binaryHash && first["pid"] as? Int != Int(getpid()) && importer.unfinished && resumed?.state == "paused" && resumed.map { value in Set(value.items.map { value.route(for: $0) }) } == expectedRoutes
        importer.resume(); try await finish()
        let items = importer.batch?.items ?? []
        checks["resumeContinuesAfterOneChangedSourceFailure"] = importer.batch?.state == "completed" && items.filter { $0.state == "imported" }.count == 3 && items.filter { $0.state == "failed" }.map(\.record.title) == ["changed.md"]
        let retainedTasks = tasks.tasks.filter { $0.importOrigin != nil }
        checks["selectedRealTaskWasImportedOnce"] = retainedTasks.count == 1 && retainedTasks.first?.id == first["taskID"] as? String && retainedTasks.first?.title == "公开会话 A-102"
        let current = try AgentMemory.importDestination(store: tasks, workspace: project.path).folder
        let global = try AgentMemory.importDestination(store: tasks, workspace: nil).folder
        let projectTopics = try files.contentsOfDirectory(atPath: current.path)
        checks["memoryKeptOriginalProjectAndFrozenSelection"] = projectTopics == ["public.md"] && !files.fileExists(atPath: global.appendingPathComponent("public.md").path)
        checks["actualProjectMemoryBytesMatch"] = try Data(contentsOf: current.appendingPathComponent("public.md")) == publicText
        if let item = items.first(where: { $0.record.category == .skills }) {
            let url = try AgentSkillImport.destinationURL(item.record, store: tasks)
            checks["actualSkillInstalledFromItsOwnDirectory"] = try Data(contentsOf: url.appendingPathComponent("SKILL.md")) == skillText
        } else { checks["actualSkillInstalledFromItsOwnDirectory"] = false }
        await importer.detect([route, memoryRoute, skillRoute])
        checks["rescanShowsAlreadyImportedAndNewSourceRecords"] = importer.preview(for: route)?.available.count == 1 && importer.preview(for: memoryRoute)?.records.count == 3 && importer.preview(for: skillRoute)?.available.isEmpty == true
        let success = checks.count == 12 && checks.values.allSatisfy { $0 }
        try write(["checks": checks, "success": success, "binaryHash": binaryHash, "appPID": getpid()], to: output.appendingPathComponent("mixed-import-report.json"))
        guard success else { throw PetError("混合导入复验失败") }
    }
}
