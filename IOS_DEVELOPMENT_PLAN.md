# SmartNote iOS 版本开发全案

> **策略**：同一 Xcode 项目多 Target（macOS + iOS），共享 `Sources/` 核心业务层，UI 层平台化适配。版本号在 `project.yml` 统一定义，自动同步。
> **目标**：iOS 功能 ⊇ macOS 功能，且在移动端原生能力、触控交互、云同步、系统级集成上全方位更强。macOS 同步补齐系统级集成。

---

## 1. 项目结构重组

```
SmartNote/
├── project.yml                    # ✅ 统一管理 macOS + iOS 双 Target、版本号、依赖
├── SmartNote.xcodeproj/           # XcodeGen 生成
├── Shared/                        # 🆕 完全跨平台共享代码
│   ├── Models/                    # 所有 Model（Codable、Equatable、无平台 API）
│   ├── Services/                  # 纯业务逻辑 Service（无 AppKit/UIKit 依赖）
│   │   ├── StorageService.swift
│   │   ├── CalendarService.swift
│   │   ├── NotificationService.swift
│   │   ├── LLMService.swift
│   │   ├── ...（所有非 UI Service）
│   ├── Utilities/                 # 纯 Swift 工具
│   │   ├── ThumbnailProvider.swift（需抽象协议）
│   │   ├── FlowLayout.swift（改为协议+平台实现）
│   │   ├── Extensions/
│   ├── Resources/                 # 共享资源（JSON、内置素材）
│   │   ├── answer_book.json
│   │   ├── history_catalog.json
│   │   ├── ThemeBackgrounds/
├── Platforms/
│   ├── macOS/
│   │   ├── App/
│   │   │   ├── SmartNoteApp_macOS.swift
│   │   │   ├── AppState_macOS.swift
│   │   │   ├── AppDelegate.swift
│   │   ├── Views/                 # macOS 专用视图（MenuBar、侧栏 NavigationSplitView、窗口管理）
│   │   │   ├── ContentView_macOS.swift
│   │   │   ├── SidebarView_macOS.swift
│   │   │   ├── SettingsView_macOS.swift
│   │   │   ├── Components_macOS/
│   │   ├── Services/              # macOS 专用 Service
│   │   │   ├── LaunchAtLoginService.swift
│   │   │   ├── FileScannerService.swift（NSOpenPanel）
│   │   │   ├── OCRService.swift（Vision + AppKit）
│   │   │   ├── SpeechService.swift（NSSpeechSynthesizer）
│   │   │   ├── KeychainService.swift（macOS API）
│   │   │   ├── UpdateService.swift（Sparkle/自研）
│   │   ├── Resources/
│   │   │   ├── Info.plist
│   │   │   ├── SmartNote.entitlements
│   │   │   ├── Assets.xcassets
│   │   │   ├── AppIcon.icns
│   ├── iOS/
│   │   ├── App/
│   │   │   ├── SmartNoteApp_iOS.swift
│   │   │   ├── AppState_iOS.swift
│   │   │   ├── SceneDelegate.swift（可选）
│   │   ├── Views/                 # iOS 专用视图（TabView、NavigationStack、Widget、Live Activity）
│   │   │   ├── ContentView_iOS.swift
│   │   │   ├── TabBarView.swift
│   │   │   ├── HomeView.swift
│   │   │   ├── SettingsView_iOS.swift
│   │   │   ├── Components_iOS/
│   │   │   ├── Widget/
│   │   │   ├── LiveActivity/
│   │   ├── Services/              # iOS 专用 Service
│   │   │   ├── CameraScannerService.swift
│   │   │   ├── VoiceMemoService.swift
│   │   │   ├── PushNotificationService.swift
│   │   │   ├── iCloudSyncService.swift
│   │   │   ├── ShortcutsProvider.swift
│   │   │   ├── SpotlightIndexer.swift
│   │   │   ├── HapticFeedbackService.swift
│   │   │   ├── FileScannerService.swift（PHPicker/UIDocumentPicker）
│   │   │   ├── OCRService.swift（Vision + UIKit）
│   │   │   ├── SpeechService.swift（AVSpeechSynthesizer）
│   │   │   ├── KeychainService.swift（iOS API）
│   │   │   ├── BackgroundTaskService.swift
│   │   ├── Resources/
│   │   │   ├── Info.plist
│   │   │   ├── SmartNote.entitlements
│   │   │   ├── Assets.xcassets
│   │   │   ├── AppIcon.appiconset
│   │   │   ├── PrivacyInfo.xcprivacy
```

