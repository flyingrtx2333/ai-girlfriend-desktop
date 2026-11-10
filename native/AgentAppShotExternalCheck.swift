import AppKit
import ApplicationServices

// A separately approved, bounded acceptance scope. Normal application use is
// governed by the user's shortcut action and macOS permissions instead.
@MainActor final class AgentAppShotExternalCheck {
    private struct Authorization: Decodable {
        var version: Int; var scope: String; var directory: String; var candidateHash: String; var applicationID: String
        var targetApplicationID: String; var documentHash: String; var maximumCaptures: Int; var modelTransmissionAllowed: Bool
    }
    private struct Attempt: Codable { var id = UUID().uuidString; var windowID: UInt32; var pid: Int32; var created = Date() }
    private struct Ledger: Codable { var version = 1; var authorizationHash: String; var maximumCaptures = 8; var attempts: [Attempt] }
    private let directory: URL, authorizationData: Data, authorization: Authorization
    private var ledger: Ledger, ledgerHash: String?
    private weak var host: AppDelegate?
    private var document: URL { directory.appendingPathComponent("workspace/README.md").resolvingSymlinksInPath() }
    init(host: AppDelegate) throws {
        guard let directory = host.checkDirectory, CommandLine.arguments.contains("--manual-ui"), !CommandLine.arguments.contains("--live-agent"), host.agentRuntime?.modelRequestCheck != nil,
              Bundle.main.bundleIdentifier == "com.xjs.bluefatfish.appshot-check", let binary = Bundle.main.executableURL else { throw PetError("外部窗口验收必须使用独立候选和禁止模型传输的窗口入口") }
        guard Array(CommandLine.arguments.dropFirst()) == ["--check", directory.path, "--manual-ui", "--appshot-external-ui"] else { throw PetError("外部窗口验收入口参数不符，不合并其他模型验收入口") }
        self.directory = directory.resolvingSymlinksInPath(); self.host = host
        let files = try AgentFiles(workspace: directory.path), url = try files.literalURL("appshot-external-authorization.json")
        guard try files.resolve("appshot-external-authorization.json") == url, try files.entryMetadata(url).kind == "file" else { throw PetError("缺少本轮独立外部窗口验收授权") }
        let data = try files.readData(url, maximum: 8192), value = try JSONDecoder().decode(Authorization.self, from: data)
        guard value.version == 1, value.scope == "appshot-external", URL(fileURLWithPath: value.directory).resolvingSymlinksInPath() == self.directory,
              value.candidateHash == (try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)), value.applicationID == Bundle.main.bundleIdentifier,
              value.targetApplicationID == "com.apple.TextEdit", value.maximumCaptures == 8, !value.modelTransmissionAllowed else { throw PetError("外部窗口验收授权的范围、候选或上限不符") }
        authorizationData = data; authorization = value
        let ledgerURL = try files.literalURL("appshot-external-capture-ledger.json"), entry = try files.entryMetadata(ledgerURL)
        if entry.kind == "missing" { ledger = Ledger(authorizationHash: AgentFiles.hash(data), attempts: []) }
        else {
            guard entry.kind == "file", try files.resolve("appshot-external-capture-ledger.json") == ledgerURL else { throw PetError("验收账本必须是普通文件") }
            let bytes = try files.readData(ledgerURL, maximum: 32_768); ledger = try JSONDecoder().decode(Ledger.self, from: bytes); ledgerHash = AgentFiles.hash(bytes)
            guard ledger.version == 1, ledger.authorizationHash == AgentFiles.hash(data), ledger.maximumCaptures == 8, ledger.attempts.count <= 8, Set(ledger.attempts.map(\.id)).count == ledger.attempts.count else { throw PetError("原外部快照账本不匹配，保留旧记录后检查") }
        }
        try validateAuthorization()
    }
    func validateAuthorization() throws {
        guard host?.agentRuntime?.modelRequestCheck != nil else { throw PetError("模型传输拦截已变化") }
        let files = try AgentFiles(workspace: directory.path), url = try files.literalURL("appshot-external-authorization.json")
        guard try files.resolve(url.path) == url, try files.entryMetadata(url).kind == "file", try files.readData(url, maximum: 8192) == authorizationData else { throw PetError("本轮外部窗口授权已变化或撤销") }
        let source = try files.literalURL("workspace/README.md")
        guard source == document, try files.resolve(source.path) == source, try files.entryMetadata(source).kind == "file", try files.fileHash(source) == authorization.documentHash else { throw PetError("本轮公开README已变化，外部快照未继续") }
    }
    func validate(_ target: AgentDesktop.Target, window: AXUIElement) throws {
        try validateAuthorization()
        guard target.bundleID == authorization.targetApplicationID, target.bundleURL?.standardizedFileURL.path == "/System/Applications/TextEdit.app",
              try AgentDesktopAX.documentURL(window)?.resolvingSymlinksInPath() == document else { throw PetError("本轮只验收系统文本编辑中已指定的公开README窗口") }
    }
    func validateApplication(_ app: NSRunningApplication) throws {
        try validateAuthorization()
        guard app.bundleIdentifier == authorization.targetApplicationID, app.bundleURL?.standardizedFileURL.path == "/System/Applications/TextEdit.app" else { throw PetError("本轮只读取系统文本编辑中的指定公开README") }
    }
    func admit(_ target: AgentDesktop.Target, window: AXUIElement) throws {
        try validate(target, window: window)
        guard ledger.attempts.count < 8 else { throw PetError("本轮已达到8次外部截图尝试上限，原记录保留") }
        var next = ledger; next.attempts.append(Attempt(windowID: target.windowID, pid: target.pid))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next), files = try AgentFiles(workspace: directory.path)
        let write = try AgentKnowledgeFileWrite(files: files, path: "appshot-external-capture-ledger.json", data: data, expectedHash: ledgerHash, missing: ledgerHash == nil, permissions: 0o600, label: "外部快照验收账本")
        try write.requireCurrent(); try write.files.writeData(data, to: write.url, permissions: 0o600, expectedTarget: write.signature)
        ledger = next; ledgerHash = AgentFiles.hash(data)
    }
}
