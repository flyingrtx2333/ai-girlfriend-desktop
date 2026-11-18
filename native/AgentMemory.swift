import Foundation

enum AgentMemoryScope: String, CaseIterable {
    case global, project, instructions, summary, userInstructions, localInstructions, effectiveInstructions
    var title: String { switch self { case .global: return "全局记忆"; case .project: return "项目记忆"; case .instructions: return "项目指令"; case .summary: return "任务摘要"; case .userInstructions: return "用户指令"; case .localInstructions: return "本机项目指令"; case .effectiveInstructions: return "有效指令" } }
    var isInstructions: Bool { [.instructions, .userInstructions, .localInstructions].contains(self) }
    var isProjectFile: Bool { [.project, .instructions, .localInstructions].contains(self) }
    var hasTopics: Bool { self == .global || self == .project }
    var primaryPath: String { self == .global ? "memory.md" : ".bluefatfish/memory.md" }
    var topicDirectory: String { self == .global ? "memory" : ".bluefatfish/memory" }
}
struct AgentMemoryDocument {
    let scope: AgentMemoryScope
    var topic: String? = nil
    var selection: String { topic.map { scope.rawValue + "/" + $0 } ?? scope.rawValue }

    init(_ scope: AgentMemoryScope, topic: String? = nil) { self.scope = scope; self.topic = topic }
    init?(selection: String) {
        let parts = selection.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, let scope = AgentMemoryScope(rawValue: String(first)) else { return nil }
        let topic = parts.count > 1 ? String(parts[1]) : nil
        guard topic.map({ scope.hasTopics && Self.validTopic($0) }) ?? true else { return nil }
        self.init(scope, topic: topic)
    }
    static func validTopic(_ name: String) -> Bool {
        let prohibited = CharacterSet.controlCharacters.union(.init(charactersIn: "/\\:"))
        return !name.hasPrefix(".") && name.utf8.count <= 160 && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
            && !name.unicodeScalars.contains(where: prohibited.contains) && !AgentFiles.sensitive(name)
            && ["md", "markdown"].contains((name as NSString).pathExtension.lowercased())
    }
}
struct AgentMemorySnapshot {
    var content: String
    var hash: String
    var location: String
    var workspace: String? = nil
    var exists = true
}
struct AgentMemoryCatalog {
    var topics: [String] = []
    var count = 0
    var latest: Date?
    var topicError: String?
}
struct AgentMemoryProjectSource: Equatable {
    let taskID: String?, workspace: String, title: String
}

