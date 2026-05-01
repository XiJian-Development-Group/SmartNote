import SwiftUI
import UniformTypeIdentifiers

struct FileImportView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var selectedURLs: [URL] = []
    @State private var isScanning = false
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            Divider()
            
            if isScanning {
                scanningView
            } else {
                dropZoneView
            }
            
            Divider()
            
            footerView
        }
        .frame(width: 500, height: 400)
    }
    
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("导入学习资料")
                    .font(.headline)
                Text("支持 PDF、Word、PPT、图片、文本等格式")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
    }
    
    private var scanningView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text("正在扫描文件...")
                .font(.headline)
            Text("请稍候")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
    }
    
    private var dropZoneView: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)
            
            Text("拖拽文件到此处")
                .font(.headline)
            
            Text("或")
                .foregroundColor(.secondary)
            
            Button("选择文件") {
                selectFiles()
            }
            .buttonStyle(.borderedProminent)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
            return true
        }
    }
    
    private var footerView: some View {
        HStack {
            Button("取消") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            
            Spacer()
            
            Button("导入") {
                importFiles()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedURLs.isEmpty)
        }
        .padding()
    }
    
    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            UTType.pdf,
            UTType.data,
            UTType.image,
            UTType.plainText
        ]
        
        if panel.runModal() == .OK {
            selectedURLs = panel.urls
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    DispatchQueue.main.async {
                        selectedURLs.append(url)
                    }
                }
            }
        }
    }
    
    private func importFiles() {
        guard !selectedURLs.isEmpty else { return }
        
        isScanning = true
        appState.importFiles(selectedURLs)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            isScanning = false
            dismiss()
        }
    }
}
