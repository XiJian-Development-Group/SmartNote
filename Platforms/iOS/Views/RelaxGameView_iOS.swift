import SwiftUI

/// iOS 放松小游戏。
///
/// 提供三个纯本地的小游戏（无需网络、无需账号），用于在学习间隙放松。
/// 每个游戏都遵循同一套「开始 / 结束 / 记录最好成绩」的流程。
struct RelaxGameView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme

    @State private var selection: Game?

    private enum Game: String, CaseIterable, Identifiable {
        case breathing = "呼吸放松"
        case memory = "记忆翻牌"
        case math = "速算挑战"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .breathing: return "wind"
            case .memory: return "square.grid.2x2"
            case .math: return "function"
            }
        }

        var subtitle: String {
            switch self {
            case .breathing: return "跟随圆环呼吸，4-7-8 节律"
            case .memory: return "记住位置，翻开配对"
            case .math: return "限时口算，挑战最高分"
            }
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(Game.allCases) { game in
                    NavigationLink {
                        switch game {
                        case .breathing: BreathingGame_iOS()
                        case .memory: MemoryGame_iOS()
                        case .math: MathGame_iOS()
                        }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: game.icon)
                                .font(.title3)
                                .foregroundStyle(appTheme.accent)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(game.rawValue)
                                    .font(.headline)
                                Text(game.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(appTheme.secondaryText)
                            }
                        }
                    }
                }
            } header: {
                Text("放松一下")
            } footer: {
                Text("游戏完全离线运行，成绩只保存在本机。")
            }
        }
        .navigationTitle("放松亿下")
    }
}

// MARK: - 呼吸放松

/// 4-7-8 呼吸法：吸气 4 秒、屏息 7 秒、呼气 8 秒。
private struct BreathingGame_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme

    @State private var phase: Phase = .ready
    @State private var remaining = 0
    @State private var cycle = 0
    @State private var timer: Timer?

    private enum Phase {
        case ready, inhale, hold, exhale

        var title: String {
            switch self {
            case .ready: return "准备"
            case .inhale: return "吸气"
            case .hold: return "屏息"
            case .exhale: return "呼气"
            }
        }

        var seconds: Int {
            switch self {
            case .ready: return 0
            case .inhale: return 4
            case .hold: return 7
            case .exhale: return 8
            }
        }

        var scale: Double {
            switch self {
            case .ready, .exhale: return 0.55
            case .inhale, .hold: return 1.0
            }
        }
    }

    private static let targetCycles = 4

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            ZStack {
                Circle()
                    .fill(appTheme.accent.opacity(0.15))
                    .frame(width: 220, height: 220)
                    .scaleEffect(phase.scale)
                    .animation(.easeInOut(duration: 1), value: phase)

                VStack(spacing: 6) {
                    Text(phase.title)
                        .font(.headline)
                        .foregroundStyle(appTheme.primaryText)
                    if phase != .ready {
                        Text("\(remaining)")
                            .font(.system(size: 56, weight: .thin, design: .rounded))
                            .foregroundStyle(appTheme.accent)
                    }
                    Text("第 \(min(cycle + 1, Self.targetCycles)) / \(Self.targetCycles) 轮")
                        .font(.caption)
                        .foregroundStyle(appTheme.secondaryText)
                }
            }

            Text("吸气时用鼻子，呼气时用嘴，肩膀放松。")
                .font(.footnote)
                .foregroundStyle(appTheme.secondaryText)
                .multilineTextAlignment(.center)

            Spacer()

            Button(phase == .ready ? "开始" : "结束") {
                phase == .ready ? start() : stop()
            }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 40)
        }
        .padding()
        .navigationTitle("呼吸放松")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { stop() }
    }

    private func start() {
        cycle = 0
        advance()
        appState.hapticFeedbackService.light()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        phase = .ready
        remaining = 0
        cycle = 0
    }

    private func advance() {
        switch phase {
        case .ready: phase = .inhale
        case .inhale: phase = .hold
        case .hold: phase = .exhale
        case .exhale:
            cycle += 1
            if cycle >= Self.targetCycles {
                stop()
                appState.hapticFeedbackService.success()
                return
            }
            phase = .inhale
        }

        remaining = phase.seconds
        appState.hapticFeedbackService.selection()
        scheduleTick()
    }

    private func scheduleTick() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                remaining -= 1
                if remaining <= 0 { advance() }
            }
        }
    }
}

// MARK: - 记忆翻牌

