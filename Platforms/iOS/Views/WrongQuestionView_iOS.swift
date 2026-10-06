import SwiftUI

/// iOS 错题本界面。
///
/// 数据与复习排期由 Shared 的 `WrongQuestionService` 负责，
/// 本视图负责列表、筛选、编辑与复习评分。
struct WrongQuestionView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme

    @StateObject private var service = WrongQuestionService.shared
    @State private var showsEditor = false
    @State private var editingQuestion: WrongQuestion?
    @State private var searchText = ""
    @State private var selectedSubject: String?
    @State private var isReviewing = false

    private var subjects: [String] {
        Array(Set(service.questions.map(\.subject).filter { !$0.isEmpty })).sorted()
    }

    private var filtered: [WrongQuestion] {
        service.questions
            .filter { question in
                if let selectedSubject, question.subject != selectedSubject { return false }
                guard !searchText.isEmpty else { return true }
                return question.questionContent.localizedCaseInsensitiveContains(searchText)
                    || question.correctAnswer.localizedCaseInsensitiveContains(searchText)
                    || question.knowledgePoints.contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    StatTile_iOS(
                        title: "错题总数",
                        value: "\(service.questions.count)",
                        icon: "xmark.circle",
                        color: .red
                    )
                    StatTile_iOS(
                        title: "待复习",
                        value: "\(service.getQuestionsForReview().count)",
                        icon: "clock",
                        color: .orange
                    )
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }

            if !subjects.isEmpty {
                Section("科目") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            FilterChip_iOS(title: "全部", isOn: selectedSubject == nil) {
                                selectedSubject = nil
                            }
                            ForEach(subjects, id: \.self) { subject in
                                FilterChip_iOS(title: subject, isOn: selectedSubject == subject) {
                                    selectedSubject = subject
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
            }

            if filtered.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("没有错题", systemImage: "checkmark.circle")
                    } description: {
                        Text("记录做错的题目，App 会按遗忘曲线安排复习。")
                    }
                }
            } else {
                Section("错题（\(filtered.count)）") {
                    ForEach(filtered) { question in
                        WrongQuestionRow_iOS(question: question) {
                            service.deleteQuestion(question)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editingQuestion = question
                            showsEditor = true
                        }
                    }
                }
            }
        }
        .navigationTitle("错题本")
        .searchable(text: $searchText, prompt: "搜索题干、答案或知识点")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        editingQuestion = nil
                        showsEditor = true
                    } label: {
                        Label("新建错题", systemImage: "plus")
                    }
                    Button {
                        isReviewing = true
                    } label: {
                        Label("开始复习", systemImage: "play.circle")
                    }
                    .disabled(service.getQuestionsForReview().isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showsEditor) {
            WrongQuestionEditor_iOS(existing: editingQuestion) { question in
                if editingQuestion == nil {
                    service.addQuestion(question)
                } else {
                    service.updateQuestion(question)
                }
            }
        }
        .fullScreenCover(isPresented: $isReviewing) {
            WrongQuestionReview_iOS(
                questions: service.getQuestionsForReview(),
                onGrade: { question, level in
                    var updated = question
                    updated.masteryLevel = level
                    updated.reviewCount += 1
                    updated.lastReviewedAt = Date()
                    service.updateQuestion(updated)
                }
            )
        }
    }
}

