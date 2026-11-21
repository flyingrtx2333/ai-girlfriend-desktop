import AppKit

struct AgentFileConflictSnapshot {
    let file: URL, disk: Data, draft: Data
    let allowsOverwrite: Bool
    let diskEncoding: AgentTextEncoding?, draftEncoding: AgentTextEncoding?
    init(file: URL, disk: Data, draft: Data, allowsOverwrite: Bool, diskEncoding: AgentTextEncoding? = nil, draftEncoding: AgentTextEncoding? = nil) {
        self.file = file; self.disk = disk; self.draft = draft; self.allowsOverwrite = allowsOverwrite; self.diskEncoding = diskEncoding; self.draftEncoding = draftEncoding
    }
    var diskHash: String { AgentFiles.hash(disk) }
    var draftHash: String { AgentFiles.hash(draft) }
    static func read(file: URL, workspace: String, draft: String, allowsOverwrite: Bool, format: AgentTextFormat? = nil) throws -> Self {
        let files = try AgentFiles(workspace: workspace), safe = try files.resolve(file.path)
        guard safe == file, !AgentFiles.sensitive(files.relative(safe)) else { throw PetError("文件位置已变化，草稿已保留") }
        let disk: Data
        do { disk = try files.readData(safe, maximum: 2_000_000) }
        catch { throw readFailure(error) }
        let draftDocument = try format.map { AgentTextFile(text: draft, format: $0) } ?? AgentTextFile.decode(Data(draft.utf8), encoding: .utf8)
        let content = try draftDocument.format.encode(draftDocument.text)
        let diskDocument = try AgentTextFile.decode(disk, encoding: AgentTextEncoding.markedEncoding(disk) == nil ? format?.encoding : nil)
        guard content.count <= 2_000_000, draftDocument.text.utf8.count <= 2_000_000, diskDocument.text.utf8.count <= 2_000_000 else { throw PetError("文本超过比较上限，草稿已保留") }
        return Self(file: safe, disk: disk, draft: content, allowsOverwrite: allowsOverwrite, diskEncoding: diskDocument.format.encoding, draftEncoding: draftDocument.format.encoding)
    }
    static func readFailure(_ error: Error) -> PetError {
        if let failure = error as? PetError { return failure }
        if let failure = error as? POSIXError {
            switch failure.code {
            case .ENOENT, .ENOTDIR, .ENODEV, .ENXIO, .ESTALE: return PetError("原文件暂不可用")
            case .EACCES, .EPERM: return PetError("没有读取原文件的权限")
            case .ELOOP: return PetError("原文件位置已变化，草稿已保留")
            default: break
            }
        }
        if let failure = error as? CocoaError {
            switch failure.code {
            case .fileNoSuchFile, .fileReadNoSuchFile: return PetError("原文件暂不可用")
            case .fileReadNoPermission: return PetError("没有读取原文件的权限")
            default: break
            }
        }
        return PetError("无法读取原文件，草稿已保留")
    }
    func requireUnchanged(_ current: Self) throws {
        guard file == current.file, disk == current.disk, draft == current.draft, diskEncoding == current.diskEncoding, draftEncoding == current.draftEncoding else { throw PetError("文件或草稿已变化，请刷新比较") }
    }
    func diskDocument() throws -> AgentTextFile { try AgentTextFile.decode(disk, encoding: diskEncoding) }
    func draftDocument() throws -> AgentTextFile { try AgentTextFile.decode(draft, encoding: draftEncoding) }
    static func format(_ data: Data) -> String { AgentTextFile.formatDescription(data) }
    func patch(protectedData: URL) async throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bluefatfish-file-compare-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try AgentFiles(workspace: directory.path), left = try files.resolve("disk"), right = try files.resolve("draft")
        let before = try diskDocument(), after = try draftDocument()
        try files.writeData(Data(((before.format.bom ? "\u{FEFF}" : "") + before.text).utf8), to: left, permissions: 0o600)
        try files.writeData(Data(((after.format.bom ? "\u{FEFF}" : "") + after.text).utf8), to: right, permissions: 0o600)
        let result = try await AgentChanges.fileDiff(left: left, right: right, directory: directory, protectedData: protectedData, maximumOutput: 2_000_000)
        return await AgentChanges.labels(result, path: file.lastPathComponent)
    }
}

@MainActor final class AgentFileConflictWindow: AgentSettingsPageController, NSWindowDelegate {
    enum Resolution { case disk, draft }
    struct RecoveryState: Codable, Sendable {
        var version = 1
        let file: String
        var mode: Int
        var diskHash: String? = nil, draftHash: String? = nil
        var disk: AgentTextViewport? = nil, draft: AgentTextViewport? = nil
        var split: AgentGitDiffView.SplitPosition? = nil
        var revealSelection: Bool? = nil

