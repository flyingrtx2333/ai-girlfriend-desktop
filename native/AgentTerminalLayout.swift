import Foundation
import Darwin

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
