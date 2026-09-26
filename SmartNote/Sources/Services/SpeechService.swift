import Foundation
import AVFoundation
import AppKit

class SpeechService: NSObject, ObservableObject {
    static let shared = SpeechService()
    
    @Published var isSpeaking = false
    @Published var isPaused = false
    @Published var availableVoices: [NSSpeechSynthesizer.VoiceName] = []
    @Published var currentVoice: String = ""
    @Published var speechRate: Double = 0.5
    @Published var volume: Double = 1.0
    /// 朗读失败或不可用时的真实原因；成功后清空。界面据此提示，而不是静默无反应。
    @Published private(set) var lastError: String?

    /// 优先使用的中文音色名。macOS 实际注册的名称是 `Tingting`（无连字符），
    /// 早期版本叫 `Ting-Ting`；两者都可能不存在（未下载中文语音的机器）。
    /// 硬编码单一名称会让 NSSpeechSynthesizer 拿不到音色，朗读全程无声且无任何提示。
    static let preferredChineseVoices = ["Ting-Ting", "Tingting", "Meijia", "Sinji"]

    private var synthesizer: NSSpeechSynthesizer?
    private var currentText: String = ""
    private var currentTextIndex: String.Index?

    private override init() {
        super.init()
        loadAvailableVoices()
        resolveVoice()
        setupSynthesizer()
    }

    /// 在已安装的音色中挑一个可用的中文音色；找不到中文时回退到系统默认。
    ///
    /// 优先级：偏好音色名 → compact/enhanced 品质的中文音色 → 任意中文音色 → 任意音色。
    /// `voice.compact.*` / `voice.enhanced.*` 明显优于 `eloquence.*`（后者是机械音）。
    private func resolveVoice() {
        let names = availableVoices.map(\.rawValue)

        for preferred in Self.preferredChineseVoices where names.contains(preferred) {
            currentVoice = preferred
            return
        }

        let chinese = availableVoices.filter { Self.isChinese($0.rawValue) }
        if let quality = chinese.first(where: {
            let raw = $0.rawValue.lowercased()
            return raw.contains("voice.compact") || raw.contains("voice.enhanced") || raw.contains("voice.premium")
        }) {
            currentVoice = quality.rawValue
            return
        }
        if let any = chinese.first {
            currentVoice = any.rawValue
            return
        }
        if let fallback = availableVoices.first {
            currentVoice = fallback.rawValue
            lastError = "未安装中文语音，已改用系统音色「\(Self.displayName(of: fallback.rawValue))」朗读。"
        } else {
            currentVoice = ""
            lastError = "系统没有可用的语音音色，无法朗读。"
        }
    }

    /// `NSSpeechSynthesizer.VoiceName` 没有 language 属性，中文音色按标识判断。
    private static func isChinese(_ name: String) -> Bool {
        let raw = name.lowercased()
        return raw.contains("zh-cn") || raw.contains("zh-tw") || raw.contains("zh-hk")
            || raw.contains("chinese")
    }

    /// 把 com.apple.voice.compact.zh-CN.Tingting 这样的标识转成可读名称。
    static func displayName(of identifier: String) -> String {
        guard let last = identifier.split(separator: ".").last else { return identifier }
        return String(last)
    }

    func clearError() { lastError = nil }

    private func setupSynthesizer() {
        guard !currentVoice.isEmpty else {
            synthesizer = nil
            return
        }
        let voiceName = NSSpeechSynthesizer.VoiceName(rawValue: currentVoice)
        synthesizer = NSSpeechSynthesizer(voice: voiceName)
        synthesizer?.rate = Float(speechRate * 200 + 100)
        synthesizer?.volume = Float(volume)
        synthesizer?.delegate = self
    }
    
    func loadAvailableVoices() {
        availableVoices = NSSpeechSynthesizer.availableVoices
    }
    
    func setVoice(_ voiceName: String) {
        currentVoice = voiceName
        let voice = NSSpeechSynthesizer.VoiceName(rawValue: voiceName)
        synthesizer?.setVoice(voice)
        lastError = nil
    }
    
    func setRate(_ rate: Double) {
        speechRate = rate
        synthesizer?.rate = Float(rate * 200 + 100)
    }
    
    func setVolume(_ vol: Double) {
        volume = vol
        synthesizer?.volume = Float(vol)
    }
    
    func speak(_ text: String) {
        stop()
        currentText = text

        guard let synthesizer else {
            lastError = "没有可用的语音音色，请在「系统设置 → 辅助功能 → 朗读内容」中下载中文语音。"
            return
        }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking() }
        isSpeaking = true
        isPaused = false
        lastError = nil
        synthesizer.startSpeaking(text)
        // startSpeaking 本身不保证成功（例如文本为空），确认一次实际状态。
        if !synthesizer.isSpeaking {
            isSpeaking = false
            lastError = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "没有可朗读的内容。"
                : "语音合成未能启动，请更换音色后重试。"
        }
    }
    
    func pause() {
        if isSpeaking && !isPaused {
            synthesizer?.pauseSpeaking(at: .wordBoundary)
            isPaused = true
        }
    }
    
    func resume() {
        if isPaused {
            synthesizer?.continueSpeaking()
            isPaused = false
        }
    }
    
    func stop() {
        synthesizer?.stopSpeaking()
        isSpeaking = false
        isPaused = false
        currentText = ""
    }
    
    func togglePause() {
        if isPaused {
            resume()
        } else {
            pause()
        }
    }
    
    func getVoiceDisplayName(_ voiceName: String) -> String {
        let voice = NSSpeechSynthesizer.VoiceName(rawValue: voiceName)
        let attributes = NSSpeechSynthesizer.attributes(forVoice: voice)
        return attributes[NSSpeechSynthesizer.VoiceAttributeKey.name] as? String
            ?? Self.displayName(of: voiceName)
    }
    
    /// 判断是否为中文音色。旧实现只匹配 "Ting-Ting"、"Mei-Jia" 这类早期短名，
    /// 而现代 macOS 注册的是 `com.apple.voice.compact.zh-CN.Tingting`，
    /// 导致中文音色列表恒为空、用户根本选不到。
    func isChineseVoice(_ voiceName: String) -> Bool {
        Self.isChinese(voiceName)
    }
    
    func getChineseVoices() -> [String] {
        return availableVoices.map { $0.rawValue }.filter { isChineseVoice($0) }
    }
    
    func getDefaultChineseVoice() -> String {
        let chineseVoices = getChineseVoices()
        if chineseVoices.isEmpty {
            return currentVoice
        }
        if chineseVoices.contains(where: { $0 == "Ting-Ting" }) {
            return "Ting-Ting"
        }
        return chineseVoices.first ?? currentVoice
    }
}

extension SpeechService: NSSpeechSynthesizerDelegate {
    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        DispatchQueue.main.async {
            self.isSpeaking = false
            self.isPaused = false
            self.currentText = ""
        }
    }
}
