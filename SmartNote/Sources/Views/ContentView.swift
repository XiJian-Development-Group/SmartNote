import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        ZStack {
            BackgroundImageView()
            
            NavigationSplitView {
                SidebarView()
            } detail: {
                DetailView()
            }
            .navigationSplitViewStyle(.balanced)
            .frame(minWidth: 900, minHeight: 600)
            .background(Color.clear)
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
    }
}

struct BackgroundImageView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        let settings = appState.appSettings
        
        if settings.backgroundImageEnabled,
           let imageName = settings.backgroundImageName {
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
    
    var body: some View {
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
                
                NavigationLink(value: 14) {
                    Label("重复清理", systemImage: "doc.on.doc")
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
        .navigationTitle("智学笔记")
        .background(Color.clear)
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
                WhiteboardView()
            case 20:
                TodoListView()
            case 21:
                HabitTrackerView()
            default:
                MaterialsListView()
            }
        }
        .background(Color.clear)
    }
}
