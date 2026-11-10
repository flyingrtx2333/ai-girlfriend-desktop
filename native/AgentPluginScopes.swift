import Foundation

struct AgentPluginLocalReview: Codable {
    var reviewedHash: String
    var activeHash: String?
}

@MainActor extension AgentPlugins {
    nonisolated static func scopedID(_ name: String, workspace: String?) -> String {
        workspace.map { "project:" + Data($0.utf8).base64EncodedString() + ":" + name } ?? name
    }
    nonisolated static func scope(_ id: String) throws -> (name: String, workspace: String?) {
        if validName(id) { return (id, nil) }
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "project", validName(String(parts[2])),
              let data = Data(base64Encoded: String(parts[1])), data.base64EncodedString() == String(parts[1]),
              let path = String(data: data, encoding: .utf8), path.hasPrefix("/"), path.utf8.count <= 4000, !path.contains("\0"),
              URL(fileURLWithPath: path).standardizedFileURL.path == path else { throw PetError("插件范围无效，请重新选择项目与插件") }
        return (String(parts[2]), path)
    }
    func scopeCatalog(_ workspace: String?) throws -> (items: [AgentPluginInstallation], names: Set<String>, warnings: [String]) {
        let files = try AgentFiles(workspace: workspace ?? profile.path)
        let base = try files.literalURL(workspace == nil ? "extensions/plugins" : ".bluefatfish/plugins")
        guard FileManager.default.fileExists(atPath: base.path) else { return ([], [], []) }
        guard base.resolvingSymlinksInPath() == base else { throw PetError("插件目录不能是链接") }
        let children = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles])
        guard children.count <= 64 else { throw PetError("此范围插件数量超过64项") }
        var items: [AgentPluginInstallation] = [], warnings: [String] = []; var known = Set<String>()
        let reviews = workspace == nil ? [:] : try projectApprovals()
        for child in children {
            do {
                guard try child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw PetError("插件目录不能是链接") }
                items.append(try installation(Self.scopedID(child.lastPathComponent, workspace: workspace)))
            } catch { warnings.append(child.lastPathComponent + "：" + error.localizedDescription) }
            let id = Self.scopedID(child.lastPathComponent, workspace: workspace)
            if workspace == nil { known.insert(child.lastPathComponent) }
            else if let review = reviews[id] {
                if review.activeHash != nil { known.insert(child.lastPathComponent) }
                else if let data = try? AgentFiles(workspace: child.path).readData(child.appendingPathComponent("receipt.json"), maximum: 500_000), let receipt = try? JSONDecoder().decode(AgentPluginReceipt.self, from: data), try Self.reviewFingerprint(receipt) == review.reviewedHash { known.insert(child.lastPathComponent) }
            }
        }
        let linked = Set(items.flatMap { ($0.receipt.revisions ?? []).map(\.directory) })
        let unlinked = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".plugin-revision-") && !linked.contains($0.lastPathComponent) }
        if !unlinked.isEmpty { warnings.append("\(unlinked.count)份未关联的版本副本保留在：" + base.path) }
        return (items.sorted { $0.metadata.title.localizedStandardCompare($1.metadata.title) == .orderedAscending }, known, warnings)
    }
    nonisolated static func reviewFingerprint(_ receipt: AgentPluginReceipt) throws -> String {
        struct Content: Encodable { var installationID: String?; var sourceHash: String; var hashes: [String: String] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return AgentFiles.hash(try encoder.encode(Content(installationID: receipt.installationID, sourceHash: receipt.sourceHash, hashes: receipt.hashes)))
    }
    func projectApprovals() throws -> [String: AgentPluginLocalReview] {
        let files = try AgentFiles(workspace: profile.path), file = try files.literalURL("extensions/project-plugin-approvals.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let values = try JSONDecoder().decode([String: AgentPluginLocalReview].self, from: files.readData(file, maximum: 512_000))
        func digest(_ hash: String) -> Bool { hash.count == 64 && hash.allSatisfy(\.isHexDigit) }
        guard values.count <= 2048, values.allSatisfy({ key, value in (try? Self.scope(key).workspace) != nil && digest(value.reviewedHash) && (value.activeHash.map(digest) ?? true) }) else { throw PetError("项目插件本机审阅记录无效，请在设置目录核对") }
        return values
    }
    private func saveProjectApprovals(_ values: [String: AgentPluginLocalReview]) throws {
        guard values.count <= 2048 else { throw PetError("项目插件本机审阅记录已达2048项，请先核对不用的项目") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(values); guard data.count <= 512_000 else { throw PetError("项目插件本机审阅记录超过512 KB") }
        let files = try AgentFiles(workspace: profile.path); try files.writeData(data, to: files.literalURL("extensions/project-plugin-approvals.json"), permissions: 0o600)
    }
    func revokeProjectApproval(_ id: String) throws {
        guard try Self.scope(id).workspace != nil else { return }
        var values = try projectApprovals(); guard values[id]?.activeHash != nil else { return }
        values[id]?.activeHash = nil; try saveProjectApprovals(values)
    }
    func recordProjectReview(_ item: AgentPluginInstallation, active: Bool) throws {
        guard item.workspace != nil else { return }
        var values = try projectApprovals(); values[item.id] = AgentPluginLocalReview(reviewedHash: try Self.reviewFingerprint(item.receipt), activeHash: active ? item.receiptHash : nil)
        try saveProjectApprovals(values)
    }
    func validateProjectActivations(_ workspace: String?) throws {
        guard let workspace else { return }; let root = try AgentFiles(workspace: workspace).root.path
        for (id, review) in try projectApprovals() where review.activeHash != nil && (try? Self.scope(id).workspace) == root {
            guard let item = try? installation(id), item.locallyReviewed, item.enabled, item.receiptHash == review.activeHash else { throw PetError("项目插件来源已变化，请在“插件 → 项目”重新审阅或全部停用：" + ((try? Self.scope(id).name) ?? "")) }
        }
    }
    func hasProjectActivations(_ workspace: String?) -> Bool {
        guard let workspace, let root = try? AgentFiles(workspace: workspace).root.path else { return false }
        return (try? projectApprovals().contains { id, review in review.activeHash != nil && (try? Self.scope(id).workspace) == root }) ?? false
    }
    func disableProject(_ workspace: String) throws -> [String] {
        let root = try AgentFiles(workspace: workspace).root.path
        var values = try projectApprovals()
        let ids = values.keys.filter { (try? Self.scope($0).workspace) == root }
        for id in ids { values[id]?.activeHash = nil }; try saveProjectApprovals(values)
        for id in ids { notify(id) }
        var failures: [String] = []
        for item in try scopeCatalog(root).items where item.receipt.enabled {
            do { try setEnabled(item, false) } catch { failures.append(item.metadata.name + "：" + error.localizedDescription) }
        }
        return failures
    }
    func requireScope(_ id: String, workspace: String?) throws {
        if let required = try Self.scope(id).workspace {
            guard let workspace, try AgentFiles(workspace: workspace).root.path == required else { throw PetError("此插件仅属于原项目，请重新选择当前项目的插件") }
        }
        if (try Self.scope(id).workspace) != nil, !(try installation(id)).locallyReviewed { throw PetError("项目插件来源尚未在本机审阅，请先在插件窗口审阅并启用") }
        guard try catalog(workspace: workspace).contains(where: { $0.id == id }) else { throw PetError("此插件已由当前项目的同名插件覆盖，请重新选择组件") }
    }
    func isEffective(_ id: String, workspace: String?) -> Bool { (try? catalog(workspace: workspace).contains { $0.id == id }) == true }
}
