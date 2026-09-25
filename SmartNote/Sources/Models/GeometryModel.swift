import Foundation
import SwiftUI
import CoreGraphics

// MARK: - 几何画板新增 Shape 类型
//
// 这些类型与 Whiteboard.swift 里的"传统形状"（stroke/rect/ellipse/text等）并列，
// 全部继承 WhiteboardShape 协议，便于 WhiteboardObject enum 统一建模与持久化。
// 这里集中放，避免 Whiteboard.swift 进一步膨胀。

// MARK: - 折线命中辅助

/// 点到折线 / 线段的距离，供曲线类 Shape（函数图 / 参数 / 极坐标 / 多边形）做命中判定。
enum GeometryHit {
    /// 点到线段的最短距离
    static func distanceToSegment(_ p: WhiteboardPoint, _ a: WhiteboardPoint, _ b: WhiteboardPoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = max(0, min(1, t))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// 点到折线的最短距离（点列为空时返回无穷大）
    static func distanceToPolyline(_ p: WhiteboardPoint, points: [WhiteboardPoint]) -> Double {
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else { return hypot(p.x - first.x, p.y - first.y) }
        var best = Double.infinity
        for i in 0..<(points.count - 1) {
            best = Swift.min(best, distanceToSegment(p, points[i], points[i + 1]))
            if best == 0 { return 0 }
        }
        return best
    }

    /// 点到分段折线的最短距离。单点段不参与命中，因为曲线绘制也明确忽略单点段。
    static func distanceToSegments(_ p: WhiteboardPoint, segments: [[WhiteboardPoint]]) -> Double {
        var best = Double.infinity
        for segment in segments where segment.count >= 2 {
            for i in 0..<(segment.count - 1) {
                best = Swift.min(best, distanceToSegment(p, segment[i], segment[i + 1]))
                if best == 0 { return 0 }
            }
        }
        return best
    }
}

/// 采样字段的运行时保护：保留旧数据中 2~256 的有效值，非法小值仍按无曲线处理。
private func normalizedPlotSamples(_ samples: Int) -> Int {
    min(max(16, samples), AlgebraEvaluator.maxSamples)
}

private func boundedPlotSampleCount(_ samples: Int) -> Int? {
    guard samples >= 2 else { return nil }
    return min(samples, AlgebraEvaluator.maxSamples)
}

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

