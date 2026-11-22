import AppKit

extension AgentWorkspaceColor {
    var nsColor: NSColor { NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1) }
}

@MainActor final class AgentWorkspaceEditor: NSViewController, NSTextFieldDelegate {
    enum Exit: Equatable { case returned, archived }

    let original: AgentDirectoryEntry
    private let input = AgentDialogTextField(frame: .zero)
    private let status = AgentSettingsStatusField("工作区保存状态")
    private let scopeNote = NSTextField(wrappingLabelWithString: "文件夹变更用于新任务。")
    private let folderColumn = NSStackView()
    private let save = AgentDialogButton(title: "保存", target: nil, action: nil)
    private let archive: AgentDialogButton
    private var viewport: NSScrollView!
    private var iconButtons: [NSButton] = [], colorButtons: [NSButton] = []
    private var primaryButtons: [NSButton] = []
    private var folders: [String], primary: String, icon: AgentWorkspaceIcon, color: AgentWorkspaceColor
    private let saveWorkspace: (String, AgentWorkspaceIcon, AgentWorkspaceColor, [String], String) throws -> Void
    private let archiveWorkspace: () throws -> Void
    private let onClose: (Exit) -> Void

    init(entry: AgentDirectoryEntry, save: @escaping (String, AgentWorkspaceIcon, AgentWorkspaceColor, [String], String) throws -> Void,
         archive: @escaping () throws -> Void, onClose: @escaping (Exit) -> Void) {
        original = entry; folders = entry.sourceFolders; primary = entry.primary
        icon = entry.icon ?? .folder; color = entry.color ?? .forest
        self.archive = AgentDialogButton(title: "归档" + entry.mode.directoryTitle, target: nil, action: nil)
        saveWorkspace = save; archiveWorkspace = archive; self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
        title = entry.title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var isPageVisible: Bool { view.window?.isVisible == true && !view.isHiddenOrHasHiddenAncestor }
    private var proposedName: String { input.stringValue }
    private var changed: Bool {
        proposedName != original.title || icon != (original.icon ?? .folder) || color != (original.color ?? .forest)
            || folders != original.sourceFolders || primary != original.primary
    }

    override func loadView() {
        let root = AgentWorkspacePageView(fill: AgentWorkbenchTheme.surface)
        root.identifier = .init("workspace-editor-page")
        view = root

        let back = AgentWorkbenchButton()
        AgentWorkbenchTheme.toolbar(back, title: "返回", symbol: "chevron.left")
        back.target = self; back.action = #selector(returnToWorkspace)
        back.keyEquivalent = "\u{1b}"; back.keyEquivalentModifierMask = []
        let heading = NSTextField(labelWithString: original.title)
        heading.font = .systemFont(ofSize: 20, weight: .semibold); heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [back, heading, NSView()]); header.alignment = .centerY; header.spacing = 10
        header.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true

        input.stringValue = original.title; input.font = .systemFont(ofSize: 13); input.outlined = true
        input.identifier = .init("workspace-editor-name"); input.setAccessibilityLabel(original.mode.directoryTitle + "名称")
        input.delegate = self; input.heightAnchor.constraint(equalToConstant: 30).isActive = true
        input.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iconButtons = AgentWorkspaceIcon.allCases.map { value in
            paletteButton(value.rawValue, label: "图标：" + value.title,
                          image: NSImage(systemSymbolName: value.rawValue, accessibilityDescription: nil), action: #selector(selectIcon(_:)))
        }
        colorButtons = AgentWorkspaceColor.allCases.map { value in
            let swatch = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { bounds in
                value.nsColor.setFill(); NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill(); return true
            }
            return paletteButton(value.rawValue, label: "颜色：" + value.title, image: swatch, action: #selector(selectColor(_:)))
        }
        let details = AgentSettingsStyle.section("基本信息", id: "workspace-appearance", rows: [
            AgentSettingsStyle.formRow("名称", input, trailing: false, showsIcon: false),
            AgentSettingsStyle.formRow("图标", palette(iconButtons), trailing: false, showsIcon: false),
            AgentSettingsStyle.formRow("颜色", palette(colorButtons), trailing: false, showsIcon: false)
        ])

        let add = AgentDialogButton(title: "添加文件夹", target: self, action: #selector(addFolders))
        add.setAccessibilityLabel("添加源文件夹"); AgentDialogStyle.action(add)
        let folderLabel = NSTextField(labelWithString: "源文件夹")
        folderLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let folderHeader = NSStackView(views: [folderLabel, NSView(), add]); folderHeader.alignment = .centerY
        folderColumn.orientation = .vertical; folderColumn.alignment = .leading; folderColumn.spacing = 1
        folderColumn.setAccessibilityLabel("源文件夹列表")
        scopeNote.font = .systemFont(ofSize: 11); scopeNote.textColor = AgentWorkbenchTheme.secondaryText
        scopeNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let sources = AgentSettingsStyle.section("", id: "workspace-folders", rows: [folderHeader, folderColumn, scopeNote], separatesRows: false)
        viewport = AgentSettingsStyle.form([details, sources], label: "工作区设置")
        viewport.setContentHuggingPriority(.defaultLow, for: .vertical)
        viewport.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true

        archive.target = self; archive.action = #selector(archiveEntry); archive.hasDestructiveAction = true
        let cancel = AgentDialogButton(title: "取消", target: self, action: #selector(cancelEditing))
        save.target = self; save.action = #selector(submit)
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        AgentDialogStyle.action(archive); AgentDialogStyle.action(cancel); AgentSettingsStyle.primaryAction(save)
        let actions = NSStackView(views: [archive, NSView(), cancel, save]); actions.alignment = .centerY; actions.spacing = 8
        let column = NSStackView(views: [header, viewport, status, actions])
        column.orientation = .vertical; column.alignment = .leading; column.spacing = 12
        root.addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        for item in column.arrangedSubviews { item.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        let preferredWidth = column.widthAnchor.constraint(equalToConstant: 824)
        preferredWidth.priority = .init(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 1)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: root.centerXAnchor), preferredWidth, column.widthAnchor.constraint(lessThanOrEqualToConstant: 824),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 28),
            column.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -28),
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        ])
        root.onResize = { [weak self, weak root] in
            guard let self, let root else { return }
            let width = max(0, min(824, root.bounds.width - 56))
            status.preferredMaxLayoutWidth = width
            scopeNote.preferredMaxLayoutWidth = max(0, width - 32)
        }
        renderFolders()
        refreshSelection()
    }

