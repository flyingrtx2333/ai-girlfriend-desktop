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
    static func prepareSources(_ output: URL) throws -> [URL] {
        let fm = FileManager.default, source = output.appendingPathComponent("插件审阅来源")
        func prepare(_ version: Int) throws -> URL {
            let root = source.appendingPathComponent("v\(version)")
            let manifest: [String: Any] = ["name": "review-inline", "displayName": "设置审阅插件", "version": "\(version).0.0", "description": "公开文本的插件页面检查"]
            var files: [String: Data] = [".qoder-plugin/plugin.json": try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])]
            let values = ["README.md": "公开插件版本 \(version)。\n", "skills/check/SKILL.md": "---\nname: check\ndescription: 公开技能\n---\n完整技能正文 version-\(version)。\n", "commands/check.md": "公开命令 version-\(version)。\n$ARGUMENTS\n", "agents/reviewer.md": "---\nname: reviewer\ndescription: 公开只读审阅角色\ntools: [read_file]\nreadOnly: true\nnetwork: false\n---\n完整角色指令 version-\(version)。\n", "rules/check.md": "---\ntrigger: always_on\n---\n完整规则正文 version-\(version)。\n"]
            for (name, value) in values { files[name] = Data(value.utf8) }
            files[".mcp.json"] = try JSONSerialization.data(withJSONObject: ["mcpServers": ["local": ["command": "/usr/bin/true", "args": ["public-v\(version)"]]]], options: [.sortedKeys])
            files["hooks/hooks.json"] = try JSONSerialization.data(withJSONObject: ["hooks": ["SessionStart": [["hooks": [["name": "public", "type": "command", "command": "/usr/bin/true", "args": ["hook-v\(version)"], "network": false, "timeout": 10]]]]]], options: [.sortedKeys])
            for index in 0..<105 { files[String(format: "skills/check/resources/item-%03d.txt", index)] = Data("公开资源 \(index) version-\(version)。\n".utf8) }
            for (name, bytes) in files { let file = root.appendingPathComponent(name); try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true); try bytes.write(to: file) }
            return root
        }
        return try [prepare(1), prepare(2)]
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
        let changed = Set(first.files.keys).union(second.files.keys).sorted().filter { first.files[$0] != second.files[$0] }
        checks["pluginReviewShowsEveryChangedPathBeyondOneHundred"] = changed.count > 100 && rows.numberOfRows == changed.count
        let path = "skills/check/resources/item-104.txt", index = changed.firstIndex(of: path)!
        rows.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); rows.scrollRowToVisible(index)
        checks["pluginReviewCanReadLatePathAndBothActualVersions"] = detail.string.contains(path) && detail.string.contains("version-1") && detail.string.contains("version-2")
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
        checks["pluginReviewReturnRefreshesExternallyChangedState"] = find(NSButton.self, in: manager.pageContentView, matching: { $0.title == "启用插件" })?.state == .on
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
        try press("启用插件", page: manager)
        guard let activation = pane.currentController as? AgentPluginReviewPage else { throw PetError("项目启用未进入审阅子页") }
        checks["pluginReviewActivationShowsActualComponentCount"] = try control(NSTableView.self, "插件审阅列表", page: activation).numberOfRows == 6
        try press("审阅并启用", page: activation); current = try plugins.installation(projectID)
        checks["pluginReviewActivationPreservesLocalApprovalGuard"] = current.enabled && current.locallyApproved && pane.currentController === manager
        checks["pluginReviewCreatesNoVisibleManagementWindows"] = NSApp.windows.filter(\.isVisible).count == visible
        checks["pluginReviewLeavesNormally"] = pane.leave()
        return checks
    }
}
