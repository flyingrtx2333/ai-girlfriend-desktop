import Foundation

struct AgentWorktreeUpstream: Codable {
    let remote: String
    let branch: String
    let trackingRef: String
    let selectedCommit: String
    let fetchedCommit: String
    let configurationHash: String

    func summary(base: String) -> String {
        let source = remote + "/" + String(branch.dropFirst("refs/heads/".count))
        return "已获取 " + source + (base == fetchedCommit ? "" : " · 使用本地提交")
    }
}

struct AgentWorktreeUpstreamAccessError: LocalizedError {
    let title: String
    let detail: String
    var errorDescription: String? { detail }

    static func recognize(_ result: AgentToolResult, scheme: String, target: String) -> Self? {
        guard result.failed, !result.timedOut, let stderr = result.stderr?.lowercased() else { return nil }
        if scheme == "ssh", stderr.contains("permission denied (publickey") {
            return Self(title: "上游认证失败", detail: target + "\n请确认该远端的 SSH 密钥可用后重新预览。")
        }
        guard scheme == "http" || scheme == "https" else { return nil }
        if stderr.contains("requested url returned error: 403") {
            return Self(title: "上游访问被拒绝", detail: target + "\n请确认当前账号拥有仓库读取权限后重新预览。")
        }
        let loginErrors = ["requested url returned error: 401", "fatal: authentication failed for", "fatal: unable to get password from user",
                           "fatal: could not read username for", "fatal: could not read password for"]
        guard loginErrors.contains(where: stderr.contains) else { return nil }
        return Self(title: "上游认证失败", detail: target + "\n请更新该远端的 Git 凭据后重新预览。")
    }
}

@MainActor extension AgentGit {
    private struct UpstreamTarget: Hashable {
        let remote: String
        let branch: String
        let trackingRef: String
    }

