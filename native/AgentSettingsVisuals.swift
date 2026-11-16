import AppKit

@MainActor private final class AgentSettingsGlyph: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor final class AgentSettingsPopupFrame: AgentThemeView {
    private let popup: NSPopUpButton
    init(_ popup: NSPopUpButton) {
        self.popup = popup
        super.init(frame: .zero)
        fill = .clear; stroke = AgentWorkbenchTheme.line
        layer?.cornerRadius = 6; layer?.borderWidth = 1
        popup.isBordered = false; popup.controlSize = .regular; popup.font = .systemFont(ofSize: 13)
        (popup.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let chevron = AgentSettingsGlyph(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) ?? NSImage())
        chevron.contentTintColor = AgentWorkbenchTheme.secondaryText; chevron.setAccessibilityElement(false)
        for view in [popup, chevron] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        let limit = widthAnchor.constraint(lessThanOrEqualToConstant: 260); limit.priority = .defaultHigh
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28), widthAnchor.constraint(greaterThanOrEqualToConstant: 68), limit,
            popup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), popup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            popup.topAnchor.constraint(equalTo: topAnchor), popup.bottomAnchor.constraint(equalTo: bottomAnchor),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10), chevron.heightAnchor.constraint(equalToConstant: 10)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func mouseDown(with event: NSEvent) { if popup.isEnabled { popup.performClick(nil) } }
}

@MainActor final class AgentSettingsDivider: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame); translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true; setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) {
        AgentThemeContext.resolve(AgentWorkbenchTheme.line, in: self).withAlphaComponent(0.7).setStroke()
        let path = NSBezierPath(); path.move(to: NSPoint(x: 0, y: 0.5)); path.line(to: NSPoint(x: bounds.width, y: 0.5))
        path.lineWidth = 1; path.setLineDash([2, 3], count: 2, phase: 0); path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsDisplay = true }
}

@MainActor extension AgentSettingsStyle {
    static func divider() -> NSView { AgentSettingsDivider(frame: .zero) }
    static func rowIcon(_ title: String) -> NSView {
        let symbol: String
        switch title {
        case "运行中发送方式": symbol = "paperplane"
        case "Slash 命令展示方式": symbol = "command"
        case "问答面板静默跳过", "等待回答通知": symbol = "questionmark.bubble"
        case "产物文件默认打开位置", "产出": symbol = "tray"
        case "提示建议": symbol = "text.bubble"
        case "Skill 自进化建议", "Skills", "Skill 与 MCP": symbol = "sparkles"
        case "首页小游戏": symbol = "gamecontroller"
        case "对话显示", "侧边聊天": symbol = "bubble.left.and.bubble.right"
        case "思考状态": symbol = "brain"
        case "目标驱动执行", "任务目标": symbol = "scope"
        case "轮次完成通知", "权限请求通知", "系统通知": symbol = "bell"
        case "显示菜单栏图标": symbol = "menubar.rectangle"
        case "任务监控形式", "固定模式默认展示", "演示画面": symbol = "sidebar.right"
        case "任务回顾": symbol = "doc.text.magnifyingglass"
        case "回顾模型", "模型", "视觉理解", "思考程度": symbol = "cpu"
        case "计划": symbol = "checklist"
        case "子智能体": symbol = "person.2"
        case "后台进程": symbol = "terminal"
        case "网页查阅", "来源", "接口", "MCP": symbol = "globe"
        case "Token": symbol = "key"
        case "状态": symbol = "info.circle"
        case "知识", "记忆更新", "全局记忆", "项目记忆": symbol = "brain.head.profile"
        case "绑定主题", "明暗模式", "字体风格": symbol = "paintpalette"
        case "项目选择入口", "窗口连接": symbol = "folder"
        case "输入区运行环境", "启用电脑操作", "辅助功能": symbol = "desktopcomputer"
        case "变更审阅": symbol = "arrow.triangle.branch"
        case "屏幕录制", "自动观察": symbol = "viewfinder"
        case "全局快捷键": symbol = "keyboard"
        case "上下文", "回复上限": symbol = "text.alignleft"
        case "启用", "审批方式", "回收范围": symbol = "checkmark.shield"
        case "保留期", "观察间隔", "停顿等待": symbol = "clock"
        case "备份": symbol = "externaldrive"
        case "语音回复", "语音唤醒", "唤醒词": symbol = "waveform"
        case "音色": symbol = "person.wave.2"
        case "窗口置顶": symbol = "pin"
        case "动画": symbol = "play.rectangle"
        case "大小", "内容宽度", "对话字号": symbol = "textformat.size"
        case "文件图标": symbol = "doc"
        default: symbol = "slider.horizontal.3"
        }
        let box = AgentThemeView(fill: AgentWorkbenchTheme.subtle, stroke: AgentWorkbenchTheme.line)
        box.layer?.cornerRadius = 8; box.layer?.borderWidth = 0.5; box.setAccessibilityElement(false)
        let image = AgentSettingsGlyph(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.image = image.image?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        image.contentTintColor = AgentWorkbenchTheme.secondaryText; image.setAccessibilityElement(false)
        box.addSubview(image); image.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([box.widthAnchor.constraint(equalToConstant: 28), box.heightAnchor.constraint(equalToConstant: 28), image.centerXAnchor.constraint(equalTo: box.centerXAnchor), image.centerYAnchor.constraint(equalTo: box.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 14), image.heightAnchor.constraint(equalToConstant: 14)])
        return box
    }
}
