import Foundation
import Combine

private let percentMarkerPrefix = "__SMARTNOTE_PERCENT_"
private let percentMarkerSuffix = "__"

/// 高级计算器引擎。
///
/// 支持三种模式：
///   - **standard**  + - × ÷ % = ± C / MC MR M+ M- / = / % / ±
///   - **scientific**  + 上述 + sin / cos / tan / log / ln / sqrt / pow / x² / x³ / x! / π / e / ( / ) / deg-rad
///   - **programmer**  + 上述 + AND / OR / XOR / NOT / ×2 / ÷2 / 进制转换（BIN / OCT / DEC / HEX）
///
/// 实现策略：
///   - 普通表达式统一交给 AlgebraEvaluator，避免旧表达式引擎的 Objective-C 异常
///   - 程序员模式的整数表达式走 Int64 路径，不把 > 2^53 的值转换成 Double
///   - 百分号先在引擎内部变成专用标记，再由表达式 AST 展开；不会把 `%` 送给
///     AlgebraEvaluator（那里 `%` 的含义是模运算）
///   - 白板继续直接使用 AlgebraEvaluator 的默认弧度；计算器只在求值边界传入角度单位
final class CalculatorEngine: ObservableObject {

    enum Mode: String, CaseIterable, Identifiable {
        case standard
        case scientific
        case programmer
        var id: String { rawValue }
    }

    enum AngleMode: String, CaseIterable, Identifiable {
        case deg, rad
        var id: String { rawValue }
        var label: String { self == .deg ? "DEG" : "RAD" }
    }

    enum NumberBase: String, CaseIterable, Identifiable {
        case bin, oct, dec, hex
        var id: String { rawValue }
        var radix: Int {
            switch self {
            case .bin: return 2
            case .oct: return 8
            case .dec: return 10
            case .hex: return 16
            }
        }
        var label: String {
            switch self {
            case .bin: return "BIN"
            case .oct: return "OCT"
            case .dec: return "DEC"
            case .hex: return "HEX"
            }
        }
    }

    @Published var mode: Mode = .standard
    @Published var expression: String = ""
    @Published var display: String = "0"
    @Published var history: String = ""
    @Published var angleMode: AngleMode = .deg
    @Published var numberBase: NumberBase = .dec
    @Published var lastError: String?

    /// 内存。memoryInteger 保留整数的原始值，避免大整数在内存键上经过 Double。
    @Published private(set) var memory: Double = 0
    @Published private(set) var hasMemory: Bool = false

    private var memoryInteger: Int64?
    private var lastResult: Double?
    private var lastIntegerResult: Int64?

    /// 上一次等号结果显示在 display 上时，下一次数字输入应替换它。
    private var replacingDisplay = false
    /// display 已经是 expression 的一部分（关闭括号或待求值的百分号标记）。
    private var displayAlreadyInExpression = false
    /// false 表示刚按过运算符或左括号，display 中的 0 只是占位符。
    private var hasCurrentInput = true

    private var percentMarkers: [String: String] = [:]
    private var nextPercentMarkerID = 0

    private let maxInputLength = 512
    private let maxSafeInteger: Int64 = 9_007_199_254_740_991

    // MARK: - 数字与小数点

    /// 数字按钮。
    func appendDigit(_ digit: String) {
        guard !digit.isEmpty else { return }

        if mode == .programmer, !isValidDigit(digit, base: numberBase) {
            lastError = "当前进制不支持该字符"
            return
        }

        // 错误状态下的第一个新数字开始一次新的计算，而不是继续使用坏的操作数。
        if lastError != nil {
            resetAfterError()
        }

        if displayAlreadyInExpression {
            // 括号或百分号表达式已经完整；直接输入新数字时开始一次新的计算。
            beginNewInput(with: digit)
        } else if replacingDisplay {
            expression = ""
            display = digit
            replacingDisplay = false
            displayAlreadyInExpression = false
            hasCurrentInput = true
        } else {
            if display.isEmpty || display == "0" {
                display = digit
            } else {
                display += digit
            }
            hasCurrentInput = true
        }

        guard display.count <= maxInputLength else {
            lastError = "表达式过于复杂，请简化"
            return
        }

        // 立即告诉用户输入已经超过 Int64；显示文本仍保留，方便定位问题。
        if mode == .programmer,
           case .outOfRange = parseIntegerText(display, base: numberBase) {
            lastError = "超出范围"
        }
    }

    /// 小数点：程序员模式不允许。
    func appendDot() {
        guard mode != .programmer else { return }
        if lastError != nil {
            resetAfterError()
        }

        if displayAlreadyInExpression || replacingDisplay {
            beginNewInput(with: "0.")
        } else if display.isEmpty {
            display = "0."
        } else if !display.contains(".") {
            if display == "0" {
                display = "0."
            } else {
                display += "."
            }
        }
        replacingDisplay = false
        displayAlreadyInExpression = false
        hasCurrentInput = true
    }

    // MARK: - 操作符

    /// 操作符按钮。百分号和幂按钮在这里分流，不把它们拼成普通二元表达式。
    func appendOperator(_ op: String) {
        let trimmedOp = op.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOp.isEmpty else { return }

        switch trimmedOp {
        case "=":
            evaluate()
            return
        case "%":
            applyPercent()
            return
        case "√":
            applyFunction("sqrt")
            return
        case "n!", "!":
            applyFunction("fact")
            return
        case "x²", "^2":
            applyFunction("sqr")
            return
        case "x³", "^3":
            applyFunction("cube")
            return
        case "1/x":
            applyFunction("inv")
            return
        case "(":
            appendOpeningParenthesis()
            return
        case ")":
            appendClosingParenthesis()
            return
        default:
            break
        }

        // π/e 按钮以常量形式进入引擎；在空表达式或操作符后应填入当前操作数。
        let trimmedExpression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        let endsWithOperator = trimmedExpression.last.map {
            "+-*/%^(".contains($0)
        } ?? false
        let constantText: String? = if trimmedOp == "pi" {
            String(Double.pi)
        } else if trimmedOp == "e" {
            String(M_E)
        } else {
            trimmedOp
        }
        if let constantText, let constant = Double(constantText), constant.isFinite,
           displayAlreadyInExpression || trimmedExpression.isEmpty || endsWithOperator || trimmedExpression.hasSuffix("(") {
            if displayAlreadyInExpression {
                expression = ""
                displayAlreadyInExpression = false
            }
            display = formatNumber(constant)
            guard lastError == nil else { return }
            replacingDisplay = false
            hasCurrentInput = true
            return
        }

        guard lastError == nil else { return }
        appendBinaryOperator(trimmedOp)
    }

    private func appendBinaryOperator(_ op: String) {
        let operatorText: String
        switch op {
        case "mod":
            operatorText = " % "
        case "^", "**":
            operatorText = " ^ "
        case "×":
            operatorText = " * "
        case "÷":
            operatorText = " / "
        case "−":
            operatorText = " - "
        default:
            operatorText = " \(op) "
        }

        if displayAlreadyInExpression {
            // 关闭括号或百分号标记已经写入 expression，不能再把占位 0 拼进去。
            expression += operatorText
        } else {
            guard hasCurrentInput else {
                lastError = "运算符缺少操作数"
                return
            }
            guard let operand = currentOperandLiteral() else { return }
            expression += operand + operatorText
        }

        display = "0"
        hasCurrentInput = false
        replacingDisplay = false
        displayAlreadyInExpression = false
        history = expression
        lastError = nil
    }

