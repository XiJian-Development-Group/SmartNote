import SwiftUI

/// 高级计算器视图：标准 / 科学 / 程序员 三模式
struct CalculatorView: View {
    @StateObject private var engine = CalculatorEngine()
    @State private var showCopyToast: Bool = false

    private let standardLayout: [[CalcButton]] = [
        [.fn("C", kind: .clear), .fn("MC", kind: .mc), .fn("MR", kind: .mr), .fn("M+", kind: .mp), .fn("M-", kind: .mm)],
        [.fn("sin", kind: .hiddenFunction), .fn("cos", kind: .hiddenFunction), .fn("√", kind: .hiddenFunction), .op("÷"), .op("mod")],
        [.digit("7"), .digit("8"), .digit("9"), .op("×"), .fn("x²", kind: .hiddenFunction)],
        [.digit("4"), .digit("5"), .digit("6"), .op("−"), .fn("1/x", kind: .hiddenFunction)],
        [.digit("1"), .digit("2"), .digit("3"), .op("+"), .fn("ln", kind: .hiddenFunction)],
        [.digit("0"), .dot, .fn("±", kind: .negate), .equals, .backspace]
    ]

    private let programmerDigits: [String] = ["0","1","2","3","4","5","6","7","8","9","A","B","C","D","E","F"]

    var body: some View {
        VStack(spacing: 0) {
            modeBar
            display
            Divider()
            if engine.mode == .standard {
                standardPad
            } else if engine.mode == .scientific {
                scientificPad
            } else {
                programmerPad
            }
        }
        .frame(minWidth: 380, minHeight: 420)
    }

    // MARK: - 顶部

