# SmartNote 潜在问题清单

> 本文件由 Mavis 在 2026-09-26 一次性扫描生成，已分清"故意保留的边界（见 `docs/notes.md` 第 22 章）"与"实际可被修掉的问题"。提交给 OpenCode 修复时，请优先 P0 / P1，P2 / P3 是用户已知的边界或低优先级。
>
> 章节顺序与项目 `docs/notes.md` 的 P0/P1/P2/P3 严重性档对齐。每条问题给出：文件位置 + 行号 + 现状描述 + 修复方向（不替 OpenCode 写实现）。

---

## 0. 用户视角看到的不合理处（先看这章）

这部分是"假如我是用户"发现的明显 UX / 一致性问题，OpenCode 修复优先级最高。

### U-1. Siri "打开许愿"实际打不开
- 位置：`SmartNote/Sources/Services/SmartNoteIntents.swift:79-82`
- 现状：`OpenWishIntent.perform()` 把 `selectedTab = 24` 然后返回 "已打开许愿"。
- 实际：`ContentView.swift:273-278` 中"许愿"用的是 `openWindow(id: "wish-fullscreen")`，**不是 NavigationLink**；侧栏里没有 `value: 24` 的项目。
- 后果：Siri/Shortcut 触发"智学笔记许愿"后什么都没发生，对话框仍说"已打开"。
- 修复方向：`OpenWishIntent` 应该用 `OpenPageIntent` 同款的 `OpenWindowAction` 唤起 `wish-fullscreen` 窗口，或在 `AppState` 中新增 `openWishWindow: Bool` 状态由 `ContentView` 监听并触发 openWindow。

### U-2. Siri "打开白板"实际打不开，但 Intent 撒谎
- 位置：`SmartNote/Sources/Services/SmartNoteIntents.swift:60-66`
- 现状：`OpenWhiteboardIntent` 设置 `selectedTab = 19`，并返回 "已打开白板"。
- 实际：`ContentView.swift:217-220` 中 `NavigationLink(value: 19)` 是 `.disabled(true)`（白板维护中，见 `WhiteBoardView.swift` 的 "维护中"占位页）。
- 后果：Intent 描述与 UI 状态脱节，朗读反馈误导用户。
- 修复方向：把 `OpenWhiteboardIntent` 改成"未开放" 类型的 intent（`static var openAppWhenRun = false`，返回对话框"白板功能维护中，请关注更新"）。

### U-3. Cmd+Shift+R / Cmd+Shift+K 仍写裸数字 tab ID
- 位置：`SmartNote/Sources/App/SmartNoteApp.swift:48-56`
- 现状：`Button("开始复习计划") { appState.selectedTab = 2 }` 和 `Button("提取考点") { appState.selectedTab = 1 }`，与 `SmartNoteIntents.swift` 的 10/20/19/22/24/25 一起构成"魔法数字"。
- 后果：侧栏顺序调整后会失效；与 `notes.md` 17 章自承的"侧栏顺序变化时容易失效"完全对应。
- 修复方向：定义 `enum SidebarTab: Int { case ... }`，把 `selectedTab` 类型改成 `SidebarTab?`，ContentView 的 NavigationLink、AppState、SmartNoteIntents 全部走枚举。

### U-4. 「白板暂时关闭」入口还显示，但点了没反应
- 位置：`SmartNote/Sources/Views/ContentView.swift:217-220`
- 现状：白板仍在「学习」分组中占位，但 `.disabled(true)`；点击没有视觉反馈。
- 修复方向：要么把入口完全隐藏（直到重做上线），要么点击后打开 `WhiteBoardView` 的"维护中"页而不是 silent disable。

