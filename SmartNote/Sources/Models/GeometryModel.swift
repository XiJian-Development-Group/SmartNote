import Foundation
import SwiftUI
import CoreGraphics

// MARK: - 几何画板新增 Shape 类型
//
// 这些类型与 Whiteboard.swift 里的"传统形状"（stroke/rect/ellipse/text等）并列，
// 全部继承 WhiteboardShape 协议，便于 WhiteboardObject enum 统一建模与持久化。
// 这里集中放，避免 Whiteboard.swift 进一步膨胀。

// MARK: - 代数点

/// 拖动式点。可绑定到度量（中间点、垂足等）
struct PointShape: WhiteboardShape, Codable, Hashable, Identifiable {
    var id: UUID
    var position: WhiteboardPoint
    var zIndex: Int
    var color: WhiteboardColor
    var strokeWidth: Double
    var fillStyle: FillStyle
    var rotation: Double
    /// 点的可选标签（用于度量目标的中文名称，如 "C"）
    var label: String?

    init(id: UUID = UUID(), position: WhiteboardPoint, color: WhiteboardColor = .red, strokeWidth: Double = 6.0, label: String? = nil) {
        self.id = id
        self.position = position
        self.zIndex = 0
        self.color = color
        self.strokeWidth = strokeWidth
        self.fillStyle = .solid
        self.rotation = 0
        self.label = label
    }

    /// 点的命中判定：以 (x,y) 为中心的半径 ~strokeWidth 的圆
    var boundingRect: WhiteboardRect {
        let r = strokeWidth + 2
        return WhiteboardRect(x: position.x - r, y: position.y - r, width: r * 2, height: r * 2)
    }

    func translated(by offset: WhiteboardPoint) -> PointShape {
        var c = self
        c.position = WhiteboardPoint(x: position.x + offset.x, y: position.y + offset.y)
        return c
    }
    func scaled(by factor: Double, around center: WhiteboardPoint) -> PointShape {
        var c = self
        c.position = WhiteboardPoint(
            x: center.x + (position.x - center.x) * factor,
            y: center.y + (position.y - center.y) * factor
        )
        return c
    }
    mutating func move(by offset: WhiteboardPoint) {
        position = WhiteboardPoint(x: position.x + offset.x, y: position.y + offset.y)
    }
    mutating func resize(to rect: WhiteboardRect) {
        position = rect.center
    }
    func contains(_ point: WhiteboardPoint) -> Bool {
        let dx = point.x - position.x
        let dy = point.y - position.y
        let r = strokeWidth + 4
        return dx * dx + dy * dy <= r * r
    }
}

// MARK: - 圆

struct CircleShape: WhiteboardShape, Codable, Hashable, Identifiable {
    var id: UUID
    var center: WhiteboardPoint
    var radius: Double
    var zIndex: Int
    var color: WhiteboardColor
    var strokeWidth: Double
    var fillStyle: FillStyle
    var fillColor: WhiteboardColor?
    var rotation: Double

    init(id: UUID = UUID(), center: WhiteboardPoint, radius: Double, color: WhiteboardColor = .black, strokeWidth: Double = 2.0, fillStyle: FillStyle = .none, fillColor: WhiteboardColor? = nil) {
        self.id = id
        self.center = center
        self.radius = abs(radius)
        self.zIndex = 0
        self.color = color
        self.strokeWidth = strokeWidth
        self.fillStyle = fillStyle
        self.fillColor = fillColor
        self.rotation = 0
    }

    var boundingRect: WhiteboardRect {
        let r = radius + strokeWidth + 2
        return WhiteboardRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
    }

