import Foundation

struct AgentGitDraftRecovery: Codable {
    struct Scope: Codable, Equatable, Sendable {
        struct Checkout: Codable, Equatable, Sendable {
            var directory: String, identity: String, head: String
        }
        var workspace: String, identity: String
        var checkout: Checkout?

        static func current(_ task: AgentTaskRecord?) throws -> Scope {
            guard let task else { throw PetError("Git 草稿所属任务不可用") }
            let files = try AgentFiles(workspace: task.workspace)
            var value = Scope(workspace: files.root.path, identity: try AgentFiles.directoryIdentity(files.root), checkout: nil)
            guard try files.entryMetadata(files.literalURL(".git")).kind != "missing" else { return value }
            let shared = try AgentGit.metadata(workspace: files.root.path)
            guard shared.path.hasPrefix(files.root.path + "/") || shared == files.root || shared.path == task.gitDirectory else {
                throw PetError("请在原任务中连接 Git 仓库后重试")
            }
            value.checkout = try currentCheckout(workspace: files.root.path)
            guard value.valid else { throw PetError("无法确认 Git 草稿的原分支") }
            return value
        }

        fileprivate static func currentCheckout(workspace: String) throws -> Checkout {
            let metadata = try AgentFiles(workspace: AgentGit.metadata(workspace: workspace, checkout: true).path)
            let headURL = try metadata.literalURL("HEAD")
            let head: String
            if try metadata.entryMetadata(headURL).kind == "link" {
                head = "ref: " + (try FileManager.default.destinationOfSymbolicLink(atPath: headURL.path))
            } else {
                head = String(decoding: try metadata.readData(headURL, maximum: 8192), as: UTF8.self).trimmingCharacters(in: .newlines)
            }
            return Checkout(directory: metadata.root.path, identity: try AgentFiles.directoryIdentity(metadata.root), head: head)
        }

        func matches(_ current: Scope?) -> Bool {
            guard let current else { return false }
            return workspace == current.workspace && identity == current.identity && (checkout == nil || checkout == current.checkout)
        }

        func requireCurrent(_ task: AgentTaskRecord?, preserving detail: String = "原说明已保留") throws {
            guard matches(try? Self.current(task)) else { throw PetError("请回到 Git 草稿的原项目、仓库和分支后重试，" + detail) }
        }

        fileprivate static func validPath(_ value: String) -> Bool { value.hasPrefix("/") && value.utf8.count < 8192 && !value.contains("\0") }
        fileprivate static func validIdentity(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 128 && !value.contains("\0") }

        fileprivate var valid: Bool {
            guard Self.validPath(workspace), Self.validIdentity(identity) else { return false }
            guard let checkout else { return true }
            let head = checkout.head
            let symbolic = head.hasPrefix("ref: refs/") && head.utf8.count < 8192 && !head.dropFirst(5).utf8.contains { $0 <= 32 || $0 == 127 }
            let detached = [40, 64].contains(head.count) && head.allSatisfy { $0.isASCII && $0.isHexDigit }
            return Self.validPath(checkout.directory) && Self.validIdentity(checkout.identity) && (symbolic || detached)
        }
    }

    struct Reading: Codable, Equatable, Sendable {
        var version = 1
        var scope: Scope
        var source: AgentGitSource
        var revision: String
        var paths: [String]
        var split: Bool
        var wraps: Bool
        var ignoresWhitespace: Bool
        var fileList: Bool?
        var patchHash: String?
        var unified: AgentTextViewport?
        var sideBySide: AgentGitDiffView.SplitPosition?
        var splitHorizontal: [Double]?

        func page(taskID: String) throws -> AgentWorkspaceRecovery.Page {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            return AgentWorkspaceRecovery.Page(taskID: taskID, kind: "git-reading", state: try encoder.encode(self), dirty: false, asset: nil)
        }

