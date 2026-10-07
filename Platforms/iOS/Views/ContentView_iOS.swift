import SwiftUI

struct ContentView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.verticalSizeClass) var verticalSizeClass

    var body: some View {
        Group {
            if horizontalSizeClass == .regular && verticalSizeClass == .regular {
                // iPad 横屏/竖屏：使用 NavigationSplitView
                iPadLayout
            } else {
                // iPhone：使用 TabView
                iPhoneLayout
            }
        }
        .background {
            // 层级与 macOS 的 ContentView_macOS 一致：ThemeBackdrop 在下、
            // 背景图在上（背景图自带 opacity/blur，因此能透出主题配色）。
            ZStack {
                ThemeBackdrop(theme: appTheme)
                BackgroundImageView_iOS()
            }
        }
        .sheet(isPresented: $appState.showFileImporter) {
            FileImportView_iOS()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showCameraScanner) {
            DocumentScannerView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showVoiceMemo) {
            VoiceMemoView()
                .environmentObject(appState)
        }
        .alert("错误", isPresented: $appState.showError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(appState.errorMessage ?? "发生未知错误")
        }
        .onReceive(NotificationCenter.default.publisher(for: .openTabFromShortcut)) { notification in
            if let tabIndex = notification.userInfo?["tabIndex"] as? Int {
                appState.goToSection(tabIndex)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newMaterialFromShortcut)) { _ in
            appState.showFileImporter = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .newDiaryFromShortcut)) { _ in
            // 打开日记编辑器
        }
        .onReceive(NotificationCenter.default.publisher(for: .startPomodoroFromShortcut)) { notification in
            let work = notification.userInfo?["work"] as? Int ?? 25
            let break_ = notification.userInfo?["break"] as? Int ?? 5
            // 启动番茄钟
        }
        .onReceive(NotificationCenter.default.publisher(for: .addTodoFromShortcut)) { notification in
            // 添加待办
        }
        .onReceive(NotificationCenter.default.publisher(for: .checkHabitFromShortcut)) { notification in
            // 打卡习惯
        }
        .onReceive(NotificationCenter.default.publisher(for: .askAIFromShortcut)) { notification in
            // AI 对话
        }
        .onReceive(NotificationCenter.default.publisher(for: .getAnswerBookFromShortcut)) { _ in
            // 原来写的是 `selectedTab = 17`，但 17 是「放松亿下」；
            // 答案之书是 24。
            appState.goToSection(AppState_iOS.IPadSection.answerBook.rawValue)
        }
    }

    // MARK: - iPhone 布局

    private var iPhoneLayout: some View {
        // 注意绑定的是 `iphoneTab` 而不是 `selectedTab`：
        // 后者的编号是 iPad 详情区的页面号，与这里的标签栏不是一回事，
        // 混用会导致「课件/真题/笔记/收藏」在 iPhone 上永远到不了。
        TabView(selection: $appState.iphoneTab) {
            // 资料库
            NavigationStack {
                MaterialsBrowserView_iOS()
            }
            .tabItem { Label("资料库", systemImage: "folder.fill") }
            .tag(AppState_iOS.IPhoneTab.materials)

            // 学习工具
            NavigationStack {
                StudyToolsView_iOS()
            }
            .tabItem { Label("学习", systemImage: "brain.head.profile") }
            .tag(AppState_iOS.IPhoneTab.study)

            // 计划
            NavigationStack {
                PlansView_iOS()
            }
            .tabItem { Label("计划", systemImage: "calendar.badge.clock") }
            .tag(AppState_iOS.IPhoneTab.plans)

            // 实用工具
            NavigationStack {
                UtilitiesView_iOS()
            }
            .tabItem { Label("工具", systemImage: "wrench.and.screwdriver.fill") }
            .tag(AppState_iOS.IPhoneTab.tools)

            // 历史科普
            NavigationStack {
                HistoryHomeView_iOS(service: appState.historyService)
            }
            .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }
            .tag(AppState_iOS.IPhoneTab.history)

            // 设置
            NavigationStack {
                SettingsView_iOS()
            }
            .tabItem { Label("设置", systemImage: "gearshape.fill") }
            .tag(AppState_iOS.IPhoneTab.settings)
        }
        .tint(appTheme.accent)
    }

    // MARK: - iPad 布局

    private var iPadLayout: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            // 侧栏
            SidebarView_iOS()
                .navigationTitle("智学笔记")
                .navigationBarTitleDisplayMode(.large)
        } detail: {
            // 详情区
            DetailView_iOS()
        }
        .navigationSplitViewStyle(.balanced)
    }
}

// MARK: - iPad 侧栏

