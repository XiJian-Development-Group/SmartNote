import SwiftUI
import AppKit
import Combine

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.appTheme) private var appTheme
    @State private var integrityIssues: [StorageIntegrityIssue] = StorageService.integrityIssues

    var body: some View {
        ZStack {
            ThemeBackdrop(theme: appTheme)

            ZStack {
                BackgroundImageView()

                NavigationSplitView {
                    SidebarView()
                } detail: {
                    DetailView()
                }
                .navigationSplitViewStyle(.balanced)
                .background(Color.clear)
                // 祝福条必须用 safeAreaInset 挂在 split view 上。
                // 之前把它作为 NavigationSplitView 的同级兄弟放进 VStack，
                // 会让 split view 拿不到正确的安全区，侧栏 List 底部被裁掉。
                .safeAreaInset(edge: .top, spacing: 0) {
                    if appState.shouldShowBlessingBar {
                        FestivalBlessingBar(service: appState.blessingService)
                    }
                }
                .overlay(alignment: .top) {
                    if !integrityIssues.isEmpty {
                        storageIntegrityBanner
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                    }
                }
            }
        }
        .sheet(isPresented: $appState.showFileImporter) {
            FileImportView()
                .environmentObject(appState)
        }
        .alert("错误", isPresented: $appState.showError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(appState.errorMessage ?? "发生未知错误")
        }
        .onReceive(NotificationCenter.default.publisher(for: .storageIntegrityIssue)) { notification in
            guard let fileURL = notification.userInfo?["fileURL"] as? URL,
                  let message = notification.userInfo?["message"] as? String else { return }
            integrityIssues.append(StorageIntegrityIssue(fileURL: fileURL, message: message))
            integrityIssues.sort { $0.timestamp < $1.timestamp }
        }
        .onReceive(NotificationCenter.default.publisher(for: .storageDidClearAllData)) { _ in
            integrityIssues.removeAll()
            StorageService.dismissIntegrityIssues()
        }
    }

    private var storageIntegrityBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                Text("部分数据文件读取失败，已自动备份损坏文件（\(integrityIssues.map { $0.fileURL.lastPathComponent }.joined(separator: "、"))），若继续保存会写入新内容。")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Button("查看备份位置") {
                        showBackupLocation()
                    }
                    .buttonStyle(.bordered)

                    Button("关闭") {
                        integrityIssues.removeAll()
                        StorageService.dismissIntegrityIssues()
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func showBackupLocation() {
        guard let firstIssue = integrityIssues.first else { return }
        let directory = firstIssue.fileURL.deletingLastPathComponent()
        NSWorkspace.shared.open(directory)
    }
}

