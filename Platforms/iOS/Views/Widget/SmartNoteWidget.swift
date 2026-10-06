import WidgetKit
import SwiftUI

struct SmartNoteWidget: Widget {
    let kind: String = "SmartNoteWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SmartNoteTimelineProvider()) { entry in
            SmartNoteWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("智学笔记")
        .description("查看考试倒计时、习惯打卡、番茄钟进度")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

struct SmartNoteTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> SmartNoteEntry {
        SmartNoteEntry(date: Date(), examCountdown: nil, habits: [], pomodoroProgress: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (SmartNoteEntry) -> Void) {
        let entry = SmartNoteEntry(date: Date(), examCountdown: nil, habits: [], pomodoroProgress: 0)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SmartNoteEntry>) -> Void) {
        Task {
            let entry = await fetchCurrentData()
            let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
            let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
            completion(timeline)
        }
    }

    private func fetchCurrentData() async -> SmartNoteEntry {
        // 从 App Groups / UserDefaults / CoreData 读取数据
        // 这里返回模拟数据
        return SmartNoteEntry(
            date: Date(),
            examCountdown: ExamCountdownWidgetData(name: "高考", daysRemaining: 42, examDate: Date().addingTimeInterval(42*86400)),
            habits: [
                HabitWidgetData(name: "背单词", isCompleted: true, streak: 15),
                HabitWidgetData(name: "跑步", isCompleted: false, streak: 7),
                HabitWidgetData(name: "阅读", isCompleted: true, streak: 30)
            ],
            pomodoroProgress: 0.6
        )
    }
}

struct SmartNoteEntry: TimelineEntry {
    let date: Date
    let examCountdown: ExamCountdownWidgetData?
    let habits: [HabitWidgetData]
    let pomodoroProgress: Double
}

struct ExamCountdownWidgetData {
    let name: String
    let daysRemaining: Int
    let examDate: Date
}

struct HabitWidgetData {
    let name: String
    let isCompleted: Bool
    let streak: Int
}

struct SmartNoteWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: SmartNoteEntry

    var body: some View {
        switch family {
        case .systemSmall: SmallWidgetView(entry: entry)
        case .systemMedium: MediumWidgetView(entry: entry)
        case .systemLarge: LargeWidgetView(entry: entry)
        case .accessoryRectangular: AccessoryRectangularView(entry: entry)
        @unknown default: SmallWidgetView(entry: entry)
        }
    }
}

// MARK: - Small Widget (1x1)
struct SmallWidgetView: View {
    let entry: SmartNoteEntry

    var body: some View {
        VStack(spacing: 8) {
            if let exam = entry.examCountdown {
                VStack(spacing: 4) {
                    Text("距离 \(exam.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(exam.daysRemaining)")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(.red)
                    Text("天")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !entry.habits.isEmpty {
                VStack(spacing: 4) {
                    Text("今日习惯")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(entry.habits.filter { $0.isCompleted }.count) / \(entry.habits.count)")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                    Text("已完成")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "book.fill")
                        .font(.title)
                    Text("智学笔记")
                        .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Medium Widget (2x1)
struct MediumWidgetView: View {
    let entry: SmartNoteEntry

    var body: some View {
        HStack(spacing: 16) {
            // 左侧：考试倒计时
            if let exam = entry.examCountdown {
                VStack(alignment: .leading, spacing: 8) {
                    Label(exam.name, systemImage: "calendar.badge.exclamationmark")
                        .font(.headline)
                    Text("\(exam.daysRemaining) 天")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.red)
                    Text(exam.examDate, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 右侧：习惯/番茄钟
            VStack(alignment: .leading, spacing: 12) {
                if !entry.habits.isEmpty {
                    Text("习惯打卡")
                        .font(.headline)
                    ForEach(entry.habits.prefix(3)) { habit in
                        HStack {
                            Image(systemName: habit.isCompleted ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(habit.isCompleted ? .green : .secondary)
                            Text(habit.name)
                                .font(.subheadline)
                                .strikethrough(habit.isCompleted)
                            Spacer()
                            Text("\(habit.streak)🔥")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if entry.pomodoroProgress > 0 {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "timer").foregroundStyle(.red)
                            Text("番茄钟")
                            Spacer()
                            Text("\(Int(entry.pomodoroProgress * 100))%")
                        }
                        ProgressView(value: entry.pomodoroProgress)
                            .tint(.red)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Large Widget (2x2)
struct LargeWidgetView: View {
    let entry: SmartNoteEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 考试倒计时
            if let exam = entry.examCountdown {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("考试倒计时", systemImage: "calendar.badge.exclamationmark")
                            .font(.headline)
                        Spacer()
                        Text("\(exam.daysRemaining) 天")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.red)
                    }
                    Text(exam.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ProgressView(value: min(1.0, Double(max(0, 100 - exam.daysRemaining)) / 100.0))
                        .tint(.red)
                }
                .padding()
                .background(.fill.tertiary)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            // 习惯打卡
            if !entry.habits.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("今日习惯")
                        .font(.headline)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(entry.habits) { habit in
                            HabitWidgetCard(habit: habit)
                        }
                    }
                }
            }

            // 番茄钟进度
            if entry.pomodoroProgress > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("今日专注", systemImage: "timer")
                            .font(.headline)
                            .foregroundStyle(.red)
                        Spacer()
                        Text("\(Int(entry.pomodoroProgress * 100))%")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.red)
                    }
                    ProgressView(value: entry.pomodoroProgress)
                        .tint(.red)
                        .scaleEffect(y: 2)
                }
                .padding()
                .background(.fill.tertiary)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Spacer()
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct HabitWidgetCard: View {
    let habit: HabitWidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: habit.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(habit.isCompleted ? .green : .secondary)
                Text(habit.name)
                    .font(.subheadline)
                    .strikethrough(habit.isCompleted)
                Spacer()
            }
            Text("连续 \(habit.streak) 天 🔥")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.fill.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Lock Screen Widget
struct AccessoryRectangularView: View {
    let entry: SmartNoteEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let exam = entry.examCountdown {
                Text(exam.name)
                    .font(.caption)
                Text("\(exam.daysRemaining) 天")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.red)
            } else if !entry.habits.isEmpty {
                Text("习惯: \(entry.habits.filter { $0.isCompleted }.count)/\(entry.habits.count)")
                    .font(.caption)
            }
        }
    }
}

// MARK: - HabitWidgetData Identifiable
extension HabitWidgetData: Identifiable {
    var id: String { name }
}