struct SidebarView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme

    /// 侧栏选中项与 `AppState` 的双向桥接。
    private var tabSelection: Binding<Int?> {
        Binding(
            get: { appState.selectedTab },
            set: { newValue in
                if let newValue { appState.selectedTab = newValue }
            }
        )
    }

    var body: some View {
        // `List(selection:)` 在 iOS 上要求 Optional 的 SelectionValue，
        // 因此用一个计算属性把可空的选中项与 `selectedTab` 互相转换。
        List(selection: tabSelection) {
            Section("资料库") {
                NavigationLink(value: 0) { Label("全部资料", systemImage: "folder.fill") }
                NavigationLink(value: 1) { Label("课件", systemImage: "book.fill") }
                NavigationLink(value: 2) { Label("真题", systemImage: "pencil.and.list.clipboard") }
                NavigationLink(value: 3) { Label("笔记", systemImage: "note.text") }
                NavigationLink(value: 4) { Label("收藏", systemImage: "star.fill") }
            }

            Section("学习工具") {
                NavigationLink(value: 5) { Label("考点提取", systemImage: "brain.head.profile") }
                NavigationLink(value: 9) { Label("智能阅卷", systemImage: "checkmark.seal.fill") }
                NavigationLink(value: 8) { Label("AI 对话", systemImage: "bubble.left.and.bubble.right.fill") }
                NavigationLink(value: 10) { Label("番茄钟", systemImage: "timer") }
                NavigationLink(value: 11) { Label("错题本", systemImage: "xmark.circle") }
                NavigationLink(value: 12) { Label("背诵卡片", systemImage: "rectangle.stack") }
                NavigationLink(value: 19) { Label("白板", systemImage: "square.and.pencil") }
            }

            Section("历史科普") {
                NavigationLink(value: 27) { Label("中国近代史", systemImage: "clock.arrow.circlepath") }
            }

            Section("计划") {
                NavigationLink(value: 13) { Label("考试倒计时", systemImage: "calendar.badge.exclamationmark") }
                NavigationLink(value: 6) { Label("复习计划", systemImage: "calendar.badge.clock") }
                NavigationLink(value: 20) { Label("待办清单", systemImage: "checklist") }
                NavigationLink(value: 21) { Label("习惯养成打卡", systemImage: "checkmark.square") }
            }

            Section("实用工具") {
                NavigationLink(value: 7) { Label("学习统计", systemImage: "chart.bar.fill") }
                NavigationLink(value: 16) { Label("社交", systemImage: "bubble.left.and.bubble.right.fill") }
                NavigationLink(value: 17) { Label("放松亿下", systemImage: "gamecontroller") }
                NavigationLink(value: 18) { Label("日记", systemImage: "book.fill") }
                NavigationLink(value: 22) { Label("文件加密", systemImage: "lock.doc.fill") }
                NavigationLink(value: 23) { Label("白噪音", systemImage: "speaker.wave.3.fill") }
                NavigationLink(value: 24) { Label("答案之书", systemImage: "book.closed.fill") }
                NavigationLink(value: 25) { Label("纪念日", systemImage: "calendar.badge.exclamationmark") }
                NavigationLink(value: 26) { Label("计算器", systemImage: "function") }
                NavigationLink(value: 14) { Label("重复清理", systemImage: "doc.on.doc") }
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - iPad 详情区

struct DetailView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS

    var body: some View {
        Group {
            switch appState.selectedTab {
            case 0: MaterialsListView_iOS(filter: nil)
            case 1: MaterialsListView_iOS(filter: .lecture)
            case 2: MaterialsListView_iOS(filter: .exam)
            case 3: MaterialsListView_iOS(filter: .notes)
            case 4: MaterialsListView_iOS(filter: nil, favoritesOnly: true)
            case 5: KeyPointsView_iOS()
            case 6: ReviewPlanView_iOS()
            case 7: StatisticsView_iOS()
            case 8: AIChatView_iOS()
            case 9: SmartGradingView_iOS()
            case 10: PomodoroView_iOS()
            case 11: WrongQuestionView_iOS()
            case 12: FlashCardView_iOS()
            case 13: ExamCountdownView_iOS()
            case 14: DuplicateScannerView_iOS()
            case 16: P2PSocialView_iOS()
            case 17: RelaxGameView_iOS()
            case 18: DiaryListView_iOS()
            case 19: WhiteboardUnavailableView()
            case 20: TodoListView_iOS()
            case 21: HabitTrackerView_iOS()
            case 22: FileCryptoUnavailableView()
            case 23: WhiteNoiseView_iOS()
            case 24: AnswerBookView_iOS(service: appState.answerBookService)
            case 25: AnniversaryView_iOS()
            case 26: CalculatorView_iOS()
            case 27: HistoryHomeView_iOS(service: appState.historyService)
            default: MaterialsListView_iOS(filter: nil)
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { detailToolbar }
    }

    private var navigationTitle: String {
        let titles = [
            0: "全部资料", 1: "课件", 2: "真题", 3: "笔记", 4: "收藏",
            5: "考点提取", 6: "复习计划", 7: "学习统计", 8: "AI 对话", 9: "智能阅卷",
            10: "番茄钟", 11: "错题本", 12: "背诵卡片", 13: "考试倒计时", 14: "重复清理",
            16: "社交", 17: "放松亿下", 18: "日记", 19: "白板", 20: "待办清单",
            21: "习惯养成", 22: "文件加密", 23: "白噪音", 24: "答案之书", 25: "纪念日",
            26: "计算器", 27: "中国近代史"
        ]
        return titles[appState.selectedTab] ?? "智学笔记"
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            switch appState.selectedTab {
            case 0, 1, 2, 3, 4:
                Button { appState.showFileImporter = true } label: { Image(systemName: "plus") }
            case 10:
                Button { /* 开始番茄钟 */ } label: { Image(systemName: "play.fill") }
            case 18:
                Button { /* 新建日记 */ } label: { Image(systemName: "plus") }
            case 20:
                Button { /* 新建待办 */ } label: { Image(systemName: "plus") }
            case 21:
                Button { /* 新建习惯 */ } label: { Image(systemName: "plus") }
            case 23:
                Button { /* 添加白噪音 */ } label: { Image(systemName: "plus") }
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - iPhone 专用容器视图

struct StudyToolsView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS

    var body: some View {
        List {
            Section("核心工具") {
                NavigationLink { KeyPointsView_iOS() } label: { Label("考点提取", systemImage: "brain.head.profile") }
                NavigationLink { SmartGradingView_iOS() } label: { Label("智能阅卷", systemImage: "checkmark.seal.fill") }
                NavigationLink { AIChatView_iOS() } label: { Label("AI 对话", systemImage: "bubble.left.and.bubble.right.fill") }
            }
            Section("专注与记忆") {
                NavigationLink { PomodoroView_iOS() } label: { Label("番茄钟", systemImage: "timer") }
                NavigationLink { WrongQuestionView_iOS() } label: { Label("错题本", systemImage: "xmark.circle") }
                NavigationLink { FlashCardView_iOS() } label: { Label("背诵卡片", systemImage: "rectangle.stack") }
            }
            Section("其他") {
                NavigationLink { WhiteboardUnavailableView() } label: { Label("白板", systemImage: "square.and.pencil") }
            }
        }
        .navigationTitle("学习工具")
    }
}

struct PlansView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS

    var body: some View {
        List {
            Section("时间管理") {
                NavigationLink { ExamCountdownView_iOS() } label: { Label("考试倒计时", systemImage: "calendar.badge.exclamationmark") }
                NavigationLink { ReviewPlanView_iOS() } label: { Label("复习计划", systemImage: "calendar.badge.clock") }
            }
            Section("任务与习惯") {
                NavigationLink { TodoListView_iOS() } label: { Label("待办清单", systemImage: "checklist") }
                NavigationLink { HabitTrackerView_iOS() } label: { Label("习惯养成打卡", systemImage: "checkmark.square") }
            }
        }
        .navigationTitle("计划")
    }
}

struct UtilitiesView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS

    var body: some View {
        List {
            Section("统计与社交") {
                NavigationLink { StatisticsView_iOS() } label: { Label("学习统计", systemImage: "chart.bar.fill") }
                NavigationLink { P2PSocialView_iOS() } label: { Label("社交", systemImage: "bubble.left.and.bubble.right.fill") }
            }
            Section("娱乐与记录") {
                NavigationLink { RelaxGameView_iOS() } label: { Label("放松亿下", systemImage: "gamecontroller") }
                NavigationLink { DiaryListView_iOS() } label: { Label("日记", systemImage: "book.fill") }
                NavigationLink { FileCryptoUnavailableView() } label: { Label("文件加密", systemImage: "lock.doc.fill") }
                NavigationLink { WhiteNoiseView_iOS() } label: { Label("白噪音", systemImage: "speaker.wave.3.fill") }
            }
            Section("趣味工具") {
                NavigationLink { AnswerBookView_iOS(service: appState.answerBookService) } label: { Label("答案之书", systemImage: "book.closed.fill") }
                NavigationLink { AnniversaryView_iOS() } label: { Label("纪念日", systemImage: "calendar.badge.exclamationmark") }
                NavigationLink { CalculatorView_iOS() } label: { Label("计算器", systemImage: "function") }
                NavigationLink { DuplicateScannerView_iOS() } label: { Label("重复清理", systemImage: "doc.on.doc") }
            }
        }
        .navigationTitle("实用工具")
    }
}