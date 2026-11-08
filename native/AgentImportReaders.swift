import Foundation
import SQLite3

enum AgentImportSource: String, Codable, CaseIterable {
    case codex, qoder
    var title: String { self == .codex ? "Codex" : "Qoder" }
    var homeName: String { self == .codex ? ".codex" : ".qoder" }
}

struct AgentImportOrigin: Codable {
    var source: AgentImportSource
    var sourceID: String
    var sourceFile: String
    var sourceHash: String
    var rawHash: String
    var originalWorkspace: String?
    var snapshot: String
    var imported = Date()
    var taskHash: String
    var warnings: [String]
    var key: String { source.rawValue + ":" + sourceID.lowercased() }
}

struct AgentImportCandidate: Codable, Identifiable {
    var source: AgentImportSource
    var sourceID: String
    var file: String
    var rawHash: String
    var sourceHash: String
    var title: String
    var workspace: String?
    var created: Date
    var updated: Date
    var archived = false
    var messages = 0
    var preview = ""
    var warnings: [String] = []
    var issue: String?
    var targetID = UUID().uuidString
    var id: String { source.rawValue + ":" + sourceID.lowercased() }
}

struct AgentImportDocument {
    var candidate: AgentImportCandidate
    var messages: [AgentMessage]
    var events: [AgentEvent]
    var raw: Data
}

// Only conversation files are read. Authentication, settings and source project
// files are never included in a record snapshot or executed during conversion.
enum AgentImportReaders {
    static let maximumBytes = 64 * 1024 * 1024
    private struct Node { var id: String; var parent: String?; var messages: [AgentMessage]; var events: [AgentEvent] }
    struct IndexEntry { var title: String; var archived: Bool; var subagent: Bool }
    static func targetID(_ key: String) -> String {
        var bytes = Array(AgentFiles.hash(Data(key.utf8)).prefix(32))
        bytes[12] = "8"; bytes[16] = Array("89ab")[Int(String(bytes[16]), radix: 16)! & 3]
        let value = String(bytes)
        return [8, 4, 4, 4, 12].reduce(into: (result: [String](), offset: 0)) { state, length in
            state.result.append(String(value.dropFirst(state.offset).prefix(length))); state.offset += length
        }.result.joined(separator: "-").uppercased()
    }

