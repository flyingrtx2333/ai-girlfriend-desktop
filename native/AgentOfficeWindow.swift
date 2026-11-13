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
    private let state = NSTextField(labelWithString: ""), content = AgentWorkspacePageView(fill: AgentWorkbenchTheme.surface)
    private var web: WKWebView!, server: AgentOfficeHTTP?, base: URL?, snapshot: AgentOfficeSnapshot?
    private var ready = false, closed = false, conflict = false, lastReadOnly: Bool?
    private var opening: Task<Void, Error>?, uiTask: Task<Void, Never>?, watchTask: Task<Void, Never>?
    private var shell: CheckedContinuation<Void, Error>?, shellTimeout: Task<Void, Never>?, watcher: DispatchSourceFileSystemObject?
    private var toolEpoch = UUID()
    var onClose: (() -> Void)?
    var onWorkspaceChange: (() -> Void)?
    var workspaceIsClosed: Bool { closed }
    init(office: AgentOffice, store: AgentStore, taskID: String, files: AgentFiles, file: URL) {
        self.office = office; self.store = store; self.taskID = taskID; self.files = files; self.file = file
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 800), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = file.lastPathComponent; window.minSize = NSSize(width: 760, height: 520); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self; window.contentView = content
        for (button, action) in [(save, #selector(saveFile)), (reload, #selector(reloadFile)), (saveCopy, #selector(saveAs))] { button.target = self; button.action = action; button.bezelStyle = .texturedRounded; button.controlSize = .small }
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        reload.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "重新载入"); reload.title = ""; reload.toolTip = "重新载入"; reload.setAccessibilityLabel("重新载入办公文件")
        state.font = .systemFont(ofSize: 11); state.textColor = AgentWorkbenchTheme.secondaryText; state.lineBreakMode = .byTruncatingMiddle
        let name = NSTextField(labelWithString: file.lastPathComponent); name.font = .systemFont(ofSize: 12, weight: .medium); name.lineBreakMode = .byTruncatingMiddle; name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let heading = NSStackView(views: [name, NSView(), state]), actions = NSStackView(views: [reload, NSView(), saveCopy, save]); heading.spacing = 9; actions.spacing = 9
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
    func updateAvailability() {
        guard !closed else { return }
        let locked = !manuallyWritable
        save.isEnabled = ready && dirty && !locked && !working && !conflict
        saveCopy.isEnabled = ready && dirty && !locked && !working; reload.isEnabled = !working
        if ready, lastReadOnly != locked { lastReadOnly = locked; web.evaluateJavaScript("BlueFatFishOffice.setInteractionLocked(\(locked ? "true" : "false"))", in: nil, in: .page) { _ in } }
        if locked && !working && state.stringValue.isEmpty { state.stringValue = "只读" }
        else if !locked && state.stringValue == "只读" { state.stringValue = dirty ? "未保存" : "" }
    }
    func open() async throws {
        guard !closed else { throw PetError("办公窗口已关闭") }
        if settingsHostWindow == nil { showWindow(nil); window?.makeKeyAndOrderFront(nil) }
        if ready { return }; if let opening { try await opening.value; return }
        guard !dirty else { throw PetError("此窗口仍有未保存的编辑，请先保留内容或关闭窗口") }
        let operation = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            working = true; state.stringValue = "正在打开…"; updateAvailability()
            defer { working = false; updateAvailability() }
            let files = self.files, file = self.file
            let pinned = try await Task.detached(priority: .userInitiated) { try AgentOffice.snapshot(files: files, file: file) }.value
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
            openedHash = pinned.hash; openedSignature = pinned.signature; openedPermissions = pinned.permissions
            ready = true; conflict = false; dirty = false; lastReadOnly = nil; window?.isDocumentEdited = false; state.stringValue = ""; watch()
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
        case "dirty":
            dirty = body["value"] as? Bool == true; window?.isDocumentEdited = dirty
            if !working { state.stringValue = conflict ? "磁盘文件已变化，可另存为新文件" : dirty ? "未保存" : "" }; updateAvailability()
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
        dirty = result["dirty"] as? Bool == true; window?.isDocumentEdited = dirty; updateAvailability()
    }
    func inspect(_ request: [String: Any] = [:]) async throws -> [String: Any] {
        guard ready else { throw PetError("办公文件尚未打开") }
        let allowed = request.filter { ["offset", "limit", "sheet", "range"].contains($0.key) }
        guard let result = try await evaluate("return await BlueFatFishOffice.inspect(request)", args: ["request": allowed]) as? [String: Any] else { throw PetError("办公文件读取结果无效") }; return result
    }
    func applyAndSave(_ request: [String: Any], expected: String) async throws {
        guard !working, !dirty, ready, expected == openedHash else { throw PetError("办公文件已有未保存更改，请重新读取") }
        working = true; state.stringValue = "正在修改…"; updateAvailability(); let epoch = toolEpoch
        defer { working = false; updateAvailability() }
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
        guard let snapshot, let result = try await evaluate("return await BlueFatFishOffice.beginExport()") as? [String: Any], let count = result["bytes"] as? Int, count > 0, count <= AgentOffice.maximum else { throw PetError("办公文件导出无效") }
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
            dirty = value["dirty"] as? Bool == true; window?.isDocumentEdited = dirty
        }
    }
    private func writeExport(agent: Bool, expected: String) async throws {
        do {
            let exported = try await exportFile()
            let written = try await office.recordWrite(self, source: exported, agent: agent, expected: expected)
            openedHash = written.0; openedSignature = written.1; conflict = false
            await acknowledge(true); state.stringValue = dirty ? "未保存" : "已保存"
        } catch {
            await acknowledge(false); state.stringValue = error is CancellationError ? "修改保留在窗口，尚未保存" : error.localizedDescription
            throw error
        }
    }
    func saveDocument() async throws {
        guard ready, !working else { throw PetError("办公文件正在处理") }
        _ = try office.task(taskID, root: files.root, manualWrite: true)
        working = true; state.stringValue = "正在保存…"; updateAvailability()
        defer { working = false; updateAvailability() }
        try await writeExport(agent: false, expected: openedHash)
    }
    @objc private func saveFile() {
        guard uiTask == nil, !working else { return }
        uiTask = Task { [weak self] in guard let self else { return }; defer { uiTask = nil }; do { try await saveDocument() } catch { state.stringValue = error.localizedDescription } }
    }
    @objc private func reloadFile() {
        guard !working, uiTask == nil else { return }
        uiTask = Task { [weak self] in guard let self else { return }; defer { uiTask = nil }; do { if ready { try await verifyClean() }; guard canDiscard() else { return }; dirty = false; window?.isDocumentEdited = false; ready = false; try await open() } catch { state.stringValue = error.localizedDescription } }
    }
    @objc private func saveAs() {
        guard ready, !working, manuallyWritable, let window = presentingWindow else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: file.pathExtension) ?? .data]; panel.directoryURL = file.deletingLastPathComponent(); panel.nameFieldStringValue = file.deletingPathExtension().lastPathComponent + " 副本." + file.pathExtension
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let target = panel.url, let self else { return }
            self.uiTask = Task { @MainActor in
                self.working = true; self.updateAvailability(); defer { self.working = false; self.uiTask = nil; self.updateAvailability() }
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
            guard response == .OK, let url = panel.url, let self else { return }
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
        guard uiTask == nil, presentingWindow?.attachedSheet == nil else { return false }
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
    override func settingsDidAppear() { updateAvailability() }
    override func settingsWillLeave() { finishClose() }
    func workspaceReadback() async -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled else { return [:] }
        let controls = [save, reload, saveCopy].filter { !$0.isHiddenOrHasHiddenAncestor }
        let frames = controls.map { content.convert($0.bounds, from: $0) }
        var value: [String: Any] = ["taskID": taskID, "file": file.path, "dirty": dirty, "working": working, "closed": closed, "ready": ready, "openedHash": openedHash, "state": state.stringValue,
            "loopbackURL": base?.absoluteString ?? "", "snapshot": snapshot?.folder.path ?? "", "saveEnabled": save.isEnabled,
            "checks": ["officeUsesTaskWindow": settingsHostWindow != nil && pageContentView?.window === settingsHostWindow, "officeHasNoFloatingWindow": window?.isVisible != true, "officeToolbarFits": !frames.isEmpty && frames.allSatisfy { content.bounds.insetBy(dx: -1, dy: -1).contains($0) }, "officeEditorHasUsableSize": web.bounds.width >= 450 && web.bounds.height >= 250]]
        if ready, !working, !closed {
            value["editor"] = try? await evaluate("return BlueFatFishOffice.state()")
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
    func checkWorkspaceEdit(_ request: [String: Any]) async throws {
        guard AgentTaskWorkspace.readbackEnabled else { throw PetError("仅限工作区验收") }
        _ = try await evaluate("return await BlueFatFishOffice.edit(request)", args: ["request": request]); try await verifyClean()
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