    /// 归一化后的 [起始角, 终止角]：保证 end > start，跨度 ≤ 2π。
    /// 起止角相等按"整圆"处理。`contains` 与渲染都基于它，保证命中与绘制一致。
    var normalizedAngles: (start: Double, end: Double) {
        var s = startAngle
        var e = endAngle
        while e <= s { e += .pi * 2 }
        if e - s > .pi * 2 { e = s + .pi * 2 }
        return (s, e)
    }

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
        let (s, e) = normalizedAngles
        var angle = atan2(dy, dx)
        // atan2 返回 [-π, π]，把它平移到 [s, s+2π) 再与跨度比较
        while angle < s { angle += .pi * 2 }
        return angle <= e
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
        let scale = ((rect.width / old.width) + (rect.height / old.height)) / 2
        let from = old.center
        let to = rect.center
        vertices = vertices.map { v in
            WhiteboardPoint(
                x: to.x + (v.x - from.x) * scale,
                y: to.y + (v.y - from.y) * scale
            )
        }
        strokeWidth *= scale
    }
    func contains(_ point: WhiteboardPoint) -> Bool {
        if fillStyle.isVisible { return pointInPolygon(point: point) }
        // 边框：判定到每条边的距离
        guard vertices.count >= 2 else { return false }
        for i in 0..<vertices.count {
            let a = vertices[i]
            let b = vertices[(i + 1) % vertices.count]
            if GeometryHit.distanceToSegment(point, a, b) <= strokeWidth + 4 {
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
    /// 数学原点 (0,0) 对应的世界坐标；nil = 世界原点 (0,0)。
    /// 数学坐标 y 轴向上、白板世界坐标 y 轴向下，因此 worldY = origin.y - yMath。
    var origin: WhiteboardPoint?

    init(id: UUID = UUID(), formula: String, xMin: Double = -10, xMax: Double = 10, samples: Int = 256, color: WhiteboardColor = .blue, strokeWidth: Double = 2.0, origin: WhiteboardPoint? = nil) {
        self.id = id
        self.formula = formula
        self.xMin = Swift.min(xMin, xMax)
        self.xMax = Swift.max(xMin, xMax)
        self.yMin = -10
        self.yMax = 10
        self.origin = origin
        // 旧数据可能绕过 init 直接解码出很大的 samples；运行时仍会在
        // samplePoints/sampleSegments 中再次收敛到 AlgebraEvaluator.maxSamples。
        self.samples = normalizedPlotSamples(samples)
        self.zIndex = 0
        self.color = color
        self.strokeWidth = strokeWidth
        self.fillStyle = .none
        self.rotation = 0
    }

    var boundingRect: WhiteboardRect {
        let pts = samplePoints()
        guard !pts.isEmpty else {
            // 采样失败：退化为定义域窗口，保证选框仍可见
            let ox = origin?.x ?? 0, oy = origin?.y ?? 0
            let w = Swift.max(1, xMax - xMin)
            return WhiteboardRect(x: ox + xMin, y: oy - Swift.max(10, yMax), width: w, height: Swift.max(20, yMax - yMin))
        }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        let p = strokeWidth + 2
        return WhiteboardRect(x: minX - p, y: minY - p, width: (maxX - minX) + p * 2, height: (maxY - minY) + p * 2)
    }
    func translated(by offset: WhiteboardPoint) -> FunctionPlotShape {
        var c = self
        c.origin = WhiteboardPoint(x: (origin?.x ?? 0) + offset.x, y: (origin?.y ?? 0) + offset.y)
        return c
    }
    func scaled(by factor: Double, around anchor: WhiteboardPoint) -> FunctionPlotShape {
        var c = self
        let ox = origin?.x ?? 0, oy = origin?.y ?? 0
        c.origin = WhiteboardPoint(x: anchor.x + (ox - anchor.x) * factor,
                                   y: anchor.y + (oy - anchor.y) * factor)
        // y 方向由公式决定无法直接缩放；x 定义域围绕中点缩放
        let cx = (xMin + xMax) / 2
        let half = (xMax - xMin) * factor / 2
        c.xMin = cx - half
        c.xMax = cx + half
        c.strokeWidth *= factor
        return c
    }
    mutating func move(by offset: WhiteboardPoint) {
        origin = WhiteboardPoint(x: (origin?.x ?? 0) + offset.x, y: (origin?.y ?? 0) + offset.y)
    }
    mutating func resize(to rect: WhiteboardRect) {
        // 未提供手柄缩放，这里只把曲线中心对齐到目标矩形中心
        let cur = boundingRect.center
        let d = WhiteboardPoint(x: rect.center.x - cur.x, y: rect.center.y - cur.y)
        origin = WhiteboardPoint(x: (origin?.x ?? 0) + d.x, y: (origin?.y ?? 0) + d.y)
    }
    func contains(_ point: WhiteboardPoint) -> Bool {
        // 使用分段结果命中，避免把渐近线两侧的非连续点当成一条线段。
        GeometryHit.distanceToSegments(point, segments: sampleSegments()) <= strokeWidth + 5
    }

    /// 采样并映射到白板世界坐标（数学 y 轴翻转 + 原点平移）。
    /// 保持旧的扁平 API：包围盒、移动和其它需要连续点列的调用点仍可使用它。
    func samplePoints() -> [WhiteboardPoint] {
        guard xMax > xMin, let sampleCount = boundedPlotSampleCount(samples) else { return [] }
        let ox = origin?.x ?? 0
        let oy = origin?.y ?? 0
        let pts = AlgebraEvaluator.sampleY(
            formula,
            variableName: "x",
            xRange: xMin...xMax,
            samples: sampleCount
        )
        return pts.map { (x, y) in WhiteboardPoint(x: ox + x, y: oy - y) }
    }

    /// 曲线分段采样；NaN/±inf 处断开。段内仍按世界坐标返回，供 Canvas 逐段绘制。
    func sampleSegments() -> [[WhiteboardPoint]] {
        guard xMax > xMin, let sampleCount = boundedPlotSampleCount(samples) else { return [] }
        let ox = origin?.x ?? 0
        let oy = origin?.y ?? 0
        return AlgebraEvaluator.sampleYSegments(
            formula,
            variableName: "x",
            xRange: xMin...xMax,
            samples: sampleCount
        ).map { segment in
            segment.map { (x, y) in WhiteboardPoint(x: ox + x, y: oy - y) }
        }
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
    /// 数学原点 (0,0) 对应的世界坐标；nil = 世界原点。数学 y 轴向上，绘制时 y 翻转。
    var origin: WhiteboardPoint?

    init(id: UUID = UUID(), fx: String, fy: String, tMin: Double = 0, tMax: Double = .pi * 2, samples: Int = 256, color: WhiteboardColor = .purple, strokeWidth: Double = 2.0, origin: WhiteboardPoint? = nil) {
        self.id = id
        self.fxFormula = fx
        self.fyFormula = fy
        self.tMin = Swift.min(tMin, tMax)
        self.tMax = Swift.max(tMin, tMax)
        self.origin = origin
        // 旧数据可能绕过 init 直接解码出很大的 samples；运行时仍会在
        // samplePoints/sampleSegments 中再次收敛到 AlgebraEvaluator.maxSamples。
        self.samples = normalizedPlotSamples(samples)
        self.zIndex = 0
        self.color = color
        self.strokeWidth = strokeWidth
        self.fillStyle = .none
        self.rotation = 0
    }

    var boundingRect: WhiteboardRect {
        let pts = samplePoints()
        guard !pts.isEmpty else {
            return WhiteboardRect(x: origin?.x ?? 0, y: origin?.y ?? 0, width: 1, height: 1)
        }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        let p = strokeWidth + 2
        return WhiteboardRect(x: minX - p, y: minY - p, width: (maxX - minX) + p * 2, height: (maxY - minY) + p * 2)
    }
    func translated(by offset: WhiteboardPoint) -> ParametricPlotShape {
        var c = self
        c.origin = WhiteboardPoint(x: (origin?.x ?? 0) + offset.x, y: (origin?.y ?? 0) + offset.y)
        return c
    }
    func scaled(by factor: Double, around anchor: WhiteboardPoint) -> ParametricPlotShape {
        var c = self
        let ox = origin?.x ?? 0, oy = origin?.y ?? 0
        c.origin = WhiteboardPoint(x: anchor.x + (ox - anchor.x) * factor,
                                   y: anchor.y + (oy - anchor.y) * factor)
        c.strokeWidth *= factor
        return c
    }
    mutating func move(by offset: WhiteboardPoint) {
        origin = WhiteboardPoint(x: (origin?.x ?? 0) + offset.x, y: (origin?.y ?? 0) + offset.y)
    }
    mutating func resize(to rect: WhiteboardRect) {
        let cur = boundingRect.center
        let d = WhiteboardPoint(x: rect.center.x - cur.x, y: rect.center.y - cur.y)
        origin = WhiteboardPoint(x: (origin?.x ?? 0) + d.x, y: (origin?.y ?? 0) + d.y)
    }
    func contains(_ point: WhiteboardPoint) -> Bool {
        GeometryHit.distanceToSegments(point, segments: sampleSegments()) <= strokeWidth + 5
    }

    /// 旧的扁平采样 API，保留给包围盒等需要点列的逻辑。
    func samplePoints() -> [WhiteboardPoint] {
        guard tMax > tMin, let sampleCount = boundedPlotSampleCount(samples) else { return [] }
        let ox = origin?.x ?? 0
        let oy = origin?.y ?? 0
        let pts = AlgebraEvaluator.sampleParametric(
            fx: fxFormula,
            fy: fyFormula,
            tRange: tMin...tMax,
            samples: sampleCount
        )
        return pts.map { (x, y) in WhiteboardPoint(x: ox + x, y: oy - y) }
    }

    /// 参数方程的分段采样，任一坐标非有限时断开。
    func sampleSegments() -> [[WhiteboardPoint]] {
        guard tMax > tMin, let sampleCount = boundedPlotSampleCount(samples) else { return [] }
        let ox = origin?.x ?? 0
        let oy = origin?.y ?? 0
        return AlgebraEvaluator.sampleParametricSegments(
            fx: fxFormula,
            fy: fyFormula,
            tRange: tMin...tMax,
            samples: sampleCount
        ).map { segment in
            segment.map { (x, y) in WhiteboardPoint(x: ox + x, y: oy - y) }
        }
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
    /// 数学原点 (0,0) 对应的世界坐标；nil = 世界原点。数学 y 轴向上，绘制时 y 翻转。
    var origin: WhiteboardPoint?

    init(id: UUID = UUID(), r: String, thetaMin: Double = 0, thetaMax: Double = .pi * 2, samples: Int = 256, color: WhiteboardColor = .orange, strokeWidth: Double = 2.0, origin: WhiteboardPoint? = nil) {
        self.id = id
        self.rFormula = r
        self.thetaMin = Swift.min(thetaMin, thetaMax)
        self.thetaMax = Swift.max(thetaMin, thetaMax)
        self.origin = origin
        // 旧数据可能绕过 init 直接解码出很大的 samples；运行时仍会在
        // samplePoints/sampleSegments 中再次收敛到 AlgebraEvaluator.maxSamples。
        self.samples = normalizedPlotSamples(samples)
        self.zIndex = 0
        self.color = color
        self.strokeWidth = strokeWidth
        self.fillStyle = .none
        self.rotation = 0
    }

    var boundingRect: WhiteboardRect {
        let pts = samplePoints()
        guard !pts.isEmpty else {
            return WhiteboardRect(x: origin?.x ?? 0, y: origin?.y ?? 0, width: 1, height: 1)
        }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        let p = strokeWidth + 2
        return WhiteboardRect(x: minX - p, y: minY - p, width: (maxX - minX) + p * 2, height: (maxY - minY) + p * 2)
    }
    func translated(by offset: WhiteboardPoint) -> PolarPlotShape {
        var c = self
        c.origin = WhiteboardPoint(x: (origin?.x ?? 0) + offset.x, y: (origin?.y ?? 0) + offset.y)
        return c
    }
    func scaled(by factor: Double, around anchor: WhiteboardPoint) -> PolarPlotShape {
        var c = self
        let ox = origin?.x ?? 0, oy = origin?.y ?? 0
        c.origin = WhiteboardPoint(x: anchor.x + (ox - anchor.x) * factor,
                                   y: anchor.y + (oy - anchor.y) * factor)
        c.strokeWidth *= factor
        return c
    }
    mutating func move(by offset: WhiteboardPoint) {
        origin = WhiteboardPoint(x: (origin?.x ?? 0) + offset.x, y: (origin?.y ?? 0) + offset.y)
    }
    mutating func resize(to rect: WhiteboardRect) {
        let cur = boundingRect.center
        let d = WhiteboardPoint(x: rect.center.x - cur.x, y: rect.center.y - cur.y)
        origin = WhiteboardPoint(x: (origin?.x ?? 0) + d.x, y: (origin?.y ?? 0) + d.y)
    }
    func contains(_ point: WhiteboardPoint) -> Bool {
        GeometryHit.distanceToSegments(point, segments: sampleSegments()) <= strokeWidth + 5
    }

    /// 旧的扁平采样 API，保留给包围盒等需要点列的逻辑。
    func samplePoints() -> [WhiteboardPoint] {
        guard thetaMax > thetaMin, let sampleCount = boundedPlotSampleCount(samples) else { return [] }
        let ox = origin?.x ?? 0
        let oy = origin?.y ?? 0
        let pts = AlgebraEvaluator.samplePolar(
            r: rFormula,
            thetaRange: thetaMin...thetaMax,
            samples: sampleCount
        )
        return pts.map { (x, y) in WhiteboardPoint(x: ox + x, y: oy - y) }
    }

    /// 极坐标的分段采样；r 或转换后的笛卡尔坐标非有限时断开。
    func sampleSegments() -> [[WhiteboardPoint]] {
        guard thetaMax > thetaMin, let sampleCount = boundedPlotSampleCount(samples) else { return [] }
        let ox = origin?.x ?? 0
        let oy = origin?.y ?? 0
        return AlgebraEvaluator.samplePolarSegments(
            r: rFormula,
            thetaRange: thetaMin...thetaMax,
            samples: sampleCount
        ).map { segment in
            segment.map { (x, y) in WhiteboardPoint(x: ox + x, y: oy - y) }
        }
    }
}

// MARK: - 曲线 Codable 兼容与采样上限

// 这些 shape 仍沿用原来的 JSON key；这里只接管 samples 的解码归一化。
// 旧文件没有 origin 时仍按 Codable 的 optional 语义解码为 nil。
extension FunctionPlotShape {
    enum CodingKeys: String, CodingKey {
        case id, formula, xMin, xMax, yMin, yMax, samples, zIndex
        case color, strokeWidth, fillStyle, rotation, origin
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        formula = try container.decode(String.self, forKey: .formula)
        xMin = try container.decode(Double.self, forKey: .xMin)
        xMax = try container.decode(Double.self, forKey: .xMax)
        yMin = try container.decode(Double.self, forKey: .yMin)
        yMax = try container.decode(Double.self, forKey: .yMax)
        samples = normalizedPlotSamples(try container.decode(Int.self, forKey: .samples))
        zIndex = try container.decode(Int.self, forKey: .zIndex)
        color = try container.decode(WhiteboardColor.self, forKey: .color)
        strokeWidth = try container.decode(Double.self, forKey: .strokeWidth)
        fillStyle = try container.decode(FillStyle.self, forKey: .fillStyle)
        rotation = try container.decode(Double.self, forKey: .rotation)
        origin = try container.decodeIfPresent(WhiteboardPoint.self, forKey: .origin)
    }
}

extension ParametricPlotShape {
    enum CodingKeys: String, CodingKey {
        case id, fxFormula, fyFormula, tMin, tMax, samples, zIndex
        case color, strokeWidth, fillStyle, rotation, origin
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        fxFormula = try container.decode(String.self, forKey: .fxFormula)
        fyFormula = try container.decode(String.self, forKey: .fyFormula)
        tMin = try container.decode(Double.self, forKey: .tMin)
        tMax = try container.decode(Double.self, forKey: .tMax)
        samples = normalizedPlotSamples(try container.decode(Int.self, forKey: .samples))
        zIndex = try container.decode(Int.self, forKey: .zIndex)
        color = try container.decode(WhiteboardColor.self, forKey: .color)
        strokeWidth = try container.decode(Double.self, forKey: .strokeWidth)
        fillStyle = try container.decode(FillStyle.self, forKey: .fillStyle)
        rotation = try container.decode(Double.self, forKey: .rotation)
        origin = try container.decodeIfPresent(WhiteboardPoint.self, forKey: .origin)
    }
}

extension PolarPlotShape {
    enum CodingKeys: String, CodingKey {
        case id, rFormula, thetaMin, thetaMax, samples, zIndex
        case color, strokeWidth, fillStyle, rotation, origin
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        rFormula = try container.decode(String.self, forKey: .rFormula)
        thetaMin = try container.decode(Double.self, forKey: .thetaMin)
        thetaMax = try container.decode(Double.self, forKey: .thetaMax)
        samples = normalizedPlotSamples(try container.decode(Int.self, forKey: .samples))
        zIndex = try container.decode(Int.self, forKey: .zIndex)
        color = try container.decode(WhiteboardColor.self, forKey: .color)
        strokeWidth = try container.decode(Double.self, forKey: .strokeWidth)
        fillStyle = try container.decode(FillStyle.self, forKey: .fillStyle)
        rotation = try container.decode(Double.self, forKey: .rotation)
        origin = try container.decodeIfPresent(WhiteboardPoint.self, forKey: .origin)
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
