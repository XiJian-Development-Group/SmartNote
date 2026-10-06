import SwiftUI
import Charts

struct TodoStatisticsView: View {
    @StateObject private var todoService = TodoService.shared
    @Environment(\.dismiss) var dismiss
    @State private var selectedPeriod: TodoStatisticsPeriod = .week
    
    private var statisticsData: [TodoStatisticsData] {
        todoService.statistics(for: selectedPeriod)
    }
    
    private var totalCompleted: Int {
        statisticsData.reduce(0) { $0 + $1.completedCount }
    }
    
    private var totalCount: Int {
        statisticsData.reduce(0) { $0 + $1.totalCount }
    }
    
    private var totalFocused: TimeInterval {
        statisticsData.reduce(0) { $0 + $1.focusedSeconds }
    }
    
    private var totalElapsed: TimeInterval {
        statisticsData.reduce(0) { $0 + $1.elapsedSeconds }
    }
    
    private var completionRate: Double {
        guard totalCount > 0 else { return 0 }
        return Double(totalCompleted) / Double(totalCount)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 20) {
                    periodPicker
                    summaryCards
                    completionChart
                    timeDistributionChart
                    categoryStats
                }
                .padding()
            }
        }
        .frame(width: 800, height: 700)
    }
    
    // MARK: - 顶部
    
    private var header: some View {
        HStack {
            Text("待办统计")
                .font(.title2)
                .fontWeight(.bold)
            Spacer()
            Button("完成") { dismiss() }
        }
        .padding()
    }
    
    // MARK: - 周期选择
    
    private var periodPicker: some View {
        Picker("统计周期", selection: $selectedPeriod) {
            ForEach(TodoStatisticsPeriod.allCases) { period in
                Text(period.displayName).tag(period)
            }
        }
        .pickerStyle(.segmented)
    }
    
    // MARK: - 摘要卡片
    
    private var summaryCards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 12) {
            SummaryCard(
                icon: "checkmark.circle.fill",
                title: "完成数",
                value: "\(totalCompleted)/\(totalCount)",
                color: .green
            )
            SummaryCard(
                icon: "percent",
                title: "完成率",
                value: String(format: "%.1f%%", completionRate * 100),
                color: .blue
            )
            SummaryCard(
                icon: "timer",
                title: "番茄钟时长",
                value: formatTime(totalFocused),
                color: .orange
            )
            SummaryCard(
                icon: "clock",
                title: "累计处理",
                value: formatTime(totalElapsed),
                color: .purple
            )
        }
    }
    
    // MARK: - 完成情况图表
    
    private var completionChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("完成情况")
                .font(.headline)
            
            if statisticsData.isEmpty {
                Text("暂无数据")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                Chart {
                    ForEach(statisticsData) { data in
                        BarMark(
                            x: .value("周期", data.periodLabel),
                            y: .value("总数", data.totalCount)
                        )
                        .foregroundStyle(Color.gray.opacity(0.3))
                        
                        BarMark(
                            x: .value("周期", data.periodLabel),
                            y: .value("完成", data.completedCount)
                        )
                        .foregroundStyle(Color.green.gradient)
                    }
                }
                .frame(height: 220)
                .chartLegend(.hidden)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
    
    // MARK: - 时间分布图表
    
    private var timeDistributionChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("时间分布")
                .font(.headline)
            
            if statisticsData.isEmpty || totalFocused + totalElapsed == 0 {
                Text("暂无时间记录")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                Chart {
                    ForEach(statisticsData) { data in
                        LineMark(
                            x: .value("周期", data.periodLabel),
                            y: .value("番茄钟时长(分钟)", data.focusedSeconds / 60)
                        )
                        .foregroundStyle(Color.orange)
                        .symbol {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6)
                        }
                        
                        LineMark(
                            x: .value("周期", data.periodLabel),
                            y: .value("处理时长(分钟)", data.elapsedSeconds / 60)
                        )
                        .foregroundStyle(Color.purple)
                        .symbol {
                            Circle()
                                .fill(Color.purple)
                                .frame(width: 6)
                        }
                    }
                }
                .frame(height: 220)
                .chartLegend(position: .bottom, alignment: .leading) {
                    HStack(spacing: 16) {
                        Label("番茄钟", systemImage: "circle.fill")
                            .foregroundColor(.orange)
                        Label("累计处理", systemImage: "circle.fill")
                            .foregroundColor(.purple)
                    }
                    .font(.caption)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
    
    // MARK: - 分类统计
    
    private var categoryStats: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("分类统计")
                .font(.headline)
            
            let categoryData = computeCategoryStats()
            
            if categoryData.isEmpty {
                Text("暂无分类数据")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                ForEach(categoryData, id: \.category) { item in
                    HStack {
                        Text(item.category)
                            .frame(width: 80, alignment: .leading)
                        
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.gray.opacity(0.2))
                                    .frame(height: 16)
                                
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.accentColor.gradient)
                                    .frame(width: geometry.size.width * item.ratio, height: 16)
                            }
                        }
                        .frame(height: 16)
                        
                        Text("\(item.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
    
    private func computeCategoryStats() -> [(category: String, count: Int, ratio: Double)] {
        let allItems = todoService.items
        guard !allItems.isEmpty else { return [] }
        
        var counts: [String: Int] = [:]
        for item in allItems {
            counts[item.category, default: 0] += 1
        }
        
        let total = Double(allItems.count)
        return counts
            .sorted { $0.value > $1.value }
            .map { (category: $0.key, count: $0.value, ratio: Double($0.value) / total) }
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return "\(hours)h\(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m"
        } else {
            return "0m"
        }
    }
}

struct SummaryCard: View {
    let icon: String
    let title: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(color)
                Spacer()
            }
            
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
}
