import SwiftUI
import AppKit

/// 主白板视图
struct WhiteboardView: View {
    @StateObject private var service = WhiteboardService.shared
    @State private var tool: WhiteboardTool = .pen
    @State private var currentColor: WhiteboardColor = .black
    @State private var strokeWidth: Double = 3.0
    @State private var fillStyle: FillStyle = .none
    @State private var zoom: Double = 1.0
    @State private var offset: CGSize = .zero
    @State private var selectedIDs: Set<UUID> = []
    @State private var isOptionKeyPressed: Bool = false
    @State private var showDocumentPicker: Bool = false
    @State private var showRenameDialog: Bool = false
    @State private var newDocumentName: String = ""
    @State private var showAutoSaveStatus: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏
            toolbar
            Divider()
            
            // 主内容
            HStack(spacing: 0) {
                // 左侧工具栏
                leftToolbar
                Divider()
                
                // 画布
                ZStack {
                    if let doc = service.currentDocument {
                        WhiteboardCanvasView(
                            service: service,
                            tool: $tool,
                            currentColor: $currentColor,
                            strokeWidth: $strokeWidth,
                            fillStyle: $fillStyle,
                            zoom: $zoom,
                            offset: $offset,
                            selectedIDs: $selectedIDs,
                            isOptionKeyPressed: $isOptionKeyPressed,
                            canvasSize: .zero
                        )
                    } else {
                        emptyStateView
                    }
                    
                    // 底部状态栏
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            statusBar
                        }
                    }
                }
                Divider()
                
                // 右侧属性面板
                rightPanel
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        // 监听 Option 键
        .background(OptionKeyMonitor(isPressed: $isOptionKeyPressed))
        // 自动保存状态提示
        .onReceive(service.objectWillChange) { _ in
            showAutoSaveStatus = true
        }
        .sheet(isPresented: $showDocumentPicker) {
            documentPicker
        }
        .alert("重命名画板", isPresented: $showRenameDialog) {
            TextField("画板名称", text: $newDocumentName)
            Button("取消", role: .cancel) {}
            Button("确定") {
                if let doc = service.currentDocument {
                    service.renameDocument(doc, to: newDocumentName)
                }
            }
        }
    }
    
    // MARK: - 顶部工具栏
    
    private var toolbar: some View {
        HStack(spacing: 12) {
            // 画板选择
            Button {
                showDocumentPicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                    Text(service.currentDocument?.name ?? "未选择")
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
            }
            .buttonStyle(.bordered)
            
            // 撤销/重做
            Button {
                service.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .disabled(!service.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .help("撤销 (⌘Z)")
            
            Button {
                service.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.bordered)
            .disabled(!service.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help("重做 (⌘⇧Z)")
            
            Divider().frame(height: 20)
            
            // 删除选中
            Button {
                service.deleteObjects(ids: selectedIDs)
                selectedIDs.removeAll()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(selectedIDs.isEmpty)
            .help("删除选中")
            
            // 复制选中
            Button {
                if let doc = service.currentDocument {
                    let selected = doc.objects.filter { selectedIDs.contains($0.id) }
                    service.copyObjects(selected)
                }
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .disabled(selectedIDs.isEmpty)
            .help("复制选中")
            .keyboardShortcut("d", modifiers: .command)
            
            Divider().frame(height: 20)
            
            // 模式指示
            HStack(spacing: 6) {
                Circle()
                    .fill(tool == .pen && isOptionKeyPressed ? Color.orange : (tool == .pen ? Color.green : Color.gray))
                    .frame(width: 8, height: 8)
                Text(currentModeText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // 自动保存状态
            if showAutoSaveStatus {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                    Text("已自动保存")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    
    private var currentModeText: String {
        if isOptionKeyPressed {
            return "选择模式（按 Option 临时切换）"
        }
        switch tool {
        case .pen: return "画笔模式"
        case .select: return "选择模式"
        default: return "\(tool.displayName)模式"
        }
    }
    
    // MARK: - 左侧工具栏
    
    private var leftToolbar: some View {
        VStack(spacing: 8) {
            ForEach(WhiteboardTool.allCases) { t in
                ToolButton(
                    tool: t,
                    isActive: tool == t && !isOptionKeyPressed,
                    action: { tool = t }
                )
            }
            
            Divider().padding(.vertical, 4)
            
            // 颜色选择
            VStack(spacing: 4) {
                ForEach(WhiteboardColor.palette, id: \.self) { color in
                    Button {
                        currentColor = color
                    } label: {
                        Circle()
                            .fill(color.color)
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle()
                                    .stroke(currentColor == color ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: currentColor == color ? 2 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            
            Spacer()
        }
        .padding(8)
        .frame(width: 60)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
    
    // MARK: - 右侧属性面板
    
    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 笔划粗细
            propertySection(title: "笔划粗细", icon: "lineweight") {
                VStack(spacing: 4) {
                    Slider(value: $strokeWidth, in: 1...30, step: 0.5)
                    Text("\(Int(strokeWidth)) px")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // 填充样式
            propertySection(title: "填充", icon: "paintbrush.fill") {
                HStack(spacing: 6) {
                    FillButton(style: .none, current: $fillStyle)
                    FillButton(style: .solid, current: $fillStyle)
                    FillButton(style: .semiTransparent, current: $fillStyle)
                }
            }
            
            // 颜色选择
            propertySection(title: "颜色", icon: "paintpalette") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 28))], spacing: 6) {
                    ForEach(WhiteboardColor.palette, id: \.self) { color in
                        Button {
                            currentColor = color
                        } label: {
                            Circle()
                                .fill(color.color)
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Circle()
                                        .stroke(currentColor == color ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: currentColor == color ? 2 : 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            
            // 缩放控制
            propertySection(title: "缩放", icon: "magnifyingglass") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Button {
                            zoom = max(0.1, zoom - 0.1)
                        } label: {
                            Image(systemName: "minus.magnifyingglass")
                        }
                        .buttonStyle(.bordered)
                        
                        Text("\(Int(zoom * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 50)
                        
                        Button {
                            zoom = min(10, zoom + 0.1)
                        } label: {
                            Image(systemName: "plus.magnifyingglass")
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    Text("• 触控板捏合 / Cmd+滚轮：缩放")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("• 触控板两指滑动 / 滚轮：平移")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            
            // 重置视图
            Button {
                zoom = 1.0
                offset = .zero
            } label: {
                Label("重置视图", systemImage: "arrow.counterclockwise")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            
            Spacer()
            
            // 自动保存信息
            VStack(alignment: .leading, spacing: 4) {
                Label("自动保存已启用", systemImage: "icloud.and.arrow.up")
                    .font(.caption)
                    .foregroundColor(.green)
                Text("每 3 秒自动保存")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .frame(width: 220)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
    
    private func propertySection<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundColor(.secondary)
            content()
        }
    }
    
    // MARK: - 状态栏（右下角）显示比例
    
    private var statusBar: some View {
        HStack(spacing: 16) {
            // 自动保存状态
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
                Text("已自动保存")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
            .cornerRadius(6)
            
            // 缩放比例
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                Text("\(Int(zoom * 100))%")
                    .font(.system(size: 11, design: .monospaced))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
            .cornerRadius(6)
            
            // 对象数量
            HStack(spacing: 4) {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                Text("\(service.currentDocument?.objects.count ?? 0) 个对象")
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
            .cornerRadius(6)
        }
        .padding(8)
    }
    
    // MARK: - 文档选择
    
    private var documentPicker: some View {
        VStack(spacing: 0) {
            HStack {
                Text("画板管理")
                    .font(.headline)
                Spacer()
                Button {
                    let doc = service.createDocument(name: "新建画板 \(service.documents.count + 1)")
                    _ = doc
                } label: {
                    Label("新建", systemImage: "plus")
                }
                Button("完成") { showDocumentPicker = false }
            }
            .padding()
            
            Divider()
            
            List {
                ForEach(service.documents) { doc in
                    HStack {
                        Image(systemName: doc.id == service.currentDocument?.id ? "doc.text.fill" : "doc.text")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.name)
                                .font(.system(size: 13, weight: .medium))
                            Text("\(doc.objects.count) 个对象")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button {
                            newDocumentName = doc.name
                            showRenameDialog = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.plain)
                        Button {
                            service.deleteDocument(doc)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        service.selectDocument(doc)
                    }
                }
            }
            .frame(width: 450, height: 400)
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "scribble.variable")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text("没有可用的画板")
                .font(.headline)
            Button("创建新画板") {
                _ = service.createDocument()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - 工具按钮

struct ToolButton: View {
    let tool: WhiteboardTool
    let isActive: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: tool.icon)
                    .font(.system(size: 18))
                Text(tool.displayName)
                    .font(.system(size: 9))
            }
            .frame(width: 44, height: 44)
            .background(isActive ? Color.accentColor : Color.clear)
            .foregroundColor(isActive ? .white : .primary)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .help(tool.displayName)
    }
}

// MARK: - 填充按钮

struct FillButton: View {
    let style: FillStyle
    @Binding var current: FillStyle
    
    var icon: String {
        switch style {
        case .none: return "circle"
        case .solid: return "circle.fill"
        case .semiTransparent: return "circle.lefthalf.filled"
        }
    }
    
    var label: String {
        switch style {
        case .none: return "无"
        case .solid: return "实心"
        case .semiTransparent: return "半透"
        }
    }
    
    var body: some View {
        Button {
            current = style
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                Text(label)
                    .font(.system(size: 9))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(current == style ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            .foregroundColor(current == style ? .white : .primary)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Option 键监听

/// 全局监听 Option 键按下/释放，触发模式切换
struct OptionKeyMonitor: NSViewRepresentable {
    @Binding var isPressed: Bool
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        DispatchQueue.main.async {
            context.coordinator.startMonitoring()
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(isPressed: $isPressed)
    }
    
    class Coordinator {
        @Binding var isPressed: Bool
        private var globalMonitor: Any?
        private var localMonitor: Any?
        private var lastOptionState: Bool = false
        
        init(isPressed: Binding<Bool>) {
            self._isPressed = isPressed
        }
        
        func startMonitoring() {
            // 使用 NSEvent.addLocalMonitorForEvents 监听 keyDown/keyUp
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
                guard let self = self else { return event }
                let optionPressed = event.modifierFlags.contains(.option)
                if optionPressed != self.lastOptionState {
                    self.lastOptionState = optionPressed
                    DispatchQueue.main.async {
                        self.isPressed = optionPressed
                    }
                }
                return event
            }
        }
        
        deinit {
            if let monitor = localMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let monitor = globalMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
