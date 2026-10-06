import SwiftUI
import UserNotifications
import PhotosUI

struct SettingsView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = false

    var body: some View {
        NavigationStack {
            List {
                // 外观
                Section("外观") {
                    Picker("主题", selection: Binding(
                        get: { appState.activeThemeID },
                        set: { appState.setTheme($0) }
                    )) {
                        ForEach(AppSettings.ThemeID.allCases) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }

                    if appState.activeThemeID == .classic {
                        Picker("深色模式", selection: Binding(
                            get: { appState.activeDarkModePreference },
                            set: { appState.setDarkModePreference($0) }
                        )) {
                            ForEach(AppSettings.DarkModePreference.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                    }

                    Toggle("背景图片", isOn: Binding(
                        get: { appState.appSettings.backgroundImageEnabled },
                        set: { appState.appSettings.backgroundImageEnabled = $0; appState.storageService.saveSettings(appState.appSettings) }
                    ))

                    if appState.appSettings.backgroundImageEnabled && !appState.isBackgroundLockedByTheme {
                        Toggle("随机轮换", isOn: Binding(
                            get: { appState.appSettings.backgroundImageRandomEnabled },
                            set: { appState.setBackgroundImageRandomEnabled($0) }
                        ))

                        NavigationLink("管理背景图片") {
                            BackgroundImageManagerView()
                                .environmentObject(appState)
                        }
                    }

                    if appState.isBackgroundLockedByTheme {
                        Label("当前主题锁定背景：\(appState.lockedBundledBackgroundName ?? "")", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(appTheme.secondaryText)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("背景模糊半径")
                            Spacer()
                            Text("\(Int(appState.appSettings.backgroundBlurRadius))")
                                .foregroundStyle(appTheme.secondaryText)
                        }
                        Slider(value: Binding(
                            get: { appState.appSettings.backgroundBlurRadius },
                            set: { appState.appSettings.backgroundBlurRadius = $0; appState.storageService.saveSettings(appState.appSettings) }
                        ), in: 0...50)

                        HStack {
                            Text("背景透明度")
                            Spacer()
                            Text("\(Int(appState.appSettings.backgroundOpacity * 100))%")
                                .foregroundStyle(appTheme.secondaryText)
                        }
                        Slider(value: Binding(
                            get: { appState.appSettings.backgroundOpacity },
                            set: { appState.appSettings.backgroundOpacity = $0; appState.storageService.saveSettings(appState.appSettings) }
                        ), in: 0...1)
                    }
                }

                // 通用
                Section("通用") {
                    Toggle("日历集成", isOn: Binding(
                        get: { appState.appSettings.calendarIntegrationEnabled },
                        set: { appState.appSettings.calendarIntegrationEnabled = $0; appState.storageService.saveSettings(appState.appSettings) }
                    ))

                    Toggle("提醒事项集成", isOn: Binding(
                        get: { appState.appSettings.reminderEnabled },
                        set: { appState.appSettings.reminderEnabled = $0; appState.storageService.saveSettings(appState.appSettings) }
                    ))

                    Stepper("番茄钟专注时长：\(appState.appSettings.pomodoroWorkDuration) 分钟", value: Binding(
                        get: { appState.appSettings.pomodoroWorkDuration },
                        set: { appState.appSettings.pomodoroWorkDuration = $0; appState.storageService.saveSettings(appState.appSettings) }
                    ), in: 1...120)

                    Stepper("番茄钟休息时长：\(appState.appSettings.pomodoroBreakDuration) 分钟", value: Binding(
                        get: { appState.appSettings.pomodoroBreakDuration },
                        set: { appState.appSettings.pomodoroBreakDuration = $0; appState.storageService.saveSettings(appState.appSettings) }
                    ), in: 1...60)
                }

                // iCloud 同步
                //
                // iCloud 能力仅在付费 Apple Developer Program 下可用；个人账号的
                // 描述文件里没有这项能力，此时整块隐藏，而不是显示一个必然报错的开关。
                if appState.isCloudKitAvailable {
                    Section("iCloud 同步") {
                        Toggle("启用 iCloud 同步", isOn: $iCloudSyncEnabled)
                            .onChange(of: iCloudSyncEnabled) { _, newValue in
                                appState.toggleICloudSync(newValue)
                            }

                        if iCloudSyncEnabled {
                            HStack {
                                Text("同步状态")
                                Spacer()
                                switch appState.syncStatus {
                                case .idle: Text("待同步").foregroundStyle(appTheme.secondaryText)
                                case .syncing: ProgressView().controlSize(.small)
                                case .success(let date): Text("已同步 \(date, style: .relative)").foregroundStyle(.green)
                                case .failed(let error): Text("失败：\(error.localizedDescription)").foregroundStyle(.red)
                                }
                            }

                            Button("立即同步") {
                                Task { await appState.performICloudSync() }
                            }
                            .disabled(appState.syncStatus == .syncing)

                            Button("从 iCloud 拉取") {
                                Task { await appState.pullFromICloud() }
                            }
                            .disabled(appState.syncStatus == .syncing)
                        }
                    }
                }

                // AI 设置
                Section("AI 分析") {
                    Toggle("启用 AI 分析", isOn: Binding(
                        get: { appState.appSettings.llmConfiguration.enabled },
                        set: { appState.appSettings.llmConfiguration.enabled = $0; appState.storageService.saveSettings(appState.appSettings) }
                    ))

                    if appState.appSettings.llmConfiguration.enabled {
                        // `baseURL` 是按 provider 推导的只读属性（会给空值补默认地址），
                        // 因此输入框绑定的是真正可写的 `serverURL`。
                        TextField("API Base URL", text: Binding(
                            get: { appState.appSettings.llmConfiguration.serverURL },
                            set: {
                                appState.appSettings.llmConfiguration.serverURL = $0
                                appState.storageService.saveSettings(appState.appSettings)
                            }
                        ))
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)

                        SecureField("API Key", text: Binding(
                            get: { appState.appSettings.llmConfiguration.apiKey },
                            set: { appState.appSettings.llmConfiguration.apiKey = $0; appState.storageService.saveSettings(appState.appSettings) }
                        ))

                        TextField("模型名称", text: Binding(
                            get: { appState.appSettings.llmConfiguration.modelID },
                            set: { appState.appSettings.llmConfiguration.modelID = $0; appState.storageService.saveSettings(appState.appSettings) }
                        ))

                        Stepper("Temperature: \(appState.appSettings.llmConfiguration.temperature, specifier: "%.2f")", value: Binding(
                            get: { appState.appSettings.llmConfiguration.temperature },
                            set: { appState.appSettings.llmConfiguration.temperature = $0; appState.storageService.saveSettings(appState.appSettings) }
                        ), in: 0...2, step: 0.1)
                    }
                }

                // 通知
                Section("通知") {
                    NavigationLink("通知权限设置") {
                        NotificationSettingsView()
                    }

                    Toggle("复习提醒", isOn: .constant(true))
                    Toggle("习惯打卡提醒", isOn: .constant(true))
                    Toggle("纪念日提醒", isOn: .constant(true))
                }

                // 数据管理
                Section("数据管理") {
                    NavigationLink("备份与恢复") {
                        BackupRestoreView_iOS()
                            .environmentObject(appState)
                    }

                    NavigationLink("存储空间") {
                        StorageView_iOS()
                            .environmentObject(appState)
                    }

                    Button(role: .destructive) {
                        // 清除所有数据确认
                    } label: {
                        Text("清除所有数据")
                    }
                }

                // 关于
                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.1.0")
                            .foregroundStyle(appTheme.secondaryText)
                    }
                    HStack {
                        Text("构建号")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "101")
                            .foregroundStyle(appTheme.secondaryText)
                    }

                    Link("隐私政策", destination: URL(string: "https://smartnote.app/privacy")!)
                    Link("用户协议", destination: URL(string: "https://smartnote.app/terms")!)
                    Link("GitHub", destination: URL(string: "https://github.com/XiJian-Development-Group/SmartNote")!)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

// 通知设置视图
struct NotificationSettingsView: View {
    @Environment(\.appTheme) private var appTheme
    @State private var notificationSettings: UNNotificationSettings?

    var body: some View {
        Form {
            Section("系统权限") {
                HStack {
                    Text("通知权限")
                    Spacer()
                    Text(permissionText)
                        .foregroundStyle(permissionColor)
                }

                if notificationSettings?.authorizationStatus != .authorized {
                    Button("前往设置开启") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Section("通知类型") {
                Toggle("横幅", isOn: .constant(true))
                Toggle("声音", isOn: .constant(true))
                Toggle("角标", isOn: .constant(true))
                Toggle("锁屏显示", isOn: .constant(true))
            }

            Section("通知分类") {
                ForEach(NotificationCategory.allCases) { category in
                    Toggle(category.displayName, isOn: .constant(true))
                }
            }
        }
        .navigationTitle("通知设置")
        .onAppear { loadSettings() }
    }

    private var permissionText: String {
        switch notificationSettings?.authorizationStatus {
        case .authorized: return "已开启"
        case .denied: return "已拒绝"
        case .notDetermined: return "未确定"
        case .provisional: return "临时授权"
        case .ephemeral: return "临时授权"
        @unknown default: return "未知"
        }
    }

    private var permissionColor: Color {
        switch notificationSettings?.authorizationStatus {
        case .authorized: return .green
        case .denied: return .red
        default: return .orange
        }
    }

    private func loadSettings() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in self.notificationSettings = settings }
        }
    }
}

enum NotificationCategory: String, CaseIterable, Identifiable {
    case review = "review"
    case habit = "habit"
    case anniversary = "anniversary"
    case pomodoro = "pomodoro"
    case todo = "todo"
    case social = "social"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .review: return "复习提醒"
        case .habit: return "习惯打卡"
        case .anniversary: return "纪念日"
        case .pomodoro: return "番茄钟"
        case .todo: return "待办事项"
        case .social: return "社交消息"
        }
    }
}