@MainActor enum AgentMemory {
    private static func registeredProjects(_ store: AgentStore) -> [AgentDirectoryEntry] {
        AgentWorkMode.allCases.flatMap { store.organization.directories($0, tasks: [], includingArchived: true) }
    }
    static func projects(store: AgentStore, preferredTaskID: String?) -> [AgentMemoryProjectSource] {
        let projects = registeredProjects(store)
        let registeredPaths = Set(projects.flatMap(\.sourceFolders))
        var sources: [String: AgentMemoryProjectSource] = [:]
        func add(_ path: String, taskID: String?, title: String) {
            guard path.hasPrefix("/"), path != "/", !path.contains("\0"), path.utf8.count < 8192 else { return }
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            let key = taskID == nil ? normalized : (try? AgentFiles(workspace: path).root.path) ?? normalized
            // A redirected registration must not displace the destination in the catalog.
            if registeredPaths.contains(path), key != normalized { return }
            guard sources[key] == nil else { return }
            sources[key] = AgentMemoryProjectSource(taskID: taskID, workspace: path, title: title)
        }
        let tasks = store.tasks.sorted {
            if ($0.id == preferredTaskID) != ($1.id == preferredTaskID) { return $0.id == preferredTaskID }
            if $0.archived != $1.archived { return !$0.archived }
            return $0.id < $1.id
        }
        for task in tasks {
            for path in task.workspacePaths {
                let title = store.organization.name(path, mode: task.organizationMode) ?? URL(fileURLWithPath: path).lastPathComponent
                add(path, taskID: task.id, title: title)
            }
        }
        for project in projects {
            for path in project.sourceFolders {
                let title = path == project.primary ? project.title : URL(fileURLWithPath: path).lastPathComponent
                add(path, taskID: nil, title: title)
            }
        }
        return sources.values.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.workspace < $1.workspace : order == .orderedAscending
        }
    }
    static func agentSettings(store: AgentStore) throws -> AgentGeneralSettings.Settings {
        let service = AgentGeneralSettings(directory: store.directory.deletingLastPathComponent())
        if let error = service.error { throw PetError(error) }
        return service.settings
    }
    static func requireAgentEnabled(_ scope: AgentMemoryScope, store: AgentStore) throws {
        let settings = try agentSettings(store: store)
        guard scope == .global ? settings.globalMemory : settings.projectMemory else { throw PetError(scope.title + "已关闭；可在设置中重新启用") }
    }
    private static func root(_ scope: AgentMemoryScope, store: AgentStore, taskID: String?, workspace: String?, followParentLinks: Bool = true) throws -> AgentFiles {
        let path: String?
        if scope == .global { path = store.directory.path }
        else if scope == .userInstructions { path = store.directory.deletingLastPathComponent().path }
        else if scope.isProjectFile, taskID == nil, let workspace {
            guard workspace != "/", registeredProjects(store).contains(where: { $0.sourceFolders.contains(workspace) }) else { throw PetError("项目目录已离开登记范围") }
            path = workspace
        }
        else {
            guard let taskID, let original = store.task(taskID) else { throw PetError("任务不存在") }
            let task = try AgentWorkspaceScope.settingsTask(original, workspace: workspace)
            path = task.workspace
        }
        let files = try AgentFiles(workspace: path, followParentLinks: followParentLinks)
        if (scope.isProjectFile && taskID == nil || scope == .project && !followParentLinks), files.root.path != path {
            throw PetError("项目目录位置已变化，请重新选择")
        }
        return files
    }
    private static func file(_ scope: AgentMemoryScope, store: AgentStore, taskID: String?, workspace: String?, topic: String?) throws -> (AgentFiles, URL, Int) {
        let files = try root(scope, store: store, taskID: taskID, workspace: workspace, followParentLinks: topic == nil)
        if let topic {
            guard scope.hasTopics, AgentMemoryDocument.validTopic(topic) else { throw PetError("请输入有效的 Markdown 主题文件名") }
            return (files, try files.literalURL(scope.topicDirectory + "/" + topic), 24_000)
        }
        let path = scope == .instructions || scope == .userInstructions ? "AGENTS.md" : scope == .localInstructions ? "AGENTS.local.md" : scope.primaryPath
        let url = try files.resolve(path)
        if scope.isProjectFile, taskID == nil, url.path != files.root.appendingPathComponent(path).path {
            throw PetError(scope.title + "路径已变化，请检查文件后重新打开")
        }
        return (files, url, scope.isInstructions ? 65_536 : 24_000)
    }
    static func catalog(_ scope: AgentMemoryScope, store: AgentStore, taskID: String?, workspace: String? = nil) throws -> AgentMemoryCatalog {
        guard scope.hasTopics else { throw PetError("请选择全局或项目记忆") }
        _ = try root(scope, store: store, taskID: taskID, workspace: workspace)
        var result = AgentMemoryCatalog()
        if let (files, primary, _) = try? file(scope, store: store, taskID: taskID, workspace: workspace, topic: nil),
           let entry = try? files.entryMetadata(primary), entry.kind == "file" { result.count = 1; result.latest = entry.modified }
        do {
            let source = try root(scope, store: store, taskID: taskID, workspace: workspace, followParentLinks: false)
            let directory = source.root.appendingPathComponent(scope.topicDirectory, isDirectory: true)
            let topics = try source.regularFiles(in: directory).filter { AgentMemoryDocument.validTopic($0.name) }
            result.topics = topics.map(\.name).sorted { a, b in
                let order = a.localizedStandardCompare(b)
                return order == .orderedSame ? a < b : order == .orderedAscending
            }
            result.count += topics.count
            result.latest = ([result.latest].compactMap { $0 } + topics.map(\.modified)).max()
        } catch let error as POSIXError where error.code == .ENOENT {
            // The topic directory is created when the first document is saved.
        } catch { result.topicError = "主题目录无法读取：" + error.localizedDescription }
        return result
    }
    static func topicContext(store: AgentStore, task: AgentTaskRecord, settings: AgentGeneralSettings.Settings) -> String {
        var sources: [(AgentMemoryScope, String?)] = []
        if settings.globalMemory { sources.append((.global, nil)) }
        if settings.projectMemory { sources += task.workspacePaths.map { (.project, $0) } }
        var lines: [String] = [], bytes = 0, omitted = false
        for (scope, workspace) in sources {
            guard let value = try? catalog(scope, store: store, taskID: task.id, workspace: workspace), !value.topics.isEmpty else { continue }
            var item: [String: Any] = ["scope": scope.rawValue, "topics": Array(value.topics.prefix(4)), "topic_count": value.topics.count]
            item["workspace"] = workspace
            guard let data = try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys, .withoutEscapingSlashes]) else { continue }
            guard bytes + data.count <= 1800 else { omitted = true; continue }
            bytes += data.count
            lines.append(String(decoding: data, as: UTF8.self))
        }
        if omitted { lines.append("其余主题可通过 read_memory 的源目录和分页参数列出。") }
        return lines.joined(separator: "\n")
    }
    static func createTopic(_ name: String, scope: AgentMemoryScope, store: AgentStore, taskID: String?, workspace: String?) throws -> AgentMemoryDocument {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let topic = (cleaned as NSString).pathExtension.isEmpty ? cleaned + ".md" : cleaned
        let (files, url, _) = try file(scope, store: store, taskID: taskID, workspace: workspace, topic: topic)
        guard try files.entryMetadata(url).kind == "missing" else { throw PetError("已存在同名主题") }
        try files.writeData(Data(), to: url, permissions: scope == .global ? 0o600 : 0o644, expectedTarget: "missing")
        return AgentMemoryDocument(scope, topic: topic)
    }
    static func importDestination(store: AgentStore, workspace: String?) throws -> (files: AgentFiles, folder: URL) {
        let taskID: String?
        if let workspace {
            guard let source = projects(store: store, preferredTaskID: store.selectedID).first(where: { $0.workspace == workspace }) else { throw PetError("导入目标已离开项目范围") }
            taskID = source.taskID
        } else { taskID = nil }
        let scope: AgentMemoryScope = workspace == nil ? .global : .project
        let files = try root(scope, store: store, taskID: taskID, workspace: workspace, followParentLinks: false)
        let folder = try files.literalURL(scope.topicDirectory)
        guard ["missing", "directory"].contains(try files.entryMetadata(folder).kind) else { throw PetError("记忆目录不是普通目录") }
        return (files, folder)
    }
    static func revealURL(_ document: AgentMemoryDocument, store: AgentStore, taskID: String?, workspace: String?) throws -> URL {
        let (files, url, _) = try file(document.scope, store: store, taskID: taskID, workspace: workspace, topic: document.topic)
        guard try files.entryMetadata(url).kind == "file" else { throw PetError("记忆文件已移除") }
        return url
    }
    static func snapshot(_ scope: AgentMemoryScope, store: AgentStore, taskID: String?, workspace: String? = nil, topic: String? = nil) throws -> AgentMemorySnapshot {
        guard topic == nil || scope.hasTopics else { throw PetError("此范围不支持主题文件") }
        if scope == .effectiveInstructions {
            guard let taskID, let task = store.task(taskID) else { throw PetError("任务不存在") }
            let report = store.instructions.report(task), text = report.preview
            return AgentMemorySnapshot(content: text, hash: AgentFiles.hash(Data(text.utf8)), location: "\(report.sources.count)份来源" + (report.issues.isEmpty ? "" : " · \(report.issues.count)项待处理"))
        }
        if scope == .summary {
            guard let taskID, let task = store.task(taskID) else { throw PetError("任务不存在") }
            let text = task.contextSummary ?? ""
            return AgentMemorySnapshot(content: text, hash: AgentFiles.hash(Data(text.utf8)), location: "当前任务摘要")
        }
        let (files, url, maximum) = try file(scope, store: store, taskID: taskID, workspace: workspace, topic: topic)
        let entry = try files.entryMetadata(url)
        guard entry.kind == "file" || entry.kind == "missing" else { throw PetError("记忆路径不是普通文件") }
        let exists = entry.kind == "file"
        let data = exists ? try files.readData(url, maximum: maximum) : Data()
        guard let text = String(data: data, encoding: .utf8) else { throw PetError("记忆文件不是 UTF-8 文本") }
        let path = topic.map { scope.topicDirectory + "/" + $0 } ?? files.relative(url)
        let location = scope == .global ? "全局 " + (topic == nil ? scope.primaryPath : path) : path
        return AgentMemorySnapshot(content: text, hash: AgentFiles.hash(data), location: location, workspace: [.global, .userInstructions].contains(scope) ? nil : files.root.path, exists: exists)
    }
    static func save(_ scope: AgentMemoryScope, content: String, expectedHash: String, store: AgentStore, taskID: String?, workspace: String? = nil, topic: String? = nil, expectedExists: Bool? = nil) throws -> AgentMemorySnapshot {
        guard scope != .effectiveInstructions else { throw PetError("请编辑原指令文件，有效指令只读") }
        if let taskID, store.task(taskID) == nil { throw PetError("任务不存在") }
        let previous = try snapshot(scope, store: store, taskID: taskID, workspace: workspace, topic: topic)
        guard previous.hash == expectedHash, expectedExists == nil || expectedExists == previous.exists else { throw PetError("记忆已更改，请重新打开后编辑") }
        let data = Data(content.utf8)
        if scope == .summary {
            guard let taskID, let task = store.task(taskID) else { throw PetError("任务不存在") }
            guard task.status != .running, data.count <= 24_000 else { throw PetError("请先停止任务，摘要最多 24 KB") }
            store.update(taskID) { $0.contextSummary = content.isEmpty ? nil : content; if content.isEmpty { $0.contextThroughID = nil } }
            if let error = store.writeError { throw PetError(error) }
        } else {
            let (files, url, maximum) = try file(scope, store: store, taskID: taskID, workspace: workspace, topic: topic)
            guard data.count <= maximum else { throw PetError(scope.isInstructions ? "指令最多 64 KB" : "记忆最多 24 KB") }
            let metadata = try files.entryMetadata(url)
            guard metadata.kind == "missing" || (metadata.permissions ?? 0) & 0o222 != 0 else { throw PetError(scope.title + "文件只读，未保存") }
            if metadata.kind == "missing", previous.exists { throw PetError("记忆文件已被移除，请重新打开后编辑") }
            if metadata.kind != "missing", !previous.exists { throw PetError("同名记忆已创建，请重新打开后编辑") }
            if metadata.kind != "missing", try files.fileHash(url, maximum: maximum) != expectedHash { throw PetError("记忆已更改，请重新打开后编辑") }
            if !previous.content.isEmpty {
                let directory = store.directory.appendingPathComponent("memory-backups", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let backup = directory.appendingPathComponent(UUID().uuidString + ".md")
                try Data(previous.content.utf8).write(to: backup, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
            let permissions = metadata.permissions ?? ([.global, .userInstructions].contains(scope) ? 0o600 : 0o644)
            if scope.isInstructions { store.instructions.onChange?(nil, scope == .userInstructions ? nil : files.root.path) }
            try files.writeData(data, to: url, permissions: permissions, expectedTarget: metadata.signature)
        }
        return try snapshot(scope, store: store, taskID: taskID, workspace: workspace, topic: topic)
    }
}
