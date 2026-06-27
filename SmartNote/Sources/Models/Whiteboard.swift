import Foundation
import SwiftUI
import CoreGraphics

// MARK: - 基础几何

/// 画板上的一个点（包含压力）
struct WhiteboardPoint: Codable, Hashable {
    var x: Double
    var y: Double
    var pressure: Double  // 0.0 - 1.0
    
    init(x: Double, y: Double, pressure: Double = 1.0) {
        self.x = x
        self.y = y
        self.pressure = pressure
    }
    
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

/// 矩形
struct WhiteboardRect: Codable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    
    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
    
    init(min: WhiteboardPoint, max: WhiteboardPoint) {
        self.x = Swift.min(min.x, max.x)
        self.y = Swift.min(min.y, max.y)
        self.width = abs(max.x - min.x)
        self.height = abs(max.y - min.y)
    }
    
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    
    var minPoint: WhiteboardPoint { WhiteboardPoint(x: x, y: y) }
    var maxPoint: WhiteboardPoint {
        WhiteboardPoint(x: x + width, y: y + height)
    }
    
    var center: WhiteboardPoint {
        WhiteboardPoint(x: x + width / 2, y: y + height / 2)
    }
    
    func contains(_ point: WhiteboardPoint) -> Bool {
        return point.x >= x && point.x <= x + width &&
               point.y >= y && point.y <= y + height
    }
}

// MARK: - 图形类型

/// 画板上的对象（笔划或图形）
enum WhiteboardObject: Codable, Identifiable, Hashable {
    case stroke(StrokeShape)
    case rectangle(RectangleShape)
    case ellipse(EllipseShape)
    case triangle(TriangleShape)
    case line(LineShape)
    case arrow(ArrowShape)
    case text(TextShape)
    
    var id: UUID {
        switch self {
        case .stroke(let s): return s.id
        case .rectangle(let s): return s.id
        case .ellipse(let s): return s.id
        case .triangle(let s): return s.id
        case .line(let s): return s.id
        case .arrow(let s): return s.id
        case .text(let s): return s.id
        }
    }
    
    var boundingRect: WhiteboardRect {
        switch self {
        case .stroke(let s): return s.boundingRect
        case .rectangle(let s): return s.boundingRect
        case .ellipse(let s): return s.boundingRect
        case .triangle(let s): return s.boundingRect
        case .line(let s): return s.boundingRect
        case .arrow(let s): return s.boundingRect
        case .text(let s): return s.boundingRect
        }
    }
    
    var zIndex: Int {
        switch self {
        case .stroke(let s): return s.zIndex
        case .rectangle(let s): return s.zIndex
        case .ellipse(let s): return s.zIndex
        case .triangle(let s): return s.zIndex
        case .line(let s): return s.zIndex
        case .arrow(let s): return s.zIndex
        case .text(let s): return s.zIndex
        }
    }
    
    var color: WhiteboardColor {
        switch self {
        case .stroke(let s): return s.color
        case .rectangle(let s): return s.color
        case .ellipse(let s): return s.color
        case .triangle(let s): return s.color
        case .line(let s): return s.color
        case .arrow(let s): return s.color
        case .text(let s): return s.color
        }
    }
    
    var strokeWidth: Double {
        switch self {
        case .stroke(let s): return s.strokeWidth
        case .rectangle(let s): return s.strokeWidth
        case .ellipse(let s): return s.strokeWidth
        case .triangle(let s): return s.strokeWidth
        case .line(let s): return s.strokeWidth
        case .arrow(let s): return s.strokeWidth
        case .text: return 0
        }
    }
    
    var fillStyle: FillStyle {
        switch self {
        case .stroke(let s): return .none
        case .rectangle(let s): return s.fillStyle
        case .ellipse(let s): return s.fillStyle
        case .triangle(let s): return s.fillStyle
        case .line: return .none
        case .arrow: return .none
        case .text: return .none
        }
    }
    
    /// 该形状的独立填充色（nil = 使用笔划色）
    var fillColor: WhiteboardColor? {
        switch self {
        case .rectangle(let s): return s.fillColor
        case .ellipse(let s): return s.fillColor
        case .triangle(let s): return s.fillColor
        default: return nil
        }
    }
    
