import AppKit
import ApplicationServices
import Carbon

@MainActor final class AgentAppShot {
    enum Shortcut: String, Codable, CaseIterable {
        case disabled, command, option, shift
        var title: String { switch self { case .disabled: return "停用"; case .command: return "左 ⌘ + 右 ⌘"; case .option: return "左 ⌥ + 右 ⌥"; case .shift: return "左 ⇧ + 右 ⇧" } }
        var keys: (CGKeyCode, CGKeyCode)? { switch self { case .disabled: return nil; case .command: return (55, 54); case .option: return (58, 61); case .shift: return (56, 60) } }
    }
    static let changed = Notification.Name("AgentAppShotChanged")
    private struct Document: Codable { var version = 1; var shortcut: Shortcut }
    private weak var host: AppDelegate?
    private let profile: URL
    private var revision: String?, configurationError: String?
    private(set) var shortcut = Shortcut.disabled
    private(set) var status = ""
    private(set) var lastTaskID: String?, lastAttachmentID: String?, captures = 0
    private var local: Any?, global: Any?, latched = false, generation = 0
    private var externalCheck: AgentAppShotExternalCheck?
    private var job: Task<Void, Never>?
    var isBusy: Bool { job != nil }
    init(host: AppDelegate) { self.host = host; profile = host.store.directory; reload() }
    private func changed() { NotificationCenter.default.post(name: Self.changed, object: self) }
    func reload() {
        stop(); externalCheck = nil
        do {
            let files = try AgentFiles(workspace: profile.path), url = try files.literalURL("computer-use/appshot.json"), entry = try files.entryMetadata(url)
            guard try files.resolve("computer-use/appshot.json") == url, ["missing", "file"].contains(entry.kind) else { throw PetError("AppShot 配置必须是普通文件") }
            if entry.kind == "missing" { shortcut = .disabled; revision = nil }
            else {
                let data = try files.readData(url, maximum: 4096)
                guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(raw.keys) == ["version", "shortcut"] else { throw PetError("AppShot 配置包含不支持的字段") }
                let document = try JSONDecoder().decode(Document.self, from: data)
                guard document.version == 1 else { throw PetError("AppShot 配置版本不受支持") }
                shortcut = document.shortcut; revision = AgentFiles.hash(data)
            }
            if let host, host.checkDirectory != nil, CommandLine.arguments.contains("--appshot-external-ui") { externalCheck = try AgentAppShotExternalCheck(host: host) }
            configurationError = nil; status = ""; installMonitors()
        } catch { shortcut = .disabled; configurationError = error.localizedDescription; status = "AppShot 配置未载入：" + error.localizedDescription }
        changed()
    }
    func setShortcut(_ value: Shortcut) throws {
        guard configurationError == nil else { throw PetError("请修复 AppShot 配置并重新载入") }
        let data = try JSONEncoder().encode(Document(shortcut: value))
        let write = try AgentKnowledgeFileWrite(files: AgentFiles(workspace: profile.path), path: "computer-use/appshot.json", data: data, expectedHash: revision, missing: revision == nil, permissions: 0o600, label: "AppShot 配置")
        try write.requireCurrent(); try write.files.writeData(data, to: write.url, permissions: 0o600, expectedTarget: write.signature)
        stop(); shortcut = value; revision = AgentFiles.hash(data); status = ""; installMonitors(); changed()
    }
    func stop() {
        generation += 1; job?.cancel()
        if let local { NSEvent.removeMonitor(local); self.local = nil }
        if let global { NSEvent.removeMonitor(global); self.global = nil }
        latched = false
    }
    func cancelAndWait() async { let pending = job; stop(); await pending?.value }
    private func installMonitors() {
        guard shortcut != .disabled else { return }
        if local == nil { local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in self?.flagsChanged(event); return event } }
        // Global keyboard observation is installed only when macOS already permits it.
        // This code never opens a system authorization prompt.
        if global == nil, host?.checkDirectory == nil || externalCheck != nil, AXIsProcessTrusted() {
            global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated { self?.flagsChanged(event) }
            }
        }
    }
    func refreshPermissions() { installMonitors(); changed() }
    private func flagsChanged(_ event: NSEvent) {
        guard let keys = shortcut.keys, event.keyCode == keys.0 || event.keyCode == keys.1 else { return }
        let pressed = CGEventSource.keyState(.combinedSessionState, key: keys.0) && CGEventSource.keyState(.combinedSessionState, key: keys.1)
        if !pressed { latched = false; return }
        guard !latched, !IsSecureEventInputEnabled() else { return }; latched = true; capture()
    }
    func capture() {
        guard job == nil else { return }
        do {
            guard let host, !host.closing, let application = NSWorkspace.shared.frontmostApplication else { throw PetError("没有可用的当前窗口") }
            if host.checkDirectory != nil, application.processIdentifier != getpid(), externalCheck == nil {
                guard CommandLine.arguments.contains("--appshot-external-ui") else { throw PetError("本轮窗口检查只截取当前候选应用；外部应用须另行授权验收") }
                externalCheck = try AgentAppShotExternalCheck(host: host)
            }
            if application.processIdentifier != getpid() { try externalCheck?.validateAuthorization() }
            let owner = host.inputControl, id = try owner.prepareAppShot(), ownWindow = application.processIdentifier == getpid() ? NSApp.keyWindow?.windowNumber : nil
            let token = generation
            job = Task { @MainActor [weak self, weak owner] in
                guard let self else { return }
                defer { job = nil; changed() }
                do {
                    await Task.yield()
                    let shot = try await AgentAppShotCapture.frontmost(expectedApplication: application, expectedOwnWindow: ownWindow, externalCheck: externalCheck)
                    try Task.checkCancellation()
                    guard generation == token, let owner, owner.window?.isVisible == true else { throw PetError("接收快照的任务窗口已关闭，截图未添加") }
                    let file = try await owner.attachAppShot(shot, taskID: id)
                    try Task.checkCancellation()
                    captures += 1; lastTaskID = id; lastAttachmentID = file.id; status = "已添加：" + shot.source.application
                } catch {
                    if generation == token && !Task.isCancelled { status = error.localizedDescription; self.host?.inputControl.setStatus(status, error: true); self.host?.inputControl.show(tab: "chat") }
                }
            }
            status = "截图中…"; changed()
        } catch {
            status = error.localizedDescription; changed()
            if host?.closing != true { host?.inputControl.setStatus(status, error: true); host?.inputControl.show(tab: "chat") }
        }
    }
    func checkState() -> [String: Any] { ["shortcut": shortcut.rawValue, "busy": isBusy, "captures": captures, "taskID": lastTaskID as Any? ?? NSNull(), "attachmentID": lastAttachmentID as Any? ?? NSNull(), "localMonitor": local != nil, "globalMonitor": global != nil, "status": status] }
}

@MainActor extension AppDelegate {
    @objc func captureAppShot() { appShot.capture() }
}
