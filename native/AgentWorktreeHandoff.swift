import Foundation
import Darwin

struct AgentWorktreeHandoffReview {
    enum Change: Int, CaseIterable {
        case commits, staged, working
        var title: String { ["提交", "已暂存", "未暂存"][rawValue] }
    }
    struct Checkout: Codable, Equatable {
        let root: String
        let identity: String
        let metadata: String
        let metadataIdentity: String
        let head: String
        let branch: String?
        let indexHash: String
        var name: String { branch.map { String($0.dropFirst("refs/heads/".count)) } ?? "分离状态" }
    }
    struct Source: Codable, Equatable {
        let origin: AgentWorktreeOrigin
        let from: Checkout
        let to: Checkout
        let sourceIndexTree: String
        let sourceWorkingTree: String
        let appliedHead: String?
        let committedTree: String
        let indexTree: String
        let workingTree: String
    }
    struct Plan {
        let source: Source
        let directory: URL
        let commits: String
        let patches: [String]
        var hasChanges: Bool {
            source.appliedHead != source.to.head || source.committedTree != source.indexTree || source.indexTree != source.workingTree
        }
    }
    let taskVersion: String
    let directory: URL
    let plans: [Plan]
}

@MainActor final class AgentWorktreeHandoff {
    private typealias Checkout = AgentWorktreeHandoffReview.Checkout
    private typealias Plan = AgentWorktreeHandoffReview.Plan
    fileprivate struct Journal: Codable, Equatable {
        struct Project: Codable, Equatable {
            let source: AgentWorktreeHandoffReview.Source
            let head: String
            let indexHash: String
            let patchHash: String
        }
        var version = 1
        let taskID: String
        let localTaskID: String
        let eventID: String
        let projects: [Project]
    }
    struct Recovery: Equatable {
        fileprivate let directory: URL
        fileprivate let journal: Journal
        let published: Bool
        let localTaskID: String?
        var paths: [String] { journal.projects.map(\.source.to.root) }
    }
    private let store: AgentStore
    private let taskID: String
    private var applying = false
    private var confirmed = false
    private var lease: AgentWorktreeLease?

    init(store: AgentStore, taskID: String) {
        self.store = store
        self.taskID = taskID
    }

    private func task() throws -> (AgentTaskRecord, [AgentWorktreeOrigin]) {
        guard let task = store.task(taskID), task.canStartFreshSession,
              store.archiveIsBusy?(taskID) != true, !store.hooks.isRunning(taskID),
              !task.managedWorktreeOrigins.isEmpty else { throw PetError("请从已停止且可用的工作树任务移交") }
        let origins = try task.workspacePaths.map { path in
            guard let origin = task.managedWorktreeOrigins.first(where: { $0.path == path }) else { throw PetError("任务缺少工作树来源，无法确认本地目录") }
            return origin
        }
        guard Set(origins.map(\.path)).count == task.managedWorktreeOrigins.count, let main = origins.first(where: { $0.path == task.workspace }),
              try AgentWorkspaceScope.validateFolders(origins.map(\.root), primary: main.root) == origins.map(\.root) else {
            throw PetError("本地工作区范围已变化")
        }
        try store.agents.check(.init(id: "worktree-handoff", name: "git_commit", arguments: "{}"), task: task, store: store)
        for origin in origins {
            guard !store.projectChanges.isObserving(origin.root), !store.projectChanges.isObserving(origin.path),
                  !store.hasFileRollback(in: origin.root), store.organization.archiveID(task.organizationWorkspace, mode: task.organizationMode) == nil else {
                throw PetError("请先结束本地工作区的文件操作，或恢复已归档的工作区")
            }
        }
        let roots = origins.flatMap { [$0.root, $0.path] }
        guard !store.tasks.contains(where: { record in
            record.id != taskID && ([.running, .waiting].contains(record.status) || record.pendingFileCapture != nil || store.hooks.isRunning(record.id))
                && record.workspacePaths.contains { path in roots.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") } }
        }) else { throw PetError("相关工作区还有任务正在执行或等待处理") }
        return (task, origins)
    }

    private func git(_ arguments: [String], origin: AgentWorktreeOrigin, root: String, session: URL, index: String? = nil,
                     write: Bool = false, inspect: Bool = false, timeout: Double = 45) async throws -> AgentToolResult {
        let checkoutProtection = [origin.path == root ? origin.root : origin.path].filter { protected in
            // A checkout can live inside its parent project. In that direction the
            // source is already read-only, so a parent-wide deny would also block objects.
            !root.hasPrefix(protected + "/")
        }
        let objectsOnly = ["index", "index.lock", "HEAD", "logs", "refs", "packed-refs", "worktrees", "config", "config.worktree"]
        let protected = checkoutProtection.map { URL(fileURLWithPath: $0) } + (arguments.first == "update-ref" ? [] :
            objectsOnly.map { URL(fileURLWithPath: origin.metadata).appendingPathComponent($0) })
        let result = try await AgentCommand().run(command: try AgentGit.executablePath(), workspace: URL(fileURLWithPath: root),
            scratch: session, network: false, timeout: timeout, readOnly: true,
            gitDirectory: URL(fileURLWithPath: origin.metadata), gitWrite: true, gitConfiguration: true,
            maximumOutput: 2_000_000, protectedData: store.directory.deletingLastPathComponent(),
            writeRoots: write ? [URL(fileURLWithPath: root)] : [], protectedWrites: protected,
            environment: index.map { ["GIT_INDEX_FILE": session.appendingPathComponent($0).path] } ?? [:],
            arguments: ["--no-pager", "--literal-pathspecs", "-c", "core.fsmonitor=false", "-c", "core.splitIndex=false",
                        "-c", "core.hooksPath=/dev/null", "-c", "core.quotePath=true"] + arguments,
            leaseDescriptor: lease?.descriptor)
        guard result.truncated != true else { throw PetError("移交内容过大，请缩小本次改动后重试") }
        if !inspect, result.failed { throw PetError(result.text) }
        return result
    }

    private func line(_ result: AgentToolResult) throws -> String {
        guard let raw = result.stdout, raw.hasSuffix("\n") else { throw PetError("Git 未返回可核对的结果") }
        return String(raw.dropLast())
    }

    private func oid(_ result: AgentToolResult) throws -> String {
        let value = try line(result)
        guard [40, 64].contains(value.count), value.allSatisfy(\.isHexDigit) else { throw PetError("Git 对象无法确认") }
        return value
    }

    private func directoryIdentity(_ path: String) throws -> String {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw PetError("目录已移动或变更：" + path) }
        return "\(info.st_dev):\(info.st_ino)"
    }

