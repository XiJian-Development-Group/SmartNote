import Foundation

/// 数学表达式解析与求值：自带 tokenizer + 递归下降 parser，不依赖 NSExpression。
///
/// 为什么弃用 Foundation `NSExpression(format:)`（本项目的原始实现）：
/// 1. 遇到非法表达式（`1+`、`sin(`、`1 2`、`()`、未知函数 `foo(x)`）抛的是 **Objective-C 异常**，
///    Swift 的 `do/catch` 根本接不住 → 用户输错一个字符就直接崩；原有的 catch 分支是不可达代码。
/// 2. 格式串解析器**不支持** `sin/cos/tan/asin/acos/atan/log10/round/min/max/pow/mod`，
///    一律抛 `Unable to parse function name` → 崩。而 `sin(x)` 正是函数图的**默认公式**。
/// 3. 裸常量 `pi`、`e` 求值返回 nil（未绑定 keypath），文档却宣称支持。
/// 4. 原实现把 `ln(` 归一成 `log(`，但 NSExpression 的 `log` 是 **以 10 为底** → `ln(x)` 算错。
///
/// 语言范围：数字（含 1e3 科学计数）、变量、常量 pi/e、一元 ±、二元 + - * / % ^（`**` 同 `^`）、
/// 括号、逗号传参；`name = …` / `x(t) = …` 这类输入前缀会被自动剥掉。
/// 数学上无定义（asin(2)、1/0）返回 nan / ±inf，不抛错，由采样方过滤。
final class AlgebraEvaluator {

    enum AlgebraError: Error, LocalizedError {
        case empty
        case parseFailed(String)
        case evaluationFailed(String)

        var errorDescription: String? {
            switch self {
            case .empty: return "表达式为空"
            case .parseFailed(let s): return "表达式无效：\(s)"
            case .evaluationFailed(let s): return "求值失败：\(s)"
            }
        }
    }

    /// 编译后的表达式：给定变量表即可重复求值（采样时复用，避免逐点重复解析）
    typealias Compiled = (_ variables: [String: Double]) -> Double

    // MARK: - 函数表

    private struct FunctionSpec {
        /// 允许的参数个数区间
        let arity: ClosedRange<Int>
        let apply: ([Double]) -> Double
    }

    private static let functions: [String: FunctionSpec] = {
        func one(_ f: @escaping (Double) -> Double) -> FunctionSpec {
            FunctionSpec(arity: 1...1, apply: { f($0[0]) })
        }
        func two(_ f: @escaping (Double, Double) -> Double) -> FunctionSpec {
            FunctionSpec(arity: 2...2, apply: { f($0[0], $0[1]) })
        }
        var table: [String: FunctionSpec] = [
            // 三角函数（弧度）
            "sin": one(sin), "cos": one(cos), "tan": one(tan),
            "asin": one(asin), "acos": one(acos), "atan": one(atan),
            "sinh": one(sinh), "cosh": one(cosh), "tanh": one(tanh),
            // 对数：ln = 自然对数；log / lg / log10 = 常用对数（ISO 80000-2，且与旧版行为一致）
            "ln": one(log),
            "log": one(log10), "lg": one(log10), "log10": one(log10),
            "log2": one(log2),
            // 其它常用一元函数
            "sqrt": one(sqrt), "cbrt": one(cbrt), "abs": one(abs), "exp": one(exp),
            "floor": one(floor), "ceil": one(ceil), "round": one(round), "trunc": one(trunc),
            // 二元
            "pow": two(pow), "mod": two(fmod), "atan2": two(atan2), "hypot": two(hypot),
            "min": two(min), "max": two(max)
        ]
        return table
    }()

    private static let constants: [String: Double] = [
        "pi": .pi,
        "e": exp(1.0)   // Double 没有内建 e，用 exp(1) 等价定义
    ]

    // MARK: - 对外 API

