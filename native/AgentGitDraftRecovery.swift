import Foundation

struct AgentGitDraftRecovery: Codable {
    struct Scope: Codable, Equatable {
        struct Checkout: Codable, Equatable {
            var directory: String, identity: String, head: String
        }
        var workspace: String, identity: String
        var checkout: Checkout?

        private static func identity(of directory: URL) throws -> String {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            let volume = (try? directory.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) ?? (attributes[.systemNumber] as? NSNumber)?.stringValue
            guard let volume, let inode = attributes[.systemFileNumber] as? NSNumber else { throw PetError("无法确认 Git 草稿的原目录") }
            return volume + ":" + inode.stringValue
        }

        static func current(_ task: AgentTaskRecord?) throws -> Scope {
            guard let task else { throw PetError("Git 草稿所属任务不可用") }
            let files = try AgentFiles(workspace: task.workspace)
            var value = Scope(workspace: files.root.path, identity: try identity(of: files.root), checkout: nil)
            guard try files.entryMetadata(files.literalURL(".git")).kind != "missing" else { return value }
            let shared = try AgentGit.metadata(workspace: files.root.path)
            guard shared.path.hasPrefix(files.root.path + "/") || shared == files.root || shared.path == task.gitDirectory else {
                throw PetError("请在原任务中连接 Git 仓库后重试")
            }
            let metadata = try AgentFiles(workspace: AgentGit.metadata(workspace: files.root.path, checkout: true).path)
            let headURL = try metadata.literalURL("HEAD")
            let head: String
            if try metadata.entryMetadata(headURL).kind == "link" {
                head = "ref: " + (try FileManager.default.destinationOfSymbolicLink(atPath: headURL.path))
            } else {
                head = String(decoding: try metadata.readData(headURL, maximum: 8192), as: UTF8.self).trimmingCharacters(in: .newlines)
            }
            value.checkout = Checkout(directory: metadata.root.path, identity: try identity(of: metadata.root), head: head)
            guard value.valid else { throw PetError("无法确认 Git 草稿的原分支") }
            return value
        }

        func matches(_ current: Scope?) -> Bool {
            guard let current else { return false }
            return workspace == current.workspace && identity == current.identity && (checkout == nil || checkout == current.checkout)
        }

        func requireCurrent(_ task: AgentTaskRecord?, preserving detail: String = "原说明已保留") throws {
            guard matches(try? Self.current(task)) else { throw PetError("请回到 Git 草稿的原项目、仓库和分支后重试，" + detail) }
        }

        fileprivate var valid: Bool {
            func path(_ value: String) -> Bool { value.hasPrefix("/") && value.utf8.count < 8192 && !value.contains("\0") }
            func validIdentity(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 128 && !value.contains("\0") }
            guard path(workspace), validIdentity(identity) else { return false }
            guard let checkout else { return true }
            let head = checkout.head
            let symbolic = head.hasPrefix("ref: refs/") && head.utf8.count < 8192 && !head.dropFirst(5).utf8.contains { $0 <= 32 || $0 == 127 }
            let detached = [40, 64].contains(head.count) && head.allSatisfy { $0.isASCII && $0.isHexDigit }
            return path(checkout.directory) && validIdentity(checkout.identity) && (symbolic || detached)
        }
    }

    struct Push: Codable {
        var scope: Scope
        var branch: String
        var upstream: Bool
        var remote: String?
        var addressHash: String?
        var selection: AgentTextViewport.Selection?
        var focused = false
        var opened = true

        func requireCurrent(_ task: AgentTaskRecord?) throws {
            try scope.requireCurrent(task, preserving: "推送草稿已保留")
        }
    }

    var version = 1
    var scope: Scope?
    var message: String
    var selection: AgentTextViewport.Selection?
    var focused: Bool
    var source: AgentGitSource
    var revision: String
    var paths: [String]
    var push: Push? = nil

    static func decode(_ page: AgentWorkspaceRecovery.Page) throws -> Self {
        let unsupported = PetError("Git 草稿恢复格式不受支持，原记录已保留")
        guard page.version == 1, page.kind == "git-draft", page.asset == nil, UUID(uuidString: page.taskID) != nil,
              let raw = try JSONSerialization.jsonObject(with: page.state) as? [String: Any],
              Set(raw.keys).isSubset(of: ["version", "scope", "message", "selection", "focused", "source", "revision", "paths", "push"]) else { throw unsupported }
        let push = raw["push"] as? [String: Any]
        if let push, !Set(push.keys).isSubset(of: ["scope", "branch", "upstream", "remote", "addressHash", "selection", "focused", "opened"]) { throw unsupported }
        for object in [raw, push ?? [:]] {
            if let scope = object["scope"] as? [String: Any] {
                guard Set(scope.keys).isSubset(of: ["workspace", "identity", "checkout"]) else { throw unsupported }
                if let checkout = scope["checkout"] as? [String: Any], !Set(checkout.keys).isSubset(of: ["directory", "identity", "head"]) { throw unsupported }
            }
            if let selection = object["selection"] as? [String: Any], !Set(selection.keys).isSubset(of: ["location", "length"]) { throw unsupported }
        }
        let value = try JSONDecoder().decode(Self.self, from: page.state)
        guard value.version == 1, page.dirty == (!value.message.isEmpty || value.push != nil), value.message.isEmpty == (value.scope == nil), value.scope?.valid != false,
              value.selection?.valid(in: value.message.utf16.count) != false,
              value.paths.count <= 100_000, Set(value.paths).count == value.paths.count,
              value.paths.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("/") && $0.utf8.count < 8192 && !$0.contains("\0") }) else { throw unsupported }
        if let push = value.push {
            guard push.scope.checkout != nil, push.scope.valid, push.selection?.valid(in: push.branch.utf16.count) != false,
                  push.remote.map({ !$0.isEmpty && $0.utf8.count <= 200 && $0.rangeOfCharacter(from: .controlCharacters) == nil }) != false,
                  push.addressHash.map({ push.remote != nil && $0.utf8.count == 64 && $0.allSatisfy { $0.isASCII && $0.isHexDigit } }) != false else { throw unsupported }
        }
        return value
    }
}