    func contains(_ point: WhiteboardPoint) -> Bool {
        switch self {
        case .stroke(let s): return s.contains(point)
        case .rectangle(let s): return s.contains(point)
        case .ellipse(let s): return s.contains(point)
        case .triangle(let s): return s.contains(point)
        case .line(let s): return s.contains(point)
        case .arrow(let s): return s.contains(point)
        case .text(let s): return s.contains(point)
        }
    }
}

// MARK: - 颜色

/// 画板颜色（RGBA）
struct WhiteboardColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double
    
    init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
    
    static let black = WhiteboardColor(red: 0, green: 0, blue: 0)
    static let red = WhiteboardColor(red: 1, green: 0, blue: 0)
    static let blue = WhiteboardColor(red: 0, green: 0.4, blue: 1)
    static let green = WhiteboardColor(red: 0, green: 0.7, blue: 0.3)
    static let yellow = WhiteboardColor(red: 1, green: 0.8, blue: 0)
    static let orange = WhiteboardColor(red: 1, green: 0.5, blue: 0)
    static let purple = WhiteboardColor(red: 0.6, green: 0.2, blue: 0.8)
    static let pink = WhiteboardColor(red: 1, green: 0.4, blue: 0.7)
    static let gray = WhiteboardColor(red: 0.5, green: 0.5, blue: 0.5)
    
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
    
    /// 预设颜色调色板
    static let palette: [WhiteboardColor] = [
        .black, .red, .orange, .yellow, .green, .blue, .purple, .pink, .gray
    ]
}

// MARK: - 填充样式

enum FillStyle: Codable, Hashable {
    case none
    case solid
    case semiTransparent
    
    var isVisible: Bool {
        switch self {
        case .none: return false
        case .solid, .semiTransparent: return true
        }
    }
}

// MARK: - 形状基类协议

protocol WhiteboardShape: Codable, Hashable {
    var id: UUID { get }
    var zIndex: Int { get set }
    var color: WhiteboardColor { get set }
    var strokeWidth: Double { get set }
    var fillStyle: FillStyle { get set }
    var rotation: Double { get set }  // 角度
    
    var boundingRect: WhiteboardRect { get }
    
    func translated(by offset: WhiteboardPoint) -> Self
    func scaled(by factor: Double, around center: WhiteboardPoint) -> Self
    mutating func move(by offset: WhiteboardPoint)
    mutating func resize(to rect: WhiteboardRect)
    func contains(_ point: WhiteboardPoint) -> Bool
}

// MARK: - 笔划

struct StrokeShape: WhiteboardShape, Codable, Hashable, Identifiable {
    var id: UUID
    var points: [WhiteboardPoint]
    var zIndex: Int
    var color: WhiteboardColor
    var strokeWidth: Double
    var fillStyle: FillStyle
    var rotation: Double
    
    init(id: UUID = UUID(), points: [WhiteboardPoint], color: WhiteboardColor = .black, strokeWidth: Double = 3.0) {
        self.id = id
        self.points = points
        self.zIndex = 0
        self.color = color
        self.strokeWidth = strokeWidth
        self.fillStyle = .none
        self.rotation = 0
    }
    
    var boundingRect: WhiteboardRect {
        guard !points.isEmpty else { return WhiteboardRect(x: 0, y: 0, width: 0, height: 0) }
        let minX = points.map { $0.x }.min() ?? 0
        let minY = points.map { $0.y }.min() ?? 0
        let maxX = points.map { $0.x }.max() ?? 0
        let maxY = points.map { $0.y }.max() ?? 0
        // 加上笔划宽度的 padding
        let padding = strokeWidth
        return WhiteboardRect(x: minX - padding, y: minY - padding, width: (maxX - minX) + padding * 2, height: (maxY - minY) + padding * 2)
    }
    
    func translated(by offset: WhiteboardPoint) -> StrokeShape {
        var copy = self
        copy.points = points.map { WhiteboardPoint(x: $0.x + offset.x, y: $0.y + offset.y, pressure: $0.pressure) }
        return copy
    }
    
    func scaled(by factor: Double, around center: WhiteboardPoint) -> StrokeShape {
        var copy = self
        copy.points = points.map {
            WhiteboardPoint(
                x: center.x + ($0.x - center.x) * factor,
                y: center.y + ($0.y - center.y) * factor,
                pressure: $0.pressure
            )
        }
        copy.strokeWidth *= factor
        return copy
    }
    
