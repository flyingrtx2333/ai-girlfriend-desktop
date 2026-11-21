import AppKit
import WebKit
import UniformTypeIdentifiers
import Darwin

@MainActor final class AgentOfficeWindow: AgentSettingsPageController, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    unowned let office: AgentOffice
    private let store: AgentStore
    let taskID: String, files: AgentFiles, file: URL
    private(set) var dirty = false { didSet { if dirty != oldValue { onWorkspaceChange?() } } }
    private(set) var working = false, openedHash = "", openedSignature = "", openedPermissions = 0o644
    private let save = NSButton(title: "保存", target: nil, action: nil), reload = NSButton(title: "重新载入", target: nil, action: nil), saveCopy = NSButton(title: "另存为…", target: nil, action: nil)
    private let body = NSButton(title: "正文", target: nil, action: nil), comments = NSButton(title: "批注", target: nil, action: nil)
    private let state = NSTextField(labelWithString: ""), content = AgentWorkspacePageView(fill: AgentWorkbenchTheme.surface)
    private var web: WKWebView!, server: AgentOfficeHTTP?, base: URL?, snapshot: AgentOfficeSnapshot?
    private var ready = false, closed = false, conflict = false, lastReadOnly: Bool?
    private var recoveredDirty = false, editorRevision = 0, recoveryBaseRevision = 0, lastExportedRevision = 0
    private var documentDirty = false, hasReviewDraft = false
    private var lastExportedView: String?
    private var opening: Task<Void, Error>?, uiTask: Task<Void, Never>?, watchTask: Task<Void, Never>?
    private var shell: CheckedContinuation<Void, Error>?, shellTimeout: Task<Void, Never>?, watcher: DispatchSourceFileSystemObject?
    private var toolEpoch = UUID()
    var onClose: (() -> Void)?
    var onWorkspaceChange: (() -> Void)?
    var workspaceIsClosed: Bool { closed }
    var canPreserveForQuit: Bool { ready && !closed && !working && store.task(taskID).map { $0.sideTask?.retained != false } == true }
    init(office: AgentOffice, store: AgentStore, taskID: String, files: AgentFiles, file: URL) {
        self.office = office; self.store = store; self.taskID = taskID; self.files = files; self.file = file
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 800), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = file.lastPathComponent; window.minSize = NSSize(width: 760, height: 520); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self; window.contentView = content
        for (button, action) in [(save, #selector(saveFile)), (reload, #selector(reloadFile)), (saveCopy, #selector(saveAs)), (body, #selector(reviewLocation(_:))), (comments, #selector(reviewLocation(_:)))] { button.target = self; button.action = action; button.bezelStyle = .texturedRounded; button.controlSize = .small }
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        reload.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "重新载入"); reload.title = ""; reload.toolTip = "重新载入"; reload.setAccessibilityLabel("重新载入办公文件")
        state.font = .systemFont(ofSize: 11); state.textColor = AgentWorkbenchTheme.secondaryText; state.lineBreakMode = .byTruncatingMiddle
        let name = NSTextField(labelWithString: file.lastPathComponent); name.font = .systemFont(ofSize: 12, weight: .medium); name.lineBreakMode = .byTruncatingMiddle; name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        body.setAccessibilityLabel("返回 Word 正文")
        comments.setAccessibilityLabel("查看 Word 批注")
        let review: [NSView] = file.pathExtension.lowercased() == "docx" ? [body, comments] : []
        let heading = NSStackView(views: [name, NSView(), state])
        let actions = NSStackView(views: [reload] + review + [NSView(), saveCopy, save]); heading.spacing = 9; actions.spacing = 9
        let bar = NSStackView(views: [heading, actions]); bar.orientation = .vertical; bar.alignment = .leading; bar.spacing = 8
        for row in [heading, actions] { row.widthAnchor.constraint(equalTo: bar.widthAnchor).isActive = true }
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent(); configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(self, name: "office")
        configuration.userContentController.addUserScript(WKUserScript(source: "document.addEventListener('click',event=>{const input=event.target;if(input instanceof HTMLInputElement&&input.type==='file'&&!input.accept.includes('image')){event.preventDefault();window.webkit.messageHandlers.office.postMessage({action:'open-request'});}},true);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: .zero, configuration: configuration); web.navigationDelegate = self; web.uiDelegate = self; web.setAccessibilityLabel("办公文档编辑器")
        for view in [bar, web!] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 10), web.leadingAnchor.constraint(equalTo: content.leadingAnchor), web.trailingAnchor.constraint(equalTo: content.trailingAnchor), web.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 9), web.bottomAnchor.constraint(equalTo: content.bottomAnchor), state.widthAnchor.constraint(lessThanOrEqualToConstant: 300), reload.widthAnchor.constraint(equalToConstant: 28)])
        updateAvailability()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private var manuallyWritable: Bool { (try? office.task(taskID, root: files.root, manualWrite: true)) != nil }
    private var editingStatus: String {
        if conflict && documentDirty { return "磁盘文件已变化，可另存为新文件" }
        if hasReviewDraft { return conflict ? "原文件已变化，批注草稿已保留" : "批注草稿未提交" }
        return documentDirty ? "未保存" : ""
    }
    func updateAvailability() {
        guard !closed else { return }
        let locked = !manuallyWritable
        let metadata = try? files.entryMetadata(file), sourceWritable = metadata?.kind == "file" && (metadata?.permissions ?? 0) & 0o222 != 0
        save.isEnabled = ready && documentDirty && !locked && !working && !conflict && sourceWritable
        saveCopy.isEnabled = ready && documentDirty && !locked && !working; reload.isEnabled = !working
        body.isEnabled = ready && !working; comments.isEnabled = body.isEnabled
        if ready, lastReadOnly != locked { lastReadOnly = locked; web.evaluateJavaScript("BlueFatFishOffice.setInteractionLocked(\(locked ? "true" : "false"))", in: nil, in: .page) { _ in } }
        if locked && !working && state.stringValue.isEmpty { state.stringValue = "只读" }
        else if !locked && state.stringValue == "只读" { state.stringValue = editingStatus }
        if ready, documentDirty, !locked, !working, !sourceWritable { state.stringValue = metadata?.kind == "missing" ? "原文件已不存在，可另存为新文件" : "原文件只读或不可用，可另存为新文件"; state.toolTip = state.stringValue }
    }
    struct RecoveryState: Codable, Equatable, Sendable {
        var version = 1
        var taskID: String, file: String, sourceRoot: String, openedHash: String, openedSignature: String
        var openedPermissions: Int, editorRevision: Int, dirty: Bool
        var view: String? = nil
        var documentDirty: Bool? = nil
    }
    private static func viewObject(_ value: String, format: String) throws -> [String: Any] {
        let fields: Set<String> = ["version", "format", "zoom", "selection", "scroll"]
        guard value.utf8.count <= (format == "docx" ? 1_200_000 : 65_536), let data = value.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == fields || format == "docx" && Set(object.keys) == fields.union(["review"]),
              object["version"] as? Int == 1, object["format"] as? String == format else { throw PetError("办公位置格式不受支持，原草稿已保留") }
        if let review = object["review"] {
            guard let values = review as? [[String: Any]], (1...2).contains(values.count) else { throw PetError("批注草稿格式无效，原记录已保留") }
        }
        return object
    }
    private func encodedView(_ value: Any?) throws -> String {
        guard let value, JSONSerialization.isValidJSONObject(value) else { throw PetError("办公位置不可读") }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else { throw PetError("办公位置编码失败") }
        _ = try Self.viewObject(text, format: file.pathExtension.lowercased()); return text
    }
    static func recoveryState(_ page: AgentWorkspaceRecovery.Page) throws -> RecoveryState {
        guard page.kind == "office", let object = try JSONSerialization.jsonObject(with: page.state) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "taskID", "file", "sourceRoot", "openedHash", "openedSignature", "openedPermissions", "editorRevision", "dirty", "view", "documentDirty"]) else { throw PetError("办公恢复格式不受支持，原草稿已保留") }
        let value = try JSONDecoder().decode(RecoveryState.self, from: page.state)
        guard value.version == 1, value.taskID == page.taskID, value.dirty == page.dirty, value.editorRevision >= 0,
              value.file.hasPrefix("/"), value.sourceRoot.hasPrefix("/"), !value.file.contains("\0"), !value.sourceRoot.contains("\0"),
              value.file.utf8.count < 8192, value.sourceRoot.utf8.count < 8192,
              URL(fileURLWithPath: value.file).standardizedFileURL.path == value.file,
              URL(fileURLWithPath: value.sourceRoot).standardizedFileURL.path == value.sourceRoot,
              value.sourceRoot == "/" || value.file.hasPrefix(value.sourceRoot + "/"), AgentOffice.supports(value.file),
              value.openedHash.count == 64, value.openedHash.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }),
              !value.openedSignature.isEmpty, value.openedSignature.utf8.count <= 16384, (0...0o7777).contains(value.openedPermissions) else { throw PetError("办公恢复记录版本或来源无效，原草稿已保留") }
        let review = try value.view.map { try viewObject($0, format: URL(fileURLWithPath: value.file).pathExtension.lowercased())["review"] != nil } ?? false
        guard review == (value.documentDirty != nil), !review || value.dirty else { throw PetError("批注草稿状态不一致，原记录已保留") }
        return value
    }
    private func recoveryPage(revision: Int, view: String) throws -> AgentWorkspaceRecovery.Page {
        let (logical, overflow) = recoveryBaseRevision.addingReportingOverflow(revision)
        guard !overflow else { throw PetError("办公恢复版本无效，原草稿已保留") }
        let review = try Self.viewObject(view, format: file.pathExtension.lowercased())["review"] != nil
        let requiresAsset = documentDirty || review
        let value = RecoveryState(taskID: taskID, file: file.path, sourceRoot: files.root.path, openedHash: openedHash, openedSignature: openedSignature, openedPermissions: openedPermissions, editorRevision: logical, dirty: requiresAsset, view: view, documentDirty: review ? documentDirty : nil)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return .init(taskID: taskID, kind: "office", state: try encoder.encode(value), dirty: requiresAsset, asset: nil)
    }
    func persistWorkspaceRecovery(previous: AgentWorkspaceRecovery.Page?, write: (AgentWorkspaceRecovery.Page, URL?) async throws -> Void) async throws {
        if let opening { try await opening.value }
        guard !closed, ready, !working, uiTask == nil, presentingWindow?.hasBlockingDialog != true else { throw PetError("请先完成办公文件的当前操作，恢复草稿尚未保存") }
        try await verifyClean()
        guard let captured = try await evaluate("return await BlueFatFishOffice.captureView()") as? [String: Any],
              let capturedRevision = captured["revision"] as? Int, capturedRevision == editorRevision else { throw PetError("办公内容已变化，正在重新保存位置") }
        let page = try recoveryPage(revision: capturedRevision, view: encodedView(captured["view"]))
        if let previous, previous.kind == page.kind, previous.state == page.state, previous.dirty == page.dirty, (page.dirty ? previous.asset != nil : previous.asset == nil) { return }
        if !page.dirty { try await write(page, nil); return }
        if let previous, let old = try? Self.recoveryState(previous), old.openedHash == openedHash, old.editorRevision == recoveryBaseRevision + capturedRevision, previous.asset != nil {
            var retained = page; retained.asset = previous.asset
            try await write(retained, nil); return
        }
        if !documentDirty, let snapshot, snapshot.hash == openedHash {
            try await write(page, snapshot.file); return
        }
        working = true; updateAvailability()
        defer { working = false; updateAvailability() }
        do {
            let exported = try await exportFile()
            // Keep the export alive until the private streamed copy finishes.
            guard let lastExportedView else { throw PetError("导出的办公位置缺失") }
            try await write(recoveryPage(revision: lastExportedRevision, view: lastExportedView), exported)
            await acknowledge(false)
        } catch { await acknowledge(false); throw error }
    }
    private func applyEditorState(_ value: [String: Any]) {
        let revision = value["revision"] as? Int, changed = revision.map { $0 >= 0 && $0 != editorRevision } == true
        if let revision, revision >= 0 { editorRevision = revision }
        if let changedDocument = (value["dirty"] ?? value["value"]) as? Bool { documentDirty = recoveredDirty || changedDocument }
        if let review = value["hasReviewDraft"] as? Bool { hasReviewDraft = review }
        dirty = documentDirty || hasReviewDraft
        window?.isDocumentEdited = dirty
        if changed { onWorkspaceChange?() }
    }
    func open(recovering loaded: AgentWorkspaceRecovery.LoadedPage? = nil) async throws {
        guard !closed else { throw PetError("办公窗口已关闭") }
        if settingsHostWindow == nil { showWindow(nil); window?.makeKeyAndOrderFront(nil) }
        if ready { return }; if let opening { try await opening.value; return }
        guard !dirty else { throw PetError("此窗口仍有未保存的编辑，请先保留内容或关闭窗口") }
        let recovery = try loaded.map { try Self.recoveryState($0.saved.value) }
        if let recovery { guard recovery.taskID == taskID, recovery.file == file.path, recovery.sourceRoot == files.root.path, (recovery.dirty ? loaded?.asset != nil && loaded?.saved.value.asset != nil : loaded?.saved.value.asset == nil) else { throw PetError("办公恢复附件或来源不匹配") } }
        let view = try recovery?.view.map { try Self.viewObject($0, format: file.pathExtension.lowercased()) }
        let operation = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            working = true; state.stringValue = "正在打开…"; updateAvailability()
            defer { working = false; updateAvailability(); onWorkspaceChange?() }
            let files = self.files, file = self.file
            let pinned: AgentOfficeSnapshot
            if recovery?.dirty == true, let asset = loaded?.asset, let hash = loaded?.saved.value.asset?.hash {
                pinned = try await Task.detached(priority: .userInitiated) { try AgentOffice.recoverySnapshot(asset: asset, hash: hash, file: file) }.value
            } else { pinned = try await Task.detached(priority: .userInitiated) { try AgentOffice.snapshot(files: files, file: file) }.value }
            guard !closed, !Task.isCancelled else { try? FileManager.default.removeItem(at: pinned.folder); throw CancellationError() }
            let previous = snapshot; snapshot = pinned
            server?.stop(); server = nil
            if let previous { try? FileManager.default.removeItem(at: previous.folder) }
            guard let assets = Bundle.main.resourceURL?.appendingPathComponent("web/office") else { throw PetError("办公编辑器资源缺失") }
            let server = try await Task.detached { try AgentOfficeHTTP(assets: assets, document: pinned.file) }.value
            guard !closed, !Task.isCancelled else { server.stop(); throw CancellationError() }
            self.server = server; base = try await server.start()
            try await withCheckedThrowingContinuation { continuation in
                self.shell = continuation
                self.shellTimeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                    self?.finishShell(.failure(PetError("办公编辑器资源未就绪，请重新载入")))
                }
                self.web.load(URLRequest(url: self.base!))
            }
            _ = try await evaluate("return await BlueFatFishOffice.load(url,name,locked)", args: ["url": base!.appendingPathComponent("document").absoluteString, "name": file.lastPathComponent, "locked": !manuallyWritable])
            guard !closed else { throw CancellationError() }
            editorRevision = 0; lastExportedRevision = 0; lastExportedView = nil
            if let recovery, recovery.dirty {
                openedHash = recovery.openedHash; openedSignature = recovery.openedSignature; openedPermissions = recovery.openedPermissions
                recoveryBaseRevision = recovery.editorRevision; recoveredDirty = recovery.documentDirty ?? true
                documentDirty = recoveredDirty; hasReviewDraft = view?["review"] != nil
                let signature = openedSignature, hash = openedHash
                conflict = await Task.detached { (try? files.entryMetadata(file).signature) != signature || (try? files.fileHash(file, maximum: AgentOffice.maximum)) != hash }.value
                state.stringValue = conflict ? editingStatus : hasReviewDraft ? "已恢复批注草稿" : "已恢复未保存内容"
            } else {
                openedHash = pinned.hash; openedSignature = pinned.signature; openedPermissions = pinned.permissions
                recoveryBaseRevision = 0; recoveredDirty = false; documentDirty = false; hasReviewDraft = false; conflict = false; state.stringValue = ""
            }
            if let view {
                if recovery?.dirty == true || recovery?.openedHash == pinned.hash {
                    _ = try await evaluate("return await BlueFatFishOffice.restoreView(view,focus)", args: ["view": view, "focus": isPageVisible])
                    if isPageVisible { presentingWindow?.makeFirstResponder(web) }
                } else { state.stringValue = "原文件已变化，上次位置未恢复" }
            }
            ready = true; dirty = documentDirty || hasReviewDraft; lastReadOnly = nil; window?.isDocumentEdited = dirty; state.toolTip = state.stringValue; watch()
        }
        opening = operation
        do { try await operation.value; opening = nil }
        catch { opening = nil; if !closed { ready = false; state.stringValue = error.localizedDescription }; throw error }
    }
    private func finishShell(_ result: Result<Void, Error>) { let pending = shell; shell = nil; shellTimeout?.cancel(); shellTimeout = nil; pending?.resume(with: result) }
    private func evaluate(_ code: String, args: [String: Any] = [:]) async throws -> Any? {
        guard !closed else { throw CancellationError() }
        do {
            let value = try await web.callAsyncJavaScript(code, arguments: args, in: nil, contentWorld: .page)
            try Task.checkCancellation(); guard !closed else { throw CancellationError() }; return value
        } catch {
            let native = error as NSError
            if let message = native.userInfo["WKJavaScriptExceptionMessage"] as? String {
                var details = native.userInfo; details[NSLocalizedDescriptionKey] = "办公操作未完成：" + String(message.prefix(1000))
                throw NSError(domain: native.domain, code: native.code, userInfo: details)
            }
            throw error
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !closed, message.frameInfo.isMainFrame, let base, message.frameInfo.request.url?.scheme == base.scheme, message.frameInfo.request.url?.host == base.host, message.frameInfo.request.url?.port == base.port,
              let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "shell-ready": finishShell(.success(()))
        case "dirty", "review-draft":
            applyEditorState(body)
            if !working { state.stringValue = editingStatus }; updateAvailability()
            if action == "review-draft" { onWorkspaceChange?() }
        case "view-change": onWorkspaceChange?()
        case "save-request": saveFile()
        case "open-request": chooseFile()
        case "error":
            state.stringValue = String((body["message"] as? String ?? "办公编辑器错误").prefix(1000))
            if body["recoverable"] as? Bool != true { ready = false }; updateAvailability()
        default: break
        }
    }
    func prepareForTool() async throws {
        try await verifyClean()
        guard !dirty else { throw PetError("请先保存或关闭未保存的办公编辑，再继续任务") }
        _ = try office.task(taskID, root: files.root)
        let files = self.files, file = self.file, signature = openedSignature, expected = openedHash
        let changed = try await Task.detached { try files.entryMetadata(file).signature != signature || files.fileHash(file, maximum: AgentOffice.maximum) != expected }.value
        if changed { ready = false; try await open() }
    }
    func verifyClean() async throws {
        guard !working, ready else { throw PetError("办公文件正在处理，请稍候") }
        guard let result = try await evaluate("return await BlueFatFishOffice.verifyClean()") as? [String: Any] else { throw PetError("办公文件状态不可用") }
        applyEditorState(result); updateAvailability()
    }
    func inspect(_ request: [String: Any] = [:]) async throws -> [String: Any] {
        guard ready else { throw PetError("办公文件尚未打开") }
        let allowed = request.filter { ["offset", "limit", "sheet", "range"].contains($0.key) }
        guard let result = try await evaluate("return await BlueFatFishOffice.inspect(request)", args: ["request": allowed]) as? [String: Any] else { throw PetError("办公文件读取结果无效") }; return result
    }
    func applyAndSave(_ request: [String: Any], expected: String) async throws {
        guard !working, !dirty, ready, expected == openedHash else { throw PetError("办公文件已有未保存更改，请重新读取") }
        working = true; state.stringValue = "正在修改…"; updateAvailability(); let epoch = toolEpoch
        defer { working = false; updateAvailability(); onWorkspaceChange?() }
        do {
            guard let result = try await evaluate("return await BlueFatFishOffice.edit(request,true)", args: ["request": request]) as? [String: Any] else { throw PetError("编辑器未返回实际修改结果") }
            guard result["ok"] as? Bool == true else {
                let failure = result["failure"] as? [String: Any] ?? [:]
                throw AgentOfficeEditError(code: failure["code"] as? String ?? "unknown", message: failure["message"] as? String ?? "办公编辑未应用")
            }
            guard epoch == toolEpoch else { throw CancellationError() }
            try await writeExport(agent: true, expected: expected)
        } catch { state.stringValue = error is CancellationError ? "修改保留在窗口，尚未保存" : error.localizedDescription; throw error }
    }
    private func exportFile() async throws -> URL {
        guard let snapshot, let result = try await evaluate("return await BlueFatFishOffice.beginExport()") as? [String: Any], let count = result["bytes"] as? Int, count > 0, count <= AgentOffice.maximum,
              let revision = result["revision"] as? Int, revision >= 0 else { throw PetError("办公文件导出无效") }
        lastExportedRevision = revision
        lastExportedView = try encodedView(result["view"])
        let output = snapshot.folder.appendingPathComponent("export." + file.pathExtension)
        let temporary = try AgentFiles(workspace: snapshot.folder.path)
        try temporary.writeData(Data(), to: output, permissions: 0o600)
        let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
        var offset = 0
        while offset < count {
            try Task.checkCancellation()
            let length = min(1024 * 1024, count - offset)
            guard let encoded = try await evaluate("return BlueFatFishOffice.exportChunk(offset,length)", args: ["offset": offset, "length": length]) as? String,
                  let bytes = Data(base64Encoded: encoded), bytes.count == length else { throw PetError("办公文件导出片段无效") }
            if offset == 0 { guard bytes.starts(with: [80, 75]) else { throw PetError("导出结果不是Office文件") } }
            try handle.write(contentsOf: bytes); offset += bytes.count
        }
        try handle.synchronize(); return output
    }
    private func acknowledge(_ saved: Bool) async {
        // Always release an actual export, including after native I/O failed.
        guard !closed else { return }
        if let value = try? await web.callAsyncJavaScript("return BlueFatFishOffice.finishExport(saved)", arguments: ["saved": saved], in: nil, contentWorld: .page) as? [String: Any] {
            if saved { recoveredDirty = false }; applyEditorState(value)
        }
    }
    private func writeExport(agent: Bool, expected: String) async throws {
        do {
            let exported = try await exportFile()
            let written = try await office.recordWrite(self, source: exported, agent: agent, expected: expected)
            openedHash = written.0; openedSignature = written.1; conflict = false
            await acknowledge(true); state.stringValue = dirty ? editingStatus : "已保存"
        } catch {
            await acknowledge(false); state.stringValue = error is CancellationError ? "修改保留在窗口，尚未保存" : error.localizedDescription
            throw error
        }
    }
    func saveDocument() async throws {
        guard ready, !working else { throw PetError("办公文件正在处理") }
        if hasReviewDraft && !documentDirty { throw PetError("先提交批注，再保存 Word 文件") }
        _ = try office.task(taskID, root: files.root, manualWrite: true)
        working = true; state.stringValue = "正在保存…"; updateAvailability()
        defer { working = false; updateAvailability(); onWorkspaceChange?() }
        try await writeExport(agent: false, expected: openedHash)
    }
    @objc private func saveFile() {
        guard uiTask == nil, !working else { return }
        uiTask = Task { [weak self] in guard let self else { return }; defer { uiTask = nil }; do { try await saveDocument() } catch { state.stringValue = error.localizedDescription } }
    }
    @objc private func reviewLocation(_ sender: NSButton) {
        guard ready, !working, uiTask == nil else { return }
        let showComments = sender === comments
        uiTask = Task { [weak self] in
            guard let self else { return }
            defer { uiTask = nil; onWorkspaceChange?() }
            do {
                let notice = try await evaluate("return await BlueFatFishOffice.navigateDocxReview(showComments)", args: ["showComments": showComments]) as? String ?? ""
                if !notice.isEmpty { state.stringValue = notice }
                else if state.stringValue.hasPrefix("暂无可查看的批注") { state.stringValue = editingStatus; updateAvailability() }
            } catch { state.stringValue = error.localizedDescription }
            state.toolTip = state.stringValue
        }
    }
    @objc private func reloadFile() {
        guard !working, uiTask == nil else { return }
        uiTask = Task { [weak self] in guard let self else { return }; defer { uiTask = nil; onWorkspaceChange?() }; do { if ready { try await verifyClean() }; guard canDiscard() else { return }; recoveredDirty = false; dirty = false; window?.isDocumentEdited = false; ready = false; try await open() } catch { state.stringValue = error.localizedDescription } }
    }
    @objc private func saveAs() {
        guard ready, !working, manuallyWritable, let window = presentingWindow else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: file.pathExtension) ?? .data]; panel.directoryURL = file.deletingLastPathComponent(); panel.nameFieldStringValue = file.deletingPathExtension().lastPathComponent + " 副本." + file.pathExtension
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }; defer { self.onWorkspaceChange?() }
            guard response == .OK, let target = panel.url else { return }
            self.uiTask = Task { @MainActor in
                self.working = true; self.updateAvailability(); defer { self.working = false; self.uiTask = nil; self.updateAvailability(); self.onWorkspaceChange?() }
                do {
                    _ = try self.office.task(self.taskID, root: self.files.root, manualWrite: true)
                    let (_, safe) = try self.office.file(target.path, taskID: self.taskID)
                    guard safe != self.file, safe.pathExtension.lowercased() == self.file.pathExtension.lowercased(), try self.files.entryMetadata(safe).kind == "missing" else { throw PetError("请使用相同格式的新文件名") }
                    let exported = try await self.exportFile(), files = self.files, source = try AgentFiles(workspace: exported.deletingLastPathComponent().path)
                    _ = try await self.store.projectChanges.observe(taskID: self.taskID, origin: "办公另存为", paths: [safe.path], requireCheckpoint: true) {
                        _ = try self.office.task(self.taskID, root: files.root, manualWrite: true, allowCapture: true)
                        _ = try await Task.detached { try files.copyFile(exported, from: source, to: safe, permissions: 0o644, expectedTarget: "missing", maximum: AgentOffice.maximum) }.value
                        return AgentToolResult(text: "已另存为 " + files.relative(safe), artifacts: [safe.path])
                    }
                    await self.acknowledge(false)
                    self.store.update(self.taskID) { if !$0.artifacts.contains(safe.path) { $0.artifacts.append(safe.path) } }
                    self.state.stringValue = "副本已保存，原文件仍有未保存更改"
                } catch { await self.acknowledge(false); self.state.stringValue = error.localizedDescription }
            }
        }
    }
    private func chooseFile() {
        guard !working, let window = presentingWindow else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = AgentOffice.formats.compactMap { UTType(filenameExtension: $0) }; panel.directoryURL = files.root; panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }; defer { self.onWorkspaceChange?() }
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in do { _ = try await self.office.show(url.path, taskID: self.taskID, location: self.settingsHostWindow == nil ? .window : .workspace) } catch { self.state.stringValue = error.localizedDescription } }
        }
    }
    private func watch() {
        watcher?.cancel(); watcher = nil
        let fd = Darwin.open(file.deletingLastPathComponent().path, O_EVTONLY); guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setCancelHandler { Darwin.close(fd) }
        source.setEventHandler { [weak self] in
            guard let self, !closed else { return }; watchTask?.cancel()
            watchTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                guard let self, !closed else { return }
                let files = self.files, file = self.file, expected = openedSignature
                let changed = await Task.detached { (try? files.entryMetadata(file).signature) != expected }.value
                guard !Task.isCancelled, !working else { return }
                if changed { conflict = true; state.stringValue = dirty ? "磁盘文件已变化，可另存为新文件" : "磁盘文件已变化，请重新载入"; updateAvailability() }
            }
        }
        source.resume(); watcher = source
    }
    func cancelToolOperation() { toolEpoch = UUID() }
    private func canDiscard() -> Bool {
        guard dirty else { return true }
        return AgentUnsavedChanges.discard("放弃未保存的更改？", detail: file.lastPathComponent)
    }
    func prepareWorkspaceNavigation() -> Bool {
        guard !working || opening != nil && !dirty, uiTask == nil else { state.stringValue = "正在处理，请稍候"; return false }; return true
    }
    override func prepareForWorkspaceClose() async -> Bool {
        if closed { return true }
        if working { return opening != nil && !dirty }
        guard uiTask == nil, presentingWindow?.hasBlockingDialog != true else { return false }
        var accepted = false
        defer {
            if !accepted {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed else { return }
                    try? self.office.onPresent?(self, self.settingsHostWindow == nil ? .window : .workspace); self.presentingWindow?.makeKeyAndOrderFront(nil)
                }
            }
        }
        do { if ready { try await verifyClean() }; accepted = canDiscard(); return accepted }
        catch { state.stringValue = error.localizedDescription; return false }
    }
    override func settingsDidAppear() {
        updateAvailability()
        if ready, !working, isPageVisible {
            presentingWindow?.makeFirstResponder(web)
            web.evaluateJavaScript("void BlueFatFishOffice.focusEditor()", in: nil, in: .page) { _ in }
        }
    }
    override func settingsWillLeave() { finishClose() }
    func workspaceReadback() async -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled else { return [:] }
        let controls = [save, reload, saveCopy, body, comments].filter { $0.superview != nil && !$0.isHiddenOrHasHiddenAncestor }
        let frames = controls.map { content.convert($0.bounds, from: $0) }
        var value: [String: Any] = ["taskID": taskID, "file": file.path, "dirty": dirty, "working": working, "closed": closed, "ready": ready, "openedHash": openedHash, "state": state.stringValue,
            "loopbackURL": base?.absoluteString ?? "", "snapshot": snapshot?.folder.path ?? "", "saveEnabled": save.isEnabled,
            "checks": ["officeUsesTaskWindow": settingsHostWindow != nil && pageContentView?.window === settingsHostWindow, "officeHasNoFloatingWindow": window?.isVisible != true, "officeToolbarFits": !frames.isEmpty && frames.allSatisfy { content.bounds.insetBy(dx: -1, dy: -1).contains($0) }, "officeEditorHasUsableSize": web.bounds.width >= 450 && web.bounds.height >= 250]]
        if ready, !working, !closed {
            value["documentDirty"] = documentDirty
            value["hasReviewDraft"] = hasReviewDraft
            value["editor"] = try? await evaluate("return BlueFatFishOffice.state()")
            value["view"] = try? await evaluate("return await BlueFatFishOffice.captureView()")
            if file.pathExtension.lowercased() == "docx" {
                value["selectionInfo"] = try? await evaluate("return await BlueFatFishOffice.selectionInfo()")
                value["review"] = try? await evaluate("return BlueFatFishOffice.docxReviewGeometry()")
            }
            if file.pathExtension.lowercased() == "docx", let page = try? await evaluate("const p=document.querySelector('.paged-editor__page')?.getBoundingClientRect(); return {width:innerWidth,pageWidth:p?.width??0,pageLeft:p?.left??0,pageRight:p?.right??0,dark:!!document.querySelector('.docx-editor.dark')}") as? [String: Any] {
                value["page"] = page
                var checks = value["checks"] as? [String: Bool] ?? [:]
                checks["officePageFitsWidth"] = (page["pageWidth"] as? Double ?? 0) > 0 && (page["pageRight"] as? Double ?? .infinity) <= (page["width"] as? Double ?? 0) + 1 && (page["pageLeft"] as? Double ?? -1) >= -1
                checks["officeChromeMatchesAppearance"] = (page["dark"] as? Bool) == (presentingWindow?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
                value["checks"] = checks
            }
        }
        return value
    }
    func checkWorkspaceEdit(_ request: [String: Any], verify: Bool = true) async throws {
        guard AgentTaskWorkspace.readbackEnabled else { throw PetError("仅限工作区验收") }
        _ = try await evaluate("return await BlueFatFishOffice.edit(request)", args: ["request": request]); if verify { try await verifyClean() }
    }
    func checkWorkspaceView(_ value: [String: Any]? = nil) async throws -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled else { throw PetError("仅限工作区验收") }
        if let value { _ = try await evaluate("return await BlueFatFishOffice.restoreView(view)", args: ["view": value]) }
        guard let captured = try await evaluate("return await BlueFatFishOffice.captureView()") as? [String: Any], let view = captured["view"] as? [String: Any] else { throw PetError("办公位置没有实际回读") }
        return view
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if working { if opening != nil && !dirty { finishClose(); return true }; state.stringValue = "正在处理，请稍候"; return false }
        guard uiTask == nil else { return false }
        uiTask = Task { [weak self] in
            guard let self else { return }; defer { uiTask = nil }
            do { if ready { try await verifyClean() }; if canDiscard() { finishClose() } } catch { state.stringValue = error.localizedDescription }
        }; return false
    }
    func finishClose() {
        guard !closed else { return }; closed = true; opening?.cancel(); uiTask?.cancel(); watchTask?.cancel(); watcher?.cancel(); watcher = nil
        finishShell(.failure(CancellationError())); server?.stop(); server = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "office"); web.navigationDelegate = nil; web.uiDelegate = nil; web.stopLoading(); web.loadHTMLString("", baseURL: nil)
        if let snapshot { try? FileManager.default.removeItem(at: snapshot.folder) }; snapshot = nil
        window?.delegate = nil
        if settingsHostWindow != nil { close() } else { window?.close() }
        onClose?(); onClose = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishShell(.failure(error)); state.stringValue = error.localizedDescription }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishShell(.failure(error)); state.stringValue = error.localizedDescription }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { ready = false; finishShell(.failure(PetError("办公编辑器已退出，请重新载入"))); state.stringValue = "办公编辑器已退出，请重新载入"; updateAvailability() }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if let base, url.scheme == base.scheme, url.host == base.host, url.port == base.port, url.path.hasPrefix(base.path), navigationAction.navigationType != .linkActivated { decisionHandler(.allow) }
        else { if navigationAction.navigationType == .linkActivated, ["https", "http"].contains(url.scheme), url.user == nil, url.password == nil { NSWorkspace.shared.open(url) }; decisionHandler(.cancel) }
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard manuallyWritable, !working, let window = presentingWindow else { completionHandler(nil); return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = parameters.allowsMultipleSelection; panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { response in completionHandler(response == .OK ? panel.urls : nil) }
    }
}
