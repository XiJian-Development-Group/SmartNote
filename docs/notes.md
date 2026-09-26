# SmartNote 实施笔记

> 配合 `README.md`（面向用户的产品说明）和 `project.yml`（构建配置）使用。本文件记录**实际做了什么、留了什么、为什么**。
>
> 章节按功能模块组织；每节末尾的「没动的与原因」保留有意留下的边界。涉及安全与正确性的修复统一汇总在「修复记录」章节。
>
> 部署目标：`Info.plist` 的 `LSMinimumSystemVersion=15.0`，构建配置见 `project.yml`。

---

## 0. 总原则

### 用系统原生接口，不引第三方

v2.0 阶段的所有新增功能用 macOS 系统 framework，不新增 SPM 依赖（`swift-markdown` 是历史依赖，本轮未替换）。

| 模块 | 选用 API | 关键边界 |
|------|---------|---------|
| 对称加密 | `CryptoKit` `AES.GCM` | 256-bit 密钥，96-bit nonce，128-bit auth tag |
| 密码与凭据 | `Security` Keychain | `kSecClassGenericPassword`，按 account/service 区分 |
| 备份 | `/usr/bin/ditto -c -k --sequesterRsrc --keepParent --zlibCompressionLevel 9` | 未加密 ZIP，不引 ZipFoundation |
| 菜单栏 | `MenuBarExtra` SwiftUI Scene | macOS 13+ |
| 开机自启 | `SMAppService.mainApp.register()` | 不用 LaunchAgent plist |
| Siri | `AppIntents` + `AppShortcutsProvider` | 不用 SiriKit legacy |
| 日历 / 提醒 / 通知 | `EventKit` + `UserNotifications` | 复习计划写日历；纪念日和通用通知走系统通知 |
| 白噪音 | `AVFoundation` (`AVAudioEngine` + `AVAudioPlayerNode`) | 算法生成 PCM buffer，循环播放 |
| 几何函数图 | `SwiftUI` Canvas + 自研 `AlgebraEvaluator` | tokenize + 递归下降 parser |
| AI 视觉 | `URLSession` + `NSImage` + Vision OCR | 原生视觉仅 OpenAI / Anthropic |
| 农历 / 计数 | `Foundation.Calendar` + `UNUserNotificationCenter` | 不接农历表 |
| 星空动画 | `TimelineView` + `Canvas` | 30 FPS，70 颗固定种子星 |
| 主题 | SwiftUI Environment + `AppTheme` | 四套主题，三个节庆主题锁定背景 |
| 祝福 | 本地日期索引 + 本地祝福库 | 国庆 10/1–10/7 自动切节庆文案库 |
| 历史科普 | `Bundle` JSON + `HistoryService` + 本地进度 JSON | 1840—1949 离线导览 |
| 计算器 | `AlgebraEvaluator` + `Int64` 精确整数路径 | 已弃用 `NSExpression` |

---

## 1. 资料库

- 扫描器识别的扩展名：PDF、DOC、DOCX、PPT、PPTX、PNG、JPG、JPEG、GIF、BMP、TIFF、TXT、MD。PDF 走 PDFKit 逐页抽文本，其他格式保留文件。
- 导入支持「复制到资料库」和「仅创建链接」。后者保存 security-scoped bookmark，访问时配对 `startAccessingSecurityScopedResource` / `stopAccessingSecurityScopedResource`。
- 资料正文修改走防抖自动保存；图片资料可在详情页点「文字识别」触发本地 Vision OCR，结果写回资料正文（不是云端 OCR）。
- 导出支持 PDF、纯文本、剪贴板复制。
- 资料详情页元数据：名称、分类、关键词、正文、关联文件路径、关联白板、图片路径等都是本机明文。

### 没动的与原因

- 不做全文检索索引。资料量级个人用够，SQLite 索引单独成期。
- 不做云盘 / 网盘同步。所有数据本机，避免引入第三方账号体系。

---

## 2. 学习工具

- **考点提取**：从选中资料的 `keywords` 提取候选考点；可选 AI 分析（依赖 `设置 → AI 分析`）。
- **AI 对话**：向配置 LLM 发文本请求；图片理解开关打开且 provider 支持时才发多模态，否则先本地 OCR 转文本再发；不支持原生视觉的 provider + 开关已开 → 阻止请求，不静默降级。
- **智能阅卷**：选资料或上传文件，标记用户答 / 原题 / 标准答案，向 LLM 请求批改 / 解释 / 相似题。

### 没动的与原因

- 智能阅卷不是离线题库系统。所有「标准答案」由用户在每次批改时显式提供，不做积累式评分模型。

---

## 3. 计划管理

- **考试倒计时**：`AppState.examCountdowns` 是唯一真相源，持久化 `examCountdowns.json`。`settings.json` 仍保留旧字段读取兼容，但不写回。
- **复习计划**：创建时按主题、天数生成任务；可请求日历权限创建 `EventKit` 事件。`CalendarService` 有提醒事项创建接口，但当前计划创建流程不自动调用。
- **待办清单**：标题、描述、标签、分类、状态、番茄钟关联、手动计时、提醒时间、按活动时间段统计。统计按 `TodoService.statistics` 的「期间创建/完成/番茄钟/手动计时增量」分桶，完成数按 `completedAt`。
- **习惯打卡**：按日期打卡，连续记录 + 历史。
- **学习统计**：资料数量、总大小、考点数量、分类占比、最近添加；番茄钟页另有专注时长、科目分布。

### 没动的与原因

