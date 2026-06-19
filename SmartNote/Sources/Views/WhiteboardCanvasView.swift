import SwiftUI
import AppKit

/// 画板画布视图 - 负责绘制、交互、撤销等
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
    
    // 当前正在绘制的对象（绘画/拖动过程中的临时对象）
    @State private var drawingObject: WhiteboardObject?
    @State private var dragStartPoint: WhiteboardPoint?
    @State private var dragOriginalObjects: [WhiteboardObject] = []
    @State private var currentStroke: StrokeShape?
    @State private var dragStartScreen: CGPoint = .zero
    @State private var hasMovedSignificantly: Bool = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 背景网格
                GridBackground(zoom: zoom, offset: offset)
                
                // 已有对象
                ForEach(displayedObjects) { object in
                    ObjectShapeView(
                        object: object,
                        zoom: zoom,
                        canvasOffset: offset,
                        isSelected: selectedIDs.contains(object.id)
                    )
                }
                
                // 当前正在绘制的对象（实时显示）
                if let drawing = drawingObject {
                    ObjectShapeView(
                        object: drawing,
                        zoom: zoom,
                        canvasOffset: offset,
                        isSelected: false
                    )
                }
                
                // 当前笔划（实时显示）
                if let stroke = currentStroke, !stroke.points.isEmpty {
                    StrokeView(stroke: stroke, zoom: zoom, canvasOffset: offset)
                }
                
                // 选区边框
                if !selectedIDs.isEmpty && tool == .select {
                    SelectionBoundsView(objects: selectedObjects, zoom: zoom, canvasOffset: offset)
                }
            }
            .contentShape(Rectangle())
            // 使用高优先级手势，避免 onTapGesture 拦截
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        handleDragChanged(value: value)
                    }
                    .onEnded { value in
                        handleDragEnded(value: value)
                    }
            )
            // 用 .simultaneousGesture 让 onTap 和 DragGesture 可以同时工作
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
    
    // MARK: - 计算属性
    
    private var displayedObjects: [WhiteboardObject] {
        guard let doc = service.currentDocument else { return [] }
        return doc.objects.sorted { $0.zIndex < $1.zIndex }
    }
    
    private var selectedObjects: [WhiteboardObject] {
        guard let doc = service.currentDocument else { return [] }
        return doc.objects.filter { selectedIDs.contains($0.id) }
    }
    
    // MARK: - 坐标转换
    
    /// 将屏幕坐标转换为画布世界坐标
    private func screenToWorld(_ point: CGPoint) -> WhiteboardPoint {
        let worldX = (point.x - offset.width) / zoom
        let worldY = (point.y - offset.height) / zoom
        return WhiteboardPoint(x: worldX, y: worldY)
    }
    
    // MARK: - 交互处理
    
    private func handleDragChanged(value: DragGesture.Value) {
        // 不做帧率限制，确保实时性
        let worldPoint = screenToWorld(value.location)
        let startWorld = screenToWorld(value.startLocation)
        
        // 计算是否已经显著移动（用本地坐标系）
        let dx = value.location.x - value.startLocation.x
        let dy = value.location.y - value.startLocation.y
        if sqrt(dx*dx + dy*dy) > 3 {
            hasMovedSignificantly = true
        }
        
        // Option 键按下时：选择模式
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
        
        // 短延迟后重置 hasMovedSignificantly，让 tap 行为生效
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
    
    /// 范围擦除：只删除笔划上触点附近的段，非笔划对象整对象擦除
    private func handleErase(worldPoint: WhiteboardPoint, radius: Double) {
        guard let doc = service.currentDocument else { return }
        let worldRadius = radius / zoom  // 转换为世界坐标半径
        let tolerance = worldRadius + 5
        
        var toRemoveIds: Set<UUID> = []
        var modifiedStrokes: [StrokeShape] = []
        var hasChanges = false
        
        for obj in doc.objects {
            switch obj {
            case .stroke(let s):
                if let modified = eraseStrokeRange(s, at: worldPoint, tolerance: tolerance) {
                    if modified.points.isEmpty {
                        toRemoveIds.insert(s.id)
                    } else {
                        modifiedStrokes.append(modified)
                        hasChanges = true
                    }
                }
            case .rectangle, .ellipse, .triangle, .line, .arrow:
                if obj.contains(worldPoint) {
                    toRemoveIds.insert(obj.id)
                }
            }
        }
        
        if !toRemoveIds.isEmpty {
            service.deleteObjects(ids: toRemoveIds)
        }
        if hasChanges {
            // 应用修改的笔划
            var newObjects = doc.objects
            for modified in modifiedStrokes {
                if let index = newObjects.firstIndex(where: { $0.id == modified.id }) {
                    newObjects[index] = .stroke(modified)
                }
            }
            service.replaceAllObjects(newObjects)
        }
    }
    
    /// 在笔划上擦除触点附近的段，返回修改后的笔划（如果无变化返回 nil）
    private func eraseStrokeRange(_ stroke: StrokeShape, at point: WhiteboardPoint, tolerance: Double) -> StrokeShape? {
        let points = stroke.points
        guard !points.isEmpty else { return nil }
        
        // 找到所有在擦除范围内的点
        var erasedIndices = Set<Int>()
        for (i, p) in points.enumerated() {
            let dx = p.x - point.x
            let dy = p.y - point.y
            if dx*dx + dy*dy <= tolerance * tolerance {
                erasedIndices.insert(i)
            }
        }
        
        if erasedIndices.isEmpty { return nil }
        
        // 扩展擦除范围：相邻的擦除点合并为一段
        // 找到被擦除段之间的保留段
        var keptPoints: [WhiteboardPoint] = []
        var i = 0
        while i < points.count {
            if erasedIndices.contains(i) {
                // 跳过擦除段
                while i < points.count && erasedIndices.contains(i) {
                    i += 1
                }
            } else {
                keptPoints.append(points[i])
                i += 1
            }
        }
        
        var newStroke = stroke
        newStroke.points = keptPoints
        return newStroke
    }
    
    private func handleLineDrawing(worldPoint: WhiteboardPoint, start: WhiteboardPoint) {
        if drawingObject == nil {
            let initial: WhiteboardObject
            if tool == .line {
                initial = .line(LineShape(start: start, end: worldPoint, color: currentColor, strokeWidth: strokeWidth))
            } else {
                initial = .arrow(ArrowShape(start: start, end: worldPoint, color: currentColor, strokeWidth: strokeWidth))
            }
            drawingObject = initial
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
            // 移动选中对象
            dragStartPoint = start
            dragOriginalObjects = selectedObjects
        }
        
        guard let _ = dragStartPoint else {
            return
        }
        
        // 移动对象
        let dx = worldPoint.x - start.x
        let dy = worldPoint.y - start.y
        let offset2 = WhiteboardPoint(x: dx, y: dy)
        
        // 应用移动到当前画板对象
        guard var doc = service.currentDocument else { return }
        for origObj in dragOriginalObjects {
            if let newObj = translateObject(origObj, by: offset2),
               let index = doc.objects.firstIndex(where: { $0.id == origObj.id }) {
                doc.objects[index] = newObj
            }
        }
        // 直接更新，不记录撤销
        service.replaceAllObjects(doc.objects, recordUndo: false)
    }
    
    private func translateObject(_ object: WhiteboardObject, by offset: WhiteboardPoint) -> WhiteboardObject? {
        switch object {
        case .stroke(let s): return .stroke(s.translated(by: offset))
        case .rectangle(let r): return .rectangle(r.translated(by: offset))
        case .ellipse(let e): return .ellipse(e.translated(by: offset))
        case .triangle(let t): return .triangle(t.translated(by: offset))
        case .line(let l): return .line(l.translated(by: offset))
        case .arrow(let a): return .arrow(a.translated(by: offset))
        }
    }
}

