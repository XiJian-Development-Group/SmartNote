import Foundation
import AppIntents
import SwiftUI

@available(iOS 16.0, macOS 13.0, *)
struct OpenTabIntent: AppIntent {
    static var title: LocalizedStringResource = "打开标签页"
    static var description = IntentDescription("打开智学笔记的指定标签页")

    @Parameter(title: "标签页", default: .materials)
    var tab: TabEntity

    static var parameterSummary: some ParameterSummary {
        Summary("打开 \(\.$tab)")
    }

    func perform() async throws -> some IntentResult {
        // 通过通知或共享状态打开对应标签页
        NotificationCenter.default.post(name: .openTabFromShortcut, object: nil, userInfo: ["tabIndex": tab.rawValue])
        return .result()
    }
}

/// 可跳转的标签页。
///
/// 用 `AppEnum` 而不是 `AppEntity`：标签页是编译期固定的有限集合，
/// 不需要按标识符查询实体，`AppEnum` 只需提供类型与用例的显示名。
@available(iOS 16.0, macOS 13.0, *)
enum TabEntity: Int, AppEnum {
    case materials = 0
    case keyPoints = 1
    case reviewPlan = 2
    case aiChat = 3
    case smartGrading = 4
    case pomodoro = 5
    case wrongQuestions = 6
    case flashCards = 7
    case examCountdown = 8
    case todo = 9
    case habits = 10
    case statistics = 11
    case social = 12
    case relax = 13
    case diary = 14
    case fileCrypto = 15
    case whiteNoise = 16
    case wish = 17
    case answerBook = 18
    case anniversary = 19
    case calculator = 20
    case duplicateCleaner = 21
    case history = 22

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "标签页"

    static var caseDisplayRepresentations: [TabEntity: DisplayRepresentation] = [
        .materials: "全部资料",
        .keyPoints: "考点提取",
        .reviewPlan: "复习计划",
        .aiChat: "AI 对话",
        .smartGrading: "智能阅卷",
        .pomodoro: "番茄钟",
        .wrongQuestions: "错题本",
        .flashCards: "背诵卡片",
        .examCountdown: "考试倒计时",
        .todo: "待办清单",
        .habits: "习惯养成",
        .statistics: "学习统计",
        .social: "社交",
        .relax: "放松亿下",
        .diary: "日记",
        .fileCrypto: "文件加密",
        .whiteNoise: "白噪音",
        .wish: "许愿",
        .answerBook: "答案之书",
        .anniversary: "纪念日",
        .calculator: "计算器",
        .duplicateCleaner: "重复清理",
        .history: "中国近代史",
    ]
}

@available(iOS 16.0, macOS 13.0, *)
struct NewMaterialIntent: AppIntent {
    static var title: LocalizedStringResource = "新建资料"
    static var description = IntentDescription("快速导入新资料")

    @Parameter(title: "文件类型", default: .pdf)
    var type: MaterialTypeEntity

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .newMaterialFromShortcut, object: nil, userInfo: ["type": type.rawValue])
        return .result()
    }
}

@available(iOS 16.0, macOS 13.0, *)
enum MaterialTypeEntity: String, AppEnum {
    case pdf, image, text, markdown, document
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "文件类型"
    static var caseDisplayRepresentations: [MaterialTypeEntity: DisplayRepresentation] = [
        .pdf: "PDF", .image: "图片", .text: "文本", .markdown: "Markdown", .document: "文档"
    ]
}

@available(iOS 16.0, macOS 13.0, *)
struct NewDiaryIntent: AppIntent {
    static var title: LocalizedStringResource = "新建日记"
    static var description = IntentDescription("快速创建新日记")

    @Parameter(title: "内容", default: "")
    var content: String

    @Parameter(title: "心情", default: .neutral)
    var mood: MoodEntity

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .newDiaryFromShortcut, object: nil, userInfo: ["content": content, "mood": mood.rawValue])
        return .result()
    }
}

@available(iOS 16.0, macOS 13.0, *)
enum MoodEntity: String, AppEnum {
    case happy, neutral, sad, anxious, excited, tired
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "心情"
    static var caseDisplayRepresentations: [MoodEntity: DisplayRepresentation] = [
        .happy: "开心", .neutral: "平静", .sad: "难过", .anxious: "焦虑", .excited: "兴奋", .tired: "疲惫"
    ]
}

@available(iOS 16.0, macOS 13.0, *)
struct StartPomodoroIntent: AppIntent {
    static var title: LocalizedStringResource = "开始番茄钟"
    static var description = IntentDescription("开始一个番茄钟专注时段")

    @Parameter(title: "专注时长(分钟)", default: 25)
    var workMinutes: Int

    @Parameter(title: "休息时长(分钟)", default: 5)
    var breakMinutes: Int

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .startPomodoroFromShortcut, object: nil, userInfo: ["work": workMinutes, "break": breakMinutes])
        return .result()
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct AddTodoIntent: AppIntent {
    static var title: LocalizedStringResource = "添加待办"
    static var description = IntentDescription("快速添加一条待办事项")

    @Parameter(title: "标题")
    var title: String

    @Parameter(title: "备注", default: "")
    var note: String

    @Parameter(title: "优先级", default: .medium)
    var priority: PriorityEntity

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .addTodoFromShortcut, object: nil, userInfo: ["title": title, "note": note, "priority": priority.rawValue])
        return .result()
    }
}

@available(iOS 16.0, macOS 13.0, *)
enum PriorityEntity: Int, AppEnum {
    case low = 0, medium = 1, high = 2
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "优先级"
    static var caseDisplayRepresentations: [PriorityEntity: DisplayRepresentation] = [
        .low: "低", .medium: "中", .high: "高"
    ]
}

