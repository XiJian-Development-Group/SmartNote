import SwiftUI

struct KeyPointsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedMaterial: StudyMaterial?
    @State private var searchText = ""
    @State private var extractedKeywords: [String] = []
    @State private var keySentences: [String] = []
    @State private var showAIAnalysis = false
    
    private var allKeywords: [String] {
        appState.materials
            .compactMap { $0.keywords }
            .flatMap { $0 }
    }
    
    private var uniqueKeywords: [String] {
        Array(Set(allKeywords))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            Divider()
            
            HSplitView {
                materialsSection
                    .frame(minWidth: 250, maxWidth: 350)
                
                keywordsSection
            }
        }
        .sheet(isPresented: $showAIAnalysis) {
            AIAnalysisSheet(material: selectedMaterial)
                .environmentObject(appState)
        }
    }
    
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("考点提取")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("基于 AI 分析文档内容，提取核心考点和关键词")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text("共 \(uniqueKeywords.count) 个考点")
                .font(.headline)
                .foregroundColor(.accentColor)
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private var materialsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择资料")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top)
            
            TextField("搜索资料...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
            
            List(appState.materials.filter { material in
                searchText.isEmpty || material.name.localizedCaseInsensitiveContains(searchText)
            }) { material in
                Button {
                    selectedMaterial = material
                    analyzeMaterial(material)
                } label: {
                    HStack {
                        Image(systemName: material.type.icon)
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading) {
                            Text(material.name)
                                .font(.body)
                                .lineLimit(1)
                            Text("\(material.keywords?.count ?? 0) 个考点")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if selectedMaterial?.id == material.id {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    private var keywordsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let material = selectedMaterial {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "brain.head.profile")
                            .foregroundColor(.accentColor)
                        Text(material.name)
                            .font(.headline)
                        Spacer()
                        
                        Button {
                            showAIAnalysis = true
                        } label: {
                            if appState.isAnalyzingWithAI {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Label("AI 分析", systemImage: "sparkles")
                            }
                        }
                        .disabled(appState.isAnalyzingWithAI || !appState.llmConfiguration.enabled)
                    }
                    
                    if let keywords = material.keywords, !keywords.isEmpty {
                        Text("关键词")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        FlowLayout(spacing: 8) {
                            ForEach(keywords, id: \.self) { keyword in
                                KeywordChip(keyword: keyword)
                            }
                        }
                    } else {
                        Text("暂无考点数据，点击左侧「分析」按钮提取")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    }
                    
                    if !appState.llmConfiguration.enabled {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("请在设置中启用 AI 分析功能")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 8)
                    }
                }
                .padding()
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "brain")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary)
                    Text("选择一份资料开始分析")
                        .font(.headline)
                    Text("系统将自动提取文档中的核心考点和关键词")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            Spacer()
        }
        .padding()
    }
    
    private func analyzeMaterial(_ material: StudyMaterial) {
        let text = material.extractedText ?? material.content
        guard !text.isEmpty else { return }
        
        extractedKeywords = appState.keywordService.extractKeywords(from: text)
        keySentences = appState.keywordService.extractKeySentences(from: text)
        
        if let index = appState.materials.firstIndex(where: { $0.id == material.id }) {
            appState.materials[index].keywords = extractedKeywords
            appState.storageService.saveMaterials(appState.materials)
        }
    }
}

struct AIAnalysisSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    let material: StudyMaterial?
    @State private var analysisType: AIAnalysisType = .keyPoints
    
    enum AIAnalysisType: String, CaseIterable {
        case keyPoints = "核心考点"
        case summary = "内容总结"
        case questions = "复习题目"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AI 智能分析")
                    .font(.headline)
                Spacer()
                Button("关闭") {
                    dismiss()
                }
            }
            .padding()
            
            Divider()
            
            if let material = material {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("分析资料:")
                                .foregroundColor(.secondary)
                            Text(material.name)
                                .fontWeight(.medium)
                        }
                        
                        Picker("分析类型", selection: $analysisType) {
                            ForEach(AIAnalysisType.allCases, id: \.self) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
                        
                        Button {
                            performAIAnalysis(material: material, type: analysisType)
                        } label: {
                            if appState.isAnalyzingWithAI {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("分析中...")
                            } else {
                                Label("开始 AI 分析", systemImage: "sparkles")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.isAnalyzingWithAI || !appState.llmConfiguration.enabled)
                        
                        if !appState.llmConfiguration.enabled {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("请在设置中启用 AI 分析功能")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(8)
                        }
                        
                        if !appState.aiAnalysisResult.isEmpty {
                            Divider()
                            Text("分析结果")
                                .font(.headline)
                            Text(appState.aiAnalysisResult)
                                .font(.body)
                                .textSelection(.enabled)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .textBackgroundColor))
                                .cornerRadius(8)
                        }
                    }
                    .padding()
                }
            } else {
                Text("请先选择一份资料")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 500, height: 450)
    }
    
    private func performAIAnalysis(material: StudyMaterial, type: AIAnalysisType) {
        let text = material.extractedText ?? material.content
        guard !text.isEmpty else { return }
        
        switch type {
        case .keyPoints:
            appState.analyzeWithAI(for: material)
        case .summary:
            appState.generateSummaryWithAI(for: material)
        case .questions:
            Task {
                do {
                    let result = try await appState.llmService.generateQuestions(text)
                    await MainActor.run {
                        appState.aiAnalysisResult = result
                    }
                } catch {
                    await MainActor.run {
                        appState.errorMessage = error.localizedDescription
                        appState.showError = true
                    }
                }
            }
        }
    }
}

struct KeywordChip: View {
    let keyword: String
    @State private var isHovered = false
    
    var body: some View {
        Text(keyword)
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isHovered ? Color.accentColor.opacity(0.2) : Color.accentColor.opacity(0.1))
            .foregroundColor(.accentColor)
            .cornerRadius(16)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}
