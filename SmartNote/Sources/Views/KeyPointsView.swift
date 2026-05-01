import SwiftUI

struct KeyPointsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedMaterialID: UUID?
    @State private var searchText = ""
    @State private var extractedKeywords: [String] = []
    @State private var keySentences: [String] = []
    @State private var showAIAnalysis = false
    @State private var currentMaterial: StudyMaterial?
    
    private var selectedMaterial: StudyMaterial? {
        guard let id = selectedMaterialID else { return nil }
        return appState.materials.first { $0.id == id }
    }
    
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
            AIAnalysisSheetWrapper(materialID: selectedMaterialID)
                .environmentObject(appState)
        }
        .onAppear {
            if let id = selectedMaterialID,
               let material = appState.materials.first(where: { $0.id == id }) {
                currentMaterial = material
            }
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
            
            List(selection: $selectedMaterialID) {
                ForEach(appState.materials.filter { material in
                    searchText.isEmpty || material.name.localizedCaseInsensitiveContains(searchText)
                }) { material in
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
                    }
                    .tag(material.id)
                }
            }
            .listStyle(.inset)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    private var keywordsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let material = selectedMaterial {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundColor(.accentColor)
                            Text(material.name)
                                .font(.headline)
                            Spacer()
                            
                            Button {
                                if let updatedMaterial = appState.materials.first(where: { $0.id == material.id }) {
                                    currentMaterial = updatedMaterial
                                }
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
                        
                        Divider()
                        
                        if let keywords = material.keywords, !keywords.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("关键词")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                FlowLayout(spacing: 8) {
                                    ForEach(keywords, id: \.self) { keyword in
                                        KeywordChip(keyword: keyword)
                                    }
                                }
                            }
                        } else {
                            VStack(spacing: 8) {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .font(.title)
                                    .foregroundColor(.secondary)
                                Text("暂无考点数据")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Text("点击「AI 分析」获取智能分析")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                        }
                        
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
                    }
                }
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
    let material: StudyMaterial
    @State private var analysisType: AIAnalysisType = .keyPoints
    @State private var showSavePanel = false
    @State private var showMarkdownPreview = true
    @State private var streamingText = ""
    @State private var isCancelled = false
    
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
                    cancelAnalysis()
                    dismiss()
                }
            }
            .padding()
            
            Divider()
            
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
                    
                    HStack {
                        Button {
                            performAIAnalysis()
                        } label: {
                            if appState.isAnalyzingWithAI {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("分析中...")
                                }
                            } else {
                                Label("开始 AI 分析", systemImage: "sparkles")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.isAnalyzingWithAI)
                        
                        if appState.isAnalyzingWithAI {
                            Button {
                                cancelAnalysis()
                            } label: {
                                Label("取消", systemImage: "xmark.circle.fill")
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }
                    }
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
                        HStack {
                            Text("分析结果")
                                .font(.headline)
                            Spacer()
                            Toggle("预览", isOn: $showMarkdownPreview)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                            Button {
                                saveAsPDF()
                            } label: {
                                Label("保存 PDF", systemImage: "square.and.arrow.down")
                            }
                            .buttonStyle(.bordered)
                        }
                        
                        if showMarkdownPreview {
                            ScrollView {
                                MarkdownText(appState.aiAnalysisResult)
                                    .padding()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .background(Color(nsColor: .textBackgroundColor))
                            .cornerRadius(8)
                        } else {
                            Text(appState.aiAnalysisResult)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .textBackgroundColor))
                                .cornerRadius(8)
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 550, height: 500)
    }
    
    private func performAIAnalysis() {
        let text = material.extractedText ?? material.content
        guard !text.isEmpty else { return }
        
        isCancelled = false
        streamingText = ""
        
        let prompt: String
        switch analysisType {
        case .keyPoints:
            prompt = """
            你是一个专业的学习助手。请分析以下学习资料，提取：
            1. 核心考点（最重要的知识点）
            2. 关键概念和定义
            3. 需要记忆的重点内容
            4. 可能的出题方向
            
            请用中文回复，格式清晰，使用 Markdown 格式。
            """
        case .summary:
            prompt = "请用简洁的中文总结以下内容的核心要点："
        case .questions:
            prompt = "基于以下学习资料，生成 5 道复习思考题或选择题："
        }
        
        Task {
            do {
                try await appState.llmService.sendMessageStreaming(system: prompt, user: text) { chunk in
                    Task { @MainActor in
                        if !self.isCancelled {
                            self.streamingText += chunk
                            appState.aiAnalysisResult = self.streamingText
                        }
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    // User cancelled, keep the partial result
                }
            } catch {
                await MainActor.run {
                    if !self.isCancelled {
                        appState.errorMessage = error.localizedDescription
                        appState.showError = true
                    }
                }
            }
        }
    }
    
    private func cancelAnalysis() {
        isCancelled = true
        appState.llmService.cancelCurrentRequest()
    }
    
    private func saveAsPDF() {
        guard !appState.aiAnalysisResult.isEmpty else { return }
        
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        
        let defaultName: String
        switch analysisType {
        case .keyPoints:
            defaultName = "\(material.name)_考点分析.pdf"
        case .summary:
            defaultName = "\(material.name)_内容总结.pdf"
        case .questions:
            defaultName = "\(material.name)_复习题目.pdf"
        }
        
        savePanel.nameFieldStringValue = defaultName
        
        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                let keywords = material.keywords ?? []
                var pdfURL: URL?
                
                switch analysisType {
                case .keyPoints, .summary:
                    pdfURL = PDFService.generateSummaryPDF(
                        content: appState.aiAnalysisResult,
                        title: material.name,
                        subject: material.category.rawValue,
                        keywords: keywords
                    )
                case .questions:
                    pdfURL = PDFService.generateQuestionsPDF(
                        questions: appState.aiAnalysisResult,
                        title: material.name,
                        subject: material.category.rawValue
                    )
                }
                
                if let pdfURL = pdfURL {
                    do {
                        if FileManager.default.fileExists(atPath: url.path) {
                            try FileManager.default.removeItem(at: url)
                        }
                        try FileManager.default.copyItem(at: pdfURL, to: url)
                    } catch {
                        print("Error saving PDF: \(error)")
                    }
                }
            }
        }
    }
}

struct AIAnalysisSheetWrapper: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    let materialID: UUID?
    
    private var material: StudyMaterial? {
        guard let id = materialID else { return nil }
        return appState.materials.first { $0.id == id }
    }
    
    var body: some View {
        if let material = material {
            AIAnalysisSheet(material: material)
        } else {
            VStack {
                Text("请先选择一份资料")
                    .foregroundColor(.secondary)
                Button("关闭") {
                    dismiss()
                }
            }
            .frame(width: 550, height: 500)
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
