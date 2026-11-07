import AppKit
import Darwin

@MainActor extension AppDelegate {
    func runAgentGitPushCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        do {
            let fm = FileManager.default, repo = output.appendingPathComponent("workspace"), temporary = output.appendingPathComponent("tmp")
            let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("server.json"))) as? [String: Any]
            guard let remoteURL = settings?["url"] as? String, let remotePath = settings?["repository"] as? String else { throw PetError("实际 Git 服务尚未就绪") }
            let server = URL(fileURLWithPath: remotePath)
            try fm.createDirectory(at: repo, withIntermediateDirectories: true); try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
            func setup(_ args: [String], at directory: URL? = nil) async throws -> String {
                let result = try await AgentCommand().run(command: try AgentGit.executablePath(), workspace: output, scratch: temporary, network: false, timeout: 20, gitDirectory: repo.appendingPathComponent(".git"), gitWrite: true, protectedData: store.directory, arguments: ["-C", (directory ?? repo).path] + args)
                guard !result.failed else { throw PetError(result.text) }; return result.stdout ?? ""
            }
            func write(_ path: String, _ value: String) throws { try Data(value.utf8).write(to: repo.appendingPathComponent(path)) }
            func read(_ path: String) throws -> String { try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8) }
            try write("data.txt", "base\n"); try write("user.txt", "original-user-content\n")
            _ = try await setup(["init", "-b", "main"])
            for (key, value) in [("user.name", "Push Acceptance"), ("user.email", "push@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", ".git/hooks")] { _ = try await setup(["config", key, value]) }
            _ = try await setup(["add", "--", "."]); _ = try await setup(["commit", "-m", "public initial commit"])
            let base = try await setup(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await setup(["push", "--", server.path, "HEAD:refs/heads/main"])
            try write("data.txt", "committed-push-content\n"); _ = try await setup(["add", "--", "data.txt"]); _ = try await setup(["commit", "-m", "public reviewed commit"])
            let head = try await setup(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            try write("user.txt", "user-staged-preserved\n"); _ = try await setup(["add", "--", "user.txt"]); try write("user.txt", "user-working-preserved\n")
            _ = try await setup(["remote", "add", "origin", remoteURL])
            ensureAgent(); guard let tasks = agentStore else { throw PetError("任务存储不可用") }
            var preferences = store.preferences; preferences.voiceEnabled = false; preferences.wakeEnabled = false; preferences.screenObservationEnabled = false; store.preferences = preferences
            let id = tasks.create(title: "原生 Git 推送验收", workspace: repo.path), git = try AgentGit(store: tasks, taskID: id, directory: repo.appendingPathComponent(".git"))
            func prepare(_ branch: String, upstream: Bool = false) async throws -> AgentGitPushReview {
                _ = try await git.remotes()
                return try await git.preparePush(remote: "origin", urlIndex: 0, branch: branch, setUpstream: upstream, remoteHash: tasks.task(id)?.gitRemoteSnapshot?.hash)
            }
            let first = try await prepare("main", upstream: true)
            let beforeRemoteHead = try await setup(["rev-parse", "refs/heads/main"], at: server).trimmingCharacters(in: .whitespacesAndNewlines)
            checks["preparationReadsActualRemoteWithoutSendingCommits"] = first.sourceHead == head && first.remoteHead == base && first.commitCount == 1 && first.diff.contains("+committed-push-content") && beforeRemoteHead == base
            let transport = try AgentGitTransport(store: tasks, taskID: id, sessionID: first.sessionID)
            let marker = transport.root.appendingPathComponent("authority-marker"); try Data("public-authority-marker".utf8).write(to: marker)
            let scopeProbe = try await AgentCommand().run(command: "/bin/sh", workspace: repo, scratch: git.scratch, network: false, timeout: 5, gitDirectory: git.directory, gitWrite: true, gitConfiguration: true, protectedData: tasks.directory.deletingLastPathComponent(), arguments: ["-c", "printf changed > " + AgentGit.quote(marker.path)])
            let markerValue = try String(contentsOf: marker, encoding: .utf8)
            checks["projectHookScopeCannotModifyCredentialTransport"] = scopeProbe.failed && markerValue == "public-authority-marker"
            let protectedRead = try await transport.run(["-C", transport.repository.path, "hash-object", repo.appendingPathComponent("user.txt").path], endpoint: try AgentGitEndpoint.parse("git@github.com:flyingrtx2333/ai-girlfriend-desktop.git", relativeTo: repo))
            checks["credentialTransportCannotReadOriginalWorkingFiles"] = protectedRead.failed
            let receipt = try await git.push(reviewHash: first.hash)
            checks["actualNetworkPushAndReadbackMatchReviewedCommit"] = receipt.verified && receipt.exitCode == 0 && receipt.afterHead == head
            checks["pushDoesNotIncludeStagingOrWorkingChanges"] = try await setup(["show", "refs/heads/main:user.txt"], at: server) == "original-user-content\n"
            let staged = try await setup(["show", ":user.txt"])
            checks["pushPreservesOtherStagedAndWorkingBytes"] = try staged == "user-staged-preserved\n" && read("user.txt") == "user-working-preserved\n"
            let upstream = try await setup(["rev-parse", "--abbrev-ref", "@{upstream}"])
            checks["requestedUpstreamUsesActualTrackingReference"] = upstream == "origin/main\n"
            let verified = try await AgentGitTransport.verifyReceipt(store: tasks, taskID: id, operationID: receipt.id)
            checks["receiptCanBeVerifiedWithoutRepeatingPush"] = verified.verified && verified.afterHead == head
            checks["completedPushConsumesReviewAndPrivateSnapshot"] = tasks.task(id)?.gitPushReview == nil && !fm.fileExists(atPath: transport.repository.path)
            do { _ = try await git.push(reviewHash: first.hash); checks["consumedReviewCannotReplay"] = false } catch { checks["consumedReviewCannotReplay"] = true }
            let current = try await prepare("main")
            checks["upToDateIsReportedFromActualRemote"] = current.commitCount == 0 && current.remoteHead == head
            _ = try await git.push(reviewHash: current.hash)
            let staleHead = try await prepare("head-changed")
            let tree = try await setup(["rev-parse", "HEAD^{tree}"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let advanced = try await setup(["commit-tree", tree, "-p", head, "-m", "unreviewed later commit"]).trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await setup(["update-ref", "HEAD", advanced, head])
            do { _ = try await git.push(reviewHash: staleHead.hash); checks["changedLocalHeadBlocksPush"] = false } catch { checks["changedLocalHeadBlocksPush"] = true }
            _ = try await setup(["update-ref", "HEAD", head, advanced])
            let staleConfig = try await prepare("config-changed")
            _ = try await setup(["config", "remote.origin.pushurl", remoteURL + "-changed"])
            do { _ = try await git.push(reviewHash: staleConfig.hash); checks["changedDestinationBlocksPush"] = false } catch { checks["changedDestinationBlocksPush"] = true }
            _ = try await setup(["config", "--unset-all", "remote.origin.pushurl"])
            _ = try await setup(["config", "user.name", "Push Acceptance"], at: server); _ = try await setup(["config", "user.email", "push@example.invalid"], at: server)
            let remoteTree = try await setup(["rev-parse", base + "^{tree}"], at: server).trimmingCharacters(in: .whitespacesAndNewlines)
            let divergent = try await setup(["commit-tree", remoteTree, "-p", base, "-m", "remote independent change"], at: server).trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await setup(["update-ref", "refs/heads/divergent", divergent], at: server)
            do { _ = try await prepare("divergent"); checks["nonFastForwardIsRejectedBeforePublishing"] = false } catch { checks["nonFastForwardIsRejectedBeforePublishing"] = true }
            _ = try await setup(["update-ref", "refs/heads/stale-remote", base], at: server)
            let staleRemote = try await prepare("stale-remote")
            _ = try await setup(["update-ref", "refs/heads/stale-remote", divergent, base], at: server)
            do { _ = try await git.push(reviewHash: staleRemote.hash); checks["changedRemoteRefBlocksPush"] = false } catch { checks["changedRemoteRefBlocksPush"] = true }
            let projectHook = repo.appendingPathComponent(".git/hooks/pre-push")
            func hook(_ url: URL, _ body: String) throws {
                try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            try hook(projectHook, "printf '%s\\n%s\\n' \"$1\" \"$2\" > hook-args.txt\ncat > hook-stdin.txt\nprintf 'once\\n' >> hook-count.txt")
            let hookReview = try await prepare("hook-pass"), hookReceipt = try await git.push(reviewHash: hookReview.hash)
            checks["projectPrePushHookReceivesExactArgumentsAndReference"] = try hookReceipt.verified && read("hook-args.txt") == "origin\n" + remoteURL + "\n" && read("hook-stdin.txt") == "refs/heads/main " + head + " refs/heads/hook-pass " + String(repeating: "0", count: head.count) + "\n" && read("hook-count.txt") == "once\n"
            try hook(projectHook, "cat > /dev/null\nexit 9")
            let deniedHook = try await prepare("hook-denied")
            do { _ = try await git.push(reviewHash: deniedHook.hash); checks["failedProjectHookPreventsPublishing"] = false } catch { checks["failedProjectHookPreventsPublishing"] = true }
            let deniedRef = try await setup(["for-each-ref", "--format=%(objectname)", "refs/heads/hook-denied"], at: server)
            checks["failedProjectHookLeavesActualRemoteUnchanged"] = deniedRef.isEmpty
            try fm.removeItem(at: projectHook)
            let serverHook = server.appendingPathComponent("hooks/pre-receive"), gitPath = try AgentGit.executablePath()
            try hook(serverHook, "while read old new ref; do\n if [ \"$ref\" = refs/heads/lease-race ]; then\n  unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH\n  " + AgentGit.quote(gitPath) + " update-ref \"$ref\" " + divergent + " \"$old\" || exit 7\n fi\ndone")
            _ = try await setup(["update-ref", "refs/heads/lease-race", base], at: server)
            let raced = try await prepare("lease-race"), raceReceipt = try await git.push(reviewHash: raced.hash)
            let raceHead = try await setup(["rev-parse", "refs/heads/lease-race"], at: server).trimmingCharacters(in: .whitespacesAndNewlines)
            checks["atomicLeasePreservesConcurrentRemoteCommit"] = !raceReceipt.verified && raceReceipt.exitCode != 0 && raceHead == divergent
            try hook(serverHook, "cat > /dev/null\nexit 11")
            let rejected = try await prepare("server-denied"), rejectedReceipt = try await git.push(reviewHash: rejected.hash)
            let rejectedRef = try await setup(["for-each-ref", "--format=%(objectname)", "refs/heads/server-denied"], at: server)
            checks["actualServerRejectionIsReportedWithoutRetry"] = !rejectedReceipt.verified && rejectedReceipt.exitCode != 0 && rejectedRef.isEmpty
            func slowHook(_ name: String) throws -> URL {
                let marker = server.appendingPathComponent(name + "-ready")
                try hook(serverHook, "printf '%s %s\\n' \"$$\" \"$PPID\" > " + AgentGit.quote(marker.path) + "\nprintf 'attempt\\n' >> " + AgentGit.quote(server.appendingPathComponent(name + "-attempts").path) + "\ncat > /dev/null\nsleep 2")
                return marker
            }
            func receiverPID(_ marker: URL) async throws -> pid_t {
                let limit = Date().addingTimeInterval(10)
                while Date() < limit {
                    if let value = try? String(contentsOf: marker, encoding: .utf8), let pid = value.split(whereSeparator: \.isWhitespace).last.flatMap({ Int32($0) }), pid > 1 { return pid }
                    await wait(0.05)
                }
                throw PetError("实际 Git 服务没有进入接收阶段")
            }
            func receiverFinished(_ pid: pid_t) async -> Bool {
                let limit = Date().addingTimeInterval(10)
                while Date() < limit, kill(pid, 0) == 0 { await wait(0.1) }
                return kill(pid, 0) != 0
            }
            let cancelMarker = try slowHook("cancel"), cancelledReview = try await prepare("cancelled")
            let sending = Task { try await git.push(reviewHash: cancelledReview.hash) }
            let cancelReceiver = try await receiverPID(cancelMarker); git.cancel()
            var cancelled = false
            do { _ = try await sending.value } catch { cancelled = true }
            let cancelTerminal = await receiverFinished(cancelReceiver)
            guard let cancelReceipt = tasks.task(id)?.gitPushReceipt else { throw PetError("取消后缺少待核对记录") }
            let cancelVerified = try await AgentGitTransport.verifyReceipt(store: tasks, taskID: id, operationID: cancelReceipt.id)
            let cancelHead = try await setup(["for-each-ref", "--format=%(objectname)", "refs/heads/cancelled"], at: server).trimmingCharacters(in: .whitespacesAndNewlines)
            let cancelAttempts = try String(contentsOf: server.appendingPathComponent("cancel-attempts"), encoding: .utf8)
            checks["cancelledTransferCanBeVerifiedWithoutBlindRetry"] = cancelled && cancelTerminal && cancelVerified.afterHead == (cancelHead.isEmpty ? nil : cancelHead) && cancelVerified.verified == (cancelHead == head) && cancelAttempts == "attempt\n"
            let timeoutMarker = try slowHook("timeout"), timedReview = try await prepare("timed-out")
            let timing = Task { try await git.push(reviewHash: timedReview.hash, timeout: 1) }
            let timeoutReceiver = try await receiverPID(timeoutMarker), timedReceipt = try await timing.value
            let timeoutTerminal = await receiverFinished(timeoutReceiver)
            let timeoutVerified = try await AgentGitTransport.verifyReceipt(store: tasks, taskID: id, operationID: timedReceipt.id)
            let timeoutHead = try await setup(["for-each-ref", "--format=%(objectname)", "refs/heads/timed-out"], at: server).trimmingCharacters(in: .whitespacesAndNewlines)
            let timeoutAttempts = try String(contentsOf: server.appendingPathComponent("timeout-attempts"), encoding: .utf8)
            checks["timedOutTransferCanBeVerifiedWithoutBlindRetry"] = timedReceipt.exitCode != 0 && timeoutTerminal && timeoutVerified.afterHead == (timeoutHead.isEmpty ? nil : timeoutHead) && timeoutVerified.verified == (timeoutHead == head) && timeoutAttempts == "attempt\n"
            try fm.removeItem(at: serverHook)
            let second = output.appendingPathComponent("remotes/other.git")
            _ = try await setup(["init", "--bare", "--initial-branch=main", second.path])
            _ = try await setup(["config", "--add", "remote.origin.pushurl", remoteURL]); _ = try await setup(["config", "--add", "remote.origin.pushurl", second.path])
            let multiple = try await git.remotes()
            let selectedReview = try await git.preparePush(remote: "origin", urlIndex: 0, branch: "selected-only", setUpstream: false, remoteHash: tasks.task(id)?.gitRemoteSnapshot?.hash)
            let selectedReceipt = try await git.push(reviewHash: selectedReview.hash)
            let otherRefs = try await setup(["for-each-ref", "--format=%(objectname)"], at: second)
            checks["multiplePushAddressesSendOnlyToReviewedSelection"] = multiple.first?.urls.count == 2 && selectedReceipt.verified && otherRefs.isEmpty
            _ = try await setup(["config", "--unset-all", "remote.origin.pushurl"])
            try hook(serverHook, "cat > /dev/null\nprintf 'actual-local-receiver\\n' > " + AgentGit.quote(server.appendingPathComponent("local-hook-result").path))
            try await git.addRemote(name: "local", url: server.path); _ = try await git.remotes()
            let localReview = try await git.preparePush(remote: "local", urlIndex: 0, branch: "local-transport", setUpstream: false, remoteHash: tasks.task(id)?.gitRemoteSnapshot?.hash)
            let localReceipt = try await git.push(reviewHash: localReview.hash)
            let localHook = try String(contentsOf: server.appendingPathComponent("local-hook-result"), encoding: .utf8)
            checks["actualLocalReceiverRunsItsOwnHook"] = localReceipt.verified && localHook == "actual-local-receiver\n"
            try fm.removeItem(at: serverHook)
            _ = try await setup(["remote", "remove", "local"])
            let pending = try await prepare("cross-task")
            let otherID = tasks.create(title: "另一个任务", workspace: repo.path), other = try AgentGit(store: tasks, taskID: otherID, directory: git.directory)
            do { _ = try other.storedPushReview(hash: pending.hash); checks["reviewDoesNotCrossTaskAuthority"] = false } catch { checks["reviewDoesNotCrossTaskAuthority"] = true }
            tasks.update(id) { $0.permission = .automatic }
            let tools = AgentTools(store: tasks, taskID: id)
            let pushArguments = try JSONSerialization.data(withJSONObject: ["review_hash": pending.hash])
            let mandatory = try tools.approvalReason(for: AgentToolCall(id: "approval-probe", name: "git_push", arguments: String(decoding: pushArguments, as: UTF8.self)), gitDirectory: git.directory.path)
            checks["dedicatedPushStillRequiresApprovalInAutomaticMode"] = mandatory?.contains("推送已审阅提交") == true
            tasks.update(id) { $0.permission = .workspace }
            tasks.update(id) { $0.gitPushReview?.processID = UUID().uuidString }
            do { _ = try git.storedPushReview(hash: pending.hash); checks["reviewCannotResumeAcrossApplicationSessions"] = false } catch { checks["reviewCannotResumeAcrossApplicationSessions"] = true }
            try AgentGitTransport(store: tasks, taskID: id, sessionID: pending.sessionID).cleanup()
            _ = try await setup(["remote", "add", "unsafe", "https://public-token-marker@127.0.0.1/repo.git"])
            let safeList = try await git.remotes()
            checks["remoteListDoesNotExposeEmbeddedCredentials"] = !safeList.flatMap(\.urls).joined().contains("public-token-marker")
            do { _ = try await git.preparePush(remote: "unsafe", urlIndex: 0, branch: "main", setUpstream: false); checks["embeddedCredentialsAreRejectedBeforeConnection"] = false } catch { checks["embeddedCredentialsAreRejectedBeforeConnection"] = true }
            _ = try await setup(["remote", "remove", "unsafe"])
            do { _ = try AgentGitEndpoint.parse("ext::/bin/sh -c anything", relativeTo: repo); checks["externalRemoteProgramsAreRejected"] = false } catch { checks["externalRemoteProgramsAreRejected"] = true }
            let readonly = AgentTools.definitions(mode: .ask, groups: ["git"])
            checks["readOnlyModeDoesNotAdvertisePush"] = !readonly.contains { ($0["function"] as? [String: Any])?["name"] as? String == "git_push" }
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("原生推送检查未通过") }
            if CommandLine.arguments.contains("--probe-ssh") {
                let probe = try AgentGitTransport(store: tasks, taskID: id); defer { probe.cleanup() }; try await probe.initialize()
                let input = try AgentGitEndpoint.parse("git@github.com:flyingrtx2333/ai-girlfriend-desktop.git", relativeTo: repo), destination = try await probe.effective(input)
                let response = try await probe.output(["-C", probe.repository.path, "ls-remote", "--", input.input, "HEAD"], endpoint: destination)
                let oid = response.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                checks["existingSSHIdentityReadsActualGitHubWithoutPublishing"] = oid.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
                report["sshProbe"] = ["url": destination.location, "head": oid, "readOnly": true, "privateKeysCopied": false]
            }
            var uiID = id
            if CommandLine.arguments.contains("--live-agent") {
                let profile = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
                var p = PreferencesStore(directory: profile).preferences; p.voiceEnabled = false; p.wakeEnabled = false; p.screenObservationEnabled = false; store.preferences = p
                guard let runtime = agentRuntime else { throw PetError("模型运行不可用") }
                let target = "model-" + String(UUID().uuidString.lowercased().prefix(8)), liveID = tasks.create(title: "真实模型推送并核对", workspace: repo.path, mode: .agent)
                runtime.submit("只用 git 工具把当前分支已有提交推送到 origin 的 \(target) 分支，set_upstream=false。不创建提交，不修改或暂存任何原有文件。先 git_remotes 取实际列表及 remote_hash，再 git_prepare_push、git_push；verified=true 后用 git_push_status 再核对一次。批准由验收人员处理。最后用 write_file 创建 push-result.json，合法JSON只含 branch、sourceHead、remoteHead、verified 四个字段，值取实际结果，并用 read_file 回读确认。不使用 run_command、浏览器或其他远端。", taskID: liveID)
                let deadline = Date().addingTimeInterval(240); var approvals: [String] = [], held = false
                while Date() < deadline, let task = tasks.task(liveID), [.ready, .running, .waiting].contains(task.status) {
                    if task.status == .waiting, let call = task.pendingCalls.first {
                        guard ["git_prepare_push", "git_push", "git_push_status"].contains(call.name), approvals.count < 6 else { runtime.cancel(liveID); throw PetError("真实流程提出了预期外操作：" + call.name) }
                        if call.name == "git_prepare_push" {
                            guard call.object["remote"] as? String == "origin", call.object["branch"] as? String == target, call.object["remote_hash"] as? String == task.gitRemoteSnapshot?.hash else { runtime.cancel(liveID); throw PetError("连接目标与实际要求不一致") }
                        }
                        if call.name == "git_push" {
                            guard let review = task.gitPushReview, review.endpoint.location == remoteURL, review.targetBranch == target, review.sourceHead == head, review.hash == call.object["review_hash"] as? String else { runtime.cancel(liveID); throw PetError("推送审阅与实际目标不一致") }
                            let beforePush = try await AgentGitTransport(store: tasks, taskID: liveID, sessionID: review.sessionID).remoteHead(input: try AgentGitEndpoint.parse(remoteURL, relativeTo: repo), endpoint: review.endpoint, branch: target)
                            held = beforePush == nil
                        }
                        approvals.append(call.name); runtime.decide(taskID: liveID, callID: call.id, decision: "allow")
                    }
                    await wait(0.1)
                }
                guard let task = tasks.task(liveID), task.status == .completed, let actual = task.gitPushReceipt else { runtime.cancel(liveID); throw PetError("真实模型推送未完成") }
                let result = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("push-result.json"))) as? [String: Any]
                let remoteHead = try await setup(["rev-parse", "refs/heads/" + target], at: server).trimmingCharacters(in: .whitespacesAndNewlines)
                checks["realModelWaitsForConcretePushApproval"] = held && approvals.contains("git_prepare_push") && approvals.contains("git_push") && approvals.contains("git_push_status")
                checks["realModelReportMatchesActualRemoteRef"] = actual.verified && remoteHead == head && result?["branch"] as? String == target && result?["sourceHead"] as? String == head && result?["remoteHead"] as? String == head && result?["verified"] as? Bool == true && result?.count == 4
                report["live"] = ["taskID": liveID, "branch": target, "sourceHead": head, "model": p.model, "contextLimit": p.contextLimit, "outputLimit": p.outputLimit, "inputTokens": task.inputTokens, "outputTokens": task.outputTokens, "approvals": approvals, "summary": task.summary]
                uiID = liveID
            }
            try write("ui.txt", "public-ui-commit-" + String(UUID().uuidString.prefix(8)) + "\n")
            let pushWindow = try AgentGitPushWindow(store: tasks, taskID: uiID, directory: git.directory)
            checks.merge(await pushWindow.checkLayout(output)) { _, value in value }; pushWindow.close()
            let window = AgentGitWindow(store: tasks, taskID: uiID) { _ in }
            checks.merge(await window.checkLayout(output)) { _, value in value }
            window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            report["taskID"] = uiID; report["nativeTaskID"] = id; report["sourceHead"] = head; report["baseHead"] = base; report["workspace"] = repo.path; report["remoteURL"] = remoteURL
            report["success"] = checks.values.allSatisfy { $0 }; report["checks"] = checks; report["scope"] = "Real Git TCP server and independent bare repository; actual prepared commit snapshot, lease, index and tracking updates. Existing SSH probe is read-only. Live model runs only with --live-agent and uses saved budgets. No production repository push or private-key copy."
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("git-push-report.json"))
            if CommandLine.arguments.contains("--hold-ui") {
                try Data("ui-ready".utf8).write(to: output.appendingPathComponent("phase"))
                let limit = Date().addingTimeInterval(1200)
                while Date() < limit, !fm.fileExists(atPath: output.appendingPathComponent("finish-ui").path) { await wait(0.25) }
            }
            window.close()
        } catch {
            report["success"] = false; report["checks"] = checks; report["error"] = error.localizedDescription
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("git-push-report.json"))
        }
    }
}
