import SwiftUI

/// iOS 端的「功能暂不可用」占位页。
///
/// macOS 有自己的一份（`Platforms/macOS/Views/ContentView_macOS.swift`），
/// 文案逐字保留原版，不在此处共享：
/// - 两边「暂不可用」的**原因不同**（macOS 是功能维护中，iOS 是尚未提供），
///   共用一份文案会让其中一个平台显示错误的说明。
/// - macOS 的文案属于既有 UI，随共享层改动会意外变化。

/// 白板在 iOS 端暂不可用。
///
/// 白板依赖 macOS 的窗口与拖拽交互，iOS 端尚未提供对应实现。
/// 已创建的画板数据保存在同一份文档目录中，可在 macOS 端继续使用。
struct WhiteboardUnavailableView: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        FeatureUnavailableLayout_iOS(
            icon: "square.and.pencil",
            title: "白板功能暂不可用",
            message: "几何画板依赖 macOS 的窗口与拖拽交互，iOS 端暂未提供。",
            footnote: "你已经创建的画板数据都保留着，可在 macOS 端继续使用，不会丢失。"
        )
    }
}

/// 文件加密在 iOS 端暂不可用。
///
/// 与白板不同，这里必须说清：**已经加密产出的文件不会自动解密或失效**，
/// 密码仍由用户自己保管，设置里保存过的密码也不会被清除。
struct FileCryptoUnavailableView: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        FeatureUnavailableLayout_iOS(
            icon: "lock.doc.fill",
            title: "文件加密暂不可用",
            message: "该功能依赖 macOS 的安全作用域授权，iOS 端暂未提供。",
            footnote: """
            已经加密的文件不受影响：加密产物不会被改动，密码仍由你自己保管，\
            设置里保存过的密码也不会被清除。期间请不要删除已加密的文件。
            """
        )
    }
}

/// 占位页的通用版式（与 macOS 端视觉一致）。
private struct FeatureUnavailableLayout_iOS: View {
    @Environment(\.appTheme) private var theme

    let icon: String
    let title: String
    let message: String
    let footnote: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(theme.accent)

            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(theme.accentSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 420)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }
}
