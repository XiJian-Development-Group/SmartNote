import SwiftUI

/// 许愿/还愿中心。
///
/// 背景为动态星空（TimelineView + Canvas 实时绘制）：
///   • 30~80 颗星按各自相位闪烁
///   • 偶尔划过流星
///   • 整体蓝紫色 → 上半略亮、下半略暗
/// 界面层：左右两栏（许愿中 / 已还愿），新建 dialog，渐隐 + 上浮动画。
struct WishView: View {
    @EnvironmentObject var appState: AppState
    @State private var newContent: String = ""
    @State private var newAccent: Wish.AccentColor = .gold
    @State private var showAddSheet: Bool = false
    @State private var editingWishID: UUID?

    var body: some View {
        ZStack {
            StarrySkyBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().background(Color.white.opacity(0.2))
                dualPane
            }
        }
        .frame(minWidth: 900, minHeight: 540)
        .sheet(isPresented: $showAddSheet) {
            AddWishSheet(
                content: $newContent,
                accent: $newAccent,
                onCommit: {
                    if !newContent.trimmingCharacters(in: .whitespaces).isEmpty {
                        let wish = Wish(content: newContent, status: .wish, accent: newAccent)
                        appState.wishService.add(wish)
                        newContent = ""
                        showAddSheet = false
                    }
                },
                onCancel: { showAddSheet = false }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "moon.stars.fill")
                .font(.title2)
                .foregroundColor(.white.opacity(0.85))
            VStack(alignment: .leading, spacing: 2) {
                Text("许愿 · 还愿").font(.headline).foregroundColor(.white)
                Text("\(pendingWishes.count) 个许愿 · \(fulfilledWishes.count) 个已还愿")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
            }
            Spacer()
            Button(action: { showAddSheet = true }) {
                Label("许个愿", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(.sRGB, red: 1, green: 0.84, blue: 0.42, opacity: 1))
            .foregroundColor(.black)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
    }

    private var pendingWishes: [Wish] {
        appState.wishService.wishes.filter { $0.status == .wish }
    }
    private var fulfilledWishes: [Wish] {
        appState.wishService.wishes.filter { $0.status == .fulfilled }
    }

    private var dualPane: some View {
        HSplitView {
            column(
                title: "许愿中",
                wishes: pendingWishes,
                emptyHint: "还没有许愿。点击右上角许个愿吧。",
                iconColor: Wish.AccentColor.gold.swiftColor.color,
                background: Color.black.opacity(0.2)
            )
            column(
                title: "已还愿",
                wishes: fulfilledWishes,
                emptyHint: "还没有实现的心愿。",
                iconColor: Wish.AccentColor.mint.swiftColor.color,
                background: Color.black.opacity(0.2)
            )
        }
    }

    @ViewBuilder
    private func column(title: String, wishes: [Wish], emptyHint: String, iconColor: Color, background: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Circle().fill(iconColor).frame(width: 8, height: 8)
                Text(title).font(.subheadline.weight(.semibold)).foregroundColor(.white.opacity(0.85))
                Spacer()
                Text("\(wishes.count)").font(.caption).foregroundColor(.white.opacity(0.6))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(background)

            if wishes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 36))
                        .foregroundColor(.white.opacity(0.35))
                    Text(emptyHint)
                        .font(.callout)
                        .foregroundColor(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(wishes) { wish in
                            WishCard(wish: wish,
                                     onMarkFulfilled: { appState.wishService.markFulfilled(id: wish.id) },
                                     onRestore: { appState.wishService.restore(id: wish.id) },
                                     onDelete: { appState.wishService.remove(id: wish.id) })
                        }
                    }
                    .padding(18)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WishCard: View {
    let wish: Wish
    let onMarkFulfilled: () -> Void
    let onRestore: () -> Void
    let onDelete: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: wish.status == .wish ? "sparkle" : "checkmark.seal.fill")
                .font(.system(size: 22))
                .foregroundColor(wish.accent.swiftColor.color)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(wish.content)
                    .font(.callout)
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text(wish.status == .wish ? "许于 " + Wish.relative(wish.createdAt)
                                          : "已还愿 · " + Wish.relative(wish.createdAt))
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.55))
            }
            Spacer()
            if wish.status == .wish {
                Button(action: onMarkFulfilled) {
                    Image(systemName: "checkmark.circle")
                        .foregroundColor(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("标记为已还愿")
            } else {
                Button(action: onRestore) {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .foregroundColor(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("恢复为许愿中")
            }
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help("删除")
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .opacity(hovered ? 0.9 : 0.6)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(wish.accent.swiftColor.color.opacity(0.45), lineWidth: 1)
                )
        )
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovered)
    }
}