- 不自动写系统提醒事项。理由：复习计划由用户在创建时显式触发日历事件；提醒事项接口留作未来扩展，避免双重数据源。
- 待办统计按活动时间段分桶，不做按天累计打卡曲线。

---

## 4. AI 分析（设置）

| 选项 | 行为 |
|------|------|
| 启用 AI 分析 | 总开关 |
| 提供商 | LM Studio / OpenAI / Anthropic |
| 服务器地址 | `http` / `https`；官方 HTTPS 与回环地址直接放行 |
| Token / API Key | 写 Keychain，不进 `settings.json`；旧明文迁移成功后从 JSON 剥离 |
| 模型 ID | 模型名 |
| Temperature | 0–1 |
| 最大 Token | 256–4096，步长 256 |
| 服务器支持图像理解 | LM Studio=false，OpenAI/Anthropic=true |
| 自定义系统提示词后缀 | 追加到每次请求 |

**地址与凭据边界**：

- 第三方 / 远程 HTTP 地址必须用户显式勾选信任，并提示 API key 将明文发送到目标主机。
- 图像理解关闭 → 本地 Vision OCR 转文本再发普通文本请求，图片不进多模态体。
- 图像理解打开 + provider 不支持 → 阻止图片请求，不静默降级。

---

## 5. 番茄钟

- 专注 5–60 分钟（步长 5）、短休息 1–15 分钟（步长 1）、长休息 5–30 分钟（步长 5）。
- 专注会话用 `PomodoroTimer` 记录 `studySession.duration`（实际累计秒数），停止和阶段完成都走一次性记录路径；通知授权失败 / 通知发送失败不回滚统计。
- 主题切换 / 后台进入不影响计时状态。

---

## 6. 错题本与背诵卡片

- **错题本**：手动录入题目 / 答案 / 错误原因 / 知识点 / 科目；复习时选掌握程度，页面按 `nextReviewAt` 筛到期题。
- **背诵卡片**：手动创建正面 / 背面 / 分类；复习时点翻转。

### 没动的与原因

- 不为错题本安排系统通知 / 后台推送。复习队列是应用内按到期时间筛出来的结果，没有自动提醒通道。
- `FlashCardService.generateCardsFromContent` 当前只构造提示词，函数恒返回空数组；不接资料自动生成。这是有意边界，避免无意义 API 占位。

---

## 7. 考试倒计时

- 选侧栏「考试倒计时」→「添加考试」填名称 / 日期 / 科目 / 备注。
- 按日期排序，临近考试用醒目色；过期考试显示「已过期」。
- 过期不自动归档，由用户点归档按钮完成。

---

## 8. PDF 批注

- 高亮、下划线、删除线、方框、文本备注、手写 6 种工具；6 种颜色。
- 逐页查看，自动保存；批注存到 `pdfAnnotations.json`（按资料 ID 分组）。
- 导出支持纯文本 / Markdown / JSON。导出的是批注数据，不重写回原 PDF。

### 没动的与原因

- 不把批注回写到原 PDF 文件。理由：原 PDF 可能由用户只读引用；批注与资料 ID 绑定，导出时再选择格式。

---

## 9. 白板（暂时关闭）

侧栏入口置灰，进入显示「维护中」。已有画板数据（`whiteboards.json`）保留，重做后直接续用，不需要迁移。

白板源文件（`WhiteboardView.swift`、`WhiteboardCanvasView.swift`、`GeometryModel.swift`、`AlgebraEvaluator.swift`）全部保留未删。

**下线原因**：几何画板存在用户报告的顶部持续模糊空白条，`BackgroundImageView` 的模糊层被所有页面共用，在根因未确认前不改动；先下线入口避免产生半可用状态。

### 关闭前的能力（仅作参考，重做后可能变化）

- 8 类对象：点 / 圆 / 弧 / 多边形 / 函数图 / 参数方程 / 极坐标 / 测量标记；外加画笔、橡皮擦、撤销 / 重做。
- 圆 = 圆心 + 半径拖拽；弧 = A→B 半圆；多边形 = 拖拽框内切正六边形。
- 函数图 / 参数 / 极坐标按数学坐标采样转白板坐标；输入 `30deg`、`30°`、`0.5rad` 按角度计算；曲线在 NaN / ±inf / 渐近线断点处分段，不强行连接。
- 测量工具：画布点选 → 右侧「测量」面板按目标数生成标记；点间距离、三点夹角、闭合图形面积实时计算。
- `AlgebraEvaluator`：tokenizer + 递归下降 parser；`^` / `**` 幂（右结合）；支持 sin/cos/tan 及反三角、log/log10/lg/log2/ln、sqrt/cbrt/abs/exp/floor/ceil/round/trunc/pow/mod/atan2/hypot/min/max、`pi`/`e`、科学计数、`y = ` 前缀剥除。输入长度上限 512，递归深度 64，采样点数收敛到 `maxSamples`。阶乘仅限非负整数 ≤ 170。
- 旧 `whiteboards.json` 反序列化兼容：新字段（如曲线 `origin`）是 optional；损坏文件复制 `.corrupted-<时间戳>` 隔离副本，不静默覆盖原文件。

### 没动的与原因

- 不做曲线长度 / 切线类测量。理由：需要沿笔划折线积分与导数估计，交互也更复杂。
- 不做自动坐标轴 / 网格。理由：白板是自由画板，曲线以视口中心为数学原点。
- 不做采样缓存。理由：当前 30 FPS 够用。

---

## 10. 重复文件清理

