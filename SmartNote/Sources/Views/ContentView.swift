import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            DetailView()
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 600)
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

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        List(selection: $appState.selectedTab) {
            Section("资料管理") {
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
            
            Section("智能功能") {
                NavigationLink(value: 5) {
                    Label("考点提取", systemImage: "brain.head.profile")
                }
                
                NavigationLink(value: 6) {
                    Label("复习计划", systemImage: "calendar.badge.clock")
                }
            }
            
            Section("统计") {
                NavigationLink(value: 7) {
                    Label("学习统计", systemImage: "chart.bar.fill")
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
        .navigationTitle("智学笔记")
    }
}

struct DetailView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        Group {
            switch appState.selectedTab {
            case 0:
                MaterialsListView()
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
            default:
                MaterialsListView()
            }
        }
    }
}
