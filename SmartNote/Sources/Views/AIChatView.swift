import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// 视图内"上传前的图片附件"——仅在本视图持有，不持久化。
struct ChatImageAttachment: Identifiable, Hashable {
    let id: UUID
    let fileName: String
    let base64: String
    let mediaType: String
    /// 缩略图（同时用作 UI 预览用 NSImage）
    let thumbnail: NSImage?
}

struct AIChatView: View {
    @EnvironmentObject var appState: AppState
    @State private var userMessage = ""
    @State private var messages: [ChatMessage] = []
    @State private var isSending = false
    @State private var showSettings = false
    @State private var currentStreamingID: UUID?
    @State private var streamingContent = ""
    @State private var attachments: [ChatImageAttachment] = []
    @State private var showImagePicker: Bool = false
    @State private var isTargeted: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            Divider()
            
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            ChatMessageView(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _ in
                    if let lastMessage = messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            Divider()

            attachmentStrip

            inputView
        }
        .sheet(isPresented: $showSettings) {
            LLMSettingsView()
                .environmentObject(appState)
        }
    }
    
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("智能对话")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("与 AI 助手讨论问题")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if isSending {
                Button {
                    cancelCurrentRequest()
                } label: {
                    Label("取消", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            
            speechControls
            
            if !appState.llmConfiguration.enabled {
                Button {
                    showSettings = true
                } label: {
                    Label("配置 AI", systemImage: "gear")
                }
                .buttonStyle(.bordered)
            }
            
            Button {
                messages.removeAll()
            } label: {
                Label("清空", systemImage: "trash")
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
    
    private var speechControls: some View {
        HStack(spacing: 8) {
            if appState.speechService.isSpeaking {
                Button {
                    appState.speechService.togglePause()
                } label: {
                    Label(
                        appState.speechService.isPaused ? "继续" : "暂停",
                        systemImage: appState.speechService.isPaused ? "play.fill" : "pause.fill"
                    )
                }
                .buttonStyle(.bordered)
                
                Button {
                    appState.speechService.stop()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            
            Menu {
                ForEach(appState.speechService.getChineseVoices(), id: \.self) { voice in
                    Button(appState.speechService.getVoiceDisplayName(voice)) {
                        appState.speechService.setVoice(voice)
                    }
                }
            } label: {
                Label("语音", systemImage: "speaker.wave.2.fill")
            }
            .menuStyle(.borderlessButton)
        }
    }
    
    private var inputView: some View {
        HStack(spacing: 12) {
            if !appState.llmConfiguration.enabled {
                VStack(alignment: .leading) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("请先在设置中启用 AI")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            TextField("输入问题...", text: $userMessage, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .disabled(!appState.llmConfiguration.enabled || isSending)

            Button {
                showImagePicker = true
            } label: {
                Image(systemName: "photo.on.rectangle.angled")
            }
            .help("附加图片（仅 OpenAI / Anthropic 多模态 API）")
            .disabled(!appState.llmConfiguration.enabled
                      || !appState.llmConfiguration.supportsNativeVision
                      || attachments.count >= appState.llmConfiguration.visionMaxImages
                      || isSending)

            Button {
                sendMessage()
            } label: {
                if isSending {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "paperplane.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled((userMessage.isEmpty && attachments.isEmpty)
                      || !appState.llmConfiguration.enabled
                      || isSending)
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.image, .fileURL], isTargeted: $isTargeted) { providers in
            handleDroppedImages(providers)
        }
        .fileImporter(
            isPresented: $showImagePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            handlePickedImages(result)
        }
    }

    // MARK: - 图片附件处理

    private func handlePickedImages(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls { ingestImageURL(url) }
        case .failure(let err):
            print("Image pick failed: \(err)")
        }
    }

    private func handleDroppedImages(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            p.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                defer { group.leave() }
                guard let data,
                      let s = String(data: data, encoding: .utf8),
                      let u = URL(string: s) else { return }
                let ext = u.pathExtension.lowercased()
                if ["png","jpg","jpeg","webp","gif","heic"].contains(ext) {
                    urls.append(u)
                }
            }
        }
        group.notify(queue: .main) { for u in urls { self.ingestImageURL(u) } }
        return true
    }

    private func ingestImageURL(_ url: URL) {
        let cfg = appState.llmConfiguration
        let allowed = cfg.supportsNativeVision && attachments.count < cfg.visionMaxImages
        guard allowed else { return }
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        guard let image = NSImage(contentsOf: url) else { return }
        guard let (data, mediaType) = LLMService.encodeForVision(image, quality: cfg.visionImageQuality, maxEdge: cfg.visionImageMaxEdge) else { return }
        let thumb = thumbnailFromImage(image, maxEdge: 120)
        let base64 = data.base64EncodedString()
        attachments.append(ChatImageAttachment(
            id: UUID(),
            fileName: url.lastPathComponent,
            base64: base64,
            mediaType: mediaType,
            thumbnail: thumb
        ))
    }

    private func thumbnailFromImage(_ image: NSImage, maxEdge: Int) -> NSImage? {
        let size = image.size
        let scale = CGFloat(maxEdge) / Swift.max(size.width, size.height)
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        let out = NSImage(size: target)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target))
        out.unlockFocus()
        return out
    }

    private var attachmentStrip: some View {
        Group {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { att in
                            ZStack(alignment: .topTrailing) {
                                if let img = att.thumbnail {
                                    Image(nsImage: img).resizable().scaledToFit().frame(width: 60, height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                } else {
                                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.2)).frame(width: 60, height: 60)
                                }
                                Button { attachments.removeAll { $0.id == att.id } } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                        .background(Circle().fill(Color.white))
                                }
                                .buttonStyle(.plain)
                                .offset(x: 6, y: -6)
                            }
                            .help(att.fileName)
                        }
                        Text("\(attachments.count) 张图")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
                .frame(height: 70)
                .padding(.bottom, 4)
            }
        }
    }

    private func sendMessage() {
        let question = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasImages = !attachments.isEmpty
        guard !question.isEmpty || hasImages else { return }

        let userMsg = ChatMessage(id: UUID(), role: .user,
                                  content: question.isEmpty ? "[图片消息]" : question)
        messages.append(userMsg)

        let systemMsg = ChatMessage(id: UUID(), role: .system, content: "")
        messages.append(systemMsg)

        let userMessageSnapshot = question
        let attachmentsSnapshot = attachments
        userMessage = ""
        attachments = []
        isSending = true
        currentStreamingID = systemMsg.id
        streamingContent = ""

        Task {
            do {
                let prompt = """
                你是一个专业的学习助手。请用中文回答用户的问题。如果需要，可以结合学习资料中的知识点进行解答。
                """

                if attachmentsSnapshot.isEmpty {
                    // 纯文本流式
                    try await appState.llmService.sendMessageStreaming(system: prompt, user: userMessageSnapshot) { chunk in
                        Task { @MainActor in
                            self.streamingContent += chunk
                            if let index = self.messages.firstIndex(where: { $0.id == self.currentStreamingID }) {
                                self.messages[index] = ChatMessage(id: self.currentStreamingID!, role: .system, content: self.streamingContent)
                            }
                        }
                    }
                } else {
                    // 多模态流式
                    let images: [LLMService.ImagePayload] = attachmentsSnapshot.map {
                        LLMService.ImagePayload(base64: $0.base64, mediaType: $0.mediaType)
                    }
                    try await appState.llmService.sendMessageWithImagesStreaming(system: prompt, user: userMessageSnapshot.isEmpty ? "请描述这张图" : userMessageSnapshot, images: images) { chunk in
                        Task { @MainActor in
                            self.streamingContent += chunk
                            if let index = self.messages.firstIndex(where: { $0.id == self.currentStreamingID }) {
                                self.messages[index] = ChatMessage(id: self.currentStreamingID!, role: .system, content: self.streamingContent)
                            }
                        }
                    }
                }
                
                await MainActor.run {
                    isSending = false
                    currentStreamingID = nil
                    if !streamingContent.isEmpty {
                        appState.speechService.speak(streamingContent)
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    isSending = false
                    currentStreamingID = nil
                }
            } catch {
                await MainActor.run {
                    if let index = messages.firstIndex(where: { $0.id == systemMsg.id }) {
                        messages[index] = ChatMessage(id: systemMsg.id, role: .system, content: "抱歉，发生错误: \(error.localizedDescription)")
                    }
                    isSending = false
                    currentStreamingID = nil
                }
            }
        }
    }
    
    private func cancelCurrentRequest() {
        appState.llmService.cancelCurrentRequest()
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: MessageRole
    var content: String
    
    enum MessageRole: String {
        case user
        case system
    }
}

struct ChatMessageView: View {
    let message: ChatMessage
    @State private var showRawText = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.role == .system {
                Image(systemName: "brain.head.profile")
                    .foregroundColor(.accentColor)
                    .frame(width: 30)
            } else {
                Image(systemName: "person.circle.fill")
                    .foregroundColor(.blue)
                    .frame(width: 30)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(message.role == .user ? "你" : "AI 助手")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    if message.role == .system {
                        Toggle("源码", isOn: $showRawText)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    }
                }
                
                if showRawText || message.role == .user {
                    Text(message.content)
                        .font(.body)
                        .textSelection(.enabled)
                } else {
                    ScrollView {
                        MarkdownText(message.content)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            
            Spacer()
        }
        .padding()
        .background(message.role == .user ? Color.blue.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }
}
