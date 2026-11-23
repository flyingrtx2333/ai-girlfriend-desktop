import AppKit
import Darwin
import WebKit

struct AgentBrowserDownloadRecord: Codable, Sendable {
    let id: UUID
    let name: String
    let bytes: Int
    let sha256: String
    let finished: Date
}

@MainActor final class AgentBrowserDownloads: NSObject, WKDownloadDelegate {
    struct Transfer {
        let id = UUID()
        let download: WKDownload
        let origin: String
        var destination: URL?
        var watch: Task<Void, Never>?
    }

    private static let maximum = 20_000_000
    private let files: AgentFiles
    private let root: URL
    private let taskID: String
    private weak var store: AgentStore?
    private var transfers: [ObjectIdentifier: Transfer] = [:]
    private var importing = Set<UUID>()
    private(set) var completed: [AgentBrowserDownloadRecord] = []
    private(set) var status = ""
    var onChange: (() -> Void)?
    var active: [Transfer] { transfers.values.sorted { $0.id.uuidString < $1.id.uuidString } }

    init?(store: AgentStore, taskID: String) {
        guard UUID(uuidString: taskID) != nil,
              let files = try? AgentFiles(workspace: store.directory.path, followParentLinks: false) else { return nil }
        self.store = store
        self.taskID = taskID
        self.files = files
        root = files.root.appendingPathComponent(taskID, isDirectory: true).appendingPathComponent("browser-downloads", isDirectory: true)
        super.init()
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        completed = folders.compactMap { folder in
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  let data = try? files.readData(receipt(id), maximum: 4096),
                  let record = try? JSONDecoder().decode(AgentBrowserDownloadRecord.self, from: data),
                  record.id == id, (try? readyFile(record)) != nil else { return nil }
            return record
        }.sorted { $0.finished > $1.finished }
    }

    nonisolated static func origin(_ url: URL?) -> String? {
        guard let url else { return nil }
        let value = url.scheme?.lowercased() == "blob" ? String(url.absoluteString.dropFirst(5)) : url.absoluteString
        return (try? AgentBrowser.url(value)).map(AgentBrowser.origin)
    }

    nonisolated static func filename(_ value: String) -> String {
        let separators = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let name = value.components(separatedBy: separators).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        if [".", "..", ""].contains(name) { return "下载文件" }
        if name.utf8.count <= 230 { return name }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty || ext.utf8.count > 24 ? "下载文件" : "下载文件." + ext
    }

    private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func receipt(_ id: UUID) -> URL { folder(id).appendingPathComponent("record.json") }
    private func file(_ id: UUID, name: String) -> URL {
        folder(id).appendingPathComponent("file", isDirectory: true).appendingPathComponent(name)
    }

    private func readyFile(_ record: AgentBrowserDownloadRecord) throws -> URL {
        guard Self.filename(record.name) == record.name, (0...Self.maximum).contains(record.bytes) else { throw PetError("下载记录无效") }
        let url = file(record.id, name: record.name)
        guard try files.entryMetadata(url).kind == "file",
              try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == record.bytes else { throw PetError("下载文件已移动或变化") }
        return url
    }

    func report(_ message: String) {
        status = message
        onChange?()
    }

