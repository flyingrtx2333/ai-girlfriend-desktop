import AppKit
import WebKit

struct AgentVideoPlayback: Codable, Equatable, Sendable {
    var version = 1
    var hash: String
    var time: Double
    var duration: Double
    var rate: Double
    var volume: Double
    var muted: Bool
    var isValid: Bool {
        version == 1 && hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } &&
        time.isFinite && duration.isFinite && duration > 0 && time >= 0 && time <= duration + 0.25 &&
        rate.isFinite && (0.0625...16).contains(rate) && volume.isFinite && (0...1).contains(volume)
    }
}

struct AgentVideoSnapshot: Sendable {
    let folder: URL, document: URL, media: URL, hash: String
    static let maximum = 500 * 1024 * 1024
    static func supports(_ file: URL) -> Bool { ["mp4", "webm"].contains(file.pathExtension.lowercased()) }
    static func create(files: AgentFiles, file: URL, playback: AgentVideoPlayback? = nil) throws -> Self {
        guard playback?.isValid != false else { throw PetError("视频播放记录无效，原记录已保留") }
        guard supports(file), try files.resolve(file.path) == file, !AgentFiles.sensitive(files.relative(file)) else { throw PetError("不能预览此视频路径") }
        let metadata = try files.entryMetadata(file)
        guard metadata.kind == "file" else { throw PetError("视频不存在或不是普通文件") }
        var temporary = FileManager.default.temporaryDirectory
        if let index = CommandLine.arguments.firstIndex(of: "--check") {
            guard CommandLine.arguments.indices.contains(index + 1) else { throw PetError("缺少独立验收目录") }
            temporary = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true).appendingPathComponent("tmp", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let folder = temporary.appendingPathComponent("bluefatfish-video-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let local = try AgentFiles(workspace: folder.path), media = folder.appendingPathComponent("media." + file.pathExtension.lowercased())
            let hash = try local.copyFile(file, from: files, to: media, permissions: 0o400, maximum: maximum)
            guard try files.entryMetadata(file).signature == metadata.signature else { throw PetError("打开期间视频已变化，请刷新") }
            let document = folder.appendingPathComponent("index.html")
            let html = try shell(media: media.lastPathComponent, playback: playback?.hash == hash ? playback : nil)
            try local.writeData(Data(html.utf8), to: document, permissions: 0o400)
            return Self(folder: folder, document: document, media: media, hash: hash)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            if error.localizedDescription == "文件超过大小上限" { throw PetError("视频超过 500MB，可使用系统应用打开") }
            throw error
        }
    }
    private static func shell(media: String, playback: AgentVideoPlayback?) throws -> String {
        let nonce = UUID().uuidString
        let restored = String(decoding: try JSONEncoder().encode(playback), as: UTF8.self)
        return """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; media-src 'self' file:; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline'; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'">
        <meta name="referrer" content="no-referrer"><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;width:100%;height:100%;background:#151515;color:#eee;font:13px -apple-system,sans-serif}body{display:flex;flex-direction:column}video{width:100%;flex:1;min-height:0;object-fit:contain}p{margin:0;padding:12px 16px;line-height:1.5}p:empty{display:none}</style>
        <title>视频预览</title></head><body><video id="video" controls playsinline disableremoteplayback x-webkit-airplay="deny" preload="metadata" aria-label="视频预览" src="\(media)"></video><p id="state" role="status" aria-live="polite"></p>
        <script nonce="\(nonce)">
        const video=document.getElementById('video'),state=document.getElementById('state');
        video.addEventListener('error',()=>{state.textContent=video.error?.code===2?'视频读取失败，请刷新重试':'无法播放视频，请检查文件格式或编码';});
        const restored=\(restored);let lastSecond=-1;
        const changed=()=>window.webkit?.messageHandlers.videoPlayback?.postMessage('changed');
        video.addEventListener('loadedmetadata',()=>{
          state.textContent='';
          if(restored){video.pause();video.playbackRate=restored.rate;video.volume=restored.volume;video.muted=restored.muted;video.currentTime=Math.min(restored.time,video.duration);}
          changed();
        },{once:true});
        for(const event of ['play','pause','seeking','seeked','ratechange','volumechange'])video.addEventListener(event,changed);
        video.addEventListener('timeupdate',()=>{const second=Math.floor(video.currentTime);if(second!==lastSecond){lastSecond=second;changed();}});
        document.addEventListener('keydown',event=>{
          if(event.defaultPrevented||event.altKey||event.ctrlKey||event.metaKey||(event.code!=='Space'&&event.key!==' '))return;
          event.preventDefault();event.stopPropagation();if(event.repeat)return;
          state.textContent='';
          if(video.paused)video.play().catch(()=>{state.textContent='无法开始播放，请重试';});else video.pause();
        },true);
        document.addEventListener('visibilitychange',()=>{if(document.hidden)video.pause();});
        window.addEventListener('pagehide',()=>video.pause());
        </script></body></html>
        """
    }
}

@MainActor final class AgentVideoPreview: NSView, WKNavigationDelegate, WKUIDelegate {
    private final class PlaybackEvents: NSObject, WKScriptMessageHandler {
        weak var owner: AgentVideoPreview?
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let owner, message.frameInfo.isMainFrame, message.frameInfo.request.url == owner.snapshot?.document,
                  message.body as? String == "changed" else { return }
            owner.onPlaybackChange?()
        }
    }
    private let player = NSView(), status = NSTextField(labelWithString: ""), reload = NSButton(title: "刷新", target: nil, action: nil), external = NSButton(title: "系统打开", target: nil, action: nil)
    private var web: WKWebView?, snapshot: AgentVideoSnapshot?, opening: Task<Void, Never>?
    private var source: URL?, files: AgentFiles?, validate: (() throws -> Void)?, generation = UUID()
    private var playback: AgentVideoPlayback?
    var onPlaybackChange: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        status.font = .systemFont(ofSize: 11); status.textColor = AgentWorkbenchTheme.secondaryText; status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        reload.target = self; reload.action = #selector(refresh); reload.controlSize = .small; reload.setAccessibilityLabel("刷新视频")
        external.target = self; external.action = #selector(openExternal); external.controlSize = .small; external.setAccessibilityLabel("用系统应用打开视频")
        let bar = NSStackView(views: [status, NSView(), reload, external]); bar.spacing = 8
        for child in [bar, player] { addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([bar.leadingAnchor.constraint(equalTo: leadingAnchor), bar.trailingAnchor.constraint(equalTo: trailingAnchor), bar.topAnchor.constraint(equalTo: topAnchor), bar.heightAnchor.constraint(equalToConstant: 20), player.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6), player.leadingAnchor.constraint(equalTo: leadingAnchor), player.trailingAnchor.constraint(equalTo: trailingAnchor), player.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func show(file: URL, files: AgentFiles, validate: (() throws -> Void)? = nil, restoring: AgentVideoPlayback? = nil) {
        clear(); source = file; self.files = files; self.validate = validate; status.stringValue = "正在打开视频…"; reload.isEnabled = false
        playback = restoring
        let current = generation
        opening = Task { [weak self] in
            guard let self else { return }
            do {
                try validate?()
                let copy = Task.detached(priority: .userInitiated) { try AgentVideoSnapshot.create(files: files, file: file, playback: restoring) }
                let pinned = try await withTaskCancellationHandler { try await copy.value } onCancel: { copy.cancel() }
                guard !Task.isCancelled, generation == current else { try? FileManager.default.removeItem(at: pinned.folder); return }
                do { try validate?() } catch { try? FileManager.default.removeItem(at: pinned.folder); throw error }
                snapshot = pinned
                let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
                configuration.preferences.javaScriptCanOpenWindowsAutomatically = false; configuration.allowsAirPlayForMediaPlayback = false
                configuration.preferences.isElementFullscreenEnabled = true
                configuration.mediaTypesRequiringUserActionForPlayback = .all
                let events = PlaybackEvents(); events.owner = self
                configuration.userContentController.add(events, name: "videoPlayback")
                let web = WKWebView(frame: player.bounds, configuration: configuration); self.web = web
                web.navigationDelegate = self; web.uiDelegate = self; web.setAccessibilityLabel("视频播放器")
                // WebKit reparents the web view for native fullscreen. Do not
                // leave constraints pinning it to the original window.
                web.autoresizingMask = [.width, .height]; player.addSubview(web)
                web.loadFileURL(pinned.document, allowingReadAccessTo: pinned.folder)
                status.stringValue = restoring.map { $0.hash != pinned.hash } == true ? "视频已变化，未恢复播放位置" : ""
                reload.isEnabled = true; focusIfNeeded()
            } catch { if generation == current, !Task.isCancelled { status.stringValue = error.localizedDescription; reload.isEnabled = true } }
        }
    }
    @objc private func refresh() { Task { [weak self] in await self?.refreshPlayback() } }
    private func refreshPlayback() async {
        guard let source, let files else { return }; let current = generation
        reload.isEnabled = false; let restored = await capturePlayback()
        guard generation == current else { return }
        show(file: source, files: files, validate: validate, restoring: restored)
        await opening?.value
    }
    func capturePlayback() async -> AgentVideoPlayback? {
        await opening?.value
        guard let web, let snapshot else { return playback }; let current = generation
        let script = "(()=>{const v=document.getElementById('video');return v&&v.readyState>0&&!v.error&&Number.isFinite(v.duration)&&v.duration>0?{time:v.currentTime,duration:v.duration,rate:v.playbackRate,volume:v.volume,muted:v.muted}:null;})()"
        if let value = try? await web.evaluateJavaScript(script) as? [String: Any], generation == current,
           let time = value["time"] as? Double, let duration = value["duration"] as? Double,
           let rate = value["rate"] as? Double, let volume = value["volume"] as? Double, let muted = value["muted"] as? Bool {
            let next = AgentVideoPlayback(hash: snapshot.hash, time: time, duration: duration, rate: rate, volume: volume, muted: muted)
            if next.isValid { playback = next }
        }
        return playback
    }
    @objc private func openExternal() {
        do {
            guard let source, let files else { return }; try validate?()
            guard try files.resolve(source.path) == source, !AgentFiles.sensitive(files.relative(source)), try files.entryMetadata(source).kind == "file" else { throw PetError("视频位置已变化") }
            guard NSWorkspace.shared.open(source) else { throw PetError("系统应用无法打开此视频") }
        } catch { status.stringValue = error.localizedDescription }
    }
    func pause() { web?.pauseAllMediaPlayback(completionHandler: nil) }
    func focusIfNeeded() {
        guard let window, let web, window.isVisible, !isHiddenOrHasHiddenAncestor, window.firstResponder === window else { return }
        window.makeFirstResponder(web)
    }
    func clear() {
        generation = UUID(); opening?.cancel(); opening = nil
        pause(); web?.configuration.userContentController.removeScriptMessageHandler(forName: "videoPlayback"); web?.closeAllMediaPresentations(completionHandler: nil); web?.stopLoading(); web?.navigationDelegate = nil; web?.uiDelegate = nil; web?.removeFromSuperview(); web = nil
        if let snapshot { try? FileManager.default.removeItem(at: snapshot.folder) }; snapshot = nil
        source = nil; files = nil; validate = nil; playback = nil; status.stringValue = ""
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.targetFrame?.isMainFrame == true && navigationAction.request.url == snapshot?.document ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { if webView === web { focusIfNeeded() } }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { status.stringValue = "视频预览未完成，请刷新重试" }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { status.stringValue = "视频预览无法读取，请刷新重试" }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func checkState() async -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled || AgentKnowledgePageHost.readbackEnabled || CommandLine.arguments.contains("--video-preview-check") else { return [:] }
        await opening?.value
        var result: [String: Any] = ["file": source?.path ?? "", "sourceHash": snapshot?.hash ?? "", "snapshotFolder": snapshot?.folder.path ?? "", "webPresent": web != nil, "status": status.stringValue, "hidden": isHidden, "reloadEnabled": reload.isEnabled]
        result["previewFrame"] = NSStringFromRect(frame); result["surfaceBounds"] = NSStringFromRect(player.bounds); result["webFrame"] = web.map { NSStringFromRect($0.frame) } ?? ""
        if let web, let value = try? await web.evaluateJavaScript("(()=>{const v=document.getElementById('video');return v?{readyState:v.readyState,duration:Number.isFinite(v.duration)?v.duration:0,time:v.currentTime,rate:v.playbackRate,volume:v.volume,muted:v.muted,paused:v.paused,seeking:v.seeking,ended:v.ended,width:v.videoWidth,height:v.videoHeight,clientWidth:v.clientWidth,clientHeight:v.clientHeight,viewportWidth:innerWidth,viewportHeight:innerHeight,error:v.error?.code??0,status:document.getElementById('state').textContent,controls:v.controls,frames:v.getVideoPlaybackQuality().totalVideoFrames,fullscreen:document.fullscreenElement===v,webkitFullscreen:v.webkitDisplayingFullscreen===true}:{};})()") as? [String: Any] { result["player"] = value }
        return result
    }
    func checkWorkspace(action: String = "", time: Double? = nil, rate: Double? = nil, volume: Double? = nil, muted: Bool? = nil) async {
        guard AgentTaskWorkspace.readbackEnabled else { return }; await opening?.value
        if action == "refresh" { await refreshPlayback() }
        var values: [String: Any] = [:]
        if let time, time.isFinite, time >= 0 { values["time"] = time }
        if let rate, rate.isFinite, (0.0625...16).contains(rate) { values["rate"] = rate }
        if let volume, volume.isFinite, (0...1).contains(volume) { values["volume"] = volume }
        if let muted { values["muted"] = muted }
        if !values.isEmpty { _ = try? await web?.callAsyncJavaScript("const v=document.getElementById('video');if(value.time!==undefined)v.currentTime=value.time;if(value.rate!==undefined)v.playbackRate=value.rate;if(value.volume!==undefined)v.volume=value.volume;if(value.muted!==undefined)v.muted=value.muted;", arguments: ["value": values], in: nil, contentWorld: .page) }
    }
}

@MainActor final class AgentVideoWindow: AgentSettingsPageController, NSWindowDelegate {
    let preview = AgentVideoPreview()
    init(file: URL, files: AgentFiles, validate: (() throws -> Void)? = nil) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = file.lastPathComponent; window.minSize = NSSize(width: 500, height: 350); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        let content = AgentThemeView(fill: AgentWorkbenchTheme.surface); window.contentView = content; content.addSubview(preview); preview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([preview.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), preview.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12), preview.topAnchor.constraint(equalTo: content.topAnchor, constant: 10), preview.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)])
        preview.show(file: file, files: files, validate: validate)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func settingsDidAppear() { super.settingsDidAppear(); preview.focusIfNeeded() }
    override func canLeaveSettings() -> Bool {
        guard super.canLeaveSettings() else { return false }; preview.pause(); return true
    }
    override func settingsWillLeave() { preview.clear() }
    func windowWillClose(_ notification: Notification) { preview.clear() }
}
