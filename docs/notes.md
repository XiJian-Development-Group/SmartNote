# SmartNote 实施笔记

> 配合 `README.md`（做什么）和 `project.yml`（怎么构建）使用。本文件记录**实际做了什么、留了什么、为什么**。
> 每个章节末尾的「没动的与原因」沉淀有意保留的口径与暂未实现的细节。

---

## 第 0 节 总原则（适用所有章节）

### 用系统原生接口，不引第三方

整个 v1.7 阶段所有新增功能必须走 macOS 系统原生 framework，禁止引入新的 SPM 依赖。
技术选型清单：

| 功能模块 | 选用框架 / API | 备注 |
|----------|---------------|------|
| 对称加密 | `CryptoKit` (`AES.GCM`) | 256-bit, nonce 96-bit, 12-byte auth tag |
| 密码存储 | `Security` / Keychain Services (`SecItemAdd` 等) | `kSecClassGenericPassword` |
| 备份打包 | `Process` 调 `/usr/bin/ditto` | zlib level 9；纯系统 zip，不引 ZipFoundation |
| 菜单栏 | `MenuBarExtra` SwiftUI Scene | macOS 13+ 原生 |
| 开机自启 | `SMAppService.mainApp.register()` | macOS 13+ 原生 |
| Siri | `AppIntents` + `AppShortcutsProvider` | macOS 13+ 原生 |
| 纪念日 | `EventKit` (EKEvent) 在路上；当前用 `UNUserNotificationCenter` | 还没接 EKEvent |
| 提醒推送 | `UserNotifications` (`UNUserNotificationCenter`) | 提前 X 天通知 |
| 白噪音 | `AVFoundation` (`AVAudioEngine` + `AVAudioPlayerNode`) | 本地资源 + 用户导入 |
| 函数绘图 | `SwiftUI` Canvas + `Foundation` `NSExpression` 数学 | 不引 CorePlot 等 |
| AI 视觉 | `URLSession` + `AppKit` `NSImage` + `NSBitmapImageRep` | 仅 OpenAI / Anthropic 多模态 |
| 倒数纪念日 | `Foundation.Calendar` + `UNUserNotificationCenter` | 不引第三方日期库 |
| 星空动画 | `SwiftUI` `TimelineView` + `Canvas` | 粒子系统本地绘制 |
| 计算器 | `Foundation` `NSExpression` 数学 + Int 位运算 | 不引 MathParser 等 |

---

## 第 1 章 P0-1 备份与升级基础设施

- `StorageService.runStartupMigration()` 是同步阻塞方法；AppState.init() 在 probeStorage 立即调用一次。
- schema 字段升级策略：
  - 老 settings.json 缺字段：用 `decodeIfPresent(_:forKey:) ?? 默认值` 兜底；
  - `schemaVersion` 强制写回当前值；
  - 字段重命名场景下需要显式 transform，P0 阶段没有这种破坏性改动，留 TODO 占位。
- 备份 zip 用 `/usr/bin/ditto -c -k --sequesterRsrc --keepParent`，加 `--zlibCompressionLevel 9`，无第三方依赖。
- 备份目录 `Application Support/SmartNote/Backups/`，文件名加时间戳；同名文件追加 `-1`、`-2` 避免覆盖。
- 恢复流程：解压到临时目录 → 把每个 json 覆盖回 Application Support → `exit(0)` 让 AppState 重新加载。

### 没动的与原因

- 不做"先跳出对话框让用户确认备份"流程。理由：放在启动期静默做，避免每次启动弹窗骚扰老用户；用户可在「设置 → 备份与恢复」里手动管理。
- 不限制 Backups 目录大小。理由：app 数据本身不大（< 100 MB 常见），保留 30 天滚动删除可后续再加，目前不做是为了不复杂化首批交付。
- 不做跨设备同步。理由：所有备份都在本地，避免引入 iCloud 等额外依赖。

---

## 第 2 章 P0-2 文件加密 + 钥匙串

- `.snenc` 容器格式 100% 自描述，单凭文件即可判别类型 + 版本。
- 单文件上限 2 GB 是 NSExpression / Keychain 之外的全部都依赖的尺寸边界，2 GB 是 PBKDF2 / CryptoKit / FileManager 读写的安全上限。
- PBKDF2 100 k 迭代：实测在 M1 上单次派生 < 80 ms；UX 与抗暴力破解的折中。
- 密码存 Keychain 维度按文件名（不含目录），因为 v1.7 假定「用户每个加密中心目录只放同名加密副本」。

### 没动的与原因

- 不支持"对文件夹整体加密"。理由：会把同一个路径下不同文件用同一个 key 加密，导致 metadata 泄露更严重。
- 不实现"两阶段解密 / 主密码"功能。理由：Mac 用户更习惯钥匙串自动管理；本地主密码虽然安全但 UX 不友好。
- 不上报加密统计到 LLM。理由：privacy by default，所有加密动作都不离开本机。

