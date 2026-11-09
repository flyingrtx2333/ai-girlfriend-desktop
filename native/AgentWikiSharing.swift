import Foundation

struct AgentWikiTransfer: Codable, Equatable {
    struct Document: Codable, Equatable { var file: String, title: String, sha256: String; var parent: String? }
    struct Resource: Codable, Equatable { var file: String, sha256: String }
    var format = "bluefatfish.repo-wiki", version = 1
    var branch: String, language: String, sourceRevision: String
    var sourceHashes: [String: String]
    var documents: [Document]
    var origin: String
    var resources: [Resource]? = nil
    var sourceCommit: String? = nil
}
struct AgentWikiSnapshot {
    var workspace: String, root: String, pointer: String
    var metadata: AgentWikiTransfer
    var data: [String: Data]
}
struct AgentWikiImportPreview {
    var workspace: String, branch: String, language: String, sourceRoot: String
    var metadata: AgentWikiTransfer, data: [String: Data], sourceHashes: [String: String]
    var previous: AgentWikiSnapshot
    var manuallyChanged: Int
}
struct AgentWikiHistoryEntry: Codable, Equatable {
    var id: String, created: Date, originalRoot: String
    var metadata: AgentWikiTransfer
}
private struct AgentWikiExportState: Codable { var hashes: [String: String] }

