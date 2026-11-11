import AppKit

@MainActor extension AppDelegate {
    func prepareAppearanceUI(_ output: URL, tasks: AgentStore, runtime: AgentRuntime, taskID: String) async throws {
        guard let path = tasks.task(taskID)?.workspace else { throw PetError("缺少外观验收项目") }
        let project = URL(fileURLWithPath: path), scratch = output.appendingPathComponent("appearance-git")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        let readme = project.appendingPathComponent("README.md")
        let original = """
        # 外观验收

        这份公开文档用于检查标题、正文、代码和表格。

        | 页面 | 状态 |
        | --- | --- |
        | 设置 | 页内编辑 |
        | 任务 | 保留草稿 |

        ```swift
        let theme = "light"
        ```

        """
        try Data(original.utf8).write(to: readme)
        for arguments in [["init", "-b", "main"], ["config", "core.excludesFile", "/dev/null"], ["add", "--", "README.md", "AGENTS.md"], ["-c", "user.name=Appearance Acceptance", "-c", "user.email=check@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "public appearance fixture"]] {
            let result = try await AgentCommand().run(command: try AgentGit.executablePath(), workspace: project, scratch: scratch, network: false, timeout: 15, gitDirectory: project.appendingPathComponent(".git"), gitWrite: true, arguments: arguments)
            guard !result.failed else { throw PetError("外观验收 Git 项目未准备完成") }
        }
        let updated = original.replacingOccurrences(of: "let theme = \"light\"", with: "let theme = \"light-and-dark\"") + "\n浅色与深色使用同一份公开文档。\n"
        try Data(updated.utf8).write(to: readme)
        guard runtime.submit("公开的中文🧭字号验收：这是一条未调用模型的用户消息。", taskID: taskID, startImmediately: false) else { throw PetError(runtime.submissionError ?? "公开用户消息未保存") }
        tasks.update(taskID) { $0.artifacts = [readme.path]; $0.draft = "切换外观前保留的未发送草稿。" }
        let result: [String: Any] = ["taskID": taskID, "readme": readme.path, "readmeHash": AgentFiles.hash(Data(updated.utf8)), "originalReadmeHash": AgentFiles.hash(Data(original.utf8)), "modelRequests": 0]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("appearance-fixtures.json"))
    }

