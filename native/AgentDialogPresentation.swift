import AppKit

// Short forms share a card inside their owning window. System file pickers
// remain native sheets and can temporarily take focus above this presentation.
@MainActor class AgentDialogController: NSViewController {
    weak var initialFocus: NSView?
    weak var defaultButton: NSButton? {
        didSet {
            declaredDefaultKey = defaultButton?.keyEquivalent ?? ""
            declaredDefaultModifiers = defaultButton?.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift]) ?? []
        }
    }
    // AppKit replaces the default cell's key equivalent with Return. Keep its
    // declared command shortcut independently, including after presentation reuse.
    fileprivate var declaredDefaultKey = ""
    fileprivate var declaredDefaultModifiers: NSEvent.ModifierFlags = []
    var selectInitialText = false, restoreFocusOnAccept = true
    var captureKey: ((NSEvent) -> Bool)?
    private weak var presentation: AgentDialogPresentation?
    var presentingWindow: NSWindow? { presentation?.owner }
    var isVisible: Bool { presentation != nil && view.window?.isVisible == true }
    var cardFrame: NSRect { view.frame }
    override var preferredContentSize: NSSize { didSet { presentation?.resize() } }

    init(title: String, size: NSSize) {
        super.init(nibName: nil, bundle: nil)
        self.title = title; preferredContentSize = size
        view = AgentThemeView(fill: AgentWorkbenchTheme.surface, stroke: AgentWorkbenchTheme.line)
        view.frame.size = size; view.wantsLayer = true
        view.layer?.cornerRadius = 12; view.layer?.borderWidth = 1
        view.setAccessibilityElement(true); view.setAccessibilityRole(.sheet); view.setAccessibilityLabel(title); view.setAccessibilityModal(true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func layoutForOwner(_ available: NSSize) {}
    @discardableResult func presentDialog(in owner: NSWindow, completion: @escaping (NSApplication.ModalResponse) -> Void) -> Bool {
        guard !owner.hasBlockingDialog, let content = owner.contentView else { return false }
        let next = AgentDialogPresentation(controller: self, owner: owner, content: content, completion: completion)
        presentation = next; next.begin(); return true
    }
    func endDialog(_ response: NSApplication.ModalResponse) { presentation?.finish(response) }
    @objc func cancel() { endDialog(.cancel) }
    func focusDialog() { presentation?.focus() }
    func presentationState() -> [String: Any] {
        guard let presentation, let owner = presentingWindow else { return ["visible": false] }
        owner.contentView?.layoutSubtreeIfNeeded()
        let rect = view.convert(view.bounds, to: presentation.overlay)
        return ["visible": isVisible, "title": title ?? "", "inWindow": view.window === owner,
                "nativeSheet": owner.attachedSheet != nil, "cardSize": [rect.width, rect.height],
                "centerError": [rect.midX - presentation.overlay.bounds.midX, rect.midY - presentation.overlay.bounds.midY]]
    }
    fileprivate func detached() { presentation = nil }
}

@MainActor extension NSWindow {
    var agentDialog: AgentDialogController? { AgentDialogPresentation.active(in: self)?.controller }
    var hasBlockingDialog: Bool { attachedSheet != nil || agentDialog != nil }
    func cancelAgentDialog() { agentDialog?.cancel() }
}

@MainActor private final class AgentDialogFieldEditor: NSTextView {
    private let editingUndo = UndoManager()
    private let editingStorage: NSTextStorage
    override var undoManager: UndoManager? { editingUndo }
    override init(frame: NSRect, textContainer: NSTextContainer?) {
        editingStorage = textContainer?.layoutManager?.textStorage ?? NSTextStorage()
        let container = textContainer ?? NSTextContainer(containerSize: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        if textContainer == nil { let layout = NSLayoutManager(); editingStorage.addLayoutManager(layout); layout.addTextContainer(container) }
        super.init(frame: frame, textContainer: container)
        isFieldEditor = true; isRichText = false; allowsUndo = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class AgentDialogFieldCell: NSTextFieldCell {
    override func fieldEditor(for controlView: NSView) -> NSTextView? { AgentDialogPresentation.editor(for: controlView) }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let field = controlView as? AgentDialogTextField else { super.draw(withFrame: cellFrame, in: controlView); return }
        field.effectiveAppearance.performAsCurrentDrawingAppearance {
            AgentThemeContext.resolve(field.backgroundColor ?? AgentWorkbenchTheme.card, in: field).setFill()
            NSBezierPath(roundedRect: cellFrame, xRadius: 6, yRadius: 6).fill()
            if !field.outlined {
                AgentThemeContext.resolve(AgentWorkbenchTheme.line, in: field).setStroke()
                let border = NSBezierPath(roundedRect: cellFrame.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
                border.lineWidth = 1; border.stroke()
            }
        }
        super.drawInterior(withFrame: cellFrame, in: controlView)
    }
}

@MainActor private final class AgentDialogSearchCell: NSSearchFieldCell {
    override func fieldEditor(for controlView: NSView) -> NSTextView? { AgentDialogPresentation.editor(for: controlView) }
}

@MainActor final class AgentDialogSearchField: NSSearchField {
    override init(frame: NSRect) { super.init(frame: frame); cell = AgentDialogSearchCell(textCell: ""); isEditable = true; isSelectable = true; isBezeled = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor private final class AgentDialogBackdrop: NSView {
    private let effect = NSVisualEffectView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        effect.frame = bounds; effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow; effect.blendingMode = .withinWindow; effect.state = .active
        effect.setAccessibilityElement(false); addSubview(effect)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}

@MainActor fileprivate final class AgentDialogPresentation {
    private static let sessions = NSMapTable<NSWindow, AgentDialogPresentation>.weakToStrongObjects()
    static func active(in owner: NSWindow) -> AgentDialogPresentation? { sessions.object(forKey: owner) }
    static func editor(for control: NSView) -> NSTextView? {
        guard let owner = control.window, let session = active(in: owner), control.isDescendant(of: session.controller.view) else { return nil }
        return session.fieldEditor
    }
    let controller: AgentDialogController
    weak var owner: NSWindow?
    let overlay: NSView
    private let fieldEditor = AgentDialogFieldEditor(frame: .zero, textContainer: nil)
    private weak var originalView: NSView?, originalText: NSTextView?
    private var originalString: String?, originalSelection: [NSValue]?, originalScroll: NSPoint?
    private weak var originalDefault: NSButtonCell?
    private let closeEnabled: Bool?
    private var hiddenViews: [(NSView, Bool)] = []
    private var monitor: Any?, observers: [NSObjectProtocol] = []
    private var width: NSLayoutConstraint!, height: NSLayoutConstraint!
    private var completion: ((NSApplication.ModalResponse) -> Void)?
    private var resizing = false, finished = false, focusedOnce = false

    init(controller: AgentDialogController, owner: NSWindow, content: NSView, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        self.controller = controller; self.owner = owner; self.completion = completion
        overlay = AgentDialogBackdrop(frame: content.bounds); overlay.autoresizingMask = [.width, .height]
        originalDefault = owner.defaultButtonCell
        closeEnabled = owner.standardWindowButton(.closeButton)?.isEnabled
        if let editor = owner.firstResponder as? NSTextView {
            originalText = editor; originalString = editor.string; originalSelection = editor.selectedRanges
            originalScroll = editor.enclosingScrollView?.contentView.bounds.origin
            originalView = editor.isFieldEditor ? editor.delegate as? NSView : editor
        } else { originalView = owner.firstResponder as? NSView }
    }
    func begin() {
        guard let owner, let content = owner.contentView else { return }
        // Finish the owner's edit before using a separate field editor. Its text,
        // undo stack and selection must never become the dialog's editing state.
        owner.makeFirstResponder(nil)
        hiddenViews = content.subviews.map { ($0, $0.isAccessibilityHidden()) }
        hiddenViews.forEach { $0.0.setAccessibilityHidden(true) }
        Self.sessions.setObject(self, forKey: owner)
        content.addSubview(overlay)
        let card = controller.view; card.translatesAutoresizingMaskIntoConstraints = false; overlay.addSubview(card)
        width = card.widthAnchor.constraint(equalToConstant: controller.preferredContentSize.width)
        height = card.heightAnchor.constraint(equalToConstant: controller.preferredContentSize.height)
        width.priority = .defaultHigh; height.priority = .defaultHigh
        NSLayoutConstraint.activate([card.centerXAnchor.constraint(equalTo: overlay.centerXAnchor), card.centerYAnchor.constraint(equalTo: overlay.centerYAnchor), width, height,
            card.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, constant: -32), card.heightAnchor.constraint(lessThanOrEqualTo: overlay.heightAnchor, constant: -32)])
        owner.defaultButtonCell = controller.defaultButton?.cell as? NSButtonCell
        owner.standardWindowButton(.closeButton)?.isEnabled = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }; return self.keyDown(event)
        }
        for name in [NSWindow.didResizeNotification, NSWindow.didEndSheetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: owner, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }; self.resize()
                    if note.name == NSWindow.didEndSheetNotification { self.focus() }
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.finish(.abort) } })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: owner, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let owner = self.owner, owner.isKeyWindow, owner.attachedSheet == nil else { return }
                if let current = self.focusedView(), !current.isDescendant(of: self.controller.view) { self.focus() }
            }
        })
        for name in [NSControl.textDidBeginEditingNotification, NSControl.textDidEndEditingNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let control = note.object as? NSControl, control.isDescendant(of: self.controller.view) else { return }
                    if note.name == NSControl.textDidBeginEditingNotification { self.prepareFieldUndo() }
                    else { self.fieldEditor.allowsUndo = false }
                }
            })
        }
        resize(); NSApp.activate(ignoringOtherApps: true); owner.makeKeyAndOrderFront(nil); focus()
        NSAccessibility.post(element: card, notification: .layoutChanged)
    }
    func resize() {
        guard !finished, !resizing else { return }; resizing = true
        controller.layoutForOwner(NSSize(width: max(0, overlay.bounds.width - 32), height: max(0, overlay.bounds.height - 32)))
        width.constant = controller.preferredContentSize.width; height.constant = controller.preferredContentSize.height
        overlay.layoutSubtreeIfNeeded(); resizing = false
    }
    func focus() {
        guard let owner, owner.attachedSheet == nil, !finished else { return }
        if let current = focusedView(), current.isDescendant(of: controller.view) { return }
        if let focus = controller.initialFocus { owner.makeFirstResponder(focus); if controller.selectInitialText && !focusedOnce { (focus as? NSTextField)?.selectText(nil) } }
        else { owner.makeFirstResponder(controller.defaultButton ?? controller.view) }
        focusedOnce = true
        if owner.firstResponder === fieldEditor { prepareFieldUndo() }
    }
    private func prepareFieldUndo() {
        guard !fieldEditor.allowsUndo else { return }
        fieldEditor.undoManager?.removeAllActions(); fieldEditor.allowsUndo = true
    }
    private func focusedView() -> NSView? {
        if let editor = owner?.firstResponder as? NSTextView, editor.isFieldEditor { return editor.delegate as? NSView }
        return owner?.firstResponder as? NSView
    }
    private func keyDown(_ event: NSEvent) -> NSEvent? {
        guard let owner, event.window === owner, NSApp.keyWindow === owner, owner.attachedSheet == nil, !finished else { return event }
        if controller.captureKey?(event) == true { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let editor = owner.firstResponder as? NSTextView
        if modifiers.contains(.command) {
            // Let the active text editor handle standard editing. Other key
            // equivalents are confined to the card, including Command-S.
            if let current = focusedView(), current.isDescendant(of: controller.view), editor != nil,
               (["a", "c", "v", "x", "z"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") || [51, 117, 123, 124, 125, 126].contains(event.keyCode)) { return event }
            if editor?.hasMarkedText() != true {
                if let button = controller.defaultButton, button.isEnabled,
                   controller.declaredDefaultKey.lowercased() == event.charactersIgnoringModifiers?.lowercased(), controller.declaredDefaultModifiers == modifiers {
                    button.performClick(nil); return nil
                }
                func button(in view: NSView) -> NSButton? {
                    if let button = view as? NSButton, button.isEnabled, !button.isHiddenOrHasHiddenAncestor,
                       button.keyEquivalent == event.charactersIgnoringModifiers, button.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift]) == modifiers { return button }
                    return view.subviews.lazy.compactMap { button(in: $0) }.first
                }
                button(in: controller.view)?.performClick(nil)
            }
            return nil
        }
        if editor?.hasMarkedText() == true { return event }
        if event.keyCode == 53, modifiers.isEmpty { controller.cancel(); return nil }
        if [36, 76].contains(event.keyCode), modifiers.isEmpty {
            if let button = controller.defaultButton, button.isEnabled { button.performClick(nil) }
            return nil
        }
        if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift {
            let current = (editor?.isFieldEditor == true ? editor?.delegate as? NSView : owner.firstResponder as? NSView) ?? controller.initialFocus
            var candidate = modifiers == .shift ? current?.previousValidKeyView : current?.nextValidKeyView
            var visited = Set<ObjectIdentifier>()
            while let next = candidate, visited.insert(ObjectIdentifier(next)).inserted {
                if next.isDescendant(of: controller.view), !next.isHiddenOrHasHiddenAncestor { owner.makeFirstResponder(next); return nil }
                candidate = modifiers == .shift ? next.previousValidKeyView : next.nextValidKeyView
            }
            focus(); return nil
        }
        return event
    }
    func finish(_ response: NSApplication.ModalResponse) {
        guard !finished else { return }; finished = true
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        let callback = completion; completion = nil
        if let owner {
            owner.makeFirstResponder(nil)
            Self.sessions.removeObject(forKey: owner)
            controller.view.removeFromSuperview(); overlay.removeFromSuperview()
            hiddenViews.forEach { $0.0.setAccessibilityHidden($0.1) }; hiddenViews.removeAll()
            owner.defaultButtonCell = originalDefault; controller.detached()
            if let closeEnabled { owner.standardWindowButton(.closeButton)?.isEnabled = closeEnabled }
            if owner.isVisible, response != .abort, response != .OK || controller.restoreFocusOnAccept {
                owner.makeKeyAndOrderFront(nil)
                if let originalView, originalView.window === owner, !originalView.isHiddenOrHasHiddenAncestor {
                    owner.makeFirstResponder(originalView)
                    let text = (originalView as? NSControl)?.currentEditor() as? NSTextView ?? originalText
                    if let text, text.string == originalString, let originalSelection {
                        text.selectedRanges = originalSelection
                        if let originalScroll, let scroll = text.enclosingScrollView { scroll.contentView.scroll(to: originalScroll); scroll.reflectScrolledClipView(scroll.contentView) }
                    }
                }
            }
            NSAccessibility.post(element: owner, notification: .layoutChanged)
        } else { controller.detached() }
        callback?(response)
    }
}
