import Foundation
import Darwin

enum AgentTerminalAppearance: String, Codable, CaseIterable, Sendable {
    case application, light, dark

    init(dark: Bool) { self = dark ? .dark : .light }

    var fixedDark: Bool? {
        switch self {
        case .application: return nil
        case .light: return false
        case .dark: return true
        }
    }

    var title: String {
        switch self {
        case .application: return "跟随应用"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

@MainActor final class AgentTerminalAppearanceDefaults {
    private struct Settings: Codable {
        var version = 1
        let appearance: AgentTerminalAppearance
    }

    static let changed = Notification.Name("BlueFatFishTerminalAppearanceDefaultsChanged")
    static let filename = "terminal-default-appearance.json"
    private let directory: URL
    private var revision: String?
    private(set) var appearance = AgentTerminalAppearance.application
    private(set) var error: String?

    init(directory: URL) {
        self.directory = directory
        reload()
    }

    func reload() {
        defer { publish() }
        do {
            let files = try AgentFiles(workspace: directory.path), file = try files.literalURL(Self.filename)
            let metadata = try files.entryMetadata(file)
            guard try files.resolve(Self.filename) == file, ["missing", "file"].contains(metadata.kind) else {
                throw PetError("终端外观配置必须是普通文件")
            }
            if metadata.kind == "missing" {
                appearance = .application
                revision = nil
            } else {
                let data = try files.readData(file, maximum: 4096)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == ["version", "appearance"],
                      let value = try? JSONDecoder().decode(Settings.self, from: data), value.version == 1 else {
                    throw PetError("终端外观配置版本或选项无效")
                }
                appearance = value.appearance
                revision = AgentFiles.hash(data)
            }
            error = nil
        } catch {
            self.error = "终端外观未载入：" + error.localizedDescription
        }
    }

    func save(_ value: AgentTerminalAppearance) throws {
        if let error { throw PetError(error) }
        guard value != appearance else { return }
        let files = try AgentFiles(workspace: directory.path), file = try files.literalURL(Self.filename)
        let metadata = try files.entryMetadata(file)
        guard metadata.kind == "missing" || metadata.kind == "file" && (metadata.permissions ?? 0) & 0o222 != 0 else {
            throw PetError("终端外观配置只读或不可写，未保存")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Settings(appearance: value))
        let write = try AgentKnowledgeFileWrite(files: files, path: Self.filename, data: data, expectedHash: revision,
            missing: revision == nil, permissions: 0o600, label: "终端外观配置")
        try write.requireCurrent()
        try files.writeData(data, to: write.url, permissions: 0o600, expectedTarget: write.signature)
        appearance = value
        revision = AgentFiles.hash(data)
        publish()
    }

    private func publish() { NotificationCenter.default.post(name: Self.changed, object: self) }
}

struct AgentTerminalAppearanceRecord: Codable, Equatable, Sendable {
    var version = 1
    var windowID: String
    var preference: AgentTerminalAppearance
    var fallbackDark: Bool

    func preference(forLegacyDark dark: Bool) -> AgentTerminalAppearance {
        fallbackDark == dark ? preference : AgentTerminalAppearance(dark: dark)
    }

    func validate(windowID expected: String) throws {
        guard version == 1, windowID == expected, UUID(uuidString: windowID)?.uuidString == windowID,
              preference.fixedDark.map({ $0 == fallbackDark }) ?? true else {
            throw PetError("终端外观记录格式无效，原记录已保留")
        }
    }
}

struct AgentTerminalLayout: Codable, Equatable, Sendable {
    struct Pane: Codable, Equatable, Sendable {
        var id = UUID()
        var number: Int
        var directory: String
        var exitCode: Int32?
    }
    indirect enum Split: Codable, Equatable, Sendable {
        case pane(Pane)
        case branch(vertical: Bool, fraction: Double, first: Split, second: Split)
    }
    struct Tab: Codable, Equatable, Sendable {
        var number: Int
        var active: UUID
        var root: Split
    }
    struct Task: Codable, Equatable, Sendable {
        var id: String
        var workspace: String?
        var scope: AgentWorkspaceScope?
        var directory: String
        var shown: Bool
        var index: Int
        var tabs: [Tab]
    }

    static let maximumPanes = 8
    static let maximumBytes = 2_000_000
    var version = 1
    var windowID: String
    var dark: Bool
    var height: Double?
    var nextNumber: Int
    var tasks: [Task]

    static func validPath(_ path: String) -> Bool { path.hasPrefix("/") && path.utf8.count < 8192 && !path.contains("\0") }
    func validate(windowID expected: String) throws {
        let invalid = PetError("终端恢复格式无效，原记录已保留")
        guard version == 1, windowID == expected, UUID(uuidString: windowID)?.uuidString == windowID,
              (1..<Int.max).contains(nextNumber), tasks.count <= Self.maximumPanes,
              height.map({ $0.isFinite && $0 > 0 && $0 <= 16_384 }) ?? true,
              Set(tasks.map(\.id)).count == tasks.count else { throw invalid }
        var seenIDs = Set<UUID>(), seenNumbers = Set<Int>(), seenTabs = Set<Int>()
        func check(_ node: Split, depth: Int, panes: inout Set<UUID>) throws {
            guard depth < Self.maximumPanes, seenIDs.count < Self.maximumPanes else { throw invalid }
            switch node {
            case .pane(let pane):
                guard Self.validPath(pane.directory), (1..<nextNumber).contains(pane.number),
                      seenIDs.insert(pane.id).inserted, seenNumbers.insert(pane.number).inserted else { throw invalid }
                panes.insert(pane.id)
            case .branch(_, let fraction, let first, let second):
                guard fraction.isFinite, (0...1).contains(fraction) else { throw invalid }
                try check(first, depth: depth + 1, panes: &panes); try check(second, depth: depth + 1, panes: &panes)
            }
        }
        for task in tasks {
            guard UUID(uuidString: task.id) != nil, Self.validPath(task.directory),
                  task.workspace.map(Self.validPath) ?? true, task.tabs.indices.contains(task.index),
                  task.tabs.count <= Self.maximumPanes else { throw invalid }
            if let scope = task.scope {
                guard scope.primary == task.workspace, Self.validPath(scope.group), (1...16).contains(scope.folders.count),
                      scope.folders.contains(scope.primary), scope.folders.allSatisfy(Self.validPath) else { throw invalid }
            }
            for tab in task.tabs {
                guard (1..<nextNumber).contains(tab.number), seenTabs.insert(tab.number).inserted else { throw invalid }
                var panes = Set<UUID>()
                try check(tab.root, depth: 0, panes: &panes)
                guard panes.contains(tab.active) else { throw invalid }
            }
        }
    }

    static func directory(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { bytes in
            guard let terminator = bytes.firstIndex(of: 0), let path = String(bytes: bytes[..<terminator], encoding: .utf8),
                  Self.validPath(path) else { return nil }
            return path
        }
    }
}
