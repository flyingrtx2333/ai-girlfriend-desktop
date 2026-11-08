import AppKit
import WebKit
import PDFKit

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
            (message as NSString).draw(in: rect.insetBy(dx: 10, dy: 12), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]); return true
        }
    }
}

@MainActor final class AgentMarkdownDiagramWindow: NSWindowController {
    init(_ drawing: AgentMarkdownDiagrams.Drawing) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Mermaid 图表"; window.minSize = NSSize(width: 400, height: 300); window.isReleasedWhenClosed = false; window.center()
        let pdf = PDFView(); pdf.document = PDFDocument(data: drawing.pdf); pdf.autoScales = true; pdf.displayMode = .singlePageContinuous; pdf.setAccessibilityLabel("Mermaid 图表，可缩放")
        window.contentView = pdf; super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
