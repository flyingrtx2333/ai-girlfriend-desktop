import AppKit

@MainActor extension AppDelegate {
    private static let securityFile = "00-transport.js"

    func prepareCodeSecurityCheck(_ output: URL, tasks: AgentStore) async throws -> AgentGit {
        let repo = output.appendingPathComponent("security-project", isDirectory: true)
        let scratch = output.appendingPathComponent("security-git", isDirectory: true)
        let fm = FileManager.default
        for directory in [repo, scratch] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let files = try AgentFiles(workspace: repo.path)
        func write(_ path: String, _ value: String) throws {
            try files.writeData(Data(value.utf8), to: files.root.appendingPathComponent(path), permissions: 0o600)
        }
        func git(_ args: [String]) async throws {
            let result = try await AgentCommand().run(command: try AgentGit.executablePath(), workspace: repo, scratch: scratch,
                network: false, timeout: 15, gitDirectory: repo.appendingPathComponent(".git"), gitWrite: true, arguments: args)
            guard !result.failed else { throw PetError("验收仓库 Git 操作失败") }
        }
        try await git(["init", "-b", "main"])
        try await git(["config", "core.excludesFile", "/dev/null"])
        let transport = Self.securityFile
        let clean = "const name = \"海盐\";\nconst options = { rejectUnauthorized: true };\n"
        try write(transport, clean)
        try write("deleted.txt", "baseline\n")
        try await git(["add", "--", transport, "deleted.txt"])
        try await git(["-c", "user.name=Code Security Acceptance", "-c", "user.email=check@example.invalid",
                       "-c", "commit.gpgsign=false", "commit", "-m", "public fixture baseline"])
        try write(transport, clean + "const result = eval(input);\n")
        try await git(["add", "--", transport])
        try await git(["rm", "--", "deleted.txt"])
        try write(transport, clean.replacingOccurrences(of: ": true", with: ": /* audit */ false"))
        try write("源文件/校验.py", "import requests, subprocess\nrequests.get(url, verify=False)\nsubprocess.run(command, shell=True)\n")
        // Format-only inert value. It is never used to authenticate.
        let inert = "ghp_" + String(AgentFiles.hash(Data("published-inert-scanner-proof".utf8)).prefix(36))
        try write(".env", "GITHUB_TOKEN=" + inert + " # gitleaks:allow\n")
        try write("empty.md", "")
        try write("binary.bin", "header\0bytes")
        try write("oversize.txt", String(repeating: "a", count: AgentCodeSecurity.fileLimit + 1))
        try fm.createSymbolicLink(at: repo.appendingPathComponent("alias.js"), withDestinationURL: repo.appendingPathComponent(transport))
        let id = tasks.create(title: "代码安全检查", workspace: repo.path)
        return try AgentGit(store: tasks, taskID: id, directory: AgentGit.metadata(workspace: repo.path))
    }

