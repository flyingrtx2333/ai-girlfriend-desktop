import AppKit
import UniformTypeIdentifiers

@MainActor final class AgentHookWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let service: AgentHooks
    private let workspace: String?
    private let table = NSTableView(), command = NSTextView()
    private let enabled = NSButton(checkboxWithTitle: "启用", target: nil, action: nil)
    private let state = NSTextField(labelWithString: ""), location = NSTextField(labelWithString: "")
    private let scope = NSPopUpButton(), reveal = NSButton(title: "打开来源", target: nil, action: nil)
    private let clear = NSButton(title: "清除凭据", target: nil, action: nil)
    private var items: [AgentHookDefinition] = [], selected: AgentHookDefinition?
    private var configWindow: AgentHookConfigWindow?
    init(service: AgentHooks, workspace: String?) {
        self.service = service; self.workspace = workspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Hooks"; window.minSize = NSSize(width: 700, height: 420); window.center(); window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        super.init(window: window)
        let content = NSView(); window.contentView = content
        scope.addItems(withTitles: ["全局", "当前项目"]); scope.item(at: 1)?.isEnabled = workspace != nil; scope.setAccessibilityLabel("Hooks 配置范围")
        let edit = NSButton(title: "编辑配置", target: self, action: #selector(editConfig)), importButton = NSButton(title: "导入", target: self, action: #selector(importConfig)), refresh = NSButton(title: "刷新", target: self, action: #selector(refreshList))
        let header = NSStackView(views: [scope, edit, importButton, NSView(), refresh]); header.spacing = 10
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hook"))); table.headerView = nil; table.rowHeight = 52; table.dataSource = self; table.delegate = self; table.setAccessibilityLabel("Hooks 列表")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true
        enabled.target = self; enabled.action = #selector(toggleEnabled)
        reveal.target = self; reveal.action = #selector(revealSource)
        clear.target = self; clear.action = #selector(clearCredentials)
        command.isEditable = false; command.isRichText = false; command.font = .monospacedSystemFont(ofSize: 12, weight: .regular); command.textContainerInset = NSSize(width: 12, height: 12)
        command.isVerticallyResizable = true; command.autoresizingMask = [.width]; command.textContainer?.widthTracksTextView = true; command.setAccessibilityLabel("Hook 处理器")
        let viewer = NSScrollView(); viewer.documentView = command; viewer.hasVerticalScroller = true; viewer.borderType = .bezelBorder
        for label in [location, state] { label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor; label.lineBreakMode = .byTruncatingMiddle; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let detail = NSStackView(views: [enabled, NSView(), clear, reveal]); detail.spacing = 10
        for view in [header, list, detail, location, viewer, state] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), header.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), header.heightAnchor.constraint(equalToConstant: 28),
            list.leadingAnchor.constraint(equalTo: header.leadingAnchor), list.widthAnchor.constraint(equalToConstant: 255), list.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12), list.bottomAnchor.constraint(equalTo: state.topAnchor, constant: -12),
            detail.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 12), detail.trailingAnchor.constraint(equalTo: header.trailingAnchor), detail.topAnchor.constraint(equalTo: list.topAnchor), detail.heightAnchor.constraint(equalToConstant: 28),
            location.leadingAnchor.constraint(equalTo: detail.leadingAnchor), location.trailingAnchor.constraint(equalTo: detail.trailingAnchor), location.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 8),
            viewer.leadingAnchor.constraint(equalTo: detail.leadingAnchor), viewer.trailingAnchor.constraint(equalTo: detail.trailingAnchor), viewer.topAnchor.constraint(equalTo: location.bottomAnchor, constant: 8), viewer.bottomAnchor.constraint(equalTo: list.bottomAnchor),
            state.leadingAnchor.constraint(equalTo: header.leadingAnchor), state.trailingAnchor.constraint(equalTo: header.trailingAnchor), state.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14), state.heightAnchor.constraint(equalToConstant: 18)
        ]); reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row], title = NSTextField(labelWithString: item.name)
        title.font = .systemFont(ofSize: 12, weight: .semibold); title.lineBreakMode = .byTruncatingTail
        let label = !service.enabled(item) ? "已停用" : service.trusted(item) ? "已启用" : "待审核"
        let subtitle = NSTextField(labelWithString: item.event.rawValue + " · " + item.scope + " · " + label); subtitle.font = .systemFont(ofSize: 10); subtitle.textColor = .secondaryLabelColor; subtitle.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [title, subtitle]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4; stack.toolTip = item.matcher; return stack
    }
    func tableViewSelectionDidChange(_ notification: Notification) { showSelection() }
    private func showSelection() {
        selected = items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil
        enabled.isEnabled = selected != nil && selected?.pluginEnabled != false; reveal.isEnabled = selected != nil
        clear.isHidden = !["http", "command"].contains(selected?.type ?? ""); clear.isEnabled = selected?.headerNames?.isEmpty == false || selected?.environmentNames?.isEmpty == false
        guard let item = selected else { command.string = ""; location.stringValue = ""; enabled.state = .off; return }
        enabled.state = service.enabled(item) ? .on : .off
        command.string = item.display
        let timeout = item.timeout.isFinite && (1...600).contains(item.timeout) ? " · \(Int(item.timeout))s" : ""
        location.stringValue = item.type + " · " + item.event.rawValue + (item.matcher.isEmpty ? "" : " · " + item.matcher) + timeout + (item.runsInBackground ? item.asyncRewake == true ? " · 后台唤醒" : " · 后台" : "") + (item.network ? " · 联网" : "")
        location.toolTip = item.source
        if item.pluginEnabled == false { state.stringValue = "所属插件已停用，请先在插件管理中启用" }
        else if let diagnostic = item.diagnostic { state.stringValue = diagnostic }
        else if service.enabled(item) && !service.trusted(item) { state.stringValue = "配置或脚本已变化，重新启用前需审核" }
    }
    private func reload(select id: String? = nil) {
        do {
            let previous = id ?? selected?.id; items = try service.catalog(workspace: workspace)
            table.delegate = nil; table.reloadData()
            if let index = items.firstIndex(where: { $0.id == previous }) ?? items.indices.first { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
            else { table.deselectAll(nil) }; table.delegate = self
            state.stringValue = service.warnings.isEmpty ? (items.isEmpty ? "暂无 Hooks" : "\(items.count) 项") : service.warnings.joined(separator: "\n"); state.toolTip = state.stringValue
            showSelection()
        } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func refreshList() { reload() }
    func selectHook(_ id: String) { reload(select: id) }
    @objc private func revealSource() { if let selected { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: selected.source)]) } }
    @objc private func clearCredentials() {
        guard let selected, let window else { return }
        let alert = NSAlert(); alert.messageText = "清除已保存的 Hook 凭据？"; alert.informativeText = selected.name + "\n停用此处理器并清除钥匙串中的 " + (selected.type == "http" ? "Headers" : "env") + "。来源文件内直接填写的值可通过「打开来源」移除。"; alert.addButton(withTitle: "清除"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in guard response == .alertFirstButtonReturn, let self else { return }; do { try service.clearCredentials(selected, workspace: workspace); reload(select: selected.id) } catch { state.stringValue = error.localizedDescription } }
    }
    @objc private func toggleEnabled() {
        guard let item = selected else { return }
        if enabled.state == .off {
            do { try service.setEnabled(item, false, workspace: workspace); reload(select: item.id) } catch { state.stringValue = error.localizedDescription }; return
        }
        enabled.state = service.enabled(item) ? .on : .off
        guard item.diagnostic == nil, let window else { reload(select: item.id); return }
        let alert = NSAlert(); alert.messageText = "启用「\(item.name)」？"
        let consequence: String
        switch item.type {
        case "http": consequence = "将自动向此地址发送当前事件数据。Header 可按 allowedEnvVars 引用应用环境；未指定白名单时允许所有变量。重定向不会跟随。"
        case "prompt": consequence = "将使用任务的模型连接独立判断当前事件，产生模型用量。"
        case "agent": consequence = "将创建独立模型校验任务，只读项目，按工具白名单执行，产生模型用量。" + (item.network ? "允许终端联网。" : "终端不联网。")
        default: consequence = "此命令将自动运行，可修改任务项目、读取应用进程环境。" + (item.network ? "允许访问网络。" : "不允许访问网络。")
        }
        alert.informativeText = item.event.rawValue + " · " + item.scope + "\n" + item.display + "\n\n" + consequence + (item.runsInBackground ? "\n在后台运行，结果不改变审批或工具参数。" : "") + (item.asyncRewake == true ? "退出码为 2 时可继续任务并产生模型用量。" : "")
        alert.addButton(withTitle: "启用"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn { do { try service.setEnabled(item, true, workspace: workspace) } catch { state.stringValue = error.localizedDescription } }; reload(select: item.id)
        }
    }
    @objc private func editConfig() {
        if let reference = selected?.plugin { openPluginConfig(reference) } else { openConfig(imported: nil) }
    }
    private func openPluginConfig(_ reference: AgentPluginHookReference) {
        if let window = configWindow?.window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        do {
            let document = try service.pluginDocument(reference)
            let editor = AgentHookConfigWindow(text: document.text, title: "插件 Hooks · " + reference.name) { [weak self] text in
                guard let self else { return }
                try service.savePluginDocument(text, reference: reference, original: document.original, expectedHash: document.hash); reload()
            }; configWindow = editor; editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil)
        } catch { state.stringValue = error.localizedDescription }
    }
    private func openConfig(imported: String?) {
        if let window = configWindow?.window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        do {
            let project = scope.indexOfSelectedItem == 1, document = try service.document(project: project, workspace: workspace)
            let importedData = imported.map { Data($0.utf8) }
            let masked = try importedData.map { String(decoding: try service.credentials.mask($0), as: UTF8.self) }
            let editor = AgentHookConfigWindow(text: masked ?? document.0, title: project ? "项目 Hooks" : "全局 Hooks") { [weak self] text in
                guard let self else { return }
                let data = try importedData.map { try self.service.credentials.restoreImported(Data(text.utf8), original: $0, file: self.service.file(project: project, workspace: self.workspace)) } ?? Data(text.utf8)
                try service.save(String(decoding: data, as: UTF8.self), project: project, workspace: workspace, expectedHash: document.1); reload()
            }; configWindow = editor; editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil)
        } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func importConfig() {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            do {
                let files = try AgentFiles(workspace: url.deletingLastPathComponent().path), data = try files.readData(files.resolve(url.lastPathComponent), maximum: 128_000)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let hooks = object["hooks"] as? [String: Any] else { throw PetError("文件中没有 hooks 对象") }
                openConfig(imported: String(decoding: try JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self))
            } catch { state.stringValue = error.localizedDescription }
        }
    }
}