// MARK: - 单个对象的渲染

struct ObjectShapeView: View {
    let object: WhiteboardObject
    let zoom: Double
    let canvasOffset: CGSize
    let isSelected: Bool
    
    var body: some View {
        Group {
            switch object {
            case .stroke(let s):
                StrokeView(stroke: s, zoom: zoom, canvasOffset: canvasOffset)
            case .rectangle(let r):
                RectangleView(rect: r, zoom: zoom, canvasOffset: canvasOffset)
            case .ellipse(let e):
                EllipseView(ellipse: e, zoom: zoom, canvasOffset: canvasOffset)
            case .triangle(let t):
                TriangleView(triangle: t, zoom: zoom, canvasOffset: canvasOffset)
            case .line(let l):
                LineView(line: l, zoom: zoom, canvasOffset: canvasOffset)
            case .arrow(let a):
                ArrowView(arrow: a, zoom: zoom, canvasOffset: canvasOffset)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.accentColor, lineWidth: isSelected ? 2 : 0)
                .frame(
                    width: (object.boundingRect.width + 10) * zoom,
                    height: (object.boundingRect.height + 10) * zoom
                )
                .position(
                    x: (object.boundingRect.x + object.boundingRect.width / 2) * zoom + canvasOffset.width,
                    y: (object.boundingRect.y + object.boundingRect.height / 2) * zoom + canvasOffset.height
                )
        )
    }
}

