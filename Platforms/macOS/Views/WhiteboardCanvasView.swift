import SwiftUI
import AppKit

/// 画板画布视图 - 负责绘制、交互、撤销等
///
/// 性能优化要点：
/// 1. 使用 Canvas + TimelineView 进行高频绘制，避免 ForEach 反复重建子 view
/// 2. 笔划点直接追加到 @State 数组（value-type copy，但 SwiftUI 内部优化）
/// 3. 实时笔划用独立的 Canvas 渲染，独立于已保存对象
struct WhiteboardCanvasView: View {
    @ObservedObject var service: WhiteboardService
    @Binding var tool: WhiteboardTool
    @Binding var currentColor: WhiteboardColor
    @Binding var fillColor: WhiteboardColor
    @Binding var strokeWidth: Double
    @Binding var fillStyle: FillStyle
    @Binding var zoom: Double
    @Binding var offset: CGSize
    @Binding var selectedIDs: Set<UUID>
    @Binding var isOptionKeyPressed: Bool
    // 几何曲线插入面板：在函数图 / 参数方程 / 极坐标工具下点击画布时弹出
    @Binding var showFunctionSheet: Bool
    @Binding var showParametricSheet: Bool
    @Binding var showPolarSheet: Bool
    // 测量工具的临时目标选择（顺序敏感：角度测量的顶点在中间）
    @Binding var measureTargets: [UUID]
    let canvasSize: CGSize
    
    // 当前正在绘制的对象
    @State private var drawingObject: WhiteboardObject?
    @State private var dragStartPoint: WhiteboardPoint?
    @State private var dragOriginalObjects: [WhiteboardObject] = []
    @State private var hasRecordedUndoForDrag: Bool = false
    @State private var currentStroke: StrokeShape?
    @State private var hasMovedSignificantly: Bool = false
    @State private var dragStartedAt: Date = Date()
    
    // 文字输入
    @State private var showTextInputSheet = false
    @State private var textInputContent = ""
    @State private var textInputPoint: WhiteboardPoint = WhiteboardPoint(x: 0, y: 0)
    @State private var textInputFontSize: Double = 18.0
    @State private var textInputIsBold: Bool = false
    @State private var textInputIsItalic: Bool = false
    
    // 用于驱动 TimelineView 重绘
    @State private var renderTick: Int = 0
    
    // 缩放/平移状态
    @State private var pinchStartZoom: Double = 1.0
    @State private var pinchStartOffset: CGSize = .zero
    @State private var lastMouseLocation: CGPoint? = nil
    // 供选择工具使用：框选起点/临时矩形（世界坐标）
    @State private var marqueeStart: WhiteboardPoint? = nil
    @State private var marqueeRect: WhiteboardRect? = nil
    // 键盘事件监控句柄
    @State private var keyDownMonitor: Any? = nil
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 背景网格
                GridBackground(zoom: zoom, offset: offset)
                
