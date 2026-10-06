import SwiftUI

/// iOS 智能阅卷界面。
///
/// 批改由 `LLMService.sendMessageStreaming(system:user:)` 流式返回，
/// 与 macOS 界面使用同一套提示词与服务，因此两端的批改口径一致。
struct SmartGradingView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme

    @State private var mode: GradingMode = .homework
    @State private var questionInput = ""
    @State private var answerInput = ""
    @State private var result = ""
    @State private var isGrading = false
    @State private var streamBuffer = ""

    private enum GradingMode: String, CaseIterable, Identifiable {
        case homework = "作业"
        case exam = "试卷"
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            Section {
                Picker("类型", selection: $mode) {
                    ForEach(GradingMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section(mode == .homework ? "题目" : "试卷内容") {
                TextField(
                    mode == .homework ? "粘贴题目" : "粘贴试卷原文",
                    text: $questionInput,
                    axis: .vertical
                )
                .lineLimit(3...10)
            }

            Section("学生作答") {
                TextField("粘贴学生答案", text: $answerInput, axis: .vertical)
                    .lineLimit(3...12)
            }

            Section {
                Button {
                    Task { await grade() }
                } label: {
                    HStack {
                        Spacer()
                        if isGrading {
                            ProgressView()
                        } else {
                            Label("开始批改", systemImage: "checkmark.seal.fill")
                        }
                        Spacer()
                    }
                }
                .disabled(isGrading || questionInput.isEmpty || !appState.llmConfiguration.enabled)
            }

            if !result.isEmpty {
                Section("批改结果") {
                    MarkdownText_iOS(result)
                }
            } else if !appState.llmConfiguration.enabled {
                Section {
                    Text("请先在「设置 → AI」中启用并配置大模型服务。")
                        .font(.footnote)
                        .foregroundStyle(appTheme.secondaryText)
                }
            }
        }
        .navigationTitle("智能阅卷")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 组装提示词并流式接收批改结果。
    private func grade() async {
        isGrading = true
        result = ""
        streamBuffer = ""

        let prompt: String
        if mode == .homework {
            prompt = """
            请批改以下作业题目，并对每道题给出评分与解析。

            【原题】
            \(questionInput)

            【学生回答】
            \(answerInput.isEmpty ? "（未提供）" : answerInput)

            请按以下格式回复：
            1. 总体评价
            2. 每题得分与解析
            3. 错误原因
            4. 改进建议

            请用中文回复，使用 Markdown 格式。
            """
        } else {
            prompt = """
            请批改以下作业/试卷，并给出详细的分析和评价。

            【原题】
            \(questionInput)

            【学生回答】
            \(answerInput.isEmpty ? "（未提供）" : answerInput)

            请按以下格式回复：
            1. 总体评价
            2. 正确题目及解析
            3. 错误题目及解析
            4. 改进建议

            请用中文回复，使用 Markdown 格式。
            """
        }

        do {
            try await appState.llmService.sendMessageStreaming(
                system: "你是一个专业的老师，请仔细批改作业并给出详细的反馈。",
                user: prompt
            ) { chunk in
                streamBuffer += chunk
                // 每个分片都回写一次完整快照，保证界面显示的是累积结果。
                result = streamBuffer
            }
        } catch {
            if result.isEmpty {
                appState.errorMessage = "批改失败：\(error.localizedDescription)"
                appState.showError = true
            }
        }

        isGrading = false
    }
}

/// Markdown 渲染。
///
/// 直接用 Foundation 的 `AttributedString(markdown:)`——它是 Apple 维护的
/// CommonMark 解析器，行为在所有系统版本上一致。手写正则解析 Markdown 很容易
/// 在嵌套、转义或不成对的标记上出错，得不偿失。
struct MarkdownText_iOS: View {
    let source: String

    /// 无参名构造，方便直接传字符串。
    init(_ source: String) {
        self.source = source
    }

    var body: some View {
        // 模型输出常带 ```` ``` ```` 代码块与表格；`inlineOnlyPreservingWhitespace`
        // 会把它们原样显示，避免把 ``` 当成正文。
        Text(attributed)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private var attributed: AttributedString {
        // 解析失败时退回纯文本，绝不因为格式问题而空白。
        (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
    }
}
