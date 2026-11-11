import AppKit

@MainActor final class AgentAutomationDraftRow: NSView {
    var onConfigure: (() -> Void)?
    init(_ draft: AgentAutomationDraft, saved: AgentAutomation?, issue: String? = nil) {
        super.init(frame: .zero); wantsLayer = true; layer?.cornerRadius = 10; layer?.borderWidth = 1
        let value = draft.automation, wasSaved = saved != nil || draft.savedAt != nil
        let name = NSTextField(labelWithString: String(value.name.prefix(80))); name.font = .systemFont(ofSize: 14, weight: .semibold); name.lineBreakMode = .byTruncatingTail
        let state = NSTextField(labelWithString: issue ?? (wasSaved ? (saved == nil ? "自动化 · 已移除" : saved!.archived ? "自动化 · 已归档" : saved!.enabled ? "自动化 · 已启用" : "自动化 · 已暂停") : "自动化草稿 · 未保存"))
        state.font = .systemFont(ofSize: 11); state.textColor = AgentWorkbenchTheme.secondaryText; state.lineBreakMode = .byTruncatingTail
        let button = NSButton(title: wasSaved ? "查看配置" : "继续配置", target: self, action: #selector(configure)); button.isEnabled = issue == nil && (!wasSaved || saved != nil); button.setAccessibilityLabel(button.title + " · " + value.name)
        let schedule = value.schedule, clock: String
        switch schedule.frequency {
        case .once: clock = AgentAutomations.dateText(schedule.date, zone: schedule.timeZone)
        case .interval: clock = "每\(schedule.intervalMinutes)分钟 · 开始 " + AgentAutomations.dateText(schedule.date, zone: schedule.timeZone)
        case .daily, .weekly:
            let days = schedule.frequency == .daily ? "每天" : schedule.weekdays.prefix(7).sorted().filter { (1...7).contains($0) }.map { "周" + ["日", "一", "二", "三", "四", "五", "六"][$0 - 1] }.joined(separator: "、")
            clock = days + String(format: " %02d:%02d", schedule.hour, schedule.minute)
        }
        let summary = NSTextField(wrappingLabelWithString: clock + " · " + String(schedule.timeZone.prefix(100)) + (schedule.expiration.map { " · 到期 " + AgentAutomations.dateText($0, zone: schedule.timeZone) } ?? "") + "\n" + (value.workspace.isEmpty ? "未选择项目" : String(value.workspace.prefix(4096))) + " · " + value.output.title)
        summary.font = .systemFont(ofSize: 12)
        let text = NSTextView(); text.isEditable = false; text.isRichText = false; text.font = .systemFont(ofSize: 12); text.string = String(value.prompt.prefix(40_000)); text.textContainerInset = NSSize(width: 8, height: 8); text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.setAccessibilityLabel("自动化草稿指令")
        let scroll = NSScrollView(); scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let header = NSStackView(views: [name, NSView(), state, button]); header.spacing = 10
        let content = NSStackView(views: [header, summary, scroll]); content.orientation = .vertical; content.alignment = .leading; content.spacing = 10; content.translatesAutoresizingMaskIntoConstraints = false; addSubview(content)
        for item in [header, summary, scroll] { item.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), content.topAnchor.constraint(equalTo: topAnchor, constant: 12), content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12), scroll.heightAnchor.constraint(equalToConstant: 150)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor; layer?.borderColor = NSColor.separatorColor.cgColor } }
    @objc private func configure() { onConfigure?() }
}
