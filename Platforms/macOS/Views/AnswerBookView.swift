import SwiftUI
import AppKit

/// 答案之书。
///
/// 在心里把问题想清楚，写下来，然后翻开这本书取一句话。
/// 答案文案普遍很短（多数不足 10 个字），因此书页上用大字号呈现，而不是列表小字。
struct AnswerBookView: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var service: AnswerBookService

    @State private var question: String = ""
    @State private var currentEntry: AnswerBookEntry?
    /// 当前这次测定对应的历史记录 id。「换一个」改这条记录，不新增条目。
    @State private var currentRecordID: UUID?
    @State private var settledQuestion: String = ""
    @State private var hint: String?
    @State private var toast: String?
    @State private var showHistory = false
    /// 翻页方向：1 向下一页，-1 向上一页，仅用于动画方向。
    @State private var turnDirection: Int = 1

    var body: some View {
        VStack(spacing: 0) {
            header

            if let loadError = service.loadError {
                banner(
                    message: loadError,
                    actionTitle: "重试",
                    action: { service.retryLoadCatalog() },
                    dismiss: nil
                )
            }

            if let saveError = service.saveError {
                banner(
                    message: saveError,
                    actionTitle: nil,
                    action: nil,
                    dismiss: { service.clearSaveError() }
                )
            }

            ScrollView {
                VStack(spacing: 20) {
                    pageArea
                    askArea
                    if currentEntry != nil { actionArea }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 28)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .overlay(alignment: .top) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(theme.background)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(theme.accent, in: Capsule())
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
        // 提示 2 秒后自动消失；连续操作会重新计时。
        .task(id: toast) {
            guard toast != nil else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { toast = nil }
        }
        .sheet(isPresented: $showHistory) {
            AnswerBookHistorySheet(service: service)
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "book.closed.fill")
                .font(.title2)
                .foregroundStyle(theme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text("答案之书")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer(minLength: 8)

            Button {
                showHistory = true
            } label: {
                Label("历史", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.bordered)
            .disabled(!service.isCatalogReady && service.records.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var subtitle: String {
        guard service.isCatalogReady else { return "答案库未加载" }
        let favorites = service.favoriteRecords.count
        let history = service.records.count
        return "共 \(service.entries.count) 条答案 · 已记录 \(history) 次测定" + (favorites > 0 ? " · 收藏 \(favorites)" : "")
    }

    // MARK: - 书页

    private var pageArea: some View {
        ZStack {
            pageSurface

            Group {
                if let entry = currentEntry {
                    answerContent(entry)
                        .id("answer-\(entry.id)")
                } else {
                    placeholderContent
                        .id("placeholder")
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 28)
        }
        .frame(minHeight: 260)
        .animation(.easeInOut(duration: 0.42), value: currentEntry?.id)
    }

    private var pageSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(theme.border, lineWidth: 1)
                )
                .shadow(color: theme.shadowColor, radius: 12, y: 5)

            // 书脊：中间一道竖线 + 左侧装订边，让卡片读起来像摊开的书页。
            HStack(spacing: 0) {
                Rectangle()
                    .fill(theme.accent.opacity(0.35))
                    .frame(width: 5)
                Spacer()
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Rectangle()
                .fill(theme.border.opacity(0.55))
                .frame(width: 1)
                .padding(.vertical, 16)
        }
    }

    private var placeholderContent: some View {
        VStack(spacing: 14) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(theme.accentSecondary)

            Text("在心里把问题想清楚")
                .font(.title3.weight(.medium))
                .foregroundStyle(theme.primaryText)

            Text("写下来，然后翻开这一页。")
                .font(.callout)
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    private func answerContent(_ entry: AnswerBookEntry) -> some View {
        VStack(spacing: 16) {
            // 原本这里会根据 kind 显示「这一页印坏了」或「这一页是空白的」，
            // 但这些描述源于迁移前的数据标记（Lost/Dark、SystemError=404），
            // 与当前产品无关，已按要求移除。
            // 保留 isSpecial 判断以便后续若想加其他视觉区分时可用。

            Text(entry.content)
                .font(.system(size: 34, weight: .medium, design: .serif))
                .foregroundStyle(theme.primaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(6)
                .minimumScaleFactor(0.5)
                .fixedSize(horizontal: false, vertical: true)

            if !settledQuestion.isEmpty {
                Text("「\(settledQuestion)」")
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .transition(.asymmetric(
            insertion: .move(edge: turnDirection >= 0 ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: turnDirection >= 0 ? .leading : .trailing).combined(with: .opacity)
        ))
    }

    // MARK: - 提问

    private var askArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("写下你的问题…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                    .onSubmit { ask() }
                    .accessibilityLabel("你的问题")

                Button("开始测定") { ask() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!service.isCatalogReady || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(spacing: 8) {
                if let hint {
                    Label(hint, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("最多 \(AnswerBookService.questionLimit) 个字。同一句话只留一条记录，「换一个」改的是这一次的结果。")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }

                Spacer(minLength: 8)

                Text("\(question.count)/\(AnswerBookService.questionLimit)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(question.count > AnswerBookService.questionLimit ? .orange : theme.secondaryText)
            }
        }
    }

    // MARK: - 答案操作

    private var actionArea: some View {
        HStack(spacing: 10) {
            Button {
                reroll()
            } label: {
                Label("换一个", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)

            Button {
                copyToPasteboard()
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)

            Button {
                toggleFavorite()
            } label: {
                Label(isCurrentFavorite ? "已收藏" : "收藏",
                      systemImage: isCurrentFavorite ? "star.fill" : "star")
            }
            .buttonStyle(.bordered)
            .disabled(currentRecordID == nil)

            Spacer(minLength: 0)
        }
    }

    private var isCurrentFavorite: Bool {
        guard let currentRecordID else { return false }
        return service.record(id: currentRecordID)?.isFavorite == true
    }

    // MARK: - 行为

    private func ask() {
        if let message = service.validate(question: question) {
            hint = message
            return
        }
        hint = nil
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let entry = service.drawAnswer() else {
            hint = service.loadError ?? "答案库为空，暂时无法测定。"
            return
        }
        turnDirection = 1
        settledQuestion = trimmed
        currentEntry = entry
        let record = service.record(question: trimmed, entry: entry)
        currentRecordID = record.id
        // 即使写盘失败也照样显示答案，失败原因由顶部横幅说明，不静默吞掉。
    }

    private func reroll() {
        guard let current = currentEntry else { return }
        guard let entry = service.drawAnswer(excluding: current.id) else { return }
        turnDirection = 1
        if let currentRecordID {
            service.update(recordID: currentRecordID, entry: entry)
        } else {
            let record = service.record(question: settledQuestion, entry: entry)
            currentRecordID = record.id
        }
        currentEntry = entry
    }

    private func copyToPasteboard() {
        guard let content = currentEntry?.content else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
        toast = "已复制到剪贴板"
    }

    private func toggleFavorite() {
        guard let currentRecordID else { return }
        guard let isFavorite = service.toggleFavorite(recordID: currentRecordID) else { return }
        toast = isFavorite ? "已加入收藏" : "已取消收藏"
    }

    // MARK: - 横幅

    private func banner(
        message: String,
        actionTitle: String?,
        action: (() -> Void)?,
        dismiss: (() -> Void)?
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
            if let dismiss {
                Button("知道了", action: dismiss)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.16))
    }
}

/// 历史抽屉：倒序展示历次测定，支持只看收藏、复制与取消收藏。
private struct AnswerBookHistorySheet: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismissSheet
    @ObservedObject var service: AnswerBookService

    @State private var favoritesOnly = false
    @State private var toast: String?

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private var records: [AnswerBookRecord] {
        favoritesOnly ? service.favoriteRecords : service.records
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("答案之书 · 历史")
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)

                Toggle("只看收藏", isOn: $favoritesOnly)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                Spacer(minLength: 8)

                Button("关闭") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if records.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: favoritesOnly ? "star" : "clock")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(theme.secondaryText)
                    Text(favoritesOnly ? "还没有收藏的答案。" : "还没有测定记录。")
                        .font(.callout)
                        .foregroundStyle(theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(records) { record in
                            row(record)
                            Divider()
                        }
                    }
                }
            }

            Divider()

            Text("最多保留最近 \(AnswerBookService.historyLimit) 条，每次测定后立刻写入本机；"
                 + "「设置 → 存储 → 清除所有数据」会一并清空这里的记录。")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(width: 560, height: 520)
        .background(theme.background)
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.caption)
                    .foregroundStyle(theme.background)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(theme.accent, in: Capsule())
                    .padding(.top, 8)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
        .task(id: toast) {
            guard toast != nil else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    private func row(_ record: AnswerBookRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(Self.formatter.string(from: record.createdAt))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                    if record.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(theme.accent)
                    }
                }

                Text(record.question.isEmpty ? "（未记录问题）" : record.question)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(record.answer)
                    .font(.body.weight(.medium))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(record.answer, forType: .string)
                    toast = "已复制到剪贴板"
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("复制答案")

                Button {
                    _ = service.toggleFavorite(recordID: record.id)
                } label: {
                    Image(systemName: record.isFavorite ? "star.fill" : "star")
                }
                .buttonStyle(.borderless)
                .help(record.isFavorite ? "取消收藏" : "加入收藏")

                Button {
                    service.remove(recordID: record.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除这条记录")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func dismiss() {
        dismissSheet()
    }
}
