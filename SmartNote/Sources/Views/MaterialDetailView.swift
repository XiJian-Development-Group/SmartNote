import SwiftUI

struct MaterialDetailView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State var material: StudyMaterial
    @State private var extractedText: String = ""
    @State private var isProcessingOCR = false
    @State private var isExtractingKeywords = false
    
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
        .frame(width: 600, height: 700)
    }
    
    private var headerView: some View {
        HStack {
            Image(systemName: material.type.icon)
                .font(.title)
                .foregroundColor(.accentColor)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(material.name)
                    .font(.headline)
                Text(material.type.rawValue)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
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
    }
    
    private var materialInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("资料信息", systemImage: "info.circle")
                .font(.headline)
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                InfoItem(title: "分类", value: material.category.rawValue)
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
    }
    
    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("文档内容", systemImage: "doc.text")
                    .font(.headline)
                
                Spacer()
                
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
            
            if let text = material.extractedText ?? (material.content.isEmpty ? nil : material.content) {
                Text(text)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(8)
                    .textSelection(.enabled)
            } else {
                Text("暂无文本内容")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
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
                .disabled(isExtractingKeywords || (material.extractedText?.isEmpty ?? true) && material.content.isEmpty)
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
                Text("点击「提取」分析考点关键词")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
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
                    appState.storageService.saveMaterials(appState.materials)
                }
                isProcessingOCR = false
            }
        }
    }
    
    private func extractKeywords() {
        let text = material.extractedText ?? material.content
        guard !text.isEmpty else { return }
        
        isExtractingKeywords = true
        
        Task {
            let keywords = appState.keywordService.extractKeywords(from: text)
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

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(
            in: proposal.replacingUnspecifiedDimensions().width,
            subviews: subviews,
            spacing: spacing
        )
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(
            in: bounds.width,
            subviews: subviews,
            spacing: spacing
        )
        
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                       y: bounds.minY + result.positions[index].y),
                          proposal: .unspecified)
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                
                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                
                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
            }
            
            self.size = CGSize(width: maxWidth, height: y + rowHeight)
        }
    }
}
