import SwiftUI

/// 中国近代史阅读首页（iOS）。
///
/// 目录、搜索、分期筛选与进度全部由 Shared 的 `HistoryService` 提供，
/// 与 macOS 界面读同一份 `history_catalog.json` 和同一份进度数据。
struct HistoryHomeView_iOS: View {
    @Environment(\.appTheme) private var appTheme

    @ObservedObject var service: HistoryService

    @State private var searchText = ""
    @State private var selectedPeriod: HistoryPeriod?
    @State private var selectedTag: String?
    @State private var favoritesOnly = false
    @State private var showsRandomUnavailable = false

    private var filteredArticles: [HistoryArticle] {
        service.search(
            query: searchText,
            period: selectedPeriod,
            tag: selectedTag,
            favoritesOnly: favoritesOnly
        )
    }

    private var allTags: [String] {
        Array(Set(service.articles.flatMap(\.tags))).sorted()
    }

    var body: some View {
        List {
            if let loadError = service.loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                statistics
            }

            Section("筛选") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip(title: "全部", isOn: selectedPeriod == nil && !favoritesOnly) {
                            selectedPeriod = nil
                            favoritesOnly = false
                        }
                        chip(title: "收藏", isOn: favoritesOnly) {
                            favoritesOnly.toggle()
                        }
                        ForEach(HistoryPeriod.allCases) { period in
                            chip(title: period.displayName, isOn: selectedPeriod == period) {
                                selectedPeriod = selectedPeriod == period ? nil : period
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))

                if !allTags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(allTags, id: \.self) { tag in
                                chip(title: tag, isOn: selectedTag == tag) {
                                    selectedTag = selectedTag == tag ? nil : tag
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 8, trailing: 12))
                }
            }

            if filteredArticles.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("没有匹配的篇目", systemImage: "text.magnifyingglass")
                    } description: {
                        Text(service.catalogNote)
                            .font(.footnote)
                    }
                }
            } else {
                Section("篇目（\(filteredArticles.count)）") {
                    ForEach(filteredArticles) { article in
                        NavigationLink {
                            HistoryArticleDetailView_iOS(
                                articleID: article.id,
                                service: service
                            )
                        } label: {
                            row(for: article)
                        }
                    }
                }
            }
        }
        .navigationTitle("中国近代史")
        .searchable(text: $searchText, prompt: "搜索篇目、事件或人物")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    guard let article = service.randomArticle() else {
                        showsRandomUnavailable = true
                        return
                    }
                    // 随机篇目通过导航栈进入：用 path 承载选中的篇目。
                    NavigationLink(
                        destination: HistoryArticleDetailView_iOS(articleID: article.id, service: service),
                        label: { EmptyView() }
                    )
                    .hidden()
                    randomArticleID = article.id
                } label: {
                    Image(systemName: "shuffle")
                }
            }
        }
        .navigationDestination(item: $randomArticleID) { articleID in
            HistoryArticleDetailView_iOS(articleID: articleID, service: service)
        }
        .alert("暂时没有可随机打开的篇目", isPresented: $showsRandomUnavailable) {
            Button("好", role: .cancel) {}
        }
    }

    @State private var randomArticleID: String?

    // MARK: - 分块

    private var statistics: some View {
        HStack(spacing: 12) {
            HistoryStatTile_iOS(
                title: "篇目",
                value: "\(service.articles.count)",
                icon: "books.vertical",
                color: .blue
            )
            HistoryStatTile_iOS(
                title: "已完成",
                value: "\(service.articles.count { service.isCompleted($0.id) })",
                icon: "checkmark.circle",
                color: .green
            )
            HistoryStatTile_iOS(
                title: "收藏",
                value: "\(service.articles.count { service.isFavorite($0.id) })",
                icon: "star",
                color: .yellow
            )
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }

    private func row(for article: HistoryArticle) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(article.title)
                    .font(.headline)
                    .foregroundStyle(appTheme.primaryText)
                if service.isFavorite(article.id) {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                if service.isCompleted(article.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }

            Text("\(article.startYear)\(article.endYear.map { "–\($0)" } ?? "") · \(article.period.displayName)")
                .font(.caption)
                .foregroundStyle(appTheme.secondaryText)

            Text(article.summary)
                .font(.caption2)
                .foregroundStyle(appTheme.secondaryText)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }

    private func chip(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isOn ? appTheme.accent : appTheme.surface)
                .foregroundStyle(isOn ? .white : appTheme.primaryText)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 统计小卡片。
struct HistoryStatTile_iOS: View {
    @Environment(\.appTheme) private var appTheme
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(appTheme.secondaryText)
            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(appTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// 单篇详情：概要、章节、事件、人物、术语表，以及完成/收藏操作。
struct HistoryArticleDetailView_iOS: View {
    @Environment(\.appTheme) private var appTheme

    let articleID: String
    @ObservedObject var service: HistoryService

    private var article: HistoryArticle? { service.article(id: articleID) }

    var body: some View {
        Group {
            if let article {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(article.title)
                                .font(.title2.weight(.semibold))
                            Text("\(article.startYear)\(article.endYear.map { "–\($0)" } ?? "") · \(article.period.displayName)")
                                .font(.caption)
                                .foregroundStyle(appTheme.secondaryText)
                            Text(article.summary)
                                .font(.body)
                                .foregroundStyle(appTheme.primaryText)
                        }
                        .padding(.vertical, 4)

                        HStack(spacing: 12) {
                            Button {
                                service.toggleFavorite(article.id)
                            } label: {
                                Label(
                                    service.isFavorite(article.id) ? "已收藏" : "收藏",
                                    systemImage: service.isFavorite(article.id) ? "star.fill" : "star"
                                )
                            }
                            .buttonStyle(.bordered)

                            Button {
                                service.setCompleted(article.id, completed: !service.isCompleted(article.id))
                            } label: {
                                Label(
                                    service.isCompleted(article.id) ? "已完成" : "标记完成",
                                    systemImage: service.isCompleted(article.id) ? "checkmark.circle.fill" : "checkmark.circle"
                                )
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if !article.sections.isEmpty {
                        Section("章节") {
                            ForEach(article.sections) { section in
                                SectionRow_iOS(
                                    section: section,
                                    isCompleted: service.isSectionCompleted(articleID: article.id, sectionID: section.id),
                                    onToggle: {
                                        service.toggleSectionCompleted(articleID: article.id, sectionID: section.id)
                                    }
                                )
                            }
                        }
                    }

                    if !article.keyEvents.isEmpty {
                        Section("关键事件") {
                            ForEach(article.keyEvents) { event in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(event.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(appTheme.primaryText)
                                    Text(String(event.year))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(appTheme.accent)
                                    if !event.detail.isEmpty {
                                        Text(event.detail)
                                            .font(.caption)
                                            .foregroundStyle(appTheme.secondaryText)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    if !article.keyFigures.isEmpty {
                        Section("关键人物") {
                            ForEach(article.keyFigures) { figure in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(figure.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(appTheme.primaryText)
                                    if !figure.role.isEmpty {
                                        Text(figure.role)
                                            .font(.caption)
                                            .foregroundStyle(appTheme.accent)
                                    }
                                    if !figure.contribution.isEmpty {
                                        Text(figure.contribution)
                                            .font(.caption)
                                            .foregroundStyle(appTheme.secondaryText)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    if !article.glossary.isEmpty {
                        Section("术语表") {
                            ForEach(article.glossary) { entry in
                                DisclosureGroup {
                                    Text(entry.definition)
                                        .font(.caption)
                                        .foregroundStyle(appTheme.secondaryText)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } label: {
                                    Text(entry.term)
                                        .font(.subheadline.weight(.medium))
                                }
                            }
                        }
                    }
                }
                .navigationTitle(article.title)
                .navigationBarTitleDisplayMode(.inline)
                .onAppear { service.markOpened(article.id) }
            } else {
                ContentUnavailableView("篇目不存在", systemImage: "exclamationmark.triangle")
            }
        }
    }
}

private struct SectionRow_iOS: View {
    @Environment(\.appTheme) private var appTheme

    let section: HistorySection
    let isCompleted: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isCompleted ? Color.green : appTheme.secondaryText)

                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(appTheme.primaryText)
                    if !section.bodyMarkdown.isEmpty {
                        Text(section.bodyMarkdown)
                            .font(.caption)
                            .foregroundStyle(appTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }
}