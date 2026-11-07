import AppKit
import Darwin

@MainActor extension AppDelegate {
    func checkAgentHookConfiguration(_ output: URL) async throws -> [String: Bool] {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        func object(_ file: URL) -> [String: Any] { ((try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:] }
        func until(_ test: () -> Bool) async -> Bool { let deadline = Date().addingTimeInterval(5); while !test() && Date() < deadline { await wait(0.03) }; return test() }
        do {
            let fixtures = object(output.appendingPathComponent("config-fixtures.json"))
            guard let python = fixtures["python"] as? String, let script = fixtures["script"] as? String, let executable = fixtures["executable"] as? String, let endpoint = fixtures["http"] as? String else { throw PetError("缺少实际配置检查目录") }
            let workspace = output.appendingPathComponent("workspace"), profile = output.appendingPathComponent("config-profile")
            let keychain = PetKeychain(service: "com.xjs.bluefatfish.check.hook-config." + output.lastPathComponent)
            let tasks = AgentStore(directory: profile, legacy: [], extensionHome: output.appendingPathComponent("shared-home"), hookKeychain: keychain)
            let service = tasks.hooks, id = tasks.create(title: "实际命令配置与凭据检查", workspace: workspace.path)
            let marker = "public-config-env-7319", variable = "BLUEFATFISH_PUBLIC_HOOK_HEADER_7319"
            let previous = getenv(variable).map { String(cString: $0) }; setenv(variable, "public-http-env-7319", 1)
            defer {
                if let previous { setenv(variable, previous, 1) } else { unsetenv(variable) }
                service.cancelAll()
                for hook in (try? service.catalog(workspace: workspace.path)) ?? [] where hook.scope == "全局" { try? service.credentials.clear(hook) }
            }
            let literalArguments = [script, "literal", "space ' quote 中文", "$(touch ARGV_INJECTION)", "*?.json", "${SHOULD_STAY_LITERAL}", ""]
            let quotedPython = "'" + python.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
            var entries: [[String: Any]] = [
                ["name": "字面参数", "type": "command", "command": python, "args": literalArguments, "shell": "ignored-in-exec-form", "env": ["PUBLIC_CONFIG_ENV": marker], "if": "Write|Edit(*.json)", "once": true, "timeout": 5],
                ["name": "Bash 数组", "type": "command", "command": "values=(first second); [[ ${#values[@]} == 2 ]] && " + quotedPython + " \"$QODER_PROJECT_DIR/.bluefatfish/hooks/config-worker.py\" shell \"${values[1]}\"", "shell": "bash", "env": ["PUBLIC_CONFIG_ENV": marker], "if": "Bash(git *)", "timeout": 5],
                ["name": "HTTP 环境白名单", "type": "http", "url": endpoint, "headers": ["X-Public-Env": "prefix-${" + variable + "}-suffix"], "allowedEnvVars": [variable], "if": "Write(*.json)", "timeout": 5],
                ["name": "未匹配模型规则", "type": "prompt", "prompt": "这个检查不应产生模型请求", "if": "Write(*.ts)"],
                ["name": "无效参数类型", "type": "command", "command": python, "args": [3]],
                ["name": "无效环境类型", "type": "command", "command": "true", "env": ["BAD": 3]],
                ["name": "隔离启动器覆盖", "type": "command", "command": "true", "env": ["DYLD_INSERT_LIBRARIES": "public-invalid"]],
                ["name": "上下文变量覆盖", "type": "command", "command": "true", "env": ["QODER_PROJECT_DIR": "/"]],
                ["name": "无效条件", "type": "command", "command": "true", "if": "[broken"],
                ["name": "未知 Shell", "type": "command", "command": "true", "shell": "fish"],
                ["name": "无效 once 类型", "type": "command", "command": "true", "once": "true"]
            ]
            func save() throws {
                let text = String(decoding: try JSONSerialization.data(withJSONObject: ["hooks": ["PreToolUse": [["hooks": entries]]]], options: [.sortedKeys]), as: UTF8.self)
                try service.save(text, project: false, workspace: workspace.path, expectedHash: service.document(project: false, workspace: workspace.path).1)
            }
            func named(_ name: String) throws -> AgentHookDefinition { guard let hook = try service.catalog(workspace: workspace.path).first(where: { $0.name == name }) else { throw PetError("配置检查缺少：" + name) }; return hook }
            func enableOnly(_ names: [String]) throws {
                for hook in try service.catalog(workspace: workspace.path) where hook.scope == "全局" { try service.setEnabled(hook, names.contains(hook.name), workspace: workspace.path) }
            }
            func fire(_ tool: String, path: String? = nil, command: String? = nil) async throws -> AgentHookEffect {
                var input: [String: Any] = [:]; if let path { input["file_path"] = path }; if let command { input["command"] = command }
                return try await service.fire(.preTool, trigger: UUID().uuidString, store: tasks, taskID: id, value: tool, fields: ["tool_name": tool, "tool_input": input])
            }
            func headerCount() -> Int { ((try? Data(contentsOf: output.appendingPathComponent("http-config-audit.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]])?.count ?? 0 }
            let invalidSource = try service.file(project: false, workspace: workspace.path)
            try FileManager.default.createDirectory(at: invalidSource.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["hooks": ["PreToolUse": [["hooks": entries]]]]).write(to: invalidSource)
            let invalidCatalog = try service.catalog(workspace: workspace.path)
            checks["configMalformedFieldsHaveDiagnostics"] = ["无效参数类型", "无效环境类型", "隔离启动器覆盖", "上下文变量覆盖", "无效条件", "未知 Shell", "无效 once 类型"].allSatisfy { name in invalidCatalog.first(where: { $0.name == name })?.diagnostic != nil }
            let invalidDocument = try service.document(project: false, workspace: workspace.path)
            checks["configInvalidSourceRemainsEditableAndMasked"] = !invalidDocument.0.contains(marker) && invalidDocument.0.contains("BAD")
            entries = Array(entries.prefix(4)); try save()
            let catalog = try service.catalog(workspace: workspace.path), saved = try service.document(project: false, workspace: workspace.path).0
            checks["configDiscoveryNeverEnables"] = catalog.allSatisfy { !service.enabled($0) }
            checks["configExecIgnoresShellField"] = try named("字面参数").diagnostic == nil
            checks["configEnvironmentAndHeadersSavedToKeychain"] = try !saved.contains(marker) && saved.contains(AgentHookCredentials.placeholder) && service.credentials.values(named("字面参数"))["PUBLIC_CONFIG_ENV"] == marker
            let settings = try String(contentsOf: profile.appendingPathComponent("extensions/hook-settings.json"), encoding: .utf8)
            checks["configGrantDoesNotPersistEnvironmentValues"] = !settings.contains(marker)
            let httpDefinition = try named("HTTP 环境白名单"), legacyAccount = AgentFiles.hash(Data((profile.standardizedFileURL.path + ":" + httpDefinition.id + ":" + endpoint).utf8))
            checks["configExistingHTTPAccountBindingRetained"] = !(try keychain.read(legacyAccount)).isEmpty
            try enableOnly(["字面参数", "未匹配模型规则"])
            let eventCount = tasks.task(id)?.events.count
            _ = try await fire("Read", path: "actual.json"); _ = try await fire("WriteExtra", path: "actual.json"); _ = try await fire("Write", path: "actual.txt")
            checks["configToolAndGlobNonMatchesDoNotExecute"] = tasks.task(id)?.events.count == eventCount && !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("literal-receipt.json").path)
            let literal = try await fire("Write", path: "actual.json"), receipt = object(workspace.appendingPathComponent("literal-receipt.json"))
            checks["configExecArgumentsStayLiteral"] = receipt["argv"] as? [String] == Array(literalArguments.dropFirst(2)) && !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("ARGV_INJECTION").path)
            checks["configEnvironmentAndStdinReachActualProcess"] = receipt["env"] as? String == marker && receipt["project"] as? String == workspace.path && receipt["stdinEvent"] as? String == "PreToolUse"
            checks["configCommandOutputRedactsEnvironmentValues"] = !literal.context.contains(marker) && tasks.task(id)?.events.allSatisfy { !$0.detail.contains(marker) } == true
            checks["configFilteredPromptDoesNotCallModel"] = tasks.task(id)?.events.filter { $0.kind == "hook" }.count == 1 && tasks.task(id)?.modelReceipts?.isEmpty != false
            _ = try await fire("Write", path: "actual.json")
            checks["configFileScopedOnceDoesNotRemoveHandler"] = try object(workspace.appendingPathComponent("literal-receipt.json"))["callCount"] as? Int == 2 && service.enabled(named("字面参数"))
            try enableOnly(["Bash 数组"]); _ = try await fire("Bash", command: "git status")
            checks["configExplicitBashUsesArraySyntax"] = object(workspace.appendingPathComponent("shell-receipt.json"))["argv"] as? [String] == ["second"]
            try enableOnly(["HTTP 环境白名单"])
            let initialHeaders = headerCount(), http = try await fire("Write", path: "actual.json")
            checks["configHTTPReadsActualEnvironmentOnce"] = try headerCount() == initialHeaders + 1 && http.context.contains(AgentFiles.hash(Data(contentsOf: workspace.appendingPathComponent("source.json"))))
            checks["configHTTPRedactsWholeHeaderAndExpandedVariable"] = !http.context.contains("public-http-env-7319") && tasks.task(id)?.events.allSatisfy { !$0.detail.contains("public-http-env-7319") } == true
            entries[2]["allowedEnvVars"] = []; try save(); try enableOnly(["HTTP 环境白名单"])
            let deniedCount = headerCount()
            do { _ = try await fire("Write", path: "actual.json"); checks["configDisallowedVariableNeverSendsRequest"] = false }
            catch { checks["configDisallowedVariableNeverSendsRequest"] = headerCount() == deniedCount }
            entries[2].removeValue(forKey: "allowedEnvVars"); try save(); try enableOnly(["HTTP 环境白名单"])
            _ = try await fire("Write", path: "actual.json")
            checks["configOmittedWhitelistAllowsActualEnvironment"] = headerCount() == deniedCount + 1
            unsetenv(variable); let absentCount = headerCount()
            do { _ = try await fire("Write", path: "actual.json"); checks["configMissingVariableNeverSendsRequest"] = false }
            catch { checks["configMissingVariableNeverSendsRequest"] = headerCount() == absentCount }
            setenv(variable, "public\r\nInjected: no", 1)
            do { _ = try await fire("Write", path: "actual.json"); checks["configExpandedHeaderCannotInjectNewlines"] = false }
            catch { checks["configExpandedHeaderCannotInjectNewlines"] = headerCount() == absentCount }
            setenv(variable, "public-http-env-7319", 1)
            let oldHook = try named("字面参数"), target = try service.file(project: false, workspace: workspace.path)
            let before = try Data(contentsOf: target), beforeValues = try service.credentials.values(oldHook)
            var edited = try JSONSerialization.jsonObject(with: before) as! [String: Any], editedEvents = edited["hooks"] as! [String: Any], groups = editedEvents["PreToolUse"] as! [[String: Any]], handlers = groups[0]["hooks"] as! [[String: Any]]
            handlers[0]["args"] = [script, "literal", "changed"]
            groups[0]["hooks"] = handlers; editedEvents["PreToolUse"] = groups; edited["hooks"] = editedEvents
            do { try service.save(String(decoding: JSONSerialization.data(withJSONObject: edited), as: UTF8.self), project: false, workspace: workspace.path, expectedHash: AgentFiles.hash(before)); checks["configChangedExecutableArgumentsCannotReuseCredentials"] = false }
            catch { checks["configChangedExecutableArgumentsCannotReuseCredentials"] = try Data(contentsOf: target) == before && service.credentials.values(oldHook) == beforeValues }
            var rollback = entries; rollback[0]["env"] = ["PUBLIC_CONFIG_ENV": "public-rollback-marker-7319"]
            let rollbackData = try JSONSerialization.data(withJSONObject: ["hooks": ["PreToolUse": [["hooks": rollback]]]])
            do { _ = try service.credentials.save(rollbackData, file: target) { _, _ in throw PetError("公开检查：保存失败") }; checks["configCredentialTransactionRollsBack"] = false }
            catch { checks["configCredentialTransactionRollsBack"] = try service.credentials.values(oldHook) == beforeValues }
            try enableOnly(["字面参数"]); entries[0]["env"] = ["PUBLIC_CONFIG_ENV": "public-replaced-env-7319"]; try save()
            checks["configChangingOnlySecretDisablesExistingGrant"] = try !service.enabled(named("字面参数")) && named("字面参数").diagnostic == nil
            try service.clearCredentials(named("字面参数"), workspace: workspace.path)
            checks["configClearEnvironmentDisablesAndRemovesCredential"] = try !service.credentials.available(oldHook) && named("字面参数").diagnostic != nil
            entries = [["name": "遮蔽不改变拒绝", "type": "command", "command": python, "args": ["-c", "import json; print(json.dumps({'decision':'block','reason':'实际规则拒绝'}))"], "env": ["PUBLIC_CONFIG_ENV": "block"]], ["name": "遮蔽不改变停止", "type": "command", "command": python, "args": ["-c", "import json; print(json.dumps({'continue':False,'stopReason':'实际规则停止'}))"], "env": ["PUBLIC_CONFIG_ENV": "false"]]]
            try save(); try enableOnly(["遮蔽不改变拒绝"])
            checks["configRedactionCannotEraseBlockDecision"] = try await fire("Write", path: "actual.json").deny != nil
            try enableOnly(["遮蔽不改变停止"])
            checks["configRedactionCannotBreakBooleanStopDecision"] = try await fire("Write", path: "actual.json").halt != nil
            entries.append(["name": "HTTP 遮蔽不改变拒绝", "type": "http", "url": endpoint, "headers": ["X-Public-Env": "${" + variable + "}"], "allowedEnvVars": [variable]])
            setenv(variable, "block", 1); try save(); try enableOnly(["HTTP 遮蔽不改变拒绝"])
            let httpBlock = try await service.fire(.preTool, trigger: UUID().uuidString, store: tasks, taskID: id, value: "Write", fields: ["tool_name": "Write", "tool_input": ["file_path": "actual.json"], "required_sha256": String(repeating: "0", count: 64)])
            checks["configHTTPRedactionCannotEraseActualHashRejection"] = httpBlock.deny != nil
            entries = [["name": "凭据不能改写工具参数", "type": "command", "command": python, "args": ["-c", "import json,os; print(json.dumps({'hookSpecificOutput':{'hookEventName':'PreToolUse','updatedInput':{'file_path':os.environ['PUBLIC_CONFIG_ENV']}}}))"], "env": ["PUBLIC_CONFIG_ENV": "public-protected-input-7319"]]]
            try save(); try enableOnly(["凭据不能改写工具参数"])
            do { _ = try await fire("Write", path: "actual.json"); checks["configProtectedValuesNeverRewriteActualToolInput"] = false }
            catch { checks["configProtectedValuesNeverRewriteActualToolInput"] = tasks.task(id)?.events.last?.detail.contains("public-protected-input-7319") == false }
            entries = [["name": "Exec 后台取消", "type": "command", "command": python, "args": [script, "wait-cancel"], "async": true, "timeout": 30], ["name": "Exec 超时", "type": "command", "command": python, "args": [script, "wait-timeout"], "timeout": 1], ["name": "Exec 路径原样", "type": "command", "command": executable, "args": ["direct"]], ["name": "Exec PATH 查找", "type": "command", "command": "python3", "args": [script, "path"]]]
            try save(); try enableOnly(["Exec 路径原样", "Exec PATH 查找"]); _ = try await fire("Write", path: "actual.json")
            checks["configExecutablePathWithMetacharactersIsLiteral"] = object(workspace.appendingPathComponent("direct-receipt.json"))["kind"] as? String == "direct" && !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("BAD_PATH").path)
            checks["configExecResolvesExecutableFromPath"] = object(workspace.appendingPathComponent("path-receipt.json"))["kind"] as? String == "path"
            try save(); try enableOnly(["Exec 后台取消"])
            _ = try await fire("Bash", command: "sleep owned-child")
            let cancelFile = workspace.appendingPathComponent("wait-cancel.pid.json"); _ = await until { object(cancelFile)["child"] != nil }
            service.cancel(id); _ = await until { !service.isRunning(id) }
            func gone(_ file: URL) -> Bool { let values = object(file); let pids = [values["pid"], values["child"]].compactMap { $0 as? Int }; return pids.count == 2 && pids.allSatisfy { kill(pid_t($0), 0) != 0 } }
            checks["configExecCancelKillsParentAndChild"] = await until { gone(cancelFile) }
            try enableOnly(["Exec 超时"]); _ = try await fire("Bash", command: "sleep owned-child")
            checks["configExecTimeoutKillsParentAndChild"] = await until { gone(workspace.appendingPathComponent("wait-timeout.pid.json")) }
            checks["configRemovedHeadersDeleteKeychainEntry"] = !service.credentials.available(catalog.first { $0.name == "HTTP 环境白名单" }!)
            report["taskID"] = id; report["scope"] = "Actual literal argv, Bash, keychain transactions, live process environment, local HTTP source hashing and real cancellation; no model replies simulated. PowerShell requires an installed pwsh and is not exercised here."
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; let success = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }; report["success"] = success
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("hook-config-report.json"))
        guard success else { throw PetError("Hook 配置检查未通过：" + (report["error"] as? String ?? checks.filter { !$0.value }.map(\.key).sorted().joined(separator: ", "))) }
        return checks
    }
}
