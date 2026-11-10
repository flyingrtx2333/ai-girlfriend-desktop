import Foundation
import CoreFoundation

enum AgentPluginSettingScope: Int, CaseIterable {
    case user, project, local
    var title: String { ["用户", "项目", "本机"][rawValue] }
}
struct AgentPluginSelection {
    let enabled: Bool, scope: AgentPluginSettingScope, file: URL, pluginID: String
    var hash: String { AgentFiles.hash(Data((file.path + "\n" + pluginID + "\n" + String(enabled)).utf8)) }
}
struct AgentPluginSettingDocument {
    let files: AgentFiles, file: URL, object: [String: Any], values: [String: Bool], hash: String?
}

@MainActor extension AgentPlugins {
    func settingDocument(_ scope: AgentPluginSettingScope, workspace: String?) throws -> AgentPluginSettingDocument {
        let root: String
        if scope == .user { guard let sharedHome else { throw PetError("未设置用户配置目录") }; root = sharedHome.path }
        else { guard let workspace else { throw PetError("请先选择项目") }; root = workspace }
        let files = try AgentFiles(workspace: root), file = try files.literalURL(scope == .local ? ".qoder/settings.local.json" : ".qoder/settings.json")
        let entry = try files.entryMetadata(file)
        guard ["file", "missing"].contains(entry.kind) else { throw PetError("插件设置须为普通文件：" + file.path) }
        let data = entry.kind == "file" ? try files.readData(file, maximum: 512_000) : nil
        let object: [String: Any]
        if let data {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PetError("插件设置须为JSON对象：" + file.path) }; object = value
        } else { object = [:] }
        guard object["enabledPlugins"] == nil || object["enabledPlugins"] is [String: Any] else { throw PetError("enabledPlugins须为对象：" + file.path) }
        let raw = object["enabledPlugins"] as? [String: Any] ?? [:]
        guard raw.count <= 2048 else { throw PetError("插件设置超过2048项") }
        var values: [String: Bool] = [:]
        for (key, value) in raw {
            let parts = key.split(separator: "@", omittingEmptySubsequences: false)
            guard key.utf8.count <= 256, !key.contains("\0"), parts.count == 2, parts.allSatisfy({ !$0.isEmpty }), !key.contains(where: \.isWhitespace),
                  let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw PetError("enabledPlugins须使用完整插件ID和布尔值：" + file.path) }
            values[key] = number.boolValue
        }
        return AgentPluginSettingDocument(files: files, file: file, object: object, values: values, hash: data.map(AgentFiles.hash))
    }
    func pluginSelection(_ name: String, workspace: String?, replacing: (AgentPluginSettingScope, Bool?)? = nil) throws -> AgentPluginSelection? {
        let id = name + "@local"
        var result: AgentPluginSelection?
        for scope in AgentPluginSettingScope.allCases where (scope == .user ? sharedHome != nil : workspace != nil) {
            let document = try settingDocument(scope, workspace: workspace)
            let value = replacing?.0 == scope ? replacing!.1 : document.values[id]
            if let value { result = AgentPluginSelection(enabled: value, scope: scope, file: document.file, pluginID: id) }
        }
        return result
    }
    func setPluginSetting(_ value: Bool?, name: String, scope: AgentPluginSettingScope, workspace: String?, expectedHash: String?) throws {
        guard Self.validName(name) else { throw PetError("插件名称无效") }
        let document = try settingDocument(scope, workspace: workspace)
        guard document.hash == expectedHash else { throw PetError("插件设置已变化，请刷新后重试") }
        if document.values[name + "@local"] == value { return }
        var object = document.object, values = document.values
        values[name + "@local"] = value
        object["enabledPlugins"] = values
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard data.count <= 512_000 else { throw PetError("插件设置超过512KB") }
        let write = try AgentKnowledgeFileWrite(files: document.files, path: document.file.path, data: data, expectedHash: document.hash, missing: document.hash == nil, permissions: scope == .project ? nil : 0o600, label: "插件设置")
        try write.requireCurrent()
        if scope == .user {
            for id in try projectApprovals().keys where (try? Self.scope(id).name) == name {
                guard let owner = try Self.scope(id).workspace else { continue }
                let changed: Bool
                do { changed = try pluginSelection(name, workspace: owner)?.hash != pluginSelection(name, workspace: owner, replacing: (scope, value))?.hash }
                catch { changed = true }
                if changed { try revokeProjectApproval(id); notify(id) }
            }
            notify(name)
        } else if let workspace {
            if try pluginSelection(name, workspace: workspace)?.hash != pluginSelection(name, workspace: workspace, replacing: (scope, value))?.hash {
                let id = Self.scopedID(name, workspace: try AgentFiles(workspace: workspace).root.path)
                try revokeProjectApproval(id); notify(id)
            }
        }
        try write.files.writeData(data, to: write.url, permissions: write.permissions, expectedTarget: write.signature)
    }
}