    mutating func move(by offset: WhiteboardPoint) {
        points = points.map { WhiteboardPoint(x: $0.x + offset.x, y: $0.y + offset.y, pressure: $0.pressure) }
    }
    
    mutating func resize(to rect: WhiteboardRect) {
        let old = boundingRect
        guard old.width > 0 && old.height > 0 else { return }
        let sx = rect.width / old.width
        let sy = rect.height / old.height
        let scale = (sx + sy) / 2
        self = self.scaled(by: scale, around: rect.center)
    }
    
    func contains(_ point: WhiteboardPoint) -> Bool {
        // 对笔划做"接近度"测试
        let tolerance = strokeWidth + 5
        for p in points {
            let dx = p.x - point.x
            let dy = p.y - point.y
            if dx * dx + dy * dy <= tolerance * tolerance {
                return true
            }
        }
        return false
    }
}

// MARK: - 矩形

struct RectangleShape: WhiteboardShape, Codable, Hashable, Identifiable {
    var id: UUID
    var rect: WhiteboardRect
    var zIndex: Int
    var color: WhiteboardColor
    var strokeWidth: Double
    var fillStyle: FillStyle
    var fillColor: WhiteboardColor?
    var rotation: Double  // 围绕中心
    
    init(id: UUID = UUID(), rect: WhiteboardRect, color: WhiteboardColor = .black, strokeWidth: Double = 2.0, fillStyle: FillStyle = .none, fillColor: WhiteboardColor? = nil) {
        self.id = id
        self.rect = rect
        self.zIndex = 0
        self.color = color
        self.strokeWidth = strokeWidth
        self.fillStyle = fillStyle
        self.fillColor = fillColor
        self.rotation = 0
    }
    
    var boundingRect: WhiteboardRect { rect }
    
    func translated(by offset: WhiteboardPoint) -> RectangleShape {
        var copy = self
        copy.rect.x += offset.x
        copy.rect.y += offset.y
        return copy
    }
    
    func scaled(by factor: Double, around center: WhiteboardPoint) -> RectangleShape {
        var copy = self
        let dx = copy.rect.center.x - center.x
        let dy = copy.rect.center.y - center.y
        copy.rect.x = center.x + dx * factor - copy.rect.width * factor / 2
        copy.rect.y = center.y + dy * factor - copy.rect.height * factor / 2
        copy.rect.width *= factor
        copy.rect.height *= factor
        copy.strokeWidth *= factor
        return copy
    }
    
    mutating func move(by offset: WhiteboardPoint) {
        rect.x += offset.x
        rect.y += offset.y
    }
    
    mutating func resize(to newRect: WhiteboardRect) {
        rect = newRect
    }
    
    func contains(_ point: WhiteboardPoint) -> Bool {
        if fillStyle.isVisible {
            return rect.contains(point)
        }
        // 只在边框附近算选中
        let t = strokeWidth + 5
        let onLeft = abs(point.x - rect.x) <= t && point.y >= rect.y - t && point.y <= rect.y + rect.height + t
        let onRight = abs(point.x - (rect.x + rect.width)) <= t && point.y >= rect.y - t && point.y <= rect.y + rect.height + t
        let onTop = abs(point.y - rect.y) <= t && point.x >= rect.x - t && point.x <= rect.x + rect.width + t
        let onBottom = abs(point.y - (rect.y + rect.height)) <= t && point.x >= rect.x - t && point.x <= rect.x + rect.width + t
        return onLeft || onRight || onTop || onBottom || rect.contains(point)
    }
}

// MARK: - 椭圆

struct EllipseShape: WhiteboardShape, Codable, Hashable, Identifiable {
    var id: UUID
    var rect: WhiteboardRect
    var zIndex: Int
    var color: WhiteboardColor
    var strokeWidth: Double
    var fillStyle: FillStyle
    var fillColor: WhiteboardColor?
    var rotation: Double
    