    func translated(by offset: WhiteboardPoint) -> CircleShape {
        var c = self
        c.center = WhiteboardPoint(x: center.x + offset.x, y: center.y + offset.y)
        return c
    }
    func scaled(by factor: Double, around anchor: WhiteboardPoint) -> CircleShape {
        var c = self
        c.center = WhiteboardPoint(
            x: anchor.x + (center.x - anchor.x) * factor,
            y: anchor.y + (center.y - anchor.y) * factor
        )
        c.radius *= factor
        c.strokeWidth *= factor
        return c
    }
    mutating func move(by offset: WhiteboardPoint) {
        center = WhiteboardPoint(x: center.x + offset.x, y: center.y + offset.y)
    }
    mutating func resize(to rect: WhiteboardRect) {
        center = rect.center
        radius = min(rect.width, rect.height) / 2
    }
    func contains(_ point: WhiteboardPoint) -> Bool {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let d2 = dx * dx + dy * dy
        let r2 = radius * radius
        if fillStyle.isVisible {
            return d2 <= r2
        }
        // 仅判定边框附近
        let tol = strokeWidth + 4
        let outer = (radius + tol) * (radius + tol)
        let inner = (radius - tol) * max(radius - tol, 0)
        return d2 <= outer && d2 >= inner
    }
}

// MARK: - 圆弧

struct ArcShape: WhiteboardShape, Codable, Hashable, Identifiable {
    var id: UUID
    var center: WhiteboardPoint
    var radius: Double
    /// 起始角与终止角（弧度），约定逆时针为正。
    var startAngle: Double
    var endAngle: Double
    var zIndex: Int
    var color: WhiteboardColor
    var strokeWidth: Double
    var fillStyle: FillStyle
    var rotation: Double

    init(id: UUID = UUID(), center: WhiteboardPoint, radius: Double, startAngle: Double, endAngle: Double, color: WhiteboardColor = .black, strokeWidth: Double = 2.0) {
        self.id = id
        self.center = center
        self.radius = abs(radius)
        self.startAngle = startAngle
        self.endAngle = endAngle
        self.zIndex = 0
        self.color = color
        self.strokeWidth = strokeWidth
        self.fillStyle = .none
        self.rotation = 0
    }

    var boundingRect: WhiteboardRect {
        let r = radius + strokeWidth + 2
        return WhiteboardRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
    }
    func translated(by offset: WhiteboardPoint) -> ArcShape {
        var c = self
        c.center = WhiteboardPoint(x: center.x + offset.x, y: center.y + offset.y)
        return c
    }
    func scaled(by factor: Double, around anchor: WhiteboardPoint) -> ArcShape {
        var c = self
        c.center = WhiteboardPoint(
            x: anchor.x + (center.x - anchor.x) * factor,
            y: anchor.y + (center.y - anchor.y) * factor
        )
        c.radius *= factor
        c.strokeWidth *= factor
        return c
    }
    mutating func move(by offset: WhiteboardPoint) {
        center = WhiteboardPoint(x: center.x + offset.x, y: center.y + offset.y)
    }
    mutating func resize(to rect: WhiteboardRect) {
        center = rect.center
        radius = min(rect.width, rect.height) / 2
    }
    func contains(_ point: WhiteboardPoint) -> Bool {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let d = sqrt(dx * dx + dy * dy)
        if abs(d - radius) > strokeWidth + 4 { return false }
        let angle = atan2(dy, dx)
        return angleBetween(startAngle, endAngle).contains(angle)
    }

    /// 规范化：start < end 的有向角范围（弧度）
    private func angleBetween(_ a: Double, _ b: Double) -> ClosedRange<Double> {
        var lo = a
        var hi = b
        while hi < lo { hi += .pi * 2 }
        while lo < hi - .pi * 2 { lo += .pi * 2 }
        return lo...hi
    }
}

// MARK: - 多边形

struct PolygonShape: WhiteboardShape, Codable, Hashable, Identifiable {
    var id: UUID
    var vertices: [WhiteboardPoint]
    var zIndex: Int
    var color: WhiteboardColor
    var strokeWidth: Double
    var fillStyle: FillStyle
    var fillColor: WhiteboardColor?
    var rotation: Double

    init(id: UUID = UUID(), vertices: [WhiteboardPoint], color: WhiteboardColor = .black, strokeWidth: Double = 2.0, fillStyle: FillStyle = .none, fillColor: WhiteboardColor? = nil) {
        self.id = id
        self.vertices = vertices
        self.zIndex = 0
        self.color = color
        self.strokeWidth = strokeWidth
        self.fillStyle = fillStyle
        self.fillColor = fillColor
        self.rotation = 0
    }

