import AppKit
import WebKit
import ImageIO

struct AgentBrowserRecoveryState: Codable, Equatable, Sendable {
    struct Selection: Codable, Equatable, Sendable {
        var location: Int, length: Int
        func valid(in text: String) -> Bool { location >= 0 && length >= 0 && location <= text.utf16.count && length <= text.utf16.count - location }
    }
    struct Page: Codable, Equatable, Sendable {
        var id: String, title: String
        var url: String?, interaction: Data?
        var origins: [String]
        var zoom: Double, x: Double, y: Double
        var forms: AgentBrowserFormRecovery? = nil
    }
    struct Annotation: Codable, Equatable, Sendable {
        var source: AgentBrowserCapture
        var image: Data
        var marks: [AgentBrowserMark]
        var note: String, tool: Int, focusNote: Bool
        var selection: Selection?
        var frame: AgentWorkspaceRecovery.Frame? = nil
        @MainActor func shot() throws -> AgentBrowserShot {
            guard let encoded = CGImageSourceCreateWithData(image as CFData, nil), CGImageSourceGetCount(encoded) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(encoded, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (1...4096).contains(width), (1...4096).contains(height), let decoded = CGImageSourceCreateImageAtIndex(encoded, 0, nil) else { throw PetError("恢复截图无法读取，原标注已保留") }
            return AgentBrowserShot(image: NSImage(cgImage: decoded, size: NSSize(width: width, height: height)), source: source)
        }
    }
    var version = 1
    var taskID: String
    var pages: [Page], selected: Int
    var address: String, addressEdited: Bool
    var addressSelection: Selection?
    var annotation: Annotation?

    func validate() throws {
        func require(_ pass: Bool) throws { if !pass { throw PetError("浏览器恢复格式无效或版本不受支持，原记录已保留") } }
        try require(version == 1 && UUID(uuidString: taskID) != nil && (1...8).contains(pages.count) && pages.indices.contains(selected))
        try require(Set(pages.map(\.id)).count == pages.count && address.utf8.count <= 8192 && !address.contains("\0") && addressSelection?.valid(in: address) != false)
        for page in pages {
            try require(UUID(uuidString: page.id) != nil && page.title.utf8.count <= 4096 && page.zoom.isFinite && (0.1...5).contains(page.zoom))
            try require([page.x, page.y].allSatisfy { $0.isFinite && (0...1e9).contains($0) } && page.origins.count <= 128 && Set(page.origins).count == page.origins.count)
            for origin in page.origins { try require(AgentBrowser.origin(try AgentBrowser.url(origin)) == origin) }
            if let url = page.url { try require(page.origins.contains(AgentBrowser.origin(try AgentBrowser.url(url)))) }
            else { try require(page.interaction == nil) }
            if let interaction = page.interaction { try require(!interaction.isEmpty && interaction.count <= 4_000_000) }
            try page.forms?.validate(for: page.url)
        }
        if let annotation {
            let source = annotation.source
            _ = try AgentBrowser.url(source.url)
            try require(UUID(uuidString: source.tabID) != nil && source.title.utf8.count <= 4096 && source.created.timeIntervalSince1970.isFinite && source.annotations == 0)
            try require([source.viewportWidth, source.viewportHeight].allSatisfy { $0.isFinite && $0 > 0 && $0 <= 100_000 } && ["own-window", "webkit-software"].contains(source.method ?? ""))
            try require(annotation.image.count <= 8_000_000 && annotation.image.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
            try require(annotation.note.utf8.count <= 64_000 && !annotation.note.contains("\0") && annotation.selection?.valid(in: annotation.note) != false && AgentBrowserMark.Kind(rawValue: annotation.tool) != nil)
            try require(annotation.marks.count <= 10_000 && annotation.marks.reduce(0, { $0 + $1.points.count }) <= 200_000)
            try require(annotation.frame?.valid != false)
            for mark in annotation.marks {
                try require(mark.points.count >= 2 && (mark.kind == .pen || mark.points.count == 2) && mark.points.allSatisfy { $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) })
            }
        }
    }
    static func decode(_ page: AgentWorkspaceRecovery.Page) throws -> Self {
        guard page.kind == "browser", page.asset == nil else { throw PetError("浏览器恢复记录不匹配，原记录已保留") }
        func object(_ value: Any, _ names: [String]) throws -> [String: Any] {
            guard let result = value as? [String: Any], Set(result.keys).isSubset(of: Set(names)) else { throw PetError("浏览器恢复记录包含未知字段，原记录已保留") }; return result
        }
        let root = try object(JSONSerialization.jsonObject(with: page.state), ["version", "taskID", "pages", "selected", "address", "addressEdited", "addressSelection", "annotation"])
        func selection(_ value: Any?) throws { if let value, !(value is NSNull) { _ = try object(value, ["location", "length"]) } }
        try selection(root["addressSelection"])
        for value in root["pages"] as? [Any] ?? [] {
            let page = try object(value, ["id", "title", "url", "interaction", "origins", "zoom", "x", "y", "forms"])
            if let value = page["forms"], !(value is NSNull) {
                let form = try object(value, ["version", "url", "signature", "values"])
                for value in form["values"] as? [Any] ?? [] { _ = try object(value, ["value", "checked", "selected"]) }
            }
        }
        if let value = root["annotation"], !(value is NSNull) {
            let a = try object(value, ["source", "image", "marks", "note", "tool", "focusNote", "selection", "frame"])
            _ = try object(a["source"] ?? NSNull(), ["tabID", "url", "title", "created", "viewportWidth", "viewportHeight", "annotations", "method"])
            try selection(a["selection"])
            if let frame = a["frame"], !(frame is NSNull) { _ = try object(frame, ["x", "y", "width", "height"]) }
            for value in a["marks"] as? [Any] ?? [] { _ = try object(value, ["kind", "points"]) }
        }
        let state = try JSONDecoder().decode(Self.self, from: page.state); try state.validate()
        guard state.taskID == page.taskID, page.dirty == (state.annotation.map { !$0.marks.isEmpty || !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false) else { throw PetError("浏览器恢复归属或标注状态不匹配") }
        return state
    }
    func encodedPage() throws -> AgentWorkspaceRecovery.Page {
        try validate(); let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 12_000_000 else { throw PetError("浏览器恢复记录过大，请先添加标注或关闭部分网页；原记录已保留") }
        return .init(taskID: taskID, kind: "browser", state: data, dirty: annotation.map { !$0.marks.isEmpty || !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false)
    }
}

@MainActor final class AgentBrowserRecoveryEvents: NSObject, WKScriptMessageHandler {
    var onChange: (() -> Void)?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }; onChange?()
    }
    static let script = """
    (()=>{
      let queued=false;
      const changed=()=>{if(queued)return;queued=true;queueMicrotask(()=>{queued=false;window.webkit.messageHandlers.workspaceRecovery.postMessage(null);});};
      for(const event of ['input','change','scroll','selectionchange','focusin','focusout'])document.addEventListener(event,changed,true);
      window.addEventListener('popstate',changed);window.addEventListener('hashchange',changed);
    })();
    """
}
