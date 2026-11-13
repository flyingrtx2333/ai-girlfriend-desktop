import AppKit

struct AgentCanvasVersion: Codable, Sendable { var hash: String; var created = Date() }
struct AgentCanvasRecord: Codable, Identifiable, Sendable {
    var id = UUID().uuidString; var title: String; var hash: String; var created = Date(); var updated = Date(); var versions: [AgentCanvasVersion] = []
    var draft: String?; var draftHash: String?
    var reference: String { "canvas://" + id }
}
struct AgentCanvasCapture: Codable, Sendable {
    var canvasID: String; var title: String; var sourceHash: String; var created = Date(); var annotations = 0
}

@MainActor final class AgentCanvas {
    static let tools = ["canvas_list", "canvas_create", "canvas_read", "canvas_update", "canvas_edit", "canvas_restore", "canvas_inspect", "canvas_screenshot"]
    static let writes: Set<String> = ["canvas_create", "canvas_update", "canvas_edit", "canvas_restore"]
    private weak var store: AgentStore?
    private(set) var windows: [String: AgentCanvasWindow] = [:]
    var onChange: ((String) -> Void)?
    var onPresent: ((AgentCanvasWindow, String, AgentArtifactLocation) throws -> Void)?
    var onDraftCapture: ((String, AgentCanvasShot, [AgentBrowserMark], String) async throws -> Void)?
    init(store: AgentStore) { self.store = store }
    static func definitions() -> [[String: Any]] {
        let string: [String: Any] = ["type": "string"]
        func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] { ["type": "function", "function": ["name": name, "description": description, "parameters": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]] }
        return [tool("canvas_list", "列出本任务持久画布的id、标题及源码hash；不需要项目。", [:], []),
            tool("canvas_create", "创建并预览本任务独立.canvas.tsx画布，不修改项目文件。source可省略，先创建标题组件，再canvas_read和canvas_edit分步完善；提供source时须export default React组件，可import react、recharts。禁止联网、外部模块、文件及原生接口。返回id/hash及实际渲染结果；编译失败仍保留源码供修正。", ["title": string, "source": string], ["title"]),
            tool("canvas_read", "读取本任务画布完整TSX源码、实际hash和最近版本；修改前先读取，不可使用其他任务id。", ["id": string], ["id"]),
            tool("canvas_update", "用完整TSX源码更新本任务画布并实时预览。expected_hash取canvas_read实际值，冲突时重读；原版本保留。大源码优先canvas_edit。", ["id": string, "source": string, "expected_hash": string], ["id", "source", "expected_hash"]),
            tool("canvas_edit", "精确替换画布中唯一old_text为new_text，沿用expected_hash；适合小输出预算分步编辑。保存版本并实际重新渲染。", ["id": string, "old_text": string, "new_text": string, "expected_hash": string], ["id", "old_text", "new_text", "expected_hash"]),
            tool("canvas_restore", "恢复canvas_read返回的version_hash，当前内容保留为历史；expected_hash核对当前源码。仅修改本任务画布。", ["id": string, "version_hash": string, "expected_hash": string], ["id", "version_hash", "expected_hash"]),
            tool("canvas_inspect", "打开画布并读取实际渲染文字、可见控件及图表数量；返回源码hash与渲染错误。不是执行成功的替代证据，数值须与原数据独立核对。", ["id": string], ["id"]),
            tool("canvas_screenshot", "截取本任务画布当前可见视口，保存实际图片附件；开启视觉时携图。用于核对布局、颜色及交互状态，不发送整屏或其他窗口。", ["id": string], ["id"])]
    }
    func record(_ id: String, taskID: String) throws -> AgentCanvasRecord {
        guard let record = store?.task(taskID)?.canvases?.first(where: { $0.id == id }) else { throw PetError("此画布不属于当前任务") }; return record
    }
    func directory(_ id: String, taskID: String) throws -> URL {
        guard UUID(uuidString: id) != nil, UUID(uuidString: taskID) != nil, let store else { throw PetError("画布编号无效") }
        return store.directory.appendingPathComponent(taskID).appendingPathComponent("canvases").appendingPathComponent(id)
    }
    func source(_ id: String, taskID: String) throws -> (record: AgentCanvasRecord, code: String) {
        var record = try record(id, taskID: taskID)
        let files = try AgentFiles(workspace: directory(id, taskID: taskID).path), url = try files.literalURL("document.canvas.tsx")
        guard try files.entryMetadata(url).kind == "file" else { throw PetError("画布源码不可用或已变成链接") }
        let data = try files.readData(url, maximum: 256_000)
        guard let code = String(data: data, encoding: .utf8), !data.contains(0) else { throw PetError("画布源码必须是有效UTF-8文字") }
        let hash = AgentFiles.hash(data)
        if record.hash != hash {
            try version(data, files: files); record.hash = hash; record.updated = Date(); record.versions.append(AgentCanvasVersion(hash: hash)); record.versions = Array(record.versions.suffix(50))
            store?.update(taskID) { task in if let i = task.canvases?.firstIndex(where: { $0.id == id }) { task.canvases?[i] = record } }
            if let error = store?.writeError { throw PetError("画布版本未保存：" + error) }; onChange?(taskID)
        }
        return (record, code)
    }
    private func version(_ data: Data, files: AgentFiles) throws {
        let hash = AgentFiles.hash(data), path = files.root.appendingPathComponent("versions/" + hash + ".canvas.tsx")
        if (try? files.readData(path, maximum: 256_000)).map(AgentFiles.hash) != hash { try files.writeData(data, to: path, permissions: 0o600) }
    }
    private func validate(_ source: String) throws -> Data {
        let data = Data(source.utf8); guard !data.isEmpty, data.count <= 256_000, !data.contains(0) else { throw PetError("画布源码不能为空，且不超过256KB") }; return data
    }
    private func writable(_ taskID: String) throws -> AgentTaskRecord {
        guard let store, let task = store.task(taskID), !task.archived, task.kind != "wiki", task.kind != "hook", task.queuedCount == 0 else { throw PetError("任务状态已变化，画布未保存") }
        if let error = store.writeError { throw PetError("任务未保存：" + error) }; return task
    }
    @discardableResult func create(title: String, source: String? = nil, taskID: String) throws -> AgentCanvasRecord {
        let task = try writable(taskID)
        guard (task.canvases?.count ?? 0) < 32 else { throw PetError("每个任务最多32份画布") }
        let title = title.components(separatedBy: .controlCharacters).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120 else { throw PetError("请提供120字以内的画布名称") }
        let literal = String(String(decoding: try JSONSerialization.data(withJSONObject: [title]), as: UTF8.self).dropFirst().dropLast())
        let starter = "export default function Canvas(){return <main><h1>{" + literal + "}</h1></main>}"
        let data = try validate(source ?? starter)
        var record = AgentCanvasRecord(title: title, hash: AgentFiles.hash(data)); record.versions = [AgentCanvasVersion(hash: record.hash)]
        let directory = try directory(record.id, taskID: taskID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files = try AgentFiles(workspace: directory.path)
        do {
            try version(data, files: files); try files.writeData(data, to: directory.appendingPathComponent("document.canvas.tsx"), permissions: 0o600)
            store?.update(taskID) { if $0.canvases == nil { $0.canvases = [] }; $0.canvases?.append(record) }
            if let error = store?.writeError { throw PetError("画布记录未保存：" + error) }
        } catch { store?.update(taskID, persist: false) { $0.canvases = task.canvases }; throw error }
        onChange?(taskID); return record
    }
    @discardableResult func update(_ id: String, source: String, expected: String, taskID: String) throws -> AgentCanvasRecord {
        _ = try writable(taskID); let current = try self.source(id, taskID: taskID), data = try validate(source)
        guard current.record.hash == expected else { throw PetError("画布已被其他操作修改，请重新读取后编辑") }
        let files = try AgentFiles(workspace: directory(id, taskID: taskID).path), url = try files.literalURL("document.canvas.tsx"), signature = try files.entryMetadata(url).signature
        guard AgentFiles.hash(try files.readData(url, maximum: 256_000)) == expected else { throw PetError("画布已变化，未覆盖其他编辑") }
        try version(Data(current.code.utf8), files: files); try version(data, files: files)
        try files.writeData(data, to: url, permissions: 0o600, expectedTarget: signature)
        return try self.source(id, taskID: taskID).record
    }
    func restore(_ id: String, version hash: String, expected: String, taskID: String) throws -> AgentCanvasRecord {
        let current = try source(id, taskID: taskID)
        guard current.record.versions.contains(where: { $0.hash == hash }), hash.count == 64, hash.allSatisfy(\.isHexDigit) else { throw PetError("此画布没有该历史版本") }
        let files = try AgentFiles(workspace: directory(id, taskID: taskID).path), data = try files.readData(files.literalURL("versions/" + hash + ".canvas.tsx"), maximum: 256_000)
        guard AgentFiles.hash(data) == hash, let code = String(data: data, encoding: .utf8) else { throw PetError("历史源码校验失败") }
        return try update(id, source: code, expected: expected, taskID: taskID)
    }
    func copyForFork(sourceID: String, targetID: String, records: [AgentCanvasRecord], historical: Bool = false) throws {
        var created: [URL] = []
        do {
            for record in records {
                if historical {
                    let from = try AgentFiles(workspace: directory(record.id, taskID: sourceID).path), target = try directory(record.id, taskID: targetID)
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); created.append(target)
                    let files = try AgentFiles(workspace: target.path)
                    for hash in Set(record.versions.map(\.hash) + [record.hash]) {
                        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { throw PetError("历史画布版本无效") }
                        let data = try from.readData(from.literalURL("versions/" + hash + ".canvas.tsx"), maximum: 256_000)
                        guard AgentFiles.hash(data) == hash else { throw PetError("历史画布源码校验失败") }
                        try files.writeData(data, to: files.literalURL("versions/" + hash + ".canvas.tsx"), permissions: 0o600)
                        if hash == record.hash { try files.writeData(data, to: files.literalURL("document.canvas.tsx"), permissions: 0o600) }
                    }; continue
                }
                _ = try source(record.id, taskID: sourceID)
                let source = try directory(record.id, taskID: sourceID), target = try directory(record.id, taskID: targetID)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.default.copyItem(at: source, to: target); created.append(target)
            }
        } catch { for target in created { try? FileManager.default.removeItem(at: target) }; throw error }
    }
    func show(_ id: String, taskID: String, location: AgentArtifactLocation = .workspace) async throws -> AgentCanvasWindow {
        guard let store, let task = store.task(taskID), !task.archived else { throw PetError("任务不存在或已归档") }
        _ = try record(id, taskID: taskID)
        let window: AgentCanvasWindow, key = taskID + ":" + id, created: Bool
        if let existing = windows[key] { window = existing; created = false }
        else {
            guard windows.count < 4 else { throw PetError("最多同时打开4个画布，请先关闭一个") }
            window = AgentCanvasWindow(canvas: self, taskID: taskID); created = true
            window.onClose = { [weak self] in self?.windows[key] = nil }; windows[key] = window
        }
        do { try onPresent?(window, id, location) } catch { if created { window.finishClose() }; throw error }
        try await window.open(id); return window
    }
    func stop(_ taskID: String) { for window in windows.values where window.taskID == taskID { window.stop() } }
    func close(_ taskID: String) { for window in Array(windows.values) where window.taskID == taskID { window.finishClose() } }
    func closeAll() { for window in Array(windows.values) { window.finishClose() } }
    func canQuit() async -> Bool {
        for editor in Array(windows.values) where editor.settingsHostWindow == nil {
            editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil)
            guard await editor.prepareForWorkspaceClose() else { return false }
        }
        return true
    }
    func records(_ taskID: String) -> [AgentCanvasRecord] { store?.task(taskID)?.canvases ?? [] }
    func sourceURL(_ id: String, taskID: String) throws -> URL { try directory(id, taskID: taskID).appendingPathComponent("document.canvas.tsx") }
    @discardableResult func saveDraft(_ text: String?, hash: String?, id: String, taskID: String) -> Bool {
        guard (text?.utf8.count ?? 0) <= 256_000, (try? record(id, taskID: taskID)) != nil else { return false }
        store?.update(taskID) { task in
            if let index = task.canvases?.firstIndex(where: { $0.id == id }) { task.canvases?[index].draft = text; task.canvases?[index].draftHash = hash }
        }
        return store?.writeError == nil
    }
    func submit(_ shot: AgentCanvasShot, taskID: String, marks: [AgentBrowserMark], note: String) async throws {
        guard let handler = onDraftCapture else { throw PetError("任务窗口未准备好") }
        _ = try record(shot.capture.canvasID, taskID: taskID)
        try await handler(taskID, shot, marks, note)
    }
    private func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self) }
    private func metadata(_ record: AgentCanvasRecord) -> [String: Any] { ["id": record.id, "title": record.title, "hash": record.hash, "reference": record.reference, "versions": record.versions.suffix(12).map { ["hash": $0.hash, "created": ISO8601DateFormatter().string(from: $0.created)] }] }
    func execute(_ call: AgentToolCall, task: AgentTaskRecord) async throws -> AgentToolResult {
        try Task.checkCancellation()
        let args = call.object, id = args["id"] as? String ?? ""
        if call.name == "canvas_list" { return AgentToolResult(text: try json(["canvases": records(task.id).map(metadata)])) }
        if call.name == "canvas_read" { let value = try source(id, taskID: task.id); var data = metadata(value.record); data["source"] = value.code; return AgentToolResult(text: try json(data)) }
        let record: AgentCanvasRecord
        switch call.name {
        case "canvas_create": record = try create(title: args["title"] as? String ?? "", source: args["source"] as? String, taskID: task.id)
        case "canvas_update": record = try update(id, source: args["source"] as? String ?? "", expected: args["expected_hash"] as? String ?? "", taskID: task.id)
        case "canvas_edit":
            let value = try source(id, taskID: task.id), old = args["old_text"] as? String ?? "", new = args["new_text"] as? String ?? ""
            guard !old.isEmpty, value.code.components(separatedBy: old).count == 2 else { throw PetError("旧文本必须存在且唯一") }
            record = try update(id, source: value.code.replacingOccurrences(of: old, with: new), expected: args["expected_hash"] as? String ?? "", taskID: task.id)
        case "canvas_restore": record = try restore(id, version: args["version_hash"] as? String ?? "", expected: args["expected_hash"] as? String ?? "", taskID: task.id)
        default: record = try self.record(id, taskID: task.id)
        }
        do {
            let window = try await show(record.id, taskID: task.id); try Task.checkCancellation()
            if call.name == "canvas_screenshot", let store {
                let shot = try await window.screenshot(), file = try await shot.attach(store: store, taskID: task.id, draft: false)
                return AgentToolResult(text: try json(["id": record.id, "hash": shot.capture.sourceHash, "attachment_id": file.id, "actual_viewport": true]), visuals: [AgentVisualPart(id: file.id, part: 1)])
            }
            let observed = try await window.inspect(); var result = metadata(try self.record(record.id, taskID: task.id)); result["rendered"] = observed
            if observed["error"] == nil {
                do { try cachePreview(try await window.screenshot(), taskID: task.id) }
                catch { if Task.isCancelled { throw CancellationError() }; result["preview_error"] = error.localizedDescription }
            }
            return AgentToolResult(text: try json(result), failed: observed["error"] as? String != nil)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            var result = metadata(record); result["render_error"] = error.localizedDescription; return AgentToolResult(text: try json(result), failed: true)
        }
    }
}

@MainActor struct AgentCanvasShot {
    var image: NSImage; var capture: AgentCanvasCapture
    var annotationShot: AgentBrowserShot { AgentBrowserShot(image: image, source: AgentBrowserCapture(tabID: capture.canvasID, url: "canvas://" + capture.canvasID, title: capture.title, created: capture.created, viewportWidth: image.size.width, viewportHeight: image.size.height, method: "canvas")) }
    func attach(store: AgentStore, taskID: String, draft: Bool, marks: [AgentBrowserMark] = []) async throws -> AgentAttachment {
        let folder = store.directory.appendingPathComponent(".canvas-capture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("画布截图.png"); try annotationShot.png(marks: marks).write(to: file, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var source = capture; source.annotations = marks.count
        return try await AgentAttachments.importFile(file, store: store, taskID: taskID, draft: draft, canvasCapture: source)
    }
}
