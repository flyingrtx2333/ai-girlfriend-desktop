import AppKit
import CoreText

@MainActor extension AppDelegate {
    static var contentAppearanceSample: String {
        """
        # 阅读排版 Reading
        中文与 English 混排，保留标点、段落和 🧭。这段公开文字用于检查正文换行。调整内容宽度后，阅读区域与输入区应当继续对齐，并保留原有任务。

        **重点内容**、*可辨文字* 和 `let answer = 42` 使用各自的格式。[公开链接](https://example.com)保持可用。

        ```swift
        let result = "中文与 English"
        ```

        | 页面 | 状态 |
        | --- | --- |
        | 设置 | 已保留 |
        """
    }
    func prepareContentAppearanceUI(_ output: URL) throws {
        guard let tasks = agentStore, let id = tasks.selectedID else { throw PetError("缺少内容外观验收任务") }
        tasks.update(id) { $0.messages = [AgentMessage(role: "user", content: "查看中文与 English 阅读排版 🧭"), AgentMessage(role: "assistant", content: Self.contentAppearanceSample)] }
        try JSONSerialization.data(withJSONObject: ["taskID": id, "modelRequests": 0, "sample": Self.contentAppearanceSample], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("content-appearance-fixtures.json"))
    }
    func runContentAppearanceCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        do {
            ensureAgent(); guard usesAgent, let tasks = agentStore, let runtime = agentRuntime else { throw PetError("内容外观验收未进入独立工作台") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("内容外观验收禁止模型请求") }
            let coding = tasks.create(title: "编程阅读排版", workMode: .coding), general = tasks.create(title: "通用阅读排版", workMode: .general)
            for id in [coding, general] { tasks.update(id) { $0.messages = [AgentMessage(role: "user", content: "公开提问 English 🧭"), AgentMessage(role: "assistant", content: Self.contentAppearanceSample)]; $0.draft = "保留中文 English 🧭 未发送草稿" } }
            control.showAgentTask(coding); let second = ControlWindow(companion: self, taskID: general, windowNumber: 2); additionalTaskWindows.append(second)
            let service = contentAppearance, file = store.directory.appendingPathComponent("content-appearance.json")
            checks["missingContentPreferencesUseDefaultsWithoutWriting"] = service.error == nil && service.settings == AgentContentAppearance.Settings() && !FileManager.default.fileExists(atPath: file.path)
            var large = appearance.settings; large.textSize = 18; try appearance.save(large)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let originalTasks = try [coding, general].map { try encoder.encode(tasks.task($0)!) }, preferences = try encoder.encode(store.preferences)
            let oldNames = ["appearance.json", "theme-styles.json", "mode-presentation.json", "sidebar.json"], oldBytes = oldNames.map { try? Data(contentsOf: store.directory.appendingPathComponent($0)) }
            let originalDisplays = [control, second].map { ($0.contentAppearanceReadback()["messages"] as? [[String: Any]] ?? []).map { $0["display"] as? String ?? "" }.sorted() }
            var metrics: [String: Any] = [:]
            func font(_ token: String, in text: NSAttributedString) -> NSFont? {
                let range = (text.string as NSString).range(of: token); guard range.location != NSNotFound else { return nil }; return text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            }
            let row = ChatMessageRow(message: ChatMessage(role: "assistant", content: Self.contentAppearanceSample), workbench: true)
            row.update(Self.contentAppearanceSample, searchQuery: "English"); let range = row.searchRange, display = row.label.stringValue
            for style in AgentContentFont.allCases {
                var value = service.settings; value.fontStyle = style; try service.save(value)
                let expected = style.font(size: 18)
                func expectedGlyphFont(_ token: String) -> String { CTFontCopyPostScriptName(CTFontCreateForString(expected as CTFont, token as CFString, CFRange(location: 0, length: (token as NSString).length))) as String }
                let expectedGlyphs = ["cjk": expectedGlyphFont("保留中文"), "latin": expectedGlyphFont("English")]
                checks[style.rawValue + "UpdatesBothExistingComposersAndMessageBodies"] = [control, second].allSatisfy { window in
                    let state = window.contentAppearanceReadback(), rows = state["messages"] as? [[String: Any]] ?? []
                    return state["composerGlyphFonts"] as? [String: String] == expectedGlyphs && state["composerSize"] as? CGFloat == 18 && rows.count == 2 && rows.allSatisfy { ($0["fonts"] as? [String])?.contains(expected.fontName) == true }
                }
                let rendered = NativeMarkdown.render(Self.contentAppearanceSample, font: expected, color: .labelColor, paragraph: NSParagraphStyle())
                checks[style.rawValue + "HeadingsAndInlineEmphasisKeepSelectedFamily"] = font("阅读排版", in: rendered)?.familyName == expected.familyName && font("阅读排版", in: rendered)?.pointSize == 19 && font("重点内容", in: rendered)?.fontDescriptor.symbolicTraits.contains(.bold) == true && font("可辨文字", in: rendered)?.fontDescriptor.symbolicTraits.contains(.italic) == true && font("页面", in: rendered)?.familyName == expected.familyName
                checks[style.rawValue + "InlineAndBlockCodeStayMonospaced"] = ["let answer = 42", "let result"].allSatisfy { font($0, in: rendered)?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true }
                let fallback = CTFontCreateForString(expected as CTFont, "中文" as CFString, CFRange(location: 0, length: 2)), fallbackName = CTFontCopyPostScriptName(fallback) as String
                checks[style.rawValue + "ChineseFallbackMatchesFontStyle"] = style == .serif ? fallbackName.contains("Songti") : !fallbackName.contains("Songti")
                row.refreshAppearance()
                checks[style.rawValue + "ExistingSearchAndRenderedTextRemainExact"] = row.searchRange == range && row.label.stringValue == display && row.text == Self.contentAppearanceSample
                metrics[style.rawValue + "Fonts"] = ["body": expected.fontName, "ChineseFallback": fallbackName]
                for size in [NSSize(width: 1200, height: 774), NSSize(width: 780, height: 540)] {
                    for width in AgentContentWidth.allCases {
                        value.contentWidth = width; try service.save(value)
                        for window in [control, second] { window.window?.setFrame(NSRect(origin: .zero, size: size), display: false); window.refreshContentAppearance() }
                        let states = [control, second].map { $0.contentAppearanceReadback() }, key = style.rawValue + "-" + width.rawValue + "-" + String(Int(size.width))
                        let expectedWidth = min(width.maximum, size.width - (size.width < 900 ? 218 : 231) - 36)
                        checks[key + "ActualTaskAndComposerWidthsMatchPreferenceAndAvailableSpace"] = states.allSatisfy { state in abs((state["columnWidth"] as? CGFloat ?? -1) - expectedWidth) < 1 && abs((state["composerWidth"] as? CGFloat ?? -1) - expectedWidth) < 1 && state["composerGlyphFonts"] as? [String: String] == expectedGlyphs }
                        checks[key + "PreservesExistingDisplayDraftAndTaskIdentity"] = states.enumerated().allSatisfy { index, state in (state["messages"] as? [[String: Any]] ?? []).map { $0["display"] as? String ?? "" }.sorted() == originalDisplays[index] && state["draft"] as? String == "保留中文 English 🧭 未发送草稿" && state["taskID"] as? String == [coding, general][index] }
                        metrics[key] = states
                    }
                }
            }
            second.showAgentTask(coding); checks["TaskSwitchRetainsChosenFontWidthAndOriginalDraft"] = second.contentAppearanceReadback()["fontStyle"] as? String == "serif" && second.contentAppearanceReadback()["draft"] as? String == "保留中文 English 🧭 未发送草稿"; second.showAgentTask(general)
            guard control.showSettingsCategory("appearance"), let content = control.window?.contentView else { throw PetError("外观设置不可见") }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let controls = descendants(content).compactMap { $0 as? NSPopUpButton }
            guard let fontControl = controls.first(where: { $0.identifier?.rawValue == "content-font-style" }), let widthControl = controls.first(where: { $0.identifier?.rawValue == "content-width" }) else { throw PetError("字体和宽度实际设置控件不完整") }
            checks["BothAccessibleSettingsReflectSavedPreferences"] = fontControl.accessibilityLabel() == "字体风格" && widthControl.accessibilityLabel() == "内容宽度" && fontControl.indexOfSelectedItem == 1 && widthControl.indexOfSelectedItem == 1
            for size in [NSSize(width: 1200, height: 774), NSSize(width: 780, height: 540)] {
                control.window?.setFrame(NSRect(origin: .zero, size: size), display: false); content.layoutSubtreeIfNeeded()
                checks["SettingsFit-" + String(Int(size.width))] = [fontControl, widthControl].allSatisfy { let frame = $0.convert($0.bounds, to: content); return frame.minX >= 178 && frame.maxX <= size.width && frame.width >= 150 }
            }
            let responder = control.window?.firstResponder
            fontControl.selectItem(at: 0); _ = fontControl.sendAction(fontControl.action, to: fontControl.target)
            widthControl.selectItem(at: 0); _ = widthControl.sendAction(widthControl.action, to: widthControl.target)
            checks["ActualSettingsActionsApplyBothChoicesWithoutChangingFocus"] = service.settings.fontStyle == .sans && service.settings.contentWidth == .standard && control.window?.firstResponder === responder && second.contentAppearanceReadback()["fontStyle"] as? String == "sans"
            let bytes = try Data(contentsOf: file), saved = service.settings
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
            fontControl.selectItem(at: 1); _ = fontControl.sendAction(fontControl.action, to: fontControl.target)
            checks["ReadOnlySaveRestoresChoiceAndKeepsOtherWindowAndBytes"] = try fontControl.indexOfSelectedItem == 0 && service.settings == saved && Data(contentsOf: file) == bytes && second.contentAppearanceReadback()["fontStyle"] as? String == "sans"
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            fontControl.selectItem(at: 1); _ = fontControl.sendAction(fontControl.action, to: fontControl.target)
            checks["SameControlSavesAfterWritePermissionReturns"] = service.settings.fontStyle == .serif && second.contentAppearanceReadback()["fontStyle"] as? String == "serif"
            checks["SavedContentPreferencesReloadExactlyAndPrivately"] = try AgentContentAppearance(directory: store.directory).settings == service.settings && (FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600
            let beforeConflict = service.settings; var external = beforeConflict; external.fontStyle = .sans; let changed = try encoder.encode(external); try changed.write(to: file)
            var attempted = beforeConflict; attempted.contentWidth = .wide
            var refused = false; do { try service.save(attempted) } catch { refused = true }
            checks["ExternalEditCannotBeOverwrittenByStaleContentPreferences"] = try refused && service.settings == beforeConflict && Data(contentsOf: file) == changed
            service.reload(); service.apply()
            checks["ExplicitReloadUpdatesExistingControlsAndBothWindows"] = service.error == nil && service.settings == external && fontControl.indexOfSelectedItem == 0 && [control, second].allSatisfy { $0.contentAppearanceReadback()["fontStyle"] as? String == "sans" }
            let base = try JSONSerialization.jsonObject(with: encoder.encode(AgentContentAppearance.Settings())) as! [String: Any]
            for label in ["version", "missing", "extra", "font", "width", "type"] {
                var invalid = base
                switch label { case "version": invalid["version"] = 2; case "missing": invalid.removeValue(forKey: "fontStyle"); case "extra": invalid["extra"] = true; case "font": invalid["fontStyle"] = "unknown"; case "width": invalid["contentWidth"] = "unknown"; default: invalid["fontStyle"] = true }
                let directory = output.appendingPathComponent("invalid-" + label); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let target = directory.appendingPathComponent("content-appearance.json"), data = try JSONSerialization.data(withJSONObject: invalid); try data.write(to: target)
                let guarded = AgentContentAppearance(directory: directory); refused = false; do { try guarded.save(AgentContentAppearance.Settings()) } catch { refused = true }
                checks["Invalid-" + label + "PreservesBytesAndRefusesSave"] = try guarded.error != nil && refused && Data(contentsOf: target) == data
            }
            let linked = output.appendingPathComponent("linked"); try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: false); try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("content-appearance.json"), withDestinationURL: file)
            checks["SymbolicLinkConfigurationIsRejected"] = AgentContentAppearance(directory: linked).error != nil
            checks["AllLegacyAppearanceAndModeConfigurationBytesRemainExact"] = oldNames.map { try? Data(contentsOf: store.directory.appendingPathComponent($0)) } == oldBytes
            checks["AllOriginalTaskFieldsAndModelPreferencesRemainExact"] = try [coding, general].map { try encoder.encode(tasks.task($0)!) } == originalTasks && encoder.encode(store.preferences) == preferences
            report["metrics"] = metrics; report["success"] = checks.count >= 30 && checks.values.allSatisfy { $0 }
        } catch { report["error"] = error.localizedDescription; report["success"] = false }
        report["checks"] = checks; report["modelRequests"] = requests; report["appPID"] = getpid()
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("content-appearance-report.json"))
    }
}
