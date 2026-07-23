import SwiftUI
import UniformTypeIdentifiers

struct SmartGradingView: View {
    @EnvironmentObject var appState: AppState
    @State private var markedFiles: [MarkedFile] = []
    @State private var markedMaterials: [MarkedMaterial] = []
    @State private var isGrading = false
    @State private var gradingResult = ""
    @State private var showFileImporter = false
    @State private var showMaterialPicker = false
    @State private var extractedTexts: [(String, Set<FileMarking>)] = []
    @State private var showQuestionExplanation = false
    @State private var questionToExplain = ""
    @State private var explanationResult = ""
    @State private var showQuestionGenerator = false
    @State private var questionToGenerate = ""
    @State private var generateCount = 5
    @State private var generatedQuestions = ""
    @State private var showAnalysisSheet = false
    @State private var analysisContent = ""
    @State private var showValidationError = false
    @State private var validationErrorMessage = ""
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            Divider()
            
            if markedFiles.isEmpty && markedMaterials.isEmpty {
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
            MaterialPickerSheet(markedMaterials: $markedMaterials)
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
        .alert("提示", isPresented: $showValidationError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(validationErrorMessage)
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
            LazyVStack(alignment: .leading, spacing: 12) {
                if !markedFiles.isEmpty {
                    Section("已上传文件") {
                        ForEach(markedFiles) { markedFile in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: "doc.fill")
                                        .foregroundColor(.blue)
                                    Text(markedFile.fileName)
                                        .font(.headline)
                                    Spacer()
                                    Button {
                                        markedFiles.removeAll { $0.id == markedFile.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                                
                                HStack(spacing: 8) {
                                    ForEach(FileMarking.allCases) { marking in
                                        Button {
                                            toggleMarking(for: markedFile.id, marking: marking, isMaterial: false)
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: markedFile.markings.contains(marking) ? "checkmark.circle.fill" : "circle")
                                                Text(marking.rawValue)
                                            }
                                            .font(.caption)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(markedFile.markings.contains(marking) ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1))
                                            .cornerRadius(4)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(8)
                        }
                    }
                }
                
                if !markedMaterials.isEmpty {
                    Section("已选资料") {
                        ForEach(markedMaterials) { markedMaterial in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: markedMaterial.material.type.icon)
                                        .foregroundColor(.green)
                                    Text(markedMaterial.materialName)
                                        .font(.headline)
                                    Spacer()
                                    Button {
                                        markedMaterials.removeAll { $0.id == markedMaterial.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                                
                                HStack(spacing: 8) {
                                    ForEach(FileMarking.allCases) { marking in
                                        Button {
                                            toggleMarking(for: markedMaterial.id, marking: marking, isMaterial: true)
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: markedMaterial.markings.contains(marking) ? "checkmark.circle.fill" : "circle")
                                                Text(marking.rawValue)
                                            }
                                            .font(.caption)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(markedMaterial.markings.contains(marking) ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1))
                                            .cornerRadius(4)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(8)
                        }
                    }
                }
            }
            .padding()
        }
    }
    
    private func toggleMarking(for id: UUID, marking: FileMarking, isMaterial: Bool) {
        if isMaterial {
            if let index = markedMaterials.firstIndex(where: { $0.id == id }) {
                if markedMaterials[index].markings.contains(marking) {
                    markedMaterials[index].markings.remove(marking)
                } else {
                    markedMaterials[index].markings.insert(marking)
                }
            }
        } else {
            if let index = markedFiles.firstIndex(where: { $0.id == id }) {
                if markedFiles[index].markings.contains(marking) {
                    markedFiles[index].markings.remove(marking)
                } else {
                    markedFiles[index].markings.insert(marking)
                }
            }
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
                    validateAndStartGrading()
                } label: {
                    Label("开始阅卷", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(markedFiles.isEmpty && markedMaterials.isEmpty)
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
            for url in urls {
                let markedFile = MarkedFile(url: url, markings: [], content: nil)
                markedFiles.append(markedFile)
            }
        case .failure(let error):
            appState.errorMessage = error.localizedDescription
            appState.showError = true
        }
    }
    
    private func validateAndStartGrading() {
        var hasUserAnswer = false
        var hasOriginalOrAnswer = false
        
        for markedFile in markedFiles {
            if markedFile.markings.contains(.userAnswer) {
                hasUserAnswer = true
            }
            if markedFile.markings.contains(.originalQuestion) || markedFile.markings.contains(.standardAnswer) {
                hasOriginalOrAnswer = true
            }
        }
        
        for markedMaterial in markedMaterials {
            if markedMaterial.markings.contains(.userAnswer) {
                hasUserAnswer = true
            }
            if markedMaterial.markings.contains(.originalQuestion) || markedMaterial.markings.contains(.standardAnswer) {
                hasOriginalOrAnswer = true
            }
        }
        
        if !hasUserAnswer {
            validationErrorMessage = "请至少标记一个文件为「用户回答」"
            showValidationError = true
            return
        }
        
        if !hasOriginalOrAnswer {
            validationErrorMessage = "请至少标记一个文件为「原题」或「标准答案」"
            showValidationError = true
            return
        }
        
        startGrading()
    }
    
    private func startGrading() {
        isGrading = true
        gradingResult = ""
        
        Task {
            await extractAllTexts()
            
            var userAnswerContent = ""
            var originalQuestionContent = ""
            var standardAnswerContent = ""
            
            for (content, markings) in extractedTexts {
                if markings.contains(.userAnswer) {
                    userAnswerContent += content + "\n\n"
                }
                if markings.contains(.originalQuestion) {
                    originalQuestionContent += content + "\n\n"
                }
                if markings.contains(.standardAnswer) {
                    standardAnswerContent += content + "\n\n"
                }
            }
            
            let hasStandardAnswer = !standardAnswerContent.isEmpty
            
            var prompt = ""
            if hasStandardAnswer {
                prompt = """
                请严格按照以下标准答案批改学生作业。
                
                【标准答案】
                \(standardAnswerContent)
                
                【学生回答】
                \(userAnswerContent)
                
                请按以下格式回复：
                1. 总体评价（按标准答案给分）
                2. 每题得分及详细扣分原因
                3. 正确题目及解析
                4. 错误题目及解析
                5. 改进建议
                
                请用中文回复，使用 Markdown 格式。
                """
            } else {
                prompt = """
                请批改以下作业/试卷，并给出详细的分析和评价。
                
                【原题】
                \(originalQuestionContent)
                
                【学生回答】
                \(userAnswerContent)
                
                请按以下格式回复：
                1. 总体评价
                2. 正确题目及解析
                3. 错误题目及解析
                4. 改进建议
                
                请用中文回复，使用 Markdown 格式。
                """
            }
            
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
        
        for markedFile in markedFiles {
            if let text = await extractTextFromFile(markedFile.url) {
                extractedTexts.append((text, markedFile.markings))
            }
        }
        
        for markedMaterial in markedMaterials {
            let text = markedMaterial.material.extractedText ?? markedMaterial.material.content
            if !text.isEmpty {
                extractedTexts.append((text, markedMaterial.markings))
            }
        }
    }
    
    private func extractTextFromFile(_ url: URL) async -> String? {
        let fileExtension = url.pathExtension.lowercased()
        
        switch fileExtension {
        case "txt", "md", "markdown":
            return try? String(contentsOf: url, encoding: .utf8)
        case "pdf":
            let pdfService = PDFService()
            return pdfService.extractText(from: url)
        case "png", "jpg", "jpeg", "webp", "bmp":
            let text = await OCRService().recognizeText(from: url)
            return text.isEmpty ? nil : text
        case "docx":
            return try? String(contentsOf: url, encoding: .utf8)
        default:
            return nil
        }
    }
    
    private func resetGrading() {
        markedFiles.removeAll()
        markedMaterials.removeAll()
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
    @Binding var markedMaterials: [MarkedMaterial]
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
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: material.type.icon)
                        Text(material.name)
                        Spacer()
                        if markedMaterials.contains(where: { $0.material.id == material.id }) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                    
                    if let marked = markedMaterials.first(where: { $0.material.id == material.id }) {
                        HStack(spacing: 8) {
                            ForEach(FileMarking.allCases) { marking in
                                Button {
                                    toggleMarking(for: material, marking: marking)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: marked.markings.contains(marking) ? "checkmark.circle.fill" : "circle")
                                        Text(marking.rawValue)
                                    }
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(marked.markings.contains(marking) ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1))
                                    .cornerRadius(4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if let index = markedMaterials.firstIndex(where: { $0.material.id == material.id }) {
                        markedMaterials.remove(at: index)
                    } else {
                        markedMaterials.append(MarkedMaterial(material: material, markings: []))
                    }
                }
            }
            
            Button("确认选择") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(width: 450, height: 500)
    }
    
    private func toggleMarking(for material: StudyMaterial, marking: FileMarking) {
        if let index = markedMaterials.firstIndex(where: { $0.material.id == material.id }) {
            if markedMaterials[index].markings.contains(marking) {
                markedMaterials[index].markings.remove(marking)
            } else {
                markedMaterials[index].markings.insert(marking)
            }
        }
    }
}

enum FileMarking: String, CaseIterable, Identifiable {
    case userAnswer = "用户回答"
    case originalQuestion = "原题"
    case standardAnswer = "标准答案"
    
    var id: String { rawValue }
}

struct MarkedFile: Identifiable {
    let id = UUID()
    let url: URL
    var markings: Set<FileMarking>
    var content: String?
    
    var fileName: String {
        url.lastPathComponent
    }
    
    var fileExtension: String {
        url.pathExtension.lowercased()
    }
}

struct MarkedMaterial: Identifiable {
    let id = UUID()
    let material: StudyMaterial
    var markings: Set<FileMarking>
    
    var materialName: String {
        material.name
    }
}
