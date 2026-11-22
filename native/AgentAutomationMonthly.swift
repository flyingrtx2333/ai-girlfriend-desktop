import Foundation

struct AgentAutomationMonthly {
    private struct Weekday {
        let day: Int, ordinal: Int?
    }

    private let calendar: Calendar
    private let start: Date
    private let interval: Int
    private let limit: Int?
    private let months: [Int]?
    private let days: [Int]?
    private let weekdays: [Weekday]?
    private let positions: [Int]?
    private let hours: [Int], minutes: [Int]

    init(fields: [String: String], start: Date, zone: TimeZone) throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        self.calendar = calendar; self.start = start
        guard fields["FREQ"] == "MONTHLY",
              let interval = Int(fields["INTERVAL"] ?? "1"), (1...525_600).contains(interval),
              fields["BYSECOND"].map({ Int($0) == 0 }) != false else {
            throw PetError("月内规则需要 MONTHLY 频率、有效周期和整分钟时间")
        }
        self.interval = interval
        if let count = fields["COUNT"] {
            guard let value = Int(count), value > 0 else { throw PetError("月内规则的次数必须为正整数") }
            limit = value
        } else { limit = nil }
        months = try Self.list(fields["BYMONTH"], in: 1...12)
        days = try Self.list(fields["BYMONTHDAY"], in: -31...31, excludingZero: true)
        positions = try Self.list(fields["BYSETPOS"], in: -366...366, excludingZero: true)
        if positions != nil, !fields.keys.contains(where: { $0.hasPrefix("BY") && $0 != "BYSETPOS" }) {
            throw PetError("月内序号需要搭配日期、星期或时段条件")
        }
        if let labels = fields["BYDAY"] {
            let names = AgentAutomationRecurrence.weekdayNames
            weekdays = try labels.components(separatedBy: ",").map { label in
                guard let day = names.firstIndex(of: String(label.suffix(2))) else { throw PetError("月内规则的星期无效") }
                let prefix = label.dropLast(2)
                if prefix.isEmpty { return Weekday(day: day + 1, ordinal: nil) }
                guard let ordinal = Int(prefix), (-5...5).contains(ordinal), ordinal != 0 else { throw PetError("月内星期序号无效") }
                return Weekday(day: day + 1, ordinal: ordinal)
            }
        } else { weekdays = nil }
        hours = try Self.list(fields["BYHOUR"], in: 0...23) ?? [calendar.component(.hour, from: start)]
        minutes = try Self.list(fields["BYMINUTE"], in: 0...59) ?? [calendar.component(.minute, from: start)]
        guard let firstMonth = monthNumber(start) else { throw PetError("月内规则的开始日期无效") }
        if limit != nil, !occurrences(in: firstMonth).contains(start) { throw PetError("限制次数的计划需要从实际运行时刻开始") }
    }

    func next(after date: Date, through end: Date?) -> Date? {
        guard let anchor = monthNumber(start), let current = monthNumber(max(start, date)) else { return nil }
        let first = limit == nil ? anchor + (current - anchor) / interval * interval : anchor
        var remaining = limit
        var emptyMonths = 0, month = first
        while month < 120_000, emptyMonths < 4800 {
            let dates = occurrences(in: month)
            if let end, let startOfMonth = calendar.date(from: components(month: month, day: 1)), startOfMonth > end { return nil }
            emptyMonths = dates.isEmpty ? emptyMonths + 1 : 0
            for candidate in dates where candidate >= start {
                if let end, candidate > end { return nil }
                if remaining == 0 { return nil }
                if candidate > date { return candidate }
                if let value = remaining { remaining = value - 1 }
            }
            if remaining == 0 { return nil }
            month += interval
        }
        return nil
    }

    private func monthNumber(_ date: Date) -> Int? {
        let parts = calendar.dateComponents([.era, .year, .month], from: date)
        guard parts.era == 1, let year = parts.year, (1...9999).contains(year), let month = parts.month else { return nil }
        return year * 12 + month - 1
    }

    private func components(month: Int, day: Int) -> DateComponents {
        DateComponents(year: month / 12, month: month % 12 + 1, day: day)
    }

    private func occurrences(in month: Int) -> [Date] {
        guard months?.contains(month % 12 + 1) != false,
              let first = calendar.date(from: components(month: month, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: first) else { return [] }
        let last = range.upperBound - 1, defaultDay = calendar.component(.day, from: start)
        var result: [Date] = []
        for day in range {
            if let days, !days.contains(day), !days.contains(day - last - 1) { continue }
            if days == nil, weekdays == nil, day != defaultDay { continue }
            guard let base = calendar.date(from: components(month: month, day: day)), calendar.component(.day, from: base) == day,
                  let dayInterval = calendar.dateInterval(of: .day, for: base) else { continue }
            if let weekdays {
                let index = calendar.component(.weekday, from: base)
                let forward = (day - 1) / 7 + 1, backward = -((last - day) / 7 + 1)
                guard weekdays.contains(where: { $0.day == index && ($0.ordinal == nil || $0.ordinal == forward || $0.ordinal == backward) }) else { continue }
            }
            let ordinaryDay = dayInterval.duration == 86_400 && calendar.component(.hour, from: dayInterval.start) == 0
                && calendar.component(.minute, from: dayInterval.start) == 0 && calendar.component(.second, from: dayInterval.start) == 0
            for hour in hours {
                for minute in minutes {
                    let event = ordinaryDay ? dayInterval.start.addingTimeInterval(Double(hour * 3600 + minute * 60))
                        : calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base, matchingPolicy: .strict, repeatedTimePolicy: .first)
                    if let event, event < dayInterval.end, event >= dayInterval.start { result.append(event) }
                }
            }
        }
        guard let positions else { return result }
        let indexes = Set(positions.map { $0 > 0 ? $0 - 1 : result.count + $0 })
        return indexes.sorted().filter(result.indices.contains).map { result[$0] }
    }

    private static func list(_ text: String?, in range: ClosedRange<Int>, excludingZero: Bool = false) throws -> [Int]? {
        guard let text else { return nil }
        let values = text.components(separatedBy: ",")
        let parsed = values.compactMap { Int($0) }.filter { range.contains($0) && (!excludingZero || $0 != 0) }
        guard parsed.count == values.count else { throw PetError("月内规则包含无效数字") }
        return Array(Set(parsed)).sorted()
    }
}
