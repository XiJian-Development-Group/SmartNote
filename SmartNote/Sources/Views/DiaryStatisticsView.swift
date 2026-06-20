import SwiftUI
import Charts

/// 日记统计视图
struct DiaryStatisticsView: View {
    @StateObject private var diaryService = DiaryService.shared
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部
            HStack {
                Text("日记统计")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            Divider()
            
            ScrollView {
                VStack(spacing: 20) {
                    // 概览卡片
                    overviewCards
                    
                    // 月度统计
                    monthlyChart
                    
                    // 每日字数（最近30天）
                    dailyWordChart
                    
                    // 分类分布
                    categoryChart
                }
                .padding()
            }
        }
        .frame(width: 800, height: 700)
    }
    
    // MARK: - 概览
    
    private var overviewCards: some View {
        HStack(spacing: 12) {
            DiaryStatCard(
                icon: "flame.fill",
                title: "连续写日记",
                value: "\(diaryService.continuousWritingDays)",
                unit: "天",
                color: .orange
            )
            DiaryStatCard(
                icon: "book.fill",
                title: "日记总数",
                value: "\(diaryService.totalEntries)",
                unit: "篇",
                color: .blue
            )
            DiaryStatCard(
                icon: "textformat",
                title: "总字数",
                value: "\(diaryService.totalWordCount)",
                unit: "字",
                color: .green
            )
        }
    }
    
    // MARK: - 月度柱状图
    
    private var monthlyChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("月度日记数量（最近12个月）")
                .font(.headline)
            
            let data = diaryService.countByMonth(months: 12)
            if data.allSatisfy({ $0.count == 0 }) {
                emptyChartPlaceholder
            } else {
                Chart {
                    ForEach(data, id: \.month) { item in
                        BarMark(
                            x: .value("月份", item.month),
                            y: .value("数量", item.count)
                        )
                        .foregroundStyle(Color.accentColor.gradient)
                    }
                }
                .frame(height: 200)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(12)
    }
    
    // MARK: - 每日字数图
    
    private var dailyWordChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("每日字数（最近30天）")
                .font(.headline)
            
            let data = diaryService.wordCountByDay(days: 30)
            let maxValue = data.map { $0.count }.max() ?? 0
            if maxValue == 0 {
                emptyChartPlaceholder
            } else {
                Chart {
                    ForEach(data, id: \.date) { item in
                        BarMark(
                            x: .value("日期", item.date, unit: .day),
                            y: .value("字数", item.count)
                        )
                        .foregroundStyle(Color.green.gradient)
                    }
                }
                .frame(height: 180)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 5)) { value in
                        if let date = value.as(Date.self) {
                            AxisValueLabel {
                                Text(date, format: .dateTime.month().day())
                                    .font(.caption2)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(12)
    }
    
    // MARK: - 分类分布
    
    private var categoryChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("分类分布")
                .font(.headline)
            
            let data = diaryService.countByCategory()
            if data.isEmpty {
                emptyChartPlaceholder
            } else {
                let maxCount = data.values.max() ?? 1
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(data.keys.sorted()), id: \.self) { key in
                        HStack {
                            Text(key)
                                .font(.caption)
                                .frame(width: 80, alignment: .leading)
                            
                            GeometryReader { geo in
                                let count = data[key] ?? 0
                                let ratio = CGFloat(count) / CGFloat(maxCount)
                                HStack {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.accentColor.gradient)
                                        .frame(width: max(8, geo.size.width * ratio), height: 16)
                                    Spacer(minLength: 0)
                                }
                            }
                            .frame(height: 16)
                            
                            Text("\(data[key] ?? 0)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 30, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(12)
    }
    
    private var emptyChartPlaceholder: some View {
        Text("暂无数据，开始写日记后这里会显示统计图表")
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, minHeight: 100)
    }
}

// MARK: - 统计卡片

struct DiaryStatCard: View {
    let icon: String
    let title: String
    let value: String
    let unit: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.title3)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(color)
                Text(unit)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
    }
}