    private func paletteButton(_ id: String, label: String, image: NSImage?, action: Selector) -> NSButton {
        let button = AgentDialogButton()
        button.palette = true; button.title = ""; button.image = image; button.imagePosition = .imageOnly
        button.setButtonType(.toggle); button.identifier = .init(id); button.setAccessibilityLabel(label); button.toolTip = label
        button.target = self; button.action = action
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }
    private func palette(_ buttons: [NSButton]) -> NSStackView {
        let group = NSStackView(); group.orientation = .vertical; group.alignment = .leading; group.spacing = 4
        for start in stride(from: 0, to: buttons.count, by: 8) {
            let row = NSStackView(views: Array(buttons[start..<min(start + 8, buttons.count)]))
            row.spacing = 4; row.alignment = .centerY
            group.addArrangedSubview(row)
        }
        return group
    }

    private func renderFolders() {
        for row in folderColumn.arrangedSubviews { folderColumn.removeArrangedSubview(row); row.removeFromSuperview() }
        primaryButtons.removeAll()
        let urls = folders.map { URL(fileURLWithPath: $0) }
        let names = urls.map(\.lastPathComponent)
        let duplicates = Dictionary(grouping: names, by: { $0 })
        let labels = zip(urls, names).map { url, name in
            (duplicates[name]?.count ?? 0) > 1 ? url.deletingLastPathComponent().lastPathComponent + "/" + name : name
        }
        let matchingLabels = Dictionary(grouping: labels, by: { $0 })
        for (index, path) in folders.enumerated() {
            let name = labels[index]
            let label = NSTextField(labelWithString: (matchingLabels[name]?.count ?? 0) > 1 ? path : name)
            label.font = .systemFont(ofSize: 13); label.lineBreakMode = .byTruncatingMiddle; label.toolTip = path
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let glyph = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)!)
            glyph.contentTintColor = AgentWorkbenchTheme.secondaryText; glyph.widthAnchor.constraint(equalToConstant: 16).isActive = true
            let main = AgentDialogButton(title: "", target: self, action: #selector(selectPrimary(_:)))
            AgentDialogStyle.action(main); main.tag = index; primaryButtons.append(main)
            let remove = AgentWorkbenchButton()
            AgentWorkbenchTheme.toolbar(remove, title: "移除源文件夹：" + path, symbol: "xmark")
            remove.tag = index; remove.target = self; remove.action = #selector(removeFolder(_:)); remove.isEnabled = folders.count > 1
            let row = NSStackView(views: [glyph, label, NSView(), main, remove])
            row.spacing = 8; row.alignment = .centerY
            folderColumn.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: folderColumn.widthAnchor).isActive = true
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
            if index + 1 < folders.count {
                let divider = AgentSettingsStyle.divider()
                folderColumn.addArrangedSubview(divider); divider.widthAnchor.constraint(equalTo: folderColumn.widthAnchor).isActive = true
            }
        }
    }
    private func refreshSelection() {
        for (path, button) in zip(folders, primaryButtons) {
            let selected = path == primary
            button.title = selected ? "主要" : "设为主要"; button.isEnabled = !selected
            button.setAccessibilityLabel((selected ? "主文件夹：" : "设为主文件夹：") + path)
        }
        for button in iconButtons {
            button.state = button.identifier?.rawValue == icon.rawValue ? .on : .off
            button.contentTintColor = button.state == .on ? color.nsColor : AgentWorkbenchTheme.secondaryText
        }
        for button in colorButtons { button.state = button.identifier?.rawValue == color.rawValue ? .on : .off }
        scopeNote.isHidden = folders == original.sourceFolders && primary == original.primary
        archive.isEnabled = !changed
    }

    func focusName(selectAll: Bool = false) {
        guard let window = view.window, !window.hasBlockingDialog, window.makeFirstResponder(input) else { return }
        if selectAll { (input.currentEditor() as? NSTextView)?.selectAll(nil) }
    }
    func prepareToLeave() -> Bool {
        guard let window = view.window, !window.hasBlockingDialog,
              (input.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return false }
        return !changed || AgentUnsavedChanges.discard("放弃" + original.mode.directoryTitle + "更改？", owner: window)
    }

    @objc private func returnToWorkspace() { if prepareToLeave() { onClose(.returned) } }
    @objc private func cancelEditing() {
        guard view.window?.hasBlockingDialog != true else { return }
        onClose(.returned)
    }
    @objc private func selectIcon(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let value = AgentWorkspaceIcon(rawValue: id) else { return }
        icon = value; refreshSelection()
    }
    @objc private func selectColor(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let value = AgentWorkspaceColor(rawValue: id) else { return }
        color = value; refreshSelection()
    }
    @objc private func selectPrimary(_ sender: NSButton) {
        guard folders.indices.contains(sender.tag) else { return }
        primary = folders[sender.tag]; refreshSelection()
    }
    @objc private func removeFolder(_ sender: NSButton) {
        guard folders.count > 1, folders.indices.contains(sender.tag) else { return }
        let removed = folders.remove(at: sender.tag)
        if removed == primary { primary = folders[0] }
        renderFolders(); refreshSelection()
    }
    @objc private func addFolders() {
        guard let window = view.window, !window.hasBlockingDialog else { return }
        let picker = NSOpenPanel()
        picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.allowsMultipleSelection = true
        picker.prompt = "添加"; picker.directoryURL = URL(fileURLWithPath: primary)
        picker.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK else { return }
            do {
                let paths = folders + picker.urls.map { $0.resolvingSymlinksInPath().path }
                folders = try AgentWorkspaceScope.validateFolders(paths, primary: primary)
                status.stringValue = ""; renderFolders(); refreshSelection()
            } catch { status.showSaveFailure(error) }
        }
    }
    @objc private func submit() {
        guard view.window?.hasBlockingDialog != true, (input.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        do { try saveWorkspace(proposedName, icon, color, folders, primary); onClose(.returned) }
        catch { status.showSaveFailure(error) }
    }
    @objc private func archiveEntry() {
        guard !changed, view.window?.hasBlockingDialog != true else { return }
        do { try archiveWorkspace(); onClose(.archived) }
        catch { status.showSaveFailure(error) }
    }
    func controlTextDidChange(_ notification: Notification) { archive.isEnabled = !changed }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) { submit(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { returnToWorkspace(); return true }
        return false
    }
    func checkState() -> [String: Any] {
        guard ["--manual-ui", "--workspace-editor-check", "--name-editor-check"].contains(where: CommandLine.arguments.contains) else { return [:] }
        view.layoutSubtreeIfNeeded()
        return ["visible": isPageVisible, "title": original.title, "inWindow": view.window != nil, "nativeSheet": view.window?.attachedSheet != nil,
                "pageSize": [view.bounds.width, view.bounds.height], "value": proposedName, "error": status.stringValue,
                "inputFocused": input.currentEditor().map { view.window?.firstResponder === $0 } ?? false, "inputWidth": input.bounds.width,
                "ambiguousLayout": input.hasAmbiguousLayout || viewport.hasAmbiguousLayout, "folders": folders, "primary": primary,
                "icon": icon.rawValue, "color": color.rawValue, "formHeight": viewport.documentView?.bounds.height ?? 0,
                "viewportHeight": viewport.contentSize.height, "documentFlipped": viewport.documentView?.isFlipped == true]
    }
}
