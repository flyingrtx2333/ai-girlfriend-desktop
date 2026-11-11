import Foundation

struct AgentSecurityFinding: Encodable {
    let path: String
    let line: Int
    let rule: String
    let title: String
    let advice: String
    let highRisk: Bool
    fileprivate var falseOffset: Int? = nil

    // Reports contain locations and rule metadata only.
    private enum CodingKeys: String, CodingKey { case path, line, rule, title, advice, highRisk }
}

struct AgentSecurityReport: Encodable {
    struct Skipped: Encodable { let path: String; let reason: String }
    let source: AgentGitSource
    let findings: [AgentSecurityFinding]
    let scannedFiles: Int
    let skipped: [Skipped]
    fileprivate let hashes: [String: String]

    private enum CodingKeys: String, CodingKey { case source, findings, scannedFiles, skipped }

    var sourceTitle: String { source == .staged ? "暂存区" : "工作区" }
    var summary: String {
        let result = scannedFiles == 0 ? "没有可检查的文本文件" : findings.isEmpty ? "未发现匹配项" : "\(findings.count) 项发现"
        return "\(sourceTitle) · \(scannedFiles) 个文件 · " + result + (skipped.isEmpty ? "" : " · 跳过 \(skipped.count) 个")
    }
    func canFix(_ finding: AgentSecurityFinding) -> Bool { source != .staged && finding.falseOffset != nil }
}

enum AgentCodeSecurity {
    static let sources: [AgentGitSource] = [.uncommitted, .unstaged, .staged]
    static let fileLimit = 1_000_000
    static let totalLimit = 10_000_000

    private struct Secret: Decodable {
        let File: String
        let StartLine: Int
        let RuleID: String
    }
    private struct Pattern: Decodable {
        struct MatchRange: Decodable {
            struct Position: Decodable { let line: Int }
            struct Offset: Decodable { let start: Int; let end: Int }
            let start: Position
            let byteOffset: Offset
        }
        let file: String
        let ruleId: String
        let range: MatchRange
    }

    private static func run(_ name: String, _ arguments: [String], snapshot: URL, scratch: URL, rules: URL, accepted: [Int]) async throws -> Data {
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: name),
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw PetError("缺少本机扫描器，请重新构建应用") }
        let result = try await AgentCommand().run(
            command: executable.path, workspace: snapshot, scratch: scratch, network: false, timeout: 30,
            readOnly: true, maximumOutput: 2_000_000, readRoots: [executable, rules],
            environment: ["HOME": scratch.path], arguments: arguments
        )
        try Task.checkCancellation()
        if result.truncated == true { throw PetError("安全检查结果过多，请缩小文件范围") }
        guard accepted.contains(result.exitCode ?? -1), result.timedOut != true, let data = result.stdoutData else {
            throw PetError("本机扫描器 \(name) 未完成，请缩小文件范围后重试")
        }
        return data
    }

    static func findings(snapshot: URL, scratch: URL, paths: [String: String]) async throws -> [AgentSecurityFinding] {
        guard !paths.isEmpty else { return [] }
        guard let rules = Bundle.main.resourceURL?.appendingPathComponent("security"), FileManager.default.fileExists(atPath: rules.path) else {
            throw PetError("缺少本机安全检查规则，请重新构建应用")
        }
        let gitleaks = [
            "dir", "--config", rules.appendingPathComponent("gitleaks.toml").path,
            "--gitleaks-ignore-path", scratch.path, "--ignore-gitleaks-allow", "--no-banner",
            "--redact=100", "--report-format", "json", "--report-path", "-", "--exit-code", "7", "."
        ]
        let ast = [
            "scan", "--config", rules.appendingPathComponent("sgconfig.yml").path,
            "--json=compact", "--threads", "2", "--no-ignore", "hidden", "--no-ignore", "dot",
            "--no-ignore", "parent", "--no-ignore", "vcs", "--no-ignore", "global", "--no-ignore", "exclude", "."
        ]
        async let secretData = run("gitleaks", gitleaks, snapshot: snapshot, scratch: scratch, rules: rules, accepted: [0, 7])
        async let patternData = run("ast-grep", ast, snapshot: snapshot, scratch: scratch, rules: rules, accepted: [0, 1])
        let (secrets, patterns): ([Secret], [Pattern])
        do {
            let (secretJSON, patternJSON) = try await (secretData, patternData)
            secrets = try JSONDecoder().decode([Secret]?.self, from: secretJSON) ?? []
            patterns = try JSONDecoder().decode([Pattern].self, from: patternJSON)
        } catch is DecodingError {
            throw PetError("本机扫描器返回了无法读取的结果")
        }
        func path(_ name: String) throws -> String {
            let relative = name.hasPrefix("./") ? String(name.dropFirst(2)) : name
            guard let path = paths[relative] else { throw PetError("扫描结果引用了未知文件") }
            return path
        }
        var findings = try secrets.map { secret in
            AgentSecurityFinding(path: try path(secret.File), line: secret.StartLine, rule: secret.RuleID,
                title: "疑似凭据", advice: "确认凭据是否有效。有效时先撤销并轮换，再将凭据移出源码。", highRisk: true)
        }
        for pattern in patterns {
            let title: String, advice: String, high: Bool, fix: Int?
            switch pattern.ruleId {
            case "js-tls-verification", "ts-tls-verification", "tsx-tls-verification":
                title = "TLS 证书校验被关闭"; advice = "启用证书校验。如需使用私有 CA，请配置受信任证书。"
                high = true; fix = pattern.range.byteOffset.end - 5
            case "python-tls-verification":
                title = "TLS 证书校验被关闭"; advice = "移除 verify=False，或将 verify 指向受信任的 CA 文件。"
                high = true; fix = nil
            case "js-eval", "ts-eval", "tsx-eval":
                title = "执行动态代码"; advice = "检查参数来源。用解析器或明确的允许列表处理外部输入。"
                high = false; fix = nil
            case "python-shell":
                title = "命令通过 Shell 执行"; advice = "改用参数数组并保持 shell=False，检查外部参数。"
                high = false; fix = nil
            default: throw PetError("本机扫描器返回了未知规则")
            }
            findings.append(AgentSecurityFinding(path: try path(pattern.file), line: pattern.range.start.line + 1,
                rule: pattern.ruleId, title: title, advice: advice, highRisk: high, falseOffset: fix))
        }
        return findings.sorted { ($0.path, $0.line, !$0.highRisk ? 1 : 0, $0.rule) < ($1.path, $1.line, !$1.highRisk ? 1 : 0, $1.rule) }
    }
}