@MainActor private final class AgentHookConfigWindow: NSWindowController, NSWindowDelegate {
    private let editor = NSTextView(), state = NSTextField(labelWithString: "")
    private let save: (String) throws -> Void
    private let original: String
    private var saved = false
    init(text: String, title: String, save: @escaping (String) throws -> Void) {
        self.save = save; original = text
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.minSize = NSSize(width: 560, height: 350); window.center(); window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        super.init(window: window); window.delegate = self
        editor.string = text; editor.isRichText = false; editor.allowsUndo = true; editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular); editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true; editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false; editor.setAccessibilityLabel("Hooks JSON 配置")
        let scroll = NSScrollView(); scroll.documentView = editor; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let button = NSButton(title: "保存", target: self, action: #selector(saveConfig)); button.keyEquivalent = "s"; button.keyEquivalentModifierMask = .command
        state.font = .systemFont(ofSize: 11); state.textColor = .secondaryLabelColor; state.lineBreakMode = .byTruncatingTail
        let footer = NSStackView(views: [state, NSView(), button]); footer.spacing = 8
        let content = NSView(); window.contentView = content
        for view in [scroll, footer] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12), scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10), footer.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), footer.trailingAnchor.constraint(equalTo: scroll.trailingAnchor), footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12), footer.heightAnchor.constraint(equalToConstant: 28)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func saveConfig() { do { try save(editor.string); saved = true; close() } catch { state.stringValue = error.localizedDescription; state.toolTip = state.stringValue } }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !saved, editor.string != original else { return true }
        let alert = NSAlert(); alert.messageText = "放弃未保存的更改？"; alert.addButton(withTitle: "放弃"); alert.addButton(withTitle: "继续编辑"); return alert.runModal() == .alertFirstButtonReturn
    }
}
