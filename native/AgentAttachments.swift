import Foundation

struct AgentAttachment: Codable, Identifiable, Sendable {
    var id = UUID().uuidString
    var name: String; var fileExtension: String; var bytes: Int; var sha256: String; var modified: Date
    var totalParts: Int; var partial: Bool; var width: Int?; var height: Int?
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
        guard AgentDocument.textTypes.contains(file.fileExtension) || AgentDocument.imageTypes.contains(file.fileExtension) || ["pdf", "docx", "xlsx", "pptx"].contains(file.fileExtension) else { throw PetError("附件类型无效") }
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
    static func importFile(_ original: URL, store: AgentStore, taskID: String) async throws -> AgentAttachment {
        guard let task = store.task(taskID), task.kind != "wiki", !task.archived else { throw PetError("当前任务不能添加附件") }
        if let error = store.writeError { throw PetError("任务尚未保存：" + error) }
        let selected = original.standardizedFileURL.resolvingSymlinksInPath(), type = selected.pathExtension.lowercased()
        guard !AgentFiles.sensitive(selected.lastPathComponent), AgentDocument.textTypes.contains(type) || AgentDocument.imageTypes.contains(type) || ["pdf", "docx", "xlsx", "pptx"].contains(type) else { throw PetError("不支持此类型或属于凭据文件") }
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
                try data.write(to: local, options: .atomic); try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: local.path)
                return (data.count, AgentFiles.hash(data))
            }()
            let scratch = stage.appendingPathComponent("parser-tmp", isDirectory: true)
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let document = try await AgentDocument.extract(local, scratch: scratch)
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
            return AgentAttachment(id: id, name: original.lastPathComponent, fileExtension: type, bytes: copied.0, sha256: copied.1, modified: modified, totalParts: document.totalParts, partial: document.partial, width: width, height: height)
        }
        let file = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
        do {
            try Task.checkCancellation()
            guard let previous = store.task(taskID), previous.kind != "wiki", !previous.archived else { throw PetError("任务状态已变化，附件未添加") }
            store.update(taskID, persist: false) { record in
                if record.attachments == nil { record.attachments = [] }; record.attachments?.append(file)
                if record.draftAttachmentIDs == nil { record.draftAttachmentIDs = [] }; record.draftAttachmentIDs?.append(file.id)
            }
            do { try store.save(taskID) }
            catch { store.update(taskID, persist: false) { $0.attachments = previous.attachments; $0.draftAttachmentIDs = previous.draftAttachmentIDs }; throw error }
            return file
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    static func removeDraft(store: AgentStore, taskID: String, id: String) throws {
        guard let task = store.task(taskID) else { throw PetError("任务不存在") }
        let used = task.messages.contains { $0.attachmentIDs?.contains(id) == true }
        store.update(taskID, persist: false) { record in record.draftAttachmentIDs?.removeAll { $0 == id }; if !used { record.attachments?.removeAll { $0.id == id } } }
        do { try store.save(taskID) }
        catch { store.update(taskID, persist: false) { $0.attachments = task.attachments; $0.draftAttachmentIDs = task.draftAttachmentIDs }; throw error }
        if !used { try FileManager.default.removeItem(at: directory(store: store, taskID: taskID, id: id)) }
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
}
