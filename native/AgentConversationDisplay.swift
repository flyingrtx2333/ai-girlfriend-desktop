import AppKit

enum AgentConversationDisplay {
    enum DurationFormat: String, Codable, CaseIterable {
        case seconds, tenths
        var title: String { self == .seconds ? "整数秒" : "一位小数" }
        func text(_ duration: TimeInterval?) -> String? {
            guard let duration, duration.isFinite, duration >= 0 else { return nil }
            return String(format: self == .seconds ? "%.0f 秒" : "%.1f 秒", locale: Locale(identifier: "en_US_POSIX"), duration)
        }
    }
    struct Settings: Codable, Equatable {
        var readingStart = false, toolCount = false, expandTools = false, collapseProcess = false
        var durationFormat = DurationFormat.seconds
        static let keys: Set<String> = ["readingStart", "toolCount", "expandTools", "collapseProcess", "durationFormat"]
    }
    static let searchTerms = "对话显示 新消息保持在阅读起点 显示工具调用次数 默认展开工具调用 折叠回复过程 耗时显示格式 整数秒 一位小数 Conversation Display Reading Tools Duration"
    struct Process {
        let replyID: String, messageIDs: [String], toolCount: Int
    }
    static func processes(_ task: AgentTaskRecord) -> [Process] {
        let visible = task.messages.filter { ["user", "assistant"].contains($0.role) && $0.nativeContext != true }
        var completed = Set((task.resultHistory ?? []).filter { $0.status == .completed }.compactMap(\.messageID))
        if task.status == .completed, let last = visible.last(where: \.isReply) { completed.insert(last.id) }
        var pending: [AgentMessage] = [], result: [Process] = []
        for message in visible {
            if message.role == "user" { pending = []; continue }
            guard message.isReply, completed.contains(message.id) else { pending.append(message); continue }
            let process = pending.filter { !$0.content.isEmpty || $0.reasoning?.isEmpty == false || ($0.toolCalls ?? []).contains { $0.name != "load_tools" } }
            if !process.isEmpty || message.reasoning?.isEmpty == false {
                result.append(Process(replyID: message.id, messageIDs: process.map(\.id) + [message.id], toolCount: process.flatMap { $0.toolCalls ?? [] }.filter { $0.name != "load_tools" }.count))
            }
            pending = []
        }
        return result
    }
}

@MainActor final class AgentReplyProcessRow: NSStackView {
    let body = NSStackView()
    private let header = NSView(), button = NSButton()
    private var folding: Bool?, caption = "处理过程"
    private(set) var expanded = true
    override init(frame: NSRect) {
        super.init(frame: frame); translatesAutoresizingMaskIntoConstraints = false; orientation = .vertical; alignment = .leading; spacing = 8
        button.isBordered = false; button.alignment = .left; button.font = .systemFont(ofSize: 12); button.contentTintColor = AgentWorkbenchTheme.secondaryText
        button.target = self; button.action = #selector(toggle); button.setAccessibilityLabel("处理过程")
        header.addSubview(button); button.translatesAutoresizingMaskIntoConstraints = false
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 8
        addArrangedSubview(header); addArrangedSubview(body)
        NSLayoutConstraint.activate([header.widthAnchor.constraint(equalTo: widthAnchor), header.heightAnchor.constraint(equalToConstant: 28), button.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 38), button.trailingAnchor.constraint(equalTo: header.trailingAnchor), button.topAnchor.constraint(equalTo: header.topAnchor), button.bottomAnchor.constraint(equalTo: header.bottomAnchor), body.widthAnchor.constraint(equalTo: widthAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(collapsed: Bool, toolCount: Int, showCount: Bool) {
        caption = "处理过程" + (showCount && toolCount > 0 ? " · \(toolCount) 次工具调用" : "")
        header.isHidden = !collapsed
        if folding != collapsed { folding = collapsed; setExpanded(!collapsed) }
        refreshTitle()
    }
    func setExpanded(_ value: Bool, animated: Bool = false) {
        guard expanded != value || body.isHidden == value else { return }
        expanded = value
        AgentWorkbenchTheme.layout(in: superview, duration: 0.14, animated: animated) { self.body.isHidden = !value }
        refreshTitle()
    }
    private func refreshTitle() { button.title = (expanded ? "⌄ " : "› ") + caption; button.setAccessibilityLabel(caption); button.setAccessibilityValue(expanded ? "已展开" : "已折叠") }
    @objc private func toggle() { setExpanded(!expanded, animated: true) }
    func readback() -> [String: Any] { ["expanded": expanded, "headerVisible": !header.isHiddenOrHasHiddenAncestor, "bodyVisible": !body.isHiddenOrHasHiddenAncestor, "caption": caption] }
}

final class AgentConversationHistory: NSScrollView {
    var onUserScroll: (() -> Void)?
    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaY != 0 { onUserScroll?() }
        super.scrollWheel(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if [115, 116, 119, 121, 125, 126].contains(event.keyCode) { onUserScroll?() }
        super.keyDown(with: event)
    }
}