// 备份恢复视图
struct BackupRestoreView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme
    @State private var showBackupSuccess = false
    @State private var showRestoreConfirm = false
    /// 备份生成后交给系统分享面板保存，避免强绑 iCloud Drive。
    @State private var shareURL: URL?
    @State private var showsShareSheet = false
    @State private var isPickingBackup = false
    @State private var selectedBackupURL: URL?

    var body: some View {
        Form {
            Section("备份") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("备份文件未加密，请勿上传至公共网盘")
                            .font(.caption)
                            .foregroundStyle(appTheme.secondaryText)
                    }

                    Button("立即备份") {
                        Task {
                            // 用 Shared 的 `BackupService` 生成本地 ZIP 备份，
                            // 再交给系统分享面板保存到「文件」/ 任意目标位置。
                            //
                            // 这里不用 iCloud Drive：iCloud 能力需要付费开发者账号，
                            // 个人账号的描述文件里没有该项能力（见 project.yml 注释）。
                            // 走系统分享面板反而更通用，也不依赖任何额外 entitlement。
                            do {
                                let backupURL = try appState.backupService.makeBackup()
                                shareURL = backupURL
                                showsShareSheet = true
                                showBackupSuccess = true
                            } catch {
                                appState.errorMessage = "备份失败：\(error.localizedDescription)"
                                appState.showError = true
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)

                    Text("备份会生成一个 ZIP 文件，可保存到「文件」或任意位置。")
                        .font(.caption)
                        .foregroundStyle(appTheme.secondaryText)
                }
            }

            Section("恢复") {
                Button("从备份文件恢复") {
                    // 选文件 → 二次确认 → 执行恢复。
                    // 确认放在选完之后，避免用户误点就立刻覆盖数据。
                    isPickingBackup = true
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .foregroundStyle(.blue)

                Text("恢复将覆盖当前所有数据，操作不可撤销")
                    .font(.caption)
                    .foregroundStyle(appTheme.secondaryText)
            }
            .fileImporter(
                isPresented: $isPickingBackup,
                allowedContentTypes: [.zip],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    selectedBackupURL = urls.first
                    showRestoreConfirm = true
                case .failure(let error):
                    appState.errorMessage = "选择备份失败：\(error.localizedDescription)"
                    appState.showError = true
                }
            }

            Section("导出/导入") {
                Button("导出数据文件") {
                    // 分享导出
                }
                .buttonStyle(.bordered)

                Button("导入数据文件") {
                    appState.showFileImporter = true
                }
                .buttonStyle(.bordered)
            }
        }
        .navigationTitle("备份与恢复")
        // 系统分享面板：把生成的 ZIP 交给用户自选保存位置。
        .sheet(isPresented: $showsShareSheet) {
            if let shareURL {
                ShareSheet_iOS(items: [shareURL])
            }
        }
        .alert("备份成功", isPresented: $showBackupSuccess) {
            Button("确定") {}
        } message: {
            Text("备份文件已生成，可在分享面板中选择保存位置。")
        }
        .confirmationDialog("确认恢复", isPresented: $showRestoreConfirm, titleVisibility: .visible) {
            Button("恢复", role: .destructive) {
                restoreFromSelectedBackup()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这将覆盖所有当前数据，确定要继续吗？")
        }
    }

    /// 执行恢复：先解压校验，再原子替换数据目录，最后重新载入内存中的数据。
    ///
    /// 顺序很关键——`replaceDataDirectory` 之前必须让 `extractBackup` 验证过目录结构，
    /// 否则可能用坏备份覆盖好数据。替换完成后再 `reloadAfterRestore()`，
    /// 否则界面仍在展示恢复前的旧内容。
    private func restoreFromSelectedBackup() {
        guard let backupURL = selectedBackupURL else { return }
        selectedBackupURL = nil

        do {
            let restoredDirectory = try appState.backupService.extractBackup(backupURL)
            try appState.backupService.replaceDataDirectory(withExtractedBackupAt: restoredDirectory)
            appState.reloadAfterRestore()
            showBackupSuccess = true
        } catch {
            appState.errorMessage = "恢复失败：\(error.localizedDescription)"
            appState.showError = true
        }
    }
}