    private var modeBar: some View {
        HStack(spacing: 8) {
            Picker("模式", selection: $engine.mode) {
                Text("标准").tag(CalculatorEngine.Mode.standard)
                Text("科学").tag(CalculatorEngine.Mode.scientific)
                Text("程序员").tag(CalculatorEngine.Mode.programmer)
            }
            .pickerStyle(.segmented)
            .frame(width: 280)

            Spacer()

            if engine.mode == .scientific {
                Picker("角度", selection: $engine.angleMode) {
                    Text(CalculatorEngine.AngleMode.deg.label).tag(CalculatorEngine.AngleMode.deg)
                    Text(CalculatorEngine.AngleMode.rad.label).tag(CalculatorEngine.AngleMode.rad)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }
            if engine.mode == .programmer {
                Picker("进制", selection: Binding(
                    get: { engine.numberBase },
                    set: { engine.convertBase(to: $0) }
                )) {
                    ForEach(CalculatorEngine.NumberBase.allCases) { b in
                        Text(b.label).tag(b)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(engine.display, forType: .string)
                showCopyToast = true
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("复制当前结果")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var display: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(engine.history.isEmpty ? " " : engine.history)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .lineLimit(2)
                .padding(.horizontal, 14)
            Text(engine.display)
                .font(.system(size: 44, weight: .light, design: .monospaced))
                .foregroundColor(engine.lastError != nil ? .red : .primary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            if let err = engine.lastError {
                Text(err).font(.caption).foregroundColor(.red).padding(.horizontal, 14)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.4))
        .alert("已复制", isPresented: $showCopyToast) {
            Button("好") { showCopyToast = false }
        } message: {
            Text("已复制「\(engine.display)」到剪贴板。")
        }
    }

    // MARK: - 按钮网格

    private var standardPad: some View {
        let layout: [[CalcButton]] = [
            [.fn("MC", kind: .mc), .fn("MR", kind: .mr), .fn("M-", kind: .mm), .fn("M+", kind: .mp), .fn("C", kind: .clear)],
            [.fn("±", kind: .negate), .fn("x²", kind: .sqr), .fn("√", kind: .sqrt), .fn("1/x", kind: .inv), .op("÷")],
            [.digit("7"), .digit("8"), .digit("9"), .op("×"), .fn("abs", kind: .abs)],
            [.digit("4"), .digit("5"), .digit("6"), .op("−"), .fn("%", kind: .percent)],
            [.digit("1"), .digit("2"), .digit("3"), .op("+"), .fn("n!", kind: .fact)],
            [.digit("0"), .dot, .backspace, .equals, .empty]
        ]
        return buildGrid(layout)
    }

    private var scientificPad: some View {
        let layout: [[CalcButton]] = [
            [.fn("MC", kind: .mc), .fn("MR", kind: .mr), .fn("M-", kind: .mm), .fn("M+", kind: .mp), .fn("C", kind: .clear)],
            [.fn("sin", kind: .sin), .fn("cos", kind: .cos), .fn("tan", kind: .tan), .op("^"), .fn("π", kind: .pi)],
            [.fn("x²", kind: .sqr), .fn("√", kind: .sqrt), .fn("x³", kind: .cube), .fn("log", kind: .log10), .fn("ln", kind: .ln)],
            [.fn("(", kind: .leftParen), .fn(")", kind: .rightParen), .fn("n!", kind: .fact), .fn("abs", kind: .abs), .op("÷")],
            [.digit("7"), .digit("8"), .digit("9"), .op("mod", alternate: true), .op("×")],
            [.digit("4"), .digit("5"), .digit("6"), .op("−"), .fn("1/x", kind: .inv)],
            [.digit("1"), .digit("2"), .digit("3"), .op("+"), .fn("e", kind: .e)],
            [.digit("0"), .dot, .fn("±", kind: .negate), .equals, .backspace]
        ]
        return buildGrid(layout)
    }

    private var programmerPad: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button("AND") { engine.applyBitwise("AND") }
                    .buttonStyle(CalcKeyStyle(kind: .function))
                    .frame(maxWidth: .infinity)
                Button("OR") { engine.applyBitwise("OR") }
                    .buttonStyle(CalcKeyStyle(kind: .function))
                    .frame(maxWidth: .infinity)
                Button("XOR") { engine.applyBitwise("XOR") }
                    .buttonStyle(CalcKeyStyle(kind: .function))
                    .frame(maxWidth: .infinity)
                Button("NOT") { engine.applyBitwise("NOT") }
                    .buttonStyle(CalcKeyStyle(kind: .function))
                    .frame(maxWidth: .infinity)
                Button("×2") { engine.applyBitwise("MUL2") }
                    .buttonStyle(CalcKeyStyle(kind: .function))
                    .frame(maxWidth: .infinity)
            }
            HStack(spacing: 8) {
                Button("÷2") { engine.applyBitwise("DIV2") }
                    .buttonStyle(CalcKeyStyle(kind: .function))
                    .frame(maxWidth: .infinity)
                CalcKey(button: .equals, engine: engine)
                    .frame(maxWidth: .infinity)
                Button("Clear") { engine.clear() }
                    .buttonStyle(CalcKeyStyle(kind: .danger))
                    .frame(maxWidth: .infinity)
            }

            keypadGrid(items: programmerDigits) { ch in
                .digit(ch)
            }
            .padding(.horizontal, 4)

            HStack(spacing: 8) {
                ForEach(["+", "−", "×", "÷"], id: \.self) { op in
                    Button(op) {
                        engine.appendOperator(op)
                    }
                    .buttonStyle(CalcKeyStyle(kind: .op))
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(8)
    }

    private func keypadGrid(items: [String], button: @escaping (String) -> CalcButton) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(0..<items.count, id: \.self) { i in
                let b = button(items[i])
                CalcKey(button: b, engine: engine)
            }
            .padding(.vertical, 0)
        }
    }

    // MARK: - 标准 / 科学按钮网格构造

    @ViewBuilder
    private func buildGrid(_ rows: [[CalcButton]]) -> some View {
        VStack(spacing: 6) {
            ForEach(0..<rows.count, id: \.self) { r in
                HStack(spacing: 6) {
                    ForEach(0..<rows[r].count, id: \.self) { c in
                        CalcKey(button: rows[r][c], engine: engine)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(8)
    }
}

// MARK: - 按钮模型

enum CalcButton: Equatable {
    case digit(String)
    case dot
    case op(String, alternate: Bool = false)
    case fn(String, kind: CalcFunctionKind)
    case equals
    case backspace
    case empty
    case clear
}

enum CalcFunctionKind {
    case clear, mc, mr, mp, mm
    case negate, percent, abs
    case sin, cos, tan
    case log10, ln
    case sqrt, sqr, cube
    case inv, fact, x2
    case leftParen, rightParen
    case pi, e
    case hiddenFunction   // 标准模式不显示
}

// MARK: - 按钮 view

private struct CalcKey: View {
    let button: CalcButton
    let engine: CalculatorEngine

    var body: some View {
        let style = self.style
        Button(action: action) {
            Text(label)
                .font(.system(size: 18, weight: style.fontWeight, design: .monospaced))
                .foregroundColor(style.textColor)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(style.background)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(CalcKeyStyle(kind: style.kind))
    }

    private var label: String {
        switch button {
        case .digit(let d): return d
        case .dot: return "."
        case .op(let s, _): return s
        case .fn(let s, _): return s
        case .equals: return "="
        case .backspace: return "⌫"
        case .empty: return ""
        case .clear: return "C"
        }
    }

    private var style: CalcKeyStyleDescriptor {
        switch button {
        case .digit, .dot:
            return CalcKeyStyleDescriptor(kind: .digit, textColor: .primary, background: Color(nsColor: .controlBackgroundColor))
        case .op:
            return CalcKeyStyleDescriptor(kind: .op, textColor: .white, background: Color.orange.opacity(0.85))
        case .equals:
            return CalcKeyStyleDescriptor(kind: .equals, textColor: .white, background: Color.accentColor)
        case .backspace:
            return CalcKeyStyleDescriptor(kind: .danger, textColor: .primary, background: Color.secondary.opacity(0.18))
        case .clear:
            return CalcKeyStyleDescriptor(kind: .danger, textColor: .primary, background: Color.secondary.opacity(0.18))
        case .fn(_, let kind):
            switch kind {
            case .mc, .mr, .mp, .mm:
                return CalcKeyStyleDescriptor(kind: .memory, textColor: .primary, background: Color.secondary.opacity(0.18))
            case .pi, .e:
                return CalcKeyStyleDescriptor(kind: .constant, textColor: .accentColor, background: Color.secondary.opacity(0.18))
            default:
                return CalcKeyStyleDescriptor(kind: .function, textColor: .primary, background: Color.secondary.opacity(0.18))
            }
        case .empty:
            return CalcKeyStyleDescriptor(kind: .digit, textColor: .clear, background: .clear)
        }
    }

    private func action() {
        switch button {
        case .digit(let d):
            engine.appendDigit(d)
        case .dot:
            engine.appendDot()
        case .op(let s, let alternate):
            // 特殊操作符 mod / ^ → 转 AlgebraEvaluator 接受的形式
            if alternate || s == "mod" {
                engine.appendOperator(" mod ")
            } else if s == "^" {
                engine.appendOperator(" ** ")
            } else {
                engine.appendOperator(s)
            }
        case .fn(let s, let kind):
            if s == "C" || kind == .clear { engine.clear(); return }
            switch kind {
            case .clear: engine.clear()
            case .negate: engine.toggleSign()
            case .percent: engine.applyPercent()
            case .abs: engine.applyFunction("abs")
            case .sin: engine.applyFunction("sin")
            case .cos: engine.applyFunction("cos")
            case .tan: engine.applyFunction("tan")
            case .log10: engine.applyFunction("log")
            case .ln: engine.applyFunction("ln")
            case .sqrt: engine.applyFunction("sqrt")
            case .sqr: engine.applyFunction("sqr")
            case .x2: engine.applyFunction("sqr")
            case .cube: engine.applyFunction("cube")
            case .inv: engine.applyFunction("inv")
            case .fact: engine.applyFunction("fact")
            case .leftParen: engine.appendOperator("(")
            case .rightParen: engine.appendOperator(")")
            case .pi: engine.appendOperator("\(Double.pi)")
            case .e: engine.appendOperator("\(M_E)")
            case .mc: engine.memoryClear()
            case .mr: engine.memoryRecall()
            case .mp: engine.memoryAdd()
            case .mm: engine.memorySubtract()
            case .hiddenFunction: break   // 占位
            }
        case .equals:
            engine.evaluate()
        case .backspace:
            engine.backspace()
        case .empty, .clear:
            break
        }
    }
}

// MARK: - 样式

struct CalcKeyStyleDescriptor {
    let kind: CalcKeyStyle.Kind
    let textColor: Color
    let background: Color
    var fontWeight: Font.Weight { kind == .equals ? .bold : .medium }
}

struct CalcKeyStyle: ButtonStyle {
    enum Kind { case digit, op, equals, function, memory, constant, danger }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
    }
}
