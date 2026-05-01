import SwiftUI
import UniformTypeIdentifiers

struct SmartGradingView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedFiles: [URL] = []
    @State private var selectedMaterials: [StudyMaterial] = []
    @State private var isGrading = false
    @State private var gradingResult = ""
    @State private var showFileImporter = false
    @State private var showMaterialPicker = false
    @State private var extractedTexts: [String] = []
    @State private var showQuestionExplanation = false
    @State private var questionToExplain = ""
    @State private var explanationResult = ""
    @State private var showQuestionGenerator = false
    @State private var questionToGenerate = ""
    @State private var generateCount = 5
    @State private var generatedQuestions = ""
    @State private var showAnalysisSheet = false
    @State private var analysisContent = ""
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            Divider()
            
            if selectedFiles.isEmpty && selectedMaterials.isEmpty {
                emptyStateView
            } else {
                fileListView
            }
            
            Divider()
            
            if !gradingResult.isEmpty {
                resultView
                Divider()
            }
            actionButtons
        }
        .sheet(isPresented: $showMaterialPicker) {
            MaterialPickerSheet(selectedMaterials: $selectedMaterials)
        }
        .sheet(isPresented: $showQuestionExplanation) {
            questionExplanationSheet
        }
        .sheet(isPresented: $showQuestionGenerator) {
            questionGeneratorSheet
        }
        .sheet(isPresented: $showAnalysisSheet) {
            analysisSheet
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [
                UTType.plainText,
                UTType(filenameExtension: "md") ?? .plainText,
                UTType.pdf,
                UTType.png,
                UTType.jpeg,
                UTType(filenameExtension: "webp") ?? .jpeg,
                UTType.bmp,
                UTType(filenameExtension: "docx") ?? .data,
                UTType(filenameExtension: "pages") ?? .data
            ],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
    }
    
    private var headerView: some View {
        HStack {
            Text("智能阅卷")
                .font(.title2)
                .fontWeight(.bold)
            
            Spacer()
            
            Button {
                showFileImporter = true
            } label: {
                Label("上传文件", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.bordered)
            
            Button {
                showMaterialPicker = true
            } label: {
                Label("从资料库选择", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            
            Text("上传文件或从资料库选择")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text("支持：文本、Markdown、Pages、Docx、图片、PDF")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
        }
    }
    
    private var fileListView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if !selectedFiles.isEmpty {
                    Section("已上传文件") {
                        ForEach(selectedFiles.indices, id: \.self) { index in
                            HStack {
                                Image(systemName: "doc")
                                Text(selectedFiles[index].lastPathComponent)
                                Spacer()
                                Button {
                                    selectedFiles.remove(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(6)
                        }
                    }
                }
                
                if !selectedMaterials.isEmpty {
                    Section("已选资料") {
                        ForEach(selectedMaterials) { material in
                            HStack {
                                Image(systemName: material.type.icon)
                                Text(material.name)
                                Spacer()
                                Button {
                                    selectedMaterials.removeAll { $0.id == material.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(6)
                        }
                    }
                }
            }
            .padding()
        }
    }
    
    private var actionButtons: some View {
        HStack(spacing: 16) {
            if isGrading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("AI 批改中...")
                }
            } else {
                Button {
                    startGrading()
                } label: {
                    Label("开始阅卷", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedFiles.isEmpty && selectedMaterials.isEmpty)
            }
            
            Spacer()
            
            if !gradingResult.isEmpty {
                HStack(spacing: 12) {
                    Button {
                        organizeWrongQuestions()
                    } label: {
                        Label("整理错题", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    
                    Button {
                        generateAnalysis()
                    } label: {
                        Label("智能分析", systemImage: "brain.head.profile")
                    }
                    .buttonStyle(.bordered)
                    
                    Button {
                        showQuestionExplanation = true
                    } label: {
                        Label("题目讲解", systemImage: "book")
                    }
                    .buttonStyle(.bordered)
                    
                    Button {
                        showQuestionGenerator = true
                    } label: {
                        Label("生成同类", systemImage: "plus.circle")
                    }
                    .buttonStyle(.bordered)
                    
                    Button {
                        resetGrading()
                    } label: {
                        Label("重新开始", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }
            }
        }
        .padding()
    }
    
    private var resultView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("批改结果")
                    .font(.headline)
                
                MarkdownText(gradingResult)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
            }
            .padding()
        }
    }
    
    private var questionExplanationSheet: some View {
        VStack(spacing: 16) {
            HStack {
                Text("题目讲解")
                    .font(.headline)
                Spacer()
                Button("关闭") {
                    showQuestionExplanation = false
                }
            }
            
            TextField("输入题号或题目内容", text: $questionToExplain)
                .textFieldStyle(.roundedBorder)
            
            Button {
                generateExplanation()
            } label: {
                Label("生成讲解", systemImage: "book.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(questionToExplain.isEmpty)
            
            if !explanationResult.isEmpty {
                ScrollView {
                    MarkdownText(explanationResult)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .padding()
        .frame(width: 500, height: 400)
    }
    
    private var questionGeneratorSheet: some View {
        VStack(spacing: 16) {
            HStack {
                Text("生成同类题目")
                    .font(.headline)
                Spacer()
                Button("关闭") {
                    showQuestionGenerator = false
                }
            }
            
            TextField("基于题目（题号或内容）", text: $questionToGenerate)
                .textFieldStyle(.roundedBorder)
            
            Stepper("生成数量: \(generateCount)", value: $generateCount, in: 1...20)
            
            Button {
                generateSimilarQuestions()
            } label: {
                Label("开始生成", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(questionToGenerate.isEmpty)
            
            if !generatedQuestions.isEmpty {
                ScrollView {
                    MarkdownText(generatedQuestions)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                
                Button {
                    saveGeneratedQuestions()
                } label: {
                    Label("保存到真题", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 500, height: 500)
    }
    
    private var analysisSheet: some View {
        VStack(spacing: 16) {
            HStack {
                Text("学习分析")
                    .font(.headline)
                Spacer()
                Button("关闭") {
                    showAnalysisSheet = false
                }
            }
            
            ScrollView {
                MarkdownText(analysisContent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            
            Button {
                saveAnalysis()
            } label: {
                Label("保存分析报告", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(width: 500, height: 400)
    }
    
    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            selectedFiles.append(contentsOf: urls)
        case .failure(let error):
            appState.errorMessage = error.localizedDescription
            appState.showError = true
        }
    }
    
    private func startGrading() {
        isGrading = true
        gradingResult = ""
        
        Task {
            await extractAllTexts()
            
            let prompt = """
            请批改以下作业/试卷，并给出详细的分析和评价。
            
            学生作业内容：
            \(extractedTexts.joined(separator: "\n\n---\n\n"))
            
            请按以下格式回复：
            1. 总体评价
            2. 正确题目及解析
            3. 错误题目及解析
            4. 改进建议
            
            请用中文回复，使用 Markdown 格式。
            """
            
            do {
                try await appState.llmService.sendMessageStreaming(system: "你是一个专业的老师，请仔细批改作业并给出详细的反馈。", user: prompt) { chunk in
                    Task { @MainActor in
                        self.gradingResult += chunk
                    }
                }
            } catch {
                await MainActor.run {
                    appState.errorMessage = error.localizedDescription
                    appState.showError = true
                }
            }
            
            await MainActor.run {
                isGrading = false
            }
        }
    }
    
    private func extractAllTexts() async {
        extractedTexts = []
        
        for file in selectedFiles {
            if let text = extractTextFromFile(file) {
                extractedTexts.append(text)
            }
        }
        
        for material in selectedMaterials {
            let text = material.extractedText ?? material.content
            if !text.isEmpty {
                extractedTexts.append("【\(material.name)】\n\(text)")
            }
        }
    }
    
    private func extractTextFromFile(_ url: URL) -> String? {
        let fileExtension = url.pathExtension.lowercased()
        
        switch fileExtension {
        case "txt", "md", "markdown":
            return try? String(contentsOf: url, encoding: .utf8)
        case "png", "jpg", "jpeg", "webp", "bmp":
            return nil
        default:
            return nil
        }
    }
    
    private func resetGrading() {
        selectedFiles.removeAll()
        selectedMaterials.removeAll()
        gradingResult = ""
        extractedTexts.removeAll()
        explanationResult = ""
        generatedQuestions = ""
        analysisContent = ""
    }
    
    private func organizeWrongQuestions() {
        let material = StudyMaterial(
            name: "错题整理 - \(formattedDate())",
            type: .text,
            category: .exam,
            content: gradingResult,
            extractedText: gradingResult
        )
        
        appState.materials.append(material)
        appState.storageService.saveMaterials(appState.materials)
        
        appState.errorMessage = "错题已保存到真题分类"
        appState.showError = true
    }
    
    private func generateAnalysis() {
        Task {
            let prompt = """
            基于以下批改结果，分析学生的学习情况，包括：
            1. 知识薄弱点
            2. 需要加强的知识点
            3. 学习建议
            4. 下一阶段的学习计划建议
            
            批改结果：
            \(gradingResult)
            
            请用 Markdown 格式生成个人分析报告。
            """
            
            do {
                analysisContent = ""
                try await appState.llmService.sendMessageStreaming(system: "你是一个学习分析师，请生成详细的个人分析报告。", user: prompt) { chunk in
                    Task { @MainActor in
                        self.analysisContent += chunk
                    }
                }
                
                await MainActor.run {
                    showAnalysisSheet = true
                }
            } catch {
                await MainActor.run {
                    appState.errorMessage = error.localizedDescription
                    appState.showError = true
                }
            }
        }
    }
    
    private func saveAnalysis() {
        let material = StudyMaterial(
            name: "学习分析 - \(formattedDate())",
            type: .text,
            category: .personalAnalysis,
            content: analysisContent,
            extractedText: analysisContent
        )
        
        appState.materials.append(material)
        appState.storageService.saveMaterials(appState.materials)
        
        showAnalysisSheet = false
        appState.errorMessage = "分析报告已保存到个人分析分类"
        appState.showError = true
    }
    
    private func generateExplanation() {
        Task {
            let prompt = """
            请详细讲解以下题目，要求：
            1. 详细解析解题思路
            2. 给出正确答案
            3. 解释涉及的知识点
            4. 如需要可画图说明（使用 ASCII 图表或描述性图形）
            
            题目：\(questionToExplain)
            """
            
            do {
                explanationResult = ""
                try await appState.llmService.sendMessageStreaming(system: "你是一个耐心的老师，请详细讲解题目。", user: prompt) { chunk in
                    Task { @MainActor in
                        self.explanationResult += chunk
                    }
                }
            } catch {
                await MainActor.run {
                    appState.errorMessage = error.localizedDescription
                    appState.showError = true
                }
            }
        }
    }
    
    private func generateSimilarQuestions() {
        Task {
            let prompt = """
            请基于以下题目，生成 \(generateCount) 道同类练习题。
            
            原题：\(questionToGenerate)
            
            要求：
            1. 题目类型相似
            2. 难度相当
            3. 涵盖相同知识点
            4. 给出答案和解析
            
            请用 Markdown 格式回复。
            """
            
            do {
                generatedQuestions = ""
                try await appState.llmService.sendMessageStreaming(system: "你是一个出题专家，请生成高质量的练习题。", user: prompt) { chunk in
                    Task { @MainActor in
                        self.generatedQuestions += chunk
                    }
                }
            } catch {
                await MainActor.run {
                    appState.errorMessage = error.localizedDescription
                    appState.showError = true
                }
            }
        }
    }
    
    private func saveGeneratedQuestions() {
        let material = StudyMaterial(
            name: "同类题目 - \(formattedDate())",
            type: .text,
            category: .exam,
            content: generatedQuestions,
            extractedText: generatedQuestions
        )
        
        appState.materials.append(material)
        appState.storageService.saveMaterials(appState.materials)
        
        showQuestionGenerator = false
        appState.errorMessage = "已保存到真题分类"
        appState.showError = true
    }
    
    private func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }
}

struct MaterialPickerSheet: View {
    @EnvironmentObject var appState: AppState
    @Binding var selectedMaterials: [StudyMaterial]
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("选择资料")
                    .font(.headline)
                Spacer()
                Button("关闭") {
                    dismiss()
                }
            }
            
            List(appState.materials) { material in
                HStack {
                    Image(systemName: material.type.icon)
                    VStack(alignment: .leading) {
                        Text(material.name)
                        Text(material.category.rawValue)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if selectedMaterials.contains(where: { $0.id == material.id }) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if selectedMaterials.contains(where: { $0.id == material.id }) {
                        selectedMaterials.removeAll { $0.id == material.id }
                    } else {
                        selectedMaterials.append(material)
                    }
                }
            }
            
            Button("确认选择") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(width: 400, height: 500)
    }
}
