import AppKit

@MainActor final class AgentSkillSuggestionsView: NSStackView {
    private let items: [AgentSkillEvolutionSuggestion]
    private var selected: Set<String>
    private var checks: [String:NSButton] = [:]
    private let adopt = NSButton(title:"创建改进任务",target:nil,action:nil), dismiss = NSButton(title:"忽略",target:nil,action:nil), all = NSButton(checkboxWithTitle:"全选",target:nil,action:nil)
    var onSelection: ((Set<String>)->Void)?
    var onCurate: ((Set<String>,Bool)->Void)?, onOpen: ((String)->Void)?, onSource:(()->Void)?, onRetry:(()->Void)?
    init(items:[AgentSkillEvolutionSuggestion], selected:Set<String>, generating:Bool, issue:String?, analyzed:Bool, canGenerate:Bool) {
        self.items = items; self.selected = selected.intersection(items.filter{$0.state == .pending}.map(\.id)); super.init(frame:.zero)
        orientation = .vertical; alignment = .leading; spacing = 10; identifier = .init("skill-evolution-suggestions")
        for (index,item) in items.enumerated() {
            if item.state == .pending {
                let check = NSButton(checkboxWithTitle:item.title,target:self,action:#selector(selectSuggestion(_:))); check.font = .systemFont(ofSize:12,weight:.medium); check.lineBreakMode = .byTruncatingTail
                check.tag = index; check.toolTip = item.goal; check.setAccessibilityLabel("选择 Skill 建议：" + item.title); check.identifier = .init("skill-suggestion-" + item.id); checks[item.id] = check
                let reason = NSTextField(wrappingLabelWithString:item.reason); reason.font = .systemFont(ofSize:11); reason.textColor = AgentWorkbenchTheme.secondaryText
                let target = NSTextField(labelWithString:item.target.map { "改进 · " + $0.name } ?? "创建 Skill"); target.font = .systemFont(ofSize:11); target.textColor = AgentWorkbenchTheme.secondaryText
                let row = NSStackView(views:[check,reason,target]); row.orientation = .vertical; row.alignment = .leading; row.spacing = 5; addArrangedSubview(row); row.widthAnchor.constraint(equalTo:widthAnchor).isActive = true
                check.widthAnchor.constraint(lessThanOrEqualTo:row.widthAnchor).isActive = true; reason.widthAnchor.constraint(equalTo:row.widthAnchor).isActive = true
            } else if item.state == .adopted, let id = item.taskID {
                let open = NSButton(title:"查看任务 · " + item.title,target:self,action:#selector(openTask(_:))); open.font = .systemFont(ofSize:11); open.isBordered = false; open.tag = index; open.toolTip = id; open.lineBreakMode = .byTruncatingTail; addArrangedSubview(open); open.widthAnchor.constraint(lessThanOrEqualTo:widthAnchor).isActive = true
            }
        }
        if items.contains(where:{$0.state == .pending}) {
            adopt.target = self; adopt.action = #selector(createTasks); dismiss.target = self; dismiss.action = #selector(ignoreItems); all.target = self; all.action = #selector(selectAllSuggestions)
            for button in [adopt,dismiss,all] { button.font = .systemFont(ofSize:11) }; all.allowsMixedState = true
            if checks.count > 1 { addArrangedSubview(all) }
            let actions = NSStackView(views:[adopt,dismiss]); actions.spacing = 8; addArrangedSubview(actions)
        }
        if generating { let value = NSTextField(labelWithString:"正在分析可复用经验…"); value.font = .systemFont(ofSize:11); value.textColor = AgentWorkbenchTheme.secondaryText; addArrangedSubview(value) }
        if let issue { let value = NSTextField(wrappingLabelWithString:issue); value.font = .systemFont(ofSize:11); value.textColor = .systemRed; addArrangedSubview(value); value.widthAnchor.constraint(equalTo:widthAnchor).isActive = true }
        let source = NSButton(title:"查看来源",target:self,action:#selector(showSource)); source.font = .systemFont(ofSize:11); source.isBordered = false
        let retry = NSButton(title:analyzed || issue != nil ? "重新生成建议" : "生成 Skill 建议",target:self,action:#selector(regenerate)); retry.font = .systemFont(ofSize:11); retry.isBordered = false; retry.isEnabled = canGenerate && !generating; retry.toolTip = "使用当前模型分析任务经验，会额外使用一次模型请求。"
        let footer = NSStackView(views:[source,retry]); footer.spacing = 8; addArrangedSubview(footer)
        if analyzed, items.isEmpty, !generating, issue == nil { let empty = NSTextField(labelWithString:"暂无可复用建议"); empty.font = .systemFont(ofSize:11); empty.textColor = AgentWorkbenchTheme.secondaryText; insertArrangedSubview(empty,at:0) }
        updateSelection()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    private func updateSelection() { for (id,button) in checks { button.state = selected.contains(id) ? .on : .off }; adopt.isEnabled = !selected.isEmpty; dismiss.isEnabled = !selected.isEmpty; all.state = selected.isEmpty ? .off : selected.count == checks.count ? .on : .mixed; onSelection?(selected) }
    @objc private func selectSuggestion(_ button:NSButton) { guard items.indices.contains(button.tag), items[button.tag].state == .pending else { return }; let id = items[button.tag].id; if button.state == .on { selected.insert(id) } else { selected.remove(id) }; updateSelection() }
    @objc private func selectAllSuggestions() { selected = all.state == .off ? [] : Set(checks.keys); updateSelection() }
    @objc private func createTasks() { onCurate?(selected,true) }
    @objc private func ignoreItems() { onCurate?(selected,false) }
    @objc private func showSource() { onSource?() }
    @objc private func regenerate() { onRetry?() }
    @objc private func openTask(_ button:NSButton) { guard items.indices.contains(button.tag), let id = items[button.tag].taskID else { return }; onOpen?(id) }
}

@MainActor final class AgentSkillJobRow: NSStackView {
    var onConfirm:(()->Void)?, onReview:(()->Void)?, onOpen:(()->Void)?, onSource:(()->Void)?
    init(task:AgentTaskRecord, ready:Bool, issue:String?) {
        super.init(frame:.zero); orientation = .vertical; alignment = .leading; spacing = 9; identifier = .init("skill-evolution-job")
        let title = NSTextField(labelWithString:task.skillEvolutionJob?.target.map { "Skill · " + $0.name } ?? "创建 Skill"); title.font = .systemFont(ofSize:14,weight:.semibold)
        let source = NSButton(title:"来源任务",target:self,action:#selector(openSource)); source.isBordered = false; source.font = .systemFont(ofSize:11); source.toolTip = task.skillEvolutionJob?.sourceTitle
        let header = NSStackView(views:[title,NSView(),source]); header.spacing = 8; addArrangedSubview(header); header.widthAnchor.constraint(equalTo:widthAnchor).isActive = true
        let state: String
        if let issue { state = issue }
        else if task.skillDraft?.savedAt != nil { state = "Skill 已保存" }
        else if task.skillDraft != nil { state = ready ? "草稿待审阅" : "草稿尚未完成" }
        else if task.skillEvolutionJob?.approvedPlan != nil { state = "方案已确认" }
        else { state = AgentSkillDrafts.planSource(task) == nil ? "待生成方案" : "方案待确认" }
        let label = NSTextField(wrappingLabelWithString:state); label.font = .systemFont(ofSize:12); label.textColor = issue == nil ? AgentWorkbenchTheme.secondaryText : .systemRed; addArrangedSubview(label); label.widthAnchor.constraint(equalTo:widthAnchor).isActive = true
        if task.skillDraft?.savedAt != nil { let button = NSButton(title:"查看技能",target:self,action:#selector(openSkill)); addArrangedSubview(button) }
        else if task.skillDraft != nil { let button = NSButton(title:"审阅技能",target:self,action:#selector(review)); button.isEnabled = ready && issue == nil && task.status != .running; button.identifier = .init("skill-draft-review"); addArrangedSubview(button) }
        else if AgentSkillDrafts.planSource(task) != nil { let button = NSButton(title:"确认方案并生成",target:self,action:#selector(confirm)); button.isEnabled = issue == nil; button.identifier = .init("skill-plan-confirm"); addArrangedSubview(button) }
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func confirm() { onConfirm?() }
    @objc private func review() { onReview?() }
    @objc private func openSkill() { onOpen?() }
    @objc private func openSource() { onSource?() }
}

@MainActor final class AgentSkillDraftReviewPage: AgentSettingsReviewPage, NSTextFieldDelegate {
    private let store:AgentStore, taskID:String, draft:AgentSkillDraft, job:AgentSkillEvolutionJob, revision:String
    private let name: NSTextField, scope: NSPopUpButton
    private var initialName = "", initialProject = false, applied = false
    init(store:AgentStore, taskID:String) throws {
        guard let task = store.task(taskID), let draft = task.skillDraft, draft.savedAt == nil else { throw PetError("没有可审阅的 Skill 草稿") }
        self.store = store; self.taskID = taskID; self.draft = draft
        let job = try AgentSkillDrafts.job(task,store:store), revision = AgentSkillDrafts.revision(draft); self.job = job; self.revision = revision
        let name = NSTextField(), scope = NSPopUpButton(); self.name = name; self.scope = scope
        let resources = try AgentSkillDrafts.proposed(draft,job:job,store:store), document = try AgentExtensionDocument(String(decoding:resources["SKILL.md"]!,as:UTF8.self))
        let initialName = job.target?.name ?? document.metadata["name"] ?? ""; self.initialName = initialName; name.stringValue = initialName; name.setAccessibilityLabel("Skill 名称"); name.identifier = .init("skill-review-name"); name.isEditable = job.target == nil
        scope.addItems(withTitles:["用户","项目"]); scope.setAccessibilityLabel("Skill 保存范围"); scope.identifier = .init("skill-review-scope"); scope.item(at:1)?.isEnabled = task.workspace != nil
        let initialProject = job.target.map { (try? store.extensions.item($0.id,workspace:task.workspace).scope) == "项目" } ?? (task.workspace != nil); self.initialProject = initialProject; scope.selectItem(at:initialProject ? 1 : 0); scope.isEnabled = job.target == nil
        let rows = [AgentSettingsStyle.formRow("名称",name,trailing:false),AgentSettingsStyle.formRow("保存范围",scope,trailing:false)]
        let sections = Self.previewSections(resources,original:try AgentSkillDrafts.base(job,store:store))
        super.init(title:"审阅 Skill",metadata:job.sourceTitle,notice:"",sections:sections,applyTitle:job.target == nil ? "创建 Skill" : "应用改进",controls:rows)
        name.delegate = self; scope.target = self; scope.action = #selector(scopeChanged)
        onApply = { [weak self] in
            guard let self else { throw CancellationError() }; _ = try AgentSkillDrafts.apply(taskID:taskID,draftID:draft.id,revision:revision,name:name.stringValue,project:scope.indexOfSelectedItem == 1,store:store); self.applied = true
        }; refreshPreview()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    func controlTextDidChange(_ notification:Notification) { refreshPreview() }
    @objc private func scopeChanged() { refreshPreview() }
    private func refreshPreview() {
        do {
            let values = try AgentSkillDrafts.proposed(draft,job:job,store:store,name:name.stringValue), original = try AgentSkillDrafts.base(job,store:store)
            updateSections(Self.previewSections(values,original:original))
        } catch { updateSections([("无法审阅",error.localizedDescription)]) }
    }
    private static func previewSections(_ values:[String:Data], original:[String:Data]) -> [(String,String)] {
        let sections = values.keys.sorted().filter { values[$0] != original[$0] }.map { path -> (String,String) in
            let next = String(decoding:values[path]!,as:UTF8.self)
            if let before = original[path] { return (path,"现有版本\n\n" + (String(data:before,encoding:.utf8) ?? "二进制资源") + "\n\n拟保存版本\n\n" + next) }
            return (path,next)
        }
        return sections.isEmpty ? [("Skill","草稿与当前 Skill 一致")] : sections
    }
    override func windowShouldClose(_ sender:NSWindow) -> Bool {
        guard super.windowShouldClose(sender) else { return false }
        if !applied, name.stringValue != initialName || (scope.indexOfSelectedItem == 1) != initialProject { return AgentUnsavedChanges.discard("放弃未应用的名称与保存范围？") }; return true
    }
}
