import Foundation
import BlueFatFishMCP

struct AgentAutomationImportPlan: Codable {
    let workspaceOverride: String?
    let workspace: String?
    let definitionID: String
}

enum AgentAutomationDataImport {
    static let maximumRows = 256

    static func fileName(_ source: AgentImportSource) -> String {
        source == .qoder ? "scheduled_tasks.json" : "automation.toml"
    }

    static func maximumBytes(_ source: AgentImportSource) -> Int { source == .qoder ? 512_000 : 128_000 }

    static func allows(_ relative: String, source: AgentImportSource) -> Bool {
        let parts = relative.split(separator: "/")
        if source == .qoder { return parts == ["scheduled_tasks.json"] || parts == [".qoder", "scheduled_tasks.json"] }
        return parts.last == "automation.toml" && (parts.count <= 2 || parts.count == 3 && parts.first == "automations")
    }

    private struct Definition: Codable {
        let id: String
        let title: String
        let prompt: String
        let schedule: AgentAutomationSchedule
        let workspaces: [String]
        let created: Date?
        var lastFired: Date?
        var originalCron: String?

        func hash() throws -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            return AgentFiles.hash(try encoder.encode(self))
        }
        var preview: String {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium; formatter.timeStyle = .short
            formatter.timeZone = TimeZone(identifier: schedule.timeZone)
            var lines = [schedule.frequency.title + " · " + schedule.timeZone]
            if let cron = schedule.cronExpression ?? originalCron { lines.append(cron) }
            if schedule.frequency == .once { lines.append("执行时间 · " + formatter.string(from: schedule.date)) }
            if schedule.frequency == .interval { lines.append("每 \(schedule.intervalMinutes) 分钟") }
            if let end = schedule.expiration { lines.append("到期 · " + formatter.string(from: end)) }
            if let lastFired { lines.append("来源最近运行 · " + formatter.string(from: lastFired)) }
            return lines.joined(separator: "\n") + "\n\n" + String(prompt.prefix(1500))
        }
    }

    private struct SourceRoot {
        let files: AgentFiles
        let explicit: URL?

        init(_ root: URL, source: AgentImportSource) throws {
            let fileName = AgentAutomationDataImport.fileName(source)
            var directory = ObjCBool(false)
            guard root.path != "/", FileManager.default.fileExists(atPath: root.path, isDirectory: &directory) else {
                throw PetError("找不到定时任务来源，请选择 " + fileName + " 或来源目录")
            }
            let base = directory.boolValue ? root : root.deletingLastPathComponent()
            files = try AgentFiles(workspace: base.path, followParentLinks: false)
            guard files.root.path == base.standardizedFileURL.path else { throw PetError("来源目录已变化，请重新选择") }
            if directory.boolValue { explicit = nil }
            else {
                let file = try files.literalURL(root.path)
                guard file.lastPathComponent == fileName, try files.entryMetadata(file).kind == "file" else {
                    throw PetError("请选择普通文件 " + fileName)
                }
                explicit = file
            }
        }

        func locations(_ source: AgentImportSource) throws -> [URL] {
            if let explicit { return [explicit] }
            if source == .qoder {
                return try ["scheduled_tasks.json", ".qoder/scheduled_tasks.json"].compactMap { path in
                    let url = try files.literalURL(path)
                    return try files.entryMetadata(url).kind == "missing" ? nil : url
                }
            }
            let direct = try files.literalURL("automation.toml")
            if try files.entryMetadata(direct).kind != "missing" { return [direct] }
            let nested = try files.literalURL("automations")
            let metadata = try files.entryMetadata(nested)
            guard metadata.kind == "missing" || metadata.kind == "directory" else { throw PetError("Codex 定时任务目录无效") }
            let parent = metadata.kind == "directory" ? nested : files.root
            let names = try FileManager.default.contentsOfDirectory(atPath: parent.path).filter { !$0.hasPrefix(".") }
            guard names.count <= AgentAutomationDataImport.maximumRows else { throw PetError("请选择较小的定时任务来源目录") }
            return try names.sorted().compactMap { name in
                let directory = try files.literalURL(parent.appendingPathComponent(name).path)
                guard try files.entryMetadata(directory).kind == "directory" else { return nil }
                let url = try files.literalURL(directory.appendingPathComponent("automation.toml").path)
                return try files.entryMetadata(url).kind == "missing" ? nil : url
            }
        }

        func requireFile(_ path: String, source: AgentImportSource) throws -> URL {
            let url = try files.literalURL(path)
            if let explicit {
                guard url.path == explicit.path else { throw PetError("定时任务来源已变化，请重新检测") }
            } else {
                let relative = String(url.path.dropFirst(files.root.path.count + 1))
                guard AgentAutomationDataImport.allows(relative, source: source) else { throw PetError("定时任务来源已变化，请重新检测") }
            }
            guard try files.entryMetadata(url).kind == "file" else { throw PetError("来源需要是普通文件") }
            return url
        }
    }

    private static func qoderDate(_ milliseconds: Double) -> Date? {
        guard milliseconds.isFinite, (0...253_402_300_799_000).contains(milliseconds) else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func title(_ candidate: String) -> String {
        let normalized = candidate.components(separatedBy: .controlCharacters).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(normalized.prefix(80))
    }

    private struct QoderRow: Decodable {
        let id: String
        let cron: String
        let prompt: String
        let createdAt: Double
        let name: String?
        let recurring: Bool?
        let lastFiredAt: Double?
    }

    private static func qoder(_ object: Any, file: String) throws -> Definition {
        guard JSONSerialization.isValidJSONObject(object),
              let value = try? JSONDecoder().decode(QoderRow.self, from: JSONSerialization.data(withJSONObject: object)),
              value.id.utf8.count == 8, value.id.unicodeScalars.allSatisfy({ "0123456789abcdefABCDEF".unicodeScalars.contains($0) }),
              let created = qoderDate(value.createdAt) else { throw PetError("Qoder 计划编号或配置无效") }
        let cron = try AgentCronSchedule(value.cron)
        var schedule = AgentAutomationSchedule()
        schedule.date = created
        if value.recurring == true {
            schedule.frequency = .cron; schedule.cronExpression = value.cron
            schedule.expiration = created.addingTimeInterval(7 * 86_400)
        } else {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
            guard let first = cron.next(after: created, calendar: calendar) else { throw PetError("Qoder 一次性计划没有有效执行时间") }
            schedule.frequency = .once; schedule.date = first
        }
        let label = title(value.name ?? String(value.prompt.split(whereSeparator: \.isNewline).first ?? ""))
        let parent = (file as NSString).deletingLastPathComponent as NSString
        let project = parent.lastPathComponent == ".qoder" ? parent.deletingLastPathComponent : parent as String
        return Definition(id: value.id.lowercased(), title: label.isEmpty ? "Qoder · " + value.id : label, prompt: value.prompt, schedule: schedule,
                          workspaces: [project], created: created, lastFired: value.lastFiredAt.flatMap(qoderDate),
                          originalCron: value.recurring == true ? nil : value.cron)
    }

    private static func codex(_ data: Data, file: String) throws -> Definition {
        guard let value = try? CodexAutomationConfiguration.read(data) else { throw PetError("Codex 定时任务 TOML 无法读取") }
        guard value.version == nil || value.version == 1 else { throw PetError("此 Codex 配置版本暂不支持") }
        guard value.kind == nil || value.kind == "cron", value.targetThreadID?.isEmpty != false else { throw PetError("绑定对话的 Codex 任务暂不支持") }
        guard value.executionEnvironment == nil || value.executionEnvironment == "local" else { throw PetError("仅支持在本机项目目录执行的 Codex 计划") }
        let schedule = try AgentAutomationRecurrence.codex(value.rrule, created: value.createdAt, zone: value.timeZone)
        let workspaces = Array(Set((value.cwds ?? []).filter { $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4096 })).sorted()
        let folder = (file as NSString).deletingLastPathComponent as NSString
        return Definition(id: value.id ?? folder.lastPathComponent, title: title(value.name), prompt: value.prompt,
                          schedule: schedule, workspaces: workspaces, created: value.createdAt)
    }

    private static func definitions(_ source: AgentImportSource, file: String, data: Data) throws -> [Result<Definition, Error>] {
        if source == .codex { return [Result { try codex(data, file: file) }] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tasks = json["tasks"] as? [Any], tasks.count <= maximumRows else { throw PetError("Qoder 定时任务列表无效或过大") }
        return tasks.map { entry in Result { try qoder(entry, file: file) } }
    }

    static func discover(_ source: AgentImportSource, root: URL, workspace: String?) throws -> [AgentImportCandidate] {
        let base = try SourceRoot(root, source: source)
        var rows: [AgentImportCandidate] = []
        for file in try base.locations(source) {
            try Task.checkCancellation()
            let time = (try? base.files.entryMetadata(file).modified) ?? .distantPast
            rows += try preview(source, file: file.path, workspace: workspace, time: time) {
                let url = try base.requireFile(file.path, source: source)
                return try base.files.readData(url, maximum: maximumBytes(source))
            }
            guard rows.count <= maximumRows else { throw PetError("计划项目过多，请分别选择来源文件") }
        }
        return rows
    }

    static func preview(_ source: AgentImportSource, file: String, workspace: String?, sshHost: String? = nil,
                        time: Date = .distantPast, read: () throws -> Data) throws -> [AgentImportCandidate] {
        let values: [Result<Definition, Error>]
        do { values = try definitions(source, file: file, data: read()) }
        catch { values = [.failure(error)] }
        var rows: [AgentImportCandidate] = []
        for (index, value) in values.enumerated() {
            switch value {
            case .failure(let error):
                let key = AgentFiles.hash(Data((file + "\0invalid\0" + String(index)).utf8))
                var record = AgentImportCandidate(source: source, sourceID: "automation:" + key, file: file, rawHash: "", sourceHash: "",
                    title: (file as NSString).lastPathComponent, created: time, updated: time, sshHost: sshHost)
                record.automation = AgentAutomationImportPlan(workspaceOverride: workspace, workspace: workspace, definitionID: "")
                record.issue = error.localizedDescription
                rows.append(record)
            case .success(let definition):
                let destinations: [String?] = sshHost != nil || workspace != nil ? [workspace] :
                    (definition.workspaces.isEmpty ? [nil] : definition.workspaces.map(Optional.some))
                let hash = try definition.hash()
                let hasFuture = definition.schedule.next(after: Date()) != nil
                for destination in destinations {
                    let key = AgentFiles.hash(Data([file, definition.id, destination ?? ""].joined(separator: "\0").utf8))
                    var record = AgentImportCandidate(source: source, sourceID: "automation:" + key, file: file, rawHash: hash, sourceHash: hash,
                        title: definition.title, created: definition.created ?? time, updated: time, sshHost: sshHost)
                    if destinations.count > 1, let destination {
                        record.title = title(String(record.title.prefix(53)) + " · " + URL(fileURLWithPath: destination).lastPathComponent)
                    }
                    record.targetID = AgentImportReaders.targetID(record.id)
                    record.automation = AgentAutomationImportPlan(workspaceOverride: workspace, workspace: destination, definitionID: definition.id)
                    record.preview = definition.preview
                    if sshHost != nil {
                        record.warnings.append("启用前请核对执行时区")
                        if !definition.workspaces.isEmpty {
                            let paths = definition.workspaces.prefix(3).joined(separator: "、")
                            record.preview = "来源项目 · " + paths + (definition.workspaces.count > 3 ? " 等" : "") + "\n" + record.preview
                        }
                    }
                    if definition.prompt.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") { record.warnings.append("启用前请检查来源斜杠指令") }
                    if !hasFuture { record.warnings.append("没有未来运行时段，启用前请选择新时间") }
                    if definition.title.isEmpty || definition.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || definition.prompt.utf8.count > 40_000 {
                        record.issue = "定时任务名称或提示词无效"
                    }
                    rows.append(record)
                }
            }
            guard rows.count <= maximumRows else { throw PetError("计划项目过多，请分别选择来源文件") }
        }
        return rows
    }

    @MainActor static func plan(_ entries: [AgentImportCandidate], workspace: String?, store: AgentStore) throws -> [AgentImportCandidate] {
        try AgentMCPDataImport.requireDestination(workspace, store: store)
        let service = store.automations
        guard service.isStarted else { throw PetError(service.error ?? "自动化调度未启动") }
        let projects = Set(AgentMemory.projects(store: store, preferredTaskID: store.selectedID).map(\.workspace))
        let keys = Dictionary(grouping: entries, by: \.id)
        let titles = Dictionary(grouping: entries.filter { $0.issue == nil }, by: { $0.title.lowercased() })
        return entries.map { entry in
            var record = entry
            guard record.issue == nil else { return record }
            if let existing = service.values.first(where: { $0.id == record.targetID }) {
                record.issue = existing.workspace == record.automation?.workspace ? "已经导入" : "本机计划已更改项目，保留现有计划"
                return record
            }
            guard let workspace = record.automation?.workspace, projects.contains(workspace),
                  (try? AgentFiles(workspace: workspace, followParentLinks: false).root.path) == URL(fileURLWithPath: workspace).standardizedFileURL.path else {
                record.issue = record.sshHost == nil ? "请选择可用的目标项目" : "请选择本机目标项目"; return record
            }
            if keys[record.id, default: []].count > 1 { record.issue = "来源计划编号重复"; return record }
            if titles[record.title.lowercased(), default: []].count > 1 {
                record.title = String(record.title.prefix(72)) + " · " + record.targetID.prefix(5).lowercased()
            }
            if service.values.contains(where: { !$0.archived && $0.name.caseInsensitiveCompare(record.title) == .orderedSame }) {
                record.issue = "同名自动化已存在，保留现有计划"
            } else if service.values.count >= 64 { record.issue = "已达到64个自动化的上限" }
            return record
        }
    }

    static func reveal(_ record: AgentImportCandidate, root: URL) throws -> URL {
        guard record.sshHost == nil else { throw PetError("缺少本机定时任务来源") }
        return try SourceRoot(root, source: record.source).requireFile(record.file, source: record.source)
    }

    @MainActor static func install(_ record: AgentImportCandidate, root: URL, store: AgentStore) async throws {
        try await install(record, store: store) {
            try await Task.detached(priority: .utility) {
                let base = try SourceRoot(root, source: record.source)
                let file = try base.requireFile(record.file, source: record.source)
                return try base.files.readData(file, maximum: maximumBytes(record.source))
            }.value
        }
    }

    @MainActor static func install(_ record: AgentImportCandidate, store: AgentStore, load: () async throws -> Data) async throws {
        guard let plan = record.automation, let workspace = plan.workspace,
              record.targetID == AgentImportReaders.targetID(record.id) else { throw PetError("定时任务目标无效") }
        let service = store.automations
        if let existing = service.values.first(where: { $0.id == record.targetID }) {
            guard existing.workspace == workspace else { throw PetError("本机计划已更改项目，保留现有计划") }
            return
        }
        try AgentMCPDataImport.requireDestination(workspace, store: store)
        let data = try await load()
        let definition = try await Task.detached(priority: .utility) {
            let matches = try definitions(record.source, file: record.file, data: data).compactMap { try? $0.get() }.filter { $0.id == plan.definitionID }
            guard matches.count == 1, let definition = matches.first, try definition.hash() == record.sourceHash,
                  plan.workspaceOverride == workspace || record.sshHost == nil && plan.workspaceOverride == nil && definition.workspaces.contains(workspace) else {
                throw PetError("来源计划已变化，请重新检测")
            }
            return definition
        }.value
        try Task.checkCancellation()
        try AgentMCPDataImport.requireDestination(workspace, store: store)
        var value = AgentAutomation(name: record.title, prompt: definition.prompt, workspace: workspace)
        value.id = record.targetID; value.schedule = definition.schedule
        try service.save(value, expected: nil, keepIntervalAnchor: true)
    }
}