---

## 2. project.yml 双 Target 配置

```yaml
# project.yml 关键片段
options:
  bundleIdPrefix: com.skyc8266
  deploymentTarget:
    macOS: "15.0"
    iOS: "18.0"           # 🆕 iOS 18+，用最新 API（SwiftData、App Intents、Live Activity 等）
  xcodeVersion: "16.0"
  developmentLanguage: zh-Hans

settings:
  base:
    SWIFT_VERSION: "6.0"           # 🆕 Swift 6 严格并发
    MACOSX_DEPLOYMENT_TARGET: "15.0"
    IPHONEOS_DEPLOYMENT_TARGET: "18.0"
    CODE_SIGN_STYLE: Automatic
    ENABLE_HARDENED_RUNTIME: YES
    COMBINE_HIDPI_IMAGES: YES
    # 版本号统一管理
    MARKETING_VERSION: "2.1.0"     # 🆕 统一版本号
    CURRENT_PROJECT_VERSION: "101" # 🆕 统一构建号

targets:
  # ----- macOS Target -----
  SmartNote:
    type: application
    platform: macOS
    sources:
      - path: Shared
      - path: Platforms/macOS
      - path: SmartNote/Resources    # 过渡期复用，后续迁移到 Shared/Resources
    dependencies:
      - package: Markdown
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.skyc8266.smartnote
        INFOPLIST_FILE: Platforms/macOS/Resources/Info.plist
        CODE_SIGN_ENTITLEMENTS: Platforms/macOS/Resources/SmartNote.entitlements
        PRODUCT_NAME: SmartNote
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        GENERATE_INFOPLIST_FILE: NO
        MARKETING_VERSION: "$(MARKETING_VERSION)"
        CURRENT_PROJECT_VERSION: "$(CURRENT_PROJECT_VERSION)"

  # ----- iOS Target -----
  SmartNote-iOS:
    type: application
    platform: iOS
    sources:
      - path: Shared
      - path: Platforms/iOS
    dependencies:
      - package: Markdown
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.skyc8266.smartnote.ios
        INFOPLIST_FILE: Platforms/iOS/Resources/Info.plist
        CODE_SIGN_ENTITLEMENTS: Platforms/iOS/Resources/SmartNote.entitlements
        PRODUCT_NAME: SmartNote
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        GENERATE_INFOPLIST_FILE: NO
        MARKETING_VERSION: "$(MARKETING_VERSION)"
        CURRENT_PROJECT_VERSION: "$(CURRENT_PROJECT_VERSION)"
        # iOS 专用
        TARGETED_DEVICE_FAMILY: "1,2"        # iPhone + iPad
        SUPPORTS_MULTIPLE_WINDOWS: YES       # iPad 多窗口
        APPLICATION_EXTENSION_API_ONLY: NO

  # ----- iOS Widget Extension -----
  SmartNoteWidget:
    type: app-extension
    platform: iOS
    productName: SmartNoteWidget
    bundleId: com.skyc8266.smartnote.ios.widget
    sources:
      - path: Platforms/iOS/Views/Widget
    dependencies:
      - target: SmartNote-iOS
    settings:
      base:
        MARKETING_VERSION: "$(MARKETING_VERSION)"
        CURRENT_PROJECT_VERSION: "$(CURRENT_PROJECT_VERSION)"

  # ----- Live Activity Extension -----
  SmartNoteLiveActivity:
    type: app-extension
    platform: iOS
    productName: SmartNoteLiveActivity
    bundleId: com.skyc8266.smartnote.ios.liveactivity
    sources:
      - path: Platforms/iOS/Views/LiveActivity
    settings:
      base:
        MARKETING_VERSION: "$(MARKETING_VERSION)"
        CURRENT_PROJECT_VERSION: "$(CURRENT_PROJECT_VERSION)"

  # ----- Shared Framework（可选，若需二进制复用）-----
  # SmartNoteCore:
  #   type: framework
  #   platform: [macOS, iOS]
  #   sources:
  #     - path: Shared
```

---

## 3. 版本号同步机制

