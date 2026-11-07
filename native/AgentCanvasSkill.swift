import AppKit
import Darwin

struct AgentCanvasSkillSpecification {
    var name: String
    var trigger: String
    var sources: String
    var formatting: String
    @MainActor func validate() throws {
        guard AgentExtensions.validName(name), !name.contains(":"), name.count <= 64 else { throw PetError("Skill 名称使用64字以内的文字、数字、连字符或下划线") }
        for (title, value, maximum) in [("触发要求", trigger, 500), ("数据来源", sources, 4000), ("格式约定", formatting, 4000)] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= maximum, !value.contains("\0") else { throw PetError(title + "不能为空或超过长度上限") }
        }
    }
}

@MainActor extension AgentCanvas {
    func skillResources(_ id: String, taskID: String, expected: String, specification: AgentCanvasSkillSpecification) throws -> [String: Data] {
        try specification.validate(); let value = try source(id, taskID: taskID)
        guard value.record.hash == expected else { throw PetError("画布已更新，请重新打包当前版本") }
        let description = specification.trigger.components(separatedBy: .newlines).joined(separator: " ")
        let text = """
        ---
        name: \(specification.name)
        description: >-
          \(description)
        ---

        # 画布工作流

        ## 数据来源

        \(specification.sources)

        ## 布局与交互

        1. 先读取当前任务要求与上述实际输入。缺少数据时说明缺失，等待用户提供。
        2. 通过 read_skill_resource 读取本 Skill 的 references/template.canvas.tsx，作为布局、图表与交互参考。模板中的数值、文案和来源是旧画布内容，不能作为当前数据；不要执行模板中的数据获取代码。
        3. 按当前实际数据重新生成 .canvas.tsx，使用 canvas_create 或 canvas_edit 保存到当前任务。后续修订先 canvas_read 核对实际哈希，再修改同一画布。
        4. 使用 canvas_inspect 核对渲染数值与输入，并用 canvas_screenshot 查看布局；需要点击交互的验收由实际界面完成，不能把源码推断写成已点击验收。

        ## 格式约定

        \(specification.formatting)

        所有文件读取、命令、联网及保存仍遵循当前任务范围和审批。该 Skill 不提供额外权限，不执行原画布中的脚本或外部请求，不复制旧任务历史、附件、Token 或机器路径。

        模板源码版本：\(expected)
        """
        _ = try AgentExtensionDocument(text)
        return ["SKILL.md": Data(text.utf8), "references/template.canvas.tsx": Data(value.code.utf8)]
    }
    func exportSkill(_ id: String, taskID: String, expected: String, specification: AgentCanvasSkillSpecification, parent: URL) throws -> URL {
        let resources = try skillResources(id, taskID: taskID, expected: expected, specification: specification)
        let files = try AgentFiles(workspace: parent.path), destination = try files.literalURL(specification.name)
        guard try files.entryMetadata(destination).kind == "missing" else { throw PetError("同名 Skill 文件夹已存在，未覆盖") }
        let temporary = try files.literalURL(".canvas-skill-" + UUID().uuidString), (parentFD, temporaryName) = try files.parentDescriptor(temporary, create: false)
        defer { Darwin.close(parentFD) }
        guard mkdirat(parentFD, temporaryName, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var published = false; defer { if !published { try? FileManager.default.removeItem(at: temporary) } }
        let staged = try AgentFiles(workspace: temporary.path)
        for name in resources.keys.sorted() { try staged.writeData(resources[name]!, to: staged.literalURL(name), permissions: 0o600) }
        guard try source(id, taskID: taskID).record.hash == expected else { throw PetError("画布在打包期间更新，请重试") }
        guard renameatx_np(parentFD, temporaryName, parentFD, specification.name, UInt32(RENAME_EXCL)) == 0 else { throw PetError("Skill 未发布，目标可能已存在：" + String(cString: strerror(errno))) }
        published = true
        return destination
    }
}

@MainActor final class AgentCanvasSkillWindow: NSWindowController {
    private let canvas: AgentCanvas, taskID: String, id: String, sourceHash: String
    private let name = NSTextField(), trigger = NSTextField(), sources = NSTextField(), formatting = NSTextField(), state = NSTextField(labelWithString: "")
    init(canvas: AgentCanvas, taskID: String, record: AgentCanvasRecord) {
        self.canvas = canvas; self.taskID = taskID; id = record.id; sourceHash = record.hash
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "打包画布 Skill"; window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua); window.center()
        super.init(window: window); let content = NSView(); window.contentView = content
        name.stringValue = "canvas-" + record.id.prefix(8).lowercased(); trigger.stringValue = "需要生成与「" + record.title + "」相同结构的画布时使用"
        sources.stringValue = "当前任务中用户提供的实际数据和要求"; formatting.stringValue = "沿用模板布局、色彩和交互；数值和文案依据当前实际输入生成"
        let form = NSStackView(); form.orientation = .vertical; form.alignment = .leading; form.spacing = 14
        for (title, field) in [("名称", name), ("触发要求", trigger), ("数据来源", sources), ("格式约定", formatting)] {
            let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 12, weight: .medium); label.widthAnchor.constraint(equalToConstant: 64).isActive = true
            field.font = .systemFont(ofSize: 12); field.setAccessibilityLabel("画布 Skill " + title)
            let row = NSStackView(views: [label, field]); row.spacing = 12; form.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        }
        state.font = .systemFont(ofSize: 11); state.textColor = .secondaryLabelColor; state.lineBreakMode = .byTruncatingTail
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelPackage)), export = NSButton(title: "打包…", target: self, action: #selector(exportPackage)); export.keyEquivalent = "\r"
        let actions = NSStackView(views: [state, NSView(), cancel, export]); actions.spacing = 8
        for view in [form, actions] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([form.topAnchor.constraint(equalTo: content.topAnchor, constant: 24), form.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), form.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), actions.leadingAnchor.constraint(equalTo: form.leadingAnchor), actions.trailingAnchor.constraint(equalTo: form.trailingAnchor), actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func cancelPackage() { close() }
    @objc private func exportPackage() {
        let specification = AgentCanvasSkillSpecification(name: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), trigger: trigger.stringValue, sources: sources.stringValue, formatting: formatting.stringValue)
        do {
            _ = try canvas.skillResources(id, taskID: taskID, expected: sourceHash, specification: specification)
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.canCreateDirectories = true; panel.prompt = "打包"; panel.message = "选择 Skill 保存位置"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let folder = try canvas.exportSkill(id, taskID: taskID, expected: sourceHash, specification: specification, parent: url)
            state.stringValue = "已打包 " + folder.lastPathComponent
        } catch { state.stringValue = error.localizedDescription }
    }
}
