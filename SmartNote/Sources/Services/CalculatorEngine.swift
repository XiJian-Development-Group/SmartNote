import Foundation
import Combine

/// 高级计算器引擎。
///
/// 支持三种模式：
///   - **standard**  + - × ÷ % = ± C / MC MR M+ M- / = / % / ±
///   - **scientific**  + 上述 + sin / cos / tan / log / ln / sqrt / pow / x² / x! / π / e / ( / ) / deg-rad
///   - **programmer**  + 上述 + AND / OR / XOR / NOT / << / >> / 进制转换（BIN / OCT / DEC / HEX）
///
/// 实现策略：
///   - 主表达式栈存 String（用户输入的 infix 字符串），用 NSExpression 一次性求值
///   - 单值函数（sin/cos/tan/log/ln/√/x²/x!）走 Calculator 单值评估路径
///   - 位运算把 infix 表达式 parse 后分离两边的十进制整数，按当前 base 求值，再格式化为该 base
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
    /// 程序员模式下当前输入是浮点还是整数（位运算强制整数）
    @Published var lastError: String?

    /// 内存
    @Published private(set) var memory: Double = 0
    @Published private(set) var hasMemory: Bool = false

    private var lastResult: Double?

    /// 数字按钮
    func appendDigit(_ digit: String) {
        guard mode != .programmer || numberBase.validDigit(digit) else {
            lastError = "当前进制不支持该字符"
            return
        }
        if display == "0" || display == "0." || lastError != nil {
            display = digit
            lastError = nil
        } else {
            display += digit
        }
    }

    /// 小数点：程序员模式不允许
    func appendDot() {
        guard mode != .programmer else { return }
        if !display.contains(".") {
            display += display == "" ? "0." : "."
        }
    }

    /// 操作符
    func appendOperator(_ op: String) {
        guard !display.isEmpty else { return }
        // 科学模式支持 ^、mod、factorial 后缀
        let operand: String
        if let last = lastResult.map({ formatNumber($0) }) {
            operand = last
            lastResult = nil
        } else {
            operand = display
        }
        expression += operand + " " + op + " "
        history = expression
        display = "0"
    }

    /// 一元函数（科学模式）
    func applyFunction(_ fn: String) {
        guard let value = Double(display) else { return }
        let rad = angleMode == .rad
        let result: Double
        switch fn {
        case "sin": result = rad ? Foundation.sin(value) : Foundation.sin(value * .pi / 180)
        case "cos": result = rad ? Foundation.cos(value) : Foundation.cos(value * .pi / 180)
        case "tan":
            let r = rad ? value : value * .pi / 180
            result = Foundation.tan(r)
        case "log": result = Foundation.log10(value)
        case "ln":  result = Foundation.log(value)
        case "sqrt": result = Foundation.sqrt(value)
        case "sqr": result = value * value
        case "fact":
            // 非负整数的阶乘。带小数则取整
            let n = Int(value)
            result = n >= 0 ? fact(Double(n)) : .nan
        case "inv": result = value == 0 ? .nan : 1 / value
        case "neg": result = -value
        case "abs": result = Swift.abs(value)
        default: result = value
        }
        display = formatNumber(result)
        lastResult = result
        history = "\(fn)(\(value)) = \(display)"
    }

    /// 进制转换：仅程序员模式
    func convertBase(to base: NumberBase) {
        guard mode == .programmer else { return }
        let v = currentIntegerValue()
        display = formatNumber(Double(v), base: base)
        numberBase = base
    }

    /// 取得当前整数（如 1024）— 程序员模式专用
    func currentIntegerValue() -> Int {
        // 显示文字直接当 base base 转 int
        let cleaned = display.uppercased()
        if let v = Int(cleaned, radix: numberBase.radix) { return v }
        return 0
    }

    /// 位运算：op 为 AND/OR/XOR/NOT/SHL/SHR
    func applyBitwise(_ op: String) {
        guard mode == .programmer else { return }
        let lhs = currentIntegerValue()
        let rhs = lastResult.map { Int($0) } ?? lhs
        var result: Int
        switch op {
        case "NOT": result = ~lhs
        case "SHL": result = lhs << 1
        case "SHR": result = lhs >> 1
        case "AND": result = lhs & rhs
        case "OR":  result = lhs | rhs
        case "XOR": result = lhs ^ rhs
        default: return
        }
        display = formatNumber(Double(result), base: numberBase)
        lastResult = Double(result)
        history = "\(lhs) \(op) \(rhs) = \(display)"
    }

    /// 等号
    func evaluate() {
        guard !expression.isEmpty else {
            history = display
            return
        }
        // 把当前 display 接到 expression 末尾
        var exp = expression + display
        // 用户写法归一
        exp = exp.replacingOccurrences(of: "×", with: "*")
        exp = exp.replacingOccurrences(of: "÷", with: "/")
        exp = exp.replacingOccurrences(of: "−", with: "-")
        exp = exp.replacingOccurrences(of: "π", with: "\(Double.pi)")
        // 表达式中可能含进制装饰数字（程序员模式）
        do {
            let e = NSExpression(format: exp)
            let result = e.expressionValue(with: NSMutableDictionary(), context: nil) as? NSNumber
            if let n = result?.doubleValue {
                display = formatNumber(n)
                lastResult = n
                history = exp + " = " + display
                expression = ""
            } else {
                lastError = "解析失败"
                history = exp
            }
        } catch {
            lastError = "表达式无效"
            history = exp
        }
    }

    /// 清空
    func clear() {
        expression = ""
        display = "0"
        history = ""
        lastResult = nil
        lastError = nil
    }

    /// 退格
    func backspace() {
        guard lastError == nil else { clear(); return }
        if !display.isEmpty && display != "0" {
            display.removeLast()
            if display.isEmpty || display == "-" { display = "0" }
        }
    }

    /// 内存
    func memoryClear() {
        memory = 0
        hasMemory = false
    }
    func memoryRecall() {
        display = formatNumber(memory)
    }
    func memoryAdd() {
        if let v = Double(display) {
            memory += v
            hasMemory = true
        }
    }
    func memorySubtract() {
        if let v = Double(display) {
            memory -= v
            hasMemory = true
        }
    }

    /// 切换 +/- 号
    func toggleSign() {
        if let v = Double(display) {
            display = formatNumber(-v)
        }
    }

    /// 数字格式化
    func formatNumber(_ value: Double, base: NumberBase? = nil) -> String {
        if !value.isFinite {
            return value.isNaN ? "NaN" : (value > 0 ? "+∞" : "-∞")
        }
        let useBase = base ?? (mode == .programmer ? numberBase : nil)
        if let b = useBase, b != .dec {
            // 进制格式（整数）
            let v = Int(value)
            switch b {
            case .bin:
                return String(v, radix: 2)
            case .oct:
                return String(v, radix: 8)
            case .hex:
                return String(v, radix: 16).uppercased()
            case .dec:
                return String(v)
            }
        }
        if abs(value) >= 1e15 || (abs(value) > 0 && abs(value) < 1e-6) {
            return String(format: "%.6e", value)
        }
        // 一般数：去掉末尾无意义的 0
        let s = String(format: "%.10f", value)
        if s.contains(".") {
            var trimmed = s
            while trimmed.hasSuffix("0") { trimmed.removeLast() }
            if trimmed.hasSuffix(".") { trimmed.removeLast() }
            return trimmed
        }
        return s
    }

    private func fact(_ n: Double) -> Double {
        if n <= 1 { return 1 }
        var result: Double = 1
        for i in 2...Int(n) { result *= Double(i) }
        return result
    }
}

private extension CalculatorEngine.NumberBase {
    func validDigit(_ d: String) -> Bool {
        switch self {
        case .bin: return d == "0" || d == "1"
        case .oct: return ["0","1","2","3","4","5","6","7"].contains(d)
        case .dec: return d.allSatisfy { $0.isNumber }
        case .hex: return d.allSatisfy { $0.isHexDigit }
        }
    }
}
