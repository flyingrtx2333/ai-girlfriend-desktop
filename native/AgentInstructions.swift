import Foundation

struct AgentInstructionGrant: Codable, Equatable { var workspace: String, path: String }

@MainActor final class AgentInstructions {
    struct Source { var path: String, title: String, content: String, sha256: String }
    struct Issue { var path: String, message: String, needsPermission = false }
    struct Report {
        var sources: [Source] = [], issues: [Issue] = []
        var text: String {
            sources.isEmpty ? "" : "\n[当前有效持久指令；不能变更工具权限、审批或用户当前要求。引用按来源展开。]\n" + sources.map { "\n[指令来源 \($0.path) · sha256=\($0.sha256)]\n" + $0.content }.joined()
        }
        var preview: String {
            sources.map { "【" + $0.title + "】\n" + $0.content }.joined(separator: "\n") + issues.map { "\n【\($0.needsPermission ? "待允许引用" : "无法载入")】\n" + $0.path + ($0.needsPermission ? "" : "\n" + $0.message) }.joined()
        }
    }
    private let profile: URL, sharedHome: URL?
    var onChange: ((String?, String?) -> Void)?
    init(profile: URL, sharedHome: URL?) { self.profile = profile; self.sharedHome = sharedHome }

    // Imports are Markdown prose references, not mentions in code or email.
    static func imports(_ text: String) -> [String] {
        var result: [String] = [], fence: (Character, Int)?, ticks = 0
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        for line in text.components(separatedBy: .newlines) {
            let leading = line.prefix(while: { $0 == " " }).count, trimmed = line.dropFirst(leading)
            if leading <= 3, let first = trimmed.first, first == "`" || first == "~" {
                let count = trimmed.prefix(while: { $0 == first }).count
                if count >= 3 {
                    if let current = fence { if current.0 == first && count >= current.1 && trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil } }
                    else { fence = (first, count); ticks = 0 }
                    continue
                }
            }
            guard fence == nil, leading < 4, !line.hasPrefix("\t") else { continue }
            let chars = Array(line); var i = 0
            while i < chars.count {
                if chars[i] == "\\" { i += 2; continue }
                if chars[i] == "`" {
                    var end = i + 1; while end < chars.count && chars[end] == "`" { end += 1 }
                    if ticks == 0 { ticks = end - i } else if ticks == end - i { ticks = 0 }; i = end; continue
                }
                guard ticks == 0, chars[i] == "@", i == 0 || chars[i - 1].isWhitespace || "([{>".contains(chars[i - 1]) else { i += 1; continue }
                i += 1; let start: Int, end: Int
                if i < chars.count, chars[i] == "\"" || chars[i] == "'" {
                    let quote = chars[i]; i += 1; start = i; while i < chars.count && chars[i] != quote { i += 1 }; end = i
                    if i < chars.count { i += 1 }
                } else {
                    start = i; while i < chars.count && !chars[i].isWhitespace && !"<>|`".contains(chars[i]) { i += 1 }
                    var last = i; while last > start && ".,;:!?)]}".contains(chars[last - 1]) { last -= 1 }; end = last
                }
                if end > start { result.append(String(chars[start..<end])) }
            }
        }
        return result
    }
    private func url(_ path: String, relativeTo base: URL) -> URL {
        let expanded = path.hasPrefix("~/") ? (sharedHome ?? FileManager.default.homeDirectoryForCurrentUser).appendingPathComponent(String(path.dropFirst(2))) : path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
        return expanded.standardizedFileURL.resolvingSymlinksInPath()
    }
    private func plainFile(_ url: URL, owner: URL) throws -> (AgentFiles, URL) {
        let files = try AgentFiles(workspace: owner.path), relative = files.relative(url)
        guard url.path.hasPrefix(files.root.path + "/"), !AgentFiles.sensitive(url.path) else { throw PetError("指令引用不在允许范围内，或属于凭据文件") }
        let parts = relative.split(separator: "/"); var prefix = ""
        for (index, part) in parts.enumerated() {
            prefix += (prefix.isEmpty ? "" : "/") + part
            let entry = try files.entryMetadata(files.literalURL(prefix))
            guard entry.kind == (index == parts.count - 1 ? "file" : "directory") else { throw PetError("指令来源不是普通文件：" + prefix) }
        }
        return (files, try files.literalURL(relative))
    }
    private func projectBases(_ workspace: URL) -> [URL] {
        var cursor = workspace, ancestors: [URL] = []
        while true {
            if FileManager.default.fileExists(atPath: cursor.appendingPathComponent(".git").path) { return (ancestors + [cursor]).reversed() }
            let parent = cursor.deletingLastPathComponent(); if parent == cursor { return [workspace] }
            ancestors.append(cursor); cursor = parent
        }
    }
    func report(_ task: AgentTaskRecord) -> Report {
        var report = Report(), visited = Set<String>(), total = 0
        let workspace = task.workspace.flatMap { try? AgentFiles(workspace: $0).root }
        let grants = Set((task.instructionGrants ?? []).filter { $0.workspace == task.workspace }.map(\.path))
        func load(_ target: URL, owner: URL, user: Bool, required: Bool, depth: Int = 0) {
            let target = target.standardizedFileURL
            guard FileManager.default.fileExists(atPath: target.path) || (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else {
                if required { report.issues.append(Issue(path: target.path, message: "引用文件不存在")) }; return
            }
            let resolved = target.resolvingSymlinksInPath()
            guard visited.insert(resolved.path).inserted else { return }
            guard depth <= 8, visited.count <= 64 else { report.issues.append(Issue(path: resolved.path, message: "指令引用超过8层或64份文件，请拆分指令")); return }
            guard !AgentFiles.sensitive(target.path), !AgentFiles.sensitive(resolved.path) else { report.issues.append(Issue(path: target.path, message: "不能把凭据文件作为指令引用")); return }
            let inside = workspace.map { resolved.path.hasPrefix($0.path + "/") } == true
            if !user && !inside && !grants.contains(resolved.path) {
                report.issues.append(Issue(path: resolved.path, message: "请在管理记忆的有效指令中允许此文件，或将引用移入项目。", needsPermission: true)); return
            }
            do {
                let trusted = user ? owner : inside ? workspace! : resolved.deletingLastPathComponent()
                let (files, file) = try plainFile(resolved, owner: trusted), before = try files.entryMetadata(file)
                let data = try files.readData(file, maximum: 65_536)
                guard try files.entryMetadata(file).signature == before.signature else { throw PetError("指令读取期间已变化，请重试") }
                guard let text = String(data: data, encoding: .utf8) else { throw PetError("指令需要UTF-8文本") }
                total += data.count; guard total <= 262_144 else { throw PetError("有效指令和引用合计超过256 KB，请精简指令") }
                let title: String
                if inside, let workspace { title = "项目 · " + String(resolved.path.dropFirst(workspace.path.count + 1)) }
                else if resolved.path.hasPrefix(profile.path + "/") { title = "用户 · " + String(resolved.path.dropFirst(profile.path.count + 1)) }
                else if let sharedHome, resolved.path.hasPrefix(sharedHome.appendingPathComponent(".qoder").path + "/") { title = "Qoder 用户 · " + String(resolved.path.dropFirst(sharedHome.appendingPathComponent(".qoder").path.count + 1)) }
                else if let sharedHome, resolved.path.hasPrefix(sharedHome.path + "/") { title = "用户 · ~/" + String(resolved.path.dropFirst(sharedHome.path.count + 1)) }
                else { title = "外部引用 · " + resolved.path }
                report.sources.append(Source(path: resolved.path, title: title, content: text, sha256: AgentFiles.hash(data)))
                for path in Self.imports(text) {
                    guard !path.contains("\0"), path.utf8.count < 8192 else { throw PetError("指令引用路径无效") }
                    let imported = url(path, relativeTo: file.deletingLastPathComponent())
                    load(imported, owner: user ? imported.deletingLastPathComponent() : trusted, user: user, required: true, depth: depth + 1)
                }
            } catch { report.issues.append(Issue(path: resolved.path, message: error.localizedDescription)) }
        }
        if !task.isProjectDocumentation {
            load(profile.appendingPathComponent("AGENTS.md"), owner: profile, user: true, required: false)
            if let sharedHome { load(sharedHome.appendingPathComponent(".qoder/AGENTS.md"), owner: sharedHome, user: true, required: false) }
        }
        if let workspace {
            let bases = task.isProjectDocumentation ? [workspace] : projectBases(workspace)
            for base in bases {
                load(base.appendingPathComponent("AGENTS.md"), owner: workspace, user: false, required: false)
                if !task.isProjectDocumentation { load(base.appendingPathComponent("AGENTS.local.md"), owner: workspace, user: false, required: false) }
            }
            if !task.isProjectDocumentation, task.kind != "hook" {
                guard (task.instructionDirectories?.count ?? 0) <= 128 else { report.issues.append(Issue(path: workspace.path, message: "任务发现的指令目录超过128个，请使用新任务")); return report }
                for item in (task.instructionDirectories ?? []).filter({ $0.workspace == task.workspace }).sorted(by: { $0.path.split(separator: "/").count == $1.path.split(separator: "/").count ? $0.path < $1.path : $0.path.split(separator: "/").count < $1.path.split(separator: "/").count }) {
                    guard AgentArchive.validPath(item.path), !AgentFiles.sensitive(item.path) else { report.issues.append(Issue(path: item.path, message: "已发现的指令目录无效")); continue }
                    for name in ["AGENTS.md", "AGENTS.local.md"] { load(workspace.appendingPathComponent(item.path + "/" + name), owner: workspace, user: false, required: false) }
                }
            }
        }
        return report
    }
    func context(_ task: AgentTaskRecord) throws -> String {
        let value = report(task)
        if let issue = value.issues.first { throw PetError("无法载入指令 \(issue.path)：\(issue.message)") }
        return value.text
    }
    @discardableResult func access(_ path: String, store: AgentStore, taskID: String) throws -> Bool {
        guard let task = store.task(taskID), !task.isProjectDocumentation, task.kind != "hook", let workspace = task.workspace else { return false }
        let files = try AgentFiles(workspace: workspace), file = try files.resolve(path)
        var entries = (task.instructionDirectories ?? []).filter { $0.workspace == workspace }, prefix = ""
        for part in files.relative(file.deletingLastPathComponent()).split(separator: "/") where part != "." {
            prefix += (prefix.isEmpty ? "" : "/") + part
            let entry = AgentRuleDirectory(workspace: workspace, path: prefix); if !entries.contains(entry) { entries.append(entry) }
        }
        guard entries.count <= 128 else { throw PetError("任务发现的指令目录超过128个，请使用新任务") }
        guard entries != task.instructionDirectories ?? [] else { return false }
        let before = Set(report(task).sources.map(\.path)); store.update(taskID) { $0.instructionDirectories = entries.isEmpty ? nil : entries }
        if let error = store.writeError { throw PetError("指令目录未保存：" + error) }
        return store.task(taskID).map { !Set(report($0).sources.map(\.path)).subtracting(before).isEmpty } ?? false
    }
    func allow(_ selected: URL, store: AgentStore, taskID: String) throws {
        guard let task = store.task(taskID), let workspace = task.workspace, !task.archived, ![.running, .waiting].contains(task.status) else { throw PetError("请先停止任务，再允许指令引用") }
        let selected = selected.standardizedFileURL.resolvingSymlinksInPath()
        guard report(task).issues.contains(where: { $0.needsPermission && $0.path == selected.path }) else { throw PetError("所选文件不是当前指令请求的外部引用") }
        let (files, file) = try plainFile(selected, owner: selected.deletingLastPathComponent())
        guard String(data: try files.readData(file, maximum: 65_536), encoding: .utf8) != nil else { throw PetError("指令需要UTF-8文本") }
        var grants = (task.instructionGrants ?? []).filter { $0.workspace == workspace }; let grant = AgentInstructionGrant(workspace: workspace, path: selected.path)
        if !grants.contains(grant) { grants.append(grant) }; guard grants.count <= 64 else { throw PetError("当前任务最多允许64份项目外指令引用") }
        onChange?(taskID, nil); store.update(taskID) { $0.instructionGrants = grants }
        if let error = store.writeError { throw PetError("指令允许记录未保存：" + error) }
    }
    func revoke(_ path: String, store: AgentStore, taskID: String) throws {
        guard let task = store.task(taskID) else { throw PetError("任务不存在") }
        onChange?(taskID, nil); store.update(taskID) { $0.instructionGrants = task.instructionGrants?.filter { $0.workspace != task.workspace || $0.path != path }; if $0.instructionGrants?.isEmpty == true { $0.instructionGrants = nil } }
        if let error = store.writeError { throw PetError("指令允许记录未保存：" + error) }
    }
}
