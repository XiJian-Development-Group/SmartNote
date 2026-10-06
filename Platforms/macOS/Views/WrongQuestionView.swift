import SwiftUI

struct WrongQuestionView: View {
    @StateObject private var questionService = WrongQuestionService.shared
    @State private var showAddSheet = false
    @State private var selectedQuestion: WrongQuestion?
    @State private var isFlipped = false

    @State private var newQuestion = ""
    @State private var newCorrectAnswer = ""
    @State private var newStudentAnswer = ""
    @State private var newErrorReason = ""
    @State private var newKnowledgePoints = ""
    @State private var newSubject = ""

    /// 列表范围。
    /// 修复前只有「待复习」一种视图：标记掌握后题目被推到 1~7 天后，
    /// 从列表消失且没有任何入口再看到它，等于复习完就再也找不回来。
    enum ListScope: String, CaseIterable, Identifiable {
        case due = "待复习"
        case all = "全部错题"
        var id: String { rawValue }
    }

    @State private var scope: ListScope = .due

    /// 当前范围下要展示的题目。
    var visibleQuestions: [WrongQuestion] {
        switch scope {
        case .due:
            return questionService.getQuestionsForReview()
        case .all:
            return questionService.questions.sorted { lhs, rhs in
                // 未复习的排前面，其余按下次复习时间由近到远
                let l = lhs.nextReviewAt ?? Date.distantPast
                let r = rhs.nextReviewAt ?? Date.distantPast
                return l < r
            }
        }
    }

    /// 保持旧调用点可用。
    var questionsForReview: [WrongQuestion] { questionService.getQuestionsForReview() }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()

            if visibleQuestions.isEmpty {
                emptyStateView
            } else {
                reviewModeView
            }
        }
        .sheet(isPresented: $showAddSheet) {
            addQuestionSheet
        }
    }
    
    private var headerView: some View {
        HStack {
            Text("错题本")
                .font(.title2)
                .fontWeight(.bold)

            Spacer()

            Text("\(questionService.questions.count) 道错题")
                .foregroundColor(.secondary)

            // 待复习 / 全部。没有这个切换，复习完的题目在间隔期内完全无法查看。
            Picker("", selection: $scope) {
                ForEach(ListScope.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)

            Button {
                showAddSheet = true
            } label: {
                Label("添加", systemImage: "plus")
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()

            if scope == .due {
                // 「待复习」为空是好消息；「全部」为空是还没录入，图标不该一样
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 64))
                    .foregroundColor(.green)
                Text("太棒了！")
                    .font(.headline)
                Text("当前没有需要复习的错题")
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: "tray")
                    .font(.system(size: 64))
                    .foregroundColor(.secondary)
                Text("还没有错题")
                    .font(.headline)
                Text("点右上角「添加」录入第一道错题")
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }
    
    private var reviewModeView: some View {
        VStack(spacing: 20) {
            if let question = selectedQuestion {
                flashCardView(question)
            } else {
                questionListView
            }
        }
        .padding()
    }
    
    private func flashCardView(_ question: WrongQuestion) -> some View {
        VStack(spacing: 20) {
            Button {
                withAnimation {
                    isFlipped.toggle()
                }
            } label: {
                VStack {
                    if isFlipped {
                        VStack {
                            Text("正确答案")
                                .font(.caption)
                                .foregroundColor(.green)
                            Text(question.correctAnswer)
                                .font(.title3)
                        }
                    } else {
                        VStack {
                            Text("题目")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(question.questionContent)
                                .font(.title3)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(16)
            }
            .buttonStyle(.plain)
            
            if isFlipped {
                masteryButtons(for: question)
            }

            Button("返回列表") {
                selectedQuestion = nil
                isFlipped = false
            }
            .buttonStyle(.bordered)
        }
    }

    private func masteryButtons(for question: WrongQuestion) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ForEach(MasteryLevel.allCases, id: \.self) { level in
                    Button {
                        var updated = question
                        updated.updateMastery(level)
                        questionService.updateQuestion(updated)
                        isFlipped = false
                        // 标记后这道题已被推到未来，「待复习」范围里不再包含它。
                        // 原来只把卡片翻回正面却不清 selectedQuestion，
                        // 用户会停在一张已经不在队列里的卡片上，看不出是否生效。
                        // 这里自动回到列表；若当前是「全部错题」范围则留在原地，
                        // 方便继续看同一道题的其它面。
                        if !visibleQuestions.contains(where: { $0.id == question.id }) {
                            selectedQuestion = nil
                        }
                    } label: {
                        Text(level.rawValue)
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
            }

            Text("下次复习：\(Self.nextReviewText(for: question))")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    /// 描述这道题的下次复习时间；「全部错题」范围下用于说明为何它不在待复习列表。
    private static func nextReviewText(for question: WrongQuestion) -> String {
        guard let next = question.nextReviewAt else { return "待安排" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日"
        let calendar = Calendar.current
        if calendar.isDateInToday(next) { return "今天" }
        if calendar.isDateInTomorrow(next) { return "明天" }
        return formatter.string(from: next)
    }

    private var questionListView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(visibleQuestions) { question in
                    QuestionCard(question: question) {
                        selectedQuestion = question
                    } onDelete: {
                        questionService.deleteQuestion(question)
                    }
                }
            }
        }
    }
    
    private var addQuestionSheet: some View {
        VStack(spacing: 20) {
            Text("添加错题")
                .font(.headline)
            
            Form {
                TextField("题目内容", text: $newQuestion, axis: .vertical)
                    .lineLimit(3...6)
                
                TextField("正确答案", text: $newCorrectAnswer, axis: .vertical)
                    .lineLimit(2...4)
                
                TextField("学生答案（可选）", text: $newStudentAnswer, axis: .vertical)
                    .lineLimit(2...4)
                
                TextField("错误原因（可选）", text: $newErrorReason)
                
                TextField("知识点（逗号分隔）", text: $newKnowledgePoints)
                
                TextField("科目", text: $newSubject)
            }
            .formStyle(.grouped)
            
            HStack {
                Button("取消") {
                    resetForm()
                    showAddSheet = false
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("添加") {
                    addQuestion()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newQuestion.isEmpty || newCorrectAnswer.isEmpty)
            }
        }
        .padding()
        .frame(width: 450, height: 500)
    }
    
    private func addQuestion() {
        let question = WrongQuestion(
            questionContent: newQuestion,
            correctAnswer: newCorrectAnswer,
            studentAnswer: newStudentAnswer,
            errorReason: newErrorReason,
            knowledgePoints: newKnowledgePoints.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            subject: newSubject
        )
        
        questionService.addQuestion(question)
        resetForm()
        showAddSheet = false
    }
    
    private func resetForm() {
        newQuestion = ""
        newCorrectAnswer = ""
        newStudentAnswer = ""
        newErrorReason = ""
        newKnowledgePoints = ""
        newSubject = ""
    }
}

struct QuestionCard: View {
    let question: WrongQuestion
    let onTap: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(question.questionContent)
                    .font(.headline)
                    .lineLimit(2)
                
                HStack {
                    if !question.subject.isEmpty {
                        Text(question.subject)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.2))
                            .cornerRadius(4)
                    }
                    
                    Text("\(question.reviewCount) 次复习")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Button {
                onTap()
            } label: {
                Label("复习", systemImage: "book")
            }
            .buttonStyle(.bordered)
            
            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }
}
