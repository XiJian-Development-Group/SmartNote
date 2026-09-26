# SmartNote 实施笔记

> 配合 `README.md`（做什么）和 `project.yml`（怎么构建）使用。本文件记录**实际做了什么、留了什么、为什么**。
> 章节编号按当前实现记录；每节末尾的「没动的与原因」保留有意留下的边界，新增修复节则集中列出本轮的安全与正确性结论。
> 当前部署目标以 `SmartNote/Resources/Info.plist` 的 `LSMinimumSystemVersion=15.0` 为准。

---

## 第 0 节 总原则（适用所有章节）

### 用系统原生接口，不引第三方

整个 v2.0 阶段的新增功能使用 macOS 系统原生 framework，不引入新的 SPM 依赖。技术选型清单：

| 功能模块 | 选用框架 / API | 备注 |
|----------|---------------|------|
| 对称加密 | `CryptoKit` (`AES.GCM`) | 256-bit 密钥、96-bit nonce、128-bit auth tag |
| 密码与凭据存储 | `Security` / Keychain Services (`SecItemAdd` 等) | `kSecClassGenericPassword`；按功能区分 account/service |
| 备份打包 | `Process` 调 `/usr/bin/ditto` | zlib level 9；未加密 ZIP，不引 ZipFoundation |
| 菜单栏 | `MenuBarExtra` SwiftUI Scene | API 自 macOS 13；本项目部署最低 15.0 |
| 开机自启 | `SMAppService.mainApp.register()` | API 自 macOS 13；本项目部署最低 15.0 |
| Siri | `AppIntents` + `AppShortcutsProvider` | API 自 macOS 13；本项目部署最低 15.0 |
| 日历与提醒 | `EventKit` / `UserNotifications` | 复习计划可写日历；纪念日和通用提醒走系统通知 |
| 白噪音 | `AVFoundation` (`AVAudioEngine` + `AVAudioPlayerNode`) | 内置算法声源 + 用户导入音频 |
| 函数绘图 | `SwiftUI` Canvas + 自研表达式求值器（tokenize + 递归下降） | 不引 CorePlot 等 |
| AI 视觉 | `URLSession` + AppKit `NSImage` + Vision OCR | 原生视觉仅 OpenAI / Anthropic 路径 |
| 倒数纪念日 | `Foundation.Calendar` + `UNUserNotificationCenter` | 当前不写系统日历事件 |
| 星空动画 | `SwiftUI` `TimelineView` + `Canvas` | 粒子系统本地绘制 |
| 主题系统 | `SwiftUI Environment` + `AppSettings.ThemeID` + `Color` tokens | 经典 / 国庆红 / 祥云金，主题选择持久化 |
| 节日祝福 | 本地日期索引 + 本地祝福库 | 每日选取与手动换句，不请求网络 |
| 近代史科普 | `Bundle` JSON 目录 + `HistoryService` + 本地进度 JSON | 1840—1949 离线导览、搜索、收藏、阅读进度和随机学习 |
| 计算器 | `AlgebraEvaluator` + `Int64` 精确整数路径 | 已弃用旧的 Foundation `NSExpression` 求值路径 |

---

## 第 1 章 P0-1 备份与升级基础设施

- `StorageService.runStartupMigration()` 是同步阻塞方法；`AppState.init()` 在 probe storage 阶段调用一次。
- schema 字段升级策略：
  - 老 `settings.json` 缺字段：用 `decodeIfPresent(_:forKey:) ?? 默认值` 兜底；
  - `schemaVersion` 强制写回当前值；
  - 字段重命名场景需要显式 transform；当前版本没有把这种破坏性变更伪装成自动兼容。
- 备份 ZIP 用 `/usr/bin/ditto -c -k --sequesterRsrc --keepParent`，加 `--zlibCompressionLevel 9`，无第三方依赖。
- 新备份目录位于数据根目录的同级 `SmartNote-Backups`；旧版数据目录内的 `Backups` 会先尝试迁到独立目录的 `Migrated Backups`，避免把历史 ZIP 递归打进新备份。
- 备份文件是**未加密 ZIP**，文件名带时间戳和可选标签；同名文件追加 `-1`、`-2` 避免覆盖。
- 恢复流程：解压到数据目录外的临时目录 → 规范化顶层目录 → 校验 `materials.json`、`settings.json`、`whiteboards.json` 等关键文件 → 原子改名切换数据根目录。切换或复验失败时回滚原目录；成功后退出进程，让 `AppState` 重新加载。

### 没动的与原因

- 不做“启动时弹出备份确认”流程。理由：启动迁移已有结果提示，用户可在「设置 → 备份与恢复」手动管理和确认恢复。
- 不自动删除历史备份。理由：自动清理可能丢失用户尚未迁移的重要数据；当前由用户手动删除。
- 不做跨设备同步。理由：所有备份都在本地，避免引入 iCloud 等额外依赖。

---

## 第 2 章 P0-2 文件加密 + 钥匙串

- `.snenc` 容器格式 100% 自描述，单凭文件即可判别类型和版本。
- 单文件上限 2 GB 是 `FileCryptoService` 对 PBKDF2、CryptoKit 和 FileManager 读写边界的安全限制。
- PBKDF2-HMAC-SHA256 100,000 次迭代，派生 32-byte 密钥；每份文件使用随机 salt 和 12-byte nonce。
- 密码保存到 Keychain 时按输出文件名维度；解密列表只读显示当前 service 下的 account。
- 文件加密是本地文件容器，不是端到端通信加密；密文格式中的 tag 只能保护该文件内容。

### 没动的与原因

- 不支持“对文件夹整体加密”。理由：会把同一个路径下不同文件用同一个 key 加密，导致 metadata 泄露更严重。
- 不实现“两阶段解密 / 主密码”功能。理由：Mac 用户更习惯钥匙串自动管理；本地主密码虽然安全但 UX 不友好。
- 不上报加密统计到 LLM。理由：privacy by default，所有加密动作都不离开本机。

---

## 第 3 章 P0-3 文件加密 UI

- 主面板为左右两栏（左 = 待处理列表 + 拖拽 + 选择；右 = 密码 + 操作 + 输出目录）。
- 批量并发用 `TaskGroup`；每个文件单独报告成功或失败。
- 钥匙串列表显示在解密 sheet 折叠区，只读按文件名列出。
- 拖放回调使用 `OrderedThreadSafeCollector`，在并发回调完成后按原始 provider 顺序收集 URL。

### 没动的与原因

- 不集成到白板或资料库导入链路。理由：文件加密仍作为独立工具中心；用户主动操作避免误加密。
- 不做“压缩后再加密”。理由：CryptoKit / FileManager 单独使用已经足够，减少额外路径和内存复杂度。

---

## 第 4 章 P0-4 菜单栏 + 开机自启

- `MenuBarExtra(.menu)` 内嵌在主 `App.body` scene 里，与主 `WindowGroup` 并列。
- `LaunchAtLoginService` 单例通过系统状态和 `SMAppService.mainApp` 注册表管理开机自启。
- 菜单栏内提供主窗入口、快速记录、开机自启开关、设置和退出。
- `SMAppService` 首次注册可能需要用户在系统设置批准；服务会回读实际状态并在失败时保留错误提示。

### 没动的与原因

- 菜单栏可见性没有独立隐藏 toggle；`MenuBarExtra` 一旦写入 `body` 就常驻。开机自启 toggle 则已在设置和菜单栏提供。
- LaunchAgent 方案**未采用**。理由：`SMAppService.mainApp` 是 macOS 13+ 官方 API，比手写 plist 更符合“和系统融合”；本项目最低部署版本仍是 macOS 15.0。

---

## 第 5 章 P1-1 几何画板

