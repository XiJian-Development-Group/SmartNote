import Foundation

/// 倒数纪念日
struct Anniversary: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    /// 公历原始日期（不含时间）；按 recurrenceType 重复
    var date: Date
    var recurrence: RecurrenceType
    /// 提前提醒天数（0/1/3/7/14/30）
    var leadTimeDays: Int
    var accentColor: AccentColor
    var note: String
    var createdAt: Date
    var lastNotifiedYearMonthDayKey: String?   // dedup 通知用（避免同日重复推）

    enum RecurrenceType: String, Codable, CaseIterable {
        case once        // 仅一次（具体到年月日）
        case yearly      // 每年同一天
        case monthly     // 每月同一天
    }

    enum AccentColor: String, Codable, CaseIterable {
        case rose, blue, mint, amber, violet, gray
    }

    init(
        id: UUID = UUID(),
        name: String,
        date: Date,
        recurrence: RecurrenceType = .yearly,
        leadTimeDays: Int = 0,
        accentColor: AccentColor = .rose,
        note: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.date = date
        self.recurrence = recurrence
        self.leadTimeDays = max(0, leadTimeDays)
        self.accentColor = accentColor
        self.note = note
        self.createdAt = createdAt
    }

    /// 距离下一次发生还有多少天（负数 = 已过）
    func daysUntilNextOccurrence(reference: Date = Date(), calendar: Calendar = .current) -> Int {
        let target = nextOccurrence(after: reference, calendar: calendar)
        let comps = calendar.dateComponents([.day], from: calendar.startOfDay(for: reference), to: calendar.startOfDay(for: target))
        return comps.day ?? 0
    }

    /// 取下一个发生日期（>= reference）
    func nextOccurrence(after reference: Date, calendar: Calendar = .current) -> Date {
        switch recurrence {
        case .once:
            return date
        case .yearly:
            let ref = reference
            let refComps = calendar.dateComponents([.year, .month, .day], from: ref)
            let refYear = refComps.year ?? calendar.component(.year, from: ref)
            let baseComps = calendar.dateComponents([.month, .day], from: date)
            guard let month = baseComps.month, let day = baseComps.day else { return ref }
            var attemptComps = DateComponents(year: refYear, month: month, day: day)
            var attempt = calendar.date(from: attemptComps)
            var guardCount = 0
            while (attempt == nil || (attempt! < calendar.startOfDay(for: reference))) && guardCount < 8 {
                if attempt == nil { break }
                let y = attemptComps.year ?? refYear
                attemptComps = DateComponents(year: y + 1, month: month, day: day)
                attempt = calendar.date(from: attemptComps)
                guardCount += 1
            }
            return attempt ?? ref
        case .monthly:
            let ref = reference
            let refComps = calendar.dateComponents([.year, .month, .day], from: ref)
            let refYear = refComps.year ?? calendar.component(.year, from: ref)
            let refMonth = refComps.month ?? calendar.component(.month, from: ref)
            let baseDay = calendar.dateComponents([.day], from: date).day ?? 1
            var attemptComps = DateComponents(year: refYear, month: refMonth, day: baseDay)
            var attempt = calendar.date(from: attemptComps)
            var guardCount = 0
            while (attempt == nil || (attempt! < calendar.startOfDay(for: reference))) && guardCount < 60 {
                if attempt == nil { break }
                let y = attemptComps.year ?? refYear
                let m = attemptComps.month ?? refMonth
                var newY = y
                var newM = m + 1
                if newM > 12 { newM = 1; newY += 1 }
                attemptComps = DateComponents(year: newY, month: newM, day: baseDay)
                attempt = calendar.date(from: attemptComps)
                guardCount += 1
            }
            return attempt ?? ref
        }
    }

    /// 用于 dedup 通知的字符串 key
    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = calendar
        return f.string(from: date)
    }
}
