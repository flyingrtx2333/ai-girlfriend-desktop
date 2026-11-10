import AppKit

@MainActor extension AppDelegate {
    func runAgentTaskFindCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], requests = 0
        let binary = Bundle.main.executableURL!, hash = (try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)) ?? ""
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        do {
            try write(["appPID": getpid(), "binaryHash": hash], "task-find-started.json")
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("任务内查找验收不调用模型") }
            let workspace = output.appendingPathComponent("workspace"), sourceURL = workspace.appendingPathComponent("README.md"), corpusURL = workspace.appendingPathComponent("README-repeated.md")
            let source = try String(contentsOf: sourceURL, encoding: .utf8), corpus = try String(contentsOf: corpusURL, encoding: .utf8)
            let sources = [AgentTaskFind.Source(messageID: UUID().uuidString, text: corpus), .init(messageID: UUID().uuidString, text: source)]
            var queryReports: [[String: Any]] = []
            for query in ["小鲸", "🐳", "$ARGUMENTS", "APPKIT"] {
                let index = try await Task.detached(priority: .userInitiated) { try AgentTaskFind.build(sources, query: query) }.value
                let positions = Array(Set([0, 1, 255, 256, index.count - 1].filter { $0 >= 0 && $0 < index.count })).sorted()
                let samples = positions.compactMap { position -> [String: Any]? in
                    guard let match = index.match(at: position) else { return nil }
                    return ["index": position, "messageID": match.source.messageID, "location": match.range.location, "length": match.range.length, "occurrence": match.occurrence]
                }
                checks["actualFileQuery-" + query] = index.count > 0 && samples.count == positions.count && positions.allSatisfy { position in
                    guard let match = index.match(at: position) else { return false }
                    return (match.source.text as NSString).substring(with: match.range).compare(query, options: .caseInsensitive) == .orderedSame
                }
                if query == "小鲸" { checks["multipleCheckpointBlocksWithoutPerHitPositions"] = index.count > 256 && index.checkpointCount < index.count / 8 }
                checks["invalidPositionsRejected-" + query] = index.match(at: -1) == nil && index.match(at: index.count) == nil
                queryReports.append(["query": query, "count": index.count, "checkpoints": index.checkpointCount, "samples": samples])
            }
            let noMatch = try AgentTaskFind.build(sources, query: "不存在的查找验收词-7381"), blank = try AgentTaskFind.build(sources, query: "")
            checks["emptyAndAbsentQueriesHaveNoMatch"] = noMatch.count == 0 && blank.count == 0 && noMatch.match(at: 0) == nil && blank.match(at: 0) == nil
            let originalBytes = try Data(contentsOf: output.appendingPathComponent("actual-reply-source.json")), actual = try JSONDecoder().decode(AgentTaskRecord.self, from: originalBytes)
            guard let reply = actual.messages.last(where: { message in message.isReply && (actual.modelReceipts ?? []).contains { $0.completed && $0.messageID == message.id && $0.returnedModel?.isEmpty == false } }) else { throw PetError("需要带实际模型回执的原始助手答复，不能构造替代答复") }
            let row = ChatMessageRow(message: ChatMessage(id: reply.id, role: reply.role, content: reply.content), workbench: true)
            let rendered = row.label.attributedStringValue, displayed = row.label.stringValue
            let renderedIndex = try AgentTaskFind.build([.init(messageID: reply.id, text: displayed)], query: "project/readme-review")
            guard let match = renderedIndex.match(at: 0) else { throw PetError("实际答复中缺少本轮公开README规则引用") }
            let originalFont = rendered.attribute(.font, at: match.range.location, effectiveRange: nil) as? NSFont
            row.update(reply.content, searchQuery: renderedIndex.query, searchDisplayRange: match.range, searchDisplayText: displayed)
            checks["realReplyHighlightPreservesRenderedMarkdown"] = displayed != reply.content && row.label.stringValue == displayed && row.searchRange == match.range && !row.searchUsesSource && (row.label.attributedStringValue.attribute(.font, at: match.range.location, effectiveRange: nil) as? NSFont) == originalFont && row.label.attributedStringValue.attribute(.backgroundColor, at: match.range.location, effectiveRange: nil) != nil
            row.clearSearchHighlight(); checks["clearRestoresActualReplyFormattingExactly"] = rendered.isEqual(to: row.label.attributedStringValue)
            row.update(reply.content, searchQuery: renderedIndex.query, searchDisplayRange: match.range, searchDisplayText: displayed + "已变化")
            checks["staleRenderedVersionNeverReceivesOldHighlight"] = row.searchRange == nil && row.label.stringValue == displayed
            row.update(reply.content, searchQuery: renderedIndex.query, searchDisplayRange: NSRange(location: Int.max, length: 1), searchDisplayText: displayed)
            checks["invalidRenderedRangeRejectedWithoutCrash"] = row.searchRange == nil
            let legacyRoot = output.appendingPathComponent("legacy-v2"), legacyURL = legacyRoot.appendingPathComponent("shortcuts.json")
            try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
            let legacyData = try JSONSerialization.data(withJSONObject: ["version": 2, "bindings": ["newTask": ["key": "f", "modifiers": NSEvent.ModifierFlags.command.rawValue]]], options: [.sortedKeys])
            try legacyData.write(to: legacyURL); try legacyData.write(to: output.appendingPathComponent("legacy-v2-original.json"))
            let legacy = AgentShortcuts(directory: legacyRoot)
            let legacyReadback = try Data(contentsOf: legacyURL)
            checks["v2CustomFindKeyPreservedWithoutWrite"] = legacy.error == nil && legacy.binding(.newTask) == .init("f", .command) && legacy.binding(.findInTask) == .cleared && legacyReadback == legacyData
            try legacy.set(.init("f", .command), for: .newTask)
            let migrated = try Data(contentsOf: legacyURL); try migrated.write(to: output.appendingPathComponent("legacy-v2-migrated.json"))
            checks["v3ClearFindBindingReopens"] = AgentShortcuts(directory: legacyRoot).binding(.findInTask) == .cleared
            do { try legacy.set(nil, for: .findInTask); checks["conflictingFindRestoreKeepsOriginalBytes"] = false }
            catch { checks["conflictingFindRestoreKeepsOriginalBytes"] = try Data(contentsOf: legacyURL) == migrated }
            try legacy.set(.init("f", [.command, .option]), for: .newTask); try legacy.set(nil, for: .findInTask)
            checks["explicitReleaseCanRestoreDefaultFind"] = AgentShortcuts(directory: legacyRoot).binding(.findInTask) == .init("f", .command)
            let first = tasks.create(title: "README 正文查找", workspace: workspace.path, mode: .ask), publicPart = source.components(separatedBy: "\n").prefix(32).joined(separator: "\n")
            guard runtime.submit(publicPart, taskID: first, startImmediately: false), runtime.submit(publicPart, taskID: first, startImmediately: false) else { throw PetError("公开输入未能通过正常用户提交入口保存") }
            tasks.update(first) { $0.draft = "小鲸：保留这份尚未发送的草稿。" }
            let second = tasks.create(title: "独立任务查找", mode: .ask, workMode: .general)
            guard runtime.submit(source.components(separatedBy: "\n").first ?? "", taskID: second, startImmediately: false) else { throw PetError("独立任务输入未保存") }
            tasks.update(second) { $0.draft = "另一份未发送的草稿。" }; tasks.selectedID = first
            checks["realSubmittedUserHistoriesAndIndependentDrafts"] = tasks.task(first)?.messages.count == 2 && tasks.task(second)?.messages.count == 1 && tasks.task(first)?.draft == "小鲸：保留这份尚未发送的草稿。" && tasks.task(second)?.draft == "另一份未发送的草稿。"
            checks["genuineReplySourceAndPublicFilesUnchanged"] = try Data(contentsOf: output.appendingPathComponent("actual-reply-source.json")) == originalBytes && String(contentsOf: sourceURL, encoding: .utf8) == source && String(contentsOf: corpusURL, encoding: .utf8) == corpus
            checks["noModelAttemptNewAssistantReceiptOrJob"] = requests == 0 && tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { !$0.messages.contains { $0.role == "assistant" } && ($0.modelReceipts ?? []).isEmpty && !runtime.isRunning($0.id) }
            try write(["sources": sources.map { ["messageID": $0.messageID, "sha256": AgentFiles.hash(Data($0.text.utf8)), "utf16Length": $0.text.utf16.count] as [String: Any] }, "queries": queryReports, "publicTaskID": first, "otherTaskID": second, "genuineSourceHash": AgentFiles.hash(originalBytes), "genuineReplyID": reply.id, "genuineReceiptIDs": (actual.modelReceipts ?? []).filter { $0.messageID == reply.id }.map(\.id)], "task-find-data.json")
            try write(["appPID": getpid(), "binaryHash": hash, "checks": checks, "blockedModelAttempts": requests, "success": checks.values.allSatisfy { $0 }], "task-find-result.json")
        } catch { try? write(["appPID": getpid(), "binaryHash": hash, "checks": checks, "blockedModelAttempts": requests, "success": false, "error": error.localizedDescription], "task-find-result.json") }
    }
}
