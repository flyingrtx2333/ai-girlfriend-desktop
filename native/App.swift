import AppKit
import WebKit
import AVFAudio
import UniformTypeIdentifiers

final class AssetScheme: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root.standardizedFileURL }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "app" else {
            urlSchemeTask.didFailWithError(PetError("资源地址无效。")); return
        }
        let path = url.path.removingPercentEncoding ?? url.path
        let file = root.appendingPathComponent(path == "/" ? "index.html" : String(path.dropFirst())).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            urlSchemeTask.didFailWithError(PetError("应用资源不存在。")); return
        }
        let mime: String
        switch file.pathExtension.lowercased() {
        case "js": mime = "text/javascript"
        case "css": mime = "text/css"
        case "html": mime = "text/html"
        default: mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
        let policy = "default-src 'self' pet: data: blob:; script-src 'self' pet:; style-src 'self' pet: 'unsafe-inline'; img-src 'self' pet: data: blob:; connect-src 'self' pet:; font-src 'self' pet: data:; media-src 'self' pet: blob: data:"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": mime, "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*",
            "Content-Security-Policy": policy, "Cache-Control": "no-cache",
        ])!
        urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class PetWebView: WKWebView {
    var contextMenu: (() -> NSMenu)?
    override func rightMouseDown(with event: NSEvent) {
        if let menu = contextMenu?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
        else { super.rightMouseDown(with: event) }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate, AVAudioPlayerDelegate, NSMenuDelegate {
    let store: PreferencesStore
    let checkDirectory: URL?
    var pet: PetPanel!
    var web: WKWebView!
    var scheme: AssetScheme!
    var statusItem: NSStatusItem!
    lazy var control = ControlWindow(companion: self)
    lazy var screenCompanion = ScreenCompanion(host: self)
    var agentStore: AgentStore?
    var agentRuntime: AgentRuntime?
    let automationNotifications = AgentAutomationNotifications()
    var agentAnimationPhase = "idle"
    var usesAgent: Bool { checkDirectory == nil || ["--agent-check", "--agent-ui-check", "--context-check", "--git-check", "--index-check", "--wiki-ui-check", "--attachment-ui", "--live-attachments", "--live-visuals", "--browser-check", "--extension-check", "--mcp-check", "--mcp-content-check", "--hook-check", "--hook-service-check", "--hook-async-check", "--custom-agent-check", "--workbench-check", "--automation-check", "--task-model-check", "--worktree-creation-check", "--retention-check", "--file-change-check", "--desktop-check", "--canvas-check"].contains(where: CommandLine.arguments.contains) }
    var selectedAgentBusy: Bool { agentStore?.selectedID.map { agentRuntime?.isRunning($0) == true } ?? false }
    var bubble: PetPanel?
    var bubbleLabel: NSTextField?
    var bubbleStopButton: NSButton?
    var bubbleTimer: Timer?
    var player: AVAudioPlayer?
    var speechAnimation: SpeechAnimation?
    var wakePlayer: AVAudioPlayer?
    var meterTimer: Timer?
    var lastVolume = 0.0
    var voiceGeneration = 0
    var speechFollowUp = true
    var speechTask: Task<Void, Never>?
    var chatTask: Task<Void, Never>?
    var undoMessages: [ChatMessage]?
    var ready = false, sleeping = false, renderVisible = false
    var diagnostics: [String] = []
    var globalMouse: Any?, localMouse: Any?
    var pointerInside = false, pointerGeneration = 0, lastPointerQuery = 0.0
    var dragOrigin: (mouse: NSPoint, window: NSPoint, motion: NSPoint)?
    var pendingPress: (mouse: NSPoint, window: NSPoint, motion: NSPoint, moved: Bool)?
    var motionTranslation = NSPoint.zero
    var dragged = false
    var closing = false
    var onScaleChange: ((Double) -> Void)?
    var onWakeChange: ((Bool, String) -> Void)?
    var scaleSaveTimer: Timer?
    var wakeStatus = "未开启", wakeError: String?
    var appliedWake: (Bool, String, Double)?
    var pendingVoiceListen = false
    lazy var voiceWake: VoiceWake = {
        let wake = VoiceWake(); wake.onEvent = { [weak self] event in self?.voiceEvent(event) }; return wake
    }()

    override init() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--check"), args.count > index + 1 {
            checkDirectory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        } else { checkDirectory = nil }
        let directory = checkDirectory?.appendingPathComponent("profile", isDirectory: true)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish", isDirectory: true)
        store = PreferencesStore(directory: directory, testing: checkDirectory != nil)
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenu(); setupPet(); setupMouse()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspace.addObserver(self, selector: #selector(willSleep), name: name, object: nil)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspace.addObserver(self, selector: #selector(didWake), name: name, object: nil)
        }
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(frontApplicationChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(powerChanged), name: .NSProcessInfoPowerStateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        if checkDirectory == nil { ensureAgent(); if !store.keychain.contains("chat") { control.show(tab: "settings") } }
    }
    func applicationWillTerminate(_ notification: Notification) {
        if agentStore != nil { control.persistAgentDraft() }
        closing = true; screenCompanion.suspend(); chatTask?.cancel(); agentRuntime?.stopAll(); agentStore?.automations.stop(); agentStore?.worktreeRetention.stop(); stopSpeech()
        agentStore?.browser.closeAll()
        agentStore?.canvases.closeAll()
        agentStore?.desktop.disconnectAll()
        voiceWake.stop(); scaleSaveTimer?.invalidate()
        if let globalMouse { NSEvent.removeMonitor(globalMouse) }
        if let localMouse { NSEvent.removeMonitor(localMouse) }
        try? store.saveHistory(); try? store.savePreferences()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "fish.fill", accessibilityDescription: "蓝色大肥鱼") {
            image.isTemplate = true; statusItem.button?.image = image
        } else { statusItem.button?.title = "鲸" }
        statusItem.button?.toolTip = "蓝色大肥鱼"
        statusItem.menu = menu()
        let main = NSMenu(), appMenu = NSMenu(), item = NSMenuItem()
        appMenu.addItem(withTitle: "停止录音", action: #selector(stopRecording), keyEquivalent: "\u{1b}").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出蓝色大肥鱼", action: #selector(quit), keyEquivalent: "q").target = self
        item.submenu = appMenu; main.addItem(item)
        let edit = NSMenu(title: "编辑"), editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = edit; main.addItem(editItem); NSApp.mainMenu = main
    }
    func menu() -> NSMenu {
        let m = NSMenu(); m.delegate = self; m.autoenablesItems = false; m.showsStateColumn = false; m.minimumWidth = 208
        let size = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
        size.view = SizeMenuView(value: store.preferences.scale) { [weak self] value in self?.setPetScale(value) ?? value }
        m.addItem(size); m.addItem(.separator())
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self
            m.addItem(item)
        }
        add("聊天", #selector(openChat)); add("设置", #selector(openSettings))
        if store.preferences.wakeEnabled { add("停止录音", #selector(stopRecording)) }
        m.addItem(.separator())
        add(pet?.isVisible == true ? "收起角色" : "显示角色", #selector(togglePet))
        add("退出", #selector(quit))
        return m
    }
    func menuWillOpen(_ menu: NSMenu) {
        screenCompanion.interaction()
        for item in menu.items {
            (item.view as? SizeMenuView)?.setValue(store.preferences.scale)
        }
    }
    func setupPet() {
        let frame = initialFrame()
        pet = PetPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        pet.title = "小鲸"; pet.isOpaque = false; pet.backgroundColor = .clear
        pet.setAccessibilityRole(.window); pet.setAccessibilitySubrole(.standardWindow)
        pet.hasShadow = false; pet.hidesOnDeactivate = false; pet.isFloatingPanel = true
        pet.isReleasedWhenClosed = false; pet.acceptsMouseMovedEvents = true
        pet.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        pet.delegate = self; pet.ignoresMouseEvents = true
        pet.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "聊天", target: self, selector: #selector(accessibilityChat)),
            NSAccessibilityCustomAction(name: "设置", target: self, selector: #selector(accessibilitySettings)),
        ])
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let root = Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true)
        scheme = AssetScheme(root: root); config.setURLSchemeHandler(scheme, forURLScheme: "pet")
        config.userContentController.add(self, name: "whale")
        let bridge = """
        window.whaleNative = { post(action, payload = {}) { window.webkit.messageHandlers.whale.postMessage({action, payload}); } };
        window.whaleNativeReceive = detail => window.dispatchEvent(new CustomEvent('whale-native', {detail}));
        window.addEventListener('error', e => window.whaleNative.post('error', {message: String(e.message)}));
        window.addEventListener('unhandledrejection', e => window.whaleNative.post('error', {message: String(e.reason)}));
        """
        config.userContentController.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = PetWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: config)
        view.contextMenu = { [weak self] in self?.menu() ?? NSMenu() }; web = view
        web.underPageBackgroundColor = .clear; web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self; web.autoresizingMask = [.width, .height]
        web.isInspectable = checkDirectory != nil
        pet.contentView = web
        applyPreferences()
        web.load(URLRequest(url: URL(string: "pet://app/index.html?desktop=pet")!))
    }
    func initialFrame() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens[0], visible = screen.visibleFrame
        let size = NSSize(width: (340 * store.preferences.scale).rounded(), height: (480 * store.preferences.scale).rounded())
        return clamp(NSRect(x: store.preferences.positionX ?? Double(visible.maxX - size.width - 16),
                            y: store.preferences.positionY ?? Double(visible.minY + 8), width: size.width, height: size.height))
    }
    func clamp(_ rect: NSRect) -> NSRect {
        let screen = NSScreen.screens.max { a, b in a.visibleFrame.intersection(rect).area < b.visibleFrame.intersection(rect).area } ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        return NSRect(x: min(max(rect.minX, visible.minX), visible.maxX - rect.width),
                      y: min(max(rect.minY, visible.minY), visible.maxY - rect.height), width: rect.width, height: rect.height)
    }
    func applyPreferences() {
        guard pet != nil else { return }
        pet.level = store.preferences.alwaysOnTop ? .floating : .normal
        resizePet(store.preferences.scale)
        bubble?.level = NSWindow.Level(rawValue: pet.level.rawValue + 1)
        updateBubblePosition(); updatePetWorkspaceOcclusion(); updateVisibility(); statusItem?.menu = menu()
        syncWakePreference()
        screenCompanion.configure()
    }
    func updatePetWorkspaceOcclusion() {
        guard let pet else { return }
        let work = NSApp.windows.filter { window in
            NSApp.isActive && window !== pet && window !== bubble && window.isVisible && !window.isMiniaturized && window.level.rawValue >= NSWindow.Level.normal.rawValue
        }
        let obscuresWork = work.contains { window in pet.frame.intersects(window.frame) || (bubble?.isVisible == true && bubble!.frame.intersects(window.frame)) }
        let level = obscuresWork ? NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1) : store.preferences.alwaysOnTop ? .floating : .normal
        if pet.level != level { pet.level = level }
        let bubbleLevel = obscuresWork ? level : NSWindow.Level(rawValue: level.rawValue + 1)
        if bubble?.level != bubbleLevel { bubble?.level = bubbleLevel }
    }
    func resizePet(_ value: Double) {
        guard pet != nil else { return }
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(pet.frame) } ?? NSScreen.screens[0]
        let maximum = min(1.5, Double((screen.visibleFrame.height - 16) / 480), Double((screen.visibleFrame.width - 16) / 340))
        let value = min(max(0.5, value), maximum); store.preferences.scale = value
        var frame = pet.frame; let center = frame.midX
        // Align before AppKit rounds a tiny floating-point excess upward (for
        // example 340 * 1.1 == 374.00000000000006 otherwise becomes 375 pt).
        frame.size = NSSize(width: (340 * value).rounded(), height: (480 * value).rounded()); frame.origin.x = center - frame.width / 2
        pet.setFrame(clamp(frame), display: true); updateBubblePosition()
    }
    @discardableResult func setPetScale(_ value: Double) -> Double {
        guard pet != nil else { store.preferences.scale = value; return value }
        resizePet(value)
        store.preferences.positionX = pet.frame.minX; store.preferences.positionY = pet.frame.minY
        onScaleChange?(store.preferences.scale)
        scaleSaveTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in Task { @MainActor in try? self?.store.savePreferences() } }
        scaleSaveTimer = timer; RunLoop.main.add(timer, forMode: .common)
        return store.preferences.scale
    }
    func syncWakePreference() {
        guard checkDirectory == nil else { return }
        let p = store.preferences
        if let last = appliedWake, last.0 == p.wakeEnabled && last.1 == p.wakePhrase && last.2 == p.voicePauseSeconds { return }
        appliedWake = (p.wakeEnabled, p.wakePhrase, p.voicePauseSeconds)
        if p.wakeEnabled { wakeError = nil }
        voiceWake.configure(enabled: p.wakeEnabled && !sleeping, phrase: p.wakePhrase, pauseSeconds: p.voicePauseSeconds)
        publishVoiceState()
    }
    @objc func toggleWake() {
        store.preferences.wakeEnabled.toggle(); wakeError = nil; try? store.savePreferences()
        appliedWake = nil; syncWakePreference(); statusItem.menu = menu()
    }
    @objc func listenNow() {
        screenCompanion.interaction(); cancelConversation(); pendingVoiceListen = true
        if !store.preferences.wakeEnabled {
            store.preferences.wakeEnabled = true; wakeError = nil; wakeStatus = "等待授权"
            try? store.savePreferences(); appliedWake = nil; syncWakePreference(); statusItem.menu = menu()
        }
        startPendingVoiceListen()
    }
    func startPendingVoiceListen() {
        guard pendingVoiceListen, store.preferences.wakeEnabled, chatTask == nil, !selectedAgentBusy, speechTask == nil,
              !["等待授权", "恢复麦克风"].contains(wakeStatus) else { return }
        pendingVoiceListen = false; voiceWake.listenNow()
    }
    @objc func stopRecording() { endVoiceInput("已停止录音") }
    private func endVoiceInput(_ message: String, draft: String = "") {
        pendingVoiceListen = false; store.preferences.wakeEnabled = false; wakeError = nil; wakeStatus = "未开启"
        voiceWake.stop(); appliedWake = nil; screenCompanion.interaction(); cancelConversation()
        if !draft.isEmpty { control.keepInterruptedVoiceDraft(draft) }
        try? store.savePreferences(); publishVoiceState(); statusItem.menu = menu(); showBubble(message, duration: 2.5)
    }
    func voiceEvent(_ event: VoiceWake.Event) {
        if !store.preferences.wakeEnabled {
            switch event { case .state("未开启"), .stopped: break; default: return }
        }
        switch event {
        case .state(let state):
            wakeStatus = wakeError ?? state
            if state == "等待唤醒" && (chatTask != nil || selectedAgentBusy || speechTask != nil || player?.isPlaying == true) { refreshVoiceBusy() }
            if state == "等待唤醒" { startPendingVoiceListen() }
        case .woke:
            screenCompanion.interaction()
            wakeStatus = "聆听中"; playWakeChime(); emit("voiceListen"); showBubble("我在，讲吧", duration: 10)
        case .partial(let text): showBubble(text, duration: 12)
        case .utterance(let text):
            if !send(text) { control.keepVoiceDraft(text); voiceWake.resetConversation() }
        case .stopped(let message, let draft): endVoiceInput(message, draft: draft)
        case .failure(let error):
            wakeError = error; wakeStatus = error; store.preferences.wakeEnabled = false
            try? store.savePreferences(); appliedWake = nil; syncWakePreference()
            control.setStatus(error, error: true); showBubble(error)
            statusItem.menu = menu()
        }
        publishVoiceState()
    }
    private func publishVoiceState() {
        onWakeChange?(store.preferences.wakeEnabled, wakeStatus)
        statusItem.button?.toolTip = store.preferences.wakeEnabled ? "语音唤醒：\(wakeStatus)" : "蓝色大肥鱼"
        statusItem.button?.image = NSImage(systemSymbolName: wakeStatus == "聆听中" ? "mic.fill" : "fish.fill", accessibilityDescription: wakeStatus)
        statusItem.button?.image?.isTemplate = true
        let listening = store.preferences.wakeEnabled && wakeStatus == "聆听中"
        if bubble?.isVisible == true, let button = bubbleStopButton, button.isHidden != !listening, let text = bubbleLabel?.stringValue {
            showBubble(text)
        }
    }
    func refreshVoiceBusy(followUp: Bool = false) {
        guard store.preferences.wakeEnabled else { return }
        voiceWake.setOutputBusy(chatTask != nil || selectedAgentBusy || speechTask != nil || player?.isPlaying == true || sleeping, followUp: followUp)
    }
    func emit(_ type: String, _ payload: [String: Any] = [:]) {
        guard ready, !closing, let data = try? JSONSerialization.data(withJSONObject: ["type": type, "payload": payload]),
              let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.whaleNativeReceive(\(json))", completionHandler: nil)
    }
    func updateVisibility() {
        guard pet != nil else { return }
        let wasVisible = renderVisible
        renderVisible = pet.isVisible && pet.occlusionState.contains(.visible) && !sleeping
        emit("preferences", ["visible": renderVisible, "performance": store.preferences.performance,
                             "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled])
        if renderVisible && ready { updatePointer(at: NSEvent.mouseLocation) }
        if !renderVisible { screenCompanion.suspend() }
        else if !wasVisible && ready { screenCompanion.configure() }
    }
    @objc func willSleep() { screenCompanion.suspend(); endDrag(); sleeping = true; wakePlayer?.stop(); voiceWake.stop(); updateVisibility() }
    @objc func didWake() { sleeping = false; appliedWake = nil; syncWakePreference(); updateVisibility(); agentStore?.automations.wake() }
    @objc func powerChanged() { updateVisibility() }
    @objc func frontApplicationChanged() { screenCompanion.applicationChanged() }
    @objc func screensChanged() { pet.setFrame(clamp(pet.frame), display: true); updateBubblePosition() }
    func windowDidChangeOcclusionState(_ notification: Notification) { updateVisibility() }
    func applicationDidBecomeActive(_ notification: Notification) { updatePetWorkspaceOcclusion() }
    func applicationDidResignActive(_ notification: Notification) { updatePetWorkspaceOcclusion() }

    func setupMouse() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        globalMouse = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in self?.trackMouse(event) }
        localMouse = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in self?.trackMouse(event); return event }
    }
    func trackMouse(_ event: NSEvent) {
        guard pet != nil, ready, pet.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        if event.type == .leftMouseDown {
            pendingPress = nil
            if event.window === pet && !pet.ignoresMouseEvents {
                pendingPress = (mouse, pet.frame.origin, motionTranslation, false)
            }
        } else if var press = pendingPress, event.type == .leftMouseDragged || event.type == .leftMouseUp {
            press.moved = press.moved || hypot(mouse.x - press.mouse.x, mouse.y - press.mouse.y) > 4
            pendingPress = press
        }
        if dragOrigin != nil {
            if event.type == .leftMouseUp || (event.type == .mouseMoved && NSEvent.pressedMouseButtons & 1 == 0) { endDrag(); return }
            if event.type == .leftMouseDragged {
                moveDrag(to: mouse)
            }
            return
        }
        updatePointer(at: mouse)
    }
    func updatePointer(at mouse: NSPoint) {
        guard ready, pet.isVisible, !sleeping else { return }
        let inside = pet.frame.contains(mouse)
        if !inside {
            if pointerInside { pointerInside = false; pointerGeneration += 1; pet.ignoresMouseEvents = true; web.evaluateJavaScript("window.petPointerLeave?.()", completionHandler: nil) }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPointerQuery < 1.0 / 30 { return }; lastPointerQuery = now
        // Eye contact uses the entire desktop. Hit testing remains local so the
        // transparent window never captures clicks meant for another app.
        let dx = (mouse.x - pet.frame.midX) / max(240, pet.frame.width * 0.85)
        let dy = (mouse.y - (pet.frame.minY + pet.frame.height * 0.62)) / max(220, pet.frame.height * 0.6)
        let gaze = "window.petPointerGaze?.(\(atan(dx) * 2 / .pi),\(atan(dy) * 2 / .pi));"
        guard inside else {
            if renderVisible && store.preferences.performance != "paused" { web.evaluateJavaScript(gaze, completionHandler: nil) }
            return
        }
        pointerInside = true; pointerGeneration += 1; let generation = pointerGeneration
        let x = mouse.x - pet.frame.minX, y = pet.frame.height - (mouse.y - pet.frame.minY)
        web.evaluateJavaScript(gaze + "window.petPointerAt?.(\(x),\(y))") { [weak self] value, _ in
            guard let self, self.pointerGeneration == generation, self.dragOrigin == nil,
                  self.pet.frame.contains(NSEvent.mouseLocation) else { return }
            self.pet.ignoresMouseEvents = !(value as? Bool ?? false)
        }
    }
    func beginDrag() {
        screenCompanion.interaction()
        // WebKit can deliver pointerdown after a short physical drag has ended.
        // Keep the native press and its maximum travel until the bridge arrives.
        let press = pendingPress; pendingPress = nil
        dragOrigin = (press?.mouse ?? NSEvent.mouseLocation, press?.window ?? pet.frame.origin, press?.motion ?? motionTranslation)
        dragged = press?.moved ?? false; pet.ignoresMouseEvents = false; emit("dragState", ["held": true])
    }
    func moveDrag(to mouse: NSPoint) {
        guard let origin = dragOrigin else { return }
        let dx = mouse.x - origin.mouse.x, dy = mouse.y - origin.mouse.y
        if hypot(dx, dy) > 4 { dragged = true }
        guard dragged else { return }
        var frame = pet.frame; frame.origin = NSPoint(x: origin.window.x + dx, y: origin.window.y + dy)
        pet.setFrame(clamp(frame), display: true); updateBubblePosition()
        motionTranslation = NSPoint(x: origin.motion.x + dx / 100, y: origin.motion.y + dy / 100)
        emit("translation", ["x": motionTranslation.x, "y": motionTranslation.y, "held": true, "moved": true])
    }
    func endDrag() {
        guard dragOrigin != nil else { return }
        dragOrigin = nil; store.preferences.positionX = pet.frame.minX; store.preferences.positionY = pet.frame.minY
        try? store.savePreferences(); emit("dragEnd", ["moved": dragged]); dragged = false
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == "pet",
              let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        let payload = body["payload"] as? [String: Any] ?? [:]
        switch action {
        case "ready":
            ready = true; pet.orderFrontRegardless(); updateVisibility(); statusItem.menu = menu()
            if selectedAgentBusy || agentStore?.selected?.status == .waiting { agentAnimationPhase = ""; refreshAgentAnimation() }
            if checkDirectory != nil { Task { await runSelfCheck() } }
        case "hit": if dragOrigin == nil { pet.ignoresMouseEvents = !(payload["hit"] as? Bool ?? false) }
        case "dragBegin":
            if dragOrigin == nil { beginDrag(); moveDrag(to: NSEvent.mouseLocation) }
            // A very short click can reach WebKit's bridge after mouse-up.
            if NSEvent.pressedMouseButtons & 1 == 0 { endDrag() }
        // Moving a native window can cancel WebKit pointer capture. Only a
        // physical button release ends the host drag; its event monitor owns it.
        case "dragEnd": if NSEvent.pressedMouseButtons & 1 == 0 { endDrag() }
        case "chat": openChat()
        case "menu": _ = menu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        case "error":
            let text = String((payload["message"] as? String ?? "角色渲染错误").prefix(600)); diagnostics.append(text)
            if diagnostics.count > 30 { diagnostics.removeFirst() }
            control.setStatus(text, error: true)
        default: break
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.scheme == "pet" && navigationAction.request.url?.host == "app" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        diagnostics.append(error.localizedDescription); control.setStatus("角色加载失败，请重新打开应用。", error: true)
    }
    @objc func openChat() { screenCompanion.interaction(); control.show(tab: "chat") }
    @objc func openSettings() { screenCompanion.interaction(); control.show(tab: "settings") }
    @objc func observeScreen() { screenCompanion.observe() }
    @objc func pauseScreenObservation() { screenCompanion.toggleQuiet(); statusItem.menu = menu() }
    @objc func accessibilityChat() -> Bool { openChat(); return true }
    @objc func accessibilitySettings() -> Bool { openSettings(); return true }
    @objc func togglePet() {
        if pet.isVisible { stopSpeech(); pet.orderOut(nil); bubble?.orderOut(nil) }
        else { pet.orderFrontRegardless() }
        updateVisibility(); statusItem.menu = menu()
    }
    @objc func toggleTop() { store.preferences.alwaysOnTop.toggle(); try? store.savePreferences(); applyPreferences() }
    @objc func toggleMotion() { store.preferences.performance = store.preferences.performance == "paused" ? "auto" : "paused"; try? store.savePreferences(); applyPreferences() }
    @objc func resetPosition() {
        store.preferences.positionX = nil; store.preferences.positionY = nil
        pet.setFrame(initialFrame(), display: true); try? store.savePreferences(); emit("reset"); updateBubblePosition()
    }
    @objc func quit() { NSApp.terminate(nil) }

    func send(_ text: String, attachmentIDs: [String] = []) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if usesAgent {
            ensureAgent(); screenCompanion.interaction()
            guard !text.isEmpty || !attachmentIDs.isEmpty, let runtime = agentRuntime else { return false }
            stopSpeech()
            let accepted = runtime.submit(text, attachmentIDs: attachmentIDs)
            if accepted { control.scheduleRender(); refreshVoiceBusy() }
            else if let error = runtime.submissionError { control.setStatus(error, error: true) }
            return accepted
        }
        guard !text.isEmpty, chatTask == nil else { return false }
        guard text.count <= 8000 else { control.setStatus("消息过长，请缩短后重试。", error: true); return false }
        screenCompanion.interaction()
        do {
            let preferences = store.preferences, url = try CompanionService.endpoint(preferences.endpoint, chat: true)
            let key = try store.keychain.read("chat")
            if key.isEmpty && !CompanionService.isLocal(url.host ?? "") { control.show(tab: "settings"); control.setStatus("请先填写对话密钥。", error: true); return false }
            _ = try preferences.requestBody(messages: store.messages + [ChatMessage(role: "user", content: text)])
            stopSpeech(); undoMessages = nil
            if store.preferences.wakeEnabled { voiceWake.setOutputBusy(true) }
            store.messages.append(ChatMessage(role: "user", content: text))
            let context = store.messages
            store.messages.append(ChatMessage(role: "assistant", content: ""))
            let id = store.messages.last!.id
            control.setBusy(true); control.setStatus("正在回复"); control.renderMessages()
            chatTask = Task { [weak self] in
                guard let self else { return }
                var answered = false
                do {
                    let reply = try await CompanionService.stream(preferences: preferences, key: key, messages: context) { [weak self] delta in
                        guard let self, let index = self.store.messages.firstIndex(where: { $0.id == id }) else { return }
                        self.store.messages[index].content += delta; self.control.scheduleRender()
                    }
                    try Task.checkCancellation(); answered = true; self.control.setStatus(""); self.showBubble(reply)
                    if preferences.voiceEnabled { self.synthesize(reply, preferences: preferences) }
                } catch {
                    let cancelled = Task.isCancelled || (error as? URLError)?.code == .cancelled
                    self.control.setStatus(cancelled ? "已停止" : error.localizedDescription, error: !cancelled)
                }
                self.store.messages.removeAll { $0.id == id && $0.content.isEmpty }
                try? self.store.saveHistory(); self.chatTask = nil
                self.control.setBusy(false); self.control.renderMessages()
                if !answered { self.voiceWake.resetConversation() }
                self.refreshVoiceBusy(followUp: answered)
                self.startPendingVoiceListen()
            }
            return true
        } catch { control.setStatus(error.localizedDescription, error: true); return false }
    }
    func cancelConversation() {
        chatTask?.cancel()
        if let id = agentStore?.selectedID { agentRuntime?.cancel(id) }
        stopSpeech(); refreshVoiceBusy(); startPendingVoiceListen()
    }
    func clearConversation() {
        guard chatTask == nil else { return }
        if let undo = undoMessages { store.messages = undo; undoMessages = nil }
        else { undoMessages = store.messages; store.messages = [] }
        try? store.saveHistory(); control.renderMessages()
    }
    func synthesize(_ text: String, preferences: PetPreferences, followUp: Bool = true) {
        stopSpeech(); let generation = voiceGeneration
        speechTask = Task { [weak self] in
            guard let self else { return }
            do {
                let key = try self.store.keychain.read("voice")
                let data = try await CompanionService.speech(text: text, preferences: preferences, key: key)
                guard !Task.isCancelled, generation == self.voiceGeneration else { return }
                try self.beginAudio(data, text: text, followUp: followUp)
            } catch {
                if !Task.isCancelled {
                    self.control.setStatus(error.localizedDescription, error: true)
                    self.showBubble("语音未播放：\(error.localizedDescription)")
                    self.screenCompanion.speechEnded()
                }
            }
            if generation == self.voiceGeneration { self.speechTask = nil; self.refreshVoiceBusy(followUp: followUp) }
        }
        refreshVoiceBusy()
    }
    @objc func playDemo() {
        stopSpeech()
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("web/audio/whale-maid/companion-minimax.mp3"),
              let data = try? Data(contentsOf: url) else { return }
        do { try beginAudio(data, text: "我在呢。今天也陪你一起摸鱼。要是累了，就休息一会儿吧。嗯？你刚刚是不是在叫我？") }
        catch { control.setStatus("示例音频无法播放。", error: true) }
    }
    func playWakeChime() {
        guard wakePlayer?.isPlaying != true,
              let url = Bundle.main.resourceURL?.appendingPathComponent("web/audio/whale-maid/wake-chime.wav") else { return }
        do {
            wakePlayer = try AVAudioPlayer(contentsOf: url); wakePlayer?.volume = 0.7
            wakePlayer?.prepareToPlay(); wakePlayer?.play()
        } catch { diagnostics.append("唤醒提示音无法播放。") }
        // A short nonverbal cue has its own player: do not close the active ASR
        // turn, mark speech as busy, or animate the mouth for this sound.
    }
    func beginAudio(_ data: Data, text: String, followUp: Bool = true) throws {
        speechFollowUp = followUp
        player = try AVAudioPlayer(data: data); player?.delegate = self; player?.isMeteringEnabled = true
        speechAnimation = try? SpeechAnimation(data: data, duration: player?.duration ?? 0)
        player?.prepareToPlay()
        guard player?.play() == true else { throw PetError("语音无法播放。") }
        emit("speechStart", ["frames": speechAnimation?.frames ?? [], "position": player?.currentTime ?? 0]); showBubble(text, duration: (player?.duration ?? 6) + 1)
        refreshVoiceBusy()
        meterTimer?.invalidate()
        meterTimer = Timer(timeInterval: 1 / 15, target: self, selector: #selector(updateMeter), userInfo: nil, repeats: true)
        meterTimer?.tolerance = 0.004; RunLoop.main.add(meterTimer!, forMode: .common)
    }
    @objc func updateMeter() {
        guard let player, player.isPlaying else { return }
        player.updateMeters(); lastVolume = min(1, pow(10, Double(player.averagePower(forChannel: 0)) / 20) * 5)
        if renderVisible { emit("speechLevel", ["volume": lastVolume, "position": player.currentTime]) }
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { stopSpeech(followUp: speechFollowUp) }
    func stopSpeech(followUp: Bool = false) {
        voiceGeneration += 1; speechTask?.cancel(); speechTask = nil
        player?.stop(); player = nil; speechAnimation = nil; meterTimer?.invalidate(); meterTimer = nil; lastVolume = 0
        emit("speechEnd")
        screenCompanion.speechEnded()
        refreshVoiceBusy(followUp: followUp)
    }
    func showBubble(_ text: String, duration: TimeInterval? = nil) {
        guard pet.isVisible else { return }
        bubbleTimer?.invalidate()
        let text = String(text.prefix(160)) + (text.count > 160 ? "…" : "")
        let label = bubbleLabel ?? NSTextField(wrappingLabelWithString: text); label.stringValue = text; label.font = .systemFont(ofSize: 13)
        label.textColor = NSColor(red: 0.17, green: 0.23, blue: 0.29, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [.font: label.font!]
        let listening = store.preferences.wakeEnabled && wakeStatus == "聆听中", controlSpace: CGFloat = listening ? 64 : 0
        let available = (pet.screen ?? NSScreen.main)?.visibleFrame.width ?? 268
        let width = min(268, max(56 + controlSpace, min(available - 24, ceil((text as NSString).size(withAttributes: attributes).width) + 36 + controlSpace)))
        let bounds = (text as NSString).boundingRect(with: NSSize(width: width - 36 - controlSpace, height: 220), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
        let size = NSSize(width: width, height: min(240, max(42, ceil(bounds.height) + 24)))
        let panel = bubble ?? PetPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.setContentSize(size)
        panel.isReleasedWhenClosed = false
        panel.title = "小鲸 · 语音"; panel.setAccessibilityRole(.window); panel.setAccessibilitySubrole(.standardWindow)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.ignoresMouseEvents = !listening
        panel.hidesOnDeactivate = false; panel.level = NSWindow.Level(rawValue: pet.level.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let content = panel.contentView ?? NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        content.wantsLayer = true; content.layer?.backgroundColor = NSColor.white.cgColor; content.layer?.cornerRadius = 12
        label.frame = NSRect(x: 16, y: 12, width: width - 32 - controlSpace, height: size.height - 24); label.autoresizingMask = [.width, .height]
        if label.superview == nil { content.addSubview(label) }
        let stop = bubbleStopButton ?? NSButton(title: "停止", target: self, action: #selector(stopRecording))
        stop.isBordered = false; stop.font = .systemFont(ofSize: 11, weight: .medium); stop.contentTintColor = .systemRed
        stop.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil); stop.imagePosition = .imageLeading
        stop.wantsLayer = true; stop.layer?.cornerRadius = 7; stop.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.08).cgColor
        stop.setAccessibilityLabel("停止录音"); stop.toolTip = "停止录音"; stop.isHidden = !listening
        stop.frame = NSRect(x: width - 68, y: (size.height - 26) / 2, width: 52, height: 26)
        if stop.superview == nil { content.addSubview(stop) }; bubbleStopButton = stop
        panel.contentView = content; bubble = panel; bubbleLabel = label; updateBubblePosition(); panel.orderFrontRegardless()
        if !listening {
            bubbleTimer = Timer.scheduledTimer(withTimeInterval: duration ?? max(6, min(14, Double(text.count) * 0.08)), repeats: false) { [weak self] _ in
                Task { @MainActor in self?.bubble?.orderOut(nil) }
            }
        }
    }
    func updateBubblePosition() {
        defer { updatePetWorkspaceOcclusion() }
        guard let bubble, pet != nil else { return }
        let visible = (NSScreen.screens.first { $0.visibleFrame.intersects(pet.frame) } ?? NSScreen.screens[0]).visibleFrame
        var x = pet.frame.midX - bubble.frame.width / 2, y = pet.frame.maxY - 8
        if y + bubble.frame.height > visible.maxY { x = pet.frame.minX - bubble.frame.width - 8; y = pet.frame.maxY - bubble.frame.height - 24 }
        bubble.setFrameOrigin(NSPoint(x: min(max(x, visible.minX), visible.maxX - bubble.frame.width), y: min(max(y, visible.minY), visible.maxY - bubble.frame.height)))
    }
}

private extension NSRect { var area: CGFloat { isNull ? 0 : width * height } }

@main struct BlueFatFish {
    @MainActor static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--make-icons"), CommandLine.arguments.count > index + 1 {
            makeIcons(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1])); return
        }
        let app = NSApplication.shared, delegate = AppDelegate()
        app.delegate = delegate; app.run(); withExtendedLifetime(delegate) {}
    }
}