- 选扫描文件夹 → SHA-256 索引（PDF / DOC / DOCX / TXT / MD / PPT / PPTX）→ 摘要相同的候选再流式逐字节内容确认。
- 排除扫描期间发生变化的文件；每组单独确认才移入废纸篓；清理前再校验内容。
- 默认保留最早修改；修改时间相同保留路径最短。
- 当前没有「一次清理所有分组」的无确认操作。

### 没动的与原因

- 不做「软删除 / 回收站自定义窗口」二次删除。走 macOS 废纸篓即可。

---

## 11. P2P 社交

- 配置 IPv6 地址 + 端口、加好友、文字 / 群聊、公钥指纹、黑名单、后台监听开关。
- 握手：RSA-2048 公钥交换带版本的会话密钥。
- 消息：AES-256-GCM，96-bit 随机 nonce，GCM tag 检测密文篡改。
- 首次连接的公钥指纹必须在界面里核对并确认；未知 / 变化身份不自动信任。
- 传输层是裸 TCP，没有 TLS / 证书 / 防重放 / 防降级。
- 旧 AES-CBC 消息只为兼容读取保留。

### 没动的与原因

- 这是「应用层加密的 P2P」，不是「端到端安全保证」。README「不承诺的事」里有写明。

---

## 12. 放松亿下

- 侧栏点入 → 阅读确认提示 → 全屏窗口加载包内 `ciallo/index.html`。
- WebView 使用非持久存储，只允许加载该入口；HTML meta CSP `default-src 'self'`、`connect-src 'none'`，禁止外部连接。
- 不依赖 CDN；`ciallo.cc` 作品归属和隐私边界提示保留在页面里。

---

## 13. 实用工具

- **日记**：新建 / 编辑 / 置顶 / 删除 / 按标题搜索；分类 / 日期 / 图片 / 关联白板；可启用本地日记正文加密（AES-256-GCM），密码、密保问题与答案写 Keychain。
- **白噪音**：6 个内置算法声源（雨 / 海浪 / 森林 / 粉噪 / 棕噪等），分别播放 + 调音量 + 停止全部；支持导入本地音频（security-scoped）。
- **许愿**：独立全屏窗口（`openWindow(id: "wish-fullscreen")`，1280×800 起，min 1000×620）。星空铺满画布，左右分栏，70 颗固定种子星 + 6 秒周期流星。重复点侧栏入口复用同一窗口，不开多个。
- **纪念日**：单次 / 每年 / 月三种重复；提前提醒天数；点「检查通知」才请求权限并检查。通知去重 key 是「发生日」字符串，成功投递后才写入 `lastNotifiedYearMonthDayKey`，避免重复提醒。
- **计算器**：标准 / 科学 / 程序员三模式。程序员模式按 BIN/OCT/DEC/HEX 输入，运算走带溢出检查的 `Int64`，避免大整数经 `Double` 丢精度。科学模式 DEG/RAD 切换，角度 / 弧度互转。`x²` / `x³` 是一元函数，不是二元操作；百分号按计算器语义处理。

### 没动的与原因

- **日记**：加密只覆盖正文，标题 / 分类 / 日期 / 置顶 / 关联资料 / 图片路径仍是本机明文。
- **许愿**：30 FPS 是设计上限，不带自适应降级（M1 稳定）。
- **纪念日**：不接 `EventKit` 写系统日历 / 提醒事项；不实现农历（要自带农历表或独立日期实现）；不支持 cron 表达式（3 档覆盖普通用例）。
- **计算器**：不做 `M+` / `MR` / `M-` / `MC` 跨模式记忆（v1.7 已在标准模式暴露这些按钮）；不做表达式回放 / 撤销历史；不做单位换算（cm↔inch 等）。

---

## 14. 设置与配置

- **通用**：日历同步、提醒事项、每日学习通知开关；通知时间；默认学习时长（15–120 分钟）；开机自启状态；更新检查；「启动时自动扫描」已接入启动路径（开启且 `scanPaths` 非空才异步扫描），当前设置页未提供路径编辑 UI。
- **外观**：背景图、模糊半径、透明度；主题（经典 / 国庆红 / 祥云金 / 雪山晨曦）；跟随系统 / 浅色 / 深色；显示文件扩展名（已接入 `MaterialsListView`）。

  **背景图来源**：可并存。
  - 自己的图片：导入多张，在图片库点「使用」指定其中一张。
  - 随机轮换：开启后启动时或点「换一张」时随机选自己的图片（< 2 张时不可用）。
  - 清空我的图片：只删自己导入的，主题自带素材保留并由 `StorageService.restoreBundledBackgroundsIfMissing` 启动时校验恢复。

  **节庆主题锁定背景**：国庆红 / 祥云金 / 雪山晨曦各自强制使用一张内置图，锁定期间随机 / 手动选择不可用。切回经典主题恢复用户此前的设置。锁定结论已落盘（`prepareBackgroundImage` 末尾统一 `saveSettings`，避免每次启动从旧值重推）。

- **学习**：学习档案 / 分析频率 / 讲解风格 / 难度 / 语言风格 / 记忆类型；`LearningPreferenceAutoTuner` 离线从 `StudyMaterial.keywords` / `WrongQuestion.knowledgePoints` + 复习计划完成率三路信号合并，`mergeMode=.fillMissing`（只在用户没填的字段填充，不覆盖手动改的）。
- **AI 分析**：见第 4 章。
- **存储**：资料数 / 复习计划数 / 数据目录占用；「清除所有数据」按 `ManagedDataPath` 清单逐项清 JSON / 目录 / `.corrupted-*` + 受管 Keychain 条目。
- **备份与恢复**：见第 15 章。
- **关于**：版本 / 构建号 / 版权。