    func runAppearanceCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        do {
            ensureAgent(); agentRuntime?.modelRequestCheck = { requests += 1; throw PetError("外观验收禁止模型请求") }
            guard let tasks = agentStore else { throw PetError("缺少独立任务存储") }
            let taskID = tasks.create(title: "外观选择验收"); control.showAgentTask(taskID)
            let file = store.directory.appendingPathComponent("appearance.json")
            let preferenceEncoder = JSONEncoder(); preferenceEncoder.outputFormatting = [.sortedKeys]
            let preferences = try preferenceEncoder.encode(store.preferences)
            let originalFiles = ["settings.json", "history.json"].map { try? Data(contentsOf: store.directory.appendingPathComponent($0)) }
            checks["missingAppearanceUsesSystemWithoutRewritingPreferences"] = appearance.settings == AgentAppearance.Settings() && !FileManager.default.fileExists(atPath: file.path)
            let second = ControlWindow(companion: self, taskID: taskID, windowNumber: 2); additionalTaskWindows.append(second)
            let sample = "公开的中文🧭字号验收。", row = ChatMessageRow(message: ChatMessage(role: "user", content: "公开的中文🧭字号验收。"), workbench: true)
            row.update(sample, searchQuery: "字号"); let originalRange = row.searchRange
            func resolved(_ color: NSColor, in appearance: NSAppearance) -> [CGFloat] {
                var result: [CGFloat] = []
                appearance.performAsCurrentDrawingAppearance { if let value = color.usingColorSpace(.sRGB) { result = [value.redComponent, value.greenComponent, value.blueComponent, value.alphaComponent] } }
                return result
            }
            func luminance(_ rgb: [CGFloat]) -> CGFloat {
                zip(rgb.prefix(3), [CGFloat(0.2126), 0.7152, 0.0722]).reduce(0) { value, channel in
                    let linear = channel.0 <= 0.04045 ? channel.0 / 12.92 : pow((channel.0 + 0.055) / 1.055, 2.4)
                    return value + linear * channel.1
                }
            }
            func contrast(_ foreground: NSColor, _ background: NSColor, _ look: NSAppearance) -> CGFloat {
                let front = resolved(foreground, in: look), back = resolved(background, in: look)
                guard front.count == 4, back.count == 4 else { return 0 }
                let composed = (0..<3).map { front[$0] * front[3] + back[$0] * (1 - front[3]) }
                let a = luminance(composed), b = luminance(back)
                return (max(a, b) + 0.05) / (min(a, b) + 0.05)
            }
            var colors: [String: [CGFloat]] = [:], contrasts: [String: [String: CGFloat]] = [:], selections: [String: [[CGFloat]]] = [:]
            for theme in [AgentTheme.light, .dark] {
                var value = appearance.settings; value.theme = theme; value.textSize = 16
                try appearance.save(value); await wait(0.03)
                let expected: NSAppearance.Name = theme == .dark ? .darkAqua : .aqua
                checks[theme.rawValue + "PropagatesToBothExistingTaskWindows"] = [control, second].allSatisfy { $0.window?.appearance == nil && $0.window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected }
                let selection = resolved(AgentWorkbenchTheme.selection, in: control.window!.effectiveAppearance)
                let actualSelections = [control, second].map { $0.checkAppearanceSelectionColor() ?? [] }; selections[theme.rawValue] = actualSelections
                checks[theme.rawValue + "ActualSelectedTaskLayersMatchBothWindows"] = actualSelections.allSatisfy { actual in
                    actual.count == 4 && zip(actual, selection).allSatisfy { abs($0 - $1) < 0.0001 }
                }
                let manager = AgentProfileWindow(store: agentStore!, workspace: nil)
                checks[theme.rawValue + "NewManagementWindowInheritsApplication"] = manager.window?.appearance == nil && manager.window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected
                let alert = NSAlert(); alert.messageText = "外观确认验收"
                checks[theme.rawValue + "ConfirmationInheritsApplication"] = alert.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected
                guard let look = control.window?.effectiveAppearance else { throw PetError("缺少实际窗口外观") }
                let values = ["body": contrast(.labelColor, AgentWorkbenchTheme.surface, look), "sidebarSecondary": contrast(AgentWorkbenchTheme.secondaryText, AgentWorkbenchTheme.sidebar, look), "selectedSecondary": contrast(AgentWorkbenchTheme.secondaryText, AgentWorkbenchTheme.selection, look), "primaryAction": contrast(AgentWorkbenchTheme.primaryText, AgentWorkbenchTheme.primary, look), "sendAction": contrast(AgentWorkbenchTheme.accentText, AgentWorkbenchTheme.accent, look)]
                checks[theme.rawValue + "TextAndActionContrast"] = values.values.allSatisfy { $0 >= 4.5 }; contrasts[theme.rawValue] = values
                let view = AgentThemeView(fill: AgentWorkbenchTheme.surface, stroke: AgentWorkbenchTheme.line)
                manager.window?.contentView = view; view.updateLayer()
                colors[theme.rawValue] = resolved(AgentWorkbenchTheme.surface, in: look)
                let layerColor = view.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)).map { resolved($0, in: look) } ?? []
                checks[theme.rawValue + "LayerUsesActualInheritedAppearance"] = layerColor.count == 4 && zip(layerColor, colors[theme.rawValue] ?? []).allSatisfy { abs($0 - $1) < 0.0001 }
                manager.close()
            }
            checks["LightAndDarkSurfacesActuallyDiffer"] = colors["light"] != colors["dark"]
            var large = appearance.settings; large.textSize = 18; try appearance.save(large)
            row.refreshAppearance()
            checks["ChangingTextSizeUpdatesExistingMessage"] = (row.label.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 18
            checks["ChangingTextSizePreservesSourceAndSearchRange"] = row.text == sample && row.searchRange == originalRange && row.label.stringValue == sample
            checks.merge(control.checkAppearanceLayout()) { _, value in value }
            checks["SecondWindowComposerReceivesTextSize"] = second.checkAppearanceComposerSize() == 18
            let loaded = AgentAppearance(directory: store.directory)
            checks["SavedThemeAndTextSizeReloadExactly"] = loaded.error == nil && loaded.settings == large
            checks["AppearanceFileUsesPrivatePermissions"] = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600
            var external = large; external.theme = .light
            let changed = try JSONEncoder().encode(external); try changed.write(to: file)
            var rejected = false
            do { try appearance.save(large) } catch { rejected = true }
            let afterConflict = try Data(contentsOf: file)
            checks["ExternalEditIsPreservedAndSaveRejected"] = rejected && afterConflict == changed && appearance.settings == large
            appearance.reload(); appearance.apply()
            checks["ReloadAcceptsExternalConfiguration"] = appearance.error == nil && appearance.settings == external
            var system = appearance.settings; system.theme = .system; try appearance.save(system)
            checks["SystemThemeClearsApplicationOverride"] = NSApp.appearance == nil
            for (name, content) in [("invalid-size", "{\"version\":1,\"theme\":\"dark\",\"textSize\":200}"), ("unknown-version", "{\"version\":2,\"theme\":\"light\",\"textSize\":14}"), ("unknown-field", "{\"version\":1,\"theme\":\"light\",\"textSize\":14,\"future\":true}")] {
                let directory = output.appendingPathComponent(name); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let target = directory.appendingPathComponent("appearance.json"), bytes = Data(content.utf8); try bytes.write(to: target)
                let invalid = AgentAppearance(directory: directory); var refused = false
                do { try invalid.save(AgentAppearance.Settings()) } catch { refused = true }
                let after = try Data(contentsOf: target)
                checks[name + "RemainsUnmodified"] = refused && invalid.error != nil && after == bytes
            }
            let linked = output.appendingPathComponent("linked"); try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("appearance.json"), withDestinationURL: file)
            let guarded = AgentAppearance(directory: linked)
            checks["SymlinkAppearanceIsRejected"] = guarded.error != nil
            checks["ModelAndHistoryBytesUnchanged"] = try preferenceEncoder.encode(store.preferences) == preferences && ["settings.json", "history.json"].map { try? Data(contentsOf: store.directory.appendingPathComponent($0)) } == originalFiles
            report["resolvedSurfaces"] = colors; report["contrastRatios"] = contrasts; report["actualSelectedTaskLayerColors"] = selections
            report["success"] = checks.count >= 20 && checks.values.allSatisfy { $0 }
        } catch { report["error"] = error.localizedDescription; report["success"] = false }
        report["checks"] = checks; report["modelRequests"] = requests; report["appPID"] = getpid()
        try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("appearance-report.json"))
    }
}
