import AppKit

@MainActor final class AgentMCPConfigForm: NSObject, NSTextFieldDelegate {
    private(set) var view = NSScrollView()
    private let name = NSTextField(), transport = NSPopUpButton(), command = NSTextField(), directory = NSTextField(), address = NSTextField(), bearer = NSSecureTextField(), timeout = NSTextField()
    private let arguments = AgentMCPConfigRows(title: "参数", paired: false, secure: false, limit: 100)
    private let environment = AgentMCPConfigRows(title: "环境变量", paired: true, secure: true, limit: 64)
    private let headers = AgentMCPConfigRows(title: "请求头", paired: true, secure: true, limit: 64)
    private var local = NSStackView(), remote = NSStackView()
    private let original: [String: Any]
    var onChange: (() -> Void)?
    var firstInput: NSView { name.isEnabled ? name : type == "stdio" ? command : address }
    var type: String { ["stdio", "http", "sse"][max(0, transport.indexOfSelectedItem)] }

    init(document: String, pluginLocked: Bool) throws {
        guard document.utf8.count <= 64_000, let value = try JSONSerialization.jsonObject(with: Data(document.utf8)) as? [String: Any],
              let title = value["name"] as? String, let type = value["type"] as? String, ["stdio", "http", "sse"].contains(type) else { throw PetError("请先载入单个连接器的有效 JSON 配置") }
        let keys: Set<String> = ["name", "type", "command", "args", "env", "cwd", "url", "bearerToken", "headers", "timeoutSeconds"]
        guard Set(value.keys).isSubset(of: keys) else { throw PetError("请先在 JSON 中处理未知配置字段：" + Set(value.keys).subtracting(keys).sorted().joined(separator: ", ")) }
        guard value["args"] == nil || value["args"] is [String], value["env"] == nil || value["env"] is [String: String], value["headers"] == nil || value["headers"] is [String: String],
              ["command", "cwd", "url", "bearerToken"].allSatisfy({ value[$0] == nil || value[$0] is String }), value["timeoutSeconds"] == nil || value["timeoutSeconds"] is Double else { throw PetError("JSON 配置字段格式无效，原文已保留") }
        if let raw = value["timeoutSeconds"], CFGetTypeID(raw as CFTypeRef) == CFBooleanGetTypeID() { throw PetError("timeoutSeconds 必须是秒数") }
        original = value
        super.init()
        name.stringValue = title; name.isEnabled = !pluginLocked
        transport.addItems(withTitles: ["STDIO", "HTTP", "SSE"]); transport.selectItem(at: ["stdio", "http", "sse"].firstIndex(of: type)!); transport.isEnabled = !pluginLocked
        command.stringValue = value["command"] as? String ?? ""; directory.stringValue = value["cwd"] as? String ?? ""
        address.stringValue = value["url"] as? String ?? ""; bearer.stringValue = value["bearerToken"] as? String ?? ""
        if let seconds = value["timeoutSeconds"] as? Double { timeout.stringValue = NSNumber(value: seconds * 1000).stringValue }
        timeout.placeholderString = "60000"; timeout.toolTip = "1000 至 600000 毫秒"; directory.placeholderString = "默认当前项目或用户目录"
        command.placeholderString = "/opt/homebrew/bin/node"; address.placeholderString = "https://example.com/mcp"
        try arguments.load(value["args"] as? [String] ?? []); try environment.load(value["env"] as? [String: String] ?? [:]); try headers.load(value["headers"] as? [String: String] ?? [:])
        local = AgentSettingsStyle.section("本机程序", id: "mcp-stdio", rows: [AgentSettingsStyle.labeledField("命令", command), arguments.view, environment.view, AgentSettingsStyle.labeledField("工作目录", directory)])
        remote = AgentSettingsStyle.section("远程连接", id: "mcp-http", rows: [AgentSettingsStyle.labeledField("地址", address), AgentSettingsStyle.labeledField("Bearer Token", bearer), headers.view])
        view = AgentSettingsStyle.form([
            AgentSettingsStyle.section("基本信息", id: "mcp-basic", rows: [AgentSettingsStyle.labeledField("名称", name), AgentSettingsStyle.formRow("传输方式", transport, trailing: true)]),
            local, remote, AgentSettingsStyle.section("连接选项", id: "mcp-timeout", rows: [AgentSettingsStyle.labeledField("超时（毫秒）", timeout)])
        ], label: "MCP 配置表单")
        for (field, label) in [(name, "名称"), (command, "命令"), (directory, "工作目录"), (address, "地址"), (bearer, "Bearer Token"), (timeout, "超时毫秒")] { field.delegate = self; field.setAccessibilityLabel("MCP " + label); field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        transport.setAccessibilityLabel("MCP 传输方式"); transport.target = self; transport.action = #selector(changed)
        for rows in [arguments, environment, headers] { rows.onChange = { [weak self] in self?.onChange?() } }
        updateTransport()
    }
    private func updateTransport() { local.isHidden = type != "stdio"; remote.isHidden = type == "stdio" }
    func controlTextDidChange(_ notification: Notification) { onChange?() }
    @objc private func changed() { updateTransport(); onChange?() }
    func setEnabled(_ enabled: Bool, pluginLocked: Bool) {
        for field in [name, command, directory, address, bearer, timeout] { field.isEnabled = enabled }
        name.isEnabled = enabled && !pluginLocked; transport.isEnabled = enabled && !pluginLocked
        for rows in [arguments, environment, headers] { rows.setEnabled(enabled) }
    }
    func document() throws -> String {
        var value: [String: Any] = ["name": name.stringValue, "type": type]
        if type == "stdio" {
            value["command"] = AgentMCP.configurationCommand(command.stringValue); value["args"] = arguments.values(); value["env"] = try environment.pairs()
            if !directory.stringValue.isEmpty { value["cwd"] = directory.stringValue }
        } else { value["url"] = address.stringValue; value["bearerToken"] = bearer.stringValue; value["headers"] = try headers.pairs() }
        // Keep fields of the other transport until it is deliberately changed.
        if original["type"] as? String == type {
            for key in type == "stdio" ? ["url", "bearerToken", "headers"] : ["command", "args", "env", "cwd"] { value[key] = original[key] }
        }
        if !timeout.stringValue.isEmpty {
            guard let milliseconds = Double(timeout.stringValue), milliseconds.isFinite, (1000...600_000).contains(milliseconds) else { throw PetError("超时范围为 1000 至 600000 毫秒") }
            value["timeoutSeconds"] = milliseconds / 1000
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}

@MainActor private final class AgentMCPConfigRows: NSObject, NSTextFieldDelegate {
    let view = NSStackView()
    private let rows = NSStackView(), title: String, paired: Bool, secure: Bool, limit: Int
    private let add = NSButton()
    private var entries: [(row: NSStackView, key: NSTextField?, value: NSTextField)] = []
    var onChange: (() -> Void)?
    init(title: String, paired: Bool, secure: Bool, limit: Int) {
        self.title = title; self.paired = paired; self.secure = secure; self.limit = limit; super.init()
        let heading = NSTextField(labelWithString: title); heading.font = .systemFont(ofSize: 13)
        add.title = "添加"; add.target = self; add.action = #selector(appendRow); add.setAccessibilityLabel("添加 MCP " + title)
        let header = NSStackView(views: [heading, NSView(), add]); header.spacing = 8
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 8
        view.orientation = .vertical; view.alignment = .leading; view.spacing = 8
        for child in [header, rows] { view.addArrangedSubview(child); child.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true }
    }
    func load(_ values: [String]) throws { guard values.count <= limit else { throw PetError(title + "数量超过限制") }; for value in values { insert(nil, value) } }
    func load(_ values: [String: String]) throws { guard values.count <= limit else { throw PetError(title + "数量超过限制") }; for key in values.keys.sorted() { insert(key, values[key]!) } }
    private func insert(_ key: String?, _ value: String) {
        let input: NSTextField = secure ? NSSecureTextField() : NSTextField(); input.stringValue = value
        let name: NSTextField? = paired ? NSTextField() : nil; name?.stringValue = key ?? ""; name?.placeholderString = "名称"
        input.placeholderString = "值"
        for field in [name, input].compactMap({ $0 }) { AgentSettingsStyle.field(field); field.delegate = self; field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: nil)!, target: self, action: #selector(removeRow(_:))); remove.isBordered = false; remove.setAccessibilityLabel("移除 MCP " + title + "行")
        let row = NSStackView(views: [name, input, remove].compactMap { $0 }); row.spacing = 8
        if let name { name.widthAnchor.constraint(equalTo: input.widthAnchor, multiplier: 0.7).isActive = true }
        remove.widthAnchor.constraint(equalToConstant: 24).isActive = true
        rows.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true; entries.append((row, name, input)); relabel()
    }
    private func relabel() {
        for (i, entry) in entries.enumerated() { entry.key?.setAccessibilityLabel("MCP \(title) \(i + 1) 名称"); entry.value.setAccessibilityLabel("MCP \(title) \(i + 1) 值") }; add.isEnabled = entries.count < limit
    }
    @objc private func appendRow() { guard entries.count < limit else { return }; insert(paired ? "" : nil, ""); onChange?(); if let last = entries.last { view.window?.makeFirstResponder(last.key ?? last.value) } }
    @objc private func removeRow(_ sender: NSButton) {
        guard let index = entries.firstIndex(where: { sender.isDescendant(of: $0.row) }) else { return }
        let entry = entries.remove(at: index); rows.removeArrangedSubview(entry.row); entry.row.removeFromSuperview(); relabel(); onChange?()
    }
    func controlTextDidChange(_ notification: Notification) { onChange?() }
    func values() -> [String] { entries.map { $0.value.stringValue } }
    func pairs() throws -> [String: String] {
        var result: [String: String] = [:]
        for entry in entries {
            let name = entry.key!.stringValue
            guard !name.isEmpty else { throw PetError("请填写" + title + "名称") }
            guard !result.keys.contains(where: { paired && title == "请求头" ? $0.lowercased() == name.lowercased() : $0 == name }) else { throw PetError(title + "名称重复：" + name) }
            result[name] = entry.value.stringValue
        }; return result
    }
    func setEnabled(_ enabled: Bool) { add.isEnabled = enabled && entries.count < limit; for entry in entries { for control in entry.row.arrangedSubviews.compactMap({ $0 as? NSControl }) { control.isEnabled = enabled } } }
}