    init(id: UUID = UUID(), rect: WhiteboardRect, color: WhiteboardColor = .black, strokeWidth: Double = 2.0, fillStyle: FillStyle = .none, fillColor: WhiteboardColor? = nil) {
        self.id = id
        self.rect = rect
        self.zIndex = 0
        self.color = color
        self.strokeWidth = strokeWidth
        self.fillStyle = fillStyle
        self.fillColor = fillColor
        self.rotation = 0
    }
    
    var boundingRect: WhiteboardRect { rect }
    
    func translated(by offset: WhiteboardPoint) -> EllipseShape {
        var copy = self
        copy.rect.x += offset.x
        copy.rect.y += offset.y
        return copy
    }
    
    func scaled(by factor: Double, around center: WhiteboardPoint) -> EllipseShape {
        var copy = self
        let dx = copy.rect.center.x - center.x
        let dy = copy.rect.center.y - center.y
        copy.rect.x = center.x + dx * factor - copy.rect.width * factor / 2
        copy.rect.y = center.y + dy * factor - copy.rect.height * factor / 2
        copy.rect.width *= factor
        copy.rect.height *= factor
        copy.strokeWidth *= factor
        return copy
    }
    
    mutating func move(by offset: WhiteboardPoint) {
        rect.x += offset.x
        rect.y += offset.y
    }
    
    mutating func resize(to newRect: WhiteboardRect) {
        rect = newRect
    }
    
    func contains(_ point: WhiteboardPoint) -> Bool {
        let cx = rect.center.x
        let cy = rect.center.y
        let rx = rect.width / 2
        let ry = rect.height / 2
        guard rx > 0 && ry > 0 else { return false }
        let dx = (point.x - cx) / rx
        let dy = (point.y - cy) / ry
        let value = dx * dx + dy * dy
        if fillStyle.isVisible {
            return value <= 1.0
        }
        let t = (strokeWidth + 5) / min(rx, ry)
        return abs(value - 1.0) <= t
    }
}

// MARK: - 三角形

struct TriangleShape: WhiteboardShape, Codable, Hashable, Identifiable {
    var id: UUID
    var rect: WhiteboardRect
    var zIndex: Int
    var color: WhiteboardColor
    var strokeWidth: Double
    var fillStyle: FillStyle
    var fillColor: WhiteboardColor?
    var rotation: Double
    
    init(id: UUID = UUID(), rect: WhiteboardRect, color: WhiteboardColor = .black, strokeWidth: Double = 2.0, fillStyle: FillStyle = .none, fillColor: WhiteboardColor? = nil) {
        self.id = id
        self.rect = rect
        self.zIndex = 0
        self.color = color
        self.strokeWidth = strokeWidth
        self.fillStyle = fillStyle
        self.fillColor = fillColor
        self.rotation = 0
    }
    
    /// 三角形的三个顶点（等腰三角形，顶点朝上）
    var vertices: [WhiteboardPoint] {
        let top = WhiteboardPoint(x: rect.center.x, y: rect.y)
        let left = WhiteboardPoint(x: rect.x, y: rect.y + rect.height)
        let right = WhiteboardPoint(x: rect.x + rect.width, y: rect.y + rect.height)
        return [top, right, left]
    }
    
    var boundingRect: WhiteboardRect { rect }
    
    func translated(by offset: WhiteboardPoint) -> TriangleShape {
        var copy = self
        copy.rect.x += offset.x
        copy.rect.y += offset.y
        return copy
    }
    
    func scaled(by factor: Double, around center: WhiteboardPoint) -> TriangleShape {
        var copy = self
        let dx = copy.rect.center.x - center.x
        let dy = copy.rect.center.y - center.y
        copy.rect.x = center.x + dx * factor - copy.rect.width * factor / 2
        copy.rect.y = center.y + dy * factor - copy.rect.height * factor / 2
        copy.rect.width *= factor
        copy.rect.height *= factor
        copy.strokeWidth *= factor
        return copy
    }
    
    mutating func move(by offset: WhiteboardPoint) {
        rect.x += offset.x
        rect.y += offset.y
    }
    
    mutating func resize(to newRect: WhiteboardRect) {
        rect = newRect
    }
    
