import AppKit

@MainActor final class AgentHomeGamesView: NSView {
    private let service: AgentHomeGames, choice: () -> AgentHomeGameChoice
    private let board = AgentHomeGameBoard(), header = NSTextField(labelWithString: "活动"), detail = NSTextField(labelWithString: "")
    private let back = NSButton(title: "返回热力图", target: nil, action: nil), sound = NSButton(), action = NSButton(), entry = NSButton(title: "🍎", target: nil, action: nil)
    private let footer = NSTextField(labelWithString: ""), issue = NSTextField(labelWithString: "")
    private let reload = NSButton(title: "重新载入", target: nil, action: nil)
    private var context: String?, visible = false, invitation: AgentHomeGameKind?, kind: AgentHomeGameKind?
    private var snake: AgentPixelSnake?, blocks: AgentSidewaysBlocks?, timer: Timer?, dwell: Timer?
    private var running = false, started = false, ended = false, narrow = false, ticks = 0
    private var localError: String?, soundPlayer: NSSound?
    private var tracking: NSTrackingArea?, dates: [Date] = []
    private var lastSize = NSSize.zero
    init(service: AgentHomeGames, choice: @escaping () -> AgentHomeGameChoice) {
        self.service = service; self.choice = choice; super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false; wantsLayer = true; layer?.cornerRadius = 10; layer?.borderWidth = 1
        setAccessibilityElement(false); identifier = .init("home-activity-games")
        for field in [header, detail, footer, issue] { field.font = .systemFont(ofSize: 11); field.textColor = AgentWorkbenchTheme.secondaryText; field.lineBreakMode = .byTruncatingTail }
        header.font = .systemFont(ofSize: 11, weight: .medium); issue.textColor = .systemRed
        for button in [back, sound, action, entry, reload] { button.target = self; button.font = .systemFont(ofSize: 11); button.isBordered = false }
        reload.action = #selector(reloadGames); reload.identifier = .init("home-game-reload")
        back.action = #selector(returnToActivity); sound.action = #selector(toggleSound); action.action = #selector(activate); entry.action = #selector(openGame)
        back.identifier = .init("home-game-back"); sound.identifier = .init("home-game-sound"); action.identifier = .init("home-game-action"); entry.identifier = .init("home-game-entry")
        entry.font = .systemFont(ofSize: 14); action.bezelStyle = .rounded; action.isBordered = true
        for view in [header, detail, board, back, sound, footer, action, issue, reload, entry] { addSubview(view) }
        board.setAccessibilityElement(true); board.setAccessibilityRole(.group)
        board.onKey = { [weak self] code in self?.key(code) ?? false }
        board.onBlur = { [weak self] in self?.pause() }
        board.onClick = { [weak self] in guard let self, kind != nil else { return }; if !running && !ended { activate() } }
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification, NSWindow.willCloseNotification] { NotificationCenter.default.addObserver(self, selector: #selector(inactive), name: name, object: nil) }
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: AgentHomeGames.changed, object: service)
        heightAnchor.constraint(equalToConstant: 178).isActive = true; refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { timer?.invalidate(); dwell?.invalidate(); NotificationCenter.default.removeObserver(self) }
    override var isFlipped: Bool { true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.acceptsMouseMovedEvents = true; if window == nil { stopTimers() } }
    func show(_ show: Bool, context next: String) {
        if context != next { reset(); context = next }
        visible = show; isHidden = !show
        if !show { pause(); dwell?.invalidate(); dwell = nil }
        refresh()
    }
    private func stopTimers() { timer?.invalidate(); timer = nil; dwell?.invalidate(); dwell = nil }
    private func reset() {
        stopTimers(); soundPlayer?.stop(); running = false; started = false; ended = false; ticks = 0
        kind = nil; invitation = nil; snake = nil; blocks = nil; localError = nil
    }
    @objc private func inactive(_ note: Notification) { if note.object is NSWindow, note.object as? NSWindow !== window { return }; pause(); dwell?.invalidate(); dwell = nil }
    func pause() { guard running else { return }; running = false; timer?.invalidate(); timer = nil; soundPlayer?.stop(); refresh() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let value = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .enabledDuringMouseDrag, .activeInKeyWindow, .inVisibleRect], owner: self); addTrackingArea(value); tracking = value
    }
    override func mouseEntered(with event: NSEvent) { beginDwell() }
    override func mouseMoved(with event: NSEvent) { beginDwell() }
    private func beginDwell() {
        guard visible, kind == nil, invitation == nil, dwell == nil, window?.isKeyWindow == true else { return }
        dwell = Timer.scheduledTimer(withTimeInterval: service.activity.isEmpty ? 0.7 : 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.dwell = nil; guard self.visible, self.kind == nil, self.window?.isKeyWindow == true else { return }; self.invitation = self.choice().resolve(); self.refresh() }
        }
    }
    override func mouseExited(with event: NSEvent) { dwell?.invalidate(); dwell = nil }
    override func layout() {
        super.layout(); let width = bounds.width
        header.frame = .init(x: 16,y: 10,width: max(0,width - 140),height: 20); detail.frame = .init(x: max(16,width - 180),y: 10,width: 164,height: 20); detail.alignment = .right
        if kind != nil { detail.frame = .init(x:122,y:10,width:max(0,width - 172),height:20); detail.font = .systemFont(ofSize:10) } else { detail.font = .systemFont(ofSize:11) }
        back.frame = .init(x: 12,y: 8,width: 100,height: 24); sound.frame = .init(x: width - 42,y: 8,width: 26,height: 24)
        board.frame = .init(x: 16,y: 36,width: max(0,width - 32),height: 100)
        footer.frame = .init(x: 16,y: 146,width: max(0,width - 140),height: 18)
        action.frame = .init(x: max(16,width - 116),y: 143,width: 100,height: 24)
        issue.frame = .init(x: 122,y: 10,width: max(0,width - (reload.isHidden ? 172 : 260)),height: 20)
        reload.frame = .init(x: width - 132,y: 8,width: 88,height: 24)
        if invitation == nil { entry.frame = .init(x: max(16,width - 100),y:143,width:84,height:24) }
        else { let cell = board.rect(.init(x: 45,y: 3)); entry.frame = cell.offsetBy(dx: board.frame.minX - 3,dy: board.frame.minY - 3).insetBy(dx: -3,dy: -3) }
        let limited = width < 360
        if narrow != limited { narrow = limited; if narrow { pause() }; refresh() }
        if lastSize != bounds.size { lastSize = bounds.size; refreshTooltips() }
        applyColors()
    }
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = AgentThemeContext.resolve(AgentWorkbenchTheme.surface, in: self).cgColor
            layer?.borderColor = AgentThemeContext.resolve(AgentWorkbenchTheme.line, in: self).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors(); board.needsDisplay = true }
    private var score: Int { snake?.score ?? blocks?.score ?? 0 }
    private func rewards() -> [AgentGamePoint: Int] {
        var value: [AgentGamePoint:Int] = [:]
        for (i,date) in dates.enumerated() where service.activity[date,default:0] > 0 { value[.init(x: i / 7,y: i % 7)] = service.activity[date] }
        return value
    }
    @objc private func openGame() {
        guard visible, kind == nil else { return }
        kind = invitation ?? choice().resolve(); invitation = nil; begin()
    }
    private func begin() {
        guard let kind else { return }; stopTimers(); ticks = 0; ended = false; started = kind == .snake
        board.game = kind
        snake = kind == .snake ? AgentPixelSnake(bonuses: rewards()) : nil; blocks = kind == .blocks ? AgentSidewaysBlocks(ducks: rewards()) : nil
        running = false; if started { resume() } else { refresh(); window?.makeFirstResponder(board) }
    }
    @objc private func activate() {
        guard visible, !narrow, kind != nil, window?.isKeyWindow == true else { return }
        if ended { begin(); if !started { resume() } } else { resume() }
    }
    private func resume() {
        guard visible, !narrow, kind != nil, !ended, window?.isKeyWindow == true, NSApp.isActive else { refresh(); return }
        started = true; running = true; timer?.invalidate(); window?.makeFirstResponder(board)
        timer = Timer.scheduledTimer(withTimeInterval: kind == .snake ? 0.14 : 0.095, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.advance() } }
        refresh()
    }
    private func advance() {
        guard running, visible, !isHiddenOrHasHiddenAncestor, window?.isKeyWindow == true, NSApp.isActive, window?.firstResponder === board else { pause(); return }
        ticks += 1; let result = kind == .snake ? snake!.step() : blocks!.step()
        if result == .lost || result == .won { ended = true; running = false; timer?.invalidate(); timer = nil; play("Tink") }
        else if result == .food { play("Pop") } else if case .cleared = result { play("Pop") }
        if result != .moved { do { try service.record(score,kind: kind!) } catch { localError = error.localizedDescription } }
        refresh()
    }
    private func play(_ name: String) { guard service.settings.sound else { return }; soundPlayer?.stop(); soundPlayer = NSSound(named: NSSound.Name(name))?.copy() as? NSSound; soundPlayer?.volume = 0.15; soundPlayer?.play() }
    private func key(_ code: UInt16) -> Bool {
        guard kind != nil, visible else { return false }
        if code == 36 { if !running { activate() }; return true }
        if kind == .snake, code == 49 { return true }
        if kind == .blocks, code == 49 { if running { pause() } else { activate() }; return true }
        guard running else { return [123,124,125,126,0,1,2,13].contains(code) }
        if kind == .snake {
            switch code { case 123,0: snake?.turn(.left); case 124,2: snake?.turn(.right); case 125,1: snake?.turn(.down); case 126,13: snake?.turn(.up); default: return false }
        } else {
            switch code { case 125: _ = blocks?.move(dy: 1); case 126: _ = blocks?.move(dy: -1); case 123: _ = blocks?.rotate(); case 124: advance(); default: return false }; refresh()
        }; return true
    }
    @objc private func returnToActivity() { reset(); refresh(); window?.makeFirstResponder(back.nextKeyView) }
    @objc private func toggleSound() { do { try service.setSound(!service.settings.sound); if !service.settings.sound { soundPlayer?.stop() }; localError = nil } catch { localError = error.localizedDescription }; refresh() }
    @objc private func reloadGames() { service.reload(); localError = nil; refresh() }
    @objc private func refresh() {
        let today = Calendar.current.startOfDay(for: Date()), weekday = Calendar.current.component(.weekday, from: today) - 1
        if kind == nil {
            let start = Calendar.current.date(byAdding: .day,value: -(52 * 7 + weekday),to: today)!
            dates = (0..<371).map { Calendar.current.date(byAdding: .day,value: $0,to: start)! }
        }
        let game = kind != nil; header.isHidden = game; detail.isHidden = false; back.isHidden = !game; sound.isHidden = !game
        action.isHidden = !game || running; entry.isHidden = game || narrow
        entry.setAccessibilityLabel(invitation == nil ? "打开首页小游戏" : invitation == .blocks ? "打开横向俄罗斯方块游戏" : "打开像素贪吃蛇游戏")
        entry.title = invitation == nil ? "小游戏" : invitation == .blocks ? "🧩" : "🍎"; entry.font = .systemFont(ofSize:invitation == nil ? 11 : 14)
        issue.stringValue = localError ?? service.error ?? service.activityIssue ?? ""; issue.isHidden = issue.stringValue.isEmpty
        reload.isHidden = localError == nil && service.error == nil
        detail.isHidden = !issue.isHidden
        sound.image = NSImage(systemSymbolName: service.settings.sound ? "speaker.wave.2" : "speaker.slash", accessibilityDescription: nil); sound.setAccessibilityLabel(service.settings.sound ? "关闭游戏声音" : "打开游戏声音")
        if let kind {
            detail.stringValue = kind.instruction
            board.game = kind; board.snake = snake; board.blocks = blocks
            board.overlay = narrow ? "请增大窗口宽度" : ended ? "Game Over" : !started ? "按 Enter 开始" : !running ? "游戏已暂停" : nil
            board.setAccessibilityLabel(kind.title + "游戏"); board.setAccessibilityValue("\(score) 分，" + (ended ? "游戏结束" : running ? "进行中" : started ? "已暂停" : "等待开始"))
            action.title = ended ? "再来一局" : started ? "继续游戏" : "开始游戏"; action.isEnabled = !narrow
            footer.stringValue = "得分 \(score) · 最高 \(service.best(kind))"; footer.toolTip = kind.instruction
            back.toolTip = kind.instruction; board.toolTip = kind.instruction
        } else {
            board.game = nil; board.overlay = nil; board.values = dates.map { $0 > today ? -1 : service.activity[$0,default:0] }
            header.stringValue = "活动"; detail.stringValue = "\(dates.filter { $0 <= today && service.activity[$0,default:0] > 0 }.count) 个活跃日"
            footer.stringValue = service.activityLoading ? "正在读取活动…" : "已记录的活跃任务"; footer.toolTip = nil
            board.setAccessibilityLabel("任务活动热力图"); board.setAccessibilityValue(detail.stringValue); board.toolTip = nil
        }
        action.toolTip = kind?.instruction; board.needsDisplay = true; needsLayout = true; refreshTooltips()
    }
    private func refreshTooltips() {
        board.removeAllToolTips(); guard kind == nil else { return }
        for (i,date) in dates.enumerated() where date <= Date() { board.addToolTip(board.rect(.init(x: i / 7,y: i % 7)), owner: "\(DateFormatter.localizedString(from: date,dateStyle: .medium,timeStyle: .none)) · \(service.activity[date,default:0]) 项任务" as NSString, userData: nil) }
    }
    func readback() -> [String:Any] {
        ["visible":visible && !isHiddenOrHasHiddenAncestor,"context":context ?? "","kind":kind?.rawValue ?? "","invitation":invitation?.rawValue ?? "","running":running,"started":started,"ended":ended,"timer":timer?.isValid == true,"dwell":dwell?.isValid == true,"keyWindow":window?.isKeyWindow == true,"appActive":NSApp.isActive,"ticks":ticks,"score":score,"best":kind.map { service.best($0) } ?? 0,"sound":service.settings.sound,"board": [board.bounds.width,board.bounds.height],"cells":board.values.count,"activeDays":service.activity.count,"issue":localError ?? service.error ?? "","snake":snake?.body.map { [$0.x,$0.y] } ?? [],"blockOrigin":blocks.map { [$0.origin.x,$0.origin.y] } ?? [],"blockShape":blocks?.shape.map { [$0.x,$0.y] } ?? [],"focus":window?.firstResponder === board]
    }
}

