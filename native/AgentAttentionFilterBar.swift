import AppKit

@MainActor final class AgentAttentionFilterBar: NSView {
    private let menus: [NSPopUpButton]
    private let frames: [AgentSettingsPopupFrame]
    private let search: NSSearchField
    private var height: NSLayoutConstraint!
    var showsHistory = false {
        didSet {
            for index in 2...3 { menus[index].isHidden = !showsHistory; frames[index].isHidden = !showsHistory }
            updateHeight(); needsLayout = true
        }
    }
    override var isFlipped: Bool { true }
    init(kind: NSPopUpButton, source: NSPopUpButton, time: NSPopUpButton, sender: NSPopUpButton, search: NSSearchField) {
        menus = [kind, source, time, sender]; frames = menus.map { AgentSettingsPopupFrame($0) }; self.search = search
        super.init(frame: .zero)
        for view in frames { addSubview(view) }; addSubview(search)
        height = heightAnchor.constraint(equalToConstant: 28); height.isActive = true
        for index in 2...3 { menus[index].isHidden = true; frames[index].isHidden = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private var wraps: Bool { showsHistory && bounds.width < 700 }
    private func updateHeight() { height?.constant = wraps ? 64 : 28 }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateHeight() }
    override func layout() {
        super.layout(); updateHeight()
        let widths: [CGFloat] = [112, 112, 104, 120]
        var x: CGFloat = 0
        for index in 0..<4 {
            if index == 2 && wraps { x = 0 }
            frames[index].frame = NSRect(x: x, y: index >= 2 && wraps ? 36 : 0, width: widths[index], height: 28)
            x += widths[index] + 8
        }
        let used: CGFloat = showsHistory && !wraps ? 480 : 240
        let width = min(280, max(140, bounds.width - used))
        search.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: 28)
    }
    var controlsFit: Bool {
        let controls: [NSView] = frames.filter { !$0.isHidden }.map { $0 as NSView } + [search]
        return controls.allSatisfy { bounds.insetBy(dx: -0.5, dy: -0.5).contains($0.frame) } && controls.enumerated().allSatisfy { index, view in
            controls.dropFirst(index + 1).allSatisfy { !view.frame.intersects($0.frame) }
        }
    }
}