- 新增 8 个 Shape 类型（点 / 圆 / 弧 / 多边形 / 函数图 / 参数方程 / 极坐标 / 测量标记），全部继承 `WhiteboardShape` 协议。
- 旧 `whiteboards.json` 的 Codable 兼容性不能描述为“未知 enum case 被丢弃且其它对象不受影响”：Swift 合成 Codable 遇到未知 enum case 会使整个数组解码失败。当前 `StorageService`、`WhiteboardService` 和 P2P 历史数据读取失败时会复制 `.corrupted-<时间戳>` 隔离副本，并通过 `storageIntegrityIssue` 通知主界面告警；原文件不会在失败读取时被静默覆盖。
- 代数求值已弃用旧的 Foundation `NSExpression`，改为自研 tokenizer + 递归下降 parser（`AlgebraEvaluator`）：
  - 原因：旧实现的 Objective-C 异常不能被 Swift `catch` 接住，非法表达式可能直接崩溃；`pi`/`e`、函数名和 `ln` 语义也不可靠。
  - 现支持 `^`/`**` 幂（右结合）、`sin/cos/tan` 及反三角、`log/log10/lg/log2/ln`、`sqrt/cbrt/abs/exp/floor/ceil/round/trunc/pow/mod/atan2/hypot/min/max`、常量 `pi`/`e`、科学计数和 `y = ` 定义式前缀剥除。
  - 输入长度上限 512，递归深度上限 64；非法输入抛 `.parseFailed`，UI 显示“表达式无效：…”，不再崩溃。
  - 阶乘只接受有限、非负整数且不超过 170；超出范围返回不可用值，不继续无界计算。
- 函数图 / 参数 / 极坐标通过顶部菜单“插入”弹 sheet 输入；左侧对应工具在画布上单击也会弹同一个 sheet，不占用 canvas drag。
- 曲线类 Shape（函数图 / 参数 / 极坐标）新增 `origin: WhiteboardPoint?`（可选字段，旧 `whiteboards.json` 反序列化不受影响）：
  - 数学原点 (0,0) → 世界坐标；数学 y 轴向上、白板 y 轴向下，采样时统一 `worldY = origin.y - yMath`。
  - 位移只改 `origin`，不会篡改定义域或 y 窗口。
  - 命中判定 = 点到分段采样折线的距离；渐近线两侧使用不同 segment，不把非连续点连成一条线。
  - 插入时 `origin` 取当前视口中心；采样点数收敛到 `AlgebraEvaluator.maxSamples`。
- 弧 / 圆 / 多边形工具改为真正的拖拽绘制：圆 = 圆心+半径；弧 = A→B 的半圆；多边形 = 拖拽框内切正六边形。
- `AlgebraEvaluator` 采样丢弃 NaN/±inf；插入面板先校验区间 `min < max`，避免倒序 `ClosedRange` 前置条件崩溃。
- 角度单位支持数值后缀 `30deg`、`30°`、`0.5rad`；白板默认按弧度计算，输入单位后按角度计算。
- 测量工具链路已打通：画布点选目标 → 右侧“测量”面板按目标数生成标记；渲染时实时计算点间距离 / 三点夹角（顶点在中间）/ 闭合图形面积。

### 没动的与原因

- 测量不支持曲线长度 / 切线类量。原因：需要沿笔划折线积分与导数估计，交互也更复杂。
- 函数绘制**没有**自动轴 / 网格。原因：白板本身是自由画板，曲线插入时以视口中心为数学原点。
- 曲线采样目前仍可能在每帧重新求值；分段采样已经解决渐近线不断线，但还可以继续做采样缓存。
- 表达式**没有**完整复数 / 微积分 / 自动证明。原因：超出本期范围。
- 别名函数暂未全部加入，未知记号会抛 `.parseFailed` 并在 UI 显示“表达式无效”。

---

## 第 6 章 P1-2 AI 视觉

- `LLMConfiguration.supportsNativeVision` 是 provider 判定：`LM Studio = false`，OpenAI / Anthropic 为 `true`。
- 多模态格式：
  - OpenAI：`messages.content` 是数组 `{type: text|image_url}`；
  - Anthropic：`messages.content` 是数组 `{type: image, source: {type: base64, media_type, data}}` + `{type: text}`，且 system 在外层。
- 图片上传前 `LLMService.encodeForVision` 用 `NSBitmapImageRep` 缩放到 `visionImageMaxEdge`（默认 1280 px），以 JPEG `visionImageQuality`（默认 0.85）压缩再 base64。
- 图像理解开关现在真正参与请求路由：
  - 关闭：先由本地 `OCRService` 转成文本，再走普通文本 endpoint，图片不进入多模态请求体；
  - 打开且 provider 支持原生视觉：发送多模态 payload；
  - 打开但 provider 不支持：阻止图片请求，不静默上传。
- 第三方/远程 HTTP 地址必须经过 `LLMConfiguration` 的显式信任检查；API key 只写 Keychain，不写 `settings.json`。

### 没动的与原因

- `LM Studio` 仍没有做多模态适配。理由：本地服务的多模态路由与 OpenAI/Anthropic 的 JSON 多模态格式不同；关闭图像理解时会走本地 OCR。
- `visionMaxImages > 1` 当前 UI 仍接受，实际多图内联仍受请求上下文和服务能力限制。
- 本地 OCR 不是云端视觉模型，识别结果可能不准确；OCR 失败时当前请求会失败，不发送图片。

---

## 第 7 章 P1-3 学习偏好本地调优

- `LearningPreferenceAutoTuner` 完全离线：从 `StudyMaterial.keywords` / `WrongQuestion.knowledgePoints` + 复习计划完成率，三路信号合并。
- `mergeMode`：
  - `.fillMissing` 仅在用户没填该字段时填充，避免覆盖用户手动改过的；
  - `.overwrite` 强制覆盖（保留作“ 重置+自动 ”选项，本期 UI 仅暴露 `fillMissing`）。

### 没动的与原因

- 不自动调用 LLM 做行为画像。理由：本地统计对用户**已发生**的数据已经能给到足够有用的画像；调用 LLM 是开销大、对中文学习场景 prompt 设计复杂的两难。
- 不做“主题画像 + 复习推送”个性化编排。理由：触发链跨数据 + 推送 + 提醒，当前只把画像和已有应用内复习队列做好。

---

## 第 8 章 P2-1 白噪音

- 6 个声源全部用算法（`NoiseGenerator`）生成 10–14 s 的 PCM buffer，再 `scheduleBuffer(.loops)` 循环。`AVAudioEngine` 不引第三方音频文件。
- 雨声 = 白噪底 + 25 Hz 平均脉冲；海浪 = sin 调幅 + 散高频；森林 = 粉噪 + 鸟鸣短促正弦。
- 粉噪用 Voss-McCartney，行数 16；棕噪用累计随机游走 + 钳位。
- 用户可以导入本地音频；导入和读取时使用 security-scoped access 的成对 start/stop。

### 没动的与原因

- 不支持实时调节 EQ / 立体声。原因：`AVAudioEngine` 的 EQ chain 会增加复杂度，本期不做。
- 不做跨声源的统一混音控制台。理由：当前每个声源已有独立播放节点和音量；统一混音另立一期。

---

## 第 9 章 P2-2 许愿/还愿

- 背景用 `TimelineView(.animation(minimumInterval: 1.0/30.0))` 驱动 `Canvas` 重绘，30 FPS 足够。
- 70 颗星使用 seed 稳定的伪随机分布；用户多次刷新页面位置一致。
- 流星 6 秒周期出现在窗口期内。
- 渐变背景：上半深蓝 → 下半深紫。
- 许愿和已还愿分别显示，可标记已还愿、恢复为许愿中和删除。

### 没动的与原因

- 不支持动画性能自适应。理由：30 FPS 在 M1 上稳定；后续可换 Metal 或 SKView。
- 不做“许愿分享”匿名社区。理由：用户原话“本地星空背景的私人页面”，非云端。

---

## 第 10 章 P2-3 倒数纪念日

