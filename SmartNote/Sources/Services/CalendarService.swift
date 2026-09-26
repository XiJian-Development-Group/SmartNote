import Foundation
import EventKit

class CalendarService {
    private let eventStore = EKEventStore()
    
    func requestAccess() async -> Bool {
        do {
            if #available(macOS 14.0, *) {
                return try await eventStore.requestFullAccessToEvents()
            } else {
                return try await eventStore.requestAccess(to: .event)
            }
        } catch {
            print("Calendar access error: \(error)")
            return false
        }
    }
    
    func generateReviewPlan(examDate: Date, subject: String, topics: [String]) -> ReviewPlan {
        let calendar = Calendar.current
        let today = Date()
        let daysUntilExam = max(1, calendar.dateComponents([.day], from: today, to: examDate).day ?? 1)
        
        let reviewTopics = topics.map { topic in
            ReviewTopic(name: topic, importance: .medium)
        }
        
        // 没有主题时不生成下标切片，也不产生无意义的每日计划。
        guard !topics.isEmpty else {
            return ReviewPlan(
                subject: subject,
                examDate: examDate,
                topics: reviewTopics,
                dailyPlans: []
            )
        }

        var dailyPlans: [DailyPlan] = []
        
        let daysToReview = max(1, min(daysUntilExam, 14))
        let tasksPerDay = max(1, topics.count / daysToReview)
        
        for dayOffset in 0..<daysToReview {
            guard let planDate = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
            
            let (startIndex, indexOverflow) = dayOffset.multipliedReportingOverflow(by: tasksPerDay)
            guard !indexOverflow, startIndex >= 0, startIndex < topics.count else { break }
            
            let remainingCount = topics.count - startIndex
            let (candidateEndIndex, endOverflow) = startIndex.addingReportingOverflow(
                min(tasksPerDay, remainingCount)
            )
            guard !endOverflow else { break }
            let endIndex = min(candidateEndIndex, topics.count)
            guard endIndex > startIndex, endIndex <= topics.count else { break }
            
            let dayTopics = Array(topics[startIndex..<endIndex])
            
            let tasks = dayTopics.map { topic in
                ReviewTask(
                    title: "复习: \(topic)",
                    description: "复习 \(subject) 中的 \(topic) 知识点",
                    estimatedMinutes: 30 + Int.random(in: 0...30)
                )
            }
            
            let dailyPlan = DailyPlan(date: planDate, tasks: tasks)
            dailyPlans.append(dailyPlan)
        }
        
        return ReviewPlan(
            subject: subject,
            examDate: examDate,
            topics: reviewTopics,
            dailyPlans: dailyPlans
        )
    }
    
    /// 复习计划在日历里的默认开始时刻。
    /// `dailyPlan.date` 是由年月日拼出的当天零点，直接拿去建事件会被 EventKit
    /// 判定为「全天事件」，与 estimatedMinutes 无关，闹钟也只按天触发。
    static let defaultPlanHour: Int = 19
    static let defaultPlanMinute: Int = 0

    func createCalendarEvents(for plan: ReviewPlan) async {
        let hasAccess = await requestAccess()
        guard hasAccess else { return }

        let calendar = Calendar.current

        for dailyPlan in plan.dailyPlans {
            // 同一日的多个任务顺延排布，避免全部堆在同一时刻互相覆盖。
            var offsetMinutes = 0
            for task in dailyPlan.tasks {
                guard let start = Self.planDateTime(
                    for: dailyPlan.date,
                    offsetMinutes: offsetMinutes,
                    calendar: calendar
                ) else { continue }

                let event = EKEvent(eventStore: eventStore)
                event.title = "📚 \(task.title)"
                event.notes = task.description
                event.startDate = start
                event.endDate = calendar.date(
                    byAdding: .minute, value: max(1, task.estimatedMinutes), to: start
                )
                event.isAllDay = false
                event.calendar = eventStore.defaultCalendarForNewEvents

                let alarm = EKAlarm(relativeOffset: -15 * 60)
                event.addAlarm(alarm)

                do {
                    try eventStore.save(event, span: .thisEvent)
                    offsetMinutes += max(1, task.estimatedMinutes) + 10
                } catch {
                    print("Error saving event: \(error)")
                }
            }
        }
    }

    /// 把「当天零点 + 顺延分钟数」换算成带具体时刻的日期。
    static func planDateTime(
        for day: Date,
        offsetMinutes: Int,
        calendar: Calendar,
        hour: Int = defaultPlanHour,
        minute: Int = defaultPlanMinute
    ) -> Date? {
        let startOfDay = calendar.startOfDay(for: day)
        return calendar.date(
            bySettingHour: hour, minute: minute, second: 0, of: startOfDay
        )?.addingTimeInterval(TimeInterval(offsetMinutes * 60))
    }
    
    func createReminder(for task: ReviewTask, planDate: Date) async {
        let hasAccess = await requestAccess()
        guard hasAccess else { return }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = "📝 \(task.title)"
        reminder.notes = task.description
        reminder.calendar = eventStore.defaultCalendarForNewReminders()
        // 与日历事件保持同一时刻：当天 19:00 到期，而不是零点的「全天」提醒。
        reminder.dueDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: Self.planDateTime(for: planDate, offsetMinutes: 0, calendar: .current)
                ?? planDate
        )
        
        do {
            try eventStore.save(reminder, commit: true)
        } catch {
            print("Error saving reminder: \(error)")
        }
    }
    
    func getUpcomingEvents(days: Int = 7) async -> [EKEvent] {
        let hasAccess = await requestAccess()
        guard hasAccess else { return [] }
        
        let calendar = Calendar.current
        let now = Date()
        let endDate = calendar.date(byAdding: .day, value: days, to: now) ?? now
        
        let predicate = eventStore.predicateForEvents(
            withStart: now,
            end: endDate,
            calendars: nil
        )
        
        return eventStore.events(matching: predicate)
            .filter { $0.title?.contains("📚") == true }
            .sorted { $0.startDate < $1.startDate }
    }
}