    private func appendOpeningParenthesis() {
        guard lastError == nil else { return }

        let trimmedExpression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        let endsWithOperator = trimmedExpression.last.map {
            "+-*/%^(".contains($0)
        } ?? false

        if !trimmedExpression.isEmpty,
           !trimmedExpression.hasSuffix("("),
           !endsWithOperator {
            guard let operand = currentOperandLiteral() else { return }
            expression += operand + " * "
        }
        expression += "("
        display = "0"
        hasCurrentInput = false
        replacingDisplay = false
        displayAlreadyInExpression = false
        history = expression
        lastError = nil
    }

    private func appendClosingParenthesis() {
        guard lastError == nil else { return }

        if displayAlreadyInExpression {
            expression += ")"
        } else {
            guard hasCurrentInput, let operand = currentOperandLiteral() else {
                lastError = "右括号缺少操作数"
                return
            }
            expression += operand + ")"
        }

        display = "0"
        hasCurrentInput = false
        replacingDisplay = false
        displayAlreadyInExpression = true
        history = expression
        lastError = nil
    }

    /// 百分号按钮。规则（a 是当前加/减操作的左值，b 是当前操作数）：
    /// a + b% = a + a*b/100，a - b% = a - a*b/100，
    /// a × b% = a*b/100，a ÷ b% = a/(b/100)，单独的 b% = b/100。
    /// 标记只存在于 CalculatorEngine 内部，绝不会作为 `%` 运算符进入 AlgebraEvaluator；
    /// 因此 AlgebraEvaluator 中的 `%` 仍然明确表示模运算。
    func applyPercent() {
        guard mode != .programmer else {
            lastError = "程序员模式不支持百分号"
            return
        }
        guard lastError == nil else { return }

        if displayAlreadyInExpression,
           let oldMarker = trailingPercentMarker(in: expression) {
            // 连续按百分号时，把当前显示的 b/100 再次作为新的 b。
            expression.removeLast(oldMarker.count)
            removePercentMarker(oldMarker)
        } else if displayAlreadyInExpression {
            lastError = "请先完成当前括号表达式"
            return
        }

        guard hasCurrentInput || replacingDisplay,
              let inputLiteral = currentOperandLiteral(),
              let inputValue = Double(inputLiteral) else {
            lastError = "无效的数字"
            return
        }

        let pending = pendingOperatorAndLeft(in: expression)
        if shouldResolvePercentImmediately(pending) {
            do {
                let result: Double
                let historyText: String
                if let pending, let left = pending.left, !left.isEmpty {
                    let base = try evaluateStandardText(left)
                    switch pending.op {
                    case "+":
                        result = base + base * inputValue / 100.0
                    case "-":
                        result = base - base * inputValue / 100.0
                    case "*":
                        result = base * inputValue / 100.0
                    case "/":
                        result = base / (inputValue / 100.0)
                    default:
                        result = inputValue / 100.0
                    }
                    historyText = "\(left) \(pending.op) \(inputLiteral)% = \(formatNumber(result))"
                } else {
                    result = inputValue / 100.0
                    historyText = "\(inputLiteral)% = \(formatNumber(result))"
                }
                commitDoubleResult(result, history: historyText)
                percentMarkers.removeAll()
                nextPercentMarkerID = 0
            } catch {
                lastError = errorMessageForEvaluation(error)
            }
            return
        }

        // 在含有低优先级运算的表达式中延迟展开，保证 200+10×10% 按乘法优先级计算。
        let marker = makePercentMarker(value: inputLiteral)
        let trimmedExpression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        let endsWithOperator = trimmedExpression.last.map { "+-*/%^".contains($0) } ?? false
        if expression.isEmpty {
            expression = marker
        } else if endsWithOperator {
            expression += marker
        } else {
            // 对已经完成的表达式按百分号，视作把当前显示值作为百分比操作数。
            expression += " * " + marker
        }

        display = formatNumber(inputValue / 100.0)
        if lastError != nil { return }

        history = display
        hasCurrentInput = true
        replacingDisplay = true
        displayAlreadyInExpression = true
    }

