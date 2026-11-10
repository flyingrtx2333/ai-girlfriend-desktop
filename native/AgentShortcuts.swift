import AppKit

enum AgentShortcutCommand: String, CaseIterable {
    case settings, newTask, searchTasks, previousTask, nextTask, taskInspector, newWindow, planMode, switchTask, leftSidebar, findInTask
    var title: String {
        switch self {
        case .settings: return "设置"
        case .newTask: return "新的任务"
        case .searchTasks: return "搜索任务"
        case .previousTask: return "上一个任务"
        case .nextTask: return "下一个任务"
        case .taskInspector: return "任务记录"
        case .newWindow: return "在新窗口打开任务"
        case .planMode: return "切换计划模式"
        case .switchTask: return "切换任务"
        case .leftSidebar: return "左侧栏"
        case .findInTask: return "当前任务查找"
        }
    }
    var defaultBinding: AgentShortcutBinding {
        switch self {
        case .settings: return .init(",", .command)
        case .newTask: return .init("n", .command)
        case .searchTasks: return .init("k", .command)
        case .previousTask: return .init("[", .command)
        case .nextTask: return .init("]", .command)
        case .taskInspector: return .init("b", [.command, .shift])
        case .newWindow: return .init("n", [.command, .shift])
        case .planMode: return .init("\t", .shift)
        case .switchTask: return .init("g", .command)
        case .leftSidebar: return .init("b", .command)
        case .findInTask: return .init("f", .command)
        }
    }
}

struct AgentShortcutBinding: Codable, Equatable, Hashable {
    var key: String
    var modifiers: UInt
    init(_ key: String, _ flags: NSEvent.ModifierFlags) { self.key = key; modifiers = flags.rawValue }
    static let cleared = Self("", [])
    var flags: NSEvent.ModifierFlags { .init(rawValue: modifiers) }
    var display: String {
        guard !key.isEmpty else { return "未设置" }
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + (key == "\t" ? "⇥" : key.uppercased())
    }
    static func recorded(_ event: NSEvent) -> Self {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        return .init(event.keyCode == 48 ? "\t" : (event.characters(byApplyingModifiers: []) ?? "").lowercased(), flags)
    }
    func matches(_ event: NSEvent) -> Bool { self != .cleared && Self.recorded(event) == self }
}

