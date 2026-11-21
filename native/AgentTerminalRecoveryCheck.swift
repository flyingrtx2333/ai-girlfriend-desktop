import AppKit
import Darwin
import BlueFatFishTerminal

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
            let target = AgentTerminalLayout.Pane(number: second.number, directory: second.directory, sshDestination: "build@fixture.example")
            var remote = layout
            remote.tasks[0].tabs[0].active = target.id
            remote.tasks[0].tabs[0].root = .branch(vertical: true, fraction: 0.61, first: .pane(first), second: .pane(target))
            rejected("sshSessionCannotBeDisguisedAsLegacyLocalLayout") { _ = try journal.saveTerminalLayout(remote, expected: saved.hash) }
            remote.version = 2
            let remoteSaved = try journal.saveTerminalLayout(remote, expected: saved.hash)
            checks["mixedLocalAndSSHLayoutRoundTrips"] = try journal.loadTerminalLayout(windowID: windowID)?.value == remote &&
                files.entryMetadata(file).permissions == 0o600
            var unsafe = target; unsafe.sshDestination = "-oInvalid"
            var corrupt = remote
            corrupt.tasks[0].tabs[0].root = .branch(vertical: true, fraction: 0.61, first: .pane(first), second: .pane(unsafe))
            rejected("sshLayoutRejectsOptionLikeDestination") { _ = try journal.saveTerminalLayout(corrupt, expected: remoteSaved.hash) }
            checks["sshDestinationAcceptsAliasesAndAddresses"] = ["macmini", "build@fixture.example", "127.0.0.1", "build@::1"].allSatisfy(TerminalSurface.validSSHDestination)
            checks["sshDestinationRejectsExtraArgumentsAndCredentials"] = ["-F", "fixture -F file", "ssh://fixture", "build:secret@fixture", "a@b@c", "x\ny"].allSatisfy { !TerminalSurface.validSSHDestination($0) }
            var configured = target; configured.sshDirectory = "~/项目资料 '2026'"
            remote.tasks[0].tabs[0].root = .branch(vertical: true, fraction: 0.61, first: .pane(first), second: .pane(configured))
            rejected("sshDirectoryRequiresNewLayoutVersion") { _ = try journal.saveTerminalLayout(remote, expected: remoteSaved.hash) }
            remote.version = 3
            let configuredSaved = try journal.saveTerminalLayout(remote, expected: remoteSaved.hash)
            checks["configuredSSHDirectoryRoundTripsSeparatelyFromLocalDirectory"] = try journal.loadTerminalLayout(windowID: windowID)?.value == remote
            configured.sshDestination = nil
            corrupt = remote
            corrupt.tasks[0].tabs[0].root = .branch(vertical: true, fraction: 0.61, first: .pane(first), second: .pane(configured))
            rejected("localPaneCannotCarrySSHDirectory") { _ = try journal.saveTerminalLayout(corrupt, expected: configuredSaved.hash) }
            checks["sshDirectoryValidatesHomeAbsoluteUnicodeAndControlCharacters"] =
                ["~", "~/中文路径 '引号'", "/data/Shared Folder"].allSatisfy(TerminalSurface.validSSHDirectory) &&
                ["", "relative/path", "~another", "/bad\npath", "/bad\0path", "/bad\u{2028}path", "/" + String(repeating: "a", count: 4096)]
                    .allSatisfy { !TerminalSurface.validSSHDirectory($0) }
            layout.tasks = []
            _ = try journal.saveTerminalLayout(layout, expected: configuredSaved.hash)
            checks["explicitClosureLeavesNoPaneToRestore"] = try journal.loadTerminalLayout(windowID: windowID)?.value.tasks.isEmpty == true
            checks["afterClosingSSHLegacyLayoutIsStillReadable"] = try journal.loadTerminalLayout(windowID: windowID)?.value.version == 1
            let wrongWindow = UUID().uuidString
            let other = try files.literalURL("workspace-recovery/" + wrongWindow + "/terminal.json")
            try files.writeData(original, to: other, permissions: 0o600)
            rejected("terminalRecordCannotBeLoadedByAnotherWindow") { _ = try journal.loadTerminalLayout(windowID: wrongWindow) }
            checks["wrongOwnerRecordRemainsIntact"] = try Data(contentsOf: other) == original
            let cwd = try AgentFiles(workspace: FileManager.default.currentDirectoryPath).root.path
            checks["kernelReadsActualWorkingDirectory"] = AgentTerminalLayout.directory(of: getpid()) == cwd
        } catch { failure = error.localizedDescription }
        var report: [String: Any] = ["checks": checks, "success": failure == nil && checks.count == 41 && checks.values.allSatisfy { $0 },
                                     "modelRequests": 0, "pid": getpid()]
        report["error"] = failure
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("terminal-storage-report.json"), options: .atomic)
    }

    func runSSHTerminalDirectoryCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], failure: String?, requests = 0
        let phaseFile = output.appendingPathComponent("ssh-directory-phase.json")
        let reopened = FileManager.default.fileExists(atPath: phaseFile.path)
        let binary = Bundle.main.executableURL!
        var panel: AgentTerminalPanel?
        defer { panel?.suspendAll(); agentRuntime?.stopAll() }
        do {
            ensureAgent()
            guard let tasks = agentStore, let runtime = agentRuntime, let window = control.window,
                  let content = window.contentView else { throw PetError("终端窗口不可用") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("SSH 终端验收使用本机样例") }
            let samples = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: output.appendingPathComponent("ssh-directories.json")))
            guard let relative = samples["relative"], let absolute = samples["absolute"], let retryPath = samples["retry"],
                  let log = samples["sessions"], let home = samples["home"] else { throw PetError("SSH 目录样例不完整") }
            let alias = "whale-loopback"
            let reference = AgentWorkspaceRecovery(profile: store.directory)
            window.appearance = NSAppearance(named: reopened ? .aqua : .darkAqua)
            let size = reopened ? NSSize(width: 1320, height: 800) : NSSize(width: 780, height: 540)
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
            window.makeKeyAndOrderFront(nil)
            func find<T: NSView>(_ view: NSView, _ type: T.Type, matching: (T) -> Bool) -> T? {
                guard !view.isHiddenOrHasHiddenAncestor else { return nil }
                if let typed = view as? T, matching(typed) { return typed }
                for child in view.subviews {
                    if let match = find(child, type, matching: matching) { return match }
                }
                return nil
            }
            func button(_ view: NSView, _ name: String) throws -> NSButton {
                guard let value = find(view, NSButton.self, matching: { ($0.accessibilityLabel() == name || $0.title == name) && $0.isEnabled }) else {
                    throw PetError("缺少终端操作 " + name)
                }
                return value
            }
            func activate(_ id: String) throws -> AgentTerminalPanel {
                control.showAgentTask(id); control.show(tab: "chat"); content.layoutSubtreeIfNeeded()
                if find(content, AgentTerminalPanel.self, matching: { $0.isShown }) == nil {
                    try button(content, "打开终端").performClick(nil); content.layoutSubtreeIfNeeded()
                }
                guard let value = find(content, AgentTerminalPanel.self, matching: { $0.isShown }) else { throw PetError("任务终端未显示") }
                panel = value; return value
            }
            func panes(_ id: String) -> [[String: Any]] {
                let states = panel?.verificationSnapshot()["states"] as? [[String: Any]] ?? []
                let tabs = states.first { $0["taskID"] as? String == id }?["tabs"] as? [[String: Any]] ?? []
                return tabs.flatMap { $0["panes"] as? [[String: Any]] ?? [] }
            }
            func number(_ pane: [String: Any], _ key: String) -> Int? { (pane[key] as? NSNumber)?.intValue }
            func sessionCount() -> Int { (try? String(contentsOfFile: log, encoding: .utf8).split(separator: "\n").count) ?? 0 }
            func waitFor(_ label: String, _ ready: () -> Bool) async throws {
                let deadline = Date().addingTimeInterval(15)
                while !ready(), Date() < deadline { await wait(0.05) }
                guard ready() else { throw PetError("终端未读回 " + label) }
            }
            func type(_ value: String, into field: NSTextField) {
                if let editor = field.currentEditor() as? NSTextView { editor.string = value }
                field.stringValue = value
            }
            func capture(_ view: NSView, _ file: String) throws {
                content.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw PetError("终端验收视图不可渲染") }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else { throw PetError("终端验收图不可导出") }
                try data.write(to: output.appendingPathComponent(file))
            }
            func connect(_ host: String, _ directory: String, checkInvalid: Bool = false) throws {
                guard let panel else { throw PetError("缺少终端视图") }
                try button(panel, "新建 SSH 终端").performClick(nil)
                guard let dialog = window.agentDialog,
                      let target = find(dialog.view, NSTextField.self, matching: { $0.accessibilityLabel() == "SSH 主机" && $0.isEditable }),
                      let folder = find(dialog.view, NSTextField.self, matching: { $0.accessibilityLabel() == "远程目录（可选）" && $0.isEditable }) else {
                    throw PetError("缺少 SSH 表单字段")
                }
                type(host, into: target)
                let confirm = try button(dialog.view, "连接")
                if checkInvalid {
                    let before = sessionCount()
                    type("relative-project", into: folder); confirm.performClick(nil)
                    let error = find(dialog.view, NSTextField.self, matching: { $0.accessibilityLabel() == "SSH 连接表单错误" })
                    checks["invalidDirectoryKeepsBothFieldsAndNeverConnects"] = window.agentDialog === dialog &&
                        error?.stringValue.contains("绝对路径") == true && target.stringValue == host &&
                        folder.stringValue == "relative-project" && sessionCount() == before
                    try capture(dialog.view, "ssh-directory-form-dark.png")
                }
                type(directory, into: folder); confirm.performClick(nil)
                guard window.agentDialog == nil else { throw PetError("SSH 表单未确认") }
            }
            func read(_ id: String, pane: String, marker: String, ssh: Bool = true) async throws {
                func text() -> String { panes(id).first(where: { $0["id"] as? String == pane })?["terminal"] as? String ?? "" }
                try await waitFor(ssh ? "SSH 会话" : "本机 Shell") { text().contains(ssh ? "SSH-FIXTURE-SESSION" : "whale") }
                panel?.focus()
                guard let input = window.firstResponder as? (NSView & NSTextInputClient), input.accessibilityLabel() == "终端输入" else {
                    throw PetError("没有聚焦原 SSH 会话")
                }
                input.insertText("/bin/cat terminal-fixture.txt\r", replacementRange: NSRange(location: NSNotFound, length: 0))
                try await waitFor(marker) { text().contains(marker) }
            }
            func paneID(_ id: String, path: String? = nil, host: String = "whale-loopback") throws -> String {
                let pane = panes(id).last { $0["sshDestination"] as? String == host && $0["sshDirectory"] as? String == path }
                guard let result = pane?["id"] as? String else { throw PetError("缺少原 SSH 会话记录") }
                return result
            }
            if !reopened {
                let workspace = output.appendingPathComponent("本机问答项目")
                try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
                try Data("LOCAL-PROJECT-1117\n".utf8).write(to: workspace.appendingPathComponent("terminal-fixture.txt"))
                let project = tasks.create(title: "SSH 目录 · 项目问答", workspace: workspace.path, mode: .ask)
                let standalone = tasks.create(title: "SSH 目录 · 无工作区问答", mode: .ask, workMode: .general)
                for id in [project, standalone] { tasks.update(id) { $0.draft = "保留原问题草稿" } }
                let projectPanel = try activate(project)
                guard let local = panes(project).first?["id"] as? String else { throw PetError("原本机终端不可用") }
                try await read(project, pane: local, marker: "LOCAL-PROJECT-1117", ssh: false)
                checks["localShellStillStartsAtTaskWorkspace"] = true
                try connect(alias, relative, checkInvalid: true)
                let first = try paneID(project, path: relative)
                try await read(project, pane: first, marker: "REMOTE-RELATIVE-1827")
                checks["projectAskEntersExactRemoteFolderWithQuotesAndUnicode"] = tasks.task(project)?.mode == .ask &&
                    projectPanel.monitorEntries(taskID: project).contains { $0.id == first && $0.detail.contains(relative) && $0.detail.contains(alias) }
                try button(projectPanel, "向右分屏").performClick(nil)
                let second = try paneID(project, path: relative)
                try await read(project, pane: second, marker: "REMOTE-RELATIVE-1827")
                let locals = panes(project).filter { $0["sshDestination"] is NSNull }
                checks["splitInheritsRemoteFolderAndKeepsLocalWorkspace"] = first != second && locals.first?["directory"] as? String == workspace.path &&
                    panes(project).filter { $0["sshDirectory"] as? String == relative }.count == 2
                _ = try activate(standalone)
                try connect(alias, absolute)
                try await read(standalone, pane: paneID(standalone, path: absolute), marker: "REMOTE-ABSOLUTE-2974")
                checks["noWorkspaceAskWithAbsoluteRemoteFolder"] = tasks.task(standalone)?.mode == .ask && tasks.task(standalone)?.workspace == nil
                try connect(alias, "")
                try await read(standalone, pane: paneID(standalone), marker: "REMOTE-HOME-3791")
                checks["blankRemoteDirectoryUsesExistingHostOnlySession"] = true
                try connect(alias, retryPath)
                let retry = try paneID(standalone, path: retryPath)
                try await waitFor("远程目录错误") {
                    panes(standalone).contains { $0["id"] as? String == retry && number($0, "exitCode") == 1 &&
                        ($0["terminal"] as? String)?.filter { !$0.isWhitespace && $0 != "\0" }.contains("无法进入远程目录") == true }
                }
                checks["missingRemoteDirectoryStopsBeforeInteractiveShell"] = true
                if let panel { try capture(panel, "ssh-directory-missing-dark.png") }
                let before = sessionCount()
                try connect("whale-unverified", absolute)
                let unknown = try paneID(standalone, path: absolute, host: "whale-unverified")
                try await waitFor("SSH 主机校验失败") {
                    panes(standalone).contains { $0["id"] as? String == unknown && number($0, "exitCode") == 255 }
                }
                checks["remoteDirectoryDoesNotSkipHostVerification"] = sessionCount() == before
                let pids = (panes(project) + panes(standalone)).compactMap { number($0, "pid") }.filter { $0 > 0 }
                panel?.suspendAll()
                try await waitFor("会话关闭") { (panes(project) + panes(standalone)).allSatisfy { number($0, "pid") == 0 } }
                guard await flushWorkspaceWindows(), let id = control.workspaceSession?.id else { throw PetError("终端窗口未保存") }
                let saved = try reference.loadTerminalLayout(windowID: id)
                let savedText = try String(contentsOf: store.directory.appendingPathComponent("workspace-recovery/\(id)/terminal.json"), encoding: .utf8)
                checks["suspendedWindowSavesVersionThreeWithoutTranscript"] = saved?.value.version == 3 &&
                    savedText.contains("sshDirectory") && !savedText.contains("REMOTE-RELATIVE-1827") && !savedText.contains("terminal-fixture.txt")
                let phase: [String: Any] = ["project": project, "standalone": standalone, "projectPane": first, "retryPane": retry,
                                            "sessions": before, "pids": pids, "pid": getpid(), "checks": checks, "windowID": id]
                try JSONSerialization.data(withJSONObject: phase, options: [.sortedKeys]).write(to: phaseFile, options: .atomic)
            } else {
                let previous = try JSONSerialization.jsonObject(with: Data(contentsOf: phaseFile)) as? [String: Any] ?? [:]
                checks = previous["checks"] as? [String: Bool] ?? [:]
                guard let project = previous["project"] as? String, let standalone = previous["standalone"] as? String,
                      let projectPane = previous["projectPane"] as? String, let retry = previous["retryPane"] as? String else {
                    throw PetError("缺少原 SSH 窗口记录")
                }
                let restored = try activate(standalone)
                checks["restartRestoresTwoTasksAndMakesNoConnection"] = previous["pid"] as? Int != Int(getpid()) &&
                    control.workspaceSession?.id == previous["windowID"] as? String && sessionCount() == previous["sessions"] as? Int &&
                    (panes(project) + panes(standalone)).count == 8 && (panes(project) + panes(standalone)).allSatisfy { number($0, "pid") == 0 }
                try restored.openMonitorEntry(retry, taskID: standalone)
                try capture(restored, "ssh-directory-reopened-light.png")
                guard let pane = panes(standalone).first(where: { $0["id"] as? String == retry }), let index = number(pane, "number") else {
                    throw PetError("未恢复待重试的 SSH 会话")
                }
                try button(restored, "连接 SSH \(index)").performClick(nil)
                try await read(standalone, pane: retry, marker: "REMOTE-RETRY-4885")
                checks["repairedDirectoryReconnectsUsingOriginalPane"] = panes(standalone).contains { $0["id"] as? String == retry &&
                    $0["sshDirectory"] as? String == retryPath && ($0["location"] as? String)?.contains(retryPath) == true }
                let projectPanel = try activate(project)
                try projectPanel.openMonitorEntry(projectPane, taskID: project)
                guard let pane = panes(project).first(where: { $0["id"] as? String == projectPane }), let index = number(pane, "number") else {
                    throw PetError("未恢复原项目的 SSH 会话")
                }
                try button(projectPanel, "连接 SSH \(index)").performClick(nil)
                try await read(project, pane: projectPane, marker: "REMOTE-RELATIVE-1827")
                checks["reconnectedProjectRetainsPathAndIdleSibling"] = panes(project).contains { $0["id"] as? String != projectPane &&
                    $0["sshDirectory"] as? String == relative && number($0, "pid") == 0 }
                checks["taskDraftsAndWorkspaceScopesSurvive"] = tasks.task(project)?.workspace != home &&
                    tasks.task(standalone)?.workspace == nil && [project, standalone].allSatisfy { tasks.task($0)?.draft == "保留原问题草稿" }
                checks["exactlyTwoManualConnectionsAfterRestart"] = sessionCount() == (previous["sessions"] as? Int ?? -10) + 2
                panel?.suspendAll()
                try await waitFor("会话关闭") { (panes(project) + panes(standalone)).allSatisfy { number($0, "pid") == 0 } }
                guard await flushWorkspaceWindows() else { throw PetError("重开的终端窗口未保存") }
            }
        } catch { failure = error.localizedDescription }
        var report: [String: Any] = ["checks": checks, "success": failure == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && requests == 0,
                                     "modelRequests": requests, "pid": getpid(), "reopened": reopened]
        report["error"] = failure
        if failure != nil { report["terminalState"] = panel?.verificationSnapshot() }
        report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent(reopened ? "ssh-directory-reopened.json" : "ssh-directory-initial.json"), options: .atomic)
    }
}
