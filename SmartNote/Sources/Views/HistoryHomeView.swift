import SwiftUI

struct HistoryHomeView: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject private var service: HistoryService
    @State private var searchText = ""
    @State private var selectedPeriod: HistoryPeriod?
    @State private var selectedTag: String?
    @State private var favoritesOnly = false
    @State private var selectedArticle: HistoryArticle?
    @State private var showRandomUnavailable = false
    @State private var showResetConfirmation = false

    init(service: HistoryService) {
        _service = ObservedObject(wrappedValue: service)
    }

    private var filteredArticles: [HistoryArticle] {
        service.search(
            query: searchText,
            period: selectedPeriod,
            tag: selectedTag,
            favoritesOnly: favoritesOnly
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                statistics
                filterPanel

                if let loadError = service.loadError {
                    ThemeSurface {
                        HStack(alignment: .top, spacing: 10) {
                            Label(loadError, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            // 目录加载失败后此前永不重试，必须重启应用。
                            // 这里给出重试入口，修复文件后无需重启。
                            Button("重试") { service.retryLoadCatalog() }
                                .buttonStyle(.bordered)
                        }
                    }
                }

                if !service.recentArticles.isEmpty && searchText.isEmpty && selectedPeriod == nil && selectedTag == nil && !favoritesOnly {
                    recentSection
                }

                if filteredArticles.isEmpty {
                    emptyState
                } else {
                    resultsHeader
                    LazyVStack(spacing: 12) {
                        ForEach(filteredArticles) { article in
                            HistoryArticleCard(
                                article: article,
                                isFavorite: service.isFavorite(article.id),
                                isCompleted: service.isCompleted(article.id),
                                onOpen: { selectedArticle = article },
                                onToggleFavorite: { service.toggleFavorite(article.id) }
                            )
                        }
                    }
                }

                catalogFooter
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .background(theme.background)
        .sheet(item: $selectedArticle) { article in
            HistoryArticleDetailView(service: service, article: article)
        }
        .alert("暂时没有可随机学习的内容", isPresented: $showRandomUnavailable) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("请先加载历史科普目录，或稍后再试。")
        }
        .alert("清空科普阅读进度？", isPresented: $showResetConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                service.resetProgress()
            }
        } message: {
            Text("收藏、分段已读和最近阅读记录都会被清除，文章内容不会受到影响。")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Label("中国近代史 · 离线科普", systemImage: "clock.arrow.circlepath")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(theme.primaryText)
                Text("沿着时间、人物与制度变化，建立一张可搜索、可收藏的学习地图。")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                Text("范围：1840—1949 · 主题分组用于导览，不等于严格分期")
                    .font(.caption)
                    .foregroundStyle(theme.accentSecondary)
            }

            Spacer(minLength: 12)

            Button {
                if let article = service.randomArticle() {
                    selectedArticle = article
                } else {
                    showRandomUnavailable = true
                }
            } label: {
                Label("随机学习", systemImage: "shuffle")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var statistics: some View {
        HStack(spacing: 12) {
            HistoryStatCard(title: "内容", value: "\(service.articles.count)", symbol: "books.vertical.fill", theme: theme)
            HistoryStatCard(title: "已读", value: "\(service.completedCount)", symbol: "checkmark.circle.fill", theme: theme)
            HistoryStatCard(title: "收藏", value: "\(service.favoriteCount)", symbol: "star.fill", theme: theme)
            HistoryStatCard(title: "标签", value: "\(service.allTags.count)", symbol: "tag.fill", theme: theme)
        }
    }

    private var filterPanel: some View {
        ThemeSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(theme.secondaryText)
                    TextField("搜索标题、事件、人物或关键词", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.secondaryText)
                        .help("清除搜索")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(theme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                HStack(spacing: 10) {
                    Menu {
                        Button("全部时期") { selectedPeriod = nil }
                        ForEach(HistoryPeriod.allCases) { period in
                            Button(period.displayName) { selectedPeriod = period }
                        }
                    } label: {
                        Label(selectedPeriod?.displayName ?? "全部时期", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .buttonStyle(.bordered)

                    if let selectedPeriod {
                        Text(selectedPeriod.shortName)
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }

                    Toggle(isOn: $favoritesOnly) {
                        Label("只看收藏", systemImage: "star")
                    }
                    .toggleStyle(.switch)
                    .tint(theme.accent)

                    Spacer()

                    if !searchText.isEmpty || selectedPeriod != nil || selectedTag != nil || favoritesOnly {
                        Button("清除筛选") {
                            searchText = ""
                            selectedPeriod = nil
                            selectedTag = nil
                            favoritesOnly = false
                        }
                        .buttonStyle(.borderless)
                    }
                }

                if !service.allTags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(service.allTags, id: \.self) { tag in
                                Button {
                                    selectedTag = selectedTag == tag ? nil : tag
                                } label: {
                                    ThemeTag(text: tag, isSelected: selectedTag == tag)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("最近阅读", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
                Spacer()
                if let lastRandom = service.lastRandomArticle {
                    Text("上次随机：\(lastRandom.title)")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(service.recentArticles.prefix(4)) { article in
                        HistoryArticleCard(
                            article: article,
                            isFavorite: service.isFavorite(article.id),
                            isCompleted: service.isCompleted(article.id),
                            onOpen: { selectedArticle = article },
                            onToggleFavorite: { service.toggleFavorite(article.id) }
                        )
                        .frame(width: 320)
                    }
                }
            }
        }
    }

    private var catalogFooter: some View {
        ThemeSurface {
            VStack(alignment: .leading, spacing: 8) {
                Text(service.catalogNote)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                Button("清空阅读进度") {
                    showResetConfirmation = true
                }
                .buttonStyle(.borderless)
                .foregroundStyle(theme.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var resultsHeader: some View {
        HStack {
            Text("时间线")
                .font(.headline)
                .foregroundStyle(theme.primaryText)
            Spacer()
            Text("\(filteredArticles.count) 篇")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
        }
    }

    private var emptyState: some View {
        ThemeSurface {
            VStack(spacing: 12) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 42))
                    .foregroundStyle(theme.accent)
                Text(service.articles.isEmpty ? "科普目录暂不可用" : "没有匹配的内容")
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
                Text(service.articles.isEmpty ? "请检查应用资源是否完整。" : "换一个关键词，或清除时期和收藏筛选。")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }
}

private struct HistoryStatCard: View {
    let title: String
    let value: String
    let symbol: String
    let theme: AppTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(theme.accent)
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(theme.primaryText)
            Text(title)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        }
    }
}

struct HistoryArticleCard: View {
    @Environment(\.appTheme) private var theme
    let article: HistoryArticle
    let isFavorite: Bool
    let isCompleted: Bool
    let onOpen: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(article.title)
                        .font(.headline)
                        .foregroundStyle(theme.primaryText)
                    HStack(spacing: 8) {
                        Text(article.yearLabel)
                        Text(article.period.displayName)
                        Text("\(article.readingMinutes) 分钟")
                    }
                    .font(.caption)
                    .foregroundStyle(theme.accentSecondary)
                }

                Spacer(minLength: 8)

                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundStyle(isFavorite ? theme.accentSecondary : theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help(isFavorite ? "取消收藏" : "收藏")
            }

            Text(article.summary)
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(3)
                .multilineTextAlignment(.leading)

            HStack(spacing: 7) {
                ForEach(article.tags.prefix(3), id: \.self) { tag in
                    ThemeTag(text: tag)
                }
                Spacer(minLength: 0)
                if isCompleted {
                    Label("已读", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(16)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}
