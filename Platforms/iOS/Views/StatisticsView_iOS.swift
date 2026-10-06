import SwiftUI

/// iOS 学习统计界面。
///
/// 数据来自 Shared 的 `StudyStatisticsService`（与番茄钟写入同一份学习会话），
/// 本视图只负责把数字呈现成列表与柱状分布。
struct StatisticsView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme

    @StateObject private var statistics = StudyStatisticsService.shared
    @State private var range: Range = .week

    private enum Range: String, CaseIterable, Identifiable {
        case day = "今日"
        case week = "本周"
        case all = "全部"
        var id: String { rawValue }
    }

    private var sessions: [StudySession] {
        switch range {
        case .day: return statistics.todaySessions
        case .week: return statistics.weekSessions
        case .all: return statistics.allSessions
        }
    }

    private var duration: TimeInterval {
        switch range {
        case .day: return statistics.todayDuration
        case .week: return statistics.weekDuration
        case .all: return statistics.totalDuration
        }
    }

    var body: some View {
        List {
            Section {
                Picker("范围", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("概览") {
                StatisticsStatRow_iOS(
                    title: "学习次数",
                    value: "\(sessions.count)",
                    icon: "calendar",
                    color: .blue
                )
                StatisticsStatRow_iOS(
                    title: "总时长",
                    value: Self.durationText(duration),
                    icon: "clock",
                    color: .orange
                )
                StatisticsStatRow_iOS(
                    title: "平均时长",
                    value: Self.durationText(statistics.averageSessionDuration),
                    icon: "chart.bar",
                    color: .green
                )
                StatisticsStatRow_iOS(
                    title: "本周完成率",
                    value: String(format: "%.0f%%", statistics.completionRate),
                    icon: "target",
                    color: .purple
                )
            }

            if !statistics.subjectStats.isEmpty {
                Section("科目分布") {
                    ForEach(statistics.subjectStats.sorted(by: { $0.value > $1.value }), id: \.key) { entry in
                        SubjectBar_iOS(
                            subject: entry.key.isEmpty ? "未指定" : entry.key,
                            duration: entry.value,
                            maxDuration: statistics.subjectStats.values.max() ?? 1
                        )
                    }
                }
            }

            if !sessions.isEmpty {
                Section("最近记录") {
                    ForEach(sessions.sorted { $0.startTime > $1.startTime }.prefix(20)) { session in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(session.subject.isEmpty ? "未指定科目" : session.subject)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(appTheme.primaryText)
                                Spacer()
                                Text(Self.durationText(session.duration))
                                    .font(.caption)
                                    .foregroundStyle(appTheme.secondaryText)
                            }
                            Text(session.startTime, format: .dateTime.month().day().hour().minute())
                                .font(.caption2)
                                .foregroundStyle(appTheme.secondaryText)
                        }
                    }
                }
            }
        }
        .navigationTitle("学习统计")
        .onAppear { statistics.loadSessions() }
    }

    private static func durationText(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours) 小时 \(minutes) 分钟" }
        return "\(minutes) 分钟"
    }
}

private struct StatisticsStatRow_iOS: View {
    @Environment(\.appTheme) private var appTheme
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        HStack {
            Label(title, systemImage: icon)
                .foregroundStyle(appTheme.primaryText)
            Spacer()
            Text(value)
                .font(.headline)
                .foregroundStyle(color)
        }
    }
}

/// 科目时长的横向条形图。
private struct SubjectBar_iOS: View {
    @Environment(\.appTheme) private var appTheme
    let subject: String
    let duration: TimeInterval
    let maxDuration: TimeInterval

    private var fraction: Double {
        guard maxDuration > 0 else { return 0 }
        return min(1, duration / maxDuration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(subject)
                    .font(.subheadline)
                    .foregroundStyle(appTheme.primaryText)
                Spacer()
                Text("\(Int(duration / 60)) 分钟")
                    .font(.caption)
                    .foregroundStyle(appTheme.secondaryText)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(appTheme.border.opacity(0.4))
                    Capsule()
                        .fill(appTheme.accent)
                        .frame(width: max(4, geometry.size.width * fraction))
                }
            }
            .frame(height: 8)
        }
        .padding(.vertical, 4)
    }
}