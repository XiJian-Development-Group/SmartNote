import SwiftUI
import UniformTypeIdentifiers

/// iOS 白噪音播放器。
///
/// 音频合成与播放由 Shared 的 `AmbientSoundService` 完成（内置白/粉/棕噪声、
/// 雨声、海浪、森林，以及用户导入的音频文件），
/// 本视图只负责列表、音量与播放控制。
struct WhiteNoiseView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme

    @StateObject private var service = AmbientSoundService()
    @State private var showsImporter = false
    @State private var sleepMinutes: Int = 0

    private var builtinSounds: [AmbientSoundService.Sound] {
        service.sounds.filter { $0.kind == .builtin }
    }

    private var userSounds: [AmbientSoundService.Sound] {
        service.sounds.filter { $0.kind == .user }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Button {
                        service.stopAll()
                        appState.hapticFeedbackService.light()
                    } label: {
                        Label("全部停止", systemImage: "stop.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(service.playingIDs.isEmpty)

                    Button {
                        showsImporter = true
                    } label: {
                        Label("导入音频", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            Section("内置声源") {
                ForEach(builtinSounds) { sound in
                    SoundRow_iOS(
                        sound: sound,
                        isPlaying: service.playingIDs.contains(sound.id),
                        volume: Binding(
                            get: { service.volumes[sound.id] ?? 0.6 },
                            set: { service.setVolume(sound.id, volume: $0) }
                        ),
                        onToggle: {
                            service.toggle(sound.id)
                            appState.hapticFeedbackService.selection()
                        }
                    )
                }
            }

            if !userSounds.isEmpty {
                Section("我的音频") {
                    ForEach(userSounds) { sound in
                        SoundRow_iOS(
                            sound: sound,
                            isPlaying: service.playingIDs.contains(sound.id),
                            volume: Binding(
                                get: { service.volumes[sound.id] ?? 0.6 },
                                set: { service.setVolume(sound.id, volume: $0) }
                            ),
                            onToggle: {
                                service.toggle(sound.id)
                                appState.hapticFeedbackService.selection()
                            }
                        )
                    }
                }
            }

            Section {
                Picker("定时停止", selection: $sleepMinutes) {
                    Text("不定时").tag(0)
                    ForEach([15, 30, 45, 60, 90], id: \.self) { Text("\($0) 分钟").tag($0) }
                }
            } header: {
                Text("定时停止")
            } footer: {
                Text("倒计时结束后自动停止所有声源。")
            }
        }
        .navigationTitle("白噪音")
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    guard url.startAccessingSecurityScopedResource() else { continue }
                    defer { url.stopAccessingSecurityScopedResource() }
                    do {
                        try service.importUserSound(url)
                        appState.hapticFeedbackService.success()
                    } catch {
                        appState.errorMessage = "导入失败：\(error.localizedDescription)"
                        appState.showError = true
                    }
                }
            case .failure(let error):
                appState.errorMessage = "选择音频失败：\(error.localizedDescription)"
                appState.showError = true
            }
        }
        .alert("播放错误", isPresented: Binding(
            get: { service.lastError != nil },
            set: { if !$0 { service.clearError() } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(service.lastError ?? "")
        }
    }
}

private struct SoundRow_iOS: View {
    @Environment(\.appTheme) private var appTheme

    let sound: AmbientSoundService.Sound
    let isPlaying: Bool
    @Binding var volume: Double
    let onToggle: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                Button(action: onToggle) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(isPlaying ? appTheme.accent : appTheme.secondaryText)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(sound.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(appTheme.primaryText)
                    Text(sound.kind == .builtin ? "内置" : "我的音频")
                        .font(.caption2)
                        .foregroundStyle(appTheme.secondaryText)
                }

                Spacer()
            }

            if isPlaying {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill")
                        .font(.caption2)
                        .foregroundStyle(appTheme.secondaryText)

                    Slider(value: $volume, in: 0...1)
                        .disabled(!isPlaying)

                    Image(systemName: "speaker.wave.3.fill")
                        .font(.caption2)
                        .foregroundStyle(appTheme.secondaryText)
                }
                .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
        .animation(.easeInOut(duration: 0.2), value: isPlaying)
    }
}