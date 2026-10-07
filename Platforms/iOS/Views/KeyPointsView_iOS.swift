import SwiftUI

struct KeyPointsView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme
    @State private var selectedMaterial: StudyMaterial?
    @State private var extractedPoints: [String] = []
    @State private var isExtracting = false
    @State private var showResult = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if appState.materials.isEmpty {
                    emptyState
                } else {
                    materialSelector
                }

                if isExtracting {
                    extractingView
                } else if showResult && !extractedPoints.isEmpty {
                    resultView
                }
            }
            .navigationTitle("考点提取")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("暂无资料", systemImage: "folder")
        } description: {
            Text("请先在资料库导入资料，再进行考点提取")
        } actions: {
            Button("去导入资料") {
                appState.goToSection(AppState_iOS.IPadSection.allMaterials.rawValue)
            }
                .buttonStyle(.borderedProminent)
        }
    }

    private var materialSelector: some View {
        VStack(spacing: 16) {
            Text("选择要提取考点的资料")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(appState.materials) { material in
                        MaterialCard_iOS(
                            material: material,
                            isSelected: selectedMaterial?.id == material.id
                        ) {
                            selectedMaterial = material
                        }
                    }
                }
                .padding(.horizontal)
            }

            if let material = selectedMaterial {
                VStack(alignment: .leading, spacing: 8) {
                    Text("已选择：\(material.name)")
                        .font(.subheadline)
                        .foregroundStyle(appTheme.secondaryText)

                    Button {
                        extractKeyPoints(from: material)
                    } label: {
                        Label("开始提取", systemImage: "brain.head.profile")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding()
                .background(appTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)
            }
        }
        .padding(.vertical)
    }

    private var extractingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("AI 正在分析资料内容...")
                .font(.headline)
            Text("这可能需要几十秒，请耐心等待")
                .font(.subheadline)
                .foregroundStyle(appTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("提取到 \(extractedPoints.count) 个考点")
                        .font(.headline)
                    Spacer()
                    Button("重新提取") {
                        if let material = selectedMaterial {
                            extractKeyPoints(from: material)
                        }
                    }
                    .buttonStyle(.bordered)
                }

                ForEach(Array(extractedPoints.enumerated()), id: \.offset) { index, point in
                    KeyPointCard_iOS(index: index + 1, point: point)
                }
            }
            .padding()
        }
    }

    private func extractKeyPoints(from material: StudyMaterial) {
        let text = material.extractedText ?? material.content
        // 原先是裸 `guard ... else { return }`：资料没有文字时点「开始提取」
        // 毫无反应，界面停在原地，用户不知道发生了什么。
        // 现在明确告知，并指出正确的前置步骤。
        guard !text.isEmpty else {
            appState.errorMessage = "「\(material.name)」还没有可用文字，无法提取考点。请先在资料详情里做 OCR 识别，或手动补充内容。"
            appState.showError = true
            appState.hapticFeedbackService.error()
            return
        }

        isExtracting = true
        showResult = false

        // 未启用大模型时，退回本地的关键词/关键句抽取，功能不会因此不可用。
        guard appState.llmConfiguration.enabled else {
            let points = appState.keywordService.extractKeywords(from: text)
                + appState.keywordService.extractKeySentences(from: text)
            extractedPoints = points
            isExtracting = false
            showResult = !points.isEmpty
            appState.hapticFeedbackService.selection()
            return
        }

        Task {
            do {
                let raw = try await appState.llmService.analyzeText(
                    text,
                    prompt: """
                    请从下面的资料中提取 5-10 条关键考点，每条一行，不要编号，不要解释。

                    \(text)
                    """
                )
                extractedPoints = raw
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                isExtracting = false
                showResult = true
                appState.hapticFeedbackService.success()
            } catch {
                isExtracting = false
                appState.errorMessage = "提取失败：\(error.localizedDescription)"
                appState.showError = true
                appState.hapticFeedbackService.error()
            }
        }
    }
}

struct MaterialCard_iOS: View {
    @Environment(\.appTheme) private var appTheme
    let material: StudyMaterial
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(typeColor.opacity(0.15))
                        .frame(width: 48, height: 48)
                    Image(systemName: typeIcon)
                        .font(.title2)
                        .foregroundStyle(typeColor)
                }

                Text(material.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(appTheme.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(material.type.displayName)
                    .font(.caption)
                    .foregroundStyle(appTheme.secondaryText)
            }
            .frame(width: 140, height: 140)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isSelected ? appTheme.accent.opacity(0.15) : appTheme.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(isSelected ? appTheme.accent : appTheme.border, lineWidth: isSelected ? 2 : 1)
                    }
            )
        }
        .buttonStyle(.plain)
    }

    // 图标与配色复用 Shared/Models/StudyMaterial.swift 里的映射，
    // 避免同一个 `MaterialType` 在多个视图里各写一份 switch。
    private var typeIcon: String { material.type.icon }

    private var typeColor: Color { material.type.color }
}

struct KeyPointCard_iOS: View {
    @Environment(\.appTheme) private var appTheme
    let index: Int
    let point: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("考点 \(index)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(appTheme.accent.opacity(0.15))
                    .foregroundStyle(appTheme.accent)
                    .clipShape(Capsule())

                Spacer()

                Button { /* 复制 */ } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(appTheme.secondaryText)
                }
            }

            Text(point)
                .font(.body)
                .foregroundStyle(appTheme.primaryText)
                .textSelection(.enabled)
        }
        .padding()
        .background(appTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(appTheme.border, lineWidth: 1)
        }
    }
}