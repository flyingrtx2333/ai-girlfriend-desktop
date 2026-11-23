import AppKit
import WebKit

@MainActor private final class AgentDiagramAssets: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "runtime", ["/runtime.js", "/style.css"].contains(url.path), url.query == nil,
              let resources = Bundle.main.resourceURL else { task.didFailWithError(PetError("图表资源地址无效")); return }
        do {
            let data = try Data(contentsOf: resources.appendingPathComponent("web/diagrams" + url.path))
            task.didReceive(URLResponse(url: url, mimeType: url.path.hasSuffix(".js") ? "text/javascript" : "text/css", expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data); task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// A disposable, offline WebKit renderer produces vector attachments for the
// native text view. Document code has no native bridge, network or file access.
@MainActor final class AgentMarkdownDiagrams: NSObject, WKNavigationDelegate, WKUIDelegate {
    struct Drawing { let image: NSImage; let pdf: Data; let svg: String; let labels: String }
    private var web: WKWebView?, pending: CheckedContinuation<Any, Error>?, timeout: Task<Void, Never>?
    private var generation = UUID(), loading = false
    private static let policy = "default-src 'none'; script-src appdiagrams:; style-src appdiagrams: 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; frame-src 'none'; worker-src 'none'; object-src 'none'; media-src 'none'; form-action 'none'; base-uri 'none'"
    private static var shell: String { "<!doctype html><html><head><meta charset=utf-8><meta http-equiv=Content-Security-Policy content=\"" + policy + "\"><link rel=stylesheet href=appdiagrams://runtime/style.css><script src=appdiagrams://runtime/runtime.js defer></script></head><body></body></html>" }
    private func finish(_ result: Result<Any, Error>, token: UUID) {
        guard generation == token, let continuation = pending else { return }
        pending = nil; timeout?.cancel(); timeout = nil; continuation.resume(with: result)
    }
    private func awaitResult(_ start: (UUID) -> Void) async throws -> Any {
        try Task.checkCancellation(); guard pending == nil else { throw PetError("图表正在渲染") }
        let token = generation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                    self?.finish(.failure(PetError("图表渲染超时，请拆分图表后重试")), token: token); self?.stop()
                }
                start(token)
            }
        } onCancel: { [weak self] in Task { @MainActor in if self?.generation == token { self?.stop() } } }
    }
    func render(_ source: String, width: CGFloat) async throws -> Drawing {
        guard source.utf8.count <= 32_768 else { throw PetError("图表源码超过 32KB") }
        if web == nil {
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); config.preferences.javaScriptCanOpenWindowsAutomatically = false
            config.setURLSchemeHandler(AgentDiagramAssets(), forURLScheme: "appdiagrams")
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
            web = view; view.navigationDelegate = self; view.uiDelegate = self; loading = true
            _ = try await awaitResult { _ in view.loadHTMLString(Self.shell, baseURL: URL(string: "appdiagrams://runtime/")) }
        }
        guard let view = web else { throw CancellationError() }
        let value = try await awaitResult { token in
            view.callAsyncJavaScript("return await BlueFatFishDiagrams.render(source, width)", arguments: ["source": source, "width": max(320, min(2048, width))], in: nil, in: .page) { [weak self] in self?.finish($0, token: token) }
        }
        guard let result = value as? [String: Any], let width = result["width"] as? Double, let height = result["height"] as? Double,
              let svg = result["svg"] as? String, let labels = result["labels"] as? String,
              width.isFinite, height.isFinite, width > 0, height > 0, width <= 6000, height <= 12000, width * height <= 16_000_000 else { throw PetError("图表大小无效") }
        view.setFrameSize(NSSize(width: width, height: height))
        let config = WKPDFConfiguration(); config.rect = NSRect(x: 0, y: 0, width: width, height: height)
        let pdf = try await awaitResult { token in view.createPDF(configuration: config) { [weak self] result in self?.finish(result.map { $0 as Any }, token: token) } }
        guard let data = pdf as? Data, data.count <= 20_000_000, let image = NSImage(data: data) else { throw PetError("图表无法显示") }
        image.size = NSSize(width: width, height: height)
        return Drawing(image: image, pdf: data, svg: svg, labels: labels)
    }
    func stop() {
        timeout?.cancel(); timeout = nil
        if let continuation = pending { pending = nil; continuation.resume(throwing: CancellationError()) }
        generation = UUID(); loading = false; web?.navigationDelegate = nil; web?.uiDelegate = nil; web?.stopLoading(); web = nil
    }
    func checkOfflinePolicy() async throws -> Bool {
        guard CommandLine.arguments.contains("--markdown-check"), let view = web else { return false }
        let result = try await awaitResult { token in
            view.callAsyncJavaScript("""
            return await new Promise(resolve => {
              const done = event => { if (event.violatedDirective === 'connect-src') { document.removeEventListener('securitypolicyviolation', done); resolve(true); } };
              document.addEventListener('securitypolicyviolation', done);
              fetch('https://example.invalid/diagram-check').catch(() => {});
              setTimeout(() => { document.removeEventListener('securitypolicyviolation', done); resolve(false); }, 500);
            });
            """, arguments: [:], in: nil, in: .page) { [weak self] in self?.finish($0, token: token) }
        }
        return result as? Bool == true
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { guard webView === web, loading else { return }; loading = false; finish(.success(true), token: generation) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { guard webView === web else { return }; finish(.failure(error), token: generation) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { guard webView === web else { return }; finish(.failure(error), token: generation) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(PetError("图表渲染器已退出，请重新打开文档")), token: generation); stop() }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(loading && ["about", "appdiagrams"].contains(action.request.url?.scheme ?? "") && action.navigationType != .linkActivated ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }

    static func statusImage(_ message: String) -> NSImage {
        let size = NSSize(width: 340, height: 44)
        return NSImage(size: size, flipped: false) { rect in
            NSColor(white: 0.96, alpha: 1).setFill(); rect.fill()
            (message as NSString).draw(in: rect.insetBy(dx: 10, dy: 12), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: AgentWorkbenchTheme.secondaryText]); return true
        }
    }
}

