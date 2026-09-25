import SwiftUI
import AppKit
import Markdown
import Foundation

// MARK: - Markdown streaming and identity support

/// 稳定且可区分重复内容的 Markdown 行/块 ID。
///
/// 只使用位置会让流式输出中的最后一块不断“换身份”，从而造成闪烁和滚动跳动。
/// 这里把内容散列、同内容出现序号和内容键组合起来：重复行仍可区分，内容不变时 ID 不变。
struct MarkdownStableLineID: Hashable, Identifiable, Sendable {
    let digest: UInt64
    let occurrence: Int
    let source: String

    var id: String {
        let sourceKey = Data(source.utf8).base64EncodedString()
        return "\(digest)-\(occurrence)-\(sourceKey)"
    }
}

enum MarkdownStableID {
    static func make(for text: String, occurrence: Int) -> MarkdownStableLineID {
        MarkdownStableLineID(
            digest: stableHash(text),
            occurrence: occurrence,
            source: text
        )
    }

    static func makeIDs(for texts: [String]) -> [MarkdownStableLineID] {
        var occurrences: [String: Int] = [:]
        return texts.map { text in
            let occurrence = occurrences[text, default: 0]
            occurrences[text] = occurrence + 1
            return make(for: text, occurrence: occurrence)
        }
    }

    private static func stableHash(_ text: String) -> UInt64 {
        // FNV-1a：跨进程稳定，不依赖 Swift 的随机化 Hashable 种子。
        var hash: UInt64 = 14695981039346656037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
    }
}

struct MarkdownIndexedMarkup: Identifiable {
    let id: MarkdownStableLineID
    let index: Int
    let markup: any Markup

    static func make(from markups: [any Markup]) -> [MarkdownIndexedMarkup] {
        // swift-markdown 的 children/cells 在不同父节点上暴露为不同的具体集合类型；
        // 统一擦除为 existential 后再建立稳定 ID。
        let ids = MarkdownStableID.makeIDs(for: markups.map { $0.plainText })
        return zip(ids.indices, markups).map { index, value in
            MarkdownIndexedMarkup(id: ids[index], index: index, markup: value)
        }
    }
}

/// 可复用的内容解析缓存。NSCache 自带锁，且设置数量上限避免长回复无限占用内存。
final class MarkdownParseMemoryCache<Value: AnyObject>: @unchecked Sendable {
    private let storage = NSCache<NSString, Value>()

    init(countLimit: Int = 32) {
        storage.countLimit = countLimit
    }

    func value(for content: String) -> Value? {
        storage.object(forKey: NSString(string: content))
    }

    func insert(_ value: Value, for content: String) {
        storage.setObject(value, forKey: NSString(string: content))
    }
}

private final class MarkdownParseCacheEntry: NSObject {
    let blocks: [MarkdownIndexedMarkup]

    init(blocks: [MarkdownIndexedMarkup]) {
        self.blocks = blocks
    }
}

private enum MarkdownParseCache {
    static let storage = MarkdownParseMemoryCache<MarkdownParseCacheEntry>()

    static func blocks(for content: String) -> [MarkdownIndexedMarkup] {
        if let cached = storage.value(for: content) {
            return cached.blocks
        }

        let document = Document(parsing: content)
        let blocks = MarkdownIndexedMarkup.make(from: Array(document.children).map { $0 as any Markup })
        storage.insert(MarkdownParseCacheEntry(blocks: blocks), for: content)
        return blocks
    }
}

/// 纯逻辑节流器：不依赖 SwiftUI/计时器，便于对流式输入做单元测试。
struct MarkdownStreamThrottler: Sendable {
    let interval: TimeInterval
    private(set) var lastEmission: TimeInterval?

    init(interval: TimeInterval = 0.05) {
        self.interval = max(0, interval)
    }

    mutating func shouldEmit(at timestamp: TimeInterval) -> Bool {
        guard let lastEmission else {
            self.lastEmission = timestamp
            return true
        }
        guard timestamp - lastEmission >= interval else {
            return false
        }
        self.lastEmission = timestamp
        return true
    }

    func delay(until timestamp: TimeInterval) -> TimeInterval {
        guard let lastEmission else { return 0 }
        return max(0, interval - (timestamp - lastEmission))
    }

    mutating func reset() {
        lastEmission = nil
    }
}

/// 将非 UI 的文本流以最多约 50ms 的频率汇总；finish() 始终返回完整文本。
final class ThrottledTextAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var throttler: MarkdownStreamThrottler

    init(interval: TimeInterval = 0.05) {
        throttler = MarkdownStreamThrottler(interval: interval)
    }

    func append(_ chunk: String, at timestamp: TimeInterval = Date().timeIntervalSinceReferenceDate) -> String? {
        lock.lock()
        defer { lock.unlock() }
        text += chunk
        guard throttler.shouldEmit(at: timestamp) else { return nil }
        return text
    }

    func finish() -> String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}