/// `UIActivityViewController` 的 SwiftUI 包装，用于把备份文件交回给用户保存。
struct ShareSheet_iOS: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private extension DateFormatter {
    static let backupString: String = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }()
}

// 存储视图
struct StorageView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme
    @State private var storageSize: Int64 = 0

    var body: some View {
        Form {
            Section("存储占用") {
                HStack {
                    Text("总大小")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: storageSize, countStyle: .file))
                        .foregroundStyle(appTheme.secondaryText)
                }

                StorageCategoryRow(name: "资料文件", size: 0, icon: "folder.fill", color: .blue)
                StorageCategoryRow(name: "数据库", size: 0, icon: "cylinder.fill", color: .green)
                StorageCategoryRow(name: "缓存", size: 0, icon: "externaldrive.fill", color: .orange)
                StorageCategoryRow(name: "备份", size: 0, icon: "archivebox.fill", color: .purple)
            }

            Section {
                Button(role: .destructive) {
                    // 清除缓存
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("清理缓存")
                    }
                }
            }
        }
        .navigationTitle("存储空间")
        .onAppear {
            storageSize = appState.storageService.getStorageSize()
        }
    }
}

struct StorageCategoryRow: View {
    @Environment(\.appTheme) private var appTheme
    let name: String
    let size: Int64
    let icon: String
    let color: Color

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 24)
            Text(name)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                .foregroundStyle(appTheme.secondaryText)
        }
    }
}

