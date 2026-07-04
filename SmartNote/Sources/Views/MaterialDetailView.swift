import SwiftUI
import PDFKit
import AppKit

struct MaterialDetailView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State var material: StudyMaterial
    @State private var extractedText: String = ""
    @State private var isProcessingOCR = false
    @State private var isExtractingKeywords = false
    @State private var isEditingCategory = false
    @State private var isEditingKeywords = false
    @State private var isEditingName = false
    @State private var showMarkdownPreview = false
    @State private var editedName: String = ""
    @State private var editedCategory: MaterialCategory = .other
    @State private var editedKeywords: String = ""
    @State private var showExportMenu = false
    @State private var showSaveToast: Bool = false
    @State private var isExporting: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    materialInfoSection
                    contentSection
                    keywordsSection
                }
                .padding()
            }
            
            Divider()
            
            footerView
        }
        .frame(width: 650, height: 750)
        .onAppear {
            extractedText = material.extractedText ?? material.content
            editedCategory = material.category
            editedKeywords = material.keywords?.joined(separator: ", ") ?? ""
        }
    }
    
    private var headerView: some View {
        HStack {
            Image(systemName: material.type.icon)
                .font(.title)
                .foregroundColor(.accentColor)
            
            VStack(alignment: .leading, spacing: 2) {
                if isEditingName {
                    HStack(spacing: 4) {
                        TextField("资料名称", text: $editedName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                            .onSubmit {
                                saveName()
                            }
                        
                        Button {
                            saveName()
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                        .buttonStyle(.plain)
                        
                        Button {
                            isEditingName = false
                            editedName = material.name
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    HStack {
                        Text(material.name)
                            .font(.headline)
                        
                        Button {
                            editedName = material.name
                            isEditingName = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                Text(material.type.rawValue)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Menu {
                Button {
                    exportAsPDF()
                } label: {
                    Label("导出为 PDF", systemImage: "doc.fill")
                }
                .disabled(isExporting)
                
                Button {
                    exportAsText()
                } label: {
                    Label("导出为文本", systemImage: "doc.plaintext")
                }
                .disabled(isExporting)
                
                Divider()
                
                Button {
                    copyToClipboard()
                } label: {
                    Label("复制内容", systemImage: "doc.on.clipboard")
                }
                
                if let url = material.localURL {
                    Divider()
                    
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("打开原文件", systemImage: "arrow.up.forward.app")
                    }
                }
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            
            if isExporting {
                ProgressView()
                    .scaleEffect(0.8)
                    .padding(.leading, 6)
            }
            if material.isFavorite {
                Button {
                    toggleFavorite()
                } label: {
                    Image(systemName: "star.fill")
                        .foregroundColor(.yellow)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .overlay(alignment: .topTrailing) {
            if showSaveToast {
                Text("已保存")
                    .font(.caption)
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                    .shadow(radius: 6)
                    .transition(.scale.combined(with: .opacity))
                    .padding(10)
            }
        }
    }
    
    private var materialInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("资料信息", systemImage: "info.circle")
                    .font(.headline)
                
                Spacer()
                
                Button {
                    isEditingCategory = true
                } label: {
                    Label("编辑分类", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
            }
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                InfoItem(title: "当前分类", value: material.category.rawValue)
                InfoItem(title: "大小", value: material.displayFileSize)
                InfoItem(title: "创建时间", value: material.displayDate)
                InfoItem(title: "关键词数", value: "\(material.keywords?.count ?? 0)")
            }
            
            if let url = material.localURL {
                HStack {
                    Text("文件路径:")
                        .foregroundColor(.secondary)
                    Text(url.path)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Spacer()
                    
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("打开", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.link)
                }
                .padding(.top, 8)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .sheet(isPresented: $isEditingCategory) {
            CategoryEditSheet(material: $material, currentCategory: editedCategory)
                .environmentObject(appState)
        }
    }
    
    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("文档内容", systemImage: "doc.text")
                    .font(.headline)
                
                Spacer()
                
                Text("自动保存")
                    .font(.caption)
                    .foregroundColor(.green)
                
                Toggle("预览", isOn: $showMarkdownPreview)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                
                if !extractedText.isEmpty {
                    speechButtons
                }
                
                if material.type == .image && material.extractedText == nil {
                    Button {
                        performOCR()
                    } label: {
                        if isProcessingOCR {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Label("文字识别", systemImage: "text.viewfinder")
                        }
                    }
                    .disabled(isProcessingOCR)
                }
            }
            
            if showMarkdownPreview && !extractedText.isEmpty {
                ScrollView {
                    MarkdownText(extractedText)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 150)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
            } else {
                TextEditor(text: $extractedText)
                    .font(.body)
                    .frame(minHeight: 150)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(8)
                    .onChange(of: extractedText) { newValue in
                        autoSaveContent(newValue)
                    }
            }
            
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
                Text("\(extractedText.count) 字符")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text("支持 Markdown 格式")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private var speechButtons: some View {
        HStack(spacing: 8) {
            if appState.speechService.isSpeaking {
                Button {
                    appState.speechService.togglePause()
                } label: {
                    Image(systemName: appState.speechService.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                
                Button {
                    appState.speechService.stop()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            
            Button {
                appState.speechService.speak(extractedText)
            } label: {
                Label("朗读", systemImage: "speaker.wave.2.fill")
            }
            .buttonStyle(.bordered)
            
            Button {
                explainWithAI()
            } label: {
                if isProcessingOCR {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Label("AI 讲解", systemImage: "waveform")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isProcessingOCR || extractedText.isEmpty)
        }
    }
    
    private func explainWithAI() {
        guard !extractedText.isEmpty else { return }
        guard appState.llmConfiguration.enabled else {
            appState.errorMessage = "请先在设置中启用 AI 分析功能"
            appState.showError = true
            return
        }
        
        isProcessingOCR = true
        
        Task {
            do {
                let prompt = """
                请用通俗易懂的语言讲解以下内容，可以添加例子帮助理解。讲解要清晰、有条理。
                """
                try await appState.llmService.sendMessageStreaming(system: prompt, user: extractedText) { chunk in
                    Task { @MainActor in
                        self.appState.aiAnalysisResult += chunk
                    }
                }
            } catch {
                await MainActor.run {
                    self.appState.errorMessage = error.localizedDescription
                    self.appState.showError = true
                }
            }
            
            await MainActor.run {
                isProcessingOCR = false
                if !self.appState.aiAnalysisResult.isEmpty {
                    self.appState.speechService.speak(self.appState.aiAnalysisResult)
                }
            }
        }
    }
    
    private func autoSaveContent(_ text: String) {
        if let index = appState.materials.firstIndex(where: { $0.id == material.id }) {
            appState.materials[index].extractedText = text
            appState.materials[index].modifiedAt = Date()
            appState.storageService.saveMaterials(appState.materials)
        }
    }
    
    private var keywordsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("考点关键词", systemImage: "brain.head.profile")
                    .font(.headline)
                
                Spacer()
                
                Button {
                    extractKeywords()
                } label: {
                    if isExtractingKeywords {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Label("重新提取", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isExtractingKeywords || extractedText.isEmpty)
                
                Button {
                    editedKeywords = material.keywords?.joined(separator: ", ") ?? ""
                    isEditingKeywords = true
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
            }
            
            if let keywords = material.keywords, !keywords.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(keywords, id: \.self) { keyword in
                        Text(keyword)
                            .font(.callout)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.accentColor.opacity(0.1))
                            .foregroundColor(.accentColor)
                            .cornerRadius(16)
                    }
                }
            } else {
                Text("点击「提取」分析考点关键词，或点击「编辑」手动添加")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .sheet(isPresented: $isEditingKeywords) {
            KeywordEditSheet(keywords: $editedKeywords) { newKeywords in
                if let index = appState.materials.firstIndex(where: { $0.id == material.id }) {
                    withAnimation(.easeInOut) {
                        appState.materials[index].keywords = newKeywords
                        material = appState.materials[index]
                        appState.storageService.saveMaterials(appState.materials)
                    }
                }
            }
        }
    }
    
    private var footerView: some View {
        HStack {
            Button("关闭") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            
            Spacer()
        }
        .padding()
    }
    
    private func saveName() {
        guard !editedName.isEmpty else { return }
        if let index = appState.materials.firstIndex(where: { $0.id == material.id }) {
            appState.materials[index].name = editedName
            material = appState.materials[index]
            appState.storageService.saveMaterials(appState.materials)
        }
        isEditingName = false
    }
    
    private func toggleFavorite() {
        if let index = appState.materials.firstIndex(where: { $0.id == material.id }) {
            appState.materials[index].isFavorite.toggle()
            material = appState.materials[index]
            appState.storageService.saveMaterials(appState.materials)
        }
    }
    
    private func performOCR() {
        guard let url = material.localURL, material.type == .image else { return }
        isProcessingOCR = true
        
        Task {
            let text = await appState.ocrService.recognizeText(from: url)
            await MainActor.run {
                if let index = appState.materials.firstIndex(where: { $0.id == material.id }) {
                    appState.materials[index].extractedText = text
                    material = appState.materials[index]
                    extractedText = text
                    appState.storageService.saveMaterials(appState.materials)
                }
                isProcessingOCR = false
            }
        }
    }
    
    private func extractKeywords() {
        guard !extractedText.isEmpty else { return }
        
        isExtractingKeywords = true
        
        Task {
            let keywords = appState.keywordService.extractKeywords(from: extractedText)
            await MainActor.run {
                if let index = appState.materials.firstIndex(where: { $0.id == material.id }) {
                    appState.materials[index].keywords = keywords
                    material = appState.materials[index]
                    appState.storageService.saveMaterials(appState.materials)
                }
                isExtractingKeywords = false
            }
        }
    }
    
    private func exportAsPDF() {
        guard !extractedText.isEmpty else { return }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.nameFieldStringValue = "\(material.name).pdf"

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                isExporting = true
                Task {
                    let pdfURL = PDFService.generateSummaryPDF(
                        content: extractedText,
                        title: material.name,
                        subject: material.category.rawValue,
                        keywords: material.keywords ?? []
                    )

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

                    await MainActor.run {
                        isExporting = false
                        withAnimation(.easeOut) { showSaveToast = true }
                        Task { try? await Task.sleep(nanoseconds: 800_000_000); withAnimation(.easeIn) { showSaveToast = false } }
                    }
                }
            }
        }
    }
    
    private func exportAsText() {
        guard !extractedText.isEmpty else { return }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "\(material.name).txt"

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                isExporting = true
                Task {
                    do {
                        try extractedText.write(to: url, atomically: true, encoding: .utf8)
                    } catch {
                        print("Error saving text: \(error)")
                    }
                    await MainActor.run {
                        isExporting = false
                        withAnimation(.easeOut) { showSaveToast = true }
                        Task { try? await Task.sleep(nanoseconds: 800_000_000); withAnimation(.easeIn) { showSaveToast = false } }
                    }
                }
            }
        }
    }
    
    private func copyToClipboard() {
        guard !extractedText.isEmpty else { return }
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(extractedText, forType: .string)
    }
}

struct InfoItem: View {
    let title: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CategoryEditSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @Binding var material: StudyMaterial
    @State var currentCategory: MaterialCategory
    
    var body: some View {
        VStack(spacing: 16) {
            Text("选择分类")
                .font(.headline)
            
            Picker("分类", selection: $currentCategory) {
                ForEach(MaterialCategory.allCases, id: \.self) { category in
                    Label(category.rawValue, systemImage: category.icon)
                        .tag(category)
                }
            }
            .pickerStyle(.radioGroup)
            
            HStack {
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("保存") {
                    if let index = appState.materials.firstIndex(where: { $0.id == material.id }) {
                        appState.materials[index].category = currentCategory
                        material = appState.materials[index]
                        appState.storageService.saveMaterials(appState.materials)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 300)
    }
}

struct TextEditSheet: View {
    @Environment(\.dismiss) var dismiss
    let title: String
    @Binding var content: String
    var onSave: (String) -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.headline)
            
            TextEditor(text: $content)
                .font(.body)
                .frame(minHeight: 200)
                .border(Color(nsColor: .separatorColor))
            
            HStack {
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("保存") {
                    onSave(content)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500, height: 350)
    }
}

struct KeywordEditSheet: View {
    @Environment(\.dismiss) var dismiss
    @Binding var keywords: String
    var onSave: ([String]) -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Text("编辑考点关键词")
                .font(.headline)
            
            Text("请用逗号分隔各个关键词")
                .font(.caption)
                .foregroundColor(.secondary)
            
            TextEditor(text: $keywords)
                .font(.body)
                .frame(minHeight: 150)
                .border(Color(nsColor: .separatorColor))
            
            HStack {
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("保存") {
                    let keywordArray = keywords
                        .components(separatedBy: CharacterSet(charactersIn: ",，"))
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    onSave(keywordArray)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400, height: 300)
    }
}
