import Foundation

enum AgentAutomationRecurrence {
    static let weekdayNames = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
    private static let ruleKeys: Set<String> = ["FREQ", "INTERVAL", "BYHOUR", "BYMINUTE", "BYSECOND", "BYDAY", "BYMONTHDAY", "BYMONTH", "BYSETPOS", "COUNT", "WKST"]

    static func monthly(_ rule: String, start: Date, zone: TimeZone) throws -> AgentAutomationMonthly {
        try AgentAutomationMonthly(fields: fields(rule, allowed: ruleKeys), start: start, zone: zone)
    }

    static func unboundedMonthlyStart(in zone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: 1, month: 1, day: 1))
    }

    private static func fields(_ rule: String, allowed: Set<String>) throws -> [String: String] {
        guard rule.utf8.count <= 2000 else { throw PetError("时间规则过长") }
        let body = rule.hasPrefix("RRULE:") ? String(rule.dropFirst(6)) : rule
        var fields: [String: String] = [:]
        for item in body.split(separator: ";", omittingEmptySubsequences: false) {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, allowed.contains(String(pair[0])), !pair[1].isEmpty else { throw PetError("时间规则含暂不支持的条件") }
            guard fields.updateValue(String(pair[1]), forKey: String(pair[0])) == nil else { throw PetError("时间规则含重复条件") }
        }
        guard fields["WKST"].map(weekdayNames.contains) != false else { throw PetError("时间规则的周起点无效") }
        return fields
    }

    static func codex(_ text: String, created: Date?, zone suppliedZone: String?) throws -> AgentAutomationSchedule {
        guard text.utf8.count <= 2000 else { throw PetError("Codex 时间规则过长") }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var rule: String?, startText: String?, startZone: String?
        for line in lines {
            if line.hasPrefix("DTSTART"), let colon = line.firstIndex(of: ":") {
                guard startText == nil else { throw PetError("Codex 开始时间重复") }
                let header = line[..<colon]
                if header.hasPrefix("DTSTART;TZID=") { startZone = String(header.dropFirst("DTSTART;TZID=".count)) }
                else if header != "DTSTART" { throw PetError("Codex 开始时间格式暂不支持") }
                startText = String(line[line.index(after: colon)...])
            } else {
                guard rule == nil else { throw PetError("每项计划需要一条 Codex 时间规则") }
                rule = line.hasPrefix("RRULE:") ? String(line.dropFirst(6)) : line
            }
        }
        guard let rule, !rule.isEmpty else { throw PetError("缺少 Codex 时间规则") }
        let zoneID = startZone ?? (startText?.hasSuffix("Z") == true ? "UTC" : suppliedZone ?? TimeZone.current.identifier)
        guard let zone = TimeZone(identifier: zoneID) else { throw PetError("Codex 计划时区无效") }
        var fields = try fields(rule, allowed: ruleKeys.union(["UNTIL"]))
        guard let frequency = fields["FREQ"], ["DAILY", "WEEKLY", "MONTHLY", "YEARLY", "HOURLY", "MINUTELY"].contains(frequency) else {
            throw PetError("Codex 计划频率暂不支持")
        }
        let isMonthly = frequency == "MONTHLY"
        let start = try startText.map { try date($0, zone: zone, firstRepeatedTime: isMonthly) }
        let anchor = start ?? created
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        guard let interval = Int(fields["INTERVAL"] ?? "1"), (1...525_600).contains(interval) else { throw PetError("Codex 计划周期无效") }
        var result = AgentAutomationSchedule()
        result.date = anchor ?? .distantPast
        result.timeZone = zoneID
        result.expiration = try fields["UNTIL"].map { try date($0, zone: zone, firstRepeatedTime: isMonthly) }
        if isMonthly {
            if anchor == nil, let earliest = unboundedMonthlyStart(in: zone) { result.date = earliest }
            if start == nil {
                guard interval == 1, fields["COUNT"] == nil, fields["BYMONTHDAY"] != nil || fields["BYDAY"] != nil,
                      fields["BYHOUR"] != nil, fields["BYMINUTE"] != nil else {
                    throw PetError("此 Codex 月度计划缺少明确的开始时间")
                }
            }
            if let start, fields["BYSECOND"] == nil, calendar.component(.second, from: start) != 0 {
                throw PetError("此 Codex 月度计划包含秒级时间")
            }
            guard result.expiration == nil || fields["COUNT"] == nil else { throw PetError("Codex 计划不能同时限制次数和到期") }
            fields.removeValue(forKey: "UNTIL")
            _ = try AgentAutomationMonthly(fields: fields, start: result.date, zone: zone)
            result.frequency = .monthly
            let selectors = fields.filter { $0.key != "FREQ" }.sorted { $0.key < $1.key }
            result.monthlyRule = (["FREQ=MONTHLY"] + selectors.map { "\($0.key)=\($0.value)" }).joined(separator: ";")
            return result
        }
        guard fields["BYSETPOS"] == nil else { throw PetError("频率需要为每月才支持月内序号") }
        let countOne = fields["COUNT"] == "1"
        guard fields["COUNT"] == nil || countOne && fields["UNTIL"] == nil && start != nil else {
            throw PetError("此 Codex 次数限制需要原始开始时间或运行记录")
        }
        let selectors = fields.keys.contains { $0.hasPrefix("BY") }
        if ["HOURLY", "MINUTELY"].contains(frequency), !selectors, let start, zone.identifier == "GMT" || zone.identifier == "UTC" {
            result.frequency = .interval
            result.intervalMinutes = interval * (frequency == "HOURLY" ? 60 : 1)
            guard result.intervalMinutes <= 525_600 else { throw PetError("Codex 间隔超过一年") }
            result.date = start
        } else {
            let defaultSecond = start.map { calendar.component(.second, from: $0) } ?? 0
            guard interval == 1, fields["BYSECOND"].map({ $0 == "0" }) ?? (defaultSecond == 0) else {
                throw PetError("此 Codex 间隔或秒级时间暂不能准确迁移")
            }
            let time = start.map { calendar.dateComponents([.hour, .minute, .weekday, .day, .month], from: $0) }
            let hours = try list(fields["BYHOUR"], bounds: 0...23)
            let minutes = try list(fields["BYMINUTE"], bounds: 0...59)
            var monthDays = try list(fields["BYMONTHDAY"], bounds: 1...31)
            let hasDaySelector = monthDays != nil || fields["BYDAY"] != nil
            var months = try list(fields["BYMONTH"], bounds: 1...12)
            var weekdays: [Int]?
            if let value = fields["BYDAY"] {
                let labels = value.components(separatedBy: ",")
                let indexes = labels.compactMap { weekdayNames.firstIndex(of: $0) }
                guard indexes.count == labels.count else { throw PetError("Codex 的序号星期规则暂不能准确迁移") }
                weekdays = Array(Set(indexes)).sorted()
            }
            if frequency == "WEEKLY", weekdays == nil {
                guard let day = time?.weekday else { throw PetError("每周计划缺少星期或开始时间") }
                weekdays = [day - 1]
            }
            if frequency == "YEARLY", monthDays == nil, weekdays == nil {
                guard let day = time?.day else { throw PetError("计划缺少月日或开始时间") }
                monthDays = [day]
            }
            if frequency == "YEARLY", months == nil, !hasDaySelector {
                guard let month = time?.month else { throw PetError("每年计划缺少月份或开始时间") }
                months = [month]
            }
            guard monthDays == nil || weekdays == nil else { throw PetError("同时限制月日和星期的 Codex 计划暂不能准确迁移") }
            let hour = hours.map(field) ?? (["HOURLY", "MINUTELY"].contains(frequency) ? "*" : time?.hour.map(String.init))
            let minute = minutes.map(field) ?? (frequency == "MINUTELY" ? "*" : time?.minute.map(String.init))
            guard let hour, let minute else { throw PetError("Codex 计划缺少明确的运行时间") }
            result.frequency = .cron
            result.cronExpression = [minute, hour, monthDays.map(field) ?? "*", months.map(field) ?? "*", weekdays.map(field) ?? "*"].joined(separator: " ")
            result.cronRepeatLocalTimes = false
        }
        if countOne, let anchor {
            let justBefore = Date(timeIntervalSinceReferenceDate: anchor.timeIntervalSinceReferenceDate.nextDown)
            guard result.next(after: justBefore) == anchor else { throw PetError("一次性 Codex 计划与开始时间不一致") }
            result.frequency = .once; result.date = anchor; result.cronExpression = nil; result.cronRepeatLocalTimes = nil; result.expiration = nil
        }
        return result
    }

    private static func list(_ text: String?, bounds: ClosedRange<Int>) throws -> [Int]? {
        guard let text else { return nil }
        let values = text.components(separatedBy: ",")
        let parsed = values.compactMap { Int($0) }.filter(bounds.contains)
        guard parsed.count == values.count else { throw PetError("Codex 时间条件包含无效数字") }
        return Array(Set(parsed)).sorted()
    }

    private static func field(_ values: [Int]) -> String { values.map(String.init).joined(separator: ",") }

    private static func date(_ text: String, zone: TimeZone, firstRepeatedTime: Bool = false) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.isLenient = false
        formatter.timeZone = text.hasSuffix("Z") ? TimeZone(secondsFromGMT: 0) : zone
        formatter.dateFormat = text.hasSuffix("Z") ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd'T'HHmmss"
        guard let result = formatter.date(from: text), formatter.string(from: result) == text else { throw PetError("Codex 时间或到期日期格式无效") }
        if firstRepeatedTime, !text.hasSuffix("Z") {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            let clock = calendar.dateComponents([.hour, .minute, .second], from: result)
            if let hour = clock.hour, let minute = clock.minute, let second = clock.second,
               let first = calendar.date(bySettingHour: hour, minute: minute, second: second, of: result,
                                         matchingPolicy: .strict, repeatedTimePolicy: .first),
               first < result, formatter.string(from: first) == text { return first }
        }
        return result
    }
}