---

## 15. 备份与恢复

- `StorageService.runStartupMigration()` 同步阻塞；`AppState.init()` 在 probe storage 阶段调用一次。
- 启动 schema 迁移：
  - 老 `settings.json` 缺字段 → `decodeIfPresent(_:forKey:) ?? 默认值` 兜底；
  - `schemaVersion` 强制写回当前值；
  - 字段重命名场景需要显式 transform，本轮没有把破坏性变更伪装成自动兼容。
- 备份：`/usr/bin/ditto -c -k --sequesterRsrc --keepParent` + `--zlibCompressionLevel 9`。
- 新备份放在数据根目录**同级**的 `SmartNote-Backups`；旧版数据目录内的 `Backups` 先迁到独立目录的 `Migrated Backups`，避免把历史 ZIP 递归打进去。
- 同名备份追加 `-1`、`-2` 避免覆盖；ZIP 未加密。
- 恢复：解压到数据目录外的临时目录 → 规范化顶层目录 → 校验关键 JSON（`materials.json`、`settings.json`、`whiteboards.json` 等） → 原子改名切换数据根目录；切换或复验失败回滚原目录；成功后退出进程让 `AppState` 重载。

### 没动的与原因

- 不做「启动时弹出备份确认」流程。理由：启动迁移已有结果提示，用户在「设置 → 备份与恢复」手动管理。
- 不自动清理历史备份。理由：避免误删用户未迁移的重要数据。

---

## 16. 自动更新

- 来源：GitHub Releases；自动检查只记录候选版本，**不自动下载**。
- 间隔：1–168 小时；渠道：Latest / Pre-release；可配 Owner/Repo（仓库组件做格式校验）。
- 安装前校验：ZIP 结构、Bundle ID、版本、文件数 / 大小；通过后复制到同卷旁路目录复验，再切换主目录；切换 / 启动失败保留或恢复旧版本。
- 用户点「立即更新」才下载、解压、安装。

### 已知限制

- 没有代码签名信任链。结构校验不能替代 Apple Developer ID / notarization 验证。README「不承诺的事」里写明。

---

## 17. 快捷键 / Siri / 菜单栏

- **快捷键**（与 `SmartNoteApp` 命令对齐）：

  | 快捷键 | 行为 |
  |--------|------|
  | `Cmd+I` | 打开「导入资料」 |
  | `Cmd+,` | 打开设置 |
  | `Cmd+Shift+R` | 跳到真题 |
  | `Cmd+Shift+K` | 跳到课件 |

- **Siri / Shortcuts**：8 个 `AppShortcut`（资料库 / 番茄钟 / 待办 / 白板 / 文件加密 / 许愿 / 纪念日 / 快速记录）+ `OpenPageIntent`（带页面参数）。`SharedAppStateProxy` 在 `AppState.init()` MainActor 上 bind 自身，Intent perform 时读写 `selectedTab`。快速记录 Intent 直接写文件，不依赖主窗口显示。

  ⚠️ 当前 `Cmd+Shift+R` / `Cmd+Shift+K` 和 Siri Intent 的页面跳转仍写裸数字 tab ID；侧栏顺序变化时容易失效。后续应统一路由（页面枚举）。

- **菜单栏**：常驻 `MenuBarExtra(.menu)`，提供主窗入口、快速记录、开机自启开关、设置、退出；`LaunchAtLoginService` 单例管自启。
- **开机自启**：`SMAppService.mainApp.register()`。首次注册可能需要用户在系统设置批准；服务会回读实际状态并在失败时保留错误提示。

### 没动的与原因

- 菜单栏可见性没有独立隐藏 toggle。`MenuBarExtra` 一旦写入 `body` 就常驻；开机自启 toggle 在设置和菜单栏提供。
- 状态桥不做持久化跨 launch 唤醒。Siri 调起来 App 会重新启动，`selectedTab` 重置为 0。

---

## 18. 文件加密

- 拖拽 / 选择 ≤ 2 GB 文件 → AES-256-GCM 生成 `.snenc` 文件，默认写源文件同目录，可改输出目录。
- 解密时恢复原文件名，目标冲突追加序号；可选择把每个文件的密码写 Keychain，解密时直接读取。
- 加密任务**不修改 / 不删除源文件**。

`.snenc` 容器格式：

```text
[4B magic 'SNEN'][1B version=1][16B salt][12B nonce][ciphertext][16B GCM tag]
```

技术栈：`CryptoKit AES.GCM` + `CommonCrypto CCKeyDerivationPBKDF2` + `Security` Keychain。PBKDF2-HMAC-SHA256 100,000 次迭代派生 32-byte 密钥，每份文件用随机 salt + 12-byte nonce。

### 没动的与原因

- 不支持「对文件夹整体加密」。理由：同一路径下不同文件用同一个 key 会让 metadata 泄露更严重。
- 不实现「两阶段解密 / 主密码」。理由：Mac 用户更习惯钥匙串自动管理；本地主密码虽然安全但 UX 不友好。
- 不上报加密统计到 LLM。理由：privacy by default，所有加密动作都不离开本机。

---

## 19. 主题与每日祝福

### 主题

| 主题 | 视觉方向 | 背景行为 |
|------|---------|---------|
| 经典 | 系统原生观感，清晰克制 | 留空或用用户自己的图 |
| 国庆红 | 深红底 + 金色强调 | 锁定自带「红金山河」图 |
| 祥云金 | 朱砂 + 暖金 | 锁定自带「云海金河」图 |
| 雪山晨曦 | 冷调靛蓝 + 晨光金 | 锁定自带「雪山晨曦」图 |

