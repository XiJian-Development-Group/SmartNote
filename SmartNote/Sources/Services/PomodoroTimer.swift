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
    private let notificationService: NotificationService
    private let statisticsService: StudyStatisticsService
    private let storage: StorageService

    init(
        notificationService: NotificationService = NotificationService.shared,
        statisticsService: StudyStatisticsService = StudyStatisticsService.shared,
        storage: StorageService = StorageService()
    ) {
        self.notificationService = notificationService
        self.statisticsService = statisticsService
        self.storage = storage
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
        } else {
            // 休息阶段没有正在进行的专注会话，避免沿用上一阶段的累计值。
            studySession = nil
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }

        sendNotification(title: "开始\(currentPhase.displayName)", body: "番茄钟已开始")
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
        recordCurrentStudySessionIfNeeded()
        studySession = nil
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
        // Timer 回调可能在 stop/pause 后才到达；忽略这类过期回调，避免重复完成阶段。
        guard isRunning && !isPaused else {
            return
        }

        guard remainingSeconds > 0 else {
            phaseComplete()
            return
        }

        remainingSeconds -= 1

        if currentPhase == .work {
            // 本次专注累计秒数只保存在 studySession.duration 中。
            studySession?.duration += 1
        }
    }

    private func phaseComplete() {
        timer?.invalidate()
        timer = nil

        if currentPhase == .work {
            sessionsCompleted += 1

            // remainingSeconds 此时已归零；记录依据只能是本次专注的累计值。
            // 统计写入发生在通知请求之前，且不等待通知结果；通知失败不能回退统计。
            recordCurrentStudySessionIfNeeded()
            studySession = nil

            sendNotification(title: "专注完成！", body: "番茄钟完成")

            if sessionsCompleted % sessionsBeforeLongBreak == 0 {
                currentPhase = .longBreak
                totalSeconds = longBreakDuration * 60
            } else {
                currentPhase = .shortBreak
                totalSeconds = shortBreakDuration * 60
            }
        } else {
            // 休息阶段不写入学习统计，并清理任何不应存在的旧会话。
            studySession = nil
            sendNotification(title: "休息结束！", body: "休息结束")
            currentPhase = .work
            totalSeconds = workDuration * 60
        }

        isRunning = false
        isPaused = false
        remainingSeconds = totalSeconds
    }

    /// 将当前专注阶段已经累计的有效秒数写入统计。
    ///
    /// 记录前先清空 studySession，使 phaseComplete 与 stop 即使连续到达，
    /// 也不能产生重复记录。手动停止的记录同样视为一次已记录的学习会话。
    private func recordCurrentStudySessionIfNeeded() {
        guard currentPhase == .work,
              let session = studySession,
              session.duration > 0 else {
            return
        }

        studySession = nil
        var completedSession = session
        completedSession.completed = true
        completedSession.duration = session.duration
        statisticsService.addSession(completedSession)
    }

    private func enableFocusMode() {
        print("Focus mode enabled (macOS native)")
    }

    private func disableFocusMode() {
        print("Focus mode disabled (macOS native)")
    }

    /// 番茄钟通知是尽力而为的附加反馈：请求在独立 Task 中执行，失败只写日志，
    /// 不抛错、不改变 phaseComplete 已经完成的学习统计。
    private func sendNotification(title _: String, body: String) {
        let phase = currentPhase.displayName
        let content = NotificationService.makePrivateContent(
            title: "番茄钟",
            body: body,
            userInfo: [
                "kind": "pomodoro",
                "phase": phase
            ]
        )
        let identifier = NotificationIdentifiers.pomodoro()

        Task { [weak self] in
            guard let self else { return }
            let result = await self.notificationService.submitNotification(
                identifier: identifier,
                content: content,
                trigger: nil,
                removeExisting: false
            )
            if case .failure(let failure) = result {
                print("[Pomodoro] 通知未发送：\(failure.message)；学习统计已保留。")
            }
        }
    }

    private func saveSettings() {
        let settings = storage.loadSettings()
        let updatedSettings = settings
        updatedSettings.pomodoroWorkDuration = workDuration
        updatedSettings.pomodoroBreakDuration = shortBreakDuration
        storage.saveSettings(updatedSettings)
    }

    private func loadSettings() {
        let settings = storage.loadSettings()
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

    private let storageService: StorageService

    init(storageService: StorageService = StorageService()) {
        self.storageService = storageService
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