### U-5. "默认学习时长" 设置项是死字段
- 位置：`SettingsView.swift:212-213`、`StorageService.swift:1035` (`@Published var defaultStudyMinutes`)
- 现状：UI 提供 Stepper 调节并持久化，但全工程 `grep` 不到任何代码读取它（只在 settings 的 == 编码/解码里出现）。
- 后果：用户改这个值没有任何效果，调试时找不到消费方会以为漏接。
- 修复方向：要么接到 `PomodoroTimer.start()` 默认时长（替换 `pomodoroWorkDuration` 入口），要么从 UI 移除并标"暂未启用"。

### U-6. 纪念日通知都是"立即触发"而非按日期
- 位置：`SmartNote/Sources/Services/AnniversaryService.swift:170`
- 现状：`UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)`——所有命中 `shouldNotify` 的纪念日都会在 1 秒后**同时**弹出通知，与 `leadTimeDays` / `nextOccurrence` 完全脱钩。
- 后果：用户点了"检查通知"会同时收到 3、4 条"今天/明天/后天"的通知，而不是按真正的提醒时间。
- 修复方向：用 `UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: item.nextOccurrence(after: today)), repeats: false)`；再决定触发时间是固定 9:00 还是与现有纪念日时间对齐。

### U-7. 通知点击无法路由到 App 内具体页面
- 位置：全工程（`grep UNUserNotificationCenterDelegate` 无结果）。
- 现状：纪念日通知 `userInfo` 带了 `anniversaryID` / `occurrenceDate`，但工程没有实现 `UNUserNotificationCenterDelegate`，点击通知只能打开主窗口，不会跳到详情。
- 修复方向：在 `SmartNoteApp.init()` 注册 `UNUserNotificationCenter.current().delegate` 实现 `didReceive`，按 `userInfo["kind"]` 分发到 `selectedTab` 或 openWindow。

### U-8. 「清除所有数据」无二次确认
- 位置：`SmartNote/Sources/Views/SettingsView.swift:946-950` (`clearAllData`)
- 现状：`StorageService.clearAllData()` 会删除整个 Application Support 目录、`.corrupted-*`、所有受管 JSON、所有受管 Keychain 条目；UI 调用前**没有** confirmationDialog。
- 后果：一次误操作（或者脚本误触）会把所有资料/日记/进度/Keychain 凭据一并抹掉，无法恢复。
- 修复方向：包一个 `confirmationDialog("清除所有数据将删除资料、复习计划、日记、进度、API key，且无法恢复。继续？", isPresented:)`，并要求输入"清除"两个汉字或倒计时 5 秒。

### U-9. NSColor 在 Vision OCR 的 actor 闭包里使用
- 位置：`SmartNote/Sources/Services/OCRService.swift:79`
- 现状：`actor OCRService` 的 `recognizeTextFromPDF` 里用 `NSColor.white.cgColor`，但 OCRService 是 actor，`NSColor` 的访问在 Swift 6 Concurrency 下会触发 warning（NSColor 不是 Sendable）。
- 后果：未来 Swift 6 strict concurrency 下会编译失败；当前 Swift 5.9 编译能过但埋了坑。
- 修复方向：替换为 `CGColor(red: 1, green: 1, blue: 1, alpha: 1)`，或者用 `CGColorCreateNamed` 直接拿白色。

### U-10. SpeechService 默认中文 voice "Ting-Ting" 在不少 macOS 上不存在
- 位置：`SmartNote/Sources/Services/SpeechService.swift:11,26-27`
- 现状：`currentVoice = "Ting-Ting"`；`synthesizer = NSSpeechSynthesizer(voice: VoiceName(rawValue: "Ting-Ting"))`——若不存在则返回 nil（doc 没明确行为，但实际是 nil），后续 `speak()` 完全没声音。
- 后果：用户在只装了英文 voice 的 macOS 上点朗读，UI 没错误反馈，看起来"点了没反应"。
- 修复方向：`init` 中先 `loadAvailableVoices()`，若 `Ting-Ting` 不在则降级到 `getDefaultChineseVoice()` 或 `NSSpeechSynthesizer.defaultVoice`，并把 `lastError`（仿照 AmbientSoundService 的做法）暴露给 UI。

