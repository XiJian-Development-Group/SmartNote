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
        let daysUntilExam = calendar.dateComponents([.day], from: today, to: examDate).day ?? 1
        
        let reviewTopics = topics.map { topic in
            ReviewTopic(name: topic, importance: .medium)
        }
        
        var dailyPlans: [DailyPlan] = []
        
        let daysToReview = min(daysUntilExam, 14)
        let tasksPerDay = max(1, topics.count / daysToReview)
        
        for dayOffset in 0..<daysToReview {
            guard let planDate = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
            
            let startIndex = dayOffset * tasksPerDay
            let endIndex = min(startIndex + tasksPerDay, topics.count)
            
            guard startIndex < topics.count else { break }
            
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
    
    func createCalendarEvents(for plan: ReviewPlan) async {
        let hasAccess = await requestAccess()
        guard hasAccess else { return }
        
        let calendar = Calendar.current
        
        for dailyPlan in plan.dailyPlans {
            for task in dailyPlan.tasks {
                let event = EKEvent(eventStore: eventStore)
                event.title = "📚 \(task.title)"
                event.notes = task.description
                event.startDate = dailyPlan.date
                event.endDate = calendar.date(byAdding: .minute, value: task.estimatedMinutes, to: dailyPlan.date)
                event.calendar = eventStore.defaultCalendarForNewEvents
                
                let alarm = EKAlarm(relativeOffset: -15 * 60)
                event.addAlarm(alarm)
                
                do {
                    try eventStore.save(event, span: .thisEvent)
                } catch {
                    print("Error saving event: \(error)")
                }
            }
        }
    }
    
    func createReminder(for task: ReviewTask, planDate: Date) async {
        let hasAccess = await requestAccess()
        guard hasAccess else { return }
        
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = "📝 \(task.title)"
        reminder.notes = task.description
        reminder.calendar = eventStore.defaultCalendarForNewReminders()
        reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: planDate)
        
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