@MainActor private final class AgentHomeGameBoard: NSView {
    var game: AgentHomeGameKind?, snake: AgentPixelSnake?, blocks: AgentSidewaysBlocks?, values: [Int] = [], overlay: String?
    var onKey: ((UInt16)->Bool)?, onBlur: (() -> Void)?, onClick: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { game != nil }
    override func resignFirstResponder() -> Bool { onBlur?(); return super.resignFirstResponder() }
    override func mouseDown(with event: NSEvent) { if game != nil { window?.makeFirstResponder(self); onClick?() } }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command,.control,.option]).isEmpty, onKey?(event.keyCode) == true { return }; super.keyDown(with: event)
    }
    func rect(_ point: AgentGamePoint) -> NSRect {
        let step = max(1,min(bounds.width / 53,bounds.height / 7)), gap = max(1,min(2,step * 0.15))
        return .init(x: (bounds.width - step * 53) / 2 + CGFloat(point.x) * step,y: (bounds.height - step * 7) / 2 + CGFloat(point.y) * step,width: step - gap,height: step - gap)
    }
    private func cell(_ point: AgentGamePoint, _ color: NSColor) { color.setFill(); NSBezierPath(roundedRect: rect(point),xRadius: 2,yRadius: 2).fill() }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for x in 0..<53 { for y in 0..<7 {
            let index = x * 7 + y, n = index < values.count ? values[index] : 0
            if game == nil && n < 0 { continue }
            cell(.init(x:x,y:y),game == nil && n > 0 ? AgentThemeContext.resolve(AgentWorkbenchTheme.accent,in:self).withAlphaComponent(min(1,0.25 + Double(n) * 0.15)) : AgentThemeContext.resolve(AgentWorkbenchTheme.subtle,in:self))
        } }
        func glyph(_ value: String, at point: AgentGamePoint) { let r = rect(point); (value as NSString).draw(in: r.insetBy(dx: -1,dy: -1),withAttributes: [.font:NSFont.systemFont(ofSize:max(8,r.height))]) }
        if game == .snake, let snake {
            for p in snake.rewards.keys { cell(p,AgentThemeContext.resolve(AgentWorkbenchTheme.accent,in:self).withAlphaComponent(0.45)) }
            for (i,p) in snake.body.enumerated() { cell(p,i == 0 ? .systemOrange : .systemYellow) }
            if let food = snake.food { glyph("🍎",at:food) }
        } else if game == .blocks, let blocks {
            for p in blocks.ducks.keys { glyph("🐤",at:p) }
            let colors: [NSColor] = [.systemCyan,.systemYellow,.systemPurple,.systemOrange,.systemBlue,.systemGreen,.systemRed]
            for (p,color) in blocks.settled { cell(p,colors[max(0,min(6,color - 1))]) }; for p in blocks.cells { cell(p,colors[blocks.piece.rawValue - 1]) }
        }
        if let overlay {
            AgentThemeContext.resolve(AgentWorkbenchTheme.surface,in:self).withAlphaComponent(0.88).setFill(); NSBezierPath(roundedRect:bounds.insetBy(dx:0,dy:4),xRadius:5,yRadius:5).fill()
            let text = NSAttributedString(string:overlay,attributes:[.font:NSFont.monospacedSystemFont(ofSize:18,weight:.semibold),.foregroundColor:NSColor.labelColor]); let size = text.size(); text.draw(at:.init(x:(bounds.width - size.width) / 2,y:(bounds.height - size.height) / 2))
        }
    }
}
