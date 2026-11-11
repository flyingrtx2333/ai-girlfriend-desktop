import Foundation
import Darwin

struct AgentDependencyFinding: Codable {
    let path: String
    let ecosystem: String
    let package: String
    let version: String
    let advisory: String
    let aliases: [String]
    let summary: String?
    let score: Double?
    let fixedVersions: [String]

    var severity: String {
        guard let score else { return "—" }
        switch score {
        case 9...10: return "严重"
        case 7..<9: return "高"
        case 4..<7: return "中"
        default: return "低"
        }
    }
    var advisoryURL: URL? {
        guard advisory.range(of: "^[A-Za-z0-9._-]{1,120}$", options: .regularExpression) != nil else { return nil }
        return URL(string: "https://osv.dev/vulnerability/" + advisory)
    }
}

struct AgentDependencyReport: Codable {
    enum Source: String, Codable {
        case working, staged
        var title: String { self == .staged ? "暂存区" : "工作区" }
    }
    struct Skipped: Codable { let path: String; let reason: String }
    let workspace: String
    let source: Source
    let selectedOnly: Bool
    let created: Date
    let databases: [AgentDependencyDatabase]
    let scannedFiles: Int
    let packages: Int
    let findings: [AgentDependencyFinding]
    let skipped: [Skipped]

    var summary: String {
        let result = packages == 0 ? "未检查到可核对的依赖版本" : findings.isEmpty ? "未命中已知公告" : "\(findings.count) 项漏洞"
        let coverage = scannedFiles == 0 ? "" : "\(scannedFiles) 个文件 · \(packages) 个依赖 · "
        return source.title + " · " + (selectedOnly ? "所选文件" : "整个项目") + " · " + coverage + result
            + (skipped.isEmpty ? "" : " · 跳过 \(skipped.count) 个文件")
    }
}

@MainActor final class AgentDependencySecurity {
    static let ecosystems = [
        "package-lock.json": "npm", "npm-shrinkwrap.json": "npm", "pnpm-lock.yaml": "npm", "yarn.lock": "npm", "bun.lock": "npm",
        "Cargo.lock": "crates.io", "go.mod": "Go",
        "requirements.txt": "PyPI", "Pipfile.lock": "PyPI", "poetry.lock": "PyPI", "pdm.lock": "PyPI", "pylock.toml": "PyPI", "uv.lock": "PyPI",
        "gradle.lockfile": "Maven", "buildscript-gradle.lockfile": "Maven",
        "packages.lock.json": "NuGet", "packages.config": "NuGet", "paket.lock": "NuGet",
        "composer.lock": "Packagist", "Gemfile.lock": "RubyGems", "gems.locked": "RubyGems", "pubspec.lock": "Pub", "mix.lock": "Hex"
    ]
    private static let fileLimit = 12_000_000
    private static let totalLimit = 64_000_000
    private static let reportLimit = 32_000_000
    private let store: AgentStore, taskID: String, git: AgentGit?
    let files: AgentFiles
    private let cache: URL, reportFile: URL
    var supportsStaging: Bool { git != nil }

    init(store: AgentStore, taskID: String, git: AgentGit?) throws {
        guard let task = store.task(taskID), !task.archived else { throw PetError("任务不存在或已归档") }
        self.store = store; self.taskID = taskID; self.git = git
        files = try AgentFiles(workspace: task.workspace)
        cache = store.directory.deletingLastPathComponent().appendingPathComponent("dependency-advisories", isDirectory: true)
        reportFile = try store.backupDirectory(taskID).deletingLastPathComponent().appendingPathComponent("dependency-report.json")
        try validate()
    }

    static func ecosystem(_ path: String) -> String? { ecosystems[(path as NSString).lastPathComponent] }

    private func validate() throws {
        guard let task = store.task(taskID), !task.archived, try AgentFiles(workspace: task.workspace).root == files.root else {
            throw PetError("任务项目已变化，请重新打开检查窗口")
        }
        if let git {
            guard git.files.root == files.root else { throw PetError("Git 项目已变化，请重新打开") }
            try git.validateWorkspace()
        }
    }

    func previousReport() -> AgentDependencyReport? {
        guard let bytes = try? AgentFiles(workspace: reportFile.deletingLastPathComponent().path).readData(reportFile, maximum: Self.reportLimit),
              let report = try? JSONDecoder().decode(AgentDependencyReport.self, from: bytes), report.workspace == files.root.path else { return nil }
        return report
    }