private struct AddWishSheet: View {
    @Binding var content: String
    @Binding var accent: Wish.AccentColor
    let onCommit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("许个愿").font(.title3.weight(.semibold))
            TextField("想实现什么…", text: $content, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
            VStack(alignment: .leading, spacing: 4) {
                Text("选择颜色").font(.caption).foregroundColor(.secondary)
                HStack(spacing: 12) {
                    ForEach(Wish.AccentColor.allCases, id: \.self) { c in
                        Circle()
                            .fill(c.swiftColor.color)
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle()
                                    .stroke(Color.accentColor, lineWidth: c == accent ? 3 : 0)
                            )
                            .onTapGesture { accent = c }
                    }
                }
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { onCancel() }
                Button("许愿", action: onCommit)
                    .buttonStyle(.borderedProminent)
                    .disabled(content.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - 动态星空背景

struct StarrySkyBackground: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                drawBackground(ctx: ctx, size: size)
                drawStars(ctx: ctx, size: size, t: t)
                drawShootingStars(ctx: ctx, size: size, t: t)
            }
        }
    }

    private func drawBackground(ctx: GraphicsContext, size: CGSize) {
        // 渐变背景：上半深蓝 / 下半深紫
        let rect = CGRect(origin: .zero, size: size)
        let gradient = Gradient(colors: [
            Color(.sRGB, red: 0.05, green: 0.06, blue: 0.13, opacity: 1),
            Color(.sRGB, red: 0.10, green: 0.08, blue: 0.22, opacity: 1),
            Color(.sRGB, red: 0.04, green: 0.04, blue: 0.08, opacity: 1)
        ])
        ctx.fill(Path(rect), with: .linearGradient(gradient, startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
    }

    private func drawStars(ctx: GraphicsContext, size: CGSize, t: TimeInterval) {
        // 用种子生成稳定 70 颗星（位置/大小/相位不变）
        var generator = SeededGenerator(seed: 73)
        let starCount = 70
        for i in 0..<starCount {
            _ = generator.next() // 推进种子，第 i 颗的总位移
            let x = CGFloat(generator.next()) / CGFloat(UInt64.max) * size.width
            let y = CGFloat(generator.next()) / CGFloat(UInt64.max) * size.height
            let r = 0.6 + CGFloat(generator.next() % 100) / 200.0   // 0.6 ~ 1.1
            let phase = Double(generator.next() % 1000) / 160.0
            let twinkle = 0.55 + 0.45 * sin(t * 1.2 + phase)
            let alpha = 0.35 + 0.5 * twinkle
            let dotRect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: dotRect), with: .color(.white.opacity(alpha)))
            // 大星加微光晕
            if r > 0.9 {
                let glow = CGRect(x: x - r * 3, y: y - r * 3, width: r * 6, height: r * 6)
                ctx.fill(Path(ellipseIn: glow), with: .radialGradient(
                    Gradient(colors: [.white.opacity(0.4 * alpha), .clear]),
                    center: CGPoint(x: x, y: y),
                    startRadius: 0,
                    endRadius: r * 3
                ))
            }
        }
    }

    private func drawShootingStars(ctx: GraphicsContext, size: CGSize, t: TimeInterval) {
        // 每 6 秒划过一颗流星
        let period: Double = 6
        let phase = t.truncatingRemainder(dividingBy: period) / period
        // 0..0.3 段可见
        guard phase < 0.3 else { return }
        var generator = SeededGenerator(seed: UInt64(Int(t) / Int(period)))
        let startX = CGFloat(generator.next() % UInt64(size.width))
        let startY = CGFloat(generator.next() % UInt64(size.height * 60 / 100))
        let len: CGFloat = 80
        let progress = phase / 0.3   // 0..1
        let dx = len + 60
        let dy = len * 0.4
        let start = CGPoint(x: startX + dx * progress, y: startY + dy * progress)
        let end = CGPoint(x: startX + dx * progress + len, y: startY + dy * progress + len * 0.4)
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        ctx.stroke(
            path,
            with: .linearGradient(
                Gradient(colors: [.clear, .white.opacity(1 - progress)]),
                startPoint: start, endPoint: end
            ),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
        )
    }
}

/// 简单的伪随机数生成器（保持帧间稳定）
struct SeededGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 1 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// 等同 next() 调用并 clamp 到 0..UInt64.max
    static func clamp(_ x: UInt64) -> UInt64 { x }
}
