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
    
    // 用于驱动 TimelineView 重绘
    @State private var renderTick: Int = 0
    
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
        }
        .background(Color(white: 1.0))
        .clipped()
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
            let fillColor: Color
            switch r.fillStyle {
            case .none: fillColor = .clear
            case .solid: fillColor = r.color.color
            case .semiTransparent: fillColor = r.color.color.opacity(0.4)
            }
            context.fill(Path(rect), with: .color(fillColor))
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
            let fillColor: Color
            switch e.fillStyle {
            case .none: fillColor = .clear
            case .solid: fillColor = e.color.color
            case .semiTransparent: fillColor = e.color.color.opacity(0.4)
            }
            context.fill(path, with: .color(fillColor))
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
            let fillColor: Color
            switch t.fillStyle {
            case .none: fillColor = .clear
            case .solid: fillColor = t.color.color
            case .semiTransparent: fillColor = t.color.color.opacity(0.4)
            }
            context.fill(path, with: .color(fillColor))
        }
        
        context.stroke(
            path,
            with: .color(t.color.color),
            lineWidth: max(0.5, t.strokeWidth * zoom)
        )
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
    
    // MARK: - 范围擦除
    
    private func handleErase(worldPoint: WhiteboardPoint, radius: Double) {
        guard let doc = service.currentDocument else { return }
        let worldRadius = radius / zoom
        let tolerance = worldRadius + 5
        
        var toRemoveIds: Set<UUID> = []
        var modifiedStrokes: [(id: UUID, stroke: StrokeShape)] = []
        
        for obj in doc.objects {
            switch obj {
            case .stroke(let s):
                if let modified = eraseStrokeRange(s, at: worldPoint, tolerance: tolerance) {
                    if modified.points.isEmpty {
                        toRemoveIds.insert(s.id)
                    } else {
                        modifiedStrokes.append((s.id, modified))
                    }
                }
            case .rectangle, .ellipse, .triangle, .line, .arrow:
                if obj.contains(worldPoint) {
                    toRemoveIds.insert(obj.id)
                }
            }
        }
        
        if !toRemoveIds.isEmpty || !modifiedStrokes.isEmpty {
            service.eraseAndReplace(
                removeIds: toRemoveIds,
                modifiedStrokes: modifiedStrokes
            )
        }
    }
    
    private func eraseStrokeRange(_ stroke: StrokeShape, at point: WhiteboardPoint, tolerance: Double) -> StrokeShape? {
        let points = stroke.points
        guard !points.isEmpty else { return nil }
        
        var erasedIndices = Set<Int>()
        for (i, p) in points.enumerated() {
            let dx = p.x - point.x
            let dy = p.y - point.y
            if dx * dx + dy * dy <= tolerance * tolerance {
                erasedIndices.insert(i)
            }
        }
        
        if erasedIndices.isEmpty { return nil }
        
        // 保留未擦除的点
        var keptPoints: [WhiteboardPoint] = []
        for (i, p) in points.enumerated() {
            if !erasedIndices.contains(i) {
                keptPoints.append(p)
            }
        }
        
        var newStroke = stroke
        newStroke.points = keptPoints
        return newStroke
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
                drawingObject = .ellipse(EllipseShape(rect: rect, color: currentColor, strokeWidth: strokeWidth, fillStyle: fillStyle))
            } else {
                drawingObject = .rectangle(RectangleShape(rect: rect, color: currentColor, strokeWidth: strokeWidth, fillStyle: fillStyle))
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
            drawingObject = .triangle(TriangleShape(rect: rect, color: currentColor, strokeWidth: strokeWidth, fillStyle: fillStyle))
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
