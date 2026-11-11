import AppKit

enum AgentTaskFind {
    struct Source: Equatable, Sendable { var messageID: String; var text: String }
    struct Match: Equatable, Sendable { var source: Source; var range: NSRange; var occurrence: Int }
    struct Entry: Sendable { var source: Source; var count: Int; var checkpoints: [NSRange] }
    struct Index: Sendable {
        var query: String, entries: [Entry], count: Int, locale: Locale
        var checkpointCount: Int { entries.reduce(0) { $0 + $1.checkpoints.count } }
        func match(at position: Int) -> Match? {
            guard position >= 0, position < count else { return nil }
            var remaining = position
            for entry in entries {
                if remaining >= entry.count { remaining -= entry.count; continue }
                let block = remaining / AgentTaskFind.stride, start = block * AgentTaskFind.stride
                guard entry.checkpoints.indices.contains(block) else { return nil }
                var range = entry.checkpoints[block]
                if remaining > start {
                    let text = entry.source.text as NSString
                    for _ in start..<remaining {
                        guard let next = AgentTaskFind.next(text, query: query, from: NSMaxRange(range), locale: locale) else { return nil }
                        range = next
                    }
                }
                return Match(source: entry.source, range: range, occurrence: remaining)
            }
            return nil
        }
        func position(of match: Match) -> Int? {
            var offset = 0
            for entry in entries {
                if entry.source.messageID == match.source.messageID, entry.count > 0 { return offset + min(match.occurrence, entry.count - 1) }
                offset += entry.count
            }
            return nil
        }
    }
    private static let stride = 256
    private static func next(_ text: NSString, query: String, from: Int, locale: Locale) -> NSRange? {
        guard !query.isEmpty, from >= 0, from < text.length else { return nil }
        let range = text.range(of: query, options: .caseInsensitive, range: NSRange(location: from, length: text.length - from), locale: locale)
        return range.location != NSNotFound && range.length > 0 ? range : nil
    }
    static func build(_ sources: [Source], query: String) throws -> Index {
        let locale = Locale.current
        guard !query.isEmpty else { return Index(query: query, entries: [], count: 0, locale: locale) }
        var entries: [Entry] = [], total = 0
        for source in sources {
            try Task.checkCancellation()
            let text = source.text as NSString
            var entry = Entry(source: source, count: 0, checkpoints: []), cursor = 0
            while let range = next(text, query: query, from: cursor, locale: locale) {
                if entry.count % stride == 0 {
                    try Task.checkCancellation()
                    // ponytail: retain one position per 256 hits, then scan at most
                    // that block when navigating; no result cap or per-hit text copy.
                    entry.checkpoints.append(range)
                }
                entry.count += 1; cursor = NSMaxRange(range)
            }
            total += entry.count; entries.append(entry)
        }
        try Task.checkCancellation()
        return Index(query: query, entries: entries, count: total, locale: locale)
    }
}

