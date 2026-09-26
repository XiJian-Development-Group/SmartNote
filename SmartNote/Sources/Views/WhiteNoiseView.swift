import SwiftUI
import UniformTypeIdentifiers

/// 白噪音播放中心。
struct WhiteNoiseView: View {
    @EnvironmentObject var appState: AppState
    @State private var showImporter: Bool = false
    @State private var importError: String?

    var body: some View {
        // 卡片列数随可用宽度自适应，窄窗口也不会被裁掉。
        GeometryReader { geo in
            let columns = Self.columns(forWidth: geo.size.width)

            VStack(spacing: 0) {
                header
                    .layoutPriority(1)
                Divider()

                if let error = appState.ambientSoundService.lastError {
                    playbackErrorBanner(error)
                }

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(builtinSounds) { sound in
                            SoundCard(
                                sound: sound,
                                isPlaying: appState.ambientSoundService.playingIDs.contains(sound.id),
                                volume: appState.ambientSoundService.volumes[sound.id] ?? 0.5,
                                onToggle: { appState.ambientSoundService.toggle(sound.id) },
                                onVolume: { v in appState.ambientSoundService.setVolume(sound.id, volume: v) }
                            )
                        }
                    }
                    .padding(16)

                    if !userSounds.isEmpty {
                        Divider().padding(.vertical, 8)
                        SectionTitle("我的声源（用户导入）")
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(userSounds) { sound in
                                UserSoundCard(
                                    sound: sound,
                                    isPlaying: appState.ambientSoundService.playingIDs.contains(sound.id),
                                    volume: appState.ambientSoundService.volumes[sound.id] ?? 0.5,
                                    onToggle: { appState.ambientSoundService.toggle(sound.id) },
                                    onVolume: { v in appState.ambientSoundService.setVolume(sound.id, volume: v) },
                                    onRemove: { appState.ambientSoundService.removeUserSound(sound.id) }
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 380)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.audio, .mp3, .wav, .mpeg4Audio],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
    }

    /// 按可用宽度决定列数：每列不窄于 220pt，最多 4 列。
    /// 之前固定 3 列且整体 minWidth 800，窗口缩小时卡片被裁切。
    private static func columns(forWidth width: CGFloat) -> [GridItem] {
        let minCardWidth: CGFloat = 220
        let count = max(1, min(4, Int(width / minCardWidth)))
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: count)
    }

    private func playbackErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("关闭") { appState.ambientSoundService.clearError() }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }

    private var builtinSounds: [AmbientSoundService.Sound] {
        appState.ambientSoundService.sounds.filter { $0.kind == .builtin }
    }
    private var userSounds: [AmbientSoundService.Sound] {
        appState.ambientSoundService.sounds.filter { $0.kind == .user }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.3.fill")
                .font(.title)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("白噪音").font(.headline)
                Text("6 个内置声源 + 你导入的文件，叠播不冲突")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if !appState.ambientSoundService.playingIDs.isEmpty {
                Text("\(appState.ambientSoundService.playingIDs.count) 个声源正在播放")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Button("停止全部") {
                appState.ambientSoundService.stopAll()
            }
            .disabled(appState.ambientSoundService.playingIDs.isEmpty)
            Button {
                showImporter = true
            } label: {
                Label("导入音源", systemImage: "square.and.arrow.down")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                _ = try appState.ambientSoundService.importUserSound(url)
                importError = nil
            } catch {
                importError = "导入失败：\(error.localizedDescription)"
            }
        case .failure(let err):
            importError = "选择文件失败：\(err.localizedDescription)"
        }
    }
}

private struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct SoundCard: View {
    let sound: AmbientSoundService.Sound
    let isPlaying: Bool
    let volume: Double
    let onToggle: () -> Void
    let onVolume: (Double) -> Void

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(isPlaying ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                    .frame(height: 110)
                Image(systemName: sound.icon)
                    .font(.system(size: 40))
                    .foregroundColor(isPlaying ? .accentColor : .secondary)
                    .symbolEffect(.pulse, isActive: isPlaying)
            }
            Text(sound.name).font(.headline)
            Button(action: onToggle) {
                Label(isPlaying ? "停止" : "播放", systemImage: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            VStack(alignment: .leading, spacing: 4) {
                Text("音量 \(Int(volume * 100))%")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Slider(value: Binding(
                    get: { volume },
                    set: { onVolume($0) }
                ), in: 0...1, step: 0.05)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
    }
}

private struct UserSoundCard: View {
    let sound: AmbientSoundService.Sound
    let isPlaying: Bool
    let volume: Double
    let onToggle: () -> Void
    let onVolume: (Double) -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(isPlaying ? Color.orange.opacity(0.18) : Color.secondary.opacity(0.12))
                        .frame(height: 110)
                    Image(systemName: sound.icon)
                        .font(.system(size: 40))
                        .foregroundColor(isPlaying ? .orange : .secondary)
                        .symbolEffect(.pulse, isActive: isPlaying)
                }
                Button(role: .destructive) { onRemove() } label: {
                    Image(systemName: "trash.circle.fill")
                        .foregroundColor(.red)
                        .padding(6)
                }
                .buttonStyle(.plain)
            }
            Text(sound.name).font(.headline).lineLimit(1)
            Button(action: onToggle) {
                Label(isPlaying ? "停止" : "播放", systemImage: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            VStack(alignment: .leading, spacing: 4) {
                Text("音量 \(Int(volume * 100))%")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Slider(value: Binding(
                    get: { volume },
                    set: { onVolume($0) }
                ), in: 0...1, step: 0.05)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
    }
}
