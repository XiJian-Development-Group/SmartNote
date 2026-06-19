import Foundation
import SwiftUI
import UserNotifications

class PomodoroTimer: ObservableObject {
    static let shared = PomodoroTimer()
    
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var remainingSeconds: Int = 0
    @Published var totalSeconds: Int = 25 * 60
    @Published var currentPhase: PomodoroPhase = .work
    @Published var sessionsCompleted: Int = 0
    
    @Published var workDuration: Int = 25
    @Published var shortBreakDuration: Int = 5
    @Published var longBreakDuration: Int = 15
    @Published var sessionsBeforeLongBreak: Int = 4
    
    @Published var isFocusModeEnabled = false
    
    // 关联的待办事项
    @Published var linkedTodoID: UUID? = nil
    @Published var linkedTodoTitle: String? = nil
    
    private var timer: Timer?
    private var studySession: StudySession?
    
    private init() {
        loadSettings()
    }
    
    enum PomodoroPhase {
        case work
        case shortBreak
        case longBreak
        
        var displayName: String {
            switch self {
            case .work: return "专注中"
            case .shortBreak: return "短休息"
            case .longBreak: return "长休息"
            }
        }
    }
    
    func start(subject: String? = nil) {
        guard !isRunning else { return }
        
        isRunning = true
        isPaused = false
        remainingSeconds = totalSeconds
        
        if currentPhase == .work {
            studySession = StudySession(
                id: UUID(),
                subject: subject ?? linkedTodoTitle ?? "通用",
                startTime: Date(),
                duration: 0,
                completed: false
            )
            
            if isFocusModeEnabled {
                enableFocusMode()
            }
        }
        
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        
        sendNotification(title: "开始\(currentPhase.displayName)", body: "保持专注！")
    }
    
    /// 启动番茄钟并关联指定待办
    func startForTodo(todoID: UUID, todoTitle: String) {
        linkedTodoID = todoID
        linkedTodoTitle = todoTitle
        start(subject: todoTitle)
    }
    
    /// 解除当前关联的待办
    func unlinkTodo() {
        linkedTodoID = nil
        linkedTodoTitle = nil
    }
    
    func pause() {
        guard isRunning && !isPaused else { return }
        isPaused = true
        timer?.invalidate()
    }
    
    func resume() {
        guard isRunning && isPaused else { return }
        isPaused = false
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        isPaused = false
        remainingSeconds = 0
        
        if isFocusModeEnabled {
            disableFocusMode()
        }
        
        // 不清空关联，保留以便用户查看上次关联
    }
    
    func reset() {
        stop()
        currentPhase = .work
        totalSeconds = workDuration * 60
        remainingSeconds = totalSeconds
    }
    
    func toggle() {
        if isRunning && !isPaused {
            pause()
        } else if isPaused {
            resume()
        } else {
            start()
        }
    }
    
    func setDurations(work: Int, shortBreak: Int, longBreak: Int) {
        workDuration = work
        shortBreakDuration = shortBreak
        longBreakDuration = longBreak
        saveSettings()
        
        if !isRunning {
            reset()
        }
    }
    
    private func tick() {
        guard remainingSeconds > 0 else {
            phaseComplete()
            return
        }
        
        remainingSeconds -= 1
        
        if currentPhase == .work {
            studySession?.duration += 1
        }
    }
    
    private func phaseComplete() {
        timer?.invalidate()
        
        if currentPhase == .work {
            sessionsCompleted += 1
            
            if let session = studySession {
                var completedSession = session
                completedSession.completed = true
                completedSession.duration = TimeInterval(remainingSeconds)
                StudyStatisticsService.shared.addSession(completedSession)
            }
            
            sendNotification(title: "专注完成！", body: "太棒了，现在休息一下吧")
            
            if sessionsCompleted % sessionsBeforeLongBreak == 0 {
                currentPhase = .longBreak
                totalSeconds = longBreakDuration * 60
            } else {
                currentPhase = .shortBreak
                totalSeconds = shortBreakDuration * 60
            }
        } else {
            sendNotification(title: "休息结束！", body: "继续专注学习吧")
            currentPhase = .work
            totalSeconds = workDuration * 60
        }
        
        isRunning = false
        isPaused = false
        remainingSeconds = totalSeconds
    }
    
    private func enableFocusMode() {
        print("Focus mode enabled (macOS native)")
    }
    
    private func disableFocusMode() {
        print("Focus mode disabled (macOS native)")
    }
    
    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = "智学笔记 - \(title)"
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    private func saveSettings() {
        let settings = StorageService().loadSettings()
        var updatedSettings = settings
        updatedSettings.pomodoroWorkDuration = workDuration
        updatedSettings.pomodoroBreakDuration = shortBreakDuration
        StorageService().saveSettings(updatedSettings)
    }
    
    private func loadSettings() {
        let settings = StorageService().loadSettings()
        workDuration = settings.pomodoroWorkDuration
        shortBreakDuration = settings.pomodoroBreakDuration
        totalSeconds = workDuration * 60
        remainingSeconds = totalSeconds
    }
}

class StudyStatisticsService: ObservableObject {
    static let shared = StudyStatisticsService()
    
    @Published var todaySessions: [StudySession] = []
    @Published var weekSessions: [StudySession] = []
    @Published var allSessions: [StudySession] = []
    
    @Published var todayDuration: TimeInterval = 0
    @Published var weekDuration: TimeInterval = 0
    @Published var totalDuration: TimeInterval = 0
    
    @Published var subjectStats: [String: TimeInterval] = [:]
    
    private let storageService = StorageService()
    
    private init() {
        loadSessions()
    }
    
    func addSession(_ session: StudySession) {
        allSessions.append(session)
        saveSessions()
        calculateStatistics()
    }
    
    func loadSessions() {
        allSessions = storageService.loadStudySessions()
        calculateStatistics()
    }
    
    private func calculateStatistics() {
        let calendar = Calendar.current
        let now = Date()
        let startOfDay = calendar.startOfDay(for: now)
        let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
        
        todaySessions = allSessions.filter { $0.startTime >= startOfDay }
        weekSessions = allSessions.filter { $0.startTime >= startOfWeek }
        
        todayDuration = todaySessions.reduce(0) { $0 + $1.duration }
        weekDuration = weekSessions.reduce(0) { $0 + $1.duration }
        totalDuration = allSessions.reduce(0) { $0 + $1.duration }
        
        var stats: [String: TimeInterval] = [:]
        for session in allSessions {
            stats[session.subject, default: 0] += session.duration
        }
        subjectStats = stats
    }
    
    private func saveSessions() {
        storageService.saveStudySessions(allSessions)
    }
    
    var completionRate: Double {
        guard !weekSessions.isEmpty else { return 0 }
        let completed = weekSessions.filter { $0.completed }.count
        return Double(completed) / Double(weekSessions.count) * 100
    }
    
    var averageSessionDuration: TimeInterval {
        guard !weekSessions.isEmpty else { return 0 }
        return weekDuration / Double(weekSessions.count)
    }
}

struct StudySession: Codable, Identifiable {
    let id: UUID
    let subject: String
    let startTime: Date
    var duration: TimeInterval
    var completed: Bool
}