- 三种重复：
  - `.once` 固定日期，仅一次；
  - `.yearly` 滚动到下一个匹配 (month, day)；
  - `.monthly` 滚动到下一个匹配 (day)，自动跨年。
- `nextOccurrence` 用 `Calendar.dateComponents` 逐步尝试，**有 8 / 60 次循环 guard** 防止 panic。
- 通知走 `UNUserNotificationCenter`；`shouldNotify` 以“发生日”生成 key，成功投递后才写入 `lastNotifiedYearMonthDayKey`，避免重复提醒。
- 当前界面通过“检查通知”按钮请求权限并检查；后台查询入口只查询授权，不主动弹权限框。

### 没动的与原因

- 不接 `EventKit` 写系统日历 / 提醒事项。理由：当前产品决策是纯本地表 + 系统通知，避免额外授权和重复数据源。
- 不实现农历。理由：需自带农历表或引入独立日期实现，工作量独立成一期。
- 不支持复杂 cron 表达式。理由：当前 3 档覆盖普通用例，复杂规则留给用户手动删建。

---

## 第 11 章 P2-4 Siri / App Intents

- 8 个 `AppShortcut`（资料库 / 番茄钟 / 待办 / 白板 / 文件加密 / 许愿 / 纪念日 / 快速记录），另有带页面参数的 `OpenPageIntent`。
- `SmartNoteShortcutsProvider` 返回 `[AppShortcut]`，每个短语包含 `\(.applicationName)` 占位符。
- `SharedAppStateProxy` 单例桥：AppState.init() 在 MainActor 上 bind 自身，Intent perform 时读写 selectedTab。
- Siri / Shortcuts 章节中的 tab 数字必须与 `ContentView` 的实际 `NavigationLink(value:)` 对照；当前仍是裸数字路由，重构时应集中为页面枚举。

### 没动的与原因

- 不实现 `EntityQuery`（如“打开最近的笔记”）。理由：Siri 短语里嵌入参数已能覆盖日常使用；实体查询需要数据模型联合 LLM 跑相似度，复杂度单独成期。
- 不做 SiriKit legacy（`INApp`、extension）。理由：`AppIntents` 已覆盖当前 macOS 15.0 部署目标。
- 状态桥**不**做持久化跨 launch 唤醒。理由：Siri 调起来 App 会重新启动，selectedTab 重置为 0 即可。

---

## 第 12 章 P2-5 高级计算器

- 三模式（标准 / 科学 / 程序员）共用一个 `CalculatorEngine`，输出按 mode 切换格式化。
- 普通数学表达式走自研 `AlgebraEvaluator` tokenizer + 递归下降 parser；科学函数、`x²`、`x³`、`x!`、括号和模运算也在安全求值边界处理。
- 程序员模式使用 `Int64` 精确路径，按当前进制解析，不把大于 2^53 的整数先转成 `Double`；加减乘、移位、幂和取绝对值均做溢出检查。
- 计算器中的百分号按计算器语义处理（例如加减百分比使用当前操作数作为基数），不会把它和 `AlgebraEvaluator` 中的一般模运算 `%` 混为一谈。
- `x²` / `x³` 是一元函数，不是二元操作；科学模式支持角度 DEG/RAD 边界转换。
- 用户输入：
  - 数值按钮 → `appendDigit`；
  - 操作符按钮 → 把当前 display 推到 `expression`，把操作符加入表达式；
  - 等号 → 安全 parser 求值，非法表达式显示错误。

### 没动的与原因

- 未实现复杂记忆（M+, MR, M-, MC）跨模式。理由：v1.7 只在标准模式暴露 MC/MR/M+/M-；科学与程序员模式下 math 操作更复杂，留待 v1.8 设计“按操作上下文解释 M+ 的值”。
- 不做“表达式回放 / 撤销历史”。理由：支持会引入 redoStack，复杂度 +1。
- 不做“单位换算（cm↔inch 等）”。理由：与计算器学科跨度大，独立成更合适。

---

## 第 13 章 构建与基础设施

- `xcodegen generate` 每次新增 Sources 文件后必须跑一次，把 `*.swift` 注入到 `project.pbxproj` 的 `Sources` build phase 里。
- `xcodebuild -project SmartNote.xcodeproj -scheme SmartNote -configuration Debug -destination 'platform=macOS'` 是本地编译 + 错误检测的可靠路径。
- AppleArchive 不是本项目实装的 ZIP 路径。理由：`ditto` 命令行调用足够；AppleArchive API 复杂，开销大于收益。

### 没动的与原因

- 不引 SwiftLint / Pre-commit hook。理由：项目当前尚未配；后续 v1.8 可加。
- 不写 CI script。理由：项目当前没有 `.github` 目录；本地构建足够。

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
| `d3533b9` | chore(release): 1.7.0 — README / notes / 版本号 | README.md, docs/notes.md, project.yml |
| `5042ed1` | fix(whiteboard): 几何画板修复 | AlgebraEvaluator.swift, WhiteboardCanvasView.swift |
| `54dadb7` | chore(release): 2.0.0 — 版本与构建配置 | project.yml, Info.plist |
| `f177183` | fix(security): P2 安全边界 + P3 正确性 + P5 工程卫生 | 多模块安全与正确性修复 |
| `a0a2ab6` | docs: 同步 README 与实施笔记到真实实现 | README.md, docs/notes.md |
| `b271997` | feat(diary): 日记加密设置入口 | DiaryEncryptionSettingsView.swift |
| `e5e96fe` | feat(theme): 2.0.0 国庆版主题系统 | AppTheme.swift, AppState.swift, SmartNoteApp.swift, SettingsView.swift |
| `3896532` | feat(blessing): 每日祝福与换一句 | BlessingService.swift, ContentView.swift |
| `49733d6` | feat(history): 中国近代史离线科普 34 篇 | HistoryArticle.swift, HistoryService.swift, HistoryHomeView.swift, HistoryArticleDetailView.swift, history_catalog.json, StorageService.swift |
| `a871ac3` | docs: 2.0.0 README 重写与实施笔记同步 | README.md, docs/notes.md |
| `73e4ad9` | docs: 回填 2.0.0 四个 commit 的实际哈希 | docs/notes.md |
| `e2c94ab` | fix(history): 修正来源链接与数字口径 | history_catalog.json |
| `183efcd` | feat(background): 背景图支持图片库与随机轮换 | AppState.swift, StorageService.swift, SettingsView.swift, ContentView.swift |
| `e909cbf` | feat(wish): 许愿改为独立全屏窗口；白板暂时关闭 | SmartNoteApp.swift, ContentView.swift, WishView.swift |
| `945ba0f` | docs: 同步背景图库、许愿全屏与白板暂时关闭 | README.md |
| `9c94a62` | docs: 新增第 19 章记录本轮改动 | docs/notes.md |
| `8e22762` | chore: 排除 .DS_Store 并取消跟踪 | .gitignore |
| `a1baaf3` | chore: 取消跟踪 xcuserdata 并加入忽略 | .gitignore |
| `5019fe2` | fix(ambient): 修复白噪音点击播放无反应导致进程终止 | AmbientSoundService.swift |
| `aa8b74b` | fix(ui): 修复祝福条时有时无并加顶部间距 | AppState.swift, ContentView.swift |
| `9931d4b` | fix(ui): 修复窗口缩放时侧栏变形与内容裁切 | SmartNoteApp.swift, ContentView.swift, WhiteNoiseView.swift 等 |
| `5058fa1` | fix(ambient): 移除白噪音页面的布局反馈循环 | WhiteNoiseView.swift |
| `9369db8` | fix(ui): 祝福条改用 safeAreaInset 并压平外观 | BlessingService.swift, ContentView.swift |
| `2bb9375` | fix(ui): 侧栏可滚到底，祝福条下移并固定位置 | ContentView.swift, BlessingService.swift |
| `e9528b7` | chore: 同步 Xcode 自动写入的工程设置 | project.pbxproj, entitlements |
| `c0c76f0` | docs: 恢复 README 原结构，仅补充新功能说明 | README.md |
| `fd315dc` | feat(theme): 三个节庆主题各绑定一张内置背景图 | AppTheme.swift, StorageService.swift, ThemeBackgrounds |
| `ba4b26f` | feat(theme): 节庆主题锁定背景并保护内置素材 | AppState.swift, SettingsView.swift |
| `a6cd827` | fix(blessing): 祝福条移到底部并避让侧栏 | ContentView.swift, BlessingService.swift |
| `aa7301a` | chore: 注册 ThemeBackgrounds 资源目录 | project.pbxproj |