@available(iOS 16.0, macOS 13.0, *)
struct CheckHabitIntent: AppIntent {
    static var title: LocalizedStringResource = "打卡习惯"
    static var description = IntentDescription("为指定习惯打卡")

    /// 习惯来自运行时数据，无法做成 `AppEnum`；
    /// 这里接受习惯名称，由界面解析成对应习惯。
    @Parameter(title: "习惯名称")
    var habit: String

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .checkHabitFromShortcut, object: nil, userInfo: ["habitName": habit])
        return .result()
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct AskAIIntent: AppIntent {
    static var title: LocalizedStringResource = "问 AI"
    static var description = IntentDescription("向 AI 提问")

    @Parameter(title: "问题")
    var question: String

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .askAIFromShortcut, object: nil, userInfo: ["question": question])
        return .result()
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct GetAnswerBookIntent: AppIntent {
    static var title: LocalizedStringResource = "获取答案之书"
    static var description = IntentDescription("从答案之书获取一条答案")

    @Parameter(title: "问题", default: "")
    var question: String

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .getAnswerBookFromShortcut, object: nil, userInfo: ["question": question])
        return .result()
    }
}

/// 快捷指令 / 快捷操作。
///
/// - Important: `AppShortcut.phrases` 里**只有** `\(.applicationName)` 是允许的插值；
///   其余短语必须是不含参数插值的固定字符串，否则系统无法在短语里预留参数位置，
///   会在安装时校验失败。带参数的意图由 Siri 在执行前另行询问。
///
/// 每个快捷指令拆成独立的 `static let`，而不是全部塞进一个数组字面量：
/// 后者会让类型检查器在一个表达式里同时推断 8 个 `AppShortcut`，很容易超时。
@available(iOS 16.0, macOS 13.0, *)
/// 快捷指令 / 快捷操作。
///
/// - Important: `AppShortcut.phrases` 里**只有** `\(.applicationName)` 是允许的插值；
///   其余短语必须是不含参数插值的固定字符串，否则系统无法在短语里预留参数位置，
///   会在安装时校验失败。带参数的意图由 Siri 在执行前另行询问。
///
/// - Note: `appShortcuts` 上标注了 `@AppShortcutsBuilder`（结果构造器），
///   因此必须**逐条写出** `AppShortcut(...)` 初始化调用：
///   既不能写数组字面量，也不能引用外部常量（构造器只接受初始化调用表达式）。
@available(iOS 16.0, macOS 13.0, *)
struct SmartNoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenTabIntent(),
            phrases: [
                "在 \(.applicationName) 打开标签页",
                "打开 \(.applicationName) 的标签页",
            ],
            shortTitle: "打开标签页",
            systemImageName: "sidebar.left"
        )

        AppShortcut(
            intent: NewMaterialIntent(),
            phrases: [
                "在 \(.applicationName) 新建资料",
                "导入资料到 \(.applicationName)",
            ],
            shortTitle: "新建资料",
            systemImageName: "doc.badge.plus"
        )

        AppShortcut(
            intent: NewDiaryIntent(),
            phrases: [
                "在 \(.applicationName) 记日记",
                "新建 \(.applicationName) 日记",
            ],
            shortTitle: "记日记",
            systemImageName: "book.fill"
        )

        AppShortcut(
            intent: StartPomodoroIntent(),
            phrases: [
                "在 \(.applicationName) 开始专注",
                "启动 \(.applicationName) 番茄钟",
            ],
            shortTitle: "开始专注",
            systemImageName: "timer"
        )

        AppShortcut(
            intent: AddTodoIntent(),
            phrases: [
                "在 \(.applicationName) 添加待办",
                "给 \(.applicationName) 加个待办",
            ],
            shortTitle: "添加待办",
            systemImageName: "checklist"
        )

        AppShortcut(
            intent: CheckHabitIntent(),
            phrases: [
                "在 \(.applicationName) 打卡习惯",
                "完成 \(.applicationName) 的打卡",
            ],
            shortTitle: "打卡习惯",
            systemImageName: "checkmark.circle"
        )

        AppShortcut(
            intent: AskAIIntent(),
            phrases: [
                "问 \(.applicationName)",
                "让 \(.applicationName) 回答问题",
            ],
            shortTitle: "问 AI",
            systemImageName: "brain.head.profile"
        )

        AppShortcut(
            intent: GetAnswerBookIntent(),
            phrases: [
                "打开 \(.applicationName) 答案之书",
                "问 \(.applicationName) 答案之书",
            ],
            shortTitle: "答案之书",
            systemImageName: "book.closed.fill"
        )

    }
}

// 通知名称扩展
extension Notification.Name {
    static let openTabFromShortcut = Notification.Name("openTabFromShortcut")
    static let newMaterialFromShortcut = Notification.Name("newMaterialFromShortcut")
    static let newDiaryFromShortcut = Notification.Name("newDiaryFromShortcut")
    static let startPomodoroFromShortcut = Notification.Name("startPomodoroFromShortcut")
    static let addTodoFromShortcut = Notification.Name("addTodoFromShortcut")
    static let checkHabitFromShortcut = Notification.Name("checkHabitFromShortcut")
    static let askAIFromShortcut = Notification.Name("askAIFromShortcut")
    static let getAnswerBookFromShortcut = Notification.Name("getAnswerBookFromShortcut")
}

// ShortcutsProvider 类，供 AppState 使用
@MainActor
class ShortcutsProvider: ObservableObject {
    func updateShortcuts(basedOn settings: AppSettings) {
        // 根据设置动态更新可用的快捷指令
        // 例如：如果未启用 AI，隐藏 AskAIIntent
    }

    func donateShortcuts(for actions: [String]) {
        // 捐赠快捷指令给系统，供建议使用
    }
}