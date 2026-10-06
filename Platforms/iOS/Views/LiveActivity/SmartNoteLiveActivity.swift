import AppIntents
import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - 番茄钟 Live Activity

struct PomodoroLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PomodoroActivityAttributes.self) { context in
            // Lock Screen / Banner UI
            PomodoroLockScreenView(context: context)
        } dynamicIsland: { context in
            // Dynamic Island UI
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PomodoroDynamicIslandLeading(context: context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PomodoroDynamicIslandTrailing(context: context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PomodoroDynamicIslandBottom(context: context)
                }
            } compactLeading: {
                PomodoroCompactLeading(context: context)
            } compactTrailing: {
                PomodoroCompactTrailing(context: context)
            } minimal: {
                PomodoroMinimal(context: context)
            }
        }
    }
}

struct PomodoroActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var timeRemaining: Int
        var isWorkPhase: Bool
        var workDuration: Int
        var breakDuration: Int
        var completedSessions: Int
        var isPaused: Bool
    }

    var sessionName: String
}

// Lock Screen View
struct PomodoroLockScreenView: View {
    let context: ActivityViewContext<PomodoroActivityAttributes>

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label(context.attributes.sessionName, systemImage: "timer")
                    .font(.headline)
                Spacer()
                Text(context.state.isWorkPhase ? "专注中" : "休息中")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(context.state.isWorkPhase ? Color.red.opacity(0.2) : Color.green.opacity(0.2))
                    .foregroundStyle(context.state.isWorkPhase ? .red : .green)
                    .clipShape(Capsule())
            }

            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.3), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(context.state.isWorkPhase ? Color.red : Color.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: progress)

                VStack(spacing: 2) {
                    Text(timeString)
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                    Text("已完成 \(context.state.completedSessions) 个番茄钟")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 120)

            if context.state.isPaused {
                Text("已暂停 · 点击继续")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .activityBackgroundTint(Color(.systemFill))
        .activitySystemActionForegroundColor(.primary)
    }

    private var progress: Double {
        let total = context.state.isWorkPhase ? context.state.workDuration * 60 : context.state.breakDuration * 60
        return max(0, min(1, 1.0 - Double(context.state.timeRemaining) / Double(total)))
    }

    private var timeString: String {
        let m = context.state.timeRemaining / 60
        let s = context.state.timeRemaining % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// Dynamic Island - Leading
struct PomodoroDynamicIslandLeading: View {
    let context: ActivityViewContext<PomodoroActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("番茄钟", systemImage: "timer")
                .font(.caption2)
            Text(context.state.isWorkPhase ? "专注" : "休息")
                .font(.caption.weight(.medium))
                .foregroundStyle(context.state.isWorkPhase ? .red : .green)
        }
    }
}

// Dynamic Island - Trailing
struct PomodoroDynamicIslandTrailing: View {
    let context: ActivityViewContext<PomodoroActivityAttributes>

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(timeString)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
            Text("已完成 \(context.state.completedSessions)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var timeString: String {
        let m = context.state.timeRemaining / 60
        let s = context.state.timeRemaining % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// Dynamic Island - Bottom
struct PomodoroDynamicIslandBottom: View {
    let context: ActivityViewContext<PomodoroActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            // 进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.3))
                    Capsule()
                        .fill(context.state.isWorkPhase ? Color.red : Color.green)
                        .frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 4)

            // 控制按钮
            HStack(spacing: 8) {
                Button(intent: PomodoroPauseIntent()) {
                    Image(systemName: context.state.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)

                Button(intent: PomodoroSkipIntent()) {
                    Image(systemName: "forward.fill")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var progress: Double {
        let total = context.state.isWorkPhase ? context.state.workDuration * 60 : context.state.breakDuration * 60
        return max(0, min(1, 1.0 - Double(context.state.timeRemaining) / Double(total)))
    }
}

// Compact Leading
struct PomodoroCompactLeading: View {
    let context: ActivityViewContext<PomodoroActivityAttributes>

    var body: some View {
        Image(systemName: "timer")
            .foregroundStyle(context.state.isWorkPhase ? .red : .green)
    }
}

// Compact Trailing
struct PomodoroCompactTrailing: View {
    let context: ActivityViewContext<PomodoroActivityAttributes>

    var body: some View {
        Text(timeString)
            .font(.system(size: 14, weight: .bold, design: .monospaced))
    }

    private var timeString: String {
        let m = context.state.timeRemaining / 60
        let s = context.state.timeRemaining % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// Minimal
struct PomodoroMinimal: View {
    let context: ActivityViewContext<PomodoroActivityAttributes>

    var body: some View {
        Image(systemName: context.state.isWorkPhase ? "circle.fill" : "circle")
            .foregroundStyle(context.state.isWorkPhase ? .red : .green)
    }
}

// MARK: - 考试倒计时 Live Activity

struct ExamCountdownLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ExamCountdownActivityAttributes.self) { context in
            ExamCountdownLockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ExamCountdownLeading(context: context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExamCountdownTrailing(context: context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExamCountdownBottom(context: context)
                }
            } compactLeading: {
                ExamCountdownCompactLeading(context: context)
            } compactTrailing: {
                ExamCountdownCompactTrailing(context: context)
            } minimal: {
                ExamCountdownMinimal(context: context)
            }
        }
    }
}

struct ExamCountdownActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var daysRemaining: Int
        var examName: String
        var examDate: Date
    }

    var examID: String
}

struct ExamCountdownLockScreenView: View {
    let context: ActivityViewContext<ExamCountdownActivityAttributes>