    /// 仅做语法检查（不求值），用于插入前给出准确的错误信息。
    /// - Parameters:
    ///   - allowedVariables: 允许出现的变量名（如函数图是 `["x"]`）
    static func validate(_ formula: String, allowedVariables: Set<String>) throws {
        _ = try compile(formula, allowedVariables: allowedVariables)
    }

    /// 单点求值。语法错误抛 `parseFailed`；数学上无定义时返回 nan / ±inf。
    static func evaluate(_ formula: String, variables: [String: Double]) throws -> Double {
        let f = try compile(formula, allowedVariables: Set(variables.keys))
        return f(variables)
    }

    /// 编译：tokenize + 递归下降解析，成功返回可重复求值的闭包。
    static func compile(_ formula: String, allowedVariables: Set<String>) throws -> Compiled {
        let stripped = stripDefinitionPrefix(formula.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !stripped.isEmpty else { throw AlgebraError.empty }
        let tokens = try tokenize(stripped)
        var parser = Parser(tokens: tokens, allowedVariables: allowedVariables)
        let root = try parser.parseExpression()
        try parser.expectEnd()
        return root
    }

    // MARK: - 输入前缀处理

    /// 剥掉 "y = sin(x)"、"r = 2*sin(5*theta)"、"x(t) = cos(t)" 这类定义式前缀。
    /// `==`、`>=` 等不是定义前缀，保持原样（随后由 tokenizer 报非法字符）。
    private static func stripDefinitionPrefix(_ raw: String) -> String {
        guard let eq = raw.firstIndex(of: "=") else { return raw }
        let after = raw.index(after: eq)
        if after < raw.endIndex, raw[after] == "=" { return raw }
        let compact = raw[raw.startIndex..<eq].filter { !$0.isWhitespace }
        let pattern = "^[A-Za-z_][A-Za-z0-9_]*(\\([A-Za-z0-9_,\\s]*\\))?$"
        guard compact.range(of: pattern, options: .regularExpression) != nil else { return raw }
        return String(raw[after...]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Tokenizer

    private enum Token: Equatable {
        case number(Double)
        case ident(String)
        case op(String)      // + - * / % ^ **
        case lparen
        case rparen
        case comma
        case end
    }

    private static func tokenize(_ source: String) throws -> [Token] {
        var tokens: [Token] = []
        var i = source.startIndex

        while i < source.endIndex {
            let c = source[i]
            if c.isWhitespace { i = source.index(after: i); continue }

            // 数字：123 / 1.5 / .5 / 1e-3
            if c.isNumber || c == "." {
                let start = i
                while i < source.endIndex, source[i].isNumber { i = source.index(after: i) }
                if i < source.endIndex, source[i] == "." {
                    i = source.index(after: i)
                    while i < source.endIndex, source[i].isNumber { i = source.index(after: i) }
                }
                if i < source.endIndex, source[i] == "e" || source[i] == "E" {
                    var j = source.index(after: i)
                    if j < source.endIndex, source[j] == "+" || source[j] == "-" { j = source.index(after: j) }
                    if j < source.endIndex, source[j].isNumber {
                        i = j
                        while i < source.endIndex, source[i].isNumber { i = source.index(after: i) }
                    }
                }
                let text = String(source[start..<i])
                guard let value = Double(text) else {
                    throw AlgebraError.parseFailed("数字格式错误：\(text)")
                }
                tokens.append(.number(value))
                continue
            }

            // 标识符
            if c.isLetter || c == "_" {
                let start = i
                while i < source.endIndex, source[i].isLetter || source[i].isNumber || source[i] == "_" {
                    i = source.index(after: i)
                }
                tokens.append(.ident(String(source[start..<i])))
                continue
            }

            switch c {
            case "+", "-", "/", "%", "^":
                tokens.append(.op(String(c)))
                i = source.index(after: i)
            case "*":
                let next = source.index(after: i)
                if next < source.endIndex, source[next] == "*" {
                    tokens.append(.op("**"))
                    i = source.index(next, offsetBy: 1)
                } else {
                    tokens.append(.op("*"))
                    i = source.index(after: i)
                }
            case "(":
                tokens.append(.lparen); i = source.index(after: i)
            case ")":
                tokens.append(.rparen); i = source.index(after: i)
            case ",":
                tokens.append(.comma); i = source.index(after: i)
            default:
                throw AlgebraError.parseFailed("非法字符 “\(c)”")
            }
        }
        tokens.append(.end)
        return tokens
    }

    // MARK: - 递归下降 parser
    //
    // expr   := term (("+" | "-") term)*
    // term   := unary (("*" | "/" | "%") unary)*
    // unary  := ("+" | "-")* power
    // power  := primary (("^" | "**") unary)?        // 右结合；-2^2 = -(2^2)
    // primary:= number | func "(" args ")" | ident | "(" expr ")"

    private struct Parser {
        let tokens: [Token]
        let allowedVariables: Set<String>
        var index: Int = 0

        init(tokens: [Token], allowedVariables: Set<String>) {
            self.tokens = tokens
            self.allowedVariables = allowedVariables
        }

        private var current: Token { tokens[index] }
        private mutating func advance() { index += 1 }

        mutating func expectEnd() throws {
            switch current {
            case .end:
                break
            case .rparen:
                throw AlgebraError.parseFailed("多余的右括号")
            default:
                throw AlgebraError.parseFailed("多余的内容")
            }
        }

        mutating func parseExpression() throws -> Compiled {
            var lhs = try parseTerm()
            while case .op(let o) = current, o == "+" || o == "-" {
                let op = o
                advance()
                let rhs = try parseTerm()
                let left = lhs
                if op == "+" {
                    lhs = { v in left(v) + rhs(v) }
                } else {
                    lhs = { v in left(v) - rhs(v) }
                }
            }
            return lhs
        }

        private mutating func parseTerm() throws -> Compiled {
            var lhs = try parseUnary()
            while case .op(let o) = current, o == "*" || o == "/" || o == "%" {
                let op = o
                advance()
                let rhs = try parseUnary()
                let left = lhs
                switch op {
                case "*": lhs = { v in left(v) * rhs(v) }
                case "/": lhs = { v in left(v) / rhs(v) }
                default:  lhs = { v in left(v).truncatingRemainder(dividingBy: rhs(v)) }
                }
            }
            return lhs
        }

        private mutating func parseUnary() throws -> Compiled {
            if case .op(let o) = current, o == "-" || o == "+" {
                advance()
                let operand = try parseUnary()
                if o == "-" {
                    return { v in -operand(v) }
                }
                return operand
            }
            return try parsePower()
        }

        private mutating func parsePower() throws -> Compiled {
            let base = try parsePrimary()
            if case .op(let o) = current, o == "^" || o == "**" {
                advance()
                let exponent = try parseUnary()   // 右结合：2^3^2 = 2^(3^2)
                return { v in Darwin.pow(base(v), exponent(v)) }
            }
            return base
        }

        private mutating func parsePrimary() throws -> Compiled {
            switch current {
            case .number(let value):
                advance()
                return { _ in value }

            case .ident(let name):
                advance()
                if case .lparen = current {
                    // 函数调用
                    guard let spec = functions[name.lowercased()] else {
                        throw AlgebraError.parseFailed("未知函数 “\(name)”")
                    }
                    advance() // 吃掉 "("
                    var args: [Compiled] = []
                    if case .rparen = current {
                        throw AlgebraError.parseFailed("函数 \(name) 缺少参数")
                    }
                    while true {
                        args.append(try parseExpression())
                        if case .comma = current { advance(); continue }
                        break
                    }
                    guard case .rparen = current else {
                        throw AlgebraError.parseFailed("函数 \(name) 缺少右括号")
                    }
                    advance()
                    guard spec.arity.contains(args.count) else {
                        let want = spec.arity.lowerBound == spec.arity.upperBound
                            ? "\(spec.arity.lowerBound)"
                            : "\(spec.arity.lowerBound)~\(spec.arity.upperBound)"
                        throw AlgebraError.parseFailed("函数 \(name) 需要 \(want) 个参数，收到 \(args.count) 个")
                    }
                    let captured = args
                    let apply = spec.apply
                    return { v in apply(captured.map { $0(v) }) }
                }

                // 变量 / 常量
                if allowedVariables.contains(name) {
                    return { v in v[name] ?? .nan }
                }
                let lower = name.lowercased()
                if let constant = constants[lower] {
                    return { _ in constant }
                }
                if let key = allowedVariables.first(where: { $0.lowercased() == lower }) {
                    return { v in v[key] ?? .nan }
                }
                throw AlgebraError.parseFailed("未知变量 “\(name)”")

            case .lparen:
                advance()
                let inner = try parseExpression()
                guard case .rparen = current else {
                    throw AlgebraError.parseFailed("缺少右括号")
                }
                advance()
                return inner

            case .op(let o):
                throw AlgebraError.parseFailed("运算符 “\(o)” 缺少运算数")
            case .rparen:
                throw AlgebraError.parseFailed("括号不匹配或运算符缺少运算数")
            case .comma:
                throw AlgebraError.parseFailed("逗号位置不正确")
            case .end:
                throw AlgebraError.parseFailed("表达式不完整")
            }
        }
    }

    // MARK: - 采样

    /// 函数 y = f(x) 在闭区间上的采样。解析失败返回 []；
    /// 非有限值（NaN/±inf，如 1/0、sqrt(-1)）跳过，避免污染包围盒与绘制。
    static func sampleY(_ formula: String, variableName: String = "x", xRange: ClosedRange<Double>, samples: Int = 256) -> [(Double, Double)] {
        guard samples >= 2, xRange.upperBound > xRange.lowerBound else { return [] }
        guard let f = try? compile(formula, allowedVariables: [variableName]) else { return [] }
        var pts: [(Double, Double)] = []
        pts.reserveCapacity(samples)
        let step = (xRange.upperBound - xRange.lowerBound) / Double(samples - 1)
        for i in 0..<samples {
            let x = xRange.lowerBound + step * Double(i)
            let y = f([variableName: x])
            if y.isFinite { pts.append((x, y)) }
        }
        return pts
    }

    /// 参数方程：x = fx(t), y = fy(t)
    static func sampleParametric(fx: String, fy: String, variableName: String = "t", tRange: ClosedRange<Double>, samples: Int = 256) -> [(Double, Double)] {
        guard samples >= 2, tRange.upperBound > tRange.lowerBound else { return [] }
        guard let fxCompiled = try? compile(fx, allowedVariables: [variableName]),
              let fyCompiled = try? compile(fy, allowedVariables: [variableName]) else { return [] }
        var pts: [(Double, Double)] = []
        pts.reserveCapacity(samples)
        let step = (tRange.upperBound - tRange.lowerBound) / Double(samples - 1)
        for i in 0..<samples {
            let t = tRange.lowerBound + step * Double(i)
            let x = fxCompiled([variableName: t])
            let y = fyCompiled([variableName: t])
            if x.isFinite, y.isFinite { pts.append((x, y)) }
        }
        return pts
    }

    /// 极坐标：r = f(θ)，输出笛卡尔坐标（数学 y 轴向上；世界坐标的翻转由调用方处理）
    static func samplePolar(r: String, thetaRange: ClosedRange<Double>, samples: Int = 256) -> [(Double, Double)] {
        guard samples >= 2, thetaRange.upperBound > thetaRange.lowerBound else { return [] }
        guard let f = try? compile(r, allowedVariables: ["theta"]) else { return [] }
        var pts: [(Double, Double)] = []
        pts.reserveCapacity(samples)
        let step = (thetaRange.upperBound - thetaRange.lowerBound) / Double(samples - 1)
        for i in 0..<samples {
            let theta = thetaRange.lowerBound + step * Double(i)
            let rr = f(["theta": theta])
            guard rr.isFinite else { continue }
            let x = rr * cos(theta)
            let y = rr * sin(theta)
            if x.isFinite, y.isFinite { pts.append((x, y)) }
        }
        return pts
    }
}
