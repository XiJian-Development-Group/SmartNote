import Foundation
import UIKit
import SwiftUI

@MainActor
class HapticFeedbackService: ObservableObject {
    static let shared = HapticFeedbackService()

    private init() {}

    // 选中反馈（轻微）
    func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    // 轻微撞击
    func light() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }

    // 中等撞击
    func medium() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
    }

    // 强烈撞击
    func heavy() {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.prepare()
        generator.impactOccurred()
    }

    // 成功通知
    func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }

    // 警告通知
    func warning() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
    }

    // 错误通知
    func error() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.error)
    }

    // 刚性反馈（iOS 13+）
    func rigid() {
        if #available(iOS 13.0, *) {
            let generator = UIImpactFeedbackGenerator(style: .rigid)
            generator.prepare()
            generator.impactOccurred()
        }
    }

    // 柔性反馈（iOS 13+）
    func soft() {
        if #available(iOS 13.0, *) {
            let generator = UIImpactFeedbackGenerator(style: .soft)
            generator.prepare()
            generator.impactOccurred()
        }
    }

    // 语境化反馈
    func context(_ context: HapticContext) {
        switch context {
        case .buttonTap: light()
        case .toggleOn: selection()
        case .toggleOff: selection()
        case .taskComplete: success()
        case .taskFail: error()
        case .warning: warning()
        case .delete: medium()
        case .create: success()
        case .navigate: light()
        case .longPress: medium()
        case .dragDrop: light()
        case .refresh: light()
        case .scanComplete: success()
        case .ocrComplete: success()
        case .aiResponse: light()
        }
    }
}

enum HapticContext {
    case buttonTap
    case toggleOn
    case toggleOff
    case taskComplete
    case taskFail
    case warning
    case delete
    case create
    case navigate
    case longPress
    case dragDrop
    case refresh
    case scanComplete
    case ocrComplete
    case aiResponse
}

// SwiftUI 视图扩展
extension View {
    func hapticFeedback(_ context: HapticContext, trigger: Bool) -> some View {
        onChange(of: trigger) { _, newValue in
            if newValue {
                HapticFeedbackService.shared.context(context)
            }
        }
    }
}

// 专用按钮样式
struct HapticButtonStyle: ButtonStyle {
    let context: HapticContext

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    HapticFeedbackService.shared.context(context)
                }
            }
    }
}