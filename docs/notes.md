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
| 备份打包 | `AppleArchive` 或 `Process` 调 `/usr/bin/ditto` | 纯系统 zip，不引 ZipFoundation |
| 菜单栏 | `MenuBarExtra` SwiftUI Scene | macOS 13+ 原生 |
| 开机自启 | `SMAppService.mainApp.register()` | macOS 13+ 原生 |
| Siri | `AppIntents` + `AppShortcutsProvider` | macOS 13+ 原生 |
| 纪念日 | `EventKit` (`EKEventStore`) | 同步到系统日历 / 提醒事项 |
| 提醒推送 | `UserNotifications` (`UNUserNotificationCenter`) | 提前 X 天通知 |
| 白噪音 | `AVFoundation` (`AVAudioEngine`) + `AVAudioPlayerNode` | 本地资源 + 用户导入 |
| 函数绘图 | `SwiftUI` Canvas + `Foundation` 数学 | 不引 CorePlot 等 |
| AI 视觉 | `URLSession` + `ImageIO` (图片压缩) + `UniformTypeIdentifiers` | 仅 OpenAI / Anthropic 多模态 |
| 倒数日历 | `Foundation.Calenda`r + `UserNotifications` | 不引第三方日期库 |
| 星空动画 | `SwiftUI` `TimelineView` + `Canvas` | 粒子系统本地绘制 |
| 计算器 | `Foundation` `Expression` 数学 + `Int` 位运算 | 不引 MathParser 等 |

---

## 待填充章节（实施中）

- [ ] P0-1 备份与升级基础设施
- [ ] P0-2 钥匙串 + 文件加密
- [ ] P0-3 文件加密中心 UI
- [ ] P0-4 菜单栏 + 开机自启
- [ ] P1-1 几何画板（代数 + 函数绘图）
- [ ] P1-2 AI 视觉支持
- [ ] P1-3 学习偏好优化
- [ ] P2-1 白噪音
- [ ] P2-2 许愿/还愿
- [ ] P2-3 倒数纪念日
- [ ] P2-4 Siri App Intents
- [ ] P2-5 高级计算器
