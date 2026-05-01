import SwiftUI

struct QuickAccessToolbar: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        HStack(spacing: 12) {
            QuickActionButton(
                icon: "doc.badge.plus",
                title: "导入",
                color: .blue
            ) {
                appState.showFileImporter = true
            }
            
            QuickActionButton(
                icon: "brain.head.profile",
                title: "考点",
                color: .orange
            ) {
                appState.selectedTab = 5
            }
            
            QuickActionButton(
                icon: "calendar.badge.clock",
                title: "计划",
                color: .green
            ) {
                appState.selectedTab = 6
            }
            
            Divider()
                .frame(height: 24)
            
            Spacer()
            
            if appState.isScanning {
                ProgressView()
                    .scaleEffect(0.7)
                Text("扫描中...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct QuickActionButton: View {
    let icon: String
    let title: String
    let color: Color
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(title)
                    .font(.caption2)
            }
            .frame(width: 60, height: 44)
            .foregroundColor(isHovered ? color : .secondary)
            .background(isHovered ? color.opacity(0.1) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "book.fill")
                .font(.system(size: 72))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            Text("欢迎使用智学笔记")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("让学习更高效，让复习更有序")
                .font(.title3)
                .foregroundColor(.secondary)
            
            VStack(spacing: 16) {
                FeatureRow(
                    icon: "doc.text.viewfinder",
                    title: "智能 OCR 识别",
                    description: "支持图片文字提取"
                )
                
                FeatureRow(
                    icon: "brain.head.profile",
                    title: "AI 考点分析",
                    description: "自动提取核心知识点"
                )
                
                FeatureRow(
                    icon: "calendar.badge.clock",
                    title: "复习计划",
                    description: "联动日历提醒复习"
                )
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(12)
            .padding(.horizontal, 40)
            
            Spacer()
            
            Button {
                appState.showFileImporter = true
            } label: {
                Label("开始导入资料", systemImage: "plus.circle.fill")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
}

struct EmptyCategoryView: View {
    let category: MaterialCategory
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: category.icon)
                .font(.system(size: 56))
                .foregroundColor(.secondary)
            
            Text("暂无\(category.rawValue)")
                .font(.title2)
                .fontWeight(.medium)
            
            Text("导入资料后将自动分类到此处")
                .font(.body)
                .foregroundColor(.secondary)
            
            Button {
                appState.showFileImporter = true
            } label: {
                Label("导入资料", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)
            
            Spacer()
        }
    }
}
