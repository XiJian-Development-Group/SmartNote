import SwiftUI

struct CreateMaterialView: View {
    @EnvironmentObject var appState: AppState_macOS
    @Environment(\.dismiss) var dismiss
    @State private var name: String = ""
    @State private var category: MaterialCategory = .other
    @State private var content: String = ""
    @State private var keywordsText: String = ""
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    nameSection
                    categorySection
                    contentSection
                    keywordsSection
                }
                .padding()
            }
            
            Divider()
            
            footerView
        }
        .frame(width: 600, height: 600)
    }
    
    private var headerView: some View {
        HStack {
            Text("新建资料")
                .font(.headline)
            Spacer()
            Button("关闭") {
                dismiss()
            }
        }
        .padding()
    }
    
    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("资料名称", systemImage: "doc.text")
                .font(.headline)
            
            TextField("输入资料名称", text: $name)
                .textFieldStyle(.roundedBorder)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("资料分类", systemImage: "folder")
                .font(.headline)
            
            Picker("分类", selection: $category) {
                ForEach(MaterialCategory.allCases, id: \.self) { cat in
                    Label(cat.rawValue, systemImage: cat.icon)
                        .tag(cat)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("资料内容", systemImage: "text.alignleft")
                    .font(.headline)
                
                Spacer()
                
                Text("\(content.count) 字符")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            TextEditor(text: $content)
                .font(.body)
                .frame(minHeight: 150)
                .border(Color(nsColor: .separatorColor))
            
            Text("在此输入文本内容，支持复制粘贴")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private var keywordsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("考点关键词（可选）", systemImage: "brain.head.profile")
                .font(.headline)
            
            Text("用逗号分隔各个关键词")
                .font(.caption)
                .foregroundColor(.secondary)
            
            TextField("例如: 函数, 极限, 导数", text: $keywordsText)
                .textFieldStyle(.roundedBorder)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private var footerView: some View {
        HStack {
            Button("取消") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            
            Spacer()
            
            Button("创建") {
                createMaterial()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(name.isEmpty)
        }
        .padding()
    }
    
    private func createMaterial() {
        let keywords = keywordsText.isEmpty ? nil : keywordsText
            .components(separatedBy: CharacterSet(charactersIn: ",，"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        let material = StudyMaterial(
            name: name,
            type: .text,
            category: category,
            content: content,
            keywords: keywords
        )
        
        appState.materials.append(material)
        appState.storageService.saveMaterials(appState.materials)
        dismiss()
    }
}
