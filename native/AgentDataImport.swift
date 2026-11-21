import Foundation
import Darwin

struct AgentImportRoute: Hashable, Codable, Sendable {
    let source: AgentImportSource
    let category: AgentImportCategory
    let root: String
    let workspace: String?
    var sshHost: String? = nil

    var directory: URL { URL(fileURLWithPath: root) }
}

struct AgentImportPreview {
    let id = UUID()
    let records: [AgentImportCandidate]
    let issue: String?
    let available: Set<String>

    init(records: [AgentImportCandidate], issue: String? = nil) {
        self.records = records; self.issue = issue
        available = Set(records.lazy.filter { $0.issue == nil }.map(\.id))
    }
}

struct AgentImportItem: Codable, Identifiable {
    var record: AgentImportCandidate
    var state = "pending"
    var detail = ""
    var sourceRoot: String? = nil
    var id: String { record.id }
}
struct AgentImportBatch: Codable {
    var id = UUID().uuidString
    var source: AgentImportSource
    var root: String
    var state = "paused"
    var items: [AgentImportItem]
    var created = Date()
    var sshHost: String? = nil
    var category: AgentImportCategory { items.first?.record.category ?? .tasks }
    var targetWorkspace: String? { items.first?.record.targetWorkspace }

    func route(for item: AgentImportItem) -> AgentImportRoute {
        .init(source: source, category: item.record.category, root: item.sourceRoot ?? root,
              workspace: item.record.targetWorkspace, sshHost: sshHost)
    }
}

@MainActor final class AgentDataImport {
    private unowned let store: AgentStore
    private let directory: URL, journal: URL
    private var signature = "missing", loadIssue: String?
    private var work: Task<Void, Never>?
    private var sshScan: (route: AgentImportRoute, task: Task<[AgentImportCandidate], Error>)?
    private var lock: Int32 = -1
    private(set) var batch: AgentImportBatch?
    private var recentRoute: AgentImportRoute?
    private var previews: [AgentImportRoute: AgentImportPreview] = [:]
    var preview: [AgentImportCandidate] { recentRoute.flatMap { previews[$0]?.records } ?? [] }
    private(set) var scanning = false
    private(set) var stoppedScan: AgentImportRoute?
    var stoppingScan: Bool { sshScan?.task.isCancelled == true }
    private(set) var operationIssue: String?
    var issue: String? { operationIssue ?? recentRoute.flatMap { previews[$0]?.issue } }
    var onChange: (() -> Void)?
    var active: Bool { work != nil }
    var unfinished: Bool { batch?.items.contains(where: { $0.state == "pending" }) == true && batch?.state != "cancelled" }
    private var ssh: AgentSSHImport {
        .init(profile: store.directory.deletingLastPathComponent(), home: store.extensions.sharedHome)
    }

