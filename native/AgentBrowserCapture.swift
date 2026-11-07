import AppKit
import WebKit
import ScreenCaptureKit

struct AgentBrowserCapture: Codable, Sendable {
    var tabID: String
    var url: String
    var title: String
    var created: Date
    var viewportWidth: Double
    var viewportHeight: Double
    var annotations = 0
    var method: String?
}

@MainActor struct AgentBrowserShot {
    var image: NSImage
    var source: AgentBrowserCapture

    private static func requireUnlockedSession() throws {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard session?["CGSSessionScreenIsLocked"] as? Bool != true else { throw PetError("Mac 当前已锁屏，请解锁后重试截图") }
    }

    static func viewport(_ web: WKWebView) async throws -> (NSImage, String) {
        try requireUnlockedSession()
        guard let window = web.window, window.isVisible, !window.isMiniaturized else { throw PetError("请展开此任务的浏览器窗口后截图") }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        window.contentView?.layoutSubtreeIfNeeded(); web.displayIfNeeded()
        let deadline = Date().addingTimeInterval(2)
        while !window.occlusionState.contains(.visible), Date() < deadline {
            try Task.checkCancellation(); try requireUnlockedSession(); try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard window.occlusionState.contains(.visible), !web.isHiddenOrHasHiddenAncestor else { throw PetError("网页当前不可见，请展开任务浏览器后重试截图") }
        // Ordering a window is asynchronous. Let WebKit resume and commit its
        // first accelerated frame before asking the window server for pixels.
        let visible = try await web.callAsyncJavaScript("""
        return await new Promise(resolve => {
            let done = false;
            const finish = () => { if (!done) { done = true; resolve(!document.hidden); } };
            setTimeout(finish, 750);
            requestAnimationFrame(() => requestAnimationFrame(finish));
        });
        """, arguments: [:], in: nil, contentWorld: .defaultClient)
        try Task.checkCancellation(); try requireUnlockedSession()
        guard visible as? Bool == true else { throw PetError("网页尚未恢复绘制，请展开任务浏览器后重试截图") }
        let viewport = web.bounds.size, windowSize = window.frame.size, viewRect = web.convert(web.bounds, to: nil)
        if #available(macOS 14.4, *) {
            // This API exposes only content available to the current process
            // without TCC consent. Never enumerate or capture other apps here.
            let content = try await SCShareableContent.currentProcess
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) && $0.owningApplication?.processID == getpid() }) else { throw PetError("未找到当前任务浏览器窗口，请重新打开后截图") }
            let scale = min(1, 2048 / max(own.frame.width, own.frame.height))
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int(own.frame.width * scale)); configuration.height = max(1, Int(own.frame.height * scale))
            configuration.showsCursor = false; configuration.capturesAudio = false; configuration.scalesToFit = true; configuration.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: configuration)
            try Task.checkCancellation(); try requireUnlockedSession()
            guard web.window === window, window.frame.size == windowSize, web.bounds.size == viewport else { throw PetError("截图期间窗口尺寸已变化，请重新截图") }
            let x = CGFloat(image.width) / windowSize.width, y = CGFloat(image.height) / windowSize.height
            let crop = CGRect(x: viewRect.minX * x, y: (windowSize.height - viewRect.maxY) * y, width: viewRect.width * x, height: viewRect.height * y).integral
            guard CGRect(x: 0, y: 0, width: image.width, height: image.height).contains(crop), let page = image.cropping(to: crop) else { throw PetError("无法裁出网页视口，请重新截图") }
            return (NSImage(cgImage: page, size: viewport), "own-window")
        }
        let configuration = WKSnapshotConfiguration(); configuration.rect = web.bounds
        configuration.snapshotWidth = NSNumber(value: min(1536, Double(viewport.width)))
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            web.takeSnapshot(with: configuration) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? PetError("页面截图失败")) }
            }
        }
        try requireUnlockedSession()
        return (image, "webkit-software")
    }

    func png(marks: [AgentBrowserMark] = []) throws -> Data {
        guard image.size.width.isFinite, image.size.height.isFinite, image.size.width > 0, image.size.height > 0 else { throw PetError("页面截图尺寸无效") }
        let scale = min(1, 1536 / max(image.size.width, image.size.height))
        let width = max(1, Int(image.size.width * scale)), height = max(1, Int(image.size.height * scale))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { throw PetError("页面截图无法绘制") }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        graphics.cgContext.translateBy(x: 0, y: CGFloat(height)); graphics.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: graphics.cgContext, flipped: true)
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        NSColor.white.setFill(); rect.fill()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        AgentBrowserMark.draw(marks, in: rect)
        guard let data = bitmap.representation(using: .png, properties: [:]), data.count <= 20_000_000 else { throw PetError("页面截图超过附件大小上限") }
        return data
    }

    func attach(store: AgentStore, taskID: String, draft: Bool, marks: [AgentBrowserMark] = []) async throws -> AgentAttachment {
        let directory = store.directory.appendingPathComponent(".capture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("网页截图-" + String(UUID().uuidString.prefix(8)) + ".png")
        try png(marks: marks).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var capture = source; capture.annotations = marks.count
        return try await AgentAttachments.importFile(file, store: store, taskID: taskID, draft: draft, capture: capture)
    }
}

@MainActor struct AgentBrowserMark {
    enum Kind: Int, CaseIterable { case rectangle, arrow, pen }
    var kind: Kind
    var points: [CGPoint]

    static func draw(_ marks: [Self], in rect: NSRect) {
        NSColor.systemRed.setStroke()
        for mark in marks {
            let points = mark.points.map { NSPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
            guard let first = points.first, let last = points.last, points.count > 1 else { continue }
            let path = NSBezierPath(); path.lineWidth = 3; path.lineCapStyle = .round; path.lineJoinStyle = .round
            if mark.kind == .rectangle {
                path.appendRect(NSRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y)))
            } else {
                path.move(to: first)
                for point in points.dropFirst() { path.line(to: point) }
                if mark.kind == .arrow {
                    let angle = atan2(last.y - first.y, last.x - first.x)
                    for delta in [-0.5, 0.5] {
                        path.move(to: last); path.line(to: NSPoint(x: last.x - 14 * cos(angle + delta), y: last.y - 14 * sin(angle + delta)))
                    }
                }
            }
            path.stroke()
        }
    }
}