    private func pendingOperatorAndLeft(
        in text: String
    ) -> (op: String, left: String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, "+-*/%^".contains(last) else { return nil }
        let left = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(last), left.isEmpty ? nil : left)
    }

    private func shouldResolvePercentImmediately(
        _ pending: (op: String, left: String?)?
    ) -> Bool {
        guard let pending else { return true }
        guard let left = pending.left else { return false }
        switch pending.op {
        case "+", "-":
            return true
        case "*", "/":
            return !containsTopLevelAdditionOrSubtraction(left)
        default:
            return false
        }
    }

    private func containsTopLevelAdditionOrSubtraction(_ text: String) -> Bool {
        var depth = 0
        var previous: Character?
        for character in text {
            if character == "(" || character == "[" || character == "{" {
                depth += 1
            } else if character == ")" || character == "]" || character == "}" {
                depth = max(0, depth - 1)
            } else if depth == 0, character == "+" || character == "-" {
                if let previous, !"+-*/^(".contains(previous) {
                    return true
                }
            }
            if !character.isWhitespace {
                previous = character
            }
        }
        return false
    }

    private func evaluateStandardText(_ text: String) throws -> Double {
        let normalized = try normalizeExpression(text)
        let tokens = try CalculationTokenizer.tokenize(
            normalized,
            programmerBase: nil,
            markerValues: percentMarkers
        )
        var parser = CalculationParser(tokens: tokens)
        let node = try parser.parse()
        let expanded = expandPercentExpression(node)
        var variables: [String: Double] = [:]
        if let ans = lastResult { variables["ans"] = ans }
        return try AlgebraEvaluator.evaluate(
            expanded,
            variables: variables,
            angleUnit: angleMode == .deg ? .degrees : .radians
        )
    }

    private func makePercentMarker(value: String) -> String {
        let id = String(nextPercentMarkerID)
        nextPercentMarkerID += 1
        let token = percentMarkerPrefix + id + percentMarkerSuffix
        percentMarkers[id] = value
        return token
    }

    private func removePercentMarker(_ token: String) {
        guard token.hasPrefix(percentMarkerPrefix),
              token.hasSuffix(percentMarkerSuffix) else { return }
        let start = token.index(token.startIndex, offsetBy: percentMarkerPrefix.count)
        let end = token.index(token.endIndex, offsetBy: -percentMarkerSuffix.count)
        percentMarkers.removeValue(forKey: String(token[start..<end]))
    }

    private func trailingPercentMarker(in text: String) -> String? {
        percentMarkers.keys
            .map({ percentMarkerPrefix + $0 + percentMarkerSuffix })
            .first(where: { text.hasSuffix($0) })
    }

    // MARK: - 一元函数与幂

    /// 一元函数（科学模式）。x²/x³ 也走这里，保证它们永远不是二元操作。
    func applyFunction(_ fn: String) {
        guard lastError == nil else { return }
        guard prepareUnaryInput() else { return }

        let inputText = display
        if mode == .programmer {
            switch parseIntegerText(display, base: numberBase) {
            case .value(let integer):
                do {
                    let result: Int64
                    switch fn {
                    case "sqr":
                        result = try checkedSquare(integer)
                    case "cube":
                        result = try checkedCube(integer)
                    case "neg":
                        result = try checkedNegate(integer)
                    case "abs":
                        result = try checkedAbs(integer)
                    default:
                        lastError = "程序员模式不支持该函数"
                        return
                    }
                    commitIntegerResult(
                        result,
                        history: unaryHistory(fn: fn, input: inputText)
                    )
                } catch {
                    lastError = integerErrorMessage(for: error)
                }
            case .outOfRange:
                lastError = "超出范围"
            case .invalid:
                lastError = "无效的整数"
            }
            return
        }

        guard let value = numericDisplayValue() else {
            lastError = "无效的数字"
            return
        }

        let result: Double
        switch fn {
        case "sin", "cos", "tan", "log", "ln", "sqrt", "abs":
            do {
                result = try evaluateAtom(fn, value: value)
            } catch {
                lastError = errorMessage(for: error)
                return
            }
        case "sqr":
            result = value * value
        case "cube":
            result = value * value * value
        case "fact":
            guard isValidFactorialArgument(value) else {
                lastError = "阶乘参数必须是 0~170 的整数"
                return
            }
            do {
                result = try evaluateAtom("fact", value: value)
            } catch {
                lastError = errorMessage(for: error)
                return
            }
        case "inv":
            result = value == 0 ? .nan : 1 / value
        case "neg":
            result = -value
        default:
            result = value
        }

        commitDoubleResult(result, history: unaryHistory(fn: fn, input: inputText))
    }

    private func prepareUnaryInput() -> Bool {
        if displayAlreadyInExpression {
            if let marker = trailingPercentMarker(in: expression) {
                // 百分号已经显示了 b/100；后续一元函数作用于这个显示值。
                expression.removeLast(marker.count)
                removePercentMarker(marker)
                displayAlreadyInExpression = false
                replacingDisplay = true
                hasCurrentInput = true
                return true
            }
            lastError = "请先完成当前括号表达式"
            return false
        }
        guard hasCurrentInput || replacingDisplay else {
            lastError = "无效的数字"
            return false
        }
        return true
    }

    private func unaryHistory(fn: String, input: String) -> String {
        if fn == "sqr" { return "\(input)^2 = \(display)" }
        if fn == "cube" { return "\(input)^3 = \(display)" }
        if fn == "neg" { return "-\(input) = \(display)" }
        return "\(fn)(\(input)) = \(display)"
    }

    // MARK: - 进制转换

    /// 进制转换：仅程序员模式。只接受可精确表示的 Int64。
    func convertBase(to base: NumberBase) {
        guard mode == .programmer else { return }
        switch parseIntegerText(display, base: numberBase) {
        case .value(let value):
            display = formatInteger(value, base: base)
            numberBase = base
            lastError = nil
            replacingDisplay = true
            displayAlreadyInExpression = false
            hasCurrentInput = true
        case .outOfRange:
            lastError = "超出范围"
        case .invalid:
            lastError = "无法转换该整数"
        }
    }

    /// 取得当前整数（如 1024）— 程序员模式专用。
    func currentIntegerValue() -> Int {
        switch parseIntegerText(display, base: numberBase) {
        case .value(let value):
            guard let result = Int(exactly: value) else {
                lastError = "超出范围"
                return 0
            }
            lastError = nil
            return result
        case .outOfRange:
            lastError = "超出范围"
            return 0
        case .invalid:
            lastError = "无效的整数"
            return 0
        }
    }

    // MARK: - 位运算

    /// 位运算：op 为 AND/OR/XOR/NOT/MUL2/DIV2。
    ///
    /// UI 将原来的 << / >> 明确改成 ×2 / ÷2，避免把固定一位的运算伪装成可输入移位量。
    /// 仍提供 SHL/SHR 兼容别名；它们分别表示 ×2/÷2，不会偷偷接受其它移位量。
    func applyBitwise(_ op: String) {
        guard mode == .programmer else { return }
        guard let lhs = integerValue(from: display, base: numberBase) else {
            lastError = integerParseErrorMessage(for: display, base: numberBase)
            return
        }

        let normalizedOp: String
        switch op {
        case "MUL2", "SHL": normalizedOp = "MUL2"
        case "DIV2", "SHR": normalizedOp = "DIV2"
        case "AND", "OR", "XOR", "NOT": normalizedOp = op
        default: return
        }

        do {
            let result: Int64
            var rhs = lhs
            if ["AND", "OR", "XOR"].contains(normalizedOp),
               let previous = lastIntegerResult {
                rhs = previous
            }

            switch normalizedOp {
            case "NOT":
                result = ~lhs
            case "MUL2":
                result = try checkedMultiply(lhs, 2)
            case "DIV2":
                result = lhs / 2
            case "AND":
                result = lhs & rhs
            case "OR":
                result = lhs | rhs
            case "XOR":
                result = lhs ^ rhs
            default:
                return
            }

            let label: String
            let historyText: String
            switch normalizedOp {
            case "MUL2":
                label = "×2"
                historyText = "\(display) ×2 = \(formatInteger(result, base: numberBase))"
            case "DIV2":
                label = "÷2"
                historyText = "\(display) ÷2 = \(formatInteger(result, base: numberBase))"
            default:
                label = normalizedOp
                historyText = "\(display) \(label) \(formatInteger(rhs, base: numberBase)) = \(formatInteger(result, base: numberBase))"
            }
            commitIntegerResult(result, history: historyText)
        } catch {
            lastError = integerErrorMessage(for: error)
        }
    }

    /// 如果其它调用方确实需要“按指定数量移位”，使用这个明确的 API。
    /// Swift 对 >= 64 的移位会按机器字长掩码处理，因此这里主动拒绝，避免静默得到错误值。
    func applyBitwise(_ op: String, shiftAmount: Int) {
        guard op == "SHL" || op == "SHR" else {
            applyBitwise(op)
            return
        }
        guard shiftAmount >= 0, shiftAmount < 64 else {
            lastError = "移位量必须是 0~63"
            return
        }
        guard mode == .programmer else { return }
        guard let lhs = integerValue(from: display, base: numberBase) else {
            lastError = integerParseErrorMessage(for: display, base: numberBase)
            return
        }

        let result = op == "SHL"
            ? lhs << Int64(shiftAmount)
            : lhs >> Int64(shiftAmount)
        let label = op == "SHL" ? "<<" : ">>"
        let historyText = "\(display) \(label) \(shiftAmount) = \(formatInteger(result, base: numberBase))"
        commitIntegerResult(result, history: historyText)
    }

    /// 语义明确的移位入口，供非 UI 调用方使用。
    func applyShift(_ op: String, amount: Int) {
        applyBitwise(op, shiftAmount: amount)
    }

    // MARK: - 等号

    /// 等号。
    func evaluate() {
        guard lastError == nil else { return }

        let trimmedExpression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedExpression.isEmpty {
            evaluateCurrentValue()
            return
        }

        var rawExpression = expression
        let endsWithPendingOperand = trimmedExpression.last.map {
            "+-*/%^(".contains($0)
        } ?? false
        let currentZeroIsPlaceholder = display == "0" && !endsWithPendingOperand
        if hasCurrentInput && !displayAlreadyInExpression && !currentZeroIsPlaceholder {
            guard let operand = currentOperandLiteral() else { return }
            rawExpression += operand
        }
        guard rawExpression.count <= maxInputLength else {
            lastError = "表达式过于复杂，请简化"
            history = rawExpression
            return
        }

        let normalized: String
        let node: CalculationNode
        do {
            normalized = try normalizeExpression(rawExpression)
            let tokens = try CalculationTokenizer.tokenize(
                normalized,
                programmerBase: mode == .programmer ? numberBase : nil,
                markerValues: percentMarkers
            )
            var parser = CalculationParser(tokens: tokens)
            node = try parser.parse()
        } catch {
            lastError = errorMessage(for: error)
            history = displayHistoryExpression(rawExpression)
            return
        }

        do {
            if mode == .programmer {
                // 程序员模式完全走 Int64，避免任何 Double 往返导致 > 2^53 丢精度。
                let result = try evaluateProgrammerNode(node)
                let historyText = displayHistoryExpression(normalized)
                let resultText = formatInteger(result, base: numberBase)
                finishResult(
                    displayText: resultText,
                    integerResult: result,
                    doubleResult: nil,
                    history: "\(historyText) = \(resultText)"
                )
            } else {
                let expanded = expandPercentExpression(node)
                var variables: [String: Double] = [:]
                if let ans = lastResult {
                    variables["ans"] = ans
                }
                let angleUnit: AlgebraEvaluator.AngleUnit = angleMode == .deg ? .degrees : .radians
                let result = try AlgebraEvaluator.evaluate(
                    expanded,
                    variables: variables,
                    angleUnit: angleUnit
                )
                if result.isNaN, normalized.lowercased().contains("fact(") {
                    lastError = "阶乘参数必须是 0~170 的整数"
                    history = displayHistoryExpression(normalized)
                    return
                }
                let historyText = displayHistoryExpression(normalized)
                commitDoubleResult(
                    result,
                    history: "\(historyText) = \(formatNumber(result))"
                )
            }
            percentMarkers.removeAll()
            nextPercentMarkerID = 0
        } catch {
            lastError = errorMessageForEvaluation(error)
            history = displayHistoryExpression(normalized)
        }
    }

    private func evaluateCurrentValue() {
        // 连续按等号只是重复显示已经完成的结果，不重新拼接旧表达式或旧 lastResult。
        if replacingDisplay, expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        guard hasCurrentInput || replacingDisplay else {
            lastError = "表达式不完整"
            return
        }
        if mode == .programmer {
            guard let value = integerValue(from: display, base: numberBase) else {
                lastError = integerParseErrorMessage(for: display, base: numberBase)
                return
            }
            let text = formatInteger(value, base: numberBase)
            finishResult(
                displayText: text,
                integerResult: value,
                doubleResult: nil,
                history: "\(display) = \(text)"
            )
        } else {
            guard let value = Double(display) else {
                lastError = "无效的数字"
                return
            }
            commitDoubleResult(value, history: "\(display) = \(formatNumber(value))")
        }
    }

    // MARK: - 清理、退格与符号

    /// 清空。
    func clear() {
        expression = ""
        display = "0"
        history = ""
        lastResult = nil
        lastIntegerResult = nil
        replacingDisplay = false
        displayAlreadyInExpression = false
        hasCurrentInput = true
        lastError = nil
        percentMarkers.removeAll()
        nextPercentMarkerID = 0
    }

    /// 退格。
    func backspace() {
        guard lastError == nil else {
            clear()
            return
        }
        if displayAlreadyInExpression || replacingDisplay {
            clear()
            return
        }
        if !display.isEmpty && display != "0" {
            display.removeLast()
            if display.isEmpty || display == "-" {
                display = "0"
            }
        }
    }

    /// 切换 +/- 号。
    func toggleSign() {
        guard lastError == nil else { return }
        guard prepareUnaryInput() else { return }

        if mode == .programmer, let integer = integerValue(from: display, base: numberBase) {
            do {
                let result = try checkedNegate(integer)
                commitIntegerResult(result, history: "-\(display) = \(formatInteger(result, base: numberBase))")
            } catch {
                lastError = integerErrorMessage(for: error)
            }
            return
        }

        guard let value = Double(display) else {
            lastError = "无效的数字"
            return
        }
        commitDoubleResult(-value, history: "-\(display) = \(formatNumber(-value))")
    }

    private func beginNewInput(with text: String) {
        expression = ""
        display = text
        replacingDisplay = false
        displayAlreadyInExpression = false
        hasCurrentInput = true
        percentMarkers.removeAll()
        nextPercentMarkerID = 0
    }

    private func resetAfterError() {
        expression = ""
        display = "0"
        history = ""
        lastError = nil
        replacingDisplay = false
        displayAlreadyInExpression = false
        hasCurrentInput = true
        percentMarkers.removeAll()
        nextPercentMarkerID = 0
    }

    // MARK: - 内存

    func memoryClear() {
        memory = 0
        memoryInteger = nil
        hasMemory = false
        lastError = nil
    }

    func memoryRecall() {
        if displayAlreadyInExpression, let marker = trailingPercentMarker(in: expression) {
            expression.removeLast(marker.count)
            removePercentMarker(marker)
        }

        // 在“当前值”位置按 MR，开始使用记忆值；在运算符后按 MR，则保留待求值表达式。
        let trimmedExpression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        let endsWithOperator = trimmedExpression.last.map { "+-*/%^".contains($0) } ?? false
        if !trimmedExpression.isEmpty && !endsWithOperator {
            expression = ""
        }

        if mode == .programmer, let integer = memoryInteger {
            display = formatInteger(integer, base: numberBase)
            lastError = nil
        } else if let integer = memoryInteger {
            display = String(integer)
            lastError = nil
        } else if hasMemory {
            display = formatNumber(memory)
            guard lastError == nil else { return }
        } else {
            display = "0"
            lastError = nil
        }
        hasCurrentInput = true
        replacingDisplay = true
        displayAlreadyInExpression = false
    }

    func memoryAdd() {
        applyMemoryOperation(add: true)
    }

    func memorySubtract() {
        applyMemoryOperation(add: false)
    }

    private func applyMemoryOperation(add: Bool) {
        if mode == .programmer {
            switch parseIntegerText(display, base: numberBase) {
            case .value(let integer):
                updateMemoryInteger(integer, add: add)
            case .outOfRange:
                lastError = "超出范围"
            case .invalid:
                lastError = "无效的内存操作数"
            }
            return
        }

        if let rawInteger = Int64(display.trimmingCharacters(in: .whitespacesAndNewlines)) {
            updateMemoryInteger(rawInteger, add: add)
            return
        }
        guard let value = Double(display), value.isFinite else {
            lastError = "无效的内存操作数"
            return
        }
        if let integer = integerOperand(value) {
            updateMemoryInteger(integer, add: add)
            return
        }

        if add {
            memory += value
        } else {
            memory -= value
        }
        memoryInteger = nil
        hasMemory = true
        lastError = nil
    }

    private func updateMemoryInteger(_ integer: Int64, add: Bool) {
        do {
            let result = add
                ? try checkedAdd(memoryInteger ?? 0, integer)
                : try checkedSubtract(memoryInteger ?? 0, integer)
            memoryInteger = result
            memory = safeDouble(from: result) ?? 0
            hasMemory = true
            lastError = nil
        } catch {
            lastError = integerErrorMessage(for: error)
        }
    }

    private func integerOperand(_ value: Double) -> Int64? {
        guard value.isFinite,
              value.rounded() == value,
              value > -9_223_372_036_854_775_808.0,
              value < 9_223_372_036_854_775_808.0 else {
            return nil
        }
        return Int64(exactly: value.rounded())
    }

    // MARK: - 数字格式化与整数解析

    /// 数字格式化。
    func formatNumber(_ value: Double, base: NumberBase? = nil) -> String {
        if !value.isFinite {
            return value.isNaN ? "NaN" : (value > 0 ? "+∞" : "-∞")
        }

        let useBase = base ?? (mode == .programmer ? numberBase : nil)
        if let useBase {
            guard value.rounded() == value else {
                lastError = "程序员模式只支持整数"
                return "无效"
            }
            // Double 无法可靠表示 > 2^53 的任意 Int64；精确值必须走 Int64 路径。
            guard value > -9_223_372_036_854_775_808.0,
                  value < 9_223_372_036_854_775_808.0,
                  value >= -9_007_199_254_740_992.0,
                  value <= 9_007_199_254_740_992.0 else {
                lastError = "超出范围"
                return "超出范围"
            }
            let integer = Int64(value)
            return formatInteger(integer, base: useBase)
        }

        // 整数结果使用完整十进制文本；即使 Double 本身已经近似，也不会显示成
        // 无法重新解析的科学计数法。非整数极大值仍可用科学计数法。
        if value.rounded() == value, abs(value) >= 1e15 {
            return String(format: "%.0f", value)
        }
        if abs(value) >= 1e15 || (abs(value) > 0 && abs(value) < 1e-6) {
            return String(format: "%.6e", value)
        }

        let text = String(format: "%.10f", value)
        if text.contains(".") {
            var trimmed = text
            while trimmed.hasSuffix("0") { trimmed.removeLast() }
            if trimmed.hasSuffix(".") { trimmed.removeLast() }
            return trimmed
        }
        return text
    }

    private func commitDoubleResult(_ value: Double, history: String) {
        lastError = nil
        let text = formatNumber(value)
        guard lastError == nil else { return }
        finishResult(
            displayText: text,
            integerResult: nil,
            doubleResult: value.isFinite ? value : nil,
            history: history
        )
    }

    private func commitIntegerResult(_ value: Int64, history: String) {
        finishResult(
            displayText: formatInteger(value, base: mode == .programmer ? numberBase : .dec),
            integerResult: value,
            doubleResult: safeDouble(from: value),
            history: history
        )
    }

    private func finishResult(
        displayText: String,
        integerResult: Int64?,
        doubleResult: Double?,
        history: String
    ) {
        display = displayText
        expression = ""
        hasCurrentInput = true
        replacingDisplay = true
        displayAlreadyInExpression = false
        lastIntegerResult = integerResult
        lastResult = doubleResult
        lastError = nil
        self.history = history
    }

    private func safeDouble(from value: Int64) -> Double? {
        guard value >= -maxSafeInteger, value <= maxSafeInteger else { return nil }
        return Double(value)
    }

    private func formatInteger(_ value: Int64, base: NumberBase) -> String {
        switch base {
        case .bin:
            return String(value, radix: 2)
        case .oct:
            return String(value, radix: 8)
        case .hex:
            return String(value, radix: 16).uppercased()
        case .dec:
            return String(value)
        }
    }

    private func currentOperandLiteral() -> String? {
        guard hasCurrentInput || replacingDisplay else { return nil }
        let text = display.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if mode == .programmer {
            switch parseIntegerText(text, base: numberBase) {
            case .value:
                return text
            case .outOfRange:
                lastError = "超出范围"
                return nil
            case .invalid:
                lastError = "无效的整数"
                return nil
            }
        }
        return text
    }

    private func numericDisplayValue() -> Double? {
        let text = display.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Double(text) {
            return value
        }
        if text.hasSuffix(".") {
            return Double(text + "0")
        }
        guard mode == .programmer,
              let integer = integerValue(from: text, base: numberBase) else {
            return nil
        }
        return Double(integer)
    }

    private enum IntegerParseResult {
        case value(Int64)
        case outOfRange
        case invalid
    }

    private func integerValue(from text: String, base: NumberBase) -> Int64? {
        if case .value(let value) = parseIntegerText(text, base: base) {
            return value
        }
        return nil
    }

    private func parseIntegerText(_ text: String, base: NumberBase) -> IntegerParseResult {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return .invalid }

        var negative = false
        if let first = cleaned.first, first == "+" || first == "-" {
            negative = first == "-"
            cleaned.removeFirst()
        }
        guard !cleaned.isEmpty else { return .invalid }
        guard cleaned.allSatisfy({ isValidDigit(String($0), base: base) }) else {
            return .invalid
        }
        guard let magnitude = UInt64(cleaned, radix: base.radix) else {
            return .outOfRange
        }

        let maxMagnitude = UInt64(Int64.max)
        if negative {
            if magnitude == maxMagnitude + 1 {
                return .value(Int64.min)
            }
            guard magnitude <= maxMagnitude else { return .outOfRange }
            return .value(-Int64(magnitude))
        }
        guard magnitude <= maxMagnitude else { return .outOfRange }
        return .value(Int64(magnitude))
    }

    private func isValidDigit(_ text: String, base: NumberBase) -> Bool {
        guard text.count == 1, let character = text.first else { return false }
        switch base {
        case .bin:
            return character == "0" || character == "1"
        case .oct:
            return character >= "0" && character <= "7"
        case .dec:
            return character >= "0" && character <= "9"
        case .hex:
            return (character >= "0" && character <= "9")
                || (character >= "A" && character <= "F")
                || (character >= "a" && character <= "f")
        }
    }

    private func integerParseErrorMessage(for text: String, base: NumberBase) -> String {
        if case .outOfRange = parseIntegerText(text, base: base) {
            return "超出范围"
        }
        return "无效的整数"
    }

    // MARK: - 精确整数运算

    private enum IntegerEvaluationError: Error {
        case outOfRange
        case invalid
        case divisionByZero
        case fractionalPercent
    }

    private func evaluateProgrammerNode(_ node: CalculationNode) throws -> Int64 {
        try evaluateProgrammerNode(node, percentBase: nil)
    }

    private func evaluateProgrammerNode(
        _ node: CalculationNode,
        percentBase: CalculationNode?
    ) throws -> Int64 {
        switch node {
        case .number(let text):
            switch parseIntegerText(text, base: numberBase) {
            case .value(let value): return value
            case .outOfRange: throw IntegerEvaluationError.outOfRange
            case .invalid: throw IntegerEvaluationError.invalid
            }

        case .identifier(let name):
            if name.caseInsensitiveCompare("ans") == .orderedSame,
               let answer = lastIntegerResult {
                return answer
            }
            let upperName = name.uppercased()
            if upperName.count == 1,
               let letter = upperName.first,
               let letterIndex = "ABCDEF".firstIndex(of: letter) {
                return Int64(10 + ("ABCDEF".distance(from: "ABCDEF".startIndex, to: letterIndex)))
            }
            throw IntegerEvaluationError.invalid

        case .percent(let text):
            let value: Int64
            switch parseIntegerText(text, base: numberBase) {
            case .value(let parsed): value = parsed
            case .outOfRange: throw IntegerEvaluationError.outOfRange
            case .invalid: throw IntegerEvaluationError.invalid
            }
            if let percentBase {
                let base = try evaluateProgrammerNode(percentBase)
                let scaled = try checkedMultiply(base, value)
                return try checkedDivide(scaled, 100, requireExact: true)
            }
            return try checkedDivide(value, 100, requireExact: true)

        case .unary(let op, let operand):
            let value = try evaluateProgrammerNode(operand)
            if op == "+" { return value }
            return try checkedNegate(value)

        case .binary(let op, let lhsNode, let rhsNode):
            let lhs = try evaluateProgrammerNode(lhsNode)
            switch op {
            case "+":
                let rhs = try evaluateProgrammerNode(rhsNode, percentBase: lhsNode)
                return try checkedAdd(lhs, rhs)
            case "-":
                let rhs = try evaluateProgrammerNode(rhsNode, percentBase: lhsNode)
                return try checkedSubtract(lhs, rhs)
            case "*":
                let rhs = try evaluateProgrammerNode(rhsNode)
                return try checkedMultiply(lhs, rhs)
            case "/":
                let rhs = try evaluateProgrammerNode(rhsNode)
                return try checkedDivide(lhs, rhs, requireExact: false)
            case "%":
                let rhs = try evaluateProgrammerNode(rhsNode)
                guard rhs != 0 else { throw IntegerEvaluationError.divisionByZero }
                if rhs == -1 { return 0 }
                return lhs % rhs
            case "^", "**":
                let exponent = try evaluateProgrammerNode(rhsNode)
                return try checkedPower(lhs, exponent)
            default:
                throw IntegerEvaluationError.invalid
            }

        case .function:
            throw IntegerEvaluationError.invalid
        }
    }

    private func checkedAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw IntegerEvaluationError.outOfRange }
        return result
    }

    private func checkedSubtract(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (result, overflow) = lhs.subtractingReportingOverflow(rhs)
        guard !overflow else { throw IntegerEvaluationError.outOfRange }
        return result
    }

    private func checkedMultiply(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw IntegerEvaluationError.outOfRange }
        return result
    }

    private func checkedSquare(_ value: Int64) throws -> Int64 {
        try checkedMultiply(value, value)
    }

    private func checkedCube(_ value: Int64) throws -> Int64 {
        try checkedMultiply(try checkedSquare(value), value)
    }

    private func checkedNegate(_ value: Int64) throws -> Int64 {
        guard value != Int64.min else { throw IntegerEvaluationError.outOfRange }
        return -value
    }

    private func checkedAbs(_ value: Int64) throws -> Int64 {
        guard value != Int64.min else { throw IntegerEvaluationError.outOfRange }
        return abs(value)
    }

    private func checkedDivide(
        _ lhs: Int64,
        _ rhs: Int64,
        requireExact: Bool
    ) throws -> Int64 {
        guard rhs != 0 else { throw IntegerEvaluationError.divisionByZero }
        if lhs == Int64.min, rhs == -1 {
            throw IntegerEvaluationError.outOfRange
        }
        let result = lhs / rhs
        if requireExact, lhs % rhs != 0 {
            throw IntegerEvaluationError.fractionalPercent
        }
        return result
    }

    private func checkedPower(_ base: Int64, _ exponent: Int64) throws -> Int64 {
        guard exponent >= 0 else { throw IntegerEvaluationError.invalid }
        if exponent == 0 { return 1 }
        if exponent > 62 {
            if base == 0 || base == 1 { return base }
            if base == -1 { return exponent.isMultiple(of: 2) ? 1 : -1 }
            throw IntegerEvaluationError.outOfRange
        }

        var result: Int64 = 1
        var index: Int64 = 0
        while index < exponent {
            result = try checkedMultiply(result, base)
            index += 1
        }
        return result
    }

    // MARK: - AlgebraEvaluator 适配

    private var evaluatorAngleUnit: AlgebraEvaluator.AngleUnit {
        angleMode == .deg ? .degrees : .radians
    }

    private func evaluateAtom(_ function: String, value: Double) throws -> Double {
        let literal = String(value)
        return try AlgebraEvaluator.evaluate(
            "\(function)(\(literal))",
            variables: [:],
            angleUnit: evaluatorAngleUnit
        )
    }

    private func isValidFactorialArgument(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= 170 && value.rounded() == value
    }

    private func errorMessage(for error: Error) -> String {
        if let algebraError = error as? AlgebraEvaluator.AlgebraError {
            return algebraError.localizedDescription
        }
        return "表达式无效"
    }

    private func errorMessageForEvaluation(_ error: Error) -> String {
        if let integerError = error as? IntegerEvaluationError {
            return integerErrorMessage(for: integerError)
        }
        return errorMessage(for: error)
    }

    private func integerErrorMessage(for error: Error) -> String {
        guard let integerError = error as? IntegerEvaluationError else {
            return errorMessage(for: error)
        }
        switch integerError {
        case .outOfRange:
            return "超出范围"
        case .invalid:
            return "表达式无效"
        case .divisionByZero:
            return "除数不能为 0"
        case .fractionalPercent:
            return "百分号结果不是整数"
        }
    }

    // MARK: - 计算器输入符号归一

    /// 将 UI 中的符号转换为 AlgebraEvaluator 能安全解析的 ASCII 表达式。
    private func normalizeExpression(
        _ source: String,
        currentValue: String? = nil
    ) throws -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentText = currentValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "1/x" || trimmed == "1／x" {
            if let currentText, !currentText.isEmpty {
                return "1/(" + currentText + ")"
            }
            if let lastResult {
                return "1/(" + formatNumber(lastResult) + ")"
            }
            return "1/(0)"
        }

        var result = ""
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            switch character {
            case "×":
                result += "*"
                index = source.index(after: index)
            case "÷":
                result += "/"
                index = source.index(after: index)
            case "−":
                result += "-"
                index = source.index(after: index)
            case "π":
                result += "pi"
                index = source.index(after: index)
            case "√":
                let (replacement, next) = try squareRootReplacement(in: source, after: index)
                result += replacement
                index = next
            case "!":
                result = try factorialReplacement(for: result)
                index = source.index(after: index)
            case "x", "X":
                let next = source.index(after: index)
                if next < source.endIndex, source[next] == "²" {
                    result += "^2"
                    index = source.index(after: next)
                } else if next < source.endIndex, source[next] == "³" {
                    result += "^3"
                    index = source.index(after: next)
                } else {
                    result.append(character)
                    index = next
                }
            case "²":
                result += "^2"
                index = source.index(after: index)
            case "³":
                result += "^3"
                index = source.index(after: index)
            default:
                result.append(character)
                index = source.index(after: index)
            }
        }

        return replacingModWords(in: result)
    }

    private func squareRootReplacement(
        in source: String,
        after symbol: String.Index
    ) throws -> (String, String.Index) {
        var next = source.index(after: symbol)
        while next < source.endIndex, source[next].isWhitespace {
            next = source.index(after: next)
        }
        guard next < source.endIndex else {
            throw AlgebraEvaluator.AlgebraError.parseFailed("根号缺少运算数")
        }

        if source[next] == "(" {
            return ("sqrt", next)
        }

        let start = next
        if source[next] == "+" || source[next] == "-" {
            next = source.index(after: next)
            while next < source.endIndex, source[next].isWhitespace {
                next = source.index(after: next)
            }
        }
        guard next < source.endIndex else {
            throw AlgebraEvaluator.AlgebraError.parseFailed("根号缺少运算数")
        }

        if source[next].isNumber || source[next] == "." {
            next = scanNumberEnd(in: source, from: next)
        } else if source[next].isLetter || source[next] == "_" {
            next = source.index(after: next)
            while next < source.endIndex,
                  source[next].isLetter || source[next].isNumber || source[next] == "_" {
                next = source.index(after: next)
            }
        } else {
            throw AlgebraEvaluator.AlgebraError.parseFailed("根号缺少运算数")
        }
        return ("sqrt(" + String(source[start..<next]) + ")", next)
    }

    private func scanNumberEnd(in source: String, from start: String.Index) -> String.Index {
        var next = start
        while next < source.endIndex, source[next].isNumber {
            next = source.index(after: next)
        }
        if next < source.endIndex, source[next] == "." {
            next = source.index(after: next)
            while next < source.endIndex, source[next].isNumber {
                next = source.index(after: next)
            }
        }
        if next < source.endIndex, source[next] == "e" || source[next] == "E" {
            var exponent = source.index(after: next)
            if exponent < source.endIndex,
               source[exponent] == "+" || source[exponent] == "-" {
                exponent = source.index(after: exponent)
            }
            if exponent < source.endIndex, source[exponent].isNumber {
                next = exponent
                while next < source.endIndex, source[next].isNumber {
                    next = source.index(after: next)
                }
            }
        }
        return next
    }

    private func replacingModWords(in source: String) -> String {
        var result = ""
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if character.isLetter || character == "_" {
                let start = index
                index = source.index(after: index)
                while index < source.endIndex,
                      source[index].isLetter || source[index].isNumber || source[index] == "_" {
                    index = source.index(after: index)
                }
                let word = String(source[start..<index])
                if word.lowercased() == "mod" {
                    var next = index
                    while next < source.endIndex, source[next].isWhitespace {
                        next = source.index(after: next)
                    }
                    if next < source.endIndex, source[next] == "(" {
                        result += word
                    } else {
                        result += "%"
                    }
                } else {
                    result += word
                }
            } else {
                result.append(character)
                index = source.index(after: index)
            }
        }
        return result
    }

    private func factorialReplacement(for prefix: String) throws -> String {
        let characters = Array(prefix)
        var end = characters.count
        while end > 0, characters[end - 1].isWhitespace {
            end -= 1
        }
        guard end > 0 else {
            throw AlgebraEvaluator.AlgebraError.parseFailed("阶乘缺少运算数")
        }

        var start = 0
        if characters[end - 1] == ")" {
            var depth = 0
            var cursor = end - 1
            var found = false
            while cursor >= 0 {
                if characters[cursor] == ")" {
                    depth += 1
                } else if characters[cursor] == "(" {
                    depth -= 1
                    if depth == 0 {
                        start = cursor
                        found = true
                        break
                    }
                }
                cursor -= 1
            }
            guard found else {
                throw AlgebraEvaluator.AlgebraError.parseFailed("阶乘运算数不完整")
            }
        } else if characters[end - 1].isNumber || characters[end - 1] == "." {
            start = end
            while start > 0, characters[start - 1].isNumber || characters[start - 1] == "." {
                start -= 1
            }
            if start > 0, characters[start - 1] == "e" || characters[start - 1] == "E" {
                start -= 1
                if start > 0, start < characters.count,
                   characters[start] == "+" || characters[start] == "-" {
                    start -= 1
                }
                while start > 0, characters[start - 1].isNumber {
                    start -= 1
                }
            }
        } else if characters[end - 1].isLetter || characters[end - 1] == "_" {
            start = end
            while start > 0,
                  characters[start - 1].isLetter || characters[start - 1].isNumber || characters[start - 1] == "_" {
                start -= 1
            }
        } else {
            throw AlgebraEvaluator.AlgebraError.parseFailed("阶乘缺少运算数")
        }

        var signIndex = start
        while signIndex > 0, characters[signIndex - 1].isWhitespace {
            signIndex -= 1
        }
        if signIndex > 0 {
            let sign = characters[signIndex - 1]
            if sign == "+" || sign == "-" {
                let candidate = signIndex - 1
                let isUnary = candidate == 0 || "+-*/%^(," .contains(String(characters[candidate - 1]))
                if isUnary {
                    start = candidate
                }
            }
        }

        let operand = String(characters[start..<end])
        let before = String(characters[..<start])
        return before + "fact(" + operand + ")"
    }

    private func displayHistoryExpression(_ expression: String) -> String {
        var result = expression
        for token in percentMarkers.keys.map({ percentMarkerPrefix + $0 + percentMarkerSuffix }) {
            result = result.replacingOccurrences(of: token, with: "%")
        }
        return result
    }
}

