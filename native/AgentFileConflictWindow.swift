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
        let disk = try files.readData(safe, maximum: 2_000_000)
        let draftDocument = try format.map { AgentTextFile(text: draft, format: $0) } ?? AgentTextFile.decode(Data(draft.utf8), encoding: .utf8)
        let content = try draftDocument.format.encode(draftDocument.text)
        let diskDocument = try AgentTextFile.decode(disk, encoding: AgentTextEncoding.markedEncoding(disk) == nil ? format?.encoding : nil)
        guard content.count <= 2_000_000, draftDocument.text.utf8.count <= 2_000_000, diskDocument.text.utf8.count <= 2_000_000 else { throw PetError("文本超过比较上限，草稿已保留") }
        return Self(file: safe, disk: disk, draft: content, allowsOverwrite: allowsOverwrite, diskEncoding: diskDocument.format.encoding, draftEncoding: draftDocument.format.encoding)
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

@MainActor final class AgentFileConflictWindow: NSWindowController, NSWindowDelegate {
    enum Resolution { case disk, draft }
    private let readSnapshot: () throws -> AgentFileConflictSnapshot
    private let resolve: (AgentFileConflictSnapshot, Resolution) async throws -> Void
    private let protectedData: URL
    private let diff = AgentGitDiffView(), full = NSStackView(), diskText = NSTextView(), draftText = NSTextView()
    private let diskFormat = NSTextField(labelWithString: ""), draftFormat = NSTextField(labelWithString: ""), state = NSTextField(labelWithString: "")
    private let mode = NSSegmentedControl(labels: ["差异", "全文"], trackingMode: .selectOne, target: nil, action: nil)
    private let refresh = NSButton(title: "刷新比较", target: nil, action: nil), keep = NSButton(title: "继续编辑", target: nil, action: nil)
    private let adopt = NSButton(title: "采用磁盘版本…", target: nil, action: nil), overwrite = NSButton(title: "覆盖文件…", target: nil, action: nil)
    private var review: AgentFileConflictSnapshot?, job: Task<Void, Never>?, loading = false, resolving = false
    init(file: URL, protectedData: URL, read: @escaping () throws -> AgentFileConflictSnapshot, resolve: @escaping (AgentFileConflictSnapshot, Resolution) async throws -> Void) {
        self.readSnapshot = read; self.resolve = resolve; self.protectedData = protectedData
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "文件比较 · " + file.lastPathComponent; window.minSize = NSSize(width: 720, height: 440); window.center(); window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua); super.init(window: window); window.delegate = self
        let content = NSView(); window.contentView = content
        let path = NSTextField(labelWithString: file.lastPathComponent); path.toolTip = file.path; path.setAccessibilityHelp(file.path); path.lineBreakMode = .byTruncatingMiddle
        mode.target = self; mode.action = #selector(switchComparisonView); mode.selectedSegment = 0; mode.setAccessibilityLabel("文件比较显示方式")
        let top = NSStackView(views: [path, NSView(), mode]); top.spacing = 12
        diff.splitMode = true; diff.wraps = true
        full.distribution = .fillEqually; full.spacing = 16
        for (field, title, format) in [(diskText, "磁盘文件", diskFormat), (draftText, "我的草稿", draftFormat)] {
            field.isEditable = false; field.isSelectable = true; field.isRichText = false; field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.textContainerInset = NSSize(width: 12, height: 12); field.isVerticallyResizable = true; field.autoresizingMask = [.width]; field.textContainer?.widthTracksTextView = true
            field.setAccessibilityLabel(title + "全文")
            format.font = .systemFont(ofSize: 11); format.textColor = .secondaryLabelColor
            let header = NSStackView(views: [NSTextField(labelWithString: title), NSView(), format]), scroll = NSScrollView(); scroll.documentView = field; scroll.hasVerticalScroller = true
            let column = NSStackView(views: [header, scroll]); column.orientation = .vertical; column.spacing = 6
            for view in [header, scroll] { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
            full.addArrangedSubview(column)
            column.heightAnchor.constraint(equalTo: full.heightAnchor).isActive = true
        }
        let versions = NSView()
        for view in [diff, full] { versions.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false; NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: versions.leadingAnchor), view.trailingAnchor.constraint(equalTo: versions.trailingAnchor), view.topAnchor.constraint(equalTo: versions.topAnchor), view.bottomAnchor.constraint(equalTo: versions.bottomAnchor)]) }
        refresh.target = self; refresh.action = #selector(refreshComparison); keep.target = self; keep.action = #selector(continueEditing); keep.keyEquivalent = "\u{1b}"
        adopt.target = self; adopt.action = #selector(adoptDisk); overwrite.target = self; overwrite.action = #selector(overwriteDisk)
        state.font = .systemFont(ofSize: 11); state.textColor = .secondaryLabelColor; state.lineBreakMode = .byTruncatingTail; state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [refresh, state, NSView(), keep, adopt, overwrite]); actions.spacing = 8
        for view in [top, versions, actions] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false; NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16)]) }
        NSLayoutConstraint.activate([top.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), versions.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 12), versions.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12), actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)])
        refreshComparison()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func switchComparisonView() { diff.isHidden = mode.selectedSegment != 0; full.isHidden = !diff.isHidden }
    private func updateActions() {
        refresh.isEnabled = !loading && !resolving; keep.isEnabled = !resolving
        adopt.isEnabled = !loading && !resolving && review != nil && review?.disk != review?.draft
        overwrite.isEnabled = adopt.isEnabled && review?.allowsOverwrite == true
    }
    @objc private func refreshComparison() {
        guard !resolving else { return }; job?.cancel(); review = nil; loading = true; state.stringValue = "正在比较…"; mode.isEnabled = false; updateActions()
        do {
            let value = try readSnapshot(); diskText.string = try value.diskDocument().text; draftText.string = try value.draftDocument().text
            diskFormat.stringValue = AgentTextFile.formatDescription(value.disk, encoding: value.diskEncoding); draftFormat.stringValue = AgentTextFile.formatDescription(value.draft, encoding: value.draftEncoding)
            diff.show("", oldTitle: "磁盘文件", newTitle: "我的草稿", accessibilityContext: "文件"); switchComparisonView()
            job = Task { [weak self] in
                guard let self else { return }
                do {
                    let patch = try await value.patch(protectedData: protectedData); try Task.checkCancellation()
                    diff.show(patch, oldTitle: "磁盘文件", newTitle: "我的草稿", accessibilityContext: "文件"); state.stringValue = patch.isEmpty ? (value.disk == value.draft ? "内容一致" : "文本一致，文件编码或标记不同") : ""
                    mode.isEnabled = true
                } catch {
                    guard !Task.isCancelled else { return }; mode.selectedSegment = 1; switchComparisonView(); state.stringValue = "无法显示差异，请对照全文"
                }
                review = value; loading = false; updateActions()
            }
        } catch { diskText.string = ""; draftText.string = ""; diff.show("", oldTitle: "磁盘文件", newTitle: "我的草稿", accessibilityContext: "文件"); state.stringValue = error.localizedDescription; loading = false; updateActions() }
    }
    @objc private func continueEditing() { close() }
    @objc private func adoptDisk() { confirm(.disk) }
    @objc private func overwriteDisk() { confirm(.draft) }
    private func confirm(_ resolution: Resolution) {
        guard !loading, !resolving, let review else { return }
        let alert = NSAlert(); alert.messageText = resolution == .disk ? "采用磁盘版本并放弃草稿？" : "用我的草稿覆盖磁盘文件？"
        alert.informativeText = resolution == .disk ? "当前未保存的修改会丢失。" : "磁盘版本会保留在任务的修改检查点中。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: resolution == .disk ? "采用磁盘版本" : "覆盖文件")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        resolving = true; updateActions(); state.stringValue = resolution == .disk ? "正在采用磁盘版本…" : "正在保存…"
        job = Task { [weak self] in
            guard let self else { return }
            do { try await resolve(review, resolution); resolving = false; close() }
            catch { resolving = false; self.review = nil; state.stringValue = error.localizedDescription; updateActions() }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !resolving }
    func windowWillClose(_ notification: Notification) { job?.cancel() }
    var checkState: [String: Any] {
        guard ["--file-conflict-check", "--text-encoding-check"].contains(where: CommandLine.arguments.contains) else { return [:] }
        return ["visible": window?.isVisible == true, "diskHash": review?.diskHash ?? "", "draftHash": review?.draftHash ?? "", "loading": loading, "resolving": resolving, "overwriteEnabled": overwrite.isEnabled, "adoptEnabled": adopt.isEnabled, "mode": mode.selectedSegment, "patch": diff.patch, "state": state.stringValue]
    }
}
