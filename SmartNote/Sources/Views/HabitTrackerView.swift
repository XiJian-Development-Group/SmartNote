import SwiftUI

struct HabitTrackerView: View {
    @ObservedObject var service = HabitService.shared
    @State private var showingAdd = false
    @State private var newTitle: String = ""
    @State private var newIntervalType: HabitIntervalType = .daily
    @State private var newIntervalCount: Int = 1
    @State private var newReminderTime: Date = Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? Date()
    @State private var newEndDate: Date = Date()
    @State private var hasEndDate: Bool = false
    // 用于触发打卡动画
    @State private var animatingHabitId: UUID? = nil
    @State private var animateScale: Bool = false

    var body: some View {
        VStack {
            HStack {
                Text("习惯打卡")
                    .font(.headline)
                Spacer()
                Button(action: { showingAdd = true }) {
                    Label("添加打卡", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            .padding([.horizontal, .top])

            List {
                ForEach(service.habits) { habit in
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(habit.title).font(.body)
                            if let next = service.nextOccurrence(for: habit) {
                                Text("下次提醒：\(formatted(date: next))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("已结束或未设置提醒")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            // 最近 7 天状态预览
                            HStack(spacing: 6) {
                                let hist = service.history(for: habit, days: 7)
                                ForEach(hist, id: \.date) { item in
                                    Circle()
                                        .frame(width: 10, height: 10)
                                        .foregroundColor(color(for: item.status))
                                        .overlay(
                                            Group {
                                                if Calendar.current.isDateInToday(item.date) {
                                                    Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1)
                                                }
                                            }
                                        )
                                        .help(Text(shortDate(item.date)))
                                }
                            }
                        }
                        Spacer()

                        Button(action: {
                            // 触发动画并执行打卡
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                                animatingHabitId = habit.id
                                animateScale = true
                            }
                            let _ = service.checkIn(habitId: habit.id)
                            // 0.8s 后结束动画
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                withAnimation(.easeOut) {
                                    animateScale = false
                                    animatingHabitId = nil
                                }
                            }
                        }) {
                            ZStack {
                                Text("打卡")
                                    .opacity(animatingHabitId == habit.id && animateScale ? 0.0 : 1.0)
                                if animatingHabitId == habit.id && animateScale {
                                    Image(systemName: "checkmark")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .scaleEffect(animatingHabitId == habit.id && animateScale ? 1.18 : 1.0)

                        Button(role: .destructive) {
                            service.deleteHabit(id: habit.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 6)
                }
            }
            .listStyle(.inset)
        }
        .sheet(isPresented: $showingAdd) {
            VStack(spacing: 12) {
                HStack {
                    Button("取消") { showingAdd = false }
                    Spacer()
                    Text("新增打卡")
                        .font(.headline)
                    Spacer()
                    Button("添加") {
                        let habit = Habit(
                            title: newTitle,
                            startDate: Date(),
                            endDate: hasEndDate ? newEndDate : nil,
                            intervalType: newIntervalType,
                            intervalCount: max(1, newIntervalCount),
                            reminderTime: newReminderTime,
                            isEnabled: true
                        )
                        service.addHabit(habit)
                        // reset
                        newTitle = ""
                        newIntervalType = .daily
                        newIntervalCount = 1
                        newReminderTime = Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? Date()
                        hasEndDate = false
                        showingAdd = false
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()

                Form {
                    TextField("习惯名称", text: $newTitle)
                    Picker("间隔类型", selection: $newIntervalType) {
                        ForEach(HabitIntervalType.allCases) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    if newIntervalType != .daily {
                        Stepper("间隔: \(newIntervalCount)", value: $newIntervalCount, in: 1...30)
                    }
                    DatePicker("提醒时间", selection: $newReminderTime, displayedComponents: .hourAndMinute)
                    Toggle("设置结束时间", isOn: $hasEndDate)
                    if hasEndDate {
                        DatePicker("结束日期", selection: $newEndDate, displayedComponents: .date)
                    }
                }
                .padding()
                Spacer()
            }
            .frame(width: 480, height: 380)
        }
        .padding()
    }

    private func formatted(date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    private func color(for status: HabitService.DayStatus) -> Color {
        switch status {
        case .checked: return Color.green
        case .missed: return Color.red
        case .none: return Color.gray.opacity(0.4)
        }
    }

    private func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f.string(from: d)
    }
}