                // 已有对象 - 使用 Canvas 一次性绘制所有对象
                TimelineView(.animation) { timeline in
                    Canvas { context, _ in
                        // 绘制所有已保存的对象
                        drawAllObjects(context: context)
                        // 绘制正在绘制的对象
                        if let drawing = drawingObject {
                            drawObject(drawing, context: context)
                        }
                        // 绘制当前笔划
                        if let stroke = currentStroke, !stroke.points.isEmpty {
                            drawStroke(stroke, context: context)
                        }
                        // 绘制选区边框
                        if !selectedIDs.isEmpty && tool == .select {
                            drawBounds(for: selectedIDs, context: context)
                        }
                        // 测量目标高亮
                        if tool == .measure && !measureTargets.isEmpty {
                            drawBounds(for: Set(measureTargets), context: context)
                        }
                                // 绘制框选矩形（正在拖拽选择）
                                if let m = marqueeRect {
                                    drawMarquee(rect: m, context: context)
                                }
                    }
                }
            }
            .contextMenu {
                if !selectedIDs.isEmpty && tool == .select {
                    Button(role: .destructive) {
                        service.deleteObjects(ids: selectedIDs)
                        selectedIDs.removeAll()
                    } label: {
                        Text("删除")
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        handleDragChanged(value: value)
                        lastMouseLocation = value.location
                    }
                    .onEnded { value in
                        handleDragEnded(value: value)
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 1)
                    .onEnded {
                        if tool == .select && !hasMovedSignificantly {
                            selectedIDs.removeAll()
                        }
                        hasMovedSignificantly = false
                    }
            )
            // 触控板捏合手势（缩放）
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        let newZoom = max(0.1, min(10, pinchStartZoom * Double(value)))
                        let center = lastMouseLocation ?? CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                        applyZoom(newZoom: newZoom, center: center)
                    }
                    .onEnded { _ in
                        pinchStartZoom = zoom
                        pinchStartOffset = offset
                    }
            )
            // 背景层：监听鼠标滚轮 / 触控板手势
            .background(
                CanvasEventMonitor { deltaX, deltaY, isZoom, isMagnify in
                    handleCanvasEvent(
                        deltaX: deltaX,
                        deltaY: deltaY,
                        isZoom: isZoom,
                        isMagnify: isMagnify,
                        viewSize: geometry.size
                    )
                }
                .frame(width: 0, height: 0)
            )
        }
        .background(Color(white: 1.0))
        .clipped()
        .onAppear {
            pinchStartZoom = zoom
            pinchStartOffset = offset
            // 监听删除键（Backspace / Delete）以便删除选中对象
            keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { ev in
                guard let chars = ev.charactersIgnoringModifiers?.lowercased() else { return ev }
                if (chars == "\u{8}" || chars == "\u{7f}") || ev.keyCode == 51 || ev.keyCode == 117 {
                    // 删除键或 forward delete
                    if !selectedIDs.isEmpty {
                        service.deleteObjects(ids: selectedIDs)
                        selectedIDs.removeAll()
                        return nil
                    }
                }
                return ev
            }
        }
        .onDisappear {
            if let m = keyDownMonitor {
                NSEvent.removeMonitor(m)
                keyDownMonitor = nil
            }
        }
        .sheet(isPresented: $showTextInputSheet) {
            textInputSheet
        }
    }
    
    // MARK: - 文字输入
    
    private func presentTextInput(at point: WhiteboardPoint) {
        textInputPoint = point
        textInputContent = ""
        textInputFontSize = max(12, strokeWidth * 6) // 用笔划粗细估算字号
        textInputIsBold = false
        textInputIsItalic = false
        showTextInputSheet = true
    }
    
    private func commitTextInput() {
        let trimmed = textInputContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showTextInputSheet = false
            return
        }
        var text = TextShape(
            position: textInputPoint,
            text: trimmed,
            color: currentColor,
            fontSize: textInputFontSize,
            isBold: textInputIsBold,
            isItalic: textInputIsItalic
        )
        text.fitRectToContent()
        service.addObject(.text(text))
        showTextInputSheet = false
    }
    
    private var textInputSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") {
                    showTextInputSheet = false
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Text("添加文字")
                    .font(.headline)
                
                Spacer()
                
                Button("确定") {
                    commitTextInput()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                // 文字内容
                TextEditor(text: $textInputContent)
                    .font(.system(size: 16))
                    .frame(minHeight: 100)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                
                // 字号
                HStack {
                    Text("字号")
                        .font(.caption)
                        .frame(width: 50, alignment: .leading)
                    Slider(value: $textInputFontSize, in: 10...72, step: 1)
                    Text("\(Int(textInputFontSize))")
                        .font(.caption)
                        .frame(width: 30, alignment: .trailing)
                        .monospacedDigit()
                }
                
                // 加粗/斜体
                HStack(spacing: 12) {
                    Toggle(isOn: $textInputIsBold) {
                        Label("加粗", systemImage: "bold")
                    }
                    .toggleStyle(.button)
                    
                    Toggle(isOn: $textInputIsItalic) {
                        Label("斜体", systemImage: "italic")
                    }
                    .toggleStyle(.button)
                    
                    Spacer()
                }
            }
            .padding()
            
            Spacer()
        }
        .frame(width: 480, height: 340)
    }
    
    // MARK: - 缩放与平移
    
    private func applyZoom(newZoom: Double, center: CGPoint) {
        let oldZoom = zoom
        guard oldZoom > 0 else { return }
        let ratio = newZoom / oldZoom
        // 保持 center 点对应的世界坐标不变：
        // (center - offset) / oldZoom = (center - newOffset) / newZoom
        // newOffset = center - (center - offset) * ratio
        let newOffsetW = center.x - (center.x - offset.width) * ratio
        let newOffsetH = center.y - (center.y - offset.height) * ratio
        zoom = newZoom
        offset = CGSize(width: newOffsetW, height: newOffsetH)
    }
    
    private func handleCanvasEvent(deltaX: CGFloat, deltaY: CGFloat, isZoom: Bool, isMagnify: Bool, viewSize: CGSize) {
        if isZoom {
            // 缩放：围绕视图中心或上次鼠标位置
            let center = lastMouseLocation ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
            if isMagnify {
                // Magnify 事件：deltaY 是 magnification（增量）
                let factor = 1.0 + Double(deltaY)
                let newZoom = max(0.1, min(10, zoom * factor))
                applyZoom(newZoom: newZoom, center: center)
            } else {
                // 滚轮缩放：deltaY 是滚动增量
                let factor = 1.0 + Double(deltaY) * 0.01
                let newZoom = max(0.1, min(10, zoom * factor))
                applyZoom(newZoom: newZoom, center: center)
            }
        } else {
            // 平移
            offset.width += Double(deltaX)
            offset.height += Double(deltaY)
        }
    }
    
    // MARK: - Canvas 渲染（高性能）
    
    private func drawAllObjects(context: GraphicsContext) {
        guard let doc = service.currentDocument else { return }
        let objects = doc.objects.sorted { $0.zIndex < $1.zIndex }
        for obj in objects {
            drawObject(obj, context: context)
        }
    }
    
    private func drawObject(_ object: WhiteboardObject, context: GraphicsContext) {
        switch object {
        case .stroke(let s):
            drawStroke(s, context: context)
        case .rectangle(let r):
            drawRectangle(r, context: context)
        case .ellipse(let e):
            drawEllipse(e, context: context)
        case .triangle(let t):
            drawTriangle(t, context: context)
        case .line(let l):
            drawLine(l, context: context)
        case .arrow(let a):
            drawArrow(a, context: context)
        case .text(let t):
            drawText(t, context: context)
        case .point(let p):
            drawPoint(p, context: context)
        case .circle(let c):
            drawCircle(c, context: context)
        case .arc(let a):
            drawArc(a, context: context)
        case .polygon(let p):
            drawPolygon(p, context: context)
        case .functionPlot(let f):
            drawFunctionPlot(f, context: context)
        case .parametricPlot(let p):
            drawParametricPlot(p, context: context)
        case .polarPlot(let p):
            drawPolarPlot(p, context: context)
        case .measurement(let m):
            drawMeasurement(m, context: context)
        }
    }
    
    private func drawStroke(_ stroke: StrokeShape, context: GraphicsContext) {
        let points = stroke.points
        guard !points.isEmpty else { return }
        
        var path = Path()
        
        if points.count == 1 {
            // 单点：画小圆
            let p0 = points[0]
            let r = (stroke.strokeWidth * zoom) / 2
            let rect = CGRect(
                x: p0.x * zoom + offset.width - r,
                y: p0.y * zoom + offset.height - r,
                width: r * 2,
                height: r * 2
            )
            path.addEllipse(in: rect)
            context.fill(path, with: .color(stroke.color.color))
            return
        }
        
        path.move(to: CGPoint(
            x: points[0].x * zoom + offset.width,
            y: points[0].y * zoom + offset.height
        ))
        
        if points.count == 2 {
            path.addLine(to: CGPoint(
                x: points[1].x * zoom + offset.width,
                y: points[1].y * zoom + offset.height
            ))
        } else {
            for i in 1..<points.count {
                let curr = points[i]
                let prev = points[i - 1]
                let mid = WhiteboardPoint(
                    x: (prev.x + curr.x) / 2,
                    y: (prev.y + curr.y) / 2
                )
                path.addQuadCurve(
                    to: CGPoint(x: mid.x * zoom + offset.width, y: mid.y * zoom + offset.height),
                    control: CGPoint(x: prev.x * zoom + offset.width, y: prev.y * zoom + offset.height)
                )
            }
            if let last = points.last {
                path.addLine(to: CGPoint(
                    x: last.x * zoom + offset.width,
                    y: last.y * zoom + offset.height
                ))
            }
        }
        
        context.stroke(
            path,
            with: .color(stroke.color.color),
            style: StrokeStyle(
                lineWidth: max(0.5, stroke.strokeWidth * zoom),
                lineCap: .round,
                lineJoin: .round
            )
        )
    }
    
    private func drawRectangle(_ r: RectangleShape, context: GraphicsContext) {
        let rect = CGRect(
            x: r.rect.x * zoom + offset.width,
            y: r.rect.y * zoom + offset.height,
            width: r.rect.width * zoom,
            height: r.rect.height * zoom
        )
        
        if r.fillStyle.isVisible {
            // 优先使用 fillColor；为空时回退到笔划色
            let fillColor = r.fillColor ?? r.color
            let fillColorSwiftUI: Color
            switch r.fillStyle {
            case .none: fillColorSwiftUI = .clear
            case .solid: fillColorSwiftUI = fillColor.color
            case .semiTransparent: fillColorSwiftUI = fillColor.color.opacity(0.4)
            }
            context.fill(Path(rect), with: .color(fillColorSwiftUI))
        }
        
        context.stroke(
            Path(rect),
            with: .color(r.color.color),
            lineWidth: max(0.5, r.strokeWidth * zoom)
        )
    }
    
    private func drawEllipse(_ e: EllipseShape, context: GraphicsContext) {
        let rect = CGRect(
            x: e.rect.x * zoom + offset.width,
            y: e.rect.y * zoom + offset.height,
            width: e.rect.width * zoom,
            height: e.rect.height * zoom
        )
        let path = Path(ellipseIn: rect)
        
        if e.fillStyle.isVisible {
            let fillColor = e.fillColor ?? e.color
            let fillColorSwiftUI: Color
            switch e.fillStyle {
            case .none: fillColorSwiftUI = .clear
            case .solid: fillColorSwiftUI = fillColor.color
            case .semiTransparent: fillColorSwiftUI = fillColor.color.opacity(0.4)
            }
            context.fill(path, with: .color(fillColorSwiftUI))
        }
        
        context.stroke(
            path,
            with: .color(e.color.color),
            lineWidth: max(0.5, e.strokeWidth * zoom)
        )
    }
    
    private func drawTriangle(_ t: TriangleShape, context: GraphicsContext) {
        let rect = CGRect(
            x: t.rect.x * zoom + offset.width,
            y: t.rect.y * zoom + offset.height,
            width: t.rect.width * zoom,
            height: t.rect.height * zoom
        )
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        
        if t.fillStyle.isVisible {
            let fillColor = t.fillColor ?? t.color
            let fillColorSwiftUI: Color
            switch t.fillStyle {
            case .none: fillColorSwiftUI = .clear
            case .solid: fillColorSwiftUI = fillColor.color
            case .semiTransparent: fillColorSwiftUI = fillColor.color.opacity(0.4)
            }
            context.fill(path, with: .color(fillColorSwiftUI))
        }
        
        context.stroke(
            path,
            with: .color(t.color.color),
            lineWidth: max(0.5, t.strokeWidth * zoom)
        )
    }
    
    private func drawText(_ t: TextShape, context: GraphicsContext) {
        let screenRect = CGRect(
            x: t.rect.x * zoom + offset.width,
            y: t.rect.y * zoom + offset.height,
            width: max(1, t.rect.width * zoom),
            height: max(1, t.rect.height * zoom)
        )
        let screenFontSize = t.fontSize * zoom
        
        // 文字基线
        let baselineY = screenRect.minY + screenFontSize * 0.85
        
        var font: Font {
            if t.isBold && t.isItalic {
                return .system(size: screenFontSize, weight: .bold).italic()
            } else if t.isBold {
                return .system(size: screenFontSize, weight: .bold)
            } else if t.isItalic {
                return .system(size: screenFontSize, weight: .regular).italic()
            } else {
                return .system(size: screenFontSize, weight: .regular)
            }
        }
        
        // 逐行渲染，支持换行
        let lines = t.text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let yOffset = CGFloat(index) * screenFontSize * 1.2
            let resolved = context.resolve(
                Text(line)
                    .font(font)
                    .foregroundColor(t.color.color)
            )
            context.draw(resolved, at: CGPoint(x: screenRect.minX, y: baselineY + yOffset), anchor: .leading)
        }
    }
    
    private func drawLine(_ l: LineShape, context: GraphicsContext) {
        var path = Path()
        path.move(to: CGPoint(
            x: l.startPoint.x * zoom + offset.width,
            y: l.startPoint.y * zoom + offset.height
        ))
        path.addLine(to: CGPoint(
            x: l.endPoint.x * zoom + offset.width,
            y: l.endPoint.y * zoom + offset.height
        ))
        context.stroke(
            path,
            with: .color(l.color.color),
            style: StrokeStyle(lineWidth: max(0.5, l.strokeWidth * zoom), lineCap: .round)
        )
    }
    
    private func drawArrow(_ a: ArrowShape, context: GraphicsContext) {
        var body = Path()
        body.move(to: CGPoint(
            x: a.startPoint.x * zoom + offset.width,
            y: a.startPoint.y * zoom + offset.height
        ))
        body.addLine(to: CGPoint(
            x: a.endPoint.x * zoom + offset.width,
            y: a.endPoint.y * zoom + offset.height
        ))
        context.stroke(body, with: .color(a.color.color), style: StrokeStyle(lineWidth: max(0.5, a.strokeWidth * zoom), lineCap: .round))

        let head = a.headPoints
        var headPath = Path()
        headPath.move(to: CGPoint(x: head.left.x * zoom + offset.width, y: head.left.y * zoom + offset.height))
        headPath.addLine(to: CGPoint(x: a.endPoint.x * zoom + offset.width, y: a.endPoint.y * zoom + offset.height))
        headPath.addLine(to: CGPoint(x: head.right.x * zoom + offset.width, y: head.right.y * zoom + offset.height))
        context.stroke(headPath, with: .color(a.color.color), style: StrokeStyle(lineWidth: max(0.5, a.strokeWidth * zoom), lineCap: .round, lineJoin: .round))
    }

    // MARK: - 几何画板渲染

    private func drawPoint(_ p: PointShape, context: GraphicsContext) {
        let center = CGPoint(x: p.position.x * zoom + offset.width, y: p.position.y * zoom + offset.height)
        let r = max(2, p.strokeWidth * zoom / 2)
        let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        context.fill(Path(ellipseIn: rect), with: .color(p.color.color))
        if let label = p.label, !label.isEmpty {
            context.draw(
                Text(label).font(.system(size: max(10, 14 * zoom)).bold()),
                at: CGPoint(x: center.x + r + 4, y: center.y),
                anchor: .leading
            )
        }
    }

    private func drawCircle(_ c: CircleShape, context: GraphicsContext) {
        let center = CGPoint(x: c.center.x * zoom + offset.width, y: c.center.y * zoom + offset.height)
        let r = max(1, c.radius * zoom)
        let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        let path = Path(ellipseIn: rect)
        // 先填充再描边，避免半透明填充盖住边框
        if c.fillStyle.isVisible {
            let fc = c.fillColor ?? c.color
            context.fill(path, with: .color(fc.color.opacity(c.fillStyle == .semiTransparent ? 0.4 : 0.8)))
        }
        context.stroke(path, with: .color(c.color.color), style: StrokeStyle(lineWidth: max(0.5, c.strokeWidth * zoom)))
        // 圆心十字
        let mark = max(3, c.strokeWidth * zoom)
        var cross = Path()
        cross.move(to: CGPoint(x: center.x - mark, y: center.y))
        cross.addLine(to: CGPoint(x: center.x + mark, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: center.y - mark))
        cross.addLine(to: CGPoint(x: center.x, y: center.y + mark))
        context.stroke(cross, with: .color(c.color.color), style: StrokeStyle(lineWidth: max(0.5, c.strokeWidth * zoom)))
    }

    private func drawArc(_ a: ArcShape, context: GraphicsContext) {
        let center = CGPoint(x: a.center.x * zoom + offset.width, y: a.center.y * zoom + offset.height)
        let r = max(1, a.radius * zoom)
        // 用采样折线绘制：角度定义（世界坐标 atan2）与渲染完全一致，
        // 不依赖 Path.addArc 的 clockwise 语义（y 轴向下时容易画反）。
        let (s, e) = a.normalizedAngles
        let steps = max(8, Int(ceil((e - s) / (2 * .pi) * 128)))
        var path = Path()
        for i in 0...steps {
            let t = s + (e - s) * Double(i) / Double(steps)
            let pt = CGPoint(x: center.x + r * cos(t), y: center.y + r * sin(t))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        context.stroke(path, with: .color(a.color.color), style: StrokeStyle(lineWidth: max(0.5, a.strokeWidth * zoom), lineCap: .round))
    }

    private func drawPolygon(_ p: PolygonShape, context: GraphicsContext) {
        guard !p.vertices.isEmpty else { return }
        var path = Path()
        let first = p.vertices[0]
        path.move(to: CGPoint(x: first.x * zoom + offset.width, y: first.y * zoom + offset.height))
        for i in 1..<p.vertices.count {
            let v = p.vertices[i]
            path.addLine(to: CGPoint(x: v.x * zoom + offset.width, y: v.y * zoom + offset.height))
        }
        path.closeSubpath()
        // 先填充再描边，避免半透明填充盖住边框
        if p.fillStyle.isVisible {
            let fc = p.fillColor ?? p.color
            context.fill(path, with: .color(fc.color.opacity(p.fillStyle == .semiTransparent ? 0.4 : 0.8)))
        }
        context.stroke(path, with: .color(p.color.color), style: StrokeStyle(lineWidth: max(0.5, p.strokeWidth * zoom)))
        // 顶点画小点
        for v in p.vertices {
            let pt = CGPoint(x: v.x * zoom + offset.width, y: v.y * zoom + offset.height)
            let rr: CGFloat = max(2, p.strokeWidth * zoom)
            let rect = CGRect(x: pt.x - rr, y: pt.y - rr, width: rr * 2, height: rr * 2)
            context.fill(Path(ellipseIn: rect), with: .color(p.color.color))
        }
    }

    /// 将分段的曲线画成互不相连的 Path 子路径。
    /// 单点段不画点/线，保证退化函数（全 NaN 或只有一个有效采样点）不产生伪图形。
    @discardableResult
    private func drawPlotSegments(
        _ segments: [[WhiteboardPoint]],
        color: WhiteboardColor,
        strokeWidth: Double,
        context: GraphicsContext
    ) -> Bool {
        var path = Path()
        var hasDrawableSegment = false
        for segment in segments where segment.count >= 2 {
            hasDrawableSegment = true
            let first = segment[0]
            path.move(to: CGPoint(
                x: first.x * zoom + offset.width,
                y: first.y * zoom + offset.height
            ))
            for point in segment.dropFirst() {
                path.addLine(to: CGPoint(
                    x: point.x * zoom + offset.width,
                    y: point.y * zoom + offset.height
                ))
            }
        }
        guard hasDrawableSegment else { return false }
        context.stroke(
            path,
            with: .color(color.color),
            style: StrokeStyle(lineWidth: max(0.5, strokeWidth * zoom), lineCap: .round)
        )
        return true
    }

    private func drawFunctionPlot(_ f: FunctionPlotShape, context: GraphicsContext) {
        // 直接调用 model 的分段采样（结果已映射到白板世界坐标）。
        // 每段单独 move/addLine，渐近线两侧不会互相连线。
        let drew = drawPlotSegments(
            f.sampleSegments(),
            color: f.color,
            strokeWidth: f.strokeWidth,
            context: context
        )
        guard !drew else { return }
        // 全 NaN 或只有一个有效点时不画线，仅保留公式提示。
        context.draw(
            Text("y = \(f.formula)").font(.system(size: 11)).foregroundColor(.secondary),
            at: CGPoint(x: (f.xMin + f.xMax) / 2 * zoom + offset.width,
                        y: (f.yMin + f.yMax) / 2 * zoom + offset.height),
            anchor: .center
        )
    }

    private func drawParametricPlot(_ p: ParametricPlotShape, context: GraphicsContext) {
        let drew = drawPlotSegments(
            p.sampleSegments(),
            color: p.color,
            strokeWidth: p.strokeWidth,
            context: context
        )
        guard !drew else { return }
        context.draw(
            Text("x=\(p.fxFormula)\ny=\(p.fyFormula)").font(.system(size: 10)).foregroundColor(.secondary),
            at: .zero,
            anchor: .topLeading
        )
    }

    private func drawPolarPlot(_ pl: PolarPlotShape, context: GraphicsContext) {
        _ = drawPlotSegments(
            pl.sampleSegments(),
            color: pl.color,
            strokeWidth: pl.strokeWidth,
            context: context
        )
    }

    /// 测量所需的目标数量：长度 2、角度 3（顶点在中间）、面积 1
    private func requiredTargetCount(_ kind: MeasurementKind) -> Int {
        switch kind {
        case .length: return 2
        case .angle: return 3
        case .area: return 1
        }
    }

    private func drawMeasurement(_ m: MeasurementMarkerShape, context: GraphicsContext) {
        // 按 targetIDs 的顺序解析目标（角度测量顶点在中间，顺序不能乱）
        let objects = service.currentDocument?.objects ?? []
        let ordered = m.targetIDs.compactMap { id in objects.first(where: { $0.id == id }) }

        let labelText: String
        if ordered.count < requiredTargetCount(m.kind) {
            labelText = "目标对象已被删除"
        } else {
            switch m.kind {
            case .length:
                let a = ordered[0].boundingRect.center
                let b = ordered[1].boundingRect.center
                labelText = String(format: "长度 %.1f", hypot(b.x - a.x, b.y - a.y))
            case .angle:
                let p1 = ordered[0].boundingRect.center
                let v = ordered[1].boundingRect.center
                let p2 = ordered[2].boundingRect.center
                labelText = String(format: "角度 %.1f°", WhiteboardCanvasView.angleDegrees(p1: p1, vertex: v, p2: p2))
            case .area:
                labelText = String(format: "面积 %.1f", WhiteboardCanvasView.measurementArea(of: ordered[0]))
            }
        }

        let pos = CGPoint(x: m.position.x * zoom + offset.width, y: m.position.y * zoom + offset.height)

        // 引导线：标签 -> 第一个目标
        if let first = ordered.first {
            let c = first.boundingRect.center
            let target = CGPoint(x: c.x * zoom + offset.width, y: c.y * zoom + offset.height)
            var lead = Path()
            lead.move(to: pos)
            lead.addLine(to: target)
            context.stroke(lead, with: .color(m.color.color),
                           style: StrokeStyle(lineWidth: max(0.5, m.strokeWidth * zoom), dash: [3, 3]))
        }

        // 标签（带浅色底，保证压在图形上仍可读）
        let fontSize = max(10, 12 * zoom)
        let resolved = context.resolve(
            Text(labelText)
                .font(.system(size: fontSize))
                .foregroundColor(m.color.color)
        )
        let measured = (labelText as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)])
        let bg = CGRect(x: pos.x - measured.width / 2 - 4,
                        y: pos.y - measured.height / 2 - 2,
                        width: measured.width + 8,
                        height: measured.height + 4)
        context.fill(Path(roundedRect: bg, cornerRadius: 4), with: .color(.white.opacity(0.85)))
        context.draw(resolved, at: pos, anchor: .center)
    }

    /// 夹角（顶点在中），返回角度制
    private static func angleDegrees(p1: WhiteboardPoint, vertex: WhiteboardPoint, p2: WhiteboardPoint) -> Double {
        let v1x = p1.x - vertex.x, v1y = p1.y - vertex.y
        let v2x = p2.x - vertex.x, v2y = p2.y - vertex.y
        let n1 = hypot(v1x, v1y), n2 = hypot(v2x, v2y)
        guard n1 > 1e-9, n2 > 1e-9 else { return 0 }
        let cosA = max(-1, min(1, (v1x * v2x + v1y * v2y) / (n1 * n2)))
        return acos(cosA) * 180 / .pi
    }

    /// 闭合图形面积：多边形（鞋带公式）/ 圆 / 矩形 / 三角形 / 椭圆按各自公式，其余取包围盒
    private static func measurementArea(of object: WhiteboardObject) -> Double {
        switch object {
        case .polygon(let p):
            guard p.vertices.count >= 3 else { return 0 }
            var sum: Double = 0
            for i in 0..<p.vertices.count {
                let a = p.vertices[i]
                let b = p.vertices[(i + 1) % p.vertices.count]
                sum += a.x * b.y - b.x * a.y
            }
            return abs(sum) / 2
        case .circle(let c):
            return .pi * c.radius * c.radius
        case .rectangle(let r):
            return abs(r.rect.width * r.rect.height)
        case .triangle(let t):
            return abs(t.rect.width * t.rect.height) / 2
        case .ellipse(let e):
            return .pi * abs(e.rect.width * e.rect.height) / 4
        default:
            let r = object.boundingRect
            return abs(r.width * r.height)
        }
    }
    
    private func drawBounds(for ids: Set<UUID>, context: GraphicsContext) {
        guard let doc = service.currentDocument else { return }
        let selected = doc.objects.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return }
        
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        for obj in selected {
            let r = obj.boundingRect
            minX = Swift.min(minX, r.x)
            minY = Swift.min(minY, r.y)
            maxX = Swift.max(maxX, r.x + r.width)
            maxY = Swift.max(maxY, r.y + r.height)
        }
        
        let padding = 8.0
        let bounds = CGRect(
            x: (minX - padding) * zoom + offset.width,
            y: (minY - padding) * zoom + offset.height,
            width: (maxX - minX + padding * 2) * zoom,
            height: (maxY - minY + padding * 2) * zoom
        )
        
        let path = Path(roundedRect: bounds, cornerRadius: 2)
        context.stroke(
            path,
            with: .color(.accentColor),
            style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
        )
    }
    
    // MARK: - 坐标转换
    
    private func screenToWorld(_ point: CGPoint) -> WhiteboardPoint {
        let worldX = (point.x - offset.width) / zoom
        let worldY = (point.y - offset.height) / zoom
        return WhiteboardPoint(x: worldX, y: worldY)
    }
    
    // MARK: - 交互处理
    
    private func handleDragChanged(value: DragGesture.Value) {
        let worldPoint = screenToWorld(value.location)
        let startWorld = screenToWorld(value.startLocation)
        
        // 显著移动检测
        let dx = value.location.x - value.startLocation.x
        let dy = value.location.y - value.startLocation.y
        if sqrt(dx * dx + dy * dy) > 3 {
            hasMovedSignificantly = true
        }
        
        let effectiveTool = isOptionKeyPressed ? .select : tool
        
        switch effectiveTool {
        case .pen:
            handlePenDrawing(worldPoint: worldPoint, pressure: 1.0)
        case .eraser:
            handleErase(worldPoint: worldPoint, radius: strokeWidth)
        case .line, .arrow:
            handleLineDrawing(worldPoint: worldPoint, start: startWorld)
        case .rectangle:
            handleRectDrawing(worldPoint: worldPoint, start: startWorld, isEllipse: false)
        case .ellipse:
            handleRectDrawing(worldPoint: worldPoint, start: startWorld, isEllipse: true)
        case .triangle:
            handleTriangleDrawing(worldPoint: worldPoint, start: startWorld)
        case .text:
            // 文字工具：拖拽时不做任何事，由 onEnded 触发输入面板
            break
        case .point:
            // 点：onEnded 一次性落点
            break
        case .circle:
            handleCircleDrawing(worldPoint: worldPoint, start: startWorld)
        case .arc:
            handleArcDrawing(worldPoint: worldPoint, start: startWorld)
        case .polygon:
            handlePolygonDrawing(worldPoint: worldPoint, start: startWorld)
        case .functionPlot, .parametricPlot, .polarPlot:
            // 曲线由输入面板定义，拖拽不动；onEnded 弹出对应面板
            break
        case .measure:
            // 测量：点选目标，无需拖拽
            break
        case .select:
            // 如果尚未开始拖拽，决定是移动已选对象还是开始框选
            guard let doc = service.currentDocument else { return }

            if dragStartPoint == nil && marqueeStart == nil {
                // 判断起点是否命中某个对象（以视觉上最上层对象为准）
                if let hit = doc.objects.reversed().first(where: { $0.contains(startWorld) }) {
                    // 命中对象：如果该对象已经被选中，则开始移动；否则选择它并开始移动
                    if !selectedIDs.contains(hit.id) {
                        if isOptionKeyPressed {
                            // Option 键：切换选择
                            if selectedIDs.contains(hit.id) { selectedIDs.remove(hit.id) } else { selectedIDs.insert(hit.id) }
                        } else {
                            selectedIDs = [hit.id]
                        }
                    }
                    dragStartPoint = startWorld
                    dragOriginalObjects = doc.objects.filter { selectedIDs.contains($0.id) }
                    hasRecordedUndoForDrag = false
                } else {
                    // 未命中对象：开始框选
                    marqueeStart = startWorld
                    marqueeRect = WhiteboardRect(min: startWorld, max: startWorld)
                    // 清空临时选择（用户按住 Option 可累加）
                    if !isOptionKeyPressed {
                        selectedIDs.removeAll()
                    }
                }
            } else if let start = marqueeStart {
                // 更新框选矩形
                marqueeRect = WhiteboardRect(min: start, max: worldPoint)
                // 实时更新选择（与 Option 键配合）
                if let r = marqueeRect {
                    var hits: Set<UUID> = isOptionKeyPressed ? selectedIDs : []
                    for obj in doc.objects {
                        let br = obj.boundingRect
                        // 判断边界相交
                        if !(br.x > r.x + r.width || br.x + br.width < r.x || br.y > r.y + r.height || br.y + br.height < r.y) {
                            hits.insert(obj.id)
                        }
                    }
                    selectedIDs = hits
                }
            } else if let _ = dragStartPoint {
                // 计算偏移并在第一次移动时记录撤销状态
                let dx = worldPoint.x - startWorld.x
                let dy = worldPoint.y - startWorld.y
                let offset2 = WhiteboardPoint(x: dx, y: dy)
                if !hasRecordedUndoForDrag {
                    service.moveObjects(dragOriginalObjects, by: offset2, recordUndo: true)
                    hasRecordedUndoForDrag = true
                } else {
                    service.moveObjects(dragOriginalObjects, by: offset2, recordUndo: false)
                }
            }
        }
    }
    
    private func handleDragEnded(value: DragGesture.Value) {
        let effectiveTool = isOptionKeyPressed ? .select : tool

        switch effectiveTool {
        case .pen:
            if let stroke = currentStroke, stroke.points.count > 1 {
                service.addObject(.stroke(stroke))
            }
            currentStroke = nil
        case .line, .arrow, .rectangle, .ellipse, .triangle:
            if let drawing = drawingObject {
                service.addObject(drawing)
            }
            drawingObject = nil
        case .text:
            // 仅在单击（无明显拖动）时弹出输入面板
            if !hasMovedSignificantly {
                let worldPoint = screenToWorld(value.location)
                presentTextInput(at: worldPoint)
            }
        case .eraser:
            break
        case .select:
            // 结束移动或框选
            // 已在首次移动时记录撤销，结束时仅清理状态
            hasRecordedUndoForDrag = false
            // 框选结束：marqueeRect -> 选择集
            if let m = marqueeRect {
                if let doc = service.currentDocument {
                    var hits: Set<UUID> = isOptionKeyPressed ? selectedIDs : []
                    for obj in doc.objects {
                        let br = obj.boundingRect
                        if !(br.x > m.x + m.width || br.x + br.width < m.x || br.y > m.y + m.height || br.y + br.height < m.y) {
                            hits.insert(obj.id)
                        }
                    }
                    selectedIDs = hits
                }
            }

            dragStartPoint = nil
            dragOriginalObjects = []
            marqueeStart = nil
            marqueeRect = nil
        case .point:
            let p = screenToWorld(value.location)
            service.addObject(.point(PointShape(position: p, color: currentColor, strokeWidth: max(3, strokeWidth))))
        case .circle:
            // 拖拽出的圆；未明显拖动视为单击，落一个默认半径 60 的圆
            if hasMovedSignificantly, let drawing = drawingObject, case .circle(let c) = drawing, c.radius >= 2 {
                service.addObject(drawing)
            } else {
                let p = screenToWorld(value.location)
                service.addObject(.circle(CircleShape(center: p, radius: 60, color: currentColor, strokeWidth: strokeWidth, fillStyle: fillStyle, fillColor: fillStyle.isVisible ? fillColor : nil)))
            }
            drawingObject = nil
        case .arc:
            // 拖拽出的弧（A -> B 的半圆）；单击则落一个默认半圆
            if hasMovedSignificantly, let drawing = drawingObject, case .arc(let a) = drawing, a.radius >= 2 {
                service.addObject(drawing)
            } else {
                let p = screenToWorld(value.location)
                service.addObject(.arc(ArcShape(center: p, radius: 40, startAngle: .pi, endAngle: 2 * .pi, color: currentColor, strokeWidth: strokeWidth)))
            }
            drawingObject = nil
        case .polygon:
            // 拖拽出的正六边形；单击则落一个默认半径 50 的六边形
            if hasMovedSignificantly, let drawing = drawingObject {
                service.addObject(drawing)
            } else {
                let p = screenToWorld(value.location)
                service.addObject(.polygon(PolygonShape(vertices: Self.regularPolygonVertices(center: p, radius: 50), color: currentColor, strokeWidth: strokeWidth, fillStyle: fillStyle, fillColor: fillStyle.isVisible ? fillColor : nil)))
            }
            drawingObject = nil
        case .functionPlot:
            showFunctionSheet = true
        case .parametricPlot:
            showParametricSheet = true
        case .polarPlot:
            showPolarSheet = true
        case .measure:
            // 点击对象加入 / 移出测量目标
            if !hasMovedSignificantly, let doc = service.currentDocument {
                let p = screenToWorld(value.location)
                if let hit = doc.objects.reversed().first(where: { $0.contains(p) }) {
                    if let idx = measureTargets.firstIndex(of: hit.id) {
                        measureTargets.remove(at: idx)
                    } else {
                        measureTargets.append(hit.id)
                    }
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.hasMovedSignificantly = false
        }
    }

    // MARK: - 绘制框选矩形
    private func drawMarquee(rect: WhiteboardRect, context: GraphicsContext) {
        let screenRect = CGRect(
            x: rect.x * zoom + offset.width,
            y: rect.y * zoom + offset.height,
            width: rect.width * zoom,
            height: rect.height * zoom
        )
        let path = Path(roundedRect: screenRect, cornerRadius: 2)
        context.fill(path, with: .color(Color.accentColor.opacity(0.08)))
        context.stroke(path, with: .color(Color.accentColor), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
    }
    
    // MARK: - 绘画
    
    private func handlePenDrawing(worldPoint: WhiteboardPoint, pressure: Double) {
        if currentStroke == nil {
            currentStroke = StrokeShape(
                points: [worldPoint],
                color: currentColor,
                strokeWidth: strokeWidth
            )
        } else {
            currentStroke?.points.append(worldPoint)
        }
    }
    
    // MARK: - 范围擦除（基于线段与橡皮圆相交裁剪）
    
    private func handleErase(worldPoint: WhiteboardPoint, radius: Double) {
        guard let doc = service.currentDocument else { return }
        let worldRadius = radius / zoom
        // 让橡皮的有效宽度至少覆盖笔划本身的粗细 + 一点缓冲
        let effectiveRadius = max(worldRadius, 4.0)
        
        var toRemoveIds: Set<UUID> = []
        var strokeReplacements: [(id: UUID, newStrokes: [StrokeShape])] = []
        
        for obj in doc.objects {
            switch obj {
            case .stroke(let s):
                let newStrokes = eraseStroke(s, at: worldPoint, radius: effectiveRadius)
                if newStrokes.isEmpty {
                    toRemoveIds.insert(s.id)
                } else if newStrokes.count == 1 && newStrokes[0].points.count == s.points.count {
                    // 笔划未变，跳过
                    continue
                } else {
                    strokeReplacements.append((s.id, newStrokes))
                }
            case .rectangle, .ellipse, .triangle, .line, .arrow, .text,
             .point, .circle, .arc, .polygon,
             .functionPlot, .parametricPlot, .polarPlot, .measurement:
                if obj.contains(worldPoint) {
                    toRemoveIds.insert(obj.id)
                }
            }
        }
        
        if !toRemoveIds.isEmpty || !strokeReplacements.isEmpty {
            service.eraseAndReplace(
                removeIds: toRemoveIds,
                strokeReplacements: strokeReplacements
            )
        }
    }
    
    /// 用线段与橡皮圆相交的方式擦除笔划。
    /// 返回擦除后剩余的笔划列表（空 = 全部擦除，1 = 替换，2+ = 拆分）
    private func eraseStroke(_ stroke: StrokeShape, at eraserPoint: WhiteboardPoint, radius: Double) -> [StrokeShape] {
        let points = stroke.points
        guard !points.isEmpty else { return [] }
        let radiusSq = radius * radius
        
        func isInside(_ p: WhiteboardPoint) -> Bool {
            let dx = p.x - eraserPoint.x
            let dy = p.y - eraserPoint.y
            return dx * dx + dy * dy <= radiusSq
        }
        
        /// 求线段 (p1, p2) 与橡皮圆的交点（t ∈ [0, 1]）
        func lineCircleIntersections(p1: WhiteboardPoint, p2: WhiteboardPoint) -> [WhiteboardPoint] {
            let dx = p2.x - p1.x
            let dy = p2.y - p1.y
            let a = dx * dx + dy * dy
            if a < 1e-9 { return [] } // 退化为点
            let fx = p1.x - eraserPoint.x
            let fy = p1.y - eraserPoint.y
            let b = 2 * (fx * dx + fy * dy)
            let c = fx * fx + fy * fy - radiusSq
            
            let discriminant = b * b - 4 * a * c
            if discriminant < 0 { return [] }
            
            var result: [WhiteboardPoint] = []
            if discriminant < 1e-9 {
                // 相切：忽略
                return []
            }
            let sqrtD = sqrt(discriminant)
            let t1 = (-b - sqrtD) / (2 * a)
            let t2 = (-b + sqrtD) / (2 * a)
            if t1 >= 0 && t1 <= 1 {
                result.append(WhiteboardPoint(x: p1.x + t1 * dx, y: p1.y + t1 * dy))
            }
            if t2 >= 0 && t2 <= 1 {
                result.append(WhiteboardPoint(x: p1.x + t2 * dx, y: p1.y + t2 * dy))
            }
            return result
        }
        
        // 单点笔划
        if points.count == 1 {
            return isInside(points[0]) ? [] : [stroke]
        }
        
        var segments: [[WhiteboardPoint]] = []
        var current: [WhiteboardPoint] = []
        
        // 处理第一个点
        if !isInside(points[0]) {
            current.append(points[0])
        }
        
        for i in 0..<(points.count - 1) {
            let p1 = points[i]
            let p2 = points[i + 1]
            let p1In = isInside(p1)
            let p2In = isInside(p2)
            
            if !p1In && !p2In {
                // 两端都在外：检查线段是否穿过橡皮
                let xs = lineCircleIntersections(p1: p1, p2: p2)
                if xs.count == 2 {
                    // 线段穿过橡皮 - 在两个交点处拆分
                    current.append(xs[0])
                    segments.append(current)
                    current = [xs[1], p2]
                } else {
                    // 不穿过，直接添加 p2
                    current.append(p2)
                }
            } else if !p1In && p2In {
                // 进入橡皮
                let xs = lineCircleIntersections(p1: p1, p2: p2)
                if let entry = xs.first {
                    current.append(entry)
                }
                if !current.isEmpty {
                    segments.append(current)
                    current = []
                }
            } else if p1In && !p2In {
                // 离开橡皮
                let xs = lineCircleIntersections(p1: p1, p2: p2)
                if let exit = xs.last {
                    current = [exit, p2]
                } else {
                    current = [p2]
                }
            }
            // p1In && p2In: 两端都在橡皮内，跳过
        }
        
        if !current.isEmpty {
            segments.append(current)
        }
        
        // 避免产生只有 1 个点或 0 个点的笔划
        let validSegments = segments.filter { $0.count >= 2 }
        
        return validSegments.map { seg -> StrokeShape in
            var s = stroke
            s.points = seg
            s.id = UUID() // 分配新 ID 以避免冲突
            return s
        }
    }
    
    private func handleLineDrawing(worldPoint: WhiteboardPoint, start: WhiteboardPoint) {
        if drawingObject == nil {
            if tool == .line {
                drawingObject = .line(LineShape(start: start, end: worldPoint, color: currentColor, strokeWidth: strokeWidth))
            } else {
                drawingObject = .arrow(ArrowShape(start: start, end: worldPoint, color: currentColor, strokeWidth: strokeWidth))
            }
        } else {
            switch drawingObject {
            case .line(var l):
                l.endPoint = worldPoint
                drawingObject = .line(l)
            case .arrow(var a):
                a.endPoint = worldPoint
                drawingObject = .arrow(a)
            default:
                break
            }
        }
    }
    
    private func handleRectDrawing(worldPoint: WhiteboardPoint, start: WhiteboardPoint, isEllipse: Bool) {
        let rect = WhiteboardRect(min: start, max: worldPoint)
        if drawingObject == nil {
            if isEllipse {
                drawingObject = .ellipse(EllipseShape(rect: rect, color: currentColor, strokeWidth: strokeWidth, fillStyle: fillStyle, fillColor: fillStyle.isVisible ? fillColor : nil))
            } else {
                drawingObject = .rectangle(RectangleShape(rect: rect, color: currentColor, strokeWidth: strokeWidth, fillStyle: fillStyle, fillColor: fillStyle.isVisible ? fillColor : nil))
            }
        } else {
            switch drawingObject {
            case .rectangle(var r):
                r.rect = rect
                drawingObject = .rectangle(r)
            case .ellipse(var e):
                e.rect = rect
                drawingObject = .ellipse(e)
            default:
                break
            }
        }
    }
    
    private func handleTriangleDrawing(worldPoint: WhiteboardPoint, start: WhiteboardPoint) {
        let rect = WhiteboardRect(min: start, max: worldPoint)
        if drawingObject == nil {
            drawingObject = .triangle(TriangleShape(rect: rect, color: currentColor, strokeWidth: strokeWidth, fillStyle: fillStyle, fillColor: fillStyle.isVisible ? fillColor : nil))
        } else {
            switch drawingObject {
            case .triangle(var t):
                t.rect = rect
                drawingObject = .triangle(t)
            default:
                break
            }
        }
    }

    // MARK: - 几何图形拖拽绘制

    /// 圆：按下 = 圆心，拖动距离 = 半径
    private func handleCircleDrawing(worldPoint: WhiteboardPoint, start: WhiteboardPoint) {
        let radius = max(1, hypot(worldPoint.x - start.x, worldPoint.y - start.y))
        drawingObject = .circle(CircleShape(center: start, radius: radius,
                                            color: currentColor, strokeWidth: strokeWidth,
                                            fillStyle: fillStyle, fillColor: fillStyle.isVisible ? fillColor : nil))
    }

    /// 弧：按下 = 起点 A，拖到 = 终点 B，生成以 AB 为直径的半圆（拖拽方向决定弧在哪一侧）
    private func handleArcDrawing(worldPoint: WhiteboardPoint, start: WhiteboardPoint) {
        let mid = WhiteboardPoint(x: (start.x + worldPoint.x) / 2, y: (start.y + worldPoint.y) / 2)
        let radius = max(1, hypot(worldPoint.x - start.x, worldPoint.y - start.y) / 2)
        let startAngle = atan2(start.y - mid.y, start.x - mid.x)
        drawingObject = .arc(ArcShape(center: mid, radius: radius,
                                      startAngle: startAngle, endAngle: startAngle + .pi,
                                      color: currentColor, strokeWidth: strokeWidth))
    }

    /// 多边形：拖拽框内切正六边形
    private func handlePolygonDrawing(worldPoint: WhiteboardPoint, start: WhiteboardPoint) {
        let rect = WhiteboardRect(min: start, max: worldPoint)
        let radius = max(1, Swift.min(rect.width, rect.height) / 2)
        drawingObject = .polygon(PolygonShape(vertices: WhiteboardCanvasView.regularPolygonVertices(center: rect.center, radius: radius),
                                              color: currentColor, strokeWidth: strokeWidth,
                                              fillStyle: fillStyle, fillColor: fillStyle.isVisible ? fillColor : nil))
    }

    /// 正 n 边形顶点（默认六边形，与工具图标一致）
    private static func regularPolygonVertices(center: WhiteboardPoint, radius: Double, sides: Int = 6) -> [WhiteboardPoint] {
        (0..<sides).map { i in
            let t = -Double.pi / 2 + Double(i) * 2 * Double.pi / Double(sides)
            return WhiteboardPoint(x: center.x + radius * cos(t), y: center.y + radius * sin(t))
        }
    }
    
    private func handleSelectDrag(worldPoint: WhiteboardPoint, start: WhiteboardPoint) {
        if !selectedIDs.isEmpty && dragStartPoint == nil {
            dragStartPoint = start
            dragOriginalObjects = service.currentDocument?.objects.filter { selectedIDs.contains($0.id) } ?? []
        }
        
        guard let _ = dragStartPoint, !dragOriginalObjects.isEmpty else { return }
        
        let dx = worldPoint.x - start.x
        let dy = worldPoint.y - start.y
        let offset2 = WhiteboardPoint(x: dx, y: dy)
        
        service.moveObjects(dragOriginalObjects, by: offset2, recordUndo: false)
    }
}

// MARK: - 网格背景

struct GridBackground: View {
    let zoom: Double
    let offset: CGSize
    
    var body: some View {
        Canvas { context, size in
            let gridSize: Double = 50
            let scaledGrid = gridSize * zoom
            
            let offsetX = offset.width.truncatingRemainder(dividingBy: scaledGrid)
            let offsetY = offset.height.truncatingRemainder(dividingBy: scaledGrid)
            
            var x: Double = offsetX
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(Color(white: 0.92)), lineWidth: 0.5)
                x += scaledGrid
            }
            
            var y: Double = offsetY
            while y < size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(Color(white: 0.92)), lineWidth: 0.5)
                y += scaledGrid
            }
            
            var centerX = Path()
            centerX.move(to: CGPoint(x: size.width / 2, y: 0))
            centerX.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            context.stroke(centerX, with: .color(Color(white: 0.85)), lineWidth: 0.5)
            
            var centerY = Path()
            centerY.move(to: CGPoint(x: 0, y: size.height / 2))
            centerY.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(centerY, with: .color(Color(white: 0.85)), lineWidth: 0.5)
        }
    }
}