发布更新日志与 B 站发布稿位于 `~/Desktop/Update200.md` 和 `~/Desktop/Pub.md`，不属于仓库内容。以上四个 commit 均为本地提交，未 push。

---

## 第 15 章 历史问题与当前结论

- `PDFService` 现在提供 instance method `extractText(from:) -> String?`（用 PDFKit 逐页拼接），`SmartGradingView` 的调用链已有对应实现。
- 当前项目以 `/usr/bin/ditto` 替代 ZipFoundation，以 `AlgebraEvaluator` 替代旧的 Foundation `NSExpression` 路径，以 `SMAppService` 替代 LaunchAgent plist，以 `UNUserNotificationCenter` 承担通知请求；这些都是“不引第三方”约束下的系统方案，不代表这些 API 本身没有限制。
- 旧数据迁移、解码失败隔离和恢复回滚的当前行为分别见第 1、5、16 章；不能再用“失败对象被静默丢弃”描述 Codable 行为。

---

## 第 16 章 本轮安全与正确性修复

### P0：崩溃与输入边界

- **复习计划除零 / 倒序 Range**：`CalendarService.generateReviewPlan` 对空主题、最少一天、索引乘法、结束索引和区间方向都做 guard；不再用可能为 0 的除数或倒序切片构造 `Range`。相关实现见 `CalendarService.swift`、`ReviewPlanView.swift`。
- **计算器求值器**：计算器和白板统一使用 `AlgebraEvaluator.swift` 的 tokenizer + 递归下降 parser，移除当前计算路径对 Foundation `NSExpression` 的依赖；阶乘限制在可表示范围，程序员模式走带溢出检查的 `Int64`，见 `CalculatorEngine.swift`、`CalculatorView.swift`。
- **URL 构造安全化**：现存 `URL(string:)` 构造点均改为可选解包 + `guard` 或 `URLComponents` 校验；源码中不再有 `URL(string:)!` 直接强解包，相关入口见 `UpdateService.swift`、`LLMService.swift`、`AIChatView.swift`、`MarkdownView.swift`。
- **LLM JSON 首尾顺序校验**：`LearningAnalysisService.parseAnalysisResult` 先确认首个 `{` 不晚于最后一个 `}`，再截取并解析，避免响应前后噪声或倒序括号造成错误切片，见 `LearningAnalysisService.swift`。
- **P2P 昵称 UTF-8 截断**：`P2PNicknameCodec` 按 UTF-8 byte 计数，并在 Character 边界截断，不会把多字节字符从中间切开，见 `P2PNetworkService.swift`。
- **Unicode 搜索高亮**：`MaterialsListView.highlightedName` 使用 `String` 的 `range` 和 `String.Index` 切片，不再把 UTF-16 offset 当作 Unicode 字符索引，见 `MaterialsListView.swift`。
- **解析器长度 / 深度上限**：`AlgebraEvaluator` 限制输入长度 512、递归深度 64，采样点数也收敛到 `maxSamples`，见 `AlgebraEvaluator.swift`、`GeometryModel.swift`。

### P1：数据完整性与一致性

- **白板 / 通用解码失败隔离**：`StorageService.load`、`WhiteboardService` 和 P2P 历史读取在失败时保留原文件，复制 `.corrupted-<时间戳>` 隔离副本，并广播 `storageIntegrityIssue`；主界面 `ContentView` 显示告警横幅，失败读取本身不静默写回空数组，见 `StorageService.swift`、`WhiteboardService.swift`、`P2PService.swift`、`ContentView.swift`。
- **受管数据清单化**：`StorageService.ManagedDataPath` 统一列出 JSON、目录和运行时发现的 `.corrupted-*` 文件；`clearAllData()` 按清单逐项清理并删除受管 Keychain 条目，见 `StorageService.swift`。
- **备份移出数据目录 + 恢复回滚**：`BackupService` 将新备份放到数据根目录同级，迁移旧目录；恢复先在外部临时目录校验，再用旧目录改名保留、同卷切换，失败时回滚，见 `BackupService.swift`、`SettingsView.swift`。
- **番茄钟时长统计**：`PomodoroTimer` 用 `studySession.duration` 记录专注阶段实际累计秒数，停止和阶段完成都走一次性记录路径，通知失败不会回滚统计，见 `PomodoroTimer.swift`。
- **考试倒计时单一真相源**：`AppState.examCountdowns` 是唯一真相源，持久化到 `examCountdowns.json`；`settings.json` 只保留旧字段读取兼容，不再用旧设置快照覆盖当前列表，见 `AppState.swift`、`StorageService.swift`、`ExamCountdownView.swift`。
- **白板退出 flush 与真实保存状态**：`SmartNoteApp` 在后台和 `willTerminate` 同步调用 `flushPendingSave()`；`WhiteboardService` 维护 `isSaving`、`hasPendingSave`、`lastSaveTime` 和 `lastSaveError`，保存失败不清掉待保存标记，见 `SmartNoteApp.swift`、`WhiteboardService.swift`。
- **P2P 后台开关持久化**：`p2pBackgroundEnabled` 进入 `AppSettings` 的 `Codable`、等值比较和编码路径，并由 `P2PService.setBackgroundEnabled` 读写；关闭时同时停止 listener 和连接，见 `StorageService.swift`、`P2PService.swift`。

### P2：安全边界

