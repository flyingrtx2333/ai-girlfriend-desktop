import Foundation

enum AgentSemanticSecurity {
    struct Result {
        var findings: [AgentSecurityFinding] = []
        var skipped: [AgentSecurityReport.Skipped] = []
        var scanned = 0
    }
    private static func language(_ path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "py": return "python"
        case "js", "jsx", "mjs", "cjs": return "javascript"
        case "ts", "tsx", "mts", "cts": return "typescript"
        default: return nil
        }
    }
    static func supports(_ path: String) -> Bool { language(path) != nil }

    static func scan(snapshot: URL, scratch: URL, paths: [String: String]) async throws -> Result {
        guard !paths.isEmpty else { return Result() }
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "opengrep-core"),
              FileManager.default.isExecutableFile(atPath: executable.path),
              let rules = Bundle.main.resourceURL?.appendingPathComponent("security/semantic.yml") else {
            throw PetError("缺少语义检查组件，请重新构建应用")
        }
        let files = try AgentFiles(workspace: snapshot.path)
        var lineCounts: [String: Int] = [:]
        for alias in paths.keys {
            let text = String(decoding: try files.readData(files.literalURL(alias), maximum: AgentCodeSecurity.fileLimit), as: UTF8.self)
            lineCounts[alias] = text.components(separatedBy: "\n").count
        }
        func alias(_ path: String) throws -> String {
            let normalized = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
            guard paths[normalized] != nil else { throw PetError("语义检查结果引用了未知文件") }
            return normalized
        }
        func location(_ object: [String: Any], label: String) throws -> AgentSecurityLocation {
            guard let raw = object["path"] as? String, let start = object["start"] as? [String: Any],
                  let line = start["line"] as? Int else { throw PetError("语义检查位置不完整") }
            let key = try alias(raw)
            guard line > 0, line <= (lineCounts[key] ?? 0), let path = paths[key] else { throw PetError("语义检查位置超出文件范围") }
            return AgentSecurityLocation(path: path, line: line, label: label)
        }
        // Keep locations from the engine's trace, excluding raw code and values.
        func locations(_ value: Any?, label: String, depth: Int = 0) throws -> [AgentSecurityLocation] {
            guard depth < 16, let value else { return [] }
            if let object = value as? [String: Any] {
                if object["path"] != nil, object["start"] != nil { return [try location(object, label: label)] }
                if let nested = object["location"] { return try locations(nested, label: label, depth: depth + 1) }
            }
            if let array = value as? [Any] {
                return try array.flatMap { try locations($0, label: label, depth: depth + 1) }
            }
            return []
        }

        // Opengrep resolves XDG_CONFIG_HOME during startup, before creating files.
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("config"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var report = Result()
        let deadline = Date().addingTimeInterval(90)
        for target in paths.keys.sorted() {
            guard let lang = language(target) else { throw PetError("语义检查遇到不支持的文件类型") }
            let targets = [target] // The standalone core accepts one target with -lang.
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw PetError("语义检查超时，请缩小文件范围后重试") }
            let arguments = ["-rules", rules.path, "-lang", lang, "-json_nodots", "-j", "2", "-timeout", "10",
                "-max_memory", "512", "-taint_intrafile"] + targets.sorted()
            let result = try await AgentCommand().run(command: executable.path, workspace: snapshot, scratch: scratch,
                network: false, timeout: min(30, remaining), readOnly: true, maximumOutput: 2_000_000,
                readRoots: [executable, rules], environment: ["HOME": scratch.path], arguments: arguments)
            try Task.checkCancellation()
            guard result.exitCode == 0, result.truncated != true, result.timedOut != true, let data = result.stdoutData,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let matches = object["results"] as? [[String: Any]], let errors = object["errors"] as? [[String: Any]],
                  let coverage = object["paths"] as? [String: Any], let scanned = coverage["scanned"] as? [String] else {
                throw PetError("语义检查未完整结束，请缩小文件范围后重试")
            }
            var failed: [String: String] = [:]
            for error in errors {
                guard let raw = error["path"] as? String, let level = error["level"] as? String else {
                    throw PetError("语义检查规则或运行状态异常")
                }
                let key = try alias(raw)
                let type = (error["type"] as? String ?? "").lowercased()
                failed[key] = type.contains("timeout") ? "规则检查超时" : "源码无法完整解析"
                if level == "error", !type.contains("parse"), !type.contains("syntax"), !type.contains("timeout") {
                    throw PetError("语义检查引擎未完成分析")
                }
            }
            let scannedSet = try Set(scanned.map(alias))
            for target in targets {
                if let reason = failed[target] {
                    report.skipped.append(.init(path: paths[target]!, reason: reason))
                } else if scannedSet.contains(target) {
                    report.scanned += 1
                } else { report.skipped.append(.init(path: paths[target]!, reason: "分析内核未覆盖此文件")) }
            }
            for match in matches {
                guard let rule = match["check_id"] as? String, let extra = match["extra"] as? [String: Any],
                      let flow = extra["dataflow_trace"] as? [String: Any] else { throw PetError("语义检查缺少数据流依据") }
                let sink = try location(match, label: "危险调用")
                let title: String, advice: String
                switch rule {
                case "python-request-sql", "js-request-sql":
                    title = "外部输入进入 SQL"
                    advice = "使用参数化查询，把查询语句和参数分开传入。核对调用处使用的数据库 API。"
                case "python-request-shell", "js-request-shell":
                    title = "外部输入进入 Shell"
                    advice = "使用参数数组并关闭 Shell 执行，对允许的命令和参数作明确校验。"
                case "python-request-eval", "js-request-eval":
                    title = "外部输入被执行为代码"
                    advice = "用数据解析器或允许列表处理输入，移除动态代码执行。"
                default: throw PetError("语义检查返回了未知规则")
                }
                let sources = try locations(flow["taint_source"], label: "外部输入")
                let variables = try locations(flow["intermediate_vars"], label: "变量传播")
                let sinks = try locations(flow["taint_sink"], label: "危险调用")
                guard !sources.isEmpty, !sinks.isEmpty else { throw PetError("语义检查的数据流位置不完整") }
                let trace = sources + Array(variables.prefix(32)) + sinks
                var finding = AgentSecurityFinding(path: sink.path, line: sink.line, rule: rule, title: title, advice: advice, highRisk: true)
                finding.trace = trace
                report.findings.append(finding)
            }
        }
        report.findings.sort { ($0.path, $0.line, $0.rule) < ($1.path, $1.line, $1.rule) }
        return report
    }
}