@MainActor final class AgentShortcuts {
    private struct Document: Codable { var version = 3; var bindings: [String: AgentShortcutBinding] }
    let directory: URL
    private(set) var error: String?
    private(set) var overrides: [String: AgentShortcutBinding] = [:]
    private var revision: String?
    var onChange: (() -> Void)?
    init(directory: URL) { self.directory = directory; reload() }
    func binding(_ command: AgentShortcutCommand) -> AgentShortcutBinding { overrides[command.rawValue] ?? command.defaultBinding }
    func reload() {
        do {
            let files = try AgentFiles(workspace: directory.path), url = try files.literalURL("shortcuts.json"), entry = try files.entryMetadata(url)
            guard try files.resolve("shortcuts.json") == url, ["missing", "file"].contains(entry.kind) else { throw PetError("快捷键配置必须是普通文件") }
            if entry.kind == "missing" { overrides = [:]; revision = nil }
            else {
                let data = try files.readData(url, maximum: 32_768)
                guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(raw.keys) == ["version", "bindings"],
                      let bindings = raw["bindings"] as? [String: Any], bindings.values.allSatisfy({ ($0 as? [String: Any]).map { Set($0.keys) == ["key", "modifiers"] } == true }) else { throw PetError("快捷键配置包含不支持的字段") }
                let value = try JSONDecoder().decode(Document.self, from: data)
                guard [1, 2, 3].contains(value.version), value.bindings.keys.allSatisfy({ AgentShortcutCommand(rawValue: $0) != nil }) else { throw PetError("快捷键配置版本或操作无效") }
                var effective = value.bindings
                if value.version < 3 {
                    let added: [AgentShortcutCommand] = (value.version == 1 ? [.switchTask, .leftSidebar] : []) + [.findInTask]
                    guard added.allSatisfy({ effective[$0.rawValue] == nil }) else { throw PetError("旧版快捷键配置包含新版操作") }
                    let used = Set(AgentShortcutCommand.allCases.filter { !added.contains($0) }.map { effective[$0.rawValue] ?? $0.defaultBinding })
                    // Reading never rewrites a user's file. Keep older custom bindings;
                    // colliding new defaults remain cleared until explicitly configured.
                    for command in added where used.contains(command.defaultBinding) { effective[command.rawValue] = .cleared }
                }
                try validate(effective); overrides = effective; revision = AgentFiles.hash(data)
            }
            error = nil
        } catch { self.error = "快捷键配置未载入：" + error.localizedDescription }
        onChange?()
    }
    private func validate(_ values: [String: AgentShortcutBinding]) throws {
        var used: [AgentShortcutBinding: AgentShortcutCommand] = [:]
        let allowed: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let reserved = Set("acvxzswmqh".map { AgentShortcutBinding(String($0), .command) } + [AgentShortcutBinding("z", [.command, .shift]), .init("s", [.command, .shift]), .init("w", [.command, .shift]), .init("q", [.command, .control]), .init("q", [.command, .shift]), .init("h", [.command, .option]), .init("m", [.command, .option])])
        for command in AgentShortcutCommand.allCases {
            let value = values[command.rawValue] ?? command.defaultBinding
            if value == .cleared { continue }
            guard value.modifiers & ~allowed.rawValue == 0, value.key.count == 1,
                  "abcdefghijklmnopqrstuvwxyz0123456789,./;[]\\-='\t".contains(value.key),
                  value.flags.contains(.command) || command == .planMode && value == .init("\t", .shift) else { throw PetError("请使用 ⌘ 加字母、数字或常用标点；计划模式也可使用 ⇧⇥") }
            guard value.key != "\t" || command == .planMode && value == .init("\t", .shift), !reserved.contains(value) else { throw PetError(value.display + "用于文本编辑或系统操作，请换一个组合") }
            if let previous = used[value] { throw PetError(value.display + "在“" + previous.title + "”和“" + command.title + "”中重复") }
            used[value] = command
        }
    }
    func set(_ value: AgentShortcutBinding?, for command: AgentShortcutCommand) throws {
        var next = overrides
        next[command.rawValue] = value == command.defaultBinding ? nil : value
        try save(next)
    }
    func reset() throws { try save([:]) }
    private func save(_ next: [String: AgentShortcutBinding]) throws {
        guard error == nil else { throw PetError(error! + "；请重新载入") }
        try validate(next)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(bindings: next))
        let write = try AgentKnowledgeFileWrite(files: AgentFiles(workspace: directory.path), path: "shortcuts.json", data: data, expectedHash: revision, missing: revision == nil, permissions: 0o600, label: "快捷键配置")
        try write.requireCurrent(); try write.files.writeData(data, to: write.url, permissions: 0o600, expectedTarget: write.signature)
        overrides = next; revision = AgentFiles.hash(data); onChange?()
    }
}

@MainActor extension AppDelegate {
    func setupShortcutMenu(_ main: NSMenu, app: NSMenu) {
        func item(_ command: AgentShortcutCommand) -> NSMenuItem {
            let value = NSMenuItem(title: command.title, action: #selector(performApplicationShortcut(_:)), keyEquivalent: "")
            value.target = self; value.representedObject = command.rawValue; shortcutMenuItems[command] = value
            let binding = shortcuts.binding(command); value.keyEquivalent = binding.key; value.keyEquivalentModifierMask = binding.flags
            return value
        }
        app.insertItem(item(.settings), at: 0)
        let tasks = NSMenu(title: "任务"), entry = NSMenuItem(title: "任务", action: nil, keyEquivalent: ""); entry.submenu = tasks
        for command in AgentShortcutCommand.allCases where command != .settings && command != .planMode { tasks.addItem(item(command)) }
        main.addItem(entry)
    }
    func refreshApplicationShortcuts() {
        for (command, item) in shortcutMenuItems { let value = shortcuts.binding(command); item.keyEquivalent = value.key; item.keyEquivalentModifierMask = value.flags }
        for window in taskControls { window.refreshShortcutControls() }
    }
    @objc func performApplicationShortcut(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = AgentShortcutCommand(rawValue: raw), validateMenuItem(sender) else { return }
        if command == .settings { openSettings() }
        else { (NSApp.keyWindow?.windowController as? ControlWindow)?.performShortcut(command) }
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(performApplicationShortcut(_:)), let raw = menuItem.representedObject as? String, let command = AgentShortcutCommand(rawValue: raw) else { return true }
        guard NSApp.modalWindow == nil, NSApp.keyWindow?.attachedSheet == nil, NSApp.keyWindow?.sheetParent == nil else { return false }
        if command == .settings { return true }
        return (NSApp.keyWindow?.windowController as? ControlWindow)?.canPerformShortcut(command) == true
    }
}
