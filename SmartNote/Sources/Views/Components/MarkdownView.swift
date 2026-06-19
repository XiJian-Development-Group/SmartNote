import SwiftUI
import AppKit
import Markdown

struct MarkdownText: View {
    let content: String
    
    init(_ content: String) {
        self.content = content
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parseAndRender().enumerated()), id: \.offset) { _, element in
                element
            }
        }
    }
    
    private func parseAndRender() -> [AnyView] {
        let document = Document(parsing: content)
        return document.children.map { AnyView(renderMarkup($0)) }
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
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(list.children.enumerated()), id: \.offset) { _, item in
                if let listItem = item as? ListItem {
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.body)
                        Text(listItem.plainText)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func renderOrderedList(_ list: OrderedList) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(list.children.enumerated()), id: \.offset) { index, item in
                if let listItem = item as? ListItem {
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.body)
                        Text(listItem.plainText)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
        VStack(alignment: .leading, spacing: 0) {
            let head = table.head
            HStack(spacing: 0) {
                ForEach(Array(head.cells.enumerated()), id: \.offset) { _, cell in
                    Text(cell.plainText)
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor))
                }
            }
            
            ForEach(Array(table.body.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                        Text(cell.plainText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
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
