import AppKit

@MainActor extension AppDelegate {
    private struct NavigationFixture: Codable {
        var windows: [String: String], tasks: [String: String]
        var global: AgentSettingsRecovery.Navigation, hooks: AgentSettingsRecovery.Navigation, back: AgentSettingsRecovery.Navigation
        var searchReturn: AgentSettingsRecovery.SearchReturn?
    }

    func runSettingsNavigationRecoveryCheck(_ output: URL, interactive: Bool = false) async {
        let args = CommandLine.arguments
        let stage = args.firstIndex(of: "--recovery-stage").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "seed"
        let fixtureURL = output.appendingPathComponent("navigation-fixture.json")
        let body = "{\n\"公开的未完成 Hooks 草稿 中文😀\""
        var checks: [String: Bool] = [:], requests = 0, failure: String?
        func find<T: NSView>(_ view: NSView?, _ type: T.Type, _ match: (T) -> Bool) -> T? {
            guard let view else { return nil }
            if let control = view as? T, !control.isHiddenOrHasHiddenAncestor, match(control) { return control }
            for child in view.subviews {
                if let control = find(child, type, match) { return control }
            }
            return nil
        }
        func button(_ owner: ControlWindow, _ title: String) throws -> NSButton {
            guard let control = find(owner.window?.contentView, NSButton.self, { $0.title == title && $0.isEnabled }) else {
                throw PetError("设置恢复缺少操作 " + title)
            }
            return control
        }
        do {
            ensureAgent()
            guard let store = agentStore, let runtime = agentRuntime,
                  store.extensions.sharedHome?.standardizedFileURL == output.appendingPathComponent("shared-home").standardizedFileURL else {
                throw PetError("设置搜索验收只允许独立目录")
            }
            runtime.modelRequestCheck = { requests += 1; throw PetError("设置搜索验收禁止模型请求") }
            store.automations.start(store: store, runtime: runtime)
            if stage == "seed" {
                let hookTask = try await prepareSettingsPagesCheck(output, tasks: store)
                let globalTask = store.create(title: "设置恢复 · 全局搜索")
                let backTask = store.create(title: "设置恢复 · 返回自动化")
                store.update(hookTask) { $0.title = "设置恢复 · 原编辑器"; $0.draft = "PUBLIC_HOOKS_COMPOSER" }
                store.update(globalTask) { $0.draft = "PUBLIC_GLOBAL_COMPOSER" }
                store.update(backTask) { $0.draft = "PUBLIC_BACK_COMPOSER" }
                control.showAgentTask(globalTask)
                guard control.showSettingsCategory("appearance") else { throw PetError("无法打开外观设置") }
                try control.checkSettingsNavigationSearch("模型", selection: NSRange(location: 1, length: 1))

                openTaskWindow(hookTask, from: control)
                guard let hooks = additionalTaskWindows.last, hooks.showSettingsCategory("hooks") else { throw PetError("无法打开 Hooks 设置") }
                guard let scope = find(hooks.window?.contentView, NSPopUpButton.self, { $0.accessibilityLabel() == "Hooks 配置范围" }),
                      let changeScope = scope.action else { throw PetError("无法选择项目 Hooks 范围") }
                scope.selectItem(withTitle: "当前项目")
                NSApp.sendAction(changeScope, to: scope.target, from: scope)
                try button(hooks, "编辑配置").performClick(nil)
                guard let hookEdit = find(hooks.window?.contentView, NSTextView.self, { $0.accessibilityLabel() == "Hooks JSON 配置" }) else {
                    throw PetError("无法进入原 Hooks 编辑器")
                }
                hookEdit.string = body; hookEdit.didChangeText()
                hooks.window?.makeFirstResponder(hookEdit)
                hookEdit.setSelectedRange((body as NSString).range(of: "中文😀"))
                if !interactive, let window = hooks.window {
                    window.setFrame(NSRect(origin: window.frame.origin, size: .init(width: 780, height: 540)), display: true)
                }
                try hooks.checkSettingsNavigationSearch("任务", focusLastResult: true)

                openTaskWindow(backTask, from: control)
                guard let back = additionalTaskWindows.last else { throw PetError("无法打开返回路径验收窗口") }
                back.showAutomations()
                guard back.automationWindow?.isVisible == true, back.showSettingsCategory("shortcuts") else { throw PetError("自动化返回路径不可用") }
                try back.checkSettingsNavigationSearch("任务", selection: NSRange(location: 1, length: 1))
                guard let result = find(back.window?.contentView, NSButton.self, { $0.accessibilityLabel() == "打开设置：快捷键 · 新的任务" }) else {
                    throw PetError("缺少快捷键搜索结果")
                }
                result.performClick(nil)
                if !interactive {
                    guard let window = back.window else { throw PetError("缺少设置分类验收窗口") }
                    window.setContentSize(NSSize(width: 780, height: 540)); window.contentView?.layoutSubtreeIfNeeded()
                    guard let scroll = find(window.contentView, NSScrollView.self, { $0.accessibilityLabel() == "设置分类" }),
                          let document = scroll.documentView else { throw PetError("缺少设置分类滚动区") }
                    let clip = scroll.contentView
                    clip.scroll(to: clip.constrainBoundsRect(NSRect(x: 0, y: document.bounds.height, width: clip.bounds.width, height: clip.bounds.height)).origin)
                    scroll.reflectScrolledClipView(clip)
                }
                guard await flushWorkspaceWindows(), let a = control.workspaceSession?.id, let b = hooks.workspaceSession?.id, let c = back.workspaceSession?.id,
                      let global = control.captureSettingsNavigation(), let scoped = hooks.captureSettingsNavigation(), let noQuery = back.captureSettingsNavigation() else {
                    throw PetError("设置导航记录不完整")
                }
                checks["plainSearchSelectionCheckpointed"] = global.query == "模型" && global.focus == "search" && global.selection?.range == NSRange(location: 1, length: 1)
                checks["searchDoesNotReplaceHiddenDraft"] = try hooks.captureSettingsRecovery()?.pages.map(\.kind) == ["hooks", "hook-config"] &&
                    !scoped.query.isEmpty && scoped.focus != nil && scoped.focus != "search" && scoped.resultVisible == true
                checks["resultListCanActuallyScroll"] = interactive || scoped.contentY > 0
                checks["returnRouteRecordedWithoutSearch"] = noQuery.query.isEmpty && noQuery.category == "shortcuts" && noQuery.returnTab == "automation"
                checks["manualSidebarPositionCheckpointed"] = interactive || noQuery.sidebarY > 0
                let searchReturn = back.captureSettingsSearchReturn()
                checks["searchOriginRecordedAlongsideItsOpenedSettings"] = searchReturn?.query == "任务" && searchReturn?.selection?.range == NSRange(location: 1, length: 1)
                let fixture = NavigationFixture(windows: ["global":a, "hooks":b, "back":c], tasks: ["global":globalTask, "hooks":hookTask, "back":backTask],
                    global: global, hooks: scoped, back: noQuery, searchReturn: searchReturn)
                try JSONEncoder().encode(fixture).write(to: fixtureURL, options: .atomic)
            } else {
                let fixture = try JSONDecoder().decode(NavigationFixture.self, from: Data(contentsOf: fixtureURL))
                restoreAdditionalWorkspaceWindows()
                guard await flushWorkspaceWindows() else { throw PetError("设置导航未恢复完成") }
                func window(_ role: String) throws -> ControlWindow {
                    guard let result = taskControls.first(where: { $0.workspaceSession?.id == fixture.windows[role] && $0.agentTaskID == fixture.tasks[role] }) else {
                        throw PetError("未恢复原设置窗口 " + role)
                    }
                    return result
                }
                let global = try window("global"), hooks = try window("hooks"), back = try window("back")
                checks["originalTasksAndInputsRemain"] = fixture.tasks.allSatisfy {
                    store.task($0.value)?.draft == "PUBLIC_" + $0.key.uppercased() + "_COMPOSER" && store.task($0.value)?.messages.isEmpty == true
                }
                if stage == "unavailable" {
                    checks["originalProjectMayBeUnavailableWithoutRedirectingItsDraft"] = hooks.workspaceSession?.pendingSettingsCategory == "hooks" &&
                        hooks.captureSettingsNavigation() == nil && hooks.settingsRecoveryControllers.isEmpty
                    checks["otherWindowSearchStillRestores"] = global.captureSettingsNavigation()?.query == fixture.global.query &&
                        back.captureSettingsNavigation()?.returnTab == "automation"
                } else if stage == "closed" {
                    checks["explicitBackDoesNotReopenSettings"] = global.captureSettingsNavigation() == nil && back.captureSettingsNavigation() == nil
                    let journal = AgentWorkspaceRecovery(profile: store.directory)
                    checks["returnedSearchOriginDoesNotReappear"] = try back.captureSettingsSearchReturn() == nil &&
                        journal.loadSettingsSearchReturn(windowID: fixture.windows["back"]!)?.value.origin == nil
                    checks["clearedSearchDoesNotReappearOverDraft"] = hooks.captureSettingsNavigation()?.query.isEmpty == true &&
                        find(hooks.window?.contentView, NSTextView.self, { $0.accessibilityLabel() == "Hooks JSON 配置" })?.string == body
                } else {
                    global.window?.makeKeyAndOrderFront(nil); await wait(0.14)
                    let general = global.captureSettingsNavigation()
                    checks["restoresSearchAndSelectionInPlainSettings"] = general?.query == fixture.global.query && general?.selection == fixture.global.selection &&
                        general?.focus == "search" && general?.category == fixture.global.category
                    hooks.window?.makeKeyAndOrderFront(nil); await wait(0.14)
                    let scoped = hooks.captureSettingsNavigation()
                    checks["restoresExactResultFocusAndViewport"] = scoped?.query == fixture.hooks.query && scoped?.focus == fixture.hooks.focus &&
                        scoped?.resultVisible == true && (interactive || abs((scoped?.contentY ?? 0) - fixture.hooks.contentY) <= 1)
                    checks["restoredSearchOverlaysOriginalHooksEditor"] = try hooks.captureSettingsRecovery()?.pages.map(\.kind) == ["hooks", "hook-config"] &&
                        find(hooks.window?.contentView, NSTextView.self, { $0.accessibilityLabel() == "Hooks JSON 配置" }) == nil
                    checks["restoresUnfilteredCategoryAndReturnRoute"] = back.captureSettingsNavigation()?.category == "shortcuts" &&
                        back.captureSettingsNavigation()?.returnTab == "automation" && back.automationWindow == nil
                    checks["restoresManualSidebarPositionWithOriginalCategory"] = interactive ||
                        abs((back.captureSettingsNavigation()?.sidebarY ?? 0) - fixture.back.sidebarY) < 0.5
                    checks["onlyOriginalWindowRestoresSearchReturnRoute"] = fixture.searchReturn != nil && back.captureSettingsSearchReturn() == fixture.searchReturn &&
                        global.captureSettingsSearchReturn() == nil && hooks.captureSettingsSearchReturn() == nil
                    if !interactive {
                        try hooks.checkSettingsNavigationSearch(""); await wait(0.1)
                        guard let editor = find(hooks.window?.contentView, NSTextView.self, { $0.accessibilityLabel() == "Hooks JSON 配置" }) else {
                            throw PetError("清空搜索后未回到原编辑器")
                        }
                        checks["clearingSearchRetainsOriginalBodyAndSelection"] = editor.string == body && editor.selectedRange() == (body as NSString).range(of: "中文😀")
                        try button(global, "返回对话").performClick(nil)
                        guard let searchBack = find(back.window?.contentView, NSButton.self, { $0.accessibilityLabel() == "返回搜索结果" }) else {
                            throw PetError("缺少重开后的搜索返回入口")
                        }
                        searchBack.performClick(nil)
                        let returned = back.captureSettingsNavigation()
                        checks["restoredSearchReturnOpensOriginalQueryAndResult"] = returned?.query == fixture.searchReturn?.query &&
                            returned?.focus == fixture.searchReturn?.result && returned?.selection == fixture.searchReturn?.selection && back.captureSettingsSearchReturn() == nil
                        try button(back, "返回自动化").performClick(nil)
                        checks["returnReopensActualAutomationPage"] = back.automationWindow?.isVisible == true && back.captureSettingsNavigation() == nil
                    }
                }
            }
            checks["checkpointFinished"] = await flushWorkspaceWindows()
        } catch { failure = error.localizedDescription }
        checks["zeroModelRequests"] = requests == 0
        var report: [String: Any] = ["stage":stage, "success":failure == nil && checks.values.allSatisfy { $0 }, "checks":checks, "modelRequests":requests, "pid":getpid()]
        if let failure { report["error"] = failure }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: output.appendingPathComponent("navigation-report-\(stage).json"), options: .atomic)
        }
    }
}
