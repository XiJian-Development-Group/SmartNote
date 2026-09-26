import SwiftUI

/// 全局视觉主题。主题只负责视觉层，不改变资料、计划、AI 或文件处理的业务行为。
struct AppTheme: Identifiable {
    let id: AppSettings.ThemeID
    let name: String
    let summary: String
    let symbol: String
    let background: Color
    let backgroundSecondary: Color
    let surface: Color
    let surfaceElevated: Color
    let primaryText: Color
    let secondaryText: Color
    let accent: Color
    let accentSecondary: Color
    let border: Color
    let shadowColor: Color
    let colorScheme: ColorScheme?
    let isFestive: Bool

    /// 经典主题不覆盖系统强调色；节庆主题才提供全局 tint。
    var tint: Color? { isFestive ? accent : nil }

    static let classic = AppTheme(
        id: .classic,
        name: "经典",
        summary: "清晰、克制，保留系统原生观感",
        symbol: "circle.lefthalf.filled",
        background: Color(nsColor: .windowBackgroundColor),
        backgroundSecondary: Color(nsColor: .underPageBackgroundColor),
        surface: Color(nsColor: .controlBackgroundColor),
        surfaceElevated: Color(nsColor: .textBackgroundColor),
        primaryText: Color(nsColor: .labelColor),
        secondaryText: Color(nsColor: .secondaryLabelColor),
        accent: Color.accentColor,
        accentSecondary: Color(red: 0.25, green: 0.58, blue: 0.98),
        border: Color(nsColor: .separatorColor),
        shadowColor: Color.black.opacity(0.12),
        colorScheme: nil,
        isFestive: false
    )

    static let nationalDay = AppTheme(
        id: .nationalDay,
        name: "国庆红",
        summary: "红金相映，适合节庆与学习冲刺",
        symbol: "flag.pattern.checkered",
        background: Color(red: 0.075, green: 0.012, blue: 0.025),
        backgroundSecondary: Color(red: 0.19, green: 0.025, blue: 0.045),
        surface: Color(red: 0.16, green: 0.025, blue: 0.040),
        surfaceElevated: Color(red: 0.22, green: 0.040, blue: 0.060),
        primaryText: Color.white,
        secondaryText: Color(red: 0.93, green: 0.86, blue: 0.78),
        accent: Color(red: 0.91, green: 0.62, blue: 0.16),
        accentSecondary: Color(red: 0.98, green: 0.78, blue: 0.28),
        border: Color.white.opacity(0.16),
        shadowColor: Color.black.opacity(0.30),
        colorScheme: .dark,
        isFestive: true
    )

    static let auspicious = AppTheme(
        id: .auspicious,
        name: "祥云金",
        summary: "暖金与朱砂，保留喜庆但不刺眼",
        symbol: "sparkles",
        background: Color(red: 0.13, green: 0.045, blue: 0.025),
        backgroundSecondary: Color(red: 0.24, green: 0.085, blue: 0.035),
        surface: Color(red: 0.20, green: 0.075, blue: 0.035),
        surfaceElevated: Color(red: 0.27, green: 0.105, blue: 0.045),
        primaryText: Color(red: 1.00, green: 0.96, blue: 0.88),
        secondaryText: Color(red: 0.88, green: 0.76, blue: 0.60),
        accent: Color(red: 0.95, green: 0.66, blue: 0.20),
        accentSecondary: Color(red: 0.99, green: 0.79, blue: 0.30),
        border: Color.white.opacity(0.15),
        shadowColor: Color.black.opacity(0.28),
        colorScheme: .dark,
        isFestive: true
    )

    /// 雪山晨曦。配冷调背景图，accent 用晨光金，与蓝色背景形成冷暖对比。
    static let snowDawn = AppTheme(
        id: .snowDawn,
        name: "雪山晨曦",
        summary: "冷调靛蓝与晨光金，清爽而克制",
        symbol: "sunrise.fill",
        background: Color(red: 0.045, green: 0.060, blue: 0.105),
        backgroundSecondary: Color(red: 0.090, green: 0.115, blue: 0.185),
        surface: Color(red: 0.075, green: 0.100, blue: 0.160),
        surfaceElevated: Color(red: 0.110, green: 0.140, blue: 0.215),
        primaryText: Color(red: 0.94, green: 0.96, blue: 1.00),
        secondaryText: Color(red: 0.74, green: 0.80, blue: 0.90),
        accent: Color(red: 0.98, green: 0.84, blue: 0.52),
        accentSecondary: Color(red: 0.62, green: 0.80, blue: 0.98),
        border: Color.white.opacity(0.14),
        shadowColor: Color.black.opacity(0.26),
        colorScheme: .dark,
        isFestive: true
    )

    static func theme(for id: AppSettings.ThemeID) -> AppTheme {
        switch id {
        case .classic: return .classic
        case .nationalDay: return .nationalDay
        case .auspicious: return .auspicious
        case .snowDawn: return .snowDawn
        }
    }

    /// 全部主题，按界面展示顺序：经典在前，节庆主题在后。
    static var all: [AppTheme] { [.classic, .nationalDay, .auspicious, .snowDawn] }

    /// 该主题强制使用的内置背景图文件名。
    /// 经典主题返回 nil —— 留空或使用用户自己选的图片。
    var bundledBackgroundName: String? {
        switch id {
        case .classic: return nil
        case .nationalDay: return "nationalDay.png"
        case .auspicious: return "auspicious.png"
        case .snowDawn: return "snowDawn.png"
        }
    }
}

private struct AppThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppTheme.classic
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeEnvironmentKey.self] }
        set { self[AppThemeEnvironmentKey.self] = newValue }
    }
}

/// 根窗口的统一底色。背景图片开启时仍由 ContentView 叠加在它上面。
struct ThemeBackdrop: View {
    let theme: AppTheme

    var body: some View {
        ZStack {
            theme.background
                .ignoresSafeArea()

            if theme.isFestive {
                LinearGradient(
                    colors: [theme.background, theme.backgroundSecondary.opacity(0.72)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                Circle()
                    .fill(theme.accent.opacity(0.10))
                    .frame(width: 360, height: 360)
                    .blur(radius: 2)
                    .offset(x: 250, y: -260)
                    .accessibilityHidden(true)

                Circle()
                    .fill(theme.accentSecondary.opacity(0.07))
                    .frame(width: 280, height: 280)
                    .blur(radius: 3)
                    .offset(x: -330, y: 310)
                    .accessibilityHidden(true)
            }
        }
        .allowsHitTesting(false)
    }
}

/// 供新页面和设置预览复用的主题表面，避免各页面重复写颜色和圆角。
struct ThemeSurface<Content: View>: View {
    @Environment(\.appTheme) private var theme
    private let cornerRadius: CGFloat
    private let content: Content

    init(cornerRadius: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            }
            .shadow(color: theme.shadowColor, radius: 10, y: 4)
    }
}

struct ThemeTag: View {
    @Environment(\.appTheme) private var theme
    let text: String
    var isSelected = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(isSelected ? theme.background : theme.accentSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(isSelected ? theme.accent : theme.accent.opacity(0.14))
            .clipShape(Capsule())
    }
}

private struct AppTintModifier: ViewModifier {
    let color: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let color {
            content.tint(color)
        } else {
            content
        }
    }
}

extension View {
    func appTint(_ color: Color?) -> some View {
        modifier(AppTintModifier(color: color))
    }
}

