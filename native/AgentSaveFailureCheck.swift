import AppKit

@MainActor enum AgentSaveFailureCheck {
    private static func find<T: NSView>(_ type: T.Type, in root: NSView?, matching: (T) -> Bool) -> T? {
        guard let root else { return nil }
        if let value = root as? T, matching(value) { return value }
        for child in root.subviews { if let value = find(type, in: child, matching: matching) { return value } }
        return nil
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
        let emptyJSON = capture { _ = try AgentConfigurationJSON.object(Data()) }
        let noOffset = emptyJSON.flatMap { AgentConfigurationJSON.draftSyntaxFailure(after: $0, in: "") }
        checks["EmptyDraftHasReadableSyntaxFeedbackWithoutInventingALocation"] = noOffset?.errorDescription?.contains("请检查括号") == true && noOffset?.location == nil
        checks["OtherSourceSyntaxFailureCannotLocateAValidDraft"] = emptyJSON.map { AgentConfigurationJSON.draftSyntaxFailure(after: $0, in: "{}") == nil } == true
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
                // Stack views align the text rectangle; the transparent frame extends 2pt on each side.
                let rect = state.superview!.convert(state.alignmentRect(forFrame: state.frame), to: rootView)
                let needed = state.attributedStringValue.boundingRect(with: NSSize(width: rect.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
                let key = label + "-" + appearance.rawValue
                checks[key + "ErrorWrapsWithinActualEditor"] = !state.isHiddenOrHasHiddenAncestor && !state.hasAmbiguousLayout && rect.minX >= 0 && rect.maxX <= rootView.bounds.width + 1 && needed.height <= rect.height + 2 && rect.width > 80
                var semanticColor = false
                host.effectiveAppearance.performAsCurrentDrawingAppearance { semanticColor = state.textColor?.usingColorSpace(.sRGB) == AgentDialogStyle.error.usingColorSpace(.sRGB) }
                checks[key + "ErrorUsesSemanticColor"] = semanticColor
                geometry.append(["case": key, "frameWidth": state.bounds.width, "alignmentX": rect.minX, "width": rect.width, "rootWidth": rootView.bounds.width, "height": rect.height, "neededHeight": needed.height, "message": state.stringValue])
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

        guard let task = tasks.task(taskID), let rule = try tasks.rules.catalog(workspace: workspace).first(where: { $0.name == "settings-rule" }) else { throw PetError("缺少公开只读规则") }
        let ruleOriginal = try Data(contentsOf: rule.source), ruleMode = (try fm.attributesOfItem(atPath: rule.source.path)[.posixPermissions] as! NSNumber).intValue
        let ruleFiles = try AgentFiles(workspace: rule.owner.path)
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: rule.source.path)
        defer { try? fm.setAttributes([.posixPermissions: ruleMode], ofItemAtPath: rule.source.path) }
        let readOnlyRule = try tasks.rules.current(rule.id, task: task, enabledOnly: false)
        let draftBody = "应在失败后保留的公开规则草稿 🐋\n第二行。"
        let draftRule = try AgentRuleDocument.text(name: rule.name, trigger: .always, description: "", patterns: [], body: draftBody)
        let ruleError = capture { _ = try tasks.rules.save(readOnlyRule, text: draftRule, task: task) }
        checks["AlreadyReadOnlyRuleCannotBeAtomicallyReplaced"] = try (ruleError as? AgentSaveFailure)?.reason == .readOnly && Data(contentsOf: rule.source) == ruleOriginal && (fm.attributesOfItem(atPath: rule.source.path)[.posixPermissions] as? NSNumber)?.intValue == 0o400
        func openRule(_ identity: String) throws -> (AgentRuleWindow, NSTextView, NSButton, AgentSettingsStatusField) {
            let page = AgentRuleWindow(store: tasks, taskID: taskID)
            guard pane.show(category: "rules", identity: identity, scope: "公开规则保存验收", make: { _ in page }),
                  let list = find(NSTableView.self, in: page.pageContentView, matching: { $0.accessibilityLabel() == "规则列表" }),
                  let action = list.action else { throw PetError("缺少规则目录入口") }
            NSApp.sendAction(action, to: list.target, from: list)
            let detail = pane.currentController?.pageContentView
            guard let body = find(NSTextView.self, in: detail, matching: { $0.accessibilityLabel() == "规则正文" }),
                  let save = find(NSButton.self, in: detail, matching: { $0.title == "保存" }),
                  let state = find(AgentSettingsStatusField.self, in: detail, matching: { $0.accessibilityLabel() == "规则保存状态" }) else { throw PetError("缺少规则实际保存控件") }
            body.string = draftBody; page.textDidChange(Notification(name: NSText.didChangeNotification, object: body)); save.performClick(nil)
            return (page, body, save, state)
        }
        let (rulePage, ruleBody, ruleSave, ruleState) = try openRule("readonly-rule-retry")
        checks["ActualReadOnlyRuleFailureKeepsBodyRetryAndOriginalBytes"] = try ruleState.stringValue.contains("文件为只读") && ruleState.toolTip?.contains(rule.source.path) == true && ruleBody.string == draftBody && ruleSave.isEnabled && Data(contentsOf: rule.source) == ruleOriginal
        for (label, size) in [("normal", NSSize(width: 1000, height: 660)), ("narrow", NSSize(width: 520, height: 540))] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                host.appearance = NSAppearance(named: appearance); host.setContentSize(size); pane.layoutSubtreeIfNeeded()
                // AppKit positions text fields by their alignment rectangle;
                // the transparent control frame extends beyond that rectangle.
                let aligned = ruleState.alignmentRect(forFrame: ruleState.frame)
                // The status aligns with the editor card, outside its 1pt border.
                let scroll = ruleBody.enclosingScrollView
                let container = scroll?.superview?.identifier?.rawValue == "settings-card-rule-body" ? scroll?.superview : scroll
                let viewer = container.map { $0.convert($0.bounds, to: ruleState.superview) } ?? .zero
                let action = ruleSave.convert(ruleSave.bounds, to: ruleState.superview)
                let above = ruleState.superview?.isFlipped == true ? aligned.maxY <= action.minY : aligned.minY >= action.maxY
                let needed = ruleState.attributedStringValue.boundingRect(with: NSSize(width: aligned.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
                checks[label + "-" + appearance.rawValue + "RuleErrorWrapsAboveActions"] = !ruleState.isHiddenOrHasHiddenAncestor && !ruleState.hasAmbiguousLayout && aligned.width > 80 && aligned.minX == viewer.minX && aligned.maxX == viewer.maxX && above && needed.height <= aligned.height + 2 && ruleState.lineBreakMode == .byWordWrapping
                geometry.append(["case": "rule-" + label + "-" + appearance.rawValue, "frameWidth": ruleState.bounds.width, "alignmentWidth": aligned.width, "viewerWidth": viewer.width, "height": aligned.height, "neededHeight": needed.height, "aboveActions": above, "ambiguous": ruleState.hasAmbiguousLayout, "wordWrapping": ruleState.lineBreakMode == .byWordWrapping])
            }
        }
        try fm.setAttributes([.posixPermissions: ruleMode], ofItemAtPath: rule.source.path)
        ruleSave.performClick(nil)
        checks["SameRuleSaveRetriesAfterPermissionChangeWithoutReenteringBody"] = try ruleState.stringValue == "已保存" && !ruleSave.isEnabled && ruleBody.string == draftBody && tasks.rules.current(rule.id, task: task, enabledOnly: false).definition?.body == draftBody && (fm.attributesOfItem(atPath: rule.source.path)[.posixPermissions] as? NSNumber)?.intValue == ruleMode
        guard pane.leave() else { throw PetError("规则重试保存后未能返回") }
        try ruleFiles.writeData(ruleOriginal, to: rule.source, permissions: ruleMode)
        let openedRule = try tasks.rules.current(rule.id, task: task, enabledOnly: false)
        try ruleFiles.writeData(ruleOriginal, to: rule.source, permissions: ruleMode)
        let identicalReplacement = capture { _ = try tasks.rules.save(openedRule, text: draftRule, task: task) }
        checks["StrictRuleVersionGuardStillRejectsIdenticalContentReplacement"] = try identicalReplacement != nil && Data(contentsOf: rule.source) == ruleOriginal

        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: rule.source.path)
        let (_, conflictBody, conflictSave, conflictState) = try openRule("readonly-rule-external-conflict")
        try fm.setAttributes([.posixPermissions: ruleMode], ofItemAtPath: rule.source.path)
        let externalRule = try AgentRuleDocument.text(name: rule.name, trigger: .always, description: "", patterns: [], body: "另一编辑器保留的公开规则。")
        try ruleFiles.writeData(Data(externalRule.utf8), to: rule.source, permissions: ruleMode)
        conflictSave.performClick(nil)
        checks["ReadOnlyRetryCannotRebaseOverAnActualExternalRuleEdit"] = try conflictState.stringValue.contains("其他编辑器") && conflictBody.string == draftBody && conflictSave.isEnabled && Data(contentsOf: rule.source) == Data(externalRule.utf8)
        observations["retainedPublicRuleConflict"] = ["draft": conflictBody.string, "external": externalRule, "diagnostic": conflictState.toolTip ?? ""]
        var discarded = false
        let deadline = Date().addingTimeInterval(5)
        let timer = Timer(timeInterval: 0.02, repeats: true) { timer in
            MainActor.assumeIsolated {
                if let dialog = NSApp.modalWindow?.agentDialog, let button = find(NSButton.self, in: dialog.view, matching: { $0.title == "放弃更改" }) { discarded = true; button.performClick(nil); timer.invalidate() }
                else if Date() >= deadline { timer.invalidate(); NSApp.abortModal() }
            }
        }
        RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        let left = pane.leave(); timer.invalidate()
        guard left && discarded else { throw PetError("公开冲突草稿留存后未能关闭验收页") }
        try ruleFiles.writeData(ruleOriginal, to: rule.source, permissions: ruleMode)
        checks["RuleAcceptanceRestoresExactOriginalFilePermissionsAndTask"] = try Data(contentsOf: rule.source) == ruleOriginal && (fm.attributesOfItem(atPath: rule.source.path)[.posixPermissions] as? NSNumber)?.intValue == ruleMode && encoder.encode(tasks.task(taskID)!) == taskBefore

        let validSource = try AgentRuleDocument.text(name: rule.name, trigger: .glob, description: "", patterns: ["src/**/*.ts"], body: "公开源文件正文。")
        let malformed = "---\nunknown_public_field: true\n" + validSource.dropFirst(4)
        try ruleFiles.writeData(Data(malformed.utf8), to: rule.source, permissions: ruleMode)
        defer { try? ruleFiles.writeData(ruleOriginal, to: rule.source, permissions: ruleMode) }
        let sourcePage = AgentRuleWindow(store: tasks, taskID: taskID)
        guard pane.show(category: "rules", identity: "malformed-rule-source", scope: "公开规则验收", make: { _ in sourcePage }),
              let list = find(NSTableView.self, in: sourcePage.pageContentView, matching: { $0.accessibilityLabel() == "规则列表" }),
              let action = list.action else { throw PetError("缺少格式错误规则入口") }
        NSApp.sendAction(action, to: list.target, from: list)
        let sourceDetail = pane.currentController?.pageContentView
        guard let sourceEditor = find(NSTextView.self, in: sourceDetail, matching: { $0.accessibilityLabel() == "规则源文件" }),
              let sourceState = find(AgentSettingsStatusField.self, in: sourceDetail, matching: { $0.accessibilityLabel() == "规则保存状态" }),
              let sourceSave = find(NSButton.self, in: sourceDetail, matching: { $0.title == "保存" }) else { throw PetError("缺少规则源文件编辑入口") }
        func visibleTrigger() -> NSPopUpButton? {
            find(NSPopUpButton.self, in: sourceDetail, matching: { $0.accessibilityLabel() == "规则触发方式" && !$0.isHiddenOrHasHiddenAncestor })
        }
        checks["MalformedRuleShowsItsEditableSourceInsteadOfFallbackTrigger"] = sourceEditor.isEditable && sourceEditor.string == malformed && visibleTrigger() == nil &&
            find(NSTextField.self, in: sourceDetail, matching: { $0.stringValue == "规则源文件" && !$0.isHiddenOrHasHiddenAncestor }) != nil
        let savedSource = try sourcePage.captureSettingsRecovery().map { try JSONSerialization.jsonObject(with: $0.state) as? [String: Any] } ?? nil
        checks["MalformedRulePreservesItsActualErrorStatus"] = sourceState.stringValue.contains("unknown_public_field") && sourceState.textColor == AgentDialogStyle.error && savedSource?["statusIsError"] as? Bool == true
        sourceEditor.string = validSource
        sourcePage.textDidChange(Notification(name: NSText.didChangeNotification, object: sourceEditor))
        sourceSave.performClick(nil)
        checks["CorrectedRuleShowsItsSavedTriggerAndBody"] = try Data(contentsOf: rule.source) == Data(validSource.utf8) && sourceState.stringValue == "已保存" &&
            visibleTrigger()?.titleOfSelectedItem == "匹配文件" && sourceEditor.accessibilityLabel() == "规则正文"
        guard pane.leave() else { throw PetError("修正规则后未能返回") }
        _ = rulePage
        host.appearance = nil; host.setContentSize(NSSize(width: 800, height: 540))
        observations["geometry"] = geometry
        try JSONSerialization.data(withJSONObject: ["checks": checks, "observations": observations, "success": checks.values.allSatisfy { $0 }, "modelRequests": 0], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("save-feedback-report.json"))
        return checks
    }
}
