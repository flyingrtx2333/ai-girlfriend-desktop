import AppKit

@MainActor extension AppDelegate {
    private static let cargoFixture = "锁文件/Cargo.lock"

    func prepareDependencyCheck(_ output: URL, tasks: AgentStore, expanded: Bool) async throws -> AgentGit {
        let repo = output.appendingPathComponent("dependency-project", isDirectory: true)
        let scratch = output.appendingPathComponent("fixture-git", isDirectory: true)
        for url in [repo, scratch] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let files = try AgentFiles(workspace: repo.path)
        func write(_ path: String, _ text: String) throws {
            try files.writeData(Data(text.utf8), to: files.root.appendingPathComponent(path), permissions: 0o600)
        }
        func setup(_ arguments: [String]) async throws {
            let result = try await AgentCommand().run(command: try AgentGit.executablePath(), workspace: files.root, scratch: scratch,
                network: false, timeout: 15, gitDirectory: files.root.appendingPathComponent(".git"), gitWrite: true, arguments: arguments)
            guard !result.failed else { throw PetError("无法准备依赖检查的 Git 仓库") }
        }
        func cargo(_ version: String) -> String {
            "version = 3\n\n[[package]]\nname = \"time\"\nversion = \"\(version)\"\nsource = \"registry+https://github.com/rust-lang/crates.io-index\"\n"
        }
        try await setup(["init", "-b", "main"])
        try await setup(["config", "core.excludesFile", "/dev/null"])
        try write(".gitignore", "ignored/\n")
        try write(Self.cargoFixture, cargo("0.3.47"))
        try await setup(["add", "--", ".gitignore", Self.cargoFixture])
        try await setup(["-c", "user.name=Dependency Acceptance", "-c", "user.email=check@example.invalid", "-c", "commit.gpgsign=false",
                         "commit", "-m", "baseline dependencies"])
        try write(Self.cargoFixture, cargo("0.1.44"))
        try await setup(["add", "--", Self.cargoFixture])
        try write(Self.cargoFixture, cargo("0.3.47"))
        if expanded {
            let npm = output.appendingPathComponent("public-package-lock.json")
            let lockfile = try AgentFiles(workspace: output.path).readData(npm, maximum: 100_000)
            // A genuine npm-generated lockfile with legal JSON whitespace to
            // exercise blobs larger than the command output capture limit.
            var large = Data(repeating: 0x20, count: 2_100_000); large.append(lockfile)
            try files.writeData(large, to: files.root.appendingPathComponent("package-lock.json"), permissions: 0o600)
            try await setup(["add", "--", "package-lock.json"])
            try files.remove(files.root.appendingPathComponent("package-lock.json"))
            try write("python/requirements.txt", "urllib3==1.26.4\n")
            try write("ranges/requirements.txt", "urllib3>=1.26.4\n")
            try write("invalid/Cargo.lock", "invalid Cargo lockfile\n")
            try write("ignored/Cargo.lock", cargo("0.1.44"))
        }
        let taskID = tasks.create(title: "依赖漏洞验收", workspace: files.root.path)
        return try AgentGit(store: tasks, taskID: taskID, directory: AgentGit.metadata(workspace: files.root.path))
    }

