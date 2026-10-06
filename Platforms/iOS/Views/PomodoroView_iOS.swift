import SwiftUI

/// iOS 番茄钟界面。
///
/// 计时、阶段切换、完成通知与统计全部由 Shared 的 `PomodoroTimer` 负责
/// （macOS 界面用的是同一个单例）。这里只做 iOS 特有的布局与交互，
/// 不再另写一套计时逻辑，避免两个平台的番茄钟行为出现分歧。
struct PomodoroView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme

    @StateObject private var timer = PomodoroTimer.shared
    @State private var showsStatistics = false

    /// 专注阶段用红色，休息阶段用绿色。
    private var phaseColor: Color {
        switch timer.currentPhase {
        case .work: return .red
        case .shortBreak, .longBreak: return .green
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    phaseIndicators
                    dial
                    controls
                    durationPresets
                }
                .padding()
            }
            .navigationTitle("番茄钟")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsStatistics = true
                    } label: {
                        Image(systemName: "chart.bar.fill")
                    }
                }
            }
            .sheet(isPresented: $showsStatistics) {
                PomodoroStatisticsView()
            }
        }
    }

    // MARK: - 阶段指示器

    private var phaseIndicators: some View {
        HStack(spacing: 16) {
            PhaseIndicator_iOS(
                title: "专注",
                duration: timer.workDuration,
                isActive: timer.currentPhase == .work,
                color: .red
            )
            PhaseIndicator_iOS(
                title: "短休息",
                duration: timer.shortBreakDuration,
                isActive: timer.currentPhase == .shortBreak,
                color: .green
            )
            PhaseIndicator_iOS(
                title: "长休息",
                duration: timer.longBreakDuration,
                isActive: timer.currentPhase == .longBreak,
                color: .blue
            )
        }
    }

    // MARK: - 圆形计时器

    private var dial: some View {
        ZStack {
            Circle()
                .stroke(appTheme.border, lineWidth: 8)
                .frame(width: 280, height: 280)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    phaseColor,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .frame(width: 280, height: 280)
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: progress)

            VStack(spacing: 8) {
                Text(timeString)
                    .font(.system(size: 64, weight: .thin, design: .monospaced))
                    .foregroundStyle(appTheme.primaryText)
                    .contentTransition(.numericText())

                Text(timer.currentPhase.displayName)
                    .font(.headline)
                    .foregroundStyle(phaseColor)

                Text("已完成 \(timer.sessionsCompleted) 个番茄钟")
                    .font(.caption)
                    .foregroundStyle(appTheme.secondaryText)

                if let title = timer.linkedTodoTitle {
                    Label(title, systemImage: "checklist")
                        .font(.caption)
                        .foregroundStyle(appTheme.secondaryText)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 控制按钮

    private var controls: some View {
        HStack(spacing: 24) {
            Button {
                timer.reset()
                appState.hapticFeedbackService.selection()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.title)
                    .frame(width: 64, height: 64)
                    .background(appTheme.surface)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("重置")

            Button {
                timer.toggle()
                appState.hapticFeedbackService.light()
            } label: {
                Image(systemName: timer.isRunning && !timer.isPaused ? "pause.fill" : "play.fill")
                    .font(.system(size: 32, weight: .medium))
                    .frame(width: 88, height: 88)
                    .background(phaseColor)
                    .foregroundStyle(.white)
                    .clipShape(Circle())
                    .shadow(color: phaseColor.opacity(0.4), radius: 16, y: 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(timer.isRunning && !timer.isPaused ? "暂停" : "开始")

            Button {
                timer.stop()
                appState.hapticFeedbackService.light()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.title)
                    .frame(width: 64, height: 64)
                    .background(appTheme.surface)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("停止")
        }
    }

    // MARK: - 时长快捷选择

    /// 时长快捷选择。运行中不允许修改，避免阶段时长在计时中途跳变。
    private var durationPresets: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach([15, 25, 45, 60], id: \.self) { minutes in
                    Button {
                        timer.setDurations(
                            work: minutes,
                            shortBreak: timer.shortBreakDuration,
                            longBreak: timer.longBreakDuration
                        )
                        appState.hapticFeedbackService.selection()
                    } label: {
                        Text("\(minutes) 分")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(
                                timer.workDuration == minutes ? appTheme.accent : appTheme.surface
                            )
                            .foregroundStyle(
                                timer.workDuration == minutes ? .white : appTheme.primaryText
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(timer.isRunning)
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - 派生值

    private var progress: Double {
        guard timer.totalSeconds > 0 else { return 0 }
        return Double(timer.totalSeconds - timer.remainingSeconds) / Double(timer.totalSeconds)
    }

    private var timeString: String {
        let minutes = timer.remainingSeconds / 60
        let seconds = timer.remainingSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

/// 单个阶段的时长卡片。
struct PhaseIndicator_iOS: View {
    @Environment(\.appTheme) private var appTheme
    let title: String
    let duration: Int
    let isActive: Bool
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(isActive ? color : appTheme.secondaryText)
            Text("\(duration) 分钟")
                .font(.caption)
                .foregroundStyle(appTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(isActive ? color.opacity(0.15) : appTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isActive ? color : Color.clear, lineWidth: 2)
        )
        .animation(.easeInOut(duration: 0.3), value: isActive)
    }
}

/// 番茄钟统计。
///
/// 数据来自 Shared 的 `PomodoroStatistics`，与 macOS 界面读同一份实现。
struct PomodoroStatisticsView: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme
    @Environment(\.dismiss) private var dismiss

    @StateObject private var statistics = StudyStatisticsService.shared

    var body: some View {
        NavigationStack {
            List {
                Section("今日统计") {
                    PomodoroStatRow(
                        title: "专注次数",
                        value: "\(statistics.todaySessions.count)",
                        icon: "timer",
                        color: .red
                    )
                    PomodoroStatRow(
                        title: "专注时长",
                        value: Self.durationText(statistics.todayDuration),
                        icon: "clock",
                        color: .orange
                    )
                    PomodoroStatRow(
                        title: "平均时长",
                        value: Self.durationText(statistics.averageSessionDuration),
                        icon: "chart.bar",
                        color: .blue
                    )
                }

                Section("本周趋势") {
                    PomodoroStatRow(
                        title: "本周时长",
                        value: Self.durationText(statistics.weekDuration),
                        icon: "calendar",
                        color: .purple
                    )
                    PomodoroStatRow(
                        title: "累计时长",
                        value: Self.durationText(statistics.totalDuration),
                        icon: "infinity",
                        color: .teal
                    )
                }

                if !statistics.subjectStats.isEmpty {
                    Section("科目分布") {
                        ForEach(statistics.subjectStats.sorted(by: { $0.value > $1.value }), id: \.key) { entry in
                            PomodoroStatRow(
                                title: entry.key.isEmpty ? "未指定科目" : entry.key,
                                value: Self.durationText(entry.value),
                                icon: "book.closed",
                                color: .green
                            )
                        }
                    }
                }
            }
            .navigationTitle("番茄钟统计")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
            }
        }
        .onAppear { statistics.loadSessions() }
    }

    /// 把秒数格式化为「N 小时 M 分钟」/「N 分钟」。
    private static func durationText(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours) 小时 \(minutes) 分钟" }
        return "\(minutes) 分钟"
    }
}

/// 统计页的一行「图标 + 标题 + 数值」。
struct PomodoroStatRow: View {
    @Environment(\.appTheme) private var appTheme
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 28)
            Text(title)
            Spacer()
            Text(value)
                .font(.headline)
                .foregroundStyle(appTheme.primaryText)
        }
    }
}