// MARK: - 百分号展开与表达式 AST

private indirect enum CalculationNode {
    case number(String)
    case identifier(String)
    case percent(String)
    case unary(String, CalculationNode)
    case binary(String, CalculationNode, CalculationNode)
    case function(String, [CalculationNode])
}

private enum CalculationToken: Equatable {
    case number(String)
    case identifier(String)
    case percent(String)
    case op(String)
    case lparen
    case rparen
    case comma
    case end
}

private enum CalculationTokenizer {
    static func tokenize(
        _ source: String,
        programmerBase: CalculatorEngine.NumberBase?,
        markerValues: [String: String]
    ) throws -> [CalculationToken] {
        var tokens: [CalculationToken] = []
        var index = source.startIndex

        while index < source.endIndex {
            let character = source[index]
            if character.isWhitespace {
                index = source.index(after: index)
                continue
            }

            // 百分号标记先于普通 identifier 处理。
            if character == "_" {
                let start = index
                index = source.index(after: index)
                while index < source.endIndex,
                      source[index].isLetter || source[index].isNumber || source[index] == "_" {
                    index = source.index(after: index)
                }
                let word = String(source[start..<index])
                if word.hasPrefix(percentMarkerPrefix), word.hasSuffix(percentMarkerSuffix) {
                    let idStart = word.index(word.startIndex, offsetBy: percentMarkerPrefix.count)
                    let idEnd = word.index(word.endIndex, offsetBy: -percentMarkerSuffix.count)
                    let id = String(word[idStart..<idEnd])
                    guard let value = markerValues[id] else {
                        throw AlgebraEvaluator.AlgebraError.parseFailed("百分号标记无效")
                    }
                    tokens.append(.percent(value))
                } else {
                    tokens.append(.identifier(word))
                }
                continue
            }

            if let programmerBase {
                // 程序员模式中 A-F 和 0-9 连续串是一个当前进制的字面量；
                // A+B 则自然拆成 A、+、B。
                if character.isLetter || character.isNumber {
                    let start = index
                    index = source.index(after: index)
                    while index < source.endIndex,
                          source[index].isLetter || source[index].isNumber {
                        index = source.index(after: index)
                    }
                    let candidate = String(source[start..<index])
                    if candidate.allSatisfy({ isValidDigit(String($0), base: programmerBase) }) {
                        tokens.append(.number(candidate))
                    } else {
                        tokens.append(.identifier(candidate))
                    }
                    continue
                }
            } else if character.isNumber || character == "." {
                let start = index
                while index < source.endIndex, source[index].isNumber {
                    index = source.index(after: index)
                }
                if index < source.endIndex, source[index] == "." {
                    index = source.index(after: index)
                    while index < source.endIndex, source[index].isNumber {
                        index = source.index(after: index)
                    }
                }
                if index < source.endIndex, source[index] == "e" || source[index] == "E" {
                    var exponent = source.index(after: index)
                    if exponent < source.endIndex,
                       source[exponent] == "+" || source[exponent] == "-" {
                        exponent = source.index(after: exponent)
                    }
                    if exponent < source.endIndex, source[exponent].isNumber {
                        index = exponent
                        while index < source.endIndex, source[index].isNumber {
                            index = source.index(after: index)
                        }
                    }
                }
                tokens.append(.number(String(source[start..<index])))
                continue
            } else if character.isLetter {
                let start = index
                index = source.index(after: index)
                while index < source.endIndex,
                      source[index].isLetter || source[index].isNumber || source[index] == "_" {
                    index = source.index(after: index)
                }
                tokens.append(.identifier(String(source[start..<index])))
                continue
            }

            switch character {
            case "+", "-", "/", "%", "^":
                tokens.append(.op(String(character)))
                index = source.index(after: index)
            case "*":
                let next = source.index(after: index)
                if next < source.endIndex, source[next] == "*" {
                    tokens.append(.op("**"))
                    index = source.index(next, offsetBy: 1)
                } else {
                    tokens.append(.op("*"))
                    index = source.index(after: index)
                }
            case "(", "[", "{":
                tokens.append(.lparen)
                index = source.index(after: index)
            case ")", "]", "}":
                tokens.append(.rparen)
                index = source.index(after: index)
            case ",":
                tokens.append(.comma)
                index = source.index(after: index)
            case "−":
                tokens.append(.op("-"))
                index = source.index(after: index)
            case "×":
                tokens.append(.op("*"))
                index = source.index(after: index)
            case "÷":
                tokens.append(.op("/"))
                index = source.index(after: index)
            default:
                throw AlgebraEvaluator.AlgebraError.parseFailed("非法字符 “\(character)”")
            }
        }
        tokens.append(.end)
        return tokens
    }

