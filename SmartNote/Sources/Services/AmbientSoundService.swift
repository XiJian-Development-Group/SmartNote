import Foundation
import AVFoundation
import Combine

/// 白噪音 / 自然音播放服务。
///
/// - 实现：纯 AVAudioEngine（macOS 13+ 原生）。
///   内置 6 个声源用 procedural PCM buffer 算法生成（白 / 粉 / 棕 / 雨 / 海 / 林）
///   不引第三方音频文件，确保 app 体积不变；用户可从 Finder 导入 .mp3/.wav/.m4a
///   并加入到「我的声源」列表中。
/// - 多声源：每个声源独立 AVAudioPlayerNode + 独立 volume，可叠播。
///
/// 设计原则（v1.7 总原则）：
///   全部 macOS 原生 API；不引第三方音频库；可与系统音频共享。
final class AmbientSoundService: ObservableObject {

    /// 声源模型
    struct Sound: Identifiable, Hashable {
        let id: String
        let name: String
        let kind: Kind
        let icon: String
        /// 文件路径（仅 .user 类型有值）
        let fileURL: URL?

        enum Kind: String, Codable {
            case builtin
            case user
        }

        static func builtin(_ id: String, name: String, icon: String) -> Sound {
            Sound(id: id, name: name, kind: .builtin, icon: icon, fileURL: nil)
        }
        static func user(id: String, name: String, fileURL: URL) -> Sound {
            Sound(id: id, name: name, kind: .user, icon: "waveform", fileURL: fileURL)
        }
    }

    /// 当前正在播放的声源 id 集合
    @Published private(set) var playingIDs: Set<String> = []
    /// 音量映射 id -> 0.0...1.0
    @Published private(set) var volumes: [String: Double] = [:]
    /// 已注册的全部声源（含内置 + 用户导入）
    @Published private(set) var sounds: [Sound] = []
    /// 播放失败时的真实原因；成功播放后清空。界面据此给出提示，而不是让按钮静默无反应。
    @Published private(set) var lastError: String?

    private let engine = AVAudioEngine()
    /// player node 与声源 id 的映射
    private var nodes: [String: AVAudioPlayerNode] = [:]
    /// 声源 id 对应的 PCM buffer 缓存（用户导入的小文件）
    private var buffers: [String: AVAudioPCMBuffer] = [:]

    private let userSoundsDirectory: URL

    init() {
        let appSupport = StorageService().appSupportURL
        userSoundsDirectory = appSupport.appendingPathComponent("AmbientSounds", isDirectory: true)
        if !FileManager.default.fileExists(atPath: userSoundsDirectory.path) {
            try? FileManager.default.createDirectory(at: userSoundsDirectory, withIntermediateDirectories: true)
        }
        registerBuiltinSounds()
        loadUserSounds()
    }

    /// 注册 6 个内置声源
    private func registerBuiltinSounds() {
        let all: [Sound] = [
            .builtin("white", name: "白噪音", icon: "waveform"),
            .builtin("pink", name: "粉噪音", icon: "waveform.path"),
            .builtin("brown", name: "棕噪音", icon: "waveform.path.ecg"),
            .builtin("rain", name: "雨声", icon: "cloud.rain"),
            .builtin("ocean", name: "海浪", icon: "water.waves"),
            .builtin("forest", name: "森林", icon: "leaf")
        ]
        sounds.append(contentsOf: all)
        for s in all {
            volumes[s.id] = 0.6
        }
    }

