import AppKit

@MainActor extension AppDelegate {
    func prepareFileIconsUI(_ output: URL) async throws -> String {
        guard !CommandLine.arguments.contains("--live-agent"), !CommandLine.arguments.contains("--attention-live-ui"), let tasks = agentStore else { throw PetError("文件图标验收只使用独立本地资料") }
        let project: URL, id: String
        if let selected = tasks.selectedID, let workspace = tasks.task(selected)?.workspace { project = URL(fileURLWithPath: workspace); id = selected }
        else {
            project = output.appendingPathComponent("file-icon-project"); try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
            id = tasks.create(title: "文件图标验收", workspace: project.path)
        }
        let files = try AgentFiles(workspace: project.path)
        let sample = "# 文件引用\n\n[Main.swift](Main.swift)、[package.json](package.json) 和 [README.md](README.md)。\n\n[公开网页](https://example.com)\n"
        for (name, text) in ["FILES.md": sample, "Main.swift": "let message = \"本地文件图标验收\"\n", "package.json": "{\"name\":\"file-icon-check\",\"private\":true}\n"] { try files.writeData(Data(text.utf8), to: files.resolve(name)) }
        if !FileManager.default.fileExists(atPath: project.appendingPathComponent("README.md").path) { try files.writeData(Data("# 公开本地文档\n".utf8), to: files.resolve("README.md")) }
        for name in ["Main.swift", "package.json"] { _ = try await AgentAttachments.importFile(files.resolve(name), store: tasks, taskID: id) }
        tasks.update(id) {
            $0.messages = [AgentMessage(role: "user", content: "查看本地文件图标"), AgentMessage(role: "assistant", content: "本地验收样例文件：Main.swift、package.json 和 FILES.md。")]
            $0.artifacts = ["FILES.md", "Main.swift", "package.json"].map { project.appendingPathComponent($0).path }
            $0.sources = [project.appendingPathComponent("README.md").absoluteString]; $0.draft = "保留中文 English 🧭 文件图标草稿"
        }
        try JSONSerialization.data(withJSONObject: ["taskID": id, "workspace": project.path, "modelRequests": 0], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("file-icons-fixtures.json"))
        control.showAgentTask(id); return id
    }