    private static func isValidDigit(_ text: String, base: CalculatorEngine.NumberBase) -> Bool {
        guard text.count == 1, let character = text.first else { return false }
        switch base {
        case .bin:
            return character == "0" || character == "1"
        case .oct:
            return character >= "0" && character <= "7"
        case .dec:
            return character >= "0" && character <= "9"
        case .hex:
            return (character >= "0" && character <= "9")
                || (character >= "A" && character <= "F")
                || (character >= "a" && character <= "f")
        }
    }
}

private struct CalculationParser {
    private let tokens: [CalculationToken]
    private var index = 0
    private var recursionDepth = 0
    private let maxRecursionDepth = 96

    init(tokens: [CalculationToken]) {
        self.tokens = tokens
    }

    private var current: CalculationToken { tokens[index] }

    mutating func parse() throws -> CalculationNode {
        let result = try parseExpression()
        guard case .end = current else {
            throw AlgebraEvaluator.AlgebraError.parseFailed("多余的内容")
        }
        return result
    }

    private mutating func enterRecursion() throws {
        guard recursionDepth < maxRecursionDepth else {
            throw AlgebraEvaluator.AlgebraError.parseFailed("表达式过于复杂，请简化")
        }
        recursionDepth += 1
    }

    private mutating func leaveRecursion() {
        recursionDepth -= 1
    }

