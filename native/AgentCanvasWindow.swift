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

@MainActor final class AgentCanvasWindow: AgentSettingsPageController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, NSTextViewDelegate {
    private let canvas: AgentCanvas
    let taskID: String
    private let picker = NSPopUpButton(), mode = NSSegmentedControl(labels: ["预览", "源码"], trackingMode: .selectOne, target: nil, action: nil), versions = NSPopUpButton(), exports = NSPopUpButton()
    private let save = NSButton(title: "保存", target: nil, action: nil), annotate = NSButton(title: "批注", target: nil, action: nil), reload = NSButton(title: "重新载入", target: nil, action: nil)
    private let content = AgentWorkspacePageView(fill: AgentWorkbenchTheme.surface), state = NSTextField(labelWithString: ""), editor = NSTextView(), editorScroll = NSScrollView(), preview = NSView()
    private(set) var web: WKWebView!
    private(set) var selectedID: String?
    private var loadedHash: String?, requestedHash: String?, editorHash: String?, closed = false, nativeLoading = false
    private var dirty = false { didSet { if dirty != oldValue { onWorkspaceChange?() } } }
    private var renderTask: Task<Void, Error>?, uiTask: Task<Void, Never>?, timeout: Task<Void, Never>?, watcher: DispatchSourceFileSystemObject?, watchTask: Task<Void, Never>?
    private var pending: CheckedContinuation<Any, Error>?, generation = UUID()
    private var annotation: (editor: AgentBrowserAnnotationWindow, sourceHash: String)?
    private var capturingAnnotation = false
    private var draftTask: Task<Void, Never>?
    private var skillWindow: AgentCanvasSkillWindow?
    var onClose: (() -> Void)?
    var onWorkspaceChange: (() -> Void)?
    var workspaceHasUnsavedChanges: Bool { dirty || recoveryAnnotation?.hasPendingChanges == true || recoverySkillForm?.hasPendingChanges == true }
    var recoveryAnnotation: AgentBrowserAnnotationWindow? {
        guard let editor = annotation?.editor, !editor.workspaceIsClosed else { return nil }
        return editor
    }
    var recoverySkillForm: AgentCanvasSkillWindow? { skillWindow }
    var workspaceIsClosed: Bool { closed }
    var canPreserveForQuit: Bool {
        !closed && !capturingAnnotation && selectedID != nil && canvas.canPreserveForQuit(taskID) &&
            recoveryAnnotation?.canPreserveForQuit != false && recoverySkillForm?.canPreserveForQuit != false
    }
    init(canvas: AgentCanvas, taskID: String) {
        self.canvas = canvas; self.taskID = taskID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "画布"; window.minSize = NSSize(width: 640, height: 460); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self; window.contentView = content
        picker.setAccessibilityLabel("任务画布"); picker.target = self; picker.action = #selector(changeCanvas); picker.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        picker.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true; picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        mode.selectedSegment = 0; mode.target = self; mode.action = #selector(changeCanvasMode); mode.setAccessibilityLabel("画布视图")
        versions.setAccessibilityLabel("画布历史版本"); versions.target = self; versions.action = #selector(restoreVersion)
        exports.setAccessibilityLabel("导出画布"); exports.addItems(withTitles: ["导出", "交互 HTML…", "TSX 源码…", "当前截图…", "打包为 Skill…"]); exports.target = self; exports.action = #selector(exportDocument)
        versions.widthAnchor.constraint(equalToConstant: 64).isActive = true; exports.widthAnchor.constraint(equalToConstant: 68).isActive = true
        for popup in [picker, versions, exports] { popup.controlSize = .small; popup.font = .systemFont(ofSize: 12) }
        for (button, action) in [(save, #selector(saveSource)), (annotate, #selector(beginAnnotation)), (reload, #selector(reloadDocument))] { button.target = self; button.action = action; button.bezelStyle = .texturedRounded; button.controlSize = .small }
        for (button, symbol, label) in [(reload, "arrow.clockwise", "重新载入"), (annotate, "pencil.tip.crop.circle", "批注")] { button.title = ""; button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label); button.toolTip = label; button.setAccessibilityLabel(label); button.widthAnchor.constraint(equalToConstant: 28).isActive = true }
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command; save.isHidden = true
        editor.isRichText = false; editor.allowsUndo = true; editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular); editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true; editor.textContainerInset = NSSize(width: 18, height: 16); editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false; editor.delegate = self; editor.setAccessibilityLabel("画布 TSX 源码")
        editorScroll.documentView = editor; editorScroll.hasVerticalScroller = true; editorScroll.isHidden = true
        editorScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(recoveryViewChanged(_:)), name: NSView.boundsDidChangeNotification, object: editorScroll.contentView)
        editor.drawsBackground = false; editor.textColor = .labelColor; editorScroll.drawsBackground = false; editorScroll.scrollerStyle = .overlay
        state.font = .systemFont(ofSize: 11); state.textColor = AgentWorkbenchTheme.secondaryText; state.lineBreakMode = .byTruncatingTail
        let primary = NSStackView(views: [picker, mode, NSView(), reload]), secondary = NSStackView(views: [versions, annotate, exports, NSView(), save]); primary.spacing = 8; secondary.spacing = 8
        let toolbar = NSStackView(views: [primary, secondary]); toolbar.orientation = .vertical; toolbar.alignment = .leading; toolbar.spacing = 8
        for row in [primary, secondary] { row.widthAnchor.constraint(equalTo: toolbar.widthAnchor).isActive = true }
        for view in [toolbar, preview, editorScroll, state] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 10), preview.leadingAnchor.constraint(equalTo: content.leadingAnchor), preview.trailingAnchor.constraint(equalTo: content.trailingAnchor), preview.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10), preview.bottomAnchor.constraint(equalTo: state.topAnchor, constant: -4), editorScroll.leadingAnchor.constraint(equalTo: preview.leadingAnchor), editorScroll.trailingAnchor.constraint(equalTo: preview.trailingAnchor), editorScroll.topAnchor.constraint(equalTo: preview.topAnchor), editorScroll.bottomAnchor.constraint(equalTo: preview.bottomAnchor), state.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), state.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), state.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8), state.heightAnchor.constraint(equalToConstant: 16)])
        resetWeb()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    struct RecoveryState: Codable, Sendable {
        struct Annotation: Codable, Sendable {
            var sourceHash: String
            var draft: AgentBrowserRecoveryState.Annotation
        }
        var version = 1
        var taskID: String, canvasID: String
        var mode: Int, selectionLocation: Int, selectionLength: Int
        var sourceScrollY: Double
        var annotation: Annotation?
        var skill: AgentCanvasSkillWindow.Draft?
    }
    static func recoveryState(_ page: AgentWorkspaceRecovery.Page) throws -> RecoveryState {
        guard page.kind == "canvas", page.asset == nil,
              let object = try JSONSerialization.jsonObject(with: page.state) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "taskID", "canvasID", "mode", "selectionLocation", "selectionLength", "sourceScrollY", "annotation", "skill"]) else { throw PetError("画布恢复格式不受支持，原草稿已保留") }
        if let raw = object["annotation"], !(raw is NSNull) {
            guard let fields = raw as? [String: Any], Set(fields.keys) == ["sourceHash", "draft"], let draft = fields["draft"] else {
                throw PetError("画布批注恢复格式无效，原草稿已保留")
            }
            try AgentBrowserRecoveryState.Annotation.validateFields(draft)
        }
        if let raw = object["skill"], !(raw is NSNull) { try AgentCanvasSkillWindow.Draft.validateFields(raw) }
        let value = try JSONDecoder().decode(RecoveryState.self, from: page.state)
        guard value.version == 1, value.taskID == page.taskID, UUID(uuidString: value.taskID) != nil, UUID(uuidString: value.canvasID) != nil,
              [0, 1].contains(value.mode), (0...256_000).contains(value.selectionLocation), (0...256_000).contains(value.selectionLength),
              value.sourceScrollY.isFinite, (0...1_000_000_000).contains(value.sourceScrollY) else { throw PetError("画布恢复版本或选择范围无效，原草稿已保留") }
        if let saved = value.annotation {
            let draft = saved.draft
            try draft.validate()
            guard saved.sourceHash.count == 64, saved.sourceHash.allSatisfy(\.isHexDigit),
                  draft.source.tabID == value.canvasID, draft.source.url == "canvas://" + value.canvasID, draft.source.method == "canvas",
                  draft.elementTargets == nil, draft.elementTool == nil, !draft.dirty || page.dirty else {
                throw PetError("画布批注的来源或版本不匹配，原草稿已保留")
            }
        }
        if let skill = value.skill {
            try skill.validate(taskID: value.taskID, canvasID: value.canvasID)
            guard value.annotation == nil, !skill.edited || page.dirty else { throw PetError("画布打包草稿的状态无效，原记录已保留") }
        }
        return value
    }
    func captureWorkspaceRecovery() throws -> AgentWorkspaceRecovery.Page {
        guard let id = selectedID, prepareWorkspaceNavigation() else { throw PetError("画布草稿尚未保存，请先完成当前操作") }
        _ = try canvas.record(id, taskID: taskID)
        // Source text remains in the Canvas record's existing durable draft.
        // The window journal owns only this editor's view and selection.
        let selection = editor.selectedRange()
        var savedAnnotation: RecoveryState.Annotation?
        if let annotation, !annotation.editor.workspaceIsClosed, annotation.editor.settingsHostWindow != nil {
            savedAnnotation = .init(sourceHash: annotation.sourceHash, draft: try annotation.editor.captureWorkspaceRecovery())
        }
        let savedSkill = try skillWindow.flatMap { $0.settingsHostWindow == nil ? nil : try $0.captureDraft() }
        let value = RecoveryState(taskID: taskID, canvasID: id, mode: mode.selectedSegment,
            selectionLocation: selection.location, selectionLength: selection.length, sourceScrollY: editorScroll.contentView.bounds.minY,
            annotation: savedAnnotation, skill: savedSkill)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let state = try encoder.encode(value)
        guard state.count <= 12_000_000 else { throw PetError("画布恢复记录过大，请先添加批注，原记录已保留") }
        let page = AgentWorkspaceRecovery.Page(taskID: taskID, kind: "canvas", state: state,
                                              dirty: dirty || savedAnnotation?.draft.dirty == true || savedSkill?.edited == true, asset: nil)
        _ = try Self.recoveryState(page); return page
    }
    func restoreWorkspaceRecovery(_ page: AgentWorkspaceRecovery.Page) async throws {
        let value = try Self.recoveryState(page)
        guard value.taskID == taskID else { throw PetError("恢复画布不属于当前任务") }
        try await open(value.canvasID)
        mode.selectedSegment = value.mode; changeCanvasMode()
        let count = (editor.string as NSString).length, start = min(value.selectionLocation, count)
        editor.setSelectedRange(NSRange(location: start, length: min(value.selectionLength, count - start)))
        content.layoutSubtreeIfNeeded(); if let container = editor.textContainer { editor.layoutManager?.ensureLayout(for: container) }
        editorScroll.contentView.scroll(to: NSPoint(x: 0, y: value.sourceScrollY)); editorScroll.reflectScrolledClipView(editorScroll.contentView)
        if dirty { state.stringValue = "已恢复未保存源码" }
        if let saved = value.annotation {
            guard settingsHostWindow != nil, onSettingsPush != nil else { throw PetError("请在任务工作区恢复画布批注，原草稿已保留") }
            let shot = AgentCanvasShot(image: try saved.draft.shot().image,
                capture: AgentCanvasCapture(canvasID: value.canvasID, title: saved.draft.source.title, sourceHash: saved.sourceHash,
                                            created: saved.draft.source.created))
            let annotation = makeAnnotation(shot)
            annotation.restoreWorkspaceRecovery(saved.draft)
            presentSettingsChild(annotation)
            guard annotation.settingsHostWindow != nil else { throw PetError("画布批注页尚未恢复，原草稿已保留") }
        }
        if let draft = value.skill {
            guard settingsHostWindow != nil, onSettingsPush != nil else { throw PetError("请在任务工作区恢复打包草稿") }
            let form = makeSkillForm(try canvas.record(value.canvasID, taskID: taskID))
            try form.restoreDraft(draft)
            presentSettingsChild(form)
            guard form.settingsHostWindow != nil else { throw PetError("打包页尚未恢复，原草稿已保留") }
        }
        onWorkspaceChange?()
    }
    @objc private func recoveryViewChanged(_ notification: Notification) { if !closed { onWorkspaceChange?() } }
    func textViewDidChangeSelection(_ notification: Notification) { recoveryViewChanged(notification) }
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
        if settingsHostWindow == nil { showWindow(nil); window?.makeKeyAndOrderFront(nil) }
        refreshCatalog()
        if !dirty, editorHash != value.record.hash { editor.string = value.code; editorHash = value.record.hash; editor.undoManager?.removeAllActions() }
        if loadedHash == value.record.hash { return }
        if requestedHash == value.record.hash, let renderTask { try await renderTask.value; return }
        cancelRender(); requestedHash = value.record.hash; state.stringValue = "正在渲染…"; generation = UUID()
        let operationGeneration = generation
        let operation = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }; resetWeb(); content.layoutSubtreeIfNeeded(); nativeLoading = true
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
        if let i = records.firstIndex(where: { $0.id == selectedID }) { picker.selectItem(at: i); window?.title = "画布 · " + records[i].title; onWorkspaceChange?() }
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
                    skillWindow?.checkSource()
                    guard value.record.hash != loadedHash, value.record.hash != requestedHash else { return }
                    if dirty { state.stringValue = "源码已被其他操作更新，请保留编辑内容后重新载入"; return }
                    try await open(id)
                } catch { skillWindow?.checkSource(); state.stringValue = error.localizedDescription }
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
        _ = try await evaluate("""
        await new Promise(resolve => {
          const root=document.getElementById('canvas-root'); let quiet,limit;
          const observer=new MutationObserver(arm);
          function done(){observer.disconnect();clearTimeout(quiet);clearTimeout(limit);resolve();}
          function arm(){clearTimeout(quiet);quiet=setTimeout(async()=>{const animations=root.getAnimations({subtree:true});if(animations.length){await Promise.race([Promise.all(animations.map(a=>a.finished.catch(()=>{}))),new Promise(r=>setTimeout(r,1000))]);}done();},140);}
          observer.observe(root,{attributes:true,childList:true,characterData:true,subtree:true});limit=setTimeout(done,2500);arm();
        }); return true;
        """)
        let (image, _) = try await AgentBrowserShot.viewport(web)
        guard try canvas.source(id, taskID: taskID).record.hash == source.record.hash else { throw PetError("截图期间画布源码已变化，请重试") }
        return AgentCanvasShot(image: image, capture: AgentCanvasCapture(canvasID: id, title: source.record.title, sourceHash: source.record.hash))
    }
    @objc private func changeCanvas() {
        guard let id = picker.selectedItem?.representedObject as? String else { return }
        refreshCatalog(); run { _ = try await self.canvas.show(id, taskID: self.taskID, location: self.settingsHostWindow == nil ? .window : .workspace) }
    }
    @objc private func changeCanvasMode() { let source = mode.selectedSegment == 1; editorScroll.isHidden = !source; preview.isHidden = source; save.isHidden = !source; annotate.isEnabled = !source && !capturingAnnotation; onWorkspaceChange?() }
    @objc private func reloadDocument() { guard canLeave(), let id = selectedID else { return }; loadedHash = nil; editorHash = nil; run { try await self.open(id) } }
    @objc private func saveSource() {
        guard let id = selectedID, let hash = editorHash else { return }
        do {
            let saved = try canvas.update(id, source: editor.string, expected: hash, taskID: taskID); editorHash = saved.hash; draftTask?.cancel()
            guard canvas.saveDraft(nil, hash: nil, id: id, taskID: taskID) else { dirty = true; state.stringValue = "源码已写入，草稿状态尚未保存，请检查后重试"; onWorkspaceChange?(); return }
            dirty = false; state.stringValue = ""; editorHash = nil; run { try await self.open(id) }
        } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func restoreVersion() {
        guard canLeave(), let id = selectedID, let hash = versions.selectedItem?.representedObject as? String else { versions.selectItem(at: 0); return }
        do { let current = try canvas.source(id, taskID: taskID); _ = try canvas.restore(id, version: hash, expected: current.record.hash, taskID: taskID); editorHash = nil; run { try await self.open(id) } } catch { state.stringValue = error.localizedDescription }
        versions.selectItem(at: 0)
    }
    @objc private func beginAnnotation() {
        if let editor = recoveryAnnotation {
            if editor.settingsHostWindow == nil { presentSettingsChild(editor) }
            return
        }
        guard !capturingAnnotation else { return }
        capturingAnnotation = true
        annotate.isEnabled = false
        run {
            defer {
                self.capturingAnnotation = false
                self.annotate.isEnabled = !self.closed && self.mode.selectedSegment == 0
                self.onWorkspaceChange?()
            }
            let shot = try await self.screenshot()
            try Task.checkCancellation()
            guard !self.closed, self.selectedID == shot.capture.canvasID else { throw PetError("已切换画布，请重试批注") }
            self.capturingAnnotation = false
            self.presentSettingsChild(self.makeAnnotation(shot))
        }
    }
    private func makeAnnotation(_ shot: AgentCanvasShot) -> AgentBrowserAnnotationWindow {
        let editor = AgentBrowserAnnotationWindow(shot: shot.annotationShot) { [weak self] marks, note in
            guard let self, !self.closed else { throw PetError("画布窗口已关闭") }
            try await self.canvas.submit(shot, taskID: self.taskID, marks: marks, note: note)
        }
        editor.canvas.setAccessibilityLabel("画布批注")
        editor.onWorkspaceChange = { [weak self] in self?.onWorkspaceChange?() }
        annotation = (editor, shot.capture.sourceHash)
        return editor
    }
    private func makeSkillForm(_ record: AgentCanvasRecord) -> AgentCanvasSkillWindow {
        let form = AgentCanvasSkillWindow(canvas: canvas, taskID: taskID, record: record)
        form.onExport = { [weak self] folder in self?.state.stringValue = "已打包 " + folder.lastPathComponent; self?.state.toolTip = folder.path }
        form.onSettingsRecoveryChange = { [weak self] in self?.onWorkspaceChange?() }
        form.onCloseForm = { [weak self, weak form] in
            guard let self, skillWindow === form else { return }
            skillWindow = nil; onWorkspaceChange?()
        }
        skillWindow = form
        return form
    }
    @objc private func exportDocument() {
        let kind = exports.indexOfSelectedItem; exports.selectItem(at: 0)
        guard kind > 0, let id = selectedID else { return }
        if kind == 4 {
            guard !dirty else { state.stringValue = "请先保存源码后打包"; return }
            do { presentSettingsChild(makeSkillForm(try canvas.source(id, taskID: taskID).record)); onWorkspaceChange?() }
            catch { state.stringValue = error.localizedDescription }
            return
        }
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
        let notices = try String(contentsOf: root.appendingPathComponent("THIRD-PARTY-NOTICES.txt"), encoding: .utf8)
        let licenseJSON = String(decoding: try JSONSerialization.data(withJSONObject: ["notices": notices]), as: UTF8.self)
        let data = try JSONSerialization.data(withJSONObject: [source]), encoded = String(decoding: data, as: UTF8.self).dropFirst().dropLast()
        func escape(_ text: String) -> String { text.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive) }
        let policy = Self.policy.replacingOccurrences(of: "script-src appcanvas:", with: "script-src 'unsafe-inline'").replacingOccurrences(of: "style-src appcanvas:", with: "style-src")
        return Data(("<!doctype html><html lang=zh-CN><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><meta http-equiv=Content-Security-Policy content=\"" + policy + "\"><style>" + css + "</style></head><body><div id=canvas-root></div><script>" + escape(runtime) + "</script><script type=\"application/json\" id=\"canvas-third-party-notices\">" + escape(licenseJSON) + "</script><script>BlueFatFishCanvas.render(" + escape(String(encoded)) + ")</script></body></html>").utf8)
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        uiTask?.cancel(); uiTask = Task { [weak self] in do { try await action() } catch { if !Task.isCancelled { self?.state.stringValue = error.localizedDescription } } }
    }
    func textDidChange(_ notification: Notification) {
        dirty = true; state.stringValue = "未保存"; draftTask?.cancel(); onWorkspaceChange?()
        guard let id = selectedID else { return }; let text = editor.string, hash = editorHash
        draftTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
            guard let self else { return }; if !canvas.saveDraft(text, hash: hash, id: id, taskID: taskID) { state.stringValue = "源码草稿未保存，请检查大小并另存内容" }
        }
    }
    private func canLeave() -> Bool {
        guard canMoveWindow() else { return false }
        guard dirty else { return true }; guard AgentUnsavedChanges.discard("放弃未保存的源码？", detail: window?.title ?? "画布") else { return false }
        guard let id = selectedID, canvas.saveDraft(nil, hash: nil, id: id, taskID: taskID) else { state.stringValue = "源码草稿未能清除，请检查后重试"; return false }
        dirty = false; draftTask?.cancel(); return true
    }
    private func canMoveWindow() -> Bool {
        if let child = [recoveryAnnotation?.window, skillWindow?.window].compactMap({ $0 }).first(where: { $0.isVisible }) {
            state.stringValue = "请先完成或关闭批注与打包窗口"; child.makeKeyAndOrderFront(nil); return false
        }
        return true
    }
    func prepareWorkspaceNavigation() -> Bool {
        guard !closed, !capturingAnnotation, recoveryAnnotation?.prepareWorkspaceNavigation() != false,
              recoverySkillForm?.prepareWorkspaceNavigation() != false, canMoveWindow() else { return false }
        guard !dirty || selectedID.map({ canvas.saveDraft(editor.string, hash: editorHash, id: $0, taskID: taskID) }) == true else { state.stringValue = "源码草稿未保存，请先保留编辑内容"; return false }
        draftTask?.cancel(); return true
    }
    func workspaceReadback() -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled else { return [:] }
        let frames = [picker, mode, versions, annotate, exports, reload, save].filter { !$0.isHiddenOrHasHiddenAncestor }.map { content.convert($0.bounds, from: $0) }
        return ["taskID": taskID, "canvasID": selectedID ?? "", "source": editor.string, "editorHash": editorHash ?? "", "loadedHash": loadedHash ?? "", "dirty": dirty, "closed": closed, "rendering": renderTask != nil, "state": state.stringValue, "sourceVisible": !editorScroll.isHidden, "selectionLocation": editor.selectedRange().location, "selectionLength": editor.selectedRange().length, "sourceScrollY": Double(editorScroll.contentView.bounds.minY),
            "checks": ["canvasUsesTaskWindow": settingsHostWindow != nil && pageContentView?.window === settingsHostWindow, "canvasHasNoFloatingWindow": window?.isVisible != true, "canvasToolbarFits": !frames.isEmpty && frames.allSatisfy { content.bounds.insetBy(dx: -1, dy: -1).contains($0) }, "canvasHasUsableSize": web.bounds.width >= 450 && web.bounds.height >= 250]]
    }
    func checkWorkspaceSource(_ text: String? = nil, action: String = "source") async {
        guard AgentTaskWorkspace.readbackEnabled else { return }
        if action == "source" { mode.selectedSegment = 1; changeCanvasMode() }
        if let text { editor.string = text; textDidChange(Notification(name: NSText.didChangeNotification, object: editor)) }
        if action == "save" { saveSource(); await uiTask?.value }
        if action == "skill" { exports.selectItem(at: 4); exportDocument() }
    }
    func checkWorkspaceAnnotation() async -> AgentBrowserAnnotationWindow? {
        guard AgentTaskWorkspace.readbackEnabled else { return nil }
        beginAnnotation()
        await uiTask?.value
        return recoveryAnnotation
    }
    func checkWorkspaceSelection(_ range: NSRange, scrollY: Double = 0, source: Bool = true) {
        guard AgentTaskWorkspace.readbackEnabled else { return }
        mode.selectedSegment = source ? 1 : 0; changeCanvasMode(); editor.setSelectedRange(range)
        content.layoutSubtreeIfNeeded(); if let container = editor.textContainer { editor.layoutManager?.ensureLayout(for: container) }
        editorScroll.contentView.scroll(to: NSPoint(x: 0, y: scrollY)); editorScroll.reflectScrolledClipView(editorScroll.contentView)
    }
    override func prepareForWorkspaceClose() async -> Bool {
        let accepted = canLeaveSettings()
        if !accepted, settingsHostWindow != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, let id = self.selectedID else { return }
                try? self.canvas.onPresent?(self, id, self.settingsHostWindow == nil ? .window : .workspace); self.presentingWindow?.makeKeyAndOrderFront(nil)
            }
        }; return accepted
    }
    override func settingsWillLeave() { finishClose() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { canLeave() }
    func windowWillClose(_ notification: Notification) { finishClose() }
    func finishClose() {
        guard !closed else { return }; closed = true
        if dirty, let id = selectedID { canvas.saveDraft(editor.string, hash: editorHash, id: id, taskID: taskID) }
        draftTask?.cancel(); stop(); watcher?.cancel(); watchTask?.cancel()
        if let editor = recoveryAnnotation {
            if editor.settingsHostWindow != nil { editor.finishClose() }
            else { editor.close() }
        }
        if let form = skillWindow {
            if form.settingsHostWindow != nil { form.finishForm() } else { form.close() }
        }
        web.loadHTMLString("", baseURL: nil); onClose?(); onClose = nil
        if settingsHostWindow != nil { close() } else { window?.close() }
    }
}
