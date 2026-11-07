import AppKit
import WebKit
import UniformTypeIdentifiers
import Darwin

@MainActor final class AgentCanvasAssets: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "runtime", ["/runtime.js", "/style.css"].contains(url.path), url.query == nil, let resources = Bundle.main.resourceURL else { urlSchemeTask.didFailWithError(PetError("画布资源地址无效")); return }
        do {
            let data = try Data(contentsOf: resources.appendingPathComponent("web/canvas" + url.path))
            let mime = url.path.hasSuffix(".js") ? "text/javascript" : "text/css"
            let response = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8")
            urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
        } catch { urlSchemeTask.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

@MainActor final class AgentCanvasWindow: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, NSTextViewDelegate {
    private let canvas: AgentCanvas, taskID: String
    private let picker = NSPopUpButton(), mode = NSSegmentedControl(labels: ["预览", "源码"], trackingMode: .selectOne, target: nil, action: nil), versions = NSPopUpButton(), exports = NSPopUpButton()
    private let save = NSButton(title: "保存", target: nil, action: nil), annotate = NSButton(title: "批注", target: nil, action: nil), reload = NSButton(title: "重新载入", target: nil, action: nil)
    private let content = NSView(), state = NSTextField(labelWithString: ""), editor = NSTextView(), editorScroll = NSScrollView(), preview = NSView()
    private(set) var web: WKWebView!
    private(set) var selectedID: String?
    private var loadedHash: String?, requestedHash: String?, editorHash: String?, dirty = false, closed = false, nativeLoading = false
    private var renderTask: Task<Void, Error>?, uiTask: Task<Void, Never>?, timeout: Task<Void, Never>?, watcher: DispatchSourceFileSystemObject?, watchTask: Task<Void, Never>?
    private var pending: CheckedContinuation<Any, Error>?, generation = UUID(), annotationWindow: AgentBrowserAnnotationWindow?
    private var draftTask: Task<Void, Never>?
    var onClose: (() -> Void)?
    init(canvas: AgentCanvas, taskID: String) {
        self.canvas = canvas; self.taskID = taskID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "画布"; window.minSize = NSSize(width: 640, height: 460); window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua); window.center()
        super.init(window: window); window.delegate = self; window.contentView = content
        picker.setAccessibilityLabel("任务画布"); picker.target = self; picker.action = #selector(changeCanvas); picker.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        picker.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true; picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        mode.selectedSegment = 0; mode.target = self; mode.action = #selector(changeCanvasMode); mode.setAccessibilityLabel("画布视图")
        versions.setAccessibilityLabel("画布历史版本"); versions.target = self; versions.action = #selector(restoreVersion)
        exports.setAccessibilityLabel("导出画布"); exports.addItems(withTitles: ["导出", "交互 HTML…", "TSX 源码…", "当前截图…"]); exports.target = self; exports.action = #selector(exportDocument)
        versions.widthAnchor.constraint(equalToConstant: 64).isActive = true; exports.widthAnchor.constraint(equalToConstant: 68).isActive = true
        for popup in [picker, versions, exports] { popup.controlSize = .small; popup.font = .systemFont(ofSize: 12) }
        for (button, action) in [(save, #selector(saveSource)), (annotate, #selector(beginAnnotation)), (reload, #selector(reloadDocument))] { button.target = self; button.action = action; button.bezelStyle = .texturedRounded; button.controlSize = .small }
        for (button, symbol, label) in [(reload, "arrow.clockwise", "重新载入"), (annotate, "pencil.tip.crop.circle", "批注")] { button.title = ""; button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label); button.toolTip = label; button.setAccessibilityLabel(label); button.widthAnchor.constraint(equalToConstant: 28).isActive = true }
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command; save.isHidden = true
        editor.isRichText = false; editor.allowsUndo = true; editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular); editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true; editor.textContainerInset = NSSize(width: 18, height: 16); editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false; editor.delegate = self; editor.setAccessibilityLabel("画布 TSX 源码")
        editorScroll.documentView = editor; editorScroll.hasVerticalScroller = true; editorScroll.isHidden = true
        state.font = .systemFont(ofSize: 11); state.textColor = .secondaryLabelColor; state.lineBreakMode = .byTruncatingTail
        let toolbar = NSStackView(views: [picker, mode, NSView(), reload, versions, annotate, exports, save]); toolbar.spacing = 8
        for view in [toolbar, preview, editorScroll, state] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 10), toolbar.heightAnchor.constraint(equalToConstant: 30), preview.leadingAnchor.constraint(equalTo: content.leadingAnchor), preview.trailingAnchor.constraint(equalTo: content.trailingAnchor), preview.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10), preview.bottomAnchor.constraint(equalTo: state.topAnchor, constant: -4), editorScroll.leadingAnchor.constraint(equalTo: preview.leadingAnchor), editorScroll.trailingAnchor.constraint(equalTo: preview.trailingAnchor), editorScroll.topAnchor.constraint(equalTo: preview.topAnchor), editorScroll.bottomAnchor.constraint(equalTo: preview.bottomAnchor), state.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), state.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), state.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8), state.heightAnchor.constraint(equalToConstant: 16)])
        resetWeb()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func resetWeb() {
        web?.navigationDelegate = nil; web?.uiDelegate = nil; web?.stopLoading(); web?.removeFromSuperview()
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent(); configuration.preferences.javaScriptCanOpenWindowsAutomatically = false; configuration.setURLSchemeHandler(AgentCanvasAssets(), forURLScheme: "appcanvas")
        web = WKWebView(frame: .zero, configuration: configuration); web.navigationDelegate = self; web.uiDelegate = self; web.setAccessibilityLabel("实际画布预览"); web.translatesAutoresizingMaskIntoConstraints = false; preview.addSubview(web)
        NSLayoutConstraint.activate([web.leadingAnchor.constraint(equalTo: preview.leadingAnchor), web.trailingAnchor.constraint(equalTo: preview.trailingAnchor), web.topAnchor.constraint(equalTo: preview.topAnchor), web.bottomAnchor.constraint(equalTo: preview.bottomAnchor)])
    }
    private static let policy = "default-src 'none'; script-src appcanvas: 'unsafe-eval'; style-src appcanvas: 'unsafe-inline'; img-src data: blob:; font-src data:; connect-src 'none'; frame-src 'none'; worker-src 'none'; object-src 'none'; media-src 'none'; form-action 'none'; base-uri 'none'"
    private static var shell: String { "<!doctype html><html lang=zh-CN><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><meta http-equiv=Content-Security-Policy content=\"" + policy + "\"><link rel=stylesheet href=appcanvas://runtime/style.css><script src=appcanvas://runtime/runtime.js defer></script></head><body><div id=canvas-root></div></body></html>" }
    private func finish(_ result: Result<Any, Error>, token: UUID) {
        guard token == generation, let continuation = pending else { return }; pending = nil; timeout?.cancel(); timeout = nil; continuation.resume(with: result)
    }
    private func awaitResult(_ start: (UUID) -> Void) async throws -> Any {
        try Task.checkCancellation(); guard pending == nil, !closed else { throw PetError("画布正在处理另一操作或已关闭") }
        let requestGeneration = generation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let token = generation; pending = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                    guard let self, token == generation else { return }
                    finish(.failure(PetError("画布未在10秒内完成，请检查源码并重新载入")), token: token); loadedHash = nil; web.stopLoading(); web.loadHTMLString("", baseURL: nil)
                }
                start(token)
            }
        } onCancel: { [weak self] in Task { @MainActor in if self?.generation == requestGeneration { self?.stop() } } }
    }
    private func evaluate(_ code: String, args: [String: Any] = [:], world: WKContentWorld? = nil) async throws -> Any {
        try await awaitResult { token in self.web.callAsyncJavaScript(code, arguments: args, in: nil, in: world ?? .defaultClient) { [weak self] result in self?.finish(result, token: token) } }
    }
    func open(_ id: String) async throws {
        let value = try canvas.source(id, taskID: taskID)
        if selectedID != id {
            guard canLeave() else { throw PetError("请先处理未保存的源码") }; cancelRender(); selectedID = id; loadedHash = nil; editorHash = nil; watch(id)
            if let draft = value.record.draft { editor.string = draft; editorHash = value.record.draftHash; dirty = true; mode.selectedSegment = 1; changeCanvasMode() }
        }
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        refreshCatalog()
        if !dirty, editorHash != value.record.hash { editor.string = value.code; editorHash = value.record.hash; editor.undoManager?.removeAllActions() }
        if loadedHash == value.record.hash { return }
        if requestedHash == value.record.hash, let renderTask { try await renderTask.value; return }
        cancelRender(); requestedHash = value.record.hash; state.stringValue = "正在渲染…"; generation = UUID()
        let operationGeneration = generation
        let operation = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }; resetWeb(); nativeLoading = true
            _ = try await awaitResult { _ in self.web.loadHTMLString(Self.shell, baseURL: URL(string: "appcanvas://runtime/")) }
            _ = try await evaluate("return await BlueFatFishCanvas.render(source)", args: ["source": value.code], world: .page)
            try Task.checkCancellation(); loadedHash = value.record.hash; requestedHash = nil; state.stringValue = ""; refreshCatalog()
        }
        renderTask = operation
        do { try await operation.value; if generation == operationGeneration { renderTask = nil } }
        catch { if generation == operationGeneration { renderTask = nil; requestedHash = nil; state.stringValue = error.localizedDescription }; throw error }
    }
    private func cancelRender() {
        renderTask?.cancel(); renderTask = nil; timeout?.cancel(); timeout = nil
        if let continuation = pending { pending = nil; continuation.resume(throwing: CancellationError()) }
        generation = UUID(); requestedHash = nil; nativeLoading = false; web?.stopLoading()
    }
    func stop() {
        let wasBusy = pending != nil || renderTask != nil
        uiTask?.cancel(); cancelRender()
        if wasBusy { loadedHash = nil; web?.loadHTMLString("", baseURL: nil) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { guard webView === web, nativeLoading else { return }; nativeLoading = false; finish(.success("loaded"), token: generation) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if webView === web { finish(.failure(error), token: generation) } }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if webView === web { finish(.failure(error), token: generation) } }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { guard webView === web else { return }; loadedHash = nil; finish(.failure(PetError("画布预览已退出，请重新载入")), token: generation); state.stringValue = "画布预览已退出，请重新载入" }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme ?? ""
        decisionHandler(nativeLoading && ["about", "appcanvas"].contains(scheme) && navigationAction.navigationType != .linkActivated ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    private func refreshCatalog() {
        let records = canvas.records(taskID); picker.removeAllItems()
        for record in records { picker.addItem(withTitle: record.title); picker.lastItem?.representedObject = record.id }
        if let i = records.firstIndex(where: { $0.id == selectedID }) { picker.selectItem(at: i); window?.title = "画布 · " + records[i].title }
        versions.removeAllItems(); versions.addItem(withTitle: "版本")
        if let record = records.first(where: { $0.id == selectedID }) {
            let formatter = DateFormatter(); formatter.dateFormat = "MM-dd HH:mm:ss"
            for version in record.versions.reversed() { versions.addItem(withTitle: formatter.string(from: version.created) + (version.hash == record.hash ? " · 当前" : "")); versions.lastItem?.representedObject = version.hash }
        }
    }
    private func watch(_ id: String) {
        watcher?.cancel(); watcher = nil
        guard let url = try? canvas.sourceURL(id, taskID: taskID) else { return }
        let descriptor = Darwin.open(url.deletingLastPathComponent().path, O_EVTONLY); guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setCancelHandler { Darwin.close(descriptor) }
        source.setEventHandler { [weak self] in
            guard let self else { return }; watchTask?.cancel()
            watchTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                guard let self, selectedID == id, !closed else { return }
                do {
                    let value = try canvas.source(id, taskID: taskID)
                    guard value.record.hash != loadedHash, value.record.hash != requestedHash else { return }
                    if dirty { state.stringValue = "源码已被其他操作更新，请保留编辑内容后重新载入"; return }
                    try await open(id)
                } catch { state.stringValue = error.localizedDescription }
            }
        }
        source.resume(); watcher = source
    }
    func inspect() async throws -> [String: Any] {
        guard let id = selectedID else { throw PetError("未选择画布") }; try await open(id)
        let result = try await evaluate("""
        const root = document.getElementById('canvas-root');
        const visible = e => { const r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden'; };
        const controls=Array.from(root.querySelectorAll('button,input,select,textarea')).filter(visible).slice(0,60).map(e=>({role:e.tagName.toLowerCase(),label:e.getAttribute('aria-label')||e.innerText||'',value:e.type==='password'?'[受保护]':e.value||'',pressed:e.getAttribute('aria-pressed')}));
        const error=root.querySelector('[data-canvas-error]')?.textContent;
        return {text:root.innerText.slice(0,14000),controls,svg_count:root.querySelectorAll('svg').length,bar_count:root.querySelectorAll('.recharts-bar-rectangle').length,table_row_count:root.querySelectorAll('tbody tr').length,scroll_width:document.documentElement.scrollWidth,viewport:{width:innerWidth,height:innerHeight},...(error?{error}:{} )};
        """)
        guard let value = result as? [String: Any] else { throw PetError("画布实际内容不可读") }; return value
    }
    func screenshot() async throws -> AgentCanvasShot {
        guard let id = selectedID else { throw PetError("未选择画布") }; try await open(id)
        mode.selectedSegment = 0; changeCanvasMode(); let source = try canvas.source(id, taskID: taskID)
        let (image, _) = try await AgentBrowserShot.viewport(web)
        guard try canvas.source(id, taskID: taskID).record.hash == source.record.hash else { throw PetError("截图期间画布源码已变化，请重试") }
        return AgentCanvasShot(image: image, capture: AgentCanvasCapture(canvasID: id, title: source.record.title, sourceHash: source.record.hash))
    }
    @objc private func changeCanvas() { guard let id = picker.selectedItem?.representedObject as? String else { return }; run { try await self.open(id) } }
    @objc private func changeCanvasMode() { let source = mode.selectedSegment == 1; editorScroll.isHidden = !source; preview.isHidden = source; save.isHidden = !source; annotate.isEnabled = !source }
    @objc private func reloadDocument() { guard canLeave(), let id = selectedID else { return }; loadedHash = nil; editorHash = nil; run { try await self.open(id) } }
    @objc private func saveSource() {
        guard let id = selectedID, let hash = editorHash else { return }
        do { _ = try canvas.update(id, source: editor.string, expected: hash, taskID: taskID); dirty = false; draftTask?.cancel(); canvas.saveDraft(nil, hash: nil, id: id, taskID: taskID); editorHash = nil; run { try await self.open(id) } } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func restoreVersion() {
        guard canLeave(), let id = selectedID, let hash = versions.selectedItem?.representedObject as? String else { versions.selectItem(at: 0); return }
        do { let current = try canvas.source(id, taskID: taskID); _ = try canvas.restore(id, version: hash, expected: current.record.hash, taskID: taskID); editorHash = nil; run { try await self.open(id) } } catch { state.stringValue = error.localizedDescription }
        versions.selectItem(at: 0)
    }
    @objc private func beginAnnotation() {
        run {
            let shot = try await self.screenshot()
            let window = AgentBrowserAnnotationWindow(shot: shot.annotationShot) { [weak owner = self] marks, note in
                guard let self = owner else { throw PetError("画布窗口已关闭") }; try await self.canvas.submit(shot, taskID: self.taskID, marks: marks, note: note)
            }
            window.canvas.setAccessibilityLabel("画布批注"); self.annotationWindow = window; window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil)
        }
    }
    @objc private func exportDocument() {
        let kind = exports.indexOfSelectedItem; exports.selectItem(at: 0)
        guard kind > 0, let id = selectedID else { return }
        run {
            let source = try self.canvas.source(id, taskID: self.taskID), data: Data, suffix: String
            if kind == 2 { data = Data((self.dirty ? self.editor.string : source.code).utf8); suffix = ".canvas.tsx" }
            else if kind == 3 { data = try await self.screenshot().annotationShot.png(); suffix = ".png" }
            else { data = try self.exportHTML(source.code); suffix = ".html" }
            let panel = NSSavePanel(); panel.nameFieldStringValue = source.record.title.replacingOccurrences(of: "/", with: "-") + suffix; panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic); self.state.stringValue = "已导出 " + url.lastPathComponent
        }
    }
    func exportHTML(_ source: String) throws -> Data {
        guard let resources = Bundle.main.resourceURL else { throw PetError("画布运行资源不可用") }
        let root = resources.appendingPathComponent("web/canvas"), runtime = try String(contentsOf: root.appendingPathComponent("runtime.js"), encoding: .utf8), css = try String(contentsOf: root.appendingPathComponent("style.css"), encoding: .utf8)
        let data = try JSONSerialization.data(withJSONObject: [source]), encoded = String(decoding: data, as: UTF8.self).dropFirst().dropLast()
        func escape(_ text: String) -> String { text.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive) }
        let policy = Self.policy.replacingOccurrences(of: "script-src appcanvas:", with: "script-src 'unsafe-inline'").replacingOccurrences(of: "style-src appcanvas:", with: "style-src")
        return Data(("<!doctype html><html lang=zh-CN><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><meta http-equiv=Content-Security-Policy content=\"" + policy + "\"><style>" + css + "</style></head><body><div id=canvas-root></div><script>" + escape(runtime) + "</script><script>BlueFatFishCanvas.render(" + escape(String(encoded)) + ")</script></body></html>").utf8)
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        uiTask?.cancel(); uiTask = Task { [weak self] in do { try await action() } catch { if !Task.isCancelled { self?.state.stringValue = error.localizedDescription } } }
    }
    func textDidChange(_ notification: Notification) {
        dirty = true; state.stringValue = "未保存"; draftTask?.cancel()
        guard let id = selectedID else { return }; let text = editor.string, hash = editorHash
        draftTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
            guard let self else { return }; if !canvas.saveDraft(text, hash: hash, id: id, taskID: taskID) { state.stringValue = "源码草稿未保存，请检查大小并另存内容" }
        }
    }
    private func canLeave() -> Bool {
        guard dirty else { return true }; let alert = NSAlert(); alert.messageText = "放弃未保存的源码？"; alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "放弃更改")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }; dirty = false; draftTask?.cancel(); if let id = selectedID { canvas.saveDraft(nil, hash: nil, id: id, taskID: taskID) }; return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { canLeave() }
    func windowWillClose(_ notification: Notification) {
        if dirty, let id = selectedID { canvas.saveDraft(editor.string, hash: editorHash, id: id, taskID: taskID) }
        closed = true; draftTask?.cancel(); stop(); watcher?.cancel(); watchTask?.cancel(); annotationWindow?.close(); web.loadHTMLString("", baseURL: nil); onClose?()
    }
}
