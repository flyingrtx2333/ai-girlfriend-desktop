import AppKit

@MainActor final class AgentMemorySettingsPage: AgentSettingsPageController {
    private let store: AgentStore, taskID: String, workspace: String?
    private let service: AgentGeneralSettings
    private let global = NSSwitch(), project = NSSwitch()
    private let state = AgentSettingsStatusField("记忆保存状态")
    private let feedback = NSStackView()
    private let reload = NSButton(title: "重新载入", target: nil, action: nil)
    private var states: [String: NSTextField] = [:], buttons: [NSButton] = []
    private let projectRows = NSStackView()
    private var projectSection: NSView!
    private var projectSources: [AgentMemoryProjectSource] = [], projectButtons: [NSButton] = [], projectStates: [NSTextField] = []
    private var saveFailed = false
    private weak var lastOpened: NSButton?
    override var minimumSettingsContentHeight: CGFloat { 220 }
    override var usesInternalScrolling: Bool { true }

    init(store: AgentStore, taskID: String, workspace: String?, service: AgentGeneralSettings) {
        self.store = store; self.taskID = taskID; self.workspace = workspace; self.service = service
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "记忆与指令"; window.minSize = NSSize(width: 650, height: 450); window.isReleasedWhenClosed = false
        super.init(window: window)
        for (index, control) in [global, project].enumerated() {
            control.tag = index; control.target = self; control.action = #selector(changeMemory)
            control.setAccessibilityLabel(index == 0 ? "全局记忆" : "项目记忆")
            control.identifier = .init(index == 0 ? "memory-global-enabled" : "memory-project-enabled")
            control.toolTip = "关闭后不自动加入上下文，记忆工具停止读取和写入；已有内容仍可手动管理。"
        }
        reload.target = self; reload.action = #selector(reloadSettings); reload.bezelStyle = .rounded
        [state, NSView(), reload].forEach { feedback.addArrangedSubview($0) }; feedback.spacing = 8
        let behavior = AgentSettingsStyle.section("记忆行为", id: "memory-behavior", rows: [AgentSettingsStyle.formRow("全局记忆", global, trailing: true), AgentSettingsStyle.formRow("项目记忆", project, trailing: true)])
        func source(_ scope: AgentMemoryScope) -> NSView {
            let title = NSTextField(labelWithString: scope.title); title.font = .systemFont(ofSize: 13)
            let status = NSTextField(labelWithString: ""); status.font = .systemFont(ofSize: 11); status.textColor = AgentWorkbenchTheme.secondaryText
            status.lineBreakMode = .byTruncatingMiddle; status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let labels = NSStackView(views: [title, status]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 5
            let button = NSButton(title: "管理", target: self, action: #selector(openMemory)); button.bezelStyle = .rounded
            button.tag = AgentMemoryScope.allCases.firstIndex(of: scope)!; button.identifier = .init("memory-manage-" + scope.rawValue); button.setAccessibilityLabel("管理" + scope.title)
            let row = NSStackView(views: [labels, NSView(), button]); row.alignment = .centerY; row.spacing = 12
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
            states[scope.rawValue] = status; buttons.append(button); return row
        }
        let memory = AgentSettingsStyle.section("记忆内容", id: "memory-content", rows: [.global, .project].map(source))
        projectRows.orientation = .vertical; projectRows.alignment = .leading; projectRows.spacing = 16
        projectSection = AgentSettingsStyle.section("其他项目记忆", id: "memory-projects", rows: [projectRows])
        let instructions = AgentSettingsStyle.section("指令", id: "memory-instructions", rows: [.userInstructions, .instructions, .localInstructions, .effectiveInstructions].map(source))
        let summary = AgentSettingsStyle.section("当前任务", id: "memory-summary", rows: [source(.summary)])
        let content = AgentSettingsStyle.form([behavior, feedback, memory, projectSection, instructions, summary], label: "记忆与指令设置")
        window.contentView = content; update()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func settingsDidAppear() {
        service.reload(); update()
        if isPageVisible, let lastOpened, lastOpened.window === presentingWindow, lastOpened.isEnabled { presentingWindow?.makeFirstResponder(lastOpened) }
    }
    private func update() {
        global.state = service.settings.globalMemory ? .on : .off; project.state = service.settings.projectMemory ? .on : .off
        global.isEnabled = service.error == nil; project.isEnabled = service.error == nil
        if let error = service.error { state.stringValue = error; saveFailed = true }
        feedback.isHidden = state.stringValue.isEmpty
        reload.isHidden = !saveFailed
        for button in buttons {
            let scope = AgentMemoryScope.allCases[button.tag]
            do {
                let value = try AgentMemory.snapshot(scope, store: store, taskID: taskID, workspace: workspace)
                let text = value.content.trimmingCharacters(in: .whitespacesAndNewlines)
                states[scope.rawValue]?.stringValue = text.isEmpty ? "暂无内容" : "\(text.count) 字"
                states[scope.rawValue]?.toolTip = value.location; button.isEnabled = true
            } catch {
                states[scope.rawValue]?.stringValue = error.localizedDescription; states[scope.rawValue]?.toolTip = error.localizedDescription; button.isEnabled = false
            }
        }
        updateProjects()
    }
    private func updateProjects() {
        let current = workspace ?? store.task(taskID)?.workspace
        let currentRoot = current.flatMap { try? AgentFiles(workspace: $0).root.path } ?? current
        let sources = AgentMemory.projects(store: store, preferredTaskID: taskID).filter {
            ((try? AgentFiles(workspace: $0.workspace).root.path) ?? $0.workspace) != currentRoot
        }
        if sources != projectSources {
            projectRows.arrangedSubviews.forEach { projectRows.removeArrangedSubview($0); $0.removeFromSuperview() }
            projectSources = sources; projectButtons = []; projectStates = []
            for (index, source) in sources.enumerated() {
                let title = NSTextField(labelWithString: source.title); title.font = .systemFont(ofSize: 13); title.lineBreakMode = .byTruncatingMiddle
                title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let status = NSTextField(labelWithString: ""); status.font = .systemFont(ofSize: 11); status.textColor = AgentWorkbenchTheme.secondaryText
                status.lineBreakMode = .byTruncatingMiddle; status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let labels = NSStackView(views: [title, status]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 5
                let button = NSButton(title: "管理", target: self, action: #selector(openProjectMemory)); button.bezelStyle = .rounded; button.tag = index
                button.identifier = .init("memory-project-" + AgentFiles.hash(Data(source.workspace.utf8))); button.setAccessibilityLabel("管理" + source.title + "项目记忆")
                let row = NSStackView(views: [labels, NSView(), button]); row.alignment = .centerY; row.spacing = 12
                row.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
                projectRows.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: projectRows.widthAnchor).isActive = true
                projectButtons.append(button); projectStates.append(status)
            }
        }
        projectSection.isHidden = sources.isEmpty
        for (index, source) in sources.enumerated() {
            do {
                let value = try AgentMemory.snapshot(.project, store: store, taskID: source.taskID, workspace: source.workspace)
                let count = value.content.trimmingCharacters(in: .whitespacesAndNewlines).count
                projectStates[index].stringValue = (count == 0 ? "暂无内容" : "\(count) 字") + " · " + source.workspace
                projectStates[index].toolTip = source.workspace; projectButtons[index].isEnabled = true
            } catch {
                projectStates[index].stringValue = error.localizedDescription; projectStates[index].toolTip = source.workspace + "\n" + error.localizedDescription
                projectButtons[index].isEnabled = false
            }
        }
    }
    @objc private func changeMemory(_ sender: NSSwitch) {
        var value = service.settings
        if sender === global { value.globalMemory = sender.state == .on } else { value.projectMemory = sender.state == .on }
        do { try service.save(value); saveFailed = false; state.stringValue = "已保存" }
        catch { saveFailed = true; state.stringValue = error.localizedDescription }
        update()
    }
    @objc private func reloadSettings() {
        service.reload(); saveFailed = false; state.stringValue = ""; update()
    }
    @objc private func openMemory(_ sender: NSButton) {
        guard sender.isEnabled, AgentMemoryScope.allCases.indices.contains(sender.tag) else { return }
        lastOpened = sender
        let scope = AgentMemoryScope.allCases[sender.tag]
        let editor = AgentRecordWindow(store: store, taskID: taskID, section: 5, memoryOnly: true, memoryWorkspace: workspace)
        editor.window?.title = scope.title; editor.selectItem(section: 5, value: scope.rawValue)
        presentSettingsChild(editor)
    }
    @objc private func openProjectMemory(_ sender: NSButton) {
        guard sender.isEnabled, projectButtons.contains(sender), projectSources.indices.contains(sender.tag) else { return }
        let source = projectSources[sender.tag]
        do { _ = try AgentMemory.snapshot(.project, store: store, taskID: source.taskID, workspace: source.workspace) }
        catch { updateProjects(); return }
        lastOpened = sender
        let editor = AgentRecordWindow(store: store, taskID: source.taskID, section: 5, memoryOnly: true, memoryWorkspace: source.workspace)
        editor.window?.title = source.title + " · 项目记忆"; editor.selectItem(section: 5, value: AgentMemoryScope.project.rawValue)
        presentSettingsChild(editor)
    }
}
