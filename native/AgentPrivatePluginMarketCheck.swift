import Foundation

@MainActor extension AppDelegate {
    func checkPrivatePluginMarket(_ output: URL, origin: URL, network: URLSession, firstSHA: String, secondSHA: String) async throws
        -> (checks: [String: Bool], results: [String: String]) {
        let profile = output.appendingPathComponent("private-market-profile")
        let plugins = AgentPlugins(profile: profile)
        let certificate = try Data(contentsOf: output.appendingPathComponent("server/test-cert.pem"))
        let market = AgentPluginMarket(profile: profile, network: network, fixtureOrigin: origin,
            gitFixture: .init(origin: origin, certificate: certificate))
        let catalog = origin.appendingPathComponent("private/marketplace.json")
        let repository = origin.appendingPathComponent("private-git/catalog.git")
        let stored = PetCredentialConfig(file: profile.appendingPathComponent("credentials.json"))
        let bearer = try AgentPluginMarketCredential(username: "", token: "market-test-bearer", requiresUsername: false)
        let basic = try AgentPluginMarketCredential(username: "market-example", token: "market-test-basic", requiresUsername: true)
        let wrong = try AgentPluginMarketCredential(username: "", token: "market-fixture-wrong", requiresUsername: false)
        var checks: [String: Bool] = [:], results: [String: String] = [:]

        func publish(_ version: String) async throws {
            var request = URLRequest(url: URL(string: origin.absoluteString + "/fixture?version=" + version)!)
            request.httpMethod = "POST"
            let (_, response) = try await network.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PetError("无法切换私有目录样例版本") }
        }
        func load(_ address: URL) async throws -> AgentPluginMarket.Directory {
            guard let directory = try await market.refresh(address.absoluteString).selected else { throw PetError("未选中私有目录") }
            return directory
        }
        func prepare(_ name: String, from directory: AgentPluginMarket.Directory) async throws -> (AgentPluginPackage, AgentPluginInstallation?) {
            guard let entry = directory.entries.first(where: { $0.name == name }) else { throw PetError("私有目录缺少样例条目") }
            return try await market.prepare(entry, in: directory, scope: nil, plugins: plugins)
        }
        func rejects(_ message: String, _ operation: () async throws -> Void) async -> Bool {
            do { try await operation(); return false }
            catch { return error.localizedDescription.contains(message) }
        }
        func resource(_ item: AgentPluginInstallation) throws -> String {
            let package = try plugins.reviewPackage(item)
            guard let bytes = package.files["skills/inventory/resources/count.json"] else { throw PetError("私有插件缺少验收文件") }
            return String(decoding: bytes, as: UTF8.self)
        }

        try stored.write("model-config-fixture", account: "chat")
        try await publish("1.0.0")
        checks["privateDirectoryRejectsAnonymousAccess"] = await rejects("访问凭据") { _ = try await load(catalog) }
        checks["privateGitRejectsAnonymousAccess"] = await rejects("访问凭据") { _ = try await load(repository) }
        try market.saveCredential(bearer, for: catalog)
        try market.saveCredential(basic, for: repository)
        checks["scopedCredentialsPersistAcrossMarketInstances"] = try AgentPluginMarket(profile: profile).credential(for: catalog)?.authorization == bearer.authorization
            && AgentPluginMarket(profile: profile).credential(for: repository)?.authorization == basic.authorization
        let first = try await load(catalog), repoV1 = try await load(repository)
        let (zip, prior) = try await prepare("private-inventory", from: first)
        checks["privateArchivesStillRequireExplicitReview"] = try prior == nil && plugins.catalog().isEmpty
        let installed = try plugins.install(zip)
        results["privateArchiveInstall"] = try resource(installed)
        let (git, gitPrior) = try await prepare("repo-stock", from: repoV1)
        let gitInstalled = try plugins.install(git)
        results["privateGitInstall"] = try resource(gitInstalled)
        let pinned = AgentPluginMarketGit.Commit(repository: repository, sha: firstSHA)
        checks["privateGitInstallsOnlyPinnedRepositoryFolder"] = gitPrior == nil && !gitInstalled.enabled
            && gitInstalled.receipt.marketOrigin?.gitCommit == pinned && gitInstalled.receipt.marketOrigin?.repositoryPath == "plugins/repo-stock"
        checks["privateCatalogCannotBorrowAnotherCatalogCredential"] = await rejects("访问凭据") { _ = try await prepare("repo-stock", from: first) }
        let (neighbor, _) = try await prepare("review-notes", from: first)
        checks["neighboringPublicArchiveRemainsUsable"] = neighbor.metadata.name == "review-notes"
        checks["authenticatedArchiveRejectsRedirectBeforeReadingDestination"] = await rejects("最终 HTTPS 地址") {
            _ = try await prepare("redirect-check", from: first)
        }
        checks["credentialScopeRejectsAlternatePortsAndAmbiguousPaths"] =
            ["https://localhost:1/private/package.zip", origin.absoluteString + "/private/%2e%2e/package.zip",
             origin.absoluteString + "/private/features%2fpackage.zip", origin.absoluteString + "/private/%252e/package.zip"]
            .allSatisfy { address in URL(string: address).map { !AgentPluginMarketCredential.contains($0, in: catalog) } == true }
        let gitHubURL = try AgentPluginMarket.credentialDestination("https://github.com/Fixture-Lab/Extensions.git")
        checks["githubCredentialUsesTheExistingCanonicalCatalogKey"] = gitHubURL.absoluteString == "https://github.com/fixture-lab/extensions"
            && AgentPluginMarket.gitRepository(for: gitHubURL)?.absoluteString == gitHubURL.absoluteString + ".git"