---

## 第 3 章 P0-3 文件加密 UI

- 主面板为左右两栏（左 = 待处理列表 + 拖拽 + 选择；右 = 密码 + 操作 + 输出目录）。
- 批量并发用 `TaskGroup`；每个文件单独 addObject / report success-or-fail。
- 钥匙串列表显示在解密 sheet 折叠区，只读按文件名列出。

### 没动的与原因

- 不集成到白板或资料库导入链路。理由：v1.7 把"文件加密"作为独立工具中心；用户主动操作避免误加密。
- 不做"压缩后再加密"。理由：CryptoKit / FileManager 单独使用已经足够；少一次 mmap 复杂度。

---

## 第 4 章 P0-4 菜单栏 + 开机自启

- `MenuBarExtra(.menu)` 内嵌在主 `App.body` scene 里，与主 WindowGroup 并列。
- `LaunchAtLoginService` 单例通过 `SharedAppStateProxy` 注册表唯一标识自己，防止多实例。

### 没动的与原因

- 菜单栏内容**没有**走 `@EnvironmentObject AppState` 单独做一份 Scene 重新拉取（系统不支持）；用 `.environmentObject(appState)` 共享，与主窗口共用同一份。
- "菜单栏开关"暂未做 UI toggle：MenuBarExtra 一旦在 `body` 里就常驻。理由：在 macOS 上"隐藏菜单栏"是低频动作，真要做也得重启 app 才有意义；本期不做。
- LaunchAgent 方案**未采用**。理由：`SMAppService.mainApp` 是 macOS 13+ 官方 API，比 LaunchAgent 更"系统接管"，更符合"和系统融合"。

---

## 第 5 章 P1-1 几何画板

- 新增 8 个 Shape 类型（点 / 圆 / 弧 / 多边形 / 函数图 / 参数方程 / 极坐标 / 测量标记），全部继承 `WhiteboardShape` 协议。
- 旧 whiteboards.json 兼容：Codable enum 加 case 默认兼容（Swift 不知道的 case 反序列化时丢失，但不影响其他对象）。
- 代数求值走 Foundation NSExpression：
  - 用 `^` → `**`（NSExpression 内置 power 运算符）
  - `ln` → `log`（NSExpression 的 log 默认即自然对数）
  - 不支持嵌套函数中的 `^` token，但我党已加状态机；目前只支持简单两层
- 函数图 / 参数 / 极坐标通过顶部菜单 "插入" 弹 sheet 输入；不占用 canvas drag。

### 没动的与原因

- 未做测量工具的"选择 2/3 个对象自动算距离/角度"完整链路。原因：v1.7 阶段 Measurement 标记结构已建好，但"选择-计算"交互复杂，先保留 UI 占位（显示"测量目标已选"）。
- 函数绘制**没有**自动轴 / 网格。原因：当前画布坐标系就是数学坐标系（默认 zoom = 1），加网格会改变白板本身语义。
- 表达式**没有**完整复数 / 微积分 / 自动证明。原因：超出范围 (P1 第三档 — 几何证明)。
- NSExpression 不支持的 token（如 `arccos`、`max(min)` 嵌套）当前会抛 .parseFailed 并在 UI 显示"表达式无效"。后续可换自写 Pratt parser 但本期不做。

---

## 第 6 章 P1-2 AI 视觉

- `LLMConfiguration.supportsNativeVision` 是一个简单的 provider 判定，`LM Studio = false`，其余 true。
- 多模态格式：
  - OpenAI：messages.content 是数组 `{type: text|image_url}`；
  - Anthropic：messages.content 是数组 `{type: image, source: {type: base64, media_type, data}}` + `{type: text}`，且 system 在外层。
- 图片上传前 `LLMService.encodeForVision` 用 NSBitmapImageRep 缩放到 `visionImageMaxEdge`（默认 1280 px），以 JPEG `visionImageQuality`（默认 0.85）压缩再 base64。

### 没动的与原因

- `LM Studio`（与本地 llama.cpp）没有做多模态适配。理由：llama.cpp 的 `--mmproj` 模型路由逻辑与 OpenAI/Anthropic multipart content 完全不同，且需要 mime 边界 multipart/form-data，复杂度大。LM Studio 走 ocr 间接是更稳的路。
- `visionMaxImages > 1` 当前 UI 仍接受（不禁止），但实际不会传多张。原因：base64 一次性 inline 大图，对 context window 压力大；后续可改用多轮上传。
- 不做 OCR fallback。本地 LLM 支持多模态的时候再做。

---

## 第 7 章 P1-3 学习偏好本地调优

