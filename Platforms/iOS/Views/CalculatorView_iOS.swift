import SwiftUI

/// iOS 计算器。
///
/// 求值逻辑完全由 Shared 的 `CalculatorEngine` 提供（标准 / 科学 / 程序员三种模式），
/// 本视图只负责把按键映射到引擎命令，并提供 iOS 风格的键盘布局。
/// 引擎的函数名与位运算名沿用它自己的约定（见下），避免在视图里复制一份映射表。
struct CalculatorView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme

    @StateObject private var engine = CalculatorEngine()

    var body: some View {
        VStack(spacing: 16) {
            modePicker
            display
            Spacer(minLength: 0)
            keypad
        }
        .padding()
        .navigationTitle("计算器")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 模式与显示

    private var modePicker: some View {
        Picker("模式", selection: $engine.mode) {
            ForEach(CalculatorEngine.Mode.allCases) { mode in
                Text(Self.modeTitle(mode)).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var display: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !engine.history.isEmpty {
                Text(engine.history)
                    .font(.caption)
                    .foregroundStyle(appTheme.secondaryText)
                    .lineLimit(1)
            }
            Text(engine.display)
                .font(.system(size: 52, weight: .light, design: .rounded))
                .foregroundStyle(appTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .frame(maxWidth: .infinity, alignment: .trailing)
            if let error = engine.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - 键盘

    private var keypad: some View {
        VStack(spacing: 10) {
            switch engine.mode {
            case .standard: standardKeypad
            case .scientific: scientificKeypad
            case .programmer: programmerKeypad
            }
        }
    }

    private var standardKeypad: some View {
        VStack(spacing: 10) {
            keyRow(["AC", "±", "%", "÷"], .function) { self.key($0) }
            keyRow(["7", "8", "9", "×"], .mixed) { self.key($0) }
            keyRow(["4", "5", "6", "−"], .mixed) { self.key($0) }
            keyRow(["1", "2", "3", "+"], .mixed) { self.key($0) }
            keyRow(["0", ".", "⌫", "="], .mixed) { self.key($0) }
        }
    }

    private var scientificKeypad: some View {
        VStack(spacing: 10) {
            Picker("角度", selection: $engine.angleMode) {
                ForEach(CalculatorEngine.AngleMode.allCases) { mode in
                    Text(Self.angleTitle(mode)).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            keyRow(["sin", "cos", "tan", "√"], .function) { self.key($0) }
            keyRow(["ln", "log", "x²", "xʸ"], .function) { self.key($0) }
            keyRow(["MC", "MR", "M+", "M−"], .function) { self.memoryKey($0) }
            standardKeypad
        }
    }

    private var programmerKeypad: some View {
        VStack(spacing: 10) {
            Picker("进制", selection: $engine.numberBase) {
                ForEach(CalculatorEngine.NumberBase.allCases) { base in
                    Text(Self.baseTitle(base)).tag(base)
                }
            }
            .pickerStyle(.segmented)

            keyRow(["A", "B", "C", "D"], .function) { self.hexKey($0) }
            keyRow(["E", "F", "", ""], .function) { self.hexKey($0) }
            keyRow(["MUL2", "DIV2", "AND", "OR"], .function) { self.bitwiseKey($0) }
            keyRow(["XOR", "NOT", "sqr", "neg"], .function) { self.bitwiseKey($0) }
            keyRow(["abs", "cube", "", ""], .function) { self.bitwiseKey($0) }
                .opacity(1)
            standardKeypad
        }
    }

    // MARK: - 按键构造

    private enum KeyStyle { case number, function, mixed }

    /// 构造一行等宽按钮。`operation` 收到标题后决定调用引擎的哪个命令。
    private func keyRow(
        _ titles: [String],
        _ style: KeyStyle,
        operation: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: 10) {
            ForEach(titles, id: \.self) { title in
                if title.isEmpty {
                    Color.clear.frame(maxWidth: .infinity).frame(height: 56)
                } else {
                    Button {
                        operation(title)
                        appState.hapticFeedbackService.selection()
                    } label: {
                        Text(title)
                            .font(.title3.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(background(for: style))
                            .foregroundStyle(foreground(for: style))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func background(for style: KeyStyle) -> Color {
        switch style {
        case .number: return appTheme.surface
        case .function: return appTheme.surfaceElevated
        case .mixed: return appTheme.accent.opacity(0.18)
        }
    }

    private func foreground(for style: KeyStyle) -> Color {
        switch style {
        case .number: return appTheme.primaryText
        case .function: return appTheme.secondaryText
        case .mixed: return appTheme.accent
        }
    }

    // MARK: - 按键动作

    /// 把一个字符键映射到引擎命令。
    private func key(_ token: String) {
        if token.allSatisfy(\.isNumber) {
            engine.appendDigit(token)
            return
        }

        switch token {
        case ".": engine.appendDot()
        case "±": engine.toggleSign()
        case "%": engine.applyPercent()
        case "÷", "×", "−", "+", "xʸ": engine.appendOperator(token == "xʸ" ? "^" : token)
        case "sin", "cos", "tan", "√", "ln", "log": engine.applyFunction(token)
        case "x²": engine.applyFunction("sqr")
        case "⌫": engine.backspace()
        case "=": engine.evaluate()
        case "AC": engine.clear()
        default: break
        }
    }

    private func memoryKey(_ token: String) {
        switch token {
        case "MC": engine.memoryClear()
        case "MR": engine.memoryRecall()
        case "M+": engine.memoryAdd()
        case "M−": engine.memorySubtract()
        default: break
        }
    }

    /// 十六进制数字键 A–F。引擎按 `numberBase` 校验数字合法性
    /// （`validDigit(_:)`），因此这里只需把字符交给 `appendDigit`；
    /// 非当前进制下的数字会被引擎拒绝并写入 `lastError`。
    private func hexKey(_ token: String) {
        engine.appendDigit(token)
    }

    /// 位运算键。名称与 `CalculatorEngine.applyBitwise(_:)` 接受的取值一致。
    private func bitwiseKey(_ token: String) {
        switch token {
        case "MUL2": engine.applyBitwise("MUL2")
        case "DIV2": engine.applyBitwise("DIV2")
        case "AND": engine.applyBitwise("AND")
        case "OR": engine.applyBitwise("OR")
        case "XOR": engine.applyBitwise("XOR")
        case "NOT": engine.applyBitwise("NOT")
        case "sqr", "neg", "abs", "cube": engine.applyFunction(token)
        default: break
        }
    }

    // MARK: - 显示文本

    private static func modeTitle(_ mode: CalculatorEngine.Mode) -> String {
        switch mode {
        case .standard: return "标准"
        case .scientific: return "科学"
        case .programmer: return "程序员"
        }
    }

    private static func angleTitle(_ mode: CalculatorEngine.AngleMode) -> String {
        mode.label
    }

    private static func baseTitle(_ base: CalculatorEngine.NumberBase) -> String {
        switch base {
        case .dec: return "DEC"
        case .hex: return "HEX"
        case .oct: return "OCT"
        case .bin: return "BIN"
        }
    }
}