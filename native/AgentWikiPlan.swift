import Foundation
import JavaScriptCore

struct AgentWikiDocument: Codable, Equatable {
    var title: String, goal: String
    var parent: String?
    var hints: [String] = []
    var template: String?
    init(title: String, goal: String, parent: String? = nil, hints: [String] = [], template: String? = nil) { self.title = title; self.goal = goal; self.parent = parent; self.hints = hints; self.template = template }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title); goal = try c.decode(String.self, forKey: .goal); parent = try c.decodeIfPresent(String.self, forKey: .parent); template = try c.decodeIfPresent(String.self, forKey: .template)
        if let text = try? c.decode(String.self, forKey: .hints) { hints = [text] } else { hints = try c.decodeIfPresent([String].self, forKey: .hints) ?? [] }
    }
}
struct AgentWikiPlan: Codable, Equatable {
    var template = "architecture", notes: [String] = [], documents: [AgentWikiDocument]?
    static let initialYAML = "version: 1\nrepowiki:\n  template: architecture\n  notes: []\n"
    static let configurationPath = ".bluefatfish/repowiki/wiki_plan.yaml"
    static let compatiblePath = ".qoder/repowiki/wiki_plan.yaml"
    private struct YAMLFile: Decodable {
        struct Note: Decodable {
            let text: String
            enum Keys: String, CodingKey { case text }
            init(from decoder: Decoder) throws {
                if let value = try? decoder.singleValueContainer().decode(String.self) { text = value }
                else { text = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .text) }
            }
        }
        struct Body: Decodable { let template: String?; let notes: [Note]?; let documents: [AgentWikiDocument]? }
        let version: Int, repowiki: Body
    }
    func validated() throws -> Self {
        guard ["architecture", "product_requirement"].contains(template), notes.count <= 30, notes.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 4000 }) else { throw PetError("规划模板或写作说明无效") }
        if let documents {
            guard !documents.isEmpty, documents.count <= 100, Set(documents.map(\.title)).count == documents.count else { throw PetError("规划需要1至100页，页面标题不能重复") }
            let titles = Set(documents.map(\.title))
            for doc in documents {
                guard AgentKnowledgeCards.validTitle(doc.title), !doc.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, doc.goal.utf8.count <= 4000, !doc.goal.contains("\0"), doc.hints.count <= 20, doc.hints.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 2000 }), (doc.template?.utf8.count ?? 0) <= 8000, doc.template?.contains("\0") != true, doc.parent == nil || titles.contains(doc.parent!) else { throw PetError("页面标题、目标、父页面或写作提示无效：" + doc.title) }
                var seen = Set<String>(), current: String? = doc.title
                while let title = current {
                    guard seen.insert(title).inserted else { throw PetError("规划中的父页面形成循环：" + doc.title) }
                    current = documents.first { $0.title == title }?.parent
                }
            }
            guard documents.first?.parent == nil else { throw PetError("规划第一页必须是根页面") }
        }
        return self
    }
    @MainActor static func parse(_ source: String) throws -> Self {
        guard source.utf8.count <= 64_000, !source.contains("\0"), let context = JSContext(),
              let url = Bundle.main.url(forResource: "runtime", withExtension: "js", subdirectory: "web/wiki") else { throw PetError("Wiki 规划解析器不可用，或文件超过64KB") }
        var problem: String?
        context.exceptionHandler = { _, error in problem = error?.toString() }
        context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
        let value = context.objectForKeyedSubscript("BlueFatFishWikiYAML")?.objectForKeyedSubscript("decode")?.call(withArguments: [source])?.toString()
        guard problem == nil, let value, let data = value.data(using: .utf8), data.count <= 256_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let decoded = try? JSONDecoder().decode(YAMLFile.self, from: data), decoded.version == 1,
              let config = object["repowiki"] as? [String: Any] else { throw PetError(problem.map { "规划格式错误：" + String($0.prefix(300)) } ?? "规划需要 version: 1 和 repowiki 配置") }
        guard Set(object.keys).isSubset(of: ["version", "repowiki", "knowledgecard"]), Set(config.keys).isSubset(of: ["template", "notes", "documents"]) else { throw PetError("规划包含无法识别的字段") }
        return try AgentWikiPlan(template: decoded.repowiki.template ?? "architecture", notes: decoded.repowiki.notes?.map(\.text) ?? [], documents: decoded.repowiki.documents).validated()
    }
    struct Snapshot {
        let plan: AgentWikiPlan, text: String, path: String?, hash: String?, targetSignature: String, format: AgentTextFormat
        var problem: String? = nil
    }
    @MainActor static func load(files: AgentFiles, validate: Bool = true) throws -> Snapshot {
        let target = try files.literalURL(configurationPath), signature = try files.entryMetadata(target).signature
        for path in [configurationPath, compatiblePath] {
            let file = try files.literalURL(path), meta = try files.entryMetadata(file)
            if meta.kind == "missing" { continue }
            guard meta.kind == "file" else { throw PetError("Wiki 规划不是普通文件") }
            let data = try files.readData(file, maximum: 128_000), decoded = try AgentTextFile.decode(data)
            do { return Snapshot(plan: try parse(decoded.text), text: decoded.text, path: path, hash: AgentFiles.hash(data), targetSignature: signature, format: decoded.format) }
            catch { if validate { throw error }; return Snapshot(plan: AgentWikiPlan(), text: decoded.text, path: path, hash: AgentFiles.hash(data), targetSignature: signature, format: decoded.format, problem: error.localizedDescription) }
        }
        return Snapshot(plan: AgentWikiPlan(), text: initialYAML, path: nil, hash: nil, targetSignature: signature, format: AgentTextFormat())
    }
    func paths(root: String) throws -> [String: String] {
        _ = try validated(); guard let documents else { throw PetError("请先制定 Wiki 页面规划") }
        var result: [String: String] = [:]
        for (index, doc) in documents.enumerated() {
            let slug = doc.title.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined().split(separator: "-").joined(separator: "-")
            result[doc.title] = root + "/" + (index == 0 ? "index" : String(slug.prefix(48)) + "-" + String(AgentFiles.hash(Data(doc.title.utf8)).prefix(8))) + ".md"
        }
        guard Set(result.values).count == documents.count else { throw PetError("页面路径重复，请调整标题") }; return result
    }
}
struct AgentWikiJob: Codable {
    var language: String, branch: String, root: String, configurationHash: String?
    var plan: AgentWikiPlan
    var previousRoot: String?
    var reviewed: [String: String]?
    var pageReads: [String: AgentKnowledgeCardRead]?
    var baseTaskID: String?
    var update: AgentWikiUpdateJob?
}
