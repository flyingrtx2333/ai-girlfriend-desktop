import Foundation

struct AgentGitStatistics {
    var additions = 0, deletions = 0, binaryFiles = 0
    var title: String { "+\(additions)  −\(deletions)" + (binaryFiles > 0 ? " · \(binaryFiles) 二进制" : "") }
    mutating func append(_ data: String) throws {
        let records = data.split(separator: "\0", omittingEmptySubsequences: false)
        var index = 0
        while index < records.count {
            let record = records[index]; index += 1
            if record.isEmpty, index == records.count { break }
            let values = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard values.count == 3 else { throw PetError("Git 统计响应不完整") }
            // With -z, no-index comparisons (including /dev/null) carry both
            // paths after an empty third field, even when renames are disabled.
            if values[2].isEmpty {
                guard index + 1 < records.count, !records[index].isEmpty, !records[index + 1].isEmpty else { throw PetError("Git 统计路径不完整") }
                index += 2
            }
            if values[0] == "-", values[1] == "-" { binaryFiles += 1; continue }
            guard let added = Int(values[0]), let removed = Int(values[1]), added >= 0, removed >= 0 else { throw PetError("Git 统计响应无效") }
            additions += added; deletions += removed
        }
    }
}

@MainActor extension AgentGit {
    func statistics(source: AgentGitSource, revision: String, changes: [AgentGitChange]) async throws -> AgentGitStatistics {
        var total = AgentGitStatistics()
        if changes.isEmpty { return total }
        if source == .lastTurn {
            for change in changes {
                try Task.checkCancellation()
                let value = try await inspect(source: source, revision: revision, requested: [change.path])
                total.additions += value.additions; total.deletions += value.deletions; total.binaryFiles += value.binaryFiles
            }
            return total
        }
        let options = ["--no-ext-diff", "--no-textconv", "--no-renames", "--numstat", "-z"]
        let state = try await status()
        if source == .uncommitted && state.head == nil {
            for change in changes {
                try Task.checkCancellation()
                let path = try files.resolve(change.path)
                if FileManager.default.fileExists(atPath: path.path) {
                    let value = try await output(["diff", "--no-index"] + options + ["--", "/dev/null", change.path], allowingDifference: true); try total.append(value)
                }
            }
            return total
        }
        let range: [String]
        if source == .uncommitted { range = ["diff", "HEAD"] }
        else { range = try await diffArguments(source, revision: revision).arguments }
        let result = try await run(range + options + ["--"], maximumOutput: 1_000_000)
        guard !result.failed, result.truncated != true else { throw PetError("无法取得完整来源统计") }
        try total.append(result.stdout ?? "")
        if [.uncommitted, .unstaged].contains(source) {
            for change in changes where change.status == "??" {
                try Task.checkCancellation()
                let value = try await output(["diff", "--no-index"] + options + ["--", "/dev/null", change.path], allowingDifference: true); try total.append(value)
            }
        }
        return total
    }
    private func output(_ arguments: [String], allowingDifference: Bool) async throws -> String {
        let result = try await run(arguments)
        guard result.exitCode == 0 || allowingDifference && result.exitCode == 1, result.truncated != true else { throw PetError("无法取得完整文件统计") }
        return result.stdout ?? ""
    }
}