- 主题存 `settings.json`，下次启动沿用；`ThemeID.init(from:)` 未知值回退 `.classic`（避免整份 settings.json 解码失败）。
- 经典主题不覆盖系统 tint，节庆主题才提供全局强调色。
- 切换只改视觉层，不影响资料 / 计划 / AI / 文件 / P2P 业务。

### 每日祝福

- 主界面**底部**显示，位置固定，不随窗口尺寸变化；左侧按侧栏实测宽度让开（`PreferenceKey` 采集 `NavigationSplitView` 侧栏宽），侧栏隐藏时铺满底部。
- 高度固定 38pt，标题与正文各 `lineLimit(1)` + 截断；长文案显示两行并提供完整提示。
- 按日期从本地祝福库稳定选取，国庆 10/1–10/7 自动切节庆文案库；「换一句」从当前适用库排除当前条目另选一条。
- 不联网 / 不调 LLM / 不写用户资料 / 不发系统通知。
- 经典主题非国庆期间默认不显示，避免长期占界面空间。

---

## 20. 中国近代史科普

- 侧栏 → 历史科普 → 中国近代史；1840—1949 离线导览，断网可读。
- 首批 34 篇，目录随应用打包：`SmartNote/Resources/history_catalog.json`。
- 时期筛选是**主题导览分组**，不作为严格年份边界；跨时期文章保留在最能帮助理解的主题组中。
- 每篇包含摘要、分段正文、关键事件、人物、名词卡片、关联阅读、来源入口。
- 阅读能力：标题 / 摘要 / 正文 / 事件 / 人物 / 术语 / 别名搜索；按时期 / 标签 / 收藏筛选；分段已读、整篇完成、收藏、最近阅读（首页横向卡片）、随机学习。
- 详情页可调用系统语音朗读正文，离开详情自动停止。
- 收藏和阅读进度独立保存到 `historyProgress.json`（加入 `ManagedDataPath`，参与存储统计、备份、清除所有数据）。

### 内容来源与口径

- 每篇底部列出可继续查证的来源入口，涵盖中国国家博物馆、国家图书馆、社会科学院近代史研究所、故宫博物院、美国国会图书馆与国际联盟档案等机构。
- 数字口径已逐条核对原始文献并在文中注明：
  - 《辛丑条约》赔款区分本金（4.5 亿两）与本息合计（约 9.8 亿两）；
  - 南京大屠杀遇难数字分别标注东京审判判决书与南京军事法庭判决书的依据，不做相加或替代；
  - 《南京条约》赔款说明其为第四、五、六款之和。
- 3 个来源 URL（CASS 近代史研究所、国家图书馆民国专题、全国人大网）保留 `http://`：已实测这三个站点不提供 HTTPS（`https://` 连接直接失败），浏览器 UA 下 `http://` 可正常访问；不写不存在的 `https://` 地址，README 已知边界中已说明浏览器安全提示。

### 内容性质

- 正文是基于公开文献整理的**导览稿**，不是逐句转录的原文抄录。
- 来源链接提供可追溯入口供用户自行核对。
- 数字类表述已逐条核对原始文献，但整个目录的每一句并未与全部学术文献逐条比对，不应被理解为「绝对权威」。
- 不替代教材 / 档案 / 专业研究，也不宣称完整覆盖 1840—1949。

---

## 21. 修复记录（汇总）

本轮修复按严重性分四档汇总；具体 commit 列表见第 22 章。

### P0 崩溃与输入边界

- 复习计划除零 / 倒序 Range 已加 guard（`CalendarService`、`ReviewPlanView`）。
- 计算器与白板统一走 `AlgebraEvaluator`，移除 `NSExpression` 路径；阶乘限制可表示范围；程序员模式走带溢出检查的 `Int64`。
- URL 构造全部改为可选解包 + `guard` / `URLComponents`，源码不再有 `URL(string:)!`。
- LLM JSON 解析先确认首个 `{` 不晚于最后一个 `}` 再切片。
- P2P 昵称按 UTF-8 byte 计数，在 Character 边界截断。
- 搜索高亮用 `String.Index` 切片，不把 UTF-16 offset 当字符索引。
- 解析器长度 512 / 递归深度 64 / 采样点数收敛到 `maxSamples`。

### P1 数据完整性

- 白板 / 通用 / P2P 历史读取失败时保留原文件，复制 `.corrupted-<时间戳>` 隔离副本，广播 `storageIntegrityIssue`；不静默写回空数组。
- `StorageService.ManagedDataPath` 统一清单；`clearAllData()` 按清单逐项清并删受管 Keychain 条目。
- 备份移出数据目录 + 恢复回滚：先在外部临时目录校验，再同卷切换，失败回滚。
- 番茄钟统计用 `studySession.duration` 累计秒数；通知失败不回滚。
- 考试倒计时 `AppState.examCountdowns` 是唯一真相源，持久化 `examCountdowns.json`；旧 settings.json 字段只读兼容，不写回。
- 白板退出 flush + 真实保存状态：`SmartNoteApp` 在后台和 `willTerminate` 同步调 `flushPendingSave()`；保存失败不清待保存标记。
- P2P 后台开关进 `AppSettings.Codable` + 等值比较 + 编码路径；关闭时同时停 listener 与连接。

### P2 安全边界

