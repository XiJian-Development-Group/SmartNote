import SwiftUI
import UniformTypeIdentifiers

struct FileImportView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var selectedURLs: [URL] = []
    @State private var isScanning = false
    @State private var storageMode: MaterialStorageMode = .copy
    @State private var showModeInfo = false
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            Divider()
            
            if isScanning {
                scanningView
            } else {
                VStack(spacing: 16) {
                    dropZoneView
                    modeSelectorView
                }
            }
            
            Divider()
            
            footerView
        }
        .frame(width: 540, height: 480)
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
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 36))
                .foregroundColor(.accentColor)
            
            Text("拖拽文件到此处")
                .font(.headline)
            
            Text("或")
                .foregroundColor(.secondary)
            
            Button("选择文件") {
                selectFiles()
            }
            .buttonStyle(.borderedProminent)
            
            if !selectedURLs.isEmpty {
                Text("已选择 \(selectedURLs.count) 个文件")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
            return true
        }
    }
    
    private var modeSelectorView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("文件处理方式")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Button {
                    showModeInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("了解文件处理方式")
                Spacer()
            }
            
            HStack(spacing: 12) {
                ForEach(MaterialStorageMode.allCases) { mode in
                    StorageModeOption(
                        mode: mode,
                        isSelected: storageMode == mode,
                        onSelect: { storageMode = mode }
                    )
                }
            }
            
            if showModeInfo {
                Text(storageMode.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08))
                    .cornerRadius(6)
            }
            
            if storageMode == .reference {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("关联模式下，原文件移动或删除将导致SmartNote中无法访问")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 12)
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
        appState.importFiles(selectedURLs, storageMode: storageMode)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            isScanning = false
            dismiss()
        }
    }
}

/// 存储模式选项
struct StorageModeOption: View {
    let mode: MaterialStorageMode
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: mode.icon)
                    .font(.title3)
                    .foregroundColor(isSelected ? .white : .accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName)
                        .font(.system(size: 13, weight: .medium))
                    Text(mode == .copy ? "复制到资料库" : "仅创建链接")
                        .font(.system(size: 10))
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.white)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
