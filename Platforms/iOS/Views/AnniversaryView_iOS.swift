import SwiftUI

/// iOS 纪念日界面。
///
/// 数据与提醒逻辑全部由 Shared 的 `AnniversaryService` 负责，
/// 本视图只负责增删改与提醒检查的呈现。
struct AnniversaryView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme

    @State private var showsEditor = false
    @State private var editingAnniversary: Anniversary?
    @State private var notificationMessage: String?

    private var items: [Anniversary] {
        appState.anniversaryService.items
            .sorted { $0.nextOccurrence(after: Date()) < $1.nextOccurrence(after: Date()) }
    }

    var body: some View {
        List {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("还没有纪念日", systemImage: "calendar.badge.exclamationmark")
                } description: {
                    Text("添加纪念日后，App 会在提前若干天提醒你。")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(items) { item in
                    AnniversaryRow_iOS(item: item) {
                        editingAnniversary = item
                        showsEditor = true
                    } onDelete: {
                        appState.anniversaryService.remove(id: item.id)
                    }
                }
            }
        }
        .navigationTitle("纪念日")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingAnniversary = nil
                    showsEditor = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Task { await checkNotifications() }
                } label: {
                    Image(systemName: "bell.badge")
                }
                .disabled(appState.anniversaryService.items.isEmpty)
            }
        }
        .sheet(isPresented: $showsEditor) {
            AnniversaryEditorSheet_iOS(existing: editingAnniversary) { anniversary in
                if editingAnniversary != nil {
                    appState.anniversaryService.update(anniversary)
                } else {
                    appState.anniversaryService.add(anniversary)
                }
            }
        }
        .alert("通知检查", isPresented: Binding(
            get: { notificationMessage != nil },
            set: { if !$0 { notificationMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(notificationMessage ?? "")
        }
    }

    /// 主动触发一次提醒检查，并把结果转成一句人话。
    private func checkNotifications() async {
        let results = await appState.anniversaryService.checkAndRequestPermissionAndNotify()
        notificationMessage = AnniversaryRow_iOS.message(for: results)
    }
}

private struct AnniversaryRow_iOS: View {
    @Environment(\.appTheme) private var appTheme
    let item: Anniversary
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.title3)
                .foregroundStyle(appTheme.accent)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.headline)
                    .foregroundStyle(appTheme.primaryText)

                Text(item.date, format: .dateTime.year().month().day())
                    .font(.caption)
                    .foregroundStyle(appTheme.secondaryText)

                if !item.note.isEmpty {
                    Text(item.note)
                        .font(.caption)
                        .foregroundStyle(appTheme.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(countdownText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isUrgent ? Color.red : appTheme.accent)

                Text("提前 \(item.leadTimeDays) 天提醒")
                    .font(.caption2)
                    .foregroundStyle(appTheme.secondaryText)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
        .swipeActions {
            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// 7 天内视为紧急，与列表着色保持一致。
    private var isUrgent: Bool {
        let days = item.daysUntilNextOccurrence()
        return days >= 0 && days <= 7
    }

    private var countdownText: String {
        let days = item.daysUntilNextOccurrence()
        if days == 0 { return "就是今天" }
        if days == 1 { return "明天" }
        return "还有 \(days) 天"
    }

    /// 把结构化的通知结果转成给用户看的文字。
    static func message(for results: [NotificationOperationResult]) -> String {
        guard !results.isEmpty else { return "没有需要提醒的纪念日。" }

        let successes = results.filter { if case .success = $0 { return true } else { return false } }.count
        let skipped = results.filter { if case .skipped = $0 { return true } else { return false } }.count
        let failures = results.count - successes - skipped

        var parts: [String] = []
        if successes > 0 { parts.append("已安排 \(successes) 条提醒") }
        if skipped > 0 { parts.append("跳过 \(skipped) 条") }
        if failures > 0 { parts.append("失败 \(failures) 条") }
        return parts.joined(separator: "，") + "。"
    }
}

/// 纪念日新增/编辑表单。
private struct AnniversaryEditorSheet_iOS: View {
    @Environment(\.dismiss) private var dismiss

    let existing: Anniversary?
    let onCommit: (Anniversary) -> Void

    @State private var name = ""
    @State private var date = Date()
    @State private var recurrence: Anniversary.RecurrenceType = .yearly
    @State private var leadTimeDays = 1
    @State private var accentColor: Anniversary.AccentColor = .rose
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称", text: $name)
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                    Picker("重复", selection: $recurrence) {
                        ForEach(Anniversary.RecurrenceType.allCases) { Text($0.displayName).tag($0) }
                    }
                }

                Section("提醒") {
                    Stepper("提前 \(leadTimeDays) 天", value: $leadTimeDays, in: 0...30)
                    Picker("颜色", selection: $accentColor) {
                        ForEach(Anniversary.AccentColor.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                }

                Section("备注") {
                    TextField("备注", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .navigationTitle(existing == nil ? "新建纪念日" : "编辑纪念日")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { commit() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard let existing else { return }
        name = existing.name
        date = existing.date
        recurrence = existing.recurrence
        leadTimeDays = existing.leadTimeDays
        accentColor = existing.accentColor
        note = existing.note
    }

    private func commit() {
        var anniversary = existing ?? Anniversary(name: name, date: date)
        anniversary.name = name.trimmingCharacters(in: .whitespaces)
        anniversary.date = date
        anniversary.recurrence = recurrence
        anniversary.leadTimeDays = leadTimeDays
        anniversary.accentColor = accentColor
        anniversary.note = note
        onCommit(anniversary)
        dismiss()
    }
}