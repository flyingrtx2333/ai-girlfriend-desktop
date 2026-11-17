import AppKit

@MainActor enum AgentSaveFailureCheck {
    private static func find<T: NSView>(_ type: T.Type, in root: NSView?, matching: (T) -> Bool) -> T? {
        guard let root else { return nil }
        if let value = root as? T, matching(value) { return value }
        return root.subviews.lazy.compactMap { find(type, in: $0, matching: matching) }.first
    }
    private static func capture(_ action: () throws -> Void) -> Error? {
        do { try action(); return nil } catch { return error }
    }
    static func run(tasks: AgentStore, taskID: String, pane: AgentSettingsPageHost, host: NSWindow, output: URL) throws -> [String: Bool] {
        var checks: [String: Bool] = [:], observations: [String: Any] = [:]
        let fm = FileManager.default, root = output.appendingPathComponent("save-feedback-files")
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let files = try AgentFiles(workspace: root.path), file = root.appendingPathComponent("public.json")
        let original = Data("公开原文 🐋\n".utf8), changed = Data("其他编辑者的新内容。\n".utf8)
        try files.writeData(original, to: file, permissions: 0o600)
        func attempt(_ key: String, _ reason: AgentSaveFailure.Reason, _ action: () throws -> Void) {
            let error = capture(action), failure = error as? AgentSaveFailure
            checks[key] = failure?.reason == reason && error.map { AgentSaveFailure.message(for: $0) == failure?.message && !$0.localizedDescription.isEmpty } == true
            if let error { observations[key] = ["message": AgentSaveFailure.message(for: error), "diagnostic": error.localizedDescription] }
        }
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        attempt("ReadOnlyFileHasOneKnownCause", .readOnly) { _ = try AgentKnowledgeFileWrite(files: files, path: file.path, data: changed) }
        checks["ReadOnlyFailureKeepsExactBytesAndMode"] = try Data(contentsOf: file) == original && (fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o400
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        attempt("ExistingTargetIsNotCalledReadOnly", .exists) { _ = try AgentKnowledgeFileWrite(files: files, path: file.path, data: changed, missing: true) }
        let directory = root.appendingPathComponent("directory"); try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        attempt("DirectoryTargetIsNotCalledReadOnly", .invalidFile) { _ = try AgentKnowledgeFileWrite(files: files, path: directory.path, data: changed) }
        let link = root.appendingPathComponent("linked.json"); try fm.createSymbolicLink(at: link, withDestinationURL: file)
        attempt("LinkedTargetRetainsLocationProtection", .invalidLocation) { _ = try AgentKnowledgeFileWrite(files: files, path: link.path, data: changed) }
        attempt("StaleContentIsNotCalledTooLarge", .changed) { _ = try AgentKnowledgeFileWrite(files: files, path: file.path, data: changed, expectedHash: "stale") }
        attempt("OversizedContentIsNotCalledConflict", .tooLarge) { _ = try AgentKnowledgeFileWrite(files: files, path: file.path, data: Data(repeating: 65, count: 20_000_001)) }
        let write = try AgentKnowledgeFileWrite(files: files, path: file.path, data: changed, expectedHash: AgentFiles.hash(original))
        try files.writeData(changed, to: file, permissions: 0o600)
        attempt("ChangeAfterReviewStillRefusesOverwrite", .changed) { try write.requireCurrent() }
        checks["ConflictKeepsOtherEditorsExactBytes"] = try Data(contentsOf: file) == changed
        try files.writeData(original, to: file, permissions: 0o600)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        let denied = capture { try files.writeData(changed, to: file, permissions: 0o600) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        checks["ActualParentPermissionErrorHasReadableRecovery"] = denied.map { let value = $0 as NSError; return value.domain == NSPOSIXErrorDomain && [Int(POSIXErrorCode.EACCES.rawValue), Int(POSIXErrorCode.EPERM.rawValue)].contains(value.code) && AgentSaveFailure.message(for: $0).contains("所在文件夹的权限") } == true
        checks["ActualPermissionFailureKeepsBytesAndNoTemporaryFile"] = try Data(contentsOf: file) == original && !fm.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".bluefatfish-") }
        if let denied { observations["actualPermissionError"] = ["domain": (denied as NSError).domain, "code": (denied as NSError).code, "diagnostic": denied.localizedDescription, "message": AgentSaveFailure.message(for: denied)] }
        let systemCases: [(String, Error, String)] = [
            ("CocoaPermission", CocoaError(.fileWriteNoPermission), "权限"),
            ("CocoaReadOnlyVolume", CocoaError(.fileWriteVolumeReadOnly), "磁盘为只读"),
            ("CocoaSpace", CocoaError(.fileWriteOutOfSpace), "空间不足"),
            ("CocoaMissing", CocoaError(.fileNoSuchFile), "保存位置不可用"),
            ("CocoaExisting", CocoaError(.fileWriteFileExists), "同名"),
            ("CocoaInvalidName", CocoaError(.fileWriteInvalidFileName), "文件名无效"),
            ("POSIXSpace", POSIXError(.ENOSPC), "空间不足"),
            ("POSIXQuota", POSIXError(.EDQUOT), "空间不足"),
            ("POSIXReadOnlyVolume", POSIXError(.EROFS), "磁盘为只读"),
            ("POSIXMissingVolume", POSIXError(.ENODEV), "保存位置不可用"),
            ("POSIXLongName", POSIXError(.ENAMETOOLONG), "名称或路径过长"),
            ("POSIXBusy", POSIXError(.EBUSY), "稍后重试")
        ]
        for (key, error, phrase) in systemCases { checks[key + "OffersSpecificRecovery"] = AgentSaveFailure.message(for: error).contains(phrase) }
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue, userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOSPC), NSFilePathErrorKey: file.path])
        checks["WrappedSystemErrorUsesActualCauseWithoutInternalPath"] = AgentSaveFailure.message(for: wrapped).contains("空间不足") && !AgentSaveFailure.message(for: wrapped).contains(file.path)
        checks["UnknownSystemErrorDoesNotInventPermissionCause"] = AgentSaveFailure.message(for: POSIXError(.EIO)) == "未能保存，请稍后重试。"
        let invalidJSON = capture { _ = try JSONSerialization.jsonObject(with: Data("{invalid".utf8)) }
        checks["ActualInvalidJSONKeepsValidationDiagnosticInsteadOfRetryAdvice"] = invalidJSON.map { AgentSaveFailure.message(for: $0) == $0.localizedDescription && !AgentSaveFailure.message(for: $0).contains("稍后重试") } == true
        let partial = PetError("文件已保存，但名称无效，请打开源文件修正"), validation = PetError("请输入名称；说明中包含 Permission denied 和 No space left")
        checks["PartialSuccessAndValidationAreNotRewrittenByWordMatching"] = AgentSaveFailure.message(for: partial) == partial.message && AgentSaveFailure.message(for: validation) == validation.message

        let document = try tasks.agents.document(), config = tasks.agents.directory.appendingPathComponent("extensions/agents.json")
        let configBytes = try Data(contentsOf: config), mode = (try fm.attributesOfItem(atPath: config.path)[.posixPermissions] as! NSNumber).intValue
        let parent = config.deletingLastPathComponent(), parentMode = (try fm.attributesOfItem(atPath: parent.path)[.posixPermissions] as! NSNumber).intValue
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let taskBefore = try encoder.encode(tasks.task(taskID)!)
        let manager = AgentProfileWindow(store: tasks, workspace: tasks.task(taskID)?.workspace, taskID: taskID)
        guard pane.show(category: "agents", identity: "save-feedback", scope: "公开保存验收", make: { _ in manager }) else { throw PetError("无法打开保存错误验收页面") }
        guard let role = try tasks.agents.list().first else { throw PetError("缺少公开保存验收角色") }
        manager.selectProfile(role.id)
        guard let rootView = pane.currentController?.pageContentView,
              let edit = find(NSTextField.self, in: rootView, matching: { $0.accessibilityLabel() == "Agent 职责" }),
              let save = find(NSButton.self, in: rootView, matching: { $0.title == "保存" }),
              let state = find(AgentSettingsStatusField.self, in: rootView, matching: { $0.accessibilityLabel() == "Agent 保存状态" }) else { throw PetError("缺少实际保存控件") }
        let draft = "保存失败后保留的公开中文职责 🐋"
        edit.stringValue = draft; edit.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: edit))
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: config.path)
        defer { try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: config.path); try? fm.setAttributes([.posixPermissions: parentMode], ofItemAtPath: parent.path) }
        save.performClick(nil)
        checks["ActualSettingsSaveShowsShortCauseAndRetainsFullDiagnostic"] = state.stringValue == "未保存：文件为只读。请恢复写入权限后重试。" && state.toolTip?.contains(config.path) == true && state.isSelectable
        checks["FailedSettingsSaveKeepsDraftEnabledRetryAndDiskBytes"] = try edit.stringValue == draft && save.isEnabled && Data(contentsOf: config) == configBytes
        var geometry: [[String: Any]] = []
        // Test the actual status field at both densities and appearances.
        for (label, size) in [("normal", NSSize(width: 1000, height: 660)), ("narrow", NSSize(width: 520, height: 380))] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                host.appearance = NSAppearance(named: appearance); host.setContentSize(size); pane.layoutSubtreeIfNeeded()
                let rect = state.convert(state.bounds, to: rootView)
                let needed = state.attributedStringValue.boundingRect(with: NSSize(width: state.bounds.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
                let key = label + "-" + appearance.rawValue
                checks[key + "ErrorWrapsWithinActualEditor"] = !state.isHiddenOrHasHiddenAncestor && !state.hasAmbiguousLayout && rect.minX >= 0 && rect.maxX <= rootView.bounds.width + 1 && needed.height <= state.bounds.height + 2 && state.bounds.width > 80
                var semanticColor = false
                host.effectiveAppearance.performAsCurrentDrawingAppearance { semanticColor = state.textColor?.usingColorSpace(.sRGB) == AgentDialogStyle.error.usingColorSpace(.sRGB) }
                checks[key + "ErrorUsesSemanticColor"] = semanticColor
                geometry.append(["case": key, "width": state.bounds.width, "height": state.bounds.height, "neededHeight": needed.height, "message": state.stringValue])
            }
        }
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: config.path)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        save.performClick(nil)
        checks["ActualSettingsSystemErrorKeepsDraftAndReadablePermissionAction"] = try state.stringValue.contains("所在文件夹的权限") && edit.stringValue == draft && save.isEnabled && Data(contentsOf: config) == configBytes && !state.toolTip!.isEmpty
        try fm.setAttributes([.posixPermissions: parentMode], ofItemAtPath: parent.path)
        save.performClick(nil)
        checks["SameSaveButtonRetriesAndWritesExactDraftPrivately"] = try state.stringValue == "已保存" && !save.isEnabled && tasks.agents.list().contains { $0.description == draft } && (fm.attributesOfItem(atPath: config.path)[.posixPermissions] as? NSNumber)?.intValue == mode
        checks["SuccessfulRetryClearsErrorDiagnosticAndColor"] = state.toolTip == "已保存" && state.textColor == AgentWorkbenchTheme.secondaryText
        guard pane.leave() else { throw PetError("保存后未能返回设置") }
        try tasks.agents.save(document.0, expectedHash: tasks.agents.document().1)
        checks["AcceptanceRestoresExactOriginalConfigurationAndTask"] = try Data(contentsOf: config) == configBytes && encoder.encode(tasks.task(taskID)!) == taskBefore

        let plugins = tasks.extensions.plugins, workspace = tasks.task(taskID)?.workspace
        guard let plugin = try plugins.catalog(workspace: workspace).first(where: { $0.metadata.name == "zz-settings-demo" }) else { throw PetError("缺少公开插件保存样例") }
        var pluginDocument = try plugins.settingDocument(.user, workspace: workspace)
        if pluginDocument.hash == nil {
            try pluginDocument.files.writeData(Data("{}\n".utf8), to: pluginDocument.file, permissions: 0o600)
            pluginDocument = try plugins.settingDocument(.user, workspace: workspace)
        }
        let pluginBytes = try Data(contentsOf: pluginDocument.file), pluginMode = (try fm.attributesOfItem(atPath: pluginDocument.file.path)[.posixPermissions] as! NSNumber).intValue
        let pluginPage = AgentPluginSettingsWindow(service: plugins, item: plugin, workspace: workspace)
        guard pane.show(category: "plugins", identity: "save-feedback-plugin", scope: "公开插件验收", make: { _ in pluginPage }),
              let pluginRoot = pluginPage.pageContentView,
              let choice = find(NSPopUpButton.self, in: pluginRoot, matching: { $0.accessibilityLabel() == "插件启用声明" }),
              let pluginSave = find(NSButton.self, in: pluginRoot, matching: { $0.title == "保存" }),
              let pluginState = find(AgentSettingsStatusField.self, in: pluginRoot, matching: { $0.accessibilityLabel() == "插件设置保存状态" }) else { throw PetError("缺少插件实际保存控件") }
        choice.selectItem(at: 2); _ = choice.sendAction(choice.action, to: choice.target)
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: pluginDocument.file.path)
        defer { try? fm.setAttributes([.posixPermissions: pluginMode], ofItemAtPath: pluginDocument.file.path) }
        pluginSave.performClick(nil)
        checks["ActualPluginFailureRetainsChoiceRetryAndOriginalFile"] = try pluginState.stringValue.contains("文件为只读") && choice.indexOfSelectedItem == 2 && pluginSave.isEnabled && Data(contentsOf: pluginDocument.file) == pluginBytes
        for (label, size) in [("normal", NSSize(width: 1000, height: 660)), ("narrow", NSSize(width: 520, height: 380))] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                host.appearance = NSAppearance(named: appearance); host.setContentSize(size); pane.layoutSubtreeIfNeeded()
                let frame = pluginState.convert(pluginState.bounds, to: pluginRoot), needed = pluginState.attributedStringValue.boundingRect(with: NSSize(width: pluginState.bounds.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
                checks[label + "-" + appearance.rawValue + "PluginErrorHasFullWidthWithoutTruncation"] = !pluginState.isHiddenOrHasHiddenAncestor && !pluginState.hasAmbiguousLayout && frame.minX >= 0 && frame.maxX <= pluginRoot.bounds.width + 1 && frame.width >= pluginRoot.bounds.width - 40 && needed.height <= pluginState.bounds.height + 2 && pluginState.lineBreakMode == .byWordWrapping
            }
        }
        try fm.setAttributes([.posixPermissions: pluginMode], ofItemAtPath: pluginDocument.file.path)
        pluginSave.performClick(nil)
        checks["ActualPluginRetriesWithoutReenteringChoice"] = try choice.indexOfSelectedItem == 2 && !pluginSave.isEnabled && plugins.settingDocument(.user, workspace: workspace).values[plugin.metadata.name + "@local"] == false
        guard pane.leave() else { throw PetError("插件保存后未能返回") }
        try pluginDocument.files.writeData(pluginBytes, to: pluginDocument.file, permissions: pluginMode)
        checks["PluginAcceptanceRestoresItsOriginalBytesAndTask"] = try Data(contentsOf: pluginDocument.file) == pluginBytes && encoder.encode(tasks.task(taskID)!) == taskBefore
        host.appearance = nil; host.setContentSize(NSSize(width: 800, height: 540))
        observations["geometry"] = geometry
        try JSONSerialization.data(withJSONObject: ["checks": checks, "observations": observations, "success": checks.values.allSatisfy { $0 }, "modelRequests": 0], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("save-feedback-report.json"))
        return checks
    }
}
