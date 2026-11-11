import Foundation
import Darwin

struct AgentDependencyDatabase: Codable {
    let ecosystem: String
    let publishedAt: Date
    let usedStaleCache: Bool
}

@MainActor enum AgentDependencyAdvisories {
    private static let maximumBytes = 512_000_000
    private static var updating: Set<URL> = []

    static func freeze(_ ecosystem: String, cache: URL, snapshot: URL, force: Bool, progress: (String) -> Void) async throws -> AgentDependencyDatabase {
        let fm = FileManager.default
        let relative = "osv-scalibr/" + ecosystem
        let directory = cache.appendingPathComponent(relative, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let archive = directory.appendingPathComponent("all.zip"), stamp = directory.appendingPathComponent("checked")
        while updating.contains(directory) {
            progress("等待 \(ecosystem) 公告库…")
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let cached = archiveDate(archive)
        let checked = try? stamp.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var stale = false
        if force || cached == nil || checked.map({ Date().timeIntervalSince($0) >= 86_400 }) != false {
            updating.insert(directory)
            defer { updating.remove(directory) }
            progress("更新 \(ecosystem) 公告库…")
            do {
                try await download(ecosystem, archive: archive, conditional: cached != nil && !force)
                try Data().write(to: stamp, options: .atomic)
            } catch {
                try Task.checkCancellation()
                guard cached != nil else { throw PetError("无法获取 \(ecosystem) 公告库") }
                stale = true
            }
        }
        try Task.checkCancellation()
        guard let date = archiveDate(archive) else { throw PetError("\(ecosystem) 公告库不可读") }
        let destination = snapshot.appendingPathComponent(relative, isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copy = destination.appendingPathComponent("all.zip")
        // Pin the exact advisory generation used by the scanner.
        do { try fm.linkItem(at: archive, to: copy) }
        catch { try fm.copyItem(at: archive, to: copy) }
        guard archiveDate(copy) == date else { throw PetError("\(ecosystem) 公告库已更新，请重新检查") }
        return AgentDependencyDatabase(ecosystem: ecosystem, publishedAt: date, usedStaleCache: stale)
    }

    private static func archiveDate(_ url: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int, size >= 22, size <= maximumBytes,
              let reader = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? reader.close() }
        guard let signature = try? reader.read(upToCount: 4), signature == Data([0x50, 0x4B, 0x03, 0x04]) else { return nil }
        return attributes[.modificationDate] as? Date
    }

    private static func download(_ ecosystem: String, archive: URL, conditional: Bool) async throws {
        let fm = FileManager.default
        let scratch = archive.deletingLastPathComponent().appendingPathComponent("download-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        let resultFile = scratch.appendingPathComponent("all.zip")
        var arguments = [
            "--disable", "--silent", "--show-error", "--fail", "--proto", "=https",
            "--connect-timeout", "12", "--max-time", "150", "--max-filesize", String(maximumBytes),
            "--remote-time", "--write-out", "%{http_code}", "--output", resultFile.path
        ]
        if conditional { arguments += ["--time-cond", archive.path] }
        arguments += ["https://osv-vulnerabilities.storage.googleapis.com/" + ecosystem + "/all.zip"]
        let result = try await AgentCommand().run(command: "/usr/bin/curl", workspace: scratch, scratch: scratch,
            network: true, timeout: 155, readOnly: true, readRoots: conditional ? [archive] : [],
            environment: ["HOME": scratch.path], arguments: arguments)
        try Task.checkCancellation()
        guard !result.failed else { throw PetError("公告库下载失败") }
        if result.stdout == "304", conditional { return }
        guard result.stdout == "200", archiveDate(resultFile) != nil else { throw PetError("公告库响应无效") }
        guard rename(resultFile.path, archive.path) == 0 else { throw PetError("无法保存公告库") }
    }
}
