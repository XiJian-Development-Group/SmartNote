import SwiftUI

/// 答案之书（iOS）。
///
/// 在心里把问题想清楚，写下来，然后翻开这本书取一句话。
/// 抽取、历史与「换一个」都由 Shared 的 `AnswerBookService` 负责，
/// 因此与 macOS 端记录在同一份 `answer_book_history.json` 里。
struct AnswerBookView_iOS: View {
    @Environment(\.appTheme) private var appTheme

    @ObservedObject var service: AnswerBookService

    @State private var question = ""
    @State private var currentEntry: AnswerBookEntry?
    @State private var currentRecordID: UUID?
    @State private var settledQuestion = ""
    @State private var hint: String?
    @State private var showsHistory = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                askSection
                pageSection
                historySection
            }
            .padding()
        }
        .navigationTitle("答案之书")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsHistory) {
            AnswerBookHistoryView_iOS(service: service)
        }
        .onAppear {
            // 恢复上次未清除的测定结果，避免切换标签页后答案“消失”。
            if let last = service.history.records.first, currentRecordID == nil {
                settledQuestion = last.question
                currentRecordID = last.id
                if let entry = service.entry(id: last.entryID) {
                    currentEntry = entry
                }
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 40))
                .foregroundStyle(appTheme.accent)

            Text("把问题想清楚，写下来，然后翻开。")
                .font(.footnote)
                .foregroundStyle(appTheme.secondaryText)
                .multilineTextAlignment(.center)

            if !service.catalogNote.isEmpty {
                Text(service.catalogNote)
                    .font(.caption2)
                    .foregroundStyle(appTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - 提问

    private var askSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("你的问题", text: $question, axis: .vertical)
                .lineLimit(2...5)
                .padding(12)
                .background(appTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .disabled(currentEntry != nil)

            if let hint {
                Label(hint, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let loadError = service.loadError {
                HStack {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("重试") { _ = service.retryLoadCatalog() }
                        .font(.caption)
                }
            }

            if let saveError = service.saveError {
                HStack {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("知道了") { service.clearSaveError() }
                        .font(.caption)
                }
            }

            Button {
                ask()
            } label: {
                Text(currentEntry == nil ? "翻开答案之书" : "重新提问")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(appTheme.accent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(currentEntry != nil)
        }
    }

    // MARK: - 书页

    @ViewBuilder
    private var pageSection: some View {
        if let entry = currentEntry {
            VStack(spacing: 16) {
                Text(settledQuestion)
                    .font(.subheadline)
                    .foregroundStyle(appTheme.secondaryText)
                    .multilineTextAlignment(.center)

                Text(entry.content)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(appTheme.primaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .padding(.horizontal, 16)
                    .background(appTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))

                HStack(spacing: 12) {
                    Button {
                        drawAnother()
                    } label: {
                        Label("换一个", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        clear()
                    } label: {
                        Label("收好答案", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: entry.id)
        }
    }

    // MARK: - 历史

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("历史记录")
                    .font(.headline)
                    .foregroundStyle(appTheme.primaryText)
                Spacer()
                Button("全部 \(service.history.records.count) 条") { showsHistory = true }
                    .font(.caption)
                    .disabled(service.history.records.isEmpty)
            }

            if service.history.records.isEmpty {
                Text("还没有记录。")
                    .font(.footnote)
                    .foregroundStyle(appTheme.secondaryText)
            } else {
                ForEach(service.history.records.prefix(3)) { record in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: record.isFavorite ? "star.fill" : "book.closed")
                            .font(.caption)
                            .foregroundStyle(record.isFavorite ? .yellow : appTheme.accent)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.question.isEmpty ? "（未填写问题）" : record.question)
                                .font(.caption)
                                .foregroundStyle(appTheme.secondaryText)
                                .lineLimit(1)
                            Text(record.answer)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(appTheme.primaryText)
                        }
                        Spacer(minLength: 0)

                        Button {
                            _ = service.toggleFavorite(recordID: record.id)
                        } label: {
                            Image(systemName: record.isFavorite ? "star.slash" : "star")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - 操作

    private func ask() {
        let validation = service.validate(question: question)
        guard validation == nil else {
            hint = validation
            return
        }
        hint = nil

        guard let entry = service.drawAnswer() else {
            hint = service.loadError ?? "暂时没有可抽取的答案。"
            return
        }

        let record = service.record(question: question, entry: entry)
        settledQuestion = record.question
        currentEntry = entry
        currentRecordID = record.id
        question = ""
    }

    /// 「换一个」：改写当前这条记录，不新增历史。
    private func drawAnother() {
        guard let recordID = currentRecordID,
              let record = service.record(id: recordID),
              let next = service.drawAnswer(excluding: record.entryID) else { return }

        _ = service.update(recordID: recordID, entry: next)
        withAnimation { currentEntry = next }
    }

    private func clear() {
        currentEntry = nil
        currentRecordID = nil
        settledQuestion = ""
        question = ""
        hint = nil
    }
}

/// 答案之书历史（iOS）。
struct AnswerBookHistoryView_iOS: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    @ObservedObject var service: AnswerBookService

    var body: some View {
        NavigationStack {
            List {
                if service.history.records.isEmpty {
                    ContentUnavailableView("还没有记录", systemImage: "book.closed")
                } else {
                    ForEach(service.history.records) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(record.question.isEmpty ? "（未填写问题）" : record.question)
                                    .font(.caption)
                                    .foregroundStyle(appTheme.secondaryText)
                                    .lineLimit(1)
                                Spacer()
                                Text(record.createdAt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption2)
                                    .foregroundStyle(appTheme.secondaryText)
                            }
                            Text(record.answer)
                                .font(.body.weight(.medium))
                                .foregroundStyle(appTheme.primaryText)
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                _ = service.toggleFavorite(recordID: record.id)
                            } label: {
                                Label(record.isFavorite ? "取消收藏" : "收藏",
                                      systemImage: record.isFavorite ? "star.slash" : "star")
                            }
                            .tint(.yellow)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                service.remove(recordID: record.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("历史记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
        }
        .onAppear { service.reloadHistory() }
    }
}