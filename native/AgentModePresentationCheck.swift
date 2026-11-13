import AppKit

@MainActor extension AppDelegate {
    func runModePresentationCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        do {
            ensureAgent()
            guard usesAgent, let tasks = agentStore, let runtime = agentRuntime else { throw PetError("模式验收未进入独立工作台") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("模式展示验收禁止模型请求") }
            let project = output.appendingPathComponent("公开项目"); try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
            let source = project.appendingPathComponent("README.md"); try Data("# 模式展示验收\n".utf8).write(to: source)
            let coding = tasks.create(title: "编程展示验收", workspace: project.path, workMode: .coding)
            let general = tasks.create(title: "通用展示验收", workspace: project.path, workMode: .general)
            let noWorkspace = tasks.create(title: "无工作区通用验收", workMode: .general)
            for id in [coding, general, noWorkspace] { tasks.update(id) { $0.draft = "保留" + $0.title + "输入" } }
            for id in [coding, general] { tasks.update(id) { $0.changes = [AgentChange(path: source.path, existed: true, beforeHash: AgentFiles.hash(Data("# 原文\n".utf8)), afterHash: AgentFiles.hash(Data("# 模式展示验收\n".utf8)))] } }
            control.showAgentTask(coding)
            let second = ControlWindow(companion: self, taskID: general, windowNumber: 2); additionalTaskWindows.append(second)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let originals = try [coding, general, noWorkspace].map { try encoder.encode(tasks.task($0)!) }, preferences = try encoder.encode(store.preferences)
            let service = modePresentation, file = store.directory.appendingPathComponent("mode-presentation.json")
            checks["missingConfigurationUsesModeDefaultsWithoutWriting"] = service.error == nil && service.settings == AgentModePresentation.Settings() && !FileManager.default.fileExists(atPath: file.path)
            func matches(_ window: ControlWindow, _ value: AgentModePresentation.Presentation, changes: Int, workspace: Bool) -> Bool {
                let state = window.modePresentationReadback()
                return state["projectEntryHidden"] as? Bool == !value.projectEntry && state["emptyProjectHidden"] as? Bool == !value.projectEntry && state["inputEnvironmentHidden"] as? Bool == !value.inputEnvironment && state["gitEntryHidden"] as? Bool == !value.changeReview && state["branchHidden"] as? Bool == !(value.inputEnvironment && workspace) && state["inspectorChangeRows"] as? Int == (value.changeReview ? changes : 0)
            }
            checks["existingWindowsUseIndependentCodingAndGeneralDefaults"] = matches(control, .defaults(.coding), changes: 1, workspace: true) && matches(second, .defaults(.general), changes: 1, workspace: true)
            var values = service.settings
            values.coding = .init(projectEntry: false, inputEnvironment: true, changeReview: false)
            values.general = .init(projectEntry: true, inputEnvironment: false, changeReview: true)
            try service.save(values)
            checks["mixedPreferencesImmediatelyReachBothExistingWindows"] = matches(control, values.coding, changes: 1, workspace: true) && matches(second, values.general, changes: 1, workspace: true)
            values.general.inputEnvironment = true; values.coding.inputEnvironment = false; try service.save(values)
            checks["environmentAndProjectChoicesAreIndependent"] = matches(control, values.coding, changes: 1, workspace: true) && matches(second, values.general, changes: 1, workspace: true)
            checks["savedConfigurationReloadsExactModesPrivately"] = try AgentModePresentation(directory: store.directory).settings == values && (FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600
            second.showAgentTask(noWorkspace)
            checks["enabledGeneralEnvironmentNeedsNoWorkspace"] = matches(second, values.general, changes: 0, workspace: false)
            second.showAgentTask(general)
            checks["switchingTasksRestoresTheirOwnModePreferences"] = matches(second, values.general, changes: 1, workspace: true) && second.modePresentationReadback()["draft"] as? String == "保留通用展示验收输入"
            guard control.showSettingsCategory("modes"), let content = control.window?.contentView else { throw PetError("模式设置页不可见") }
            func switches(_ view: NSView) -> [NSSwitch] {
                if let control = view as? NSSwitch, control.identifier?.rawValue.hasPrefix("mode-") == true { return [control] }
                return view.subviews.flatMap(switches)
            }
            let controls = switches(content)
            guard controls.count == 6, let toggle = controls.first(where: { $0.identifier?.rawValue == "mode-coding-0" }) else { throw PetError("实际设置开关不完整") }
            checks["settingsPageContainsSixAccessibleModeControls"] = controls.allSatisfy { $0.accessibilityLabel()?.contains("：") == true }
            checks.merge(control.checkModeSettingsSearch()) { _, next in next }
            for size in [NSSize(width: 1200, height: 774), NSSize(width: 780, height: 540)] {
                control.window?.setFrame(NSRect(origin: .zero, size: size), display: false); content.layoutSubtreeIfNeeded()
                checks["settings-\(Int(size.width))KeepsAllSwitchesInsideContentWidth"] = controls.allSatisfy { item in let frame = item.convert(item.bounds, to: content); return item.window === control.window && frame.minX >= 178 && frame.maxX <= size.width && frame.width >= 30 && frame.height >= 20 }
            }
            let focus = control.window?.firstResponder
            toggle.state = .on; _ = toggle.sendAction(toggle.action, to: toggle.target)
            checks["actualSettingsActionSavesOnlyItsModeAndKeepsFocus"] = service.settings.coding.projectEntry && service.settings.general == values.general && control.window?.firstResponder === focus
            let bytes = try Data(contentsOf: file), saved = service.settings
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
            toggle.state = .off; _ = toggle.sendAction(toggle.action, to: toggle.target)
            checks["readOnlyUIRejectsSaveAndRestoresToggleAndLayout"] = try toggle.state == .on && service.settings == saved && Data(contentsOf: file) == bytes && matches(second, saved.general, changes: 1, workspace: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            toggle.state = .off; _ = toggle.sendAction(toggle.action, to: toggle.target)
            checks["sameControlCanSaveAfterWritePermissionReturns"] = !service.settings.coding.projectEntry && service.settings.general == saved.general
            let beforeConflict = service.settings
            var external = beforeConflict; external.general.changeReview = false
            let externalBytes = try encoder.encode(external); try externalBytes.write(to: file)
            var refused = false; do { try service.save(saved) } catch { refused = true }
            checks["externalEditCannotBeOverwrittenByStaleSettings"] = try refused && service.settings == beforeConflict && Data(contentsOf: file) == externalBytes
            service.reload(); service.publish()
            checks["explicitReloadUpdatesExistingWindowsAndControls"] = service.error == nil && service.settings == external && matches(second, external.general, changes: 1, workspace: true)
            let base = try JSONSerialization.jsonObject(with: encoder.encode(AgentModePresentation.Settings())) as! [String: Any]
            for label in ["version", "missing", "extra", "mode-extra", "value-type"] {
                var invalid = base
                switch label {
                case "version": invalid["version"] = 2
                case "missing": invalid.removeValue(forKey: "general")
                case "extra": invalid["extra"] = true
                default:
                    var mode = invalid["coding"] as! [String: Any]
                    if label == "mode-extra" { mode["extra"] = true } else { mode["projectEntry"] = "true" }
                    invalid["coding"] = mode
                }
                let directory = output.appendingPathComponent("invalid-" + label); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let target = directory.appendingPathComponent("mode-presentation.json"), data = try JSONSerialization.data(withJSONObject: invalid); try data.write(to: target)
                let guarded = AgentModePresentation(directory: directory); refused = false; do { try guarded.save(AgentModePresentation.Settings()) } catch { refused = true }
                checks["invalid-" + label + "PreservesBytesAndRefusesSave"] = try guarded.error != nil && refused && Data(contentsOf: target) == data
            }
            let linked = output.appendingPathComponent("linked"); try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("mode-presentation.json"), withDestinationURL: file)
            checks["symbolicLinkConfigurationIsRejected"] = AgentModePresentation(directory: linked).error != nil
            checks["modeControlsRemainEnabledAfterValidReload"] = controls.allSatisfy(\.isEnabled)
            checks["allOriginalTaskFieldsAndModelPreferencesPreserved"] = try [coding, general, noWorkspace].map { try encoder.encode(tasks.task($0)!) } == originals && encoder.encode(store.preferences) == preferences
            report["success"] = checks.count == 27 && checks["allOriginalTaskFieldsAndModelPreferencesPreserved"] == true && checks.values.allSatisfy { $0 }
        } catch { report["error"] = error.localizedDescription; report["success"] = false }
        report["checks"] = checks; report["modelRequests"] = requests; report["appPID"] = getpid()
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("mode-presentation-report.json"))
    }
}