    private mutating func parseExpression() throws -> CalculationNode {
        var result = try parseTerm()
        while case .op(let op) = current, op == "+" || op == "-" {
            index += 1
            let rhs = try parseTerm()
            result = .binary(op, result, rhs)
        }
        return result
    }

    private mutating func parseTerm() throws -> CalculationNode {
        var result = try parseUnary()
        while case .op(let op) = current, op == "*" || op == "/" || op == "%" {
            index += 1
            let rhs = try parseUnary()
            result = .binary(op, result, rhs)
        }
        return result
    }

    private mutating func parseUnary() throws -> CalculationNode {
        if case .op(let op) = current, op == "+" || op == "-" {
            try enterRecursion()
            defer { leaveRecursion() }
            index += 1
            return .unary(op, try parseUnary())
        }
        return try parsePower()
    }

    private mutating func parsePower() throws -> CalculationNode {
        let base = try parsePrimary()
        if case .op(let op) = current, op == "^" || op == "**" {
            try enterRecursion()
            defer { leaveRecursion() }
            index += 1
            return .binary(op, base, try parseUnary())
        }
        return base
    }

    private mutating func parsePrimary() throws -> CalculationNode {
        switch current {
        case .number(let text):
            index += 1
            return .number(text)

        case .percent(let text):
            index += 1
            return .percent(text)

        case .identifier(let name):
            index += 1
            if case .lparen = current {
                try enterRecursion()
                defer { leaveRecursion() }
                index += 1
                var arguments: [CalculationNode] = []
                if case .rparen = current {
                    throw AlgebraEvaluator.AlgebraError.parseFailed("函数 \(name) 缺少参数")
                }
                while true {
                    arguments.append(try parseExpression())
                    if case .comma = current {
                        index += 1
                        continue
                    }
                    break
                }
                guard case .rparen = current else {
                    throw AlgebraEvaluator.AlgebraError.parseFailed("函数 \(name) 缺少右括号")
                }
                index += 1
                return .function(name, arguments)
            }
            return .identifier(name)

        case .lparen:
            try enterRecursion()
            defer { leaveRecursion() }
            index += 1
            let result = try parseExpression()
            guard case .rparen = current else {
                throw AlgebraEvaluator.AlgebraError.parseFailed("缺少右括号")
            }
            index += 1
            return result

        case .op(let op):
            throw AlgebraEvaluator.AlgebraError.parseFailed("运算符 “\(op)” 缺少运算数")
        case .rparen:
            throw AlgebraEvaluator.AlgebraError.parseFailed("括号不匹配或运算符缺少运算数")
        case .comma:
            throw AlgebraEvaluator.AlgebraError.parseFailed("逗号位置不正确")
        case .end:
            throw AlgebraEvaluator.AlgebraError.parseFailed("表达式不完整")
        }
    }
}

