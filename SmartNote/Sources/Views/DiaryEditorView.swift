import SwiftUI

struct DiaryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var diaryService = DiaryService.shared
    
    var entry: DiaryEntry?
    
    @State private var title: String = ""
    @State private var content: String = ""
    @State private var category: String = "默认"
    @State private var linkedMaterials: [UUID] = []
    @State private var showPreview = false
    @State private var showMaterialPicker = false
    @State private var showCategoryPicker = false
    
    @State private var isNewEntry: Bool = true
    
    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            
            Divider()
            
            editorContent
        }
        .onAppear {
            if let entry = entry {
                isNewEntry = false
                title = entry.title
                content = entry.content
                category = entry.category
                linkedMaterials = entry.linkedMaterialIDs
                
                if entry.isEncrypted, let decrypted = diaryService.decryptEntry(entry) {
                    content = decrypted.content
                }
            }
        }
    }
    
    private var editorHeader: some View {
        HStack(spacing: 12) {
            Button("取消") {
                dismiss()
            }
            .buttonStyle(.bordered)
            
            Spacer()
            
            Text(isNewEntry ? "新建日记" : "编辑日记")
                .font(.headline)
            
            Spacer()
            
            Button {
                showPreview.toggle()
            } label: {
                Image(systemName: showPreview ? "eye.slash" : "eye")
            }
            .buttonStyle(.bordered)
            
            Button {
                saveEntry()
                dismiss()
            } label: {
                Text("保存")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
    
    private var editorContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                TextField("日记标题", text: $title)
                    .font(.title2)
                    .textFieldStyle(.plain)
                
                HStack {
                    Button {
                        showCategoryPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                            Text(category)
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .popover(isPresented: $showCategoryPicker) {
                        categoryPopover
                    }
                    
                    Button {
                        showMaterialPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "link")
                            Text("关联资料")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    
                    Spacer()
                    
                    Text("\(content.count) 字")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            if showPreview {
                ScrollView {
                    MarkdownPreviewView(content: content)
                        .padding()
                }
            } else {
                TextEditor(text: $content)
                    .font(.body)
                    .padding(8)
            }
        }
        .sheet(isPresented: $showMaterialPicker) {
            MaterialPickerView(selectedIDs: $linkedMaterials)
        }
        .popover(isPresented: $showCategoryPicker) {
            categoryPopover
        }
    }
    
    private var categoryPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选择分类")
                .font(.headline)
                .padding()
            
            ForEach(diaryService.categories) { cat in
                Button {
                    category = cat.name
                    showCategoryPicker = false
                } label: {
                    HStack {
                        Circle()
                            .fill(Color(hex: cat.color) ?? .blue)
                            .frame(width: 10, height: 10)
                        Text(cat.name)
                        Spacer()
                        if category == cat.name {
                            Image(systemName: "checkmark")
                        }
                    }
                    .padding(.horizontal)
                }
                .buttonStyle(.plain)
            }
            
            Divider()
            
            Button {
                addNewCategory()
            } label: {
                Label("新建分类", systemImage: "plus")
                    .padding()
            }
            .buttonStyle(.plain)
        }
        .frame(width: 200)
    }
    
    private func saveEntry() {
        let newEntry = DiaryEntry(
            id: entry?.id ?? UUID(),
            title: title,
            content: content,
            category: category,
            createdAt: entry?.createdAt ?? Date(),
            updatedAt: Date(),
            isPinned: entry?.isPinned ?? false,
            linkedMaterialIDs: linkedMaterials,
            isEncrypted: false
        )
        
        if isNewEntry {
            diaryService.addEntry(newEntry)
        } else {
            diaryService.updateEntry(newEntry)
        }
    }
    
    private func addNewCategory() {
        let newCat = DiaryCategory(name: "新分类", color: "#FF\(String(format: "%06X", Int.random(in: 0...999999)))")
        diaryService.addCategory(newCat)
    }
}

struct MaterialPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @Binding var selectedIDs: [UUID]
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("关联资料")
                    .font(.headline)
                Spacer()
                Button("完成") {
                    dismiss()
                }
            }
            .padding()
            
            Divider()
            
            List(appState.materials) { material in
                HStack {
                    Image(systemName: selectedIDs.contains(material.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(selectedIDs.contains(material.id) ? .accentColor : .secondary)
                    
                    Text(material.name)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleSelection(material.id)
                }
            }
        }
        .frame(width: 300, height: 400)
    }
    
    private func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.removeAll { $0 == id }
        } else {
            selectedIDs.append(id)
        }
    }
}

struct MarkdownPreviewView: View {
    let content: String
    
    var body: some View {
        Text(attributedContent)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var attributedContent: AttributedString {
        var result = AttributedString()
        
        let lines = content.components(separatedBy: "\n")
        
        for (index, line) in lines.enumerated() {
            var lineAttr = AttributedString(line)
            
            if line.hasPrefix("# ") {
                lineAttr = AttributedString(String(line.dropFirst(2)))
                lineAttr.font = .title
                lineAttr.font = .title.bold()
            } else if line.hasPrefix("## ") {
                lineAttr = AttributedString(String(line.dropFirst(3)))
                lineAttr.font = .title2.bold()
            } else if line.hasPrefix("### ") {
                lineAttr = AttributedString(String(line.dropFirst(4)))
                lineAttr.font = .headline
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                var bulletAttr = AttributedString("• ")
                bulletAttr.append(lineAttr)
                lineAttr = bulletAttr
            }
            
            if index > 0 {
                result.append(AttributedString("\n"))
            }
            result.append(lineAttr)
        }
        
        return result
    }
}

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        
        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0
        
        self.init(red: r, green: g, blue: b)
    }
}