### U-11. SpeechService 单例导致多个详情页朗读相互打断
- 位置：`SpeechService.swift`（`static let shared = SpeechService()`）+ `HistoryArticleDetailView.swift` 多处直接引用
- 现状：单例 `SpeechService.shared`，离开详情页调 `stop()`，但若用户开了两个详情页、或一边朗读一边通知来了，都会冲突。
- 修复方向：考虑按 ArticleID 实例化，或在 View 的 `.onDisappear`/`onChange(scenePhase)` 时统一 stop（其实已经有了，问题是单例本身共享）。

### U-12. FileImportView 重复名称不会去重
- 位置：`SmartNote/Sources/Services/FileScannerService.swift:166-172` (`copyFileToStorage`)
- 现状：仅追加 `_1` `_2`...，但 `Material.name` 仍然是原始文件名（不带数字），导入 N 次会产生 N 个同名 `StudyMaterial`，列表筛选/搜索都按 `name` 走，会全部命中。
- 修复方向：导入同名文件时若已存在，给用户三个选项（替换/复制为新文件/取消），或至少让 `Material.name` 也带唯一后缀。

### U-13. 文件夹分类只基于名字字符串匹配
- 位置：`FileScannerService.swift:183-195` (`categorizeMaterial`)
- 现状：`if name.contains("课件") || name.contains("lecture") || name.contains("ppt")` —— 把任何文件名叫 "lecture" 的 PDF 也归到课件。
- 后果：导入"历史笔记-lecture.pdf"会被错误归类。
- 修复方向：让用户手动指定分类，或者至少再加一个"自动分类未命中时弹确认"的兜底。

### U-14. 备份恢复后用 exit(0) 强制退出
- 位置：`SmartNote/Sources/Views/SettingsView.swift:881` (`commitRestore` 调用 `exit(0)`)
- 现状：用 `exit(0)` 而不是 `NSApp.terminate(nil)`；同时 `commitRestore` 之前调了 `WhiteboardService.shared.saveDocuments()`，但 AppState/PomodoroTimer 等其它 `@Published` 状态的内存没 flush。
- 后果：正在编辑的 todo、草稿、白板文本、若没 save 会丢失；`exit(0)` 对菜单栏和 Shortcuts 留有 zombie 句柄；Mac App Store 审核标准是拒绝直接调 `exit()` 的。
- 修复方向：先 flush 所有 `@Published` 状态到磁盘（`storageService.saveMaterials`/`saveTodos`/`saveHabits`/...），再 `NSApp.terminate(nil)`。

### U-15. 备份 ZIP 不加密但 README 容易让用户误以为是"加密快照"
- 位置：`README.md:62, 92`
- 现状：明确写"ZIP 没加密，自己妥善保管" + "别把它当加密快照用"。措辞到位。
- 但用户可能看不到 README 第 91-92 行的「注意事项」，直接在 Settings 里点"立即备份"放进 iCloud/Dropbox 时误以为有保护。
- 修复方向：在 `SettingsView.backupSection` 加红色提示 "ZIP 未加密，请勿存到公共云盘；如需加密请用系统磁盘工具二次加密"。

---

## 1. P0 崩溃与输入边界

### P0-1. `runStartupMigration` 在 `legacyAPIKeyMigrationPending` 还未赋值时就跑，永远不会跳过备份
- 位置：`SmartNote/Sources/Services/StorageService.swift:317-333`（`runStartupMigration`） vs `StorageService.swift:402-451`（`loadSettings`）
- 现状：
  ```swift
  // AppState.init()
  let probeStorage = StorageService()
  let migrationResult = probeStorage.runStartupMigration()  // ← 此时 probeStorage.legacyAPIKeyMigrationPending == false（初始值）
  let settings = probeStorage.loadSettings()                 // ← 这一步才会把 legacyAPIKeyMigrationPending = true
  ```
