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
            checks["legacyLayoutHasNoAppearanceSidecar"] = try journal.loadTerminalAppearance(windowID: windowID) == nil
            let follow = AgentTerminalAppearanceRecord(windowID: windowID, preference: .application, fallbackDark: true)
            let savedAppearance = try journal.saveTerminalAppearance(follow, expected: nil)
            let appearanceFile = try files.literalURL("workspace-recovery/" + windowID + "/terminal-appearance.json")
            let appearanceBytes = try Data(contentsOf: appearanceFile)
            checks["followPreferenceRoundTripsPrivately"] = try journal.loadTerminalAppearance(windowID: windowID)?.value == follow
                && files.entryMetadata(appearanceFile).permissions == 0o600
            checks["followPreferenceKeepsLegacyTerminalFormatAndBytes"] = try Data(contentsOf: file) == original
                && journal.loadTerminalLayout(windowID: windowID)?.hash == saved.hash
            checks["matchingFallbackRestoresFollowPreference"] = follow.preference(forLegacyDark: true) == .application
            checks["changedColorFromOlderVersionOverridesTheStalePreference"] = follow.preference(forLegacyDark: false) == .light
            var invalidAppearance = follow
            invalidAppearance.preference = .light
            rejected("inconsistentExplicitAppearanceCannotBeSaved") {
                _ = try journal.saveTerminalAppearance(invalidAppearance, expected: savedAppearance.hash)
            }
            rejected("staleAppearanceWriterCannotOverwritePreference") {
                _ = try journal.saveTerminalAppearance(follow, expected: AgentFiles.hash(Data()))
            }
            checks["failedAppearanceWritesRetainBothOriginalRecords"] = try Data(contentsOf: file) == original
                && Data(contentsOf: appearanceFile) == appearanceBytes
            let explicit = AgentTerminalAppearanceRecord(windowID: windowID, preference: .dark, fallbackDark: true)
            _ = try journal.saveTerminalAppearance(explicit, expected: savedAppearance.hash)
            checks["explicitPreferenceCanReplaceFollowAtTheSameColor"] = try journal.loadTerminalAppearance(windowID: windowID)?.value == explicit
                && Data(contentsOf: file) == original

            let defaults = AgentTerminalAppearanceDefaults(directory: store.directory)
            let stale = AgentTerminalAppearanceDefaults(directory: store.directory)
            let defaultsFile = try files.literalURL(AgentTerminalAppearanceDefaults.filename)
            checks["noDefaultConfigurationStillFollowsApplication"] = defaults.appearance == .application && defaults.error == nil
                && !FileManager.default.fileExists(atPath: defaultsFile.path)
            try defaults.save(.dark)
            let defaultBytes = try Data(contentsOf: defaultsFile)
            checks["defaultAppearanceRoundTripsPrivately"] = try AgentTerminalAppearanceDefaults(directory: store.directory).appearance == .dark
                && files.entryMetadata(defaultsFile).permissions == 0o600
            checks["changingDefaultLeavesExistingWindowRecordsIntact"] = try Data(contentsOf: file) == original
                && journal.loadTerminalAppearance(windowID: windowID)?.value == explicit
            rejected("staleDefaultCannotOverwriteAnotherWindow") { try stale.save(.light) }
            checks["staleDefaultWriteKeepsSavedSetting"] = try stale.appearance == .application && Data(contentsOf: defaultsFile) == defaultBytes
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: defaultsFile.path)
            rejected("readOnlyDefaultCannotBeOverwritten") { try defaults.save(.light) }
            checks["readOnlyDefaultKeepsLastChoiceAndBytes"] = try defaults.appearance == .dark && Data(contentsOf: defaultsFile) == defaultBytes
            let invalidDefault = Data(#"{"version":2,"appearance":"light"}"#.utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: defaultsFile.path)
            try files.writeData(invalidDefault, to: defaultsFile, permissions: 0o600)
            defaults.reload()
            checks["unsupportedDefaultKeepsLastGoodChoice"] = try defaults.error != nil && defaults.appearance == .dark
                && Data(contentsOf: defaultsFile) == invalidDefault

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
        var report: [String: Any] = ["checks": checks, "success": failure == nil && checks.count == 31 && checks.values.allSatisfy { $0 },
                                     "modelRequests": 0, "pid": getpid()]
        report["error"] = failure
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("terminal-storage-report.json"), options: .atomic)
    }
}
