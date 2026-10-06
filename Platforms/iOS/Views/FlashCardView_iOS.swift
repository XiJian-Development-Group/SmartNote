import SwiftUI

/// iOS 背诵卡片界面。
///
/// 卡片数据与间隔重复算法由 Shared 的 `FlashCardService` 负责
/// （含 `MasteryLevel` 的 Leitner 式排期），本视图只做正反面翻转与进度呈现。
struct FlashCardView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme

    @StateObject private var service = FlashCardService.shared
    @State private var showsEditor = false
    @State private var showsGenerator = false
    @State private var isReviewing = false
    @State private var reviewIndex = 0
    @State private var showsAnswer = false

    private var dueCards: [FlashCard] { service.getCardsForReview() }

    var body: some View {
        List {
            Section {
                HStack {
                    StatTile_iOS(
                        title: "全部卡片",
                        value: "\(service.cards.count)",
                        icon: "rectangle.stack",
                        color: .blue
                    )
                    StatTile_iOS(
                        title: "待复习",
                        value: "\(dueCards.count)",
                        icon: "clock",
                        color: .orange
                    )
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }

            if service.cards.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("还没有背诵卡片", systemImage: "rectangle.stack")
                    } description: {
                        Text("手动添加，或用 AI 从资料正文自动生成卡片。")
                    }
                }
            } else {
                Section("卡片") {
                    ForEach(service.cards) { card in
                        FlashCardRow_iOS(card: card) {
                            service.deleteCard(card)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { edit(card) }
                    }
                }
            }
        }
        .navigationTitle("背诵卡片")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showsEditor = true
                    } label: {
                        Label("新建卡片", systemImage: "plus")
                    }
                    Button {
                        showsGenerator = true
                    } label: {
                        Label("从资料生成", systemImage: "wand.and.stars")
                    }
                    .disabled(service.cards.isEmpty == false && appState.materials.isEmpty)
                    Button {
                        isReviewing = true
                        reviewIndex = 0
                        showsAnswer = false
                    } label: {
                        Label("开始复习", systemImage: "play.circle")
                    }
                    .disabled(dueCards.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showsEditor) {
            FlashCardEditor_iOS(existing: editingCard) { card in
                if editingCard == nil {
                    service.addCard(card)
                } else {
                    service.updateCard(card)
                }
            }
        }
        .sheet(isPresented: $showsGenerator) {
            FlashCardGenerator_iOS { generated in
                generated.forEach { service.addCard($0) }
            }
        }
        .fullScreenCover(isPresented: $isReviewing) {
            FlashCardReview_iOS(
                cards: dueCards,
                onGrade: { card, level in
                    var updated = card
                    updated.updateMastery(level)
                    service.updateCard(updated)
                }
            )
        }
    }

    @State private var editingCard: FlashCard?

    private func edit(_ card: FlashCard) {
        editingCard = card
        showsEditor = true
    }
}

/// 统计小卡片。
struct StatTile_iOS: View {
    @Environment(\.appTheme) private var appTheme
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(appTheme.secondaryText)
            Text(value)
                .font(.title2.weight(.semibold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(appTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct FlashCardRow_iOS: View {
    @Environment(\.appTheme) private var appTheme
    let card: FlashCard
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.front)
                .font(.headline)
                .foregroundStyle(appTheme.primaryText)
                .lineLimit(2)

            Text(card.back)
                .font(.subheadline)
                .foregroundStyle(appTheme.secondaryText)
                .lineLimit(2)

            HStack(spacing: 8) {
                if !card.category.isEmpty {
                    Text(card.category)
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(appTheme.accent.opacity(0.15))
                        .foregroundStyle(appTheme.accent)
                        .clipShape(Capsule())
                }
                Text("复习 \(card.reviewCount) 次")
                    .font(.caption2)
                    .foregroundStyle(appTheme.secondaryText)
                Spacer()
                Text(card.masteryLevel.rawValue)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(card.masteryLevel.tintColor)
            }
        }
        .swipeActions {
            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

/// 卡片编辑表单。
private struct FlashCardEditor_iOS: View {
    @Environment(\.dismiss) private var dismiss

    let existing: FlashCard?
    let onCommit: (FlashCard) -> Void

    @State private var front = ""
    @State private var back = ""
    @State private var category = ""
    @State private var knowledgePoints: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("卡片内容") {
                    TextField("正面（问题）", text: $front, axis: .vertical).lineLimit(1...4)
                    TextField("背面（答案）", text: $back, axis: .vertical).lineLimit(1...6)
                }
                Section("分类") {
                    TextField("分类", text: $category)
                }
                Section("知识点") {
                    if knowledgePoints.isEmpty {
                        Text("尚未添加").foregroundStyle(.secondary)
                    }
                    ForEach(knowledgePoints, id: \.self) { point in
                        Text(point)
                    }
                    .onDelete { knowledgePoints.remove(atOffsets: $0) }
                    TextField("添加知识点", text: $newPoint)
                        .onSubmit { addPoint() }
                }
            }
            .navigationTitle(existing == nil ? "新建卡片" : "编辑卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { commit() }.disabled(front.isEmpty || back.isEmpty)
                }
            }
        }
        .onAppear(perform: load)
    }