- 后果：`runStartupMigration` 中检查 `if legacyAPIKeyMigrationPending { skip backup }` 永远不命中，于是**当 settings.json 含明文 API key 时，启动迁移也会把含 key 的 settings.json 复制到未加密备份里**——这与 notes.md 21 章 P2 写明的"API key 进 Keychain；含 key 的 settings.json 不能再被复制到未加密备份"语义相反。
- 修复方向：把 `legacyAPIKeyMigrationPending` 改成 static / 在 init() 第一行就跑一次 legacy key 嗅探；或者在 `runStartupMigration` 之前先调 `loadSettings` 完成剥离判断（哪怕结果丢弃），再做备份决策。

### P0-2. SettingsView `.onChange(of: appState.appSettings)` 与 `appSettings` 的 `didSet` 重复写盘
- 位置：`SettingsView.swift:60-65`、 `StorageService.swift:29-36` (`appSettings` didSet)、`AppState.swift:62-67`（`llmConfiguration` set 时也 saveSettings）
- 现状：用户动一下 toggle，会触发：① `@Published var appSettings` 发出 objectWillChange → ② SwiftUI 把新值赋回 → ③ `didSet` 改 `examCountdowns` 等 → ④ `SettingsView.onChange` 调 `storageService.saveSettings(newValue)` → ⑤ `didSet` 又调一次 `saveSettings` → ⑥ `appSettings.llmConfiguration` 又触发 `llmConfiguration` setter → ⑦ 又一次 `saveSettings`。
- 后果：每次 toggle 写盘 2-3 次，SSD 高频写入 + 可能在主线程合并 JSON 编码的卡顿。
- 修复方向：去掉 `SettingsView` 的 `onChange`，让 `AppState` 内部的 `appSettings` setter 走 `didSet` 自动持久化；`llmConfiguration` 直接调 setter，不要从外面替换 `appSettings.llmConfiguration`。

### P0-3. CalendarService 创建 EKEvent 用 `dailyPlan.date`（00:00:00）
- 位置：`SmartNote/Sources/Services/CalendarService.swift:91-92`
- 现状：`event.startDate = dailyPlan.date; event.endDate = calendar.date(byAdding: .minute, value: task.estimatedMinutes, to: dailyPlan.date)`。`dailyPlan.date` 是 `DateComponents.day` 拼出来的整天，没有小时/分钟。
- 后果：所有复习计划事件在 macOS 日历里都显示为"全天"事件，跟 `estimatedMinutes` 无关；通知时机是默认的午夜/前一天。
- 修复方向：把复习计划开始时间定为 19:00（或从 settings 读用户偏好时间），按 estimatedMinutes 计算结束时间；或允许用户为每天选时间段。

### P0-4. BackupService `makeBackup` 不限制 `safeLabel` 字符长度可被外部输入
- 位置：`SmartNote/Sources/Services/BackupService.swift:237-239`
- 现状：标签 1-40 字符但 `allowed` 里写 `".中_zh_CN"` 这是个 CharacterSet 占位（注释里的"中"是汉字示例，但 `unicodeScalars.filter` 仍保留汉字）。如果用户输入带 `;` `'` `&` 等 shell 元字符，新版本仍可能产生意外路径（虽然 `safeLabel` 经过去过滤）。
- 现状细节：白名单 ASCII + `中` + `_` 已经过滤了危险字符，但路径仍包含时间戳；若时间戳解析在某些 locale 下格式化为非 ASCII（POSIX locale 已经强制），需要确认 `formatter.locale = Locale(identifier: "en_US_POSIX")` 在这一行（已设置，安全）。
- 修复方向：维持现状即可，但加一个单测覆盖"用户输入 `(; rm -rf .)`" 路径生成的结果。

