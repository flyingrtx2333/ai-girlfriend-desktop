import Foundation

enum AgentMemoryScope: String, CaseIterable {
    case global, project, instructions, summary, userInstructions, localInstructions, effectiveInstructions
    var title: String { switch self { case .global: return "全局记忆"; case .project: return "项目记忆"; case .instructions: return "项目指令"; case .summary: return "任务摘要"; case .userInstructions: return "用户指令"; case .localInstructions: return "本机项目指令"; case .effectiveInstructions: return "有效指令" } }
    var isInstructions: Bool { [.instructions, .userInstructions, .localInstructions].contains(self) }
}
struct AgentMemorySnapshot { var content: String; var hash: String; var location: String }

@MainActor enum AgentMemory {
    private static func file(_ scope: AgentMemoryScope, store: AgentStore, taskID: String) throws -> (AgentFiles, URL, Int) {
        let files: AgentFiles, path: String
        if scope == .global { files = try AgentFiles(workspace: store.directory.path); path = "memory.md" }
        else if scope == .userInstructions { files = try AgentFiles(workspace: store.directory.deletingLastPathComponent().path); path = "AGENTS.md" }
        else {
            guard let task = store.task(taskID) else { throw PetError("任务不存在") }
            files = try AgentFiles(workspace: task.workspace); path = scope == .instructions ? "AGENTS.md" : scope == .localInstructions ? "AGENTS.local.md" : ".bluefatfish/memory.md"
        }
        return (files, try files.resolve(path), scope.isInstructions ? 65_536 : 24_000)
    }
    static func snapshot(_ scope: AgentMemoryScope, store: AgentStore, taskID: String) throws -> AgentMemorySnapshot {
        if scope == .effectiveInstructions {
            guard let task = store.task(taskID) else { throw PetError("任务不存在") }
            let report = store.instructions.report(task), text = report.preview
            return AgentMemorySnapshot(content: text, hash: AgentFiles.hash(Data(text.utf8)), location: "\(report.sources.count)份来源" + (report.issues.isEmpty ? "" : " · \(report.issues.count)项待处理"))
        }
        if scope == .summary {
            guard let task = store.task(taskID) else { throw PetError("任务不存在") }
            let text = task.contextSummary ?? ""
            return AgentMemorySnapshot(content: text, hash: AgentFiles.hash(Data(text.utf8)), location: "当前任务摘要")
        }
        let (files, url, maximum) = try file(scope, store: store, taskID: taskID)
        let data = FileManager.default.fileExists(atPath: url.path) ? try files.readData(url, maximum: maximum) : Data()
        guard let text = String(data: data, encoding: .utf8) else { throw PetError("记忆文件不是 UTF-8 文本") }
        return AgentMemorySnapshot(content: text, hash: AgentFiles.hash(data), location: scope == .global ? "全局 memory.md" : files.relative(url))
    }
    static func save(_ scope: AgentMemoryScope, content: String, expectedHash: String, store: AgentStore, taskID: String) throws -> AgentMemorySnapshot {
        guard scope != .effectiveInstructions else { throw PetError("请编辑原指令文件，有效指令只读") }
        guard let task = store.task(taskID) else { throw PetError("任务不存在") }
        let previous = try snapshot(scope, store: store, taskID: taskID)
        guard previous.hash == expectedHash else { throw PetError("记忆已更改，请重新打开后编辑") }
        let data = Data(content.utf8)
        if scope == .summary {
            guard task.status != .running, data.count <= 24_000 else { throw PetError("请先停止任务，摘要最多 24 KB") }
            store.update(taskID) { $0.contextSummary = content.isEmpty ? nil : content; if content.isEmpty { $0.contextThroughID = nil } }
            if let error = store.writeError { throw PetError(error) }
        } else {
            let (files, url, maximum) = try file(scope, store: store, taskID: taskID)
            guard data.count <= maximum else { throw PetError(scope.isInstructions ? "指令最多 64 KB" : "记忆最多 24 KB") }
            if !previous.content.isEmpty {
                let directory = store.directory.appendingPathComponent("memory-backups", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let backup = directory.appendingPathComponent(UUID().uuidString + ".md")
                try Data(previous.content.utf8).write(to: backup, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
            let metadata = try files.entryMetadata(url)
            if metadata.kind == "missing", expectedHash != AgentFiles.hash(Data()) { throw PetError("记忆文件已被移除，请重新打开后编辑") }
            if metadata.kind != "missing", try files.fileHash(url, maximum: maximum) != expectedHash { throw PetError("记忆已更改，请重新打开后编辑") }
            let permissions = metadata.permissions ?? ([.global, .userInstructions].contains(scope) ? 0o600 : 0o644)
            if scope.isInstructions { store.instructions.onChange?(nil, scope == .userInstructions ? nil : task.workspace) }
            try files.writeData(data, to: url, permissions: permissions, expectedTarget: metadata.signature)
        }
        return try snapshot(scope, store: store, taskID: taskID)
    }
}
