import AppKit

@MainActor final class AgentAutomationWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate, NSWindowDelegate {
    let store: AgentStore
    let service: AgentAutomations
    var onOpen: ((String) -> Void)?
    var onRequestNotifications: (() async throws -> Bool)?
    var onCreateWithAssistant: (() throws -> Void)?
    var onSaved: ((String) throws -> Void)?
    var sourceTaskID: String?
    private let list = NSTableView(), history = NSTableView(), sections = NSSegmentedControl(labels: ["计划", "运行记录"], trackingMode: .selectOne, target: nil, action: nil)
    private let archived = NSPopUpButton(), awake = NSButton(checkboxWithTitle: "保持设备唤醒", target: nil, action: nil)
    private let name = AgentAutomationTextField(), workspace = AgentAutomationTextField(), model = AgentAutomationTextField(), zone = AgentAutomationTextField(), time = AgentAutomationTextField(), interval = AgentAutomationTextField(), prompt = NSTextView()
    private let executor = NSPopUpButton(), frequency = NSPopUpButton(), weekdays = NSPopUpButton(frame: .zero, pullsDown: true), output = NSPopUpButton(), permission = NSPopUpButton()
    private var scheduleGrid: NSGridView!
    private let once = NSDatePicker(), expiry = NSDatePicker(), expiring = NSButton(checkboxWithTitle: "到期暂停", target: nil, action: nil)
    private let readOnly = NSButton(checkboxWithTitle: "只读项目", target: nil, action: nil), network = NSButton(checkboxWithTitle: "允许联网与外部连接", target: nil, action: nil), notify = NSButton(checkboxWithTitle: "运行结果通知", target: nil, action: nil)
    private let enabled = NSButton(checkboxWithTitle: "启用计划", target: nil, action: nil)
    private let next = NSTextField(labelWithString: ""), state = NSTextField(labelWithString: ""), detail = NSTextField(wrappingLabelWithString: "")
    private let save = NSButton(title: "保存", target: nil, action: nil), pause = NSButton(title: "暂停", target: nil, action: nil), run = NSButton(title: "立即运行", target: nil, action: nil), archive = NSButton(title: "归档", target: nil, action: nil)
    private let workspaceButton = NSButton(title: "选择…", target: nil, action: nil)
    private let formScroll = NSScrollView(), records = NSStackView(), onlySelected = NSButton(checkboxWithTitle: "当前自动化", target: nil, action: nil), status = NSPopUpButton(), grouping = NSPopUpButton(), page = NSTextField(labelWithString: "")
    private let promptField = AgentThemeView(fill: .textBackgroundColor, stroke: AgentWorkbenchTheme.line)
    private let previous = NSButton(title: "上一页", target: nil, action: nil), more = NSButton(title: "下一页", target: nil, action: nil), openTask = NSButton(title: "打开任务", target: nil, action: nil)
    private let catalog = NSView(), catalogScroll = NSScrollView(), body = NSView()
    private let empty = NSTextField(labelWithString: "还没有自动化"), title = NSTextField(labelWithString: "自动化")
    private let add = NSButton(title: "新建自动化", target: nil, action: nil), assistant = NSButton(title: "用小鲸创建", target: nil, action: nil), back = NSButton(title: "返回自动化", target: nil, action: nil)
    private var header: NSStackView!, column: NSStackView!, top: NSLayoutConstraint!
    private weak var hostWindow: NSWindow?
    private var hostedContent: NSView?, editing = false, checkSelectionContrasts: [String: CGFloat] = [:]
    var presentingWindow: NSWindow? { hostWindow ?? window }
    var hasUnsavedChanges: Bool { dirty }
    var isVisible: Bool { (hostedContent?.window?.isVisible ?? window?.isVisible ?? false) && hostedContent?.isHiddenOrHasHiddenAncestor != true }
    private var definitions: [AgentAutomation] = [], selectedID: String?, opened: AgentAutomation?, newValue: AgentAutomation?, dirty = false, loading = false, selectedDays = Set([2])
    private enum HistoryRow { case heading(String), run(AgentAutomationRun) }
    private var rows: [HistoryRow] = [], offset = 0, total = 0, observer: NSObjectProtocol?
    init(store: AgentStore) {
        self.store = store; service = store.automations
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "自动化"; window.minSize = NSSize(width: 780, height: 540); window.center(); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let content = AgentThemeView(fill: AgentWorkbenchTheme.surface); window.contentView = content; content.setAccessibilityLabel("自动化主页面")
        archived.addItems(withTitles: ["自动化", "已归档"]); archived.target = self; archived.action = #selector(changeArchiveFilter)
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("automations")); list.addTableColumn(tableColumn); list.headerView = nil; list.rowHeight = 52; list.delegate = self; list.dataSource = self; list.setAccessibilityLabel("自动化列表")
        catalogScroll.documentView = list; catalogScroll.hasVerticalScroller = true; list.style = .inset; list.backgroundColor = .clear
        add.target = self; add.action = #selector(create); archive.target = self; archive.action = #selector(archiveDefinition)
        assistant.target = self; assistant.action = #selector(createWithAssistant); back.target = self; back.action = #selector(returnToCatalog)
        back.image = NSImage(systemSymbolName: "arrow.left", accessibilityDescription: nil); back.imagePosition = .imageLeading; back.isBordered = false
        title.font = .systemFont(ofSize: 20, weight: .semibold); title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let heading = NSStackView(views: [back, title, NSView(), assistant, add]); heading.spacing = 10
        sections.selectedSegment = 0; sections.target = self; sections.action = #selector(changeSection)
        awake.state = service.keepAwake ? .on : .off; awake.target = self; awake.action = #selector(changeAwake)
        let notifications = NSButton(title: "桌面通知", target: self, action: #selector(requestNotifications))
        header = NSStackView(views: [sections, NSView(), awake, notifications]); header.spacing = 10
        for field in [name, workspace, model, zone, time, interval] { field.font = .systemFont(ofSize: 13); field.delegate = self }
        for (field, label) in [(name, "自动化名称"), (workspace, "自动化项目目录"), (model, "自动化模型"), (zone, "计划时区"), (time, "计划时间"), (interval, "间隔分钟")] { field.setAccessibilityLabel(label) }
        name.placeholderString = "名称"; workspace.isEditable = false; workspace.isSelectable = true; workspace.lineBreakMode = .byTruncatingMiddle; model.placeholderString = "跟随已配置模型"; zone.placeholderString = "Asia/Shanghai"; time.placeholderString = "09:00"; interval.placeholderString = "60"
        workspaceButton.target = self; workspaceButton.action = #selector(chooseWorkspace); let project = NSStackView(views: [workspace, workspaceButton]); project.spacing = 8
        for (popup, titles) in [(frequency, AgentAutomationFrequency.allCases.map(\.title)), (output, AgentAutomationOutput.allCases.map(\.title)), (permission, AgentPermissionMode.allCases.map(\.title))] { popup.addItems(withTitles: titles); popup.target = self; popup.action = #selector(changed) }
        executor.target = self; executor.action = #selector(changed); frequency.action = #selector(frequencyChanged)
        for (control, label) in [(executor, "自动化执行者"), (frequency, "计划频率"), (weekdays, "每周运行日期"), (output, "任务输出方式"), (permission, "执行授权")] { control.setAccessibilityLabel(label) }
        for picker in [once, expiry] { picker.datePickerStyle = .textFieldAndStepper; picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]; picker.target = self; picker.action = #selector(changed); picker.setAccessibilityLabel(picker === once ? "运行日期" : "到期日期") }
        for button in [expiring, readOnly, network, notify, enabled] { button.target = self; button.action = #selector(changed) }
        permission.toolTip = "按当前工具与项目范围执行。需要确认的操作仍会等待处理。"; readOnly.toolTip = "终端也不能写入项目；外部 MCP 无法保证只读，因此停用。"
        frequency.toolTip = "应用需在计划时段运行。错过超过一分钟时记入历史，不补跑。"
        let clockRow = NSStackView(views: [time, weekdays]); clockRow.spacing = 8; time.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let expireRow = NSStackView(views: [expiring, expiry]); expireRow.spacing = 8
        let scope = NSStackView(views: [readOnly, network]); scope.spacing = 14
        let grid = NSGridView(views: [[NSTextField(labelWithString: "名称"), name], [NSTextField(labelWithString: "项目"), project], [NSTextField(labelWithString: "执行者"), executor], [NSTextField(labelWithString: "模型"), model], [NSTextField(labelWithString: "计划"), frequency], [NSTextField(labelWithString: "日期"), once], [NSTextField(labelWithString: "时间"), clockRow], [NSTextField(labelWithString: "间隔分钟"), interval], [NSTextField(labelWithString: "时区"), zone], [NSTextField(labelWithString: "到期"), expireRow], [NSTextField(labelWithString: "输出"), output], [NSTextField(labelWithString: "执行授权"), permission], [NSTextField(labelWithString: "范围"), scope], [NSTextField(labelWithString: "通知"), notify], [NSTextField(labelWithString: "状态"), enabled], [NSTextField(labelWithString: "下次"), next]])
        scheduleGrid = grid
        grid.column(at: 0).width = 60; grid.column(at: 0).xPlacement = .trailing; grid.column(at: 1).xPlacement = .fill; grid.columnSpacing = 12; grid.rowSpacing = 10
        next.font = .systemFont(ofSize: 11); next.textColor = AgentWorkbenchTheme.secondaryText; next.lineBreakMode = .byTruncatingTail; next.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        prompt.isRichText = false; prompt.allowsUndo = true; prompt.delegate = self; prompt.font = .systemFont(ofSize: 13); prompt.textColor = .labelColor; prompt.textContainerInset = NSSize(width: 12, height: 12); prompt.isVerticallyResizable = true; prompt.autoresizingMask = [.width]; prompt.textContainer?.widthTracksTextView = true; prompt.isAutomaticQuoteSubstitutionEnabled = false; prompt.isAutomaticTextReplacementEnabled = false; prompt.setAccessibilityLabel("自动化任务指令")
        let editor = NSScrollView(); editor.documentView = prompt; editor.hasVerticalScroller = true; editor.scrollerStyle = .overlay; editor.borderType = .noBorder; editor.drawsBackground = false; prompt.drawsBackground = false
        promptField.addSubview(editor); editor.translatesAutoresizingMaskIntoConstraints = false
        promptField.layer?.cornerRadius = 8; promptField.layer?.borderWidth = 1; promptField.layer?.masksToBounds = true
        NSLayoutConstraint.activate([editor.leadingAnchor.constraint(equalTo: promptField.leadingAnchor, constant: 1), editor.trailingAnchor.constraint(equalTo: promptField.trailingAnchor, constant: -1), editor.topAnchor.constraint(equalTo: promptField.topAnchor, constant: 1), editor.bottomAnchor.constraint(equalTo: promptField.bottomAnchor, constant: -1), promptField.heightAnchor.constraint(equalToConstant: 180)])
        let label = NSTextField(labelWithString: "任务指令"); label.font = .systemFont(ofSize: 12, weight: .medium)
        let form = NSStackView(views: [grid, label, promptField]); form.orientation = .vertical; form.alignment = .leading; form.spacing = 12
        let document = FormDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(form)
        for view in form.arrangedSubviews { view.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true }; form.translatesAutoresizingMaskIntoConstraints = false; formScroll.documentView = document; formScroll.hasVerticalScroller = true
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: formScroll.contentView.widthAnchor), form.leadingAnchor.constraint(equalTo: document.leadingAnchor), form.trailingAnchor.constraint(equalTo: document.trailingAnchor), form.topAnchor.constraint(equalTo: document.topAnchor), form.bottomAnchor.constraint(equalTo: document.bottomAnchor)])
        formScroll.contentView.postsBoundsChangedNotifications = true
        for popup in [status, grouping] { popup.target = self; popup.action = #selector(filterHistory) }
        status.addItems(withTitles: ["全部状态"] + AgentAutomationRunStatus.allCases.map(\.title)); grouping.addItems(withTitles: ["按日", "按周", "按月"])
        onlySelected.target = self; onlySelected.action = #selector(filterHistory); onlySelected.state = .off
        let refresh = NSButton(title: "刷新", target: self, action: #selector(refreshHistory)), filters = NSStackView(views: [onlySelected, status, grouping, NSView(), refresh]); filters.spacing = 8
        let historyColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("runs")); history.addTableColumn(historyColumn); history.headerView = nil; history.delegate = self; history.dataSource = self; history.setAccessibilityLabel("自动化运行记录")
        let historyScroll = NSScrollView(); historyScroll.documentView = history; historyScroll.hasVerticalScroller = true; history.style = .inset; history.backgroundColor = .clear
        for scroll in [catalogScroll, historyScroll, formScroll] { scroll.scrollerStyle = .overlay; scroll.borderType = .noBorder; scroll.drawsBackground = false }
        detail.maximumNumberOfLines = 3; detail.font = .systemFont(ofSize: 12); detail.lineBreakMode = .byTruncatingTail
        previous.target = self; previous.action = #selector(previousPage); more.target = self; more.action = #selector(nextPage); openTask.target = self; openTask.action = #selector(openRun)
        let pages = NSStackView(views: [previous, page, more, NSView(), openTask]); pages.spacing = 8
        records.orientation = .vertical; records.alignment = .leading; records.spacing = 12; for view in [filters, historyScroll, detail, pages] { records.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: records.widthAnchor).isActive = true }; records.isHidden = true
        historyScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true; historyScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        save.target = self; save.action = #selector(saveDefinition); save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command; pause.target = self; pause.action = #selector(togglePause); run.target = self; run.action = #selector(runNow)
        state.font = .systemFont(ofSize: 11); state.textColor = AgentWorkbenchTheme.secondaryText; state.lineBreakMode = .byTruncatingTail; state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [state, NSView(), run, pause, archive, save]); footer.spacing = 8
        for view in [archived, catalogScroll, empty] { catalog.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        empty.font = .systemFont(ofSize: 14); empty.textColor = AgentWorkbenchTheme.secondaryText
        NSLayoutConstraint.activate([archived.leadingAnchor.constraint(equalTo: catalog.leadingAnchor), archived.topAnchor.constraint(equalTo: catalog.topAnchor), catalogScroll.leadingAnchor.constraint(equalTo: catalog.leadingAnchor), catalogScroll.trailingAnchor.constraint(equalTo: catalog.trailingAnchor), catalogScroll.topAnchor.constraint(equalTo: archived.bottomAnchor, constant: 14), catalogScroll.bottomAnchor.constraint(equalTo: catalog.bottomAnchor), empty.centerXAnchor.constraint(equalTo: catalog.centerXAnchor), empty.centerYAnchor.constraint(equalTo: catalog.centerYAnchor)])
        for view in [catalog, formScroll, records] {
            body.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: body.leadingAnchor), view.trailingAnchor.constraint(equalTo: body.trailingAnchor), view.topAnchor.constraint(equalTo: body.topAnchor), view.bottomAnchor.constraint(equalTo: body.bottomAnchor)])
        }
        column = NSStackView(views: [heading, header, body, footer]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 18
        content.addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        for view in column.arrangedSubviews { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        let width = column.widthAnchor.constraint(equalToConstant: 824); width.priority = .init(499)
        top = column.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)
        NSLayoutConstraint.activate([column.centerXAnchor.constraint(equalTo: content.centerXAnchor), column.widthAnchor.constraint(lessThanOrEqualToConstant: 824), column.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 28), column.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -28), width, top, column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24), footer.heightAnchor.constraint(equalToConstant: 30)])
        body.setContentHuggingPriority(.defaultLow, for: .vertical)
        observer = NotificationCenter.default.addObserver(forName: AgentAutomations.changed, object: service, queue: .main) { [weak self] _ in Task { @MainActor in self?.reload() } }; reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func content(in host: NSWindow) -> NSView? {
        guard let view = hostedContent ?? window?.contentView else { return nil }
        if hostedContent == nil { window?.contentView = nil; hostedContent = view }
        hostWindow = host; top.constant = 68; updatePresentation(); return view
    }
    func refresh() { reload() }
    private func updatePresentation() {
        let showingHistory = !editing && sections.selectedSegment == 1
        title.stringValue = editing ? (opened == nil ? "新建自动化" : opened!.name) : "自动化"
        back.isHidden = !editing; assistant.isHidden = editing; add.isHidden = editing; header.isHidden = editing
        catalog.isHidden = editing || showingHistory; formScroll.isHidden = !editing; records.isHidden = !showingHistory
        for button in [run, pause, archive, save] { button.isHidden = !editing }
        empty.isHidden = !definitions.isEmpty; catalogScroll.isHidden = definitions.isEmpty
        hostedContent?.layoutSubtreeIfNeeded(); presentingWindow?.recalculateKeyViewLoop()
    }
    func configureDraft(_ draft: AgentAutomationDraft) throws {
        let draft = try AgentAutomationDrafts.load(draft.id, taskID: draft.taskID, store: store)
        guard !dirty || selectedID == draft.automation.id else { throw PetError("请先保存或关闭当前自动化更改") }
        if dirty { return }
        let saved = service.values.first { $0.id == draft.automation.id }
        guard draft.savedAt == nil || saved != nil else { throw PetError("自动化已移除，原草稿保留") }
        newValue = saved == nil ? draft.automation : nil; selectedID = draft.automation.id
        archived.selectItem(at: saved?.archived == true ? 1 : 0); reload(); open(saved ?? draft.automation)
        dirty = saved == nil; editing = true; sections.selectedSegment = 0; changeSection(); updateControls()
    }
    private func reload() {
        let savedSelection = selectedID
        definitions = service.values.filter { $0.archived == (archived.indexOfSelectedItem == 1) }; if let newValue { definitions.append(newValue) }
        loading = true; list.reloadData(); if let i = definitions.firstIndex(where: { $0.id == savedSelection }) { list.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false) }; loading = false
        awake.state = service.keepAwake ? .on : .off
        if !dirty { open(definitions.first(where: { $0.id == savedSelection }) ?? definitions.first) }
        if !editing { loading = true; list.deselectAll(nil); loading = false }
        loadHistory(); updatePresentation()
    }
    private func open(_ value: AgentAutomation?) {
        loading = true; defer { loading = false }; opened = value.flatMap { candidate in service.values.first { $0.id == candidate.id } }; selectedID = value?.id
        name.stringValue = value?.name ?? ""; workspace.stringValue = value?.workspace ?? ""; model.stringValue = value?.model ?? ""; prompt.string = value?.prompt ?? ""
        let schedule = value?.schedule ?? AgentAutomationSchedule(); zone.stringValue = schedule.timeZone; time.stringValue = String(format: "%02d:%02d", schedule.hour, schedule.minute); interval.stringValue = String(schedule.intervalMinutes); selectedDays = Set(schedule.weekdays)
        frequency.selectItem(at: AgentAutomationFrequency.allCases.firstIndex(of: schedule.frequency) ?? 0); once.dateValue = schedule.date; once.timeZone = TimeZone(identifier: schedule.timeZone); expiry.dateValue = schedule.expiration ?? Date().addingTimeInterval(86_400 * 30); expiry.timeZone = once.timeZone; expiring.state = schedule.expiration == nil ? .off : .on
        output.selectItem(at: AgentAutomationOutput.allCases.firstIndex(of: value?.output ?? .independent) ?? 0); permission.selectItem(at: AgentPermissionMode.allCases.firstIndex(of: value?.permission ?? .review) ?? 0)
        readOnly.state = value?.readOnly == false ? .off : .on; network.state = value?.network == true ? .on : .off; notify.state = value?.notify == false ? .off : .on; enabled.state = value?.enabled == true ? .on : .off
        refreshExecutors(selected: value?.executor ?? "default"); refreshDays(); updateScheduleRows(); dirty = false; prompt.undoManager?.removeAllActions(); state.stringValue = service.error ?? ""
        if let i = definitions.firstIndex(where: { $0.id == value?.id }) { list.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false) }; updateControls()
    }
    private func refreshExecutors(selected: String) {
        executor.removeAllItems(); executor.addItem(withTitle: "小鲸"); executor.lastItem?.representedObject = "default"
        for value in (try? store.agents.list(enabledOnly: true, workspace: workspace.stringValue.isEmpty ? nil : workspace.stringValue)) ?? [] { executor.addItem(withTitle: "Agent · " + value.name); executor.lastItem?.representedObject = "agent:" + value.id }
        for value in (try? store.teams.list()) ?? [] where (try? store.teams.team(value.id, store: store, workspace: workspace.stringValue.isEmpty ? nil : workspace.stringValue)) != nil { executor.addItem(withTitle: "团队 · " + value.name); executor.lastItem?.representedObject = "team:" + value.id }
        if let item = executor.itemArray.first(where: { $0.representedObject as? String == selected }) { executor.select(item) } else { executor.addItem(withTitle: "执行者不可用"); executor.lastItem?.representedObject = selected; executor.select(executor.lastItem) }
    }
    private func refreshDays() {
        weekdays.removeAllItems(); weekdays.addItem(withTitle: selectedDays.sorted().map { ["日", "一", "二", "三", "四", "五", "六"][$0 - 1] }.joined(separator: "、"))
        for day in 1...7 { let item = NSMenuItem(title: "周" + ["日", "一", "二", "三", "四", "五", "六"][day - 1], action: #selector(toggleDay(_:)), keyEquivalent: ""); item.target = self; item.tag = day; item.state = selectedDays.contains(day) ? .on : .off; weekdays.menu?.addItem(item) }
    }
    @objc private func toggleDay(_ sender: NSMenuItem) { if selectedDays.contains(sender.tag) { selectedDays.remove(sender.tag) } else { selectedDays.insert(sender.tag) }; refreshDays(); changed() }
    private func updateScheduleRows() {
        let kind = AgentAutomationFrequency.allCases[max(0, frequency.indexOfSelectedItem)]
        scheduleGrid.row(at: 5).isHidden = ![.once, .interval].contains(kind); scheduleGrid.row(at: 6).isHidden = ![.daily, .weekly].contains(kind); scheduleGrid.row(at: 7).isHidden = kind != .interval; scheduleGrid.row(at: 9).isHidden = kind == .once
        weekdays.isHidden = kind != .weekly; expiry.isEnabled = expiring.state == .on
        if selectedID == nil { next.stringValue = "" }
        else if opened?.archived == true { next.stringValue = "已归档" }
        else if let value = try? capture() { next.stringValue = (value.schedule.next(after: Date()).map { AgentAutomations.dateText($0, zone: value.schedule.timeZone) } ?? "无有效运行时间") + (value.enabled ? "" : " · 未启用") }
        else { next.stringValue = "请检查时间和时区" }
    }
    private func updateControls() {
        let selected = selectedID != nil, stored = opened != nil, archived = opened?.archived == true
        for view in [name, workspace, workspaceButton, model, zone, time, interval, executor, frequency, weekdays, output, permission, once, expiry, expiring, readOnly, network, notify, enabled] as [NSControl] { view.isEnabled = selected && !archived }
        model.isEnabled = selected && !archived && executor.selectedItem?.representedObject as? String == "default"; prompt.isEditable = selected && !archived
        save.isEnabled = dirty; run.isEnabled = stored && !dirty && !archived; pause.isEnabled = run.isEnabled; pause.title = opened?.enabled == true ? "暂停" : "启用"; archive.isEnabled = stored && !dirty; archive.title = archived ? "恢复" : "归档"; save.title = stored ? (dirty ? "保存" : "已保存") : "创建"
        expiry.isEnabled = selected && !archived && expiring.state == .on
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === list ? definitions.count : rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { AgentSettingsTableRow() }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { if tableView === list { return 52 }; if case .heading = rows[row] { return 26 }; return 48 }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { if tableView === history, case .heading = rows[row] { return false }; return true }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let title: String, subtitle: String
        if tableView === list { let value = definitions[row]; title = value.name.isEmpty ? "新的自动化" : value.name; subtitle = newValue?.id == value.id ? "未保存" : value.current?.status.title ?? (value.archived ? "已归档" : value.enabled ? value.nextRun.map { AgentAutomations.dateText($0, zone: value.schedule.timeZone) } ?? "已到期" : "已暂停") }
        else { switch rows[row] { case .heading(let heading): let label = NSTextField(labelWithString: heading); label.font = .systemFont(ofSize: 11, weight: .medium); label.textColor = AgentWorkbenchTheme.secondaryText; return label
        case .run(let run): title = run.name + " · " + run.status.title + (run.unread ? " · 未读" : ""); subtitle = AgentAutomations.dateText(run.scheduled, zone: TimeZone.current.identifier) + (run.trigger == "manual" ? " · 手动" : " · 计划") } }
        let label = NSTextField(labelWithString: title), sub = NSTextField(labelWithString: subtitle); label.font = .systemFont(ofSize: 13, weight: .medium); sub.font = .systemFont(ofSize: 11); sub.textColor = AgentWorkbenchTheme.secondaryText
        for field in [label, sub] { field.lineBreakMode = .byTruncatingTail; field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let stack = NSStackView(views: [label, sub]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4; return stack
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !loading else { return }
        if notification.object as? NSTableView === list {
            guard definitions.indices.contains(list.selectedRow) else { return }
            if dirty { state.stringValue = "请先保存更改"; loading = true; if let i = definitions.firstIndex(where: { $0.id == selectedID }) { list.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false) }; loading = false; return }; open(definitions[list.selectedRow]); editing = true; updatePresentation(); formScroll.contentView.scroll(to: .zero); offset = 0; loadHistory()
        } else { let run = selectedRun; detail.stringValue = run?.detail ?? ""; openTask.isEnabled = run?.taskID.flatMap(store.task) != nil }
    }
    private var selectedRun: AgentAutomationRun? { guard rows.indices.contains(history.selectedRow), case .run(let run) = rows[history.selectedRow] else { return nil }; return run }
    private func loadHistory() {
        do {
            let selected = selectedRun?.id, filter = status.indexOfSelectedItem > 0 ? AgentAutomationRunStatus.allCases[status.indexOfSelectedItem - 1] : nil
            let result = try service.history(automationID: onlySelected.state == .on ? selectedID : nil, status: filter, offset: offset); total = result.total; rows = []
            var last = ""; let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = grouping.indexOfSelectedItem == 2 ? "yyyy年MM月" : grouping.indexOfSelectedItem == 1 ? "YYYY年第ww周" : "yyyy年MM月dd日"
            for run in result.runs { let group = formatter.string(from: run.scheduled); if group != last { rows.append(.heading(group)); last = group }; rows.append(.run(run)) }
            history.reloadData(); if let i = rows.firstIndex(where: { if case .run(let run) = $0 { return run.id == selected }; return false }) { history.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false) }
            page.stringValue = total == 0 ? "暂无记录" : "\(offset + 1)–\(min(offset + 50, total)) / \(total)"; previous.isEnabled = offset > 0; more.isEnabled = offset + 50 < total; detail.stringValue = selectedRun?.detail ?? ""; openTask.isEnabled = selectedRun?.taskID.flatMap(store.task) != nil
        } catch { state.stringValue = error.localizedDescription }
    }
    private func capture() throws -> AgentAutomation {
        guard let value = definitions.first(where: { $0.id == selectedID }) else { throw PetError("请选择自动化") }; var result = value
        result.name = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); result.prompt = prompt.string; result.workspace = workspace.stringValue; result.model = model.stringValue; result.executor = executor.selectedItem?.representedObject as? String ?? "default"
        result.schedule.frequency = AgentAutomationFrequency.allCases[frequency.indexOfSelectedItem]; result.schedule.timeZone = zone.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); result.schedule.date = once.dateValue; result.schedule.weekdays = selectedDays.sorted(); result.schedule.expiration = expiring.state == .on ? expiry.dateValue : nil
        let parts = time.stringValue.split(separator: ":"); guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]), let interval = Int(interval.stringValue) else { throw PetError("时间使用 HH:mm，间隔使用整数分钟") }; result.schedule.hour = hour; result.schedule.minute = minute; result.schedule.intervalMinutes = interval
        result.output = AgentAutomationOutput.allCases[output.indexOfSelectedItem]; result.permission = AgentPermissionMode.allCases[permission.indexOfSelectedItem]; result.readOnly = readOnly.state == .on; result.network = network.state == .on; result.notify = notify.state == .on; result.enabled = enabled.state == .on; return result
    }
    func controlTextDidChange(_ obj: Notification) { if obj.object as? NSTextField === zone, let value = TimeZone(identifier: zone.stringValue) { once.timeZone = value; expiry.timeZone = value }; changed() }
    func textDidChange(_ notification: Notification) { changed() }
    @objc private func changed() { guard !loading else { return }; dirty = true; state.stringValue = "未保存"; updateScheduleRows(); updateControls() }
    @objc private func frequencyChanged() { if frequency.indexOfSelectedItem == AgentAutomationFrequency.allCases.firstIndex(of: .interval) { once.dateValue = Date() }; changed() }
    @objc private func changeSection() { updatePresentation(); if !records.isHidden { loadHistory() } }
    @objc private func returnToCatalog() { guard prepareToLeave() else { return }; editing = false; sections.selectedSegment = 0; reload() }
    @objc private func filterHistory() { offset = 0; loadHistory() }
    @objc private func refreshHistory() { reload() }
    @objc private func previousPage() { offset = max(0, offset - 50); loadHistory() }
    @objc private func nextPage() { offset += 50; loadHistory() }
    @objc private func openRun() { guard let run = selectedRun else { return }; do { try service.markRead(run); if let id = run.taskID { onOpen?(id) }; loadHistory() } catch { state.stringValue = error.localizedDescription } }
    @objc private func create() {
        guard !dirty else { state.stringValue = "请先保存更改"; return }
        let source = sourceTaskID.flatMap(store.task) ?? store.selected
        var value = AgentAutomation(name: "", prompt: "", workspace: source?.workspace ?? ""); value.workMode = source?.workMode; value.enabled = true; newValue = value; selectedID = value.id; archived.selectItem(at: 0); editing = true; reload(); open(value); dirty = true; updateControls(); sections.selectedSegment = 0; changeSection(); formScroll.contentView.scroll(to: .zero); presentingWindow?.makeFirstResponder(name)
    }
    @objc private func saveDefinition() { do { let value = try capture(); try service.save(value, expected: opened); newValue = nil; dirty = false; selectedID = value.id; reload(); try onSaved?(value.id); state.stringValue = "已保存" } catch { state.stringValue = error.localizedDescription } }
    @objc private func createWithAssistant() {
        do { guard !dirty else { throw PetError("请先保存或关闭当前自动化更改") }; guard let action = onCreateWithAssistant else { throw PetError("会话入口暂不可用") }; try action(); if hostWindow == nil { window?.orderOut(nil) } }
        catch { state.stringValue = error.localizedDescription }
    }
    @objc private func togglePause() { do { guard let opened, !dirty else { throw PetError("请先保存更改") }; try service.setPaused(opened.id, paused: opened.enabled); reload() } catch { state.stringValue = error.localizedDescription } }
    @objc private func runNow() { do { guard let opened, !dirty else { throw PetError("请先保存更改") }; try service.runNow(opened.id); editing = false; onlySelected.state = .on; sections.selectedSegment = 1; changeSection() } catch { state.stringValue = error.localizedDescription } }
    @objc private func archiveDefinition() { do { guard var value = opened, !dirty else { throw PetError("请先保存更改") }; value.archived.toggle(); value.enabled = false; try service.save(value, expected: opened); editing = false; reload() } catch { state.stringValue = error.localizedDescription } }
    @objc private func changeArchiveFilter() { guard !dirty else { archived.selectItem(at: opened?.archived == true ? 1 : 0); state.stringValue = "请先保存更改"; return }; selectedID = nil; reload() }
    @objc private func chooseWorkspace() {
        guard selectedID != nil, opened?.archived != true else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.prompt = "选择项目"
        guard panel.runModal() == .OK, let path = panel.url?.resolvingSymlinksInPath().path else { return }; workspace.stringValue = path; refreshExecutors(selected: executor.selectedItem?.representedObject as? String ?? "default"); changed()
    }
    @objc private func changeAwake() { do { try service.setKeepAwake(awake.state == .on) } catch { awake.state = service.keepAwake ? .on : .off; state.stringValue = error.localizedDescription } }
    @objc private func requestNotifications() { Task { do { guard let action = onRequestNotifications else { throw PetError("通知设置暂不可用") }; state.stringValue = try await action() ? "桌面通知已开启" : "请在系统设置中允许通知" } catch { state.stringValue = error.localizedDescription } } }
    func windowDidResize(_ notification: Notification) {
        guard let i = CommandLine.arguments.firstIndex(of: "--check"), CommandLine.arguments.count > i + 1, let window, let root = window.contentView else { return }
        let metrics: [String: Any] = ["window": [window.frame.width, window.frame.height], "rootFitting": [root.fittingSize.width, root.fittingSize.height], "gridFitting": [scheduleGrid.fittingSize.width, scheduleGrid.fittingSize.height], "workspaceFitting": [workspace.fittingSize.width, workspace.fittingSize.height], "recordsFitting": [records.fittingSize.width, records.fittingSize.height], "detailFitting": [detail.fittingSize.width, detail.fittingSize.height], "formVisible": !formScroll.isHidden, "formWidth": formScroll.bounds.width]
        let output = URL(fileURLWithPath: CommandLine.arguments[i + 1]).appendingPathComponent("automation-window-layout.json")
        try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
    }
    func prepareToLeave() -> Bool {
        guard dirty else { return true }
        guard AgentUnsavedChanges.discard("放弃未保存的自动化更改？") else { return false }
        newValue = nil; dirty = false; editing = false; reload(); return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { prepareToLeave() }
    func checkState() -> [String: Any] {
        guard CommandLine.arguments.contains("--manual-ui") || CommandLine.arguments.contains("--automation-page-check") else { return [:] }
        return ["visible": isVisible, "embedded": hostWindow != nil, "editing": editing, "dirty": dirty, "section": sections.selectedSegment, "selected": selectedID as Any? ?? NSNull(), "definitions": definitions.map { ["id": $0.id, "name": $0.name, "archived": $0.archived, "enabled": $0.enabled] as [String: Any] }, "name": name.stringValue, "prompt": prompt.string, "workspace": workspace.stringValue, "status": state.stringValue, "historyTotal": total, "historyRunIDs": rows.compactMap { if case .run(let value) = $0 { return value.id }; return nil }, "formScrollY": formScroll.contentView.bounds.origin.y, "selectionContrasts": checkSelectionContrasts]
    }
    func checkPageGeometry() -> [String: Any] {
        guard CommandLine.arguments.contains("--automation-page-check"), let root = hostedContent else { return [:] }
        root.layoutSubtreeIfNeeded()
        let frame = column.convert(column.bounds, to: root), visible = root.bounds
        let controls = [back, add, assistant, run, pause, archive, save].filter { !$0.isHiddenOrHasHiddenAncestor }
        let checks = ["contentIsHostedByOwner": root.window === hostWindow && window?.isVisible == false, "centeredColumnFitsPage": frame.minX >= 27.5 && frame.maxX <= visible.maxX - 27.5 && frame.width <= 824.5 && abs(frame.midX - visible.midX) < 1, "pageActionsFit": controls.allSatisfy { visible.contains($0.convert($0.bounds, to: root)) }, "bodyFillsColumn": abs(body.bounds.width - column.bounds.width) < 0.5, "editorStartsAtTop": !editing || formScroll.contentView.bounds.minY < 0.5, "editorCanScrollToAllFields": !editing || formScroll.documentView?.isFlipped == true && formScroll.documentView!.bounds.height > formScroll.contentView.bounds.height && formScroll.hasVerticalScroller]
        return ["checks": checks, "columnWidth": column.bounds.width, "leadingGutter": frame.minX, "bodyHeight": body.bounds.height, "editor": editing]
    }
    func checkSelect(_ id: String) -> Bool {
        guard CommandLine.arguments.contains("--automation-page-check"), let index = definitions.firstIndex(where: { $0.id == id }) else { return false }
        list.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); return editing && selectedID == id
    }
    func checkShowCatalog() { if CommandLine.arguments.contains("--automation-page-check"), !dirty { returnToCatalog() } }
    func checkPageOperations(_ id: String) throws -> [String: Bool] {
        guard CommandLine.arguments.contains("--automation-page-check"), checkSelect(id), let original = opened else { throw PetError("自动化计划未进入页内编辑") }
        var checks = ["selectionOpensEditorInSamePage": editing && !formScroll.isHidden && back.isHidden == false && !dirty]
        name.stringValue = "已编辑的公开核对计划"; prompt.string = "读取公开 README 并核对标题。"; changed(); reload()
        checks["runtimeRefreshPreservesUnsentEdits"] = dirty && name.stringValue == "已编辑的公开核对计划" && prompt.string == "读取公开 README 并核对标题。"
        let pendingName = name.stringValue; name.stringValue = ""; saveDefinition()
        checks["invalidSaveRetainsEditAndStoredDefinition"] = dirty && service.values.first(where: { $0.id == id })?.name == original.name && !state.stringValue.isEmpty
        name.stringValue = pendingName; saveDefinition()
        guard let saved = service.values.first(where: { $0.id == id }) else { throw PetError("实际自动化未保存") }
        checks["pageSaveUsesExistingPersistentService"] = !dirty && saved.name == pendingName && saved.prompt == prompt.string && saved.readOnly == original.readOnly && saved.network == original.network && saved.schedule.frequency == original.schedule.frequency
        reload(); checks["savedFeedbackSurvivesServiceRefresh"] = save.title == "已保存" && !save.isEnabled
        checks["promptUsesSharedThemeField"] = promptField.layer?.borderWidth == 1 && promptField.layer?.cornerRadius == 8 && !prompt.drawsBackground
        var external = saved; external.prompt = "外部保存的公开任务要求。"; try service.save(external, expected: saved)
        prompt.string = "尚未覆盖的页内修改。"; changed(); saveDefinition()
        checks["staleEditorCannotOverwriteExternalChange"] = dirty && prompt.string == "尚未覆盖的页内修改。" && service.values.first(where: { $0.id == id })?.prompt == external.prompt && state.stringValue.contains("已改变")
        newValue = nil; dirty = false; open(service.values.first { $0.id == id })
        archiveDefinition()
        checks["archiveReturnsToCatalogAndRetainsDefinition"] = !editing && service.values.first(where: { $0.id == id })?.archived == true
        archived.selectItem(at: 1); changeArchiveFilter(); guard checkSelect(id) else { throw PetError("归档计划未打开") }
        checks["archivedEditorPreservesOriginalAndIsReadonly"] = !name.isEnabled && !prompt.isEditable && prompt.string == external.prompt
        archiveDefinition(); archived.selectItem(at: 0); changeArchiveFilter()
        checks["restoreRetainsIdentityAndStartsPaused"] = service.values.first(where: { $0.id == id }).map { !$0.archived && !$0.enabled && $0.prompt == external.prompt } == true
        create()
        checks["newEditorUsesOwningTaskWorkspace"] = editing && dirty && workspace.stringValue == sourceTaskID.flatMap(store.task)?.workspace && formScroll.contentView.bounds.minY < 0.5
        name.stringValue = "页内新建的公开计划"; prompt.string = "核对公开文件。"; enabled.state = .off; notify.state = .off; changed()
        let createdID = selectedID; saveDefinition()
        checks["inlineCreationPersistsWithoutEnablingExecution"] = !dirty && createdID.flatMap { id in service.values.first { $0.id == id } }.map { $0.name == name.stringValue && !$0.enabled && !$0.notify } == true
        returnToCatalog(); sections.selectedSegment = 1; onlySelected.state = .off; changeSection()
        let actual = try service.history()
        checks["historyShowsActualRunIdentifiersAndTotal"] = !records.isHidden && total == actual.total && Set(rows.compactMap { if case .run(let value) = $0 { return value.id }; return nil }) == Set(actual.runs.map(\.id))
        if let index = rows.firstIndex(where: { if case .run(let value) = $0 { return value.taskID != nil }; return false }) {
            history.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            checks["historyDetailsMatchActualRecord"] = detail.stringValue == selectedRun?.detail && openTask.isEnabled
            if let row = history.rowView(atRow: index, makeIfNecessary: true) as? AgentSettingsTableRow, let cell = history.view(atColumn: 0, row: index, makeIfNecessary: true) as? NSStackView, let secondary = cell.arrangedSubviews.last as? NSTextField {
                checks["selectedHistoryKeepsNormalTextStyle"] = row.interiorBackgroundStyle == .normal
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                        func rgba(_ color: NSColor) -> [CGFloat] { let c = color.usingColorSpace(.sRGB)!; return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent] }
                        func compose(_ front: [CGFloat], _ back: [CGFloat]) -> [CGFloat] { (0..<3).map { front[$0] * front[3] + back[$0] * (1 - front[3]) } + [1] }
                        func luminance(_ rgb: [CGFloat]) -> CGFloat { let linear = rgb.prefix(3).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }; return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722 }
                        let background = compose(rgba(row.selectionColor), rgba(AgentWorkbenchTheme.surface)), foreground = compose(rgba(secondary.textColor!), background)
                        let a = luminance(foreground), b = luminance(background), ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
                        checkSelectionContrasts[name] = ratio; checks[name + "SelectedHistoryTextContrast"] = ratio >= 4.5
                    }
                }
            } else { checks["selectedHistoryKeepsNormalTextStyle"] = false }
            let runID = selectedRun?.id; openRun()
            checks["openingActualRunMarksOnlyThatRecordRead"] = try service.history().runs.first(where: { $0.id == runID })?.unread == false
        } else { checks["historyDetailsMatchActualRecord"] = false }
        return checks
    }
}

private final class AgentAutomationTextField: NSTextField {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: super.intrinsicContentSize.height) }
}
