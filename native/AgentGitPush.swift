import Foundation

@MainActor extension AgentGit {
    private func remoteURLs(_ name: String) async throws -> [String] {
        guard !name.isEmpty, name.utf8.count <= 200, !name.hasPrefix("-"), name.rangeOfCharacter(from: .controlCharacters) == nil else { throw PetError("请选择已配置的 Git 远端") }
        let result = try await run(["remote", "get-url", "--push", "--all", name])
        guard !result.failed, result.truncated != true else { throw PetError("无法读取所选 Git 远端配置") }
        return (result.stdout ?? "").split(separator: "\n").map(String.init)
    }
    func remotes() async throws -> [AgentGitRemote] {
        var result: [AgentGitRemote] = []
        let resolver = try AgentGitTransport(store: store, taskID: taskID); defer { resolver.cleanup() }
        try await resolver.initialize()
        for name in try await output(["remote"]).split(separator: "\n").map(String.init) {
            let urls = try await remoteURLs(name)
            var locations: [String] = []
            for raw in urls {
                if let input = try? AgentGitEndpoint.parse(raw, relativeTo: files.root) { locations.append(try await resolver.effective(input).location) }
                else { locations.append("地址需要修正：移除凭据或外部传输程序") }
            }
            result.append(AgentGitRemote(name: name, urls: locations))
        }
        var snapshot = AgentGitRemoteSnapshot(remotes: result, configHash: try await pushConfigHash(), processID: AgentGitTransport.processID, hash: "")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; snapshot.hash = AgentFiles.hash(try encoder.encode(snapshot))
        store.update(taskID) { $0.gitRemoteSnapshot = snapshot }
        guard store.writeError == nil else { throw PetError("无法保存远端列表") }
        return result
    }
    func pushInput(remote: String, urlIndex: Int) async throws -> (raw: String, endpoint: AgentGitEndpoint) {
        let names = try await output(["remote"]).split(separator: "\n").map(String.init)
        guard names.contains(remote) else { throw PetError("请选择已配置的 Git 远端") }
        let urls = try await remoteURLs(remote)
        guard urls.indices.contains(urlIndex) else { throw PetError("远端地址已变化，请重新选择") }
        return (urls[urlIndex], try AgentGitEndpoint.parse(urls[urlIndex], relativeTo: files.root))
    }
    func pushBranch(_ value: String) async throws -> String {
        let branch = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty, branch.utf8.count <= 200, !branch.contains("\0"), !branch.hasPrefix("-") else { throw PetError("请填写目标分支") }
        let check = try await run(["check-ref-format", "refs/heads/" + branch])
        guard !check.failed else { throw PetError("目标分支名称无效") }; return branch
    }
    func addRemote(name: String, url: String) async throws {
        try validateWorkspace()
        guard !name.isEmpty, name.utf8.count <= 100, !name.hasPrefix("-"), name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, name.rangeOfCharacter(from: .controlCharacters) == nil else { throw PetError("远端名称无效") }
        let endpoint = try AgentGitEndpoint.parse(url.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: files.root)
        let result = try await run(["remote", "add", name, endpoint.input], write: true)
        guard !result.failed else { throw PetError(String(result.text.prefix(1000))) }
        store.update(taskID) { $0.gitRemoteSnapshot = nil; $0.gitPushReview = nil }
    }
    private func pushConfigHash() async throws -> String {
        let value = try await run(["config", "--null", "--list"], maximumOutput: 1_000_000)
        guard !value.failed, value.truncated != true else { throw PetError("无法核对 Git 配置") }
        return AgentFiles.hash(Data((value.stdout ?? "").utf8))
    }
    private func pushScopeHash() throws -> String {
        guard let task = store.task(taskID) else { throw PetError("任务不存在") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let values = [task.workspace ?? "", task.mode.rawValue, task.permission.rawValue,
                      String(decoding: try encoder.encode(task.agent), as: UTF8.self), String(decoding: try encoder.encode(task.team), as: UTF8.self), String(decoding: try encoder.encode(task.automation), as: UTF8.self)]
        return AgentFiles.hash(Data(values.joined(separator: "\0").utf8))
    }
    private func prePushHook() async throws -> (path: String?, hash: String) {
        try await validateHooks()
        let raw = try await output(["rev-parse", "--git-path", "hooks/pre-push"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let path = URL(fileURLWithPath: raw, relativeTo: files.root.appendingPathComponent("", isDirectory: true)).standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: path.path) else { return (nil, "none") }
        let root = path.path.hasPrefix(files.root.path + "/") ? files.root : directory
        let allowed = try AgentFiles(workspace: root.path), data = try allowed.readData(allowed.resolve(path.path), maximum: 1_000_000)
        let permissions = (try? FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions]) as? Int ?? 0
        return (path.path, AgentFiles.hash(Data((path.path + "\0\(permissions)\0").utf8) + data))
    }
    private func trackingReference(remote: String, branch: String) async throws -> (String?, String?) {
        let value = try await run(["config", "--get-all", "remote." + remote + ".fetch"])
        if value.exitCode == 1 { return (nil, nil) }
        guard !value.failed, value.truncated != true else { throw PetError("无法核对远端跟踪配置") }
        let source = "refs/heads/" + branch
        for line in (value.stdout ?? "").split(separator: "\n") {
            let parts = line.trimmingCharacters(in: CharacterSet(charactersIn: "+")).split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[1].hasPrefix("refs/remotes/") else { continue }
            let reference: String
            if let star = parts[0].firstIndex(of: "*") {
                let left = String(parts[0][..<star]), right = String(parts[0][parts[0].index(after: star)...])
                guard source.hasPrefix(left), source.hasSuffix(right), source.count >= left.count + right.count, parts[1].filter({ $0 == "*" }).count == 1 else { continue }
                let match = String(source.dropFirst(left.count).dropLast(right.count)); reference = parts[1].replacingOccurrences(of: "*", with: match)
            } else { guard parts[0] == source else { continue }; reference = parts[1] }
            guard try await run(["check-ref-format", reference]).exitCode == 0 else { continue }
            let old = try await run(["rev-parse", "--verify", reference])
            return (reference, old.failed ? nil : old.stdout?.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (nil, nil)
    }
    private func reviewHash(_ value: AgentGitPushReview) throws -> String {
        var copy = value; copy.hash = ""; copy.created = Date(timeIntervalSince1970: 0)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return AgentFiles.hash(try encoder.encode(copy))
    }
    func preparePush(remote: String, urlIndex: Int, branch: String, setUpstream: Bool, remoteHash: String? = nil) async throws -> AgentGitPushReview {
        try validateWorkspace()
        guard let task = store.task(taskID), !task.archived else { throw PetError("任务不存在或已归档") }
        try store.agents.check(AgentToolCall(id: "git-push-prepare", name: "git_prepare_push", arguments: "{}"), task: task, store: store)
        let input = try await pushInput(remote: remote, urlIndex: urlIndex), target = try await pushBranch(branch), state = try await status()
        guard let head = state.head else { throw PetError("请先创建首次提交") }
        let symbolic = try await run(["symbolic-ref", "--quiet", "HEAD"]), sourceRef = symbolic.failed ? "HEAD" : (symbolic.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = try await pushConfigHash(), hook = try await prePushHook(), scope = try pushScopeHash()
        guard let snapshot = task.gitRemoteSnapshot, snapshot.processID == AgentGitTransport.processID, snapshot.configHash == configuration, remoteHash == nil || remoteHash == snapshot.hash,
              let cached = snapshot.remotes.first(where: { $0.name == remote }), cached.urls.indices.contains(urlIndex) else { throw PetError("远端配置已变化，请先刷新 Git 远端列表，再确认连接") }
        let sessionID = UUID().uuidString, transport = try AgentGitTransport(store: store, taskID: taskID, sessionID: sessionID)
        pushTransport = transport; var saved = false
        defer { pushTransport = nil; if !saved { transport.cleanup() } }
        let format = try await output(["rev-parse", "--show-object-format"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try await transport.initialize(format: format)
        let endpoint = try await transport.effective(input.endpoint)
        guard endpoint.location == cached.urls[urlIndex] else { throw PetError("Git 连接目标已变化，请先刷新远端列表，再确认连接") }
        let before = try await transport.remoteHead(input: input.endpoint, endpoint: endpoint, branch: target)
        let bundle = scratch.appendingPathComponent("push-" + sessionID + ".bundle")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let packed = try await run(["bundle", "create", bundle.path, "HEAD"], timeout: 180)
        guard !packed.failed else { throw PetError("无法准备已提交内容：\n" + String(packed.text.prefix(2000))) }
        let bundleHead = try await output(["bundle", "list-heads", bundle.path]).split(whereSeparator: \.isWhitespace).map(String.init)
        guard bundleHead == [head, "HEAD"] else { throw PetError("本地提交已变化，请重新检查远端") }
        let copied = transport.root.appendingPathComponent("source.bundle"); try FileManager.default.copyItem(at: bundle, to: copied)
        _ = try await transport.output(["-C", transport.repository.path, "fetch", "--no-tags", "--no-write-fetch-head", "--no-recurse-submodules", copied.path, "HEAD:refs/heads/source"])
        if let before {
            _ = try await transport.output(["-C", transport.repository.path, "fetch", "--no-tags", "--no-write-fetch-head", "--no-recurse-submodules", "--", input.endpoint.input, "refs/heads/" + target + ":refs/heads/review-remote"], endpoint: endpoint)
            let fetched = try await transport.output(["-C", transport.repository.path, "rev-parse", "refs/heads/review-remote"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard fetched == before else { throw PetError("远端分支已变化，请重新检查") }
            let ancestry = try await transport.run(["-C", transport.repository.path, "merge-base", "--is-ancestor", before, head])
            guard ancestry.exitCode == 0 else { throw PetError("远端分支包含本地没有的提交，请先获取并合并后再推送") }
        }
        let range = before.map { $0 + ".." + head } ?? head
        let count = try await transport.output(["-C", transport.repository.path, "rev-list", "--count", range]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let total = Int(count) else { throw PetError("无法核对待推送提交数") }
        let commits = try await transport.output(["-C", transport.repository.path, "log", "--max-count=100", "--format=%H%x09%s", range])
        let base: String
        if let before { base = before }
        else { base = try await transport.output(["-C", transport.repository.path, "mktree"]).trimmingCharacters(in: .whitespacesAndNewlines) }
        let diff = try await transport.run(["-C", transport.repository.path, "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--stat", "-p", base, head, "--"], maximumOutput: 200_000)
        guard !diff.failed else { throw PetError("无法读取待推送提交的差异") }
        let tracking = try await trackingReference(remote: remote, branch: target)
        var review = AgentGitPushReview(sessionID: sessionID, processID: AgentGitTransport.processID, taskID: taskID, promptID: task.messages.last(where: \.isHumanInput)?.id ?? task.id, workspace: files.root.path, gitDirectory: directory.path, remote: remote, urlIndex: urlIndex, configuredURL: input.raw, endpoint: endpoint, sourceBranch: symbolic.failed ? "HEAD（分离状态）" : state.branch, sourceRef: sourceRef, sourceHead: head, targetBranch: target, remoteHead: before, configHash: configuration, transportConfigHash: try await transport.configurationHash(), scopeHash: scope, hookPath: hook.path, hookHash: hook.hash, trackingRef: tracking.0, trackingHead: tracking.1, setUpstream: setUpstream, commitCount: total, commits: commits, diff: diff.stdout ?? "", diffTruncated: diff.truncated == true, uncommittedFiles: state.changes.count, hash: "")
        review.hash = try reviewHash(review)
        guard try await pushConfigHash() == configuration, try await status().head == head else { throw PetError("本地提交或配置已变化，请重新准备推送") }
        let previous = store.task(taskID)?.gitPushReview
        store.update(taskID) { $0.gitPushReview = review }
        guard store.writeError == nil else { throw PetError("无法保存推送审阅：" + (store.writeError ?? "")) }
        saved = true
        if let previous, previous.sessionID != sessionID, previous.processID == AgentGitTransport.processID { try? AgentGitTransport(store: store, taskID: taskID, sessionID: previous.sessionID).cleanup() }
        return review
    }
    func storedPushReview(hash: String) throws -> AgentGitPushReview {
        guard let review = store.task(taskID)?.gitPushReview, review.hash == hash, review.taskID == taskID, review.processID == AgentGitTransport.processID, try reviewHash(review) == hash else { throw PetError("推送审阅已过期，请重新检查远端") }
        return review
    }
    private func validatePush(_ review: AgentGitPushReview, transport: AgentGitTransport) async throws {
        guard let task = store.task(taskID), !task.archived, (task.messages.last(where: \.isHumanInput)?.id ?? task.id) == review.promptID,
              (task.queuedMessages ?? []).isEmpty, (task.queuedInputs ?? []).isEmpty,
              files.root.path == review.workspace, try Self.metadata(workspace: task.workspace).path == review.gitDirectory, try pushScopeHash() == review.scopeHash else { throw PetError("任务要求或执行范围已变化，请重新准备推送") }
        try store.agents.check(AgentToolCall(id: "git-push", name: "git_push", arguments: "{}"), task: task, store: store)
        let input = try await pushInput(remote: review.remote, urlIndex: review.urlIndex)
        let state = try await status(), hook = try await prePushHook()
        guard input.raw == review.configuredURL, state.head == review.sourceHead,
              try await pushConfigHash() == review.configHash, hook.path == review.hookPath, hook.hash == review.hookHash,
              try await transport.configurationHash() == review.transportConfigHash,
              try await transport.effective(input.endpoint) == review.endpoint else { throw PetError("提交、远端或 Git 检查已变化，请重新审阅推送") }
        let localRef = try await run(["symbolic-ref", "--quiet", "HEAD"])
        let ref = localRef.failed ? "HEAD" : (localRef.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard ref == review.sourceRef else { throw PetError("当前分支已变化，请重新准备推送") }
        guard try await transport.output(["-C", transport.repository.path, "rev-parse", "refs/heads/source"]).trimmingCharacters(in: .whitespacesAndNewlines) == review.sourceHead else { throw PetError("推送快照校验失败") }
        guard try await transport.remoteHead(input: input.endpoint, endpoint: review.endpoint, branch: review.targetBranch) == review.remoteHead else { throw PetError("远端分支已变化，请重新检查后推送") }
    }
    func push(reviewHash: String, timeout: Double = 180) async throws -> AgentGitPushReceipt {
        let review = try storedPushReview(hash: reviewHash), transport = try AgentGitTransport(store: store, taskID: taskID, sessionID: review.sessionID)
        pushTransport = transport
        defer {
            pushTransport = nil; transport.cleanup()
            if store.task(taskID)?.gitPushReview?.hash == review.hash { store.update(taskID) { $0.gitPushReview = nil } }
        }
        try await validatePush(review, transport: transport)
        let input = try await pushInput(remote: review.remote, urlIndex: review.urlIndex)
        if review.commitCount == 0 {
            let receipt = AgentGitPushReceipt(taskID: taskID, remote: review.remote, input: input.endpoint, endpoint: review.endpoint, branch: review.targetBranch, sourceHead: review.sourceHead, beforeHead: review.remoteHead, afterHead: review.remoteHead, verified: true, output: "远端已包含此提交", exitCode: 0)
            store.update(taskID) { $0.gitPushReceipt = receipt }; return receipt
        }
        if let hook = review.hookPath {
            let file = scratch.appendingPathComponent("pre-push-" + review.sessionID + ".stdin")
            defer { try? FileManager.default.removeItem(at: file) }
            try Data((review.sourceRef + " " + review.sourceHead + " " + review.destinationRef + " " + (review.remoteHead ?? String(repeating: "0", count: review.sourceHead.count)) + "\n").utf8).write(to: file, options: .atomic)
            let command = AgentCommand()
            pushHookCommand = command; defer { pushHookCommand = nil }
            let result = try await command.run(command: hook, workspace: files.root, scratch: scratch, network: false, timeout: 90, gitDirectory: directory, gitWrite: true, gitConfiguration: true, protectedData: store.directory.deletingLastPathComponent(), inputFile: file, arguments: [review.remote, review.endpoint.location])
            guard !result.failed else { throw PetError("pre-push 检查未通过，未推送：\n" + String(result.text.prefix(3000))) }
        }
        try await validatePush(review, transport: transport)
        var receipt = AgentGitPushReceipt(taskID: taskID, remote: review.remote, input: input.endpoint, endpoint: review.endpoint, branch: review.targetBranch, sourceHead: review.sourceHead, beforeHead: review.remoteHead)
        store.update(taskID) { $0.gitPushReview = nil; $0.gitPushReceipt = receipt }
        guard store.writeError == nil else { throw PetError("无法保存推送状态，未发送提交") }
        do {
            // The exact lease is a compare-and-swap for the reviewed remote ref.
            // Ancestry was independently checked; history rewrites are forbidden.
            let result = try await transport.run(["-C", transport.repository.path, "push", "--porcelain", "--no-follow-tags", "--recurse-submodules=no", "--force-with-lease=" + review.destinationRef + ":" + (review.remoteHead ?? ""), "--", input.endpoint.input, review.sourceHead + ":" + review.destinationRef], endpoint: review.endpoint, writingRemote: true, timeout: timeout)
            receipt.output = String(result.text.prefix(6000)); receipt.exitCode = result.exitCode
            receipt.afterHead = try await transport.remoteHead(input: input.endpoint, endpoint: review.endpoint, branch: review.targetBranch)
            receipt.verified = receipt.afterHead == review.sourceHead
            if receipt.verified {
                do { receipt.localUpdate = try await updatePushTracking(review) }
                catch { receipt.localUpdate = "远端已核对；本地跟踪信息未更新：" + error.localizedDescription }
            }
            store.update(taskID) { $0.gitPushReceipt = receipt }
            return receipt
        } catch {
            receipt.output += "\n" + (Task.isCancelled ? "推送已停止，远端结果待核对" : "推送结果待核对：" + error.localizedDescription)
            store.update(taskID) { $0.gitPushReceipt = receipt }
            throw PetError(receipt.output + "。请核对远端后再操作，不要直接重试。")
        }
    }
    private func updatePushTracking(_ review: AgentGitPushReview) async throws -> String {
        guard try await pushConfigHash() == review.configHash else { return "远端已核对；本地配置已变化，未更新跟踪分支" }
        guard let tracking = review.trackingRef else { return review.setUpstream ? "远端已核对；当前 fetch 映射无法设置上游" : "" }
        let update = try await run(["update-ref", tracking, review.sourceHead, review.trackingHead ?? String(repeating: "0", count: review.sourceHead.count)], write: true)
        guard !update.failed else { return "远端已核对；跟踪分支已变化，未覆盖本地引用" }
        if review.setUpstream {
            let ref = try await run(["symbolic-ref", "--quiet", "HEAD"])
            guard ref.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) == review.sourceRef, try await status().head == review.sourceHead else { return "远端已核对；本地分支已变化，未设置上游" }
            let result = try await run(["branch", "--set-upstream-to=" + tracking, review.sourceBranch], write: true)
            if result.failed { return "推送已完成，上游未设置：" + String(result.text.prefix(1000)) }
            return "已设置上游"
        }
        return "已更新远端跟踪分支"
    }
}

@MainActor extension AgentGitTransport {
    static func verifyReceipt(store: AgentStore, taskID: String, operationID: String) async throws -> AgentGitPushReceipt {
        guard let task = store.task(taskID), var receipt = task.gitPushReceipt, receipt.id == operationID, receipt.taskID == taskID else { throw PetError("没有本任务的推送记录") }
        try store.agents.check(AgentToolCall(id: "git-push-status", name: "git_push_status", arguments: "{}"), task: task, store: store)
        let transport = try AgentGitTransport(store: store, taskID: taskID); defer { transport.cleanup() }
        try await transport.initialize(format: receipt.sourceHead.count == 64 ? "sha256" : "sha1")
        guard try await transport.effective(receipt.input) == receipt.endpoint else { throw PetError("连接配置已变化，请重新选择远端核对") }
        receipt.afterHead = try await transport.remoteHead(input: receipt.input, endpoint: receipt.endpoint, branch: receipt.branch)
        receipt.verified = receipt.afterHead == receipt.sourceHead
        store.update(taskID) { $0.gitPushReceipt = receipt }; return receipt
    }
}