    /// 从用户目录恢复已导入的声源
    private func loadUserSounds() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: userSoundsDirectory, includingPropertiesForKeys: nil) else { return }
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard ["mp3", "wav", "m4a", "aac", "aif"].contains(ext) else { continue }
            let id = "user-" + url.lastPathComponent
            let displayName = url.deletingPathExtension().lastPathComponent
            let sound = Sound.user(id: id, name: displayName, fileURL: url)
            sounds.append(sound)
            volumes[id] = 0.6
        }
    }

    // MARK: - 播放控制

    func play(_ id: String) {
        guard let sound = sounds.first(where: { $0.id == id }) else { return }
        ensureEngineStarted()
        ensurePlayer(for: id)
        guard let player = nodes[id] else { return }
        if player.isPlaying { return }

        do {
            try scheduleBufferIfNeeded(for: id, sound: sound, on: player)
            player.play()
            playingIDs.insert(id)
            lastError = nil
        } catch {
            // 内置声源不应该走到这里；用户文件格式不受支持时会到这里。
            lastError = "\(sound.name) 播放失败：\(error.localizedDescription)"
            print("播放失败 \(id): \(error)")
        }
    }

    func stop(_ id: String) {
        if let player = nodes[id] {
            player.stop()
        }
        playingIDs.remove(id)
    }

    func stopAll() {
        for id in playingIDs {
            nodes[id]?.stop()
        }
        playingIDs.removeAll()
    }

    func clearError() {
        lastError = nil
    }

    func toggle(_ id: String) {
        if playingIDs.contains(id) { stop(id) } else { play(id) }
    }

    /// 0.0 ... 1.0
    func setVolume(_ id: String, volume: Double) {
        let v = max(0, min(1, volume))
        volumes[id] = v
        nodes[id]?.volume = Float(v)
    }

    /// 导入用户音频文件
    func importUserSound(_ sourceURL: URL) throws -> Sound {
        let didStart = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStart { sourceURL.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw NSError(domain: "AmbientSoundService", code: -1, userInfo: [NSLocalizedDescriptionKey: "源文件不存在"])
        }

        // 拷贝到 userSounds 目录
        let destName = UUID().uuidString + "." + sourceURL.pathExtension.lowercased()
        let dest = userSoundsDirectory.appendingPathComponent(destName)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: sourceURL, to: dest)

        let id = "user-" + destName
        let displayName = sourceURL.deletingPathExtension().lastPathComponent
        let sound = Sound.user(id: id, name: displayName, fileURL: dest)
        sounds.append(sound)
        volumes[id] = 0.6
        return sound
    }

    /// 删除用户声源
    func removeUserSound(_ id: String) {
        guard let sound = sounds.first(where: { $0.id == id }), sound.kind == .user else { return }
        if let url = sound.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        stop(id)
        buffers.removeValue(forKey: id)
        nodes[id]?.stop()
        nodes.removeValue(forKey: id)
        sounds.removeAll { $0.id == id }
        volumes.removeValue(forKey: id)
    }

    // MARK: - 引擎与 buffer

    private func ensureEngineStarted() {
        if !engine.isRunning {
            do { try engine.start() } catch {
                print("AVAudioEngine 启动失败：\(error)")
            }
        }
    }

    private func ensurePlayer(for id: String) {
        if nodes[id] != nil { return }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        // 必须显式传入与 buffer 一致的 mono 格式。
        // 传 nil 会让 player 采用 mainMixerNode 的输出格式（本机为 48kHz 立体声），
        // 而内置声源与用户文件的 buffer 是单声道；scheduleBuffer 时
        // AVAudioPlayerNode 会抛出无法被 Swift 捕获的 ObjC 异常
        // （required condition is false: _outputFormat.channelCount == buffer.format.channelCount），
        // 直接终止进程，表现为「点播放没反应 / 应用闪退」。
        // 立体声混音交给 mainMixerNode 完成。
        engine.connect(player, to: engine.mainMixerNode, format: Self.monoFormat)
        nodes[id] = player
        player.volume = Float(volumes[id] ?? 0.6)
    }

    /// 统一使用 44.1kHz 单声道作为 player 的输入格式。
    private static let monoFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else {
            fatalError("无法创建 44.1kHz 单声道音频格式")
        }
        return format
    }()

    private func scheduleBufferIfNeeded(for id: String, sound: Sound, on player: AVAudioPlayerNode) throws {
        // 用户声源：每次播放前 scheduleBuffer 一次（因为 loops）
        if sound.kind == .user {
            try scheduleUserBuffer(id: id, sound: sound, player: player)
            return
        }
        // 内置声源：基于 SoundIdentifier 算法生成 10s buffer，loop
        switch id {
        case "white":
            try scheduleLoop(player: player, buffer: NoiseGenerator.white(seconds: 10, volume: 0.5))
        case "pink":
            try scheduleLoop(player: player, buffer: NoiseGenerator.pink(seconds: 10, volume: 0.5))
        case "brown":
            try scheduleLoop(player: player, buffer: NoiseGenerator.brown(seconds: 10, volume: 0.7))
        case "rain":
            try scheduleLoop(player: player, buffer: NoiseGenerator.rain(seconds: 12, volume: 0.6))
        case "ocean":
            try scheduleLoop(player: player, buffer: NoiseGenerator.ocean(seconds: 14, volume: 0.65))
        case "forest":
            try scheduleLoop(player: player, buffer: NoiseGenerator.forest(seconds: 12, volume: 0.55))
        default:
            break
        }
    }

    private func scheduleLoop(player: AVAudioPlayerNode, buffer: AVAudioPCMBuffer) throws {
        player.scheduleBuffer(buffer, at: nil, options: [.loops, .interrupts], completionHandler: nil)
    }

    private func scheduleUserBuffer(id: String, sound: Sound, player: AVAudioPlayerNode) throws {
        guard let url = sound.fileURL else { return }
        let file = try AVAudioFile(forReading: url)
        if let cached = buffers[id] {
            player.scheduleBuffer(cached, at: nil, options: [.loops, .interrupts], completionHandler: nil)
            return
        }
        let format = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            throw NSError(domain: "AmbientSoundService", code: -2, userInfo: [NSLocalizedDescriptionKey: "无法分配 PCM 缓冲"])
        }
        try file.read(into: buf)
        buffers[id] = buf
        player.scheduleBuffer(buf, at: nil, options: [.loops, .interrupts], completionHandler: nil)
    }
}

// MARK: - 噪音生成器（纯算法，无音频文件依赖）

/// 内置声源的 PCM 生成器。所有输出 44.1 kHz mono。
enum NoiseGenerator {
    static let sampleRate: Double = 44_100

