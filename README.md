# 智学笔记 (SmartNote)

macOS 原生 SwiftUI 写的学习与笔记工具

--2026年9月27日至2026年10月30日开放国庆特色主题、近代历史科普等功能，欢迎体验～--

---

## 安装与打开

需要 macOS 15.0 或更高版本。

1. 从 [Releases](https://github.com/XiJian-Development-Group/SmartNote/releases) 下载最新的 `SmartNote.app.zip`，解压。
2. 把 `SmartNote.app` 拖进「应用程序」或任意文件夹，双击启动。
3. 首次启动若被 Gatekeeper 拦截，在「系统设置 → 隐私与安全性」点「仍要打开」。

如需原始用户数据，请打开Finder，按下Command+Shift+G 输入：`~/Library/Application Support/SmartNote`

---

## 应用功能

**资料库**
导入 PDF / Word / PPT / 图片 / Markdown / 纯文本。资料详情里能编辑文字资料，可以给图片做本地 OCR、按页批注 PDF、导出 PDF 或纯文本。

**学习**
考点提取、AI 对话、智能阅卷、番茄钟、错题本、背诵卡片。**白板入口暂时关闭，数据仍然保留，可以在后续白板重新上线时继续使用，非常抱歉对您造成不便**

**计划**
考试倒计时、复习计划、待办清单、习惯打卡。

**工具**
学习统计、P2P 聊天、放松小游戏（包内离线）、日记、文件加密、白噪音、许愿（独立全屏窗口）、纪念日、计算器（标准 / 科学 / 程序员）、重复文件清理。

**主题**
[ 经典  国庆红  祥云金  雪山晨曦 ] 节庆主题各绑定一张内置背景图

---

## 智能内容使用方法

设置（按下Command+,）进入 “AI 分析” 里填：

- 提供商
- 服务器地址
- 模型 ID
- Temperature
- 最大 Token 数

不会填自己问Ai去

API Key 写在 macOS 钥匙串，以保证凭据安全。

注意：图片理解开关打开时才会发多模态请求；关闭时图片先在本地 OCR 转成文本再发。第三方或远程 HTTP 服务需要在界面里勾选「信任」才会发请求。

---

## 备份

`设置 → 备份与恢复` 可以立即生成一份压缩包，备份放在 ~/Library/Application Support/../SmartNote-Backups/  需要的话可以自己复制

ZIP 没加密，自己妥善保管。恢复前会先解压到临时目录校验关键文件，校验失败不会动原数据。

---

## 自动更新

应用基于 GitHub Releases 检查更新。自动检查只记录候选版本，**不会自动下载安装**；点「立即更新」才会下载、解压、校验、切到旁路目录再换主目录，校验失败回滚旧版本。

仓库和检查间隔在 `设置 → 通用 → 更新` 里配置

连不上GitHub自己想办法

---

## 快捷键

| 快捷键 | 行为 |
|--------|------|
| `Cmd+I` | 打开「导入资料」 |
| `Cmd+,` | 打开设置 |
| `Cmd+Shift+R` | 跳到真题 |
| `Cmd+Shift+K` | 跳到课件 |

另外注册了8个 Siri、Shortcuts 短语（「打开智学笔记资料库」「开始番茄钟」「智学笔记记一笔」等），可用 OpenPageIntent带页面参数。

---

## 注意事项

- **没有云同步**。所有数据都在本机。换电脑请用备份。
- **备份 ZIP 没加密**。别把它当加密快照用。
- 自更新没有代码签名。结构校验不等于 Apple Developer ID 验证。
- P2P 是裸 TCP + 应用层加密，有 AES-GCM 加密消息和公钥指纹确认，但没有 TLS、防重放、防降级或证书链。不要在公网用。
- App Sandbox没开
- **白板暂时不能用**。数据保留，重做后继续用。

---

## 反馈

- 邮件：panmofan@icloud.com
- Issues：<https://github.com/XiJian-Development-Group/SmartNote/issues>

docs文件夹下的文件基本上是给Ai维护用的，一般别去读

MIT License，详见 [LICENSE](LICENSE)。