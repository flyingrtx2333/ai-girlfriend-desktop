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
            let repositoryAddress = URL(string: "https://github.com/fixture-lab/extensions")!
            let files = try AgentFiles(workspace: plugins.profile.path, followParentLinks: false)
            let cache = try files.literalURL("extensions/plugin-market.json")
            struct LegacyCache: Encodable { let address: URL, catalog: Data }
            struct Revision: Decodable { let commit: String }
            let revisions = try JSONDecoder().decode([Revision].self, from: Data(contentsOf: output.appendingPathComponent("server/repository-facts.json")))
            guard revisions.count == 2 else { throw PetError("缺少两次仓库样例提交") }
            let sha1 = revisions[0].commit, sha2 = revisions[1].commit
            func entry(_ name: String, _ directory: AgentPluginMarket.Directory) throws -> AgentPluginMarket.Entry {
                guard let value = directory.entries.first(where: { $0.name == name }) else { throw PetError("市场样例条目缺失") }; return value
            }
            func serverState(_ query: String) async throws {
                var request = URLRequest(url: URL(string: origin.absoluteString + "/fixture?" + query)!)
                request.httpMethod = "POST"
                let (_, response) = try await network.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PetError("无法切换样例目录版本") }
            }
            func load(_ address: URL) async throws -> AgentPluginMarket.Directory {
                guard let selected = try await market.refresh(address.absoluteString).selected else { throw PetError("目录未选中") }
                return selected
            }
            func readInventory(_ phase: String, plugin: String = "inventory-helper") async throws {
                let name = plugin + ":inventory"
                guard let skill = try tasks.extensions.catalog(workspace: nil).first(where: { $0.name == name }) else { throw PetError("安装的库存 Skill 未载入") }
                let task = tasks.create(title: "公开库存 " + phase, mode: .ask, workMode: .general)
                guard runtime.submit("/skill:" + name + " 读取公开库存。", taskID: task, startImmediately: false) else { throw PetError("库存 Skill 未加入样例任务") }
                let data = try JSONSerialization.data(withJSONObject: ["id": skill.id, "path": "resources/count.json"])
                let call = AgentToolCall(id: "market-resource-check", name: "read_skill_resource", arguments: String(decoding: data, as: UTF8.self))
                let result = try await AgentTools(store: tasks, taskID: task).execute(call)
                guard !result.failed else { throw PetError("库存资源读取失败") }; results[phase] = result.text
            }

            let (legacyBody, _) = try await network.data(from: listing)
            let originalCache = try JSONEncoder().encode(LegacyCache(address: listing, catalog: legacyBody))
            try files.writeData(originalCache, to: cache, permissions: 0o600)
            checks["legacySingleCatalogIsReadableWithoutRewrite"] = try market.cachedCatalogs().selected?.address == listing && files.readData(cache) == originalCache

            let first = try await load(listing)
            checks["readsRealDirectoryAndCategories"] = first.publisher == "公开样例目录" && first.entries.count == 6
                && Set(first.entries.map(\.category)) == ["工作流", "开发", "检查"]
            let plain = try entry("review-notes", first)
            if case .archive(_, nil)? = plain.source {
                checks["separatesUnsupportedSourceAndOptionalDigest"] = try entry("source-not-supported", first).unavailable != nil
            }
            do { _ = try await market.prepare(entry("checksum-test", first), in: first, scope: nil, plugins: plugins); checks["mismatchedDigestRefused"] = false }
            catch { checks["mismatchedDigestRefused"] = try error.localizedDescription.contains("SHA-256") && plugins.catalog().isEmpty }
            let initialEntry = try entry("inventory-helper", first)
            let (v1, none) = try await market.prepare(initialEntry, in: first, scope: nil, plugins: plugins)
            checks["downloadAndReviewDoNotInstall"] = try none == nil && plugins.catalog().isEmpty && initialEntry.source?.matches(v1.receipt) == true
            let original = try plugins.install(v1)
            checks["installedArchiveStartsDisabledAndPinsOrigin"] = !original.enabled && original.metadata.version == "1.0.0"
                && original.receipt.marketOrigin?.matches(first, entry: initialEntry.name) == true
            try plugins.setEnabled(original, true)
            try await readInventory("install")
            let active = try plugins.installation(original.id)
            do { _ = try await market.prepare(initialEntry, in: first, scope: nil, plugins: plugins); checks["equalArchiveDoesNotCreateUpdate"] = false }
            catch { checks["equalArchiveDoesNotCreateUpdate"] = error.localizedDescription.contains("已是目录") }

            async let near = load(other)
            async let far = load(URL(string: "https://github.com/Fixture-Lab/Extensions.git")!)
            let (another, repositoryV1) = try await (near, far)
            let addresses = [listing, other, repositoryAddress]
            checks["simultaneousDirectoryLoadsPreserveAllSources"] = try Set(market.cachedCatalogs().directories.map(\.address)) == Set(addresses)
                && repositoryV1.address == repositoryAddress && another.address == other
            checks["invalidRepositoryPathRefusedBeforeDownload"] = try entry("invalid-path", repositoryV1).source == nil
                && entry("invalid-path", repositoryV1).unavailable?.contains("路径") == true
            let (rootV1, rootAbsent) = try await market.prepare(entry("repo-workflow", first), in: first, scope: nil, plugins: plugins)
            let root = try plugins.install(rootV1)
            checks["githubRefResolvesAndPinsRootInstallation"] = rootAbsent == nil && root.receipt.marketOrigin?.commit?.sha == sha1
                && root.receipt.marketOrigin?.repositoryPath == "" && !root.enabled
            try plugins.setEnabled(root, true)
            try await readInventory("rootInstall", plugin: "repo-workflow")

            let repoInitialEntry = try entry("repo-stock", repositoryV1)
            let (repoV1, absent) = try await market.prepare(repoInitialEntry, in: repositoryV1, scope: nil, plugins: plugins)
            let branchStock = try plugins.install(repoV1)
            checks["relativePackageUsesOnlyItsSelectedFolder"] = absent == nil && branchStock.receipt.marketOrigin?.commit?.sha == sha1
                && branchStock.receipt.marketOrigin?.repositoryPath == "plugins/repo-stock"
                && repoV1.files.keys.allSatisfy { !$0.hasPrefix("plugins/") } && !branchStock.enabled
            try plugins.setEnabled(branchStock, true)
            try await readInventory("repoInstall", plugin: "repo-stock")

            try await serverState("version=2.0.0")
            let second = try await load(listing)
            let cachedRepo = try market.select(repositoryAddress)
            guard let oldRepo = cachedRepo.selected else { throw PetError("缺少已保存的仓库目录") }
            let (cachedPackage, _) = try await market.prepare(entry("other", oldRepo), in: oldRepo, scope: nil, plugins: plugins)
            checks["savedDirectoryStillFetchesItsOriginalGitCommit"] = cachedPackage.receipt.marketOrigin?.commit?.sha == sha1
                && cachedPackage.metadata.version == "1.0.0"

            let separateProject = output.appendingPathComponent("pinned-project")
            try FileManager.default.createDirectory(at: separateProject, withIntermediateDirectories: true)
            let (pinned, _) = try await market.prepare(entry("repo-stock", second), in: second, scope: separateProject.path, plugins: plugins)
            checks["explicitGitSHAWinsOverRemovedRef"] = pinned.receipt.marketOrigin?.commit?.sha == sha1 && pinned.metadata.version == "1.0.0"

            let (rootV2, rootUpdate) = try await market.prepare(entry("repo-workflow", second), in: second, scope: nil, plugins: plugins)
            guard let rootUpdate else { throw PetError("缺少仓库根目录更新") }
            let updatedRoot = try plugins.update(rootV2, replacing: rootUpdate)
            checks["branchUpdateUsesLatestResolvedCommit"] = updatedRoot.receipt.marketOrigin?.commit?.sha == sha2 && !updatedRoot.enabled
            try plugins.setEnabled(updatedRoot, true)
            try await readInventory("rootUpdate", plugin: "repo-workflow")

            let repositoryV2 = try await load(repositoryAddress)
            let relativeV2 = try entry("repo-stock", repositoryV2)
            let (repoV2, candidate) = try await market.prepare(relativeV2, in: repositoryV2, scope: nil, plugins: plugins)
            guard let candidate else { throw PetError("缺少仓库子目录更新") }
            let currentStock = try plugins.update(repoV2, replacing: candidate)
            guard let savedVersion = currentStock.receipt.revisions?.first else { throw PetError("仓库更新缺少历史版本") }
            let oldStock = try plugins.revision(savedVersion, of: currentStock)
            checks["relativeUpdateKeepsExactBothRepositoryRevisions"] = currentStock.receipt.marketOrigin?.commit?.sha == sha2
                && oldStock.receipt.marketOrigin?.commit?.sha == sha1 && candidate.id == branchStock.id
                && oldStock.receipt.hashes == branchStock.receipt.hashes && !currentStock.enabled
            checks["knownRepositoryVersionRecognizesInstalledReceipt"] = relativeV2.source?.matches(currentStock.receipt) == true
            try plugins.setEnabled(currentStock, true)
            try await readInventory("repoUpdate", plugin: "repo-stock")
            let exactStock = try plugins.installation(currentStock.id)
            do { _ = try await market.prepare(entry("repo-stock", second), in: second, scope: nil, plugins: plugins); checks["repositorySameNameAcrossDirectoryCannotReplace"] = false }
            catch { checks["repositorySameNameAcrossDirectoryCannotReplace"] = try error.localizedDescription.contains("其他来源") && plugins.installation(currentStock.id).receiptHash == exactStock.receiptHash }

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
            let unrelated = try await load(other)
            do { _ = try await market.prepare(entry("inventory-helper", unrelated), in: unrelated, scope: nil, plugins: plugins); checks["differentMarketCannotReplaceNamesake"] = false }
            catch { checks["differentMarketCannotReplaceNamesake"] = try error.localizedDescription.contains("其他来源") && plugins.installation(applied.id).receiptHash == upgraded.receiptHash }
            _ = try market.select(listing)
            checks["selectionPersistsWithoutNetwork"] = try AgentPluginMarket(profile: plugins.profile).cachedCatalogs().selected?.address == listing
            try await serverState("invalid=1")
            do { _ = try await market.refresh(listing.absoluteString); checks["invalidReloadKeepsUsableCache"] = false }
            catch {
                let reopened = try market.cachedCatalogs()
                checks["invalidReloadKeepsUsableCache"] = reopened.selection == listing && reopened.directories.count == 3
                    && reopened.selected?.entries.first?.version == "2.0.0"
            }
            _ = try market.select(repositoryAddress)
            let remaining = try market.remove(repositoryAddress)
            checks["removingSelectedDirectoryKeepsOtherSourcesAndItsInstalledPlugin"] = try remaining.directories.count == 2
                && remaining.selection == listing && plugins.installation(currentStock.id).receiptHash == exactStock.receiptHash
            checks["priorVersionCanStillReadItsOriginalCache"] = try files.readData(cache) == originalCache

            let restored = try plugins.update(plugins.package(record, of: upgraded), replacing: upgraded)
            checks["restorePreservesMarketplaceReceiptAndStockBytes"] = restored.receipt.marketOrigin == original.receipt.marketOrigin
                && restored.receipt.hashes == original.receipt.hashes && restored.metadata.version == "1.0.0" && !restored.enabled
            checks["resourceReadsMatchBothInstalledVersions"] = results["install"]?.contains("42") == true && results["update"]?.contains("88") == true
        } catch { failure = error.localizedDescription }
        let report: [String: Any] = ["checks": checks, "results": results, "error": failure, "modelRequests": requests, "appPID": getpid(),
            "success": failure.isEmpty && checks.count == 26 && checks.values.allSatisfy { $0 } && requests == 0]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("plugin-market-report.json"))
    }
}
