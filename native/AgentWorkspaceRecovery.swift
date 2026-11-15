import Foundation
import Darwin

// Layouts and editor drafts live beside the task store. Original project files
// are never used as autosave destinations.
struct AgentWorkspaceRecovery: Sendable {
    struct Frame: Codable, Equatable, Sendable {
        var x: Double, y: Double, width: Double, height: Double
        var valid: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
    }
    struct Tab: Codable, Equatable, Sendable {
        var id = UUID().uuidString
        var root: String
        var title: String
    }
    struct TaskLayout: Codable, Equatable, Sendable {
        var taskID: String
        var tabs: [Tab]
        var selected: String?
        var opened: Bool
        var expanded: Bool
    }
    struct FloatingPage: Codable, Equatable, Sendable {
        var taskID: String
        var tab: Tab
        var frame: Frame?
    }
    struct Window: Codable, Equatable, Sendable {
        var version = 1
        var id: String
        var number: Int
        var taskID: String?
        var frame: Frame?
        var tasks: [TaskLayout]
        var floating: [FloatingPage] = []
        var closed = false
    }
    struct Asset: Codable, Equatable, Sendable {
        var slot: Int
        var hash: String
    }
    struct Page: Codable, Equatable, Sendable {
        var version = 1
        var taskID: String
        var kind: String
        var state: Data
        var dirty: Bool
        var asset: Asset?
    }
    struct Saved<Value: Sendable>: Sendable {
        var value: Value
        var hash: String
    }
    struct LoadedPage: Sendable {
        var saved: Saved<Page>
        var asset: URL?
    }
    struct Listing: Sendable {
        var windows: [Saved<Window>] = []
        var issues: [String] = []
    }

    let profile: URL
    private static let maximumState = 20_000_000
    private static let label = "工作区恢复记录"

    init(profile: URL) { self.profile = profile.standardizedFileURL.resolvingSymlinksInPath() }

