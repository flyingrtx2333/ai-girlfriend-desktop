import AppKit

@MainActor extension AppDelegate {
    func prepareSemanticSecurityCheck(_ output: URL, tasks: AgentStore) async throws -> AgentGit {
        let repo = output.appendingPathComponent("semantic-project"), temporary = output.appendingPathComponent("git-tmp")
        for url in [repo, temporary] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        let files = try AgentFiles(workspace: repo.path)
        func write(_ path: String, _ text: String) throws { try files.writeData(Data(text.utf8), to: files.root.appendingPathComponent(path), permissions: 0o600) }
        func setup(_ args: [String]) async throws {
            let result = try await AgentCommand().run(command: try AgentGit.executablePath(), workspace: repo, scratch: temporary, network: false,
                timeout: 15, gitDirectory: repo.appendingPathComponent(".git"), gitWrite: true, arguments: args)
            guard !result.failed else { throw PetError("无法准备语义检查项目") }
        }
        let safe = """
        from flask import request
        def lookup(cursor):
            name = request.args.get("name")
            cursor.execute("SELECT * FROM users WHERE name = %s", (name,))

        """
        let unsafe = """
        from flask import request
        def lookup(cursor):
            name = request.args.get("name")
            query = "SELECT * FROM users WHERE name = '" + name + "'"
            cursor.execute(query)

        """
        try await setup(["init", "-b", "main"])
        try await setup(["config", "core.excludesFile", "/dev/null"])
        try write("查询.py", safe)
        try await setup(["add", "--", "查询.py"])
        try await setup(["-c", "user.name=Semantic Acceptance", "-c", "user.email=check@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "parameterized query"])
        try write("查询.py", unsafe)
        try await setup(["add", "--", "查询.py"])
        try write("查询.py", safe + "# workspace version\n")
        try write("api.ts", """
        import { exec } from "node:child_process";
        export function route(req, res, db) {
          const value = req.query.name;
          const query = "SELECT * FROM users WHERE name = '" + value + "'";
          db.query(query);
          exec("echo " + value);
        }
        export function safe(req, res, db) {
          db.query("SELECT * FROM users WHERE name = ?", [req.query.name]);
        }

        """)
        try write("calls.py", """
        from flask import request
        def query(db, value):
            db.execute(value)
        def route(db):
            value = request.args.get("name")
            query(db, "SELECT " + value)

        """)
        try write("shell.py", """
        from flask import request
        import subprocess, shlex
        def unsafe():
            value = request.args.get("file")
            command = "cat " + value
            subprocess.run(command, shell=True)
        def safe():
            value = request.args.get("file")
            subprocess.run("cat " + shlex.quote(value), shell=True)

        """)
        try write("eval.py", """
        from flask import request
        def unsafe():
            value = request.form.get("code")
            return eval(value)
        def fixed():
            import json
            return json.loads(request.form.get("code"))

        """)
        try write("eval.js", """
        export function unsafe(req) {
          const value = req.body.code;
          return eval(value);
        }
        export function fixed(req) {
          return JSON.parse(req.body.code);
        }

        """)
        try write("README.md", "semantic fixture private marker\n")
        let id = tasks.create(title: "轻量语义检查", workspace: files.root.path)
        return try AgentGit(store: tasks, taskID: id, directory: AgentGit.metadata(workspace: files.root.path))
    }

    func runSemanticSecurityCheck(_ output: URL) async {
        var report: [String: Any] = [:], checks: [String: Bool] = [:]
        do {
            let tasks = AgentStore(directory: store.directory, legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            let git = try await prepareSemanticSecurityCheck(output, tasks: tasks)
            let index = try Data(contentsOf: git.directory.appendingPathComponent("index"))
            let status = try await git.output(["status", "--porcelain=v1", "-z"])
            let working = try await git.checkCodeSecurity(source: .uncommitted, requested: ["查询.py", "api.ts", "calls.py", "shell.py", "eval.py", "eval.js", "README.md"], mode: .semantic)
            checks["parameterizedQueryDoesNotProduceFlow"] = !working.findings.contains { $0.path == "查询.py" }
            checks["nodeSQLAndShellHaveActualSourceLocations"] = working.findings.filter { $0.path == "api.ts" }.map(\.rule) == ["js-request-sql", "js-request-shell"]
                && working.findings.filter { $0.path == "api.ts" }.allSatisfy { $0.trace?.first?.line == 3 && $0.trace?.last?.line == $0.line }
            checks["sameFileFunctionCallsAreTraced"] = working.findings.contains { $0.path == "calls.py" && $0.line == 3 && $0.rule == "python-request-sql" }
            checks["shellQuoteBlocksTheKnownShellFlow"] = working.findings.filter { $0.path == "shell.py" }.count == 1
                && working.findings.first { $0.path == "shell.py" }?.line == 6
            checks["pythonEvalFlowExcludesJSONParser"] = working.findings.filter { $0.path == "eval.py" }.count == 1
                && working.findings.first { $0.path == "eval.py" }?.rule == "python-request-eval"
                && working.findings.first { $0.path == "eval.py" }?.line == 4
            checks["javascriptEvalFlowExcludesJSONParser"] = working.findings.filter { $0.path == "eval.js" }.count == 1
                && working.findings.first { $0.path == "eval.js" }?.rule == "js-request-eval"
                && working.findings.first { $0.path == "eval.js" }?.line == 3
            checks["unsupportedFilesAreCountedAsSkipped"] = working.scannedFiles == 6 && working.skipped.map(\.path) == ["README.md"]
            let staged = try await git.checkCodeSecurity(source: .staged, requested: ["查询.py"], mode: .semantic)
            guard let finding = staged.findings.first, let source = finding.trace?.first else { throw PetError("暂存版本缺少数据流依据") }
            checks["indexUsesImmutableVersionAndCompleteFlow"] = staged.scannedFiles == 1 && staged.findings.count == 1
                && finding.line == 5 && source.line == 3 && finding.trace?.last?.line == 5
            try await git.validateSecurityLocation(finding, report: staged)
            try await git.validateSecurityLocation(finding.at(source), report: staged)
            let restored = try AgentGit(store: tasks, taskID: git.taskID, directory: git.directory).previousSemanticReport()
            checks["savedReportRetainsVerifiedSourceAndSink"] = restored.mode == .semantic && restored.workspace == git.files.root.path
                && restored.findings.first?.trace == finding.trace && restored.created == staged.created
            let encoded = try JSONEncoder().encode(restored), text = String(decoding: encoded, as: UTF8.self)
            checks["reportContainsMetadataWithoutRawCode"] = !text.contains("SELECT * FROM") && !text.contains("semantic fixture private marker")
            let finalStatus = try await git.output(["status", "--porcelain=v1", "-z"])
            checks["scanPreservesActualIndexAndWorkingTree"] = try finalStatus == status && Data(contentsOf: git.directory.appendingPathComponent("index")) == index
            report["working"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(working))
            report["staged"] = try JSONSerialization.jsonObject(with: encoded)
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks
        report["success"] = checks.count == 11 && checks.values.allSatisfy { $0 } && report["error"] == nil
        report["appPID"] = getpid()
        report["modelRequests"] = 0
        try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("semantic-security-report.json"), options: .atomic)
    }
}
