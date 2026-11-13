import AppKit

@MainActor extension AppDelegate {
    func runThemeStylesCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        do {
            ensureAgent(); guard usesAgent, let tasks = agentStore, let runtime = agentRuntime else { throw PetError("主题验收未进入独立工作台") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("主题风格验收禁止模型请求") }
            let coding = tasks.create(title: "编程主题验收", workMode: .coding), general = tasks.create(title: "通用主题验收", workMode: .general)
            for id in [coding, general] { tasks.update(id) { $0.draft = "保留" + $0.title + "草稿" } }
            control.showAgentTask(coding)
            let second = ControlWindow(companion: self, taskID: general, windowNumber: 2); additionalTaskWindows.append(second)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let originals = try [coding, general].map { try encoder.encode(tasks.task($0)!) }, preferences = try encoder.encode(store.preferences)
            let service = themeStyles, file = store.directory.appendingPathComponent("theme-styles.json")
            let oldFiles = ["appearance.json", "mode-presentation.json"], oldBytes = oldFiles.map { try? Data(contentsOf: store.directory.appendingPathComponent($0)) }
            checks["missingStylesUseModeDefaultsWithoutWriting"] = service.error == nil && service.settings == AgentThemeStyles.Settings() && !FileManager.default.fileExists(atPath: file.path)
            checks["twoExistingWindowsBindIndependentModeDefaults"] = control.themeStylesReadback()["style"] as? String == "forest" && second.themeStylesReadback()["style"] as? String == "bee"
            func rgba(_ color: NSColor, look: NSAppearance) -> [CGFloat] {
                var values: [CGFloat] = []
                look.performAsCurrentDrawingAppearance { if let c = color.usingColorSpace(.sRGB) { values = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent] } }
                return values
            }
            func close(_ a: [CGFloat], _ b: [CGFloat]) -> Bool { a.count == 4 && b.count == 4 && zip(a, b).allSatisfy { abs($0 - $1) < 0.0001 } }
            func contrast(_ front: NSColor, _ back: NSColor, look: NSAppearance) -> CGFloat {
                let f = rgba(front, look: look), b = rgba(back, look: look)
                guard f.count == 4, b.count == 4 else { return 0 }
                func luminance(_ values: [CGFloat]) -> CGFloat { zip(values.prefix(3), [CGFloat(0.2126), 0.7152, 0.0722]).reduce(0) { sum, c in sum + (c.0 <= 0.04045 ? c.0 / 12.92 : pow((c.0 + 0.055) / 1.055, 2.4)) * c.1 } }
                let a = luminance((0..<3).map { f[$0] * f[3] + b[$0] * (1 - f[3]) }), z = luminance(b)
                return (max(a, z) + 0.05) / (min(a, z) + 0.05)
            }
            var captures: [String: Any] = [:], ratios: [String: [String: CGFloat]] = [:]
            for theme in [AgentTheme.light, .dark] {
                var brightness = appearance.settings; brightness.theme = theme; try appearance.save(brightness)
                for style in AgentThemeStyle.allCases {
                    let unchanged = second.themeStylesReadback()
                    var values = service.settings; values.coding = style; try service.save(values)
                    await wait(0.03)
                    let state = control.themeStylesReadback(), other = second.themeStylesReadback(), look = control.window!.effectiveAppearance, dark = theme == .dark
                    let key = theme.rawValue + "-" + style.rawValue
                    captures[key] = ["coding": state, "general": other]
                    checks[key + "ActualWindowAndSendLayersUseBoundPalette"] = close(state["sidebarColor"] as? [CGFloat] ?? [], rgba(AgentThemePalette.literal(.sidebar, style: style, dark: dark), look: look)) && close(state["sendColor"] as? [CGFloat] ?? [], rgba(AgentThemePalette.literal(.accent, style: style, dark: dark), look: look)) && close(state["selectedTaskColor"] as? [CGFloat] ?? [], rgba(AgentThemePalette.literal(.selection, style: style, dark: dark), look: look))
                    checks[key + "OtherModeKeepsItsPaletteAndBothInheritBrightness"] = (other["sidebarColor"] as? [CGFloat]) == (unchanged["sidebarColor"] as? [CGFloat]) && (other["sendColor"] as? [CGFloat]) == (unchanged["sendColor"] as? [CGFloat]) && [control, second].allSatisfy { $0.window?.appearance == nil && $0.window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (dark ? .darkAqua : .aqua) }
                    let selected = AgentThemePalette.literal(.selection, style: style, dark: dark), sidebar = AgentThemePalette.literal(.sidebar, style: style, dark: dark)
                    var valuesByRole = ["body": contrast(.labelColor, AgentThemePalette.literal(.surface, style: style, dark: dark), look: look), "sidebarSecondary": contrast(AgentThemePalette.literal(.secondaryText, style: style, dark: dark), sidebar, look: look), "selectedSecondary": contrast(AgentThemePalette.literal(.secondaryText, style: style, dark: dark), selected, look: look), "sendAction": contrast(AgentThemePalette.literal(.accentText, style: style, dark: dark), AgentThemePalette.literal(.accent, style: style, dark: dark), look: look)]
                    if let gradient = AgentThemePalette.sidebarGradient(style: style, dark: dark) { valuesByRole["gradientSecondary"] = contrast(AgentThemePalette.literal(.secondaryText, style: style, dark: dark), gradient.interpolatedColor(atLocation: 1), look: look) }
                    ratios[key] = valuesByRole; checks[key + "TextAndActionContrast"] = valuesByRole.values.allSatisfy { $0 >= 4.5 }
                }
            }
            let brightnessBeforeStyleActions = try Data(contentsOf: store.directory.appendingPathComponent("appearance.json"))
            var values = service.settings; values.coding = .mint; values.general = .parchment; try service.save(values)
            second.showAgentTask(coding); checks["switchingTaskUsesItsModeStyleAndDraft"] = second.themeStylesReadback()["style"] as? String == "mint" && second.themeStylesReadback()["draft"] as? String == "保留编程主题验收草稿"
            second.showAgentTask(general)
            guard control.showSettingsCategory("appearance"), let content = control.window?.contentView else { throw PetError("外观设置不可见") }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let previews = descendants(content).compactMap { $0 as? AgentThemePreviewButton }
            checks["appearanceHasFourAccessiblePreviewControls"] = previews.count == 4 && previews.allSatisfy { $0.accessibilityLabel() == $0.style.title + "主题" }
            checks["previewCoordinatesMatchWindowAndGradientDirection"] = previews.count == 4 && previews.allSatisfy { !$0.isFlipped }
            for size in [NSSize(width: 1200, height: 774), NSSize(width: 780, height: 540)] {
                control.window?.setFrame(NSRect(origin: .zero, size: size), display: false); content.layoutSubtreeIfNeeded()
                checks["previewGalleryFits-\(Int(size.width))"] = previews.count == 4 && previews.allSatisfy { let frame = $0.convert($0.bounds, to: content); return frame.minX >= 178 && frame.maxX <= size.width && frame.width >= 65 && frame.height == 112 }
            }
            guard let bee = previews.first(where: { $0.style == .bee }) else { throw PetError("蜜蜂预览不可用") }
            _ = bee.sendAction(bee.action, to: bee.target)
            checks["previewActionSavesCurrentModeOnlyAndUpdatesWindow"] = service.settings.coding == .bee && service.settings.general == .parchment && control.themeStylesReadback()["style"] as? String == "bee" && second.themeStylesReadback()["style"] as? String == "parchment"
            guard control.showSettingsCategory("modes") else { throw PetError("模式设置不可见") }
            let bindings = descendants(content).compactMap { $0 as? NSPopUpButton }.filter { $0.identifier?.rawValue.hasPrefix("theme-binding-") == true }
            guard bindings.count == 2, let generalBinding = bindings.first(where: { $0.identifier?.rawValue == "theme-binding-general" }) else { throw PetError("模式主题绑定不完整") }
            checks["modePageReflectsSameStyleSettings"] = bindings.allSatisfy { $0.titleOfSelectedItem == service.settings[$0 === generalBinding ? .general : .coding].title }
            generalBinding.selectItem(at: 0); _ = generalBinding.sendAction(generalBinding.action, to: generalBinding.target)
            checks["bindingActionUpdatesOtherWindowWithoutChangingCurrentMode"] = service.settings.general == .forest && service.settings.coding == .bee && second.themeStylesReadback()["style"] as? String == "forest" && control.themeStylesReadback()["style"] as? String == "bee"
            let bytes = try Data(contentsOf: file), saved = service.settings
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
            generalBinding.selectItem(at: 1); _ = generalBinding.sendAction(generalBinding.action, to: generalBinding.target)
            checks["readOnlySaveRestoresControlAndKeepsPaletteAndBytes"] = try service.settings == saved && generalBinding.indexOfSelectedItem == 0 && Data(contentsOf: file) == bytes && second.themeStylesReadback()["style"] as? String == "forest"
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            generalBinding.selectItem(at: 1); _ = generalBinding.sendAction(generalBinding.action, to: generalBinding.target)
            checks["sameControlRetriesAfterPermissionReturns"] = service.settings.general == .mint && second.themeStylesReadback()["style"] as? String == "mint"
            checks["savedStylesReloadExactlyAndPrivately"] = try AgentThemeStyles(directory: store.directory).settings == service.settings && (FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600
            let beforeConflict = service.settings; var external = beforeConflict; external.general = .bee
            let externalBytes = try encoder.encode(external); try externalBytes.write(to: file)
            var refused = false; do { try service.save(saved) } catch { refused = true }
            checks["externalEditCannotBeOverwrittenByStaleStyles"] = try refused && service.settings == beforeConflict && Data(contentsOf: file) == externalBytes
            service.reload(); service.publish()
            checks["explicitReloadUpdatesBothControlsAndExistingWindows"] = service.error == nil && service.settings == external && generalBinding.indexOfSelectedItem == 2 && second.themeStylesReadback()["style"] as? String == "bee"
            let base = try JSONSerialization.jsonObject(with: encoder.encode(AgentThemeStyles.Settings())) as! [String: Any]
            for label in ["version", "missing", "extra", "style", "type"] {
                var invalid = base
                switch label { case "version": invalid["version"] = 2; case "missing": invalid.removeValue(forKey: "general"); case "extra": invalid["extra"] = true; case "style": invalid["coding"] = "unknown"; default: invalid["general"] = true }
                let directory = output.appendingPathComponent("invalid-" + label); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let target = directory.appendingPathComponent("theme-styles.json"), data = try JSONSerialization.data(withJSONObject: invalid); try data.write(to: target)
                let guarded = AgentThemeStyles(directory: directory); refused = false; do { try guarded.save(AgentThemeStyles.Settings()) } catch { refused = true }
                checks["invalid-" + label + "PreservesBytesAndRefusesSave"] = try guarded.error != nil && refused && Data(contentsOf: target) == data
            }
            let linked = output.appendingPathComponent("linked"); try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("theme-styles.json"), withDestinationURL: file)
            checks["symbolicLinkStylesAreRejected"] = AgentThemeStyles(directory: linked).error != nil
            // Brightness is the only deliberate old-file edit above. Mode display
            // preferences and all existing task/model fields remain untouched.
            checks["legacyModeFileRemainsByteIdentical"] = (try? Data(contentsOf: store.directory.appendingPathComponent(oldFiles[1]))) == oldBytes[1]
            let brightnessBytes = try Data(contentsOf: store.directory.appendingPathComponent(oldFiles[0]))
            let brightnessKeys = try JSONSerialization.jsonObject(with: brightnessBytes) as! [String: Any]
            checks["legacyAppearanceSchemaRemainsUnchanged"] = Set(brightnessKeys.keys) == ["version", "theme", "textSize"]
            checks["styleActionsKeepBrightnessFileByteIdentical"] = brightnessBytes == brightnessBeforeStyleActions
            checks["allOriginalTasksAndModelPreferencesPreserved"] = try [coding, general].map { try encoder.encode(tasks.task($0)!) } == originals && encoder.encode(store.preferences) == preferences
            report["windowColors"] = captures; report["contrastRatios"] = ratios
            report["success"] = checks.count >= 45 && checks.values.allSatisfy { $0 }
        } catch { report["error"] = error.localizedDescription; report["success"] = false }
        report["checks"] = checks; report["modelRequests"] = requests; report["appPID"] = getpid()
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("theme-styles-report.json"))
    }
}