    // Fetch refspecs can rename branches. Resolve the configured source of
    // a selected tracking ref, including wildcard mappings and exclusions.
    private static func refspecMatch(_ ref: String, _ pattern: String) -> String? {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false)
        if parts.count == 1 { return ref == pattern ? "" : nil }
        guard parts.count == 2, ref.hasPrefix(parts[0]), ref.hasSuffix(parts[1]),
              ref.count >= parts[0].count + parts[1].count else { return nil }
        return String(ref.dropFirst(parts[0].count).dropLast(parts[1].count))
    }

    private func remoteBranches(_ remote: String, tracking: String) async throws -> Set<String> {
        guard !remote.isEmpty, !remote.hasPrefix("-"), remote.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw PetError("上游远端名称无效")
        }
        let result = try await run(["config", "--null", "--get-all", "remote." + remote + ".fetch"])
        if result.exitCode == 1 { return [] }
        guard !result.failed, result.truncated != true else { throw PetError("无法读取远端跟踪配置") }
        let specs = (result.stdout ?? "").split(separator: "\0").map(String.init)
        let excluded = specs.filter { $0.hasPrefix("^") }.map { String($0.dropFirst()) }
        let branches = specs.compactMap { spec -> String? in
            guard !spec.hasPrefix("^") else { return nil }
            let parts = (spec.hasPrefix("+") ? spec.dropFirst() : spec[...]).split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].hasPrefix("refs/heads/"),
                  let matched = Self.refspecMatch(tracking, String(parts[1])) else { return nil }
            let ref = parts[0].replacingOccurrences(of: "*", with: matched)
            return excluded.contains(where: { Self.refspecMatch(ref, $0) != nil }) ? nil : ref
        }
        return Set(branches)
    }

    private func upstreamTarget(_ point: AgentWorktreeStart, headRef: String) async throws -> UpstreamTarget? {
        let ref = point.ref == "HEAD" ? headRef : point.ref
        if ref.hasPrefix("refs/heads/") {
            let raw = try await output(["for-each-ref", "--format=%(refname)%00%(upstream)%00%(upstream:remotename)%00%(upstream:remoteref)", "--", ref])
            let values = raw.trimmingCharacters(in: .newlines).components(separatedBy: "\0")
            guard values.count == 4, values[0] == ref else { throw PetError("所选本地分支已变化，请重新预览") }
            let tracking = values[1], remote = values[2], branch = values[3]
            if remote.isEmpty || remote == "." { return nil }
            guard tracking.hasPrefix("refs/remotes/"), try await remoteBranches(remote, tracking: tracking) == [branch] else {
                throw PetError("上游配置无法唯一确认，请检查所选分支的远端设置")
            }
            return UpstreamTarget(remote: remote, branch: branch, trackingRef: tracking)
        }
        guard ref.hasPrefix("refs/remotes/") else { return nil }
        var targets: [UpstreamTarget] = []
        for remote in try await output(["remote"]).split(separator: "\n").map(String.init) {
            for branch in try await remoteBranches(remote, tracking: ref) {
                targets.append(UpstreamTarget(remote: remote, branch: branch, trackingRef: ref))
            }
        }
        guard targets.count == 1, let target = targets.first else { throw PetError("无法唯一确定所选远程分支，请检查远端跟踪设置") }
        return target
    }

    private func trackingCommit(_ ref: String) async throws -> String? {
        let symbolic = try await run(["symbolic-ref", "--quiet", ref])
        guard symbolic.exitCode == 1 else { throw PetError("请直接选择远程分支，不能刷新符号引用") }
        let result = try await run(["rev-parse", "--verify", "--quiet", ref])
        guard result.exitCode == 0 || result.exitCode == 1 else { throw PetError("无法读取远端跟踪分支") }
        return result.exitCode == 0 ? result.stdout?.trimmingCharacters(in: .newlines) : nil
    }

    func refreshWorktreeUpstream(_ point: AgentWorktreeStart, headRef: String, scope: String) async throws -> (commit: String, upstream: AgentWorktreeUpstream)? {
        let configuration = try await gitConfigurationHash()
        guard let target = try await upstreamTarget(point, headRef: headRef) else { return nil }
        let old = try await trackingCommit(target.trackingRef)
        let address = try await output(["remote", "get-url", target.remote]).trimmingCharacters(in: .newlines)
        let input = try AgentGitEndpoint.parse(address, relativeTo: files.root)
        let transport = try AgentGitTransport(store: store, taskID: taskID)
        remoteTransport = transport
        defer { remoteTransport = nil; transport.cleanup() }
        let format = try await output(["rev-parse", "--show-object-format"]).trimmingCharacters(in: .newlines)
        try await transport.initialize(format: format)
        var origin = input, endpoint = try await transport.effective(input)
        if let local = endpoint.localPath, FileManager.default.fileExists(atPath: URL(fileURLWithPath: local).appendingPathComponent(".git").path) {
            origin = try AgentGitEndpoint.parse(Self.metadata(workspace: local).path, relativeTo: files.root)
            endpoint = try await transport.effective(origin)
        }
        guard let task = store.task(taskID), try creationScope() == scope, try await gitConfigurationHash() == configuration else {
            throw PetError("工作区或远端设置已变化，请重新预览")
        }
        if endpoint.needsNetwork, try !store.agents.limits(task, store: store).network {
            throw PetError("当前任务禁止联网。关闭「创建前获取上游更新」后可使用现有起点")
        }
        let upstreamRef = "refs/heads/upstream"
        let repo = ["-C", transport.repository.path]
        let remoteBranch = target.remote + "/" + String(target.branch.dropFirst("refs/heads/".count))
        let fetch: AgentToolResult
        do {
            fetch = try await transport.run(repo + ["fetch", "--no-tags", "--no-write-fetch-head", "--no-recurse-submodules", "--no-auto-gc", "--", origin.input, target.branch + ":" + upstreamRef], endpoint: endpoint)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PetError("无法获取 " + remoteBranch + "\n" + error.localizedDescription)
        }
        if fetch.failed || fetch.truncated == true {
            let source = files.root.lastPathComponent + " · " + remoteBranch
            if let access = AgentWorktreeUpstreamAccessError.recognize(fetch, scheme: endpoint.scheme, target: source) { throw access }
            throw PetError("无法获取 " + remoteBranch + "\n" + String(fetch.text.prefix(3000)))
        }
        let fetched = try await transport.output(repo + ["rev-parse", "--verify", upstreamRef + "^{commit}"]).trimmingCharacters(in: .newlines)
        if fetched != old {
            let bundle = transport.root.appendingPathComponent("upstream.bundle")
            _ = try await transport.output(repo + ["bundle", "create", bundle.path, upstreamRef])
            let imported = try await run(["bundle", "unbundle", bundle.path], write: true, timeout: 120, readRoots: [transport.root], metadataOnly: true)
            guard !imported.failed, imported.stdout?.split(whereSeparator: \.isWhitespace).map(String.init) == [fetched, upstreamRef] else {
                throw PetError("无法导入已获取的上游提交")
            }
        }
        try Task.checkCancellation()
        guard try creationScope() == scope, try await gitConfigurationHash() == configuration,
              try await trackingCommit(target.trackingRef) == old else { throw PetError("上游或工作区已变化，请重新预览") }
        if fetched != old {
            let updated = try await run(["-c", "core.hooksPath=/dev/null", "update-ref", "--no-deref", target.trackingRef, fetched, old ?? String(repeating: "0", count: fetched.count)], write: true, metadataOnly: true)
            guard !updated.failed else { throw PetError("无法更新远端跟踪分支，请重新预览\n" + String(updated.text.prefix(1000))) }
        }
        let upstream = AgentWorktreeUpstream(remote: target.remote, branch: target.branch, trackingRef: target.trackingRef,
                                             selectedCommit: point.commit, fetchedCommit: fetched, configurationHash: configuration)
        if point.ref == target.trackingRef { return (fetched, upstream) }
        let containsLocal = try await run(["merge-base", "--is-ancestor", point.commit, fetched])
        guard containsLocal.exitCode == 0 || containsLocal.exitCode == 1 else { throw PetError("无法核对本地提交与上游的关系") }
        return (containsLocal.exitCode == 0 ? fetched : point.commit, upstream)
    }

    func validateCreationStartingPoint(_ review: AgentWorktreeCreationReview) async throws {
        if let refresh = review.refreshUpstream, try store.gitPreferences.worktreeFetchPreference().enabled != refresh {
            throw PetError("获取上游设置已变化，请重新预览")
        }
        let expected = review.upstream.map { review.startPoint == $0.trackingRef ? $0.fetchedCommit : $0.selectedCommit } ?? review.baseCommit
        guard try await worktreeStartingPoint(review.startPoint).commit == expected else { throw PetError("所选起点已变化，请重新预览") }
        if let value = review.upstream {
            guard try await trackingCommit(value.trackingRef) == value.fetchedCommit,
                  try await gitConfigurationHash() == value.configurationHash else { throw PetError("上游分支或远端设置已变化，请重新预览") }
        }
    }
}