@MainActor final class AgentTaskFindBar: NSStackView, NSSearchFieldDelegate {
    var onMatch: ((String, AgentTaskFind.Match?) -> Void)?, onClose: (() -> Void)?
    private let search = NSSearchField(), counter = NSTextField(labelWithString: "0/0")
    private let previous = NSButton(), next = NSButton(), closeButton = NSButton()
    private var sources: [AgentTaskFind.Source] = [], indexedSources: [AgentTaskFind.Source] = []
    private var index: AgentTaskFind.Index?, position = 0, generation = 0
    private var requestedQuery = ""
    private var job: Task<Void, Never>?
    private(set) var taskID: String?
    override init(frame: NSRect) {
        super.init(frame: frame); orientation = .horizontal; alignment = .centerY; spacing = 6; isHidden = true
        search.placeholderString = "在当前任务中查找"; search.setAccessibilityLabel("当前任务查找"); search.delegate = self; search.target = self; search.action = #selector(queryChanged)
        search.setContentHuggingPriority(.defaultLow, for: .horizontal); search.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        counter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); counter.textColor = AgentWorkbenchTheme.secondaryText; counter.alignment = .right; counter.setAccessibilityLabel("查找结果")
        counter.widthAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        for (button, title, symbol, action) in [(previous, "上一个匹配", "chevron.up", #selector(previousMatch)), (next, "下一个匹配", "chevron.down", #selector(nextMatch)), (closeButton, "关闭查找", "xmark", #selector(closeFind))] {
            button.title = ""; button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); button.isBordered = false; button.target = self; button.action = action
            button.setAccessibilityLabel(title); button.toolTip = title; button.widthAnchor.constraint(equalToConstant: 24).isActive = true; button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        for view in [search, counter, previous, next, closeButton] { addArrangedSubview(view) }
        refreshCounter()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func open(taskID: String, sources: [AgentTaskFind.Source]) {
        if self.taskID != taskID { reset() }
        self.taskID = taskID; isHidden = false; update(taskID: taskID, sources: sources)
        window?.makeFirstResponder(search); search.selectText(nil)
    }
    func update(taskID: String, sources: [AgentTaskFind.Source]) {
        guard !isHidden, self.taskID == taskID else { return }
        guard self.sources != sources || index == nil else { return }
        self.sources = sources; startIndex()
    }
    func reset() {
        close(notify: false); taskID = nil; search.stringValue = ""; requestedQuery = ""; sources = []; indexedSources = []
    }
    func close(notify: Bool = true) {
        generation &+= 1; job?.cancel(); job = nil; index = nil; indexedSources = []; isHidden = true; position = 0
        if notify { onMatch?(search.stringValue, nil); onClose?() }
    }
    @objc private func closeFind() { close() }
    func controlTextDidChange(_ obj: Notification) { queryChanged() }
    @objc private func queryChanged() {
        guard requestedQuery != search.stringValue else { return }; requestedQuery = search.stringValue
        generation &+= 1; job?.cancel(); job = nil; index = nil; indexedSources = []; position = 0
        onMatch?(search.stringValue, nil); startIndex()
    }
    private func startIndex() {
        guard !isHidden, job == nil else { refreshCounter(); return }
        let query = search.stringValue
        guard !query.isEmpty else { index = nil; refreshCounter(); return }
        guard index == nil || indexedSources != sources else { refreshCounter(); return }
        let snapshot = sources, token = generation, preferred = index?.match(at: position)
        let worker = Task.detached(priority: .userInitiated) { try AgentTaskFind.build(snapshot, query: query) }
        job = Task { [weak self] in
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, !Task.isCancelled, generation == token, !isHidden, search.stringValue == query else { return }
                job = nil; index = result; indexedSources = snapshot
                position = preferred.flatMap { result.position(of: $0) } ?? min(position, max(0, result.count - 1))
                startIndex(); refreshCounter(); onMatch?(query, result.match(at: position))
            } catch {
                guard let self, generation == token else { return }
                job = nil; refreshCounter()
            }
        }
        refreshCounter()
    }
    private func refreshCounter() {
        let count = index?.count ?? 0
        counter.stringValue = job != nil && index == nil ? "查找中…" : "\(count == 0 ? 0 : position + 1)/\(count)" + (job == nil ? "" : "…")
        previous.isEnabled = count > 0; next.isEnabled = count > 0
    }
    private func move(_ delta: Int) {
        guard let index, index.count > 0 else { return }
        position = (position + delta + index.count) % index.count; refreshCounter(); onMatch?(index.query, index.match(at: position))
    }
    @objc private func previousMatch() { move(-1) }
    @objc private func nextMatch() { move(1) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.insertLineBreak(_:)) { move(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1); return true }
        return false
    }
    func checkState() -> [String: Any] {
        var value: [String: Any] = ["visible": !isHidden, "taskID": taskID as Any? ?? NSNull(), "query": search.stringValue, "count": index?.count ?? 0, "position": position, "busy": job != nil, "counter": counter.stringValue]
        if let match = index?.match(at: position) { value["match"] = ["messageID": match.source.messageID, "location": match.range.location, "length": match.range.length, "occurrence": match.occurrence] }
        return value
    }
}