    init(store: AgentStore) {
        self.store = store; directory = store.directory.deletingLastPathComponent().appendingPathComponent("imports"); journal = directory.appendingPathComponent("batch.json")
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        do {
            let files = try AgentFiles(workspace: directory.path), before = try files.entryMetadata(journal).signature
            let bytes = try files.readData(journal, maximum: 12_000_000)
            guard try files.entryMetadata(journal).signature == before else { throw PetError("导入记录正在变化") }
            batch = try JSONDecoder().decode(AgentImportBatch.self, from: bytes); signature = before
            if batch?.state == "running" { batch?.state = "paused" }
        } catch { loadIssue = "导入记录无法读取，原件已保留：" + error.localizedDescription; operationIssue = loadIssue }
    }
    private func save() throws {
        if let loadIssue { throw PetError(loadIssue) }
        guard let batch else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(batch); guard bytes.count <= 12_000_000 else { throw PetError("导入记录过大") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files = try AgentFiles(workspace: directory.path)
        try files.writeData(bytes, to: journal, permissions: 0o600, expectedTarget: signature); signature = try files.entryMetadata(journal).signature
    }
    static func taskHash(_ task: AgentTaskRecord) throws -> String {
        var value = task; value.importOrigin = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return AgentFiles.hash(try encoder.encode(value))
    }

    func preview(for route: AgentImportRoute) -> AgentImportPreview? { previews[route] }

    func canStopScan(for route: AgentImportRoute) -> Bool { sshScan?.route == route && sshScan?.task.isCancelled == false }

    func stopScan(for route: AgentImportRoute) {
        guard canStopScan(for: route) else { return }
        sshScan?.task.cancel()
        onChange?()
    }

    func detect(_ source: AgentImportSource, root: URL, category: AgentImportCategory = .tasks, workspace: String? = nil) async {
        await detect([.init(source: source, category: category, root: root.path, workspace: workspace)])
    }

    func detect(_ routes: [AgentImportRoute]) async {
        guard let first = routes.first, routes.allSatisfy({ $0.source == first.source && $0.sshHost == first.sshHost }),
              Set(routes.map(\.category)).count == routes.count else { return }
        guard !scanning, !active, !unfinished else { operationIssue = "请先继续或取消尚未完成的导入"; onChange?(); return }
        if let loadIssue { operationIssue = loadIssue; onChange?(); return }
        let categories = Set(routes.map(\.category))
        previews = previews.filter { $0.key.source != first.source || $0.key.sshHost != first.sshHost || !categories.contains($0.key.category) }
        recentRoute = routes.count == 1 ? first : nil
        scanning = true; stoppedScan = nil; operationIssue = nil
        onChange?()
        defer { scanning = false; onChange?() }
        for route in routes {
            do {
                let records = try await (route.sshHost == nil ? discover(route) : discoverSSH(route))
                previews[route] = .init(records: records)
            }
            catch is CancellationError { stoppedScan = route; break }
            catch { previews[route] = .init(records: [], issue: error.localizedDescription) }
            onChange?()
        }
    }

    private func discoverSSH(_ route: AgentImportRoute) async throws -> [AgentImportCandidate] {
        let task = Task { try await discover(route) }
        sshScan = (route, task)
        onChange?()
        defer { sshScan = nil }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            guard !task.isCancelled else { throw CancellationError() }
            return result
        } onCancel: { task.cancel() }
    }

    private func discover(_ route: AgentImportRoute) async throws -> [AgentImportCandidate] {
        if route.sshHost != nil, !AgentSSHImport.categories.contains(route.category) { throw PetError("此类别暂不支持 SSH 导入") }
        let source = route.source, root = route.directory, workspace = route.workspace
        switch route.category {
        case .memory:
            let destination = try AgentMemory.importDestination(store: store, workspace: workspace)
            let records: [AgentMemoryImport.Preview]
            if route.sshHost != nil { records = try await ssh.discoverMemory(route) }
            else { records = try await Task.detached(priority: .utility) { try AgentMemoryImport.discover(source, root: root, workspace: workspace) }.value }
            var reserved = Set<String>()
            return records.map { entry in
                do { return try AgentMemoryImport.plan(entry, destination: destination, reserved: &reserved) }
                catch { var skipped = entry.record; skipped.issue = error.localizedDescription; return skipped }
            }
        case .skills:
            let records: [AgentImportCandidate]
            if route.sshHost != nil { records = try await ssh.discoverSkills(route) }
            else { records = try await Task.detached(priority: .utility) { try AgentSkillImport.discover(source, root: root, workspace: workspace) }.value }
            return try AgentSkillImport.plan(records, store: store, workspace: workspace)
        case .connectors:
            let records = try await Task.detached(priority: .utility) { try AgentMCPDataImport.discover(source, root: root, workspace: workspace) }.value
            return try AgentMCPDataImport.plan(records, workspace: workspace, store: store)
        case .automations:
            let records = try await Task.detached(priority: .utility) { try AgentAutomationDataImport.discover(source, root: root, workspace: workspace) }.value
            return try AgentAutomationDataImport.plan(records, workspace: workspace, store: store)
        case .plugins:
            return try await AgentPluginDataImport.discover(source, root: root, workspace: workspace, store: store)
        case .configuration:
            return try await AgentStandaloneDataImport.discover(source, root: root, workspace: workspace, store: store)
        case .tasks:
            let records: [AgentImportCandidate]
            if route.sshHost != nil { records = try await ssh.discover(route) }
            else { records = try await Task.detached(priority: .utility) { try AgentImportReaders.discover(source, root: root) }.value }
            let duplicates = Dictionary(grouping: records, by: \.id)
            return try records.map { record in
                var value = record
                guard value.issue == nil else { return value }
                value.targetID = try store.importTargetID(value.targetID)
                if duplicates[value.id, default: []].count > 1 { value.issue = "同编号存在多份来源，请分别选择来源目录"; return value }
                if let task = store.task(value.targetID) {
                    guard let origin = task.importOrigin, origin.key == value.id else { value.issue = "目标任务编号已被占用，未覆盖"; return value }
                    if origin.sourceHash == value.sourceHash { value.issue = "已经导入" }
                    else if (try? Self.taskHash(task)) != origin.taskHash { value.issue = "本地任务已继续或修改，保留现有内容" }
                }
                return value
            }
        }
    }