| 文件/位置 | 管理方式 |
|-----------|----------|
| `project.yml` | **单一真相源**：`MARKETING_VERSION`、`CURRENT_PROJECT_VERSION` |
| 两个 Target 的 `Info.plist` | `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` 占位符 |
| Widget / Live Activity Extension | 继承主 Target 版本号（Xcode 自动同步） |
| `AppState` 运行时读取 | `Bundle.main.infoDictionary?["CFBundleShortVersionString"]` |
| 发布脚本 | 读取 `project.yml` 解析版本号，自动打 Tag、生成 Release Note |

**发布流程**：
```bash
# 1. 修改 project.yml 版本号
# 2. xcodegen generate
# 3. 双 Target 归档
# 4. 同一 Git Tag 对应 macOS + iOS 同版本发布
```

---

## 4. 核心共享层设计原则

### 4.1 完全跨平台的代码
- **Models**：所有 `struct`/`class` 只用 `Foundation`、`SwiftUI`（仅 `Color`/`Image` 等平台无关类型）
- **Services**：纯业务逻辑，依赖协议而非具体平台类型
  - `StorageService`：文件路径抽象为 `AppStorageProvider` 协议
  - `CalendarService`：统一接口，平台实现分离
  - `NotificationService`：统一接口，macOS 用 `NSUserNotification`/UNUserNotificationCenter，iOS 用 `UNUserNotificationCenter` + Push
  - `LLMService`、`P2PService`、`BackupService` 等完全共享

### 4.2 平台抽象协议
```swift
// Shared/Protocols/PlatformAbstractions.swift
protocol AppStorageProvider {
    var appSupportDirectory: URL { get }
    func createDirectoryIfNeeded(_ url: URL) throws
}

protocol ImageProvider {
    associatedtype NativeImage
    func loadImage(named: String) -> NativeImage?
    func saveImage(_ image: NativeImage, named: String) -> URL?
}

protocol SpeechSynthesizer {
    func speak(_ text: String, language: String?)
    func stop()
}

protocol FilePickerService {
    func pickFiles(types: [UTType], allowsMultiple: Bool) async -> [URL]
}

protocol CameraService {
    func capturePhoto() async -> Data?
    func scanDocument() async -> [Data]  // 多页扫描
}
```

### 4.3 平台实现分离
- `Platforms/macOS/Services/` 实现 macOS 协议
- `Platforms/iOS/Services/` 实现 iOS 协议
- `AppState` 通过 `@Environment(\.platformServices)` 注入

---

## 5. iOS 独有「更强功能」详细规划

### 5.1 移动端原生能力

| 功能 | 入口 | 核心技术 | 备注 |
|------|------|----------|------|
| **相机扫描/多页 PDF 生成** | 资料库 → 「扫描文档」 | `VisionKit.VNDocumentCameraViewController` + `PDFKit` | 边缘检测、滤镜增强、自动排序 |
| **拍照 OCR** | 资料详情 → 相机图标 | `Vision.VNRecognizeTextRequest` + 相机 | 实时预览识别区域，支持手写体 |
| **语音笔记/语音转文字** | 资料库 → 「语音笔记」 | `Speech.SFSpeechRecognizer` + `AVFAudioEngine` | 支持离线识别、自动断句、标点预测 |
| **GPS 位置打卡/地理围栏** | 习惯打卡、日记 | `CoreLocation.CLLocationManager` + `CLRegion` | 到达图书馆自动提醒打卡 |
| **推送通知（APNs）** | 全局 | `UserNotifications` + 自建/第三方 Push 服务 | 复习提醒、习惯打卡、纪念日、协作邀请 |
| **Widget 小组件** | 桌面/锁屏 | `WidgetKit` + `TimelineProvider` | 考试倒计时、今日习惯、番茄钟、下一节课 |
| **Live Activity** | 锁屏/灵动岛 | `ActivityKit` | 番茄钟进行中、考试倒计时实时、P2P 传输进度 |
| **Dynamic Island** | iPhone 14 Pro+ | `ActivityKit` + 自定义 UI | 番茄钟、录音、P2P 连接状态 |

### 5.2 触控/手势优先交互

| 交互 | 场景 | 实现 |
|------|------|------|
| **侧滑返回/全屏手势** | 全应用 | `NavigationStack` 原生 + 自定义转场 |
| **长按上下文菜单** | 资料列表、错题卡片、日记 | `.contextMenu` + 预览 |
| **拖拽排序/多选** | 资料库、待办、习惯、卡片 | `onDrag`/`onDrop` + `EditMode` |
| **下拉刷新** | 所有列表 | `.refreshable` |
| **Apple Pencil 手写/批注** | PDF 批注、白板、日记 | `PKCanvasView` + `UIKit` 互操作 |
| **触觉反馈** | 按钮、开关、完成任务、错误 | `UIImpactFeedbackGenerator` / `UISelectionFeedbackGenerator` |
| **横竖屏自适应** | iPad 全场景、iPhone 横屏阅读 | `Size Classes` + `GeometryReader` + 自定义布局 |