- `LearningPreferenceAutoTuner` 完全离线：从 `StudyMaterial.keywords` / `WrongQuestion.knowledgePoints` + 复习计划完成率，三路信号合并。
- `mergeMode`：
  - `.fillMissing` 仅在用户没填该字段时填充，避免覆盖用户手动改过的；
  - `.overwrite` 强制覆盖（保留作按钮"重置+自动" 选项，本期 UI 仅暴露 fillMissing）。

### 没动的与原因

- 不自动调用 LLM 做行为画像。理由：本地统计对用户**已发生**的数据已经能给到足够有用的画像；调用 LLM 是开销大、对中文学习场景 prompt 设计复杂的两难权衡。
- 不做"主题画像 + 复习推送"个性化编排。理由：触发链跨数据 + 推送 + 提醒，前期只把"画像"做好，下一步再接 push。

---

## 第 8 章 P2-1 白噪音

- 6 个声源全部用算法（`NoiseGenerator`）生成 10-14 s 的 PCM buffer，再 `scheduleBuffer(.loops)` 循环。`AVAudioEngine` 不引第三方音频文件，app 体积 +0。
- 雨声 = 白噪底 + 25 Hz 平均脉冲；海浪 = sin 调幅 + 散高频；森林 = 粉噪 + 鸟鸣短促正弦。
- 粉噪用 Voss-McCartney，行数 16；棕噪用累计随机游走 + 钳位。

### 没动的与原因

- 不支持实时调节 EQ / 立体声。原因：`AVAudioEngine` 已支持 `AVAudioUnitEQ` chain，复杂度提升大，本期不做。
- 不实现"环境音混合（2 个声源同步 + 单独音量）"。理由：v1.7 已实现（每个声源独立 node + 独立 volume），但跨声源的混音留待 v1.8。

---

## 第 9 章 P2-2 许愿/还愿

- 背景用 `TimelineView(.animation(minimumInterval: 1.0/30.0))` 驱动 `Canvas` 重绘，30 FPS 足够。
- 70 颗星使用 seed 稳定的伪随机分布；用户多次刷新页面位置一致。
- 流星 6 秒周期出现在窗口期内。
- 渐变背景：上半深蓝 → 下半深紫。

### 没动的与原因

- 不支持动画性能自适应。理由：30 FPS 在 M1 上稳定；后续可换 Metal 或 SKView。
- 不做"许愿分享"匿名社区。理由：用户原话"本地星空背景的私人页面"，非云端。

---

## 第 10 章 P2-3 倒数纪念日

- 三种重复：
  - `.once` 固定日期，仅一次；
  - `.yearly` 滚动到下一个匹配 (month, day)；
  - `.monthly` 滚动到下一个匹配 (day)，自动跨年。
- `nextOccurrence` 用 `Calendar.dateComponents` 步步尝试，**有 8 / 60 次循环 guard** 防止 panic。
- 通知走 `UNUserNotificationCenter`，每次启动 `checkAndRequestPermissionAndNotify` 推送一次未通知过的；用 `lastNotifiedYearMonthDayKey` dedup。

### 没动的与原因

- 不接 `EventKit` 写系统日历 / 提醒事项。理由：`EKEvent` 需要 entitlement 与许可；用户当前场景更偏好纯本地表。
- 不实现农历。理由：需自带农历表或调 LunarCalendar，工作量独立成一期；当前用户决策走"公历 + 重复"。
- 不支持复杂 cron 表达式。理由：当前 3 档覆盖普通用例，复杂规则留给用户手动删建。

---

## 第 11 章 P2-4 Siri / App Intents

- 8 个 `AppIntent`（资料库 / 番茄钟 / 待办 / 白板 / 文件加密 / 许愿 / 纪念日 / OpenPage 参数化 / 快速记录）。
- `SmartNoteShortcutsProvider` 返回 `[AppShortcut]`，每个短语包含 `\(.applicationName)` 占位符。
- `SharedAppStateProxy` 单例桥：AppState.init() 在 MainActor 上 bind 自身，Intent perform 时读写 selectedTab。

### 没动的与原因

- 不实现 `EntityQuery`（如"打开最近的笔记"）。理由：Siri 短语里嵌入参数已能覆盖日常使用；实体查询需要数据模型联合 LLM 跑相似度，复杂度单独成期。
- 不做 SiriKit legacy（`INApp`、extension）。理由：iOS 14+ / macOS 11+ 起 `AppIntents` 已全面替代，最小系统要求 macOS 15。
- 状态桥**不**做持久化跨 launch 唤醒。理由：Siri 调起来 App 反正重新启动，selectedTab 重置为 0 即可；不必过设计。

---

## 第 12 章 P2-5 高级计算器