/// 供拖放回调使用的线程安全收集器；最终按 NSItemProvider 原始顺序排序。
final class OrderedThreadSafeCollector<Element>: @unchecked Sendable {
    private struct Entry {
        let index: Int
        let sequence: Int
        let element: Element
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var nextSequence = 0

    func append(_ element: Element, at index: Int) {
        lock.lock()
        entries.append(Entry(index: index, sequence: nextSequence, element: element))
        nextSequence += 1
        lock.unlock()
    }

    func snapshot() -> [Element] {
        lock.lock()
        let sorted = entries.sorted {
            if $0.index != $1.index { return $0.index < $1.index }
            return $0.sequence < $1.sequence
        }
        lock.unlock()
        return sorted.map(\.element)
    }
}

/// MarkdownText 只在节流窗口结束时替换解析块；父视图的普通重算不会再次解析同一内容。
final class MarkdownRenderStore: ObservableObject {
    @Published private(set) var blocks: [MarkdownIndexedMarkup]

    private var displayedContent: String
    private var pendingContent: String?
    private var timer: Timer?
    private var throttler: MarkdownStreamThrottler

    init(content: String) {
        displayedContent = content
        pendingContent = nil
        throttler = MarkdownStreamThrottler()
        blocks = MarkdownParseCache.blocks(for: content)
    }

    func receive(_ content: String) {
        guard content != displayedContent else {
            pendingContent = nil
            timer?.invalidate()
            timer = nil
            return
        }
        guard content != pendingContent else { return }

        pendingContent = content
        let now = Date().timeIntervalSinceReferenceDate
        if throttler.shouldEmit(at: now) {
            flushPending()
        } else {
            scheduleTimer()
        }
    }

    /// 流结束时强制提交最后一个待处理版本，避免尾部内容停留在节流窗口内。
    func finish() {
        flushPending()
        throttler.reset()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let now = Date().timeIntervalSinceReferenceDate
        let delay = throttler.delay(until: now)
        timer = Timer.scheduledTimer(withTimeInterval: max(0.001, delay), repeats: false) { [weak self] _ in
            self?.flushPending()
        }
    }

    private func flushPending() {
        timer?.invalidate()
        timer = nil
        guard let content = pendingContent else { return }
        pendingContent = nil
        displayedContent = content
        blocks = MarkdownParseCache.blocks(for: content)
    }

    deinit {
        timer?.invalidate()
    }
}

struct MarkdownText: View {
    let content: String
    @StateObject private var renderStore: MarkdownRenderStore

    init(_ content: String) {
        self.content = content
        _renderStore = StateObject(wrappedValue: MarkdownRenderStore(content: content))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(renderStore.blocks) { block in
                renderMarkup(block.markup)
                    .id(block.id)
            }
        }
        .onChange(of: content) { _, newContent in
            renderStore.receive(newContent)
        }
        .onDisappear {
            renderStore.finish()
        }
    }
    
