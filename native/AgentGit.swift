import Foundation

struct AgentGitChange: Codable { var status: String; var path: String; var previousPath: String? }
struct AgentGitStatus: Codable { var branch: String; var head: String?; var changes: [AgentGitChange] }
struct AgentGitReview: Codable {
    var paths: [String]; var head: String?; var hash: String; var diff: String; var created = Date()
    var source: AgentGitSource? = nil
    var branchRef: String? = nil
    var commitSource: AgentGitSource { source ?? .uncommitted }
    enum CodingKeys: String, CodingKey { case paths, head, hash = "review_hash", diff, created, source, branchRef }
}
struct AgentGitCommit: Codable { var commit: String; var branch: String; var output: String }
struct AgentGitWorktree: Codable { var taskID: String; var workspace: String; var branch: String; var baseCommit: String? = nil; var includedChanges: Bool? = nil }

@MainActor final class AgentGit {
    static let externalTools = ["git_prepare_push", "git_push", "git_push_status"]
    static let creationTools = ["git_worktree_branches", "git_prepare_worktree"]
    static let tools = ["git_status", "git_diff", "git_commit", "git_create_worktree", "git_init", "git_remotes"] + externalTools + AgentWorktreeEntry.tools + creationTools
    private static let executable: Result<String, Error> = Result {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun"); process.arguments = ["--find", "git"]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { throw PetError("找不到 Git，请先安装 Xcode 命令行工具") }
        return path
    }
    static func executablePath() throws -> String { try executable.get() }
    let store: AgentStore, taskID: String, files: AgentFiles, directory: URL
    let scratch: URL
    private var command: AgentCommand?
    var pushTransport: AgentGitTransport?
    var pushHookCommand: AgentCommand?
    var worktreeCopy: AgentCommand?
    let allowsArchivedWorktreeSource: Bool
    var worktreeEligibilityCheck: ((AgentWorktreeEntry, Date) throws -> Void)?
    init(store: AgentStore, taskID: String, directory: URL, allowsArchivedWorktreeSource: Bool = false) throws {
        guard let task = store.task(taskID) else { throw PetError("任务不存在") }
        self.store = store; self.taskID = taskID; files = try AgentFiles(workspace: task.workspace); self.directory = directory
        self.allowsArchivedWorktreeSource = allowsArchivedWorktreeSource
        scratch = try store.backupDirectory(taskID).deletingLastPathComponent().appendingPathComponent("git", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    static func metadata(workspace: String?, creating: Bool = false) throws -> URL {
        let files = try AgentFiles(workspace: workspace), entry = try files.resolve(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory) else {
            if creating { return entry }; throw PetError("当前项目不是 Git 仓库，请选择仓库根目录")
        }
        if isDirectory.boolValue { return entry }
        let data = try files.readData(entry, maximum: 8192)
        guard let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), line.hasPrefix("gitdir: ") else { throw PetError("Git 工作树元数据无效") }
        let raw = String(line.dropFirst(8)), url = URL(fileURLWithPath: raw, relativeTo: files.root.appendingPathComponent("", isDirectory: true)).standardizedFileURL.resolvingSymlinksInPath()
        return url.deletingLastPathComponent().lastPathComponent == "worktrees" ? url.deletingLastPathComponent().deletingLastPathComponent() : url
    }
    func cancel() { command?.cancel(); pushTransport?.cancel(); pushHookCommand?.cancel(); worktreeCopy?.cancel() }
    nonisolated static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    func run(_ args: [String], write: Bool = false, maximumOutput: Int = 100_000, timeout: Double? = nil, environment: [String: String] = [:], inputFile: URL? = nil, readRoots: [URL] = []) async throws -> AgentToolResult {
        let process = AgentCommand(); command = process; defer { command = nil }
        let flags = [try Self.executablePath(), "--no-pager", "--literal-pathspecs", "-c", "core.fsmonitor=false", "-c", "core.quotePath=false"]
        return try await process.run(command: (flags + args).map(Self.quote).joined(separator: " "), workspace: files.root, scratch: scratch, network: false, timeout: timeout ?? (write ? 90 : 15), readOnly: !write, gitDirectory: directory, gitWrite: write, gitConfiguration: true, maximumOutput: maximumOutput, protectedData: store.directory.deletingLastPathComponent(), inputFile: inputFile, readRoots: readRoots, environment: environment)
    }
    func output(_ args: [String]) async throws -> String {
        let result = try await run(args)
        guard !result.failed else { throw PetError(String(result.text.prefix(3000))) }
        guard result.truncated != true else { throw PetError("Git 输出较大，请缩小文件范围") }; return result.stdout ?? ""
    }
    func validateWorkspace() throws {
        guard let task = store.task(taskID), !task.archived || allowsArchivedWorktreeSource else { throw PetError("任务不存在或已归档") }
        let current = try AgentFiles(workspace: task.workspace), metadata = try Self.metadata(workspace: task.workspace, creating: true)
        guard current.root == files.root, metadata.standardizedFileURL.resolvingSymlinksInPath() == directory.standardizedFileURL.resolvingSymlinksInPath() else { throw PetError("任务项目已变化，请重新打开 Git 后审阅") }
    }
    func filePaths() async throws -> [String] {
        let result = try await run(["ls-files", "--cached", "--others", "--exclude-standard", "-z"], maximumOutput: 1_000_000)
        guard !result.failed else { throw PetError(result.text) }
        guard result.truncated != true else { throw PetError("项目文件过多，请选择较小的项目目录") }
        return Array(Set((result.stdout ?? "").components(separatedBy: "\0").filter { !$0.isEmpty })).sorted()
    }
    func status() async throws -> AgentGitStatus {
        let raw = try await output(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=all"])
        let branch = try await run(["symbolic-ref", "--quiet", "--short", "HEAD"])
        let head = try await run(["rev-parse", "--verify", "HEAD"])
        let values = raw.components(separatedBy: "\0"); var index = 0, changes: [AgentGitChange] = []
        while index < values.count {
            let value = values[index]; index += 1; if value.isEmpty { continue }
            guard value.count >= 3 else { throw PetError("Git 状态格式无效") }
            let state = String(value.prefix(2)), path = String(value.dropFirst(3)); var prior: String?
            if state.contains("R") || state.contains("C") { guard index < values.count else { throw PetError("Git 重命名记录不完整") }; prior = values[index]; index += 1 }
            changes.append(AgentGitChange(status: state, path: path, previousPath: prior))
        }
        return AgentGitStatus(branch: branch.failed ? "分离状态" : (branch.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines), head: head.failed ? nil : (head.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines), changes: changes)
    }
    func paths(_ requested: [String], allowRecordedTypes: Bool = false) throws -> [String] {
        guard !requested.isEmpty, requested.count <= 50 else { throw PetError("请选择 1 至 50 个文件") }
        return try Array(Set(requested.map { path in
            let url = try allowRecordedTypes ? files.literalURL(path) : files.resolve(path)
            let value = String(url.path.dropFirst(files.root.path.count + 1))
            let lexical = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : files.root.appendingPathComponent(path)).standardizedFileURL
            guard lexical.path == url.path else { throw PetError("Git 文件路径包含符号链接，请直接选择实际文件") }
            guard value != ".", value != ".git", !value.hasPrefix(".git/") else { throw PetError("不能把 Git 元数据当作项目文件") }
            var directory: ObjCBool = false
            if !allowRecordedTypes, FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue { throw PetError("请选择具体文件") }
            return value
        })).sorted()
    }
    func diff(_ requested: [String], source: AgentGitSource = .uncommitted) async throws -> AgentGitReview {
        if source == .staged {
            let inspection = try await inspect(source: .staged, revision: "", requested: requested)
            guard let saved = store.task(taskID)?.gitReview, saved.hash == inspection.hash, store.writeError == nil else { throw PetError("无法保存暂存审阅") }
            return saved
        }
        guard source == .uncommitted else { throw PetError("提交审阅请选择未提交或已暂存来源") }
        let state = try await status(), requested = try paths(requested)
        let renamed = state.changes.filter { requested.contains($0.path) }.compactMap(\.previousPath)
        let selected = try paths(requested + renamed); var diff = ""
        for path in selected {
            let existsInHead = state.head != nil ? try await run(["cat-file", "-e", "HEAD:" + path]).exitCode == 0 : false
            let result: AgentToolResult
            if existsInHead { result = try await run(["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--binary", "HEAD", "--", path]) }
            else { result = try await run(["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--binary", "--", "/dev/null", path]) }
            guard result.exitCode == 0 || (!existsInHead && result.exitCode == 1) else { throw PetError(result.text) }
            guard result.truncated != true else { throw PetError("差异较大，请选择更小的文件") }; diff += result.stdout ?? ""
            guard diff.utf8.count <= 100_000 else { throw PetError("差异较多，请分批审阅") }
        }
        let fingerprint = Data(((state.head ?? "unborn") + "\0" + selected.joined(separator: "\0") + "\0" + diff).utf8)
        let review = AgentGitReview(paths: selected, head: state.head, hash: AgentFiles.hash(fingerprint), diff: diff)
        store.update(taskID) { $0.gitReview = review }; return review
    }
    func validateHooks() async throws {
        let hook = try await run(["config", "--path", "--get", "core.hooksPath"])
        if hook.exitCode == 0, let raw = hook.stdout?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let path = URL(fileURLWithPath: raw, relativeTo: files.root.appendingPathComponent("", isDirectory: true)).standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(files.root.path + "/") || path == directory.path || path.hasPrefix(directory.path + "/") else { throw PetError("Git Hook 位于项目外，当前隔离范围无法执行。请使用本地 Git 完成操作") }
        } else if hook.exitCode != 1 { throw PetError(hook.text) }
    }
    func commit(paths requested: [String], message: String, reviewHash: String) async throws -> AgentGitCommit {
        try validateWorkspace()
        let selected = try paths(requested), message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.utf8.count <= 4000, !message.contains("\0") else { throw PetError("请填写提交说明，最多 4000 字节") }
        guard let saved = store.task(taskID)?.gitReview, saved.paths == selected, saved.hash == reviewHash else { throw PetError("请先审阅这些文件的 Git 差异") }
        if let task = store.task(taskID) { try store.agents.check(AgentToolCall(id: "git-commit", name: "git_commit", arguments: "{}"), task: task, store: store) }
        if saved.commitSource == .staged { return try await commitStaged(saved, message: message) }
        let current = try await diff(selected)
        guard current.hash == reviewHash else { throw PetError("文件或 HEAD 已变化，请重新审阅差异后提交") }
        guard !current.diff.isEmpty else { throw PetError("所选文件没有可提交的变化") }
        try await validateHooks()
        let state = try await status()
        guard !state.changes.contains(where: { selected.contains($0.path) && ($0.status.contains("U") || ["AA", "DD"].contains($0.status)) }) else { throw PetError("请先处理所选文件的合并冲突") }
        let added = state.changes.filter { selected.contains($0.path) && $0.status == "??" }.map(\.path)
        if !added.isEmpty {
            let add = try await run(["add", "--intent-to-add", "--"] + added, write: true)
            guard !add.failed else { throw PetError(add.text) }
        }
        try Task.checkCancellation()
        let result = try await run(["commit", "--only", "-m", message, "--"] + selected, write: true)
        guard !result.failed else { throw PetError("提交未完成，请检查当前 Git 状态：\n" + result.text) }
        let after = try await status()
        guard let head = after.head, head != current.head else { throw PetError("Git 未生成新的提交，请检查实际状态") }
        store.update(taskID) { $0.gitReview = nil }
        return AgentGitCommit(commit: head, branch: after.branch, output: result.text)
    }
    func initialize() async throws -> AgentGitStatus {
        try validateWorkspace()
        guard !FileManager.default.fileExists(atPath: files.root.appendingPathComponent(".git").path) else { throw PetError("项目已有 Git 元数据") }
        let result = try await run(["init", "-b", "main"], write: true)
        guard !result.failed else { throw PetError(result.text) }; return try await status()
    }
    func createWorktree(branch: String, startPoint: String = "HEAD", includeChanges: Bool = false, reviewHash: String? = nil) async throws -> AgentGitWorktree {
        if let reviewHash {
            let review = try storedWorktreeCreation(reviewHash)
            let matches = try await worktreeStartingPoints().filter { $0.ref == startPoint || $0.title == startPoint }
            guard review.branch == branch, review.includeChanges == includeChanges,
                  matches.count == 1, matches.first?.ref == review.startPoint else { throw PetError("创建选项与审阅不一致，请重新预览") }
            return try await createReviewedWorktree(reviewHash)
        }
        guard !includeChanges else { throw PetError("带入修改前请先使用 git_prepare_worktree 审阅，并传入 review_hash") }
        let review = try await prepareWorktreeCreation(branch: branch, startPoint: startPoint)
        return try await createReviewedWorktree(review.hash)
    }
}