    func begin(_ source: AgentImportSource, root: URL, ids: Set<String>, category: AgentImportCategory = .tasks, workspace: String? = nil) throws {
        let route = AgentImportRoute(source: source, category: category, root: root.path, workspace: workspace)
        guard recentRoute == route else { throw PetError("来源或导入目标已变化，请重新检测") }
        try begin([route: ids])
    }

    func begin(_ selections: [AgentImportRoute: Set<String>]) throws {
        guard !active, !scanning, !unfinished else { throw PetError("已有尚未完成的导入") }
        let choices = selections.filter { !$0.value.isEmpty }
        guard let first = choices.keys.first else { throw PetError("请选择可导入的内容") }
        let source = first.source
        guard choices.keys.allSatisfy({ $0.source == source && $0.sshHost == first.sshHost }),
              Set(choices.keys.map(\.category)).count == choices.count else {
            throw PetError("请从同一来源选择导入内容")
        }
        var items: [AgentImportItem] = []
        let ordered = AgentImportCategory.allCases.compactMap { category in choices.keys.first { $0.category == category } }
        guard let root = ordered.first?.root else { throw PetError("请选择可导入的内容") }
        for route in ordered {
            guard let ids = choices[route], let preview = previews[route], ids.isSubset(of: preview.available) else {
                throw PetError("来源或导入目标已变化，请重新检测")
            }
            let records = preview.records.filter { ids.contains($0.id) && $0.issue == nil }
            guard records.allSatisfy({ $0.source == route.source && $0.category == route.category &&
                $0.targetWorkspace == route.workspace && $0.sshHost == route.sshHost }) else {
                throw PetError("导入记录与选定来源或目标不符，请重新检测")
            }
            items += records.map { record in
                .init(record: record, sourceRoot: route.root == root ? nil : route.root)
            }
        }
        if let previous = batch {
            let history = directory.appendingPathComponent("history")
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let files = try AgentFiles(workspace: history.path), url = try files.literalURL(previous.id + ".json")
            let bytes = try JSONEncoder().encode(previous)
            try files.writeData(bytes, to: url, permissions: 0o600)
        }
        let previous = batch
        batch = AgentImportBatch(source: source, root: root, items: items, sshHost: first.sshHost)
        do { try save() } catch { batch = previous; throw error }
        operationIssue = nil; previews = previews.filter { $0.key.source != source || $0.key.sshHost != first.sshHost }; recentRoute = nil
        resume()
    }
    func pause() {
        guard active else { return }
        batch?.state = "paused"
        if batch?.sshHost != nil { work?.cancel() }
        do { try save() } catch { operationIssue = error.localizedDescription }
        onChange?()
    }
    func cancel() {
        guard unfinished || active else { return }
        batch?.state = "cancelled"
        if batch?.sshHost != nil { work?.cancel() }
        do { try save() } catch { operationIssue = error.localizedDescription }
        onChange?()
    }
    func resume() {
        guard work == nil, unfinished, loadIssue == nil else { return }
        batch?.state = "running"; operationIssue = nil
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let files = try AgentFiles(workspace: directory.path), url = try files.literalURL("import.lock")
            let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw PetError("导入锁无法打开") }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); throw PetError("另一个应用窗口正在导入，请稍后继续") }
            lock = descriptor; try save()
        } catch { releaseLock(); batch?.state = "paused"; operationIssue = error.localizedDescription; onChange?(); return }
        work = Task { [weak self] in await self?.process() }; onChange?()
    }
    private func process() async {
        defer { releaseLock(); work = nil; onChange?() }
        while let current = batch, current.state == "running", let index = current.items.firstIndex(where: { $0.state == "pending" }) {
            let item = current.items[index]
            let candidate = item.record, route = current.route(for: item), root = route.root, source = route.source
            do {
                if candidate.memory != nil {
                    let id = current.id
                    guard UUID(uuidString: id) != nil else { throw PetError("导入批次编号无效") }
                    let data: Data
                    if route.sshHost != nil || candidate.sshHost != nil {
                        data = try await ssh.readMemory(candidate, route: route)
                        guard batch?.state == "running" else { return }
                    } else {
                        let base = URL(fileURLWithPath: root)
                        data = try await Task.detached(priority: .utility) { try AgentMemoryImport.read(candidate, root: base) }.value
                    }
                    let recordID = AgentFiles.hash(Data(candidate.id.utf8))
                    let backup = directory.appendingPathComponent("memory-transfers").appendingPathComponent(id).appendingPathComponent(recordID)
                    try AgentMemoryImport.install(data, record: candidate, store: store, backup: backup)
                } else if candidate.skill != nil {
                    if route.sshHost != nil || candidate.sshHost != nil {
                        try await AgentSkillImport.install(candidate, store: store) { try await ssh.readSkill(candidate, route: route) }
                    } else {
                        try await AgentSkillImport.install(candidate, root: URL(fileURLWithPath: root), store: store)
                    }
                } else if route.sshHost != nil || candidate.sshHost != nil {
                    let document = try await ssh.read(candidate, route: route)
                    guard batch?.state == "running" else { return }
                    guard document.candidate.id == candidate.id, document.candidate.sourceHash == candidate.sourceHash,
                          document.candidate.rawHash == candidate.rawHash else { throw PetError("远端来源已更新，请重新检测；本次未替换任务") }
                    try install(document, candidate: candidate)
                } else if candidate.connector != nil {
                    try await AgentMCPDataImport.install(candidate, root: URL(fileURLWithPath: root), store: store)
                } else if candidate.automation != nil {
                    try await AgentAutomationDataImport.install(candidate, root: URL(fileURLWithPath: root), store: store)
                } else if candidate.plugin != nil {
                    try await AgentPluginDataImport.install(candidate, root: URL(fileURLWithPath: root), store: store)
                } else if candidate.configuration != nil {
                    try await AgentStandaloneDataImport.install(candidate, root: URL(fileURLWithPath: root), store: store)
                } else {
                    let document = try await Task.detached(priority: .utility) {
                        let directory = URL(fileURLWithPath: root)
                        let index = source == .codex ? AgentImportReaders.codexIndex(directory) : [:]
                        return try AgentImportReaders.read(source, file: URL(fileURLWithPath: candidate.file), root: directory, index: index)
                    }.value
                    guard document.candidate.sourceHash == candidate.sourceHash else { throw PetError("来源已更新，请重新检测；本次未替换任务") }
                    try install(document, candidate: candidate)
                }
                batch?.items[index].state = "imported"; batch?.items[index].detail = "已导入"
            } catch {
                if route.sshHost != nil, batch?.state != "running" { return }
                batch?.items[index].state = "failed"; batch?.items[index].detail = error.localizedDescription
            }
            do { try save() } catch { operationIssue = "进度未保存，请重新打开应用后继续：" + error.localizedDescription; return }
            onChange?(); await Task.yield()
        }
        if batch?.state != "cancelled", batch?.items.contains(where: { $0.state == "pending" }) == false { batch?.state = "completed"; do { try save() } catch { operationIssue = error.localizedDescription } }
    }
    private func releaseLock() { if lock >= 0 { flock(lock, LOCK_UN); close(lock); lock = -1 } }
    private func install(_ document: AgentImportDocument, candidate: AgentImportCandidate) throws {
        let identity = candidate.targetID
        guard try store.importTargetID(identity) == identity else { throw PetError("目标任务已永久删除，请重新检测后导入") }
        if let task = store.task(identity) {
            guard let origin = task.importOrigin, origin.key == candidate.id else { throw PetError("目标任务编号已被占用，未覆盖") }
            if origin.sourceHash == candidate.sourceHash {
                if !store.tasks.contains(where: { $0.id == identity }) { try store.installImportedRecord(task) }
                return
            }
            guard try Self.taskHash(task) == origin.taskHash else { throw PetError("本地任务已继续或修改，未覆盖") }
        }
        let snapshots = directory.appendingPathComponent("records"), name = AgentFiles.hash(Data((candidate.id + ":" + candidate.rawHash).utf8)) + ".jsonl"
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files = try AgentFiles(workspace: snapshots.path), target = try files.literalURL(name)
        if FileManager.default.fileExists(atPath: target.path) {
            guard AgentFiles.hash(try files.readData(target, maximum: AgentImportReaders.maximumBytes)) == candidate.rawHash else { throw PetError("已保存的来源副本发生变化，未覆盖") }
        } else { try files.writeData(document.raw, to: target, permissions: 0o600, expectedTarget: "missing") }
        var task = AgentTaskRecord(title: candidate.title, workspace: candidate.sshHost == nil ? candidate.workspace : nil, mode: .agent)
        task.id = identity; task.permission = .review; task.status = .stopped; task.archived = candidate.archived
        if let workspace = task.workspace, !FileManager.default.fileExists(atPath: workspace) { task.workspace = nil }
        task.messages = document.messages; task.events = document.events; task.created = candidate.created; task.updated = candidate.updated
        task.summary = "从" + candidate.source.title + "导入 · " + String(candidate.preview.prefix(160))
        task.importOrigin = AgentImportOrigin(source: candidate.source, sourceID: candidate.sourceID, sourceFile: candidate.file, sourceHash: candidate.sourceHash, rawHash: candidate.rawHash, originalWorkspace: candidate.workspace, snapshot: name, taskHash: try Self.taskHash(task), historyThroughID: task.messages.last?.id, warnings: candidate.warnings, sshHost: candidate.sshHost)
        try store.installImportedRecord(task)
    }
    static func historyBoundary(_ task: AgentTaskRecord, directory: URL) throws -> String? {
        guard let origin = task.importOrigin else { return nil }
        let expected = AgentFiles.hash(Data((origin.key + ":" + origin.rawHash).utf8)) + ".jsonl"
        guard origin.snapshot == expected else { throw PetError("来源副本编号不匹配") }
        let root = directory.deletingLastPathComponent().appendingPathComponent("imports/records")
        let document = try AgentImportReaders.read(origin.source, file: root.appendingPathComponent(expected), root: root)
        guard document.candidate.rawHash == origin.rawHash, document.candidate.sourceID.lowercased() == origin.sourceID.lowercased(), !document.messages.isEmpty, document.messages.count <= task.messages.count else { throw PetError("导入历史与来源副本不匹配") }
        return task.messages[document.messages.count - 1].id
    }
    func sourceURL(_ taskID: String) throws -> URL {
        guard let origin = store.task(taskID)?.importOrigin else { throw PetError("此任务没有导入来源") }
        let expected = AgentFiles.hash(Data((origin.key + ":" + origin.rawHash).utf8)) + ".jsonl"
        guard origin.snapshot == expected else { throw PetError("来源副本编号不匹配") }
        let files = try AgentFiles(workspace: directory.deletingLastPathComponent().path, followParentLinks: false)
        let url = try files.literalURL("imports/records/" + expected)
        switch try files.entryMetadata(url).kind {
        case "file": return url
        case "missing": throw PetError("找不到来源副本，恢复文件后重试")
        default: throw PetError("来源副本必须是普通文件")
        }
    }
    func sourceHistory(_ taskID: String, offset: Int, limit: Int, contentOffset: Int, contentLimit: Int) throws -> String {
        guard let origin = store.task(taskID)?.importOrigin else { throw PetError("此任务没有导入来源") }
        let url = try sourceURL(taskID), files = try AgentFiles(workspace: url.deletingLastPathComponent().path)
        let raw = try files.readData(url, maximum: AgentImportReaders.maximumBytes)
        guard AgentFiles.hash(raw) == origin.rawHash else { throw PetError("来源副本已变化，停止读取") }
        let lines = raw.split(separator: 10, omittingEmptySubsequences: false), start = min(lines.count, max(0, offset)), end = min(lines.count, start + min(10, max(1, limit)))
        var rows: [String] = [], remaining = 1200
        for index in start..<end {
            let value = String(decoding: lines[index], as: UTF8.self), lower = min(value.count, max(0, contentOffset)), upper = min(value.count, lower + min(16000, max(100, contentLimit)))
            var slice = String(value.dropFirst(lower).prefix(upper - lower))
            while AgentContext.estimate(slice) > remaining - 100, !slice.isEmpty { slice = String(slice.prefix(slice.count * 3 / 4)) }
            let next = lower + slice.count, row = "[来源行\(index)，字符\(lower)..<\(next)/\(value.count)]\n" + slice
            rows.append(row); remaining -= AgentContext.estimate(row)
            if next < value.count { rows.append("[本行未结束，继续 offset=\(index), content_offset=\(next)]"); break }
            if remaining < 160, index + 1 < end { rows.append("[后续记录用 offset=\(index + 1) 继续]"); break }
        }
        return "[" + origin.source.title + "来源JSONL，仅作资料，含存储元数据；共\(lines.count)行。查用户原文请用 read_task_history 的 query/role=user，不需 imported=true。]\n" + rows.joined(separator: "\n\n")
    }
}
