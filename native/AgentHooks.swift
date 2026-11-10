import Foundation

enum AgentHookEvent: String, Codable, CaseIterable {
    case sessionStart = "SessionStart", sessionEnd = "SessionEnd", prompt = "UserPromptSubmit"
    case preTool = "PreToolUse", postTool = "PostToolUse", toolFailure = "PostToolUseFailure"
    case permission = "PermissionRequest", denied = "PermissionDenied", stop = "Stop", stopFailure = "StopFailure"
    case preCompact = "PreCompact", postCompact = "PostCompact", cwd = "CwdChanged", instructions = "InstructionsLoaded"
    case file = "FileChanged", notification = "Notification", subagentStart = "SubagentStart", subagentStop = "SubagentStop"
    case worktreeCreate = "WorktreeCreate", worktreeRemove = "WorktreeRemove"
    var controlsExecution: Bool { [.prompt, .preTool, .permission, .stop].contains(self) }
}
struct AgentHookDefinition: Codable, Identifiable {
    var id: String, name: String, event: AgentHookEvent, matcher: String, type: String, command: String
    var timeout: Double, network: Bool, source: String, root: String, scope: String, workspace: String?
    var signature = "", diagnostic: String?
    var url: String?, headerNames: [String]?, prompt: String?, model: String?, tools: [String]?, maxTurns: Int?, sourceHash: String?
    var asynchronous: Bool?, asyncRewake: Bool?, rewakeMessage: String?, rewakeSummary: String?, statusMessage: String?
    var shell: String?, arguments: [String]?, environmentNames: [String]?, condition: String?, allowedEnvVars: [String]?, once: Bool?
    var plugin: AgentPluginHookReference?, pluginEnabled: Bool?
    var runsInBackground: Bool { asynchronous == true || asyncRewake == true }
    var display: String {
        let body: String
        switch type {
        case "http": body = "POST " + (url ?? "") + ((headerNames ?? []).isEmpty ? "" : "\nHeaders: " + (headerNames ?? []).joined(separator: ", ")) + (allowedEnvVars.map { "\n环境变量：" + ($0.isEmpty ? "不允许插值" : $0.joined(separator: ", ")) } ?? "")
        case "prompt", "agent": body = (model.map { "模型：" + $0 + "\n" } ?? "") + (tools.map { "工具：" + $0.joined(separator: ", ") + "\n" } ?? "") + (prompt ?? "")
        default:
            let argv = arguments.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.withoutEscapingSlashes]) }.map { String(decoding: $0, as: UTF8.self) }
            body = (arguments == nil ? (shell ?? "sh") + " · Shell\n" : "Exec · 直接参数\n") + command + (argv.map { "\nargs: " + $0 } ?? "") + ((environmentNames ?? []).isEmpty ? "" : "\nenv: " + (environmentNames ?? []).joined(separator: ", "))
        }
        return (condition.map { "if: " + $0 + "\n" } ?? "") + body + (once == true ? "\nonce: true（仅适用于会话配置）" : "")
    }
}
struct AgentHookSetting: Codable { var enabled: Bool; var definition: AgentHookDefinition }
struct AgentHookEffect: Codable {
    var deny: String?, halt: String?, ask = false, context = "", updatedInput: String?, sessionTitle: String?
    var systemMessage: String?, suppressOutput = false
    mutating func merge(_ other: Self) {
        deny = deny ?? other.deny; halt = halt ?? other.halt; ask = ask || other.ask
        if !other.context.isEmpty { context += (context.isEmpty ? "" : "\n") + other.context }
        if let input = other.updatedInput { updatedInput = input }
        sessionTitle = other.sessionTitle ?? sessionTitle
        systemMessage = other.systemMessage ?? systemMessage; suppressOutput = suppressOutput || other.suppressOutput
    }
}
struct AgentHookExecution: Codable {
    var key: String, hookID: String, event: AgentHookEvent, signature: String
    var effect: AgentHookEffect?, exitCode: Int?
    var childTaskID: String?, model: String?, inputTokens: Int?, outputTokens: Int?
    var asynchronous: Bool?, originPromptID: String?, delivery: String?, rewakeRequested: Bool?
}
struct AgentHookHalt: LocalizedError { let errorDescription: String?; init(_ text: String) { errorDescription = text } }

