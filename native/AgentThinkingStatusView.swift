import AppKit

@MainActor final class AgentThinkingStatusView: NSStackView, NSTextFieldDelegate {
    private let service: AgentThinkingStatus
    private let loader = NSPopUpButton(), preview = AgentThinkingIndicator()
    private let save = NSButton(title: "保存文案", target: nil, action: nil), resetAll = NSButton(title: "全部恢复", target: nil, action: nil)
    private let reload = NSButton(title: "重新载入", target: nil, action: nil), status = NSTextField(wrappingLabelWithString: "")
    private var fields: [NSTextField] = [], counts: [NSTextField] = [], resets: [NSButton] = []
    private var baseline: [AgentThinkingStatus.Caption], draft: [AgentThinkingStatus.Caption]
    var dirty: Bool { draft != baseline }
    init(service: AgentThinkingStatus) {
        self.service = service; baseline = service.settings.captions; draft = baseline; super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 18
        loader.addItems(withTitles: AgentThinkingStatus.Loader.allCases.map(\.title)); loader.target = self; loader.action = #selector(changeLoader)
        loader.identifier = NSUserInterfaceItemIdentifier("thinking-loader"); loader.setAccessibilityLabel("思考状态 Loader")
        let loaderRow = AgentSettingsStyle.formRow("加载动效", loader, trailing: true); append(loaderRow)
        append(preview)
        for (button, title, action) in [(save, "保存文案", #selector(saveCaptions)), (resetAll, "全部恢复", #selector(restoreAll)), (reload, "重新载入", #selector(reloadSettings))] {
            button.bezelStyle = .rounded; button.target = self; button.action = action; button.setAccessibilityLabel(title)
        }
        save.identifier = NSUserInterfaceItemIdentifier("thinking-save"); resetAll.identifier = NSUserInterfaceItemIdentifier("thinking-reset-all"); reload.identifier = NSUserInterfaceItemIdentifier("thinking-reload")
        status.font = .systemFont(ofSize: 12); status.textColor = .systemRed; status.setAccessibilityLabel("思考状态保存状态")
        let actions = NSStackView(views: [resetAll, NSView(), reload, save]); actions.spacing = 8; append(actions); append(status)
        let table = NSStackView(); table.orientation = .vertical; table.alignment = .leading; table.spacing = 10
        func cell(_ title: String) -> NSTextField { let value = NSTextField(labelWithString: title); value.font = .systemFont(ofSize: 12); value.textColor = AgentWorkbenchTheme.secondaryText; return value }
        let number = cell(""), zh = cell("中文"), en = cell("English"), end = NSView()
        number.widthAnchor.constraint(equalToConstant: 22).isActive = true; end.widthAnchor.constraint(equalToConstant: 28).isActive = true
        zh.identifier = NSUserInterfaceItemIdentifier("thinking-column-zh"); en.identifier = NSUserInterfaceItemIdentifier("thinking-column-en")
        let header = NSStackView(views: [number, zh, en, end]); header.spacing = 10; header.distribution = .fill; zh.widthAnchor.constraint(equalTo: en.widthAnchor).isActive = true
        table.addArrangedSubview(header); header.widthAnchor.constraint(equalTo: table.widthAnchor).isActive = true
        for index in 0..<20 {
            let number = cell(String(index + 1)); number.widthAnchor.constraint(equalToConstant: 22).isActive = true
            var columns: [NSView] = []
            for language in 0..<2 {
                let field = NSTextField(); field.delegate = self; field.tag = index * 2 + language; field.font = .systemFont(ofSize: 13); field.isBezeled = false; field.drawsBackground = false
                field.setAccessibilityLabel("编辑" + (language == 0 ? "中文" : "英文") + "文案 \(index + 1)"); field.identifier = NSUserInterfaceItemIdentifier("thinking-caption-\(index + 1)-" + (language == 0 ? "zh" : "en"))
                field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let count = cell(""); count.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular); count.alignment = .right; count.widthAnchor.constraint(equalToConstant: 39).isActive = true
                let inside = NSStackView(views: [field, count]); inside.spacing = 3; inside.alignment = .centerY; inside.translatesAutoresizingMaskIntoConstraints = false
                let box = AgentThemeView(fill: AgentWorkbenchTheme.surface, stroke: AgentWorkbenchTheme.line); box.layer?.cornerRadius = 5; box.layer?.borderWidth = 1; box.addSubview(inside)
                NSLayoutConstraint.activate([inside.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 7), inside.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6), inside.topAnchor.constraint(equalTo: box.topAnchor, constant: 7), inside.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -7), box.widthAnchor.constraint(greaterThanOrEqualToConstant: 125)])
                fields.append(field); counts.append(count); columns.append(box)
            }
            let reset = AgentWorkbenchButton(); AgentWorkbenchTheme.toolbar(reset, title: "恢复文案 \(index + 1)", symbol: "arrow.counterclockwise"); reset.tag = index; reset.target = self; reset.action = #selector(restoreRow(_:)); resets.append(reset)
            let row = NSStackView(views: [number] + columns + [reset]); row.spacing = 10; row.alignment = .centerY; row.distribution = .fill
            columns[0].widthAnchor.constraint(equalTo: columns[1].widthAnchor).isActive = true
            table.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: table.widthAnchor).isActive = true
            if index == 0 { zh.widthAnchor.constraint(equalTo: columns[0].widthAnchor).isActive = true; en.widthAnchor.constraint(equalTo: columns[1].widthAnchor).isActive = true }
            if index < 19 { let rule = AgentWorkbenchTheme.rule(); table.addArrangedSubview(rule); rule.widthAnchor.constraint(equalTo: table.widthAnchor).isActive = true }
        }
        append(table)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: AgentThinkingStatus.changed, object: service)
        renderFields(); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func append(_ view: NSView) { addArrangedSubview(view); view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
    private func renderFields() {
        for index in 0..<20 { fields[index * 2].stringValue = draft[index].zh; fields[index * 2 + 1].stringValue = draft[index].en }
    }
    @objc private func settingsChanged() {
        if !dirty { baseline = service.settings.captions; draft = baseline; renderFields() }
        refresh()
    }
    private func refresh() {
        loader.selectItem(at: AgentThinkingStatus.Loader.allCases.firstIndex(of: service.settings.loader) ?? 0)
        loader.isEnabled = service.error == nil
        for (index, field) in fields.enumerated() {
            let length = field.stringValue.utf16.count; counts[index].stringValue = "\(length)/64"; counts[index].textColor = length > 64 ? .systemRed : AgentWorkbenchTheme.secondaryText
            field.isEnabled = service.error == nil
        }
        for index in 0..<20 { resets[index].isEnabled = service.error == nil && draft[index] != AgentThinkingStatus.defaults[index] }
        resetAll.isEnabled = service.error == nil && draft != AgentThinkingStatus.defaults
        save.isEnabled = service.error == nil && dirty && (try? AgentThinkingStatus.normalized(draft)) != nil
        if let error = service.error { status.stringValue = error }
        status.isHidden = status.stringValue.isEmpty; reload.isHidden = status.stringValue.isEmpty
        preview.update(service.settings, active: true)
    }
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, fields.contains(field) else { return }
        let index = field.tag / 2
        if field.tag % 2 == 0 { draft[index].zh = field.stringValue } else { draft[index].en = field.stringValue }
        status.stringValue = (try? AgentThinkingStatus.normalized(draft)) == nil ? "文案最多 64 个字符，不能换行" : ""; refresh()
    }
    @objc private func changeLoader() {
        do { try service.saveLoader(AgentThinkingStatus.Loader.allCases[max(0, loader.indexOfSelectedItem)]); status.stringValue = "" }
        catch { status.stringValue = error.localizedDescription }; refresh()
    }
    @discardableResult @objc func saveCaptions() -> Bool {
        window?.makeFirstResponder(save)
        do { try service.saveCaptions(draft, expected: baseline); baseline = service.settings.captions; draft = baseline; renderFields(); status.stringValue = ""; refresh(); return true }
        catch { status.stringValue = error.localizedDescription; refresh(); return false }
    }
    @objc private func restoreRow(_ sender: NSButton) { draft[sender.tag] = AgentThinkingStatus.defaults[sender.tag]; renderFields(); status.stringValue = ""; refresh() }
    @objc private func restoreAll() { draft = AgentThinkingStatus.defaults; renderFields(); status.stringValue = ""; refresh() }
    @objc private func reloadSettings() {
        guard !dirty || AgentUnsavedChanges.discard("重新载入思考文案？", detail: "当前未保存的文案将被替换。", discardTitle: "重新载入") else { return }
        service.reload(); if service.error == nil { baseline = service.settings.captions; draft = baseline; renderFields(); NotificationCenter.default.post(name: AgentThinkingStatus.changed, object: service) }
        status.stringValue = service.error ?? ""; refresh()
    }
    func prepareToClose() -> Bool {
        guard dirty else { return true }
        switch AgentUnsavedChanges.saveOrDiscard("保存思考文案更改？") {
        case .alertFirstButtonReturn: return saveCaptions()
        case .alertSecondButtonReturn: baseline = service.settings.captions; draft = baseline; renderFields(); status.stringValue = ""; refresh(); return true
        default: return false
        }
    }
    func readback() -> [String: Any] { ["dirty": dirty, "draft": draft.map { ["zh": $0.zh, "en": $0.en] }, "savedLoader": service.settings.loader.rawValue, "saveEnabled": save.isEnabled, "error": status.stringValue, "preview": preview.readback()] }
}
