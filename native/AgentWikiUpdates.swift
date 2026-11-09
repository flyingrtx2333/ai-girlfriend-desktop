import Foundation

struct AgentWikiRetainedPage: Codable {
    var sha256: String
    var sources: [String: String]
}
struct AgentWikiUpdateJob: Codable {
    var baseCommit: String, commit: String, diff: String
    var changedPaths: [String]
    var retained: [String: AgentWikiRetainedPage] = [:]
    var assets: [String: String] = [:]
    var baseFiles: [String: String] = [:]
    var changesRead: AgentKnowledgeCardRead?
}
struct AgentWikiUpdatePreview {
    var snapshot: AgentWikiSnapshot
    var manifestID: String, baseCommit: String, commit: String, revision: String
    var diff: String, changedPaths: [String], plan: AgentWikiPlan
    var configurationHash: String?, rootIdentity: String
}

@MainActor extension AgentWiki {
    static func updateGit(store: AgentStore, taskID: String) throws -> AgentGit {
        guard let task = store.task(taskID), !task.archived else { throw PetError("请选择当前项目任务") }
        let scope = try store.knowledgeCards.scope(task)
        guard scope.branch != "folder" else { throw PetError("增量更新仅适用于 Git 仓库") }
        let directory = try AgentGit.metadata(workspace: scope.root)
        guard directory.path == scope.root || directory.path.hasPrefix(scope.root + "/") || task.gitDirectory == directory.path else { throw PetError("请先连接当前工作区的 Git 元数据") }
        return try AgentGit(store: store, taskID: taskID, directory: directory)
    }
    static func validCommit(_ value: String) -> Bool { [40, 64].contains(value.count) && value.allSatisfy(\.isHexDigit) }
    static func updatePath(_ path: String) -> Bool { !path.hasPrefix(".bluefatfish/") && !path.hasPrefix(".qoder/") && !AgentFiles.sensitive(path) }
    static func cleanCommit(store: AgentStore, taskID: String) async throws -> String {
        let git = try updateGit(store: store, taskID: taskID), status = try await git.status()
        guard let head = status.head, validCommit(head) else { throw PetError("请先创建 Git 提交") }
        guard !status.changes.contains(where: { updatePath($0.path) || $0.previousPath.map(updatePath) == true }) else { throw PetError("请先提交项目修改，再增量更新 Wiki") }
        return head
    }
    static func previewUpdate(store: AgentStore, runtime: AgentRuntime, sourceID: String, language: String) async throws -> AgentWikiUpdatePreview {
        guard ["zh", "en"].contains(language), let source = store.task(sourceID), !source.archived, source.kind != "hook", try !store.agents.limits(source, store: store).readOnly else { throw PetError("请选择可写的项目任务和更新语言") }
        let state = try generationState(store: store, runtime: runtime, sourceID: sourceID, language: language)
        guard !["pause", "publishing"].contains(state.action) else { throw PetError("请先暂停当前 Wiki 生成") }
        let scope = try store.knowledgeCards.scope(source), identity = try AgentKnowledgeCards.identity(scope.root)
        guard let manifest = try plannedManifest(store: store, taskID: sourceID, language: language), let base = manifest.sourceCommit, validCommit(base) else { throw PetError("当前 Wiki 没有 Git 提交基线，请先重新生成") }
        let head = try await cleanCommit(store: store, taskID: sourceID)
        guard head != base else { throw PetError("当前提交已更新，无需重复生成") }
        let git = try updateGit(store: store, taskID: sourceID)
        guard try await git.output(["rev-parse", "--verify", "--end-of-options", base + "^{commit}"]).trimmingCharacters(in: .whitespacesAndNewlines) == base else { throw PetError("Wiki 基线提交不可用，请重新生成") }
        let raw = try await git.output(["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--name-only", "-z", base, head, "--"])
        let paths = raw.split(separator: "\0").map(String.init).filter(updatePath).sorted()
        guard !paths.isEmpty else { throw PetError("没有可更新的项目源码变更") }
        guard paths.count <= 200 else { throw PetError("变更超过200个文件，请分批更新或重新生成") }
        let result = try await git.run(["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--no-color", "--unified=3", base, head, "--"] + paths, maximumOutput: 128_000)
        guard !result.failed, result.truncated != true, let diff = result.stdout, !diff.isEmpty else { throw PetError("提交差异超过128KB或无法读取，请分批更新或重新生成") }
        let snapshot = try await snapshot(store, sourceID, language), documents = snapshot.metadata.documents
        let plan: AgentWikiPlan
        if let frozen = manifest.plan { plan = try frozen.validated() }
        else {
            let titles = Dictionary(uniqueKeysWithValues: documents.map { ($0.file, $0.title) })
            plan = try AgentWikiPlan(documents: documents.map { AgentWikiDocument(title: $0.title, goal: "结合提交变更核对并保留此页已有事实与用户补充", parent: $0.parent.flatMap { titles[$0] }) }).validated()
        }
        let indexed = try await store.knowledgeCards.refreshIndex(source)
        guard try await cleanCommit(store: store, taskID: sourceID) == head, try store.knowledgeCards.scope(source).branch == scope.branch, try AgentKnowledgeCards.identity(scope.root) == identity else { throw PetError("项目或提交已变化，请重新审阅更新") }
        try requireSnapshot(snapshot, store: store, taskID: sourceID, language: language)
        return AgentWikiUpdatePreview(snapshot: snapshot, manifestID: manifest.taskID, baseCommit: base, commit: head, revision: indexed.index.revision, diff: diff, changedPaths: paths, plan: plan, configurationHash: store.task(manifest.taskID)?.wikiJob?.configurationHash, rootIdentity: identity)
    }
    static func startUpdate(_ preview: AgentWikiUpdatePreview, store: AgentStore, runtime: AgentRuntime, sourceID: String) async throws -> String {
        guard let source = store.task(sourceID), try AgentFiles(workspace: source.workspace).root.path == preview.snapshot.workspace, try AgentKnowledgeCards.identity(preview.snapshot.workspace) == preview.rootIdentity,
              try store.knowledgeCards.scope(source).branch == preview.snapshot.metadata.branch, try await cleanCommit(store: store, taskID: sourceID) == preview.commit,
              try plannedManifest(store: store, taskID: sourceID, language: preview.snapshot.metadata.language)?.taskID == preview.manifestID else { throw PetError("项目、提交或 Wiki 版本已变化，请重新审阅更新") }
        try requireSnapshot(preview.snapshot, store: store, taskID: sourceID, language: preview.snapshot.metadata.language)
        let indexed = try await store.knowledgeCards.refreshIndex(source)
        guard indexed.index.revision == preview.revision, try await cleanCommit(store: store, taskID: sourceID) == preview.commit else { throw PetError("更新确认后源码已变化，请重新审阅") }
        try requireSnapshot(preview.snapshot, store: store, taskID: sourceID, language: preview.snapshot.metadata.language)
        try Task.checkCancellation()
        return try startPlanned(store: store, runtime: runtime, sourceID: sourceID, language: preview.snapshot.metadata.language, update: preview)
    }
    static func copyUpdatePages(_ preview: AgentWikiUpdatePreview, taskID: String, store: AgentStore) throws {
        guard let task = store.task(taskID), var job = task.wikiJob, var update = job.update else { throw PetError("Wiki 更新任务缺失") }
        let files = try AgentFiles(workspace: task.workspace), paths = try job.plan.paths(root: job.root), snapshot = preview.snapshot
        var mapping: [String: URL] = [:], payloads: [String: Data] = [:]
        for doc in snapshot.metadata.documents { guard let next = paths[doc.title] else { throw PetError("Wiki 页面与冻结规划不一致") }; mapping[try files.resolve(snapshot.root + "/" + doc.file).path] = try files.resolve(next) }
        for resource in snapshot.metadata.resources ?? [] { mapping[try files.resolve(snapshot.root + "/" + resource.file).path] = try files.resolve(job.root + "/" + resource.file) }
        for doc in snapshot.metadata.documents {
            guard let data = snapshot.data[doc.file], AgentFiles.hash(data) == doc.sha256, let path = paths[doc.title] else { throw PetError("Wiki 更新副本与审阅不一致") }
            let original = try files.resolve(snapshot.root + "/" + doc.file), next = try files.resolve(path)
            let rewritten = try AgentWikiLinks.rewrite(data, from: original, to: next, files: files, pages: mapping)
            guard rewritten.count <= 256_000 else { throw PetError("Wiki 更新单页超过256KB，请缩减或重新生成") }
            var sources: [String: String] = [:]
            for target in try AgentWikiLinks.localTargets(data, document: original, files: files) {
                let relative = files.relative(target)
                if relative.hasPrefix(snapshot.root + "/") || AgentMarkdownDocument.fragment(target) == nil { continue }
                guard updatePath(relative), let hash = snapshot.metadata.sourceHashes[relative] else { continue }
                sources[relative] = hash
            }
            update.retained[path] = AgentWikiRetainedPage(sha256: AgentFiles.hash(rewritten), sources: sources); payloads[path] = rewritten
        }
        for resource in snapshot.metadata.resources ?? [] {
            guard let bytes = snapshot.data[resource.file], AgentFiles.hash(bytes) == resource.sha256 else { throw PetError("Wiki 附件与审阅不一致") }
            let path = job.root + "/" + resource.file; guard payloads[path] == nil else { throw PetError("Wiki 页面与附件路径冲突") }; payloads[path] = bytes; update.assets[path] = resource.sha256
        }
        guard try files.entryMetadata(files.resolve(job.root)).kind == "missing" else { throw PetError("Wiki 更新目录已存在，未覆盖") }
        try requireSnapshot(snapshot, store: store, taskID: taskID, language: job.language)
        for (path, data) in payloads { try files.writeData(data, to: files.resolve(path), expectedTarget: "missing") }
        update.baseFiles = Dictionary(uniqueKeysWithValues: snapshot.data.map { (snapshot.root + "/" + $0.key, AgentFiles.hash($0.value)) })
        job.update = update; store.update(taskID) { $0.wikiJob = job }
        if let error = store.writeError { throw PetError(error) }
    }
    static func retainedPage(_ task: AgentTaskRecord, path: String, hash: String) -> Bool {
        guard let page = task.wikiJob?.update?.retained[path], page.sha256 == hash, !page.sources.isEmpty, let files = try? AgentFiles(workspace: task.workspace) else { return false }
        return page.sources.allSatisfy { (try? files.fileHash(files.resolve($0.key), maximum: 512_000)) == $0.value }
    }
    static func readUpdateChanges(_ call: AgentToolCall, store: AgentStore, task: AgentTaskRecord) throws -> AgentToolResult {
        guard var job = task.wikiJob, var update = job.update else { throw PetError("此任务没有提交更新差异") }
        let start = min(update.diff.count, max(0, call.object["content_offset"] as? Int ?? 0)), limit = min(1600, max(1, call.object["content_limit"] as? Int ?? 1200)), content = String(update.diff.dropFirst(start).prefix(limit))
        let hash = AgentFiles.hash(Data(update.diff.utf8)); var read = update.changesRead ?? AgentKnowledgeCardRead(sha256: hash, ranges: [])
        if !content.isEmpty, !read.ranges.contains([start + 1, start + content.count]) { read.ranges.append([start + 1, start + content.count]) }
        guard read.ranges.count <= 200 else { throw PetError("差异读取次数过多，请重新更新") }
        update.changesRead = read; job.update = update; store.update(task.id) { $0.wikiJob = job }
        if let error = store.writeError { throw PetError(error) }
        return AgentToolResult(text: "提交 \(update.baseCommit) → \(update.commit) · \(update.changedPaths.count) 个文件\n差异字符 \(start)...\(start + content.count)/\(update.diff.count)\n" + content + (start + content.count < update.diff.count ? "\n[next_offset=\(start + content.count)]" : "\n[提交差异已读到末尾]"))
    }
    static func confirmUpdatePage(_ call: AgentToolCall, store: AgentStore, task: AgentTaskRecord) throws -> AgentToolResult {
        guard var job = task.wikiJob, var update = job.update, let path = call.object["confirm_page"] as? String, let expected = call.object["expected_hash"] as? String, let copied = update.retained[path], copied.sha256 == expected, job.reviewed?[path] == expected else { throw PetError("请先完整回读本次复制的页面，再按当前哈希确认保留") }
        let files = try AgentFiles(workspace: task.workspace), file = try files.resolve(path), data = try files.readData(file, maximum: 256_000)
        guard AgentFiles.hash(data) == expected else { throw PetError("Wiki 页面已变化，请重新回读") }
        update.retained[path]?.sources = try pageSources(task, file: file, text: AgentTextFile.decode(data).text)
        job.update = update; store.update(task.id) { $0.wikiJob = job }; if let error = store.writeError { throw PetError(error) }
        return AgentToolResult(text: "已按实际源码读取与完整页面回读确认保留：" + path)
    }
}