- API key 进 Keychain：`LLMConfiguration.encode(to:)` 跳过 `apiKey`；写 settings.json 前先写 Keychain 成功，旧明文迁移失败时保留原文。
- 第三方 / 远程 HTTP 显式信任 + API key 明文传输警告。
- 自更新先校验（ZIP 结构 / Info.plist / Bundle ID / 版本 / 体积）再旁路切换 + 回滚；当前没有代码签名信任链。
- 日记 AES-256-GCM + fail-closed：当前格式 `SND2`，PBKDF2-HMAC-SHA256 + AES-GCM，nonce 每次随机；加密开启但 Keychain 没密码时保存失败，不写明文。密码 / 密保问题 / 答案只写 Keychain，UserDefaults 只存开关和迁移后的存在标记。
- P2P 分帧 + AES-GCM + 指纹确认：`P2PFrameAssembler` 处理 TCP 拆包 / 粘包和长度上限；`P2PCryptoService` 新消息带版本 envelope + 随机 nonce + GCM tag；首次身份必须用户核对 SHA-256 fingerprint 后确认。
- 图像理解开关真正生效：关闭 → 本地 OCR 转文本；打开且 provider 支持 → 多模态；不支持 → 阻止请求。
- WebView 去 CDN + CSP / 导航限制：`RelaxGameView` 只加载包内 `ciallo/index.html`，非持久存储、禁新窗口、CSP `default-src 'self'` `connect-src 'none'`。
- 权限声明对齐：`Info.plist` 声明本地网络 / 日历 / 提醒用途；entitlements 声明日历 / 提醒 / 用户选择文件权限。
- security-scoped 访问与书签成对调用。

### P3 正确性

- 待办统计按活动时间段归桶：期间创建 / 完成 / 番茄钟 / 手动计时增量分桶；历史时长按与统计桶重叠部分计算。
- 日记字数互斥统计：CJK 逐字，英文 / 数字按含字母或数字的 token。
- 百分比四舍五入：非有限值归零，限到 0...100，`toNearestOrAwayFromZero`。
- 程序员模式按进制解析与 `Int64` 精确路径；`x²` / `x³` 是一元函数。
- 曲线分段采样：NaN / ±inf / 渐近线断点处分段，不强行连接。
- 白板角度单位后缀：`30deg` / `30°` / `0.5rad`。
- 重复文件 SHA-256 + 内容二次确认 + 逐组确认清理；扫描期间变化 / 摘要变化 / 内容不同的候选跳过。
- 拖放并发安全收集：`OrderedThreadSafeCollector` 锁 + 原始 index 排序。
- 流式 Markdown 稳定 id + 解析缓存 + 50ms 节流；`MarkdownStableID` 内容散列 + 重复序号；`NSCache` 缓存解析块；`ThrottledTextAccumulator` / `MarkdownRenderStore` 约 50ms 节流并在结束时强制 flush。
- 通知授权 / 隐私 / 幂等：不在启动时主动弹权限框；通知正文不放私密字段；稳定 identifier + 先删后加避免重复 pending；纪念日只在真实成功后写去重 key。

### 复盘：上一轮「修复」引入的更严重缺陷

- 用 `GeometryReader` 读容器宽度再决定列数 → 列数影响容器宽度 → SwiftUI 无法收敛 → 进入页面后布局反馈循环卡死；用户体感是「播放点不了 / 进了出不来」，但根因是布局，不是音频。
- 修复：改 `GridItem(.adaptive(minimum: 200, maximum: 320))`，由 SwiftUI 自行排布；移除 `columns(forWidth:)` 与 `GeometryReader` 包装。
- **教训**：在 SwiftUI 中用 `GeometryReader` 读尺寸后，再据以改变**会影响该尺寸本身**的布局属性（列数 / 宽度约束等），是高风险反模式。
- 全局排查：`DiaryStatisticsView` / `TodoStatisticsView` 只用宽度画固定 16pt 高的进度条，不反影响容器尺寸，安全；`WhiteboardCanvasView` 属白板范畴，暂不处理。
- 音频本身此前已修（`connect` 用 44.1kHz 单声道，与 buffer 一致；立体声交给 `mainMixerNode`）。`AmbientSoundService.lastError` 播放失败时写真实原因，界面顶部显示橙色提示条并可关闭，不再静默无反应。

### 排查套路

- 同一症状的根因可能不止一个。拿独立程序（每个进程跑一种接法）逐个验证，比看代码路径靠谱。
- 「进程被 ObjC 异常终止」表现像「点不动」，要靠日志 / 进程状态而不是 UI 反馈判断。
- 嵌套 `ObservableObject` 的 `body` 只 observe 父对象时，子对象的修改不触发重算；要把子状态以快照形式 publish 到父对象上。
- SwiftUI 尺寸约束「取最大」会让重复声明的最小尺寸叠加；只在根声明一次。
- 「内存状态正确但磁盘值没变」纯看代码路径不容易察觉；按真实 `settings.json` 复核可以发现。

---

## 22. 已知限制

有意留下的边界，不应被 README 的功能列表包装成端到端加密 / 自动云同步 / 完整代码签名更新。

