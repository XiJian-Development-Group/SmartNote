import SwiftUI

struct HistoryArticleDetailView: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var service: HistoryService
    @ObservedObject private var speechService = SpeechService.shared
    let article: HistoryArticle
    @State private var relatedArticle: HistoryArticle?

    private var relatedArticles: [HistoryArticle] {
        article.relatedArticleIDs.compactMap { service.article(id: $0) }
    }

    private var isCompleted: Bool {
        service.isCompleted(article.id)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    keyFacts
                    sections
                    if !article.glossary.isEmpty {
                        glossary
                    }
                    if !relatedArticles.isEmpty {
                        related
                    }
                    sources
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
            }
            .background(theme.background)
            .navigationTitle(article.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        service.toggleFavorite(article.id)
                    } label: {
                        Image(systemName: service.isFavorite(article.id) ? "star.fill" : "star")
                    }
                    .help(service.isFavorite(article.id) ? "取消收藏" : "收藏")

                    Button {
                        if speechService.isSpeaking {
                            speechService.stop()
                        } else {
                            speechService.speak(article.readableText)
                        }
                    } label: {
                        Image(systemName: speechService.isSpeaking ? "stop.fill" : "speaker.wave.2.fill")
                    }
                    .help(speechService.isSpeaking ? "停止朗读" : "朗读全文")
                }
            }
        }
        .onAppear {
            service.markOpened(article.id)
        }
        .onDisappear {
            speechService.stop()
        }
        .sheet(item: $relatedArticle) { related in
            HistoryArticleDetailView(service: service, article: related)
        }
    }

    private var header: some View {
        ThemeSurface {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(article.title)
                            .font(.largeTitle.weight(.bold))
                            .foregroundStyle(theme.primaryText)
                        HStack(spacing: 8) {
                            Text(article.yearLabel)
                            Text(article.period.displayName)
                            Text("约 \(article.readingMinutes) 分钟")
                        }
                        .font(.caption)
                        .foregroundStyle(theme.accentSecondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "book.closed.fill")
                        .font(.title2)
                        .foregroundStyle(theme.accent)
                }

                Text(article.summary)
                    .font(.body)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        service.setCompleted(article.id, completed: !isCompleted)
                    } label: {
                        Label(isCompleted ? "重新标记未读" : "标记整篇已读", systemImage: isCompleted ? "arrow.uturn.backward" : "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)

                    if speechService.isSpeaking {
                        Button {
                            speechService.stop()
                        } label: {
                            Label("停止朗读", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button {
                            speechService.speak(article.readableText)
                        } label: {
                            Label("朗读全文", systemImage: "speaker.wave.2")
                        }
                        .buttonStyle(.bordered)
                    }

                    // 音色缺失或合成失败时说明原因，避免「点了没反应」。
                    if let speechError = speechService.lastError {
                        Label(speechError, systemImage: "speaker.slash.fill")
                            .font(.caption)
                            .foregroundStyle(theme.accentSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var keyFacts: some View {
        ThemeSurface {
            VStack(alignment: .leading, spacing: 12) {
                Label("时间线速览", systemImage: "calendar.badge.clock")
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)

                ForEach(article.keyEvents) { event in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(event.year)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(theme.accentSecondary)
                            .frame(width: 52, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(theme.primaryText)
                            Text(event.detail)
                                .font(.caption)
                                .foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !article.keyFigures.isEmpty {
                    Divider()
                    Text("关键人物")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                    ForEach(article.keyFigures) { figure in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(figure.name) · \(figure.role)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(theme.accentSecondary)
                            Text(figure.contribution)
                                .font(.caption)
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                }
            }
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(article.sections) { section in
                ThemeSurface {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            Text(section.title)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(theme.primaryText)
                            Spacer()
                            Button {
                                service.toggleSectionCompleted(articleID: article.id, sectionID: section.id)
                            } label: {
                                Image(systemName: service.isSectionCompleted(articleID: article.id, sectionID: section.id) ? "checkmark.circle.fill" : "circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(service.isSectionCompleted(articleID: article.id, sectionID: section.id) ? theme.accent : theme.secondaryText)
                            .help(service.isSectionCompleted(articleID: article.id, sectionID: section.id) ? "取消本段已读" : "标记本段已读")
                        }

                        MarkdownText(section.bodyMarkdown)
                            .foregroundStyle(theme.primaryText)

                        HStack {
                            Spacer()
                            Text(service.isSectionCompleted(articleID: article.id, sectionID: section.id) ? "本段已读" : "读完后标记本段")
                                .font(.caption2)
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                }
            }
        }
    }

    private var glossary: some View {
        ThemeSurface {
            VStack(alignment: .leading, spacing: 10) {
                Label("名词卡片", systemImage: "character.book.closed.fill")
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
                ForEach(article.glossary) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.term)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.accentSecondary)
                        Text(entry.definition)
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var related: some View {
        ThemeSurface {
            VStack(alignment: .leading, spacing: 10) {
                Label("继续阅读", systemImage: "arrow.triangle.branch")
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
                ForEach(relatedArticles) { related in
                    Button {
                        relatedArticle = related
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(related.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(theme.primaryText)
                                Text("\(related.yearLabel) · \(related.period.displayName)")
                                    .font(.caption)
                                    .foregroundStyle(theme.secondaryText)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(theme.accent)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var sources: some View {
        ThemeSurface {
            VStack(alignment: .leading, spacing: 10) {
                Label("资料来源", systemImage: "books.vertical")
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
                Text("以下链接用于继续查证；应用内文字为整理后的离线导览，不代表来源机构的全部观点。")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)

                ForEach(article.sources) { source in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.primaryText)
                        Text("\(source.organization) · \(source.note)")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                        if let url = URL(string: source.url) {
                            Link("打开来源", destination: url)
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }
}