### P0-5. LLMConfiguration 信任状态会因 URL 变更而失效，但没有 UI 自动恢复
- 位置：`SmartNote/Sources/Models/LLMConfiguration.swift:210-213` (`isServerTrusted`)
- 现状：把 URL 改一下再改回来，旧 `trustedServerURL` 不匹配，导致 `isServerTrusted = false` → 用户必须重新勾选信任。这是有意的（避免沿用旧授权），但 UI 在用户切回原 URL 时没有提示"你以前信任过这个地址"。
- 修复方向：在 SettingsView 提示"之前你信任过 X，是否沿用？"，或者在 storage 中保留 trust history。

---

## 2. P1 数据完整性

### P1-1. OCRService 错误路径返回空串被误判为成功
- 位置：`SmartNote/Sources/Services/OCRService.swift:29-34`
- 现状：`VNRecognizeTextRequest` 失败、`CGPDFDocument` 无效、所有 page 都渲染失败——均 `continuation.resume(returning: "")`。
- 后果：`LLMService.makeOCRTextPrompt` 用 `recognized.trimmingCharacters(...).isEmpty` 抛 `imageUnderstandingUnavailable`，但 `OCRService` 上层无 `lastError`，UI 不知道是图片损坏还是无文字。
- 修复方向：加 `enum OCRError { case invalidPDF, noPages, allPagesFailed, noTextRecognized }`，把错误传出来给调用方决定。

### P1-2. HistoryService `loadCatalogIfNeeded` 失败后永不重试
- 位置：`SmartNote/Sources/Services/HistoryService.swift:162-190`
- 现状：一旦 JSON 解码失败，`didLoadCatalog = true`，后续修复 JSON 必须重启 App。
- 修复方向：加"重试"按钮，或在 `loadError` 被用户清空时把 `didLoadCatalog` 重置。

### P1-3. AppState 启动期同步阻塞主线程做迁移
- 位置：`SmartNote/Sources/App/AppState.swift:101-118`（`runStartupMigration()` + `loadSavedData()` 同步执行）
- 现状：`runStartupMigration` 会调 `ditto` 外部命令做大文件备份（虽然小但仍 IO）；`loadSavedData` 同步读所有 JSON。
- 后果：冷启动卡顿；JSON 文件损坏场景下 `load(from:)` 走 `reportStorageIntegrityIssue` 也是同步。
- 修复方向：迁移逻辑可异步，先用默认值快速显示 UI，再后台迁移。

### P1-4. StorageService.ManagedDataPath `backupDirectory` / `legacyBackupDirectory` 的清理依赖 `clearAllData`
- 位置：`StorageService.swift:917-937` (`clearAllData`)
- 现状：`clearAllData()` 把 `legacyBackupDirectory` 一并删除；但没有删"清理过程中新产生的备份"——如果用户在恢复流程中失败，旧目录已经在原地被替换过，清除逻辑可能漏掉中间态。
- 后果：理论极端场景下，"清除所有数据"后磁盘仍残留半个临时目录。
- 修复方向：清空时显式 enumerate `appSupportDirectory.deletingLastPathComponent()` 下的 `SmartNote-*-Backups` 同级目录，再删。

### P1-5. `loadAll` 在 P2PService 单例 init 里跑，但 SharedAppStateProxy 还未 bind
- 位置：`SmartNote/Sources/Services/P2PService.swift:238-274`
- 现状：`P2PService.shared.init()` → `loadData()` → 读 storage、启动 listener。`AppState.init()` 里调 `SharedAppStateProxy.shared.bind(self)`，但 `bind` 时 `P2PService.shared` 已经把内部 listener 起来了。
- 后果：单例初始化顺序依赖造成潜在时序问题；AppState 创建的 StorageService 与 P2PService 持有的 StorageService 是两个实例（`StorageService()` 没有 shared），删除流程有可能不一致。
- 修复方向：把 P2PService 改成 `@MainActor final class P2PService: ObservableObject { init(deps: ...) }`，由 AppState 注入；删除单例访问入口。

