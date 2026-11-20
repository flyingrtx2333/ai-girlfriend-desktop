import AppKit

@MainActor extension AppDelegate {
    func configurePluginMarketFixture(_ output: URL, plugins: AgentPlugins) throws -> (origin: URL, network: URLSession) {
        guard checkDirectory == output, Bundle.main.object(forInfoDictionaryKey: "BlueFatFishAcceptanceOnly") as? Bool == true else {
            throw PetError("插件市场样例只可在独立验收包中使用")
        }
        let ready = try AgentConfigurationJSON.object(Data(contentsOf: output.appendingPathComponent("server/ready.json")))
        guard let text = ready["origin"] as? String, let origin = URL(string: text), origin.scheme == "https", origin.host == "localhost", let port = origin.port else {
            throw PetError("插件市场样例必须使用本机 HTTPS 服务")
        }
        let certificate = try Data(contentsOf: output.appendingPathComponent("server/test-cert.der"))
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 12
        let network = URLSession(configuration: config, delegate: AgentCheckLocalTLS(certificate: certificate, port: port), delegateQueue: nil)
        plugins.market = AgentPluginMarket(profile: plugins.profile, network: network, fixtureOrigin: origin)
        return (origin, network)
    }

    func runPluginMarketCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], results: [String: String] = [:], requests = 0, failure = ""
        defer { agentRuntime?.stopAll() }
        do {
            ensureAgent()
            guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("Agent 未初始化") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("市场验收禁止模型请求") }
            let plugins = tasks.extensions.plugins
            let (origin, network) = try configurePluginMarketFixture(output, plugins: plugins)
            defer { network.invalidateAndCancel() }
            let market = plugins.market, listing = origin.appendingPathComponent("marketplace.json")
            let other = origin.appendingPathComponent("other-marketplace.json")
            func entry(_ name: String, _ directory: AgentPluginMarket.Directory) throws -> AgentPluginMarket.Entry {
                guard let value = directory.entries.first(where: { $0.name == name }) else { throw PetError("市场样例条目缺失") }; return value
            }
            func serverState(_ query: String) async throws {
                var request = URLRequest(url: URL(string: origin.absoluteString + "/fixture?" + query)!)
                request.httpMethod = "POST"
                let (_, response) = try await network.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PetError("无法切换样例目录版本") }
            }
            func readInventory(_ phase: String) async throws {
                guard let skill = try tasks.extensions.catalog(workspace: nil).first(where: { $0.name == "inventory-helper:inventory" }) else { throw PetError("安装的库存 Skill 未载入") }
                let task = tasks.create(title: "公开库存 " + phase, mode: .ask, workMode: .general)
                guard runtime.submit("/skill:inventory-helper:inventory 读取公开库存。", taskID: task, startImmediately: false) else { throw PetError("库存 Skill 未加入样例任务") }
                let data = try JSONSerialization.data(withJSONObject: ["id": skill.id, "path": "resources/count.json"])
                let call = AgentToolCall(id: "market-resource-check", name: "read_skill_resource", arguments: String(decoding: data, as: UTF8.self))
                let result = try await AgentTools(store: tasks, taskID: task).execute(call)
                guard !result.failed else { throw PetError("库存资源读取失败") }; results[phase] = result.text
            }

            let first = try await market.refresh(listing.absoluteString)
            checks["readsRealDirectoryAndCategories"] = first.publisher == "公开样例目录" && first.entries.count == 4
                && Set(first.entries.map(\.category)) == ["工作流", "开发", "检查"]
            checks["separatesUnsupportedSourceAndOptionalDigest"] = try entry("source-not-supported", first).unavailable != nil && entry("review-notes", first).archive != nil && entry("review-notes", first).digest == nil
            do { _ = try await market.prepare(entry("checksum-test", first), in: first, scope: nil, plugins: plugins); checks["mismatchedDigestRefused"] = false }
            catch { checks["mismatchedDigestRefused"] = try error.localizedDescription.contains("SHA-256") && plugins.catalog().isEmpty }
            let initialEntry = try entry("inventory-helper", first)
            let (v1, none) = try await market.prepare(initialEntry, in: first, scope: nil, plugins: plugins)
            checks["downloadAndReviewDoNotInstall"] = try none == nil && plugins.catalog().isEmpty && v1.receipt.sourceHash == initialEntry.digest
            let original = try plugins.install(v1)
            checks["installedArchiveStartsDisabledAndPinsOrigin"] = !original.enabled && original.metadata.version == "1.0.0"
                && original.receipt.marketOrigin?.matches(first, entry: initialEntry.name) == true
            try plugins.setEnabled(original, true)
            try await readInventory("install")
            let active = try plugins.installation(original.id)
            do { _ = try await market.prepare(initialEntry, in: first, scope: nil, plugins: plugins); checks["equalArchiveDoesNotCreateUpdate"] = false }
            catch { checks["equalArchiveDoesNotCreateUpdate"] = error.localizedDescription.contains("已是目录") }

            try await serverState("version=2.0.0")
            let second = try await market.refresh(listing.absoluteString)
            let (v2, update) = try await market.prepare(entry("inventory-helper", second), in: second, scope: nil, plugins: plugins)
            checks["previewPinsSameOriginAndOldVersion"] = update?.receiptHash == active.receiptHash && v2.metadata.version == "2.0.0" && update?.enabled == true
            guard let update else { throw PetError("市场更新缺少原版本") }
            let applied = try plugins.update(v2, replacing: update)
            guard let record = applied.receipt.revisions?.first else { throw PetError("市场更新没有原版本记录") }
            let previous = try plugins.revision(record, of: applied)
            checks["updateStartsDisabledAndRetainsExactOldArchive"] = !applied.enabled && applied.metadata.version == "2.0.0"
                && previous.receiptHash == active.receiptHash && previous.receipt.marketOrigin == active.receipt.marketOrigin
            try plugins.setEnabled(applied, true)
            try await readInventory("update")
            let upgraded = try plugins.installation(applied.id)
            let unrelated = try await market.refresh(other.absoluteString)
            do { _ = try await market.prepare(entry("inventory-helper", unrelated), in: unrelated, scope: nil, plugins: plugins); checks["differentMarketCannotReplaceNamesake"] = false }
            catch { checks["differentMarketCannotReplaceNamesake"] = try error.localizedDescription.contains("其他来源") && plugins.installation(applied.id).receiptHash == upgraded.receiptHash }
            _ = try await market.refresh(listing.absoluteString)
            try await serverState("invalid=1")
            do { _ = try await market.refresh(listing.absoluteString); checks["invalidReloadKeepsUsableCache"] = false }
            catch { checks["invalidReloadKeepsUsableCache"] = try market.cachedDirectory()?.address == listing && market.cachedDirectory()?.entries.first?.version == "2.0.0" }

            let restored = try plugins.update(plugins.package(record, of: upgraded), replacing: upgraded)
            checks["restorePreservesMarketplaceReceiptAndStockBytes"] = restored.receipt.marketOrigin == original.receipt.marketOrigin
                && restored.receipt.hashes == original.receipt.hashes && restored.metadata.version == "1.0.0" && !restored.enabled
            checks["resourceReadsMatchBothInstalledVersions"] = results["install"]?.contains("42") == true && results["update"]?.contains("88") == true
        } catch { failure = error.localizedDescription }
        let report: [String: Any] = ["checks": checks, "results": results, "error": failure, "modelRequests": requests, "appPID": getpid(),
            "success": failure.isEmpty && checks.count == 12 && checks.values.allSatisfy { $0 } && requests == 0]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("plugin-market-report.json"))
    }
}
