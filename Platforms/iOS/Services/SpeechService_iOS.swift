import Foundation
import AVFoundation
import Combine

/// iOS 语音合成服务（`AVSpeechSynthesizer`）。
///
/// macOS 的 `SpeechService` 依赖 AppKit 的语音面板控制器，两者接口不同，
/// 因此 iOS 提供独立的实现；界面只依赖下面这组方法。
@MainActor
final class SpeechService_iOS: ObservableObject {
    @MainActor static let shared = SpeechService_iOS()

    @Published var isSpeaking = false
    @Published var currentUtterance: AVSpeechUtterance?

    /// 语速。0.5 是中文听感较舒适的值，与 macOS 实现保持一致。
    private let rate: Float = 0.5
    private var synthesizer: AVSpeechSynthesizer?

    private init() {}

    /// 朗读文本。
    ///
    /// 语音按优先级回退：请求语言 → 中文 → 英文 → 系统默认。
    /// 若设备完全没有对应语音，`AVSpeechSynthesisVoice(language:)` 返回 nil，
    /// 此时交给系统使用默认语音，而不是静默失败。
    func speak(_ text: String, language: String = "zh-CN") {
        guard !text.isEmpty else { return }

        stop()

        let synthesizer = AVSpeechSynthesizer()
        self.synthesizer = synthesizer

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.resolveVoice(preferredLanguage: language)
        utterance.rate = rate
        utterance.volume = 1.0

        currentUtterance = utterance
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    /// 语音回退链：请求语言 → 中文 → 英文 → nil（系统默认）。
    private static func resolveVoice(preferredLanguage: String) -> AVSpeechSynthesisVoice? {
        let candidates = [preferredLanguage, "zh-CN", "en-US", "zh-Hans", "zh-Hant"]
        for candidate in candidates {
            if let voice = AVSpeechSynthesisVoice(language: candidate) {
                return voice
            }
        }
        return nil
    }

    func stop() {
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
        isSpeaking = false
        currentUtterance = nil
    }

    func pause() {
        synthesizer?.pauseSpeaking(at: .immediate)
    }

    func continueSpeaking() {
        synthesizer?.continueSpeaking()
    }
}