    private func checkout(_ origin: AgentWorktreeOrigin, source: Bool, session: URL, holdingIndex: Bool = false,
                          requireClean: Bool = true) async throws -> Checkout {
        let root = source ? origin.path : origin.root
        guard try AgentFiles(workspace: root).root.path == root, try AgentGit.metadata(workspace: root).path == origin.metadata else {
            throw PetError("两处检出已不属于原 Git 仓库：" + root)
        }
        func read(_ args: [String], inspect: Bool = false) async throws -> AgentToolResult {
            try await git(args, origin: origin, root: root, session: session, inspect: inspect)
        }
        guard try await line(read(["rev-parse", "--show-toplevel"])) == root else { throw PetError("请选择实际 Git 检出目录") }
        let metadata = try await line(read(["rev-parse", "--absolute-git-dir"]))
        guard metadata == origin.metadata || URL(fileURLWithPath: metadata).deletingLastPathComponent().path == origin.metadata + "/worktrees",
              !source || metadata != origin.metadata else { throw PetError("Git 工作树登记已变化") }
        let admin = try AgentFiles(workspace: metadata, followParentLinks: false)
        for name in ["index.lock", "HEAD.lock", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer"]
            where name != "index.lock" || !holdingIndex {
            guard try admin.entryMetadata(admin.literalURL(name)).kind == "missing" else { throw PetError("请先结束当前 Git 操作：" + root) }
        }
        let sparse = try await read(["config", "--bool", "core.sparseCheckout"], inspect: true)
        guard sparse.stdout?.trimmingCharacters(in: .newlines) != "true" else { throw PetError("请先在完整检出中移交：" + root) }
        let ref = try await read(["symbolic-ref", "--quiet", "HEAD"], inspect: true)
        let branch = ref.failed ? nil : try line(ref)
        guard branch?.hasPrefix("refs/heads/") == true || source && branch == nil else { throw PetError("请在本地检出一个分支后移交：" + root) }
        let head = try await oid(read(["rev-parse", "--verify", "HEAD^{commit}"]))
        if !source, requireClean {
            let status = try await read(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none"])
            guard (status.stdoutData ?? Data()).isEmpty else { throw PetError("本地工作区有改动，请先处理后再移交：" + root) }
        }
        return Checkout(root: root, identity: try directoryIdentity(root), metadata: metadata,
                        metadataIdentity: try directoryIdentity(metadata), head: head, branch: branch,
                        indexHash: try admin.fileHash(admin.literalURL("index"), maximum: 32_000_000))
    }

    private func prepare(_ origin: AgentWorktreeOrigin, session: URL) async throws -> Plan {
        let from = try await checkout(origin, source: true, session: session)
        let to = try await checkout(origin, source: false, session: session)
        guard from.branch != to.branch else { throw PetError("两处检出使用同一分支，请先为工作树选择独立分支") }
        func local(_ args: [String], index: String? = nil, inspect: Bool = false) async throws -> AgentToolResult {
            try await git(args, origin: origin, root: to.root, session: session, index: index, inspect: inspect)
        }
        func difference(_ a: String, _ b: String) async throws -> Data {
            let raw = try await local(["diff", "--raw", "--no-renames", a, b, "--"])
            guard !(raw.stdout ?? "").split(separator: "\n").contains(where: { row in
                row.split(separator: " ").prefix(2).contains { $0 == ":160000" || $0 == "160000" }
            }) else { throw PetError("移交涉及子模块，请先在 Git 中处理：" + to.root) }
            let result = try await local(["diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", "--no-color", a, b, "--"])
            return result.stdoutData ?? Data()
        }
        func layer(_ patch: Data, name: String) async throws -> String {
            if !patch.isEmpty {
                let file = session.appendingPathComponent(name)
                try patch.write(to: file, options: .atomic)
                let result = try await local(["apply", "--cached", "--3way", "--whitespace=nowarn", file.path], index: "composed.index", inspect: true)
                guard !result.failed else { throw PetError("本地与工作树的\(name == "staged.patch" ? "暂存" : "未暂存")改动有冲突：\n" + result.text) }
            }
            return try await oid(local(["write-tree"], index: "composed.index"))
        }
        let (staged, working) = try await sourceTrees(origin, from: from, session: session)
        let forward = try await local(["merge-base", "--is-ancestor", to.head, from.head], inspect: true)
        let included = try await local(["merge-base", "--is-ancestor", from.head, to.head], inspect: true)
        guard [0, 1].contains(forward.exitCode ?? -1), [0, 1].contains(included.exitCode ?? -1) else { throw PetError("无法比较两边的 Git 历史") }
        let head = !forward.failed ? from.head : !included.failed ? to.head : nil
        let merged: String
        if let head { merged = try await oid(local(["rev-parse", head + "^{tree}"])) }
        else {
            let result = try await local(["merge-tree", "--write-tree", to.head, from.head], inspect: true)
            guard !result.failed else { throw PetError("两边的提交无法自动合并：\n" + result.text) }
            merged = try oid(result)
        }
        _ = try await local(["read-tree", merged], index: "composed.index")
        let targetStage = try await layer(try await difference(from.head, staged), name: "staged.patch")
        let targetWorking = try await layer(try await difference(staged, working), name: "working.patch")
        let delta = try await difference(to.head, targetWorking)
        let transfer = session.appendingPathComponent("transfer.patch")
        try delta.write(to: transfer, options: .atomic)
        try saveIndex(to, to: session.appendingPathComponent("before.index"))
        try saveIndex(to, to: session.appendingPathComponent("apply.index"))
        if !delta.isEmpty {
            // Clean files can still have an older stat cache after Git or rollback
            // rewrites them. Refresh only the private index used by git apply.
            _ = try await local(["update-index", "--refresh"], index: "apply.index")
            let checked = try await local(["apply", "--index", "--check", transfer.path], index: "apply.index", inspect: true)
            guard !checked.failed else { throw PetError("本地文件无法安全移交：\n" + checked.text) }
        }
        _ = try await local(["read-tree", targetStage], index: "final.index")
        guard try await checkout(origin, source: true, session: session) == from,
              try await checkout(origin, source: false, session: session) == to else { throw PetError("审阅期间两边的 Git 状态已变化") }
        let log = try await local(["log", "--format=%h %s", to.head + ".." + from.head])
        let patches = [String(decoding: try await difference(to.head, merged), as: UTF8.self),
                       String(decoding: try await difference(merged, targetStage), as: UTF8.self),
                       String(decoding: try await difference(targetStage, targetWorking), as: UTF8.self)]
        return Plan(source: .init(origin: origin, from: from, to: to, sourceIndexTree: staged, sourceWorkingTree: working,
                                  appliedHead: head, committedTree: merged, indexTree: targetStage, workingTree: targetWorking),
                    directory: session, commits: log.stdout ?? "", patches: patches)
    }

    func prepare() async throws -> AgentWorktreeHandoffReview {
        guard try pendingRecovery() == nil else { throw PetError("请先处理上次中断的移交") }
        let (_, origins) = try task()
        let version = try store.recordVersion(taskID)
        let folder = try history().appendingPathComponent(UUID().uuidString, isDirectory: true)
        var plans: [Plan] = []
        do {
            for (index, origin) in origins.enumerated() {
                let session = folder.appendingPathComponent(String(index), isDirectory: true)
                try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                plans.append(try await prepare(origin, session: session))
            }
            guard try task().1 == origins, try store.recordVersion(taskID) == version else { throw PetError("原任务或目录已变化，请重新审阅") }
            return .init(taskVersion: version, directory: folder, plans: plans)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func discard(_ review: AgentWorktreeHandoffReview) {
        // An operation which has started writing retains its journal for readback.
        if !FileManager.default.fileExists(atPath: review.directory.appendingPathComponent("journal.json").path) {
            try? FileManager.default.removeItem(at: review.directory)
        }
    }

    private func saveIndex(_ checkout: Checkout, to destination: URL) throws {
        let files = try AgentFiles(workspace: checkout.metadata, followParentLinks: false)
        let data = try files.readData(files.literalURL("index"), maximum: 32_000_000)
        guard AgentFiles.hash(data) == checkout.indexHash else { throw PetError("暂存区已变化，请重新审阅") }
        try data.write(to: destination, options: .atomic)
    }

    private func sourceTrees(_ origin: AgentWorktreeOrigin, from: Checkout, session: URL) async throws -> (String, String) {
        let name = "source.index"
        try saveIndex(from, to: session.appendingPathComponent(name))
        func active(_ args: [String]) async throws -> AgentToolResult {
            try await git(args, origin: origin, root: from.root, session: session, index: name)
        }
        let staged = try await oid(active(["write-tree"]))
        _ = try await active(["add", "--all", "--", "."])
        return (staged, try await oid(active(["write-tree"])))
    }

    private func applyGit(_ args: [String], plan: Plan, index: String? = nil, write: Bool = false, inspect: Bool = false) async throws -> AgentToolResult {
        try await git(args, origin: plan.source.origin, root: plan.source.to.root, session: plan.directory, index: index, write: write, inspect: inspect)
    }

    private func targetHead(_ plan: Plan) async throws -> String {
        let source = plan.source
        if let head = source.appliedHead { return head }
        let signing = try await applyGit(["config", "--bool", "commit.gpgSign"], plan: plan, inspect: true)
        guard [0, 1].contains(signing.exitCode ?? -1) else { throw PetError("无法读取仓库提交签名设置") }
        let flags = signing.stdout?.trimmingCharacters(in: .newlines) == "true" ? ["-S"] : []
        return try await oid(applyGit(["commit-tree", source.committedTree, "-p", source.to.head, "-p", source.from.head]
                                      + flags + ["-m", "Merge worktree " + String(source.from.head.prefix(12))], plan: plan))
    }

    private func installIndex(_ name: String, plan: Plan, expected: String) throws -> String {
        guard try directoryIdentity(plan.source.to.metadata) == plan.source.to.metadataIdentity else {
            throw PetError("本地暂存目录已变化")
        }
        let admin = try AgentFiles(workspace: plan.source.to.metadata, followParentLinks: false)
        let url = try admin.literalURL("index")
        let entry = try admin.entryMetadata(url)
        guard entry.kind == "file", let permissions = entry.permissions,
              try admin.fileHash(url, maximum: 32_000_000) == expected else { throw PetError("本地暂存区已变化：" + plan.source.to.root) }
        let data = try Data(contentsOf: plan.directory.appendingPathComponent(name))
        try admin.writeData(data, to: url, permissions: permissions, expectedTarget: entry.signature)
        return AgentFiles.hash(data)
    }

    private func referenceMatches(_ plan: Plan, head: String) async throws -> Bool {
        guard try directoryIdentity(plan.source.to.root) == plan.source.to.identity,
              try directoryIdentity(plan.source.to.metadata) == plan.source.to.metadataIdentity else { return false }
        let branch = try await applyGit(["symbolic-ref", "--quiet", "HEAD"], plan: plan, inspect: true)
        guard !branch.failed, try line(branch) == plan.source.to.branch else { return false }
        return try await oid(applyGit(["rev-parse", "--verify", "HEAD"], plan: plan)) == head
    }

    private func updateRef(_ plan: Plan, from old: String, to new: String) async throws {
        guard let branch = plan.source.to.branch, try await referenceMatches(plan, head: old) else { throw PetError("本地分支已变化：" + plan.source.to.root) }
        if old != new { _ = try await applyGit(["update-ref", "-m", "Worktree handoff", branch, new, old], plan: plan) }
    }

    private func continuation(_ source: AgentTaskRecord, review: AgentWorktreeHandoffReview, heads: [String]) throws -> AgentTaskRecord {
        let roots = review.plans.map { $0.source.origin }
        guard let primary = roots.first(where: { $0.path == source.workspace }) else { throw PetError("无法确认本地任务的主文件夹") }
        let scope = source.workspaceScope.map { AgentWorkspaceScope(group: $0.group, folders: roots.map(\.root), primary: primary.root) }
        var task = AgentTaskRecord(title: String(source.title.prefix(112)) + " · 本地", workspace: primary.root, workspaceScope: scope, mode: source.mode)
        task.parentID = taskID; task.workMode = source.workMode; task.permission = source.permission
        task.model = source.model; task.modelOverride = source.modelOverride; task.toolGroups = source.toolGroups
        task.inheritedLimits = source.inheritedLimits; task.agent = source.agent; task.agent?.workspace = primary.root; task.team = source.team
        task.draft = source.draft
        let ids = source.draftAttachmentIDs ?? []
        task.attachments = (source.attachments ?? []).filter { ids.contains($0.id) }
        task.draftAttachmentIDs = task.attachments?.map(\.id)
        let changes = zip(roots, heads).map { $0.0.root + " · " + String($0.1.prefix(12)) }.joined(separator: "\n")
        task.events.append(.init(kind: "git", title: "已移交到本地", detail: changes, status: "completed"))
        return task
    }

    private func history(create: Bool = false) throws -> URL {
        guard UUID(uuidString: taskID) != nil else { throw PetError("任务标识无效") }
        let path = store.directory.appendingPathComponent(taskID + "/checkpoints/worktree-handoff", isDirectory: true)
        if create { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        return path
    }

    private func savedContinuation(_ journal: Journal) throws -> (published: Bool, taskID: String?) {
        guard store.refreshDeletedRecords() else { throw PetError("任务记录暂不可用，请重新载入后再处理移交") }
        if store.deletions.taskIDs.contains(journal.localTaskID) { return (true, nil) }
        let files = try AgentFiles(workspace: store.directory.path, followParentLinks: false)
        let file = try files.literalURL(journal.localTaskID + ".json")
        if try files.entryMetadata(file).kind == "missing" { return (false, nil) }
        let data = try files.readData(file, maximum: 20_000_000)
        guard let task = try? JSONDecoder().decode(AgentTaskRecord.self, from: data), task.id == journal.localTaskID,
              task.parentID == taskID, task.events.contains(where: { $0.id == journal.eventID && $0.kind == "git" && $0.status == "completed" }) else {
            throw PetError("本地延续任务与移交记录不一致，请先核对任务记录")
        }
        return (true, task.id)
    }

    func pendingRecovery() throws -> Recovery? {
        let root = try history()
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var pending: Recovery?
        for directory in directories where UUID(uuidString: directory.lastPathComponent) != nil {
            let url = directory.appendingPathComponent("journal.json")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let files = try AgentFiles(workspace: directory.path, followParentLinks: false)
            guard files.root.path == directory.path else { throw PetError("移交记录目录已变化") }
            let outcome = try files.literalURL("outcome")
            if try files.entryMetadata(outcome).kind == "file" {
                let status = String(decoding: try files.readData(outcome, maximum: 2_000_000), as: UTF8.self)
                if status.hasPrefix("completed\n") || status.hasPrefix("restored\n") || status.hasPrefix("已恢复本次写入。\n") { continue }
            }
            let bytes = try files.readData(url, maximum: 4_000_000)
            guard let journal = try? JSONDecoder().decode(Journal.self, from: bytes), journal.version == 1,
                  journal.taskID == taskID, UUID(uuidString: journal.localTaskID) != nil, journal.localTaskID != taskID,
                  UUID(uuidString: journal.eventID) != nil, !journal.projects.isEmpty,
                  Set(journal.projects.map(\.source.to.metadata)).count == journal.projects.count else {
                throw PetError("这笔移交的恢复记录不可用，请在 Git 中核对目录和锁。\n" + directory.path)
            }
            guard pending == nil else { throw PetError("发现多笔未完成的移交，请核对移交记录。\n" + root.path) }
            let continuation = try savedContinuation(journal)
            pending = .init(directory: directory, journal: journal, published: continuation.published, localTaskID: continuation.taskID)
        }
        return pending
    }

    private func artifactHashes(_ plan: Plan) throws -> (index: String, patch: String) {
        let files = try AgentFiles(workspace: plan.directory.path, followParentLinks: false)
        guard files.root.path == plan.directory.path,
              try files.fileHash(files.literalURL("before.index"), maximum: 32_000_000) == plan.source.to.indexHash else {
            throw PetError("原暂存区备份无法核对：" + plan.source.to.root)
        }
        return (try files.fileHash(files.literalURL("final.index"), maximum: 32_000_000),
                try files.fileHash(files.literalURL("transfer.patch"), maximum: 2_000_000))
    }

    private func lock(_ plan: Plan, operation: String, mode: AgentWorktreeIndexLock.Mode) throws -> AgentWorktreeIndexLock? {
        guard try directoryIdentity(plan.source.to.root) == plan.source.to.identity,
              try directoryIdentity(plan.source.to.metadata) == plan.source.to.metadataIdentity else {
            throw PetError("本地目录已变化：" + plan.source.to.root)
        }
        return try AgentWorktreeIndexLock(metadata: plan.source.to.metadata, operation: operation, mode: mode)
    }

    private func finish(_ directory: URL, locks: [AgentWorktreeIndexLock], outcome: String) throws {
        for lock in locks { try lock.release() }
        try Data(outcome.utf8).write(to: directory.appendingPathComponent("outcome"), options: .atomic)
    }

    func apply(_ reviewed: AgentWorktreeHandoffReview) async throws -> String {
        guard !applying, !confirmed else { throw PetError("此移交已处理") }
        applying = true; defer { applying = false }
        lease = try AgentWorktreeLease(in: history(create: true)); defer { lease = nil }
        let repeated = try await prepare()
        defer { discard(repeated) }
        guard reviewed.taskVersion == repeated.taskVersion, reviewed.plans.map(\.source) == repeated.plans.map(\.source) else {
            throw PetError("来源、本地分支或改动已变化，请重新审阅")
        }
        let (original, _) = try task()
        let plans = repeated.plans
        let owner = UUID()
        store.worktreeRetention.setNativeOperation(owner, taskID: taskID, busy: true)
        defer { store.worktreeRetention.setNativeOperation(owner, taskID: taskID, busy: false) }
        var projects: [Journal.Project] = []
        for plan in plans {
            let head = try await targetHead(plan), hashes = try artifactHashes(plan)
            projects.append(.init(source: plan.source, head: head, indexHash: hashes.index, patchHash: hashes.patch))
        }
        guard try store.recordVersion(taskID) == repeated.taskVersion else { throw PetError("原任务已变化，请重新审阅") }
        let heads = projects.map(\.head)
        let task = try continuation(original, review: repeated, heads: heads)
        guard let eventID = task.events.last?.id else { throw PetError("缺少本地移交记录") }
        let journal = Journal(taskID: taskID, localTaskID: task.id, eventID: eventID, projects: projects)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(to: repeated.directory.appendingPathComponent("journal.json"), options: .atomic)
        let operation = repeated.directory.lastPathComponent
        var locks: [AgentWorktreeIndexLock] = []
        defer { for lock in locks { try? lock.release() } }
        var mayHaveWritten = false
        do {
            for plan in plans {
                if let value = try lock(plan, operation: operation, mode: .new) { locks.append(value) }
            }
            if let files = task.attachments, !files.isEmpty {
                try AgentAttachments.copyForFork(store: store, sourceID: taskID, targetID: task.id, files: files)
            }
            for (i, plan) in plans.enumerated() where plan.hasChanges {
                try Task.checkCancellation()
                guard try await checkout(plan.source.origin, source: true, session: plan.directory) == plan.source.from,
                      try await checkout(plan.source.origin, source: false, session: plan.directory, holdingIndex: true) == plan.source.to else {
                    throw PetError("两边工作区已变化，请重新审阅")
                }
                let (staged, working) = try await sourceTrees(plan.source.origin, from: plan.source.from, session: plan.directory)
                guard staged == plan.source.sourceIndexTree, working == plan.source.sourceWorkingTree else { throw PetError("工作树文件已变化，请重新审阅") }
                let patch = plan.directory.appendingPathComponent("transfer.patch")
                guard locks[i].holdsIndex, try await referenceMatches(plan, head: plan.source.to.head) else { throw PetError("本地分支或移交锁已变化：" + plan.source.to.root) }
                mayHaveWritten = true
                if !(try Data(contentsOf: patch)).isEmpty {
                    _ = try await applyGit(["update-index", "--refresh"], plan: plan, index: "apply.index")
                    _ = try await applyGit(["apply", "--index", "--whitespace=nowarn", patch.path], plan: plan, index: "apply.index", write: true)
                }
                guard try await oid(applyGit(["write-tree"], plan: plan, index: "apply.index")) == plan.source.workingTree else {
                    throw PetError("实际写入与审阅的工作文件不一致")
                }
                guard locks[i].holdsIndex else { throw PetError("移交锁已变化：" + plan.source.to.root) }
                _ = try installIndex("final.index", plan: plan, expected: plan.source.to.indexHash)
                try await updateRef(plan, from: plan.source.to.head, to: heads[i])
                guard try await referenceMatches(plan, head: heads[i]) else { throw PetError("移交后的本地分支无法核对") }
            }
            try store.installRelatedRecord(task, sourceID: taskID, expectedHash: repeated.taskVersion, label: "移交到本地")
        } catch {
            let failure = error.localizedDescription
            do {
                guard try !savedContinuation(journal).published else { throw PetError("本地延续任务已保存，请重新打开移交核对。") }
                if mayHaveWritten {
                    // A cancelled confirmation still needs to finish its rollback.
                    try await Task { try await restore(plans, journal: journal, locks: locks) }.value
                }
                removeUnpublishedAttachments(journal)
                try finish(repeated.directory, locks: locks, outcome: "restored\n" + failure)
            } catch {
                throw PetError(failure + "\n移交仍待恢复。\n" + error.localizedDescription)
            }
            throw PetError(failure + "\n已恢复本次写入。")
        }
        confirmed = true
        try finish(repeated.directory, locks: locks, outcome: completed(journal))
        return task.id
    }

    private func completed(_ journal: Journal) -> String {
        "completed\n" + journal.localTaskID + "\n" + journal.projects.map(\.head).joined(separator: "\n")
    }

    private func removeUnpublishedAttachments(_ journal: Journal) {
        // This directory belongs to the fresh, unpublished task ID in the journal.
        try? FileManager.default.removeItem(at: store.directory.appendingPathComponent(journal.localTaskID, isDirectory: true))
    }

    func recover(_ reviewed: Recovery) async throws -> String? {
        guard !applying else { throw PetError("移交正在进行") }
        applying = true; defer { applying = false }
        lease = try AgentWorktreeLease(in: history()); defer { lease = nil }
        guard try pendingRecovery() == reviewed else { throw PetError("移交状态已变化，请重新载入") }
        let journal = reviewed.journal, operation = reviewed.directory.lastPathComponent
        let plans = journal.projects.enumerated().map { i, project in
            Plan(source: project.source, directory: reviewed.directory.appendingPathComponent(String(i), isDirectory: true), commits: "", patches: [])
        }
        if !reviewed.published {
            guard try task().1 == plans.map(\.source.origin) else { throw PetError("原任务或工作区范围已变化") }
        }
        let owner = UUID()
        store.worktreeRetention.setNativeOperation(owner, taskID: taskID, busy: true)
        defer { store.worktreeRetention.setNativeOperation(owner, taskID: taskID, busy: false) }
        var locks: [AgentWorktreeIndexLock] = []
        defer { for lock in locks { lock.endRecoveryAttempt() } }
        for plan in plans {
            if let value = try lock(plan, operation: operation, mode: reviewed.published ? .cleanup : .recover) { locks.append(value) }
        }
        if reviewed.published {
            try finish(reviewed.directory, locks: locks, outcome: completed(journal))
            return reviewed.localTaskID
        }
        try await restore(plans, journal: journal, locks: locks)
        removeUnpublishedAttachments(journal)
        try finish(reviewed.directory, locks: locks, outcome: "restored\n")
        return nil
    }

    private struct RestoreState {
        let checkout: Checkout
        let reversePatch: Bool
    }

    private func inspectRestore(_ plan: Plan, project: Journal.Project, index: String) async throws -> RestoreState {
        let to = plan.source.to, hashes = try artifactHashes(plan)
        guard hashes.index == project.indexHash, hashes.patch == project.patchHash else { throw PetError("移交备份已变化：" + to.root) }
        let current = try await checkout(plan.source.origin, source: false, session: plan.directory, holdingIndex: true, requireClean: false)
        guard current.root == to.root, current.identity == to.identity, current.metadata == to.metadata,
              current.metadataIdentity == to.metadataIdentity, current.branch == to.branch,
              current.head == to.head || current.head == project.head,
              current.indexHash == to.indexHash || current.indexHash == project.indexHash else {
            throw PetError("本地分支或暂存区已有后续改动：" + to.root)
        }
        let before = try await oid(applyGit(["rev-parse", to.head + "^{tree}"], plan: plan))
        let after = plan.source.workingTree
        let patch = plan.directory.appendingPathComponent("transfer.patch")
        // Rebuild a private index from each possible endpoint. A full worktree
        // comparison detects later edits, including new untracked files.
        for tree in before == after ? [before] : [after, before] {
            _ = try await applyGit(["read-tree", tree], plan: plan, index: index)
            _ = try await applyGit(["add", "--all", "--", "."], plan: plan, index: index)
            guard try await oid(applyGit(["write-tree"], plan: plan, index: index)) == tree else { continue }
            let reverse = tree != before
            if before != after {
                _ = try await applyGit(["update-index", "--refresh"], plan: plan, index: index)
                let arguments = ["apply", "--index", "--check"] + (reverse ? ["--reverse"] : []) + [patch.path]
                if try await applyGit(arguments, plan: plan, index: index, inspect: true).failed { continue }
            }
            return .init(checkout: current, reversePatch: reverse)
        }
        throw PetError("本地工作文件已有后续改动或写入未完成。请保留这些文件并在 Git 中核对：\n" + to.root)
    }

    private func restore(_ plans: [Plan], journal: Journal, locks: [AgentWorktreeIndexLock]) async throws {
        let index = "restore-" + UUID().uuidString + ".index"
        defer {
            for plan in plans { try? FileManager.default.removeItem(at: plan.directory.appendingPathComponent(index)) }
        }
        var states: [RestoreState] = []
        for (i, plan) in plans.enumerated() {
            guard locks[i].holdsIndex else { throw PetError("移交锁已变化：" + plan.source.to.root) }
            states.append(try await inspectRestore(plan, project: journal.projects[i], index: index))
        }
        // Check all projects before writing any of them.
        for i in plans.indices.reversed() {
            let plan = plans[i], before = plan.source.to, state = states[i], current = state.checkout
            let admin = try AgentFiles(workspace: before.metadata, followParentLinks: false)
            guard locks[i].holdsIndex, try await referenceMatches(plan, head: current.head),
                  try admin.fileHash(admin.literalURL("index"), maximum: 32_000_000) == current.indexHash else {
                throw PetError("本地分支、暂存区或移交锁已变化：" + before.root)
            }
            if state.reversePatch {
                let patch = plan.directory.appendingPathComponent("transfer.patch")
                _ = try await applyGit(["apply", "--index", "--reverse", "--whitespace=nowarn", patch.path], plan: plan, index: index, write: true)
            }
            if current.indexHash != before.indexHash { _ = try installIndex("before.index", plan: plan, expected: current.indexHash) }
            try await updateRef(plan, from: current.head, to: before.head)
            guard try await checkout(plan.source.origin, source: false, session: plan.directory, holdingIndex: true) == before else {
                throw PetError("恢复后的工作区无法核对：" + before.root)
            }
        }
    }
}

final class AgentWorktreeLease {
    let descriptor: Int32

    init(in directory: URL, label: String = "移交", name: String = "lease") throws {
        let path = directory.appendingPathComponent(name).path
        let descriptor = open(path, O_RDONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw PetError("无法读取" + label + "操作锁") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw PetError("另一进程仍在处理" + label + "。请稍后重试。")
        }
        self.descriptor = descriptor
    }

    // A Git child inherits a copy so its writes stay protected after a force quit.
    deinit { close(descriptor) }
}

final class AgentWorktreeIndexLock {
    enum Mode { case new, recover, cleanup }
    private var parent: Int32
    private var lock: Int32
    private let marker: String
    private let wasPresent: Bool
    private let label: String

    init?(metadata: String, operation: String, mode: Mode, prefix: String = "handoff", label: String = "移交") throws {
        let files = try AgentFiles(workspace: metadata, followParentLinks: false)
        let (parent, name) = try files.parentDescriptor(files.literalURL("index.lock"), create: false)
        let marker = "bluefatfish-" + prefix + "-" + operation + ".lock"
        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        var lock = mode == .cleanup ? -1 : openat(parent, marker, flags | O_CREAT | O_EXCL, 0o600)
        let created = lock >= 0
        if mode == .cleanup || !created && mode == .recover && errno == EEXIST { lock = openat(parent, marker, flags) }
        if mode == .cleanup && lock < 0 && errno == ENOENT { close(parent); return nil }
        var info = stat()
        guard lock >= 0, fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            if lock >= 0 { close(lock) }
            close(parent)
            throw PetError("本地" + label + "锁无法核对：" + metadata)
        }
        let wasPresent = Self.matches(parent, lock, name)
        // The exclusive hard link publishes a Git lock whose owner can still
        // be verified against the journal's private name after either process exits.
        if mode != .cleanup, !wasPresent, linkat(parent, marker, parent, name, 0) != 0 {
            let conflict = errno == EEXIST
            if created, Self.matches(parent, lock, marker) { unlinkat(parent, marker, 0) }
            close(lock); close(parent)
            throw PetError((conflict ? "本地暂存区正被其他 Git 操作使用：" : "无法建立本地" + label + "锁：") + metadata)
        }
        self.parent = parent
        self.lock = lock
        self.marker = marker
        self.wasPresent = wasPresent
        self.label = label
    }

    private static func matches(_ parent: Int32, _ lock: Int32, _ name: String) -> Bool {
        var owned = stat(), current = stat()
        return fstat(lock, &owned) == 0 && fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0
            && owned.st_ino == current.st_ino && owned.st_dev == current.st_dev
    }
    var holdsIndex: Bool { lock >= 0 && Self.matches(parent, lock, "index.lock") }

    func release() throws {
        guard lock >= 0 else { return }
        if holdsIndex, unlinkat(parent, "index.lock", 0) != 0 { throw PetError("本地 Git 暂存锁无法释放") }
        if Self.matches(parent, lock, marker), unlinkat(parent, marker, 0) != 0 { throw PetError("本地" + label + "锁无法释放") }
        closeHandles()
    }
    func endRecoveryAttempt() {
        if !wasPresent { try? release() }
        closeHandles()
    }
    private func closeHandles() {
        if lock >= 0 {
            close(lock); close(parent); lock = -1; parent = -1
        }
    }
    deinit { closeHandles() }
}