        try await publish("2.0.0")
        try market.saveCredential(wrong, for: catalog)
        let refused = await rejects("HTTP 403") { _ = try await load(catalog) }
        checks["wrongCredentialRetainsLastVerifiedCatalog"] = try refused && market.cachedCatalogs().directories
            .first(where: { $0.address == catalog })?.entries.first?.version == "1.0.0"
        try market.saveCredential(bearer, for: catalog)
        let latest = try await load(catalog), repoV2 = try await load(repository)
        let (zipUpdate, existingZip) = try await prepare("private-inventory", from: latest)
        let (gitUpdate, existingGit) = try await prepare("repo-stock", from: repoV2)
        guard let existingZip, let existingGit else { throw PetError("私有市场没有找到原安装") }
        let updated = try plugins.update(zipUpdate, replacing: existingZip)
        let gitUpdated = try plugins.update(gitUpdate, replacing: existingGit)
        results["privateArchiveUpdate"] = try resource(updated)
        results["privateGitUpdate"] = try resource(gitUpdated)
        checks["privateCatalogUpdatesPreserveInstallationsAndHistory"] = existingZip.receiptHash == installed.receiptHash
            && existingGit.receiptHash == gitInstalled.receiptHash && updated.metadata.version == "2.0.0" && !updated.enabled
            && gitUpdated.receipt.marketOrigin?.gitCommit?.sha == secondSHA && gitUpdated.receipt.revisions?.first != nil && !gitUpdated.enabled

        try market.saveCredential(nil, for: catalog)
        try market.saveCredential(nil, for: repository)
        let deniedZIP = await rejects("访问凭据") { _ = try await prepare("private-inventory", from: latest) }
        let deniedGit = await rejects("访问凭据") { _ = try await load(repository) }
        checks["clearingDisablesAccessWithoutRemovingCachedOrInstalledData"] = try deniedZIP && deniedGit
            && market.credential(for: catalog) == nil && market.credential(for: repository) == nil
            && market.cachedCatalogs().directories.count == 2 && plugins.installation(gitUpdated.id).receiptHash == gitUpdated.receiptHash
        let configBytes = try Data(contentsOf: stored.file)
        let cacheBytes = try Data(contentsOf: profile.appendingPathComponent("extensions/plugin-markets.json"))
        let privateMode = try FileManager.default.attributesOfItem(atPath: stored.file.path)[.posixPermissions] as? NSNumber == 0o600
        checks["secretsStayOutOfCatalogAndRemovalKeepsOtherConfiguration"] = try stored.value("chat") == "model-config-fixture" && privateMode
            && [configBytes, cacheBytes].allSatisfy { !String(decoding: $0, as: UTF8.self).contains("market-test-") }
        checks["gitAuthenticationScratchRemovedAfterSuccessAndFailure"] = try FileManager.default.contentsOfDirectory(atPath: profile.path)
            .allSatisfy { !$0.hasPrefix(".plugin-git-") }
        return (checks, results)
    }
}