@MainActor final class AgentMarkdownDiagramPreview: AgentThemeView {
    struct Position: Codable, Equatable, Sendable {
        var index: Int
        var scale: Double?
        var x: Double, y: Double
        var valid: Bool {
            (0..<16).contains(index) && (scale.map { (0.02...8).contains($0) } ?? true) &&
                (0...1).contains(x) && (0...1).contains(y)
        }
    }
    private let scroll = NSScrollView(), paper = NSView(), chart = NSImageView()
    private let back = AgentWorkbenchButton(), minus = AgentWorkbenchButton(), plus = AgentWorkbenchButton(), fit = AgentWorkbenchButton()
    private let percentage = NSTextField(labelWithString: "")
    private(set) var position: Position
    private var fittedTo: NSSize = .zero, applyingLayout = false
    private var displayedScale: CGFloat = 1
    var onReturn: (() -> Void)?
    var onChange: (() -> Void)?

    init(index: Int, drawing: AgentMarkdownDiagrams.Drawing, position: Position?) {
        self.position = position ?? Position(index: index, scale: nil, x: 0.5, y: 0.5)
        super.init(frame: .zero)
        fill = AgentWorkbenchTheme.surface
        setAccessibilityLabel("Mermaid 图表预览")
        let title = NSTextField(labelWithString: "Mermaid 图表")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        for (button, label, symbol, action) in [
            (back, "返回文档", "chevron.left", #selector(returnToDocument)),
            (minus, "缩小图表", "minus", #selector(zoom(_:))),
            (plus, "放大图表", "plus", #selector(zoom(_:))),
            (fit, "适合窗口", "arrow.up.left.and.arrow.down.right", #selector(fitToWindow))
        ] {
            AgentWorkbenchTheme.toolbar(button, title: label, symbol: symbol)
            button.target = self
            button.action = action
        }
        back.keyEquivalent = "\u{1b}"
        back.keyEquivalentModifierMask = []
        percentage.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        percentage.alignment = .center
        percentage.textColor = AgentWorkbenchTheme.secondaryText
        percentage.widthAnchor.constraint(equalToConstant: 42).isActive = true
        let header = NSStackView(views: [back, title, NSView(), minus, percentage, plus, fit])
        header.alignment = .centerY
        header.spacing = 4
        let line = AgentWorkbenchTheme.rule()
        for view in [header, line, scroll] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            line.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        chart.image = drawing.image
        chart.imageScaling = .scaleAxesIndependently
        chart.setAccessibilityLabel("Mermaid 图表")
        paper.addSubview(chart)
        scroll.documentView = paper
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.usesPredominantAxisScrolling = false
        updateBackground()
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }
    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            scroll.backgroundColor = AgentThemeContext.resolve(AgentWorkbenchTheme.subtle, in: self)
        }
    }
    override func layout() {
        super.layout()
        if fittedTo != scroll.contentView.bounds.size { layoutChart() }
    }
    private func layoutChart() {
        let clip = scroll.contentView, size = clip.bounds.size
        guard !applyingLayout, size.width > 16, size.height > 16, let image = chart.image else { return }
        applyingLayout = true
        defer { applyingLayout = false }
        fittedTo = size
        let fitted = min((size.width - 16) / image.size.width, (size.height - 16) / image.size.height)
        displayedScale = position.scale.map { CGFloat($0) } ?? min(8, fitted)
        let width = displayedScale * image.size.width, height = displayedScale * image.size.height
        let document = NSSize(width: max(size.width, width + 16), height: max(size.height, height + 16))
        paper.setFrameSize(document)
        chart.frame = NSRect(x: (document.width - width) / 2, y: (document.height - height) / 2, width: width, height: height)
        let reading = NSRect(x: chart.frame.minX + CGFloat(position.x) * width - size.width / 2,
                             y: chart.frame.minY + CGFloat(position.y) * height - size.height / 2,
                             width: size.width, height: size.height)
        clip.scroll(to: clip.constrainBoundsRect(reading).origin)
        scroll.reflectScrolledClipView(clip)
        percentage.stringValue = "\(Int((displayedScale * 100).rounded()))%"
        minus.isEnabled = displayedScale > 0.02
        plus.isEnabled = displayedScale < 8
        fit.isEnabled = position.scale != nil
    }
    func focus() { window?.makeFirstResponder(back) }
    @objc private func returnToDocument() { onReturn?() }
    @objc private func zoom(_ sender: NSButton) {
        let next = displayedScale * (sender === plus ? 1.4 : 1 / 1.4)
        position.scale = Double(max(0.02, min(8, next)))
        layoutChart()
        onChange?()
    }
    @objc private func fitToWindow() {
        position = Position(index: position.index, scale: nil, x: 0.5, y: 0.5)
        layoutChart()
        onChange?()
    }
    @objc private func viewportChanged() {
        let clip = scroll.contentView, bounds = clip.bounds, image = chart.frame
        guard !applyingLayout else { return }
        if bounds.size != fittedTo { layoutChart(); return }
        guard !image.isEmpty, position.scale != nil else { return }
        let center = clip.convert(NSPoint(x: bounds.midX, y: bounds.midY), to: paper)
        let x = min(1, max(0, (center.x - image.minX) / image.width)), y = min(1, max(0, (center.y - image.minY) / image.height))
        guard x != position.x || y != position.y else { return }
        position.x = x
        position.y = y
        onChange?()
    }
}