// MARK: - 画布事件监听（鼠标滚轮 / 触控板手势）

/// 监听鼠标滚轮（鼠标 / 触控板两指滑动）与触控板捏合（magnify）事件。
/// 通过闭包回调把事件转换为画布的缩放/平移量。
struct CanvasEventMonitor: NSViewRepresentable {
    /// 事件回调：deltaX, deltaY, isZoom（true=缩放，false=平移）, isMagnify（true=捏合事件，false=滚轮事件）
    let onEvent: (CGFloat, CGFloat, Bool, Bool) -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = EventMonitorNSView()
        view.onEvent = onEvent
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? EventMonitorNSView)?.onEvent = onEvent
    }
}

final class EventMonitorNSView: NSView {
    var onEvent: ((CGFloat, CGFloat, Bool, Bool) -> Void)?
    private var monitors: [Any] = []
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }
    
    private func startMonitoring() {
        stopMonitoring()
        
        // 鼠标滚轮 / 触控板两指滑动
        let scrollClosure: (NSEvent) -> NSEvent? = { [weak self] event in
            guard let self = self, let onEvent = self.onEvent else { return event }
            // 只有当事件的目标窗口是当前窗口时才处理
            if event.window == self.window {
                if event.modifierFlags.contains(.command) {
                    // Cmd + 滚轮 = 缩放
                    onEvent(0, event.scrollingDeltaY, true, false)
                } else {
                    // 普通滚轮 = 平移
                    onEvent(event.scrollingDeltaX, event.scrollingDeltaY, false, false)
                }
            }
            return event
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel], handler: scrollClosure) {
            monitors.append(m)
        }
        
        // 触控板捏合
        let magnifyClosure: (NSEvent) -> NSEvent? = { [weak self] event in
            guard let self = self, let onEvent = self.onEvent else { return event }
            if event.window == self.window {
                onEvent(0, event.magnification, true, true)
            }
            return event
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .magnify, handler: magnifyClosure) {
            monitors.append(m)
        }
    }
    
    private func stopMonitoring() {
        for m in monitors {
            NSEvent.removeMonitor(m)
        }
        monitors.removeAll()
    }
    
    deinit {
        stopMonitoring()
    }
}