    func runDependencySecurityCheck(_ output: URL) async {
        var report: [String: Any] = [:], checks: [String: Bool] = [:]
        do {
            let tasks = AgentStore(directory: store.directory, legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            let git = try await prepareDependencyCheck(output, tasks: tasks, expanded: true)
            let scan = try AgentDependencySecurity(store: tasks, taskID: git.taskID, git: git)
            let indexURL = git.directory.appendingPathComponent("index")
            let index = try Data(contentsOf: indexURL)
            let head = try await git.output(["rev-parse", "HEAD"])
            let status = try await git.output(["status", "--porcelain=v1", "-z"])
            let staged = try await scan.scan(source: .staged)
            let cargo = staged.findings.first { $0.aliases.contains("CVE-2020-26235") }
            checks["exactStagedCargoAdvisoryAndFix"] = cargo?.version == "0.1.44" && cargo?.path == Self.cargoFixture
                && cargo?.score == 6.2 && cargo?.fixedVersions == ["0.2.23"]
            let npm = staged.findings.first { $0.package == "lodash" && $0.aliases.contains("CVE-2021-23337") }
            checks["largeStagedNpmBlobReadExactly"] = npm?.version == "4.17.20" && npm?.path == "package-lock.json"
                && npm?.fixedVersions.contains("4.17.21") == true && staged.scannedFiles == 2 && staged.packages >= 3
            checks["actualPublicAdvisoryDatabasesDownloaded"] = Set(staged.databases.map(\.ecosystem)) == ["crates.io", "npm"]
                && staged.databases.allSatisfy { !$0.usedStaleCache && $0.publishedAt < Date() }
            let working = try await scan.scan(source: .working)
            checks["fullWorkingScopeHasOwnVersionsAndPublicPyPIResult"] = working.scannedFiles == 2 && working.packages == 2
                && !working.findings.contains { $0.package == "time" || $0.package == "lodash" }
                && working.findings.contains { $0.package == "urllib3" && $0.version == "1.26.4" && $0.path == "python/requirements.txt" }
            checks["invalidUnpinnedAndMissingFilesAreReported"] = Set(working.skipped.map(\.path))
                == ["invalid/Cargo.lock", "ranges/requirements.txt", "package-lock.json"]
            var progress: [String] = []
            let selected = try await scan.scan(source: .working, requested: [Self.cargoFixture]) { progress.append($0) }
            checks["selectedScopeAndFreshCache"] = selected.selectedOnly && selected.packages == 1 && selected.findings.isEmpty
                && selected.skipped.isEmpty && !progress.contains { $0.hasPrefix("更新") }
            let reopened = try AgentDependencySecurity(store: tasks, taskID: git.taskID, git: git)
            checks["reportPersistsForOriginalTask"] = reopened.previousReport()?.created == selected.created
                && reopened.previousReport()?.source == .working && reopened.previousReport()?.selectedOnly == true
            let actualHead = try await git.output(["rev-parse", "HEAD"])
            let actualStatus = try await git.output(["status", "--porcelain=v1", "-z"])
            checks["preservesGitIndexHeadAndWorkspace"] = try actualHead == head && actualStatus == status && Data(contentsOf: indexURL) == index
                && tasks.task(git.taskID)?.gitReview == nil
            let folder = output.appendingPathComponent("standalone-project")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let files = try AgentFiles(workspace: folder.path)
            let blob = try await git.securityIndexEntries([Self.cargoFixture])
            guard let object = blob[Self.cargoFixture] else { throw PetError("缺少验收锁文件") }
            let data = try await git.securityBlob(object)
            try files.writeData(data, to: files.root.appendingPathComponent("Cargo.lock"))
            try files.writeData(data, to: files.root.appendingPathComponent("node_modules/unused/Cargo.lock"))
            let standaloneID = tasks.create(title: "无 Git 依赖检查", workspace: files.root.path)
            let standalone = try AgentDependencySecurity(store: tasks, taskID: standaloneID, git: nil)
            let local = try await standalone.scan(source: .working)
            checks["ordinaryFolderScansWithoutGit"] = local.scannedFiles == 1 && local.findings.contains { $0.aliases.contains("CVE-2020-26235") }
                && local.skipped.isEmpty && !standalone.supportsStaging
            let boundary = FileManager.default.temporaryDirectory.appendingPathComponent("dependency-boundary-" + UUID().uuidString)
            let scratch = boundary.appendingPathComponent("scratch"), snapshot = scratch.appendingPathComponent("files")
            try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: boundary) }
            let neighbor = boundary.appendingPathComponent("neighbor.txt")
            try Data("outside scan snapshot".utf8).write(to: neighbor)
            let denied = try await AgentCommand().run(command: "/bin/cat", workspace: snapshot, scratch: scratch, network: false, timeout: 5,
                readOnly: true, listSnapshotParents: true, arguments: [neighbor.path])
            checks["snapshotTraversalDoesNotExposeSiblingFiles"] = denied.failed && denied.stdoutData?.isEmpty == true
            report["staged"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(staged))
            report["working"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(working))
            report["selected"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selected))
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks
        report["success"] = checks.count == 10 && checks.values.allSatisfy { $0 } && report["error"] == nil
        report["appPID"] = getpid()
        report["modelRequests"] = 0
        try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("dependency-security-report.json"), options: .atomic)
    }
}
