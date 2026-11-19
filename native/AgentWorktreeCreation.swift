import Foundation
import Darwin

struct AgentWorktreeStart: Codable {
    var ref: String
    var title: String
    var commit: String
}
struct AgentWorkspaceWorktreeSetup: Codable, Equatable {
    var sourceTaskID: String
    var scope: String
    var folders: [String]
    var primary: String
    var branch: String
    var startPoints: [String: String]
    var includeChanges: Bool
}
struct AgentWorktreeRetainedReview: Codable {
    var origin: AgentWorktreeOrigin
    var fingerprint: String
    var status: AgentGitStatus
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
    var sources: [AgentWorktreeCreationReview]?
    var resumeTaskID: String?
    var retained: [AgentWorktreeRetainedReview]?
    var summary: String {
        if let sources {
            return "\(sources.count) 个待创建源文件夹" + ((retained?.isEmpty == false) ? " · 保留 \(retained!.count) 个已有源" : "") + "\n" + sources.map { URL(fileURLWithPath: $0.root).lastPathComponent + " · " + $0.branch + " · " + String($0.baseCommit.prefix(12)) }.joined(separator: "\n") + "\n" + (includeChanges ? "带入待创建源的当前修改，保持未暂存；忽略文件不带入。" : "使用各源选定的提交。")
        }
        return "新分支：" + branch + "\n起点：" + startPoint + " · " + String(baseCommit.prefix(12)) + "\n" +
        (includeChanges ? "带入 \(paths.count) 个文件的当前修改，保持未暂存；忽略文件不带入。" : "不带入当前未提交修改。")
    }
}