    func start(_ download: WKDownload, origin: String) {
        transfers[ObjectIdentifier(download)] = Transfer(download: download, origin: origin)
        download.delegate = self
        report("下载中…")
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let key = ObjectIdentifier(download)
        guard var transfer = transfers[key] else { completionHandler(nil); return }
        do {
            guard Self.origin(response.url) == transfer.origin else { throw PetError("下载地址变更，请单独打开下载站点") }
            if let response = response as? HTTPURLResponse, response.statusCode >= 400 {
                throw PetError("下载失败（\(response.statusCode)）")
            }
            guard response.expectedContentLength <= Self.maximum else { throw PetError("每个下载文件最大 20 MB") }
            let destination = file(transfer.id, name: Self.filename(suggestedFilename))
            let directory = folder(transfer.id)
            let (parent, name) = try files.parentDescriptor(directory, create: true)
            defer { Darwin.close(parent) }
            guard mkdirat(parent, name, 0o700) == 0 else { throw PetError("无法创建下载目录") }
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
            transfer.destination = destination
            transfer.watch = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled, let self, let current = transfers[key] else { return }
                    let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
                    if current.download.progress.completedUnitCount > Self.maximum || (size ?? 0) > Self.maximum {
                        cancel(current.id, message: "每个下载文件最大 20 MB")
                        return
                    }
                }
            }
            transfers[key] = transfer
            completionHandler(destination)
            report("正在下载 " + destination.lastPathComponent)
        } catch {
            _ = take(download)
            completionHandler(nil)
            report(error.localizedDescription)
        }
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        guard let transfer = transfers[ObjectIdentifier(download)], Self.origin(request.url) == transfer.origin else {
            if let transfer = take(download) { discard(transfer) }
            decisionHandler(.cancel)
            report("下载地址变更，请单独打开下载站点")
            return
        }
        decisionHandler(.allow)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let transfer = take(download), let destination = transfer.destination else { return }
        do {
            guard let bytes = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  (0...Self.maximum).contains(bytes) else { throw PetError("每个下载文件最大 20 MB") }
            let sha = try files.fileHash(destination, maximum: Self.maximum)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
            let record = AgentBrowserDownloadRecord(id: transfer.id, name: destination.lastPathComponent, bytes: bytes, sha256: sha, finished: Date())
            try files.writeData(JSONEncoder().encode(record), to: receipt(record.id), permissions: 0o600, expectedTarget: "missing")
            completed.insert(record, at: 0)
            report("已下载 " + record.name)
        } catch {
            discard(transfer)
            report(error.localizedDescription)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let transfer = take(download) else { return }
        discard(transfer)
        report("下载失败，请重试")
    }

    private func take(_ download: WKDownload) -> Transfer? {
        let transfer = transfers.removeValue(forKey: ObjectIdentifier(download))
        transfer?.watch?.cancel()
        download.delegate = nil
        return transfer
    }

    private func discard(_ transfer: Transfer) {
        guard transfer.destination != nil else { return }
        try? FileManager.default.removeItem(at: folder(transfer.id))
    }

    func cancel(_ id: UUID, message: String = "已取消下载") {
        guard let download = active.first(where: { $0.id == id })?.download, let transfer = take(download) else { return }
        let directory = folder(id)
        download.cancel { _ in
            if transfer.destination != nil { try? FileManager.default.removeItem(at: directory) }
        }
        report(message)
    }

    func close() {
        onChange = nil
        for transfer in active { cancel(transfer.id) }
    }

    func attachmentStatus(_ record: AgentBrowserDownloadRecord) -> String? {
        if importing.contains(record.id) { return "正在加入草稿…" }
        if store?.task(taskID)?.attachments?.contains(where: { $0.browserDownloadID == record.id }) == true { return "已添加附件" }
        return nil
    }

    func reveal(_ record: AgentBrowserDownloadRecord) {
        do { NSWorkspace.shared.activateFileViewerSelecting([try readyFile(record)]) }
        catch { report(error.localizedDescription) }
    }

    func attach(_ record: AgentBrowserDownloadRecord) async {
        guard let store, attachmentStatus(record) == nil else { return }
        importing.insert(record.id)
        defer { importing.remove(record.id); onChange?() }
        do {
            let url = try readyFile(record)
            try AgentAttachments.validateImportFiles([url], store: store, taskID: taskID)
            _ = try await AgentAttachments.importFile(url, store: store, taskID: taskID, browserDownload: record)
            report("已加入草稿 " + record.name)
        } catch { report(error.localizedDescription) }
    }
}