    @ViewBuilder
    private func renderMarkup(_ markup: any Markup) -> some View {
        switch markup {
        case let heading as Heading:
            renderHeading(heading)
        case let paragraph as Paragraph:
            renderParagraph(paragraph)
        case let list as UnorderedList:
            renderUnorderedList(list)
        case let list as OrderedList:
            renderOrderedList(list)
        case let blockQuote as BlockQuote:
            renderBlockQuote(blockQuote)
        case let codeBlock as CodeBlock:
            renderCodeBlock(codeBlock)
        case let thematicBreak as ThematicBreak:
            renderThematicBreak(thematicBreak)
        case let table as Markdown.Table:
            renderTable(table)
        default:
            if let text = markup as? Markdown.Text {
                Text(text.string)
                    .font(.body)
            } else if let strong = markup as? Strong {
                Text(strong.plainText)
                    .fontWeight(.bold)
            } else if let emphasis = markup as? Emphasis {
                Text(emphasis.plainText)
                    .italic()
            } else if let code = markup as? Markdown.InlineCode {
                Text(code.code)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 4)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(3)
            } else if let link = markup as? Markdown.Link {
                linkView(link)
            } else {
                Text(markup.plainText)
                    .font(.body)
            }
        }
    }
    
    @ViewBuilder
    private func renderHeading(_ heading: Heading) -> some View {
        let text = heading.plainText
        switch heading.level {
        case 1:
            Text(text)
                .font(.title)
                .fontWeight(.bold)
                .padding(.top, 8)
        case 2:
            Text(text)
                .font(.title2)
                .fontWeight(.bold)
                .padding(.top, 6)
        case 3:
            Text(text)
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.top, 4)
        default:
            Text(text)
                .font(.headline)
                .fontWeight(.bold)
                .padding(.top, 2)
        }
    }
    
    @ViewBuilder
    private func renderParagraph(_ paragraph: Paragraph) -> some View {
        Text(attributedString(from: paragraph))
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
    }
    
    @ViewBuilder
    private func renderUnorderedList(_ list: UnorderedList) -> some View {
        let items = MarkdownIndexedMarkup.make(from: Array(list.children).map { $0 as any Markup })
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                if let listItem = item.markup as? ListItem {
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.body)
                        Text(listItem.plainText)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .id(item.id)
                }
            }
        }
    }
    
    @ViewBuilder
    private func renderOrderedList(_ list: OrderedList) -> some View {
        let items = MarkdownIndexedMarkup.make(from: Array(list.children).map { $0 as any Markup })
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                if let listItem = item.markup as? ListItem {
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(item.index + 1).")
                            .font(.body)
                        Text(listItem.plainText)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .id(item.id)
                }
            }
        }
    }
    
    @ViewBuilder
    private func renderBlockQuote(_ blockQuote: BlockQuote) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 4)
            Text(blockQuote.plainText)
                .font(.body)
                .foregroundColor(.secondary)
                .padding(.leading, 8)
        }
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private func renderCodeBlock(_ codeBlock: CodeBlock) -> some View {
        Text(codeBlock.code)
            .font(.system(.body, design: .monospaced))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(4)
    }
    
    @ViewBuilder
    private func renderThematicBreak(_ thematicBreak: ThematicBreak) -> some View {
        Divider()
            .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private func renderTable(_ table: Markdown.Table) -> some View {
        let headItems = MarkdownIndexedMarkup.make(from: Array(table.head.cells).map { $0 as any Markup })
        let rowItems = MarkdownIndexedMarkup.make(from: Array(table.body.rows).map { $0 as any Markup })
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(headItems) { item in
                    Text(item.markup.plainText)
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .id(item.id)
                }
            }
            
            Divider()
            
            ForEach(rowItems) { rowItem in
                if let row = rowItem.markup as? Markdown.Table.Row {
                    let cellItems = MarkdownIndexedMarkup.make(from: Array(row.cells).map { $0 as any Markup })
                    HStack(spacing: 0) {
                        ForEach(cellItems) { cellItem in
                            Text(cellItem.markup.plainText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .id(cellItem.id)
                        }
                    }
                    .id(rowItem.id)
                    .background(rowItem.index % 2 == 1 ? Color(nsColor: .controlBackgroundColor).opacity(0.5) : Color.clear)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
    
    @ViewBuilder
    private func linkView(_ link: Markdown.Link) -> some View {
        if let destination = link.destination, let url = URL(string: destination) {
            Link(destination: url) {
                Text(link.plainText)
                    .foregroundColor(.blue)
                    .underline()
            }
            .onTapGesture {
                openLink(url)
            }
        } else {
            Text(link.plainText)
                .foregroundColor(.blue)
                .underline()
        }
    }
    
    /// 打开链接：按住Command键（⌘）点击时在默认浏览器打开
    private func openLink(_ url: URL) {
        if NSEvent.modifierFlags.contains(.command) {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func attributedString(from markup: any Markup) -> AttributedString {
        let text = markup.plainText
        var result = AttributedString(text)
        
        if let paragraph = markup as? Paragraph {
            for child in paragraph.children {
                processInlineElements(&result, in: child)
            }
        }
        
        return result
    }
    
    private func processInlineElements(_ result: inout AttributedString, in markup: any Markup) {
        if let strong = markup as? Strong {
            let range = result.range(of: strong.plainText)
            if let range = range {
                result[range].inlinePresentationIntent = .stronglyEmphasized
                result[range].font = .body.weight(.bold)
            }
        } else if let emphasis = markup as? Emphasis {
            let range = result.range(of: emphasis.plainText)
            if let range = range {
                result[range].inlinePresentationIntent = .emphasized
                result[range].font = .body.italic()
            }
        } else if let inlineCode = markup as? Markdown.InlineCode {
            let range = result.range(of: inlineCode.code)
            if let range = range {
                result[range].font = .system(.body, design: .monospaced)
                result[range].backgroundColor = Color(nsColor: .controlBackgroundColor)
            }
        } else if let link = markup as? Markdown.Link {
            let range = result.range(of: link.plainText)
            if let range = range {
                result[range].foregroundColor = .blue
                result[range].underlineStyle = .single
            }
        }
        
        for child in markup.children {
            processInlineElements(&result, in: child)
        }
    }
}

extension Markup {
    var plainText: String {
        var result = ""
        for child in children {
            if let text = child as? Markdown.Text {
                result += text.string
            } else if let code = child as? Markdown.InlineCode {
                result += code.code
            } else {
                result += child.plainText
            }
        }
        return result
    }
}

struct MarkdownTextField: View {
    @Binding var text: String
    var placeholder: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 150)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
            
            HStack {
                Spacer()
                Text("支持 Markdown 格式")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct MarkdownPreview: View {
    let source: String
    @State private var isEditing = false
    @Binding var text: String
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("预览")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Toggle("编辑", isOn: $isEditing)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))
            
            if isEditing {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .padding(4)
            } else {
                ScrollView {
                    MarkdownText(text)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}