### 5.3 云同步与协作（核心差异化）

| 能力 | 方案 | 关键点 |
|------|------|--------|
| **iCloud 文档同步** | `NSUbiquitousKeyValueStore` + `FileManager` + `UIDocument` | 资料、日记、设置、进度自动同步；冲突合并策略（最后写入胜/字段级合并） |
| **CloudKit 私有/共享数据库** | `CloudKit` | 复习计划、错题本、习惯、P2P 身份跨设备同步；支持共享记录区实现协作 |
| **多设备无缝衔接** | `NSUserActivity` + `Handoff` | Mac 写日记 → iPhone 接力继续；iPhone 扫描 → Mac 直接打开 |
| **家庭共享/协作** | `CloudKit` 共享记录区 + `UICloudSharingController` | 共享复习计划、错题本、待办清单给家人/同学 |
| **备份到 iCloud Drive** | `UIDocumentPicker` + `FileProvider` | 一键导出/导入加密备份，支持文件 App 直接访问 |

### 5.4 系统级集成（macOS 同步补齐）

| 集成点 | iOS 实现 | macOS 补齐 |
|--------|----------|------------|
| **App Intents / Siri / Shortcuts** | `AppIntents` 框架：打开页面、新建任务、开始番茄钟、记日记、查询进度 | macOS 同样接入 `AppIntents`，支持 Siri、快捷指令、Spotlight Action |
| **Spotlight 搜索** | `CoreSpotlight` 索引资料、日记、错题、历史文章 | macOS 用 `CSSearchableIndex` 同等索引 |
| **Focus 模式联动** | `FocusFilter` + `AppIntent`：专注模式下只显示番茄钟/白噪音 | macOS Focus Filter API 同步实现 |
| **文件 App 集成** | `FileProvider` / `UIDocumentBrowserViewController` | macOS Finder 同步集成（已通过沙盒文件访问） |
| **通知中心/锁屏** | 交互式通知、关键警报、定时摘要 | macOS 通知中心同等交互 |
| **AirDrop/附近分享** | `UIActivityViewController` + 自定义 Activity | macOS `NSSharingService` |
| **通用链接** | `Associated Domains` + `ASWebAuthenticationSession` | macOS 同域名关联 |

---

## 6. UI 适配策略

### 6.1 导航模式对应

| macOS | iOS / iPadOS |
|-------|--------------|
| `NavigationSplitView` (Sidebar + Detail) | iPhone: `TabView` + `NavigationStack`<br>iPad: `NavigationSplitView` (Sidebar + Detail) + 多窗口 |
| 独立窗口 (`WindowGroup` id) | iPhone: `NavigationStack` push / `.fullScreenCover`<br>iPad: 独立场景 (`WindowGroup` + `SceneDelegate`) |
| MenuBarExtra | Widget / Live Activity / Dynamic Island |

### 6.2 组件对应表

| 组件 | macOS | iOS |
|------|-------|-----|
| 列表 | `List` + `.listStyle(.sidebar)` | `List` + `.listStyle(.insetGrouped)` |
| 表单 | `Form` | `Form` |
| 设置页 | `Settings` Scene + `Form` | `NavigationStack` + `Form` |
| 弹窗 | `.sheet` / `.popover` | `.sheet` / `.popover` / `.alert` / `.confirmationDialog` |
| 工具栏 | `.toolbar` (窗口级) | `.toolbar` (导航栏/底部栏) + `.navigationBarTitleDisplayMode` |
| 搜索 | `.searchable` (Sidebar) | `.searchable` (NavigationStack) |
| 进度指示 | `ProgressView` | `ProgressView` + `ActivityIndicator` |

### 6.3 响应式布局断点

