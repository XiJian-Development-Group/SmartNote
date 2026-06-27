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
    let canvasSize: CGSize
    
    // 当前正在绘制的对象
    @State private var drawingObject: WhiteboardObject?
    @State private var dragStartPoint: WhiteboardPoint?
    @State private var dragOriginalObjects: [WhiteboardObject] = []
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
                            drawSelectionBounds(context: context)
                        }
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
    
    private func drawSelectionBounds(context: GraphicsContext) {
        guard let doc = service.currentDocument else { return }
        let selected = doc.objects.filter { selectedIDs.contains($0.id) }
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
        case .select:
            handleSelectDrag(worldPoint: worldPoint, start: startWorld)
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
            dragStartPoint = nil
            dragOriginalObjects = []
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.hasMovedSignificantly = false
        }
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
            case .rectangle, .ellipse, .triangle, .line, .arrow, .text:
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
