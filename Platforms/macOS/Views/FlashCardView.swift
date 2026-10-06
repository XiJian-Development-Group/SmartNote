import SwiftUI

struct FlashCardView: View {
    @StateObject private var cardService = FlashCardService.shared
    @State private var showAddSheet = false
    @State private var isFlipped = false

    @State private var newFront = ""
    @State private var newBack = ""
    @State private var newCategory = ""

    // MARK: - 复习会话
    //
    // 修复前没有「开始复习」的会话流程：只能从分类列表逐张点开，
    // 标记后停留状态从不清空，所以看完最后一张回到列表看起来像重新开始，
    // 而且复习途中没有明确的退出入口（返回按钮被 maxHeight: .infinity 的卡片挤出屏幕）。
    // 这里显式建模一个会话：进入时冻结队列，结束时回到主页并汇报进度。
    @State private var sessionQueue: [UUID] = []
    @State private var sessionIndex: Int = 0
    @State private var reviewedInSession: Int = 0

    var isInSession: Bool { !sessionQueue.isEmpty }

    /// 当前会话待复习的那张卡。队列按 ID 冻结，避免标记后
    /// getCardsForReview() 把已复习的卡剔除导致索引错乱。
    private var currentSessionCard: FlashCard? {
        guard sessionIndex < sessionQueue.count else { return nil }
        let id = sessionQueue[sessionIndex]
        return cardService.cards.first { $0.id == id }
    }

    var cardsForReview: [FlashCard] {
        cardService.getCardsForReview()
    }
    
    var categories: [String] {
        Array(Set(cardService.cards.map { $0.category })).sorted()
    }
    
    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()

