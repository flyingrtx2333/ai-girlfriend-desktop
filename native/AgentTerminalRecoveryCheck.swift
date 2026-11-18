import Foundation
import Darwin

@MainActor extension AppDelegate {
    func runTerminalRecoveryStorageCheck(_ output: URL) {
        var checks: [String: Bool] = [:], failure: String?
        func rejected(_ name: String, _ operation: () throws -> Void) {
            do { try operation(); checks[name] = false }
            catch { checks[name] = true }
        }
        do {
            guard checkDirectory != nil, !CommandLine.arguments.contains("--live-agent") else { throw PetError("终端记录仅供独立验收") }
            let journal = AgentWorkspaceRecovery(profile: store.directory), windowID = UUID().uuidString, taskID = UUID().uuidString
            let window = AgentWorkspaceRecovery.Window(id: windowID, number: 1, taskID: taskID, frame: nil, tasks: [])
            let prior = try journal.saveWindow(window, expected: nil)
            checks["oldWindowLoadsWithoutTerminalRecord"] = try journal.loadTerminalLayout(windowID: windowID) == nil && journal.loadWindow(windowID)?.value == window
            let first = AgentTerminalLayout.Pane(number: 1, directory: output.path)
            let second = AgentTerminalLayout.Pane(number: 2, directory: output.appendingPathComponent("公开目录").path, exitCode: 7)
            let tab = AgentTerminalLayout.Tab(number: 1, active: second.id,
                root: .branch(vertical: true, fraction: 0.61, first: .pane(first), second: .pane(second)))
            let task = AgentTerminalLayout.Task(id: taskID, workspace: nil, scope: nil, directory: output.path, shown: true, index: 0, tabs: [tab])
            var layout = AgentTerminalLayout(windowID: windowID, dark: true, height: 226, nextNumber: 3, tasks: [task])
            let saved = try journal.saveTerminalLayout(layout, expected: nil)
            let files = try AgentFiles(workspace: store.directory.path)
            let path = "workspace-recovery/" + windowID + "/terminal.json"
            let file = try files.literalURL(path)
            let original = try Data(contentsOf: file)
            checks["exactSplitLayoutAndDirectoryRoundTrip"] = try journal.loadTerminalLayout(windowID: windowID)?.value == layout
            checks["sidecarIsPrivate"] = try files.entryMetadata(file).permissions == 0o600
            checks["windowLayoutMaintainsOldFormatAndBytes"] = try journal.loadWindow(windowID)?.hash == prior.hash
            checks["onlyTerminalMetadataIsStored"] = try JSONSerialization.jsonObject(with: original) is [String: Any]
                && !String(decoding: original, as: UTF8.self).contains("pid") && !String(decoding: original, as: UTF8.self).contains("transcript")
            var invalid = layout; invalid.tasks[0].tabs[0].active = UUID()
            rejected("unknownActivePaneIsRejected") { _ = try journal.saveTerminalLayout(invalid, expected: saved.hash) }
            invalid = layout; invalid.tasks[0].tabs[0].root = .branch(vertical: false, fraction: 0.5, first: .pane(first), second: .pane(first))
            rejected("duplicatePaneCannotOverwriteRecord") { _ = try journal.saveTerminalLayout(invalid, expected: saved.hash) }
            invalid = layout; invalid.tasks[0].directory = "unscoped-relative-directory"
            rejected("relativeDirectoryIsRejected") { _ = try journal.saveTerminalLayout(invalid, expected: saved.hash) }
            rejected("staleWriterCannotOverwriteCurrentRecord") { _ = try journal.saveTerminalLayout(layout, expected: AgentFiles.hash(Data())) }
            checks["failedWritesKeepPrivateBytes"] = try Data(contentsOf: file) == original && files.entryMetadata(file).permissions == 0o600
            layout.tasks = []
            _ = try journal.saveTerminalLayout(layout, expected: saved.hash)
            checks["explicitClosureLeavesNoPaneToRestore"] = try journal.loadTerminalLayout(windowID: windowID)?.value.tasks.isEmpty == true
            let wrongWindow = UUID().uuidString
            let other = try files.literalURL("workspace-recovery/" + wrongWindow + "/terminal.json")
            try files.writeData(original, to: other, permissions: 0o600)
            rejected("terminalRecordCannotBeLoadedByAnotherWindow") { _ = try journal.loadTerminalLayout(windowID: wrongWindow) }
            checks["wrongOwnerRecordRemainsIntact"] = try Data(contentsOf: other) == original
            let cwd = try AgentFiles(workspace: FileManager.default.currentDirectoryPath).root.path
            checks["kernelReadsActualWorkingDirectory"] = AgentTerminalLayout.directory(of: getpid()) == cwd
        } catch { failure = error.localizedDescription }
        var report: [String: Any] = ["checks": checks, "success": failure == nil && checks.count == 14 && checks.values.allSatisfy { $0 },
                                     "modelRequests": 0, "pid": getpid()]
        report["error"] = failure
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("terminal-storage-report.json"), options: .atomic)
    }
}
