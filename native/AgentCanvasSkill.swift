import AppKit
import Darwin

struct AgentCanvasSkillSpecification: Codable, Equatable, Sendable {
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

@MainActor final class AgentCanvasSkillWindow: AgentSettingsPageController, NSWindowDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    enum Field: String, Codable, Sendable { case name, trigger, sources, formatting, destination }
    struct Draft: Codable, Sendable {
        var version = 1
        var taskID: String, canvasID: String, sourceHash: String
        var specification: AgentCanvasSkillSpecification, destination: String
        var edited: Bool, status: String, scrollY: Double, focus: Field
        var fieldSelection: AgentTextViewport.Selection?
        var editorPositions: [String: AgentTextViewport]

        static func validateFields(_ raw: Any) throws {
            let fields = try AgentSettingsRecovery.object(raw, keys: ["version", "taskID", "canvasID", "sourceHash", "specification", "destination", "edited", "status", "scrollY", "focus", "fieldSelection", "editorPositions"])
            guard let specification = fields["specification"], let positions = fields["editorPositions"] as? [String: Any] else {
                throw PetError("打包草稿格式无效")
            }
            _ = try AgentSettingsRecovery.object(specification, keys: ["name", "trigger", "sources", "formatting"])
            if let selection = fields["fieldSelection"], !(selection is NSNull) { _ = try AgentSettingsRecovery.object(selection, keys: ["location", "length"]) }
            for position in positions.values { try AgentTextViewport.validateObject(position) }
        }
        func validate(taskID: String, canvasID: String) throws {
            let texts = ["trigger": specification.trigger, "sources": specification.sources, "formatting": specification.formatting]
            let singleLine = focus == .name ? specification.name : destination
            guard version == 1, self.taskID == taskID, self.canvasID == canvasID,
                  sourceHash.count == 64, sourceHash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                  (0...1_000_000_000).contains(scrollY), (Array(texts.values) + [specification.name, destination]).allSatisfy({ $0.utf8.count <= 64_000 && !$0.contains("\0") }),
                  status.utf8.count <= 4096,
                  fieldSelection == nil || ([Field.name, .destination].contains(focus) && fieldSelection?.valid(in: singleLine.utf16.count) == true),
                  editorPositions.allSatisfy({ key, position in
                      guard let text = texts[key] else { return false }
                      return position.valid && position.count == text.utf16.count && position.hash == AgentFiles.hash(Data(text.utf8))
                  }) else { throw PetError("画布打包草稿与原任务、版本或选区不符，原记录已保留") }
        }
    }

    private let canvas: AgentCanvas, taskID: String, id: String
    private var sourceHash: String, proposedHash: String?
    private let name = AgentDialogTextField(), destination = AgentDialogTextField()
    private let trigger = NSTextView(), sources = NSTextView(), formatting = NSTextView()
    private let state = AgentSettingsStatusField("Skill 打包状态"), source = NSTextField(labelWithString: "")
    private let export = AgentDialogButton(title: "打包", target: nil, action: nil)
    private let review = AgentDialogButton(title: "使用当前版本", target: nil, action: nil)
    private let back = AgentDialogButton(title: "返回画布", target: nil, action: nil)
    private var form: NSScrollView!
    private var panel: NSOpenPanel?
    private var edited = false, ended = false, restoring = false
    private var lastFocus: Field = .name, fieldSelection: AgentTextViewport.Selection?
    private var pending: Draft?
    var onExport: ((URL) -> Void)?
    var onCloseForm: (() -> Void)?
    var hasPendingChanges: Bool { edited && !ended }
    var canPreserveForQuit: Bool { !ended && panel == nil }
    private var editors: [(Field, NSTextView)] { [(.trigger, trigger), (.sources, sources), (.formatting, formatting)] }

