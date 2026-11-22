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
    private let spreadsheetNotes = NSButton(title: "备注", target: nil, action: nil)
    private let spreadsheetThreads = NSButton(title: "评论", target: nil, action: nil)
    private let presentationComments = NSButton(title: "批注", target: nil, action: nil)
    private let state = NSTextField(labelWithString: ""), content = AgentWorkspacePageView(fill: AgentWorkbenchTheme.surface)
    private var web: WKWebView!, server: AgentOfficeHTTP?, base: URL?, snapshot: AgentOfficeSnapshot?
    private var ready = false, closed = false, conflict = false, lastReadOnly: Bool?
    private var spreadsheetNotesLoaded = false, spreadsheetThreadsLoaded = false
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
        for (button, action) in [(save, #selector(saveFile)), (reload, #selector(reloadFile)), (saveCopy, #selector(saveAs)), (body, #selector(reviewLocation(_:))), (comments, #selector(reviewLocation(_:))), (spreadsheetNotes, #selector(toggleSpreadsheetAnnotation(_:))), (spreadsheetThreads, #selector(toggleSpreadsheetAnnotation(_:))), (presentationComments, #selector(togglePresentationComments))] { button.target = self; button.action = action; button.bezelStyle = .texturedRounded; button.controlSize = .small }
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        reload.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "重新载入"); reload.title = ""; reload.toolTip = "重新载入"; reload.setAccessibilityLabel("重新载入办公文件")
        state.font = .systemFont(ofSize: 11); state.textColor = AgentWorkbenchTheme.secondaryText; state.lineBreakMode = .byTruncatingMiddle
        let name = NSTextField(labelWithString: file.lastPathComponent); name.font = .systemFont(ofSize: 12, weight: .medium); name.lineBreakMode = .byTruncatingMiddle; name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        body.setAccessibilityLabel("返回 Word 正文")
        comments.setAccessibilityLabel("查看 Word 批注")
        spreadsheetNotes.setAccessibilityLabel("查看 Excel 单元格备注")
        spreadsheetThreads.setAccessibilityLabel("查看 Excel 单元格评论")
        presentationComments.setAccessibilityLabel("查看 PowerPoint 批注")
        let review: [NSView]
        switch file.pathExtension.lowercased() {
        case "docx": review = [body, comments]
        case "xlsx": review = [spreadsheetNotes, spreadsheetThreads]
        case "pptx": review = [presentationComments]
        default: review = []
        }
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
        spreadsheetNotes.isEnabled = ready && !working && uiTask == nil
        spreadsheetThreads.isEnabled = spreadsheetNotes.isEnabled
        presentationComments.isEnabled = spreadsheetNotes.isEnabled
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
        guard value.utf8.count <= 1_200_000, let data = value.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PetError("办公位置格式不受支持，原草稿已保留")
        }
        let provided = Set(object.keys)
        guard provided == fields || format == "docx" && provided == fields.union(["review"]) ||
                format == "xlsx" && fields.isSubset(of: provided) && provided.isSubset(of: fields.union(["notes", "threads"])) ||
                format == "pptx" && provided == fields.union(["presentationReview"]),
              object["version"] as? Int == 1, object["format"] as? String == format else { throw PetError("办公位置格式不受支持，原草稿已保留") }
        if let review = object["review"] {
            guard let values = review as? [[String: Any]], (1...2).contains(values.count) else { throw PetError("批注草稿格式无效，原记录已保留") }
        }
        if let thread = object["threads"] {
            guard let comments = thread as? [String: Any], let drafts = comments["drafts"] as? [[String: Any]], drafts.count <= 5_000 else {
                throw PetError("评论草稿格式无效，原记录已保留")
            }
        }
        if let review = object["presentationReview"] {
            guard let review = review as? [String: Any], let drafts = review["drafts"] as? [[String: Any]], drafts.count <= 5_000 else {
                throw PetError("演示文稿批注草稿无效，原记录已保留")
            }
        } else if format == "pptx", value.utf8.count > 65_536 { throw PetError("演示文稿位置过长，原草稿已保留") }
        return object
    }
    private static func containsReviewDraft(_ view: [String: Any]?) -> Bool {
        if view?["review"] != nil { return true }
        return ["threads", "presentationReview"].contains { key in
            let review = view?[key] as? [String: Any]
            return (review?["drafts"] as? [[String: Any]])?.isEmpty == false
        }
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
        let review = try containsReviewDraft(value.view.map { try viewObject($0, format: URL(fileURLWithPath: value.file).pathExtension.lowercased()) })
        guard review == (value.documentDirty != nil), !review || value.dirty else { throw PetError("批注草稿状态不一致，原记录已保留") }
        return value
    }
    private func recoveryPage(revision: Int, view: String) throws -> AgentWorkspaceRecovery.Page {
        let (logical, overflow) = recoveryBaseRevision.addingReportingOverflow(revision)
        guard !overflow else { throw PetError("办公恢复版本无效，原草稿已保留") }
        let review = try Self.containsReviewDraft(Self.viewObject(view, format: file.pathExtension.lowercased()))
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
            let previous = snapshot; snapshot = pinned; spreadsheetNotesLoaded = false; spreadsheetThreadsLoaded = false
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
                documentDirty = recoveredDirty; hasReviewDraft = Self.containsReviewDraft(view)
                let signature = openedSignature, hash = openedHash
                conflict = await Task.detached { (try? files.entryMetadata(file).signature) != signature || (try? files.fileHash(file, maximum: AgentOffice.maximum)) != hash }.value
                state.stringValue = conflict ? editingStatus : hasReviewDraft ? "已恢复批注草稿" : "已恢复未保存内容"
            } else {
                openedHash = pinned.hash; openedSignature = pinned.signature; openedPermissions = pinned.permissions
                recoveryBaseRevision = 0; recoveredDirty = false; documentDirty = false; hasReviewDraft = false; conflict = false; state.stringValue = ""
            }
            if let view {
                if recovery?.dirty == true || recovery?.openedHash == pinned.hash {
                    if view["notes"] != nil { try await loadSpreadsheetNotes(pinned) }
                    if view["threads"] != nil { try await loadSpreadsheetThreads(pinned) }
                    if view["presentationReview"] != nil, isPageVisible { presentingWindow?.makeFirstResponder(web) }
                    _ = try await evaluate("return await BlueFatFishOffice.restoreView(view,focus)", args: ["view": view, "focus": isPageVisible])
                    if view["presentationReview"] == nil, isPageVisible { presentingWindow?.makeFirstResponder(web) }
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
        try handle.synchronize()
        try handle.close()
        if file.pathExtension.lowercased() == "xlsx", let edits = result["noteEdits"] {
            let required: Set<String> = ["sheet", "cell", "original", "text"]
            guard let changes = edits as? [[String: Any]], changes.count <= 5_000,
                  changes.allSatisfy({ Set($0.keys) == required || Set($0.keys) == required.union(["rich"]) }) else {
                throw PetError("备注编辑记录无法读取，原草稿已保留")
            }
            if !changes.isEmpty {
                let data = try JSONSerialization.data(withJSONObject: changes)
                guard data.count <= 8_000_000 else { throw PetError("备注编辑超过保存大小，原草稿已保留") }
                try await AgentSpreadsheetNotes.apply(JSONDecoder().decode([AgentSpreadsheetNoteEdit].self, from: data), to: output)
            }
        }
        if file.pathExtension.lowercased() == "xlsx", let edits = result["threadEdits"] {
            let fields: Set<String> = ["id", "sheet", "cell", "version", "opening", "resolved", "replies"]
            guard let changes = edits as? [[String: Any]], changes.count <= 5_000,
                  changes.allSatisfy({ Set($0.keys) == fields }) else { throw PetError("评论修改无法读取，草稿已保留") }
            if !changes.isEmpty {
                let data = try JSONSerialization.data(withJSONObject: changes)
                guard data.count <= 8_000_000 else { throw PetError("评论超过保存大小，草稿已保留") }
                try await AgentSpreadsheetNotes.applyThreads(JSONDecoder().decode([AgentSpreadsheetThreadEdit].self, from: data), to: output)
            }
        }
        if file.pathExtension.lowercased() == "pptx" {
            if let edits = result["legacyReplies"] {
                guard let changes = edits as? [[String: Any]], changes.count <= 5_000 else {
                    throw PetError("旧版批注回复无法读取，原草稿已保留")
                }
                if !changes.isEmpty {
                    let data = try JSONSerialization.data(withJSONObject: changes)
                    guard data.count <= 2_000_000 else { throw PetError("旧版批注回复超过保存大小，原草稿已保留") }
                    try await AgentPowerPointComments.attachLegacyReplies(
                        JSONDecoder().decode([AgentPowerPointComments.LegacyReplyLink].self, from: data), in: output)
                }
            }
            if result["modernPresentationCommentsEdited"] as? Bool == true {
                try await AgentPowerPointComments.ensureSlideLinks(in: output)
            }
        }
        return output
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
        if hasReviewDraft && !documentDirty {
            switch file.pathExtension.lowercased() {
            case "xlsx": throw PetError("先添加回复或评论，再保存工作簿")
            case "pptx": throw PetError("先添加批注或回复，再保存演示文稿")
            default: throw PetError("先提交批注，再保存 Word 文件")
            }
        }
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
    private func loadSpreadsheetNotes(_ pinned: AgentOfficeSnapshot) async throws {
        guard !spreadsheetNotesLoaded else { return }
        let catalog: AgentSpreadsheetNoteCatalog, warning: String
        do { catalog = try await AgentSpreadsheetNotes.catalog(pinned.file); warning = "" }
        catch is CancellationError { throw CancellationError() }
        catch {
            catalog = .init(notes: [], creationUnavailable: [], author: "")
            warning = "无法读取单元格备注"; spreadsheetNotes.toolTip = error.localizedDescription
        }
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog))
        _ = try await evaluate("BlueFatFishOffice.setSpreadsheetNotes(catalog,warning); return true", args: ["catalog": payload, "warning": warning])
        spreadsheetNotesLoaded = true
    }
    private func loadSpreadsheetThreads(_ pinned: AgentOfficeSnapshot) async throws {
        guard !spreadsheetThreadsLoaded else { return }
        let catalog: AgentSpreadsheetThreadCatalog
        do { catalog = try await AgentSpreadsheetNotes.threadCatalog(pinned.file) }
        catch is CancellationError { throw CancellationError() }
        catch {
            catalog = .init(threads: [], incomplete: true, author: "", creation: [:], recipients: [])
            spreadsheetThreads.toolTip = error.localizedDescription
        }
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog))
        _ = try await evaluate("BlueFatFishOffice.setSpreadsheetThreads(catalog); return true", args: ["catalog": payload])
        spreadsheetThreadsLoaded = true
    }
    @objc private func toggleSpreadsheetAnnotation(_ sender: NSButton) {
        guard ready, !working, uiTask == nil, let snapshot else { return }
        let showThreads = sender === spreadsheetThreads
        uiTask = Task { [weak self] in
            guard let self else { return }
            working = true
            updateAvailability()
            defer { working = false; uiTask = nil; updateAvailability(); onWorkspaceChange?() }
            do {
                if showThreads { try await loadSpreadsheetThreads(snapshot) }
                else { try await loadSpreadsheetNotes(snapshot) }
                presentingWindow?.makeFirstResponder(web)
                _ = try await evaluate(showThreads ? "return BlueFatFishOffice.toggleSpreadsheetThreads()" : "return BlueFatFishOffice.toggleSpreadsheetNotes()")
            } catch { state.stringValue = error.localizedDescription }
        }
    }
    @objc private func togglePresentationComments() {
        guard ready, !working, uiTask == nil else { return }
        uiTask = Task { [weak self] in
            guard let self else { return }
            updateAvailability()
            defer { uiTask = nil; updateAvailability(); onWorkspaceChange?() }
            do {
                presentingWindow?.makeFirstResponder(web)
                _ = try await evaluate("return await BlueFatFishOffice.togglePresentationComments()")
            } catch { state.stringValue = error.localizedDescription }
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
        let controls = [save, reload, saveCopy, body, comments, spreadsheetNotes, spreadsheetThreads, presentationComments].filter { $0.superview != nil && !$0.isHiddenOrHasHiddenAncestor }
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
    private var spreadsheetReadback: Bool {
        AgentTaskWorkspace.readbackEnabled && (CommandLine.arguments.contains("--spreadsheet-notes-check") ||
            CommandLine.arguments.contains("--spreadsheet-threads-check"))
    }
    func checkSpreadsheetNotes(show: Bool = false, address: String? = nil, newAddress: String? = nil, edit: String? = nil,
                               range: Range<Int>? = nil, action: String? = nil) async throws -> [String: Any] {
        guard spreadsheetReadback,
              file.pathExtension.lowercased() == "xlsx" else { throw PetError("仅限备注验收") }
        if show {
            spreadsheetNotes.performClick(nil)
            await uiTask?.value
        }
        let args: [String: Any] = ["address": address as Any? ?? NSNull(), "newAddress": newAddress as Any? ?? NSNull(),
                                   "edit": edit as Any? ?? NSNull(), "range": range.map { [$0.lowerBound, $0.upperBound] } as Any? ?? NSNull(),
                                   "action": action as Any? ?? NSNull()]
        guard let value = try await evaluate("""
            const panel = document.querySelector('.spreadsheet-notes');
            if (!panel || panel.hidden) throw new Error('备注栏没有显示');
            const list = panel.querySelector('.spreadsheet-notes-list');
            const text = panel.querySelector('.spreadsheet-note-body');
            const settled = () => new Promise(resolve => setTimeout(resolve, 75));
            const select = async ([from, to]) => {
              const point = index => {
                const walker = document.createTreeWalker(text, NodeFilter.SHOW_TEXT);
                for (let node = walker.nextNode(); node; node = walker.nextNode()) {
                  if (index <= node.length) return [node, index];
                  index -= node.length;
                }
                const body = text.firstElementChild ?? text;
                return [body, body.childNodes.length];
              };
              text.focus();
              getSelection().setBaseAndExtent(...point(from), ...point(to));
              await settled();
            };
            if (address !== null) {
              const row = Array.from(list.querySelectorAll('button')).find(b => b.title === address);
              if (!row) throw new Error('目标备注没有显示');
              row.click();
            }
            if (newAddress !== null) {
              const button = panel.querySelector('.spreadsheet-note-add');
              if (!button || button.disabled) throw new Error('新建备注按钮不可用');
              button.click();
              const deadline = Date.now() + 5000;
              while (Date.now() < deadline && (list.querySelector('[aria-pressed="true"]')?.title !== newAddress || document.activeElement !== text)) {
                await new Promise(resolve => setTimeout(resolve, 25));
              }
              if (list.querySelector('[aria-pressed="true"]')?.title !== newAddress || document.activeElement !== text) {
                throw new Error(panel.querySelector('[role="status"]').textContent || '新备注未绑定原单元格');
              }
            }
            if (range !== null) await select(range);
            if (edit !== null) {
              if (text.closest('[hidden]') || text.getAttribute('aria-readonly') === 'true') throw new Error('备注不可编辑');
              if (range === null) await select([0, text.textContent.length]);
              if (edit.includes('\\n')) {
                const clipboardData = new DataTransfer();
                clipboardData.setData('text/plain', edit);
                text.dispatchEvent(new ClipboardEvent('paste', { clipboardData, bubbles: true, cancelable: true }));
              } else if (!document.execCommand(edit ? 'insertText' : 'delete', false, edit)) {
                throw new Error('备注输入失败');
              }
              await settled();
              if (range === null) await select([0, Math.min(2, edit.length)]);
            }
            if (action !== null) {
              text.focus();
              const button = panel.querySelector('.spreadsheet-note-format button[data-format="' + action + '"]');
              if (button && !button.disabled) button.click();
              else {
                const key = { undo: 'z', redo: 'z', boldKey: 'b', enter: 'Enter' }[action];
                if (!key) throw new Error('备注格式操作不可用');
                text.dispatchEvent(new KeyboardEvent('keydown', { key, code: key.length === 1 ? 'Key' + key.toUpperCase() : key,
                  bubbles: true, cancelable: true, metaKey: action !== 'enter', shiftKey: action === 'redo' }));
              }
              await settled();
            }
            const frame = panel.getBoundingClientRect(), grid = document.getElementById('office-root').getBoundingClientRect();
            const marks = selector => Array.from(text.querySelectorAll(selector), node => node.textContent);
            return {entries: Array.from(list.querySelectorAll('button')).map(b => b.title), value: text.textContent,
                    author: panel.querySelector('.spreadsheet-note-author').textContent,
                    focused: document.activeElement === text, readOnly: text.getAttribute('aria-readonly') === 'true',
                    bold: marks('strong'), italic: marks('em'), underline: marks('u'),
                    doubleUnderline: marks('.spreadsheet-note-double u'), selection: getSelection().toString(),
                    grid: grid.width, left: frame.left, right: frame.right, width: innerWidth};
            """, args: args) as? [String: Any] else { throw PetError("无法读取当前备注栏") }
        return value
    }
    func checkSpreadsheetNotesImage(_ file: URL) async throws {
        guard spreadsheetReadback else { throw PetError("仅限表格批注验收") }
        try await checkEditorImage(file)
    }
    private func checkEditorImage(_ file: URL) async throws {
        let image: NSImage = try await withCheckedThrowingContinuation { done in
            web.takeSnapshot(with: nil) { image, error in
                if let image { done.resume(returning: image) }
                else { done.resume(throwing: error ?? PetError("无法取得办公编辑器图像")) }
            }
        }
        guard let tiff = image.tiffRepresentation, let bits = NSBitmapImageRep(data: tiff),
              let png = bits.representation(using: .png, properties: [:]) else { throw PetError("办公编辑器图像无法编码") }
        try png.write(to: file, options: .atomic)
    }
    func checkPresentationAppearance(action: String = "", image: URL? = nil) async throws -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled, CommandLine.arguments.contains("--presentation-comments"),
              file.pathExtension.lowercased() == "pptx" else { throw PetError("仅限演示文稿外观验收") }
        let value = try await evaluate(#"""
            const root = document.getElementById('office-root');
            const toolbar = root.querySelector('[data-testid="pptx-editor-toolbar"]');
            const canvas = root.querySelector('[data-testid="pptx-slide-canvas"]');
            const notes = root.querySelector('[data-testid="pptx-notes-textarea"]');
            const rail = root.querySelector('aside');
            const pane = document.getElementById('presentation-comments');
            const stage = canvas?.closest('[role=application]') ?? canvas?.parentElement;
            if (!toolbar || !canvas || !notes || !rail || !stage) throw new Error('演示文稿编辑区尚未就绪');
            const more = toolbar.querySelector('[data-testid="pptx-toolbar-more"]');
            if (action === 'menu') more?.click();
            if (action === 'notes') notes.focus();
            if (action === 'lock' || action === 'unlock') await BlueFatFishOffice.setInteractionLocked(action === 'lock');
            if (action) await new Promise(resolve => requestAnimationFrame(resolve));
            function describe(element) {
              const style = getComputedStyle(element), rect = element.getBoundingClientRect();
              return {tag: element.tagName, role: element.getAttribute('role') ?? '', label: element.getAttribute('aria-label') ?? '',
                testID: element.getAttribute('data-testid') ?? '', background: style.backgroundColor, color: style.color,
                border: style.borderTopColor, width: rect.width, height: rect.height};
            }
            function background(element) {
              for (let node = element; node; node = node.parentElement) {
                const value = getComputedStyle(node).backgroundColor;
                if (value !== 'rgba(0, 0, 0, 0)' && value !== 'transparent') return value;
              }
              return '';
            }
            function lightness(value) {
              const rgb = (value.match(/\d+(?:\.\d+)?/g) ?? []).slice(0,3).map(s => Number(s) / 255);
              if (rgb.length !== 3) return -1;
              const [r,g,b] = rgb.map(v => v <= .04045 ? v / 12.92 : Math.pow((v + .055) / 1.055, 2.4));
              return .2126*r + .7152*g + .0722*b;
            }
            const surfaces = { toolbar: toolbar.parentElement, stage, rail, notesPanel: notes.parentElement, notesField: notes, annotations: pane };
            const colors = Object.fromEntries(Object.entries(surfaces).map(([key,node]) => [key, background(node)]));
            function contrast(text, backgroundColor) {
              const ink = lightness(text), base = lightness(backgroundColor);
              return (Math.max(ink,base)+.05) / (Math.min(ink,base)+.05);
            }
            const noteStyle = getComputedStyle(notes);
            const menu = document.getElementById(more?.getAttribute('aria-controls') || '') ?? document.querySelector('[role=menu]');
            const choice = menu?.querySelector('[role^=menuitem]:not([aria-disabled=true]):not([disabled])') ?? menu;
            const menuBounds = menu?.getBoundingClientRect();
            let menuEndReachable = false;
            if (menu) {
              const previousScroll = menu.scrollTop;
              menu.scrollTop = menu.scrollHeight;
              menuEndReachable = menu.scrollHeight - menu.clientHeight - menu.scrollTop <= 1;
              menu.scrollTop = previousScroll;
            }
            const encoded = new TextEncoder().encode(canvas.toDataURL());
            const canvasHash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', encoded)),
              v => v.toString(16).padStart(2, '0')).join('');
            const trail = element => {
              const values = [];
              for (let node = element; node && node !== root; node = node.parentElement) values.push(describe(node));
              return values;
            };
            return {
              prefersDark: matchMedia('(prefers-color-scheme: dark)').matches, colors,
              surfaceLightness: Object.fromEntries(Object.entries(colors).map(([key,value]) => [key, lightness(value)])),
              notesContrast: contrast(noteStyle.color, colors.notesField), notesColor: noteStyle.color,
              notesFocusRing: document.activeElement === notes && noteStyle.outlineStyle !== 'none' && parseFloat(noteStyle.outlineWidth) >= 2,
              locked: root.inert, reviewLocked: pane.querySelector('textarea').readOnly,
              canvasHash, canvasBackground: getComputedStyle(canvas).backgroundColor,
              canvasWidth: canvas.width, canvasHeight: canvas.height, notesValue: notes.value,
              editorWidth: root.clientWidth, viewportWidth: innerWidth,
              focus: document.activeElement?.getAttribute('aria-label') ?? '',
              selectedSlides: Array.from(rail.querySelectorAll('[aria-current]'), el => el.getAttribute('aria-label') ?? el.textContent),
              trace: { toolbar:trail(toolbar), canvas:trail(canvas), rail:trail(rail), notes:trail(notes) },
              menuTriggers: Array.from(toolbar.querySelectorAll('[aria-haspopup=menu]'), button =>
                ({label:button.getAttribute('aria-label') ?? '', testID:button.getAttribute('data-testid') ?? '',
                  expanded:button.getAttribute('aria-expanded') ?? '', width:button.getBoundingClientRect().width})),
              menu: menu && choice ? { lightness: lightness(background(menu)), contrast: contrast(getComputedStyle(choice).color, background(menu)),
                endReachable: menuEndReachable, inside: menuBounds.left >= -1 && menuBounds.right <= innerWidth + 1 &&
                  menuBounds.top >= -1 && menuBounds.bottom <= innerHeight + 1 } : null
            };
            """#, args: ["action": action])
        if let image { try await checkEditorImage(image) }
        guard let detail = value as? [String: Any] else { throw PetError("演示文稿外观未回读") }
        return detail
    }
    func checkPresentationComments(action: String = "", text: String? = nil, image: URL? = nil) async throws -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled, CommandLine.arguments.contains("--presentation-comments"),
              file.pathExtension.lowercased() == "pptx" else { throw PetError("仅限演示文稿批注验收") }
        if action == "toggle" {
            presentationComments.performClick(nil)
            await uiTask?.value
        }
        let value = try await evaluate("""
            const panel = document.getElementById('presentation-comments');
            const input = panel.querySelector('textarea'), submit = panel.querySelector('.spreadsheet-thread-reply');
            const add = panel.querySelector('.spreadsheet-note-add'), heading = panel.querySelector('.spreadsheet-thread-header');
            const [resolve, cancel] = heading.querySelectorAll('button');
            const rows = Array.from(panel.querySelectorAll('.spreadsheet-thread-list button'));
            if (action === 'new') add.click();
            if (action === 'select' || action === 'select-last') {
              const matches = rows.filter(row => row.querySelector('span').textContent.startsWith(text));
              matches.at(action === 'select-last' ? -1 : 0)?.click();
            }
            if (action === 'draft') {
              if (input.readOnly) throw new Error('Draft input is read-only');
              input.focus(); input.value = text; input.setSelectionRange(2, 6, 'backward');
              input.dispatchEvent(new InputEvent('input', {bubbles: true}));
            }
            if (action === 'submit') submit.click();
            if (action === 'key') input.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', metaKey:true, bubbles:true}));
            if (action === 'status') resolve.click();
            if (action === 'cancel') cancel.click();
            const body = panel.querySelector('.spreadsheet-thread-messages');
            return {
              visible: !panel.hidden,
              slide: heading.querySelector('strong').textContent,
              draft: input.value, range: [input.selectionStart, input.selectionEnd, input.selectionDirection],
              focused: document.activeElement === input, submit: !submit.disabled, readOnly: input.readOnly,
              newEnabled: !add.disabled, status: resolve.hidden ? '' : resolve.textContent,
              notice: panel.querySelector('[role=status]').textContent,
              messages: Array.from(body.querySelectorAll('article'), row => ({
                author: row.querySelector('strong').textContent, text: row.querySelector('p').textContent,
                reply: row.hasAttribute('data-parent')
              })),
              dark: matchMedia('(prefers-color-scheme: dark)').matches,
              slideLabelsStayOnOneLine: Array.from(panel.querySelectorAll('.spreadsheet-thread-list strong'))
                .every(label => label.getBoundingClientRect().height <= 20),
              panelWidth: panel.getBoundingClientRect().width, viewportWidth: innerWidth,
              bodyHeight: body.clientHeight, submitBottom: submit.getBoundingClientRect().bottom,
              viewportHeight: innerHeight,
            };
            """, args: ["action": action, "text": text as Any? ?? NSNull()])
        if let image { try await checkEditorImage(image) }
        guard let report = value as? [String: Any] else { throw PetError("批注窗口未回读") }
        return report
    }
    func checkSpreadsheetThread(show: Bool = false, address: String? = nil, text: String? = nil, action: String? = nil,
                                newAddress: String? = nil, blocked: Bool = false) async throws -> [String: Any] {
        guard CommandLine.arguments.contains("--spreadsheet-threads-check"), AgentTaskWorkspace.readbackEnabled,
              file.pathExtension.lowercased() == "xlsx" else { throw PetError("仅限评论验收") }
        if show {
            spreadsheetThreads.performClick(nil)
            await uiTask?.value
        }
        let args: [String: Any] = ["address": address as Any? ?? NSNull(), "text": text as Any? ?? NSNull(),
                                   "action": action as Any? ?? NSNull(), "newAddress": newAddress as Any? ?? NSNull(), "blocked": blocked]
        guard let value = try await evaluate("""
            const pane = document.querySelector('.spreadsheet-threads');
            if (!pane || pane.hidden) throw new Error('评论栏没有显示');
            const rows = () => [...pane.querySelectorAll('.spreadsheet-thread-list button')];
            const active = () => rows().find(item => item.getAttribute('aria-pressed') === 'true');
            const reply = pane.querySelector('textarea');
            const resolve = pane.querySelector('.spreadsheet-thread-resolve');
            const send = pane.querySelector('.spreadsheet-thread-reply');
            const status = pane.querySelector('[role=status]');
            if (newAddress !== null) {
                const create = pane.querySelector('.spreadsheet-thread-add');
                if (create.disabled) throw new Error('新建评论不可用');
                create.click();
                const reached = () => blocked ? status.textContent === '此单元格已有备注'
                  : active()?.title === newAddress && document.activeElement === reply;
                const deadline = Date.now() + 5000;
                while (!reached() && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 25));
                if (!reached()) throw new Error(status.textContent || '新评论未定位至原单元格');
            }
            if (address !== null) {
                const row = rows().find(item => item.title === address);
                if (!row) throw new Error('评论位置没有显示');
                row.click();
            }
            if (text !== null) {
                if (reply.readOnly || reply.closest('[hidden]')) throw new Error('当前评论无法回复');
                reply.focus(); reply.value = text; reply.setSelectionRange(0, 4);
                reply.dispatchEvent(new InputEvent('input', {bubbles: true}));
            }
            if (action !== null) {
                const button = action === 'cancel' ? pane.querySelector('.spreadsheet-thread-cancel') : action === 'resolve' ? resolve : send;
                if (button.disabled || button.closest('[hidden]')) throw new Error('评论操作不可用');
                if (action === 'key') {
                    reply.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', metaKey: true, bubbles: true, cancelable: true }));
                } else button.click();
            }
            const frame = pane.getBoundingClientRect(), grid = document.getElementById('office-root').getBoundingClientRect();
            const articles = [...pane.querySelectorAll('.spreadsheet-thread-message')];
            return { entries: rows().map(item => item.title), resolved: rows().filter(item => item.dataset.resolved === 'true').map(item => item.title),
              selected: active()?.title ?? '', threadID: active()?.dataset.thread ?? '', status: status.textContent,
              messages: articles.map(item => ({ id: item.dataset.id, parent: item.dataset.parent ?? '', author: item.querySelector('strong').textContent,
                text: item.querySelector('p').textContent, time: item.querySelector('time').dateTime })),
              draft: reply.value, selection: [reply.selectionStart, reply.selectionEnd], focused: document.activeElement === reply,
              canReply: !reply.readOnly && !reply.closest('[hidden]'), canResolve: !resolve.disabled && !resolve.closest('[hidden]'),
              canSubmit: !send.disabled, composerAction: send.textContent,
              showingNotes: !document.querySelector('.spreadsheet-notes').hidden,
              grid: grid.width, left: frame.left, right: frame.right, width: innerWidth };
            """, args: args) as? [String: Any] else { throw PetError("无法读取当前评论栏") }
        return value
    }
    func checkSpreadsheetMentions(insert: String? = nil, range: Range<Int>? = nil, choose: String? = nil,
                                  key: String? = nil) async throws -> [String: Any] {
        guard spreadsheetReadback, CommandLine.arguments.contains("--spreadsheet-threads-mentions"),
              file.pathExtension.lowercased() == "xlsx" else { throw PetError("仅限评论提及验收") }
        let args: [String: Any] = ["insert": insert as Any? ?? NSNull(), "range": range.map { [$0.lowerBound, $0.upperBound] } as Any? ?? NSNull(),
                                   "choose": choose as Any? ?? NSNull(), "key": key as Any? ?? NSNull()]
        guard let value = try await evaluate("""
            const panel = document.querySelector('.spreadsheet-threads');
            if (!panel || panel.hidden) throw new Error('评论栏没有显示');
            const input = panel.querySelector('textarea'), picker = panel.querySelector('.spreadsheet-mention-picker');
            const options = () => [...picker.querySelectorAll('[role=option]')];
            const email = button => button.querySelector('small')?.textContent ?? button.querySelector('span').textContent;
            if (range !== null || insert !== null) {
              if (input.readOnly || input.closest('[hidden]')) throw new Error('当前评论无法编辑');
              input.focus();
              if (range !== null) input.setSelectionRange(...range);
              if (insert !== null) {
                if (range === null) input.setSelectionRange(input.value.length, input.value.length);
                if (!document.execCommand('insertText', false, insert)) throw new Error('未能插入评论文字');
              }
            }
            if (choose !== null) {
              const choice = options().find(button => email(button) === choose);
              if (!choice || picker.hidden) throw new Error('联系人未在候选列表中');
              choice.click();
            }
            if (key !== null) {
              input.dispatchEvent(new KeyboardEvent('keydown', {key, bubbles: true, cancelable: true}));
            }
            return { value: input.value, pickerOpen: !picker.hidden, focused: document.activeElement === input,
              selection: [input.selectionStart, input.selectionEnd],
              bodyHeight: panel.querySelector('.spreadsheet-thread-messages').clientHeight,
              pickerTop: picker.getBoundingClientRect().top, pickerBottom: picker.getBoundingClientRect().bottom,
              inputTop: input.getBoundingClientRect().top,
              options: options().map(button => ({ name: button.querySelector('span').textContent, email: email(button),
                selected: button.getAttribute('aria-selected') === 'true' })),
              marks: [...panel.querySelectorAll('.spreadsheet-message-mention')].map(span => ({
                text: span.textContent, person: span.dataset.person, recipient: span.title, message: span.closest('article').dataset.id
              }))
            };
            """, args: args) as? [String: Any] else { throw PetError("无法读取评论提及") }
        return value
    }
    func checkSpreadsheetNoteVisible(sheet: String, cell: String) async throws -> Bool {
        guard spreadsheetReadback else { throw PetError("仅限备注验收") }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try await evaluate("return await BlueFatFishOffice.spreadsheetNoteVisible(sheet,cell)", args: ["sheet": sheet, "cell": cell]) as? Bool == true { return true }
            try await Task.sleep(for: .milliseconds(70))
        }
        return false
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