### P1-6. `SettingsView.onChange(of: appState.appSettings)` 也会把 `examCountdowns` 字段写回旧 settings.json
- 位置：`SettingsView.swift:60-65` + `StorageService.swift:1232-1268`（`encode(to:)`）已显式跳过了 `examCountdowns`
- 现状：当前 `encode(to:)` 没有把 `examCountdowns` 写进 JSON，因此 `saveSettings` 不会写这个字段；但 `SettingsView.onChange` 传入的是整个 `newValue`，saveSettings 内部走 `save(settings, to:)`，对应 `LLMConfiguration.encode` 也会跑一次（密钥剥离）。整体 OK，但用户观察不到"考试倒计时改 settings 写盘"的细节。
- 修复方向：无功能性问题，仅文档。

---

## 3. P2 安全边界

### P2-1. clearAllData 没二次确认（P0 重复登记在此提醒）
- 位置：`SettingsView.swift:946-950`
- 现状：调一次就清空所有 JSON、所有受管 Keychain 条目。
- 修复方向：U-8 已说明。

### P2-2. App Sandbox 仍关闭（README 已声明是有意）
- 位置：`project.yml:79-83`、`SmartNote.entitlements`、README 第 95 行
- 现状：`com.apple.security.app-sandbox = false`；security-scoped bookmark 已接入资料模型；/Applications 安装、ditto/unzip 外部进程、全量文件访问未迁移到沙盒兼容流程。
- 修复方向：先关闭 ditto/unzip 调用（用 `FileManager` / `Compression.framework` 内置 API 替代）；把 /Applications 写入拆成 helper；然后开沙盒。

### P2-3. 自更新没有代码签名（README 已声明）
- 位置：`UpdateService.swift:118-119`、`README.md:93`
- 现状：结构、Info.plist、Bundle ID、版本、体积都校验，但不替代 Developer ID 签名。
- 修复方向：接入 Apple Notarization + Developer ID 签名；至少在用户下载前显示"已签名/未签名"。

### P2-4. P2P 仍是裸 TCP（README 已声明）
- 位置：`P2PNetworkService.swift:226-229`、`README.md:94`
- 现状：没有 TLS / 证书身份验证 / 防重放 / 防降级。
- 修复方向：迁移到 `NWConnection(tls: NWProtocolTLS.Options())` + 自签证书指纹交换（与现有 RSA-2048 公钥指纹一并提示用户比对）。

### P2-5. `P2PNetworkService.startListening` 没有等待 listener 就绪就 `updateLocalAddress`
- 位置：`P2PNetworkService.swift:264-267`
- 现状：`start(queue:)` 后 1 秒 `updateLocalAddress()`，但 listener `.ready` 之前 getifaddrs 可能拿到旧的（特别是 IPv6 link-local）。
- 后果：刚启动 listener 后立刻被读到的 `localIPv6Address` 是上一轮 IP（设备切网时常见）。
- 修复方向：在 `.ready` 回调里 `updateLocalAddress()`，去掉 `1.0` 秒兜底。

### P2-6. P2PService 内存中 `chatHistoryLoadFailed` / `groupHistoryLoadFailed` 锁不住写回
- 位置：`P2PService.swift:319-327`
- 现状：仅在 `loadEncryptedMessages` 失败时把 flag 设为 true，但 `resetIdentity` 又会重置——若用户重新连接后某次内存里临时存消息，会被 `saveChatMessages`/`saveGroupMessages` 直接写回（因为 save 路径不读 flag）。
- 修复方向：写回路径也校验 flag，失败时拒绝写盘并提示"聊天记录加载失败，禁止写回"。

---

## 4. P3 正确性 / 体验细节

### P3-1. `NotificationIdentifiers.pomodoro()` 默认参数每次都是新 UUID
- 位置：`NotificationService.swift:207`
- 现状：`pomodoro` 通知用 `pomodoro_<UUID>` 标识符，每次点开始/结束都是新 UUID，旧通知留在通知中心。
- 后果：通知中心堆满 `pomodoro_*` 通知条目。
- 修复方向：用一个稳定的 `pomodoro_<phase>` 或 `pomodoro_last` 标识符 + `removeExisting: true`。