- **应用数据不是整体加密**。多数资料 / 计划 / 设置 / 业务历史仍是本机明文 JSON；`StorageService` 写文件收紧到 0600 / 目录 0700，但这是权限边界不是磁盘加密。
- **备份 ZIP 未加密**。
- **自更新没有签名信任链**。
- **P2P 仍是裸 TCP**。没有 TLS / 证书身份验证 / 防重放 / 防降级；旧 AES-CBC 消息只为兼容读取，CBC 没有认证标签。
- **App Sandbox 仍关闭**。`SmartNote.entitlements` 里 `com.apple.security.app-sandbox=false`。原因：`/Applications` 安装流程、`ditto` / `unzip` 外部进程、全量文件访问和 helper 授权尚未迁移到沙盒兼容流程；security-scoped 书签已接入，不是真沙盒。
- **设置开关已接入但有条件**：`showFileExtensions` 已控制列表是否显示扩展名；`autoScanDirectories` 启动路径读取，开启且 `scanPaths` 非空才扫描；当前 `SettingsView` 没路径编辑 UI，默认空路径不会触发启动扫描。
- **白板暂时关闭**（见第 9 章）。
- **Cmd+Shift+R / K 与 Siri Intent** 仍写裸数字 tab ID，侧栏顺序变化时易失效（见第 17 章）。
  - 2026-09-26 补：Intents 「撒谎」的部分已单独修掉（`OpenWishIntent` 改为真正开窗、`OpenWhiteboardIntent` 改为如实回报维护中）。
    裸数字本身按本条保留未动——它是有意的已知边界，不在本轮范围内。

---

## 24. 2026-09-26 问题清单修复（依据 `problems.md`）

修复范围：第 0~4 章 + 第 6 章 W-1~W-4。**第 5 章（已知但保留）未动**，
`P2-2`（开 App Sandbox）、`P2-3`（代码签名）、`P2-4`（P2P 改 TLS）按第 22 章的声明排除。

### 经验证不成立、未改动的条目

- **P0-1「启动迁移把明文 API key 复制进未加密备份」——不成立。**
  `runStartupMigration()` 第 307 行先调用 `loadSettings()`，该调用已给
  `legacyAPIKeyMigrationPending` 赋值，第 318 行的检查有效；
  且 `LLMConfiguration.encode` 根本不编码 `apiKey`，
  迁移成功后磁盘文件已无明文，备份拷的是安全文件。
  已用四种场景（剥离成功 / 重写失败 / Keychain 失败 / 本无明文）验证
  「磁盘含明文时绝不备份」这一核心断言成立。**没有改动这段代码**——
  它本身是正确的防护，按问题描述去「修」反而会破坏它。
- **P0-2 的归因有误，但缺陷真实。** 问题描述把重复写盘归因于 `appSettings` 的
  `didSet`，实际 `didSet` 只同步 `examCountdowns`、并不落盘；
  真正的重复在本轮之前新增的主题/背景代码里（一次 `setTheme` 写盘 3 次）。已按实际情况修复。
- **P1-6** 经查证无功能性问题，仅补充说明。

### 已修复

| 编号 | 内容 | 关键文件 |
|------|------|----------|
| U-1 | Siri「打开许愿」真正开窗（经状态桥 + `ContentView` 消费） | `SmartNoteIntents.swift` `AppState.swift` `ContentView.swift` |
| U-2 | Siri「打开白板」如实回报维护中，`openAppWhenRun = false` | `SmartNoteIntents.swift` |
| U-4 | 白板入口不再 `.disabled(true)`，改为可点击进维护说明页 | `ContentView.swift` |
| U-5 | 移除无消费者的「默认学习时长」设置项 | `SettingsView.swift` `StorageService.swift` |
| U-6 | 纪念日通知按发生日与提前量排程（09:00），不再全部 1 秒后一起弹 | `AnniversaryService.swift` |
| U-7 | 新增 `NotificationRouter`，通知点击按 `kind` 路由到对应页面 | `NotificationRouter.swift`（新增）`SmartNoteApp.swift` |
| U-9 | actor 内不再访问 `NSColor`，改用 `nonisolated static CGColor` | `OCRService.swift` |
| U-10 | 语音合成音色分级回退 + 失败提示 | `SpeechService.swift` |
| U-12 | 同名导入文件按落盘名去重，列表不再出现多条同名资料 | `FileScannerService.swift` |
| U-13 | 分类按「关键词最早出现位置」判定，中文复合词可命中 | `FileScannerService.swift` |
| U-14 | 恢复备份改为先 flush 再 `NSApp.terminate` | `SettingsView.swift` `AppState.swift` |
| U-15 | 备份未加密改为橙色警示块，说明明文性质与处理建议 | `SettingsView.swift` |
| P0-2 | 写盘收敛到单一入口（`setTheme` 由 3 次降为 1 次） | `AppState.swift` |
| P0-3 | 复习计划日历事件不再是「全天」，19:00 起顺延排布 | `CalendarService.swift` |
| P0-5 | 信任过的地址变更后提供「沿用」按钮 | `LLMSettingsView.swift` |
| P1-1 | OCR 失败区分具体原因并提示，不再静默写空文本 | `OCRService.swift` `MaterialDetailView.swift` |
| P1-2 | 历史目录加载失败可重试，不必重启 | `HistoryService.swift` `HistoryHomeView.swift` |
| P3-7 | 识别语言按 Vision 已安装语言动态取，加入 `zh-TW` | `OCRService.swift` |

### 验证方式

- 编译：每次改动后 `xcodebuild -configuration Debug` 均 `** BUILD SUCCEEDED **`。
- 启动冒烟：每批改动后用 Debug 产物直接运行 14 秒，无崩溃、无异常日志。
- 逻辑用例（独立 Swift 程序，复刻生产算法并断言）：
  纪念日排程 15 项、日历时刻 13 项、文件分类 16 项、启动迁移 13 项。
- 真实环境核对：本机 185 个语音音色中，旧实现能匹配到的中文音色为 **0 个**，
  修复后为 20 个并正确选中 compact 品质。

### 没动的与原因