// 背景图片管理
struct BackgroundImageManagerView: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme
    @Environment(\.dismiss) private var dismiss
    @State private var showImagePicker = false

    var body: some View {
        List {
            Section("当前背景") {
                if let activeName = appState.appSettings.backgroundImageActiveName,
                   let imageData = appState.storageService.loadBackgroundImage(named: activeName),
                   let uiImage = UIImage(data: imageData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .listRowInsets(EdgeInsets())
                } else {
                    Text("无背景图片")
                        .foregroundStyle(appTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                }
            }

            Section("图片库") {
                ForEach(appState.appSettings.backgroundImageLibrary, id: \.self) { name in
                    BackgroundImageRow(
                        name: name,
                        isActive: name == appState.appSettings.backgroundImageActiveName,
                        isBundled: StorageService.isBundledBackground(name),
                        onSelect: { appState.selectBackgroundImage(name) },
                        onDelete: { appState.removeBackgroundImage(name) }
                    )
                }
                .onMove { indices, newOffset in
                    var library = appState.appSettings.backgroundImageLibrary
                    library.move(fromOffsets: indices, toOffset: newOffset)
                    appState.appSettings.backgroundImageLibrary = library
                    appState.storageService.saveSettings(appState.appSettings)
                }
            }

            Section {
                Button {
                    showImagePicker = true
                } label: {
                    Label("添加图片", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.borderedProminent)

                if !appState.isBackgroundLockedByTheme {
                    Button(role: .destructive) {
                        appState.clearUserBackgroundLibrary()
                    } label: {
                        Text("清空用户图片库")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
        .navigationTitle("背景图片管理")
        .toolbar { EditButton() }
        .sheet(isPresented: $showImagePicker) {
            ImagePickerView { image in
                // 保存图片并添加到库
                if let data = image.jpegData(compressionQuality: 0.8) {
                    let fileName = "bg_\(UUID().uuidString).jpg"
                    if appState.storageService.saveBackgroundImage(data, fileName: fileName) != nil {
                        _ = appState.addBackgroundImage(fileName)
                    }
                }
            } onCancel: {
                // 用户直接关闭选择器：不改动背景库。
            }
            .ignoresSafeArea()
        }
    }
}

struct BackgroundImageRow: View {
    @Environment(\.appTheme) private var appTheme
    let name: String
    let isActive: Bool
    let isBundled: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            if let data = StorageService.shared.loadBackgroundImage(named: name),
               let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading) {
                Text(name)
                    .font(.subheadline)
                HStack {
                    if isActive {
                        Label("当前", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    if isBundled {
                        Label("内置", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(appTheme.accent)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .swipeActions(edge: .trailing) {
            if !isBundled {
                Button(role: .destructive) { onDelete() } label: { Label("删除", systemImage: "trash") }
            }
        }
    }
}

// ImagePicker 封装
/// 从相册选一张图片。
///
/// 用 `PHPickerViewController`（PhotosUI）而不是 `UIImagePickerController`：
/// 前者不要求相册访问权限，也不会让 App 因未授权而无法使用。
struct ImagePickerView: UIViewControllerRepresentable {
    let onImagePicked: (UIImage) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ImagePickerView
        init(_ parent: ImagePickerView) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else {
                parent.onCancel()
                return
            }
            provider.loadObject(ofClass: UIImage.self) { image, _ in
                if let image = image as? UIImage {
                    Task { @MainActor in self.parent.onImagePicked(image) }
                }
            }
        }
    }
}

// `StorageService.shared` 与 `loadBackgroundImage(named:)` 都已由
// Shared/Services/StorageService.swift 提供，此处不再重复声明。