### P3-2. PomodoroTimer 启动时立刻 `enableFocusMode()` 但 `disableFocusMode()` 只是 print
- 位置：`PomodoroTimer.swift:230-236`
- 现状：实现是空函数体（注释说"macOS native"，但代码无实际集成）。
- 后果：UI 上"启用专注模式"开关是装饰，无功能。
- 修复方向：要么接 `SetFocusFilter` API（macOS 12+），要么从 UI 移除该开关。

### P3-3. PomodoroTimer 的 Timer 在 `stop()` 后可能仍在 queue 中排队的 `tick()`
- 位置：`PomodoroTimer.swift:159-176`
- 现状：`guard isRunning && !isPaused` 兜底了，但还是写 `studySession?.duration += 1`；`tick()` 调用 phaseComplete 后 `timer = nil`，但下一帧 timer 已入队。
- 后果：极端场景 studySession.duration 多 1。
- 修复方向：用 `Date` 算实际流逝秒数，timer 1Hz 只是心跳。

### P3-4. P2PService `sendValidatedPacket` 完成回调可能多次调用
- 位置：`P2PService.swift:610-624`（`sendMessage`）
- 现状：`sendValidatedPacket` 通过 `networkService.send(...)`，失败回调 `markChatMessageFailed`；但 success 分支也写 `msg.status = .sent` + `appendChatMessage`——若 `send` 立刻进 pumpSendQueue 并完成，回调 `success(true)` 会再触发 `markChatMessageFailed`（实际是 success 分支不会触发，但 success 分支也写了 `appendChatMessage`）。
- 后果：理论上不会重复，但 success/fail 的 callback 顺序与 `appendChatMessage` 的时机混乱。
- 修复方向：把 `appendChatMessage` 改为 send 前先 push (status: .sending)，completion 回调里只 update status，不重复 append。

### P3-5. `LLMConfiguration.normalizedServerURL` 用 `URLComponents`，但空 query 不归一化
- 位置：`LLMConfiguration.swift:94-115`
- 现状：`serverURL = "http://localhost:1234/?foo=bar"` 和 `"http://localhost:1234"` 会得到不同的 normalizedServerURL（因为 query 不同）。
- 后果：用户在 URL 后加 `?debug=1` 后，trustedServerURL 会突然失配。
- 修复方向：信任判定时把 query 强制清空或归一化（仅 scheme/host/port 决定信任，path 仅在官方 API 域名下生效）。

### P3-6. Anniversary 通知 `timeInterval: 1` 把所有到期项目一起炸
- 位置：U-6 已记录。

### P3-7. OCRService `recognitionLanguages` 写死 `["zh-CN", "en-US"]`
- 位置：`OCRService.swift:50`
- 现状：纯中文或纯英文场景可以，但中日韩混排或竖排繁体不会识别。
- 修复方向：从 LLMConfiguration 同款机制读 `UserLearningProfile.preferredLanguageTone`，自动加入语言。

### P3-8. FileScannerService PDF 抽取只读前 5 页
- 位置：`FileScannerService.swift:202-208`（`extractPDFText`）
- 现状：`for i in 0..<min(document.pageCount, 5)`。
- 后果：100 页的 PDF 只取前 5 页用于关键词提取。
- 修复方向：异步批量抽，或者干脆跳到 `LLMService` 时让 LLM 看 PDF（已支持 vision / OCR 路径）。

### P3-9. `LLMService.sendMessageStreaming` 在 `LMStudio` 提供商下没有 maxTokens / temperature 校验
- 位置：`LLMService.swift:355-397`（`callLMStudio`）/`399-458`（`streamLMStudio`）
- 现状：直接塞进 payload；如果用户把 maxTokens 设到 4096 但 LM Studio 模型只支持 2048，会被服务端截断/报错。
- 修复方向：在 LLMService.init() / updateConfiguration() 里 clamp 到 [256, 4096]（已声明范围），并在用户改设置时显示"你的模型声明支持吗？"。

