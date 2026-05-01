import SwiftUI

struct StatisticsView: View {
    @EnvironmentObject var appState: AppState
    
    private var totalMaterials: Int {
        appState.materials.count
    }
    
    private var totalSize: String {
        let totalBytes = appState.materials.reduce(0) { $0 + $1.fileSize }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalBytes)
    }
    
    private var totalKeywords: Int {
        appState.materials.compactMap { $0.keywords }.flatMap { $0 }.count
    }
    
    private var categoryStats: [MaterialCategory: Int] {
        Dictionary(grouping: appState.materials, by: { $0.category })
            .mapValues { $0.count }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            Divider()
            
            ScrollView {
                VStack(spacing: 20) {
                    overviewSection
                    categorySection
                    recentSection
                }
                .padding()
            }
        }
    }
    
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("学习统计")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("了解你的学习数据概览")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("数据概览", systemImage: "chart.bar")
                .font(.headline)
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 16) {
                StatCard(title: "资料总数", value: "\(totalMaterials)", icon: "folder.fill", color: .blue)
                StatCard(title: "总大小", value: totalSize, icon: "internaldrive.fill", color: .purple)
                StatCard(title: "考点数量", value: "\(totalKeywords)", icon: "brain.head.profile", color: .orange)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("资料分类", systemImage: "piechart")
                .font(.headline)
            
            VStack(spacing: 8) {
                ForEach(MaterialCategory.allCases, id: \.self) { category in
                    HStack {
                        Image(systemName: category.icon)
                            .foregroundColor(categoryColor(category))
                            .frame(width: 24)
                        
                        Text(category.rawValue)
                            .font(.body)
                        
                        Spacer()
                        
                        let count = categoryStats[category] ?? 0
                        Text("\(count)")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        Text("\(totalMaterials > 0 ? Int(Double(count) / Double(totalMaterials) * 100) : 0)%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("最近添加", systemImage: "clock")
                .font(.headline)
            
            if appState.materials.isEmpty {
                Text("暂无资料")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                ForEach(appState.materials.sorted { $0.createdAt > $1.createdAt }.prefix(5)) { material in
                    HStack {
                        Image(systemName: material.type.icon)
                            .foregroundColor(.accentColor)
                        
                        Text(material.name)
                            .font(.body)
                            .lineLimit(1)
                        
                        Spacer()
                        
                        Text(material.displayDate)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private func categoryColor(_ category: MaterialCategory) -> Color {
        switch category {
        case .lecture: return .blue
        case .exam: return .red
        case .notes: return .green
        case .other: return .gray
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title)
                .foregroundColor(color)
            
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(color.opacity(0.1))
        .cornerRadius(12)
    }
}
