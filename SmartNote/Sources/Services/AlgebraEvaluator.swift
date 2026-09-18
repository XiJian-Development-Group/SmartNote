import Foundation

/// 数学表达式解析与求值。
///
/// - 实现：包装 Foundation `NSExpression`（macOS/iOS 原生）。
///         NSExpression 支持 + - * / % **、单变量绑定，常量 pi、内置函数
///         abs/sin/cos/tan/log(自然对数)/log10/exp/sqrt。无需第三方数学库。
/// - 用户写法兼容：
///     • `^` → `**`（指数）
///     • `ln(` → `log(`
///     • 支持变量名作为 binding key（NSMutableDictionary 注入）
final class AlgebraEvaluator {

    enum AlgebraError: Error, LocalizedError {
        case empty
        case parseFailed(String)
        case evaluationFailed(String)

        var errorDescription: String? {
            switch self {
            case .empty: return "表达式为空"
            case .parseFailed(let s): return "解析失败：\(s)"
            case .evaluationFailed(let s): return "求值失败：\(s)"
            }
        }
    }

    /// 把用户写法的运算符 / 函数名归一为 NSExpression 支持的写法。
    private static func normalize(_ formula: String) -> String {
        var f = formula
        // ^ → **
        // 字符级替换即可（NSExpression 不识别 ^；** 是其内置 power 运算）
        f = f.replacingOccurrences(of: "^", with: "**")
        // ln → log（NSExpression 的 log 默认即自然对数）
        f = f.replacingOccurrences(of: "ln(", with: "log(")
        return f
    }

    /// 单点求值
    static func evaluate(_ formula: String, variables: [String: Double]) throws -> Double {
        let trimmed = formula.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AlgebraError.empty }
        let normalized = normalize(trimmed)
        let expression: NSExpression
        do {
            expression = NSExpression(format: normalized)
        } catch {
            throw AlgebraError.parseFailed("\(error)")
        }

        let binding = NSMutableDictionary()
        for (k, v) in variables {
            binding.setValue(NSNumber(value: v), forKey: k)
        }
        let result = expression.expressionValue(with: binding, context: nil)
        guard let n = result as? NSNumber else {
            throw AlgebraError.evaluationFailed("返回类型不是数字")
        }
        return n.doubleValue
    }

    /// 函数 y = f(x) 在闭区间上的采样。失败点跳过（保留断点）。
    static func sampleY(_ formula: String, variableName: String = "x", xRange: ClosedRange<Double>, samples: Int = 256) -> [(Double, Double)] {
        guard samples >= 2 else { return [] }
        var pts: [(Double, Double)] = []
        pts.reserveCapacity(samples)
        let step = (xRange.upperBound - xRange.lowerBound) / Double(samples - 1)
        for i in 0..<samples {
            let x = xRange.lowerBound + step * Double(i)
            if let y = try? evaluate(formula, variables: [variableName: x]) {
                pts.append((x, y))
            }
        }
        return pts
    }

    /// 参数方程：x = fx(t), y = fy(t)
    static func sampleParametric(fx: String, fy: String, variableName: String = "t", tRange: ClosedRange<Double>, samples: Int = 256) -> [(Double, Double)] {
        guard samples >= 2 else { return [] }
        var pts: [(Double, Double)] = []
        pts.reserveCapacity(samples)
        let step = (tRange.upperBound - tRange.lowerBound) / Double(samples - 1)
        for i in 0..<samples {
            let t = tRange.lowerBound + step * Double(i)
            if let x = try? evaluate(fx, variables: [variableName: t]),
               let y = try? evaluate(fy, variables: [variableName: t]) {
                pts.append((x, y))
            }
        }
        return pts
    }

    /// 极坐标：r = f(θ)
    static func samplePolar(r: String, thetaRange: ClosedRange<Double>, samples: Int = 256) -> [(Double, Double)] {
        guard samples >= 2 else { return [] }
        var pts: [(Double, Double)] = []
        pts.reserveCapacity(samples)
        let step = (thetaRange.upperBound - thetaRange.lowerBound) / Double(samples - 1)
        for i in 0..<samples {
            let theta = thetaRange.lowerBound + step * Double(i)
            if let rr = try? evaluate(r, variables: ["theta": theta]) {
                let x = rr * cos(theta)
                let y = rr * sin(theta)
                pts.append((x, y))
            }
        }
        return pts
    }
}
