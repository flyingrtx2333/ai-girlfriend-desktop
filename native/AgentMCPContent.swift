import Foundation

struct AgentMCPAttachmentSource: Codable, Sendable {
    var serverID: String
    var serverName: String
    var configuration: String
    var uri: String
    var mimeType: String
    var kind: String
    var created = Date()
}

struct AgentMCPContentPart {
    var role: String?
    var uri: String?
    var mimeType: String
    var data: Data
    var inline = false
    var text: String? { String(data: data, encoding: .utf8) }
}

struct AgentMCPContentPreview {
    var server: AgentMCPServer
    var owner: String
    var connection: String
    var catalog: String
    var kind: String
    var name: String
    var uri: String?
    var version = 0
    var parts: [AgentMCPContentPart]
    var created = Date()
    var digest: String
    var promptText: String {
        let header = "[用户选用的 MCP 提示词：\(server.name) / \(name)；版本 \(digest.prefix(12))]"
        return header + "\n" + parts.map { part in
            let role = part.role == "assistant" ? "助手示例（非实际回复）" : "用户模板"
            return "\n[\(role)]\n" + (part.inline ? part.text ?? "" : "[随消息附上 MCP 内容：\(part.uri ?? part.mimeType)，需读取实际附件。]")
        }.joined(separator: "\n")
    }
    var displayText: String {
        parts.enumerated().map { index, part in
            let label = part.role.map { $0 == "assistant" ? "助手示例（非实际回复）" : "用户模板" } ?? "内容 \(index + 1)"
            let description = "\(label) · \(part.mimeType) · \(part.data.count.formatted()) 字节" + (part.uri.map { "\n" + $0 } ?? "")
            let text = part.mimeType.hasPrefix("text/") || part.mimeType == "application/json" ? part.text : nil
            return description + "\n" + (text.map { String($0.prefix(12_000)) + ($0.count > 12_000 ? "\n[预览节选，附件保留完整内容]" : "") } ?? "SHA256 " + AgentFiles.hash(part.data))
        }.joined(separator: "\n\n────────\n\n")
    }
}

