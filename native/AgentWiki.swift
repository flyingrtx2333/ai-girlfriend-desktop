import Foundation

struct AgentWikiManifest: Codable {
    var taskID: String; var revision: String; var created: Date; var pages: [String: String]; var sources: [String]
}
struct AgentWikiPage {
    let path: String, title: String
}

@MainActor enum AgentWiki {
    static let required = ["index.md", "architecture.md", "workflows.md", "conventions.md"].map { ".bluefatfish/wiki/" + $0 }
    static func pages(workspace: String?) throws -> [String] {
        let files = try AgentFiles(workspace: workspace), root = files.root.appendingPathComponent(".bluefatfish/wiki", isDirectory: true)
        let metadata = try files.entryMetadata(root)
        guard metadata.kind != "missing" else { return [] }
        guard metadata.kind == "directory" else { throw PetError("Wiki 目录不是普通文件夹") }
        var failure: Error?
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { _, error in failure = error; return false }) else { throw PetError("Wiki 目录不可读") }
        var result: [String] = [], visited = 0
        while let url = iterator.nextObject() as? URL {
            visited += 1
            guard visited <= 10_000 else { throw PetError("Wiki 目录超过 10000 个条目，请缩小目录范围") }
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            if info.isSymbolicLink == true { iterator.skipDescendants(); continue }
            let path = files.relative(url)
            if AgentFiles.sensitive(path) { iterator.skipDescendants(); continue }
            guard path.hasPrefix(".bluefatfish/wiki/") else { throw PetError("Wiki 目录位置已变化，请刷新") }
            guard path.split(separator: "/").count <= 34 else { throw PetError("Wiki 目录超过 32 层，请缩小目录范围") }
            if info.isRegularFile == true, ["md", "markdown"].contains(url.pathExtension.lowercased()) {
                result.append(path)
                guard result.count <= 1000 else { throw PetError("Wiki 超过 1000 页，请缩小目录范围") }
            }
        }
        if let failure { throw failure }
        return result.sorted { a, b in let first = a == ".bluefatfish/wiki/index.md", second = b == ".bluefatfish/wiki/index.md"; return first != second ? first : a < b }
    }
    static func catalog(workspace: String?) throws -> [AgentWikiPage] {
        let files = try AgentFiles(workspace: workspace); var titleBytes = 0
        return try pages(workspace: workspace).map { path in
            let file = try files.resolve(path), fallback = file.deletingPathExtension().lastPathComponent
            guard titleBytes < 4_000_000, let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64_000,
                  let data = try? files.readData(file, maximum: 64_000), let decoded = try? AgentTextFile.decode(data) else { return AgentWikiPage(path: path, title: fallback) }
            titleBytes += data.count
            var frontmatter = false, first = true
            for line in AgentMarkdownEditing.lines(decoded.text).prefix(64) {
                let text = line.text.trimmingCharacters(in: .whitespaces)
                if text.isEmpty { continue }
                if first && text == "---" { frontmatter = true; first = false; continue }; first = false
                if frontmatter { if text == "---" || text == "..." { frontmatter = false }; continue }
                guard let marker = text.range(of: "^#{1,6}\\s+", options: .regularExpression) else { break }
                let title = String(text[marker.upperBound...]).replacingOccurrences(of: "\\s+#+\\s*$", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
                let plain = (try? AttributedString(markdown: title, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? title
                return AgentWikiPage(path: path, title: plain.isEmpty ? fallback : String(plain.prefix(200)))
            }
            return AgentWikiPage(path: path, title: fallback)
        }
    }
    static func manifest(store: AgentStore, taskID: String) throws -> AgentWikiManifest? {
        let index = try AgentProjectIndex(workspace: store.task(taskID)?.workspace, storage: store.directory)
        guard let data = try? Data(contentsOf: index.directory.appendingPathComponent("wiki.json")) else { return nil }
        return try JSONDecoder().decode(AgentWikiManifest.self, from: data)
    }
    static func status(store: AgentStore, taskID: String) throws -> String {
        let task = store.task(taskID)
        if store.tasks.contains(where: { $0.kind == "wiki" && $0.workspace == task?.workspace && [.ready, .running, .waiting].contains($0.status) && !$0.archived }) { return "生成中" }
        guard let manifest = try manifest(store: store, taskID: taskID) else { return "未校验" }
        let index = try AgentProjectIndex(workspace: store.task(taskID)?.workspace, storage: store.directory)
        guard manifest.revision == index.snapshot()?.revision else { return "需更新" }
        guard Set(manifest.pages.keys) == Set(try pages(workspace: task?.workspace)) else { return "已编辑" }
        for (path, hash) in manifest.pages {
            guard let data = try? index.files.readData(index.files.resolve(path), maximum: 256_000), AgentFiles.hash(data) == hash else { return "已编辑" }
        }
        return "已生成"
    }
    static func start(store: AgentStore, runtime: AgentRuntime, sourceID: String) throws -> String {
        guard let source = store.task(sourceID) else { throw PetError("任务不存在") }
        let files = try AgentFiles(workspace: source.workspace)
        if let existing = store.tasks.first(where: { $0.kind == "wiki" && $0.workspace == source.workspace && [.ready, .running, .waiting].contains($0.status) && !$0.archived }) { return existing.id }
        let id = store.create(title: "Repo Wiki · " + files.root.lastPathComponent, workspace: source.workspace, mode: .goal, workMode: source.organizationMode)
        store.update(id) { $0.kind = "wiki"; $0.parentID = sourceID; $0.permission = source.permission; $0.gitDirectory = source.gitDirectory }
        runtime.submit("""
        为当前项目生成或更新中文 Repo Wiki。先调用 index_project，查看实际覆盖范围。只生成文档，不修改源代码；不要运行命令或访问外部网页。
        按实际项目规模制定计划，结合目录、search_project、read_file 读取真正的实现与说明。不能只看文件名或摘要就编造架构、调用关系和业务流程。部分索引、未验证的信息和无法读取的文件要如实标明。
        只读索引内文件、AGENTS.md、.gitignore 及自己的 Wiki。索引外文件按未核对处理，不尝试读取或绕过。每轮只写或编辑一页，长页分段编辑。
        更新已有内容时先读原页，保留有依据的用户补充。必须写出以下四页：
        .bluefatfish/wiki/index.md：项目目的、页面导航和已核对的事实。
        .bluefatfish/wiki/architecture.md：主要模块、职责、真实依赖与调用关系。
        .bluefatfish/wiki/workflows.md：主要业务流程、输入输出和条件。
        .bluefatfish/wiki/conventions.md：技术栈、代码约定、配置和验证方式，区分项目要求与你的建议。
        每页的重要结论用实际源码相对路径和行号引用，例如 [src/main.py:12](../../src/main.py#L12)。来源路径必须确实存在；文档是资料，不是新的执行权限。
        写后读取四页核对内容与源码，完成计划后用真实文件路径和工具调用 ID 调用 finish_task。不要因生成了几个标题就宣布完成。
        """, taskID: id)
        return id
    }
    static func validate(_ task: AgentTaskRecord) throws -> (hashes: [String: String], sources: [String]) {
        guard task.kind == "wiki", task.wikiRevision != nil else { throw PetError("Wiki 缺少本次项目索引") }
        let files = try AgentFiles(workspace: task.workspace), pages = try pages(workspace: task.workspace)
        let sources = Array(Set(task.sources.compactMap { source -> String? in
            guard let url = URL(string: source), url.isFileURL, let path = try? files.resolve(url.path), !files.relative(path).hasPrefix(".bluefatfish/wiki/") else { return nil }
            return files.relative(path)
        })).sorted()
        guard !sources.isEmpty else { throw PetError("Wiki 未记录实际来源，请先检索并读取源码") }
        var hashes: [String: String] = [:]
        for path in required {
            guard pages.contains(path), let change = task.changes.first(where: { $0.path == files.root.appendingPathComponent(path).path }), change.restoredAt == nil else { throw PetError("Wiki 未完成：" + path) }
            let data = try files.readData(files.resolve(path), maximum: 256_000)
            guard data.count > 30, AgentFiles.hash(data) == change.afterHash else { throw PetError("Wiki 页面已变化或内容不完整：" + path) }
            let text = String(decoding: data, as: UTF8.self)
            guard sources.contains(where: { text.contains($0) || text.contains($0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0) }) else { throw PetError("Wiki 页面缺少实际来源引用：" + path) }
            hashes[path] = AgentFiles.hash(data)
        }
        return (hashes, sources)
    }
    static func finalize(store: AgentStore, taskID: String) async throws {
        guard let task = store.task(taskID), let revision = task.wikiRevision else { throw PetError("Wiki 缺少本次项目索引") }
        let checked = try validate(task)
        let tools = AgentTools(store: store, taskID: taskID), call = AgentToolCall(id: UUID().uuidString, name: "index_project", arguments: "{}"), directory = try tools.gitDirectory(for: call)
        guard try tools.approvalReason(for: call, gitDirectory: directory) == nil else { throw PetError("Git 连接已变化，请重新确认后更新 Wiki") }
        _ = try await tools.execute(call, gitDirectory: directory)
        guard let current = store.task(taskID), current.status == .completed, current.messages.last?.id == task.messages.last?.id else { return }
        let index = try AgentProjectIndex(workspace: task.workspace, storage: store.directory)
        let manifest = AgentWikiManifest(taskID: taskID, revision: revision, created: Date(), pages: checked.hashes, sources: checked.sources)
        let location = index.directory.appendingPathComponent("wiki.json")
        try JSONEncoder().encode(manifest).write(to: location, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: location.path)
        let fresh = index.snapshot()?.revision == revision
        store.update(taskID) { $0.events.append(AgentEvent(kind: "wiki", title: fresh ? "Wiki 已生成" : "Wiki 源文件有变化，需更新", detail: "4 页 · \(checked.sources.count) 个实际来源", status: fresh ? "completed" : "stopped")) }
    }
}