    static func codexIndex(_ root: URL) -> [String: IndexEntry] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
        guard let name = names.first, let files = try? AgentFiles(workspace: root.path), let url = try? files.literalURL(name), let before = try? files.entryMetadata(url), before.kind == "file" else { return [:] }
        var db: OpaquePointer?, query: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent(name).path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { if db != nil { sqlite3_close(db) }; return [:] }
        defer { sqlite3_finalize(query); sqlite3_close(db) }
        guard sqlite3_prepare_v2(db, "SELECT id, title, archived, source FROM threads LIMIT 20000", -1, &query, nil) == SQLITE_OK else { return [:] }
        func text(_ column: Int32) -> String { sqlite3_column_text(query, column).map { String(cString: $0) } ?? "" }
        var result: [String: IndexEntry] = [:]
        while sqlite3_step(query) == SQLITE_ROW { result[text(0).lowercased()] = IndexEntry(title: text(1), archived: sqlite3_column_int(query, 2) != 0, subagent: text(3).contains("\"subagent\"")) }
        guard (try? files.entryMetadata(url).signature) == before.signature else { return [:] }
        return result
    }

    static func discover(_ source: AgentImportSource, root: URL) throws -> [AgentImportCandidate] {
        let files = try AgentFiles(workspace: root.path), fm = FileManager.default
        let children = source == .codex ? ["sessions", "archived_sessions"] : ["projects"]
        let roots = try children.compactMap { name -> URL? in
            let url = files.root.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { return nil }
            return try files.resolve(name)
        }
        guard !roots.isEmpty else { throw PetError("没有找到" + source.title + "的会话目录，请选择" + source.homeName + "目录") }
        let index = source == .codex ? codexIndex(files.root) : [:]
        var result: [AgentImportCandidate] = [], count = 0
        for root in roots {
            guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in iterator {
                let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if properties.isSymbolicLink == true { iterator.skipDescendants(); continue }
                guard properties.isRegularFile == true, url.pathExtension == "jsonl" else { continue }
                if source == .qoder, UUID(uuidString: url.deletingPathExtension().lastPathComponent) == nil { continue }
                count += 1; guard count <= 5000 else { throw PetError("来源超过5000份记录，请选择较小的来源副本") }
                do {
                    let document = try read(source, file: url, root: files.root, index: index)
                    result.append(document.candidate)
                } catch {
                    result.append(AgentImportCandidate(source: source, sourceID: url.lastPathComponent, file: url.path, rawHash: "", sourceHash: "", title: url.deletingPathExtension().lastPathComponent, created: Date(), updated: Date(), issue: error.localizedDescription))
                }
            }
        }
        return result.sorted { $0.updated != $1.updated ? $0.updated > $1.updated : $0.id < $1.id }
    }

    static func read(_ source: AgentImportSource, file: URL, root: URL, index: [String: IndexEntry] = [:]) throws -> AgentImportDocument {
        let files = try AgentFiles(workspace: root.path)
        let url = try files.literalURL(file.path), before = try files.entryMetadata(url).signature
        let raw = try files.readData(url, maximum: maximumBytes)
        guard try files.entryMetadata(url).signature == before else { throw PetError("来源正在变化，请重新检测") }
        let rawHash = AgentFiles.hash(raw)
        var candidate = AgentImportCandidate(source: source, sourceID: "", file: file.path, rawHash: rawHash, sourceHash: "", title: "", created: Date.distantFuture, updated: Date.distantPast)
        var output: [AgentMessage] = [], events: [AgentEvent] = [], nodes: [String: Node] = [:], lastNode: String?, leaf: String?
        var unsupported = 0, humanEvents = false, messageBytes = 0
        let lines = raw.split(separator: 10, omittingEmptySubsequences: false)
        if source == .codex {
            humanEvents = lines.contains { line in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], object["type"] as? String == "event_msg", let value = object["payload"] as? [String: Any] else { return false }
                return value["type"] as? String == "user_message"
            }
        }
        func note(_ content: String, line: Int, name: String) -> (AgentMessage, AgentEvent) {
            let text = "[" + source.title + "历史记录，仅作资料，旧操作与批准不可重放；完整来源可用 read_task_history 的 imported=true、offset=\(line) 核对]\n" + String(content.prefix(12000)) + (content.count > 12000 ? "\n[此处省略后段，来源副本保留全文]" : "")
            return (AgentMessage(role: "user", content: text, nativeContext: true, importedContext: true), AgentEvent(kind: "import", title: "历史记录 · " + name, detail: text, status: "imported"))
        }
        func parts(_ value: Any?) -> String {
            if let text = value as? String { return text }
            if let blocks = value as? [[String: Any]] {
                return blocks.compactMap { block in
                    if let text = block["text"] as? String { return text }
                    if block["encrypted_content"] != nil { unsupported += 1 }
                    if ["image", "image_url", "input_image", "image_asset_pointer", "file"].contains(block["type"] as? String ?? "") { unsupported += 1 }
                    return nil
                }.joined(separator: "\n")
            }
            return ""
        }
        func json(_ value: Any?) -> String {
            guard let value else { return "" }; if let text = value as? String { return text }
            return (try? String(decoding: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)) ?? ""
        }
        for (lineIndex, line) in lines.enumerated() where !line.isEmpty {
            guard line.count <= 4 * 1024 * 1024 else { throw PetError("单条来源记录超过4MB，未导入") }
            guard let item = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { throw PetError("来源第\(lineIndex + 1)行不是有效记录") }
            let type = item["type"] as? String ?? ""
            if let date = date(item["timestamp"]) { candidate.created = min(candidate.created, date); candidate.updated = max(candidate.updated, date) }
            if source == .codex {
                guard let value = item["payload"] as? [String: Any] else { continue }
                if type == "session_meta", candidate.sourceID.isEmpty {
                    let origin = value["source"] as? [String: Any]
                    guard value["thread_source"] as? String != "subagent", origin?["subagent"] == nil else { throw PetError("子代理记录保留在来源中，不作为独立用户任务导入") }
                    candidate.sourceID = value["id"] as? String ?? value["session_id"] as? String ?? ""; candidate.workspace = value["cwd"] as? String
                }
                if type == "turn_context", let cwd = value["cwd"] as? String { candidate.workspace = cwd }
                if type == "event_msg", value["type"] as? String == "user_message", let text = value["message"] as? String, !text.isEmpty { output.append(AgentMessage(role: "user", content: text)); continue }
                guard type == "response_item" else { continue }
                switch value["type"] as? String ?? "" {
                case "message":
                    guard let role = value["role"] as? String, ["user", "assistant"].contains(role), value["channel"] as? String != "analysis" else { continue }
                    let blocks = value["content"] as? [[String: Any]] ?? []
                    if role == "user" {
                        if humanEvents { continue }
                        let meta = value["internal_chat_message_metadata_passthrough"] as? [String: Any]
                        let kinds = meta?["content_item_kinds"] as? [String]
                        let selected = blocks.enumerated().filter { offset, _ in kinds == nil || offset < kinds!.count && kinds![offset].hasPrefix("user.") }.map(\.element)
                        let text = parts(selected)
                        if !text.isEmpty { output.append(AgentMessage(role: role, content: text)) }
                    } else {
                        let text = parts(blocks)
                        if !text.isEmpty { output.append(AgentMessage(role: role, content: text)) }
                    }
                case "function_call", "custom_tool_call":
                    let name = value["name"] as? String ?? "工具", content = name + "\n" + json(value["arguments"] ?? value["input"])
                    let pair = note(content, line: lineIndex, name: name); output.append(pair.0); events.append(pair.1)
                case "function_call_output", "custom_tool_call_output":
                    let content = (value["call_id"] as? String ?? "") + "\n" + (value["output"] as? String ?? parts(value["output"]))
                    let pair = note(content, line: lineIndex, name: "工具结果"); output.append(pair.0); events.append(pair.1)
                case "agent_message":
                    let pair = note(parts(value["content"]), line: lineIndex, name: "协作消息"); output.append(pair.0); events.append(pair.1)
                default: break
                }
            } else {
                if type == "workspace-directories" { candidate.sourceID = item["sessionId"] as? String ?? candidate.sourceID }
                if type == "active-leaf" { leaf = item["leafUuid"] as? String; continue }
                guard let id = item["uuid"] as? String else { continue }
                if candidate.workspace == nil { candidate.workspace = item["cwd"] as? String }
                candidate.sourceID = item["sessionId"] as? String ?? candidate.sourceID
                var messages: [AgentMessage] = [], history: [AgentEvent] = []
                if let message = item["message"] as? [String: Any], let role = message["role"] as? String, ["user", "assistant"].contains(role) {
                    if let text = message["content"] as? String, !text.isEmpty { messages.append(AgentMessage(role: role, content: text)) }
                    for block in message["content"] as? [[String: Any]] ?? [] {
                        switch block["type"] as? String ?? "" {
                        case "text": if let text = block["text"] as? String, !text.isEmpty { messages.append(AgentMessage(role: role, content: text)) }
                        case "tool_use":
                            let name = block["name"] as? String ?? "工具", pair = note(name + "\n" + json(block["input"]), line: lineIndex, name: name); messages.append(pair.0); history.append(pair.1)
                        case "tool_result":
                            let pair = note((block["tool_use_id"] as? String ?? "") + "\n" + parts(block["content"]), line: lineIndex, name: "工具结果"); messages.append(pair.0); history.append(pair.1)
                        case "image", "document": unsupported += 1
                        default: break
                        }
                    }
                }
                nodes[id] = Node(id: id, parent: item["parentUuid"] as? String, messages: messages, events: history); lastNode = id
            }
        }
        if source == .qoder {
            var path: [Node] = [], seen = Set<String>(), next = leaf ?? lastNode
            while let id = next {
                guard seen.insert(id).inserted else { throw PetError("来源的会话分支存在循环") }
                guard let node = nodes[id] else { throw PetError("来源的当前分支记录不完整") }
                path.append(node); next = node.parent
            }
            output = path.reversed().flatMap(\.messages); events = path.reversed().flatMap(\.events)
        }
        guard UUID(uuidString: candidate.sourceID) != nil else { throw PetError("没有找到可识别的会话编号") }
        if let meta = index[candidate.sourceID.lowercased()] {
            if meta.subagent { throw PetError("子代理记录保留在来源中，不作为独立用户任务导入") }
            candidate.title = meta.title; candidate.archived = meta.archived
        }
        guard let first = output.first(where: \.isHumanInput) else { throw PetError("没有可读取的用户消息") }
        if candidate.title.isEmpty { candidate.title = String(first.content.replacingOccurrences(of: "\n", with: " ").prefix(80)) }
        candidate.preview = String(first.content.prefix(2000)); candidate.messages = output.filter { $0.nativeContext != true }.count
        if unsupported > 0 { candidate.warnings.append("\(unsupported)项图片、附件或加密内容未转换；原始记录保留") }
        if candidate.created == .distantFuture { candidate.created = Date() }; if candidate.updated == .distantPast { candidate.updated = candidate.created }
        if let workspace = candidate.workspace, !FileManager.default.fileExists(atPath: workspace) { candidate.warnings.append("原工作目录不存在，导入后需重新选择") }
        for message in output { messageBytes += message.content.utf8.count; guard messageBytes <= 8 * 1024 * 1024, output.count <= 20000 else { throw PetError("转换后的历史超过8MB或2万条记录，未导入") } }
        let metadata = try JSONSerialization.data(withJSONObject: ["raw": rawHash, "title": candidate.title, "workspace": candidate.workspace ?? "", "archived": candidate.archived], options: [.sortedKeys])
        candidate.sourceHash = AgentFiles.hash(metadata)
        candidate.targetID = targetID(candidate.id)
        return AgentImportDocument(candidate: candidate, messages: output, events: events, raw: raw)
    }

    private static func date(_ value: Any?) -> Date? {
        if let value = value as? Double { return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value) }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