// MARK: - 各形状的渲染

struct StrokeView: View {
    let stroke: StrokeShape
    let zoom: Double
    let canvasOffset: CGSize
    
    var body: some View {
        // 使用 Path 绘制，使用二次贝塞尔平滑
        Path { path in
            let points = stroke.points
            guard points.count > 0 else { return }
            
            path.move(to: CGPoint(
                x: points[0].x * zoom + canvasOffset.width,
                y: points[0].y * zoom + canvasOffset.height
            ))
            
            if points.count == 1 {
                // 单点：画一个小圆点
                let p0 = points[0]
                let r = (stroke.strokeWidth * zoom) / 2
                path.addEllipse(in: CGRect(
                    x: p0.x * zoom + canvasOffset.width - r,
                    y: p0.y * zoom + canvasOffset.height - r,
                    width: r * 2,
                    height: r * 2
                ))
            } else if points.count == 2 {
                path.addLine(to: CGPoint(
                    x: points[1].x * zoom + canvasOffset.width,
                    y: points[1].y * zoom + canvasOffset.height
                ))
            } else {
                // 使用 二次贝塞尔曲线 串联所有点（中点法）
                for i in 1..<points.count {
                    let curr = points[i]
                    let prev = points[i - 1]
                    let mid = WhiteboardPoint(
                        x: (prev.x + curr.x) / 2,
                        y: (prev.y + curr.y) / 2
                    )
                    path.addQuadCurve(
                        to: CGPoint(x: mid.x * zoom + canvasOffset.width, y: mid.y * zoom + canvasOffset.height),
                        control: CGPoint(x: prev.x * zoom + canvasOffset.width, y: prev.y * zoom + canvasOffset.height)
                    )
                }
                if let last = points.last {
                    path.addLine(to: CGPoint(
                        x: last.x * zoom + canvasOffset.width,
                        y: last.y * zoom + canvasOffset.height
                    ))
                }
            }
        }
        .stroke(stroke.color.color, style: StrokeStyle(
            lineWidth: max(0.5, stroke.strokeWidth * zoom),
            lineCap: .round,
            lineJoin: .round
        ))
    }
}

struct RectangleView: View {
    let rect: RectangleShape
    let zoom: Double
    let canvasOffset: CGSize
    
    var body: some View {
        ZStack {
            if rect.fillStyle.isVisible {
                Rectangle()
                    .fill(fillColor)
                    .frame(width: rect.rect.width * zoom, height: rect.rect.height * zoom)
                    .position(
                        x: rect.rect.center.x * zoom + canvasOffset.width,
                        y: rect.rect.center.y * zoom + canvasOffset.height
                    )
            }
            Rectangle()
                .stroke(rect.color.color, lineWidth: max(0.5, rect.strokeWidth * zoom))
                .frame(width: rect.rect.width * zoom, height: rect.rect.height * zoom)
                .position(
                    x: rect.rect.center.x * zoom + canvasOffset.width,
                    y: rect.rect.center.y * zoom + canvasOffset.height
                )
        }
    }
    
    private var fillColor: Color {
        switch rect.fillStyle {
        case .none: return .clear
        case .solid: return rect.color.color
        case .semiTransparent: return rect.color.color.opacity(0.4)
        }
    }
}

struct EllipseView: View {
    let ellipse: EllipseShape
    let zoom: Double
    let canvasOffset: CGSize
    
    var body: some View {
        ZStack {
            if ellipse.fillStyle.isVisible {
                Ellipse()
                    .fill(fillColor)
                    .frame(width: ellipse.rect.width * zoom, height: ellipse.rect.height * zoom)
                    .position(
                        x: ellipse.rect.center.x * zoom + canvasOffset.width,
                        y: ellipse.rect.center.y * zoom + canvasOffset.height
                    )
            }
            Ellipse()
                .stroke(ellipse.color.color, lineWidth: max(0.5, ellipse.strokeWidth * zoom))
                .frame(width: ellipse.rect.width * zoom, height: ellipse.rect.height * zoom)
                .position(
                    x: ellipse.rect.center.x * zoom + canvasOffset.width,
                    y: ellipse.rect.center.y * zoom + canvasOffset.height
                )
        }
    }
    
    private var fillColor: Color {
        switch ellipse.fillStyle {
        case .none: return .clear
        case .solid: return ellipse.color.color
        case .semiTransparent: return ellipse.color.color.opacity(0.4)
        }
    }
}

