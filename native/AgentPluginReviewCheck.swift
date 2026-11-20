import AppKit

@MainActor enum AgentPluginReviewCheck {
    private static func find<T: NSView>(_ type: T.Type, in view: NSView?, matching: (T) -> Bool) -> T? {
        guard let view else { return nil }
        if let value = view as? T, matching(value) { return value }
        for child in view.subviews { if let value = find(type, in: child, matching: matching) { return value } }; return nil
    }
    private static func control<T: NSView>(_ type: T.Type, _ label: String, page: AgentSettingsPageController) throws -> T {
        guard let value = find(type, in: page.pageContentView, matching: { $0.accessibilityLabel() == label }) else { throw PetError("缺少审阅控件：" + label) }; return value
    }
    private static func press(_ title: String, page: AgentSettingsPageController) throws {
        guard let button = find(NSButton.self, in: page.pageContentView, matching: { $0.title == title && $0.isEnabled }) else { throw PetError("缺少审阅按钮：" + title) }; button.performClick(nil)
    }
    private static func text(_ view: NSView?) -> String {
        guard let view else { return "" }; return (view as? NSTextView)?.string ?? (view as? NSTextField)?.stringValue ?? view.subviews.map { text($0) }.joined(separator: "\n")
    }
    private static func select(_ control: NSSegmentedControl, _ segment: Int) {
        control.selectedSegment = segment
        if let action = control.action { NSApp.sendAction(action, to: control.target, from: control) }
    }
    private static func waitForPatch(_ reader: AgentGitDiffView, containing text: String) async throws -> Bool {
        for _ in 0..<100 {
            if !reader.isHidden, reader.patch.contains(text) { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }
    static func prepareSources(_ output: URL, history: Bool = false) throws -> [URL] {
        let fm = FileManager.default, source = output.appendingPathComponent("插件审阅来源")
        func prepare(_ version: Int) throws -> URL {
            let root = source.appendingPathComponent("v\(version)")
            let manifest: [String: Any] = ["name": history ? "history-inline" : "review-inline", "displayName": history ? "插件历史恢复样例" : "设置审阅插件", "version": "\(version).0.0", "description": "公开文本的插件页面检查"]
            var files: [String: Data] = [".qoder-plugin/plugin.json": try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])]
            let values = ["README.md": "公开插件版本 \(version)。\n", "skills/check/SKILL.md": "---\nname: check\ndescription: 公开技能\n---\n完整技能正文 version-\(version)。\n", "commands/check.md": "公开命令 version-\(version)。\n$ARGUMENTS\n", "agents/reviewer.md": "---\nname: reviewer\ndescription: 公开只读审阅角色\ntools: [read_file]\nreadOnly: true\nnetwork: false\n---\n完整角色指令 version-\(version)。\n", "rules/check.md": "---\ntrigger: always_on\n---\n完整规则正文 version-\(version)。\n"]
            for (name, value) in values { files[name] = Data(value.utf8) }
            if history {
                let lines = (1...140).map { "HISTORY-LINE-\($0)-v\(version) 公开阅读样例" }
                files["README.md"] = Data((lines.joined(separator: "\n") + "\n").utf8)
            }
            files[".mcp.json"] = try JSONSerialization.data(withJSONObject: ["mcpServers": ["local": ["command": "/usr/bin/true", "args": ["public-v\(version)"]]]], options: [.sortedKeys])
            files["hooks/hooks.json"] = try JSONSerialization.data(withJSONObject: ["hooks": ["SessionStart": [["hooks": [["name": "public", "type": "command", "command": "/usr/bin/true", "args": ["hook-v\(version)"], "network": false, "timeout": 10]]]]]], options: [.sortedKeys])
            files["skills/check/resources/sample.bin"] = Data([0] + Array(repeating: UInt8(version), count: version))
            for index in 0..<(history ? 24 : 105) { files[String(format: "skills/check/resources/item-%03d.txt", index)] = Data("公开资源 \(index) version-\(version)。\n".utf8) }
            for (name, bytes) in files { let file = root.appendingPathComponent(name); try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true); try bytes.write(to: file) }
            return root
        }
        return try [prepare(1), prepare(2)]
    }

    @discardableResult static func prepareHistory(_ output: URL, tasks: AgentStore, workspace: String) async throws -> AgentPluginInstallation {
        let root = output.appendingPathComponent("插件历史恢复"), plugins = tasks.extensions.plugins
        let sources = try prepareSources(root, history: true)
        var current = try plugins.install(await plugins.inspect(sources[0]), workspace: workspace)
        let manifest = sources[1].appendingPathComponent(".qoder-plugin/plugin.json")
        guard var fields = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any] else { throw PetError("历史验收清单无效") }
        for version in 2...9 {
            fields["version"] = "\(version).0.0"
            try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]).write(to: manifest)
            current = try plugins.update(await plugins.inspect(sources[1]), replacing: current)
        }
        return current
    }
    static func run(tasks: AgentStore, taskID: String, pane: AgentSettingsPageHost, host: NSWindow, output: URL) async throws -> [String: Bool] {
        let plugins = tasks.extensions.plugins, workspace = tasks.task(taskID)!.workspace!, sources = try prepareSources(output)
        let first = try await plugins.inspect(sources[0]), second = try await plugins.inspect(sources[1])
        let manager = AgentPluginWindow(store: tasks, workspace: workspace)
        guard pane.show(category: "plugins", identity: "plugin-review", scope: "设置项目", make: { _ in manager }) else { throw PetError("无法进入插件审阅检查") }
        var checks: [String: Bool] = [:]
        let visible = NSApp.windows.filter(\.isVisible).count
        pane.layoutSubtreeIfNeeded()
        let baselineList = try control(NSTableView.self, "插件列表", page: manager)
        checks["settingsHostGivesPluginListDeterminateHeight"] = !baselineList.hasAmbiguousLayout
        let baselineLayout: [String: Any] = ["ambiguous": baselineList.hasAmbiguousLayout, "autoresizingMask": baselineList.autoresizingMask.rawValue, "translatesAutoresizingMask": baselineList.translatesAutoresizingMaskIntoConstraints, "horizontalConstraints": baselineList.constraintsAffectingLayout(for: .horizontal).map(\.description), "verticalConstraints": baselineList.constraintsAffectingLayout(for: .vertical).map(\.description)]
        manager.review(first)
        guard let installation = pane.currentController as? AgentPluginReviewPage else { throw PetError("安装审阅未进入子页面") }
        checks["pluginInstallReviewHostedWithoutSheet"] = installation.presentingWindow === host && installation.window?.isVisible == false && host.attachedSheet == nil
        checks["pluginReviewHeadingGivesActionNameAndVersion"] = installation.detailHeading?.title == "安装「设置审阅插件」"
            && installation.detailHeading?.scope == "用户 · 1.0.0"
        let actions = NSStackView()
        installation.setSettingsActionsHost(actions)
        checks["pluginReviewActionsAttachToSharedToolbar"] = actions.arrangedSubviews.compactMap { ($0 as? NSButton)?.title } == ["取消", "安装"]
            && installation.detailActionRow?.isHidden == true
        installation.setSettingsActionsHost(nil)
        checks["pluginReviewActionsReturnToLocalRow"] = actions.arrangedSubviews.isEmpty && installation.detailActionRow?.isHidden == false
        checks["pluginInstallReviewDoesNotPublishBeforeApply"] = try plugins.catalog().allSatisfy { $0.metadata.name != first.metadata.name }
        let installRows = try control(NSTableView.self, "插件审阅列表", page: installation)
        checks["pluginReviewContainsAllSixComponentKinds"] = installRows.numberOfRows == 6
        for row in 0..<installRows.numberOfRows {
            installRows.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            let detail = try control(NSTextView.self, "插件审阅详情", page: installation).string
            checks["pluginComponentFullPreview-\(row)"] = detail.contains(["version-1", "version-1", "public-v1", "version-1", "hook-v1", "version-1"][row])
        }
        var layoutMeasurements: [String: [String: Any]] = [:]
        for (label, size) in [("normal", NSSize(width: 800, height: 540)), ("narrow", NSSize(width: 420, height: 360))] {
            host.setContentSize(size); pane.layoutSubtreeIfNeeded()
            let detail = try control(NSTextView.self, "插件审阅详情", page: installation)
            layoutMeasurements[label] = ["previewSize": [detail.bounds.width, detail.bounds.height], "previewViewportSize": [detail.enclosingScrollView?.bounds.width ?? -1, detail.enclosingScrollView?.bounds.height ?? -1], "listSize": [installRows.bounds.width, installRows.bounds.height], "previewAmbiguous": detail.hasAmbiguousLayout, "listAmbiguous": installRows.hasAmbiguousLayout, "listAutoresizingMask": installRows.autoresizingMask.rawValue, "listTranslatesAutoresizingMask": installRows.translatesAutoresizingMaskIntoConstraints, "listHorizontalConstraints": installRows.constraintsAffectingLayout(for: .horizontal).map(\.description), "listVerticalConstraints": installRows.constraintsAffectingLayout(for: .vertical).map(\.description), "listViewportAmbiguous": installRows.enclosingScrollView?.hasAmbiguousLayout ?? true]
            checks["pluginReviewLayout-" + label] = !detail.hasAmbiguousLayout && detail.bounds.width > 120 && detail.bounds.height >= 100 && !installRows.hasAmbiguousLayout
        }
        try JSONSerialization.data(withJSONObject: ["review": layoutMeasurements, "baseline": baselineLayout], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("plugin-review-layout.json"))
        host.setContentSize(NSSize(width: 800, height: 540))
        try press("安装", page: installation)
        var current = try plugins.installation(first.metadata.name)
        checks["pluginInstallReturnsSelectedDisabledPackage"] = pane.currentController === manager && current.metadata.version == "1.0.0" && !current.enabled && text(manager.pageContentView).contains("已安装")
        let original = current.receiptHash
        manager.review(second, replacing: current)
        guard let update = pane.currentController as? AgentPluginReviewPage else { throw PetError("更新审阅未进入子页面") }
        let rows = try control(NSTableView.self, "插件审阅列表", page: update), detail = try control(NSTextView.self, "插件审阅详情", page: update)
        let mode = try control(NSSegmentedControl.self, "插件文件读取方式", page: update)
        let types = try control(NSSegmentedControl.self, "插件审阅内容", page: update)
        let filter = try control(NSSearchField.self, "筛选插件变更文件", page: update)
        guard let diff = find(AgentGitDiffView.self, in: update.pageContentView, matching: { _ in true }) else { throw PetError("缺少插件差异阅读器") }
        let changed = Set(first.files.keys).union(second.files.keys).sorted().filter { first.files[$0] != second.files[$0] }
        checks["pluginReviewShowsEveryChangedPathBeyondOneHundred"] = changed.count > 100 && rows.numberOfRows == changed.count
        let path = "skills/check/resources/item-104.txt", index = changed.firstIndex(of: path)!
        rows.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); rows.scrollRowToVisible(index)
        let patchReady = try await waitForPatch(diff, containing: "+公开资源 104 version-2。")
        let currentPath = try control(NSTextField.self, "当前插件文件", page: update)
        checks["pluginReviewReadsActualDiffAtSelectedPath"] = patchReady
            && diff.patch.hasPrefix("@@ -1 +1 @@") && currentPath.stringValue == path
            && diff.patch.contains("-公开资源 104 version-1。") && diff.patch.contains("+公开资源 104 version-2。")
            && diff.text.records.contains { $0.kind == .removed && $0.old == 1 }
            && diff.text.records.contains { $0.kind == .added && $0.new == 1 }
        select(mode, 1)
        checks["pluginReviewCanReadLatePathAndBothActualVersions"] = detail.string.contains(path) && detail.string.contains("version-1") && detail.string.contains("version-2")
        func filterFiles(_ query: String) {
            filter.stringValue = query
            update.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: filter))
        }
        filterFiles("item-104")
        select(types, 0)
        select(types, 1)
        checks["pluginReviewRetainsFileFilterSelectionAndFullTextMode"] = rows.numberOfRows == 1 && filter.stringValue == "item-104"
            && mode.selectedSegment == 1 && detail.string.contains(path)
        filterFiles("no-such-plugin-file")
        checks["pluginReviewGivesSearchEmptyStateWithoutOldDiff"] = rows.numberOfRows == 0 && detail.string == "未找到匹配文件" && diff.isHidden
        filterFiles("sample.bin")
        select(mode, 0)
        checks["pluginReviewBinaryFileKeepsByteCountsVisible"] = rows.numberOfRows == 1 && diff.isHidden
            && detail.string.contains("二进制文件 · 2 字节") && detail.string.contains("二进制文件 · 3 字节")
        filterFiles("item-104")
        select(types, 0)
        try await Task.sleep(nanoseconds: 120_000_000)
        checks["pluginReviewCanceledComparisonCannotOverwriteComponent"] = diff.isHidden && detail.string.contains("完整技能正文")
        try press("取消", page: update)
        checks["pluginReviewCancelKeepsActualInstalledReceipt"] = try pane.currentController === manager && plugins.installation(current.id).receiptHash == original && host.firstResponder is NSTableView
        manager.review(second, replacing: current)
        guard let applied = pane.currentController as? AgentPluginReviewPage else { throw PetError("缺少更新审阅") }; try press("更新并停用", page: applied)
        current = try plugins.installation(current.id)
        checks["pluginReviewUpdatePublishesDisabledVersion"] = pane.currentController === manager && current.metadata.version == "2.0.0" && !current.enabled
        let revision = current.receipt.revisions!.first!, previous = try plugins.package(revision, of: current)
        checks["pluginReviewUpdatePreservesExactOldFiles"] = previous.files == first.files
        manager.review(previous, replacing: current, restoring: true)
        guard let stale = pane.currentController as? AgentPluginReviewPage else { throw PetError("缺少过期审阅") }
        try plugins.setEnabled(current, true); let externallyChanged = try plugins.installation(current.id)
        try press("恢复并停用", page: stale)
        checks["pluginStaleReviewKeepsPageAndRefusesPublication"] = try pane.currentController === stale && text(stale.pageContentView).contains("插件已被其他操作修改") && plugins.installation(current.id).receiptHash == externallyChanged.receiptHash
        try press("取消", page: stale)
        let catalog = try control(AgentSettingsCatalogTable.self, "插件列表", page: manager); catalog.onOpen?()
        guard let pluginEditor = pane.currentController as? AgentSettingsDetailPage else { throw PetError("插件未进入详情页") }
        checks["pluginReviewReturnRefreshesExternallyChangedState"] = find(NSButton.self, in: pluginEditor.pageContentView, matching: { $0.title == "启用插件" })?.state == .on
        pluginEditor.close()
        try plugins.setEnabled(externallyChanged, false); current = try plugins.installation(current.id)
        manager.review(try plugins.package(revision, of: current), replacing: current, restoring: true)
        guard let restoration = pane.currentController as? AgentPluginReviewPage else { throw PetError("缺少恢复审阅") }; try press("恢复并停用", page: restoration)
        current = try plugins.installation(current.id)
        checks["pluginReviewRestoreReturnsActualOriginalVersion"] = try current.metadata.version == "1.0.0" && !current.enabled && plugins.reviewPackage(current).files == first.files
        checks["pluginReviewRestorePreservesBothVersionArchives"] = current.receipt.revisions?.count == 2
        let scopes = try control(NSSegmentedControl.self, "插件范围", page: manager); scopes.selectedSegment = 1; NSApp.sendAction(scopes.action!, to: scopes.target, from: scopes)
        manager.review(first, installWorkspace: workspace)
        guard let project = pane.currentController as? AgentPluginReviewPage else { throw PetError("缺少项目插件审阅") }; try press("安装", page: project)
        let projectID = AgentPlugins.scopedID(first.metadata.name, workspace: workspace)
        current = try plugins.installation(projectID)
        checks["pluginReviewProjectInstallUsesActualProjectScope"] = current.workspace == workspace && !current.enabled && text(manager.pageContentView).contains("已安装")
        catalog.onOpen?()
        guard let projectEditor = pane.currentController as? AgentSettingsDetailPage else { throw PetError("项目插件未进入详情页") }
        try press("启用插件", page: projectEditor)
        guard let activation = pane.currentController as? AgentPluginReviewPage else { throw PetError("项目启用未进入审阅子页") }
        checks["pluginReviewActivationShowsActualComponentCount"] = try control(NSTableView.self, "插件审阅列表", page: activation).numberOfRows == 6
        try press("审阅并启用", page: activation); current = try plugins.installation(projectID)
        checks["pluginReviewActivationPreservesLocalApprovalGuard"] = current.enabled && current.locallyApproved && pane.currentController === projectEditor
        checks["pluginReviewCreatesNoVisibleManagementWindows"] = NSApp.windows.filter(\.isVisible).count == visible
        checks["pluginReviewLeavesNormally"] = pane.leave()
        return checks
    }

    static func historyRecovery(tasks: AgentStore, taskID: String, pane: AgentSettingsPageHost, host: NSWindow, output: URL) async throws -> [String: Bool] {
        guard let task = tasks.task(taskID), let workspace = task.workspace else { throw PetError("缺少历史验收项目") }
        let plugins = tasks.extensions.plugins, current = try await prepareHistory(output, tasks: tasks, workspace: workspace)
        let currentFiles = try plugins.reviewPackage(current).files
        guard let revision = current.receipt.revisions?.first else { throw PetError("缺少首个已保存版本") }
        let archived = try plugins.revision(revision, of: current)
        let context = AgentSettingsRecovery.Context(task: task, workspace: workspace)
        func make(_ kind: String) -> AgentSettingsPageController? {
            kind == "plugins" ? AgentPluginWindow(store: tasks, workspace: workspace) : nil
        }
        func openReview() throws -> AgentPluginReviewPage {
            guard let history = pane.currentController else { throw PetError("缺少历史列表") }
            try control(AgentSettingsCatalogTable.self, "插件历史版本列表", page: history).onOpen?()
            guard let review = pane.currentController as? AgentPluginReviewPage else { throw PetError("历史审阅未打开") }
            return review
        }
        func capture() throws -> AgentSettingsRecovery.State {
            guard let recovery = try pane.captureRecovery(active: true) else { throw PetError("历史位置未生成恢复记录") }
            return recovery
        }
        func reopen(_ value: AgentSettingsRecovery.State) throws {
            pane.finish(); try pane.restoreRecovery(value, make: make)
        }
        func reveal(_ marker: String, in text: NSTextView) throws -> NSRange {
            let range = (text.string as NSString).range(of: marker)
            guard range.location != NSNotFound, host.makeFirstResponder(text) else { throw PetError("缺少可选择的公开审阅行") }
            host.contentView?.layoutSubtreeIfNeeded()
            if let layout = text.layoutManager, let container = text.textContainer, let scroll = text.enclosingScrollView {
                layout.ensureLayout(for: container)
                text.setFrameSize(NSSize(width: text.frame.width, height: max(scroll.contentSize.height, layout.usedRect(for: container).maxY + text.textContainerInset.height * 2)))
            }
            text.setSelectedRange(range); text.scrollRangeToVisible(range); return range
        }
        var checks: [String: Bool] = [:]
        guard pane.show(category: "extensions", identity: context.identity, scope: "设置项目", recoveryContext: context, make: make),
              let manager = pane.currentController as? AgentPluginWindow else { throw PetError("缺少插件历史入口") }
        try manager.selectInstallation(current.id)
        guard let detail = pane.currentController, let menu = try control(NSPopUpButton.self, "插件更多操作", page: detail).itemArray.first(where: { $0.title == "历史版本" }),
              let action = menu.action, NSApp.sendAction(action, to: menu.target, from: menu), let history = pane.currentController else {
            throw PetError("未进入插件历史版本")
        }
        let historyRows = try control(AgentSettingsCatalogTable.self, "插件历史版本列表", page: history), oldest = historyRows.numberOfRows - 1
        guard oldest == 7 else { throw PetError("历史版本少于预期") }
        historyRows.selectRowIndexes(IndexSet(integer: oldest), byExtendingSelection: false); historyRows.scrollRowToVisible(oldest)
        let review = try openReview()
        let filter = try control(NSSearchField.self, "筛选插件变更文件", page: review)
        filter.stringValue = "README"; review.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: filter))
        let mode = try control(NSSegmentedControl.self, "插件文件读取方式", page: review)
        select(mode, 1)
        let full = try control(NSTextView.self, "插件审阅详情", page: review), fullSelection = try reveal("HISTORY-LINE-99-v1", in: full)
        let fullState = try capture()
        checks["historyCaptureRecordsOnlyTheValidSettingsPath"] = fullState.pages.map(\.kind) == ["plugins", "plugin-history", "plugin-history-review"]
        var missingParent = fullState; missingParent.pages.remove(at: 1)
        checks["historyReviewCannotBeReopenedWithoutItsParent"] = !missingParent.valid
        host.setContentSize(NSSize(width: 780, height: 540)); try reopen(fullState)
        try await Task.sleep(for: .milliseconds(150))
        guard let restored = pane.currentController as? AgentPluginReviewPage else { throw PetError("缺少重开的全文审阅") }
        let restoredFull = try control(NSTextView.self, "插件审阅详情", page: restored)
        checks["historyFullPreviewReopensExactSourceAndReadingSelection"] = try restored.detailHeading?.scope == "项目 · 设置项目 · 9.0.0 → 1.0.0"
            && control(NSSearchField.self, "筛选插件变更文件", page: restored).stringValue == "README"
            && control(NSTextField.self, "当前插件文件", page: restored).stringValue == "README.md"
            && restoredFull.string.contains("HISTORY-LINE-99-v2") && restoredFull.string.contains("HISTORY-LINE-99-v1")
            && restoredFull.selectedRange() == fullSelection && host.firstResponder === restoredFull && (restoredFull.enclosingScrollView?.contentView.bounds.minY ?? 0) > 0
        select(try control(NSSegmentedControl.self, "插件文件读取方式", page: restored), 0)
        guard let diff = find(AgentGitDiffView.self, in: restored.pageContentView, matching: { _ in true }),
              try await waitForPatch(diff, containing: "+HISTORY-LINE-101-v1") else { throw PetError("缺少真实历史差异") }
        let diffSelection = try reveal("HISTORY-LINE-101-v1", in: diff.text)
        let diffState = try capture(); try reopen(diffState)
        guard let diffReview = pane.currentController as? AgentPluginReviewPage,
              let restoredDiff = find(AgentGitDiffView.self, in: diffReview.pageContentView, matching: { _ in true }),
              try await waitForPatch(restoredDiff, containing: "+HISTORY-LINE-101-v1") else { throw PetError("未从同一文件重建历史差异") }
        try await Task.sleep(for: .milliseconds(100))
        checks["historyDiffRestoresPositionAfterLoading"] = restoredDiff.text.selectedRange() == diffSelection && host.firstResponder === restoredDiff.text
            && (restoredDiff.text.enclosingScrollView?.contentView.bounds.minY ?? 0) > 0 && restoredDiff.patch.contains("-HISTORY-LINE-101-v2")
        checks["reopeningReviewKeepsCurrentPluginAndArchiveBytes"] = try plugins.reviewPackage(current).files == currentFiles && plugins.revision(revision, of: current).receiptHash == archived.receiptHash
        try press("取消", page: diffReview)
        try await Task.sleep(for: .milliseconds(100))
        guard let returned = pane.currentController else { throw PetError("取消后缺少历史列表") }
        let returnedRows = try control(AgentSettingsCatalogTable.self, "插件历史版本列表", page: returned)
        let listState = try capture(); try reopen(listState)
        try await Task.sleep(for: .milliseconds(120))
        guard let reopenedHistory = pane.currentController else { throw PetError("未恢复历史列表") }
        let reopenedRows = try control(AgentSettingsCatalogTable.self, "插件历史版本列表", page: reopenedHistory)
        checks["cancelAndListReopenPreserveOriginalBackupAndScroll"] = listState.pages.map(\.kind) == ["plugins", "plugin-history"]
            && returnedRows.selectedRow == oldest && reopenedRows.selectedRow == oldest
            && (reopenedRows.enclosingScrollView?.contentView.bounds.minY ?? 0) > 0
        let active = try openReview(), archivedReadme = archived.root.appendingPathComponent("payload/README.md")
        let old = try Data(contentsOf: archivedReadme)
        func replaceArchive(_ data: Data) throws {
            try data.write(to: archivedReadme, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: archivedReadme.path)
        }
        try replaceArchive(Data("已变更的公开样例\n".utf8))
        defer { try? replaceArchive(old) }
        try press("恢复并停用", page: active)
        checks["confirmationRechecksTheActualArchivedFile"] = try pane.currentController === active && text(active.pageContentView).contains("插件文件已变化") && plugins.installation(current.id).receiptHash == current.receiptHash
        do { try reopen(diffState); checks["changedBackupRefusesReopenWithoutPublishing"] = false }
        catch { checks["changedBackupRefusesReopenWithoutPublishing"] = try error.localizedDescription.contains("插件文件已变化") && plugins.installation(current.id).receiptHash == current.receiptHash }
        try replaceArchive(old); try reopen(fullState)
        guard let valid = pane.currentController as? AgentPluginReviewPage else { throw PetError("原件复原后未恢复审阅") }
        try press("恢复并停用", page: valid)
        let result = try plugins.installation(current.id)
        checks["explicitConfirmationRestoresExactPluginInTheOriginalProject"] = result.workspace == workspace && result.metadata.version == "1.0.0" && !result.enabled
            && result.receipt.hashes == archived.receipt.hashes && result.receipt.revisions?.count == 9 && result.receipt.revisions?.last?.receiptHash == current.receiptHash
        if let backup = result.receipt.revisions?.last { checks["confirmationPreservesExactPriorVersionFiles"] = try plugins.package(backup, of: result).files == currentFiles }
        else { checks["confirmationPreservesExactPriorVersionFiles"] = false }
        do { try reopen(fullState); checks["changedCurrentVersionDoesNotReviveObsoleteReview"] = false }
        catch { checks["changedCurrentVersionDoesNotReviveObsoleteReview"] = try error.localizedDescription.contains("当前插件版本已变化") && plugins.installation(current.id).receiptHash == result.receiptHash }
        return checks
    }
}

@MainActor extension AppDelegate {
    func runPluginReviewCheck(_ output: URL) async {
        var report: [String: Any] = ["appPID": getpid(), "modelRequests": 0]
        do {
            let tasks = AgentStore(directory: store.directory, legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            let project = output.appendingPathComponent("设置项目")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let task = tasks.create(title: "插件审阅验收", workspace: project.path)
            let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 540),
                styleMask: [.titled], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            let pane = AgentSettingsPageHost(); host.contentView = pane
            host.makeKeyAndOrderFront(nil)
            var checks = try await AgentPluginReviewCheck.run(tasks: tasks, taskID: task, pane: pane, host: host, output: output)
            report["checks"] = checks
            checks.merge(try await AgentPluginReviewCheck.historyRecovery(tasks: tasks, taskID: task, pane: pane, host: host, output: output)) { _, new in new }
            report["checks"] = checks
            report["success"] = checks.values.allSatisfy { $0 }
            host.close()
        } catch {
            report["error"] = error.localizedDescription
            report["success"] = false
        }
        try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("plugin-review-report.json"))
    }
}
