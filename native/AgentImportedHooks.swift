import Foundation

struct AgentImportedHookReceipt: Codable {
    let originalName: String
    let sourceHash: String
}

@MainActor extension AgentHooks {
    private func importedFolder(workspace: String?) throws -> (AgentFiles, URL) {
        let files = try AgentFiles(workspace: profile.path, followParentLinks: false)
        let scope = workspace.map { AgentFiles.hash(Data($0.utf8)) } ?? "user"
        return (files, try files.literalURL("extensions/imported-hooks/" + scope))
    }
    func importedConfiguration(_ id: String, workspace: String?) throws -> (AgentFiles, URL) {
        guard UUID(uuidString: id)?.uuidString == id else { throw PetError("导入 Hooks 编号无效") }
        let (files, folder) = try importedFolder(workspace: workspace)
        return (files, try files.literalURL(folder.appendingPathComponent(id + "/hooks.json").path))
    }
    func importedReceipt(_ id: String, workspace: String?) throws -> AgentImportedHookReceipt? {
        let (files, target) = try importedConfiguration(id, workspace: workspace)
        let receipt = try files.literalURL(target.deletingLastPathComponent().appendingPathComponent("receipt.json").path)
        if try files.entryMetadata(receipt).kind == "missing" { return nil }
        let value = try JSONDecoder().decode(AgentImportedHookReceipt.self, from: files.readData(receipt, maximum: 4096))
        guard ["settings.json", "settings.local.json", "hooks.json"].contains(value.originalName),
              value.sourceHash.count == 64, value.sourceHash.allSatisfy(\.isHexDigit) else { throw PetError("Hooks 导入记录无效") }
        return value
    }
    func importedConfigurations(workspace: String?) throws -> [URL] {
        let (files, folder) = try importedFolder(workspace: workspace)
        let metadata = try files.entryMetadata(folder)
        if metadata.kind == "missing" { return [] }
        guard metadata.kind == "directory" else { throw PetError("导入 Hooks 目录不是普通文件夹") }
        let children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        guard children.count <= 128 else { throw PetError("同一范围最多 128 份独立 Hooks 配置") }
        let entries: [(URL, String)] = try children.compactMap { child in
            let id = child.lastPathComponent
            guard UUID(uuidString: id)?.uuidString == id else { return nil }
            let (_, file) = try importedConfiguration(id, workspace: workspace)
            guard try files.entryMetadata(file).kind == "file", let receipt = try importedReceipt(id, workspace: workspace) else { return nil }
            return (file, receipt.originalName)
        }
        return entries.sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 < $1.1 }.map(\.0)
    }
    private func importedStorage(path: String, workspace: String?) throws -> (AgentFiles, URL) {
        let url = URL(fileURLWithPath: path)
        let (files, file) = try importedConfiguration(url.deletingLastPathComponent().lastPathComponent, workspace: workspace)
        guard file.path == path, try files.entryMetadata(file).kind == "file" else { throw PetError("原导入 Hooks 配置不在当前范围") }
        return (files, file)
    }
    func importedDocument(path: String, workspace: String?) throws -> (String, String) {
        let (files, file) = try importedStorage(path: path, workspace: workspace)
        let data = try files.readData(file, maximum: 128_000)
        return (String(decoding: try credentials.mask(data), as: UTF8.self), AgentFiles.hash(data))
    }
    func saveImportedDocument(_ text: String, path: String, workspace: String?, expectedHash: String?) throws {
        let (files, file) = try importedStorage(path: path, workspace: workspace), data = Data(text.utf8)
        guard data.count <= 128_000 else { throw PetError("Hooks 配置不超过 128KB") }
        _ = try parse(data, file: file, scope: workspace == nil ? "导入 · 全局" : "导入 · 项目", workspace: workspace)
        try commitConfiguration(data, target: file, files: files, expectedHash: expectedHash)
    }
}

struct AgentStandaloneHookPackage {
    var files: [String: Data]
    var executable: Set<String>
    var events: [String]
    var warnings: [String]
    var fingerprint: String {
        AgentFiles.hash(Data((AgentExtensions.digest(files) + "\n" + executable.sorted().joined(separator: "\n")).utf8))
    }