        var valid: Bool {
            version == 1 && file.hasPrefix("/") && file.utf8.count < 8192 && !file.contains("\0") && (0...1).contains(mode) &&
                (diskHash == nil) == (draftHash == nil) && AgentSettingsRecovery.validHash(diskHash) && AgentSettingsRecovery.validHash(draftHash) &&
                (diskHash != nil || disk == nil && draft == nil && split == nil) && disk?.valid != false && draft?.valid != false &&
                split?.valid != false && !(disk?.focused == true && draft?.focused == true) &&
                (revealSelection != true || disk?.focused == true || draft?.focused == true)
        }
        static func validateObject(_ raw: Any) throws {
            let value = try AgentSettingsRecovery.object(raw, keys: ["version", "file", "mode", "diskHash", "draftHash", "disk", "draft", "split", "revealSelection"])
            for key in ["disk", "draft"] { if let viewport = value[key], !(viewport is NSNull) { try AgentTextViewport.validateObject(viewport) } }
            if let split = value["split"], !(split is NSNull) { _ = try AgentSettingsRecovery.object(split, keys: ["row", "fraction"]) }
        }
    }

    private let file: URL
    private let readSnapshot: () throws -> AgentFileConflictSnapshot
    private let didReview: (AgentFileConflictSnapshot) throws -> Void
    private let resolve: (AgentFileConflictSnapshot, Resolution) async throws -> Void
    private let protectedData: URL
    private let diff = AgentGitDiffView(), full = NSStackView(), diskText = NSTextView(), draftText = NSTextView()
    private let diskFormat = NSTextField(labelWithString: ""), draftFormat = NSTextField(labelWithString: ""), state = NSTextField(wrappingLabelWithString: "")
    private let filename = NSTextField(labelWithString: "")
    private let mode = NSSegmentedControl(labels: ["差异", "全文"], trackingMode: .selectOne, target: nil, action: nil)
    private let refresh = AgentDialogButton(title: "刷新比较", target: nil, action: nil), keep = AgentDialogButton(title: "继续编辑", target: nil, action: nil)
    private let adopt = AgentDialogButton(title: "采用磁盘版本…", target: nil, action: nil), overwrite = AgentDialogButton(title: "覆盖文件…", target: nil, action: nil)
    private var review: AgentFileConflictSnapshot?, job: Task<Void, Never>?, loading = false, resolving = false
    private var recovery: RecoveryState?, applyingPosition = false
    var onPositionChange: (() -> Void)?, onClose: (() -> Void)?
    init(file: URL, protectedData: URL, recovery: RecoveryState? = nil,
         read: @escaping () throws -> AgentFileConflictSnapshot, didReview: @escaping (AgentFileConflictSnapshot) throws -> Void = { _ in },
         resolve: @escaping (AgentFileConflictSnapshot, Resolution) async throws -> Void) {
        self.file = file; self.readSnapshot = read; self.didReview = didReview; self.resolve = resolve
        self.protectedData = protectedData; self.recovery = recovery
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "文件比较 · " + file.lastPathComponent; window.minSize = NSSize(width: 720, height: 440); window.center(); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let content = AgentThemeView(fill: AgentWorkbenchTheme.surface); window.contentView = content
        filename.stringValue = file.lastPathComponent; filename.toolTip = file.path; filename.setAccessibilityHelp(file.path); filename.lineBreakMode = .byTruncatingMiddle
        mode.target = self; mode.action = #selector(switchComparisonView); mode.selectedSegment = recovery?.mode ?? 0; mode.setAccessibilityLabel("文件比较显示方式")
        let top = NSStackView(views: [filename, NSView(), mode]); top.spacing = 12
        diff.splitMode = true; diff.wraps = true
        diff.onSplitScroll = { [weak self] in self?.positionChanged() }
        full.distribution = .fillEqually; full.spacing = 16
        for (field, title, format) in [(diskText, "磁盘文件", diskFormat), (draftText, "我的草稿", draftFormat)] {
            field.isEditable = false; field.isSelectable = true; field.isRichText = false; field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.textContainerInset = NSSize(width: 12, height: 12); field.isVerticallyResizable = true; field.autoresizingMask = [.width]; field.textContainer?.widthTracksTextView = true
            field.setAccessibilityLabel(title + "全文")
            format.font = .systemFont(ofSize: 11); format.textColor = AgentWorkbenchTheme.secondaryText
            let header = NSStackView(views: [NSTextField(labelWithString: title), NSView(), format]), scroll = NSScrollView(); scroll.documentView = field; scroll.hasVerticalScroller = true
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged(_:)), name: NSTextView.didChangeSelectionNotification, object: field)
            let column = NSStackView(views: [header, scroll]); column.orientation = .vertical; column.spacing = 6
            for view in [header, scroll] { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
            full.addArrangedSubview(column)
            column.heightAnchor.constraint(equalTo: full.heightAnchor).isActive = true
        }
        let versions = NSView()
        for view in [diff, full] { versions.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false; NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: versions.leadingAnchor), view.trailingAnchor.constraint(equalTo: versions.trailingAnchor), view.topAnchor.constraint(equalTo: versions.topAnchor), view.bottomAnchor.constraint(equalTo: versions.bottomAnchor)]) }
        refresh.target = self; refresh.action = #selector(refreshComparison); keep.target = self; keep.action = #selector(continueEditing); keep.keyEquivalent = "\u{1b}"
        adopt.target = self; adopt.action = #selector(adoptDisk); overwrite.target = self; overwrite.action = #selector(overwriteDisk)
        state.font = .systemFont(ofSize: 13); state.maximumNumberOfLines = 2; state.lineBreakMode = .byWordWrapping
        for field in [diskText, draftText] { field.drawsBackground = false; field.textColor = .labelColor }
        for button in [refresh, keep, adopt, overwrite] { AgentDialogStyle.action(button) }
        let actions = NSStackView(views: [keep, refresh, NSView(), adopt, overwrite]); actions.spacing = 8
        let header = NSStackView(views: [top, state]); header.orientation = .vertical; header.alignment = .leading; header.spacing = 8
        for row in [top, state] { row.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true }
        for view in [header, versions, actions] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false; NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16)]) }
        NSLayoutConstraint.activate([header.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), versions.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12), versions.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12), actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)])
        loadComparison(requiringMatch: recovery != nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func settingsContent(in host: NSWindow, styled: Bool = true) -> NSView? {
        filename.isHidden = true
        return super.settingsContent(in: host, styled: styled)
    }
    @objc private func viewportChanged(_ notification: Notification) { positionChanged() }
    private func positionChanged() { if !applyingPosition, !loading, isPageVisible { onPositionChange?() } }
    private func showSelectedVersion() {
        diff.isHidden = review == nil || mode.selectedSegment != 0
        full.isHidden = review == nil || mode.selectedSegment != 1
    }
    @objc private func switchComparisonView() {
        showSelectedVersion()
        restorePositionWhenVisible(); positionChanged()
    }
    private func restorePositionWhenVisible() {
        guard isPageVisible, review != nil, !loading, recovery != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, isPageVisible, !loading, review != nil, var pending = recovery else { return }
            applyingPosition = true
            defer { applyingPosition = false }
            pageContentView?.layoutSubtreeIfNeeded()
            if mode.selectedSegment == 0 {
                if let split = pending.split, diff.restoreSplitPosition(split) { pending.split = nil }
            } else {
                if let disk = pending.disk, restore(disk, in: diskText, revealSelection: pending.revealSelection == true) { pending.disk = nil }
                if let draft = pending.draft, restore(draft, in: draftText, revealSelection: pending.revealSelection == true) { pending.draft = nil }
                if pending.disk == nil, pending.draft == nil { pending.revealSelection = nil }
            }
            recovery = pending
        }
    }
    private func restore(_ viewport: AgentTextViewport, in text: NSTextView, revealSelection: Bool) -> Bool {
        guard viewport.apply(to: text) else { return false }
        if revealSelection, viewport.focused, let selected = viewport.selections.first, !viewport.focusedSelectionIsVisible(in: text) {
            text.scrollRangeToVisible(selected.range)
        }
        return true
    }
    override func settingsDidAppear() { super.settingsDidAppear(); restorePositionWhenVisible() }
    func windowDidBecomeKey(_ notification: Notification) { restorePositionWhenVisible() }

    func captureRecovery() throws -> RecoveryState {
        guard !resolving else { throw PetError("请先完成文件比较中的操作") }
        var saved = recovery ?? RecoveryState(file: file.path, mode: mode.selectedSegment)
        saved.mode = mode.selectedSegment
        if let review {
            saved.diskHash = review.diskHash; saved.draftHash = review.draftHash
            if !loading {
                if saved.disk == nil { saved.disk = try AgentTextViewport(diskText) }
                if saved.draft == nil { saved.draft = try AgentTextViewport(draftText) }
                if saved.split == nil { saved.split = diff.captureSplitPosition() }
                if mode.selectedSegment == 1, isPageVisible, recovery?.disk == nil, recovery?.draft == nil {
                    let visible = saved.disk?.focusedSelectionIsVisible(in: diskText) == true || saved.draft?.focusedSelectionIsVisible(in: draftText) == true
                    saved.revealSelection = visible ? true : nil
                }
            }
        }
        guard saved.valid else { throw PetError("文件比较的位置无法保存，原草稿已保留") }
        return saved
    }
    private func updateActions() {
        keep.title = review?.allowsOverwrite == true ? "继续编辑" : "返回草稿"
        refresh.isEnabled = !loading && !resolving; keep.isEnabled = !resolving
        refresh.prominent = review == nil && !loading
        adopt.isEnabled = !loading && !resolving && review != nil && review?.disk != review?.draft
        overwrite.isEnabled = adopt.isEnabled && review?.allowsOverwrite == true
    }
    private func showStatus(_ message: String, warning: Bool = false) {
        state.stringValue = message; state.toolTip = message
        state.textColor = warning ? AgentDialogStyle.warning : AgentWorkbenchTheme.secondaryText
        state.isHidden = message.isEmpty
    }
    private func invalidateReview(_ message: String) {
        review = nil
        showSelectedVersion()
        diskText.string = ""; draftText.string = ""
        diff.show("", oldTitle: "磁盘文件", newTitle: "我的草稿", accessibilityContext: "文件")
        mode.isEnabled = false; loading = false
        showStatus(message, warning: true); updateActions(); positionChanged()
    }
    @objc private func refreshComparison() {
        if review != nil, let saved = try? captureRecovery() { recovery = saved }
        loadComparison(requiringMatch: false)
    }
    private func loadComparison(requiringMatch: Bool) {
        guard !resolving else { return }
        job?.cancel(); review = nil; loading = true; mode.isEnabled = false
        showSelectedVersion(); showStatus("正在比较…"); updateActions()
        do {
            let value = try readSnapshot()
            let matches = recovery.map { expected in
                expected.file == value.file.path && expected.diskHash == value.diskHash && expected.draftHash == value.draftHash
            } ?? true
            guard matches || !requiringMatch else {
                throw PetError("文件或草稿已变化，请刷新比较")
            }
            diskText.string = try value.diskDocument().text; draftText.string = try value.draftDocument().text
            try didReview(value)
            if !matches { recovery = nil }
            review = value
            diskFormat.stringValue = AgentTextFile.formatDescription(value.disk, encoding: value.diskEncoding); draftFormat.stringValue = AgentTextFile.formatDescription(value.draft, encoding: value.draftEncoding)
            diff.show("", oldTitle: "磁盘文件", newTitle: "我的草稿", accessibilityContext: "文件"); switchComparisonView()
            job = Task { [weak self] in
                guard let self else { return }
                do {
                    let patch = try await value.patch(protectedData: protectedData); try Task.checkCancellation()
                    diff.show(patch, oldTitle: "磁盘文件", newTitle: "我的草稿", accessibilityContext: "文件")
                    showStatus(patch.isEmpty ? (value.disk == value.draft ? "内容一致" : "文本一致，文件编码或标记不同") : "")
                    mode.isEnabled = true
                } catch {
                    guard !Task.isCancelled else { return }; mode.selectedSegment = 1; switchComparisonView()
                    showStatus("无法显示差异，请对照全文", warning: true)
                }
                loading = false; updateActions(); restorePositionWhenVisible(); positionChanged()
            }
        } catch {
            invalidateReview(error.localizedDescription)
        }
    }
    @objc private func continueEditing() { close() }
    @objc private func adoptDisk() { confirm(.disk) }
    @objc private func overwriteDisk() { confirm(.draft) }
    private func confirm(_ resolution: Resolution) {
        guard !loading, !resolving, let review else { return }
        let position = try? captureRecovery()
        let alert = AgentConfirmation(); alert.messageText = resolution == .disk ? "采用磁盘版本并放弃草稿？" : "用我的草稿覆盖磁盘文件？"
        alert.informativeText = resolution == .disk ? "当前未保存的修改会丢失。" : "磁盘版本会保留在任务的修改检查点中。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: resolution == .disk ? "采用磁盘版本" : "覆盖文件").hasDestructiveAction = true
        guard alert.runModal(for: presentingWindow) == .alertSecondButtonReturn else { return }
        resolving = true; updateActions(); showStatus(resolution == .disk ? "正在采用磁盘版本…" : "正在保存…")
        job = Task { [weak self] in
            guard let self else { return }
            do { try await resolve(review, resolution); resolving = false; close() }
            catch {
                resolving = false; recovery = position ?? recovery
                invalidateReview(AgentSaveFailure.message(for: error))
            }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !resolving }
    var canNavigateWorkspace: Bool { !resolving }
    func windowWillClose(_ notification: Notification) { job?.cancel(); onClose?(); onClose = nil }
    var checkState: [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled || ["--file-conflict-check", "--text-encoding-check"].contains(where: CommandLine.arguments.contains) else { return [:] }
        return ["visible": isPageVisible, "diskHash": review?.diskHash ?? "", "draftHash": review?.draftHash ?? "", "loading": loading, "resolving": resolving, "overwriteEnabled": overwrite.isEnabled, "adoptEnabled": adopt.isEnabled, "mode": mode.selectedSegment, "patch": diff.patch, "state": state.stringValue]
    }
}
