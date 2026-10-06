import SwiftUI

/// iOS 语音备忘界面。
///
/// 录音、转写与计时全部由 `VoiceMemoService`（AVFoundation）负责；
/// 本视图只负责呈现状态、触发操作，并把转写结果交回
/// `AppState_iOS.saveVoiceMemoTranscript(_:audioURL:)` 存成学习资料。
struct VoiceMemoView: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    @StateObject private var voiceMemo = VoiceMemoService()
    @State private var showsError = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                levelIndicator

                Text(timeText)
                    .font(.system(size: 40, weight: .thin, design: .monospaced))
                    .foregroundStyle(appTheme.primaryText)

                Text(hintText)
                    .font(.footnote)
                    .foregroundStyle(appTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                transcriptView

                Spacer()

                controlButton
            }
            .padding()
            .navigationTitle("语音备忘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        voiceMemo.cancelRecording()
                        dismiss()
                    }
                }
            }
        }
        .onDisappear {
            // 离开界面时必须停止录音，否则麦克风指示灯会一直亮着。
            if voiceMemo.isRecording { voiceMemo.cancelRecording() }
        }
        .onChange(of: voiceMemo.errorMessage) { _, newValue in
            guard let newValue, !newValue.isEmpty else { return }
            appState.errorMessage = newValue
            showsError = true
        }
    }

    // MARK: - 状态呈现

    /// 录音电平指示环。空闲时收敛，录音时随音量脉动。
    private var levelIndicator: some View {
        ZStack {
            Circle()
                .fill(indicatorColor.opacity(0.15))
                .frame(width: 180, height: 180)

            Circle()
                .stroke(indicatorColor, lineWidth: 6)
                .frame(width: 180, height: 180)
                .scaleEffect(1 + CGFloat(voiceMemo.audioLevel) * 0.12)
                .animation(.easeOut(duration: 0.1), value: voiceMemo.audioLevel)

            Image(systemName: voiceMemo.isRecording ? "waveform" : "mic.fill")
                .font(.system(size: 56))
                .foregroundStyle(indicatorColor)
        }
    }

    private var indicatorColor: Color {
        voiceMemo.isRecording ? .red : appTheme.accent
    }

    @ViewBuilder
    private var transcriptView: some View {
        if voiceMemo.isTranscribing {
            ProgressView("正在转写…")
        } else if !voiceMemo.transcript.isEmpty {
            ScrollView {
                Text(voiceMemo.transcript)
                    .font(.body)
                    .foregroundStyle(appTheme.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(appTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .frame(maxHeight: 180)
        }
    }

    private var controlButton: some View {
        Button {
            voiceMemo.isRecording ? finishRecording() : startRecording()
        } label: {
            Label(
                voiceMemo.isRecording ? "停止并转写" : "开始录音",
                systemImage: voiceMemo.isRecording ? "stop.circle.fill" : "record.circle"
            )
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(voiceMemo.isRecording ? Color.red : appTheme.accent)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(voiceMemo.isTranscribing)
    }

    private var timeText: String {
        let total = Int(voiceMemo.recordingDuration)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private var hintText: String {
        if voiceMemo.isTranscribing { return "语音已录制，正在转换为文字…" }
        if !voiceMemo.transcript.isEmpty { return "已生成学习资料，可在资料库中查看。" }
        if voiceMemo.isRecording { return "正在录音，说完后点击下方按钮结束。" }
        return "点击下方按钮开始录音。录音会转换为文字并保存为学习资料。"
    }

    // MARK: - 操作

    private func startRecording() {
        voiceMemo.startRecording()
        appState.hapticFeedbackService.medium()
    }

    /// 结束录音并在转写成功后入库为学习资料。
    private func finishRecording() {
        appState.hapticFeedbackService.light()

        guard let audioURL = voiceMemo.stopRecording() else {
            appState.errorMessage = "录音失败或过短，请重试。"
            appState.showError = true
            return
        }

        Task {
            let text = (await voiceMemo.transcribe(audioURL)) ?? ""
            guard !text.isEmpty else {
                appState.errorMessage = "没有识别到语音内容。音频仍保留在应用目录中。"
                appState.showError = true
                return
            }
            await appState.saveVoiceMemoTranscript(text, audioURL: audioURL)
            dismiss()
        }
    }
}