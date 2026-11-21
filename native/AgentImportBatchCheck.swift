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
        if CommandLine.arguments.contains("--ssh-configuration-import-check") {
            let phase = output.appendingPathComponent("ssh-configuration-paused.json")
            let folder = output.appendingPathComponent("Qoder 会话")
            let target = output.appendingPathComponent("本机扩展配置项目")
            let category = AgentImportCategory.configuration
            let unscoped = AgentImportRoute(source: .qoder, category: category, root: folder.path, workspace: nil, sshHost: route.sshHost)
            let qoder = AgentImportRoute(source: .qoder, category: category, root: folder.path, workspace: target.path, sshHost: route.sshHost)
            let codex = AgentImportRoute(source: .codex, category: category, root: root.appendingPathComponent(".codex").path,
                                         workspace: nil, sshHost: route.sshHost)
            let files = FileManager.default
            func write(_ value: [String: Any], to url: URL) throws {
                try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
            }
            func records(_ path: AgentImportRoute) throws -> [AgentImportCandidate] {
                guard let preview = importer.preview(for: path), preview.issue == nil else {
                    throw PetError(importer.preview(for: path)?.issue ?? "缺少扩展配置预览")
                }
                return preview.records
            }
            func select(_ index: Int) throws {
                guard let list = find(content, NSTableView.self, { $0.accessibilityLabel() == "可导入扩展配置" }) else {
                    throw PetError("缺少扩展配置列表")
                }
                list.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                content.layoutSubtreeIfNeeded()
            }
            if !reopening {
                try tasks.organization.register(target.path, mode: .coding)
                try detectSSH(unscoped)
                try await settle { importer.scanning || importer.preview(for: unscoped) == nil }
                let unscopedRows = try records(unscoped)
                checks["qoderProjectRequiresExplicitLocalTarget"] = unscopedRows.count > 3 &&
                    unscopedRows.allSatisfy { $0.issue != nil } && unscopedRows.contains { $0.issue?.contains("选择目标项目") == true }
                guard let picker = find(content, NSPopUpButton.self, { $0.accessibilityLabel() == "扩展配置目标" }),
                      let item = picker.itemArray.first(where: { $0.representedObject as? String == target.path }),
                      let action = picker.action else { throw PetError("缺少扩展配置项目选择") }
                picker.select(item)
                NSApp.sendAction(action, to: picker.target, from: picker)
                try button("重新检测").performClick(nil)
                try await settle { importer.scanning || importer.preview(for: qoder) == nil }
                let rows = try records(qoder), available = rows.filter { $0.issue == nil }
                checks["detectsFiveKindsKeepingNestedTargetAndLinkedFileSkipped"] =
                    Set(available.compactMap { $0.configuration?.kind }) == [.rule, .instruction, .command, .agent, .hooks] &&
                    rows.contains { $0.file.hasSuffix("/link.md") && $0.issue?.contains("无法读取远端文件") == true } &&
                    rows.contains { $0.file.hasSuffix("AGENTS.local.md") && $0.issue?.contains("指令引用") == true } &&
                    rows.contains { $0.configuration?.destination == "src/.bluefatfish/rules/swift.md" && $0.issue == nil }
                guard let index = rows.firstIndex(where: { $0.configuration?.kind == .hooks && $0.issue == nil }) else { throw PetError("缺少 Hooks 预览") }
                try select(index)
                let detail = find(content, NSTextView.self, { $0.accessibilityLabel() == "导入预览" })
                let confirm = try button("导入 \(available.count) 项")
                checks["narrowPreviewKeepsHostTargetAndDisabledStatusVisible"] =
                    detail?.string.contains("whale-import:" + folder.path) == true && detail?.string.contains(target.path) == true &&
                    detail?.string.contains("导入后为停用状态") == true && confirm.visibleRect.height >= confirm.bounds.height - 1 &&
                    find(content, NSButton.self, { $0.title == "来源文件" }) == nil
                let notify = importer.onChange
                importer.onChange = { [weak importer] in
                    notify?()
                    if importer?.batch?.state == "running", importer?.batch?.items.contains(where: { $0.state == "imported" }) == true {
                        importer?.pause()
                    }
                }
                defer { importer.onChange = notify }
                confirm.performClick(nil)
                try await settle { importer.active || importer.batch == nil }
                guard let batch = importer.batch, batch.state == "paused" else { throw PetError("扩展配置批次没有暂停") }
                checks["pausesAfterOneWriteAndRetainsExactScope"] = batch.items.count == available.count &&
                    batch.items.filter { $0.state == "imported" }.count == 1 && batch.items.allSatisfy { batch.route(for: $0) == qoder }
                let changed = folder.appendingPathComponent(".qoder/rules/changed.md")
                try Data("---\nname: changed\ntrigger: manual\n---\nAfter preview\n".utf8).write(to: changed, options: .atomic)
                try write(["checks": checks, "batch": batch.id, "pid": getpid(), "modelRequests": requests], to: phase)
                try Data("{}".utf8).write(to: navigation, options: .atomic)
                return
            }
            let before = try JSONSerialization.jsonObject(with: Data(contentsOf: phase)) as? [String: Any] ?? [:]
            checks = before["checks"] as? [String: Bool] ?? [:]
            checks["reopenedWindowRetainsOriginalPendingBatch"] = before["pid"] as? Int != Int(getpid()) &&
                importer.batch?.id == before["batch"] as? String && importer.unfinished
            guard control.showSettingsCategory("imports") else { throw PetError("不能恢复扩展配置批次") }
            try button("继续导入").performClick(nil)
            try await settle { importer.active }
            let batch = importer.batch?.items ?? []
            checks["changedSourceFailsWithoutOverwriteAndRemainingItemsContinue"] = importer.batch?.state == "completed" &&
                batch.filter { $0.state == "failed" }.count == 1 && batch.contains { $0.record.title == "changed" && $0.detail.contains("来源已变化") } &&
                !files.fileExists(atPath: target.appendingPathComponent(".bluefatfish/rules/changed.md").path)
            checks["retainsNestedRuleAndReferencesInSelectedProject"] =
                files.fileExists(atPath: target.appendingPathComponent("src/.bluefatfish/rules/swift.md").path) &&
                files.fileExists(atPath: target.appendingPathComponent("AGENTS.md").path) &&
                !files.fileExists(atPath: target.appendingPathComponent(".bluefatfish/rules/swift.md").path)
            let roles = try tasks.agents.list(workspace: target.path).filter { $0.sourceWorkspace == target.path }
            let hooks = try tasks.hooks.catalog(workspace: target.path).filter { $0.workspace == target.path }
            checks["qoderAgentAndHooksStartDisabled"] = roles.count == 1 && roles.allSatisfy { !$0.enabled } &&
                hooks.count == 1 && hooks.allSatisfy { !tasks.hooks.enabled($0) }
            let offline = output.appendingPathComponent("暂离线的扩展配置来源")
            try files.moveItem(at: folder, to: offline)
            do {
                let transport = AgentSSHImport(profile: tasks.directory.deletingLastPathComponent(), home: tasks.extensions.sharedHome)
                for item in batch where item.state == "imported" {
                    try await AgentStandaloneDataImport.installRemote(item.record, route: qoder, transport: transport, store: tasks)
                }
                checks["alreadyPublishedItemsCanResumeWithSourceOffline"] = true
            } catch {
                try files.moveItem(at: offline, to: folder)
                throw error
            }
            try files.moveItem(at: offline, to: folder)
            try chooseSSH(codex)
            try button("检测可导入内容").performClick(nil)
            try await settle { importer.scanning || importer.preview(for: codex) == nil }
            let memory = AgentImportRoute(source: .codex, category: .memory, root: codex.root, workspace: nil, sshHost: codex.sshHost)
            checks["oneSSHDetectionSupportsConfigurationAndMemory"] = importer.preview(for: memory)?.available.count == 1
            try openCategory(category)
            let rows = try records(codex), available = rows.filter { $0.issue == nil }
            checks["codexOverridePromptsAgentsAndHookVariantsAreIdentified"] =
                available.count == 5 && available.contains { $0.title == "AGENTS.override.md" } &&
                available.contains { $0.title == "/prompts:review" && $0.warnings.contains(where: { $0.contains("FILE") }) } &&
                rows.contains { $0.configuration?.kind == .policy && $0.issue?.contains("单独配置") == true } &&
                available.contains { $0.standaloneMCPHooks == true && $0.warnings.contains(where: { $0.contains("内嵌凭据") }) }
            let selected = available.count + 1
            try button("导入 \(selected) 项").performClick(nil)
            try await settle { importer.active }
            guard let inline = available.first(where: { $0.configuration?.kind == .hooks && $0.standaloneMCPHooks != true }) else {
                throw PetError("缺少 Codex 内联命令 Hooks")
            }
            let hookFile = try AgentStandaloneDataImport.installedURL(inline, store: tasks)
            let hookText = try String(contentsOf: hookFile, encoding: .utf8)
            let resource = hookFile.deletingLastPathComponent().appendingPathComponent("hooks/公开 '检查'.sh")
            checks["inlineHookKeepsExecutableResourceWithCredentialPlaceholders"] = files.isExecutableFile(atPath: resource.path) &&
                hookText.contains("QODER_HOOK_ROOT") && hookText.contains(AgentHookCredentials.placeholder) && !hookText.contains("CONFIG_TEST_SECRET")
            let mcp = try tasks.hooks.catalog(workspace: nil).filter { $0.mcpHook != nil }
            checks["mcpHookRemainsDisabledAndRequiresLocalConnector"] = mcp.count == 1 &&
                mcp.first?.mcpHook?.server == "remote-test" && mcp.first?.diagnostic?.contains("配置连接器") == true &&
                mcp.allSatisfy { !tasks.hooks.enabled($0) }
            let globalRoles = try tasks.agents.list(workspace: nil)
            checks["globalCodexRecordsAreInstalledAndProjectRecordsStayProjectScoped"] = importer.batch?.items.allSatisfy { $0.state == "imported" } == true &&
                importer.batch?.items.count == selected && importer.batch?.items.contains { $0.record.category == .memory } == true &&
                globalRoles.contains { $0.name == "codex-review" && !$0.enabled } &&
                !globalRoles.contains { $0.sourceWorkspace == target.path }
            checks["sourceFilesAndRemoteTransferCleanup"] = try !files.contentsOfDirectory(atPath: tasks.directory.deletingLastPathComponent().path).contains {
                $0.hasPrefix("ssh-import-transfer-") || $0.hasPrefix("ssh-configuration-")
            }
            let success = checks.values.allSatisfy { $0 } && requests == 0 && before["modelRequests"] as? Int == 0
            try write(["checks": checks, "binaryHash": binaryHash, "appPID": getpid(), "modelRequests": requests, "success": success],
                      to: output.appendingPathComponent("ssh-configuration-report.json"))
            guard success else { throw PetError("SSH 扩展配置导入检查失败") }
            return
        }
        if CommandLine.arguments.contains("--ssh-plugin-import-check") {
            let phase = output.appendingPathComponent("ssh-plugin-paused.json")
            let original = AgentImportRoute(source: .codex, category: .plugins, root: route.root, workspace: nil, sshHost: route.sshHost)
            let service = tasks.extensions.plugins, files = FileManager.default
            let primary = root.appendingPathComponent("plugins/alpha-source")
            let changed = root.appendingPathComponent("plugins/beta-source/skills/source/resources/note.txt")
            func write(_ value: [String: Any], to url: URL) throws {
                try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
            }
            func choose(_ records: [AgentImportCandidate], titles: Set<String>, table: NSTableView) throws {
                try button("全选").performClick(nil)
                for (index, record) in records.enumerated() where titles.contains(record.title) {
                    table.scrollRowToVisible(index)
                    guard let checkbox = table.view(atColumn: 0, row: index, makeIfNecessary: true) as? NSButton else {
                        throw PetError("缺少插件勾选入口")
                    }
                    checkbox.performClick(nil)
                }
            }
            if !files.fileExists(atPath: phase.path) {
                try chooseSSH(route)
                try button("检测可导入内容").performClick(nil)
                try await settle { importer.scanning || importer.preview(for: original) == nil }
                let records = importer.preview(for: original)?.records ?? []
                checks["codexCacheSelectsSemverAndLocalOverride"] = importer.preview(for: original)?.available.count == 4 && records.count == 6 &&
                    records.contains { $0.title == "缓存正式版" && $0.file.hasSuffix("/1.10.0") } &&
                    records.contains { $0.title == "本机覆盖版" && $0.file.hasSuffix("/local") }
                checks["linkedAndProtectedFilesSkipOnlyTheirPackages"] = records.filter {
                    $0.issue?.contains("受保护文件、链接") == true
                }.count == 2
                guard let index = records.firstIndex(where: { $0.title == "远端资料插件" }) else {
                    throw PetError(importer.preview(for: original)?.issue ?? "缺少远端插件预览")
                }
                let selected = records[index]
                checks["previewListsAllComponentKindsAndSetup"] = ["Skill ·", "命令 ·", "Agent ·", "规则 ·", "MCP ·", "Hook ·"]
                    .allSatisfy { selected.preview.contains($0) } && selected.warnings.contains { $0.contains("凭据") } &&
                    !selected.preview.contains("PLUGIN_FIXTURE_SECRET")
                try openCategory(.plugins)
                guard let table = find(content, NSTableView.self, { $0.accessibilityLabel() == "可导入插件" }) else { throw PetError("缺少插件预览列表") }
                try choose(records, titles: ["远端资料插件", "远端改动插件"], table: table)
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                content.layoutSubtreeIfNeeded()
                let detail = find(content, NSTextView.self, { $0.accessibilityLabel() == "导入预览" })
                let confirm = try button("导入 6 项")
                checks["narrowPreviewShowsOriginSelectedCountAndDisabledImport"] = detail?.string.contains("whale-import:" + primary.path) == true &&
                    detail?.string.contains("导入后为停用状态") == true && confirm.visibleRect.width >= confirm.bounds.width - 1 &&
                    confirm.visibleRect.height >= confirm.bounds.height - 1 && find(content, NSButton.self, { $0.title == "来源文件" }) == nil
                checks["selectionIsPinnedToReviewedRemoteSource"] = control.captureSettingsNavigation()?.dataImport?.routes
                    .first(where: { $0.route == original })?.checked?.count == 2
                try button("返回导入").performClick(nil)
                let notify = importer.onChange
                importer.onChange = { [weak importer] in
                    notify?()
                    if let importer, importer.batch?.state == "running", importer.batch?.items.filter({ $0.state == "imported" }).count == 4 {
                        importer.pause()
                    }
                }
                defer { importer.onChange = notify }
                try button("导入 6 项").performClick(nil)
                try await settle { importer.active || importer.batch == nil }
                guard let batch = importer.batch, batch.state == "paused" else { throw PetError("SSH 插件批次没有暂停") }
                checks["mixedBatchPinsOnlyTwoSelectedPluginPackages"] = batch.items.filter { $0.state == "imported" && $0.record.category != .plugins }.count == 4 &&
                    batch.items.filter { $0.state == "pending" && batch.route(for: $0) == original }.count == 2
                try Data("预览后更新的公开插件资料\n".utf8).write(to: changed)
                try write(["batch": batch.id, "pid": getpid(), "checks": checks, "modelRequests": requests], to: phase)
                return
            }
            let initial = try JSONSerialization.jsonObject(with: Data(contentsOf: phase)) as? [String: Any] ?? [:]
            checks = initial["checks"] as? [String: Bool] ?? [:]
            checks["restartRestoresFrozenRemotePluginSelection"] = initial["pid"] as? Int != Int(getpid()) && importer.unfinished &&
                importer.batch?.id == initial["batch"] as? String && importer.batch?.items.filter {
                    $0.record.category == .plugins && $0.record.sshHost == route.sshHost && $0.state == "pending"
                }.count == 2
            guard control.showSettingsCategory("imports") else { throw PetError("不能恢复 SSH 插件导入页") }
            try button("继续导入").performClick(nil)
            try await settle { importer.active }
            guard let batch = importer.batch, let copied = batch.items.first(where: { $0.record.title == "远端资料插件" }),
                  let id = AgentPluginDataImport.installedID(copied.record, store: tasks) else { throw PetError("缺少已导入远端插件") }
            let plugin = try service.installation(id)
            checks["resourceChangeBlocksOnlyTheAffectedPackage"] = batch.state == "completed" && copied.state == "imported" &&
                batch.items.filter { $0.state == "imported" }.count == 5 && batch.items.contains {
                    $0.record.title == "远端改动插件" && $0.state == "failed" && $0.detail.contains("已变化")
                }
            let resource = "skills/source/resources/nested/sample.bin"
            let installedBytes = try service.content(resource, installation: plugin)
            let expected = try Data(contentsOf: primary.appendingPathComponent(resource))
            checks["directoryResourcesAndDisabledComponentsArePreserved"] = installedBytes == expected && !plugin.enabled &&
                plugin.receipt.components.count == 2 && plugin.agents.count == 1 && plugin.rules.count == 1 &&
                plugin.hooks.count == 1 && plugin.mcpServers.count == 1
            let mcp = try service.content(".mcp.json", installation: plugin), hooks = try service.content("hooks/hooks.json", installation: plugin)
            let templates = String(decoding: mcp + hooks, as: UTF8.self)
            checks["installedTemplatesOnlyKeepCredentialPlaceholders"] = templates.contains(AgentMCP.importPlaceholder) &&
                templates.contains(AgentHookCredentials.placeholder) && !templates.contains("PLUGIN_FIXTURE_SECRET")

            let qoderRoot = output.appendingPathComponent("Qoder 会话"), project = output.appendingPathComponent("本机插件项目")
            let zip = qoderRoot.appendingPathComponent(".qoder/plugins/公开 '项目'.zip")
            let global = AgentImportRoute(source: .qoder, category: .plugins, root: qoderRoot.path, workspace: nil, sshHost: route.sshHost)
            let scoped = AgentImportRoute(source: .qoder, category: .plugins, root: zip.path, workspace: project.path, sshHost: route.sshHost)
            try files.createDirectory(at: project, withIntermediateDirectories: true)
            try tasks.organization.register(project.path, mode: .coding)
            try detectSSH(global)
            try await settle { importer.scanning || importer.preview(for: global) == nil }
            let projectRecords = importer.preview(for: global)?.records ?? []
            checks["qoderDiscoversZipAndConventionalFolderWithProjectRequirement"] = projectRecords.count == 2 &&
                projectRecords.contains { $0.file == zip.path } && projectRecords.contains { $0.plugin?.name == "conventional" } &&
                projectRecords.allSatisfy { $0.issue?.contains("选择目标项目") == true }
            try button("返回导入").performClick(nil)
            try chooseSSH(scoped)
            try openCategory(.plugins)
            guard let picker = find(content, NSPopUpButton.self, { $0.accessibilityLabel() == "插件目标" }),
                  let destination = picker.itemArray.first(where: { $0.representedObject as? String == project.path }),
                  let action = picker.action else { throw PetError("缺少插件项目选择") }
            picker.select(destination)
            NSApp.sendAction(action, to: picker.target, from: picker)
            try button("重新检测").performClick(nil)
            try await settle { importer.scanning || importer.preview(for: scoped) == nil }
            guard let selected = importer.preview(for: scoped)?.records.first, selected.issue == nil,
                  selected.file == zip.path, selected.plugin?.name == "qoder-zip" else {
                throw PetError(importer.preview(for: scoped)?.issue ?? "缺少指定 ZIP 预览")
            }
            try button("导入 1 项").performClick(nil)
            try await settle { importer.active }
            guard let projectID = AgentPluginDataImport.installedID(selected, store: tasks) else { throw PetError("缺少本机项目 ZIP 插件") }
            let scopedPlugin = try service.installation(projectID)
            let zipHash = AgentFiles.hash(try Data(contentsOf: zip))
            let globalNames = try service.catalog(workspace: nil, onlyScope: true).map { $0.metadata.name }
            checks["exactZipIsInstalledOnlyInTheSelectedProject"] = scopedPlugin.workspace == project.path && !scopedPlugin.enabled &&
                scopedPlugin.receipt.sourceHash == zipHash && importer.batch?.items.count == 1 && globalNames == ["remote-directory"]
            let profile = tasks.directory.deletingLastPathComponent()
            checks["noTransferOrArchiveReviewScratchIsLeft"] = try !files.contentsOfDirectory(atPath: profile.path).contains {
                $0.hasPrefix("ssh-import-transfer-") || $0.hasPrefix(".plugin-review-")
            }
            let success = checks.values.allSatisfy { $0 } && requests == 0 && initial["modelRequests"] as? Int == 0
            try write(["checks": checks, "binaryHash": binaryHash, "appPID": getpid(), "modelRequests": requests, "success": success],
                      to: output.appendingPathComponent("ssh-plugin-report.json"))
            guard success else { throw PetError("SSH 插件导入检查失败") }
            return
        }
        if CommandLine.arguments.contains("--ssh-connector-import-check") {
            let phase = output.appendingPathComponent("ssh-connector-paused.json")
            let sourceFile = root.appendingPathComponent("config.toml")
            let connectors = AgentImportRoute(source: .codex, category: .connectors, root: route.root, workspace: nil, sshHost: route.sshHost)
            let model = tasks.mcp, files = FileManager.default
            func write(_ value: [String: Any], to url: URL) throws {
                try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
            }
            if !files.fileExists(atPath: phase.path) {
                try chooseSSH(route)
                try button("检测可导入内容").performClick(nil)
                try await settle { importer.scanning || importer.preview(for: connectors) == nil }
                let records = importer.preview(for: connectors)?.records ?? []
                let available = records.filter { $0.issue == nil }
                checks["codexPreviewKeepsThreeConnectionsAndReportsBadRow"] = available.count == 3 && records.count == 4 &&
                    records.contains { $0.title == "invalid-row" && $0.issue != nil } && importer.preview(for: route)?.available.count == 2
                guard let index = records.firstIndex(where: { $0.title == "public-stdio" }) else { throw PetError("缺少远端 STDIO 预览") }
                let selected = records[index]
                checks["previewShowsNamesAndPlaceholdersWithoutCredentialValues"] = selected.preview.contains("PUBLIC_TOKEN") &&
                    selected.preview.contains("FORWARDED") && selected.preview.contains("待填写") &&
                    !records.contains { $0.preview.contains("WIRE_CANARY") }
                checks["remoteProgramRequiresReviewBeforeEnable"] = selected.connector?.needsSetup == true &&
                    selected.warnings.contains("启用前请核对本机程序和工作目录")
                try openCategory(.connectors)
                guard let list = find(content, NSTableView.self, { $0.accessibilityLabel() == "可导入连接器" }) else { throw PetError("缺少连接器预览列表") }
                list.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                content.layoutSubtreeIfNeeded()
                let detail = find(content, NSTextView.self, { $0.accessibilityLabel() == "导入预览" })
                let confirm = try button("导入 7 项")
                checks["narrowWindowShowsRemoteOriginWithConfirmAndSetupState"] = detail?.string.contains("whale-import:" + sourceFile.path) == true &&
                    detail?.string.contains("待配置") == true && confirm.visibleRect.width >= confirm.bounds.width - 1 &&
                    confirm.visibleRect.height >= confirm.bounds.height - 1 && find(content, NSButton.self, { $0.title == "来源文件" }) == nil
                checks["reviewKeepsTheSelectedRemoteConnectors"] = control.captureSettingsNavigation()?.dataImport?.routes
                    .first(where: { $0.route == connectors })?.checked?.count == 3
                try button("返回导入").performClick(nil)
                let notify = importer.onChange
                importer.onChange = { [weak importer] in
                    notify?()
                    if let importer, importer.batch?.state == "running", importer.batch?.items.filter({ $0.state == "imported" }).count == 4 {
                        importer.pause()
                    }
                }
                defer { importer.onChange = notify }
                try button("导入 7 项").performClick(nil)
                try await settle { importer.active || importer.batch == nil }
                guard let batch = importer.batch, batch.state == "paused" else { throw PetError("连接器导入批次没有暂停") }
                checks["mixedBatchKeepsThreeRemoteConnectionsPending"] = batch.items.filter { $0.state == "imported" && $0.record.category != .connectors }.count == 4 &&
                    batch.items.filter { $0.state == "pending" && batch.route(for: $0) == connectors }.count == 3 && model.servers.isEmpty
                let before = try String(contentsOf: sourceFile, encoding: .utf8)
                let after = before.replacingOccurrences(of: "/before-update", with: "/after-update")
                    .replacingOccurrences(of: "WIRE_CANARY_ENV", with: "WIRE_CANARY_ROTATED")
                guard before != after else { throw PetError("连接器来源变更样例有误") }
                try Data(after.utf8).write(to: sourceFile)
                try write(["batch": batch.id, "pid": getpid(), "checks": checks, "modelRequests": requests], to: phase)
                return
            }
            let initial = try JSONSerialization.jsonObject(with: Data(contentsOf: phase)) as? [String: Any] ?? [:]
            checks = initial["checks"] as? [String: Bool] ?? [:]
            checks["restartRestoresOriginalRemoteConnectorSelection"] = initial["pid"] as? Int != Int(getpid()) && importer.unfinished &&
                importer.batch?.id == initial["batch"] as? String && importer.batch?.items.filter {
                    $0.state == "pending" && $0.record.category == .connectors && $0.record.sshHost == route.sshHost
                }.count == 3
            guard control.showSettingsCategory("imports") else { throw PetError("不能恢复 SSH 连接器页") }
            try button("继续导入").performClick(nil)
            try await settle { importer.active }
            let servers = model.servers
            guard let stdio = servers.first(where: { $0.name == "public-stdio" }),
                  let portable = servers.first(where: { $0.name == "public-https" }) else { throw PetError("缺少已导入连接器") }
            checks["actualDefinitionChangeRejectedWhileCredentialRotationKeepsSelection"] = importer.batch?.state == "completed" &&
                importer.batch?.items.contains { $0.record.title == "changed-source" && $0.state == "failed" && $0.detail.contains("已变化") } == true &&
                servers.count == 2
            let document = try model.document(stdio)
            checks["storedStdioHasOnlyCredentialPlaceholdersAndNames"] = stdio.configured == false && !stdio.enabled &&
                document.contains("PUBLIC_TOKEN") && document.contains(AgentMCP.importPlaceholder) && !document.contains("WIRE_CANARY")
            checks["portableHttpsKeepsAddressAndTimeoutWhileDisabled"] = portable.configured == true && !portable.enabled &&
                portable.url == "https://example.invalid/mcp" && portable.timeoutSeconds == 29

            let qoderFile = output.appendingPathComponent("Qoder 会话/.qoder/settings.json")
            let project = output.appendingPathComponent("本机 MCP 项目")
            let global = AgentImportRoute(source: .qoder, category: .connectors, root: qoderFile.path, workspace: nil, sshHost: route.sshHost)
            let scoped = AgentImportRoute(source: .qoder, category: .connectors, root: qoderFile.path, workspace: project.path, sshHost: route.sshHost)
            try files.createDirectory(at: project, withIntermediateDirectories: true)
            try tasks.organization.register(project.path, mode: .coding)
            try detectSSH(global)
            try await settle { importer.scanning || importer.preview(for: global) == nil }
            checks["directQoderProjectFileCannotImportToGlobal"] = importer.preview(for: global)?.records.count == 2 &&
                importer.preview(for: global)?.records.allSatisfy { $0.file == qoderFile.path && $0.issue?.contains("选择目标项目") == true } == true
            guard let picker = find(content, NSPopUpButton.self, { $0.accessibilityLabel() == "连接器目标" }),
                  let item = picker.itemArray.first(where: { $0.representedObject as? String == project.path }), let action = picker.action else {
                throw PetError("缺少连接器项目选择")
            }
            picker.select(item)
            NSApp.sendAction(action, to: picker.target, from: picker)
            try button("重新检测").performClick(nil)
            try await settle { importer.scanning || importer.preview(for: scoped) == nil }
            guard let result = importer.preview(for: scoped), let index = result.records.firstIndex(where: { $0.title == "project-loopback" }),
                  let table = find(content, NSTableView.self, { $0.accessibilityLabel() == "可导入连接器" }) else { throw PetError("缺少项目连接器预览") }
            let row = result.records[index]
            checks["remoteLoopbackRequiresNewAddressAndOriginalTokensAreRedacted"] = row.connector?.needsSetup == true &&
                row.preview.contains("待填写") && row.warnings.contains("启用前请更换远端回环地址") &&
                !result.records.contains { $0.preview.contains("WIRE_CANARY") }
            try button("全选").performClick(nil)
            table.scrollRowToVisible(index)
            guard let checkbox = table.view(atColumn: 0, row: index, makeIfNecessary: true) as? NSButton else { throw PetError("缺少连接器勾选入口") }
            checkbox.performClick(nil)
            try button("导入 1 项").performClick(nil)
            try await settle { importer.active }
            let installed = model.availableServers(workspace: project.path).first { $0.id == row.targetID }
            checks["onlySelectedProjectConnectionIsSavedDisabledAndUnconfigured"] = installed?.workspace == project.path &&
                installed?.configured == false && installed?.enabled == false && installed?.url?.contains(AgentMCP.importPlaceholder) == true &&
                installed?.hasBearerToken == true && !model.servers.contains { $0.name == row.title } &&
                !model.availableServers(workspace: project.path).contains { $0.name == "project-unused-sse" } && importer.batch?.items.count == 1
            let profile = tasks.directory.deletingLastPathComponent()
            checks["importDoesNotRunSourceProgramOrKeepTransferScratch"] = try !files.fileExists(atPath: output.appendingPathComponent("unexpected-script-output").path) &&
                !files.contentsOfDirectory(atPath: profile.path).contains { $0.hasPrefix("ssh-import-transfer-") }
            let success = checks.values.allSatisfy { $0 } && requests == 0 && initial["modelRequests"] as? Int == 0
            try write(["checks": checks, "binaryHash": binaryHash, "appPID": getpid(), "modelRequests": requests, "success": success],
                      to: output.appendingPathComponent("ssh-connectors-report.json"))
            guard success else { throw PetError("SSH 连接器导入检查失败") }
            return
        }
        if CommandLine.arguments.contains("--ssh-automation-import-check") {
            guard let runtime = agentRuntime else { throw PetError("缺少定时任务运行时") }
            let schedules = tasks.automations, fm = FileManager.default
            schedules.start(store: tasks, runtime: runtime)
            defer { schedules.stop() }
            guard schedules.isStarted else { throw PetError(schedules.error ?? "定时任务服务未启动") }
            let phase = output.appendingPathComponent("ssh-automation-paused.json")
            let target = output.appendingPathComponent("本机定时任务项目")
            let decoy = output.appendingPathComponent("本机同路径项目")
            let original = AgentImportRoute(source: .codex, category: .automations, root: route.root, workspace: nil, sshHost: route.sshHost)
            let mapped = AgentImportRoute(source: .codex, category: .automations, root: route.root, workspace: target.path, sshHost: route.sshHost)
            let changed = root.appendingPathComponent("automations/update-check/automation.toml")
            func write(_ value: [String: Any], to file: URL) throws {
                try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: file, options: .atomic)
            }
            func chooseProject(_ project: URL) throws {
                guard let picker = find(content, NSPopUpButton.self, { $0.accessibilityLabel() == "定时任务目标" }),
                      let item = picker.itemArray.first(where: { $0.representedObject as? String == project.path }),
                      let action = picker.action else { throw PetError("缺少定时任务项目选择") }
                picker.select(item)
                NSApp.sendAction(action, to: picker.target, from: picker)
            }
            if !fm.fileExists(atPath: phase.path) {
                for project in [target, decoy] {
                    try fm.createDirectory(at: project, withIntermediateDirectories: true)
                    try tasks.organization.register(project.path, mode: .coding)
                }
                try chooseSSH(route)
                try button("检测可导入内容").performClick(nil)
                try await settle { importer.scanning || importer.preview(for: original) == nil }
                let memory = AgentImportRoute(source: .codex, category: .memory, root: route.root, workspace: nil, sshHost: route.sshHost)
                let skills = AgentImportRoute(source: .codex, category: .skills, root: route.root, workspace: nil, sshHost: route.sshHost)
                let detected = importer.preview(for: original)
                checks["overviewDetectsFourCompatibleCategories"] = importer.preview(for: route)?.available.count == 2 &&
                    importer.preview(for: memory)?.available.count == 1 && importer.preview(for: skills)?.available.count == 1 && detected?.records.count == 4
                checks["remoteProjectPathNeverImplicitlyBecomesLocalTarget"] = detected?.available.isEmpty == true &&
                    detected?.records.contains { $0.title == "远端每周核对" && $0.preview.contains(decoy.path) &&
                        $0.automation?.workspace == nil && $0.issue == "请选择本机目标项目" } == true && schedules.values.isEmpty
                try openCategory(.automations)
                try chooseProject(target)
                try button("重新检测").performClick(nil)
                try await settle { importer.scanning || importer.preview(for: mapped) == nil }
                guard let preview = importer.preview(for: mapped), let index = preview.records.firstIndex(where: { $0.title == "远端每周核对" }),
                      let list = find(content, NSTableView.self, { $0.accessibilityLabel() == "可导入定时任务" }) else {
                    throw PetError(importer.preview(for: mapped)?.issue ?? "缺少 SSH 定时任务预览")
                }
                checks["unsupportedExecutionAndLinkedFilesRemainSeparateSkippedRows"] = preview.available.count == 2 &&
                    preview.records.contains { $0.issue?.contains("本机项目目录执行") == true } &&
                    preview.records.contains { $0.file.contains("/linked/") && $0.issue?.contains("无法读取远端文件") == true }
                list.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                content.layoutSubtreeIfNeeded()
                let detail = find(content, NSTextView.self, { $0.accessibilityLabel() == "导入预览" })
                let confirm = try button("导入 6 项")
                checks["narrowPreviewShowsScheduleSourceTargetAndDisabledImport"] = detail?.string.contains("whale-import:" + root.path) == true &&
                    detail?.string.contains(target.path) == true && detail?.string.contains("Asia/Shanghai") == true &&
                    detail?.string.contains("导入后为停用状态") == true && detail?.string.contains("启用前请核对执行时区") == true &&
                    confirm.visibleRect.width >= confirm.bounds.width - 1 && confirm.visibleRect.height >= confirm.bounds.height - 1 &&
                    find(content, NSButton.self, { $0.title == "来源文件" }) == nil
                checks["reviewKeepsRemoteHostLocalTargetAndTwoSelections"] = control.captureSettingsNavigation()?.dataImport?.routes
                    .first(where: { $0.route == mapped })?.checked?.count == 2
                try button("返回导入").performClick(nil)
                let notify = importer.onChange
                importer.onChange = { [weak importer] in
                    notify?()
                    if let importer, importer.batch?.state == "running", importer.batch?.items.filter({ $0.state == "imported" }).count == 4 {
                        importer.pause()
                    }
                }
                defer { importer.onChange = notify }
                try button("导入 6 项").performClick(nil)
                try await settle { importer.active || importer.batch == nil }
                guard let batch = importer.batch, batch.state == "paused" else { throw PetError("SSH 定时任务批次没有暂停") }
                checks["mixedBatchFreezesTwoSchedulesAfterOtherCategories"] = batch.items.filter { $0.state == "imported" && $0.record.category != .automations }.count == 4 &&
                    batch.items.filter { $0.state == "pending" && batch.route(for: $0) == mapped }.count == 2 && schedules.values.isEmpty
                let before = try String(contentsOf: changed, encoding: .utf8)
                let after = before.replacingOccurrences(of: "检查未更新的公开内容", with: "预览后写入的公开提示词")
                guard before != after else { throw PetError("定时任务变更样例有误") }
                try Data(after.utf8).write(to: changed)
                try write(["batch": batch.id, "pid": getpid(), "checks": checks, "modelRequests": requests], to: phase)
                return
            }
            let previous = try JSONSerialization.jsonObject(with: Data(contentsOf: phase)) as? [String: Any] ?? [:]
            checks = previous["checks"] as? [String: Bool] ?? [:]
            checks["restartRestoresFrozenRemoteSchedulesAndTarget"] = previous["pid"] as? Int != Int(getpid()) &&
                importer.batch?.id == previous["batch"] as? String && importer.unfinished &&
                importer.batch?.items.filter { $0.record.automation?.workspace == target.path && $0.record.sshHost == route.sshHost && $0.state == "pending" }.count == 2
            guard control.showSettingsCategory("imports") else { throw PetError("不能恢复 SSH 定时任务导入页") }
            try button("继续导入").performClick(nil)
            try await settle { importer.active }
            guard let batch = importer.batch, let copied = batch.items.first(where: { $0.record.title == "远端每周核对" }),
                  let weekly = schedules.values.first(where: { $0.id == copied.record.targetID }) else { throw PetError("缺少已导入计划") }
            checks["changedRemotePromptIsRejectedWithoutBlockingTheBatch"] = batch.state == "completed" &&
                batch.items.filter { $0.state == "imported" }.count == 5 && batch.items.contains {
                    $0.record.title == "远端改动计划" && $0.state == "failed" && $0.detail.contains("已变化")
                } && schedules.values.count == 1
            let clock = ISO8601DateFormatter()
            let sample = clock.date(from: "2030-01-07T01:16:00Z")!, expected = clock.date(from: "2030-01-11T01:15:00Z")!
            checks["codexCalendarKeepsExplicitZonePromptAndNextOccurrence"] = weekly.workspace == target.path &&
                weekly.prompt == "在选定项目核对公开 README" && weekly.schedule.timeZone == "Asia/Shanghai" &&
                weekly.schedule.cronExpression == "15 9 * * 1,5" && weekly.schedule.next(after: sample) == expected

            let qoderFile = output.appendingPathComponent("Qoder 会话/.qoder/scheduled_tasks.json")
            let qoderTarget = output.appendingPathComponent("本机 Qoder 项目")
            let qoder = AgentImportRoute(source: .qoder, category: .automations, root: qoderFile.path, workspace: qoderTarget.path, sshHost: route.sshHost)
            try fm.createDirectory(at: qoderTarget, withIntermediateDirectories: true)
            try tasks.organization.register(qoderTarget.path, mode: .coding)
            try chooseSSH(qoder)
            try openCategory(.automations)
            try chooseProject(qoderTarget)
            try button("重新检测").performClick(nil)
            try await settle { importer.scanning || importer.preview(for: qoder) == nil }
            guard let result = importer.preview(for: qoder), let selected = result.records.first(where: { $0.title == "Qoder 远端定时检查" }),
                  let list = find(content, NSTableView.self, { $0.accessibilityLabel() == "可导入定时任务" }),
                  let index = result.records.firstIndex(where: { $0.id == selected.id }) else {
                throw PetError(importer.preview(for: qoder)?.issue ?? "缺少 Qoder 定时任务预览")
            }
            checks["explicitQoderFileShowsCronAndSourceRunWithoutChangingPath"] = result.available.count == 2 &&
                selected.file == qoderFile.path && selected.preview.contains("0,30 9-11 * * 1-5") && selected.preview.contains("来源最近运行") &&
                result.records.contains { $0.issue?.contains("Cron") == true }
            try button("全选").performClick(nil)
            list.scrollRowToVisible(index)
            guard let checkbox = list.view(atColumn: 0, row: index, makeIfNecessary: true) as? NSButton else { throw PetError("缺少计划勾选入口") }
            checkbox.performClick(nil)
            try button("导入 1 项").performClick(nil)
            try await settle { importer.active }
            let qoderValue = schedules.values.first { $0.id == selected.targetID }
            checks["onlySelectedQoderPlanAppearsInTheChosenProject"] = importer.batch?.items.count == 1 &&
                importer.batch?.items.first?.state == "imported" && qoderValue?.workspace == qoderTarget.path &&
                qoderValue?.schedule.cronExpression == "0,30 9-11 * * 1-5" && schedules.values.count == 2
            checks["importedSchedulesStayDisabledWithNoHistoryOrDispatch"] = try schedules.history().runs.isEmpty &&
                schedules.values.allSatisfy { !$0.enabled && $0.nextRun == nil && $0.current == nil && $0.readOnly && !$0.network && $0.permission == .review }
            let profile = tasks.directory.deletingLastPathComponent()
            checks["noTransferScratchRemains"] = try !fm.contentsOfDirectory(atPath: profile.path).contains { $0.hasPrefix("ssh-import-transfer-") }
            let success = checks.values.allSatisfy { $0 } && requests == 0 && previous["modelRequests"] as? Int == 0
            try write(["checks": checks, "binaryHash": binaryHash, "appPID": getpid(), "modelRequests": requests, "success": success],
                      to: output.appendingPathComponent("ssh-automation-report.json"))
            guard success else { throw PetError("SSH 定时任务导入检查失败") }
            return
        }
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
                checks["overviewShowsSupportedSSHCategories"] = Set(categories) == Set(AgentImportCategory.allCases)
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