/// 可选中的筛选胶囊。
struct FilterChip_iOS: View {
    @Environment(\.appTheme) private var appTheme
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isOn ? appTheme.accent : appTheme.surface)
                .foregroundStyle(isOn ? .white : appTheme.primaryText)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct WrongQuestionRow_iOS: View {
    @Environment(\.appTheme) private var appTheme
    let question: WrongQuestion
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question.questionContent)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(appTheme.primaryText)
                .lineLimit(3)

            if !question.correctAnswer.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(question.correctAnswer)
                        .font(.caption)
                        .foregroundStyle(appTheme.secondaryText)
                        .lineLimit(2)
                }
            }

            HStack(spacing: 8) {
                if !question.subject.isEmpty {
                    Text(question.subject)
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(appTheme.accent.opacity(0.15))
                        .foregroundStyle(appTheme.accent)
                        .clipShape(Capsule())
                }
                Text("复习 \(question.reviewCount) 次")
                    .font(.caption2)
                    .foregroundStyle(appTheme.secondaryText)
                Spacer()
                Text(question.masteryLevel.rawValue)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(question.masteryLevel.tintColor)
            }
        }
        .swipeActions {
            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

/// 错题编辑表单。
private struct WrongQuestionEditor_iOS: View {
    @Environment(\.dismiss) private var dismiss

    let existing: WrongQuestion?
    let onCommit: (WrongQuestion) -> Void

    @State private var questionContent = ""
    @State private var correctAnswer = ""
    @State private var studentAnswer = ""
    @State private var errorReason = ""
    @State private var subject = ""
    @State private var source = ""
    @State private var knowledgePoints: [String] = []
    @State private var newPoint = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("题目") {
                    TextField("题干", text: $questionContent, axis: .vertical).lineLimit(2...6)
                    TextField("正确答案", text: $correctAnswer, axis: .vertical).lineLimit(1...4)
                    TextField("我的答案", text: $studentAnswer, axis: .vertical).lineLimit(1...4)
                }

                Section("错因") {
                    TextField("错因分析", text: $errorReason, axis: .vertical).lineLimit(1...4)
                }

                Section("分类") {
                    TextField("科目", text: $subject)
                    TextField("来源", text: $source)
                }

                Section("知识点") {
                    ForEach(knowledgePoints, id: \.self) { point in
                        Text(point)
                    }
                    .onDelete { knowledgePoints.remove(atOffsets: $0) }

                    TextField("添加知识点", text: $newPoint)
                        .onSubmit { addPoint() }
                }
            }
            .navigationTitle(existing == nil ? "新建错题" : "编辑错题")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { commit() }.disabled(questionContent.isEmpty)
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard let existing else { return }
        questionContent = existing.questionContent
        correctAnswer = existing.correctAnswer
        studentAnswer = existing.studentAnswer
        errorReason = existing.errorReason
        subject = existing.subject
        source = existing.source
        knowledgePoints = existing.knowledgePoints
    }

    private func addPoint() {
        let trimmed = newPoint.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !knowledgePoints.contains(trimmed) else { return }
        knowledgePoints.append(trimmed)
        newPoint = ""
    }

    private func commit() {
        var question = existing ?? WrongQuestion(
            questionContent: questionContent,
            correctAnswer: correctAnswer
        )
        question.questionContent = questionContent
        question.correctAnswer = correctAnswer
        question.studentAnswer = studentAnswer
        question.errorReason = errorReason
        question.subject = subject
        question.source = source
        question.knowledgePoints = knowledgePoints
        onCommit(question)
        dismiss()
    }
}

/// 错题复习：先看题干，再翻答案并评分。
private struct WrongQuestionReview_iOS: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    let questions: [WrongQuestion]
    let onGrade: (WrongQuestion, MasteryLevel) -> Void

    @State private var index = 0
    @State private var showsAnswer = false

    private var isFinished: Bool { index >= questions.count }
    private var current: WrongQuestion? { index < questions.count ? questions[index] : nil }

    var body: some View {
        VStack(spacing: 24) {
            if isFinished {
                Spacer()
                ContentUnavailableView {
                    Label("复习完成", systemImage: "checkmark.seal.fill")
                } description: {
                    Text("本轮共复习 \(questions.count) 道错题。")
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 40)
            } else {
                ProgressView(value: Double(index), total: Double(questions.count))
                    .padding(.horizontal)

                Text("第 \(index + 1) / \(questions.count) 题")
                    .font(.caption)
                    .foregroundStyle(appTheme.secondaryText)

                Spacer()

                questionCard
                    .onTapGesture { withAnimation { showsAnswer.toggle() } }

                Spacer()

                if showsAnswer {
                    VStack(spacing: 12) {
                        ForEach(MasteryLevel.allCases.filter { $0 != .notReviewed }, id: \.self) { level in
                            Button(level.rawValue) {
                                if let current {
                                    onGrade(current, level)
                                }
                                advance()
                            }
                            .buttonStyle(.bordered)
                            .tint(level.tintColor)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.bottom, 40)
                } else {
                    Button("显示答案") { withAnimation { showsAnswer = true } }
                        .buttonStyle(.borderedProminent)
                        .padding(.bottom, 40)
                }
            }
        }
        .padding()
    }

    private var questionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let current, !current.subject.isEmpty {
                Text(current.subject)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(appTheme.accent)
            }

            Text(current?.questionContent ?? "")
                .font(.body)
                .foregroundStyle(appTheme.primaryText)

            if showsAnswer, let current {
                Divider()

                labelled("正确答案", current.correctAnswer, color: .green)
                if !current.studentAnswer.isEmpty {
                    labelled("我的答案", current.studentAnswer, color: .red)
                }
                if !current.errorReason.isEmpty {
                    labelled("错因", current.errorReason, color: .orange)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
        .padding(24)
        .background(appTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(appTheme.border, lineWidth: 1)
        )
    }

    private func labelled(_ title: String, _ text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(appTheme.primaryText)
        }
    }

    private func advance() {
        withAnimation {
            showsAnswer = false
            index += 1
        }
    }
}