- **API key 迁移到 Keychain**：`LLMConfiguration.encode(to:)` 明确跳过 `apiKey`；`StorageService.saveSettings` 先写 Keychain 成功后才写不含凭据的 JSON，旧明文迁移失败时保留原文，见 `LLMConfiguration.swift`、`StorageService.swift`、`KeychainService.swift`、`LLMSettingsView.swift`。
- **第三方 / 远程 HTTP 显式信任**：地址先做 scheme/host 校验；非官方、非回环服务必须将信任绑定到规范化 URL，远程 HTTP 还会显示 API key 明文传输警告，见 `LLMConfiguration.swift`、`LLMSettingsView.swift`。
- **自更新先校验再旁路切换 + 回滚**：`UpdateService` 下载 ZIP 后先解压到独立临时目录，验证结构、Info.plist、Bundle ID、版本和体积，再复制同卷旁路文件并复验，切换/启动失败保留或恢复旧 App，见 `UpdateService.swift`。
- **自更新已知限制**：当前没有代码签名信任链；结构校验不能替代 Apple Developer ID / notarization 等签名验证，见 `UpdateService.swift`。
- **日记 AES-256-GCM 且 fail-closed**：当前日记格式为 `SND2`，正文使用 PBKDF2-HMAC-SHA256 + AES-256-GCM，nonce 每次随机生成，认证失败不会被当作空正文；加密开启但 Keychain 没有密码时保存失败，不降级写明文，见 `DiaryEncryptionService.swift`、`DiaryService.swift`、`DiaryEditorView.swift`；设置页「通用 → 日记加密」提供启用/关闭入口（`DiaryEncryptionSettingsView.swift`），密码、密保问题与答案只写入钥匙串，启用后立即清空输入框。
- **日记凭据入 Keychain**：密码、密保问题和答案只写 `KeychainService`；UserDefaults 只保存非敏感开关和迁移后的存在标记，旧明文迁移失败时保留旧数据，见 `DiaryEncryptionService.swift`、`KeychainService.swift`。
- **P2P 分帧 + AES-GCM + 指纹确认**：`P2PFrameAssembler` 处理 TCP 拆包/粘包和长度上限，`P2PCryptoService` 新消息使用带版本 envelope、随机 nonce 和 GCM tag，提供机密性与完整性；首次身份必须由用户核对 SHA-256 fingerprint 后确认，见 `P2PNetworkService.swift`、`P2PCryptoService.swift`、`P2PService.swift`、`P2PSettingsView.swift`。
- **图像理解开关真正生效**：关闭时由 `OCRService` 本地识别后只发文本；开启且 provider 支持时才构造多模态请求；不支持的 provider 阻止图片发送，见 `LLMService.swift`、`LLMSettingsView.swift`、`OCRService.swift`、`AIChatView.swift`。
- **WebView 去 CDN + CSP / 导航限制**：`RelaxGameView` 只加载包内 `ciallo/index.html`，使用非持久数据存储、禁止新窗口和入口 URL 以外的导航；HTML meta CSP 设置 `default-src 'self'`、`connect-src 'none'` 等限制，见 `RelaxGameView.swift`、`ciallo/index.html`。
- **权限声明对齐**：`Info.plist` 声明本地网络、日历和提醒用途说明；entitlements 声明日历/提醒和用户选择文件权限，见 `Info.plist`、`SmartNote.entitlements`。
- **security-scoped 访问与书签**：关联资料保存 security-scoped bookmark；文件扫描、导入、背景音、资料详情和图片拖放在异步 I/O 周围成对调用 `startAccessingSecurityScopedResource` / `stopAccessingSecurityScopedResource`，见 `StudyMaterial.swift`、`FileScannerService.swift`、`FileImportView.swift`、`AmbientSoundService.swift`、`MaterialDetailView.swift`、`AIChatView.swift`。

### P3：正确性与交互细节

- **待办统计按活动归桶**：`TodoService.statistics` 按期间创建、完成、番茄钟/手动计时增量确定活动任务，完成数按 `completedAt` 统计，历史时长按与统计桶重叠部分计算，见 `TodoService.swift`、`TodoItem.swift`。
- **日记字数互斥统计**：`DiaryEntry.countWords` 将 CJK 字符逐字计数，英文/数字按含字母或数字的 token 计数，标点和空白不再重复计数，见 `Diary.swift`、`DiaryService.swift`。
- **百分比四舍五入**：`ReviewPlanView` 和 `StatisticsView` 对非有限值归零、限制到 0...100，并使用 `.toNearestOrAwayFromZero` 四舍五入，见 `ReviewPlanView.swift`、`StatisticsView.swift`。
- **程序员模式按进制解析与 Int64 精确路径**：`CalculatorEngine.integerValue(from:base:)` 按 BIN/OCT/DEC/HEX 解析，程序员的加减乘、位运算和进制转换走 `Int64`，避免大整数经 `Double` 丢精度，见 `CalculatorEngine.swift`。
- **百分号 / x² / x³ 语义**：计算器百分号保留基数语义，`x²` / `x³` 走一元函数，不误解析为二元运算；见 `CalculatorEngine.swift`、`CalculatorView.swift`。
- **曲线分段采样**：`AlgebraEvaluator.sampleYSegments`、`sampleParametricSegments` 和 `samplePolarSegments` 在 NaN/±inf 或渐近线断点处分段，`GeometryModel` 和画布按 segment 绘制与命中，见 `AlgebraEvaluator.swift`、`GeometryModel.swift`、`WhiteboardCanvasView.swift`。
- **白板角度单位后缀**：数值后支持 `30deg`、`30°`、`0.5rad`，白板插入面板同步提示单位语义，见 `AlgebraEvaluator.swift`、`WhiteBoardView.swift`。
- **重复文件 SHA-256 + 内容二次确认 + 逐组确认清理**：`DuplicateScanner` 以 SHA-256 作为索引，再流式逐字节比较；扫描期间变化、摘要变化或内容不同的候选会跳过；UI 每组单独确认，清理前再次校验并移入废纸篓，见 `DuplicateScanner.swift`、`DuplicateScannerView.swift`。
- **拖放并发安全收集**：`OrderedThreadSafeCollector` 在异步 provider 回调中加锁，并按原始 index/sequence 排序；文件加密和 AI 图片拖放均使用它，见 `MarkdownView.swift`、`FileCryptoView.swift`、`AIChatView.swift`。
- **流式 Markdown 稳定 id + 解析缓存 + 50ms 节流**：`MarkdownStableID` 用内容散列和重复序号生成稳定身份，`NSCache` 缓存解析块，`ThrottledTextAccumulator` / `MarkdownRenderStore` 以约 50ms 节流并在结束时强制 flush，见 `MarkdownView.swift`。
- **通知授权 / 隐私 / 幂等**：`NotificationService` 区分授权状态，不在启动时主动弹权限框；通知正文使用中性内容而不放私密字段，稳定 identifier 和先删后加避免重复 pending 请求，纪念日只在真实成功后写去重 key，见 `NotificationService.swift`、`AnniversaryService.swift`、`PomodoroTimer.swift`。

---

## 第 17 章 仍未解决的限制

- **应用数据不是整体加密**：大多数资料、计划、设置和业务历史仍是本机明文 JSON；`StorageService` 管理的文件写入后尝试收紧为 0600、目录为 0700，但这不是磁盘加密边界。API key、日记密码/密保答案以及文件密码、P2P 私钥等专用凭据进入 Keychain；日记正文只有用户启用后才使用 AES-GCM。
- **备份 ZIP 未加密**：`BackupService` 生成的是普通 ZIP，设置页会提示用户自行保管；不能把备份当作加密快照。
- **自更新没有签名信任链**：`UpdateService` 有结构、Info.plist、Bundle ID、版本、体积和旁路回滚校验，但没有 Apple Developer ID / notarization 等代码签名验证。
- **P2P 仍是裸 TCP**：没有 TLS 或证书式身份验证；当前没有防重放、防降级或经证书链的 MITM 防护。旧 AES-CBC 消息只为兼容读取，CBC 没有认证标签；新消息才走 AES-GCM。
- **App Sandbox 仍关闭**：`SmartNote.entitlements` 中 `com.apple.security.app-sandbox=false`。原因是安装到 `/Applications` 的更新流程、ditto/unzip 等外部进程、全量文件访问和 helper 授权尚未迁移到沙盒兼容流程；security-scoped 书签和用户选择文件访问已接入，但不能把它描述成已开启沙盒。
- **设置开关已接入但有条件**：`showFileExtensions` 已传入 `MaterialsListView` 并控制列表是否显示扩展名；`autoScanDirectories` 已在 `AppState` 启动路径读取，开启且 `scanPaths` 非空时才异步扫描。当前 `SettingsView` 仍没有路径编辑 UI，因此默认空路径不会触发启动扫描。

这些限制是有意的已知边界，不应被 README 的功能列表包装成端到端加密、自动云同步或完整代码签名更新。

---

## 第 18 章 2.0.0 国庆版：主题、祝福与近代史科普

本轮版本定位为 `2.0.0` 国庆版，构建号继续使用 `100`（当前仓库没有已发布的 `v2.0.0` GitHub Release；发布前仍需确认远端资产状态）。

### 主题系统

