import AppKit

struct AgentOfficeSnapshot: Sendable {
    var folder: URL, file: URL, hash: String, signature: String, permissions: Int
}
struct AgentOfficeEditError: LocalizedError {
    let code: String, message: String
    var errorDescription: String? { message }
}

@MainActor final class AgentOffice {
    nonisolated static let maximum = 500 * 1024 * 1024
    static let formats = ["docx", "xlsx", "pptx"]
    static let tools = ["office_read", "office_create", "office_edit"]
    static let writes: Set<String> = ["office_create", "office_edit"]
    private weak var store: AgentStore?
    private(set) var windows: [String: AgentOfficeWindow] = [:]
    var onPresent: ((AgentOfficeWindow, AgentArtifactLocation) throws -> Void)?
    init(store: AgentStore) { self.store = store }
    static func supports(_ path: String) -> Bool { formats.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) }
    static func definitions() -> [[String: Any]] {
        let string: [String: Any] = ["type": "string"], integer: [String: Any] = ["type": "integer"]
        func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "function", "function": ["name": name, "description": description, "parameters": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]]
        }
        return [tool("office_read", "在内置编辑器打开项目内DOCX/XLSX/PPTX并读取实际内容、sha256、version及编辑格式。Word/幻灯片offset从0分页；Excel可选sheet名称和不超过256格的A1范围range，默认A1:H20。不读取未保存的人工编辑；重要结果保存后重读核对。", ["path": string, "offset": integer, "limit": integer, "sheet": string, "range": string], ["path"]),
            tool("office_create", "在当前项目新建空白DOCX/XLSX/PPTX并打开内置编辑器，拒绝覆盖已有文件。随后office_read读取实际目标与version，再office_edit填入内容。", ["path": string], ["path"]),
            tool("office_edit", "编辑并保存刚由office_read读取的办公文件。expected_hash取实际sha256；edits是JSON字符串，遵循该格式返回的edit_format，expectVersion取实际version。修改后重新office_read核对。冲突或未保存人工编辑时拒绝覆盖，不执行脚本。", ["path": string, "expected_hash": string, "edits": string], ["path", "expected_hash", "edits"])]
    }
    func file(_ path: String, taskID: String) throws -> (AgentFiles, URL) {
        guard let store, let task = store.task(taskID) else { throw PetError("请先选择项目文件夹") }
        let (files,url) = try AgentWorkspaceScope.location(task,path:path,literal:true)
        guard Self.supports(url.path), !AgentFiles.sensitive(files.relative(url)) else { throw PetError("请选择项目中的DOCX、XLSX或PPTX文件") }
        let privateRoot = store.directory.deletingLastPathComponent().resolvingSymlinksInPath().path
        let value = url.path.lowercased(), protected = [privateRoot.lowercased(), Bundle.main.bundleURL.resolvingSymlinksInPath().path.lowercased()]
        guard !protected.contains(where: { value == $0 || value.hasPrefix($0 + "/") }) else { throw PetError("不能通过办公工具访问应用私有文件") }
        return (files, url)
    }
    func task(_ id: String, root: URL, agentWrite: Bool = false, manualWrite: Bool = false, allowCapture: Bool = false) throws -> AgentTaskRecord {
        guard let store, let task = store.task(id), task.kind != "hook", task.kind != "wiki",
              try AgentWorkspaceScope.roots(task).contains(where:{$0.root == root}) else { throw PetError("任务项目已变化，请先保留编辑内容") }
        if (agentWrite || manualWrite) && task.archived { throw PetError("任务已归档，请先取消归档再保存") }
        if agentWrite {
            guard ![.ask, .plan].contains(task.mode), try !store.agents.limits(task, store: store).readOnly, task.queuedCount == 0 else { throw PetError("当前任务只读或要求已变化，办公文件未保存") }
        }
        if manualWrite {
            let otherWorking = store.tasks.contains { record in
                guard record.id != id, [.running, .waiting].contains(record.status) else { return false }
                return record.workspacePaths.contains{AgentWorktreeRetention.within($0,root.path) || AgentWorktreeRetention.within(root.path,$0)}
            }
            guard task.status != .running, task.status != .waiting, task.pendingFileCapture == nil || allowCapture, task.queuedCount == 0, !otherWorking else { throw PetError("请先停止此项目中的任务并处理待确认操作，再编辑办公文件") }
        }
        if let error = store.writeError { throw PetError("任务记录未保存：" + error) }; return task
    }
    @discardableResult func show(_ path: String, taskID: String, location: AgentArtifactLocation = .workspace) async throws -> AgentOfficeWindow {
        let (files, url) = try file(path, taskID: taskID)
        _ = try task(taskID, root: files.root)
        if let existing = windows[url.path] {
            guard existing.taskID == taskID else {
                if let onPresent { try onPresent(existing, existing.settingsHostWindow == nil ? .window : .workspace) } else { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil) }
                throw PetError("此文件已在另一个任务打开，请先保存并关闭")
            }
            try onPresent?(existing, location)
            try await existing.open(); return existing
        }
        guard windows.count < 4, let store else { throw PetError("最多同时打开4份办公文件，请先关闭一份") }
        let window = AgentOfficeWindow(office: self, store: store, taskID: taskID, files: files, file: url)
        windows[url.path] = window
        window.onClose = { [weak self, weak window] in if self?.windows[url.path] === window { self?.windows[url.path] = nil } }
        do { try onPresent?(window, location) } catch { window.finishClose(); throw error }
        try await window.open(); return window
    }
    func changed(_ taskID: String) { for window in windows.values { window.updateAvailability() } }
    func unsavedReason(task:AgentTaskRecord) -> String? { task.workspacePaths.compactMap{unsavedReason(workspace:$0)}.first }
    func unsavedReason(workspace: String?) -> String? {
        guard let workspace, let files = try? AgentFiles(workspace: workspace) else { return nil }
        let related = windows.values.filter { AgentWorktreeRetention.within($0.files.root.path, files.root.path) || AgentWorktreeRetention.within(files.root.path, $0.files.root.path) }
        let names = related.filter(\.dirty).map { $0.file.lastPathComponent }.sorted()
        if !names.isEmpty { return "请先保存或关闭未保存的办公文档：" + names.joined(separator: "、") }
        return related.contains(where: \.working) ? "办公文件正在处理，请稍候" : nil
    }
    var hasWindows: Bool { !windows.isEmpty }
    func prepareForExecution(workspace: String?) async throws {
        guard let workspace else { return }
        for window in windows.values where AgentWorktreeRetention.within(window.files.root.path, workspace) || AgentWorktreeRetention.within(workspace, window.files.root.path) {
            try await window.verifyClean()
            guard !window.dirty else { throw PetError("请先保存或关闭办公文档：" + window.file.lastPathComponent) }
        }
    }
    func canQuit() async -> Bool {
        if windows.values.contains(where: \.working) { let alert = AgentConfirmation(); alert.messageText = "办公文件正在处理，请稍后退出"; alert.addButton(withTitle: "继续"); alert.runModal(); return false }
        for window in windows.values { do { try await window.verifyClean() } catch { if window.dirty { continue }; let alert = AgentConfirmation(); alert.messageText = "办公文件尚未就绪，请关闭其窗口后退出"; alert.addButton(withTitle: "继续"); alert.runModal(); return false } }
        let unsaved = windows.values.filter(\.dirty)
        guard !unsaved.isEmpty else { return true }
        if AgentUnsavedChanges.discard("仍有未保存的办公文档", detail: unsaved.map { $0.file.lastPathComponent }.sorted().joined(separator: "\n"), discardTitle: "放弃更改并退出") { return true }
        if let first = unsaved.first { if let onPresent { try? onPresent(first, first.settingsHostWindow == nil ? .window : .workspace) } else { first.showWindow(nil); first.window?.makeKeyAndOrderFront(nil) } }; return false
    }
    func closeAll() { for window in Array(windows.values) { window.finishClose() }; windows.removeAll() }
    func stop(_ taskID: String) { for window in windows.values where window.taskID == taskID { window.cancelToolOperation() } }
    func requireDeletionAllowed(_ ids: Set<String>) throws {
        if windows.values.contains(where: { ids.contains($0.taskID) && ($0.dirty || $0.working) }) { throw PetError("请先保存或关闭此任务未保存或正在处理的办公文档") }
    }
    func closeDeletedTask(_ id: String) { for window in Array(windows.values) where window.taskID == id { window.finishClose() } }
    nonisolated static func snapshot(files: AgentFiles, file: URL) throws -> AgentOfficeSnapshot {
        let metadata = try files.entryMetadata(file)
        guard metadata.kind == "file" else { throw PetError("办公文件不存在或已变成链接") }
        var temporary = FileManager.default.temporaryDirectory
        if let index = CommandLine.arguments.firstIndex(of: "--check") {
            guard CommandLine.arguments.indices.contains(index + 1) else { throw PetError("缺少独立验收目录") }
            temporary = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true).appendingPathComponent("tmp", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let folder = temporary.appendingPathComponent("bluefatfish-office-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let snapshots = try AgentFiles(workspace: folder.path), copy = folder.appendingPathComponent("document." + file.pathExtension)
            let hash = try snapshots.copyFile(file, from: files, to: copy, permissions: 0o400, maximum: maximum)
            guard try files.entryMetadata(file).signature == metadata.signature else { throw PetError("打开期间文件已变化，请重试") }
            return AgentOfficeSnapshot(folder: folder, file: copy, hash: hash, signature: metadata.signature, permissions: metadata.permissions ?? 0o644)
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    func recordWrite(_ window: AgentOfficeWindow, source: URL, agent: Bool, expected: String) async throws -> (String, String) {
        guard let store else { throw PetError("任务存储不可用") }
        _ = try task(window.taskID, root: window.files.root, agentWrite: agent, manualWrite: !agent)
        var written: (String, String)?
        _ = try await store.projectChanges.observe(taskID: window.taskID, origin: agent ? "办公工具" : "办公编辑", paths: [window.file.path], requireCheckpoint: true) {
            _ = try self.task(window.taskID, root: window.files.root, agentWrite: agent, manualWrite: !agent, allowCapture: true)
            try Task.checkCancellation()
            let files = window.files, file = window.file, signature = window.openedSignature, permissions = window.openedPermissions
            written = try await Task.detached(priority: .userInitiated) {
                guard try files.entryMetadata(file).signature == signature, try files.fileHash(file, maximum: Self.maximum) == expected else { throw PetError("磁盘文件已变化，未覆盖其他编辑；可另存为新文件") }
                let temporary = try AgentFiles(workspace: source.deletingLastPathComponent().path)
                let hash = try files.copyFile(source, from: temporary, to: file, permissions: permissions, expectedTarget: signature, maximum: Self.maximum)
                let after = try files.entryMetadata(file); guard try files.fileHash(file, maximum: Self.maximum) == hash else { throw PetError("保存后的文件再次变化，请核对磁盘内容") }
                return (hash, after.signature)
            }.value
            return AgentToolResult(text: "已保存 " + files.relative(file), artifacts: [file.path])
        }
        guard let written else { throw PetError("办公文件未写入") }
        store.update(window.taskID) { if !$0.artifacts.contains(window.file.path) { $0.artifacts.append(window.file.path) } }; return written
    }
    @discardableResult func create(_ path: String, taskID: String, agent: Bool = false) async throws -> AgentOfficeWindow {
        guard let store else { throw PetError("任务存储不可用") }
        let (files, url) = try file(path, taskID: taskID)
        _ = try task(taskID, root: files.root, agentWrite: agent, manualWrite: !agent)
        guard windows.count < 4 else { throw PetError("最多同时打开4份办公文件，请先关闭一份") }
        guard let template = Bundle.main.resourceURL?.appendingPathComponent("web/office/templates/blank." + url.pathExtension.lowercased()) else { throw PetError("空白文档资源缺失") }
        _ = try await store.projectChanges.observe(taskID: taskID, origin: agent ? "办公工具" : "新建办公文件", paths: [url.path], requireCheckpoint: true) {
            _ = try self.task(taskID, root: files.root, agentWrite: agent, manualWrite: !agent, allowCapture: true)
            try Task.checkCancellation()
            try await Task.detached {
                guard try files.entryMetadata(url).kind == "missing" else { throw PetError("文件已存在，请使用新的名称") }
                let resources = try AgentFiles(workspace: template.deletingLastPathComponent().path)
                try files.copyFile(template, from: resources, to: url, permissions: 0o644, expectedTarget: "missing", maximum: Self.maximum)
            }.value
            return AgentToolResult(text: "已创建 " + files.relative(url), artifacts: [url.path])
        }
        store.update(taskID) { if !$0.artifacts.contains(url.path) { $0.artifacts.append(url.path) } }
        return try await show(url.path, taskID: taskID)
    }
    func execute(_ call: AgentToolCall, task: AgentTaskRecord) async throws -> AgentToolResult {
        guard let path = call.object["path"] as? String else { throw PetError("缺少办公文件路径") }
        let window: AgentOfficeWindow
        if call.name == "office_create" { window = try await create(path, taskID: task.id, agent: true) }
        else { window = try await show(path, taskID: task.id) }
        try Task.checkCancellation(); try await window.prepareForTool()
        if call.name == "office_edit" {
            _ = try self.task(task.id, root: window.files.root, agentWrite: true)
            guard let hash = call.object["expected_hash"] as? String, hash == window.openedHash,
                  let edits = call.object["edits"] as? String, edits.utf8.count <= 64_000, let data = edits.data(using: .utf8),
                  let request = try JSONSerialization.jsonObject(with: data) as? [String: Any], request["expectVersion"] is String,
                  let steps = request["steps"] as? [[String: Any]], !steps.isEmpty, steps.count <= 64 else { throw PetError("请先office_read，再提供实际sha256、version及1至64项编辑") }
            try await window.applyAndSave(request, expected: hash)
        }
        var result = try await window.inspect(call.object)
        result["path"] = window.file.path; result["sha256"] = window.openedHash; result["format"] = window.file.pathExtension.lowercased()
        switch window.file.pathExtension.lowercased() {
        case "docx": result["edit_format"] = "{expectVersion:version,steps:[{op:'replaceText',target:{kind:'search',within:{kind:'paragraph',story:story,paraId:id},text:old,view:'accepted'},text:new,expect:{text:old}}]}; 空段落可用target:{kind:'paragraph',story,paraId:id}和expect:{text:''}。"
        case "xlsx": result["edit_format"] = "{expectVersion:version,steps:[{op:'setCellInputs',target:{sheetId:sheet,range:{kind:'a1',a1:'A1'}},inputs:[[newInput]]}]}; inputs为用户输入字符串，公式以=开头。"
        default: result["edit_format"] = "{expectVersion:version,steps:[{op:'replaceText',target:{kind:'search',within:{slideId,shapeId,storyId:id},text:old},text:new,expect:{text:old}}]}"
        }
        let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
        guard encoded.count <= 60_000 else { throw PetError("读取结果过大，请缩小范围或分页读取") }
        return AgentToolResult(text: String(decoding: encoded, as: UTF8.self), artifacts: Self.writes.contains(call.name) ? [window.file.path] : [], sources: [window.file.absoluteString])
    }
}