    func contains(_ point: WhiteboardPoint) -> Bool {
        // 使用重心法判断点是否在三角形内
        let p1 = vertices[0]
        let p2 = vertices[1]
        let p3 = vertices[2]
        
        let d1 = sign(point, p1, p2)
        let d2 = sign(point, p2, p3)
        let d3 = sign(point, p3, p1)
        
        let hasNeg = d1 < 0 || d2 < 0 || d3 < 0
        let hasPos = d1 > 0 || d2 > 0 || d3 > 0
        
        if fillStyle.isVisible {
            return !(hasNeg && hasPos)
        }
        // 边框模式：检查是否在边框附近
        let onEdge = pointOnLine(point, p1, p2) || pointOnLine(point, p2, p3) || pointOnLine(point, p3, p1)
        return onEdge
    }
    
    private func sign(_ p1: WhiteboardPoint, _ p2: WhiteboardPoint, _ p3: WhiteboardPoint) -> Double {
        return (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y)
    }
    
    private func pointOnLine(_ p: WhiteboardPoint, _ a: WhiteboardPoint, _ b: WhiteboardPoint) -> Bool {
        let t = strokeWidth + 5
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return false }
        var t2 = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t2 = max(0, min(1, t2))
        let cx = a.x + t2 * dx
        let cy = a.y + t2 * dy
        let dist2 = (p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy)
        return dist2 <= t * t
    }
}

// MARK: - 直线

struct LineShape: WhiteboardShape, Codable, Hashable, Identifiable {
    var id: UUID
    var startPoint: WhiteboardPoint
    var endPoint: WhiteboardPoint
    var zIndex: Int
    var color: WhiteboardColor
    var strokeWidth: Double
    var fillStyle: FillStyle
    var rotation: Double
    
    init(id: UUID = UUID(), start: WhiteboardPoint, end: WhiteboardPoint, color: WhiteboardColor = .black, strokeWidth: Double = 2.0) {
        self.id = id
        self.startPoint = start
        self.endPoint = end
        self.zIndex = 0
        self.color = color
        self.strokeWidth = strokeWidth
        self.fillStyle = .none
        self.rotation = 0
    }
    
    var boundingRect: WhiteboardRect {
        WhiteboardRect(min: WhiteboardPoint(x: Swift.min(startPoint.x, endPoint.x), y: Swift.min(startPoint.y, endPoint.y)),
                       max: WhiteboardPoint(x: Swift.max(startPoint.x, endPoint.x), y: Swift.max(startPoint.y, endPoint.y)))
    }
    
    func translated(by offset: WhiteboardPoint) -> LineShape {
        var copy = self
        copy.startPoint = WhiteboardPoint(x: startPoint.x + offset.x, y: startPoint.y + offset.y)
        copy.endPoint = WhiteboardPoint(x: endPoint.x + offset.x, y: endPoint.y + offset.y)
        return copy
    }
    
    func scaled(by factor: Double, around center: WhiteboardPoint) -> LineShape {
        var copy = self
        copy.startPoint = WhiteboardPoint(
            x: center.x + (startPoint.x - center.x) * factor,
            y: center.y + (startPoint.y - center.y) * factor
        )
        copy.endPoint = WhiteboardPoint(
            x: center.x + (endPoint.x - center.x) * factor,
            y: center.y + (endPoint.y - center.y) * factor
        )
        copy.strokeWidth *= factor
        return copy
    }
    
    mutating func move(by offset: WhiteboardPoint) {
        startPoint = WhiteboardPoint(x: startPoint.x + offset.x, y: startPoint.y + offset.y)
        endPoint = WhiteboardPoint(x: endPoint.x + offset.x, y: endPoint.y + offset.y)
    }
    
    mutating func resize(to rect: WhiteboardRect) {
        let old = boundingRect
        guard old.width > 0 || old.height > 0 else {
            startPoint = rect.minPoint
            endPoint = rect.maxPoint
            return
        }
        let oldCenter = old.center
        let newCenter = rect.center
        startPoint = WhiteboardPoint(
            x: newCenter.x + (startPoint.x - oldCenter.x),
            y: newCenter.y + (startPoint.y - oldCenter.y)
        )
        endPoint = WhiteboardPoint(
            x: newCenter.x + (endPoint.x - oldCenter.x),
            y: newCenter.y + (endPoint.y - oldCenter.y)
        )
    }
    