- `AppSettings.themeID` 新增 `classic`、`nationalDay`、`auspicious` 三个值，并通过手写 `Codable`、默认值和 `Equatable` 持久化到 `settings.json`。
- `AppState.activeThemeID` / `activeDarkModePreference` 是根场景即时刷新的外观快照；设置页通过 `setTheme` / `setDarkModePreference` 更新并显式保存，避免嵌套 `AppSettings` 的变更无法转发到 `AppState`。
- `AppTheme` 通过 SwiftUI Environment 注入主窗口、日记编辑器、设置窗口和菜单栏；经典主题不覆盖系统 tint，节庆主题才提供全局强调色。
- 经典主题继续遵循「跟随系统 / 浅色 / 深色」；两种节庆主题使用自带深色对比度方案，避免红金主题与浅色系统控件混用时失去可读性。
- 背景图片仍由 `BackgroundImageView` 叠加在主题底色之上，没有改变用户已有的背景图、透明度和模糊设置。
- 主题切换只改变视觉层，不修改资料、计划、AI、文件处理或 P2P 业务行为。

### 每日祝福

- `BlessingService` 分为全年祝福库和国庆期间祝福库，使用当前日期稳定选取；国庆期间（10 月 1—7 日）显示国庆标签和节庆文案。
- 「换一句」从当前适用库中排除当前条目后随机选择另一条；祝福不联网、不调用 LLM，也不写入用户资料。
- 祝福条只在节庆主题或国庆期间显示，避免普通经典主题长期占用主界面空间；长文案显示两行并提供完整提示。

### 中国近代史科普

- `SmartNote/Resources/history_catalog.json` 是随应用打包的只读目录，首批 34 篇文章覆盖 1840—1949 的时间线与主题节点；`HistoryPeriod` 是主题导览分组，不作为严格年份边界，跨时期文章保留在最能帮助理解的主题组中。
- `HistoryService` 从 `Bundle.main` 读取并校验目录，按标题、摘要、正文、事件、人物、术语和标签搜索；目录为空、缺失或损坏时显示真实错误，不返回固定文章兜底。
- 收藏、分段已读、整篇完成、最近阅读和随机学习状态独立保存到 `historyProgress.json`；该文件加入 `ManagedDataPath`，因此会参与存储统计、备份和「清除所有数据」。
- 首页提供最近阅读横向卡片、随机文章提示和带确认的「清空阅读进度」；目录说明、时期主题说明和来源入口均从实际目录/状态读取。
- 详情页使用现有 `MarkdownText` 和 `SpeechService`，提供来源入口与关联阅读；历史目录是只读内容，不会被资料编辑流程改写。
- 目录采用本项目明确说明的 1840—1949 分期。重大条约、战争伤亡数字、评价性判断和来源口径保留继续查证入口，不将有限目录描述为完整历史。

### 构建与验证

```bash
source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate xijianBase
xcodegen generate
xcodebuild -project SmartNote.xcodeproj -scheme SmartNote \
  -configuration Debug -destination 'platform=macOS' build
xcodebuild -project SmartNote.xcodeproj -scheme SmartNote \
  -configuration Release -destination 'platform=macOS' build
```

本轮还应执行 JSON 结构校验、Release 归档内版本检查、`SmartNote.app.zip` 资源检查和主题/历史/祝福人工冒烟测试；实际结果记录在发布更新日志中。

### 本轮实际执行的验证

| 项目 | 结果 |
|------|------|
| Debug `xcodebuild build` | 通过 |
| Release `xcodebuild build` | 通过 |
| Release `xcodebuild archive` | 通过 |
| 归档 `CFBundleShortVersionString` / `CFBundleVersion` | `2.0.0` / `100` |
| 归档内 `history_catalog.json` | 存在，34 篇，可解析 |
| ZIP 解压后版本与资源 | `2.0.0` / `100`，资源完整 |
| 归档架构 | `x86_64 arm64` |
| 解压后启动冒烟 | 进程可启动并保持运行，无崩溃后停止 |
| 离线逻辑校验（复用生产源文件） | 1720 项断言全部通过 |
| `xcodebuild test` | 仓库没有 XCTest target，scheme 未配置 test action；不伪造通过 |

离线逻辑校验的做法：把 `HistoryArticle.swift`、`AppTheme.swift`、`HistoryService.swift`、`BlessingService.swift` 四个生产源文件直接编译为校验程序，只把存储层替换为同语义的临时实现（JSON 编解码、原子写、ISO8601 日期），覆盖目录加载与 ID/关联校验、搜索与时期/标签/收藏筛选、书名号归一化、收藏、分段已读与整篇完成判定、最近阅读去重与上限 8、随机学习、进度持久化往返、损坏文件不被覆盖、清空进度、祝福日期归属（逐日遍历全年）与换句、主题 tint 与未知值回退。该程序只存在于临时目录，不进入仓库，也不替代界面人工验收。

### 本轮修复与内容订正

- 主题原本嵌在 `AppSettings` 内，直接改属性不会让所有 Scene 刷新；改为 `AppState` 单独发布主题与明暗快照，设置页经 `setTheme` / `setDarkModePreference` 更新并显式保存。
- 经典主题原本也覆盖系统 tint；改为只有节庆主题设置 `tint`，经典主题保持系统观感。
- 最近阅读此前有数据但没有入口；已补上首页横向卡片。
- 未知 `themeID` 原本会让整份 `settings.json` 解码失败；`ThemeID.init(from:)` 改为回退 `.classic`。
- 损坏的 `historyProgress.json` 可能在用户下一次收藏时被静默覆盖；改为保留原文件并提示。
- 时期文案与年份范围表述不一致；统一为 1840—1949，并说明时期筛选是主题导览分组而非严格边界。
- 34 篇文章的「预计阅读时长」普遍偏大约 2.5 倍（正文仅约 200 字却标 4—6 分钟）。改为按详情页实际展示文字推算（约 300 字/分钟，下限 2 分钟），`readingMinutes` 不再从 JSON 读取，避免手写数字与内容长度脱节。
- 3 条来源链接（CASS 近代史研究所、国家图书馆民国专题、全国人大网）保持 `http://`：已实测这三个站点不提供 HTTPS（`https://` 连接直接失败），浏览器 UA 下 `http://` 可正常访问，因此不改写为不存在的 `https://` 地址；README 已知边界中已说明可能出现浏览器安全提示。

### 本轮明确的边界

- 主题不是对全部旧页面的逐控件重新设计；本轮通过根环境、强调色、主题表面和新增页面完成统一视觉层，保留固定语义页面（许愿星空、白板纸张、WebView 小游戏）的原有配色。
- 历史科普不提供图片、地图、音频、在线更新或 AI 自动写作；内容来源和授权边界仍需在后续扩充时逐条复核。
- `historyProgress.json` 是普通本机 JSON，不是加密存储；清除所有数据会按既有受管数据规则删除它。若进度文件解码失败，会保留原文件并隔离副本，不在用户下一次收藏操作时静默覆盖。

---

## 第 19 章 背景图库、许愿全屏与白板暂时关闭

### 背景图片库与随机轮换

- `AppSettings` 新增 `backgroundImageLibrary`、`backgroundImageRandomEnabled`、`backgroundImageActiveName`，并由 `effectiveBackgroundImageName` 决定实际渲染哪一张。随机模式取激活项，指定模式取锁定项 `backgroundImageName`。
- 旧 `settings.json` 只有 `backgroundImageName` 一个字段，解码时把它收进图片库，因此老用户升级后行为不变，不会出现「原来有背景图，升级后变空」。
- `AppState` 集中图片库逻辑：`addBackgroundImage` / `selectBackgroundImage` / `removeBackgroundImage` / `setBackgroundImageRandomEnabled` / `pickRandomBackgroundImage` / `syncBackgroundImageLibrary`。磁盘上的增删会同步回内存列表。
- 随机只在启动时和用户点击「换一张」时发生，不在使用过程中自行变化；`pickRandom` 会避开当前项，图片库只有一张时退回该张而不是取不到值。
- 模糊半径、透明度等既有效果对两种方式一致生效，`BackgroundImageView` 只改为读取 `effectiveBackgroundImageName`。

### 许愿改为独立全屏窗口