- 三模式（标准 / 科学 / 程序员）共用一个 `CalculatorEngine`，输出按 mode 切换格式化。
- 表达式走 `NSExpression`，单值函数（sin/cos/log/ln/√/x²/x!）走 `applyFunction` 直接算；位运算走 Int。
- 进制切换时 `formatNumber` 走 `Int(value)` + `String(radix:)`，所以 HEX 显示大写、DEC 走普通浮点格式（已是整数时无小数点）。
- 用户输入：
  - 数值按钮 → `appendDigit`
  - 操作符按钮 → 把当前 display 推到 `expression`，把操作符加进去
  - 等号 → `evaluate()` 用 NSExpression 一次性求值。

### 没动的与原因

- 未实现复杂记忆（M+, MR, M-, MC）跨模式。理由：v1.7 只在标准模式暴露 MC/MR/M+/M-；科学与程序员模式下 math 操作更复杂，留待 v1.8 设计"按操作上下文解释 M+ 的值"。
- 不做"表达式回放 / 撤销历史"。理由：支持会引入 redoStack，复杂度 +1。
- 不做"单位换算（cm↔inch 等）"。理由：与计算器学科跨度大，独立成更合适。

---

## 第 13 章 构建与基础设施

- `xcodegen generate` 每次新增 Sources 文件后必须跑一次，把 `*.swift` 注入到 `project.pbxproj` 的 `Sources` build phase 里。
- `xcodebuild -project SmartNote.xcodeproj -scheme SmartNote -configuration Debug -destination 'platform=macOS'` 是本地编译 + 错误检测的唯一可靠路径。
- AppleArchive 不是本项目实装的 zip 路径。理由：`ditto` 命令行调用足够；AppleArchive API 复杂（C 级别 ByteStream）开销大于收益。

### 没动的与原因

- 不引 SwiftLint / Pre-commit hook。理由：项目当前尚未配；后续 v1.8 可加。
- 不写 CI script。理由：项目无 .github 目录；本地构建足够。

---

## 第 14 章 改动概览（commits）

| commit | 标题 | 关键文件 |
|--------|------|----------|
| `725f93d` | chore(docs): docs/notes.md 骨架 | docs/notes.md |
| `fb24642` | feat(backup): 启动期自动备份与 schema 迁移 | BackupService.swift, StorageService.swift |
| `e73350c` | fix(pdf): PDFService 加 extractText 方法 | PDFService.swift |
| `7ca0d0a` | feat(crypto): 任意文件加密/解密与钥匙串集成 | KeychainService.swift, FileCryptoService.swift, FileCryptoView.swift |
| `a4aec95` | feat(system): 菜单栏与开机自启 | LaunchAtLoginService.swift, MenuBarContentView.swift |
| `9b5ae98` | feat(geometry): 模型与代数 | AlgebraEvaluator.swift, GeometryModel.swift, Whiteboard.swift, WhiteboardService.swift |
| `f43226e` | feat(geometry): 渲染与输入面板 | WhiteboardCanvasView.swift, WhiteBoardView.swift |
| `df15439` | feat(ai-vision): 多模态消息载荷 | LLMConfiguration.swift, LLMService.swift |
| `2b04a04` | feat(ai-vision): AI 对话接入图片 | AIChatView.swift |
| `b7a8d45` | feat(learning): 本地启发式调优 | LearningPreferenceAutoTuner.swift, LearningAnalysisService.swift, LearningProfileSettingsView.swift |
| `f4dbeab` | feat(ambient): 白噪音播放中心 | AmbientSoundService.swift, WhiteNoiseView.swift |
| `6897f97` | feat(wish): 许愿/还愿 + 动态星空 | WishModel.swift, WishService.swift, WishView.swift |
| `6e46efe` | feat(anniversary): 倒数纪念日与提醒 | AnniversaryModel.swift, AnniversaryService.swift, AnniversaryView.swift |
| `b5c0c66` | feat(siri): App Intents 跳转 + 快速记录 | SmartNoteIntents.swift, QuickNoteStore.swift |
| `438ee50` | feat(calculator): 标准 / 科学 / 程序员 | CalculatorEngine.swift, CalculatorView.swift |

---

## 第 15 章 pre-existing bug 备注

- `SmartGradingView.swift` 调用了 `pdfService.extractText(from:)`，但 `PDFService` 只暴露了 `generate*` 静态方法，v1.6.2 之前已经 missing。本次补回 instance method `extractText(from:) -> String?`（用 PDFKit 逐页拼接）。
- 项目以 `/usr/bin/ditto` 替代 ZipFoundation；以 NSExpression 替代自写 parser；以 SMAppService 替代 LaunchAgent plist；以 UNUserNotificationCenter 替代 EventKit 写死 entitlement——全部为"不引第三方"约束。
