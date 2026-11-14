import AppKit

extension AgentWorkspaceColor {
    var nsColor:NSColor { NSColor(srgbRed:CGFloat((hex >> 16) & 255)/255,green:CGFloat((hex >> 8) & 255)/255,blue:CGFloat(hex & 255)/255,alpha:1) }
}

@MainActor private final class AgentWorkspaceEditorDocument: NSView {
    override var isFlipped:Bool { true }
}

@MainActor final class AgentWorkspaceEditor: NSWindowController, NSTextFieldDelegate {
    let original:AgentDirectoryEntry
    private let input = NSTextField(), status = NSTextField(wrappingLabelWithString:""), rangeNote = NSTextField(wrappingLabelWithString:"文件夹变更用于新任务。")
    private let folderColumn = NSStackView(), form = NSStackView(), folderScroll = NSScrollView(), viewport = NSScrollView()
    private let folderDocument = AgentWorkspaceEditorDocument(), formDocument = AgentWorkspaceEditorDocument()
    private var folderHeight:NSLayoutConstraint!, icons:[NSButton] = [], colors:[NSButton] = []
    private var folders:[String], primary:String, icon:AgentWorkspaceIcon, color:AgentWorkspaceColor
    private let saveWorkspace:(String,AgentWorkspaceIcon,AgentWorkspaceColor,[String],String) throws -> Void
    private let archiveWorkspace:() throws -> Void, onClose:() -> Void
    private weak var previousResponder:NSResponder?
    init(entry:AgentDirectoryEntry, save:@escaping (String,AgentWorkspaceIcon,AgentWorkspaceColor,[String],String) throws -> Void, archive:@escaping () throws -> Void, onClose:@escaping () -> Void) {
        original = entry; folders = entry.sourceFolders; primary = entry.primary; icon = entry.icon ?? .folder; color = entry.color ?? .forest
        saveWorkspace = save; archiveWorkspace = archive; self.onClose = onClose
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:560,height:470),styleMask:[.titled,.fullSizeContentView],backing:.buffered,defer:false)
        panel.title = "编辑" + entry.mode.directoryTitle; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true; panel.isReleasedWhenClosed = false
        super.init(window:panel)
        let root = AgentThemeView(fill:AgentWorkbenchTheme.surface); panel.contentView = root
        let heading = NSTextField(labelWithString:panel.title); heading.font = .systemFont(ofSize:15,weight:.semibold)
        let close = AgentWorkbenchButton(); AgentWorkbenchTheme.toolbar(close,title:"取消工作区编辑",symbol:"xmark"); close.target = self; close.action = #selector(cancel)
        let header = NSStackView(views:[heading,NSView(),close]); header.alignment = .centerY
        let add = AgentWorkbenchButton(); AgentWorkbenchTheme.toolbar(add,title:"添加源文件夹",symbol:"plus"); add.target = self; add.action = #selector(addFolders)
        let sourceLabel = label("源文件夹"), sourceHeader = NSStackView(views:[sourceLabel,NSView(),add]); sourceHeader.alignment = .centerY
        folderColumn.orientation = .vertical; folderColumn.alignment = .leading; folderColumn.spacing = 4
        configureScroll(folderScroll,document:folderDocument,content:folderColumn)
        folderHeight = folderScroll.heightAnchor.constraint(equalToConstant:32); folderHeight.isActive = true
        input.stringValue = entry.title; input.font = .systemFont(ofSize:13); input.bezelStyle = .roundedBezel; input.delegate = self; input.setAccessibilityLabel(entry.mode.directoryTitle + "名称"); input.identifier = .init("workspace-editor-name")
        input.heightAnchor.constraint(equalToConstant:32).isActive = true
        let iconRow = NSStackView(); iconRow.spacing = 5
        for value in AgentWorkspaceIcon.allCases {
            let button = AgentWorkbenchButton(); button.image = NSImage(systemSymbolName:value.rawValue,accessibilityDescription:nil); button.imagePosition = .imageOnly
            button.title = ""; button.bezelStyle = .regularSquare; button.setButtonType(.toggle); button.identifier = .init(value.rawValue)
            button.setAccessibilityLabel("图标：" + value.title); button.toolTip = value.title; button.target = self; button.action = #selector(selectIcon(_:))
            button.widthAnchor.constraint(equalToConstant:26).isActive = true; button.heightAnchor.constraint(equalToConstant:28).isActive = true
            icons.append(button); iconRow.addArrangedSubview(button)
        }
        let colorRow = NSStackView(); colorRow.spacing = 5
        for value in AgentWorkspaceColor.allCases {
            let button = AgentWorkbenchButton(); button.title = ""; button.bezelStyle = .regularSquare; button.setButtonType(.toggle); button.identifier = .init(value.rawValue)
            button.image = NSImage(size:NSSize(width:16,height:16),flipped:false) { bounds in value.nsColor.setFill(); NSBezierPath(ovalIn:bounds.insetBy(dx:1,dy:1)).fill(); return true }; button.imagePosition = .imageOnly
            button.setAccessibilityLabel("颜色：" + value.title); button.toolTip = value.title; button.target = self; button.action = #selector(selectColor(_:))
            button.widthAnchor.constraint(equalToConstant:26).isActive = true; button.heightAnchor.constraint(equalToConstant:28).isActive = true
            colors.append(button); colorRow.addArrangedSubview(button)
        }
        rangeNote.font = .systemFont(ofSize:11); rangeNote.textColor = AgentWorkbenchTheme.secondaryText
        form.orientation = .vertical; form.alignment = .leading; form.spacing = 10
        for view in [sourceHeader,folderScroll,label(entry.mode.directoryTitle + "名称"),input,label(entry.mode.directoryTitle + "图标"),iconRow,label(entry.mode.directoryTitle + "颜色"),colorRow,rangeNote] {
            form.addArrangedSubview(view); if view !== iconRow && view !== colorRow { view.widthAnchor.constraint(equalTo:form.widthAnchor).isActive = true }
        }
        configureScroll(viewport,document:formDocument,content:form)
        status.font = .systemFont(ofSize:12); status.textColor = .systemRed; status.setAccessibilityLabel("工作区保存状态"); status.isHidden = true
        let archive = NSButton(title:"归档" + entry.mode.directoryTitle,target:self,action:#selector(archiveEntry)); archive.isBordered = false; archive.contentTintColor = .systemRed
        let cancel = NSButton(title:"取消",target:self,action:#selector(cancel)), save = NSButton(title:"保存",target:self,action:#selector(submit))
        for button in [cancel,save] { button.bezelStyle = .rounded; button.controlSize = .large; button.widthAnchor.constraint(equalToConstant:80).isActive = true }
        cancel.keyEquivalent = "\u{1b}"; save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command; save.bezelColor = AgentWorkbenchTheme.accent
        let actions = NSStackView(views:[archive,NSView(),cancel,save]); actions.spacing = 8
        let column = NSStackView(views:[header,viewport,status,actions]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 12; column.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(column)
        for view in column.arrangedSubviews { view.widthAnchor.constraint(equalTo:column.widthAnchor).isActive = true }
        viewport.setContentHuggingPriority(.defaultLow,for:.vertical)
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:20),column.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-20),column.topAnchor.constraint(equalTo:root.topAnchor,constant:18),column.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-18)])
        panel.initialFirstResponder = input; refresh()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    private func configureScroll(_ scroll:NSScrollView, document:NSView, content:NSView) {
        scroll.documentView = document; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        document.translatesAutoresizingMaskIntoConstraints = false; content.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(content)
        let preferredHeight = document.heightAnchor.constraint(equalTo:scroll.contentView.heightAnchor); preferredHeight.priority = .defaultLow
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor),document.heightAnchor.constraint(greaterThanOrEqualTo:scroll.contentView.heightAnchor),preferredHeight,
            content.leadingAnchor.constraint(equalTo:document.leadingAnchor),content.trailingAnchor.constraint(equalTo:document.trailingAnchor),content.topAnchor.constraint(equalTo:document.topAnchor),content.bottomAnchor.constraint(lessThanOrEqualTo:document.bottomAnchor)])
    }
    private func label(_ text:String) -> NSTextField { let value = NSTextField(labelWithString:text); value.font = .systemFont(ofSize:12,weight:.medium); return value }
    private func refresh() {
        for child in folderColumn.arrangedSubviews { folderColumn.removeArrangedSubview(child); child.removeFromSuperview() }
        for (index,path) in folders.enumerated() {
            let name = NSTextField(labelWithString:URL(fileURLWithPath:path).lastPathComponent); name.font = .systemFont(ofSize:12); name.lineBreakMode = .byTruncatingMiddle; name.toolTip = path
            let image = NSImageView(image:NSImage(systemSymbolName:"folder",accessibilityDescription:nil)!); image.contentTintColor = AgentWorkbenchTheme.secondaryText
            image.widthAnchor.constraint(equalToConstant:16).isActive = true
            let main = NSButton(title:path == primary ? "主要" : "设为主要",target:self,action:#selector(selectPrimary(_:))); main.tag = index; main.isEnabled = path != primary; main.bezelStyle = .inline; main.font = .systemFont(ofSize:11); main.setAccessibilityLabel((path == primary ? "主文件夹：" : "设为主文件夹：") + path)
            let remove = AgentWorkbenchButton(); AgentWorkbenchTheme.toolbar(remove,title:"移除源文件夹：" + path,symbol:"xmark"); remove.tag = index; remove.target = self; remove.action = #selector(removeFolder(_:)); remove.isEnabled = folders.count > 1
            let row = NSStackView(views:[image,name,NSView(),main,remove]); row.spacing = 8; row.heightAnchor.constraint(equalToConstant:32).isActive = true; folderColumn.addArrangedSubview(row); row.widthAnchor.constraint(equalTo:folderColumn.widthAnchor).isActive = true
        }
        folderHeight.constant = CGFloat(min(4,folders.count))*36
        for button in icons { button.state = button.identifier?.rawValue == icon.rawValue ? .on : .off; button.contentTintColor = button.state == .on ? color.nsColor : AgentWorkbenchTheme.secondaryText }
        for button in colors { button.state = button.identifier?.rawValue == color.rawValue ? .on : .off }
        rangeNote.isHidden = folders == original.sourceFolders && primary == original.primary
        window?.contentView?.layoutSubtreeIfNeeded()
    }
    func begin(in owner:NSWindow) {
        guard let panel = window, owner.attachedSheet == nil else { return }; previousResponder = owner.firstResponder; AgentThemeContext.inherit(panel,from:owner)
        panel.setContentSize(NSSize(width:min(560,owner.contentLayoutRect.width-32),height:min(420 + CGFloat(min(4,folders.count)-1)*36,owner.contentLayoutRect.height-32)))
        owner.beginSheet(panel) { [self,weak owner] _ in panel.orderOut(nil); onClose(); if let view = previousResponder as? NSView, view.window === owner { owner?.makeFirstResponder(view) } }
        panel.makeFirstResponder(input); input.selectText(nil); refresh()
    }
    @objc func cancel() { if let window { window.sheetParent?.endSheet(window,returnCode:.cancel) } }
    @objc private func selectIcon(_ sender:NSButton) { if let id = sender.identifier?.rawValue, let value = AgentWorkspaceIcon(rawValue:id) { icon = value; refresh() } }
    @objc private func selectColor(_ sender:NSButton) { if let id = sender.identifier?.rawValue, let value = AgentWorkspaceColor(rawValue:id) { color = value; refresh() } }
    @objc private func selectPrimary(_ sender:NSButton) { guard folders.indices.contains(sender.tag) else { return }; primary = folders[sender.tag]; refresh() }
    @objc private func removeFolder(_ sender:NSButton) { guard folders.count > 1, folders.indices.contains(sender.tag) else { return }; let removed = folders.remove(at:sender.tag); if removed == primary { primary = folders[0] }; refresh() }
    @objc private func addFolders() {
        guard let window, window.attachedSheet == nil else { return }
        let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.allowsMultipleSelection = true; picker.prompt = "添加"; picker.directoryURL = URL(fileURLWithPath:primary)
        picker.beginSheetModal(for:window) { [weak self] result in
            guard let self, result == .OK else { return }
            do { let paths = folders + picker.urls.map{ $0.resolvingSymlinksInPath().path }; folders = try AgentWorkspaceScope.validateFolders(paths,primary:primary); status.isHidden = true; refresh() }
            catch { status.stringValue = error.localizedDescription; status.isHidden = false }
        }
    }
    @objc private func submit() {
        guard (input.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        do { try saveWorkspace(input.stringValue,icon,color,folders,primary); if let window { window.sheetParent?.endSheet(window,returnCode:.OK) } }
        catch { status.stringValue = error.localizedDescription; status.isHidden = false }
    }
    @objc private func archiveEntry() {
        guard input.stringValue == original.title, icon == (original.icon ?? .folder), color == (original.color ?? .forest), folders == original.sourceFolders, primary == original.primary else { status.stringValue = "请先保存或取消工作区修改"; status.isHidden = false; return }
        do { try archiveWorkspace(); cancel() } catch { status.stringValue = error.localizedDescription; status.isHidden = false }
    }
    func control(_ control:NSControl, textView:NSTextView, doCommandBy selector:Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) { submit(); return true }; if selector == #selector(NSResponder.cancelOperation(_:)) { cancel(); return true }; return false
    }
    func checkState() -> [String:Any] {
        guard CommandLine.arguments.contains("--manual-ui") || CommandLine.arguments.contains("--workspace-editor-check") || CommandLine.arguments.contains("--name-editor-check") else { return [:] }
        return ["visible":window?.isVisible == true,"title":window?.title ?? "","value":input.stringValue,"error":status.stringValue,"inputFocused":input.currentEditor().map{window?.firstResponder === $0} ?? false,"inputWidth":input.bounds.width,"ambiguousLayout":input.hasAmbiguousLayout || viewport.hasAmbiguousLayout,"folders":folders,"primary":primary,"icon":icon.rawValue,"color":color.rawValue,"formHeight":form.frame.height,"viewportHeight":viewport.contentSize.height,"formTop":form.frame.minY,"folderTop":folderColumn.frame.minY,"documentFlipped":formDocument.isFlipped]
    }
}