        static func decode(_ page: AgentWorkspaceRecovery.Page) throws -> Self {
            let failure = PetError("Git 审阅位置格式无效，原记录已保留")
            guard page.kind == "git-reading", !page.dirty, page.asset == nil,
                  let raw = try JSONSerialization.jsonObject(with: page.state) as? [String: Any],
                  Set(raw.keys).isSubset(of: ["version", "scope", "source", "revision", "paths", "split", "wraps", "ignoresWhitespace", "fileList", "patchHash", "unified", "sideBySide", "splitHorizontal"]),
                  let scope = raw["scope"] as? [String: Any], Set(scope.keys).isSubset(of: ["workspace", "identity", "checkout"]),
                  let checkout = scope["checkout"] as? [String: Any], Set(checkout.keys).isSubset(of: ["directory", "identity", "head"]) else { throw failure }
            if let unified = raw["unified"] { try AgentTextViewport.validateObject(unified) }
            if let split = raw["sideBySide"] as? [String: Any], !Set(split.keys).isSubset(of: ["row", "fraction"]) { throw failure }
            let value = try JSONDecoder().decode(Self.self, from: page.state)
            guard value.version == 1, value.scope.valid, value.revision.utf8.count <= 512, !value.revision.contains("\0"),
                  value.paths.count <= 100_000, Set(value.paths).count == value.paths.count,
                  value.paths.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("/") && $0.utf8.count < 8192 && !$0.contains("\0") }),
                  value.patchHash.map({ !value.paths.isEmpty && $0.utf8.count == 64 && $0.allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase } }) != false,
                  value.unified.map({ !value.split && value.patchHash != nil && $0.valid }) != false,
                  value.sideBySide.map({ value.split && value.patchHash != nil && $0.valid }) != false,
                  value.splitHorizontal.map({ value.sideBySide != nil && $0.count == 2 && $0.allSatisfy { $0.isFinite && (0...1_000_000_000).contains($0) } }) != false else { throw failure }
            return value
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

    struct RemoteForm: Codable {
        enum Field: String, Codable { case name, address }
        var scope: Scope
        var name: String, address: String
        var focus: Field
        var nameSelection: AgentTextViewport.Selection?, addressSelection: AgentTextViewport.Selection?

        static func canPreserve(name: String, address: String) -> Bool {
            guard name.utf8.count <= 65_536, address.utf8.count <= 65_536,
                  !name.contains("\0"), !address.contains("\0") else { return false }
            let nameValue = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let nameLooksLikeURL = nameValue.contains("://") || nameValue.removingPercentEncoding?.contains("://") == true
            return (!nameLooksLikeURL || canPreserveAddress(nameValue)) && canPreserveAddress(address.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        private static func canPreserveAddress(_ value: String) -> Bool {
            let decoded = value.removingPercentEncoding ?? value
            if value.contains("://") || decoded.contains("://") {
                let url = value.contains("://") ? value : decoded
                guard let endpoint = URLComponents(string: url), let scheme = endpoint.scheme?.lowercased(),
                      endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil else { return false }
                if let host = endpoint.host, host.contains("@") || (host.contains(":") && !host.hasPrefix("[")) { return false }
                if let user = endpoint.user {
                    return scheme == "ssh" && user.rangeOfCharacter(from: CharacterSet(charactersIn: ":@/?#\\").union(.whitespacesAndNewlines).union(.controlCharacters)) == nil
                }
                return true
            }
            if ["/", "./", "../", "~/"].contains(where: value.hasPrefix) { return true }
            guard !decoded.contains("?"), !decoded.contains("#"), !decoded.contains("::") else { return false }
            guard let colon = decoded.firstIndex(of: ":") else { return true }
            return !decoded[decoded.index(after: colon)...].prefix(while: { $0 != "/" }).contains("@")
        }

        func requireCurrent(_ task: AgentTaskRecord?) throws {
            try scope.requireCurrent(task, preserving: "添加远端草稿已保留")
        }
    }

    struct WorktreeForm: Codable {
        struct Source: Codable, Equatable {
            var root: String
            var scope: Scope
            var metadata: String, metadataIdentity: String

            static func current(_ root: String) throws -> Source {
                let files = try AgentFiles(workspace: root)
                let metadata = try AgentGit.metadata(workspace: files.root.path)
                let scope = Scope(workspace: files.root.path, identity: try AgentFiles.directoryIdentity(files.root),
                                  checkout: try Scope.currentCheckout(workspace: files.root.path))
                guard scope.valid else { throw PetError("无法确认工作树源的原分支") }
                return Source(root: root, scope: scope, metadata: metadata.path, metadataIdentity: try AgentFiles.directoryIdentity(metadata))
            }

            fileprivate var valid: Bool {
                Scope.validPath(root) && scope.checkout != nil && scope.valid && Scope.validPath(metadata) && Scope.validIdentity(metadataIdentity)
            }
        }

        var sourceTaskID: String, resumeTaskID: String?
        var sources: [Source]
        var branch: String, startPoints: [String: String], includeChanges: Bool
        var focus: String?, branchSelection: AgentTextViewport.Selection?, scroll: Double

        fileprivate func valid(for host: String) -> Bool {
            guard UUID(uuidString: sourceTaskID) != nil, host == sourceTaskID || host == resumeTaskID,
                  resumeTaskID.map({ UUID(uuidString: $0) != nil && $0 != sourceTaskID }) != false,
                  (1...16).contains(sources.count), sources.allSatisfy(\.valid),
                  branch.utf8.count <= 65_536, !branch.contains("\0"), branchSelection?.valid(in: branch.utf16.count) != false,
                  (0...10_000).contains(scroll) else { return false }
            let roots = Set(sources.map(\.root))
            return roots.count == sources.count && roots == Set(startPoints.keys) && startPoints.values.allSatisfy { ref in
                ref == "HEAD" || ((ref.hasPrefix("refs/heads/") || ref.hasPrefix("refs/remotes/")) &&
                    ref.utf8.count < 8192 && !ref.utf8.contains { $0 <= 32 || $0 == 127 })
            } && focus.map { $0 == "branch" || $0 == "include" || roots.contains($0) } != false
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
    var remoteForm: RemoteForm? = nil
    var worktreeForm: WorktreeForm? = nil
    var worktreeManager: AgentWorktreeManagerRecovery? = nil

    static func decode(_ page: AgentWorkspaceRecovery.Page) throws -> Self {
        let unsupported = PetError("Git 草稿恢复格式不受支持，原记录已保留")
        guard page.version == 1, page.kind == "git-draft", page.asset == nil, UUID(uuidString: page.taskID) != nil,
              let raw = try JSONSerialization.jsonObject(with: page.state) as? [String: Any],
              Set(raw.keys).isSubset(of: ["version", "scope", "message", "selection", "focused", "source", "revision", "paths", "push", "remoteForm", "worktreeForm", "worktreeManager"]) else { throw unsupported }
        let push = raw["push"] as? [String: Any]
        if let push, !Set(push.keys).isSubset(of: ["scope", "branch", "upstream", "remote", "addressHash", "selection", "focused", "opened"]) { throw unsupported }
        let remoteForm = raw["remoteForm"] as? [String: Any]
        if let remoteForm, !Set(remoteForm.keys).isSubset(of: ["scope", "name", "address", "focus", "nameSelection", "addressSelection"]) { throw unsupported }
        let worktreeForm = raw["worktreeForm"] as? [String: Any]
        var objects = [raw, push ?? [:], remoteForm ?? [:]]
        if let worktreeForm {
            guard Set(worktreeForm.keys).isSubset(of: ["sourceTaskID", "resumeTaskID", "sources", "branch", "startPoints", "includeChanges", "focus", "branchSelection", "scroll"]),
                  let sources = worktreeForm["sources"] as? [[String: Any]],
                  sources.allSatisfy({ Set($0.keys).isSubset(of: ["root", "scope", "metadata", "metadataIdentity"]) }) else { throw unsupported }
            objects.append(worktreeForm); objects.append(contentsOf: sources)
        }
        for object in objects {
            if let scope = object["scope"] as? [String: Any] {
                guard Set(scope.keys).isSubset(of: ["workspace", "identity", "checkout"]) else { throw unsupported }
                if let checkout = scope["checkout"] as? [String: Any], !Set(checkout.keys).isSubset(of: ["directory", "identity", "head"]) { throw unsupported }
            }
            for key in ["selection", "nameSelection", "addressSelection", "branchSelection"] {
                if let selection = object[key] as? [String: Any], !Set(selection.keys).isSubset(of: ["location", "length"]) { throw unsupported }
            }
        }
        let value = try JSONDecoder().decode(Self.self, from: page.state)
        guard value.version == 1, page.dirty == (!value.message.isEmpty || value.push != nil || value.remoteForm != nil || value.worktreeForm != nil),
              value.worktreeForm?.valid(for: page.taskID) != false, value.message.isEmpty == (value.scope == nil), value.scope?.valid != false,
              value.worktreeManager.map({ $0.valid && $0.source.taskID == page.taskID }) != false,
              value.selection?.valid(in: value.message.utf16.count) != false,
              value.paths.count <= 100_000, Set(value.paths).count == value.paths.count,
              value.paths.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("/") && $0.utf8.count < 8192 && !$0.contains("\0") }) else { throw unsupported }
        if let push = value.push {
            guard push.scope.checkout != nil, push.scope.valid, push.selection?.valid(in: push.branch.utf16.count) != false,
                  push.remote.map({ !$0.isEmpty && $0.utf8.count <= 200 && $0.rangeOfCharacter(from: .controlCharacters) == nil }) != false,
                  push.addressHash.map({ push.remote != nil && $0.utf8.count == 64 && $0.allSatisfy { $0.isASCII && $0.isHexDigit } }) != false else { throw unsupported }
        }
        if let remote = value.remoteForm {
            guard remote.scope.checkout != nil, remote.scope.valid, remote.name != "origin" || !remote.address.isEmpty,
                  RemoteForm.canPreserve(name: remote.name, address: remote.address),
                  remote.nameSelection?.valid(in: remote.name.utf16.count) != false,
                  remote.addressSelection?.valid(in: remote.address.utf16.count) != false,
                  value.push.map({ $0.opened && $0.scope == remote.scope }) != false,
                  value.scope.map({ $0.matches(remote.scope) }) != false else { throw unsupported }
        }
        return value
    }
}