    private static func makeBuffer(durationSeconds: Double, samplesFactory: (Int, inout [Float]) -> Void) -> AVAudioPCMBuffer {
        let frameCount = Int(durationSeconds * sampleRate)
        var samples = [Float](repeating: 0, count: frameCount)
        samplesFactory(frameCount, &samples)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let ptr = buffer.floatChannelData![0]
        for i in 0..<frameCount { ptr[i] = samples[i] }
        return buffer
    }

    /// 白噪音：均匀分布
    static func white(seconds: Double, volume: Float) -> AVAudioPCMBuffer {
        makeBuffer(durationSeconds: seconds) { n, s in
            for i in 0..<n { s[i] = Float.random(in: -1...1) * volume }
        }
    }

    /// 粉噪音（1/f）：Voss-McCartney 算法近似
    static func pink(seconds: Double, volume: Float) -> AVAudioPCMBuffer {
        makeBuffer(durationSeconds: seconds) { n, s in
            let rows = 16
            var rowsVal = [Float](repeating: 0, count: rows)
            var runningSum: Float = 0
            var counter = 0
            for i in 0..<n {
                counter &+= 1
                if counter & (counter &- 1) == 0 {
                    for r in 0..<rows where (counter >> r) & 1 == 0 {
                        runningSum -= rowsVal[r]
                        rowsVal[r] = Float.random(in: -1...1)
                        runningSum += rowsVal[r]
                    }
                }
                let white = Float.random(in: -1...1)
                let pink = (runningSum + white) / Float(rows + 1)
                s[i] = pink * volume * 0.5
            }
        }
    }

    /// 棕噪音（红噪声）：累计随机游走
    static func brown(seconds: Double, volume: Float) -> AVAudioPCMBuffer {
        makeBuffer(durationSeconds: seconds) { n, s in
            var last: Float = 0
            for i in 0..<n {
                let white = Float.random(in: -1...1)
                last = (last + white * 0.02).clamped(to: -1...1)
                s[i] = last * volume * 3.5   // 放大补偿低频
            }
        }
    }

    /// 雨声：白噪音底 + 稀疏高频脉冲
    static func rain(seconds: Double, volume: Float) -> AVAudioPCMBuffer {
        makeBuffer(durationSeconds: seconds) { n, s in
            // 基础白噪音
            for i in 0..<n {
                s[i] = Float.random(in: -1...1) * 0.2 * volume
            }
            // 雨滴：随机高频脉冲（带衰减）
            let drops = Int(Double(n) / seconds * 25) // 25 Hz 平均
            for _ in 0..<drops {
                let pos = Int.random(in: 0..<n)
                let decay: Int = 500
                let end = min(pos + decay, n)
                for j in pos..<end {
                    let t = Float(j - pos) / Float(decay)
                    let envelope = (1.0 - t) * Float.random(in: 0.6...1.0)
                    s[j] += envelope * volume * 0.6
                }
            }
            // 钳位防止失真
            for i in 0..<n { s[i] = max(-1, min(1, s[i])) }
        }
    }

    /// 海浪：低频正弦调幅 + 噪声
    static func ocean(seconds: Double, volume: Float) -> AVAudioPCMBuffer {
        makeBuffer(durationSeconds: seconds) { n, s in
            for i in 0..<n {
                let t = Double(i) / Self.sampleRate
                // 7 秒一个波浪周期
                let envelope = (sin(2 * .pi * t / 7.0) + 1) / 2   // 0..1
                let carrier = sin(2 * .pi * 80 * t) * 0.3 + sin(2 * .pi * 140 * t) * 0.2
                let noise = Float.random(in: -1...1) * 0.4
                let v = Float(carrier * envelope) * volume * 0.6 + noise * volume * 0.15
                s[i] = max(-1, min(1, v))
            }
        }
    }

    /// 森林：白噪 + 鸟鸣脉冲（800–2000 Hz 短促音）
    static func forest(seconds: Double, volume: Float) -> AVAudioPCMBuffer {
        makeBuffer(durationSeconds: seconds) { n, s in
            // 树叶沙沙：低频粉噪
            let pinkBuf = pink(seconds: seconds, volume: 0.35)
            let pinkPtr = pinkBuf.floatChannelData![0]
            for i in 0..<n { s[i] = pinkPtr[i] }
            // 鸟鸣：每 0.4–1.5 秒一次短促 0.05 秒高频正弦
            let birds = Int(seconds * 2.5)
            for _ in 0..<birds {
                let pos = Int.random(in: 0..<(n - 2205))
                let freq = Double.random(in: 800...2000)
                let dur = 2205 // 0.05s
                for j in 0..<dur {
                    let t = Double(j) / Self.sampleRate
                    let envelope = exp(-t * 30)
                    let v = sin(2 * .pi * freq * t) * envelope
                    s[pos + j] += Float(v) * volume * 0.4
                }
            }
            for i in 0..<n { s[i] = max(-1, min(1, s[i])) }
        }
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
