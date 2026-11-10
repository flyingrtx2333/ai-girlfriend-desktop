import AppKit

@MainActor extension AppDelegate {
    func runAgentShortcutCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], requests = 0
        let binary = Bundle.main.executableURL!, hash = (try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)) ?? ""
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        do {
            try write(["appPID": getpid(), "binaryHash": hash], "shortcut-started.json")
            ensureAgent(); agentRuntime?.modelRequestCheck = { requests += 1; throw PetError("快捷键验收不调用模型") }
            let root = output.appendingPathComponent("shortcut-store-check", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let value = AgentShortcuts(directory: root), config = root.appendingPathComponent("shortcuts.json")
            func bytes() throws -> Data { try Data(contentsOf: config) }
            func rejects(_ name: String, _ action: () throws -> Void) throws {
                let before = try bytes(); var rejected = false
                do { try action() } catch { rejected = true }
                let after = try bytes(); checks[name] = rejected && after == before
            }
            let defaults = AgentShortcutCommand.allCases.map { value.binding($0) }
            checks["eightUniqueDefaultsWithoutCreatingConfig"] = value.error == nil && defaults.count == 8 && Set(defaults).count == 8 && !FileManager.default.fileExists(atPath: config.path)
            try value.set(.init("n", [.command, .option]), for: .newTask)
            checks["customBindingPersistsAndReopens"] = AgentShortcuts(directory: root).binding(.newTask) == .init("n", [.command, .option])
            checks["configOwnerOnly"] = (try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600
            try rejects("duplicateRejectedWithoutWrite") { try value.set(.init("k", .command), for: .newTask) }
            try rejects("textEditingReservedWithoutWrite") { try value.set(.init("c", .command), for: .newTask) }
            try rejects("unmodifiedTypingRejected") { try value.set(.init("n", []), for: .newTask) }
            try rejects("unknownModifierRejected") { try value.set(.init("n", [.command, .function]), for: .newTask) }
            try rejects("backtabReservedForComposer") { try value.set(.init("\t", .shift), for: .newTask) }
            try value.set(.cleared, for: .newTask)
            checks["clearPersistsRatherThanFallingBack"] = AgentShortcuts(directory: root).binding(.newTask) == .cleared
            try value.set(.init("n", .command), for: .searchTasks)
            try rejects("singleRestoreChecksConflicts") { try value.set(nil, for: .newTask) }
            try value.reset()
            checks["restoreAllIsAtomicAndSparse"] = value.overrides.isEmpty && AgentShortcuts(directory: root).binding(.searchTasks) == AgentShortcutCommand.searchTasks.defaultBinding
            let stale = AgentShortcuts(directory: root)
            try value.set(.init("j", [.command, .option]), for: .searchTasks)
            try rejects("externalChangePreservedByCAS") { try stale.set(.init("n", [.command, .option]), for: .newTask) }
            stale.reload(); checks["reloadAdoptsExternalChange"] = stale.error == nil && stale.binding(.searchTasks) == value.binding(.searchTasks)
            let good = try bytes(); try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: config.path)
            try rejects("readOnlyConfigPreserved") { try value.reset() }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
            let target = root.appendingPathComponent("retained-original.json"); try good.write(to: target); try FileManager.default.removeItem(at: config); try FileManager.default.createSymbolicLink(at: config, withDestinationURL: target)
            let linked = AgentShortcuts(directory: root)
            checks["symlinkLoadRejected"] = linked.error != nil
            do { try linked.reset(); checks["symlinkWriteRejectedTargetPreserved"] = false }
            catch { checks["symlinkWriteRejectedTargetPreserved"] = try Data(contentsOf: target) == good }
            try FileManager.default.removeItem(at: config); try Data("{\"version\":2,\"bindings\":{}}".utf8).write(to: config)
            let future = AgentShortcuts(directory: root)
            try rejects("unknownVersionPreserved") { try future.reset() }
            try Data("{\"version\":1,\"bindings\":{},\"future\":true}".utf8).write(to: config)
            checks["unknownFieldsRejected"] = AgentShortcuts(directory: root).error != nil
            try good.write(to: config); value.reload()
            checks["recoverAfterValidFileRestored"] = value.error == nil && value.binding(.searchTasks) == .init("j", [.command, .option])
            try shortcuts.set(.init("n", [.command, .option]), for: .newTask)
            checks["actualMenuUpdatesImmediately"] = shortcutMenuItems[.newTask]?.keyEquivalent == "n" && shortcutMenuItems[.newTask]?.keyEquivalentModifierMask == [.command, .option]
            try shortcuts.set(.cleared, for: .newTask)
            checks["clearedMenuHasNoKeyEquivalent"] = shortcutMenuItems[.newTask]?.keyEquivalent.isEmpty == true
            try shortcuts.reset()
            checks["actualMenuRestoresDefaults"] = shortcutMenuItems[.newTask]?.keyEquivalent == "n" && shortcutMenuItems[.newTask]?.keyEquivalentModifierMask == .command
            checks["zeroModelRepliesReceiptsAndJobs"] = requests == 0 && agentStore?.tasks.compactMap { agentStore?.task($0.id) }.allSatisfy { $0.messages.isEmpty && $0.modelReceipts?.isEmpty != false && agentRuntime?.isRunning($0.id) != true } == true
            try write(["appPID": getpid(), "binaryHash": hash, "checks": checks, "blockedModelAttempts": requests, "success": checks.values.allSatisfy { $0 }], "shortcut-result.json")
        } catch { try? write(["appPID": getpid(), "binaryHash": hash, "checks": checks, "blockedModelAttempts": requests, "success": false, "error": error.localizedDescription], "shortcut-result.json") }
    }
}