    var boundingRect: WhiteboardRect {
        guard !vertices.isEmpty else { return WhiteboardRect(x: 0, y: 0, width: 0, height: 0) }
        let xs = vertices.map(\.x)
        let ys = vertices.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        let p = strokeWidth + 2
        return WhiteboardRect(x: minX - p, y: minY - p, width: (maxX - minX) + p * 2, height: (maxY - minY) + p * 2)
    }

    func translated(by offset: WhiteboardPoint) -> PolygonShape {
        var c = self
        c.vertices = vertices.map { WhiteboardPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
        return c
    }
    func scaled(by factor: Double, around center: WhiteboardPoint) -> PolygonShape {
        var c = self
        c.vertices = vertices.map { v in
            WhiteboardPoint(
                x: center.x + (v.x - center.x) * factor,
                y: center.y + (v.y - center.y) * factor
            )
        }
        c.strokeWidth *= factor
        return c
    }
    mutating func move(by offset: WhiteboardPoint) {
        vertices = vertices.map { WhiteboardPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
    }
    mutating func resize(to rect: WhiteboardRect) {
        let old = boundingRect
        guard old.width > 0 && old.height > 0 else { return }
        let sx = rect.width / old.width
        let sy = rect.height / old.height
        let c = self
        let _ = self.scaled(by: (sx + sy) / 2, around: rect.center)
        // mutate
        let scaledVerts = c.vertices.map { v in
            WhiteboardPoint(
                x: rect.center.x + (v.x - old.center.x) * (sx + sy) / 2,
                y: rect.center.y + (v.y - old.center.y) * (sx + sy) / 2
            )
        }
        vertices = scaledVerts
    }
    func contains(_ point: WhiteboardPoint) -> Bool {
        if fillStyle.isVisible { return pointInPolygon(point: point) }
        // 边框：判定到每条边的距离
        for i in 0..<vertices.count {
            let a = vertices[i]
            let b = vertices[(i + 1) % vertices.count]
            if distanceToSegment(point: point, a: a, b: b) <= strokeWidth + 4 {
                return true
            }
        }
        return false
    }

    private func pointInPolygon(point: WhiteboardPoint) -> Bool {
        var inside = false
        let n = vertices.count
        guard n > 2 else { return false }
        var j = n - 1
        for i in 0..<n {
            let pi = vertices[i], pj = vertices[j]
            if (pi.y > point.y) != (pj.y > point.y) {
                let slope = (point.x - pi.x) * (pj.y - pi.y) - (pj.x - pi.x) * (point.y - pi.y)
                if slope == 0 { return true }
                if (slope < 0) != (pj.y < pi.y) { inside.toggle() }
            }
            j = i
        }
        return inside
    }
    private func distanceToSegment(point p: WhiteboardPoint, a: WhiteboardPoint, b: WhiteboardPoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = max(0, min(1, t))
        let fx = a.x + t * dx
        let fy = a.y + t * dy
        return hypot(p.x - fx, p.y - fy)
    }
}

// MARK: - 函数图 / 参数图 / 极坐标图

/// 函数图：y = f(x)
struct FunctionPlotShape: WhiteboardShape, Codable, Hashable, Identifiable {
    var id: UUID
    var formula: String
    var xMin: Double
    var xMax: Double
    var yMin: Double
    var yMax: Double
    var samples: Int
    var zIndex: Int
    var color: WhiteboardColor
    var strokeWidth: Double
    var fillStyle: FillStyle
    var rotation: Double

    init(id: UUID = UUID(), formula: String, xMin: Double = -10, xMax: Double = 10, samples: Int = 256, color: WhiteboardColor = .blue, strokeWidth: Double = 2.0) {
        self.id = id
        self.formula = formula
        self.xMin = xMin
        self.xMax = xMax
        self.yMin = -10
        self.yMax = 10
        self.samples = max(16, samples)
        self.zIndex = 0
        self.color = color
        self.strokeWidth = strokeWidth
        self.fillStyle = .none
        self.rotation = 0
    }

    var boundingRect: WhiteboardRect {
        let p = strokeWidth + 2
        return WhiteboardRect(x: xMin - p, y: yMin - p, width: (xMax - xMin) + p * 2, height: (yMax - yMin) + p * 2)
    }
    func translated(by offset: WhiteboardPoint) -> FunctionPlotShape {
        var c = self
        c.xMin += offset.x; c.xMax += offset.x
        c.yMin += offset.y; c.yMax += offset.y
        return c
    }
    func scaled(by factor: Double, around center: WhiteboardPoint) -> FunctionPlotShape {
        var c = self
        let cx = (c.xMin + c.xMax) / 2, cy = (c.yMin + c.yMax) / 2
        let newCx = center.x + (cx - center.x) * factor
        let newCy = center.y + (cy - center.y) * factor
        let w = (c.xMax - c.xMin) * factor / 2
        let h = (c.yMax - c.yMin) * factor / 2
        c.xMin = newCx - w; c.xMax = newCx + w
        c.yMin = newCy - h; c.yMax = newCy + h
        c.strokeWidth *= factor
        return c
    }
    mutating func move(by offset: WhiteboardPoint) {
        xMin += offset.x; xMax += offset.x
        yMin += offset.y; yMax += offset.y
    }
    mutating func resize(to rect: WhiteboardRect) {
        xMin = rect.x; xMax = rect.x + rect.width
        yMin = rect.y; yMax = rect.y + rect.height
    }
    func contains(_ point: WhiteboardPoint) -> Bool {
        boundingRect.contains(point)
    }

    /// 用 AlgebraEvaluator 在内部坐标系下采样，结果直接当作屏幕点绘制。
    func samplePoints() -> [WhiteboardPoint] {
        let pts = AlgebraEvaluator.sampleY(formula, variableName: "x", xRange: xMin...xMax, samples: samples)
        return pts.map { (x, y) in WhiteboardPoint(x: x, y: y) }
    }
}

/// 参数方程：x = fx(t), y = fy(t)
struct ParametricPlotShape: WhiteboardShape, Codable, Hashable, Identifiable {
    var id: UUID
    var fxFormula: String
    var fyFormula: String
    var tMin: Double
    var tMax: Double
    var samples: Int
    var zIndex: Int
    var color: WhiteboardColor
    var strokeWidth: Double
    var fillStyle: FillStyle
    var rotation: Double

    init(id: UUID = UUID(), fx: String, fy: String, tMin: Double = 0, tMax: Double = .pi * 2, samples: Int = 256, color: WhiteboardColor = .purple, strokeWidth: Double = 2.0) {
        self.id = id
        self.fxFormula = fx
        self.fyFormula = fy
        self.tMin = tMin
        self.tMax = tMax
        self.samples = max(16, samples)
        self.zIndex = 0
        self.color = color
        self.strokeWidth = strokeWidth
        self.fillStyle = .none
        self.rotation = 0
    }

    var boundingRect: WhiteboardRect {
        let pts = samplePoints()
        guard !pts.isEmpty else { return WhiteboardRect(x: 0, y: 0, width: 0, height: 0) }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        let p = strokeWidth + 2
        return WhiteboardRect(x: minX - p, y: minY - p, width: (maxX - minX) + p * 2, height: (maxY - minY) + p * 2)
    }
    func translated(by offset: WhiteboardPoint) -> ParametricPlotShape {
        var c = self
        c.tMin += offset.x; c.tMax += offset.x   // 简化：用 t 范围表达位移
        return c
    }
    func scaled(by factor: Double, around center: WhiteboardPoint) -> ParametricPlotShape {
        var c = self
        c.strokeWidth *= factor
        return c
    }
    mutating func move(by offset: WhiteboardPoint) { /* no-op */ }
    mutating func resize(to rect: WhiteboardRect) { /* no-op */ }
    func contains(_ point: WhiteboardPoint) -> Bool { false }

    func samplePoints() -> [WhiteboardPoint] {
        let pts = AlgebraEvaluator.sampleParametric(fx: fxFormula, fy: fyFormula, tRange: tMin...tMax, samples: samples)
        return pts.map { (x, y) in WhiteboardPoint(x: x, y: y) }
    }
}

/// 极坐标：r = f(θ)
struct PolarPlotShape: WhiteboardShape, Codable, Hashable, Identifiable {
    var id: UUID
    var rFormula: String
    var thetaMin: Double
    var thetaMax: Double
    var samples: Int
    var zIndex: Int
    var color: WhiteboardColor
    var strokeWidth: Double
    var fillStyle: FillStyle
    var rotation: Double

    init(id: UUID = UUID(), r: String, thetaMin: Double = 0, thetaMax: Double = .pi * 2, samples: Int = 256, color: WhiteboardColor = .orange, strokeWidth: Double = 2.0) {
        self.id = id
        self.rFormula = r
        self.thetaMin = thetaMin
        self.thetaMax = thetaMax
        self.samples = max(16, samples)
        self.zIndex = 0
        self.color = color
        self.strokeWidth = strokeWidth
        self.fillStyle = .none
        self.rotation = 0
    }

    var boundingRect: WhiteboardRect {
        let pts = samplePoints()
        guard !pts.isEmpty else { return WhiteboardRect(x: 0, y: 0, width: 0, height: 0) }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        let p = strokeWidth + 2
        return WhiteboardRect(x: minX - p, y: minY - p, width: (maxX - minX) + p * 2, height: (maxY - minY) + p * 2)
    }
    func translated(by offset: WhiteboardPoint) -> PolarPlotShape {
        var c = self
        c.thetaMin += offset.x; c.thetaMax += offset.x
        return c
    }
    func scaled(by factor: Double, around center: WhiteboardPoint) -> PolarPlotShape {
        var c = self
        c.strokeWidth *= factor
        return c
    }
    mutating func move(by offset: WhiteboardPoint) { /* no-op */ }
    mutating func resize(to rect: WhiteboardRect) { /* no-op */ }
    func contains(_ point: WhiteboardPoint) -> Bool { false }

    func samplePoints() -> [WhiteboardPoint] {
        let pts = AlgebraEvaluator.samplePolar(r: rFormula, thetaRange: thetaMin...thetaMax, samples: samples)
        return pts.map { (x, y) in WhiteboardPoint(x: x, y: y) }
    }
}

// MARK: - 测量标记

enum MeasurementKind: String, Codable {
    case length       // 两点距离
    case angle        // 三点夹角（顶点在中）
    case area         // 闭合路径 / 多边形 / 圆面积（取包围）
}

/// 测量标记（仅显示数值文本 + 引导线，不影响底层几何）
struct MeasurementMarkerShape: WhiteboardShape, Codable, Hashable, Identifiable {
    var id: UUID
    var kind: MeasurementKind
    /// 受测对象的 UUID 列表（顺序敏感：length=2、angle=3、area=1+）
    var targetIDs: [UUID]
    var position: WhiteboardPoint   // 标签锚点
    var zIndex: Int
    var color: WhiteboardColor
    var strokeWidth: Double
    var fillStyle: FillStyle
    var rotation: Double

    init(id: UUID = UUID(), kind: MeasurementKind, targetIDs: [UUID], position: WhiteboardPoint, color: WhiteboardColor = .gray, strokeWidth: Double = 1.0) {
        self.id = id
        self.kind = kind
        self.targetIDs = targetIDs
        self.position = position
        self.zIndex = 0
        self.color = color
        self.strokeWidth = strokeWidth
        self.fillStyle = .none
        self.rotation = 0
    }

    var boundingRect: WhiteboardRect {
        let half: Double = 60
        return WhiteboardRect(x: position.x - half, y: position.y - 20, width: half * 2, height: 40)
    }
    func translated(by offset: WhiteboardPoint) -> MeasurementMarkerShape {
        var c = self
        c.position = WhiteboardPoint(x: position.x + offset.x, y: position.y + offset.y)
        return c
    }
    func scaled(by factor: Double, around center: WhiteboardPoint) -> MeasurementMarkerShape {
        var c = self
        c.position = WhiteboardPoint(
            x: center.x + (position.x - center.x) * factor,
            y: center.y + (position.y - center.y) * factor
        )
        return c
    }
    mutating func move(by offset: WhiteboardPoint) {
        position = WhiteboardPoint(x: position.x + offset.x, y: position.y + offset.y)
    }
    mutating func resize(to rect: WhiteboardRect) {
        position = WhiteboardPoint(x: rect.x, y: rect.y)
    }
    func contains(_ point: WhiteboardPoint) -> Bool {
        // 标签区域命中
        let half = 60.0
        let dx = point.x - position.x, dy = point.y - position.y
        return abs(dx) <= half && abs(dy) <= 20
    }
}
