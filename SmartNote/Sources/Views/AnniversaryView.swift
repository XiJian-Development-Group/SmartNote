import SwiftUI

/// 倒数纪念日
struct AnniversaryView: View {
    @EnvironmentObject var appState: AppState
    @State private var showAddSheet: Bool = false
    @State private var editingAnniversaryID: UUID?

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if appState.anniversaryService.items.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(appState.anniversaryService.items) { item in
                        AnniversaryRow(item: item) {
                            editingAnniversaryID = item.id
                            showAddSheet = true
                        } onDelete: {
                            appState.anniversaryService.remove(id: item.id)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .sheet(isPresented: $showAddSheet) {
            AnniversaryEditorSheet(
                existing: editingAnniversaryID.flatMap { id in
                    appState.anniversaryService.items.first(where: { $0.id == id })
                },
                onCommit: { ann in
                    if editingAnniversaryID != nil {
                        appState.anniversaryService.update(ann)
                    } else {
                        appState.anniversaryService.add(ann)
                    }
                    editingAnniversaryID = nil
                    showAddSheet = false
                },
                onCancel: {
                    editingAnniversaryID = nil
                    showAddSheet = false
                }
            )
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "calendar.badge.exclamationmark")
                .foregroundColor(.accentColor)
            Text("倒数纪念日").font(.headline)
            Spacer()
            Button("检查通知") {
                Task { await appState.anniversaryService.checkAndRequestPermissionAndNotify() }
            }
            Button {
                showAddSheet = true
            } label: {
                Label("添加纪念日", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("还没有纪念日")
                .font(.title3)
                .foregroundColor(.secondary)
            Text("点击右上角添加，倒数日会自动计算")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.top, 60)
    }
}

private struct AnniversaryRow: View {
    let item: Anniversary
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var daysUntil: Int {
        item.daysUntilNextOccurrence()
    }

    private var countdownText: String {
        if item.recurrence == .once {
            if daysUntil > 0 { return "还有 \(daysUntil) 天" }
            if daysUntil == 0 { return "就是今天" }
            return "已过去 \(abs(daysUntil)) 天"
        }
        if daysUntil > 0 { return "还有 \(daysUntil) 天" }
        if daysUntil == 0 { return "就是今天" }
        return "今天过后本周期结束"
    }

    private var dateText: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: item.date)
    }

    private var recurrenceText: String {
        switch item.recurrence {
        case .once: return "单次"
        case .yearly: return "每年"
        case .monthly: return "每月"
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(color(for: item.accentColor))
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.headline)
                Text("\(dateText) · \(recurrenceText) · 提前 \(item.leadTimeDays) 天")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if !item.note.isEmpty {
                    Text(item.note).font(.caption).foregroundColor(.secondary.opacity(0.85))
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(countdownText)
                    .font(.callout.weight(.semibold))
                    .foregroundColor(daysUntil <= 7 ? .red : .primary)
                Text(item.nextOccurrence(after: Date()), style: .date)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Menu {
                Button("编辑") { onEdit() }
                Button("删除", role: .destructive) { onDelete() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }

    private func color(for c: Anniversary.AccentColor) -> Color {
        switch c {
        case .rose: return .pink
        case .blue: return .blue
        case .mint: return .mint
        case .amber: return .orange
        case .violet: return .purple
        case .gray: return .gray
        }
    }
}

private struct AnniversaryEditorSheet: View {
    let existing: Anniversary?
    let onCommit: (Anniversary) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var date: Date = Date()
    @State private var recurrence: Anniversary.RecurrenceType = .yearly
    @State private var leadTimeDays: Int = 0
    @State private var accentColor: Anniversary.AccentColor = .rose
    @State private var note: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "添加纪念日" : "编辑纪念日").font(.title3.weight(.semibold))
            Form {
                TextField("名称", text: $name)
                DatePicker("日期", selection: $date, displayedComponents: .date)
                Picker("重复", selection: $recurrence) {
                    ForEach(Anniversary.RecurrenceType.allCases, id: \.self) {
                        Text(label($0)).tag($0)
                    }
                }
                Picker("提前提醒", selection: $leadTimeDays) {
                    ForEach([0, 1, 3, 7, 14, 30], id: \.self) { d in
                        Text(d == 0 ? "当天" : "\(d) 天前").tag(d)
                    }
                }
                Picker("颜色", selection: $accentColor) {
                    ForEach(Anniversary.AccentColor.allCases, id: \.self) { c in
                        Text(label(c)).tag(c)
                    }
                }
                TextField("备注（可选）", text: $note)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { onCancel() }
                Button(existing == nil ? "添加" : "保存") {
                    let ann = Anniversary(
                        id: existing?.id ?? UUID(),
                        name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "未命名纪念日" : name,
                        date: date,
                        recurrence: recurrence,
                        leadTimeDays: leadTimeDays,
                        accentColor: accentColor,
                        note: note
                    )
                    onCommit(ann)
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460, height: 480)
        .onAppear {
            if let e = existing {
                name = e.name
                date = e.date
                recurrence = e.recurrence
                leadTimeDays = e.leadTimeDays
                accentColor = e.accentColor
                note = e.note
            }
        }
    }

    private func label(_ r: Anniversary.RecurrenceType) -> String {
        switch r {
        case .once: return "单次"
        case .yearly: return "每年"
        case .monthly: return "每月"
        }
    }
    private func label(_ c: Anniversary.AccentColor) -> String {
        switch c {
        case .rose: return "玫红"
        case .blue: return "蓝"
        case .mint: return "薄荷"
        case .amber: return "琥珀"
        case .violet: return "紫"
        case .gray: return "灰"
        }
    }
}