    func contains(_ point: WhiteboardPoint) -> Bool {
        let t = strokeWidth + 5
        let dx = endPoint.x - startPoint.x
        let dy = endPoint.y - startPoint.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 {
            let ddx = point.x - startPoint.x
            let ddy = point.y - startPoint.y
            return ddx * ddx + ddy * ddy <= t * t
        }
        var tt = ((point.x - startPoint.x) * dx + (point.y - startPoint.y) * dy) / len2
        tt = max(0, min(1, tt))
        let cx = startPoint.x + tt * dx
        let cy = startPoint.y + tt * dy
        let ddx = point.x - cx
        let ddy = point.y - cy
        return ddx * ddx + ddy * ddy <= t * t
    }
}

// MARK: - 箭头

struct ArrowShape: WhiteboardShape, Codable, Hashable, Identifiable {
    var id: UUID
    var startPoint: WhiteboardPoint
    var endPoint: WhiteboardPoint
    var zIndex: Int
    var color: WhiteboardColor
    var strokeWidth: Double
    var fillStyle: FillStyle
    var rotation: Double
    
    init(id: UUID = UUID(), start: WhiteboardPoint, end: WhiteboardPoint, color: WhiteboardColor = .black, strokeWidth: Double = 2.0) {
        self.id = id
        self.startPoint = start
        self.endPoint = end
        self.zIndex = 0
        self.color = color
        self.strokeWidth = strokeWidth
        self.fillStyle = .none
        self.rotation = 0
    }
    
    var boundingRect: WhiteboardRect {
        let minX = Swift.min(startPoint.x, endPoint.x) - strokeWidth * 4
        let minY = Swift.min(startPoint.y, endPoint.y) - strokeWidth * 4
        let maxX = Swift.max(startPoint.x, endPoint.x) + strokeWidth * 4
        let maxY = Swift.max(startPoint.y, endPoint.y) + strokeWidth * 4
        return WhiteboardRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
    
    /// 箭头头部
    var headPoints: (left: WhiteboardPoint, right: WhiteboardPoint) {
        let angle = atan2(endPoint.y - startPoint.y, endPoint.x - startPoint.x)
        let headLength = max(15, strokeWidth * 4)
        let headAngle: Double = .pi / 7
        let left = WhiteboardPoint(
            x: endPoint.x - headLength * cos(angle - headAngle),
            y: endPoint.y - headLength * sin(angle - headAngle)
        )
        let right = WhiteboardPoint(
            x: endPoint.x - headLength * cos(angle + headAngle),
            y: endPoint.y - headLength * sin(angle + headAngle)
        )
        return (left, right)
    }
    
    func translated(by offset: WhiteboardPoint) -> ArrowShape {
        var copy = self
        copy.startPoint = WhiteboardPoint(x: startPoint.x + offset.x, y: startPoint.y + offset.y)
        copy.endPoint = WhiteboardPoint(x: endPoint.x + offset.x, y: endPoint.y + offset.y)
        return copy
    }
    
    func scaled(by factor: Double, around center: WhiteboardPoint) -> ArrowShape {
        var copy = self
        copy.startPoint = WhiteboardPoint(
            x: center.x + (startPoint.x - center.x) * factor,
            y: center.y + (startPoint.y - center.y) * factor
        )
        copy.endPoint = WhiteboardPoint(
            x: center.x + (endPoint.x - center.x) * factor,
            y: center.y + (endPoint.y - center.y) * factor
        )
        copy.strokeWidth *= factor
        return copy
    }
    
    mutating func move(by offset: WhiteboardPoint) {
        startPoint = WhiteboardPoint(x: startPoint.x + offset.x, y: startPoint.y + offset.y)
        endPoint = WhiteboardPoint(x: endPoint.x + offset.x, y: endPoint.y + offset.y)
    }
    
    mutating func resize(to rect: WhiteboardRect) {
        let old = boundingRect
        let oldCenter = old.center
        let newCenter = rect.center
        startPoint = WhiteboardPoint(
            x: newCenter.x + (startPoint.x - oldCenter.x),
            y: newCenter.y + (startPoint.y - oldCenter.y)
        )
        endPoint = WhiteboardPoint(
            x: newCenter.x + (endPoint.x - oldCenter.x),
            y: newCenter.y + (endPoint.y - oldCenter.y)
        )
    }
    
    func contains(_ point: WhiteboardPoint) -> Bool {
        // 检查主线
        if LineShape(start: startPoint, end: endPoint, strokeWidth: strokeWidth).contains(point) {
            return true
        }
        // 检查箭头头部
        let head = headPoints
        return LineShape(start: head.left, end: endPoint, strokeWidth: strokeWidth).contains(point) ||
               LineShape(start: head.right, end: endPoint, strokeWidth: strokeWidth).contains(point)
    }
}

// MARK: - 文字

struct TextShape: WhiteboardShape, Codable, Hashable, Identifiable {
    var id: UUID
    var rect: WhiteboardRect
    var text: String
    var zIndex: Int
    var color: WhiteboardColor
    var strokeWidth: Double
    var fillStyle: FillStyle
    var fillColor: WhiteboardColor?
    var rotation: Double
    var fontSize: Double
    var isBold: Bool
    var isItalic: Bool
    