    @MainActor static func prepare(_ data: Data, source: AgentImportSource, file: URL, files: AgentFiles,
                                  target: URL, workspace: String?, service: AgentHooks) throws -> Self? {
        let object = try AgentConfigurationJSON.object(data)
        guard let raw = object["hooks"] else { return nil }
        guard let events = raw as? [String: Any] else { throw PetError("需要 Hooks 事件对象") }
        guard !events.isEmpty else { return nil }
        var normalized: [String: [[String: Any]]] = [:], skipped: [String] = [], labels: [String] = []
        var count = 0
        let handlerFields: Set<String> = ["name", "type", "command", "timeout", "shell", "args", "env", "network", "if", "allowedEnvVars",
            "url", "headers", "prompt", "model", "tools", "maxTurns", "async", "asyncRewake", "rewakeMessage", "rewakeSummary", "statusMessage", "once"]
        for key in events.keys.sorted() {
            guard AgentHookEvent(rawValue: key) != nil else { skipped.append(key); continue }
            guard let groups = events[key] as? [[String: Any]], groups.count <= 64 else { throw PetError("Hooks 的事件分组无效：" + key) }
            for group in groups {
                guard Set(group.keys).isSubset(of: ["matcher", "hooks", "timeout", "async"]),
                      let handlers = group["hooks"] as? [[String: Any]], handlers.count <= 32 else {
                    skipped.append(key + " 分组格式"); continue
                }
                var kept: [[String: Any]] = []
                for var handler in handlers {
                    count += 1
                    guard count <= 128 else { throw PetError("单份来源超过 128 个 Hooks") }
                    let type = handler["type"] as? String ?? "command"
                    if source == .codex {
                        guard type == "command" else { skipped.append(key + " · " + type); continue }
                        handler.removeValue(forKey: "commandWindows"); handler.removeValue(forKey: "command_windows")
                        if handler["timeout"] == nil && group["timeout"] == nil { handler["timeout"] = key == "SessionEnd" ? 1 : 600 }
                    }
                    guard Set(handler.keys).isSubset(of: handlerFields), handler["once"] as? Bool != true,
                          ["command", "http", "prompt", "agent"].contains(type) else { skipped.append(key + " · 处理器格式"); continue }
                    if let command = handler["command"] as? String,
                       command.range(of: #"(?i)(?:\b[a-z_]*(?:token|password|secret|api[_-]?key)\s*=|--(?:token|password|secret|api-key)(?:=|\s)|\bAuthorization\s*:|https?://[^\s'"]*\?)"#,
                                     options: .regularExpression) != nil {
                        skipped.append(key + " · 命令含内嵌凭据字段"); continue
                    }
                    handler["name"] = handler["name"] ?? key + " · " + type + " " + String(count)
                    var candidate = group
                    candidate["hooks"] = [handler]
                    if source == .codex, let matcher = group["matcher"] as? String {
                        if matcher == "apply_patch" || matcher == "^apply_patch$" { candidate["matcher"] = "Write|Edit" }
                    }
                    do {
                        let clean = try AgentImportedPlugin.cleanHooks(["hooks": [key: [candidate]]])
                        let encoded = try JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys, .withoutEscapingSlashes])
                        let parsed = try service.parse(encoded, file: target, scope: "导入", workspace: workspace, inspectResources: false, inspectCredentials: false)
                        guard let check = parsed.first, check.diagnostic == nil,
                              let cleaned = (clean["hooks"] as? [String: [[String: Any]]])?[key]?.first?["hooks"] as? [[String: Any]] else {
                            throw PetError("处理器配置无法载入")
                        }
                        kept += cleaned
                        labels.append(check.name + "\n" + key + " · " + type + (check.matcher.isEmpty ? "" : " · " + check.matcher))
                    } catch { skipped.append(key + " · 处理器需要调整") }
                }
                if !kept.isEmpty {
                    var output = group
                    if source == .codex, let matcher = group["matcher"] as? String, matcher == "apply_patch" || matcher == "^apply_patch$" {
                        output["matcher"] = "Write|Edit"
                    }
                    output["hooks"] = kept
                    normalized[key, default: []].append(output)
                }
            }
        }
        guard !normalized.isEmpty else {
            throw PetError("没有兼容的处理器" + (skipped.isEmpty ? "" : " · " + Array(Set(skipped)).sorted().prefix(4).joined(separator: "、")))
        }
        let config = try JSONSerialization.data(withJSONObject: ["hooks": normalized], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard config.count <= 128_000 else { throw PetError("Hooks 配置超过 128KB") }
        var payload = try resources(file.deletingLastPathComponent().appendingPathComponent("hooks"), files: files)
        payload.contents["hooks.json"] = config
        var warnings = ["导入后为停用状态"]
        if !skipped.isEmpty { warnings.append("跳过 " + String(skipped.count) + " 项 · " + Array(Set(skipped)).sorted().prefix(5).joined(separator: "、")) }
        if String(decoding: config, as: UTF8.self).contains(AgentHookCredentials.placeholder) { warnings.append("使用前请补填本机凭据") }
        if payload.contents.count > 1 { warnings.append("包含 " + String(payload.contents.count - 1) + " 份脚本与资源") }
        return Self(files: payload.contents, executable: payload.executable, events: labels, warnings: warnings)
    }

    private static func resources(_ root: URL, files: AgentFiles) throws -> (contents: [String: Data], executable: Set<String>) {
        let metadata = try files.entryMetadata(root)
        if metadata.kind == "missing" { return ([:], []) }
        guard metadata.kind == "directory" else { throw PetError("Hooks 资源需要普通目录") }
        let all = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        guard all.count <= 500 else { throw PetError("Hooks 资源目录超过 500 项") }
        var result: [String: Data] = [:], executable = Set<String>(), bytes = 0
        for name in all.sorted() {
            try Task.checkCancellation()
            guard AgentArchive.validPath(name), !AgentFiles.sensitive(name) else { throw PetError("Hooks 资源路径无效或包含受保护文件") }
            let url = try files.literalURL(root.appendingPathComponent(name).path), before = try files.entryMetadata(url)
            if before.kind == "directory" { continue }
            guard before.kind == "file" else { throw PetError("Hooks 资源包含链接或特殊文件") }
            let data = try files.readData(url, maximum: 1_000_000)
            guard try files.entryMetadata(url).signature == before.signature else { throw PetError("Hooks 资源正在变化，请重新检测") }
            bytes += data.count
            guard bytes <= 5_000_000 else { throw PetError("Hooks 资源超过 5MB") }
            let relative = "hooks/" + name
            result[relative] = data
            if (before.permissions ?? 0) & 0o111 != 0 { executable.insert(relative) }
        }
        return (result, executable)
    }
}