@MainActor final class AgentHooks {
    let profile: URL, sharedHome: URL?
    let plugins: AgentPlugins
    private var settings: [String: AgentHookSetting] = [:]
    @MainActor private final class Job {
        let hookID: String, background: Bool, title: String, source: String
        let pluginName: String?
        var childID: String?
        var cancelReason: String?
        var task: Task<AgentHookEffect, Error>?
        init(_ hook: AgentHookDefinition) { hookID = hook.id; background = hook.runsInBackground; title = hook.statusMessage ?? hook.name; source = hook.source; pluginName = hook.plugin?.name }
    }
    private var jobs: [String: [String: Job]] = [:]
    let http: AgentHookHTTP, credentials: AgentHookCredentials
    private(set) var loadError: String?
    private(set) var warnings: [String] = []
    var onAsyncResult: ((String, String, String?, Bool) -> Void)?
    init(profile: URL, sharedHome: URL?, keychain: PetKeychain? = nil, plugins: AgentPlugins? = nil) {
        self.profile = profile; self.sharedHome = sharedHome; self.plugins = plugins ?? AgentPlugins(profile: profile)
        credentials = AgentHookCredentials(profile: profile, keychain: keychain); http = AgentHookHTTP(credentials: credentials)
        let file = profile.appendingPathComponent("extensions/hook-settings.json")
        do { if FileManager.default.fileExists(atPath: file.path) { settings = try JSONDecoder().decode([String: AgentHookSetting].self, from: Data(contentsOf: file)); guard settings.count <= 256 else { throw PetError("Hooks 数量超过 256") } } }
        catch { loadError = "Hooks 设置无法读取：" + error.localizedDescription }
        _ = self.plugins.observeChanges { [weak self] name in
            guard let self else { return }
            for list in self.jobs.values { for job in list.values where job.pluginName == name { self.cancel(job) } }
        }
    }
    var isWorking: Bool { !jobs.values.allSatisfy(\.isEmpty) }
    func isRunning(_ id: String) -> Bool { jobs[id]?.isEmpty == false || jobs.values.contains { $0.values.contains { $0.childID == id } } }
    func backgroundTitle(_ id: String) -> String? {
        let titles = (jobs[id] ?? [:]).values.filter(\.background).map(\.title).sorted()
        return titles.first.map { "后台 · " + $0 + (titles.count > 1 ? "（\(titles.count) 项）" : "") }
    }
    private func cancel(_ job: Job) { if job.cancelReason == nil { job.cancelReason = "user" }; job.task?.cancel() }
    func cancel(_ id: String) { for (owner, list) in jobs { for job in list.values where owner == id || job.childID == id { cancel(job) } } }
    func cancelAll() { for list in jobs.values { for job in list.values { cancel(job) } } }
    func file(project: Bool, workspace: String?) throws -> URL {
        if project { return try AgentFiles(workspace: workspace).resolve(".bluefatfish/hooks.json") }
        return profile.appendingPathComponent("extensions/hooks.json")
    }
    func document(project: Bool, workspace: String?) throws -> (String, String?) {
        let file = try file(project: project, workspace: workspace)
        guard FileManager.default.fileExists(atPath: file.path) else { return ("{\n  \"hooks\": {\n    \"PreToolUse\": [\n      {\n        \"matcher\": \"Write|Edit\",\n        \"hooks\": [{\"name\": \"写入前检查\", \"type\": \"command\", \"command\": \"python3 -c 'import json,sys; data=json.load(sys.stdin); print(json.dumps({}))'\", \"timeout\": 10}]\n      }\n    ]\n  }\n}\n", nil) }
        let files = try AgentFiles(workspace: file.deletingLastPathComponent().path), data = try files.readData(files.resolve(file.lastPathComponent), maximum: 128_000)
        guard let text = String(data: try credentials.mask(data), encoding: .utf8) else { throw PetError("Hooks 配置不是 UTF-8") }; return (text, AgentFiles.hash(data))
    }
    func save(_ text: String, project: Bool, workspace: String?, expectedHash: String?) throws {
        guard text.utf8.count <= 128_000 else { throw PetError("Hooks 配置不超过 128KB") }
        let target = try file(project: project, workspace: workspace), current = try document(project: project, workspace: workspace)
        guard current.1 == expectedHash else { throw PetError("配置已变化，请重新打开后编辑") }
        _ = try parse(Data(text.utf8), file: target, scope: project ? "项目" : "全局", workspace: project ? workspace : nil)
        let files = try AgentFiles(workspace: project ? workspace : profile.path)
        try commitConfiguration(Data(text.utf8), target: target) { data in try files.writeData(data, to: files.resolve(project ? ".bluefatfish/hooks.json" : "extensions/hooks.json"), permissions: 0o600) }
    }
    func commitConfiguration(_ data: Data, target: URL, write: (Data) throws -> Void) throws {
        let changed = try credentials.save(data, file: target) { data, changed in
            let previous = settings
            for id in changed where settings[id] != nil { settings[id]?.enabled = false }
            do { try persistSettings(); try write(data) }
            catch { settings = previous; do { try persistSettings() } catch { loadError = "Hook 授权保存失败，请修复文件权限后重启" }; throw error }
        }
        for id in changed {
            for list in jobs.values { for job in list.values where job.hookID == id { cancel(job) } }
        }
        for list in jobs.values { for job in list.values where job.source == target.path { cancel(job) } }
    }
    func parse(_ data: Data, file: URL, scope: String, workspace: String?, resource: URL? = nil, fingerprintSuffix: Data = Data(), inspectResources: Bool = true, inspectCredentials: Bool = true) throws -> [AgentHookDefinition] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let events = object["hooks"] as? [String: Any] else { throw PetError("Hooks 配置需要 hooks 对象") }
        let resource = resource ?? file.deletingLastPathComponent().appendingPathComponent("hooks", isDirectory: true)
        var fingerprint = data + fingerprintSuffix, resourceDiagnostic: String?
        if inspectResources && FileManager.default.fileExists(atPath: resource.path) {
            do {
                guard (try FileManager.default.attributesOfItem(atPath: resource.path))[.type] as? FileAttributeType != .typeSymbolicLink else { throw PetError("hooks 目录不能是符号链接") }
                let files = try AgentFiles(workspace: resource.path)
                let children = try FileManager.default.subpathsOfDirectory(atPath: files.root.path).sorted(); guard children.count <= 500 else { throw PetError("hooks 目录超过 500 项") }
                var bytes = 0
                for name in children {
                    let original = files.root.appendingPathComponent(name)
                    guard (try FileManager.default.attributesOfItem(atPath: original.path))[.type] as? FileAttributeType != .typeSymbolicLink, !AgentFiles.sensitive(name) else { throw PetError("hooks 目录不能包含链接或凭据文件") }
                    let url = try files.resolve(name), info = try url.resourceValues(forKeys: [.isRegularFileKey])
                    if info.isRegularFile == true { let data = try files.readData(url, maximum: 1_000_000); bytes += data.count; guard bytes <= 5_000_000 else { throw PetError("hooks 目录超过 5MB") }; fingerprint += Data((name + "\0" + AgentFiles.hash(data)).utf8) }
                }
            } catch { resourceDiagnostic = error.localizedDescription }
        }
        var result: [AgentHookDefinition] = []
        for eventName in events.keys.sorted() {
            guard let event = AgentHookEvent(rawValue: eventName), let groups = events[eventName] as? [[String: Any]], groups.count <= 64 else { throw PetError("未知 Hook 事件或配置错误：" + eventName) }
            for (groupIndex, group) in groups.enumerated() {
                guard let handlers = group["hooks"] as? [[String: Any]], handlers.count <= 32 else { throw PetError("Hook matcher 需要 hooks 数组") }
                let matcher = group["matcher"] as? String ?? ""
                for (index, handler) in handlers.enumerated() {
                    let type = handler["type"] as? String ?? "command", command = handler["command"] as? String ?? "", timeout = handler["timeout"] as? Double ?? group["timeout"] as? Double ?? (handler["type"] as? String == "prompt" ? 30 : 60)
                    let name = handler["name"] as? String ?? eventName + " · " + String((type == "command" ? command : type).prefix(45))
                    let id = AgentHookHTTP.id(file, eventName, groupIndex, index)
                    var item = AgentHookDefinition(id: id, name: name, event: event, matcher: matcher, type: type, command: command, timeout: timeout, network: handler["network"] as? Bool ?? false, source: file.path, root: resource.path, scope: scope, workspace: workspace)
                    item.sourceHash = AgentFiles.hash(data)
                    item.asynchronous = handler["async"] as? Bool ?? group["async"] as? Bool ?? false
                    item.asyncRewake = handler["asyncRewake"] as? Bool ?? false
                    item.rewakeMessage = handler["rewakeMessage"] as? String; item.rewakeSummary = handler["rewakeSummary"] as? String
                    item.statusMessage = handler["statusMessage"] as? String
                    item.shell = handler["shell"] as? String; item.arguments = handler["args"] as? [String]; item.condition = handler["if"] as? String
                    item.once = handler["once"] as? Bool
                    item.environmentNames = (handler["env"] as? [String: String])?.keys.sorted()
                    item.url = handler["url"] as? String; item.prompt = handler["prompt"] as? String; item.model = handler["model"] as? String
                    item.tools = handler["tools"] as? [String] ?? (type == "agent" ? ["Read", "Glob", "Grep", "Bash"] : nil); item.maxTurns = handler["maxTurns"] as? Int ?? 50
                    item.headerNames = (handler["headers"] as? [String: String])?.keys.sorted()
                    if !["command", "http", "prompt", "agent"].contains(type) { item.diagnostic = "未知处理器：\(type)" }
                    else if type == "command" && (command.isEmpty || command.utf8.count > 16_000 || command.contains("\0")) { item.diagnostic = "命令为空或超过 16KB" }
                    else if type == "http" {
                        do {
                            _ = try AgentHookHTTP.endpoint(item.url); try AgentHookHTTP.validateHeaders(handler["headers"])
                            item.allowedEnvVars = try AgentHookHTTP.allowedEnvironment(handler["allowedEnvVars"])
                            if inspectCredentials && (handler["headers"] as? [String: String])?.values.contains(AgentHookHTTP.placeholder) == true && !credentials.available(item) { throw PetError("HTTP Header 凭据未配置，请编辑后重新保存") }
                        } catch { item.diagnostic = error.localizedDescription }
                    }
                    if type == "command", item.diagnostic == nil {
                        do {
                            try AgentHookCredentials.validateEnvironment(handler["env"])
                            if handler["args"] != nil {
                                guard let args = item.arguments, args.count <= 256, args.allSatisfy({ !$0.contains("\0") }), args.reduce(0, { $0 + $1.utf8.count }) <= 64_000 else { throw PetError("args 需要字符串数组，不超过 256 项或 64KB，不能包含空字符") }
                            } else if handler["shell"] != nil {
                                guard let shell = item.shell, ["bash", "powershell"].contains(shell) else { throw PetError("shell 支持 bash 或 powershell；args 模式忽略 shell") }
                                if shell == "powershell", !["/opt/homebrew/bin/pwsh", "/usr/local/bin/pwsh"].contains(where: FileManager.default.isExecutableFile(atPath:)) { throw PetError("未安装 PowerShell，请先安装 pwsh 或选择 bash") }
                            }
                            if inspectCredentials && (handler["env"] as? [String: String])?.values.contains(AgentHookCredentials.placeholder) == true && !credentials.available(item) { throw PetError("env 凭据未配置，请编辑后重新保存") }
                        } catch { item.diagnostic = error.localizedDescription }
                    }
                    if ["prompt", "agent"].contains(type) {
                        if (item.prompt ?? "").isEmpty || (item.prompt ?? "").utf8.count > 16_000 { item.diagnostic = "模型提示词不能为空或超过 16KB" }
                        else if (item.model?.count ?? 0) > 200 || item.model?.contains("\n") == true { item.diagnostic = "模型名称无效" }
                        else if type == "prompt", handler["tools"] != nil { item.diagnostic = "Prompt 处理器不执行工具，请使用 agent 类型" }
                        else if type == "agent", !(1...100).contains(item.maxTurns ?? 50) || (item.tools?.count ?? 0) > 16 || item.tools?.contains(where: { AgentHookModel.aliases[$0] == nil }) == true { item.diagnostic = "Agent 工具白名单或轮数无效" }
                    }
                    if item.diagnostic == nil {
                    if !timeout.isFinite || !(1...600).contains(timeout) { item.diagnostic = "超时范围为 1 至 600 秒" }
                    else if matcher.count > 300 || (!matcher.isEmpty && matcher != "*" && (try? NSRegularExpression(pattern: matcher)) == nil) { item.diagnostic = "matcher 不是有效正则表达式" }
                    else if [handler["async"], group["async"], handler["asyncRewake"]].contains(where: { $0 != nil && !($0 is Bool) }) { item.diagnostic = "async 和 asyncRewake 需要布尔值" }
                    else if item.asyncRewake == true && type != "command" { item.diagnostic = "asyncRewake 仅适用于 command 处理器" }
                    else if ["statusMessage", "rewakeMessage", "rewakeSummary"].contains(where: { handler[$0] != nil && !(handler[$0] is String) }) { item.diagnostic = "状态与唤醒消息需要字符串" }
                    else if (item.statusMessage?.count ?? 0) > 120 || item.statusMessage?.contains("\n") == true { item.diagnostic = "statusMessage 不超过 120 字且不能换行" }
                    else if (item.rewakeMessage?.count ?? 0) > 3000 || (item.rewakeSummary?.count ?? 0) > 300 { item.diagnostic = "rewakeMessage 不超过 3000 字，rewakeSummary 不超过 300 字" }
                    else if handler["once"] != nil && !(handler["once"] is Bool) { item.diagnostic = "once 需要布尔值；仅适用于会话级 Hooks" }
                    else if type != "command", ["shell", "env", "args"].contains(where: { handler[$0] != nil }) { item.diagnostic = "shell / env / args 仅适用于 command 处理器" }
                    else if type != "http", handler["allowedEnvVars"] != nil { item.diagnostic = "allowedEnvVars 仅适用于 HTTP 处理器" }
                    else if handler["if"] != nil && !(handler["if"] is String) { item.diagnostic = "if 需要字符串" }
                    else if name.count > 100 { item.diagnostic = "Hook 名称不超过 100 字" }
                    }
                    if item.diagnostic == nil, let condition = item.condition { do { _ = try AgentHookCondition(condition) } catch { item.diagnostic = error.localizedDescription } }
                    if let resourceDiagnostic { item.diagnostic = resourceDiagnostic }
                    item.signature = AgentFiles.hash(fingerprint + Data((id + (type == "command" ? "\0command-environment-v2" : "")).utf8)); result.append(item)
                    guard result.count <= 128 else { throw PetError("单份配置超过 128 个 Hooks") }
                }
            }
        }; return result
    }
    func catalog(workspace: String?) throws -> [AgentHookDefinition] {
        if let loadError { throw PetError(loadError) }; warnings = []
        try plugins.validateProjectActivations(workspace)
        var sources: [(URL, String, String?)] = [(profile.appendingPathComponent("extensions/hooks.json"), "全局", nil)]
        if let sharedHome { sources += [(sharedHome.appendingPathComponent(".qoder/settings.json"), "共享全局", nil)] }
        if let workspace {
            let root = try AgentFiles(workspace: workspace).root
            sources += [(root.appendingPathComponent(".bluefatfish/hooks.json"), "项目", workspace), (root.appendingPathComponent(".qoder/settings.json"), "共享项目", workspace), (root.appendingPathComponent(".qoder/settings.local.json"), "本机项目", workspace)]
        }
        var items: [AgentHookDefinition] = []
        for (file, scope, workspace) in sources where FileManager.default.fileExists(atPath: file.path) {
            do {
                let files = try AgentFiles(workspace: file.deletingLastPathComponent().path), data = try files.readData(files.resolve(file.lastPathComponent), maximum: 128_000)
                if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["hooks"] == nil { continue }
                items += try parse(data, file: file, scope: scope, workspace: workspace)
            } catch { warnings.append(file.lastPathComponent + "：" + error.localizedDescription) }
        }
        items += try pluginItems(workspace: workspace)
        let present = Set(items.map(\.id))
        for setting in settings.values where setting.enabled && !present.contains(setting.definition.id) && (setting.definition.workspace == nil || setting.definition.workspace == workspace) {
            if let reference = setting.definition.plugin, !plugins.isEffective(reference.name, workspace: workspace) { continue }
            var item = setting.definition; item.diagnostic = "来源已移除或不可读，请停用或修复配置"
            if let reference = item.plugin { item.pluginEnabled = pluginParentActive(reference) }
            items.append(item)
        }
        return items
    }
    func enabled(_ item: AgentHookDefinition) -> Bool { settings[item.id]?.enabled == true && item.pluginEnabled != false }
    func trusted(_ item: AgentHookDefinition) -> Bool { enabled(item) && settings[item.id]?.definition.signature == item.signature && item.diagnostic == nil }
    func setEnabled(_ item: AgentHookDefinition, _ enabled: Bool, workspace: String?) throws {
        if enabled {
            guard let current = try catalog(workspace: workspace).first(where: { $0.id == item.id }), current.signature == item.signature, current.diagnostic == nil, current.pluginEnabled != false else { throw PetError("Hook 已变化、所属插件未启用或有诊断错误，请刷新后核对") }
            try validatePlugin(current)
        }
        var updated = settings; updated[item.id] = AgentHookSetting(enabled: enabled, definition: item)
        guard updated.count <= 256 else { throw PetError("已保存的 Hook 授权最多256项") }
        let previous = settings; settings = updated
        do { try persistSettings() } catch { settings = previous; throw error }
        if !enabled { for list in jobs.values { for job in list.values where job.hookID == item.id { cancel(job) } } }
    }
    private func pluginParentActive(_ reference: AgentPluginHookReference) -> Bool {
        if (try? AgentPlugins.scope(reference.name).workspace) != nil { return (try? plugins.installation(reference.name)).map { $0.instanceID == reference.installationID && $0.enabled } ?? false }
        if let item = try? plugins.installation(reference.name) { return item.instanceID == reference.installationID && item.enabled }
        guard AgentExtensions.validName(reference.name), !reference.name.contains(":") else { return true }
        return FileManager.default.fileExists(atPath: profile.appendingPathComponent("extensions/plugins/" + reference.name).path)
    }
    func pluginConfigurationFailure(_ reference: AgentPluginHookReference, error: Error) -> [AgentHookDefinition] {
        warnings.append(reference.name + "：" + error.localizedDescription)
        return settings.values.filter { $0.definition.plugin == reference }.map { setting in
            var item = setting.definition; item.diagnostic = error.localizedDescription; item.pluginEnabled = pluginParentActive(reference); return item
        }
    }
    private func persistSettings() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let files = try AgentFiles(workspace: profile.path); try files.writeData(encoder.encode(settings), to: files.resolve("extensions/hook-settings.json"), permissions: 0o600)
    }
    func clearCredentials(_ item: AgentHookDefinition, workspace: String?) throws { try setEnabled(item, false, workspace: workspace); try credentials.clear(item) }
    private func matches(_ pattern: String, _ value: String, name: String) throws -> Bool {
        if pattern.isEmpty || pattern == "*" { return true }
        let alternatives = pattern.components(separatedBy: "|")
        if alternatives.allSatisfy({ !$0.isEmpty && $0.rangeOfCharacter(from: CharacterSet(charactersIn: ".^$*+?()[]{}\\")) == nil }) {
            return value.components(separatedBy: "\n").contains(where: alternatives.contains)
        }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let deadline = Date().addingTimeInterval(0.05); var expired = false
        for part in value.components(separatedBy: "\n") {
            var found = false
            regex.enumerateMatches(in: part, options: .reportProgress, range: NSRange(part.startIndex..., in: part)) { match, _, stop in
                if match != nil { found = true; stop.pointee = true }
                if Date() > deadline { expired = true; stop.pointee = true }
            }
            if expired { throw AgentHookHalt("Hook 匹配计算超时：" + name) }
            if found { return true }
        }; return false
    }
    func fire(_ event: AgentHookEvent, trigger: String, store: AgentStore, taskID: String, value: String = "", fields: [String: Any] = [:], secret: String = "", preferences: PetPreferences? = nil, onChange: @escaping () -> Void = {}) async throws -> AgentHookEffect {
        guard let task = store.task(taskID), !["wiki", "hook"].contains(task.kind ?? "") else { return AgentHookEffect() }
        if let loadError { throw AgentHookHalt(loadError) }
        guard settings.values.contains(where: \.enabled) else { return AgentHookEffect() }
        let hooks = try catalog(workspace: task.workspace).filter { $0.event == event && enabled($0) }
        var combined = AgentHookEffect()
        for hook in hooks {
            try Task.checkCancellation()
            guard trusted(hook) else { throw AgentHookHalt("Hook 需要重新审核：" + hook.name + "。" + (hook.diagnostic ?? "配置或 hooks 目录已变化，请在管理界面重新启用")) }
            guard try matches(hook.matcher, value, name: hook.name) else { continue }
            if let text = hook.condition {
                let condition = try AgentHookCondition(text)
                guard try matches(condition.selector, value, name: hook.name), condition.argumentMatches(fields) else { continue }
            }
            let key = AgentFiles.hash(Data((trigger + ":" + event.rawValue + ":" + hook.id + ":" + hook.signature).utf8))
            if let prior = store.task(taskID)?.events.last(where: { $0.hook?.key == key }) {
                // Background work is scheduled once, including interrupted or
                // still-running work. Its result is delivered separately.
                if prior.hook?.asynchronous == true { continue }
                guard let effect = prior.hook?.effect else { throw AgentHookHalt("上次 Hook 结果未确认，请先核对实际状态后重新发起操作：" + hook.name) }
                combined.merge(effect); continue
            }
            let eventID = UUID().uuidString, origin = task.messages.last(where: \.isHumanInput)?.id
            let execution = AgentHookExecution(key: key, hookID: hook.id, event: event, signature: hook.signature, asynchronous: hook.runsInBackground, originPromptID: origin)
            let display = secret.isEmpty ? hook.display : hook.display.replacingOccurrences(of: secret, with: "[Token 已隐藏]")
            if hook.runsInBackground, (jobs[taskID]?.count ?? 0) >= 16 || jobs.values.reduce(0, { $0 + $1.count }) >= 32 {
                var skipped = execution; skipped.delivery = "not-started"
                store.update(taskID) { $0.events.append(AgentEvent(id: eventID, kind: "hook", title: hook.name, detail: "后台 Hook 已达并发上限，此次未启动", status: "failed", hook: skipped)) }; onChange(); continue
            }
            let job = Job(hook); jobs[taskID, default: [:]][eventID] = job
            store.update(taskID) { $0.events.append(AgentEvent(id: eventID, kind: "hook", title: hook.name, detail: event.rawValue + " · " + hook.type + (hook.runsInBackground ? " · 后台" : "") + (hook.statusMessage.map { " · " + $0 } ?? "") + "\n" + display, hook: execution)) }; onChange()
            let work = Task { @MainActor [self] in try await execute(hook, eventID: eventID, task: task, store: store, fields: fields, secret: secret, preferences: preferences, job: job, onChange: onChange) }
            job.task = work
            if hook.runsInBackground { continue }
            let effect = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            combined.merge(effect)
            if combined.halt != nil || (combined.deny != nil && event.controlsExecution) { break }
        }; return combined
    }
    private func sameScope(_ current: AgentTaskRecord, _ origin: AgentTaskRecord) -> Bool {
        !current.archived && current.workspace == origin.workspace && current.mode == origin.mode && current.permission == origin.permission && current.agent?.profile.id == origin.agent?.profile.id && current.agent?.ownerID == origin.agent?.ownerID && current.team?.team.id == origin.team?.team.id
    }
    private func execute(_ hook: AgentHookDefinition, eventID: String, task: AgentTaskRecord, store: AgentStore, fields: [String: Any], secret: String, preferences: PetPreferences?, job: Job, onChange: @escaping () -> Void) async throws -> AgentHookEffect {
        let taskID = task.id, event = hook.event, started = Date()
        var secretValues = [secret]
        func redact(_ text: String) -> String { secretValues.filter { !$0.isEmpty }.sorted { $0.count > $1.count }.reduce(text) { $0.replacingOccurrences(of: $1, with: "[凭据已隐藏]") } }
        defer {
            if store.task(taskID)?.events.first(where: { $0.id == eventID })?.status == "running" {
                store.update(taskID) { record in if let i = record.events.firstIndex(where: { $0.id == eventID }) { record.events[i].status = Task.isCancelled || job.cancelReason == "user" ? "stopped" : "failed"; record.events[i].duration = Date().timeIntervalSince(started) } }
            }
            jobs[taskID]?[eventID] = nil; if jobs[taskID]?.isEmpty == true { jobs[taskID] = nil }; onChange()
        }
        do {
            try Task.checkCancellation()
            guard let current = store.task(taskID), sameScope(current, task), job.cancelReason == nil else { throw CancellationError() }
            try validatePlugin(hook)
            if hook.runsInBackground {
                guard let fresh = try catalog(workspace: current.workspace).first(where: { $0.id == hook.id }), fresh.signature == hook.signature, trusted(fresh) else { throw AgentHookHalt("Hook 配置已变化，未启动：" + hook.name) }
            }
            let limits = try store.agents.limits(current, store: store)
            let commandEnvironment = hook.type == "command" ? try credentials.values(hook) : [:]
            if hook.type == "command" {
                secretValues += commandEnvironment.values
                secretValues += ProcessInfo.processInfo.environment.filter { $0.key.range(of: "TOKEN|SECRET|PASSWORD|CREDENTIAL|API_KEY|ACCESS_KEY|AUTHORIZATION", options: [.regularExpression, .caseInsensitive]) != nil }.values
            }
            if current.agent != nil || current.automation != nil, hook.network || hook.type == "http" {
                guard limits.network, hook.type != "http" || !limits.readOnly else { throw AgentHookHalt("当前 Agent 的只读或外部连接范围不允许此 Hook") }
            }
            let scratch = try store.backupDirectory(taskID).deletingLastPathComponent().appendingPathComponent("tmp", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let input = scratch.appendingPathComponent("hook-" + eventID + ".json"), transcript = scratch.appendingPathComponent("hook-transcript-" + eventID + ".jsonl")
            defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: transcript) }
            var payload: [String: Any] = ["session_id": task.hookSession ?? task.id, "cwd": task.workspace ?? scratch.path, "hook_event_name": event.rawValue, "transcript_path": transcript.path, "permission_mode": task.permission.rawValue]
            for (name, value) in fields { payload[name] = value }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]); guard data.count <= 500_000 else { throw AgentHookHalt("Hook 输入超过 500KB") }
            try AgentFiles(workspace: scratch.path).writeData(Data(redact(String(decoding: data, as: UTF8.self)).utf8), to: input, permissions: 0o600)
            FileManager.default.createFile(atPath: transcript.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let transcriptHandle = try FileHandle(forWritingTo: transcript)
            do {
                for message in task.messages where message.hookRejected != true {
                    var bytes = Data(redact(String(decoding: try JSONEncoder().encode(message), as: UTF8.self)).utf8); bytes.append(10); try transcriptHandle.write(contentsOf: bytes)
                }; try transcriptHandle.close()
            } catch { try? transcriptHandle.close(); throw error }
            let safeInput = try AgentFiles(workspace: scratch.path).readData(input, maximum: 500_000)
            let work = Task { @MainActor [self] () throws -> AgentToolResult in
                try Task.checkCancellation()
                switch hook.type {
                case "http": return try await http.send(safeInput, hook: hook, secret: secret) { secretValues += $0 }
                case "prompt", "agent":
                    guard let preferences else { throw AgentHookHalt("模型 Hook 需要当前任务的模型配置") }
                    return try await AgentHookModel.evaluate(hook: hook, payload: safeInput, store: store, owner: taskID, preferences: preferences, key: secret, onChild: { childID in
                        job.childID = childID
                        store.update(taskID) { record in if let i = record.events.firstIndex(where: { $0.id == eventID }) { record.events[i].hook?.childTaskID = childID; record.events[i].detail += "\n评估子任务：" + childID } }; onChange()
                    }, onChange: onChange)
                default:
                    var environment = commandEnvironment
                    environment["QODER_PROJECT_DIR"] = task.workspace ?? scratch.path; environment["QODER_HOOK_ROOT"] = hook.root; environment["BLUEFATFISH_HOOK_EVENT"] = event.rawValue
                    if hook.plugin != nil { for name in AgentPlugins.hookRootVariables { environment[name] = hook.root } }
                    let shell: String?, command: String
                    if hook.arguments == nil && hook.shell == "powershell" {
                        guard let pwsh = ["/opt/homebrew/bin/pwsh", "/usr/local/bin/pwsh"].first(where: FileManager.default.isExecutableFile(atPath:)) else { throw AgentHookHalt("未安装 PowerShell") }
                        shell = pwsh; command = "$QODER_PROJECT_DIR=$env:QODER_PROJECT_DIR; $QODER_HOOK_ROOT=$env:QODER_HOOK_ROOT; " + (hook.plugin == nil ? "" : "$QODER_PLUGIN_ROOT=$env:QODER_PLUGIN_ROOT; $CLAUDE_PLUGIN_ROOT=$env:CLAUDE_PLUGIN_ROOT; $PLUGIN_ROOT=$env:PLUGIN_ROOT; ") + hook.command
                    } else { shell = hook.shell == "bash" ? "/bin/bash" : nil; command = hook.command }
                    return try await AgentCommand().run(command: command, workspace: task.workspace.map { URL(fileURLWithPath: $0) } ?? scratch, scratch: scratch, network: hook.network, timeout: hook.timeout, readOnly: limits.readOnly, maximumOutput: 64_000, protectedData: profile, inputFile: input, readRoots: [URL(fileURLWithPath: hook.root)], environment: environment, arguments: hook.arguments, shell: shell, inheritEnvironment: true)
                }
            }
            let result = try await withTaskCancellationHandler(operation: {
                if hook.type == "command" { return try await work.value }
                return try await withThrowingTaskGroup(of: AgentToolResult.self) { group in
                    group.addTask { try await work.value }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(hook.timeout * 1_000_000_000))
                        await MainActor.run { if job.cancelReason == nil { job.cancelReason = "timeout" }; work.cancel() }
                        throw AgentHookHalt("Hook 执行超时：" + hook.name)
                    }
                    defer { group.cancelAll() }
                    guard let result = try await group.next() else { throw CancellationError() }; return result
                }
            }, onCancel: { work.cancel() })
            try Task.checkCancellation()
            if hook.runsInBackground && result.timedOut { throw AgentHookHalt("后台 Hook 执行超时，结果未加入上下文：" + hook.name) }
            guard let latest = store.task(taskID), sameScope(latest, task), job.cancelReason == nil else { throw CancellationError() }
            let latestLimits = try store.agents.limits(latest, store: store)
            guard latestLimits == limits else { throw AgentHookHalt("Hook 执行范围已变化，结果未加入上下文") }
            try validatePlugin(hook)
            if hook.runsInBackground {
                guard let fresh = try catalog(workspace: latest.workspace).first(where: { $0.id == hook.id }), fresh.signature == hook.signature, trusted(fresh) else { throw AgentHookHalt("后台 Hook 来源已变化，结果未加入上下文") }
            }
            // Interpret protocol values before hiding text. An env value such
            // as "block" or "false" must never alter the execution decision.
            var effect = hook.runsInBackground ? try backgroundEffect(hook, result: result, stdout: result.stdout ?? "", stderr: result.stderr ?? "") : try interpret(event, result: result, stdout: result.stdout ?? "", stderr: result.stderr ?? "")
            if let input = effect.updatedInput, redact(input) != input { throw AgentHookHalt("Hook 参数包含受保护的凭据或环境值，未继续执行") }
            effect.context = redact(effect.context); effect.systemMessage = effect.systemMessage.map(redact)
            effect.deny = effect.deny.map(redact); effect.halt = effect.halt.map(redact); effect.sessionTitle = effect.sessionTitle.map(redact)
            let stdout = redact(result.stdout ?? ""), stderr = redact(result.stderr ?? "")
            if !hook.runsInBackground, result.truncated == true && event.controlsExecution { effect.halt = "Hook 输出超过 64KB，未继续执行" }
            store.update(taskID) { record in
                if let i = record.events.firstIndex(where: { $0.id == eventID }) {
                    record.events[i].status = effect.deny != nil || effect.halt != nil ? "blocked" : result.failed ? "failed" : "completed"
                    record.events[i].duration = Date().timeIntervalSince(started); record.events[i].detail += "\n[exit=\(result.exitCode ?? -1)]\n" + (effect.suppressOutput ? "[输出已隐藏]" : String((stdout + "\n" + stderr).prefix(12_000)))
                    record.events[i].hook?.effect = effect; record.events[i].hook?.exitCode = result.exitCode
                    if let childID = job.childID, let child = store.task(childID) { record.events[i].hook?.model = child.model; record.events[i].hook?.inputTokens = child.inputTokens; record.events[i].hook?.outputTokens = child.outputTokens }
                }
            }; onChange()
            if hook.runsInBackground {
                let contextKey = "async:" + eventID
                let size = (store.task(taskID)?.hookContexts?.values.reduce(0) { $0 + $1.count } ?? 0) + effect.context.count
                guard size <= 16_000 else { throw AgentHookHalt("后台 Hook 输出未加入上下文：补充资料已超过 16000 字") }
                let wake = hook.asyncRewake == true && result.exitCode == 2
                store.update(taskID) { record in
                    if !effect.context.isEmpty, record.hookContextIDs?.contains(contextKey) != true {
                        if record.hookContexts == nil { record.hookContexts = [:] }; record.hookContexts?[contextKey] = effect.context
                        if record.hookContextIDs == nil { record.hookContextIDs = [] }; record.hookContextIDs?.append(contextKey)
                    }
                    if let i = record.events.firstIndex(where: { $0.id == eventID }) { record.events[i].hook?.delivery = effect.context.isEmpty ? "recorded" : "queued"; record.events[i].hook?.rewakeRequested = wake }
                }
                onAsyncResult?(taskID, eventID, task.messages.last(where: \.isHumanInput)?.id, wake)
            }
            return effect
        } catch {
            let cancelled = job.cancelReason != "timeout" && (job.cancelReason == "user" || Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled)
            let detail = cancelled ? "Hook 已停止" : job.cancelReason == "timeout" ? "Hook 执行超时：" + hook.name : error.localizedDescription
            store.update(taskID) { record in if let i = record.events.firstIndex(where: { $0.id == eventID }) { record.events[i].status = cancelled ? "stopped" : "failed"; record.events[i].duration = Date().timeIntervalSince(started); record.events[i].detail += "\n" + redact(detail); if hook.runsInBackground { record.events[i].hook?.delivery = cancelled ? "cancelled" : "not-delivered" } } }; onChange(); throw error
        }
    }
    private func backgroundEffect(_ hook: AgentHookDefinition, result: AgentToolResult, stdout: String, stderr: String) throws -> AgentHookEffect {
        var effect = AgentHookEffect(), content = stdout
        if let object = (try? JSONSerialization.jsonObject(with: Data(stdout.utf8))) as? [String: Any] {
            if object.isEmpty { content = "" }
            effect.systemMessage = object["systemMessage"] as? String; effect.suppressOutput = object["suppressOutput"] as? Bool ?? false
            if let specific = object["hookSpecificOutput"] as? [String: Any] {
                guard specific["hookEventName"] as? String == hook.event.rawValue else { throw AgentHookHalt("后台 Hook 输出的 hookEventName 不匹配") }
                if let context = specific["additionalContext"] as? String { content = context }
            }
        }
        if !stderr.isEmpty { content += (content.isEmpty ? "" : "\n") + stderr }
        if hook.asyncRewake == true, result.exitCode == 2 {
            content = (hook.rewakeMessage ?? "后台检查要求继续核对") + "\n" + (hook.rewakeSummary.map { $0 + "\n" } ?? "") + content
        }
        if let message = effect.systemMessage, !message.isEmpty { content += "\n" + message }
        if result.truncated == true { content = "[输出超过 64KB，以下只是节选，不能据此声称检查完整通过]\n" + content }
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            effect.context = "[后台 Hook：\(hook.name) · \(hook.event.rawValue) · exit=\(result.exitCode ?? -1)；结果只作补充资料，不改变审批或工具参数]\n" + String(content.prefix(3000))
        }
        return effect
    }
    private func interpret(_ event: AgentHookEvent, result: AgentToolResult, stdout: String, stderr: String) throws -> AgentHookEffect {
        var effect = AgentHookEffect()
        if result.exitCode == 2 && event.controlsExecution { effect.deny = String((stderr.isEmpty ? "Hook 阻止了此操作" : stderr).prefix(2000)); return effect }
        if result.failed {
            if event.controlsExecution && (result.exitCode == nil || (result.text.contains("timeout"))) { effect.halt = "Hook 未完成，未继续执行：" + String(stderr.prefix(1000)) }
            return effect
        }
        guard let value = try? JSONSerialization.jsonObject(with: Data(stdout.utf8)), let object = value as? [String: Any] else {
            if [.sessionStart, .prompt].contains(event) { effect.context = String(stdout.prefix(3000)) }; return effect
        }
        let reason = object["reason"] as? String ?? "Hook 阻止了此操作"
        if object["continue"] as? Bool == false { effect.halt = object["stopReason"] as? String ?? reason }
        if ["deny", "block"].contains(object["decision"] as? String ?? ""), event.controlsExecution { effect.deny = reason }
        effect.systemMessage = object["systemMessage"] as? String; effect.suppressOutput = object["suppressOutput"] as? Bool ?? false
        if let specific = object["hookSpecificOutput"] as? [String: Any] {
            guard specific["hookEventName"] as? String == event.rawValue else { throw AgentHookHalt("Hook 输出缺少匹配的 hookEventName") }
            effect.context = String((specific["additionalContext"] as? String ?? "").prefix(3000))
            if [.preTool, .permission].contains(event) {
                let nested = event == .permission ? specific["decision"] as? [String: Any] : nil
                let decision = specific["permissionDecision"] as? String ?? nested?["behavior"] as? String
                if let decision, !["allow", "deny", "ask"].contains(decision) { throw AgentHookHalt("未知 Hook 权限结果：" + decision) }
                if decision == "deny" { effect.deny = specific["permissionDecisionReason"] as? String ?? nested?["message"] as? String ?? reason }
                if decision == "ask" { effect.ask = true }
                if event == .permission, specific["updatedInput"] != nil || nested?["updatedInput"] != nil || nested?["updatedPermissions"] != nil {
                    throw AgentHookHalt("PermissionRequest 暂不接受参数或权限改写；参数改写请移至 PreToolUse，原有审批仍生效")
                }
                if event == .preTool, let input = specific["updatedInput"] as? [String: Any] { let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]); guard data.count <= 100_000 else { throw AgentHookHalt("Hook 修改的参数超过 100KB") }; effect.updatedInput = String(decoding: data, as: UTF8.self) }
            }
            if event == .prompt { effect.sessionTitle = (specific["sessionTitle"] as? String).map { String($0.prefix(60)) } }
            if event == .postTool, let output = specific["updatedToolOutput"] { effect.context += "\n[Hook 提供的补充输出，原工具结果保留]\n" + String(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self).prefix(3000)) }
        }; return effect
    }
}