- 新增 `Window("许愿 · 还愿", id: "wish-fullscreen")` 场景，`defaultSize` 1280×800，最小尺寸从 900×540 提到 1000×620。
- 侧栏「许愿」从 `NavigationLink` 改为 `Button` + `openWindow(id:)`；`openWindow` 对同一 id 复用已有窗口，重复点击不会开出多个窗口。
- `DetailView` 中的 `case 24` 已移除，许愿不再是侧栏详情页的一项。
- 保留：许愿的星空背景、左右分栏、渐隐上浮动画和新建弹窗逻辑均未改动，只是承载窗口变大。

### 白板暂时关闭

- 侧栏「白板」`NavigationLink` 加 `.disabled(true)`，进入后显示 `WhiteboardUnavailableView` 占位页，说明维护状态与数据保留情况。
- `WhiteboardView.swift`、`WhiteboardCanvasView.swift`、`GeometryModel.swift`、`AlgebraEvaluator.swift` 等源文件全部保留未删，`whiteboards.json` 仍登记在 `ManagedDataPath` 中参与存储统计、备份与「清除所有数据」，重新开放后可直接续用。
- 原因：几何画板存在用户报告的显示异常（含顶部持续存在的模糊空白条）。在未定位根因前先下线入口，避免继续产生半可用状态；`BackgroundImageView` 的模糊层被所有页面共用，不宜在根因未确认时改动。

---

## 第 20 章 UI 布局与白噪音播放修复

本轮按用户实测反馈修复。四个问题分属两类根因：嵌套 `ObservableObject` 的读取时机，以及互相冲突的最小尺寸约束。

### 白噪音点击播放无反应（真实崩溃，非无响应）

- 根因不是按钮失效，而是**进程被 AVAudioPlayerNode 抛出 ObjC 异常直接终止**。`ensurePlayer` 用 `engine.connect(player, to: mixer, format: nil)`，player 因此采用 `mainMixerNode` 的输出格式（本机为 48kHz 立体声），而内置声源与用户文件的 buffer 是 44.1kHz 单声道。`scheduleBuffer` 时前置条件 `_outputFormat.channelCount == buffer.format.channelCount` 不成立，抛出 Swift `try` **无法捕获**的 NSException，进程 abort。
- 已用独立程序逐个验证三种接法（每种单独进程，避免异常中断整批）：`format: nil` → 崩溃；`format: mixer.outputFormat`（48k/2ch）→ 同样崩溃；`format: 44.1kHz mono` → 正常，`isPlaying=true` 持续。
- 修复：`connect` 显式传入 44.1kHz 单声道，与 buffer 一致；立体声混音交给 `mainMixerNode`。修正后按生产链路复测 10 步全通过（engine 启动、schedule、播放、停止）。
- 同时新增 `AmbientSoundService.lastError`：播放失败时写真实原因，界面顶部显示橙色提示条并可关闭，不再静默无反应。

### 祝福条时有时无

- 根因同属嵌套 `ObservableObject`：`ContentView` 的 `@EnvironmentObject` 是 `AppState`，而 body 里直接读 `appState.blessingService.isNationalDayPeriod`。`BlessingService` 变化不会让只 observe `AppState` 的视图重算，国庆期间可能出现整条不出现。
- 修复：`AppState` 新增 `@Published isNationalDayPeriod` 快照与 `shouldShowBlessingBar`，在 `init` 与 `loadSavedData()` 中同步；`ContentView` 改读 `appState.shouldShowBlessingBar`。这与第 18 章处理 `themeID` 的做法一致。
- 另按反馈给祝福条加 `.padding(.top, 8)`，不再贴着窗口标题栏。

### 窗口缩放时侧栏变形、内容显示不全

- 根因是尺寸约束层层叠加：`SmartNoteApp` 主窗口 `.frame(minWidth: 900, minHeight: 600)`，`ContentView` 的 `NavigationSplitView` 又重复一次 `.frame(minWidth: 900, minHeight: 600)`，而各详情页还有各自更大的 min（文件加密 900、白噪音 800、许愿 1000）。SwiftUI 取最大者作为实际下限，窗口被强行撑大，缩小时侧栏被挤压变形、卡片被裁切。
- 修复：
  - 移除主窗口与 `NavigationSplitView` 上重复的 900×600，改用 `.defaultSize(width: 1280, height: 820)`；
  - 侧栏只保留 `.frame(minWidth: 190)`，不设固定高度，高度交由 `NavigationSplitView` 分配；
  - ~~白噪音用 `GeometryReader` 按可用宽度算列数~~（**此实现有缺陷，已废弃，见下方复盘**）；
  - 文件加密 900→560、纪念日 720→520、计算器 520→380、重复清理 520→360；
  - 白噪音新增播放错误提示条。

### 仍未处理

- 几何画板的模糊空白条：白板已下线，该现象当前不可复现；`BackgroundImageView` 模糊层被所有页面共用，在根因未确认前不改动。
- 番茄钟 200pt 计时圈、各处 sheet 的固定尺寸属于设计选择，不影响缩放，保持原样。
- 界面仍缺人工验收：仓库没有 XCTest target，上述修复依赖独立程序验证与架构分析，无法自动断言渲染结果。

### 复盘：上一轮的白噪音「修复」引入了更严重的缺陷

上面「白噪音用 GeometryReader 算列数」这一条本身是错的，并且它同时解释了后续反馈的三个症状。

- 当时用 `GeometryReader` 包裹整页，再用 `columns(forWidth: geo.size.width)` 决定列数。列数依赖容器宽度，而容器宽度又受列数与卡片最小宽度影响，构成**布局反馈循环**。SwiftUI 无法收敛，持续重排布局。
- 表现：进入白噪音页面后界面卡死 → 播放按钮点不动（**并非音频问题**）→ 也无法切换到其它功能，只能强退。因此「播放点不了」和「进来了出不来」是同一根因。
- 修复：改用 `GridItem(.adaptive(minimum: 200, maximum: 320))`，由 SwiftUI 依据可用宽度自行排布，视图不再读取自身尺寸，无反馈环；移除 `columns(forWidth:)` 与 `GeometryReader` 包装；`minWidth/minHeight` 收敛到 420×340。
- **教训**：在 SwiftUI 中用 `GeometryReader` 读取尺寸后，再据以改变**会影响该尺寸本身**的布局属性（列数、宽度约束等），是高风险反模式。已全局排查其余 `GeometryReader`：`DiaryStatisticsView` 与 `TodoStatisticsView` 只用其宽度绘制固定 16pt 高的进度条，不反影响容器尺寸，安全；`WhiteboardCanvasView` 属白板范畴，暂不处理。

### 祝福条外观与安全区（第二轮修正）

- 上一轮把祝福条作为 `NavigationSplitView` 的**同级兄弟**放进 `VStack`，导致 split view 拿不到正确的安全区 inset，侧栏 `List` 底部被裁掉——这是「菜单栏依旧显示不全」的根因。正确做法是 `.safeAreaInset(edge: .top, spacing: 0)`。
- 外观臃肿的根因是 **padding 叠加**：`ThemeSurface` 内部已有 16pt，组件自身再加水平 12 / 垂直 8，调用处再加顶部 8，实际垂直达 32pt、水平 28pt。改为不使用 `ThemeSurface` 的单层扁平板（10pt 圆角、1pt 描边、无阴影），内边距只在一处设置。
- 文案由 `caption` 降为 `caption2`，标题与正文各限一行；换一句按钮改为无边框图标，避免撑宽窄条。

### 本轮验证结果

| 项目 | 结果 |
|------|------|
| Debug `xcodebuild build` | 通过 |
| Release `xcodebuild archive` | 通过，SHA-256 `377e88db…` |
| 归档版本 / 构建号 | `2.0.0` / `100` |
| 解压后启动冒烟 | 运行中未崩溃，无异常日志 |
| 白噪音页面无 `GeometryReader` | 确认（仅注释中出现） |
| 祝福条无 `ThemeSurface` 叠加 | 确认 |
| 音频链路按生产代码复测 | forest 声源 529,200 帧 / 30 次鸟鸣生成正常，`scheduleBuffer` 与 `play()` 成功，`isPlaying=true` |

