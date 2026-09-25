# 智学笔记（SmartNote）

> macOS 15.0+ 原生 SwiftUI 学习与知识工作台
>
> **2.0.0 国庆版**：三套可持久化主题、每日祝福，以及 1840—1949 中国近代史离线科普。

[![macOS](https://img.shields.io/badge/macOS-15.0%2B-000000?style=flat-square)](https://www.apple.com/macos/)
[![Version](https://img.shields.io/badge/version-2.0.0-8A1538?style=flat-square)](https://github.com/XiJian-Development-Group/SmartNote/releases)
[![License](https://img.shields.io/badge/license-MIT-2F6F62?style=flat-square)](LICENSE)

智学笔记把资料整理、复习规划、专注计时、错题与历史科普放在一个本地 macOS 应用里。它默认把数据保存在本机；AI、联网更新和 P2P 都是可选能力，不会被包装成默认云服务。

## 2.0.0 亮点

- **主题系统**：经典、国庆红、祥云金三套主题；主题选择会保存到本机，节庆主题提供独立的红金对比度方案。
- **每日祝福**：按日期从本地祝福库选取一句话，也可以手动换一句；不依赖网络或 LLM。
- **背景图库与随机轮换**：可以导入多张背景图，随时指定其中一张，或开启随机轮换——每次启动换一张，也能随时手动换。原有「单张指定」方式完全保留。
- **中国近代史科普**：首批 34 条离线内容，覆盖 1840—1949 的战争、条约、改革、人物、教育、经济、战争社会与建国节点；支持时间线、搜索、时期/标签筛选、详情、收藏、分段已读和随机学习。
- **原有学习工作台**：资料库、OCR、考点提取、复习计划、番茄钟、错题本、背诵卡片、待办、统计、日记、文件加密等能力继续保留。

> 历史科普是学习导览，不是完整教材或百科替代品。文章会显示来源入口；重大条约、战争伤亡数字和分期争议请继续查证原始档案与专业研究。

## 快速开始

### 系统要求

- macOS 15.0 或更高版本。
- Xcode 16 或兼容的 macOS SDK（仅从源码构建时需要）。
- 应用运行时不需要 Python、Node.js 或本地服务器。

### 安装

1. 打开 [GitHub Releases](https://github.com/XiJian-Development-Group/SmartNote/releases)，下载 `SmartNote.app.zip`。
2. 解压后将 `SmartNote.app` 拖入「应用程序」文件夹。
3. 首次启动后，在「设置 → 外观」选择主题；打开「资料库」导入资料，或从侧栏进入「历史科普」。

## 功能地图

### 资料与学习

- **资料库**：导入、复制或链接 PDF、Office、图片、文本和 Markdown 文件；按课件、真题、笔记、收藏筛选。
- **OCR 与关键词**：图片使用本地 Vision OCR；关键词提取和可选 AI 分析分别处理本地内容与用户明确配置的 LLM 请求。
- **复习计划**：按考试日期和科目生成计划，可写入 macOS 日历；待办支持提醒、番茄钟关联和统计。
- **番茄钟**：专注、短休息、长休息；记录实际专注秒数并提供科目统计。
- **错题本与背诵卡片**：手动录入、复习队列、掌握度与到期筛选；资料自动生成卡片仍不是当前版本的承诺能力。
- **白板**：几何画板正在重做，暂时不开放，入口已置灰。已创建的画板数据保留在 `whiteboards.json`，恢复后可直接继续使用。

### 计划与统计

- 考试倒计时、复习计划、待办清单、习惯打卡。
- 学习统计、番茄钟统计、待办活动时段统计。
- 日记、日记统计和可选的本地 AES-256-GCM 正文加密。

### 本地工具

- 白噪音：6 个算法声源与本地音频导入。
- 许愿/还愿：在独立全屏窗口中打开，动态星空铺满整个画布；重复点击复用同一窗口。
- 纪念日、计算器、重复文件清理。
- 文件加密：AES-256-GCM 容器 `.snenc`，密码可按文件保存到 macOS Keychain。
- 菜单栏快速记录、开机自启、Siri / Shortcuts 页面跳转。

### 主题与祝福

在「设置 → 外观 → 主题」中即时切换：

| 主题 | 视觉方向 | 行为 |
|------|----------|------|
| 经典 | 清晰、克制、接近系统原生 | 继续遵循「跟随系统 / 浅色 / 深色」 |
| 国庆红 | 深红底、金色强调、节庆装饰 | 使用深色对比度，保留背景图片能力 |
| 祥云金 | 朱砂与暖金、柔和节庆感 | 使用深色对比度，保留背景图片能力 |

选择节庆主题时，顶部会出现每日祝福条；在国庆期间（10 月 1—7 日）即使使用经典主题也会显示。祝福由本地日期和祝福库计算，「换一句」会从同一库中选择另一条，不会请求网络。

### 背景图片

在「设置 → 外观 → 背景图片」中导入多张图片后，可以：

- **指定一张**：在图片库中点「使用」，锁定该张；
- **随机轮换**：打开开关后每次启动随机换一张，并可用「换一张」立即重抽（图片少于 2 张时该开关不可用）；
- **清理**：单张「删除」或「清空图片库」。

模糊半径、背景透明度等既有效果对两种方式都生效。随机只在启动时和手动点击时发生，不会在使用过程中自行变化。

### 中国近代史科普

「侧栏 → 历史科普 → 中国近代史」提供：

- 1840—1949 时间线目录和 34 条首批文章；时期筛选是主题导览分组，跨时期文章可能出现在多个相关语境中。
- 标题、摘要、正文、事件、人物、术语、关联文章与来源搜索。
- 按时期、标签和收藏筛选。
- 文章详情中的分段已读、整篇完成、收藏、最近阅读与随机学习。
- 收藏和阅读进度独立保存到 `historyProgress.json`，不会混入资料或 AI 设置。
- 详情页可调用系统语音朗读正文；离开详情时停止朗读。

内容采用本项目明确标注的离线整理方案，来源入口包括中国国家博物馆、国家图书馆、社会科学院近代史研究所、故宫博物院、美国国会图书馆与国际联盟档案等官方或档案机构。涉及数字的表述均已核对原始文献并注明统计口径，例如《辛丑条约》赔款区分本金与本息、南京大屠杀遇难数字分别标注东京审判与南京军事法庭的判决依据。应用不把历史内容描述为完整覆盖，也不把有争议的数字或评价包装成唯一结论。

## AI 与隐私边界

AI 默认关闭。只有在「设置 → AI 分析」中配置服务后，AI 对话、考点分析和智能阅卷才会发送请求。

- API Key 保存在 macOS Keychain，不写入 `settings.json`。
- 官方 HTTPS 和回环地址按配置规则使用；第三方或远程 HTTP 服务需要显式信任确认。
- 关闭图像理解时，图片先由本地 Vision OCR 转成文本；只有服务明确支持原生视觉且用户打开开关时才会发送图片。
- OCR、关键词、计算器、白板数学和历史目录均可在不启用 AI 的情况下使用。

应用数据默认位于：

```text
~/Library/Application Support/SmartNote/
```

资料、计划和大多数业务历史是本机 JSON 文件；API Key、日记凭据和文件密码等专用凭据进入 Keychain。日记正文只有启用日记加密后才使用 AES-GCM；这不等于整个应用数据目录都已加密。

## 从源码构建

维护者构建时需要 `xcodegen` 和 Xcode：

```bash
git clone https://github.com/XiJian-Development-Group/SmartNote.git
cd SmartNote

# 如使用项目约定的 Conda 环境
source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate xijianBase

xcodegen generate
xcodebuild -project SmartNote.xcodeproj \
  -scheme SmartNote \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

新增 Swift 文件后必须重新运行 `xcodegen generate`，因为 Xcode 工程使用显式文件列表。发布构建使用 Release 配置，并应将归档中的应用 ZIP 命名为 `SmartNote.app.zip`，以兼容应用内更新检查。

## 已知边界

- 历史科普首批内容是有限的离线导览，没有图片、地图、音频或完整时间轴数据。
- 部分历史来源链接使用 `http://`（相关机构站点不提供 HTTPS），访问时可能出现浏览器安全提示。
- 白板正在重做，当前版本不可用；已有画板数据未受影响。
- 应用更新流程会校验 ZIP 结构、Bundle ID、版本和旁路切换，但当前没有 Apple Developer ID / notarization 信任链；结构校验不能替代代码签名验证。
- P2P 使用应用层加密消息和身份指纹确认，但传输层仍是裸 TCP，不应理解为完整的端到端安全方案。
- App Sandbox 当前关闭；security-scoped 书签和用户选择文件访问已接入，但不等于全量沙盒化。
- 备份 ZIP 未加密；请自行妥善保管。
- 仓库当前没有自动化 XCTest target。本轮通过直接编译生产源文件的离线校验程序覆盖目录加载、搜索筛选、进度持久化、损坏文件保护和主题回退等逻辑，但这不能替代界面人工验收。

## 贡献与反馈

欢迎提交具体、可复现的 Issue 或 Discussion：

- [GitHub Issues](https://github.com/XiJian-Development-Group/SmartNote/issues)
- [GitHub Discussions](https://github.com/XiJian-Development-Group/SmartNote/discussions)
- [GitHub Releases](https://github.com/XiJian-Development-Group/SmartNote/releases)

反馈问题时请附上 macOS 版本、复现步骤、预期行为和实际行为；涉及数据丢失或安全问题时请先移除个人资料与凭据。

## License

[MIT License](LICENSE)
