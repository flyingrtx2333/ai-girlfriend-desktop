import Foundation

struct AgentCodexPrompt {
    static let argumentFormat = "bluefatfish-argument-format"
    private static let placeholderPattern = try! NSRegularExpression(pattern: #"\$(?:\$|[A-Z][A-Z0-9_]*|[1-9])"#)

    private let text: NSString
    private let placeholders: [(range: NSRange, name: String)]
    private let names: [String]
    private let lastPosition: Int
    private let usesAllArguments: Bool

    init(_ body: String) {
        let text = body as NSString
        self.text = text
        placeholders = Self.placeholderPattern.matches(in: body, range: NSRange(location: 0, length: text.length)).map {
            ($0.range, String(text.substring(with: $0.range).dropFirst()))
        }
        var seen = Set<String>()
        names = placeholders.map(\.name).filter { name in
            name != "$" && name != "ARGUMENTS" && Int(name) == nil && seen.insert(name).inserted
        }
        lastPosition = placeholders.compactMap { Int($0.name) }.max() ?? 0
        usesAllArguments = placeholders.contains { $0.name == "ARGUMENTS" }
    }

    var hasPlaceholders: Bool { !placeholders.isEmpty }

    var argumentHint: String? {
        if !names.isEmpty { return names.map { $0 + "=<值>" }.joined(separator: " ") }
        if usesAllArguments { return "[参数…]" }
        if lastPosition > 0 { return (1...lastPosition).map { "[参数\($0)]" }.joined(separator: " ") }
        return nil
    }

    static func markCommand(_ source: String) -> String {
        let newline = source.first(where: \.isNewline) == "\r\n" ? "\r\n" : "\n"
        let delimiter = "---" + newline, marker = argumentFormat + ": codex" + newline
        if source.hasPrefix(delimiter) {
            return delimiter + marker + source.dropFirst(delimiter.count)
        }
        return delimiter + marker + delimiter + source
    }

    func expand(_ input: String) throws -> String {
        let arguments = !names.isEmpty || lastPosition > 0 || usesAllArguments ? try Self.words(input) : []
        var named: [Substring: Substring] = [:]
        if !names.isEmpty {
            for token in arguments {
                guard let separator = token.firstIndex(of: "="), separator != token.startIndex else {
                    throw PetError("命名参数请按 KEY=值填写，含空格的值请加引号")
                }
                named[token[..<separator]] = token[token.index(after: separator)...]
            }
            let missing = names.filter { named[Substring($0)] == nil }
            guard missing.isEmpty else { throw PetError("缺少参数 " + missing.joined(separator: "、") + "。请按 KEY=值填写") }
        }

        let all = usesAllArguments && names.isEmpty ? arguments.joined(separator: " ") : ""
        var output = "", byteCount = 0, cursor = 0
        func append(_ piece: String) throws {
            byteCount += piece.utf8.count
            guard byteCount <= 100_000 else { throw PetError("展开后的提示词超过 100 KB，请缩短参数") }
            output += piece
        }
        for (range, name) in placeholders {
            try append(text.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            if name == "$" { try append("$") }
            else if !names.isEmpty { try append(named[Substring(name)].map { String($0) } ?? "$" + name) }
            else if name == "ARGUMENTS" { try append(all) }
            else if let position = Int(name), position <= arguments.count { try append(arguments[position - 1]) }
            cursor = NSMaxRange(range)
        }
        try append(text.substring(from: cursor))
        return output
    }

    // Recognize quoting and escaping while keeping argument values as text.
    private static func words(_ input: String) throws -> [String] {
        var result: [String] = [], token = "", quote: Character?, started = false
        var index = input.startIndex
        while index < input.endIndex {
            let character = input[index]
            index = input.index(after: index)
            if character == quote {
                quote = nil
            } else if quote == nil && (character == "\"" || character == "'") {
                quote = character
                started = true
            } else if character == "\\" && quote != "'" {
                guard index < input.endIndex else { throw PetError("参数末尾的反斜线需要转义字符") }
                let next = input[index]
                if quote == nil || next.isNewline || ["\\", "\"", "$", "`"].contains(next) {
                    index = input.index(after: index)
                    if !next.isNewline { token.append(next); started = true }
                } else { token.append(character) }
            } else if quote == nil && character.isWhitespace {
                if started { result.append(token); token = ""; started = false }
            } else {
                token.append(character)
                started = true
            }
        }
        guard quote == nil else { throw PetError("参数的引号未闭合") }
        if started { result.append(token) }
        return result
    }
}
