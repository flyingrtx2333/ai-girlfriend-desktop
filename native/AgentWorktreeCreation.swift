import Foundation
import Darwin

struct AgentWorktreeStart: Codable {
    var ref: String
    var title: String
    var commit: String
}
struct AgentWorktreeCreationReview: Codable {
    var hash = UUID().uuidString
    var taskID: String
    var processID = ProcessInfo.processInfo.processIdentifier
    var created = Date()
    var root: String
    var scope: String
    var branch: String
    var startPoint: String
    var baseCommit: String
    var sourceHead: String
    var sourceRef: String
    var sourceIndex: String
    var includeChanges: Bool
    var sourceTree: String?
    var targetTree: String
    var paths: [String]
    var patch: String
    var consumed = false
    var summary: String {
        "新分支：" + branch + "\n起点：" + startPoint + " · " + String(baseCommit.prefix(12)) + "\n" +
        (includeChanges ? "带入 \(paths.count) 个文件的当前修改，保持未暂存；忽略文件不带入。" : "不带入当前未提交修改。")
    }
}

@MainActor extension AgentGit {
    private func creationScope() throws -> String {
        try validateWorkspace()
        guard let task = store.task(taskID), task.automation == nil, task.agent?.ownerID == nil,
              !["hook", "wiki"].contains(task.kind ?? "") else { throw PetError("请从独立任务创建工作树") }
        try store.agents.check(AgentToolCall(id: "create-worktree", name: "git_create_worktree", arguments: "{}"), task: task, store: store)
        return AgentFiles.hash(Data([files.root.path, task.mode.rawValue, task.permission.rawValue, task.agent?.profile.id ?? "", task.team?.team.id ?? ""].joined(separator: "\0").utf8))
    }
    private func creationDirectory(_ hash: String) throws -> URL {
        guard UUID(uuidString: hash) != nil else { throw PetError("工作树审阅编号无效") }
        return scratch.appendingPathComponent("worktree-create-" + hash, isDirectory: true)
    }
    private func saveCreation(_ review: AgentWorktreeCreationReview) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let folder = try creationDirectory(review.hash)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("review.json")
        try encoder.encode(review).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func storedWorktreeCreation(_ hash: String) throws -> AgentWorktreeCreationReview {
        let review = try JSONDecoder().decode(AgentWorktreeCreationReview.self, from: Data(contentsOf: creationDirectory(hash).appendingPathComponent("review.json")))
        guard review.hash == hash, review.taskID == taskID, review.processID == ProcessInfo.processInfo.processIdentifier,
              Date().timeIntervalSince(review.created) < 900, !review.consumed, review.root == files.root.path else { throw PetError("工作树审阅已失效，请重新预览") }
        return review
    }
    func worktreeStartingPoints() async throws -> [AgentWorktreeStart] {
        try validateWorkspace()
        let head = try await output(["rev-parse", "--verify", "HEAD^{commit}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = try await output(["for-each-ref", "--format=%(refname)%00%(objectname)", "refs/heads/", "refs/remotes/"])
        var result = [AgentWorktreeStart(ref: "HEAD", title: "当前提交", commit: head)]
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw PetError("分支列表格式无效") }
            let ref = String(parts[0]); if ref.hasSuffix("/HEAD") { continue }
            result.append(AgentWorktreeStart(ref: ref, title: ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : String(ref.dropFirst(13)), commit: String(parts[1])))
        }
        return result
    }
    private func startingPoint(_ value: String) async throws -> AgentWorktreeStart {
        let matches = try await worktreeStartingPoints().filter { $0.ref == value || $0.title == value }
        guard matches.count == 1, let result = matches.first else { throw PetError("起点分支不存在或名称不明确，请重新选择") }
        return result
    }
    private func creationState() async throws -> (head: String, ref: String, index: String, protected: [URL]) {
        _ = try creationScope()
        let head = try await output(["rev-parse", "--verify", "HEAD^{commit}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let refResult = try await run(["symbolic-ref", "--quiet", "HEAD"])
        let ref = refResult.failed ? "HEAD" : (refResult.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        func canonical(_ url: URL) -> URL {
            if let raw = realpath(url.path, nil) { defer { free(raw) }; return URL(fileURLWithPath: String(cString: raw)) }
            if let raw = realpath(url.deletingLastPathComponent().path, nil) { defer { free(raw) }; return URL(fileURLWithPath: String(cString: raw)).appendingPathComponent(url.lastPathComponent) }
            return url.standardizedFileURL
        }
        let rawIndex = try await output(["rev-parse", "--git-path", "index"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let index = canonical(URL(fileURLWithPath: rawIndex, relativeTo: files.root.appendingPathComponent("", isDirectory: true)))
        let indexData = try AgentFiles(workspace: directory.path).readData(index, maximum: 32_000_000)
        for marker in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer", "index.lock"] {
            let path = try await output(["rev-parse", "--git-path", marker]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !FileManager.default.fileExists(atPath: URL(fileURLWithPath: path, relativeTo: files.root.appendingPathComponent("", isDirectory: true)).path) else { throw PetError("请先结束当前 Git 操作，再创建工作树") }
        }
        var protected = [index, index.appendingPathExtension("lock")]
        for name in ["HEAD", "HEAD.lock", "logs/HEAD", "packed-refs", "packed-refs.lock"] + (ref == "HEAD" ? [] : [ref, ref + ".lock"]) {
            let raw = try await output(["rev-parse", "--git-path", name]).trimmingCharacters(in: .whitespacesAndNewlines)
            protected.append(canonical(URL(fileURLWithPath: raw, relativeTo: files.root.appendingPathComponent("", isDirectory: true))))
        }
        return (head, ref, AgentFiles.hash(indexData), protected)
    }
    private func creationRun(_ args: [String], session: URL, protected: [URL], index: String? = nil, writes: [URL] = []) async throws -> String {
        let process = AgentCommand(); worktreeCopy = process; defer { worktreeCopy = nil }
        let result = try await process.run(command: try Self.executablePath(), workspace: files.root, scratch: session, network: false, timeout: 90,
            readOnly: true, gitDirectory: directory, gitWrite: true, gitConfiguration: true, maximumOutput: 2_000_000,
            protectedData: store.directory.deletingLastPathComponent(), writeRoots: writes, protectedWrites: protected,
            environment: index.map { ["GIT_INDEX_FILE": $0] } ?? [:], arguments: ["--no-pager", "--literal-pathspecs", "-c", "core.fsmonitor=false"] + args)
        guard !result.failed else { throw PetError(result.text) }
        guard result.truncated != true else { throw PetError("当前修改过大，无法完整预览；请缩小修改范围后重试") }
        return result.stdout ?? ""
    }
    private func currentWorkingTree(head: String, session: URL, protected: [URL]) async throws -> String {
        let sparse = try await run(["config", "--bool", "core.sparseCheckout"])
        guard sparse.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) != "true" else { throw PetError("稀疏检出暂不支持带入当前修改，请取消该选项") }
        let tracked = try await output(["ls-files", "--stage", "-z"])
        guard !tracked.components(separatedBy: "\0").contains(where: { entry in
            let fields = entry.components(separatedBy: "\t").first?.split(separator: " ") ?? []
            return !entry.isEmpty && (fields.count != 3 || fields[0] == "160000" || fields[2] != "0")
        }) else { throw PetError("当前存在子模块或未解决冲突，不能带入修改") }
        let old = try await output(["ls-tree", "-r", "--name-only", "-z", head])
        let current = try await filePaths()
        let paths = Set(old.components(separatedBy: "\0").filter { !$0.isEmpty } + current).filter { !$0.hasPrefix(".bluefatfish/worktrees/") }
        for path in paths {
            let lexical = files.root.appendingPathComponent(path).standardizedFileURL
            guard lexical.path.hasPrefix(files.root.path + "/"), !path.split(separator: "/").contains(".git") else { throw PetError("修改路径无效") }
            let parent = try files.resolve(lexical.deletingLastPathComponent().path)
            guard parent.path == lexical.deletingLastPathComponent().path else { throw PetError("修改路径的父目录包含符号链接") }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: lexical.path),
               let kind = attributes[.type] as? FileAttributeType,
               kind != .typeRegular && kind != .typeSymbolicLink { throw PetError("当前修改含子仓库或特殊文件：" + path) }
        }
        let list = session.appendingPathComponent("paths"), index = session.appendingPathComponent("source-index").path
        try Data(paths.sorted().map { $0 + "\0" }.joined().utf8).write(to: list, options: .atomic)
        _ = try await creationRun(["read-tree", head], session: session, protected: protected, index: index)
        if !paths.isEmpty { _ = try await creationRun(["add", "-A", "--pathspec-from-file=" + list.path, "--pathspec-file-nul"], session: session, protected: protected, index: index) }
        return try await creationRun(["write-tree"], session: session, protected: protected, index: index).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func prepareWorktreeCreation(branch: String, startPoint: String = "HEAD", includeChanges: Bool = false) async throws -> AgentWorktreeCreationReview {
        let scope = try creationScope(), state = try await creationState()
        guard !branch.isEmpty, branch.utf8.count <= 200, !branch.hasPrefix("-"), !branch.contains("\0"),
              try await run(["check-ref-format", "--branch", branch]).exitCode == 0 else { throw PetError("分支名称无效") }
        guard try await run(["show-ref", "--verify", "--quiet", "refs/heads/" + branch]).exitCode == 1 else { throw PetError("新分支已存在，请更换名称") }
        let base = try await startingPoint(startPoint), hash = UUID().uuidString, session = try creationDirectory(hash)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let baseTree = try await output(["rev-parse", base.commit + "^{tree}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        var review = AgentWorktreeCreationReview(taskID: taskID, root: files.root.path, scope: scope, branch: branch, startPoint: base.ref, baseCommit: base.commit,
            sourceHead: state.head, sourceRef: state.ref, sourceIndex: state.index, includeChanges: includeChanges, targetTree: baseTree, paths: [], patch: "")
        review.hash = hash
        if includeChanges {
            let tree = try await currentWorkingTree(head: state.head, session: session, protected: state.protected)
            review.sourceTree = tree
            let patch = try await creationRun(["diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", state.head, tree, "--"], session: session, protected: state.protected)
            if !patch.isEmpty {
                let input = session.appendingPathComponent("source.patch"), target = session.appendingPathComponent("target-index").path
                try Data(patch.utf8).write(to: input, options: .atomic)
                _ = try await creationRun(["read-tree", base.commit], session: session, protected: state.protected, index: target)
                do { _ = try await creationRun(["apply", "--cached", "--3way", "--whitespace=nowarn", input.path], session: session, protected: state.protected, index: target) }
                catch { throw PetError("当前修改无法完整合并到所选起点，尚未创建工作树：\n" + error.localizedDescription) }
                review.targetTree = try await creationRun(["write-tree"], session: session, protected: state.protected, index: target).trimmingCharacters(in: .whitespacesAndNewlines)
                review.patch = try await creationRun(["diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", base.commit, review.targetTree, "--"], session: session, protected: state.protected)
                review.paths = try await creationRun(["diff", "--name-only", "-z", base.commit, review.targetTree, "--"], session: session, protected: state.protected).components(separatedBy: "\0").filter { !$0.isEmpty }
            }
        }
        let after = try await creationState()
        guard after.head == state.head, after.ref == state.ref, after.index == state.index, try creationScope() == scope,
              try await startingPoint(base.ref).commit == base.commit else { throw PetError("来源或起点已变化，请重新预览") }
        try saveCreation(review); return review
    }
    func createReviewedWorktree(_ hash: String) async throws -> AgentGitWorktree {
        var review = try storedWorktreeCreation(hash)
        let scope = try creationScope(), state = try await creationState()
        guard scope == review.scope, state.head == review.sourceHead, state.ref == review.sourceRef, state.index == review.sourceIndex,
              try await startingPoint(review.startPoint).commit == review.baseCommit else { throw PetError("分支、暂存区或任务范围已变化，请重新预览") }
        if review.includeChanges {
            let session = scratch.appendingPathComponent("worktree-verify-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: session) }
            guard try await currentWorkingTree(head: state.head, session: session, protected: state.protected) == review.sourceTree else { throw PetError("当前文件已变化，请重新预览") }
        }
        guard try await run(["show-ref", "--verify", "--quiet", "refs/heads/" + review.branch]).exitCode == 1 else { throw PetError("新分支已存在，请更换名称后重新预览") }
        try await validateHooks(); try Task.checkCancellation()
        let relative = ".bluefatfish/worktrees/" + UUID().uuidString.lowercased(), destination = try files.resolve(relative)
        try ignoreAppWorktrees()
        let session = try creationDirectory(hash)
        review.consumed = true; try saveCreation(review)
        // Project hooks may write inside the new checkout, never the source files or index.
        guard let rawRoot = realpath(files.root.path, nil) else { throw PetError("来源项目不可用") }
        let root = URL(fileURLWithPath: String(cString: rawRoot)); free(rawRoot)
        let writes = [root.appendingPathComponent(".bluefatfish")]
        var checkoutError: String?
        do { _ = try await creationRun(["worktree", "add", "-b", review.branch, destination.path, review.baseCommit], session: session, protected: state.protected, writes: writes) }
        catch {
            guard FileManager.default.fileExists(atPath: destination.appendingPathComponent(".git").path) else { throw error }
            checkoutError = error.localizedDescription
        }
        guard try Self.metadata(workspace: destination.path) == directory else { throw PetError("工作树已创建但元数据不匹配：" + destination.path) }
        let selection = store.selectedID, source = store.task(taskID)
        let id = store.create(title: (source?.title ?? "任务") + " · " + review.branch, workspace: destination.path, mode: source?.mode ?? .agent, workMode: source?.organizationMode)
        store.update(id) {
            $0.parentID = taskID; $0.permission = source?.permission ?? .workspace; $0.gitDirectory = directory.path
            $0.model = source?.model ?? ""; $0.modelOverride = source?.modelOverride; $0.agent = source?.agent; $0.agent?.workspace = destination.path; $0.team = source?.team
            $0.worktreeOrigin = AgentWorktreeOrigin(root: files.root.path, metadata: directory.path, path: destination.path)
        }
        store.selectedID = selection
        do {
            if let checkoutError { throw PetError(checkoutError) }
            if !review.patch.isEmpty {
                let patch = session.appendingPathComponent("carry.patch"); try Data(review.patch.utf8).write(to: patch, options: .atomic)
                _ = try await creationRun(["-C", destination.path, "apply", "--whitespace=nowarn", patch.path], session: session, protected: state.protected, writes: writes)
            }
            let actual = try await creationRun(["-C", destination.path, "symbolic-ref", "HEAD"], session: session, protected: state.protected)
            guard actual.trimmingCharacters(in: .whitespacesAndNewlines) == "refs/heads/" + review.branch else { throw PetError("新工作树分支不匹配") }
            let child = try AgentGit(store: store, taskID: id, directory: directory), childState = try await child.creationState()
            guard childState.head == review.baseCommit else { throw PetError("新工作树起点已被 Hook 改变") }
            if review.includeChanges {
                let verify = session.appendingPathComponent("verify-result")
                try FileManager.default.createDirectory(at: verify, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                guard try await child.currentWorkingTree(head: review.baseCommit, session: verify, protected: state.protected + childState.protected) == review.targetTree,
                      try await child.output(["diff", "--cached", "--name-only"]).isEmpty else { throw PetError("新工作树文件或暂存状态不符合预览，请检查实际状态") }
            } else if try await child.status().changes.isEmpty == false { throw PetError("Git Hook 改变了新工作树，请检查实际状态") }
            let finalSource = try await creationState()
            guard finalSource.head == state.head, finalSource.ref == state.ref, finalSource.index == state.index else { throw PetError("来源 Git 状态已变化") }
            store.update(id) { $0.events.append(AgentEvent(kind: "git", title: "已创建工作树", detail: review.summary + "\n" + destination.path, status: "completed")) }
            guard store.writeError == nil else { throw PetError("任务未保存：" + (store.writeError ?? "")) }
            return AgentGitWorktree(taskID: id, workspace: destination.path, branch: review.branch, baseCommit: review.baseCommit, includedChanges: review.includeChanges)
        } catch {
            store.update(id) { $0.status = .failed; $0.events.append(AgentEvent(kind: "git", title: "工作树需要检查", detail: error.localizedDescription, status: "failed")) }
            throw PetError("工作树已创建并保留，请检查：" + destination.path + "\n" + error.localizedDescription)
        }
    }
    private func ignoreAppWorktrees() throws {
        let metadata = try AgentFiles(workspace: directory.path), exclude = try metadata.resolve("info/exclude")
        let before = FileManager.default.fileExists(atPath: exclude.path) ? try metadata.readData(exclude, maximum: 1_000_000) : Data()
        guard let text = String(data: before, encoding: .utf8) else { throw PetError("Git 本地忽略文件不是 UTF-8") }
        let pattern = "/.bluefatfish/worktrees/"
        if !text.components(separatedBy: "\n").contains(pattern) {
            let current = FileManager.default.fileExists(atPath: exclude.path) ? try metadata.readData(exclude, maximum: 1_000_000) : Data()
            guard current == before else { throw PetError("Git 本地忽略配置已变化，请重试") }
            try metadata.writeData(Data((text + (text.hasSuffix("\n") || text.isEmpty ? "" : "\n") + pattern + "\n").utf8), to: exclude)
        }
    }
}
