import Foundation
import AppIntents
import AppKit

// MARK: - 跳转类

/// 打开智学笔记某个页面（侧边栏 tab）。参数可选，缺省打开「资料库」。
struct OpenPageIntent: AppIntent {
    static var title: LocalizedStringResource = "打开智学笔记页面"
    static var description = IntentDescription("用 Siri 打开智学笔记某个页面。")

    @Parameter(title: "页面", default: SmartNotePage.materials)
    var page: SmartNotePage

    static var parameterSummary: some ParameterSummary { Summary("打开 \(\.$page)") }

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let pageName = page.displayName
        // 许愿与白板不走侧栏 tab：前者是独立窗口，后者当前未开放。
        switch page {
        case .wish:
            SharedAppStateProxy.shared.requestWishWindow()
            NSApp.activate(ignoringOtherApps: true)
            return .result(dialog: "已打开\(pageName)")
        case .whiteboard:
            return .result(dialog: "白板功能维护中，暂时无法打开。")
        default:
            SharedAppStateProxy.shared.selectedTab = page.tabIndex
            NSApp.activate(ignoringOtherApps: true)
            return .result(dialog: "已打开\(pageName)")
        }
    }
}

/// 直接调起资料库 / 番茄钟 / 待办 / 白板 / 加密 / 许愿 / 纪念日。
/// 这是独立 intent（便于 Shortcuts 直接插入对应动作）
struct OpenMaterialsIntent: AppIntent {
    static var title: LocalizedStringResource = "打开资料库"
    static var openAppWhenRun: Bool = true
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        SharedAppStateProxy.shared.selectedTab = 0
        NSApp.activate(ignoringOtherApps: true)
        return .result(dialog: "已打开资料库")
    }
}
struct OpenPomodoroIntent: AppIntent {
    static var title: LocalizedStringResource = "开始番茄钟"
    static var openAppWhenRun: Bool = true
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        SharedAppStateProxy.shared.selectedTab = 10
        NSApp.activate(ignoringOtherApps: true)
        return .result(dialog: "已打开番茄钟")
    }
}
struct OpenTodoIntent: AppIntent {
    static var title: LocalizedStringResource = "打开待办"
    static var openAppWhenRun: Bool = true
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        SharedAppStateProxy.shared.selectedTab = 20
        NSApp.activate(ignoringOtherApps: true)
        return .result(dialog: "已打开待办清单")
    }
}
/// 白板当前处于维护中（见 docs/notes.md 第 9 章）。
/// 这里不再切 tab——侧栏入口已 disabled，设了 tab 也只会停在原页面，
/// 却在对话里回答「已打开白板」，属于对用户报错状态。
struct OpenWhiteboardIntent: AppIntent {
    static var title: LocalizedStringResource = "打开白板"
    static var description = IntentDescription("白板功能维护中，暂时无法打开。")
    /// 不启动应用：打开它也没有可看的页面，只回报真实状态。
    static var openAppWhenRun: Bool = false
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "白板功能维护中，暂时无法打开。")
    }
}
struct OpenFileCryptoIntent: AppIntent {
    static var title: LocalizedStringResource = "打开文件加密"
    static var openAppWhenRun: Bool = true
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        SharedAppStateProxy.shared.selectedTab = 22
        NSApp.activate(ignoringOtherApps: true)
        return .result(dialog: "已打开文件加密")
    }
}
/// 许愿在独立全屏窗口中（`Window(id: "wish-fullscreen")`），不再是侧栏详情页，
/// 因此不能再靠设置 `selectedTab` 跳转。改为向状态桥登记「待打开许愿窗口」，
/// 由持有 `openWindow` 的视图消费（见 ContentView）。
struct OpenWishIntent: AppIntent {
    static var title: LocalizedStringResource = "打开许愿"
    static var openAppWhenRun: Bool = true
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        SharedAppStateProxy.shared.requestWishWindow()
        NSApp.activate(ignoringOtherApps: true)
        return .result(dialog: "已打开许愿")
    }
}
struct OpenAnniversaryIntent: AppIntent {
    static var title: LocalizedStringResource = "打开纪念日"
    static var openAppWhenRun: Bool = true
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        SharedAppStateProxy.shared.selectedTab = 25
        NSApp.activate(ignoringOtherApps: true)
        return .result(dialog: "已打开纪念日")
    }
}

// MARK: - 写操作

/// 创建一条快速笔记。
struct CreateQuickNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "智学笔记快速记录"
    static var description = IntentDescription("把一段文字落到智学笔记的「快速笔记」里。")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "内容", description: "要记录的文本")
    var content: String

    static var parameterSummary: some ParameterSummary {
        Summary("记录 \(\.$content)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "内容为空，没有记录。")
        }
        QuickNoteStore.append(text: trimmed)
        return .result(dialog: "已记录")
    }
}

