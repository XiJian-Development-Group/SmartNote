import Foundation
import AVFoundation
import Speech
import SwiftUI

@MainActor
class VoiceMemoService: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var audioLevel: Float = 0
    @Published var transcript: String = ""
    @Published var isTranscribing = false
    @Published var errorMessage: String?

    private var audioEngine: AVAudioEngine?
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var timer: Timer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))!

    override init() {
        super.init()
        requestPermissions()
    }

    private func requestPermissions() {
        AVAudioApplication.requestRecordPermission { granted in
            if !granted {
                Task { @MainActor in self.errorMessage = "需要麦克风权限才能录音" }
            }
        }
        SFSpeechRecognizer.requestAuthorization { status in
            if status != .authorized {
                Task { @MainActor in self.errorMessage = "需要语音识别权限才能转文字" }
            }
        }
    }

    func startRecording() {
        guard !isRecording else { return }
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileName = "voice_memo_\(Date().timeIntervalSince1970).m4a"
        recordingURL = documentsPath.appendingPathComponent(fileName)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: recordingURL!, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.delegate = self
            audioRecorder?.record()

            audioEngine = AVAudioEngine()
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest else { return }
            recognitionRequest.shouldReportPartialResults = true
            recognitionRequest.requiresOnDeviceRecognition = true // 优先离线识别

            let inputNode = audioEngine!.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                recognitionRequest.append(buffer)
                DispatchQueue.main.async {
                    self.audioLevel = self.averagePower(for: buffer)
                }
            }

            audioEngine?.prepare()
            try audioEngine?.start()

            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                Task { @MainActor in
                    if let result = result {
                        self?.transcript = result.bestTranscription.formattedString
                    }
                    if error != nil || (result?.isFinal ?? false) {
                        self?.stopTranscription()
                    }
                }
            }

            isRecording = true
            recordingDuration = 0
            transcript = ""
            startTimer()
        } catch {
            errorMessage = "开始录音失败：\(error.localizedDescription)"
        }
    }

    func stopRecording() -> URL? {
        guard isRecording else { return nil }
        audioRecorder?.stop()
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        stopTimer()
        stopTranscription()
        isRecording = false
        return recordingURL
    }

    private func stopTranscription() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recordingDuration += 0.1
                self?.audioRecorder?.updateMeters()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func averagePower(for buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let channelDataValue = channelData.pointee
        let channelDataValueArray = stride(from: 0, to: Int(buffer.frameLength), by: buffer.stride).map { channelDataValue[$0] }
        let rms = sqrt(channelDataValueArray.map { $0 * $0 }.reduce(0, +) / Float(buffer.frameLength))
        let avgPower = 20 * log10(rms)
        return max(0, min(1, (avgPower + 80) / 80)) // 归一化到 0-1
    }

    func transcribe(_ audioURL: URL) async -> String? {
        isTranscribing = true
        defer { isTranscribing = false }

        return await withCheckedContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: audioURL)
            request.shouldReportPartialResults = false
            request.requiresOnDeviceRecognition = true

            speechRecognizer.recognitionTask(with: request) { result, error in
                if let result = result, result.isFinal {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if error != nil {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func cancelRecording() {
        if isRecording {
            audioRecorder?.stop()
            audioEngine?.stop()
            audioEngine?.inputNode.removeTap(onBus: 0)
            recognitionRequest?.endAudio()
            stopTimer()
            stopTranscription()
            isRecording = false
            recordingDuration = 0
            transcript = ""
            if let url = recordingURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

extension VoiceMemoService: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            Task { @MainActor in self.errorMessage = "录音保存失败" }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.errorMessage = "录音编码错误：\(error?.localizedDescription ?? "未知")" }
    }
}