```swift
// Shared/Utilities/ResponsiveLayout.swift
enum LayoutSizeClass {
    case compact      // iPhone 竖屏
    case regular      // iPad / iPhone 横屏 / Mac
    case ultraWide    // iPad Pro 横屏 / Mac 宽窗口
}

struct ResponsiveContainer<Content: View>: View {
    @Environment(\.horizontalSizeClass) var hSize
    @Environment(\.verticalSizeClass) var vSize
    let content: () -> Content
    
    var layout: LayoutSizeClass {
        switch (hSize, vSize) {
        case (.compact, .regular): return .compact
        case (.regular, .regular): return .regular
        case (.regular, .compact): return .ultraWide
        default: return .regular
        }
    }
    
    var body: some View {
        Group {
            switch layout {
            case .compact: content().frame(maxWidth: .infinity)
            case .regular: content().frame(maxWidth: 720).frame(maxWidth: .infinity, alignment: .center)
            case .ultraWide: content().frame(maxWidth: 1024).frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}
```

---

## 7. 数据层迁移与云同步架构

### 7.1 统一数据模型版本控制
- 所有 Model 遵循 `Codable` + `versioned` 字段
- `StorageService.currentSchemaVersion` 统一管理
- iCloud 同步时携带 schema 版本，自动迁移

### 7.2 冲突解决策略
```swift
enum ConflictResolution {
    case lastWriteWins          // 设置、简单字段
    case fieldLevelMerge        // 复杂对象（资料、日记、计划）
    case userChoose             // 关键数据（加密文件、P2P 身份）
    case serverWins             // 共享协作数据
}
```

### 7.3 离线优先 + 后台同步
- 本地 SQLite/Core Data/SwiftData 作为主存储（当前 JSON 方案可保留，后续可迁移 SwiftData）
- `BackgroundTaskService` 定期推送变更到 CloudKit
- 网络恢复时增量同步（基于 `CKRecord` 变更令牌）

---

## 8. macOS 同步补齐系统级集成

| 功能 | 现状 | 补齐方案 |
|------|------|----------|
| **App Intents / Siri / Shortcuts** | 仅 `SmartNoteIntents.swift` 基础支持 | 全面接入 `AppIntents`：所有核心操作暴露为 Intent，支持参数、返回值、后台执行 |
| **Spotlight 索引** | 无 | `CSSearchableIndex` 索引所有可搜索内容（资料、日记、错题、历史文章、许愿） |
| **Focus Filter** | 无 | 实现 `FocusFilter`：专注模式下只显示番茄钟、白噪音、当前复习任务 |
| **通用链接** | 无 | 配置 `Associated Domains`，支持 `smartnote://` 深度链接 |
| **文件 App / Finder 集成** | 基础文件导入导出 | 实现 `FileProvider` 扩展，资料库直接挂载到 Finder/文件 App |

---

## 9. 开发阶段规划

### Phase 0：基础设施（第 1-2 周）
- [ ] `project.yml` 双 Target 配置 + XcodeGen 生成验证
- [ ] 创建 `Shared/` 目录结构，迁移 Models、纯 Services、Utilities
- [ ] 定义平台抽象协议，实现 macOS/iOS 两套实现
- [ ] 版本号同步验证（双 Target 归档版本一致）
- [ ] CI/CD 配置（GitHub Actions 双平台构建测试）

### Phase 1：iOS 核心功能对齐（第 3-6 周）
- [ ] `AppState_iOS` + `SmartNoteApp_iOS` 入口
- [ ] TabBar 导航 + NavigationStack 详情页
- [ ] 资料库：列表、详情、导入（PHPicker/相机扫描）、OCR、批注
- [ ] 学习工具：考点提取、AI 对话、智能阅卷、番茄钟、错题本、背诵卡片
- [ ] 计划：考试倒计时、复习计划、待办、习惯
- [ ] 实用工具：日记、白噪音、许愿、答案之书、纪念日、计算器、重复清理
- [ ] 历史科普：列表、搜索、详情、朗读、收藏
- [ ] 设置页：外观、备份、AI、通用、存储

### Phase 2：iOS 独有强化（第 7-10 周）
- [ ] **相机扫描/多页 PDF/拍照 OCR/语音笔记**
- [ ] **Widget 小组件**（4 尺寸：考试倒计时、习惯、番茄钟、下一任务）
- [ ] **Live Activity + Dynamic Island**（番茄钟、考试倒计时、P2P 传输）
- [ ] **推送通知（APNs）**：复习提醒、习惯打卡、纪念日、协作邀请
- [ ] **Shortcuts / App Intents 全套**：30+ Intent 覆盖所有核心操作
- [ ] **Spotlight 索引**：全内容搜索
- [ ] **Focus Filter**：专注模式界面
- [ ] **Haptic 触觉反馈**：全应用覆盖
- [ ] **Apple Pencil 手写/批注**：PDF、白板、日记
- [ ] **横竖屏/多窗口/iPad 适配**：完整 Size Class 测试

