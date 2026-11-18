import Foundation

struct AgentCronSchedule {
    private let minutes: [Int], hours: [Int], days: Set<Int>, months: Set<Int>, weekdays: Set<Int>
    private let anyDay: Bool, anyWeekday: Bool

    init(_ expression: String) throws {
        guard expression.utf8.count <= 300 else { throw PetError("Cron 表达式过长") }
        let fields = expression.split(whereSeparator: \.isWhitespace)
        guard fields.count == 5 else { throw PetError("Cron 需要分钟、小时、日、月和星期五个字段") }
        minutes = try Self.field(fields[0], bounds: 0...59).sorted()
        hours = try Self.field(fields[1], bounds: 0...23).sorted()
        days = try Self.field(fields[2], bounds: 1...31)
        months = try Self.field(fields[3], bounds: 1...12)
        weekdays = try Set(Self.field(fields[4], bounds: 0...7).map { $0 % 7 + 1 })
        anyDay = fields[2] == "*"; anyWeekday = fields[4] == "*"
    }

    private static func field(_ value: Substring, bounds: ClosedRange<Int>) throws -> Set<Int> {
        let issue = PetError("Cron 字段格式无效或超出范围：\(value)")
        var matches = Set<Int>()
        for part in value.split(separator: ",", omittingEmptySubsequences: false) {
            let pieces = part.split(separator: "/", omittingEmptySubsequences: false)
            guard (1...2).contains(pieces.count) else { throw issue }
            let step: Int
            if pieces.count == 2 {
                guard let amount = number(pieces[1]), amount > 0 else { throw issue }
                step = amount
            } else { step = 1 }
            let range: ClosedRange<Int>
            if pieces[0] == "*" { range = bounds }
            else {
                let ends = pieces[0].split(separator: "-", omittingEmptySubsequences: false)
                guard (1...2).contains(ends.count), let start = number(ends[0]), bounds.contains(start) else { throw issue }
                let end: Int
                if ends.count == 2 {
                    guard let upper = number(ends[1]), bounds.contains(upper), upper >= start else { throw issue }
                    end = upper
                } else { end = pieces.count == 2 ? bounds.upperBound : start }
                range = start...end
            }
            // The field is at most 60 values, even if the supplied step is large.
            matches.formUnion(range.filter { ($0 - range.lowerBound).isMultiple(of: step) })
        }
        guard !matches.isEmpty else { throw issue }
        return matches
    }

    private static func number(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(text)
    }

    func next(after now: Date, calendar: Calendar, repeatLocalTimes: Bool = true) -> Date? {
        var day = calendar.startOfDay(for: now)
        // Eight years covers the maximum gap between leap days in Gregorian dates.
        for _ in 0..<2930 {
            guard let following = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            let nextDay = calendar.startOfDay(for: following)
            let parts = calendar.dateComponents([.month, .day, .weekday], from: day)
            if let month = parts.month, months.contains(month), let number = parts.day, let weekday = parts.weekday {
                let matchesDay = days.contains(number), matchesWeekday = weekdays.contains(weekday)
                if (anyDay || anyWeekday) ? matchesDay && matchesWeekday : matchesDay || matchesWeekday,
                   let match = firstTime(on: day, nextDay: nextDay, after: now, calendar: calendar, repeatLocalTimes: repeatLocalTimes) { return match }
            }
            day = nextDay
        }
        return nil
    }

    private func firstTime(on day: Date, nextDay: Date, after now: Date, calendar: Calendar, repeatLocalTimes: Bool) -> Date? {
        if nextDay.timeIntervalSince(day) == 86_400, calendar.component(.hour, from: day) == 0, calendar.component(.minute, from: day) == 0 {
            for hour in hours {
                for minute in minutes {
                    let value = day.addingTimeInterval(Double(hour * 3600 + minute * 60))
                    if value > now { return value }
                }
            }
            return nil
        }
        let policies: [Calendar.RepeatedTimePolicy] = repeatLocalTimes ? [.first, .last] : [.first]
        var best: Date?
        for hour in hours {
            for minute in minutes {
                for policy in policies {
                    guard let value = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day,
                                                    matchingPolicy: .strict, repeatedTimePolicy: policy),
                          value > now, calendar.isDate(value, inSameDayAs: day), best.map({ value < $0 }) ?? true else { continue }
                    best = value
                }
            }
        }
        return best
    }
}