/// 展开百分号。直接放在 + / - 右侧的标记使用左值作为基数；其它位置先变成 b/100。
private func expandPercentExpression(_ node: CalculationNode) -> String {
    func expand(_ node: CalculationNode, percentBase: CalculationNode? = nil) -> String {
        switch node {
        case .number(let text):
            return text
        case .identifier(let name):
            return name
        case .percent(let text):
            if let percentBase {
                return "(\(expand(percentBase)) * (\(text) / 100))"
            }
            return "(\(text) / 100)"
        case .unary(let op, let operand):
            return "(\(op)\(expand(operand)))"
        case .binary(let op, let lhs, let rhs):
            let left = expand(lhs)
            let right = expand(rhs, percentBase: (op == "+" || op == "-") ? lhs : nil)
            return "(\(left) \(op) \(right))"
        case .function(let name, let arguments):
            return "\(name)(\(arguments.map { expand($0) }.joined(separator: ", ")))"
        }
    }
    return expand(node)
}

private extension CalculatorEngine.NumberBase {
    func validDigit(_ digit: String) -> Bool {
        switch self {
        case .bin: return digit == "0" || digit == "1"
        case .oct: return ["0", "1", "2", "3", "4", "5", "6", "7"].contains(digit)
        case .dec: return digit.count == 1 && digit.first.map { $0 >= "0" && $0 <= "9" } == true
        case .hex:
            return digit.count == 1 && digit.first.map {
                ($0 >= "0" && $0 <= "9") || ($0 >= "A" && $0 <= "F") || ($0 >= "a" && $0 <= "f")
            } == true
        }
    }
}
