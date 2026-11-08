import AppKit
import WebKit

struct AgentVideoSnapshot: Sendable {
    let folder: URL, document: URL, media: URL, hash: String
    static let maximum = 500 * 1024 * 1024
    static func supports(_ file: URL) -> Bool { ["mp4", "webm"].contains(file.pathExtension.lowercased()) }
    static func create(files: AgentFiles, file: URL) throws -> Self {
        guard supports(file), try files.resolve(file.path) == file, !AgentFiles.sensitive(files.relative(file)) else { throw PetError("不能预览此视频路径") }
        let metadata = try files.entryMetadata(file)
        guard metadata.kind == "file" else { throw PetError("视频不存在或不是普通文件") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bluefatfish-video-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let local = try AgentFiles(workspace: folder.path), media = folder.appendingPathComponent("media." + file.pathExtension.lowercased())
            let hash = try local.copyFile(file, from: files, to: media, permissions: 0o400, maximum: maximum)
            guard try files.entryMetadata(file).signature == metadata.signature else { throw PetError("打开期间视频已变化，请刷新") }
            let document = folder.appendingPathComponent("index.html")
            try local.writeData(Data(shell(media: media.lastPathComponent).utf8), to: document, permissions: 0o400)
            return Self(folder: folder, document: document, media: media, hash: hash)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            if error.localizedDescription == "文件超过大小上限" { throw PetError("视频超过 500MB，可使用系统应用打开") }
            throw error
        }
    }
    private static func shell(media: String) -> String {
        let nonce = UUID().uuidString
        return """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; media-src 'self' file:; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline'; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'">
        <meta name="referrer" content="no-referrer"><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;width:100%;height:100%;background:#151515;color:#eee;font:13px -apple-system,sans-serif}body{display:flex;flex-direction:column}video{width:100%;flex:1;min-height:0;object-fit:contain}p{margin:0;padding:12px 16px;line-height:1.5}p:empty{display:none}</style>
        <title>视频预览</title></head><body><video id="video" controls playsinline disableremoteplayback x-webkit-airplay="deny" preload="metadata" aria-label="视频预览" src="\(media)"></video><p id="state" role="status" aria-live="polite"></p>
        <script nonce="\(nonce)">
        const video=document.getElementById('video'),state=document.getElementById('state');
        video.addEventListener('error',()=>{state.textContent=video.error?.code===2?'视频读取失败，请刷新重试':'无法播放视频，请检查文件格式或编码';});
        video.addEventListener('loadedmetadata',()=>{state.textContent='';});
        document.addEventListener('visibilitychange',()=>{if(document.hidden)video.pause();});
        window.addEventListener('pagehide',()=>video.pause());
        </script></body></html>
        """
    }
}