    private static func uuid(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString == value }
    private static func hash(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase } }
    private func prefix(_ windowID: String) throws -> String {
        guard Self.uuid(windowID) else { throw PetError("工作区窗口编号无效") }
        return "workspace-recovery/" + windowID
    }
    private func pagePath(_ windowID: String, _ pageID: String) throws -> String {
        guard Self.uuid(pageID) else { throw PetError("工作区标签编号无效") }
        return try prefix(windowID) + "/pages/" + pageID
    }
    private func files() throws -> AgentFiles { try AgentFiles(workspace: profile.path) }
    private func literal(_ files: AgentFiles, _ path: String) throws -> URL {
        let url = try files.literalURL(path)
        guard try files.resolve(path) == url else { throw PetError(Self.label + "路径包含符号链接") }
        return url
    }
    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumState else { throw PetError(Self.label + "超过20MB，请先保存或关闭部分编辑") }
        return data
    }
    private func locked<T>(_ windowID: String, _ operation: (AgentFiles) throws -> T) throws -> T {
        let files = try files(), path = try prefix(windowID) + "/write.lock", lock = try literal(files, path)
        let (parent, name) = try files.parentDescriptor(lock, create: true); defer { close(parent) }
        let fd = openat(parent, name, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PetError(Self.label + "无法锁定") }; defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw PetError("另一窗口正在保存" + Self.label) }; defer { flock(fd, LOCK_UN) }
        return try operation(files)
    }
    private func validate(_ value: Window) throws {
        guard value.version == 1, Self.uuid(value.id), value.number > 0,
              value.taskID.map({ UUID(uuidString: $0) != nil }) ?? true, value.frame?.valid != false,
              Set(value.tasks.map(\.taskID)).count == value.tasks.count else { throw PetError("工作区窗口恢复格式无效或版本不受支持") }
        var ids = Set<String>()
        func tab(_ value: Tab) throws {
            guard Self.uuid(value.id), ids.insert(value.id).inserted, !value.root.isEmpty, value.root.utf8.count <= 16_384,
                  !value.root.contains("\0"), value.title.utf8.count <= 4096 else { throw PetError("工作区标签恢复格式无效") }
        }
        for task in value.tasks {
            guard UUID(uuidString: task.taskID) != nil, Set(task.tabs.map(\.root)).count == task.tabs.count,
                  task.selected.map({ selected in task.tabs.contains { $0.root == selected } }) ?? true else { throw PetError("工作区任务恢复范围无效") }
            try task.tabs.forEach(tab)
        }
        for page in value.floating {
            guard UUID(uuidString: page.taskID) != nil, page.frame?.valid != false else { throw PetError("独立编辑窗口恢复格式无效") }
            try tab(page.tab)
        }
    }
    private func validate(_ value: Page) throws {
        guard value.version == 1, UUID(uuidString: value.taskID) != nil, !value.kind.isEmpty, value.kind.utf8.count <= 80,
              value.kind.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }), value.state.count <= Self.maximumState,
              value.asset.map({ [0, 1].contains($0.slot) && Self.hash($0.hash) }) ?? true else { throw PetError("工作区编辑恢复格式无效或版本不受支持") }
    }
    private func keys(_ value: Any, _ allowed: [String]) throws -> [String: Any] {
        guard let object = value as? [String: Any], Set(object.keys).isSubset(of: Set(allowed)) else { throw PetError(Self.label + "包含未知字段或无效对象，原记录已保留") }
        return object
    }
    private func decodeWindow(_ data: Data) throws -> Window {
        let object = try keys(JSONSerialization.jsonObject(with: data), ["version", "id", "number", "taskID", "frame", "tasks", "floating", "closed"])
        func frame(_ value: Any?) throws { if let value, !(value is NSNull) { _ = try keys(value, ["x", "y", "width", "height"]) } }
        func tab(_ value: Any) throws { _ = try keys(value, ["id", "root", "title"]) }
        try frame(object["frame"])
        for value in object["tasks"] as? [Any] ?? [] {
            let task = try keys(value, ["taskID", "tabs", "selected", "opened", "expanded"])
            try (task["tabs"] as? [Any] ?? []).forEach(tab)
        }
        for value in object["floating"] as? [Any] ?? [] {
            let page = try keys(value, ["taskID", "tab", "frame"])
            if let value = page["tab"] { try tab(value) }; try frame(page["frame"])
        }
        let value = try JSONDecoder().decode(Window.self, from: data); try validate(value); return value
    }
    private func decodePage(_ data: Data) throws -> Page {
        let object = try keys(JSONSerialization.jsonObject(with: data), ["version", "taskID", "kind", "state", "dirty", "asset"])
        if let asset = object["asset"], !(asset is NSNull) { _ = try keys(asset, ["slot", "hash"]) }
        let value = try JSONDecoder().decode(Page.self, from: data); try validate(value); return value
    }
    func list() throws -> Listing {
        let files = try files(), root = try literal(files, "workspace-recovery")
        let metadata = try files.entryMetadata(root)
        if metadata.kind == "missing" { return Listing() }
        guard metadata.kind == "directory" else { throw PetError(Self.label + "目录不可用") }
        var result = Listing()
        for id in try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() where Self.uuid(id) {
            do { if let window = try loadWindow(id) { result.windows.append(window) } }
            catch { result.issues.append(id + "：" + error.localizedDescription) }
        }
        return result
    }
    func loadWindow(_ id: String) throws -> Saved<Window>? {
        let files = try files(), path = try prefix(id) + "/layout.json", url = try literal(files, path)
        let metadata = try files.entryMetadata(url)
        if metadata.kind == "missing" { return nil }
        guard metadata.kind == "file" else { throw PetError(Self.label + "不是普通文件") }
        let data = try files.readData(url, maximum: Self.maximumState), value = try decodeWindow(data)
        guard value.id == id else { throw PetError("工作区窗口编号与保存位置不符") }
        return Saved(value: value, hash: AgentFiles.hash(data))
    }
    @discardableResult func saveWindow(_ value: Window, expected: String?) throws -> Saved<Window> {
        try validate(value); let data = try encoded(value)
        return try locked(value.id) { files in
            let path = try prefix(value.id) + "/layout.json"
            let change = try AgentKnowledgeFileWrite(files: files, path: path, data: data, expectedHash: expected ?? AgentFiles.hash(Data()), missing: expected == nil, permissions: 0o600, label: Self.label)
            if let before = change.before { guard try decodeWindow(before).id == value.id else { throw PetError("工作区窗口编号已变化") } }
            try change.requireCurrent(); try files.writeData(data, to: change.url, permissions: 0o600, expectedTarget: change.signature)
            return Saved(value: value, hash: AgentFiles.hash(data))
        }
    }
    // Tab chrome needs only metadata. It must not hash a large Office asset or
    // construct an editor merely to retain the last known unsaved marker.
    func loadTabDirtyState(windowID: String, pageID: String, taskID: String) throws -> Bool? {
        let files = try files(), url = try literal(files, pagePath(windowID, pageID) + ".json")
        if try files.entryMetadata(url).kind == "missing" { return nil }
        let value = try decodePage(files.readData(url, maximum: Self.maximumState))
        guard value.taskID == taskID else { throw PetError("恢复草稿不属于当前任务") }
        return value.dirty
    }
    func loadPage(windowID: String, pageID: String, taskID: String) throws -> LoadedPage? {
        let files = try files(), path = try pagePath(windowID, pageID) + ".json", url = try literal(files, path)
        if try files.entryMetadata(url).kind == "missing" { return nil }
        return try locked(windowID) { files in
            let data = try files.readData(url, maximum: Self.maximumState), value = try decodePage(data)
            guard value.taskID == taskID else { throw PetError("恢复草稿不属于当前任务") }
            var asset: URL?
            if let stored = value.asset {
                let file = try literal(files, pagePath(windowID, pageID) + ".\(stored.slot).data")
                guard try files.fileHash(file, maximum: AgentOffice.maximum) == stored.hash else { throw PetError("工作区恢复附件校验失败，原记录已保留") }
                asset = file
            }
            return LoadedPage(saved: Saved(value: value, hash: AgentFiles.hash(data)), asset: asset)
        }
    }
    @discardableResult func savePage(_ value: Page, asset: URL?, windowID: String, pageID: String, expected: String?) throws -> Saved<Page> {
        try validate(value)
        guard value.asset == nil || (asset == nil && value.kind == "office") else { throw PetError("恢复附件必须由保存入口生成") }
        _ = try encoded(value)
        return try locked(windowID) { files in
            let path = try pagePath(windowID, pageID), url = try literal(files, path + ".json")
            let entry = try files.entryMetadata(url)
            let before = entry.kind == "missing" ? nil : try files.readData(url, maximum: Self.maximumState)
            let probe = try AgentKnowledgeFileWrite(files: files, path: path + ".json", data: before ?? Data(), expectedHash: expected ?? AgentFiles.hash(Data()), missing: expected == nil, permissions: 0o600, label: Self.label)
            let previous = try before.map(decodePage)
            if let previous { guard previous.taskID == value.taskID, previous.kind == value.kind else { throw PetError("恢复草稿所属任务或编辑器已变化") } }
            var saved = value
            if let retained = value.asset {
                guard value.dirty, previous?.dirty == true, previous?.asset == retained,
                      var oldState = try previous.map({ try JSONSerialization.jsonObject(with: $0.state) as? [String: Any] }) ?? nil,
                      var newState = try JSONSerialization.jsonObject(with: value.state) as? [String: Any] else { throw PetError("办公恢复附件已变化，原草稿已保留") }
                oldState.removeValue(forKey: "view"); newState.removeValue(forKey: "view")
                guard NSDictionary(dictionary: oldState).isEqual(to: newState) else { throw PetError("位置更新不能替换办公正文或来源") }
                let retainedURL = try literal(files, path + ".\(retained.slot).data"), metadata = try files.entryMetadata(retainedURL)
                guard metadata.kind == "file", metadata.permissions == 0o600,
                      try files.fileHash(retainedURL, maximum: AgentOffice.maximum) == retained.hash,
                      try files.entryMetadata(retainedURL).signature == metadata.signature else { throw PetError("办公恢复正文不可用，原记录已保留") }
            }
            // Write the inactive asset first. The previous JSON continues to
            // reference its intact slot if copying or the final write fails.
            if let asset {
                let slot = previous?.asset?.slot == 0 ? 1 : 0
                let target = try literal(files, path + ".\(slot).data"), metadata = try files.entryMetadata(target)
                guard ["file", "missing"].contains(metadata.kind), metadata.kind == "missing" || (metadata.permissions ?? 0) & 0o222 != 0 else { throw PetError("工作区恢复附件只读或不是普通文件") }
                let source = try AgentFiles(workspace: asset.deletingLastPathComponent().path)
                let hash = try files.copyFile(asset, from: source, to: target, permissions: 0o600, expectedTarget: metadata.signature, maximum: AgentOffice.maximum)
                saved.asset = Asset(slot: slot, hash: hash)
            }
            let data = try encoded(saved); try probe.requireCurrent()
            try files.writeData(data, to: url, permissions: 0o600, expectedTarget: probe.signature)
            return Saved(value: saved, hash: AgentFiles.hash(data))
        }
    }
}
