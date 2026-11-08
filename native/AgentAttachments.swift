import Foundation
import Darwin

struct AgentAttachment: Codable, Identifiable, Sendable {
    var id = UUID().uuidString
    var name: String; var fileExtension: String; var bytes: Int; var sha256: String; var modified: Date
    var totalParts: Int; var partial: Bool; var width: Int?; var height: Int?
    var partTitles: [String]?
    var notes: [String]?
    var browserCapture: AgentBrowserCapture?
    var mcpSource: AgentMCPAttachmentSource?
    var desktopCapture: AgentDesktopCapture?
    var canvasCapture: AgentCanvasCapture?
}

@MainActor enum AgentAttachments {
    static func directory(store: AgentStore, taskID: String, id: String) throws -> URL {
        guard UUID(uuidString: taskID) != nil, UUID(uuidString: id) != nil else { throw PetError("附件编号无效") }
        return store.directory.appendingPathComponent(taskID, isDirectory: true).appendingPathComponent("attachments", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }
    static func record(store: AgentStore, taskID: String, id: String) throws -> AgentAttachment {
        guard let file = store.task(taskID)?.attachments?.first(where: { $0.id == id }) else { throw PetError("当前任务没有这个附件") }
        return file
    }
    static func source(store: AgentStore, taskID: String, id: String) throws -> URL {
        let file = try record(store: store, taskID: taskID, id: id)
        guard AgentDocument.textTypes.contains(file.fileExtension) || AgentDocument.imageTypes.contains(file.fileExtension) || ["pdf", "docx", "xlsx", "pptx"].contains(file.fileExtension) || (file.mcpSource != nil && AgentMCPContent.opaqueTypes.contains(file.fileExtension)) else { throw PetError("附件类型无效") }
        let url = try directory(store: store, taskID: taskID, id: id).appendingPathComponent("source." + file.fileExtension)
        let metadata = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey])
        guard metadata.isSymbolicLink != true, metadata.fileSize == file.bytes, metadata.contentModificationDate == file.modified else { throw PetError("附件已被外部修改，请重新添加") }
        return url
    }
    static func content(store: AgentStore, taskID: String, id: String) throws -> AgentDocumentContent {
        _ = try source(store: store, taskID: taskID, id: id)
        let root = try directory(store: store, taskID: taskID, id: id), files = try AgentFiles(workspace: root.path)
        return try JSONDecoder().decode(AgentDocumentContent.self, from: files.readData(root.appendingPathComponent("content.json"), maximum: 2_000_000))
    }
    static func importFile(_ original: URL, store: AgentStore, taskID: String, draft: Bool = true, capture: AgentBrowserCapture? = nil, mcpSource: AgentMCPAttachmentSource? = nil, desktopCapture: AgentDesktopCapture? = nil, canvasCapture: AgentCanvasCapture? = nil) async throws -> AgentAttachment {
        guard let task = store.task(taskID), task.kind != "wiki", !task.archived else { throw PetError("当前任务不能添加附件") }
        guard !draft || (task.draftAttachmentIDs?.count ?? 0) < 6 else { throw PetError("每条消息最多 6 个附件") }
        if let error = store.writeError { throw PetError("任务尚未保存：" + error) }
        let selected = original.standardizedFileURL.resolvingSymlinksInPath(), type = selected.pathExtension.lowercased()
        guard !AgentFiles.sensitive(selected.lastPathComponent), AgentDocument.textTypes.contains(type) || AgentDocument.imageTypes.contains(type) || ["pdf", "docx", "xlsx", "pptx"].contains(type) || (mcpSource != nil && AgentMCPContent.opaqueTypes.contains(type)) else { throw PetError("不支持此类型或属于凭据文件") }
        let id = UUID().uuidString, destination = try directory(store: store, taskID: taskID, id: id)
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".import-" + id, isDirectory: true)
        let job = Task.detached(priority: .utility) { () async throws -> AgentAttachment in
            try Task.checkCancellation()
            let fm = FileManager.default
            try fm.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var moved = false; defer { if !moved { try? fm.removeItem(at: stage) } }
            let files = try AgentFiles(workspace: selected.deletingLastPathComponent().path), local = stage.appendingPathComponent("source." + type)
            let copied: (Int, String) = try {
                let data = try files.readData(selected, maximum: 20_000_000)
                try data.write(to: local, options: .atomic); try preserveQuarantine(from: selected, to: local)
                try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: local.path)
                return (data.count, AgentFiles.hash(data))
            }()
            let scratch = stage.appendingPathComponent("parser-tmp", isDirectory: true)
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let document: AgentDocumentContent
            if mcpSource != nil, AgentMCPContent.opaqueTypes.contains(type) {
                document = AgentDocumentContent(format: type, parts: [.init(title: "文件", text: "")], totalParts: 1, notes: [type == "gz" ? "压缩数据未展开，不能据此推断文件内容" : ["wav", "mp3", "m4a", "ogg", "flac", "aac"].contains(type) ? "音频尚未转写或发送给模型，不能声称已经收听" : "二进制内容未解析，不能据此推断内容"])
            } else { document = try await AgentDocument.extract(local, scratch: scratch) }
            try Task.checkCancellation()
            let cache = stage.appendingPathComponent("content.json")
            try JSONEncoder().encode(document).write(to: cache, options: .atomic); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cache.path)
            var width: Int?, height: Int?
            if AgentDocument.imageTypes.contains(type) {
                let image = try AgentDocument.image(local), preview = stage.appendingPathComponent("preview.jpg")
                try image.jpeg.write(to: preview, options: .atomic); try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: preview.path)
                width = image.width; height = image.height
            }
            let modified = try local.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            try fm.moveItem(at: stage, to: destination); moved = true
            return AgentAttachment(id: id, name: original.lastPathComponent, fileExtension: type, bytes: copied.0, sha256: copied.1, modified: modified, totalParts: document.totalParts, partial: document.partial, width: width, height: height, partTitles: document.parts.map(\.title), notes: document.notes, browserCapture: capture, mcpSource: mcpSource, desktopCapture: desktopCapture, canvasCapture: canvasCapture)
        }
        let file = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
        do {
            try Task.checkCancellation()
            guard let previous = store.task(taskID), previous.kind != "wiki", !previous.archived else { throw PetError("任务状态已变化，附件未添加") }
            guard !draft || (previous.draftAttachmentIDs?.count ?? 0) < 6 else { throw PetError("每条消息最多 6 个附件") }
            store.update(taskID, persist: false) { record in
                if record.attachments == nil { record.attachments = [] }; record.attachments?.append(file)
                if draft { if record.draftAttachmentIDs == nil { record.draftAttachmentIDs = [] }; record.draftAttachmentIDs?.append(file.id) }
            }
            do { try store.save(taskID) }
            catch { store.update(taskID, persist: false) { $0.attachments = previous.attachments; $0.draftAttachmentIDs = previous.draftAttachmentIDs }; throw error }
            return file
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    static func removeDraft(store: AgentStore, taskID: String, id: String) throws {
        guard let task = store.task(taskID) else { throw PetError("任务不存在") }
        let used = task.messages.contains { $0.attachmentIDs?.contains(id) == true || $0.visuals?.contains(where: { $0.id == id }) == true }
        store.update(taskID, persist: false) { record in record.draftAttachmentIDs?.removeAll { $0 == id }; if !used { record.attachments?.removeAll { $0.id == id } } }
        do { try store.save(taskID) }
        catch { store.update(taskID, persist: false) { $0.attachments = task.attachments; $0.draftAttachmentIDs = task.draftAttachmentIDs }; throw error }
        if !used { try FileManager.default.removeItem(at: directory(store: store, taskID: taskID, id: id)) }
    }
    static func part(store: AgentStore, taskID: String, id: String, number: Int) async throws -> AgentDocumentPart {
        let file = try record(store: store, taskID: taskID, id: id), document = try content(store: store, taskID: taskID, id: id)
        guard number > 0, number <= file.totalParts else { throw PetError("附件页码或工作表编号无效") }
        if document.parts.indices.contains(number - 1), !document.parts[number - 1].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || document.parts[number - 1].ocr == true { return document.parts[number - 1] }
        guard file.fileExtension == "pdf" else {
            guard document.parts.indices.contains(number - 1) else { throw PetError("该部分超出提取范围") }; return document.parts[number - 1]
        }
        let root = try directory(store: store, taskID: taskID, id: id), cache = root.appendingPathComponent("part-\(number).json"), files = try AgentFiles(workspace: root.path)
        if FileManager.default.fileExists(atPath: cache.path) { return try JSONDecoder().decode(AgentDocumentPart.self, from: files.readData(cache, maximum: 500_000)) }
        let url = try source(store: store, taskID: taskID, id: id)
        let job = Task.detached(priority: .utility) { try AgentDocument.pdfPage(url, number: number, recognize: true) }
        let result = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
        try Task.checkCancellation(); _ = try source(store: store, taskID: taskID, id: id)
        try files.writeData(try JSONEncoder().encode(result.0), to: cache, permissions: 0o600)
        if let image = result.1 { try files.writeData(image.jpeg, to: root.appendingPathComponent("page-\(number).jpg"), permissions: 0o400) }
        return result.0
    }
    static func copyForFork(store: AgentStore, sourceID: String, targetID: String, files: [AgentAttachment]) throws {
        var created: [URL] = []
        do {
            for file in files {
                _ = try source(store: store, taskID: sourceID, id: file.id)
                let from = try directory(store: store, taskID: sourceID, id: file.id), to = try directory(store: store, taskID: targetID, id: file.id)
                try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); created.append(to)
                for name in ["source." + file.fileExtension, "content.json", "preview.jpg"] {
                    let original = from.appendingPathComponent(name), target = to.appendingPathComponent(name)
                    guard FileManager.default.fileExists(atPath: original.path) else { continue }
                    do { try FileManager.default.linkItem(at: original, to: target) } catch { try FileManager.default.copyItem(at: original, to: target) }
                }
            }
        } catch { for url in created { try? FileManager.default.removeItem(at: url) }; throw error }
    }
    static func copyDraft(store: AgentStore, sourceID: String, targetID: String) throws {
        guard let source = store.task(sourceID), let target = store.task(targetID) else { throw PetError("任务不存在") }
        let ids = source.draftAttachmentIDs ?? [], files = (source.attachments ?? []).filter { ids.contains($0.id) }
        guard !files.isEmpty else { return }
        try copyForFork(store: store, sourceID: sourceID, targetID: targetID, files: files)
        store.update(targetID, persist: false) { $0.attachments = files; $0.draftAttachmentIDs = ids }
        do { try store.save(targetID) }
        catch {
            store.update(targetID, persist: false) { $0.attachments = target.attachments; $0.draftAttachmentIDs = target.draftAttachmentIDs }
            for file in files { if let url = try? directory(store: store, taskID: targetID, id: file.id) { try? FileManager.default.removeItem(at: url) } }
            throw error
        }
    }
    nonisolated static func preserveQuarantine(from source: URL, to target: URL) throws {
        let name = "com.apple.quarantine"
        let size = getxattr(source.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        if size < 0 { if errno == ENOATTR || errno == ENOTSUP { return }; throw PetError("无法读取文件来源标记") }
        guard size <= 16_384 else { throw PetError("文件来源标记过大") }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(source.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read == size else { throw PetError("文件来源标记已变化") }
        let result = data.withUnsafeBytes { setxattr(target.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard result == 0 else { throw PetError("无法保留文件来源标记") }
    }
}