    func runCodeSecurityCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        do {
            let tasks = AgentStore(directory: store.directory, legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            let git = try await prepareCodeSecurityCheck(output, tasks: tasks)
            let path = Self.securityFile, file = try git.files.literalURL(path)
            let before = try git.files.readData(file)
            let state = try await git.output(["status", "--porcelain=v1", "-z"])
            let indexURL = git.directory.appendingPathComponent("index")
            let index = try Data(contentsOf: indexURL)
            let head = try await git.output(["rev-parse", "HEAD"])
            let working = try await git.checkCodeSecurity(source: .uncommitted,
                requested: [path, ".env", "源文件/校验.py", "empty.md", "binary.bin", "alias.js", "deleted.txt", "oversize.txt"])
            let staged = try await git.checkCodeSecurity(source: .staged, requested: [path, "deleted.txt"])
            let unstaged = try await git.checkCodeSecurity(source: .unstaged, requested: [path])
            let clean = try await git.checkCodeSecurity(source: .uncommitted, requested: ["empty.md"])
            let encoded = try JSONEncoder().encode(working)
            let env = try String(contentsOf: git.files.literalURL(".env"), encoding: .utf8)
            let inert = String(env.dropFirst("GITHUB_TOKEN=".count).prefix(40))
            let unchanged = try await git.output(["status", "--porcelain=v1", "-z"])
            let currentHead = try await git.output(["rev-parse", "HEAD"])
            checks["scanPreservesRealGitStateAndReview"] = try unchanged == state && index == Data(contentsOf: indexURL)
                && before == git.files.readData(file) && head == currentHead && tasks.task(git.taskID)?.gitReview == nil
            checks["workingAndIndexHaveDifferentFindings"] = working.findings.filter { $0.path == path }.map(\.rule) == ["js-tls-verification"]
                && staged.findings.map(\.rule) == ["js-eval"] && staged.findings.first?.line == 3
            checks["unstagedAndWorkingReadSameBytes"] = unstaged.findings.map(\.rule) == ["js-tls-verification"]
            checks["unicodePathAndPythonLocations"] = working.findings.filter { $0.path == "源文件/校验.py" }.map(\.line) == [2, 3]
            checks["hiddenCredentialDetectedAndReportRedacted"] = working.findings.contains { $0.path == ".env" && $0.line == 1 && $0.rule == "github-pat" }
                && !String(decoding: encoded, as: UTF8.self).contains(inert)
            checks["scanCountsSkippedAndTextFiles"] = working.scannedFiles == 4
                && Set(working.skipped.map(\.path)) == Set(["binary.bin", "alias.js", "deleted.txt", "oversize.txt"]) && staged.skipped.map(\.path) == ["deleted.txt"]
            checks["emptyTextCanReturnClean"] = clean.findings.isEmpty && clean.scannedFiles == 1 && clean.skipped.isEmpty
            guard let finding = working.findings.first(where: { $0.path == path }), let stageFinding = staged.findings.first else {
                throw PetError("两层 Git 发现缺失")
            }
            try await git.validateSecurityLocation(finding, report: working)
            try await git.validateSecurityLocation(stageFinding, report: staged)
            checks["locationsBelongToExactSnapshots"] = finding.line == 2 && stageFinding.line == 3
            checks["onlyWorkingFixCanBeOffered"] = working.canFix(finding) && !staged.canFix(stageFinding)
            let updated = before + Data("// changed after scan\n".utf8)
            try git.files.writeData(updated, to: file, permissions: 0o600)
            do { _ = try git.applySecurityFix(finding, report: working); checks["staleFindingCannotOverwrite"] = false }
            catch { checks["staleFindingCannotOverwrite"] = try git.files.readData(file) == updated }
            do { try await git.validateSecurityLocation(finding, report: working); checks["staleLocationCannotMislead"] = false }
            catch { checks["staleLocationCannotMislead"] = true }
            try git.files.writeData(before, to: file, permissions: 0o600)
            let id = try git.applySecurityFix(finding, report: working)
            let after = try git.files.readData(file)
            let rescanned = try await git.checkCodeSecurity(source: .uncommitted, requested: [path])
            checks["fixChangesOnlyTheVerifiedLiteral"] = try String(decoding: after, as: UTF8.self) == String(decoding: before, as: UTF8.self)
                .replacingOccurrences(of: "/* audit */ false", with: "/* audit */ true") && Data(contentsOf: indexURL) == index && rescanned.findings.isEmpty
            guard let checkpoint = tasks.task(git.taskID)?.changes.first(where: { $0.id == id }) else { throw PetError("缺少修复检查点") }
            try AgentChanges.restore(checkpoint, taskID: git.taskID, store: tasks)
            checks["undoRestoresBytesAndPermissions"] = try git.files.readData(file) == before && Data(contentsOf: indexURL) == index
                && git.files.entryMetadata(file).permissions == 0o600
            report["working"] = try JSONSerialization.jsonObject(with: encoded)
            report["staged"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(staged))
            report["head"] = head.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            report["error"] = error.localizedDescription
        }
        report["checks"] = checks
        report["success"] = checks.count == 13 && checks.values.allSatisfy { $0 } && report["error"] == nil
        report["modelRequests"] = 0
        report["appPID"] = getpid()
        try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("code-security-report.json"), options: .atomic)
    }
}