@MainActor extension AgentGit {
    private func creationScope() throws -> String {
        try validateWorkspace()
        guard let task = store.task(taskID), task.automation == nil, task.agent?.ownerID == nil,
              !["hook", "wiki"].contains(task.kind ?? "") else { throw PetError("请从独立任务创建工作树") }
        try store.agents.check(AgentToolCall(id: "create-worktree", name: "git_create_worktree", arguments: "{}"), task: task, store: store)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bindings = try encoder.encode(task.agent) + encoder.encode(task.team) + encoder.encode(task.inheritedLimits)
        return AgentFiles.hash(Data(([files.root.path, task.mode.rawValue, task.permission.rawValue, task.organizationWorkspace ?? ""] + task.workspacePaths).joined(separator: "\0").utf8) + bindings)
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
        let raw = try await output(["for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)", "refs/heads/", "refs/remotes/"])
        var result = [AgentWorktreeStart(ref: "HEAD", title: "当前提交", commit: head)]
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard parts.count == 3 else { throw PetError("分支列表格式无效") }
            let ref = String(parts[0])
            if ref.hasPrefix("refs/remotes/"), ref.hasSuffix("/HEAD"), !parts[2].isEmpty { continue }
            result.append(AgentWorktreeStart(ref: ref, title: ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : String(ref.dropFirst(13)), commit: String(parts[1])))
        }
        return result
    }
    func worktreeStartingPoint(_ value: String) async throws -> AgentWorktreeStart {
        let points = try await worktreeStartingPoints()
        if let exact = points.first(where: { $0.ref == value }) { return exact }
        let matches = points.filter { $0.title == value }
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
    func prepareWorktreeCreation(branch: String, startPoint: String = "HEAD", includeChanges: Bool = false, sourceStartPoints: [String: String] = [:], resumeTaskID: String? = nil, singleSource: Bool = false) async throws -> AgentWorktreeCreationReview {
        if !singleSource, let task = store.task(taskID), task.workspacePaths.count > 1 {
            return try await prepareWorkspaceWorktree(branch: branch, startPoint: startPoint, includeChanges: includeChanges, sourceStartPoints: sourceStartPoints, resumeTaskID: resumeTaskID)
        }
        let scope = try creationScope(), state = try await creationState()
        guard !branch.isEmpty, branch.utf8.count <= 200, !branch.hasPrefix("-"), !branch.contains("\0"),
              try await run(["check-ref-format", "--branch", branch]).exitCode == 0 else { throw PetError("分支名称无效") }
        guard try await run(["show-ref", "--verify", "--quiet", "refs/heads/" + branch]).exitCode == 1 else { throw PetError("新分支已存在，请更换名称") }
        let base = try await worktreeStartingPoint(startPoint), hash = UUID().uuidString, session = try creationDirectory(hash)
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
              try await worktreeStartingPoint(base.ref).commit == base.commit else { throw PetError("来源或起点已变化，请重新预览") }
        try saveCreation(review); return review
    }
    private func validateCreation(_ review: AgentWorktreeCreationReview) async throws -> (head: String, ref: String, index: String, protected: [URL]) {
        let scope = try creationScope(), state = try await creationState()
        guard scope == review.scope, state.head == review.sourceHead, state.ref == review.sourceRef, state.index == review.sourceIndex,
              try await worktreeStartingPoint(review.startPoint).commit == review.baseCommit else { throw PetError("分支、暂存区或任务范围已变化，请重新预览") }
        if review.includeChanges {
            let session = scratch.appendingPathComponent("worktree-verify-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: session) }
            guard try await currentWorkingTree(head: state.head, session: session, protected: state.protected) == review.sourceTree else { throw PetError("当前文件已变化，请重新预览") }
        }
        guard try await run(["show-ref", "--verify", "--quiet", "refs/heads/" + review.branch]).exitCode == 1 else { throw PetError("新分支已存在，请更换名称后重新预览") }
        try await validateHooks(); try Task.checkCancellation()
        return state
    }
    func createReviewedWorktree(_ hash: String, addingToTask: String? = nil) async throws -> AgentGitWorktree {
        lastCreatedWorktreeTaskID = nil
        var review = try storedWorktreeCreation(hash)
        if review.sources != nil { return try await createWorkspaceWorktree(review) }
        if let addingToTask {
            guard let target = store.task(addingToTask), target.parentID == taskID, target.worktreeSetup?.sourceTaskID == taskID, target.workspaceScope != nil,
                  !target.managedWorktreeOrigins.contains(where: { $0.root == files.root.path }) else { throw PetError("待完成的多源工作树任务已变化，请重新预览") }
        }
        let state = try await validateCreation(review)
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
        let id = addingToTask ?? store.create(title: (source?.title ?? "任务") + " · " + review.branch, workspace: destination.path, mode: source?.mode ?? .agent, workMode: source?.organizationMode)
        lastCreatedWorktreeTaskID = id
        let origin = AgentWorktreeOrigin(root: files.root.path, metadata: directory.path, path: destination.path)
        store.update(id) { record in
            if addingToTask != nil {
                record.worktreeOrigins = record.managedWorktreeOrigins + [origin]
                record.workspaceScope?.folders.append(destination.path)
            } else {
                record.parentID = taskID; record.permission = source?.permission ?? .workspace; record.gitDirectory = directory.path
                record.model = source?.model ?? ""; record.modelOverride = source?.modelOverride; record.agent = source?.agent; record.agent?.workspace = destination.path; record.team = source?.team
                record.inheritedLimits = source?.inheritedLimits; record.toolGroups = source?.toolGroups
                record.worktreeOrigin = origin
            }
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
            let child = try AgentGit(store: store, taskID: id, directory: directory, workspace: addingToTask == nil ? nil : destination.path), childState = try await child.creationState()
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
    private func workspaceSources() throws -> [String] {
        guard let task = store.task(taskID), let primary = task.workspace else { throw PetError("来源任务不可用") }
        _ = try AgentWorkspaceScope.roots(task)
        return [primary] + task.workspacePaths.filter { $0 != primary }
    }
    func worktreeDraftSources(resumeTaskID: String?) throws -> [AgentGitDraftRecovery.WorktreeForm.Source] {
        try validateWorkspace()
        let roots = try workspaceSources()
        if let resumeTaskID { _ = try resumeWorkspaceTask(resumeTaskID, roots: roots, scope: creationScope()) }
        return try roots.map { root in
            do { return try AgentGitDraftRecovery.WorktreeForm.Source.current(root) }
            catch { throw PetError("无法隔离源文件夹：" + root + "\n" + error.localizedDescription) }
        }
    }
    private func sourceHelper(_ root: String) throws -> AgentGit {
        do {
            let value = try AgentGit(store: store, taskID: taskID, directory: Self.metadata(workspace: root), workspace: root)
            workspaceWorktreeHelpers.append(value); return value
        } catch { throw PetError("无法隔离源文件夹：" + root + "\n" + error.localizedDescription) }
    }
    func workspaceWorktreeStartingPoints() async throws -> [(root: String, points: [AgentWorktreeStart])] {
        workspaceWorktreeHelpers = []; defer { workspaceWorktreeHelpers = [] }
        var result: [(String, [AgentWorktreeStart])] = []
        for root in try workspaceSources() {
            let helper = try sourceHelper(root)
            do { result.append((root, try await helper.worktreeStartingPoints())) }
            catch { throw PetError("无法隔离源文件夹：" + root + "\n" + error.localizedDescription) }
        }
        return result
    }
    private func resumeWorkspaceTask(_ id: String, roots: [String], scope: String) throws -> AgentTaskRecord {
        guard let source = store.task(taskID), let task = store.task(id), let setup = task.worktreeSetup,
              setup.sourceTaskID == taskID, setup.scope == scope, setup.folders == source.workspacePaths, setup.primary == source.workspace,
              task.parentID == taskID, !task.archived, task.workspaceScope?.group == source.organizationWorkspace,
              task.workspaceScope?.primary == task.workspace, task.workspace == task.worktreeOrigin?.path else { throw PetError("待完成的工作树范围已变化，或来源任务已不可用；已创建目录仍保留") }
        let origins = task.managedWorktreeOrigins
        guard !origins.isEmpty, origins.count <= roots.count, Set(origins.map(\.root)).count == origins.count,
              Set(origins.map(\.root)).isSubset(of: Set(roots)), Set(task.workspacePaths) == Set(origins.map(\.path)) else { throw PetError("待完成任务的工作树关联已变化") }
        for origin in origins {
            guard origin.path.hasPrefix(origin.root + "/.bluefatfish/worktrees/"), UUID(uuidString: URL(fileURLWithPath: origin.path).lastPathComponent) != nil,
                  try Self.metadata(workspace: origin.root).path == origin.metadata,
                  try AgentFiles(workspace: origin.path).root.path == origin.path,
                  try Self.metadata(workspace: origin.path).path == origin.metadata else { throw PetError("请先恢复或修复已保留的工作树：" + origin.path) }
        }
        return task
    }
    private func retainedReview(_ origin: AgentWorktreeOrigin, taskID id: String) async throws -> AgentWorktreeRetainedReview {
        let helper = try AgentGit(store: store, taskID: id, directory: URL(fileURLWithPath: origin.metadata), workspace: origin.path)
        workspaceWorktreeHelpers.append(helper)
        try helper.validateWorkspace()
        let status = try await helper.status(), path = origin.path
        let scan = Task.detached { try AgentWorktreeSnapshot.read(URL(fileURLWithPath: path)) }
        let tree = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
        let raw = try await helper.output(["rev-parse", "--git-path", "index"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let index = URL(fileURLWithPath: raw, relativeTo: helper.files.root.appendingPathComponent("", isDirectory: true)).standardizedFileURL
        let indexHash = try AgentFiles.hash(AgentFiles(workspace: origin.metadata).readData(index, maximum: 32_000_000))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let fingerprint = AgentFiles.hash(try encoder.encode(status) + Data((tree.hash + indexHash + origin.path + origin.metadata).utf8))
        return AgentWorktreeRetainedReview(origin: origin, fingerprint: fingerprint, status: status)
    }
    private func prepareWorkspaceWorktree(branch: String, startPoint: String, includeChanges: Bool, sourceStartPoints: [String: String], resumeTaskID: String?) async throws -> AgentWorktreeCreationReview {
        let roots = try workspaceSources(), scope = try creationScope()
        guard Set(sourceStartPoints.keys).isSubset(of: Set(roots)) else { throw PetError("起点分支包含不属于当前任务的源目录") }
        workspaceWorktreeHelpers = []; defer { workspaceWorktreeHelpers = [] }
        let previous = try resumeTaskID.map { try resumeWorkspaceTask($0, roots: roots, scope: scope) }
        guard previous?.worktreeSetup?.branch == nil || previous?.worktreeSetup?.branch == branch else { throw PetError("继续创建时保留原分支名称；可调整尚未创建源的起点") }
        let origins = previous?.managedWorktreeOrigins ?? []
        var retained: [AgentWorktreeRetainedReview] = [], reviews: [AgentWorktreeCreationReview] = []
        for (index, root) in roots.enumerated() {
            if let origin = origins.first(where: { $0.root == root }), let resumeTaskID {
                retained.append(try await retainedReview(origin, taskID: resumeTaskID)); continue
            }
            let helper = try sourceHelper(root)
            var name = branch + (index == 0 ? "" : "-\(index + 1)")
            if resumeTaskID != nil, try await helper.run(["show-ref", "--verify", "--quiet", "refs/heads/" + name]).exitCode == 0 {
                while name.utf8.count > 180 { name.removeLast() }
                name += "-retry-" + String(UUID().uuidString.lowercased().prefix(8))
            }
            reviews.append(try await helper.prepareWorktreeCreation(branch: name, startPoint: sourceStartPoints[root] ?? (index == 0 ? startPoint : "HEAD"), includeChanges: includeChanges, singleSource: true))
        }
        guard try creationScope() == scope else { throw PetError("来源范围已变化，请重新预览") }
        var review = reviews.first ?? AgentWorktreeCreationReview(taskID: taskID, root: files.root.path, scope: scope, branch: branch, startPoint: startPoint, baseCommit: "", sourceHead: "", sourceRef: "", sourceIndex: "", includeChanges: includeChanges, targetTree: "", paths: [], patch: "")
        review.hash = UUID().uuidString; review.root = files.root.path; review.scope = scope; review.branch = branch
        review.startPoint = sourceStartPoints[roots[0]] ?? startPoint
        if let primary = retained.first(where: { $0.origin.root == roots[0] }) { review.baseCommit = primary.status.head ?? "" }
        review.sources = reviews; review.resumeTaskID = resumeTaskID; review.retained = retained
        review.paths = reviews.flatMap { item in item.paths.map { item.root + "/" + $0 } }
        review.patch = reviews.map { "源文件夹：" + $0.root + "\n新分支：" + $0.branch + "\n起点：" + $0.startPoint + " · " + $0.baseCommit + "\n" + $0.patch }.joined(separator: "\n\n")
        for item in retained { review.patch += "\n已保留源：" + item.origin.root + "\n工作树：" + item.origin.path + "\n分支：" + item.status.branch + "\n提交：" + (item.status.head ?? "") + "\n" + item.status.changes.map { $0.status + " " + $0.path }.joined(separator: "\n") + "\n" }
        try saveCreation(review); return review
    }
    private func createWorkspaceWorktree(_ initial: AgentWorktreeCreationReview) async throws -> AgentGitWorktree {
        guard let sources = initial.sources, sources.count + (initial.retained?.count ?? 0) <= 16 else { throw PetError("多源工作树审阅无效") }
        let roots = try workspaceSources(), scope = try creationScope()
        guard initial.scope == scope, Set(sources.map(\.root) + (initial.retained ?? []).map { $0.origin.root }) == Set(roots), Set(sources.map(\.root)).count == sources.count else { throw PetError("来源范围已变化，请重新预览") }
        workspaceWorktreeHelpers = []; defer { workspaceWorktreeHelpers = [] }
        var targetID = initial.resumeTaskID
        if let targetID { _ = try resumeWorkspaceTask(targetID, roots: roots, scope: scope) }
        var helpers: [String: AgentGit] = [:]
        for source in sources {
            let helper = try sourceHelper(source.root), stored = try helper.storedWorktreeCreation(source.hash)
            guard stored.sources == nil, stored.branch == source.branch, stored.baseCommit == source.baseCommit else { throw PetError("源文件夹审阅已变化，请重新预览") }
            _ = try await helper.validateCreation(stored); helpers[source.root] = helper
        }
        for retained in initial.retained ?? [] {
            guard let targetID, try await retainedReview(retained.origin, taskID: targetID).fingerprint == retained.fingerprint else { throw PetError("已保留工作树内容已变化，请重新预览") }
        }
        var review = initial; review.consumed = true; try saveCreation(review)
        guard let sourceTask = store.task(taskID), let primary = sourceTask.workspace else { throw PetError("来源任务不可用") }
        var starts = targetID.flatMap { store.task($0)?.worktreeSetup?.startPoints } ?? [:]
        for source in sources { starts[source.root] = source.startPoint }
        let setup = AgentWorkspaceWorktreeSetup(sourceTaskID: taskID, scope: scope, folders: sourceTask.workspacePaths, primary: primary, branch: review.branch, startPoints: starts, includeChanges: review.includeChanges)
        let owner = UUID()
        func bind(_ id: String) {
            store.update(id) { task in
                task.worktreeSetup = setup; task.status = .failed
                let origins = task.managedWorktreeOrigins; task.worktreeOrigins = origins
                if let primary = task.worktreeOrigin?.path { task.workspaceScope = AgentWorkspaceScope(group: sourceTask.organizationWorkspace!, folders: origins.map(\.path), primary: primary) }
            }
            store.worktreeRetention.setNativeOperation(owner, taskID: id, busy: true)
        }
        if let targetID { bind(targetID) }
        defer { if let targetID { store.worktreeRetention.setNativeOperation(owner, taskID: targetID, busy: false) } }
        do {
            for source in sources {
                guard let helper = helpers[source.root] else { throw PetError("源审阅不可用") }
                do {
                    let result = try await helper.createReviewedWorktree(source.hash, addingToTask: targetID)
                    targetID = result.taskID; lastCreatedWorktreeTaskID = result.taskID; bind(result.taskID)
                } catch {
                    if let id = helper.lastCreatedWorktreeTaskID { targetID = id; lastCreatedWorktreeTaskID = id; bind(id) }
                    throw error
                }
            }
            guard let targetID, let child = store.task(targetID), child.managedWorktreeOrigins.count == roots.count, try creationScope() == scope else { throw PetError("创建结果或原任务范围已变化") }
            for retained in initial.retained ?? [] {
                guard try await retainedReview(retained.origin, taskID: targetID).fingerprint == retained.fingerprint else { throw PetError("已保留工作树在创建期间变化，请重新预览") }
            }
            let origins = child.managedWorktreeOrigins
            let ordered = try sourceTask.workspacePaths.map { root -> String in guard let origin = origins.first(where: { $0.root == root }) else { throw PetError("工作树源不完整") }; return origin.path }
            store.update(targetID) { task in
                task.workspaceScope?.folders = ordered; task.worktreeSetup = nil; task.status = .ready
                task.events.append(AgentEvent(kind: "git", title: "已创建多源工作树", detail: origins.map { $0.root + "\n→ " + $0.path }.joined(separator: "\n"), status: "completed"))
            }
            guard store.writeError == nil else { throw PetError(store.writeError!) }
            return AgentGitWorktree(taskID: targetID, workspace: child.workspace!, branch: review.branch, baseCommit: review.baseCommit, includedChanges: review.includeChanges, sources: origins)
        } catch {
            if let targetID {
                bind(targetID)
                store.update(targetID) { $0.events.append(AgentEvent(kind: "git", title: "多源工作树尚未完成", detail: error.localizedDescription + "\n已创建的目录保留，可重新预览后继续创建。", status: "failed")) }
                throw PetError("多源工作树尚未完成，已保留任务与目录：" + targetID + "\n" + error.localizedDescription)
            }
            throw error
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