- **U-3 裸数字 tab ID**：第 17 章已声明为已知边界。Intents「撒谎」的部分
  （U-1/U-2）已单独修复，枚举化重构不在本轮范围。
- **U-11 SpeechService 单例**：多详情页同时朗读属于交互设计取舍，
  现有 `.onDisappear` 已覆盖离开即停的常见路径；改为按文章实例化会牵动
  三处调用点与状态管理，收益不抵风险。
- **U-7 的路由粒度**：目前按 `kind` 跳到对应侧栏页面，不做「定位到具体条目」。
  待办/复习/习惯的详情跳转需要各页面暴露定位接口，属于更大改动。
- **P1-3 启动期异步化**：`runStartupMigration` 涉及 schema 升级与备份决策，
  移到异步会引入「UI 已显示旧数据、迁移随后改写」的竞态；
  当前数据量下同步执行未观察到可感知卡顿。
- **P1-5 P2PService 单例改造**：需要改动 P2P 全模块的依赖注入方式，
  超出本轮范围，暂保留。
- **P2-2 / P2-3 / P2-4**：见第 22 章声明，按已知边界保留。
- **P3-2 专注模式**：`enableFocusMode()` 目前只有 `print`。
  macOS 没有公开的「专注模式」开关 API（`SetFocusFilter` 面向自家应用），
  在没有真实可调用的系统接口前不实现假开关。

---

## 23. 构建与验证

### 本地构建路径

```bash
source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate xijianBase
xcodegen generate
xcodebuild -project SmartNote.xcodeproj -scheme SmartNote \
  -configuration Debug -destination 'platform=macOS' build
xcodebuild -project SmartNote.xcodeproj -scheme SmartNote \
  -configuration Release -destination 'platform=macOS' build
xcodebuild -project SmartNote.xcodeproj -scheme SmartNote \
  -configuration Release -destination 'platform=macOS' archive
```

每次新增 `Sources/` 下文件后必须重跑 `xcodegen generate`，否则新文件不会进 `project.pbxproj` 的 `Sources` build phase。

### 2.0.0 实测验证

| 项目 | 结果 |
|------|------|
| Debug `xcodebuild build` | 通过 |
| Release `xcodebuild build` | 通过 |
| Release `xcodebuild archive` | 通过 |
| 归档 `CFBundleShortVersionString` / `CFBundleVersion` | `2.0.0` / `100` |
| 归档架构 | `x86_64 arm64` |
| 归档内 `history_catalog.json` | 34 篇，可解析 |
| 解压后启动冒烟 | 进程可启动并保持运行 |
| 离线逻辑校验（复用生产源文件） | 1720 项断言全部通过 |
| `xcodebuild test` | **仓库没有 XCTest target，不伪造通过** |

离线逻辑校验的做法：把 `HistoryArticle.swift`、`AppTheme.swift`、`HistoryService.swift`、`BlessingService.swift` 四个生产源文件直接编译为校验程序，把存储层替换为同语义的临时实现（JSON 编解码 / 原子写 / ISO8601 日期），覆盖目录加载与 ID / 关联校验、搜索与时期 / 标签 / 收藏筛选、书名号归一化、收藏、分段已读与整篇完成判定、最近阅读去重与上限 8、随机学习、进度持久化往返、损坏文件不被覆盖、清空进度、祝福日期归属（逐日遍历全年）与换句、主题 tint 与未知值回退。该程序只存在于临时目录，不进仓库。

### 本轮主要 commit（按时间倒序，本地未 push）

```
02715a1 docs: 新增第 21 章记录主题绑定/锁定/恢复与祝福条改动
aa7301a chore: 注册 ThemeBackgrounds 资源目录（xcodegen 生成）
a6cd827 fix(blessing): 祝福条移到底部并避让侧栏
ba4b26f feat(theme): 节庆主题锁定背景并保护内置素材
fd315dc feat(theme): 三个节庆主题各绑定一张内置背景图
c0c76f0 docs: 恢复 README 原结构，仅补充新功能说明
e9528b7 chore: 同步 Xcode 自动写入的工程设置
2bb9375 fix(ui): 侧栏可滚到底，祝福条下移并固定位置
b08d764 docs: 记录布局反馈循环的复盘与祝福条第二轮修正
9369db8 fix(ui): 祝福条改用 safeAreaInset 并压平外观
5058fa1 fix(ambient): 移除白噪音页面的布局反馈循环
1406881 docs: 新增第 20 章记录 UI 布局与白噪音播放修复
9931d4b fix(ui): 修复窗口缩放时侧栏变形与内容裁切
aa8b74b fix(ui): 修复祝福条时有时无并加顶部间距
5019fe2 fix(ambient): 修复白噪音点击播放无反应导致进程终止
a1baaf3 chore: 取消跟踪 xcuserdata 并加入忽略
8e22762 chore: 排除 .DS_Store 并取消跟踪
9c94a62 docs: 新增第 19 章记录本轮改动
945ba0f docs: 同步背景图库、许愿全屏与白板暂时关闭
e909cbf feat(wish): 许愿改为独立全屏窗口；白板暂时关闭
e2c94ab fix(history): 修正来源链接与数字口径
183efcd feat(background): 背景图支持图片库与随机轮换
```

发布更新日志与 B 站发布稿位于 `~/Desktop/Update200.md` 和 `~/Desktop/Pub.md`，不属于仓库。

### README 维护规则

README 与 docs 可以在既有结构内增补和修改功能描述，但**不得调整章节顺序、编号或整体体例**。新增功能优先追加到末尾章节以免重排既有编号。