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
/// 数学上无定义（asin(2)、x=0 时的 1/x）返回 nan / ±inf，由采样方过滤；字面量除以 0 会在校验阶段报错。
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

    /// 三角函数输入/输出所使用的角度单位。默认使用弧度，保持白板等既有调用点行为不变。
    /// 显式单位写在数值后（30deg / 30° / 0.5rad）；反三角函数结果后的单位会明确报错。
    enum AngleUnit: Equatable {
        case radians
        case degrees

        // 兼容常见的简写写法，避免调用方因单位命名不同而产生歧义。
        static let radian = AngleUnit.radians
        static let degree = AngleUnit.degrees
        static let rad = AngleUnit.radians
        static let deg = AngleUnit.degrees
    }

    /// 编译后的表达式：给定变量表即可重复求值（采样时复用，避免逐点重复解析）
    typealias Compiled = (_ variables: [String: Double]) -> Double

    private static let maxInputLength = 512
    private static let maxRecursionDepth = 64

    // MARK: - 函数表

    private struct FunctionSpec {
        /// 允许的参数个数区间
        let arity: ClosedRange<Int>
        let apply: ([Double]) -> Double
    }

    private static func functions(for angleUnit: AngleUnit) -> [String: FunctionSpec] {
        func one(_ f: @escaping (Double) -> Double) -> FunctionSpec {
            FunctionSpec(arity: 1...1, apply: { f($0[0]) })
        }
        func two(_ f: @escaping (Double, Double) -> Double) -> FunctionSpec {
            FunctionSpec(arity: 2...2, apply: { f($0[0], $0[1]) })
        }

        let toRadians: (Double) -> Double
        let fromRadians: (Double) -> Double
        switch angleUnit {
        case .radians:
            toRadians = { $0 }
            fromRadians = { $0 }
        case .degrees:
            toRadians = { $0 * .pi / 180.0 }
            fromRadians = { $0 * 180.0 / .pi }
        }

        let table: [String: FunctionSpec] = [
            // 三角函数（默认弧度；角度模式只在边界处转换）
            "sin": one { sin(toRadians($0)) },
            "cos": one { cos(toRadians($0)) },
            "tan": one { tan(toRadians($0)) },
            "asin": one { fromRadians(asin($0)) },
            "acos": one { fromRadians(acos($0)) },
            "atan": one { fromRadians(atan($0)) },
            "sinh": one(sinh), "cosh": one(cosh), "tanh": one(tanh),
            // 对数：ln = 自然对数；log / lg / log10 = 常用对数（ISO 80000-2，且与旧版行为一致）
            "ln": one(log),
            "log": one(log10), "lg": one(log10), "log10": one(log10),
            "log2": one(log2),
            // 其它常用一元函数
            "sqrt": one(sqrt), "cbrt": one(cbrt), "abs": one(abs), "exp": one(exp),
            "floor": one(floor), "ceil": one(ceil), "round": one(round), "trunc": one(trunc),
            "fact": one(safeFactorial),
            // 二元
            "pow": two(pow), "mod": two(fmod), "atan2": two { atan2($0, $1) },
            "hypot": two(hypot),
            "min": two(min), "max": two(max)
        ]
        return table
    }

    private static func safeFactorial(_ value: Double) -> Double {
        guard value.isFinite, value >= 0, value <= 170, value.rounded() == value,
              let n = Int(exactly: value) else {
            return .nan
        }
        if n <= 1 { return 1 }
        var result = 1.0
        var index = 2
        while index <= n {
            result *= Double(index)
            index += 1
        }
        return result
    }

    private static let constants: [String: Double] = [
        "pi": .pi,
        "e": exp(1.0)   // Double 没有内建 e，用 exp(1) 等价定义
    ]

    // MARK: - 对外 API

    /// 仅做语法检查（不求值），用于插入前给出准确的错误信息。
    /// - Parameters:
    ///   - allowedVariables: 允许出现的变量名（如函数图是 `["x"]`）
    ///   - angleUnit: 三角函数使用的角度单位，默认弧度
    static func validate(
        _ formula: String,
        allowedVariables: Set<String>,
        angleUnit: AngleUnit = .radians
    ) throws {
        _ = try compile(formula, allowedVariables: allowedVariables, angleUnit: angleUnit)
    }

    /// 单点求值。语法错误抛 `parseFailed`；数学上无定义时返回 nan / ±inf。
    static func evaluate(
        _ formula: String,
        variables: [String: Double],
        angleUnit: AngleUnit = .radians
    ) throws -> Double {
        let f = try compile(
            formula,
            allowedVariables: Set(variables.keys),
            angleUnit: angleUnit
        )
        return f(variables)
    }

    /// 编译：tokenize + 递归下降解析，成功返回可重复求值的闭包。
    static func compile(
        _ formula: String,
        allowedVariables: Set<String>,
        angleUnit: AngleUnit = .radians
    ) throws -> Compiled {
        guard formula.count <= maxInputLength else {
            throw AlgebraError.parseFailed("表达式过于复杂，请简化")
        }
        let stripped = stripDefinitionPrefix(formula.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !stripped.isEmpty else { throw AlgebraError.empty }
        let tokens = try tokenize(stripped)
        try validateNoLiteralDivisionByZero(tokens)
        var parser = Parser(
            tokens: tokens,
            allowedVariables: allowedVariables,
            functions: functions(for: angleUnit),
            angleUnit: angleUnit
        )
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
        /// 数值以及显式角度单位（单位会直接归一到当前求值单位）。
        case number(Double, unit: AngleUnit?)
        case ident(String)
        case op(String)      // + - * / % ^ **
        case lparen
        case rparen
        case comma
        case end
    }

    private static func angleUnit(forSuffix suffix: String) -> AngleUnit? {
        switch suffix.lowercased() {
        case "deg", "degree", "degrees", "°":
            return .degrees
        case "rad", "radian", "radians":
            return .radians
        default:
            return nil
        }
    }

    private static func tokenize(_ source: String) throws -> [Token] {
        var tokens: [Token] = []
        var i = source.startIndex

        while i < source.endIndex {
            let c = source[i]
            if c.isWhitespace { i = source.index(after: i); continue }

            // 数字：123 / 1.5 / .5 / 1e-3；可在数值后直接写 deg、° 或 rad。
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

                // 显式角度单位属于数值 token 的一部分，而不是可被 parser 忽略的
                // 独立标识符。这样 `30foo` 会在 validate/compile 阶段直接报错。
                var unit: AngleUnit?
                var suffixStart = i
                while suffixStart < source.endIndex, source[suffixStart].isWhitespace {
                    suffixStart = source.index(after: suffixStart)
                }
                if suffixStart < source.endIndex {
                    if source[suffixStart] == "°" {
                        unit = .degrees
                        i = source.index(after: suffixStart)
                    } else if source[suffixStart].isLetter || source[suffixStart] == "_" {
                        let unitStart = suffixStart
                        var unitEnd = suffixStart
                        while unitEnd < source.endIndex,
                              source[unitEnd].isLetter || source[unitEnd].isNumber || source[unitEnd] == "_" {
                            unitEnd = source.index(after: unitEnd)
                        }
                        let suffix = String(source[unitStart..<unitEnd])
                        guard let parsed = angleUnit(forSuffix: suffix) else {
                            throw AlgebraError.parseFailed("未知角度单位 “\(suffix)”（可用 deg、° 或 rad）")
                        }
                        unit = parsed
                        i = unitEnd
                    }
                }
                tokens.append(.number(value, unit: unit))
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
            case "°":
                throw AlgebraError.parseFailed("角度单位只能写在数值后，例如 30deg")
            default:
                throw AlgebraError.parseFailed("非法字符 “\(c)”")
            }
        }
        tokens.append(.end)
        return tokens
    }

    private static func validateNoLiteralDivisionByZero(_ tokens: [Token]) throws {
        guard tokens.count > 1 else { return }
        for index in 0..<(tokens.count - 1) {
            guard case .op(let operation) = tokens[index], operation == "/" else { continue }
            if case .number(let value, _) = tokens[index + 1], value == 0 {
                throw AlgebraError.parseFailed("除数不能是 0")
            }
        }
    }

    private static func numericValue(
        _ value: Double,
        explicitUnit: AngleUnit?,
        evaluatorUnit: AngleUnit
    ) -> Double {
        guard let explicitUnit else { return value }
        switch (explicitUnit, evaluatorUnit) {
        case (.radians, .radians), (.degrees, .degrees):
            return value
        case (.degrees, .radians):
            return value * .pi / 180.0
        case (.radians, .degrees):
            return value * 180.0 / .pi
        }
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
        let functions: [String: FunctionSpec]
        let angleUnit: AngleUnit
        var index: Int = 0
        private var recursionDepth: Int = 0

        init(
            tokens: [Token],
            allowedVariables: Set<String>,
            functions: [String: FunctionSpec],
            angleUnit: AngleUnit
        ) {
            self.tokens = tokens
            self.allowedVariables = allowedVariables
            self.functions = functions
            self.angleUnit = angleUnit
        }

        private var current: Token { tokens[index] }
        private mutating func advance() { index += 1 }

        private mutating func enterRecursion() throws {
            guard recursionDepth < maxRecursionDepth else {
                throw AlgebraError.parseFailed("表达式过于复杂，请简化")
            }
            recursionDepth += 1
        }

        private mutating func leaveRecursion() {
            recursionDepth -= 1
        }

        mutating func expectEnd() throws {
            switch current {
            case .end:
                break
            case .rparen:
                throw AlgebraError.parseFailed("多余的右括号")
            case .ident(let name) where AlgebraEvaluator.angleUnit(forSuffix: name) != nil:
                throw AlgebraError.parseFailed("角度单位只能写在数值后，例如 30deg")
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
                // 每一层一元运算都进入递归计数；defer 确保异常时也会回退。
                try enterRecursion()
                defer { leaveRecursion() }
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
                // 右结合的幂运算也会形成递归链，单独计入深度。
                try enterRecursion()
                defer { leaveRecursion() }
                advance()
                let exponent = try parseUnary()   // 右结合：2^3^2 = 2^(3^2)
                return { v in Darwin.pow(base(v), exponent(v)) }
            }
            return base
        }

        private mutating func parsePrimary() throws -> Compiled {
            switch current {
            case .number(let value, let unit):
                advance()
                let normalized = AlgebraEvaluator.numericValue(
                    value,
                    explicitUnit: unit,
                    evaluatorUnit: angleUnit
                )
                return { _ in normalized }

            case .ident(let name):
                advance()
                if case .lparen = current {
                    // 函数调用
                    guard let spec = functions[name.lowercased()] else {
                        throw AlgebraError.parseFailed("未知函数 “\(name)”")
                    }
                    // 函数实参会递归回 parseExpression；函数调用本身占用一层深度。
                    try enterRecursion()
                    defer { leaveRecursion() }
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
                // 括号内递归解析表达式；离开括号时由 defer 正确回退。
                try enterRecursion()
                defer { leaveRecursion() }
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

    /// 单次曲线输出最多 256 个采样点（默认值也是 256）。
    /// 这个硬上限同时用于运行时采样和旧数据中的 `samples` 字段，避免解码后
    /// 因历史数据写入过大的值而产生不可控的计算/内存开销。
    static let maxSamples = 256

    private static func boundedSampleCount(_ samples: Int) -> Int? {
        guard samples >= 2 else { return nil }
        return min(samples, maxSamples)
    }

    /// 把均匀采样值切成连续段。非有限值会结束当前段；如果相邻有限值呈现
    /// 明显的无界跳变（例如浮点 tan 在极点两侧），也断开，避免留下假竖线。
    /// 单点段会被保留在分段结果中，调用方绘制时再过滤掉不足 2 点的段。
    private static func makeSegments(
        samples: Int,
        range: ClosedRange<Double>,
        valueAt: @escaping (Double) -> (Double, Double),
        detectVerticalJumps: Bool = false,
        scalarValueAt: ((Double) -> Double)? = nil
    ) -> [[(Double, Double)]] {
        guard let count = boundedSampleCount(samples),
              range.lowerBound.isFinite,
              range.upperBound.isFinite,
              range.upperBound > range.lowerBound else { return [] }

        var segments: [[(Double, Double)]] = []
        var current: [(Double, Double)] = []
        var previous: (Double, Double)?
        var previousParameter: Double?
        let step = (range.upperBound - range.lowerBound) / Double(count - 1)

        for index in 0..<count {
            let parameter = range.lowerBound + step * Double(index)
            let value = valueAt(parameter)
            let valid = value.0.isFinite && value.1.isFinite
            guard valid else {
                if !current.isEmpty {
                    segments.append(current)
                    current.removeAll(keepingCapacity: true)
                }
                previous = nil
                previousParameter = nil
                continue
            }

            if let previous, let previousParameter,
               detectVerticalJumps,
               hasVerticalJump(
                   from: previous,
                   to: value,
                   fromParameter: previousParameter,
                   toParameter: parameter,
                   valueAt: valueAt,
                   scalarValueAt: scalarValueAt
               ) {
                if !current.isEmpty {
                    segments.append(current)
                    current.removeAll(keepingCapacity: true)
                }
            }
            current.append(value)
            previous = value
            previousParameter = parameter
        }

        if !current.isEmpty { segments.append(current) }
        return segments
    }

    private static func hasVerticalJump(
        from previous: (Double, Double),
        to current: (Double, Double),
        fromParameter: Double,
        toParameter: Double,
        valueAt: @escaping (Double) -> (Double, Double),
        scalarValueAt: ((Double) -> Double)? = nil
    ) -> Bool {
        let dx = toParameter - fromParameter
        guard dx.isFinite, dx != 0 else { return false }

        // 只在符号变化且已有一定幅值时递归探测，避免对普通 sin 过零点做昂贵工作。
        let componentCount = scalarValueAt == nil ? 2 : 1
        for component in 0..<componentCount {
            let a: Double
            let b: Double
            let pointValue: (Double) -> Double
            if let scalarValueAt {
                a = scalarValueAt(fromParameter)
                b = scalarValueAt(toParameter)
                pointValue = scalarValueAt
            } else {
                a = component == 0 ? previous.1 : previous.0
                b = component == 0 ? current.1 : current.0
                pointValue = { point in
                    let pair = valueAt(point)
                    return component == 0 ? pair.1 : pair.0
                }
            }
            let signChanged = (a < 0 && b > 0) || (a > 0 && b < 0)
            guard signChanged, max(abs(a), abs(b)) > 1 else { continue }
            let initialPeak = max(abs(a), abs(b))

            func search(
                leftX: Double,
                rightX: Double,
                leftValue: Double,
                rightValue: Double,
                depth: Int
            ) -> Bool {
                guard depth > 0 else { return false }
                let midpoint = (leftX + rightX) / 2
                guard midpoint.isFinite, midpoint > leftX, midpoint < rightX else { return false }
                let middle = pointValue(midpoint)
                guard middle.isFinite else { return true }
                // tan 在浮点极点不会必然返回 NaN；递归看到值持续放大时视为断点。
                if abs(middle) > initialPeak * 4 || abs(middle) > 1e12 { return true }
                let leftSignChanged = (leftValue < 0 && rightValue > 0)
                    || (leftValue > 0 && rightValue < 0)
                guard leftSignChanged else { return false }
                return search(
                    leftX: leftX,
                    rightX: midpoint,
                    leftValue: leftValue,
                    rightValue: middle,
                    depth: depth - 1
                ) || search(
                    leftX: midpoint,
                    rightX: rightX,
                    leftValue: middle,
                    rightValue: rightValue,
                    depth: depth - 1
                )
            }

            if search(
                leftX: fromParameter,
                rightX: toParameter,
                leftValue: a,
                rightValue: b,
                depth: 4
            ) { return true }
        }
        return false
    }

    /// 函数 y = f(x) 的分段采样。非有限值处断开；旧的扁平 API 仍由下方方法提供。
    static func sampleYSegments(
        _ formula: String,
        variableName: String = "x",
        xRange: ClosedRange<Double>,
        samples: Int = 256,
        angleUnit: AngleUnit = .radians
    ) -> [[(Double, Double)]] {
        guard let f = try? compile(
            formula,
            allowedVariables: [variableName],
            angleUnit: angleUnit
        ) else { return [] }
        return makeSegments(
            samples: samples,
            range: xRange,
            valueAt: { x in (x, f([variableName: x])) },
            detectVerticalJumps: true
        )
    }

    /// 函数 y = f(x) 在闭区间上的扁平采样（兼容旧调用点）。
    /// 非有限值（NaN/±inf，如 x=0 时的 1/x、sqrt(-1)）跳过，避免污染包围盒与命中。
    static func sampleY(
        _ formula: String,
        variableName: String = "x",
        xRange: ClosedRange<Double>,
        samples: Int = 256,
        angleUnit: AngleUnit = .radians
    ) -> [(Double, Double)] {
        sampleYSegments(
            formula,
            variableName: variableName,
            xRange: xRange,
            samples: samples,
            angleUnit: angleUnit
        ).flatMap { $0 }
    }

    /// 参数方程：x = fx(t), y = fy(t) 的分段采样。
    static func sampleParametricSegments(
        fx: String,
        fy: String,
        variableName: String = "t",
        tRange: ClosedRange<Double>,
        samples: Int = 256,
        angleUnit: AngleUnit = .radians
    ) -> [[(Double, Double)]] {
        guard let fxCompiled = try? compile(
            fx,
            allowedVariables: [variableName],
            angleUnit: angleUnit
        ), let fyCompiled = try? compile(
            fy,
            allowedVariables: [variableName],
            angleUnit: angleUnit
        ) else { return [] }
        return makeSegments(
            samples: samples,
            range: tRange,
            valueAt: { t in
                (fxCompiled([variableName: t]), fyCompiled([variableName: t]))
            },
            detectVerticalJumps: true
        )
    }

    /// 参数方程的扁平采样（兼容旧调用点）。
    static func sampleParametric(
        fx: String,
        fy: String,
        variableName: String = "t",
        tRange: ClosedRange<Double>,
        samples: Int = 256,
        angleUnit: AngleUnit = .radians
    ) -> [(Double, Double)] {
        sampleParametricSegments(
            fx: fx,
            fy: fy,
            variableName: variableName,
            tRange: tRange,
            samples: samples,
            angleUnit: angleUnit
        ).flatMap { $0 }
    }

    /// 极坐标：r = f(θ)，输出笛卡尔坐标（数学 y 轴向上；世界坐标的翻转由调用方处理）。
    static func samplePolarSegments(
        r: String,
        thetaRange: ClosedRange<Double>,
        samples: Int = 256,
        angleUnit: AngleUnit = .radians
    ) -> [[(Double, Double)]] {
        guard let f = try? compile(
            r,
            allowedVariables: ["theta"],
            angleUnit: angleUnit
        ) else { return [] }
        let cartesianTheta: (Double) -> Double = { theta in
            switch angleUnit {
            case .radians: return theta
            case .degrees: return theta * .pi / 180.0
            }
        }
        return makeSegments(
            samples: samples,
            range: thetaRange,
            valueAt: { theta in
                let radius = f(["theta": theta])
                let angle = cartesianTheta(theta)
                return (radius * cos(angle), radius * sin(angle))
            },
            detectVerticalJumps: true,
            scalarValueAt: { theta in f(["theta": theta]) }
        )
    }

    /// 极坐标的扁平采样（兼容旧调用点）。
    static func samplePolar(
        r: String,
        thetaRange: ClosedRange<Double>,
        samples: Int = 256,
        angleUnit: AngleUnit = .radians
    ) -> [(Double, Double)] {
        samplePolarSegments(
            r: r,
            thetaRange: thetaRange,
            samples: samples,
            angleUnit: angleUnit
        ).flatMap { $0 }
    }
}