@MainActor extension AgentWiki {
    static let transferMetadata = "meta/repowiki-metadata.json"
    static func sharingPath(_ language: String) throws -> String {
        guard ["zh", "en"].contains(language) else { throw PetError("请选择中文或英文 Wiki") }
        return ".bluefatfish/repowiki/" + language
    }
    private static func storage(_ store: AgentStore, _ taskID: String, _ language: String, writing: Bool = false) throws -> (files: AgentFiles, branch: String, directory: URL) {
        _ = try sharingPath(language)
        guard let task = store.task(taskID) else { throw PetError("任务已关闭") }
        let scope = try store.knowledgeCards.scope(task), files = try AgentFiles(workspace: scope.root)
        if writing {
            guard !task.archived, task.kind != "hook", try !store.agents.limits(task, store: store).readOnly, FileManager.default.isWritableFile(atPath: scope.root), !scope.root.hasPrefix(Bundle.main.bundleURL.path + "/"), scope.root != Bundle.main.bundleURL.path else { throw PetError("此项目当前不可写") }
        }
        return (files, scope.branch, scope.directory.deletingLastPathComponent().appendingPathComponent("wiki"))
    }
    private static func key(_ branch: String, _ language: String) -> String { AgentFiles.hash(Data((branch + "\n" + language).utf8)) }
    private static func pointerHash(_ directory: URL, branch: String, language: String) throws -> String {
        let file = directory.appendingPathComponent(key(branch, language) + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else { return AgentFiles.hash(Data()) }
        return try AgentFiles(workspace: directory.path).fileHash(file, maximum: 4_000_000)
    }
    // A shared path must stay at its literal location, including every parent.
    private static func target(_ files: AgentFiles, _ path: String) throws -> URL {
        let literal = try files.literalURL(path)
        guard files.relative(try files.resolve(path)) == path, try files.entryMetadata(literal).kind != "link" else { throw PetError("Wiki 共享目录含符号链接或位置已变化") }
        return literal
    }
    private static func relativeDocuments(_ metadata: AgentWikiTransfer, root: String) throws -> [AgentWikiPage] {
        guard metadata.format == "bluefatfish.repo-wiki", metadata.version == 1, ["zh", "en"].contains(metadata.language), !metadata.branch.isEmpty, metadata.branch.utf8.count <= 1024, !metadata.branch.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), metadata.sourceRevision.isEmpty || validHash(metadata.sourceRevision), metadata.sourceHashes.count <= 5000 else { throw PetError("不支持此 Wiki 元数据格式；原文件未修改") }
        guard ["generation", "manual", "legacy", "import", "restore"].contains(metadata.origin), metadata.sourceHashes.allSatisfy({ path, hash in !path.isEmpty && path.utf8.count <= 1000 && !path.hasPrefix("/") && !path.contains("\\") && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) && !AgentFiles.sensitive(path) && validHash(hash) }), metadata.documents.allSatisfy({ validPageFile($0.file) && validHash($0.sha256) }) else { throw PetError("Wiki 元数据包含无效路径或哈希") }
        let pages = metadata.documents.map { AgentWikiPage(path: root + "/" + $0.file, title: $0.title, parent: $0.parent.map { root + "/" + $0 }) }
        var value = AgentWikiManifest(taskID: UUID().uuidString, revision: metadata.sourceRevision, created: Date(), pages: [:], sources: [])
        value.version = 3; value.root = root; value.structure = pages
        let resources = metadata.resources ?? [], names = metadata.documents.map(\.file) + resources.map(\.file)
        guard resources.count <= 1000, resources.allSatisfy({ validSharedFile($0.file) && !validPageFile($0.file) && validHash($0.sha256) }), Set(names.map { $0.precomposedStringWithCanonicalMapping.lowercased() }).count == names.count else { throw PetError("Wiki 附件路径、数量或哈希无效") }
        return try manifestDocuments(value)
    }
    private static func validHash(_ value: String) -> Bool { value.count == 64 && value.allSatisfy(\.isHexDigit) }
    private static func requireNoGeneration(_ store: AgentStore, workspace: String, branch: String, language: String) throws {
        if store.tasks.contains(where: { $0.workspace == workspace && $0.kind == "wiki" && [.ready, .running, .waiting].contains($0.status) && !$0.archived && ($0.wikiJob == nil ? language == "zh" : $0.wikiJob?.branch == branch && $0.wikiJob?.language == language) }) { throw PetError("请先停止此分支和语言的 Wiki 生成，再导入") }
    }
    private static func resources(_ documents: [String: Data], root: String, files: AgentFiles) async throws -> [String: Data] {
        let folder = try files.resolve(root); var result: [String: Data] = [:], total = 0
        for (name, data) in documents {
            for file in try AgentWikiLinks.localTargets(data, document: files.resolve(root + "/" + name), files: files) where file.path.hasPrefix(folder.path + "/") {
                let relative = String(file.path.dropFirst(folder.path.count + 1))
                if validPageFile(relative) || result[relative] != nil { continue }
                guard validSharedFile(relative) else { continue }
                let url = try target(files, files.relative(file)), entry = try files.entryMetadata(url)
                guard entry.kind == "file" else { continue }
                let bytes = try files.readData(url, maximum: 20_000_000); total += bytes.count
                guard total <= 64_000_000, result.count < 1000 else { throw PetError("Wiki 内部附件合计超过64MB或1000份") }; result[relative] = bytes
            }
            await Task.yield(); try Task.checkCancellation()
        }
        return result
    }
    private static func mapping(files: AgentFiles, names: Dictionary<String, Data>.Keys, from: String, to: String) throws -> [String: URL] {
        var result: [String: URL] = [:]
        for name in names {
            result[try files.resolve(from + "/" + name).path] = try target(files, to + "/" + name)
            var parent = (name as NSString).deletingLastPathComponent
            while !parent.isEmpty && parent != "." { result[try files.resolve(from + "/" + parent).path] = files.root.appendingPathComponent(to + "/" + parent, isDirectory: true); parent = (parent as NSString).deletingLastPathComponent }
        }
        result[try files.resolve(from).path] = files.root.appendingPathComponent(to, isDirectory: true)
        return result
    }
    static func snapshot(_ store: AgentStore, _ taskID: String, _ language: String) async throws -> AgentWikiSnapshot {
        let scope = try storage(store, taskID, language), pointer = try pointerHash(scope.directory, branch: scope.branch, language: language), view = try view(store: store, taskID: taskID, language: language)
        var data: [String: Data] = [:], documents: [AgentWikiTransfer.Document] = [], total = 0
        for page in view.pages {
            let file = String(page.path.dropFirst(view.root.count + 1)); guard validPageFile(file) else { throw PetError("Wiki 页面路径不适合共享：" + file) }
            let bytes = try scope.files.readData(target(scope.files, page.path), maximum: 512_000); total += bytes.count
            guard total <= 32_000_000 else { throw PetError("Wiki 文档超过32MB，未导出部分内容") }
            data[file] = bytes; documents.append(.init(file: file, title: page.title, sha256: AgentFiles.hash(bytes), parent: page.parent.map { String($0.dropFirst(view.root.count + 1)) }))
            await Task.yield(); try Task.checkCancellation()
        }
        var sources = view.manifest?.sourceHashes ?? [:]
        if sources.isEmpty, let manifest = view.manifest, let task = store.task(manifest.taskID) {
            for path in manifest.sources { if let read = task.knowledgeReads?[path] { sources[path] = read.sha256 } }
        }
        var assets = try await resources(data, root: view.root, files: scope.files)
        for path in view.manifest?.assets?.keys ?? Dictionary<String, String>().keys {
            let name = String(path.dropFirst(view.root.count + 1)); if assets[name] == nil { assets[name] = try scope.files.readData(target(scope.files, path), maximum: 20_000_000) }
        }
        guard assets.values.reduce(0, { $0 + $1.count }) <= 64_000_000 else { throw PetError("Wiki 附件超过64MB") }
        let origin = view.manifest?.version == 3 ? "import" : view.manifest == nil ? "legacy" : view.manifest.flatMap { store.task($0.taskID) }?.hasConfirmedWikiCompletion == true ? "generation" : "manual"
        var metadata = AgentWikiTransfer(branch: scope.branch, language: language, sourceRevision: view.manifest?.revision ?? "", sourceHashes: sources, documents: documents, origin: origin)
        metadata.sourceCommit = view.manifest?.sourceCommit
        metadata.resources = assets.keys.sorted().map { .init(file: $0, sha256: AgentFiles.hash(assets[$0]!)) }; data.merge(assets) { _, resource in resource }
        guard try pointerHash(scope.directory, branch: scope.branch, language: language) == pointer else { throw PetError("读取期间 Wiki 发布版本已变化，请重试") }
        return AgentWikiSnapshot(workspace: scope.files.root.path, root: view.root, pointer: pointer, metadata: metadata, data: data)
    }
    static func requireSnapshot(_ expected: AgentWikiSnapshot, store: AgentStore, taskID: String, language: String) throws {
        let scope = try storage(store, taskID, language, writing: true)
        guard scope.files.root.path == expected.workspace, scope.branch == expected.metadata.branch, try pointerHash(scope.directory, branch: scope.branch, language: language) == expected.pointer else { throw PetError("Wiki 工作区、分支或发布版本已变化，请重新预览") }
        let actual = try pages(workspace: scope.files.root.path, root: expected.root)
        guard Set(actual) == Set(expected.metadata.documents.map { expected.root + "/" + $0.file }), expected.metadata.documents.allSatisfy({ (try? scope.files.fileHash(target(scope.files, expected.root + "/" + $0.file), maximum: 512_000)) == $0.sha256 }), (expected.metadata.resources ?? []).allSatisfy({ (try? scope.files.fileHash(target(scope.files, expected.root + "/" + $0.file), maximum: 20_000_000)) == $0.sha256 }) else { throw PetError("预览后当前 Wiki 或附件已被编辑，请重新预览") }
    }
    static func exportWiki(store: AgentStore, taskID: String, language: String) async throws -> Int {
        let scope = try storage(store, taskID, language, writing: true), original = try await snapshot(store, taskID, language), relative = try sharingPath(language)
        guard !original.data.isEmpty else { throw PetError("当前语言没有可导出的 Wiki") }
        var metadata = original.metadata, payloads: [String: Data] = [:], total = 0
        let mapping = try mapping(files: scope.files, names: original.data.keys, from: original.root, to: relative + "/content")
        for i in metadata.documents.indices {
            let file = metadata.documents[i].file, source = try scope.files.resolve(original.root + "/" + file), destination = try target(scope.files, relative + "/content/" + file)
            let data = try AgentWikiLinks.rewrite(original.data[file]!, from: source, to: destination, files: scope.files, pages: mapping)
            total += data.count
            guard data.count <= 512_000, total <= 32_000_000, try AgentTextFile.decode(data).text.utf16.count <= 300_000 else { throw PetError("链接重定位后的页面或文档总量超过处理上限：" + file) }
            metadata.documents[i].sha256 = AgentFiles.hash(data); payloads["content/" + file] = data; await Task.yield(); try Task.checkCancellation()
        }
        for resource in metadata.resources ?? [] { payloads["content/" + resource.file] = original.data[resource.file]! }
        _ = try relativeDocuments(metadata, root: relative + "/content")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; payloads[transferMetadata] = try encoder.encode(metadata)
        guard payloads[transferMetadata]!.count <= 4_000_000 else { throw PetError("Wiki 元数据超过4MB") }
        try FileManager.default.createDirectory(at: scope.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try store.knowledgeCards.locked(scope.directory, label: "Wiki") {
            try requireSnapshot(original, store: store, taskID: taskID, language: language)
            let stateURL = scope.directory.appendingPathComponent("export-" + key(scope.branch, language) + ".json"), stateFiles = try AgentFiles(workspace: scope.directory.path)
            let previous = FileManager.default.fileExists(atPath: stateURL.path) ? try JSONDecoder().decode(AgentWikiExportState.self, from: stateFiles.readData(stateURL, maximum: 4_000_000)) : AgentWikiExportState(hashes: [:])
            let actual = try pages(workspace: scope.files.root.path, root: relative + "/content")
            guard actual.allSatisfy({ previous.hashes[String($0.dropFirst(relative.count + 1))] != nil }) else { throw PetError("共享目录有未导入的页面，请先导入") }
            var before: [String: (data: Data?, signature: String, permissions: Int)] = [:]
            for name in Set(payloads.keys).union(previous.hashes.keys) {
                guard name == transferMetadata || name.hasPrefix("content/") && validSharedFile(String(name.dropFirst(8))) else { throw PetError("原导出记录包含无效路径") }
                let file = try target(scope.files, relative + "/" + name), entry = try scope.files.entryMetadata(file)
                if entry.kind == "missing" { before[name] = (nil, entry.signature, 0o644); continue }
                guard entry.kind == "file", let expected = previous.hashes[name], (entry.permissions ?? 0) & 0o222 != 0 else { throw PetError("共享目录有未导入或只读的文件：" + name) }
                let data = try scope.files.readData(file, maximum: 20_000_000)
                guard AgentFiles.hash(data) == expected else { throw PetError("共享文件有外部修改，请先导入：" + name) }; before[name] = (data, entry.signature, entry.permissions ?? 0o644)
            }
            let backup = scope.directory.appendingPathComponent("export-backups/" + UUID().uuidString); try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); let backups = try AgentFiles(workspace: backup.path)
            for (name, entry) in before { if let data = entry.data { try backups.writeData(data, to: backups.resolve(name), permissions: 0o600) } }
            var changed: [String: (hash: String?, signature: String)] = [:]
            do {
                for name in payloads.keys.filter({ $0 != transferMetadata }).sorted() + [transferMetadata] {
                    let file = try target(scope.files, relative + "/" + name), data = payloads[name]!
                    try scope.files.writeData(data, to: file, permissions: before[name]!.permissions, expectedTarget: before[name]!.signature)
                    changed[name] = (AgentFiles.hash(data), try scope.files.entryMetadata(file).signature)
                }
                for name in previous.hashes.keys.sorted() where payloads[name] == nil && before[name]?.data != nil {
                    let file = try target(scope.files, relative + "/" + name)
                    guard try scope.files.entryMetadata(file).signature == before[name]!.signature else { throw PetError("共享文件在导出期间被编辑") }
                    try scope.files.remove(file); changed[name] = (nil, "missing")
                }
                try stateFiles.writeData(encoder.encode(AgentWikiExportState(hashes: payloads.mapValues(AgentFiles.hash))), to: stateURL, permissions: 0o600)
            } catch {
                for name in changed.keys.filter({ $0 != transferMetadata }).sorted() + [transferMetadata] {
                    guard let changed = changed[name], let file = try? target(scope.files, relative + "/" + name), (try? scope.files.entryMetadata(file).signature) == changed.signature else { continue }
                    if let hash = changed.hash, (try? scope.files.fileHash(file, maximum: 20_000_000)) != hash { continue }
                    if let data = before[name]?.data { try? scope.files.writeData(data, to: file, permissions: before[name]!.permissions, expectedTarget: changed.signature) }
                    else if changed.hash != nil { try? scope.files.remove(file) }
                }
                throw PetError("导出未完成：" + error.localizedDescription + "；原文件备份：" + backup.path)
            }
        }
        return metadata.documents.count
    }
    static func previewWikiImport(store: AgentStore, taskID: String, language: String) async throws -> AgentWikiImportPreview {
        let scope = try storage(store, taskID, language, writing: true), relative = try sharingPath(language), file = try target(scope.files, relative + "/" + transferMetadata)
        let bytes = try scope.files.readData(file, maximum: 4_000_000), metadata = try JSONDecoder().decode(AgentWikiTransfer.self, from: bytes)
        guard metadata.sourceCommit == nil || validCommit(metadata.sourceCommit!) else { throw PetError("共享 Wiki 的 Git 提交基线无效") }
        guard metadata.language == language else { throw PetError("共享 Wiki 不是当前选择的语言") }
        _ = try relativeDocuments(metadata, root: relative + "/content")
        let listed = Set(metadata.documents.map(\.file)), actual = try catalog(workspace: scope.files.root.path, root: relative + "/content")
        guard listed.isSubset(of: Set(actual.map { String($0.path.dropFirst(relative.count + 9)) })), !actual.isEmpty else { throw PetError("共享目录不完整，请保留 content 和 meta 目录") }
        var updated = metadata, data: [String: Data] = [:], hashes = [transferMetadata: AgentFiles.hash(bytes)], total = 0, changed = 0
        for page in actual {
            let name = String(page.path.dropFirst(relative.count + 9)), raw = try scope.files.readData(target(scope.files, page.path), maximum: 512_000); total += raw.count
            guard total <= 32_000_000 else { throw PetError("共享 Wiki 超过32MB") }; _ = try AgentTextFile.decode(raw)
            let hash = AgentFiles.hash(raw); data[name] = raw; hashes["content/" + name] = hash
            if let i = updated.documents.firstIndex(where: { $0.file == name }) { if hash != updated.documents[i].sha256 { changed += 1 }; updated.documents[i].sha256 = hash; updated.documents[i].title = page.title }
            else { updated.documents.append(.init(file: name, title: page.title, sha256: hash, parent: nil)); changed += 1 }
            await Task.yield(); try Task.checkCancellation()
        }
        var assets = try await resources(data, root: relative + "/content", files: scope.files), resourceTotal = 0
        for resource in metadata.resources ?? [] {
            let raw = try scope.files.readData(target(scope.files, relative + "/content/" + resource.file), maximum: 20_000_000)
            if AgentFiles.hash(raw) != resource.sha256 { changed += 1 }; assets[resource.file] = raw
        }
        for (name, bytes) in assets { resourceTotal += bytes.count; guard resourceTotal <= 64_000_000 else { throw PetError("共享 Wiki 附件超过64MB") }; data[name] = bytes; hashes["content/" + name] = AgentFiles.hash(bytes) }
        updated.resources = assets.keys.sorted().map { .init(file: $0, sha256: AgentFiles.hash(assets[$0]!)) }
        _ = try relativeDocuments(updated, root: relative + "/content")
        return AgentWikiImportPreview(workspace: scope.files.root.path, branch: scope.branch, language: language, sourceRoot: relative + "/content", metadata: updated, data: data, sourceHashes: hashes, previous: try await snapshot(store, taskID, language), manuallyChanged: changed)
    }
    private static func archive(_ snapshot: AgentWikiSnapshot, directory: URL) throws {
        guard !snapshot.data.isEmpty else { return }
        let id = UUID().uuidString, folder = directory.appendingPathComponent("history/" + id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); let files = try AgentFiles(workspace: folder.path)
        for (name, bytes) in snapshot.data { try files.writeData(bytes, to: files.resolve("content/" + name), permissions: 0o600) }
        let entry = AgentWikiHistoryEntry(id: id, created: Date(), originalRoot: snapshot.root, metadata: snapshot.metadata)
        try files.writeData(JSONEncoder().encode(entry), to: files.resolve("version.json"), permissions: 0o600)
    }
    static func saveEditedPage(_ snapshot: AgentWikiSnapshot, store: AgentStore, taskID: String, path: String, data: Data) throws {
        let scope = try storage(store, taskID, snapshot.metadata.language, writing: true)
        guard snapshot.metadata.documents.contains(where: { snapshot.root + "/" + $0.file == path }), data.count <= 512_000 else { throw PetError("编辑页面不属于当前 Wiki 或超过512KB") }
        try FileManager.default.createDirectory(at: scope.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try store.knowledgeCards.locked(scope.directory, label: "Wiki") {
            try requireSnapshot(snapshot, store: store, taskID: taskID, language: snapshot.metadata.language)
            try requireNoGeneration(store, workspace: snapshot.workspace, branch: snapshot.metadata.branch, language: snapshot.metadata.language)
            let url = try target(scope.files, path), metadata = try scope.files.entryMetadata(url)
            try archive(snapshot, directory: scope.directory)
            try scope.files.writeData(data, to: url, permissions: metadata.permissions ?? 0o644, expectedTarget: metadata.signature)
        }
    }
    static func importWiki(_ preview: AgentWikiImportPreview, store: AgentStore, taskID: String, restoring: Bool = false) async throws {
        let scope = try storage(store, taskID, preview.language, writing: true)
        guard scope.files.root.path == preview.workspace, scope.branch == preview.branch else { throw PetError("导入预览的工作区或分支已变化") }
        try requireNoGeneration(store, workspace: scope.files.root.path, branch: scope.branch, language: preview.language)
        let id = UUID().uuidString, importedRoot = root(branch: scope.branch, language: preview.language, taskID: id), docs = try relativeDocuments(preview.metadata, root: importedRoot)
        let mapping = try mapping(files: scope.files, names: preview.data.keys, from: preview.sourceRoot, to: importedRoot)
        var payloads: [String: Data] = [:], total = 0
        for doc in preview.metadata.documents {
            guard let data = preview.data[doc.file], AgentFiles.hash(data) == doc.sha256 else { throw PetError("导入页面与预览不一致") }
            let rewritten = try AgentWikiLinks.rewrite(data, from: scope.files.resolve(preview.sourceRoot + "/" + doc.file), to: scope.files.resolve(importedRoot + "/" + doc.file), files: scope.files, pages: mapping)
            total += rewritten.count; guard rewritten.count <= 512_000, total <= 32_000_000 else { throw PetError("导入页面超过512KB或总量超过32MB") }; payloads[importedRoot + "/" + doc.file] = rewritten; await Task.yield(); try Task.checkCancellation()
        }
        for resource in preview.metadata.resources ?? [] {
            guard let data = preview.data[resource.file], AgentFiles.hash(data) == resource.sha256 else { throw PetError("附件与导入预览不一致") }; payloads[importedRoot + "/" + resource.file] = data
        }
        try FileManager.default.createDirectory(at: scope.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try store.knowledgeCards.locked(scope.directory, label: "Wiki") {
            try requireSnapshot(preview.previous, store: store, taskID: taskID, language: preview.language)
            try requireNoGeneration(store, workspace: scope.files.root.path, branch: scope.branch, language: preview.language)
            if !restoring {
                let relative = try sharingPath(preview.language), actual = try pages(workspace: scope.files.root.path, root: relative + "/content")
                guard Set(actual) == Set(preview.metadata.documents.map { relative + "/content/" + $0.file }), preview.sourceHashes.allSatisfy({ (try? scope.files.fileHash(target(scope.files, relative + "/" + $0.key), maximum: 20_000_000)) == $0.value }) else { throw PetError("导入文件在预览后已变化，请重新预览") }
            }
            let storage = try AgentFiles(workspace: scope.directory.path), pointer = scope.directory.appendingPathComponent(key(scope.branch, preview.language) + ".json"), pointerSignature = try storage.entryMetadata(pointer).signature
            try archive(preview.previous, directory: scope.directory)
            guard try scope.files.entryMetadata(target(scope.files, importedRoot)).kind == "missing" else { throw PetError("导入目录已存在，未覆盖") }
            for (path, data) in payloads { try scope.files.writeData(data, to: target(scope.files, path), expectedTarget: "missing") }
            let documentPaths = Set(preview.metadata.documents.map { importedRoot + "/" + $0.file })
            var value = AgentWikiManifest(taskID: id, revision: preview.metadata.sourceRevision, created: Date(), pages: payloads.filter { documentPaths.contains($0.key) }.mapValues(AgentFiles.hash), sources: preview.metadata.sourceHashes.keys.sorted())
            value.version = 3; value.branch = scope.branch; value.language = preview.language; value.root = importedRoot; value.structure = docs; value.sourceHashes = preview.metadata.sourceHashes; value.origin = restoring ? "restore" : "import"
            value.assets = payloads.filter { !documentPaths.contains($0.key) }.mapValues(AgentFiles.hash)
            value.sourceCommit = preview.metadata.sourceCommit
            try storage.writeData(JSONEncoder().encode(value), to: pointer, permissions: 0o600, expectedTarget: pointerSignature)
            if !restoring {
                do { try storage.writeData(JSONEncoder().encode(AgentWikiExportState(hashes: preview.sourceHashes)), to: scope.directory.appendingPathComponent("export-" + key(scope.branch, preview.language) + ".json"), permissions: 0o600) }
                catch { throw PetError("Wiki 已导入，导出记录未能更新：" + error.localizedDescription) }
            }
        }
        await store.wikiMaintenance.published(taskID: taskID, language: preview.language, expectedID: id)
    }
    static func wikiHistory(store: AgentStore, taskID: String, language: String) throws -> [AgentWikiHistoryEntry] {
        let scope = try storage(store, taskID, language), folder = scope.directory.appendingPathComponent("history")
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }; let files = try AgentFiles(workspace: folder.path)
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { UUID(uuidString: $0.lastPathComponent) != nil }.compactMap { directory in
            guard let data = try? files.readData(directory.appendingPathComponent("version.json"), maximum: 4_000_000), let value = try? JSONDecoder().decode(AgentWikiHistoryEntry.self, from: data), value.id == directory.lastPathComponent, value.metadata.branch == scope.branch, value.metadata.language == language else { return nil }; return value
        }.sorted { $0.created > $1.created }
    }
    static func previewWikiRestore(_ entry: AgentWikiHistoryEntry, store: AgentStore, taskID: String, language: String) async throws -> AgentWikiImportPreview {
        let scope = try storage(store, taskID, language, writing: true)
        let originalID = (entry.originalRoot as NSString).lastPathComponent
        guard UUID(uuidString: entry.id) != nil, entry.metadata.branch == scope.branch, entry.metadata.language == language, entry.originalRoot == ".bluefatfish/wiki" || UUID(uuidString: originalID) != nil && entry.originalRoot == root(branch: scope.branch, language: language, taskID: originalID) else { throw PetError("此历史版本不属于当前分支和语言") }
        _ = try relativeDocuments(entry.metadata, root: entry.originalRoot)
        let folder = scope.directory.appendingPathComponent("history/" + entry.id), files = try AgentFiles(workspace: folder.path), saved = try JSONDecoder().decode(AgentWikiHistoryEntry.self, from: files.readData(folder.appendingPathComponent("version.json"), maximum: 4_000_000))
        guard saved == entry else { throw PetError("历史版本已变化") }
        var data: [String: Data] = [:], total = 0
        for doc in saved.metadata.documents { let raw = try files.readData(files.resolve("content/" + doc.file), maximum: 512_000); total += raw.count; guard AgentFiles.hash(raw) == doc.sha256, total <= 32_000_000 else { throw PetError("历史版本文件不完整") }; data[doc.file] = raw; await Task.yield(); try Task.checkCancellation() }
        var resourceTotal = 0
        for resource in saved.metadata.resources ?? [] { let raw = try files.readData(files.resolve("content/" + resource.file), maximum: 20_000_000); resourceTotal += raw.count; guard AgentFiles.hash(raw) == resource.sha256, resourceTotal <= 64_000_000 else { throw PetError("历史附件不完整") }; data[resource.file] = raw; await Task.yield(); try Task.checkCancellation() }
        return AgentWikiImportPreview(workspace: scope.files.root.path, branch: scope.branch, language: language, sourceRoot: saved.originalRoot, metadata: saved.metadata, data: data, sourceHashes: [:], previous: try await snapshot(store, taskID, language), manuallyChanged: 0)
    }
}