### Phase 3：云同步与协作（第 11-14 周）
- [ ] **iCloud 文档同步**：资料、日记、设置、进度
- [ ] **CloudKit 私有数据库**：复习计划、错题本、习惯、P2P 身份
- [ ] **CloudKit 共享数据库**：共享复习计划、错题本、待办
- [ ] **Handoff/NSUserActivity**：Mac↔iPhone 无缝衔接
- [ ] **备份到 iCloud Drive/文件 App**：加密备份导入导出
- [ ] **冲突解决 UI**：用户可视化选择合并策略

### Phase 4：macOS 系统级集成补齐（第 15-17 周）
- [ ] macOS `AppIntents` 全套对齐 iOS
- [ ] macOS `CSSearchableIndex` Spotlight 索引
- [ ] macOS `FocusFilter` 专注模式
- [ ] macOS 通用链接 `Associated Domains`
- [ ] macOS `FileProvider` 资料库挂载 Finder

### Phase 5：打磨、测试、发布（第 18-20 周）
- [ ] 双平台完整回归测试（功能清单 100% 覆盖）
- [ ] 性能调优：启动速度、内存、电量、滚动帧率
- [ ] 无障碍：VoiceOver、Dynamic Type、高对比度、Voice Control
- [ ] 本地化：中英双语完善（已有基础）
- [ ] TestFlight 内测 + Mac 版本同步发布
- [ ] App Store / Mac App Store 上架准备

---

## 10. 关键技术决策记录（ADR）

| 编号 | 决策 | 理由 | 替代方案 |
|------|------|------|----------|
| ADR-001 | 同一项目多 Target | 版本号绝对同步、共享代码零拷贝、单一仓库管理 | Swift Package 分离（版本号需额外同步） |
| ADR-002 | iOS 18+ / macOS 15+ | Swift 6 严格并发、App Intents、Live Activity、SwiftData、Observation | iOS 17+（需兼容旧 API） |
| ADR-003 | 不用 SwiftData，沿用 JSON + 文件存储 | 现有架构稳定、迁移成本高、JSON 透明易调试、云同步可自行实现 | SwiftData + CloudKit 原生同步（iOS 17+） |
| ADR-004 | Widget / Live Activity 作为 App Extension 独立 Target | 生命周期隔离、内存限制、独立编译 | 内嵌主 App（不可行） |
| ADR-005 | P2P 仅局域网，不走云同步 | 隐私优先、架构解耦 | WebRTC + 信令服务器（未来可选） |
| ADR-006 | 白板功能暂不移植 iOS | 维护中、几何画板重做中 | 同步上线（等重做完成） |

---

## 11. 验收标准

### 功能对齐（iOS ⊇ macOS）
- [ ] `docs/功能清单.md` 所有 84 项在 iOS 逐项通过
- [ ] iOS 独有功能清单 100% 实现（见 5.1-5.4）

### 质量门槛
- [ ] 启动冷启动 < 1.5s（iPhone 15 Pro 基准）
- [ ] 内存峰值 < 300 MB（典型使用场景）
- [ ] 60fps 滚动/动画无掉帧
- [ ] 电量影响：后台同步 < 1%/天
- [ ] 无障碍：VoiceOver 全流程可用、Dynamic Type 全支持
- [ ] 本地化：中英双语无硬编码字符串

### 发布门槛
- [ ] TestFlight 连续 2 周无 Crash / 严重 Bug
- [ ] Mac App Store 版本同版本号同步发布
- [ ] 发布说明自动生成（Git Log + 功能清单对比）

---

## 12. 立即可执行的第一步

1. **修改 `project.yml`** 添加 iOS Target、Widget、Live Activity 配置
2. **运行 `xcodegen generate`** 验证双 Target 编译通过
3. **创建 `Shared/` 目录**，开始迁移 Models/Services
4. **建立平台抽象协议**，拆分 `StorageService` 路径依赖
5. **搭建 iOS 入口**：`SmartNoteApp_iOS.swift` + `AppState_iOS.swift` + `TabBarView`

---

> **下一步**：我将从修改 `project.yml` 开始，逐步落地上述方案。需要我先从哪一步开始？