    var body: some View {
        VStack(spacing: 8) {
            Text(context.state.examName)
                .font(.headline)
            Text("\(context.state.daysRemaining)")
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundStyle(.red)
            Text("天")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("考试日期：\(context.state.examDate, style: .date)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .activityBackgroundTint(Color(.systemFill))
    }
}

struct ExamCountdownLeading: View {
    let context: ActivityViewContext<ExamCountdownActivityAttributes>
    var body: some View {
        VStack(alignment: .leading) {
            Text(context.state.examName).font(.caption2)
            Label("\(context.state.daysRemaining) 天", systemImage: "calendar")
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
        }
    }
}

struct ExamCountdownTrailing: View {
    let context: ActivityViewContext<ExamCountdownActivityAttributes>
    var body: some View {
        Text("D-\(context.state.daysRemaining)")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.red)
    }
}

struct ExamCountdownBottom: View {
    let context: ActivityViewContext<ExamCountdownActivityAttributes>
    var body: some View {
        Text("距离 \(context.state.examName) 还有 \(context.state.daysRemaining) 天")
            .font(.caption)
    }
}

struct ExamCountdownCompactLeading: View {
    let context: ActivityViewContext<ExamCountdownActivityAttributes>
    var body: some View {
        Image(systemName: "calendar.badge.exclamationmark").foregroundStyle(.red)
    }
}

struct ExamCountdownCompactTrailing: View {
    let context: ActivityViewContext<ExamCountdownActivityAttributes>
    var body: some View {
        Text("D-\(context.state.daysRemaining)").font(.caption.weight(.bold)).foregroundStyle(.red)
    }
}

struct ExamCountdownMinimal: View {
    let context: ActivityViewContext<ExamCountdownActivityAttributes>
    var body: some View {
        Image(systemName: "calendar.badge.exclamationmark").foregroundStyle(.red)
    }
}

// MARK: - Live Activity 管理器

@MainActor
class LiveActivityManager: ObservableObject {
    static let shared = LiveActivityManager()

    private init() {}

    // 启动番茄钟 Live Activity
    func startPomodoroActivity(
        sessionName: String,
        workDuration: Int,
        breakDuration: Int
    ) async -> Activity<PomodoroActivityAttributes>? {
        let attributes = PomodoroActivityAttributes(sessionName: sessionName)
        let initialState = PomodoroActivityAttributes.ContentState(
            timeRemaining: workDuration * 60,
            isWorkPhase: true,
            workDuration: workDuration,
            breakDuration: breakDuration,
            completedSessions: 0,
            isPaused: false
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: Date().addingTimeInterval(TimeInterval(workDuration) * 60)),
                pushType: nil
            )
            return activity
        } catch {
            print("启动 Live Activity 失败：\(error)")
            return nil
        }
    }

    // 更新番茄钟状态
    func updatePomodoroActivity(
        _ activity: Activity<PomodoroActivityAttributes>,
        timeRemaining: Int,
        isWorkPhase: Bool,
        completedSessions: Int,
        isPaused: Bool
    ) async {
        let state = PomodoroActivityAttributes.ContentState(
            timeRemaining: timeRemaining,
            isWorkPhase: isWorkPhase,
            workDuration: activity.content.state.workDuration,
            breakDuration: activity.content.state.breakDuration,
            completedSessions: completedSessions,
            isPaused: isPaused
        )
        await activity.update(.init(state: state, staleDate: Date().addingTimeInterval(TimeInterval(timeRemaining))))
    }

    // 结束番茄钟 Live Activity
    func endPomodoroActivity(_ activity: Activity<PomodoroActivityAttributes>) async {
        let finalState = PomodoroActivityAttributes.ContentState(
            timeRemaining: 0,
            isWorkPhase: false,
            workDuration: activity.content.state.workDuration,
            breakDuration: activity.content.state.breakDuration,
            completedSessions: activity.content.state.completedSessions,
            isPaused: true
        )
        await activity.end(.init(state: finalState, staleDate: Date()), dismissalPolicy: .immediate)
    }

    // 启动考试倒计时 Live Activity
    func startExamCountdownActivity(
        examID: String,
        examName: String,
        examDate: Date
    ) async -> Activity<ExamCountdownActivityAttributes>? {
        let daysRemaining = Calendar.current.dateComponents([.day], from: Date(), to: examDate).day ?? 0
        let attributes = ExamCountdownActivityAttributes(examID: examID)
        let initialState = ExamCountdownActivityAttributes.ContentState(
            daysRemaining: max(0, daysRemaining),
            examName: examName,
            examDate: examDate
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: Date().addingTimeInterval(86400))
            )
            return activity
        } catch {
            print("启动考试倒计时 Live Activity 失败：\(error)")
            return nil
        }
    }

    // 更新考试倒计时
    func updateExamCountdownActivity(
        _ activity: Activity<ExamCountdownActivityAttributes>,
        daysRemaining: Int
    ) async {
        let state = ExamCountdownActivityAttributes.ContentState(
            daysRemaining: max(0, daysRemaining),
            examName: activity.content.state.examName,
            examDate: activity.content.state.examDate
        )
        await activity.update(.init(state: state, staleDate: Date().addingTimeInterval(86400)))
    }

    // 结束所有 Live Activity
    func endAllActivities() async {
        for activity in Activity<PomodoroActivityAttributes>.activities {
            await endPomodoroActivity(activity)
        }
        for activity in Activity<ExamCountdownActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

// MARK: - Intents for Live Activity Buttons

struct PomodoroPauseIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "暂停/继续"
    func perform() async throws -> some IntentResult { .result() }
}

struct PomodoroSkipIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "跳过"
    func perform() async throws -> some IntentResult { .result() }
}