### P3-10. `P2PNetworkService.connections` 是 `@Published var`，但可变状态分散在 P2PConnection 上
- 位置：`P2PNetworkService.swift:196`
- 现状：`connections[friendID]` 字典是 `@Published`，但 P2PConnection.isTerminated / keyMaterial / handshakeCompleted 等都在 connection 对象上，SwiftUI 视图读不到。
- 后果：SwiftUI 显示的"在线/离线"必须靠 `P2PService.connectionStatus` 二次发布。
- 修复方向：要么 connection 自己 ObservableObject，要么 NetworkService 暴露 `@Published var connectionSummaries: [UUID: ConnectionSummary]` 镜像关键字段。

---

## 5. 已知但暂时保留（不要让 OpenCode 改）

这些是 `docs/notes.md` 第 22 章已经记录的有意保留：

- 备份 ZIP 未加密 → README / notes 22 章
- 自更新没有代码签名 → README / notes 22 章
- P2P 裸 TCP → README / notes 22 章
- App Sandbox 关闭 → README / notes 22 章
- 白板暂时关闭但代码保留 → notes 9 章
- `Cmd+Shift+R / K` 与 Siri Intent 仍写裸数字 tab ID → notes 17 章
- `setBackgroundImageRandomEnabled` 在 < 2 张用户图时不可用 → notes 14 章
- `ShowFileExtensions` UI 缺失对应开关 → notes 14 章
- 不接农历表 → notes 13 章
- 纪念日不支持 cron → notes 13 章

---

## 6. 待观察项（OpenCode 评估时再决定要不要修）

### W-1. `SettingsView` 整个 `.frame(width: 600, height: 480)` 是否在 Retina/外接显示器下太小
### W-2. `BackupService` 中 `isValidRepositoryComponent` 拒绝非 ASCII owner/repo，但 GitHub 实际上也支持中文 repo（极少数）
### W-3. `P2PService.isBackgroundEnabled` 启动顺序敏感：先 `loadData()` 再 `setupNetworkHandlers`，但 listener 启动在 `loadData` 末尾；若 `currentIdentity == nil` 永远不会启 listener——这是有意的，但 UI 没有"未创建身份时显示状态"提示
### W-4. `NoiseGenerator.brown` 用 `last = (last + white * 0.02).clamped(to: -1...1)` ——数学上能稳定，但每样本 clamp 会引入轻微失真，听感可能"沙沙声"

---

## 7. 修复优先级建议（提交给 OpenCode）

| 顺序 | 编号 | 一句话 |
|------|------|--------|
| 1 | U-1, U-2 | Siri/Shortcut 撒谎问题（误导用户） |
| 2 | P0-1 | 启动迁移时把明文 API key 复制到未加密备份（数据泄露） |
| 3 | U-6 | 纪念日通知立即触发（破坏语义） |
| 4 | U-8 | 清除所有数据无二次确认（数据丢失） |
| 5 | U-5 | defaultStudyMinutes 死字段（UI 谎话） |
| 6 | U-14 | exit(0) 强制退出（可能丢数据 + 不规范） |
| 7 | U-3 | 裸数字 tab ID（侧栏顺序变动即坏） |
| 8 | P0-2 | onChange 重复写盘（性能 + 偶发数据覆盖） |
| 9 | P0-3 | CalendarService 全天事件（复习计划体验） |
| 10 | P1-1, P1-2 | OCR 失败 / History catalog 失败诊断信息不足 |
| 11 | U-7 | 通知点击路由（用户体验） |
| 12 | U-9, U-10, U-11, U-12, U-13, U-15 | 其他体验/防御性细节 |
| 13 | P1-3 ~ P1-6 | 启动时序、并发、清理路径 |
| 14 | P2 系列 | 安全边界（多数 README 已声明） |
| 15 | P3 系列 | 正确性 / 体验细节 |