@MainActor extension AgentGit {
    func checkCodeSecurity(source: AgentGitSource, requested: [String]) async throws -> AgentSecurityReport {
        try validateWorkspace()
        guard AgentCodeSecurity.sources.contains(source) else { throw PetError("请选择工作区或暂存区") }
        let selected = try paths(requested, allowRecordedTypes: true)
        let changed = try await inspectionChanges(source: source, revision: "")
        guard Set(selected).isSubset(of: Set(changed.map(\.path))) else { throw PetError("文件列表已变化，请刷新 Git 后再检查") }

        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("bluefatfish-security-" + UUID().uuidString, isDirectory: true)
        let snapshot = temporary.appendingPathComponent("files", isDirectory: true)
        let scratch = temporary.appendingPathComponent("scratch", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        for directory in [snapshot, scratch] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        // Read all stage-zero object IDs in one index read. cat-file reads the
        // immutable blob even if the editor or a different Git client changes it.
        let staged = source == .staged ? try await securityIndexEntries(selected) : [:]

        let copies = try AgentFiles(workspace: snapshot.path)
        var aliases: [String: String] = [:], hashes: [String: String] = [:], skipped: [AgentSecurityReport.Skipped] = []
        var total = 0
        for (index, path) in selected.enumerated() {
            try Task.checkCancellation()
            let url = files.root.appendingPathComponent(path)
            let data: Data
            do {
                if source == .staged {
                    guard let oid = staged[path] else { throw PetError("暂存区没有普通文件") }
                    data = try await securityBlob(oid)
                } else {
                    guard try files.literalURL(path).path == url.path, try files.entryMetadata(url).kind == "file" else {
                        throw PetError("工作区没有普通文件")
                    }
                    let read = try files.readPrefix(url, maximum: AgentCodeSecurity.fileLimit)
                    guard !read.partial else { throw PetError("超过单文件 1 MB 上限") }
                    data = read.data
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as PetError {
                skipped.append(.init(path: path, reason: error.localizedDescription)); continue
            } catch {
                skipped.append(.init(path: path, reason: "无法读取文件")); continue
            }
            guard !data.contains(0), String(data: data, encoding: .utf8) != nil else {
                skipped.append(.init(path: path, reason: "二进制或非 UTF-8 文件")); continue
            }
            guard total + data.count <= AgentCodeSecurity.totalLimit else {
                skipped.append(.init(path: path, reason: "超过本次 10 MB 上限")); continue
            }
            let alias = "\(index)/" + url.lastPathComponent
            try copies.writeData(data, to: copies.root.appendingPathComponent(alias), permissions: 0o600)
            aliases[alias] = path; hashes[path] = AgentFiles.hash(data); total += data.count
        }
        let findings = try await AgentCodeSecurity.findings(snapshot: snapshot, scratch: scratch, paths: aliases)
        try validateWorkspace()
        return AgentSecurityReport(source: source, findings: findings, scannedFiles: aliases.count, skipped: skipped, hashes: hashes)
    }

    func securityIndexEntries(_ pathspecs: [String], literalPaths: Bool = true) async throws -> [String: String] {
        let result = try await run(["ls-files", "--stage", "-z", "--"] + pathspecs, maximumOutput: 1_000_000, literalPaths: literalPaths)
        guard !result.failed, result.truncated != true else { throw PetError("无法完整读取暂存区文件列表") }
        var entries: [String: String] = [:]
        for entry in (result.stdout ?? "").split(separator: "\0") {
            let parts = entry.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { throw PetError("无法读取暂存区条目") }
            let fields = parts[0].split(separator: " ")
            guard fields.count == 3 else { throw PetError("无法读取暂存区对象") }
            if ["100644", "100755"].contains(fields[0]), fields[2] == "0",
               fields[1].range(of: "^([0-9a-f]{40}|[0-9a-f]{64})$", options: .regularExpression) != nil {
                entries[String(parts[1])] = String(fields[1])
            }
        }
        return entries
    }

    func securityBlob(_ oid: String, maximum: Int = AgentCodeSecurity.fileLimit) async throws -> Data {
        let environment = ["GIT_NO_REPLACE_OBJECTS": "1"]
        let size = try await run(["cat-file", "-s", oid], environment: environment)
        guard !size.failed, let bytes = Int((size.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw PetError("无法读取暂存对象")
        }
        guard bytes <= maximum else { throw PetError("超过单文件 \(maximum / 1_000_000) MB 上限") }
        let data: Data
        if bytes < 1_900_000 {
            let blob = try await run(["cat-file", "blob", oid], maximumOutput: bytes + 1024, environment: environment)
            guard !blob.failed, blob.truncated != true, let content = blob.stdoutData else { throw PetError("无法完整读取暂存对象") }
            data = content
        } else {
            let output = scratch.appendingPathComponent("blob-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: output) }
            let result = try await run(["cat-file", "blob", oid], environment: environment, stdoutFile: output)
            guard !result.failed else { throw PetError("无法完整读取暂存对象") }
            let files = try AgentFiles(workspace: scratch.path)
            data = try files.readData(files.literalURL(output.path), maximum: maximum)
        }
        guard data.count == bytes else { throw PetError("暂存对象长度与 Git 记录不一致") }
        return data
    }

    func validateSecurityLocation(_ finding: AgentSecurityFinding, report: AgentSecurityReport) async throws {
        try validateWorkspace()
        let data: Data
        if report.source == .staged {
            let id = try await run(["rev-parse", "--verify", "--end-of-options", ":" + finding.path])
            let oid = (id.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.failed, oid.range(of: "^([0-9a-f]{40}|[0-9a-f]{64})$", options: .regularExpression) != nil else {
                throw PetError("暂存文件已变化，请重新检查")
            }
            data = try await securityBlob(oid)
        } else {
            let url = try files.literalURL(finding.path)
            guard url.path == files.root.appendingPathComponent(finding.path).path else { throw PetError("工作区文件已变化，请重新检查") }
            let read = try files.readPrefix(url, maximum: AgentCodeSecurity.fileLimit)
            guard !read.partial else { throw PetError("工作区文件已变化，请重新检查") }
            data = read.data
        }
        guard AgentFiles.hash(data) == report.hashes[finding.path] else { throw PetError("文件已变化，请重新检查") }
    }

    func applySecurityFix(_ finding: AgentSecurityFinding, report: AgentSecurityReport) throws -> String {
        try validateWorkspace()
        guard report.canFix(finding), let offset = finding.falseOffset, let hash = report.hashes[finding.path],
              let task = store.task(taskID), ![.running, .waiting].contains(task.status),
              task.pendingFileCapture == nil, task.pendingFileRollback == nil else { throw PetError("当前无法修复工作区文件") }
        let url = try files.literalURL(finding.path), metadata = try files.entryMetadata(url)
        guard url.path == files.root.appendingPathComponent(finding.path).path, let permissions = metadata.permissions else {
            throw PetError("文件已变化，请重新检查")
        }
        let before = try files.readPrefix(url, maximum: AgentCodeSecurity.fileLimit)
        guard !before.partial, AgentFiles.hash(before.data) == hash, offset >= 0, offset + 5 <= before.data.count,
              before.data[offset..<offset + 5].elementsEqual("false".utf8) else { throw PetError("文件已变化，请重新检查") }
        var after = before.data
        after.replaceSubrange(offset..<offset + 5, with: "true".utf8)
        var checkpoint = AgentChange(path: url.path, existed: true, beforeHash: hash)
        let backups = try AgentFiles(workspace: store.backupDirectory(taskID).path)
        let backup = backups.root.appendingPathComponent(checkpoint.id)
        try backups.writeData(before.data, to: backup, permissions: 0o600)
        checkpoint.permissions = permissions
        checkpoint.afterPermissions = permissions
        checkpoint.backup = backup.path
        checkpoint.afterHash = AgentFiles.hash(after)
        checkpoint.origin = "安全检查"
        store.update(taskID) { $0.changes.append(checkpoint) }
        guard store.writeError == nil else { throw PetError("无法保存撤回记录，文件未修改") }
        do {
            try files.writeData(after, to: url, permissions: permissions, expectedTarget: metadata.signature)
        } catch {
            store.update(taskID) { $0.changes.removeAll { $0.id == checkpoint.id } }
            if store.writeError == nil { try? backups.remove(backup) }
            throw error
        }
        return checkpoint.id
    }
}