**需要写清的判断**：白噪音「播放点不了」不是音频缺陷，而是上一轮布局缺陷导致页面无响应。音频服务本身此前已修好（`connect` 格式），本轮复测确认仍然正常。

---

## 第 21 章 主题背景绑定、锁定与自动恢复

### 主题结构调整

- `AppSettings.ThemeID` 新增 `snowDawn`；`AppTheme` 补上「雪山晨曦」（冷调靛蓝 + 晨光金），与「国庆红」「祥云金」构成**三个节庆主题**，经典主题保持无背景绑定。
- `AppTheme.all` 提供界面展示顺序；`AppTheme.bundledBackgroundName` 声明该主题强制使用的素材名，经典主题返回 `nil`（留空或用用户自己的图）。
- 三张国庆主题图放入 `SmartNote/Resources/ThemeBackgrounds/`，随应用打包。XcodeGen 将其拷到 `Contents/Resources` 根目录，因此 `StorageService.bundledBackgroundURL` 先按根目录查找、再回退到子目录，避免因打包路径变化导致找不到。

### 锁定行为

- `setTheme` 触发 `applyThemeBackgroundLock`：节庆主题强制启用背景、关闭随机、把指定与当前图都指向自带素材，并确保该素材在图片库中。
- 切回经典主题时解除锁定，恢复用户此前的随机与指定设置。
- 锁定期间 `addBackgroundImage` / `selectBackgroundImage` / `setBackgroundImageRandomEnabled` / `pickRandomBackgroundImage` 全部提前返回，界面对应控件同步禁用。
- `pickRandomBackgroundImage` 改为只在用户图片中挑选，不会随机到内置素材。

### 内置素材保护与自动恢复

- `StorageService.isBundledBackground` 标记受保护素材；`removeBackgroundImage` 与 `clearUserBackgroundLibrary` 都跳过它们，「清空我的图片」只处理用户导入的图。
- `restoreBundledBackgroundsIfMissing` 在启动时校验，被删除的素材从应用包重新拷回。`syncBackgroundImageLibrary` 保证内置素材始终出现在图片库中，不会被磁盘清理误伤。
- 恢复失败时写入 `AppState.restorationFailedBundledImage`，设置页显示提示而不是静默失败。

### 修复：锁定结论未落盘

`prepareBackgroundImage` 修改了 `appSettings` 的多项属性（背景启用、随机开关、指定图、当前图、图片库），但**没有调用 `saveSettings`**，因此每次启动都从旧值重新推导，主题锁定表现得时有时无。已在函数末尾统一落盘。这个缺陷是靠「启动后读取真实 settings.json 复核」发现的——内存状态正确但磁盘值没变，纯看代码路径不容易察觉。

### 祝福条位置与避让

- 从顶部安全区改为**底部安全区**，与窗口底部的距离固定，不随窗口尺寸变化。
- 左侧按侧栏实测宽度让开：用 `PreferenceKey` 采集 `NavigationSplitView` 侧栏宽度，`.padding(.leading, isSidebarVisible ? sidebarWidth : 0)`；侧栏隐藏时（`columnVisibility == .detailOnly`）自动铺满整个底部。
- 高度固定 38pt，标题与正文各 `lineLimit(1)` + 截断，文案长短或窗口宽窄都不改变高度，不会把内容顶出可视区；文字区 `layoutPriority(1)`，保证「换一句」按钮不被挤出。

### 验证

| 项目 | 结果 |
|------|------|
| 主题逻辑回归（独立程序） | 43 项断言全部通过 |
| 归档内含三张主题背景图 | 通过（`Contents/Resources/`） |
| 空数据目录首次启动 | 自动恢复 3 张素材 |
| 手动删除 2 张后重启 | 2 张自动补回 |
| 真实数据启动后 settings.json | `themeID=nationalDay` 时锁定项与当前图均为 `nationalDay.png`，随机已关闭（落盘生效） |
| Release 归档 | 通过 |

### README 结构调整的教训

`a871ac3` 曾把 README 从 20 章的逐功能手册整体改写为产品定位式短文（删 393 行、增 98 行），超出「补充功能说明」的范围，属于越界。`c0c76f0` 已恢复原结构，改为纯增量：0 行删除、51 行新增，只在目录追加两章，并在 5.3 许愿、11 白板、15 外观三处做定点补充。

**规则**：README 与 docs 可以在既有结构内增补和修改功能描述，但不得调整章节顺序、编号或整体体例。新增功能优先追加到末尾章节以免重排既有编号。

### 历史内容来源审计

本轮对 34 篇文章的 14 个来源 URL 与全部数字类断言做了逐条核验（curl 复验 + 原始文献比对），修正内容见 `e2c94ab`。要点：

- `gov.cn/guoqing/2020-10/29/content_5555766.htm` 是真死链（站点改版后 404，返回 JS 跳转壳）；改用香港中联办转载的同一文档 `locpg.gov.cn`。该文档只有朝代年代对照，不含条约与事件日期，8 篇文章中「用于核对关键年份」一类 note 相应收窄。
- `loc.gov/item/2021666890` 原本被标为「数字馆藏与历史地图」并置于《教育、报刊与电影》，实际是 1932 年国际联盟李顿调查团报告书；已改归《九一八事变与局部抗战》，并在原文删除错误条目。
- 东京审判判决书改用 `tile.loc.gov` 直链（4.3MB / 137 页），避开 `www.loc.gov` 的 Cloudflare 挑战。已下载该 PDF 并用 pypdf 定位到 p.1014 原文：*over 200,000*、*more than 155,000 bodies*。
- 南京军事法庭判决原文（维基文库《国防部审判战犯军事法庭判决》）确认为「十九万余人」+「十五万余具」+「被害总数达三十万人以上」。
- `history.state.gov/.../frus1895p1/d203` 在本机网络不可达，但经检索确认为 1895 年《马关条约》英方存档文本，引证正确，保留并把标题改精确。
- 4 个实质数字口径订正：《辛丑条约》4.5 亿两为本金、本息约 9.8 亿两（据维基文库原文「九百八十二兆二十三万八千一百五十两」）；《南京条约》2100 万银元为第四、五、六款之和；虎门销烟「导火索」改标准术语「导火线」并补三层因果；南京大屠杀删去易引发中外对立的措辞，改按判决时间先后叙述。

**内容性质的边界**：历史正文是依据公开文献整理的导览稿，不是逐句转录的原文抄录。来源链接提供可追溯入口供用户自行核对。数字类表述已逐条核对原始文献，但整个目录的每一句并未与全部学术文献逐条比对，不应宣称「绝对权威」。

### 本轮验证

| 项目 | 结果 |
|------|------|
| Debug `xcodebuild build` | 通过 |
| Release `xcodebuild archive` | 通过，SHA-256 `e58677bf…` |
| 归档版本 / 构建号 | `2.0.0` / `100` |
| 归档内 `history_catalog.json` | 34 篇，死链与误位条目均已清除 |
| 解压后启动冒烟 | 运行中未崩溃 |
| 背景图随机逻辑 | 单独验证三条不变量：空库返回 nil、单张库排除自身仍取到该张、多张库 3000 次采样分布 983/1003/1014 |
| 旧 `settings.json` 迁移 | 四种情况（旧版单图 / 未启用 / 无图 / 空对象）锁定项与模糊参数均不丢 |
| 来源 URL | 14 个中 13 个返回 200；`history.state.gov` 因本机网络不可达无法复验 |
| 白板下线后无悬空引用 | `WhiteboardView()` 已无调用点，源文件保留 |

`xcodebuild test` 仍不可用：仓库没有 XCTest target，scheme 未配置 test action，本轮不以任何方式伪造测试通过。
