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
    private let store: AgentStore
    private let taskID: String
    private var applying = false
    private var confirmed = false

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
                        "-c", "core.hooksPath=/dev/null", "-c", "core.quotePath=true"] + arguments)
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

    private func checkout(_ origin: AgentWorktreeOrigin, source: Bool, session: URL, holdingIndex: Bool = false) async throws -> Checkout {
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
        let status = try await read(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none"])
        if !source, !(status.stdoutData ?? Data()).isEmpty { throw PetError("本地工作区有改动，请先处理后再移交：" + root) }
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
        let (_, origins) = try task()
        let version = try store.recordVersion(taskID)
        let folder = try store.backupDirectory(taskID).appendingPathComponent("worktree-handoff/" + UUID().uuidString, isDirectory: true)
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
        if let files = task.attachments, !files.isEmpty {
            try AgentAttachments.copyForFork(store: store, sourceID: taskID, targetID: task.id, files: files)
        }
        return task
    }

    func apply(_ reviewed: AgentWorktreeHandoffReview) async throws -> String {
        guard !applying, !confirmed else { throw PetError("此移交已处理") }
        applying = true; defer { applying = false }
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
        let locks = try plans.map { try AgentHandoffIndexLock(metadata: $0.source.to.metadata) }
        defer { locks.forEach { $0.release() } }
        var heads: [String] = []
        for plan in plans {
            guard try await checkout(plan.source.origin, source: false, session: plan.directory, holdingIndex: true) == plan.source.to else {
                throw PetError("本地工作区已变化，请重新审阅")
            }
            heads.append(try await targetHead(plan))
        }
        guard try store.recordVersion(taskID) == repeated.taskVersion else { throw PetError("原任务已变化，请重新审阅") }
        let journal = repeated.directory.appendingPathComponent("journal.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Journal: Codable {
            let taskID: String
            let sources: [AgentWorktreeHandoffReview.Source]
            let expectedHeads: [String]
        }
        try encoder.encode(Journal(taskID: taskID, sources: plans.map(\.source), expectedHeads: heads)).write(to: journal, options: .atomic)
        let task = try continuation(original, review: repeated, heads: heads)
        defer {
            if !confirmed, store.task(task.id) == nil {
                try? FileManager.default.removeItem(at: store.directory.appendingPathComponent(task.id))
            }
        }
        var applied: [Int] = []
        var indexHashes: [Int: String] = [:]
        var updatedRefs: Set<Int> = []
        var writing: Int?
        do {
            for (i, plan) in plans.enumerated() where plan.hasChanges {
                try Task.checkCancellation()
                guard try await checkout(plan.source.origin, source: true, session: plan.directory) == plan.source.from,
                      try await checkout(plan.source.origin, source: false, session: plan.directory, holdingIndex: true) == plan.source.to else {
                    throw PetError("两边工作区已变化，请重新审阅")
                }
                let (staged, working) = try await sourceTrees(plan.source.origin, from: plan.source.from, session: plan.directory)
                guard staged == plan.source.sourceIndexTree, working == plan.source.sourceWorkingTree else { throw PetError("工作树文件已变化，请重新审阅") }
                let patch = plan.directory.appendingPathComponent("transfer.patch")
                if !(try Data(contentsOf: patch)).isEmpty {
                    _ = try await applyGit(["update-index", "--refresh"], plan: plan, index: "apply.index")
                    writing = i
                    _ = try await applyGit(["apply", "--index", "--whitespace=nowarn", patch.path], plan: plan, index: "apply.index", write: true)
                    writing = nil
                }
                applied.append(i)
                guard try await oid(applyGit(["write-tree"], plan: plan, index: "apply.index")) == plan.source.workingTree else {
                    throw PetError("实际写入与审阅的工作文件不一致")
                }
                indexHashes[i] = try installIndex("final.index", plan: plan, expected: plan.source.to.indexHash)
                try await updateRef(plan, from: plan.source.to.head, to: heads[i])
                updatedRefs.insert(i)
                guard try await referenceMatches(plan, head: heads[i]) else { throw PetError("移交后的本地分支无法核对") }
            }
            try store.installRelatedRecord(task, sourceID: taskID, expectedHash: repeated.taskVersion, label: "移交到本地")
            confirmed = true
            try? Data(("completed\n" + task.id + "\n" + heads.joined(separator: "\n")).utf8).write(to: repeated.directory.appendingPathComponent("outcome"), options: .atomic)
            return task.id
        } catch {
            // Recovery uses a separate task so a cancelled confirmation can still undo its writes.
            let recovery = Task { await restore(plans, heads: heads, applied: applied, writing: writing, indexes: indexHashes, moved: updatedRefs) }
            let uncertain = await recovery.value
            let detail = uncertain.isEmpty ? "已恢复本次写入。" : "请核对这些目录和移交日志：\n" + uncertain.joined(separator: "\n")
            try? Data((detail + "\n" + error.localizedDescription).utf8).write(to: repeated.directory.appendingPathComponent("outcome"), options: .atomic)
            throw PetError(error.localizedDescription + "\n" + detail + "\n" + repeated.directory.path)
        }
    }

    private func restore(_ plans: [Plan], heads: [String], applied: [Int], writing: Int?, indexes: [Int: String], moved: Set<Int>) async -> [String] {
        var applied = applied, uncertain: [String] = []
        if let writing {
            let plan = plans[writing]
            let tree = try? await oid(applyGit(["write-tree"], plan: plan, index: "apply.index"))
            if tree == plan.source.workingTree { applied.append(writing) }
            else { uncertain.append(plan.source.to.root) }
        }
        for i in applied.reversed() {
            let plan = plans[i]
            do {
                let head = moved.contains(i) ? heads[i] : plan.source.to.head
                guard try await referenceMatches(plan, head: head) else { throw PetError("本地分支已有后续改动") }
                let patch = plan.directory.appendingPathComponent("transfer.patch")
                if !(try Data(contentsOf: patch)).isEmpty {
                    _ = try await applyGit(["apply", "--reverse", "--index", "--check", patch.path], plan: plan, index: "apply.index")
                    _ = try await applyGit(["apply", "--reverse", "--index", "--whitespace=nowarn", patch.path], plan: plan, index: "apply.index", write: true)
                }
                if let hash = indexes[i] { _ = try installIndex("before.index", plan: plan, expected: hash) }
                try await updateRef(plan, from: head, to: plan.source.to.head)
            } catch { uncertain.append(plan.source.to.root) }
        }
        return uncertain
    }
}

private final class AgentHandoffIndexLock {
    private var parent: Int32 = -1
    private var lock: Int32 = -1
    init(metadata: String) throws {
        let files = try AgentFiles(workspace: metadata, followParentLinks: false)
        let (parent, name) = try files.parentDescriptor(files.literalURL("index.lock"), create: false)
        let lock = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { close(parent); throw PetError("本地暂存区正被其他 Git 操作使用：" + metadata) }
        self.parent = parent
        self.lock = lock
    }
    func release() {
        guard lock >= 0 else { return }
        var owned = stat(), current = stat()
        if fstat(lock, &owned) == 0, fstatat(parent, "index.lock", &current, AT_SYMLINK_NOFOLLOW) == 0,
           owned.st_ino == current.st_ino, owned.st_dev == current.st_dev {
            unlinkat(parent, "index.lock", 0)
        }
        close(lock); close(parent); lock = -1; parent = -1
    }
    deinit { release() }
}
