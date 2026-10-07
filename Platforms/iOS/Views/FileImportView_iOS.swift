import SwiftUI
import UniformTypeIdentifiers

/// iOS 资料导入面板。
///
/// 只负责挑选文件与选择存储方式，真正的解析/OCR/入库由
/// `AppState_iOS.importFiles(_:storageMode:)` → `FileScannerService_iOS` 完成。
struct FileImportView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    @State private var storageMode: MaterialStorageMode = .copy
    @State private var isPicking = false
    @State private var didImport = false

    /// 可导入的类型。与 `FileScannerService_iOS.detectFileType(from:)` 保持一致。
    private static let supportedTypes: [UTType] = [
        .pdf,
        .plainText,
        .image,
        .audiovisualContent,
        .movie,
        .audio,
        .spreadsheet,
        .presentation,
        .content,
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("存储方式") {
                    Picker("文件保存", selection: $storageMode) {
                        ForEach(MaterialStorageMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)

                    Text(storageMode.description)
                        .font(.footnote)
                        .foregroundStyle(appTheme.secondaryText)
                }

                Section {
                    Button {
                        isPicking = true
                    } label: {
                        HStack {
                            Label("选择文件", systemImage: "doc.badge.plus")
                            Spacer()
                            if appState.isScanning {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(appState.isScanning)

                    Button {
                        appState.showCameraScanner = false
                        dismiss()
                    } label: {
                        Label("扫描文稿文件夹", systemImage: "folder.badge.plus")
                    }

                    Button {
                        appState.startDocumentScan()
                        dismiss()
                    } label: {
                        Label("拍照扫描", systemImage: "camera.viewfinder")
                    }

                    Button {
                        appState.startVoiceMemo()
                        dismiss()
                    } label: {
                        Label("语音备忘", systemImage: "waveform")
                    }
                } header: {
                    Text("导入方式")
                } footer: {
                    Text("导入后会立即提取文本，并对图片执行 OCR。")
                }
            }
            .navigationTitle("导入资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .fileImporter(
                isPresented: $isPicking,
                allowedContentTypes: Self.supportedTypes,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    guard !urls.isEmpty else { return }
                    // 直接把 URL 交给 `importFiles`，**不要**在这里碰安全作用域。
                    //
                    // 这里原先用 `urls.filter { ... startAccessing...
                    // defer { stopAccessing... } }` 先「试一下能不能访问」，
                    // 但 `defer` 在 `filter` 的闭包返回时就执行了——也就是说
                    // 访问权在 `importFiles` 被调用**之前**就已经释放，
                    // 随后 `copyItem` 必然失败，表现为「导入没反应 / 全部失败」。
                    //
                    // 正确的位置是真正读文件的地方：`FileScannerService_iOS.processFile`
                    // 里用 `defer` 包住整个处理过程（与 macOS 版一致）。
                    appState.importFiles(urls, storageMode: storageMode)
                    didImport = true
                case .failure(let error):
                    appState.errorMessage = "选择文件失败：\(error.localizedDescription)"
                    appState.showError = true
                }
            }
        }
        .interactiveDismissDisabled(appState.isScanning)
    }
}