@MainActor enum AgentMCPContent {
    nonisolated static let opaqueTypes: Set<String> = ["bin", "wav", "mp3", "m4a", "ogg", "flac", "aac", "gz"]
    static func validURI(_ value: String) -> Bool {
        // A resource URI is an opaque server identifier, never a host file or
        // network URL for this application to open directly.
        guard !value.isEmpty, value.utf8.count <= 4000, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), value.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil else { return false }
        return true
    }
    static func catalogEntry(_ item: [String: Any], redact: (String) -> String) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for key in ["name", "title", "uri", "uriTemplate", "mimeType"] {
            if let value = item[key] as? String { guard value.utf8.count <= 4000 else { throw PetError("MCP 目录字段过长") }; result[key] = redact(value) }
        }
        if let value = item["description"] as? String { result["description"] = redact(String(value.prefix(800))) }
        if let value = item["size"] as? Int, value >= 0 { result["size"] = value }
        if let fields = item["arguments"] as? [[String: Any]] {
            guard fields.count <= 32 else { throw PetError("提示词参数超过 32 项") }
            result["arguments"] = try fields.map { field -> [String: Any] in
                guard let name = field["name"] as? String, !name.isEmpty, name.count <= 200 else { throw PetError("提示词参数名称无效") }
                var entry: [String: Any] = ["name": redact(name), "required": field["required"] as? Bool ?? false]
                for key in ["title", "description"] { if let value = field[key] as? String { entry[key] = redact(String(value.prefix(500))) } }
                return entry
            }
        }
        return result
    }
    private static func content(_ block: [String: Any], role: String?, resource: Bool, redact: (String) -> String) throws -> AgentMCPContentPart {
        let uri = block["uri"] as? String
        if let uri, !validURI(uri) { throw PetError("MCP 内容返回了无效 URI") }
        if let text = block["text"] as? String {
            let mime = block["mimeType"] as? String ?? "text/plain", sanitized = redact(text)
            guard sanitized.utf8.count <= 2_000_000 else { throw PetError("MCP 文本超过 2MB，请缩小读取范围") }
            return .init(role: role, uri: uri, mimeType: mime, data: Data(sanitized.utf8), inline: !resource)
        }
        guard let encoded = (block["blob"] ?? block["data"]) as? String, encoded.utf8.count <= 8_000_000,
              let bytes = Data(base64Encoded: encoded), bytes.count <= 6_000_000 else { throw PetError("MCP 二进制内容无效或超过 6MB") }
        let mime = block["mimeType"] as? String ?? "application/octet-stream"
        let textual = mime.hasPrefix("text/") || ["application/json", "application/xml"].contains(mime)
        if textual {
            guard let text = String(data: bytes, encoding: .utf8), !text.contains("\0") else { throw PetError("MCP 文本不是有效 UTF-8") }
            return .init(role: role, uri: uri, mimeType: mime, data: Data(redact(text).utf8))
        }
        return .init(role: role, uri: uri, mimeType: mime, data: bytes)
    }
    static func resource(_ data: Data, server: AgentMCPServer, owner: String, connection: String, catalog: String, uri: String, name: String, version: Int, redact: (String) -> String) throws -> AgentMCPContentPreview {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], let contents = value["contents"] as? [[String: Any]], !contents.isEmpty, contents.count <= 32 else { throw PetError("资源未返回内容或超过 32 项") }
        let parts = try contents.map { try content($0, role: nil, resource: true, redact: redact) }
        return .init(server: server, owner: owner, connection: connection, catalog: catalog, kind: "resources", name: name, uri: uri, version: version, parts: parts, digest: AgentFiles.hash(data))
    }
    static func prompt(_ data: Data, server: AgentMCPServer, owner: String, connection: String, catalog: String, name: String, redact: (String) -> String) throws -> AgentMCPContentPreview {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], let messages = value["messages"] as? [[String: Any]], !messages.isEmpty, messages.count <= 32 else { throw PetError("提示词未返回消息或超过 32 条") }
        let parts = try messages.map { message -> AgentMCPContentPart in
            guard let role = message["role"] as? String, ["user", "assistant"].contains(role), let block = message["content"] as? [String: Any], let type = block["type"] as? String else { throw PetError("提示词消息格式无效") }
            switch type {
            case "text", "image", "audio": return try content(block, role: role, resource: false, redact: redact)
            case "resource":
                guard let resource = block["resource"] as? [String: Any] else { throw PetError("提示词内嵌资源无效") }
                return try content(resource, role: role, resource: true, redact: redact)
            default: throw PetError("提示词返回了暂不支持的内容类型：" + type)
            }
        }
        let preview = AgentMCPContentPreview(server: server, owner: owner, connection: connection, catalog: catalog, kind: "prompts", name: name, parts: parts, digest: AgentFiles.hash(data))
        guard preview.promptText.utf8.count <= 64_000 else { throw PetError("提示词正文超过 64KB，请缩小参数范围") }
        return preview
    }
    static func fileType(_ mimeType: String) -> String {
        let mime = mimeType.lowercased().components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
        let types = ["text/markdown": "md", "application/json": "json", "text/csv": "csv", "image/png": "png", "image/jpeg": "jpg", "image/webp": "webp", "image/gif": "gif", "image/tiff": "tiff", "image/heic": "heic", "application/pdf": "pdf", "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx", "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx", "audio/wav": "wav", "audio/x-wav": "wav", "audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/ogg": "ogg", "audio/flac": "flac", "audio/aac": "aac", "application/gzip": "gz"]
        return types[mime] ?? (mime.hasPrefix("text/") || mime == "application/xml" ? "txt" : "bin")
    }
    static func toolMedia(_ value: [String: Any], server: AgentMCPServer, owner: String, connection: String, name: String, redact: (String) -> String) throws -> AgentMCPContentPreview? {
        var parts: [AgentMCPContentPart] = []
        for block in value["content"] as? [[String: Any]] ?? [] {
            if ["image", "audio"].contains(block["type"] as? String ?? "") { parts.append(try content(block, role: nil, resource: true, redact: redact)) }
            else if let resource = block["resource"] as? [String: Any], resource["blob"] != nil { parts.append(try content(resource, role: nil, resource: true, redact: redact)) }
        }
        guard !parts.isEmpty else { return nil }
        return .init(server: server, owner: owner, connection: connection, catalog: "", kind: "tool", name: name, parts: parts, digest: AgentFiles.hash(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])))
    }
    static func importParts(_ preview: AgentMCPContentPreview, store: AgentStore, taskID: String) async throws -> [AgentAttachment] {
        let parts = preview.kind == "prompts" ? preview.parts.filter { !$0.inline } : preview.parts
        guard parts.count <= 6 else { throw PetError("一次最多加入 6 份 MCP 内容，请选择集合中的具体资源") }
        var imported: [AgentAttachment] = []
        do {
            for (index, part) in parts.enumerated() {
                try Task.checkCancellation()
                let type = fileType(part.mimeType), temporary = store.directory.appendingPathComponent(".mcp-import-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: temporary) }
                let clean = preview.name.replacingOccurrences(of: "[^\\p{L}\\p{N} _-]", with: "_", options: .regularExpression)
                let name = (AgentFiles.sensitive(clean) || clean.isEmpty ? "MCP 内容" : String(clean.prefix(70))) + (parts.count > 1 ? "-\(index + 1)" : "") + "." + type
                let file = temporary.appendingPathComponent(name)
                try part.data.write(to: file, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
                let origin = AgentMCPAttachmentSource(serverID: preview.server.id, serverName: preview.server.name, configuration: preview.server.revision, uri: part.uri ?? preview.uri ?? (preview.kind == "prompts" ? "prompt:" : "tool:") + preview.name, mimeType: part.mimeType, kind: preview.kind, created: preview.created)
                imported.append(try await AgentAttachments.importFile(file, store: store, taskID: taskID, draft: false, mcpSource: origin))
            }
            return imported
        } catch { for file in imported { try? AgentAttachments.removeDraft(store: store, taskID: taskID, id: file.id) }; throw error }
    }
}