    func runFileIconsCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0, documentToReload: AgentRecordWindow?
        defer { documentToReload?.checkReloadDocument(); agentRuntime?.stopAll() }
        do {
            ensureAgent(); guard usesAgent, let tasks = agentStore, let runtime = agentRuntime else { throw PetError("文件图标验收未进入独立工作台") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("文件图标验收禁止模型请求") }
            let id = try await prepareFileIconsUI(output), service = fileIcons, file = store.directory.appendingPathComponent("file-icons.json")
            let secondID = tasks.create(title: "通用文件图标", mode: .ask, workMode: .general)
            tasks.update(secondID) { $0.draft = "保留通用任务草稿" }
            let second = ControlWindow(companion: self, taskID: secondID, windowNumber: 2); additionalTaskWindows.append(second)
            checks["MissingSettingsDefaultWithoutWriting"] = service.error == nil && service.settings == AgentFileIcons.Settings() && !FileManager.default.fileExists(atPath: file.path)
            guard let catalog = AgentFileIcons.catalog, let catalogURL = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "file-icons") else { throw PetError("缺少打包图标") }
            let provenance = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL.deletingLastPathComponent().appendingPathComponent("SOURCE.json"))) as? [String: Any]
            checks["BundledCatalogMatchesPinnedSourceAndLicenses"] = try catalog.icons.count == 377 && catalog.files.count == 911 && catalog.extensions.count == 924 && provenance?["catalogSHA256"] as? String == AgentFiles.hash(Data(contentsOf: catalogURL)) && ["Material-File-Icons-LICENSE.txt", "Material-Icon-Theme-LICENSE.txt"].allSatisfy { (try? String(contentsOf: catalogURL.deletingLastPathComponent().appendingPathComponent($0), encoding: .utf8).contains("Permission is hereby granted")) == true }
            func raster(_ image: NSImage?) -> String? {
                guard let image, let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32), let context = NSGraphicsContext(bitmapImageRep: bitmap), let bytes = bitmap.bitmapData else { return nil }
                bytes.initialize(repeating: 0, count: 4096); NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
                image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32)); NSGraphicsContext.restoreGraphicsState()
                guard stride(from: 3, to: 4096, by: 4).contains(where: { bytes[$0] > 0 }) else { return nil }
                return AgentFiles.hash(Data(bytes: bytes, count: 4096))
            }
            let failedImages = catalog.icons.compactMap { key, svg in raster(NSImage(data: Data(svg.utf8))) == nil ? key : nil }.sorted()
            checks["All377OriginalSVGsDecodeAndDrawNonemptyPixels"] = failedImages.isEmpty; report["failedImages"] = failedImages
            let expected = ["README.md": "readme", "Main.swift": "swift", "script.py": "python", "package.json": "nodejs", "Dockerfile": "docker", "archive.tar.gz": "zip", "foo.d.ts": "typescript-def", ".gitignore": "git", "styles.CSS": "css", "photo.png": "image", "unknown.qzx": "file", "tsconfig.json": "json"]
            checks["UpstreamFilenameLongestSuffixCaseAndFallbackMappings"] = expected.allSatisfy { AgentFileIcons.identifier("folder/" + $0.key, style: .material) == $0.value }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let oldSettings: [(String, Data)] = [("appearance.json", try encoder.encode(appearance.settings)), ("theme-styles.json", try encoder.encode(themeStyles.settings)), ("content-appearance.json", try encoder.encode(contentAppearance.settings)), ("mode-presentation.json", try encoder.encode(modePresentation.settings)), ("sidebar.json", try encoder.encode(sidebarLayout.settings))]
            for (name, bytes) in oldSettings { try bytes.write(to: store.directory.appendingPathComponent(name)) }
            let project = URL(fileURLWithPath: tasks.task(id)!.workspace!), files = try AgentFiles(workspace: project.path), documentURL = project.appendingPathComponent("FILES.md"), original = try Data(contentsOf: documentURL)
            control.showTaskDocument(documentURL.path)
            guard let editor = control.taskWorkspace.currentController as? AgentRecordWindow else { throw PetError("未进入文档标签页") }
            documentToReload = editor
            await editor.checkTaskDocument(text: String(decoding: original, as: UTF8.self) + "\n保留未保存的编辑。\n")
            let beforeEditor = await editor.workspaceReadback(), beforeTasks = try [id, secondID].map { try encoder.encode(tasks.task($0)!) }, modelPreferences = try encoder.encode(store.preferences)
            let strip = AgentAttachmentStrip(), panel = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200)), artifact = AgentInspectorFileButton(title: "Main.swift", value: project.appendingPathComponent("Main.swift").path, section: 1, symbol: "doc", inline: true)
            strip.update(tasks.task(id)?.attachments ?? [], removable: true); panel.addSubview(strip); panel.addSubview(artifact)
            var opened: String?, removed: String?; strip.onOpen = { opened = $0 }; strip.onRemove = { removed = $0 }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let buttons = descendants(strip).compactMap { $0 as? NSButton }, open = buttons.first { $0.title == "Main.swift" }
            let remove = buttons.first { $0.tag == open?.tag && $0 !== open && $0.title != "package.json" }
            let target = open?.target, action = open?.action
            let reader = AgentMarkdownReader(frame: NSRect(x: 0, y: 0, width: 600, height: 380))
            let markdown = "# [**Main**.swift](Main.swift)\n\n[Main.swift](Main.swift) [网页](https://example.com) [越界](../outside.txt) [凭据](.env)\n"
            reader.show(markdown, file: documentURL, workspace: project.path); panel.addSubview(reader); reader.text.setSelectedRange(NSRange(location: 1, length: 4))
            let initialDisplay = reader.text.string, initialSelection = reader.text.selectedRange(), heading = reader.document?.headings.first
            checks["DecorativeHeadingKeepsOriginalTitleAndAnchor"] = heading?.title == "Main.swift" && heading?.anchor == "mainswift"
            func inlineAttachments() -> [NSTextAttachment] {
                var list: [NSTextAttachment] = []; reader.text.textStorage?.enumerateAttribute(AgentFileIcons.marker, in: NSRange(location: 0, length: reader.text.string.utf16.count)) { name, range, _ in if name != nil, let attachment = reader.text.textStorage?.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment { list.append(attachment) } }; return list
            }
            let inline = inlineAttachments(), initialBounds = inline.map(\.bounds)
            checks["OneInlineIconPerValidatedLinkIncludingFormattedLabel"] = inline.count == 2 && AgentFileIcons.plainText(reader.text.attributedString()).contains("Main.swift 网页 越界 凭据")
            reader.text.setSelectedRange(NSRange(location: 0, length: reader.text.string.utf16.count))
            let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }; pasteboard.declareTypes([.string], owner: nil)
            checks["PlainTextCopyOmitsOnlyDecorativeFileIcons"] = reader.text.writeSelection(to: pasteboard, type: .string) && pasteboard.string(forType: .string) == initialDisplay.replacingOccurrences(of: "\u{FFFC}", with: "")
            let selection = AgentMarkdownSelectionAction(text: reader.text, button: NSButton()) { (documentURL, project.path) }
            checks["TaskQuotationOmitsDecorativeIconsAndKeepsVisibleText"] = try selection.selection().text == initialDisplay.replacingOccurrences(of: "\u{FFFC}", with: "")
            reader.text.setSelectedRange(initialSelection)
            var safeLinks = 0, unsafeLinks = 0
            reader.text.textStorage?.enumerateAttribute(.link, in: NSRange(location: 0, length: reader.text.string.utf16.count)) { value, _, _ in if let url = value as? URL { if url.isFileURL { safeLinks += 1 }; if url.path.contains("outside") || url.path.contains(".env") { unsafeLinks += 1 } } }
            checks["FileLinkTargetsStayValidatedWithoutGrantingUnsafeActions"] = safeLinks == 2 && unsafeLinks == 0 && inline.allSatisfy { attachment in
                var safe = false
                reader.text.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: reader.text.string.utf16.count)) { value, range, _ in if value as? NSTextAttachment === attachment, let url = reader.text.textStorage?.attribute(.link, at: range.location, effectiveRange: nil) as? URL { safe = url == project.appendingPathComponent("Main.swift") } }; return safe
            }
            let folder = NSImageView(); panel.addSubview(folder); AgentFileIcons.bind(folder, filename: "Main.swift"); AgentFileIcons.unbind(folder); folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil); let folderImage = folder.image
            let wiki = AgentWikiTree(frame: NSRect(x: 0, y: 0, width: 260, height: 300)), wikiHost = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            wikiHost.isReleasedWhenClosed = false; wikiHost.contentView = wiki; defer { wikiHost.close() }
            wiki.show([AgentWikiPage(path: ".bluefatfish/wiki/index.md", title: "首页")], selected: nil); wiki.layoutSubtreeIfNeeded()
            guard let outline = descendants(wiki).compactMap({ $0 as? NSOutlineView }).first, let cell = outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView else { throw PetError("Wiki 文件行未创建") }
            var metrics: [String: Any] = [:], buttonHashes: [String: String] = [:], inlineHashes: [String: String] = [:]
            for style in AgentFileIconStyle.allCases {
                var value = service.settings; value.style = style; try service.save(value)
                let icons = AgentFileIcons.readback(in: panel), bound = icons["views"] as? [[String: Any]] ?? [], states = [control, second].map { $0.fileIconsReadback() }
                checks[style.rawValue + "RefreshesExistingAttachmentArtifactAndInlineImages"] = bound.count == 3 && bound.allSatisfy { ($0["imageHash"] as? String)?.isEmpty == false } && inline.allSatisfy { raster($0.image) != nil } && states.allSatisfy { $0["style"] as? String == style.rawValue }
                checks[style.rawValue + "KeepsLinkRangesSelectionBoundsAndFolderIdentity"] = reader.text.string == initialDisplay && reader.text.selectedRange() == initialSelection && inline.map(\.bounds) == initialBounds && folder.image === folderImage
                checks[style.rawValue + "RefreshesExistingWikiFileCell"] = cell.imageView?.image === AgentFileIcons.image("index.md") && cell.textField?.stringValue == "首页" && raster(cell.imageView?.image) != nil
                let state = await editor.workspaceReadback()
                checks[style.rawValue + "KeepsDocumentControllerUnsavedBytesAndTaskDrafts"] = control.taskWorkspace.currentController === editor && state["draftHash"] as? String == beforeEditor["draftHash"] as? String && state["dirty"] as? Bool == true && tasks.task(id)?.draft == "保留中文 English 🧭 文件图标草稿" && tasks.task(secondID)?.draft == "保留通用任务草稿"
                checks[style.rawValue + "RefreshesActualDocumentTabWithFileImage"] = (control.fileIconsReadback()["views"] as? [[String: Any]] ?? []).contains { $0["name"] as? String == "FILES.md" && ($0["label"] as? String)?.contains("FILES.md") == true && ($0["imageHash"] as? String)?.isEmpty == false }
                buttonHashes[style.rawValue] = raster(open?.image); inlineHashes[style.rawValue] = raster(inline.first?.image); metrics[style.rawValue] = icons
            }
            checks["TwoStylesProduceDifferentActualButtonAndInlinePixels"] = buttonHashes["native"] != nil && buttonHashes["material"] != nil && buttonHashes["native"] != buttonHashes["material"] && inlineHashes["native"] != inlineHashes["material"]
            _ = open?.sendAction(open?.action, to: open?.target); _ = remove?.sendAction(remove?.action, to: remove?.target)
            report["attachmentActions"] = ["opened": opened ?? "", "removed": removed ?? "", "buttons": buttons.map { ["title": $0.title, "tag": $0.tag, "action": $0.action.map(NSStringFromSelector) ?? ""] }]
            checks["ExistingAttachmentOpenRemoveActionsAndTargetsRemainExact"] = open?.target === target && open?.action == action && opened == tasks.task(id)?.attachments?.first(where: { $0.name == "Main.swift" })?.id && removed == opened
            checks["UnwrittenDocumentBytesRemainExact"] = try Data(contentsOf: documentURL) == original
            guard control.showSettingsCategory("appearance"), let content = control.window?.contentView, let choice = descendants(content).compactMap({ $0 as? NSPopUpButton }).first(where: { $0.identifier?.rawValue == "file-icon-style" }) else { throw PetError("缺少文件图标实际设置控件") }
            checks["AccessibleSettingsExposeBothSavedChoices"] = choice.accessibilityLabel() == "文件图标" && choice.itemTitles == ["小鲸", "Material File Icons"] && choice.indexOfSelectedItem == 1
            for width in [1200, 780] { control.window?.setFrame(NSRect(x: 0, y: 0, width: width, height: width == 780 ? 540 : 774), display: false); content.layoutSubtreeIfNeeded(); let rect = choice.convert(choice.bounds, to: content); checks["SettingsFit-" + String(width)] = rect.minX >= 178 && rect.maxX <= CGFloat(width) && rect.width == 180 }
            let responder = control.window?.firstResponder
            choice.selectItem(at: 0); _ = choice.sendAction(choice.action, to: choice.target)
            checks["ActualSettingsActionAppliesWithoutMovingFocus"] = service.settings.style == .native && control.window?.firstResponder === responder && second.fileIconsReadback()["style"] as? String == "native"
            var value = service.settings; value.style = .material; try service.save(value)
            let bytes = try Data(contentsOf: file), saved = service.settings
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
            choice.selectItem(at: 0); _ = choice.sendAction(choice.action, to: choice.target)
            checks["ReadOnlyRestoresChoiceAndPreservesExistingStyleAndBytes"] = try choice.indexOfSelectedItem == 1 && service.settings == saved && Data(contentsOf: file) == bytes && AgentFileIcons.style == .material
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            choice.selectItem(at: 0); _ = choice.sendAction(choice.action, to: choice.target)
            checks["SameControlCanSaveAfterPermissionReturns"] = service.settings.style == .native && AgentFileIcons.style == .native
            checks["PreferencesReloadExactlyAndPrivately"] = try AgentFileIcons(directory: store.directory).settings == service.settings && (FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600
            var external = service.settings; external.style = .material; let externalBytes = try encoder.encode(external); try externalBytes.write(to: file)
            var attempted = service.settings; attempted.style = .material; var refused = false
            do { try service.save(attempted) } catch { refused = true }
            checks["StaleSettingsCannotOverwriteExternalEdit"] = try refused && service.settings.style == .native && Data(contentsOf: file) == externalBytes
            service.reload(); service.apply(); checks["ExplicitReloadUpdatesExistingControls"] = service.error == nil && service.settings.style == .material && choice.indexOfSelectedItem == 1
            let base: [String: Any] = ["version": 1, "style": "native"]
            for label in ["version", "missing", "extra", "style", "type"] {
                var invalid = base
                switch label { case "version": invalid["version"] = 2; case "missing": invalid.removeValue(forKey: "style"); case "extra": invalid["extra"] = true; case "style": invalid["style"] = "unknown"; default: invalid["style"] = true }
                let directory = output.appendingPathComponent("invalid-" + label); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let target = directory.appendingPathComponent("file-icons.json"), data = try JSONSerialization.data(withJSONObject: invalid); try data.write(to: target)
                let guarded = AgentFileIcons(directory: directory); refused = false; do { try guarded.save(AgentFileIcons.Settings()) } catch { refused = true }
                checks["Invalid-" + label + "PreservesBytesAndRefusesSave"] = try guarded.error != nil && refused && Data(contentsOf: target) == data
            }
            let linked = output.appendingPathComponent("linked"); try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: false); try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("file-icons.json"), withDestinationURL: file)
            checks["SymbolicLinkConfigurationIsRejected"] = AgentFileIcons(directory: linked).error != nil
            checks["AllFiveLegacySettingsRemainByteExact"] = oldSettings.allSatisfy { (try? Data(contentsOf: store.directory.appendingPathComponent($0.0))) == $0.1 }
            editor.checkReloadDocument(); checks["CheckCleanupRestoresUnwrittenSampleWithoutChangingDisk"] = try !editor.workspaceHasUnsavedChanges && Data(contentsOf: documentURL) == original
            checks["AllOriginalTaskFieldsAndModelPreferencesRemainExact"] = try [id, secondID].map { try encoder.encode(tasks.task($0)!) } == beforeTasks && encoder.encode(store.preferences) == modelPreferences
            report["metrics"] = metrics; report["buttonHashes"] = buttonHashes; report["inlineHashes"] = inlineHashes; report["success"] = checks.count >= 30 && checks.values.allSatisfy { $0 }
        } catch { report["error"] = error.localizedDescription; report["success"] = false }
        report["checks"] = checks; report["modelRequests"] = requests; report["appPID"] = getpid()
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("file-icons-report.json"))
    }
}
