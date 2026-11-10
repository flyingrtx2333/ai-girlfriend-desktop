import Foundation
import Darwin

@MainActor extension AppDelegate {
    func checkAgentPluginDirectory(_ output: URL, tasks: AgentStore, runtime: AgentRuntime) async throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        defer { try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("plugin-directory-native-checks.json"), options: .atomic) }
        let plugins = tasks.extensions.plugins, source = output.appendingPathComponent("directory-v1/目录 插件"), original = try pluginUpdateHashes(source)
        let directory = try await plugins.inspect(source), zipped = try await plugins.inspect(output.appendingPathComponent("lifecycle-v1.zip"))
        checks["actualDirectoryAndZIPLoadIdenticalSixComponentPayloads"] = directory.files == zipped.files && !directory.receipt.components.isEmpty && !directory.agents.isEmpty && !directory.mcpServers.isEmpty && !directory.hooks.isEmpty && !directory.rules.isEmpty
        checks["unicodeSpaceDirectoryKeepsManifestIdentityAndReadableOrigin"] = directory.metadata.name == "lifecycle-tools" && directory.receipt.sourceName == "目录 插件/" && directory.receipt.sourceHash == AgentExtensions.digest(directory.files)
        let cases = output.appendingPathComponent("directory-cases"); try FileManager.default.createDirectory(at: cases, withIntermediateDirectories: true)
        func copy(_ name: String) throws -> URL { let target = cases.appendingPathComponent(name); try FileManager.default.copyItem(at: source, to: target); return target }
        let convention = output.appendingPathComponent("convention-tools"), conventional = try await plugins.inspect(convention)
        checks["manifestlessDirectoryUsesActualFolderNameAndFallbackMCPFile"] = conventional.metadata.name == "convention-tools" && conventional.receipt.manifest == ".qoder-plugin/plugin.json" && conventional.mcpServers.count == 1 && !FileManager.default.fileExists(atPath: convention.appendingPathComponent(".qoder-plugin").path)
        let privateProfile = output.appendingPathComponent("directory-private-profile"); try FileManager.default.createDirectory(at: privateProfile, withIntermediateDirectories: true)
        let isolated = AgentPlugins(profile: privateProfile), installed = try isolated.install(conventional)
        checks["inferredMetadataIsStoredOnlyInReviewedInstalledSnapshot"] = !installed.enabled && (try? isolated.content(".qoder-plugin/plugin.json", installation: installed)) == conventional.files[".qoder-plugin/plugin.json"] && !FileManager.default.fileExists(atPath: convention.appendingPathComponent(".qoder-plugin/plugin.json").path)
        let ignored = try copy("ignored-content"), ignoredFiles = try AgentFiles(workspace: ignored.path)
        for path in [".git/private-state", ".env", "node_modules/module/index.js", "__pycache__/state", "__MACOSX/metadata"] { try ignoredFiles.writeData(Data("not part of the plugin snapshot".utf8), to: ignoredFiles.literalURL(path)) }
        let filtered = try await plugins.inspect(ignored)
        try JSONSerialization.data(withJSONObject: ["original": directory.receipt.hashes, "filtered": filtered.receipt.hashes], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("plugin-directory-filtered-hashes.json"))
        checks["ignoredRepositoryEnvironmentAndDependencyFilesNeverEnterSnapshot"] = filtered.files == directory.files
        let binary = try copy("binary-resource"), bytes = Data([0, 255, 128, 10, 0, 42]), binaryFiles = try AgentFiles(workspace: binary.path)
        try binaryFiles.writeData(bytes, to: binaryFiles.literalURL("skills/source/resources/actual.bin"))
        let binaryPackage = try await plugins.inspect(binary), binaryInstalled = try isolated.install(binaryPackage)
        checks["actualBinaryResourceIsCopiedWithoutTextConversion"] = try isolated.content("skills/source/resources/actual.bin", installation: binaryInstalled) == bytes
        let sensitive = try copy("protected-file"), sensitiveFile = sensitive.appendingPathComponent("credentials.json")
        try Data("public test value".utf8).write(to: sensitiveFile)
        do { _ = try await plugins.inspect(sensitive); checks["protectedFilesAreRejectedBeforeInstallation"] = false } catch { checks["protectedFilesAreRejectedBeforeInstallation"] = true }
        let linked = try copy("linked-resource"), outside = output.appendingPathComponent("outside-directory-resource.txt"), outsideBytes = Data("public outside resource".utf8)
        try outsideBytes.write(to: outside); try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("linked.txt"), withDestinationURL: outside)
        do { _ = try await plugins.inspect(linked); checks["externalResourceLinkCannotEnterPluginSnapshot"] = false } catch { checks["externalResourceLinkCannotEnterPluginSnapshot"] = try Data(contentsOf: outside) == outsideBytes }
        let internalLink = try copy("internal-resource-link")
        try FileManager.default.createSymbolicLink(at: internalLink.appendingPathComponent("alias.md"), withDestinationURL: internalLink.appendingPathComponent("README.md"))
        do { _ = try await plugins.inspect(internalLink); checks["internalResourceLinksAreNotSilentlyFlattened"] = false } catch { checks["internalResourceLinksAreNotSilentlyFlattened"] = true }
        let rootLink = cases.appendingPathComponent("linked-root"); try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: source)
        do { _ = try await plugins.inspect(rootLink); checks["sourceRootLinkCannotChangeChosenDirectory"] = false } catch { checks["sourceRootLinkCannotChangeChosenDirectory"] = true }
        let special = try copy("special-resource")
        guard mkfifo(special.appendingPathComponent("pipe").path, 0o600) == 0 else { throw PetError("无法创建临时FIFO") }
        do { _ = try await plugins.inspect(special); checks["actualFIFOIsRejectedWithoutBlockingFileRead"] = false } catch { checks["actualFIFOIsRejectedWithoutBlockingFileRead"] = true }
        let badPath = try copy("invalid-path"); try Data("public".utf8).write(to: badPath.appendingPathComponent("ambiguous[1].txt"))
        do { _ = try await plugins.inspect(badPath); checks["unsupportedResourcePathsAreRejectedConsistentlyWithZIP"] = false } catch { checks["unsupportedResourcePathsAreRejectedConsistentlyWithZIP"] = true }
        let tooLarge = try copy("single-resource-limit"); try Data(repeating: 7, count: 2_000_001).write(to: tooLarge.appendingPathComponent("large.bin"))
        do { _ = try await plugins.inspect(tooLarge); checks["actualResourceAboveTwoMBIsRejected"] = false } catch { checks["actualResourceAboveTwoMBIsRejected"] = true }
        let tooMany = try copy("entry-limit")
        for n in 0..<2001 { try Data().write(to: tooMany.appendingPathComponent("entry-\(n).txt")) }
        do { _ = try await plugins.inspect(tooMany); checks["actualEntryLimitIsEnforcedBeforePublication"] = false } catch { checks["actualEntryLimitIsEnforcedBeforePublication"] = true }
        let total = try copy("total-resource-limit")
        for n in 0..<11 { try Data(repeating: UInt8(n), count: 2_000_000).write(to: total.appendingPathComponent("resource-\(n).bin")) }
        do { _ = try await plugins.inspect(total); checks["actualAggregateResourceLimitIsEnforced"] = false } catch { checks["actualAggregateResourceLimitIsEnforced"] = true }
        let empty = cases.appendingPathComponent("empty-tools"); try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        do { _ = try await plugins.inspect(empty); checks["emptyConventionDirectoryCannotInstallMetadataOnlyPlugin"] = false } catch { checks["emptyConventionDirectoryCannotInstallMetadataOnlyPlugin"] = true }
        let invalidName = cases.appendingPathComponent("没有清单的目录"); try FileManager.default.copyItem(at: convention, to: invalidName)
        do { _ = try await plugins.inspect(invalidName); checks["manifestlessInvalidIdentityRequiresExplicitManifest"] = false } catch { checks["manifestlessInvalidIdentityRequiresExplicitManifest"] = error.localizedDescription.contains("清单") }
        let cancelled = Task { try await plugins.inspect(source) }; cancelled.cancel()
        do { _ = try await cancelled.value; checks["cancelledDirectoryInspectionDoesNotProduceCandidate"] = false } catch is CancellationError { checks["cancelledDirectoryInspectionDoesNotProduceCandidate"] = true }
        let changed = try copy("concurrent-source-change"), node = try String(contentsOf: output.appendingPathComponent("node-path.txt"), encoding: .utf8)
        var writerPID: Int32 = 0
        do {
            _ = try AgentArchive.directoryResources(changed, hiddenRoots: [".qoder-plugin", ".claude-plugin", ".mcp.json"], onListed: {
                let process = Process(); process.executableURL = URL(fileURLWithPath: node); process.arguments = ["-e", "require('fs').appendFileSync(process.argv[1],'actual independent change\\n');", changed.appendingPathComponent("README.md").path]
                try process.run(); writerPID = process.processIdentifier; process.waitUntilExit(); guard process.terminationStatus == 0 else { throw PetError("独立目录写入进程失败") }
            }); checks["actualIndependentChangeDuringSnapshotIsRejected"] = false
        } catch { checks["actualIndependentChangeDuringSnapshotIsRejected"] = writerPID > 0 && kill(writerPID, 0) != 0 && error.localizedDescription.contains("变化") }
        try JSONSerialization.data(withJSONObject: ["PID": writerPID, "terminated": writerPID > 0 && kill(writerPID, 0) != 0]).write(to: output.appendingPathComponent("plugin-directory-independent-writer.json"))
        let pinnedSource = try copy("pinned-review"), pinned = try await plugins.inspect(pinnedSource)
        try Data("version-changed-after-review".utf8).write(to: pinnedSource.appendingPathComponent("skills/source/resources/version.json"))
        let pinnedProfile = output.appendingPathComponent("pinned-directory-profile"); try FileManager.default.createDirectory(at: pinnedProfile, withIntermediateDirectories: true)
        let pinnedService = AgentPlugins(profile: pinnedProfile), published = try pinnedService.install(pinned)
        checks["postReviewSourceChangeCannotReplaceReviewedResourceBytes"] = try pinnedService.content("skills/source/resources/version.json", installation: published) == directory.files["skills/source/resources/version.json"] && Data(contentsOf: pinnedSource.appendingPathComponent("skills/source/resources/version.json")) != directory.files["skills/source/resources/version.json"]
        let publishedBefore = try pluginUpdateHashes(published.root), inspectedNew = try await pinnedService.inspect(pinnedSource)
        checks["choosingSourceAgainActuallyReadsChangedBytes"] = inspectedNew.receipt.hashes != pinned.receipt.hashes
        let updated = try pinnedService.update(inspectedNew, replacing: published)
        checks["directoryUpdateUsesActualNewSnapshotAndRetainsReviewedOriginal"] = try !updated.enabled && updated.receipt.hashes == inspectedNew.receipt.hashes && updated.instanceID != published.instanceID && updated.receipt.revisions?.last.map { try pluginUpdateHashes(pinnedService.revision($0, of: updated).root) == publishedBefore } == true
        checks["originalChosenDirectoryRemainsEveryOriginalByte"] = try pluginUpdateHashes(source) == original
        return checks
    }
}
