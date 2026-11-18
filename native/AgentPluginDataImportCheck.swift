import AppKit

@MainActor extension AppDelegate {
    func runPluginDataImportCheck(_ output: URL) async {
        let fm = FileManager.default
        let harbor = output.appendingPathComponent("harbor"), other = output.appendingPathComponent("other")
        let incoming = harbor.appendingPathComponent(".qoder/plugins"), offline = output.appendingPathComponent("temporary-offline")
        let paused = output.appendingPathComponent("plugin-data-import-paused.json"), report = output.appendingPathComponent("plugin-data-import-report.json")
        let profile = output.appendingPathComponent("profile"), credentials = output.appendingPathComponent("fixture-credentials.json")
        let keychain = PetKeychain(service: "com.xjs.bluefatfish.plugin-data-import-fixture", configurationFile: credentials, migrateLegacy: false)
        let store = AgentStore(directory: profile, legacy: [], extensionHome: output.appendingPathComponent("shared-home"),
                               mcpKeychain: keychain, hookKeychain: keychain)
        let importer = store.dataImport, plugins = store.extensions.plugins
        let initialTasks = store.tasks.map(\.id)
        let sourceSecret = "PUBLIC-FIXTURE-ONLY-PLUGIN-VALUE", marker = output.appendingPathComponent("connector-ran")
        let publicText = "PUBLIC PLUGIN MIGRATION FACT 8162"
        var checks: [String: Bool] = [:]

        func encode(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) }
        func save(_ bytes: Data, to file: URL) throws {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file, options: .atomic)
        }
        func write(_ object: [String: Any], to file: URL) throws { try save(encode(object), to: file) }
        func hash(_ url: URL) throws -> String { AgentFiles.hash(try Data(contentsOf: url)) }
        func fixture(_ root: URL, name: String, title: String, manifest: String = ".qoder-plugin/plugin.json",
                     extra: [String: Any] = [:]) throws {
            if !manifest.isEmpty {
                try write(["name": name, "version": "1.0.0", "description": "公开插件迁移验收", "displayName": title]
                    .merging(extra) { _, supplied in supplied }, to: root.appendingPathComponent(manifest))
            }
            try save(Data("---\nname: source\ndescription: Read a public fixture\n---\nRead resources/note.txt.\n".utf8),
                     to: root.appendingPathComponent("skills/source/SKILL.md"))
            try save(Data(publicText.utf8), to: root.appendingPathComponent("skills/source/resources/note.txt"))
            try save(Data("# \(title)\n公开插件资料。\n".utf8), to: root.appendingPathComponent("README.md"))
        }
        func idle() async throws {
            let deadline = Date().addingTimeInterval(20)
            while importer.active && Date() < deadline { await wait(0.04) }
            guard !importer.active else { throw PetError("插件迁移仍在进行") }
        }
        func rejects(_ action: () throws -> Void) -> Bool {
            do { try action(); return false } catch { return true }
        }
        func call(_ name: String, _ args: [String: Any]) throws -> AgentToolCall {
            AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try encode(args), as: UTF8.self))
        }
        do {
            guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("插件迁移验收未授权模型请求") }
            if !fm.fileExists(atPath: paused.path) {
                for project in [harbor, other] {
                    try fm.createDirectory(at: project, withIntermediateDirectories: true)
                    try store.organization.register(project.path, mode: .coding)
                }
                let legacy = output.appendingPathComponent("manual-plugin")
                try fixture(legacy, name: "kept", title: "已有本机插件")
                let kept = try plugins.install(await plugins.inspect(legacy), workspace: harbor.path)
                let keptHash = try hash(kept.root.appendingPathComponent("receipt.json"))
                checks["ordinaryPluginInstallEntryStillWorks"] = !kept.enabled && kept.locallyReviewed && kept.receipt.components.count == 1

                let first = incoming.appendingPathComponent("a-harbor"), second = incoming.appendingPathComponent("b-conventional")
                try fixture(first, name: "harbor-reader", title: "港湾项目插件")
                try fixture(second, name: "unused", title: "目录约定插件", manifest: "")
                try fixture(incoming.appendingPathComponent("d-existing"), name: "kept", title: "同名来源")
                try fixture(incoming.appendingPathComponent("e-sdk"), name: "sdk-ui", title: "专属界面", extra: ["sdk": ["requireApplication": true]])
                try save(Data("---\ndescription: Check a public document\n---\nInspect the current README.\n".utf8), to: first.appendingPathComponent("commands/check.md"))
                try save(Data("---\nname: reviewer\ndescription: Public project reader\ntools: [Read]\nreadOnly: true\n---\nCheck public project information.\n".utf8),
                         to: first.appendingPathComponent("agents/reviewer.md"))
                try save(Data("---\nname: documentation\ntrigger: manual\n---\nUse the project README as evidence.\n".utf8), to: first.appendingPathComponent("rules/documentation.md"))
                let mcpFile = first.appendingPathComponent(".mcp.json"), hooksFile = first.appendingPathComponent("hooks/hooks.json")
                try write(["mcpServers": ["docs": ["url": "https://example.com/mcp?key=" + sourceSecret,
                    "headers": ["X-Public": sourceSecret], "type": "sse"]]], to: mcpFile)
                try write(["hooks": ["SessionStart": [["hooks": [["type": "command", "command": "/usr/bin/true",
                    "env": ["PUBLIC_FIXTURE_ENV": sourceSecret]]]]]]], to: hooksFile)
                let sourceHashes = try [hash(mcpFile), hash(hooksFile)]
                await importer.detect(.qoder, root: incoming, category: .plugins)
                checks["projectCacheCannotBeImportedAsGlobalByDefault"] = importer.preview.filter { $0.issue?.contains("目标项目") == true }.count == 3
                await importer.detect(.qoder, root: incoming, category: .plugins, workspace: harbor.path)
                let rows = importer.preview
                checks["previewShowsComponentsAndExplainsConflictingAndExclusivePackages"] = rows.count == 4
                    && rows.filter { $0.issue == nil }.count == 2
                    && rows.contains { $0.issue?.contains("同名插件") == true }
                    && rows.contains { $0.issue?.contains("sdk") == true }
                    && rows.contains { $0.preview.contains("MCP · docs") && $0.preview.contains("Hook · SessionStart")
                        && $0.preview.contains("Agent · reviewer") && $0.preview.contains("规则 · documentation") }
                checks["previewHasCredentialSetupStateWithoutSourceValues"] = rows.contains { $0.warnings.contains(where: { $0.contains("凭据") }) }
                    && rows.allSatisfy { !$0.preview.contains(sourceSecret) }
                let selected = Set(rows.filter { $0.issue == nil }.map(\.id))
                checks["scopeCannotChangeAfterPreview"] = rejects { try importer.begin(.qoder, root: incoming, ids: selected, category: .plugins, workspace: other.path) }
                importer.onChange = { [weak importer] in
                    if importer?.batch?.state == "running", importer?.batch?.items.filter({ $0.state == "imported" }).count == 1 { importer?.pause() }
                }
                try importer.begin(.qoder, root: incoming, ids: selected, category: .plugins, workspace: harbor.path)
                try await idle(); importer.onChange = nil
                guard let batch = importer.batch, let written = batch.items.first(where: { $0.state == "imported" }),
                      let pending = batch.items.first(where: { $0.state == "pending" }), let id = AgentPluginDataImport.installedID(written.record, store: store) else {
                    throw PetError("缺少暂停后的已导入插件和剩余条目")
                }
                let installed = try plugins.installation(id)
                let firstPayload = try plugins.content(".mcp.json", installation: installed)
                let hookPayload = try plugins.content("hooks/hooks.json", installation: installed)
                let journal = try Data(contentsOf: profile.appendingPathComponent("imports/batch.json"))
                checks["sourceCredentialsNeverEnterInstalledTemplatesOrJournal"] = !String(decoding: firstPayload + hookPayload + journal, as: UTF8.self).contains(sourceSecret)
                    && String(decoding: firstPayload, as: UTF8.self).contains(AgentMCP.importPlaceholder)
                    && String(decoding: hookPayload, as: UTF8.self).contains(AgentHookCredentials.placeholder)
                    && !fm.fileExists(atPath: credentials.path)
                checks["allComponentsRetainOneScopedAndDisabledParent"] = installed.workspace == harbor.path && !installed.enabled
                    && installed.receipt.installationID == written.record.targetID && installed.receipt.components.count == 2 && installed.agents.count == 1
                    && installed.rules.count == 1 && installed.mcpServers.count == 1 && installed.hooks.count == 1
                    && (try? plugins.catalog(workspace: other.path).contains { $0.id == installed.id }) == false
                checks["noCredentialsConfiguredAndNoTaskEnqueuedAtImport"] = store.tasks.map(\.id) == initialTasks && !fm.fileExists(atPath: marker.path)
                    && store.mcp.availableServers(workspace: harbor.path).filter { $0.plugin?.name == installed.id }.allSatisfy { !$0.enabled && $0.configured == false }
                checks["originalPackageAndPreexistingPluginAreByteExact"] = try [hash(mcpFile), hash(hooksFile)] == sourceHashes
                    && hash(kept.root.appendingPathComponent("receipt.json")) == keptHash
                try await AgentPluginDataImport.install(pending.record, root: incoming, store: store)
                guard let pendingID = AgentPluginDataImport.installedID(pending.record, store: store) else { throw PetError("缺少保存的待续导插件") }
                try fm.moveItem(at: incoming, to: offline)
                try write(["checks": checks, "pid": getpid(), "batch": batch.id, "pending": pendingID,
                    "pendingHash": try plugins.installation(pendingID).receiptHash, "sourceHashes": sourceHashes,
                    "taskIDs": initialTasks], to: paused)
                return
            }

            let seed = try AgentConfigurationJSON.object(Data(contentsOf: paused))
            checks = seed["checks"] as! [String: Bool]
            checks["newProcessRestoresOriginalPluginBatchAndScope"] = seed["pid"] as? Int != Int(getpid()) && importer.batch?.id == seed["batch"] as? String
                && importer.batch?.category == .plugins && importer.batch?.targetWorkspace == harbor.path && importer.batch?.state == "paused"
            importer.resume(); try await idle()
            let pending = try plugins.installation(seed["pending"] as! String)
            checks["offlineResumeReusesExactInstalledPackageWithoutDuplication"] = importer.batch?.items.allSatisfy { $0.state == "imported" } == true
                && pending.receiptHash == seed["pendingHash"] as? String && !pending.enabled
            try fm.moveItem(at: offline, to: incoming)
            let original = incoming.appendingPathComponent("a-harbor")
            checks["qoderSourceStillMatchesAfterOfflineRoundTrip"] = try [hash(original.appendingPathComponent(".mcp.json")), hash(original.appendingPathComponent("hooks/hooks.json"))] == seed["sourceHashes"] as? [String]
            await importer.detect(.qoder, root: incoming, category: .plugins, workspace: harbor.path)
            checks["rediscoveryDoesNotInstallSamePackageAgain"] = importer.preview.filter { $0.issue == "已经导入" }.count == 2

            let export = output.appendingPathComponent("codex-export")
            let versions = export.appendingPathComponent("plugins/cache/public-collection/codex-reader")
            let local = versions.appendingPathComponent("local")
            try fixture(versions.appendingPathComponent("3.0.0"), name: "higher-inactive", title: "较高但未选中的版本", manifest: ".codex-plugin/plugin.json")
            try fixture(local, name: "codex-reader", title: "兼容清单覆盖", manifest: "plugin.json", extra: [
                "$schema": "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
                "extensions": ["com.openai": ["interface": ["displayName": "Codex 公开资料插件"]]]
            ])
            try write(["name": "overlay-old", "apps": "./stale-map.json"], to: local.appendingPathComponent(".codex-plugin/plugin.json"))
            try fixture(versions.deletingLastPathComponent().appendingPathComponent("semantic/1.9.0"), name: "older-meta", title: "较旧版本", manifest: ".codex-plugin/plugin.json")
            try fixture(versions.deletingLastPathComponent().appendingPathComponent("semantic/1.10.0"), name: "stable-meta", title: "稳定版", manifest: ".codex-plugin/plugin.json")
            try fixture(versions.deletingLastPathComponent().appendingPathComponent("semantic/1.10.0-beta.2"), name: "beta-meta", title: "预览版", manifest: ".codex-plugin/plugin.json")
            let broken = export.appendingPathComponent("plugins/app-only")
            try fixture(broken, name: "app-mapping", title: "应用注册连接器", manifest: ".codex-plugin/plugin.json", extra: ["apps": "./.app.json"])
            try write(["apps": ["service": ["id": "public-fixture-app-id"]]], to: broken.appendingPathComponent(".app.json"))
            let mutated = export.appendingPathComponent("plugins/edit-after-preview")
            try fixture(mutated, name: "stale-source", title: "预览后内容改动", manifest: ".codex-plugin/plugin.json")
            let mcp = local.appendingPathComponent("mcp.json")
            try write(["$schema": "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json", "mcpServers": ["reader": [
                "type": "stdio", "command": "/opt/homebrew/bin/node",
                "args": ["${CODEX_PLUGIN_ROOT}/scripts/reader.mjs", "${CODEX_PLUGIN_ROOT}/skills/source/resources/note.txt", marker.path],
                "env": ["PUBLIC_VALUE": sourceSecret]
            ]]], to: mcp)
            let program = """
            import fs from 'node:fs';
            import readline from 'node:readline';
            const [file, marker] = process.argv.slice(2);
            fs.writeFileSync(marker, String(process.pid));
            for await (const line of readline.createInterface({input: process.stdin})) {
              const request = JSON.parse(line);
              if (request.id === undefined) continue;
              let result;
              if (request.method === 'initialize') result={protocolVersion:request.params.protocolVersion,serverInfo:{name:'public-plugin-acceptance',version:'1.0'},capabilities:{tools:{}}};
              if (request.method === 'tools/list') result={tools:[{name:'read_record',inputSchema:{type:'object',properties:{}}}]};
              if (request.method === 'tools/call') result={content:[{type:'text',text:process.env.PUBLIC_VALUE === 'LOCAL-TEST-VALUE' ? fs.readFileSync(file,'utf8') : 'WRONG-FIXTURE-VALUE'}]};
              process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:request.id,result})+'\\n');
            }
            """
            try save(Data(program.utf8), to: local.appendingPathComponent("scripts/reader.mjs"))
            let resourceHash = try hash(local.appendingPathComponent("skills/source/resources/note.txt")), originalMCPHash = try hash(mcp)
            await importer.detect(.codex, root: export, category: .plugins)
            let rows = importer.preview
            checks["codexDiscoversActiveLocalAndSemanticVersionAndExplainsAppDependency"] = rows.count == 4 && rows.filter { $0.issue == nil }.count == 3
                && rows.contains { $0.title == "Codex 公开资料插件" && $0.plugin?.name == "codex-reader" }
                && rows.contains { $0.title == "稳定版" } && rows.contains { $0.issue?.contains("来源应用") == true }
            try save(Data("公开来源发生修改。\n".utf8), to: mutated.appendingPathComponent("README.md"))
            try importer.begin(.codex, root: export, ids: Set(rows.filter { $0.issue == nil }.map(\.id)), category: .plugins)
            try await idle()
            checks["changedSourceFailsIndividuallyAndOtherSelectedItemsInstall"] = importer.batch?.items.filter { $0.state == "imported" }.count == 2
                && importer.batch?.items.contains { $0.record.title == "预览后内容改动" && $0.state == "failed" && $0.detail.contains("已变化") } == true
            let portable = try plugins.installation("codex-reader")
            checks["portableResourcesMatchOriginalAndNeitherPluginNorConnectorStarts"] = try AgentFiles.hash(plugins.content("skills/source/resources/note.txt", installation: portable)) == resourceHash
                && hash(mcp) == originalMCPHash && !portable.enabled && !fm.fileExists(atPath: marker.path)
                && initialTasks == seed["taskIDs"] as? [String] && store.tasks.map(\.id) == initialTasks
            guard let connector = store.mcp.servers.first(where: { $0.plugin?.name == portable.id }) else { throw PetError("未找到导入的连接器") }
            let template = try store.mcp.document(connector)
            checks["connectorWorkingFilesResolveAgainstInstalledPayloadWithBlankCredential"] = template.contains(portable.root.path) && !template.contains(local.path)
                && !template.contains(sourceSecret) && template.contains("PUBLIC_VALUE") && !template.contains("${CODEX_PLUGIN_ROOT}")
            checks["savedConnectionRequiresNewLocalCredential"] = rejects {
                _ = try store.mcp.save(template, id: connector.id, expectedRevision: connector.revision)
            }
            var fields = try AgentConfigurationJSON.object(Data(template.utf8)); fields["env"] = ["PUBLIC_VALUE": "LOCAL-TEST-VALUE"]
            _ = try store.mcp.save(String(decoding: encode(fields), as: UTF8.self), id: connector.id, expectedRevision: connector.revision)
            try plugins.setEnabled(portable, true)
            try store.mcp.setEnabled(connector.id, true)
            let owner = store.create(title: "插件连接器读取公开样本", workspace: harbor.path)
            store.update(owner) { $0.permission = .review }
            let server = try store.mcp.server(connector.id, workspace: harbor.path)
            let tools = AgentTools(store: store, taskID: owner), connect = try call("connect_mcp", ["server_id": server.id, "configuration": server.revision])
            let reviewed = try tools.approvalReason(for: connect) != nil
            let handshake = try await tools.execute(connect)
            guard !handshake.failed, let token = store.mcp.token(server.id, owner: owner) else { throw PetError("本机插件连接器握手失败") }
            _ = try store.mcp.catalog(server.id, owner: owner, token: token, offset: 0, query: "read_record")
            let result = try await store.mcp.call(server.id, owner: owner, token: token, name: "read_record", arguments: [:])
            checks["explicitApprovalAndLocalCredentialsReadActualPackagedResource"] = reviewed && !result.failed && result.text.contains(publicText) && fm.fileExists(atPath: marker.path)
            store.mcp.disconnect()
            try plugins.setEnabled(plugins.installation(portable.id), false)
            checks["explicitPluginDisableDisablesConnectorAndNoModelReceipt"] = store.mcp.servers.first { $0.id == server.id }?.enabled == false
                && store.tasks.allSatisfy { store.task($0.id)?.modelReceipts?.isEmpty != false }

            let archiveRoot = output.appendingPathComponent("portable-zip"), archive = output.appendingPathComponent("portable-zip.zip")
            try fixture(archiveRoot, name: "portable-archive", title: "便携压缩包", manifest: "plugin.json")
            try write(["name": "example-resource"], to: archiveRoot.appendingPathComponent("examples/plugin.json"))
            let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            zip.arguments = ["-q", "-r", archive.path, archiveRoot.lastPathComponent]; zip.currentDirectoryURL = output
            try zip.run(); zip.waitUntilExit()
            guard zip.terminationStatus == 0 else { throw PetError("创建公开 ZIP 样例失败") }
            let archiveHash = try hash(archive)
            await importer.detect(.codex, root: archive, category: .plugins, workspace: other.path)
            guard let archived = importer.preview.first(where: { $0.issue == nil }) else {
                throw PetError(importer.issue ?? importer.preview.first?.issue ?? "便携 ZIP 未识别")
            }
            try importer.begin(.codex, root: archive, ids: [archived.id], category: .plugins, workspace: other.path)
            try await idle()
            let archivedID = AgentPlugins.scopedID("portable-archive", workspace: other.path)
            let savedArchive = try plugins.installation(archivedID)
            checks["portableZipWithNestedExampleKeepsProjectAndResources"] = try importer.batch?.items.first?.state == "imported"
                && savedArchive.workspace == other.path && !savedArchive.enabled && hash(archive) == archiveHash
                && plugins.content("examples/plugin.json", installation: savedArchive) == Data(contentsOf: archiveRoot.appendingPathComponent("examples/plugin.json"))
            try write(["success": checks.values.allSatisfy { $0 }, "checks": checks, "pid": getpid(), "modelRequests": 0], to: report)
        } catch {
            store.mcp.disconnect()
            try? write(["success": false, "checks": checks, "pid": getpid(), "error": error.localizedDescription, "modelRequests": 0], to: report)
        }
    }
}