    @State private var newPoint = ""

    private func load() {
        guard let existing else { return }
        front = existing.front
        back = existing.back
        category = existing.category
        knowledgePoints = existing.knowledgePoints
    }

    private func addPoint() {
        let trimmed = newPoint.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !knowledgePoints.contains(trimmed) else { return }
        knowledgePoints.append(trimmed)
        newPoint = ""
    }

    private func commit() {
        var card = existing ?? FlashCard(front: front, back: back)
        card.front = front
        card.back = back
        card.category = category
        card.knowledgePoints = knowledgePoints
        onCommit(card)
        dismiss()
    }
}

/// 从资料正文自动生成卡片。
private struct FlashCardGenerator_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    let onGenerated: ([FlashCard]) -> Void

    @StateObject private var service = FlashCardService.shared
    @State private var selectedMaterialID: UUID?
    @State private var isGenerating = false
    @State private var generated: [FlashCard] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("选择资料") {
                    Picker("资料", selection: $selectedMaterialID) {
                        Text("请选择").tag(UUID?.none)
                        ForEach(appState.materials) { material in
                            Text(material.name).tag(UUID?.some(material.id))
                        }
                    }
                }

                if isGenerating {
                    Section { ProgressView("正在生成…") }
                }

                if !generated.isEmpty {
                    Section("生成的卡片（\(generated.count)）") {
                        ForEach(generated) { card in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(card.front).font(.subheadline.weight(.medium))
                                Text(card.back).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("生成卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onGenerated(generated)
                        dismiss()
                    }
                    .disabled(generated.isEmpty)
                }
            }
        }
    }
}

/// 复习模式：正面点击翻转，按掌握程度评分。
private struct FlashCardReview_iOS: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    let cards: [FlashCard]
    let onGrade: (FlashCard, MasteryLevel) -> Void

    @State private var index = 0
    @State private var showsAnswer = false

    private var isFinished: Bool { index >= cards.count }
    private var current: FlashCard? { index < cards.count ? cards[index] : nil }

    var body: some View {
        VStack(spacing: 24) {
            if isFinished {
                Spacer()
                ContentUnavailableView {
                    Label("复习完成", systemImage: "checkmark.seal.fill")
                } description: {
                    Text("本轮共复习 \(cards.count) 张卡片。")
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 40)
            } else {
                ProgressView(value: Double(index), total: Double(cards.count))
                    .padding(.horizontal)

                Text("第 \(index + 1) / \(cards.count) 张")
                    .font(.caption)
                    .foregroundStyle(appTheme.secondaryText)

                Spacer()

                cardFace
                    .onTapGesture { withAnimation { showsAnswer.toggle() } }

                Spacer()

                if showsAnswer, let current {
                    HStack(spacing: 12) {
                        ForEach(MasteryLevel.allCases, id: \.self) { level in
                            Button(level.rawValue) {
                                onGrade(current, level)
                                advance()
                            }
                            .buttonStyle(.bordered)
                            .tint(level.tintColor)
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

    private var cardFace: some View {
        VStack(spacing: 16) {
            Text(showsAnswer ? "答案" : "问题")
                .font(.caption.weight(.medium))
                .foregroundStyle(appTheme.secondaryText)

            Text(showsAnswer ? (current?.back ?? "") : (current?.front ?? ""))
                .font(.title3)
                .foregroundStyle(appTheme.primaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 160)
        }
        .padding(24)
        .background(appTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(appTheme.border, lineWidth: 1)
        )
    }

    private func advance() {
        withAnimation {
            showsAnswer = false
            index += 1
        }
    }
}