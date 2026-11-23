import Foundation

struct AgentDelimitedText: Sendable {
    static let rowLimit = 20_000
    static let columnLimit = 100

    let rows: [[String]]
    let rowCount: Int
    let columnCount: Int

    static func supports(_ type: String) -> Bool { type == "csv" || type == "tsv" }

    static func parse(_ text: String, type: String) throws -> Self {
        enum Field { case start, plain, quoted, closingQuote }
        let separator: UInt8 = type == "tsv" ? 9 : 44
        let bytes = Array(text.utf8)
        var rows: [[String]] = [], row: [String] = [], field: [UInt8] = []
        var state: Field = .start
        var rowCount = 0, columnCount = 0, columns = 0, index = 0

        func append(_ byte: UInt8) {
            if rowCount < rowLimit && columns < columnLimit { field.append(byte) }
        }
        func finishField() {
            if rowCount < rowLimit && columns < columnLimit {
                row.append(String(decoding: field, as: UTF8.self))
            }
            field.removeAll(keepingCapacity: true)
            columns += 1
            state = .start
        }
        func finishRow() {
            finishField()
            if rowCount < rowLimit { rows.append(row) }
            row = []
            rowCount += 1
            columnCount = max(columnCount, columns)
            columns = 0
        }

        while index < bytes.count {
            if index % 65_536 == 0 { try Task.checkCancellation() }
            let byte = bytes[index]
            index += 1
            if byte == 34 {
                switch state {
                case .start: state = .quoted
                case .quoted: state = .closingQuote
                case .closingQuote: append(byte); state = .quoted
                case .plain: throw PetError("第 \(rowCount + 1) 行有未转义的引号")
                }
            } else if state == .quoted {
                append(byte)
            } else if byte == separator {
                finishField()
            } else if byte == 10 || byte == 13 {
                finishRow()
                if byte == 13 && index < bytes.count && bytes[index] == 10 { index += 1 }
            } else if state == .closingQuote {
                throw PetError("第 \(rowCount + 1) 行的引号后需要分隔符")
            } else {
                append(byte)
                state = .plain
            }
        }
        guard state != .quoted else { throw PetError("第 \(rowCount + 1) 行的引号未闭合") }
        if columns > 0 || state != .start { finishRow() }
        return Self(rows: rows, rowCount: rowCount, columnCount: columnCount)
    }
}
