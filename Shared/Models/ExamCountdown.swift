import Foundation

struct ExamCountdown: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var examDate: Date
    var subject: String
    var notes: String
    var isArchived: Bool
    
    init(id: UUID = UUID(), name: String, examDate: Date, subject: String, notes: String = "", isArchived: Bool = false) {
        self.id = id
        self.name = name
        self.examDate = examDate
        self.subject = subject
        self.notes = notes
        self.isArchived = isArchived
    }
    
    var daysRemaining: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let exam = calendar.startOfDay(for: examDate)
        return calendar.dateComponents([.day], from: today, to: exam).day ?? 0
    }
    
    var hoursRemaining: Int {
        let now = Date()
        let components = Calendar.current.dateComponents([.hour], from: now, to: examDate)
        return components.hour ?? 0
    }
    
    var isExpired: Bool {
        return examDate < Date()
    }
    
    var isUrgent: Bool {
        return daysRemaining <= 7 && daysRemaining >= 0
    }
}