@MainActor final class AgentVideoPreview: NSView, WKNavigationDelegate, WKUIDelegate {
    private let player = NSView(), status = NSTextField(labelWithString: ""), reload = NSButton(title: "刷新", target: nil, action: nil), external = NSButton(title: "系统打开", target: nil, action: nil)
    private var web: WKWebView?, snapshot: AgentVideoSnapshot?, opening: Task<Void, Never>?
    private var source: URL?, files: AgentFiles?, validate: (() throws -> Void)?, generation = UUID()
    override init(frame: NSRect) {
        super.init(frame: frame)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        reload.target = self; reload.action = #selector(refresh); reload.controlSize = .small; reload.setAccessibilityLabel("刷新视频")
        external.target = self; external.action = #selector(openExternal); external.controlSize = .small; external.setAccessibilityLabel("用系统应用打开视频")
        let bar = NSStackView(views: [status, NSView(), reload, external]); bar.spacing = 8
        for child in [bar, player] { addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([bar.leadingAnchor.constraint(equalTo: leadingAnchor), bar.trailingAnchor.constraint(equalTo: trailingAnchor), bar.topAnchor.constraint(equalTo: topAnchor), bar.heightAnchor.constraint(equalToConstant: 20), player.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6), player.leadingAnchor.constraint(equalTo: leadingAnchor), player.trailingAnchor.constraint(equalTo: trailingAnchor), player.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func show(file: URL, files: AgentFiles, validate: (() throws -> Void)? = nil) {
        clear(); source = file; self.files = files; self.validate = validate; status.stringValue = "正在打开视频…"; reload.isEnabled = false
        let current = generation
        opening = Task { [weak self] in
            guard let self else { return }
            do {
                try validate?()
                let copy = Task.detached(priority: .userInitiated) { try AgentVideoSnapshot.create(files: files, file: file) }
                let pinned = try await withTaskCancellationHandler { try await copy.value } onCancel: { copy.cancel() }
                guard !Task.isCancelled, generation == current else { try? FileManager.default.removeItem(at: pinned.folder); return }
                do { try validate?() } catch { try? FileManager.default.removeItem(at: pinned.folder); throw error }
                snapshot = pinned
                let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
                configuration.preferences.javaScriptCanOpenWindowsAutomatically = false; configuration.allowsAirPlayForMediaPlayback = false
                configuration.preferences.isElementFullscreenEnabled = true
                configuration.mediaTypesRequiringUserActionForPlayback = .all
                let web = WKWebView(frame: player.bounds, configuration: configuration); self.web = web
                web.navigationDelegate = self; web.uiDelegate = self; web.setAccessibilityLabel("视频播放器")
                // WebKit reparents the web view for native fullscreen. Do not
                // leave constraints pinning it to the original window.
                web.autoresizingMask = [.width, .height]; player.addSubview(web)
                web.loadFileURL(pinned.document, allowingReadAccessTo: pinned.folder); status.stringValue = ""; reload.isEnabled = true
            } catch { if generation == current, !Task.isCancelled { status.stringValue = error.localizedDescription; reload.isEnabled = true } }
        }
    }
    @objc private func refresh() { guard let source, let files else { return }; show(file: source, files: files, validate: validate) }
    @objc private func openExternal() {
        do {
            guard let source, let files else { return }; try validate?()
            guard try files.resolve(source.path) == source, !AgentFiles.sensitive(files.relative(source)), try files.entryMetadata(source).kind == "file" else { throw PetError("视频位置已变化") }
            guard NSWorkspace.shared.open(source) else { throw PetError("系统应用无法打开此视频") }
        } catch { status.stringValue = error.localizedDescription }
    }
    func pause() { web?.pauseAllMediaPlayback(completionHandler: nil) }
    func clear() {
        generation = UUID(); opening?.cancel(); opening = nil
        pause(); web?.closeAllMediaPresentations(completionHandler: nil); web?.stopLoading(); web?.navigationDelegate = nil; web?.uiDelegate = nil; web?.removeFromSuperview(); web = nil
        if let snapshot { try? FileManager.default.removeItem(at: snapshot.folder) }; snapshot = nil
        source = nil; files = nil; validate = nil; status.stringValue = ""
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.targetFrame?.isMainFrame == true && navigationAction.request.url == snapshot?.document ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { status.stringValue = "视频预览未完成，请刷新重试" }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { status.stringValue = "视频预览无法读取，请刷新重试" }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func checkState() async -> [String: Any] {
        guard CommandLine.arguments.contains("--video-preview-check") else { return [:] }
        await opening?.value
        var result: [String: Any] = ["file": source?.path ?? "", "sourceHash": snapshot?.hash ?? "", "snapshotFolder": snapshot?.folder.path ?? "", "webPresent": web != nil, "status": status.stringValue, "hidden": isHidden, "reloadEnabled": reload.isEnabled]
        result["previewFrame"] = NSStringFromRect(frame); result["surfaceBounds"] = NSStringFromRect(player.bounds); result["webFrame"] = web.map { NSStringFromRect($0.frame) } ?? ""
        if let web, let value = try? await web.evaluateJavaScript("(()=>{const v=document.getElementById('video');return v?{readyState:v.readyState,duration:Number.isFinite(v.duration)?v.duration:0,time:v.currentTime,paused:v.paused,ended:v.ended,width:v.videoWidth,height:v.videoHeight,clientWidth:v.clientWidth,clientHeight:v.clientHeight,viewportWidth:innerWidth,viewportHeight:innerHeight,error:v.error?.code??0,status:document.getElementById('state').textContent,controls:v.controls,frames:v.getVideoPlaybackQuality().totalVideoFrames,fullscreen:document.fullscreenElement===v,webkitFullscreen:v.webkitDisplayingFullscreen===true}:{};})()") as? [String: Any] { result["player"] = value }
        return result
    }
}

@MainActor final class AgentVideoWindow: NSWindowController, NSWindowDelegate {
    let preview = AgentVideoPreview()
    init(file: URL, files: AgentFiles, validate: (() throws -> Void)? = nil) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = file.lastPathComponent; window.minSize = NSSize(width: 500, height: 350); window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua); window.center()
        super.init(window: window); window.delegate = self
        let content = NSView(); window.contentView = content; content.addSubview(preview); preview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([preview.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), preview.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12), preview.topAnchor.constraint(equalTo: content.topAnchor, constant: 10), preview.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)])
        preview.show(file: file, files: files, validate: validate)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowWillClose(_ notification: Notification) { preview.clear() }
}