struct BackgroundImageView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let settings = appState.appSettings

        if settings.backgroundImageEnabled,
           let imageName = settings.effectiveBackgroundImageName {
            let imageURL = appState.storageService.getBackgroundImageURL(named: imageName)
            if let nsImage = NSImage(contentsOf: imageURL) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(blurOverlay(settings: settings))
                    .opacity(settings.backgroundOpacity)
            }
        }
    }
    
    @ViewBuilder
    private func blurOverlay(settings: AppSettings) -> some View {
        if settings.backgroundBlurEnabled {
            Color.clear
                .background(.ultraThinMaterial)
                .blur(radius: settings.backgroundBlurRadius)
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // 侧栏项目较多（5 组 27 项）。List 默认会滚动，
        // 但导航标题与分组头在窗口变矮时会把尾部项目挤出可视区，
        // 因此显式给一个可压缩的最小高度，避免与窗口下限冲突后无法滚动。
        List(selection: $appState.selectedTab) {
            Section("资料库") {
                NavigationLink(value: 0) {
                    Label("全部资料", systemImage: "folder.fill")
                }
                
                NavigationLink(value: 1) {
                    Label("课件", systemImage: "book.fill")
                }
                
                NavigationLink(value: 2) {
                    Label("真题", systemImage: "pencil.and.list.clipboard")
                }
                
                NavigationLink(value: 3) {
                    Label("笔记", systemImage: "note.text")
                }
                
                NavigationLink(value: 4) {
                    Label("收藏", systemImage: "star.fill")
                }
            }
            
            Section("学习") {
                NavigationLink(value: 5) {
                    Label("考点提取", systemImage: "brain.head.profile")
                }
                
                NavigationLink(value: 9) {
                    Label("智能阅卷", systemImage: "checkmark.seal.fill")
                }
                
                NavigationLink(value: 8) {
                    Label("AI 对话", systemImage: "bubble.left.and.bubble.right.fill")
                }
                
                NavigationLink(value: 10) {
                    Label("番茄钟", systemImage: "timer")
                }
                
                NavigationLink(value: 11) {
                    Label("错题本", systemImage: "xmark.circle")
                }
                
                NavigationLink(value: 12) {
                    Label("背诵卡片", systemImage: "rectangle.stack")
                }
                
                NavigationLink(value: 19) {
                    Label("白板", systemImage: "square.and.pencil")
                }
                .disabled(true)
            }

            Section("历史科普") {
                NavigationLink(value: 27) {
                    Label("中国近代史", systemImage: "clock.arrow.circlepath")
                }
            }
            
            Section("计划") {
                NavigationLink(value: 13) {
                    Label("考试倒计时", systemImage: "calendar.badge.exclamationmark")
                }
                
                NavigationLink(value: 6) {
                    Label("复习计划", systemImage: "calendar.badge.clock")
                }
                
                NavigationLink(value: 20) {
                    Label("待办清单", systemImage: "checklist")
                }
 
                NavigationLink(value: 21) {
                    Label("习惯养成打卡", systemImage: "checkmark.square")
                }
                // Value 15 Removed
            }
            
            Section("实用工具") {
                NavigationLink(value: 7) {
                    Label("学习统计", systemImage: "chart.bar.fill")
                }

                NavigationLink(value: 16) {
                    Label("社交", systemImage: "bubble.left.and.bubble.right.fill")
                }

                NavigationLink(value: 17) {
                    Label("放松亿下", systemImage: "gamecontroller")
                }

                NavigationLink(value: 18) {
                    Label("日记", systemImage: "book.fill")
                }

                NavigationLink(value: 22) {
                    Label("文件加密", systemImage: "lock.doc.fill")
                }

                NavigationLink(value: 23) {
                    Label("白噪音", systemImage: "speaker.wave.3.fill")
                }

                Button {
                    openWindow(id: "wish-fullscreen")
                } label: {
                    Label("许愿", systemImage: "moon.stars.fill")
                }
                .buttonStyle(.plain)

                NavigationLink(value: 25) {
                    Label("纪念日", systemImage: "calendar.badge.exclamationmark")
                }

                NavigationLink(value: 26) {
                    Label("计算器", systemImage: "function")
                }

                NavigationLink(value: 14) {
                    Label("重复清理", systemImage: "doc.on.doc")
                }
            }
        }
        .listStyle(.sidebar)
        // 只约束最小宽度，不设固定高度；高度由 NavigationSplitView 分配。
        // 之前 minWidth 200 叠加各详情页的 minWidth（如白噪音 800），
        // 会把窗口下限顶到 900 以上，导致缩放时侧栏被挤压变形。
        .frame(minWidth: 190)
        .navigationTitle("智学笔记")
        .background(Color.clear)
    }
}

/// 白板暂时关闭时的占位页。几何画板正在重做，暂不对外开放。
/// 已有的白板数据文件不受影响，重新开放后可直接恢复使用。
struct WhiteboardUnavailableView: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(theme.accent)

            VStack(spacing: 6) {
                Text("白板功能维护中")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                Text("几何画板正在重新整理，暂时不开放。你已经创建的画板数据都保留着，恢复后可以直接继续使用。")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }
}

struct DetailView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            switch appState.selectedTab {
            case 0:
                MaterialsListView(filter: nil)
            case 1:
                MaterialsListView(filter: .lecture)
            case 2:
                MaterialsListView(filter: .exam)
            case 3:
                MaterialsListView(filter: .notes)
            case 4:
                MaterialsListView(filter: nil, favoritesOnly: true)
            case 5:
                KeyPointsView()
            case 6:
                ReviewPlanView()
            case 7:
                StatisticsView()
            case 8:
                AIChatView()
            case 9:
                SmartGradingView()
            case 10:
                PomodoroView()
            case 11:
                WrongQuestionView()
            case 12:
                FlashCardView()
            case 13:
                ExamCountdownView()
            case 14:
                DuplicateScannerView() // Function ID 15 Removed since v1.4.4
            case 16:
                P2PSocialView()
            case 17:
                RelaxGameView()
            case 18:
                DiaryListView()
            case 19:
                WhiteboardUnavailableView()
            case 20:
                TodoListView()
            case 21:
                HabitTrackerView()
            case 22:
                FileCryptoView()
            case 23:
                WhiteNoiseView()
            case 25:
                AnniversaryView()
            case 26:
                CalculatorView()
            case 27:
                HistoryHomeView(service: appState.historyService)
            default:
                MaterialsListView()
            }
        }
        .background(Color.clear)
    }
}