    private var pathspecs: [String] { Self.ecosystems.keys.sorted().map { ":(glob)**/" + $0 } }

    private func workingPaths() async throws -> [String] {
        if let git {
            let result = try await git.run(["ls-files", "--cached", "--others", "--exclude-standard", "-z", "--"] + pathspecs,
                maximumOutput: 1_000_000, literalPaths: false)
            guard !result.failed, result.truncated != true else { throw PetError("无法完整读取 Git 锁文件列表") }
            return Array(Set((result.stdout ?? "").split(separator: "\0").map(String.init))).sorted()
        }
        var enumerationFailed = false
        guard let walker = FileManager.default.enumerator(at: files.root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in enumerationFailed = true; return false }) else {
            throw PetError("无法读取项目文件夹")
        }
        let generated: Set<String> = ["node_modules", "build", "dist", "DerivedData", "__pycache__"]
        var results: [String] = [], visited = 0
        for case let url as URL in walker {
            try Task.checkCancellation()
            visited += 1
            guard visited <= 100_000 else { throw PetError("项目文件过多，请选择较小的项目目录") }
            let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if info.isDirectory == true || info.isSymbolicLink == true {
                if generated.contains(url.lastPathComponent) || info.isSymbolicLink == true { walker.skipDescendants() }
                continue
            }
            if Self.ecosystem(url.path) != nil { results.append(files.relative(url)) }
        }
        guard !enumerationFailed else { throw PetError("部分项目目录无法读取") }
        return results.sorted()
    }

    func scan(source: AgentDependencyReport.Source, requested: [String]? = nil, forceUpdate: Bool = false,
              progress: (String) -> Void = { _ in }) async throws -> AgentDependencyReport {
        try validate()
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "osv-scanner"), FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw PetError("缺少依赖漏洞扫描器，请重新构建应用")
        }
        progress("读取依赖文件…")
        let indexed: [String: String]
        let candidates: [String]
        if source == .staged {
            guard let git else { throw PetError("此项目没有 Git 暂存区") }
            indexed = try await git.securityIndexEntries(pathspecs, literalPaths: false)
            candidates = requested ?? indexed.keys.sorted()
        } else {
            indexed = [:]
            if let requested { candidates = requested } else { candidates = try await workingPaths() }
        }
        let paths = Array(Set(candidates)).sorted()
        guard paths.allSatisfy({ Self.ecosystem($0) != nil && !$0.contains("\0") && $0.utf8.count < 8192 &&
            $0.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && ![".", "..", ".git"].contains($0) } }) else {
            throw PetError("依赖文件列表无效，请刷新项目")
        }
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("bluefatfish-dependency-" + UUID().uuidString, isDirectory: true)
        let snapshot = scratch.appendingPathComponent("files", isDirectory: true)
        let database = scratch.appendingPathComponent("advisories", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        try fm.createDirectory(at: snapshot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let copies = try AgentFiles(workspace: snapshot.path)
        var inputs: [String: [String]] = [:], skipped: [AgentDependencyReport.Skipped] = []
        var total = 0
        for (index, path) in paths.enumerated() {
            try Task.checkCancellation()
            do {
                guard index < 150 else { throw PetError("超过单次 150 个文件上限") }
                let data: Data
                if let git, source == .staged {
                    guard let oid = indexed[path] else { throw PetError("暂存区没有可读取的版本") }
                    data = try await git.securityBlob(oid, maximum: Self.fileLimit)
                } else {
                    let url = try files.literalURL(path)
                    guard url.path == files.root.appendingPathComponent(path).path, try files.entryMetadata(url).kind == "file" else {
                        throw PetError("工作区没有普通文件")
                    }
                    let read = try files.readPrefix(url, maximum: Self.fileLimit)
                    guard !read.partial else { throw PetError("超过单文件 12 MB 上限") }
                    data = read.data
                }
                guard total + data.count <= Self.totalLimit else { throw PetError("超过单次 64 MB 上限") }
                if (path as NSString).lastPathComponent == "requirements.txt", !Self.hasPinnedRequirements(data) {
                    throw PetError("需要自包含的固定版本 requirements.txt")
                }
                guard let ecosystem = Self.ecosystem(path) else { throw PetError("未支持的依赖文件") }
                try copies.writeData(data, to: copies.root.appendingPathComponent(path), permissions: 0o600)
                inputs[ecosystem, default: []].append(path)
                total += data.count
            } catch is CancellationError { throw CancellationError() }
            catch let error as PetError { skipped.append(.init(path: path, reason: error.localizedDescription)) }
            catch { skipped.append(.init(path: path, reason: "无法读取依赖文件")) }
        }

        var databases: [AgentDependencyDatabase] = [], packages = 0, scanned = 0, findings: [AgentDependencyFinding] = []
        for ecosystem in inputs.keys.sorted() {
            guard let group = inputs[ecosystem] else { continue }
            try Task.checkCancellation()
            do {
                databases.append(try await AgentDependencyAdvisories.freeze(ecosystem, cache: cache, snapshot: database,
                    force: forceUpdate, progress: progress))
            } catch is CancellationError { throw CancellationError() }
            catch {
                skipped += group.map { .init(path: $0, reason: "公告库不可用") }
                continue
            }
            progress("检查 \(ecosystem) 的 \(group.count) 个文件…")
            let batch = try await scanFiles(group, ecosystem: ecosystem, executable: executable, files: copies, scratch: scratch, database: database)
            packages += batch.packages; scanned += batch.scanned
            findings += batch.findings; skipped += batch.skipped
        }
        try Task.checkCancellation()
        try validate()
        let ordered = findings.sorted { lhs, rhs in
            if lhs.score != rhs.score { return (lhs.score ?? -1) > (rhs.score ?? -1) }
            return (lhs.path, lhs.package, lhs.version, lhs.advisory) < (rhs.path, rhs.package, rhs.version, rhs.advisory)
        }
        let report = AgentDependencyReport(workspace: files.root.path, source: source, selectedOnly: requested != nil, created: Date(),
            databases: databases, scannedFiles: scanned, packages: packages, findings: ordered, skipped: skipped.sorted { $0.path < $1.path })
        let encoded = try JSONEncoder().encode(report)
        guard encoded.count <= Self.reportLimit else { throw PetError("报告过大，请缩小检查范围") }
        let reports = try AgentFiles(workspace: reportFile.deletingLastPathComponent().path)
        try reports.writeData(encoded, to: reportFile, permissions: 0o600)
        return report
    }

    private static func hasPinnedRequirements(_ bytes: Data) -> Bool {
        guard let text = String(data: bytes, encoding: .utf8) else { return false }
        return text.components(separatedBy: .newlines).allSatisfy { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("--hash=") { return true }
            return line.range(of: #"^[A-Za-z0-9_.-]+(?:\[[^\]]+\])?\s*==\s*[A-Za-z0-9][A-Za-z0-9.!+_-]*(?=[\s;#\\]|$)"#,
                options: .regularExpression) != nil
        }
    }

    private struct Batch {
        var packages = 0, scanned = 0
        var findings: [AgentDependencyFinding] = [], skipped: [AgentDependencyReport.Skipped] = []
        mutating func add(_ batch: Batch) {
            packages += batch.packages; scanned += batch.scanned; findings += batch.findings; skipped += batch.skipped
        }
    }
    private func scanFiles(_ paths: [String], ecosystem: String, executable: URL, files: AgentFiles, scratch: URL, database: URL) async throws -> Batch {
        guard let resolved = realpath(files.root.path, nil) else { throw PetError("无法定位依赖文件副本") }
        let prefix = String(cString: resolved) + "/"
        free(resolved)
        let json = scratch.appendingPathComponent("osv-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: json) }
        let arguments = ["scan", "source", "--offline", "--no-resolve", "--all-packages", "--all-vulns", "--no-call-analysis=go", "--no-call-analysis=rust",
            "--verbosity=error", "--format=json", "--output-file", json.path] +
            paths.flatMap { ["--lockfile", ":" + prefix + $0] }
        let result = try await AgentCommand().run(command: executable.path, workspace: files.root, scratch: scratch, network: false,
            timeout: 90, readOnly: true, maximumOutput: 24_000, readRoots: [executable], listSnapshotParents: true,
            environment: ["HOME": scratch.path, "OSV_SCANNER_LOCAL_DB_CACHE_DIRECTORY": database.path], arguments: arguments)
        try Task.checkCancellation()
        if result.exitCode == 127, paths.count > 1, result.timedOut != true {
            let split = paths.count / 2
            var left = try await scanFiles(Array(paths.prefix(split)), ecosystem: ecosystem, executable: executable, files: files, scratch: scratch, database: database)
            left.add(try await scanFiles(Array(paths.dropFirst(split)), ecosystem: ecosystem, executable: executable, files: files, scratch: scratch, database: database))
            return left
        }
        guard [0, 1].contains(result.exitCode ?? -1), result.timedOut != true else {
            let reason = result.timedOut == true ? "扫描超时" : result.exitCode == 128 ? "没有可核对的依赖版本" : "扫描器无法解析文件或公告库"
            return Batch(skipped: paths.map { .init(path: $0, reason: reason) })
        }
        let storage = try AgentFiles(workspace: scratch.path)
        let data = try storage.readData(json, maximum: Self.reportLimit)
        let parsed = try JSONDecoder().decode(OSVResult.self, from: data)
        let allowed = Set(paths)
        var found: Set<String> = [], batch = Batch()
        for entry in parsed.results ?? [] {
            guard entry.source.path.hasPrefix(prefix), entry.source.type == "lockfile" else { throw PetError("扫描结果来源无效") }
            let path = String(entry.source.path.dropFirst(prefix.count))
            guard allowed.contains(path), !found.contains(path) else { throw PetError("扫描结果引用了未知或重复文件") }
            let resolved = (entry.packages ?? []).filter { $0.package.ecosystem == ecosystem &&
                $0.package.name?.isEmpty == false && $0.package.version?.isEmpty == false }
            guard !resolved.isEmpty else { continue }
            found.insert(path)
            batch.scanned += 1
            batch.packages += resolved.count
            for package in resolved { batch.findings += package.findings(path: path) }
        }
        batch.skipped = paths.filter { !found.contains($0) }.map { .init(path: $0, reason: "没有可核对的依赖版本") }
        return batch
    }
}

private struct OSVResult: Decodable {
    struct Source: Decodable { let path: String; let type: String }
    struct Entry: Decodable { let source: Source; let packages: [Package]? }
    struct Identity: Decodable { let name: String?; let ecosystem: String?; let version: String? }
    struct Advisory: Decodable {
        struct Affected: Decodable {
            struct Name: Decodable { let name: String; let ecosystem: String }
            struct Range: Decodable {
                struct Event: Decodable { let fixed: String? }
                let events: [Event]
            }
            let package: Name?
            let ranges: [Range]?
        }
        let id: String
        let summary: String?
        let affected: [Affected]?
    }
    struct Group: Decodable {
        let ids: [String]
        let aliases: [String]?
        let max_severity: String?
    }
    struct Package: Decodable {
        let package: Identity
        let groups: [Group]?
        let vulnerabilities: [Advisory]?

        func findings(path: String) -> [AgentDependencyFinding] {
            guard let ecosystem = package.ecosystem, let name = package.name, let version = package.version else { return [] }
            let advisories = vulnerabilities ?? []
            var groups = groups ?? []
            let grouped = Set(groups.flatMap(\.ids))
            groups += advisories.filter { !grouped.contains($0.id) }.map { Group(ids: [$0.id], aliases: nil, max_severity: nil) }
            return groups.compactMap { group in
                let matches = advisories.filter { group.ids.contains($0.id) }
                guard let advisory = matches.first(where: { $0.summary?.isEmpty == false }) ?? matches.first else { return nil }
                let fixes = matches.flatMap { $0.affected ?? [] }.filter {
                    $0.package.map { $0.ecosystem == ecosystem && normalized($0.name) == normalized(name) } == true
                }.flatMap { $0.ranges ?? [] }.compactMap { $0.events.last?.fixed }
                let score = group.max_severity.flatMap(Double.init).flatMap { (0...10).contains($0) ? $0 : nil }
                return AgentDependencyFinding(path: path, ecosystem: ecosystem, package: name, version: version,
                    advisory: advisory.id, aliases: Array(Set(group.aliases ?? [])).sorted(), summary: advisory.summary, score: score,
                    fixedVersions: Array(Set(fixes)).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
            }
        }
        private func normalized(_ name: String) -> String {
            package.ecosystem == "PyPI" ? name.lowercased().replacingOccurrences(of: "[-_.]+", with: "-", options: .regularExpression) : name
        }
    }
    let results: [Entry]?
}
