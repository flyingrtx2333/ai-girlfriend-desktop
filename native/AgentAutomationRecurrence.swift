import Foundation

enum AgentAutomationRecurrence {
    private static let days = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

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
        let start = try startText.map { try date($0, zone: zone) }
        let anchor = start ?? created
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        var fields: [String: String] = [:]
        let allowed: Set<String> = ["FREQ", "INTERVAL", "BYHOUR", "BYMINUTE", "BYSECOND", "BYDAY", "BYMONTHDAY", "BYMONTH", "COUNT", "UNTIL", "WKST"]
        for item in rule.split(separator: ";", omittingEmptySubsequences: false) {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, allowed.contains(String(pair[0])), !pair[1].isEmpty else { throw PetError("Codex 时间规则含暂不支持的条件") }
            guard fields.updateValue(String(pair[1]), forKey: String(pair[0])) == nil else { throw PetError("Codex 时间规则含重复条件") }
        }
        guard let frequency = fields["FREQ"], ["DAILY", "WEEKLY", "MONTHLY", "YEARLY", "HOURLY", "MINUTELY"].contains(frequency) else {
            throw PetError("Codex 计划频率暂不支持")
        }
        guard let interval = Int(fields["INTERVAL"] ?? "1"), (1...525_600).contains(interval),
              fields["WKST"].map(days.contains) != false else { throw PetError("Codex 计划周期或周起点无效") }
        let countOne = fields["COUNT"] == "1"
        guard fields["COUNT"] == nil || countOne && fields["UNTIL"] == nil && start != nil else {
            throw PetError("此 Codex 次数限制需要原始开始时间或运行记录")
        }
        var result = AgentAutomationSchedule()
        result.date = anchor ?? .distantPast
        result.timeZone = zoneID
        result.expiration = try fields["UNTIL"].map { try date($0, zone: zone) }
        let selectors = fields.keys.contains { $0.hasPrefix("BY") }
        if ["HOURLY", "MINUTELY"].contains(frequency), !selectors, let start {
            result.frequency = .interval
            result.intervalMinutes = interval * (frequency == "HOURLY" ? 60 : 1)
            guard result.intervalMinutes <= 525_600 else { throw PetError("Codex 间隔超过一年") }
            result.date = start
        } else {
            let defaultSecond = start.map { calendar.component(.second, from: $0) } ?? 0
            guard interval == 1, fields["BYSECOND"].map({ $0 == "0" }) ?? (defaultSecond == 0) else {
                throw PetError("此 Codex 间隔或秒级时间暂不能准确迁移")
            }
            let time = anchor.map { calendar.dateComponents([.hour, .minute, .weekday, .day, .month], from: $0) }
            let hours = try list(fields["BYHOUR"], bounds: 0...23)
            let minutes = try list(fields["BYMINUTE"], bounds: 0...59)
            var monthDays = try list(fields["BYMONTHDAY"], bounds: 1...31)
            let hasDaySelector = monthDays != nil || fields["BYDAY"] != nil
            var months = try list(fields["BYMONTH"], bounds: 1...12)
            var weekdays: [Int]?
            if let value = fields["BYDAY"] {
                let labels = value.components(separatedBy: ",")
                let indexes = labels.compactMap { days.firstIndex(of: $0) }
                guard indexes.count == labels.count else { throw PetError("Codex 的序号星期规则暂不能准确迁移") }
                weekdays = Array(Set(indexes)).sorted()
            }
            if frequency == "WEEKLY", weekdays == nil {
                guard let day = time?.weekday else { throw PetError("每周计划缺少星期或开始时间") }
                weekdays = [day - 1]
            }
            if ["MONTHLY", "YEARLY"].contains(frequency), monthDays == nil, weekdays == nil {
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
        }
        if countOne, let anchor {
            let justBefore = Date(timeIntervalSinceReferenceDate: anchor.timeIntervalSinceReferenceDate.nextDown)
            guard let first = result.next(after: justBefore) else { throw PetError("一次性 Codex 计划没有有效时间") }
            result.frequency = .once; result.date = first; result.cronExpression = nil; result.expiration = nil
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

    private static func date(_ text: String, zone: TimeZone) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.isLenient = false
        formatter.timeZone = text.hasSuffix("Z") ? TimeZone(secondsFromGMT: 0) : zone
        formatter.dateFormat = text.hasSuffix("Z") ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd'T'HHmmss"
        guard let result = formatter.date(from: text), formatter.string(from: result) == text else { throw PetError("Codex 时间或到期日期格式无效") }
        return result
    }
}