// MARK: - 页面枚举

enum SmartNotePage: Int, AppEnum, CaseIterable {
    case materials = -1
    case pomodoro
    case todo
    case whiteboard
    case fileCrypto
    case wish
    case anniversary

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "页面" }

    static var caseDisplayRepresentations: [SmartNotePage: DisplayRepresentation] = [
        .materials:   "资料库",
        .pomodoro:    "番茄钟",
        .todo:        "待办",
        .whiteboard:  "白板",
        .fileCrypto:  "文件加密",
        .wish:        "许愿",
        .anniversary: "纪念日"
    ]

    var tabIndex: Int {
        switch self {
        case .materials: return 0
        case .pomodoro: return 10
        case .todo: return 20
        case .whiteboard: return 19
        case .fileCrypto: return 22
        case .wish: return 24
        case .anniversary: return 25
        }
    }

    var displayName: String {
        switch self {
        case .materials: return "资料库"
        case .pomodoro: return "番茄钟"
        case .todo: return "待办"
        case .whiteboard: return "白板"
        case .fileCrypto: return "文件加密"
        case .wish: return "许愿"
        case .anniversary: return "纪念日"
        }
    }
}

// MARK: - AppShortcuts Provider

struct SmartNoteShortcutsProvider: AppShortcutsProvider {

    static let shortcutColor: ShortcutTileColor = .navy

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenMaterialsIntent(),
            phrases: [
                "打开\(.applicationName)资料库",
                "\(.applicationName)打开资料库"
            ],
            shortTitle: "打开资料库",
            systemImageName: "folder.fill"
        )
        AppShortcut(
            intent: OpenPomodoroIntent(),
            phrases: [
                "打开\(.applicationName)番茄钟",
                "\(.applicationName)开始番茄钟"
            ],
            shortTitle: "开始番茄钟",
            systemImageName: "timer"
        )
        AppShortcut(
            intent: OpenTodoIntent(),
            phrases: [
                "打开\(.applicationName)待办"
            ],
            shortTitle: "打开待办",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: OpenWhiteboardIntent(),
            phrases: [
                "打开\(.applicationName)白板"
            ],
            shortTitle: "打开白板",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: OpenFileCryptoIntent(),
            phrases: [
                "打开\(.applicationName)文件加密"
            ],
            shortTitle: "文件加密",
            systemImageName: "lock.doc.fill"
        )
        AppShortcut(
            intent: OpenWishIntent(),
            phrases: [
                "打开\(.applicationName)许愿"
            ],
            shortTitle: "许愿",
            systemImageName: "moon.stars.fill"
        )
        AppShortcut(
            intent: OpenAnniversaryIntent(),
            phrases: [
                "打开\(.applicationName)纪念日"
            ],
            shortTitle: "纪念日",
            systemImageName: "calendar.badge.exclamationmark"
        )
        AppShortcut(
            intent: CreateQuickNoteIntent(),
            phrases: [
                "在\(.applicationName)里记录",
                "\(.applicationName)记一笔"
            ],
            shortTitle: "快速记录",
            systemImageName: "square.and.pencil"
        )
    }
}

// MARK: - 状态桥

/// Siri / Shortcuts intent 需要跟主 app 的状态交互；这里用一个单例代理：
///  - AppState 在 init 时把自身写到这里
///  - Intent perform 时读 selectedTab 来切侧边栏
///
/// 许愿是独立 SwiftUI 窗口，Intent 无法直接拿到 `openWindow`，
/// 因此在这里登记一个待办标记，由视图侧消费。
/// 标记刻意保存在代理自身而不只是 AppState：`openAppWhenRun` 只保证应用被启动，
/// 不保证 `AppState.init` 已经跑完 `bind`；存在代理里可以跨过这个时序。
@MainActor
final class SharedAppStateProxy {
    static let shared = SharedAppStateProxy()
    private init() {}

    private weak var appState: AppState?
    private var pendingWishWindow = false

    func bind(_ state: AppState) {
        appState = state
        // 绑定发生在 Intent 之后时，把挂起的请求补交给 AppState。
        if pendingWishWindow {
            pendingWishWindow = false
            state.deliverWishWindowRequest()
        }
    }

    var selectedTab: Int {
        get { appState?.selectedTab ?? 0 }
        set { appState?.selectedTab = newValue }
    }

    /// 请求打开许愿窗口。已绑定时直接转发，未绑定时先挂起。
    func requestWishWindow() {
        guard let appState else {
            pendingWishWindow = true
            return
        }
        appState.deliverWishWindowRequest()
    }
}