struct TriangleView: View {
    let triangle: TriangleShape
    let zoom: Double
    let canvasOffset: CGSize
    
    var body: some View {
        ZStack {
            if triangle.fillStyle.isVisible {
                TriangleShapeView()
                    .fill(fillColor)
                    .frame(width: triangle.rect.width * zoom, height: triangle.rect.height * zoom)
                    .position(
                        x: triangle.rect.center.x * zoom + canvasOffset.width,
                        y: triangle.rect.center.y * zoom + canvasOffset.height
                    )
            }
            TriangleShapeView()
                .stroke(triangle.color.color, lineWidth: max(0.5, triangle.strokeWidth * zoom))
                .frame(width: triangle.rect.width * zoom, height: triangle.rect.height * zoom)
                .position(
                    x: triangle.rect.center.x * zoom + canvasOffset.width,
                    y: triangle.rect.center.y * zoom + canvasOffset.height
                )
        }
    }
    
    private var fillColor: Color {
        switch triangle.fillStyle {
        case .none: return .clear
        case .solid: return triangle.color.color
        case .semiTransparent: return triangle.color.color.opacity(0.4)
        }
    }
}

struct TriangleShapeView: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct LineView: View {
    let line: LineShape
    let zoom: Double
    let canvasOffset: CGSize
    
    var body: some View {
        Path { path in
            path.move(to: CGPoint(
                x: line.startPoint.x * zoom + canvasOffset.width,
                y: line.startPoint.y * zoom + canvasOffset.height
            ))
            path.addLine(to: CGPoint(
                x: line.endPoint.x * zoom + canvasOffset.width,
                y: line.endPoint.y * zoom + canvasOffset.height
            ))
        }
        .stroke(line.color.color, style: StrokeStyle(
            lineWidth: max(0.5, line.strokeWidth * zoom),
            lineCap: .round
        ))
    }
}

struct ArrowView: View {
    let arrow: ArrowShape
    let zoom: Double
    let canvasOffset: CGSize
    
    var body: some View {
        ZStack {
            // 主体
            Path { path in
                path.move(to: CGPoint(
                    x: arrow.startPoint.x * zoom + canvasOffset.width,
                    y: arrow.startPoint.y * zoom + canvasOffset.height
                ))
                path.addLine(to: CGPoint(
                    x: arrow.endPoint.x * zoom + canvasOffset.width,
                    y: arrow.endPoint.y * zoom + canvasOffset.height
                ))
            }
            .stroke(arrow.color.color, style: StrokeStyle(
                lineWidth: max(0.5, arrow.strokeWidth * zoom),
                lineCap: .round
            ))
            
            // 箭头头部
            let head = arrow.headPoints
            Path { path in
                path.move(to: CGPoint(
                    x: head.left.x * zoom + canvasOffset.width,
                    y: head.left.y * zoom + canvasOffset.height
                ))
                path.addLine(to: CGPoint(
                    x: arrow.endPoint.x * zoom + canvasOffset.width,
                    y: arrow.endPoint.y * zoom + canvasOffset.height
                ))
                path.addLine(to: CGPoint(
                    x: head.right.x * zoom + canvasOffset.width,
                    y: head.right.y * zoom + canvasOffset.height
                ))
            }
            .stroke(arrow.color.color, style: StrokeStyle(
                lineWidth: max(0.5, arrow.strokeWidth * zoom),
                lineCap: .round,
                lineJoin: .round
            ))
        }
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

// MARK: - 选区边框

struct SelectionBoundsView: View {
    let objects: [WhiteboardObject]
    let zoom: Double
    let canvasOffset: CGSize
    
    var body: some View {
        if let bounds = combinedBounds {
            let padding = 8.0
            Rectangle()
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .frame(
                    width: (bounds.width + padding * 2) * zoom,
                    height: (bounds.height + padding * 2) * zoom
                )
                .position(
                    x: (bounds.x + bounds.width / 2) * zoom + canvasOffset.width,
                    y: (bounds.y + bounds.height / 2) * zoom + canvasOffset.height
                )
        }
    }
    
    private var combinedBounds: WhiteboardRect? {
        guard !objects.isEmpty else { return nil }
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        for obj in objects {
            let r = obj.boundingRect
            minX = Swift.min(minX, r.x)
            minY = Swift.min(minY, r.y)
            maxX = Swift.max(maxX, r.x + r.width)
            maxY = Swift.max(maxY, r.y + r.height)
        }
        return WhiteboardRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