    init(canvas: AgentCanvas, taskID: String, record: AgentCanvasRecord) {
        self.canvas = canvas; self.taskID = taskID; id = record.id; sourceHash = record.hash
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "打包画布 Skill"; window.minSize = NSSize(width: 440, height: 360); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        name.stringValue = "canvas-" + record.id.prefix(8).lowercased()
        trigger.string = "需要生成与「" + record.title + "」相同结构的画布时使用"
        sources.string = "当前任务中用户提供的实际数据和要求"
        formatting.string = "沿用模板布局、色彩和交互，数值和文案依据实际输入生成"
        for field in [name, destination] { field.outlined = true; field.delegate = self }
        name.setAccessibilityLabel("画布 Skill 名称"); destination.setAccessibilityLabel("画布 Skill 保存目录")
        destination.placeholderString = "选择或输入目录"
        let choose = AgentDialogButton(title: "选择…", target: self, action: #selector(chooseDestination))
        choose.setAccessibilityLabel("选择 Skill 保存目录"); AgentDialogStyle.action(choose)
        let directory = AgentSettingsStyle.labeledField("保存目录", destination)
        let directoryRow = NSStackView(views: [directory, choose]); directoryRow.alignment = .bottom; directoryRow.spacing = 8
        let identity = AgentSettingsStyle.section("", id: "canvas-skill-name", rows: [AgentSettingsStyle.labeledField("名称", name), editorRow("触发要求", trigger)])
        let content = AgentSettingsStyle.section("", id: "canvas-skill-content", rows: [editorRow("数据来源", sources), editorRow("格式约定", formatting), directoryRow])
        form = AgentSettingsStyle.form([identity, content], label: "画布 Skill 配置")
        watchScroll(form)

        source.font = .systemFont(ofSize: 14, weight: .semibold); source.lineBreakMode = .byTruncatingTail
        source.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        source.setAccessibilityLabel("来源画布"); source.stringValue = record.title; source.toolTip = record.title
        for button in [export, review, back] { button.target = self; AgentDialogStyle.action(button, prominent: button === export) }
        back.action = #selector(returnToCanvas); review.action = #selector(useCurrentSource); review.isHidden = true
        export.action = #selector(exportPackage); export.keyEquivalent = "s"; export.keyEquivalentModifierMask = .command
        let actions = NSStackView(views: [back, source, NSView(), review, export]); actions.alignment = .centerY; actions.spacing = 10
        let header = NSStackView(views: [actions, state]); header.orientation = .vertical; header.alignment = .leading; header.spacing = 6
        for row in header.arrangedSubviews { row.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true }
        let surface = AgentThemeView(fill: AgentWorkbenchTheme.surface); window.contentView = surface
        for view in [header, form!] { surface.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: surface.topAnchor, constant: 12), header.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -18), form.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            form.leadingAnchor.constraint(equalTo: header.leadingAnchor), form.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            form.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -10)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged(_:)), name: NSTextView.didChangeSelectionNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func settingsContent(in host: NSWindow, styled: Bool = true) -> NSView? {
        back.isHidden = true
        return super.settingsContent(in: host, styled: true)
    }
    private func editorRow(_ title: String, _ editor: NSTextView) -> NSStackView {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 14)
        editor.setAccessibilityLabel("画布 Skill " + title); editor.font = .systemFont(ofSize: 13); editor.delegate = self
        editor.isRichText = false; editor.allowsUndo = true; editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true; editor.textContainerInset = NSSize(width: 8, height: 6)
        editor.drawsBackground = false; editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false
        let scroll = NSScrollView(); scroll.documentView = editor; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.identifier = .init("form-input"); watchScroll(scroll)
        let field = AgentThemeView(fill: AgentWorkbenchTheme.surface, stroke: AgentWorkbenchTheme.line)
        field.layer?.cornerRadius = 7; field.layer?.borderWidth = 1
        field.addSubview(scroll); scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 1), scroll.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: field.topAnchor, constant: 1), scroll.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: -1),
            field.heightAnchor.constraint(equalToConstant: editor === trigger ? 62 : 82)
        ])
        let row = NSStackView(views: [label, field]); row.orientation = .vertical; row.alignment = .leading; row.spacing = 6
        field.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        return row
    }
    private func watchScroll(_ scroll: NSScrollView) {
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }
    private func text(_ field: NSTextField) -> String { (field.currentEditor() as? NSTextView)?.string ?? field.stringValue }
    private var specification: AgentCanvasSkillSpecification {
        .init(name: text(name), trigger: trigger.string, sources: sources.string, formatting: formatting.string)
    }
    private func rememberFocus() {
        guard let active = presentingWindow?.firstResponder as? NSTextView else { return }
        if let field = editors.first(where: { $0.1 === active }) { lastFocus = field.0; fieldSelection = nil }
        else if active === name.currentEditor() || active === destination.currentEditor() {
            lastFocus = active === name.currentEditor() ? .name : .destination
            let range = active.selectedRange()
            let selection = AgentTextViewport.Selection(location: range.location, length: range.length)
            fieldSelection = selection.valid(in: active.string.utf16.count) ? selection : nil
        }
    }
    func prepareWorkspaceNavigation() -> Bool { guard panel == nil else { return false }; rememberFocus(); return true }
    @objc private func selectionChanged(_ notification: Notification) {
        guard !restoring, let editor = notification.object as? NSTextView, editor.window === presentingWindow, isPageVisible,
              editors.contains(where: { $0.1 === editor }) || editor === name.currentEditor() || editor === destination.currentEditor() else { return }
        rememberFocus(); onSettingsRecoveryChange?()
    }
    @objc private func scrolled(_ notification: Notification) { if !restoring { onSettingsRecoveryChange?() } }
    private func editedField() {
        guard !restoring else { return }; edited = true; rememberFocus()
        if export.isEnabled { state.stringValue = "" }; onSettingsRecoveryChange?()
    }
    func controlTextDidChange(_ notification: Notification) { editedField() }
    func textDidChange(_ notification: Notification) { editedField() }
    func captureDraft() throws -> Draft {
        if let pending { return pending }
        rememberFocus()
        let positions = try Dictionary(uniqueKeysWithValues: editors.map { ($0.0.rawValue, try AgentTextViewport($0.1)) })
        let activeText = text(lastFocus == .name ? name : destination)
        let selection = fieldSelection?.valid(in: activeText.utf16.count) == true ? fieldSelection : nil
        let draft = Draft(taskID: taskID, canvasID: id, sourceHash: sourceHash, specification: specification, destination: text(destination),
            edited: edited, status: state.stringValue, scrollY: form.contentView.bounds.minY, focus: lastFocus, fieldSelection: selection, editorPositions: positions)
        try draft.validate(taskID: taskID, canvasID: id); return draft
    }
    func restoreDraft(_ draft: Draft) throws {
        try draft.validate(taskID: taskID, canvasID: id)
        name.stringValue = draft.specification.name; destination.stringValue = draft.destination
        trigger.string = draft.specification.trigger; sources.string = draft.specification.sources; formatting.string = draft.specification.formatting
        sourceHash = draft.sourceHash; edited = draft.edited; lastFocus = draft.focus; fieldSelection = draft.fieldSelection; pending = draft
        if !draft.status.isEmpty { state.showSaveFailure(PetError(draft.status)) }
    }
    override func settingsDidAppear() { super.settingsDidAppear(); checkSource(); restoreFocus() }
    func windowDidBecomeKey(_ notification: Notification) { if settingsHostWindow == nil { checkSource(); restoreFocus() } }
    private func restoreFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !ended, isPageVisible, let host = presentingWindow else { return }
            restoring = true; defer { restoring = false }
            host.contentView?.layoutSubtreeIfNeeded()
            let field: NSView
            if let editor = editors.first(where: { $0.0 == self.lastFocus })?.1 { field = editor }
            else { field = lastFocus == .destination ? destination : name }
            if host.makeFirstResponder(field), let textField = field as? NSTextField, let fieldSelection,
               fieldSelection.valid(in: text(textField).utf16.count) {
                (textField.currentEditor() as? NSTextView)?.setSelectedRange(fieldSelection.range)
            }
            if let pending {
                for (key, editor) in editors { _ = pending.editorPositions[key.rawValue]?.apply(to: editor, focus: false) }
                form.contentView.scroll(to: NSPoint(x: 0, y: pending.scrollY)); form.reflectScrolledClipView(form.contentView)
                self.pending = nil
            }
        }
    }
    @discardableResult func checkSource() -> AgentCanvasRecord? {
        do {
            let record = try canvas.source(id, taskID: taskID).record
            source.stringValue = record.title; source.toolTip = record.title
            if record.hash != sourceHash {
                proposedHash = record.hash; review.isHidden = false; review.title = "使用当前版本"; export.isEnabled = false
                state.showSaveFailure(PetError("画布已更新至 " + record.hash.prefix(8) + "，原填写内容已保留。"))
            } else {
                if !export.isEnabled { state.stringValue = "" }
                proposedHash = nil; review.isHidden = true; export.isEnabled = true
            }
            return record
        } catch {
            proposedHash = nil; review.isHidden = false; review.title = "重新检查"; export.isEnabled = false
            state.showSaveFailure(error); return nil
        }
    }
    @objc private func useCurrentSource() {
        let reviewed = proposedHash
        guard let current = checkSource(), current.hash == reviewed, current.hash != sourceHash else { return }
        sourceHash = current.hash; edited = true; checkSource(); onSettingsRecoveryChange?()
    }
    @objc private func chooseDestination() {
        guard panel == nil, let host = presentingWindow, !host.hasBlockingDialog else { return }
        rememberFocus()
        let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true
        picker.canCreateDirectories = true; picker.allowsMultipleSelection = false; picker.prompt = "选择"
        panel = picker
        picker.beginSheetModal(for: host) { [weak self, weak picker] response in
            guard let self, self.panel === picker else { return }; self.panel = nil
            guard !ended else { return }
            if response == .OK, let url = picker?.url {
                destination.stringValue = url.path; editedField()
                if lastFocus == .destination { fieldSelection = nil }
            }
            restoreFocus()
        }
    }
    @objc private func returnToCanvas() { window?.performClose(nil) }
    @objc private func exportPackage() {
        guard isPageVisible, panel == nil, !ended, checkSource()?.hash == sourceHash else { return }
        var value = specification; value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let path = (text(destination).trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
            guard path.hasPrefix("/"), !path.contains("\0") else { throw PetError("请选择保存目录或输入绝对路径") }
            let folder = try canvas.exportSkill(id, taskID: taskID, expected: sourceHash, specification: value, parent: URL(fileURLWithPath: path, isDirectory: true))
            edited = false; onExport?(folder); close()
        } catch { state.showSaveFailure(error); onSettingsRecoveryChange?() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard panel == nil else { return false }
        return !hasPendingChanges || AgentUnsavedChanges.discard("放弃 Skill 打包草稿？", owner: presentingWindow)
    }
    override func settingsWillLeave() { finishForm() }
    func windowWillClose(_ notification: Notification) { finishForm() }
    func finishForm() {
        guard !ended else { return }; ended = true
        if let panel { presentingWindow?.endSheet(panel, returnCode: .cancel); self.panel = nil }
        onCloseForm?(); onCloseForm = nil
    }
}