            if isInSession {
                // 复习中：任何时候都有一个明确的「结束复习」回到主页
                if let card = currentSessionCard {
                    sessionCardView(card)
                } else {
                    sessionFinishedView
                }
            } else if cardService.cards.isEmpty {
                emptyStateView
            } else {
                cardHomeView
            }
        }
        .sheet(isPresented: $showAddSheet) {
            addCardSheet
        }
    }

    /// 非复习状态下的主页：复习入口 + 全部卡片清单。
    private var cardHomeView: some View {
        VStack(spacing: 0) {
            reviewEntryBar
            Divider()
            cardListView
        }
    }

    /// 复习入口。修复前完全没有这个入口，只能从列表逐张点开。
    private var reviewEntryBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.stack.fill")
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(cardsForReview.isEmpty ? "当前没有待复习的卡片" : "有 \(cardsForReview.count) 张卡片待复习")
                    .font(.callout)
                Text(cardsForReview.isEmpty
                     ? "所有卡片都已安排到未来，可在下方清单里随时查看"
                     : "按遗忘曲线排序，标记后自动安排下次复习")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                startReviewSession()
            } label: {
                Label("开始复习", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(cardsForReview.isEmpty)
        }
        .padding()
    }

    private func startReviewSession() {
        let queue = cardsForReview
        guard !queue.isEmpty else { return }
        sessionQueue = queue.map(\.id)
        sessionIndex = 0
        reviewedInSession = 0
        isFlipped = false
    }

    /// 结束复习并回到主页。无论还剩多少张都能退出。
    private func endReviewSession() {
        sessionQueue = []
        sessionIndex = 0
        reviewedInSession = 0
        isFlipped = false
    }

    /// 队列走完：明确汇报本轮完成，而不是静默回到列表让人以为重新开始。
    private var sessionFinishedView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)
            Text("本轮复习完成")
                .font(.title3)
                .fontWeight(.semibold)
            Text("已复习 \(reviewedInSession) 张卡片")
                .foregroundColor(.secondary)
            Button("返回主页") {
                endReviewSession()
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    private var headerView: some View {
        HStack {
            Text("背诵卡片")
                .font(.title2)
                .fontWeight(.bold)

            Spacer()

            if isInSession {
                Text("第 \(min(sessionIndex + 1, sessionQueue.count)) / \(sessionQueue.count) 张")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            Text("\(cardService.cards.count) 张卡片")
                .foregroundColor(.secondary)

            // 复习中把「返回主页」提到标题栏，任何时候都能退出
            if isInSession {
                Button {
                    endReviewSession()
                } label: {
                    Label("结束复习", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
            }

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
            
            Image(systemName: "rectangle.stack")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            
            Text("还没有背诵卡片")
                .font(.headline)
            
            Text("点击上方按钮添加卡片")
                .foregroundColor(.secondary)
            
            Spacer()
        }
    }
    
    /// 复习会话中的单张卡片。
    /// 卡片本身用 `minHeight` 而不是 `maxHeight: .infinity`——
    /// 后者会把下面的「上一张/下一张」按钮挤出可视区，
    /// 用户在复习途中看不到任何导航按钮，也就「无法回到主页」。
    private func sessionCardView(_ card: FlashCard) -> some View {
        VStack(spacing: 16) {
            ScrollView {
                Button {
                    withAnimation {
                        isFlipped.toggle()
                    }
                } label: {
                    VStack(spacing: 16) {
                        if isFlipped {
                            VStack(spacing: 8) {
                                Text("答案")
                                    .font(.caption)
                                    .foregroundColor(.green)
                                Text(card.back)
                                    .font(.title3)
                                    .multilineTextAlignment(.center)
                            }
                        } else {
                            VStack(spacing: 8) {
                                Text("问题")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(card.front)
                                    .font(.title3)
                                    .multilineTextAlignment(.center)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .padding(32)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(16)
                }
                .buttonStyle(.plain)
            }

            Text(isFlipped ? "想一想，再标记掌握程度" : "点击卡片显示答案")
                .font(.caption)
                .foregroundColor(.secondary)

            if isFlipped {
                sessionMasteryButtons(for: card)
            }

            HStack(spacing: 12) {
                Button {
                    goToPreviousCard()
                } label: {
                    Label("上一张", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .disabled(sessionIndex == 0)

                Spacer()

                Button {
                    goToNextCard()
                } label: {
                    Label("下一张", systemImage: "chevron.right")
                }
                .buttonStyle(.bordered)
                .disabled(sessionIndex >= sessionQueue.count - 1)

                Spacer()

                Button {
                    endReviewSession()
                } label: {
                    Label("返回主页", systemImage: "house")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    private func sessionMasteryButtons(for card: FlashCard) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ForEach(MasteryLevel.allCases, id: \.self) { level in
                    Button {
                        var updated = card
                        updated.updateMastery(level)
                        cardService.updateCard(updated)
                        reviewedInSession += 1
                        isFlipped = false
                        // 自动推进到下一张；已经是最后一张时保留在原地，
                        // 由 body 切到「本轮复习完成」页。
                        if sessionIndex < sessionQueue.count - 1 {
                            sessionIndex += 1
                        }
                    } label: {
                        Text(level.rawValue)
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
            }
            Text("下次复习：\(Self.nextReviewText(for: card))")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private static func nextReviewText(for card: FlashCard) -> String {
        guard let next = card.nextReviewAt else { return "待安排" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日"
        let calendar = Calendar.current
        if calendar.isDateInToday(next) { return "今天" }
        if calendar.isDateInTomorrow(next) { return "明天" }
        return formatter.string(from: next)
    }

    private func goToPreviousCard() {
        guard sessionIndex > 0 else { return }
        sessionIndex -= 1
        isFlipped = false
    }

    private func goToNextCard() {
        guard sessionIndex < sessionQueue.count - 1 else { return }
        sessionIndex += 1
        isFlipped = false
    }

    private var cardListView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(categories, id: \.self) { category in
                    DisclosureGroup(category) {
                        ForEach(cardService.getCardsByCategory(category)) { card in
                            FlashCardRow(card: card) {
                                // 从清单点开：作为一次单张预览，随时可退出
                                sessionQueue = [card.id]
                                sessionIndex = 0
                                reviewedInSession = 0
                                isFlipped = false
                            } onDelete: {
                                cardService.deleteCard(card)
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }
    
    private var addCardSheet: some View {
        VStack(spacing: 20) {
            Text("添加背诵卡片")
                .font(.headline)
            
            Form {
                TextField("正面（问题/名词）", text: $newFront, axis: .vertical)
                    .lineLimit(2...4)
                
                TextField("背面（答案/解释）", text: $newBack, axis: .vertical)
                    .lineLimit(3...6)
                
                TextField("分类", text: $newCategory)
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
                    addCard()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newFront.isEmpty || newBack.isEmpty)
            }
        }
        .padding()
        .frame(width: 400, height: 350)
    }
    
    private func addCard() {
        let card = FlashCard(
            front: newFront,
            back: newBack,
            category: newCategory.isEmpty ? "未分类" : newCategory
        )
        
        cardService.addCard(card)
        resetForm()
        showAddSheet = false
    }
    
    private func resetForm() {
        newFront = ""
        newBack = ""
        newCategory = ""
    }
}

struct FlashCardRow: View {
    let card: FlashCard
    let onTap: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(card.front)
                    .font(.headline)
                    .lineLimit(1)
                
                Text(card.back)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            Text(masteryText)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(masteryColor.opacity(0.2))
                .cornerRadius(4)
            
            Button {
                onTap()
            } label: {
                Image(systemName: "book")
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
        .padding(.vertical, 4)
    }
    
    private var masteryText: String {
        switch card.masteryLevel {
        case .notReviewed: return "未复习"
        case .completelyForgotten: return "忘记"
        case .rememberWithDifficulty: return "困难"
        case .rememberWithEase: return "记住"
        case .completelyMastered: return "掌握"
        }
    }
    
    private var masteryColor: Color {
        switch card.masteryLevel {
        case .notReviewed: return .gray
        case .completelyForgotten: return .red
        case .rememberWithDifficulty: return .orange
        case .rememberWithEase: return .blue
        case .completelyMastered: return .green
        }
    }
}