/// 4×4 翻牌配对小游戏。
private struct MemoryGame_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme

    @State private var cards: [Card] = []
    @State private var firstIndex: Int?
    @State private var isBusy = false
    @State private var moves = 0
    @State private var bestMoves: Int?
    @State private var didWin = false

    private struct Card: Identifiable {
        let id = UUID()
        let symbol: String
        var isRevealed = false
        var isMatched = false
    }

    private static let symbols = ["🍎", "🍌", "🍇", "🍓", "🍑", "🍒", "🥝", "🍍"]
    private static let columns = 4

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("步数：\(moves)")
                Spacer()
                if let bestMoves {
                    Text("最佳：\(bestMoves)")
                }
            }
            .font(.subheadline)
            .foregroundStyle(appTheme.secondaryText)
            .padding(.horizontal)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: Self.columns), spacing: 10) {
                ForEach(cards.indices, id: \.self) { index in
                    Button {
                        reveal(index)
                    } label: {
                        Text(cards[index].isRevealed || cards[index].isMatched ? cards[index].symbol : "?")
                            .font(.system(size: 32))
                            .frame(maxWidth: .infinity)
                            .frame(height: 64)
                            .background(cards[index].isRevealed || cards[index].isMatched
                                        ? appTheme.accent.opacity(0.2)
                                        : appTheme.surface)
                            .foregroundStyle(appTheme.primaryText)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(cards[index].isMatched || isBusy)
                }
            }
            .padding(.horizontal)

            Text(didWin ? "完成！用了 \(moves) 步" : "翻开两张相同的图案即可配对。")
                .font(.footnote)
                .foregroundStyle(didWin ? Color.green : appTheme.secondaryText)

            Button("重新开始") { newGame() }
                .buttonStyle(.bordered)
                .padding(.bottom, 20)
        }
        .padding()
        .navigationTitle("记忆翻牌")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if cards.isEmpty { newGame() } }
    }

    private func newGame() {
        let pairs = Self.symbols.shuffled().prefix(8)
        cards = (pairs + pairs).shuffled().map { Card(symbol: $0) }
        firstIndex = nil
        isBusy = false
        moves = 0
        didWin = false
    }

    private func reveal(_ index: Int) {
        guard !isBusy, !cards[index].isRevealed, !cards[index].isMatched else { return }

        cards[index].isRevealed = true
        appState.hapticFeedbackService.selection()

        guard let first = firstIndex else {
            firstIndex = index
            return
        }
        guard first != index else { return }

        moves += 1
        isBusy = true

        if cards[first].symbol == cards[index].symbol {
            cards[first].isMatched = true
            cards[index].isMatched = true
            firstIndex = nil
            isBusy = false
            appState.hapticFeedbackService.success()
            checkWin()
        } else {
            // 短暂展示配对失败的结果，再翻回去。
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                cards[first].isRevealed = false
                cards[index].isRevealed = false
                firstIndex = nil
                isBusy = false
                appState.hapticFeedbackService.warning()
            }
        }
    }

    private func checkWin() {
        guard cards.allSatisfy(\.isMatched) else { return }
        didWin = true
        if bestMoves == nil || moves < bestMoves! {
            bestMoves = moves
            UserDefaults.standard.set(moves, forKey: "relax.memory.bestMoves")
        }
    }
}

// MARK: - 速算挑战

/// 60 秒限时口算小游戏。
private struct MathGame_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme

    @State private var left = 60
    @State private var leftOperand = 0
    @State private var rightOperand = 0
    @State private var usesSubtraction = false
    @State private var input = ""
    @State private var score = 0
    @State private var streak = 0
    @State private var best: Int?
    @State private var isRunning = false
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 28) {
            HStack {
                Text("得分：\(score)")
                Spacer()
                Text("连击：\(streak)")
                Spacer()
                Text("\(left)s")
                    .foregroundStyle(left <= 10 ? Color.red : appTheme.secondaryText)
            }
            .font(.subheadline)
            .foregroundStyle(appTheme.secondaryText)

            Spacer()

            Text("\(leftOperand) \(usesSubtraction ? "−" : "+") \(rightOperand)")
                .font(.system(size: 56, weight: .medium, design: .rounded))
                .foregroundStyle(appTheme.primaryText)

            TextField("答案", text: $input)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .textFieldStyle(.plain)
                .frame(width: 220)
                .disabled(!isRunning)
                .onSubmit { submit() }

            Spacer()

            if let best {
                Text("历史最佳：\(best)")
                    .font(.caption)
                    .foregroundStyle(appTheme.secondaryText)
            }

            Button(isRunning ? "结束" : "开始") {
                isRunning ? stop() : start()
            }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 30)
        }
        .padding()
        .navigationTitle("速算挑战")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { stop() }
    }

    private var answer: Int {
        usesSubtraction ? leftOperand - rightOperand : leftOperand + rightOperand
    }

    private func start() {
        score = 0
        streak = 0
        left = 60
        isRunning = true
        best = UserDefaults.standard.integer(forKey: "relax.math.best")
        nextQuestion()
        appState.hapticFeedbackService.light()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                left -= 1
                if left <= 0 { stop() }
            }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false

        let stored = UserDefaults.standard.integer(forKey: "relax.math.best")
        if score > stored {
            UserDefaults.standard.set(score, forKey: "relax.math.best")
        }
    }

    private func nextQuestion() {
        leftOperand = Int.random(in: 2...49)
        rightOperand = Int.random(in: 1...20)
        usesSubtraction = Bool.random()
        // 保证减法不出现负数。
        if usesSubtraction, rightOperand > leftOperand {
            swap(&leftOperand, &rightOperand)
        }
        input = ""
    }

    private func submit() {
        guard isRunning, let typed = Int(input) else { return }
        if typed == answer {
            score += 1
            streak += 1
            appState.hapticFeedbackService.success()
        } else {
            streak = 0
            appState.hapticFeedbackService.error()
        }
        nextQuestion()
    }
}