    init(
        id: UUID = UUID(),
        position: WhiteboardPoint,
        text: String,
        color: WhiteboardColor = .black,
        fontSize: Double = 18.0,
        isBold: Bool = false,
        isItalic: Bool = false
    ) {
        self.id = id
        self.text = text
        self.zIndex = 0
        self.color = color
        self.strokeWidth = 0
        self.fillStyle = .none
        self.fillColor = nil
        self.rotation = 0
        self.fontSize = fontSize
        self.isBold = isBold
        self.isItalic = isItalic
        // 根据文本长度估算尺寸
        let estimatedWidth = max(Double(text.count) * fontSize * 0.6, 60)
        let estimatedHeight = fontSize * 1.5
        self.rect = WhiteboardRect(
            x: position.x,
            y: position.y,
            width: estimatedWidth,
            height: estimatedHeight
        )
    }
    
    /// 用实际测量结果调整 rect（用于编辑后让框贴合文本）
    mutating func fitRectToContent() {
        let estimatedWidth = max(Double(text.count) * fontSize * 0.6, 60)
        let estimatedHeight = fontSize * 1.5
        rect = WhiteboardRect(
            x: rect.x,
            y: rect.y,
            width: estimatedWidth,
            height: estimatedHeight
        )
    }
    
    var boundingRect: WhiteboardRect { rect }
    
    func translated(by offset: WhiteboardPoint) -> TextShape {
        var copy = self
        copy.rect.x += offset.x
        copy.rect.y += offset.y
        return copy
    }
    
    func scaled(by factor: Double, around center: WhiteboardPoint) -> TextShape {
        var copy = self
        let dx = copy.rect.center.x - center.x
        let dy = copy.rect.center.y - center.y
        copy.rect.x = center.x + dx * factor - copy.rect.width * factor / 2
        copy.rect.y = center.y + dy * factor - copy.rect.height * factor / 2
        copy.rect.width *= factor
        copy.rect.height *= factor
        copy.fontSize *= factor
        return copy
    }
    
    mutating func move(by offset: WhiteboardPoint) {
        rect.x += offset.x
        rect.y += offset.y
    }
    
    mutating func resize(to newRect: WhiteboardRect) {
        rect = newRect
    }
    
    func contains(_ point: WhiteboardPoint) -> Bool {
        return rect.contains(point)
    }
}

// MARK: - 画板文档

/// 一个画板文档
struct WhiteboardDocument: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var objects: [WhiteboardObject]
    var createdAt: Date
    var updatedAt: Date
    
    init(id: UUID = UUID(), name: String = "未命名画板", objects: [WhiteboardObject] = []) {
        self.id = id
        self.name = name
        self.objects = objects
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - 工具类型

enum WhiteboardTool: String, CaseIterable, Identifiable, Codable {
    case select
    case pen
    case line
    case rectangle
    case ellipse
    case triangle
    case arrow
    case text
    case eraser
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .select: return "选择"
        case .pen: return "画笔"
        case .line: return "直线"
        case .rectangle: return "矩形"
        case .ellipse: return "圆形"
        case .triangle: return "三角形"
        case .arrow: return "箭头"
        case .text: return "文字"
        case .eraser: return "橡皮"
        }
    }
    
    var icon: String {
        switch self {
        case .select: return "cursorarrow"
        case .pen: return "pencil.tip"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .triangle: return "triangle"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        case .eraser: return "eraser"
        }
    }
}
