import Foundation
import CoreImage
import PDFKit
import Vision
import Combine

/// iOS 文字识别实现（Vision + `VNRecognizeTextRequest`）。
///
/// Shared 层的 `LLMService`、`LearningAnalysisService` 只依赖 `TextRecognizing`
/// 协议，因此这里提供 iOS 侧的 Vision 实现即可，无需 macOS 的 `NSImage` 通道。
@MainActor
final class OCRService_iOS: ObservableObject {
    @MainActor static let shared = OCRService_iOS()

    @Published var isProcessing = false
    @Published var progress: Double = 0

    private init() {}

    /// 从磁盘文件识别文字。
    ///
    /// **PDF 与图片走不同路径**：`CIImage(contentsOf:)` 读不了 PDF
    /// （CoreImage 不支持 PDF 容器），直接拿它去喂 PDF 必然得到 `nil`。
    /// 所以这里按扩展名分流，PDF 改用 PDFKit 逐页光栅化后再识别 ——
    /// 与 macOS 版 `OCRService.recognizeText(fromPDF:)` 的做法一致。
    ///
    /// 识别是 CPU 密集操作，放到 detached task 中执行，避免阻塞主线程。
    /// 识别失败（文件损坏、加密、无可渲染页面）一律返回 `nil`，
    /// 由调用方决定是否提示用户。
    func recognizeText(from url: URL) async -> String? {
        if url.pathExtension.lowercased() == "pdf" {
            return await Self.recognizeTextInPDF(at: url)
        }
        guard let ciImage = CIImage(contentsOf: url) else { return nil }
        return await Self.recognizeText(in: ciImage)
    }

    /// 逐页识别 PDF 里的文字。
    ///
    /// 只取前 `maxPages` 页：整本教材可能有几百页，全量 OCR 既慢又会
    /// 撑爆内存，而资料分析通常只看开头若干页。
    private static func recognizeTextInPDF(at url: URL, maxPages: Int = 20) async -> String? {
        let pageCount = await withCheckedContinuation { continuation in
            Task.detached {
                guard let document = PDFDocument(url: url) else {
                    continuation.resume(returning: 0)
                    return
                }
                continuation.resume(returning: document.pageCount)
            }
        }
        guard pageCount > 0 else { return nil }

        var collected: [String] = []
        for index in 0..<min(pageCount, maxPages) {
            let pageText: String? = await withCheckedContinuation { continuation in
                Task.detached {
                    guard let document = PDFDocument(url: url),
                          let page = document.page(at: index) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    // 优先用 PDF 自带的文字层：比光栅化后再 OCR 快得多，也更准。
                    if let embedded = page.string, !embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        continuation.resume(returning: embedded)
                        return
                    }
                    // 扫描版 PDF 没有文字层，退回位图 OCR。
                    let image = page.thumbnail(of: CGSize(width: 2000, height: 2000), for: .mediaBox)
                    guard let cgImage = image.cgImage else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let ciImage = CIImage(cgImage: cgImage)
                    continuation.resume(returning: await recognizeText(in: ciImage))
                }
            }
            if let pageText, !pageText.isEmpty {
                collected.append(pageText)
            }
        }
        let joined = collected.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    /// 从内存中的图片数据识别文字。
    func recognizeText(fromImageData data: Data) async -> String? {
        guard let ciImage = CIImage(data: data) else { return nil }
        return await Self.recognizeText(in: ciImage)
    }

    /// 实际识别实现。Vision 的请求与句柄都可跨线程使用，因此这里不进主线程。
    private static func recognizeText(in ciImage: CIImage) async -> String? {
        await withCheckedContinuation { continuation in
            // 只允许恢复一次：Vision 的完成回调与 perform 的 throw 可能都触发，
            // 用一个受锁保护的标志保证 continuation 恰好恢复一次。
            let resumeOnce = ResumeOnce()

            let request = VNRecognizeTextRequest { request, _ in
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                resumeOnce.resume(continuation, with: text.isEmpty ? nil : text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.revision = VNRecognizeTextRequestRevision3

            let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                resumeOnce.resume(continuation, with: nil)
            }
        }
    }
}

// MARK: - TextRecognizing 协议实现

// 类内的 `recognizeText(from:)` / `recognizeText(fromImageData:)` 已与
// `TextRecognizing` 的要求逐字匹配，因此这里无需额外适配代码。
extension OCRService_iOS: TextRecognizing {}

/// 保证 `withCheckedContinuation` 恰好恢复一次。
///
/// Vision 的完成回调与 `handler.perform` 的抛出路径在竞态下可能都到达，
/// 重复恢复 continuation 会触发运行时崩溃。
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    /// 首次调用生效，其余调用被忽略。
    func resume(_ continuation: CheckedContinuation<String?, Never>, with value: String?) {
        lock.lock()
        let shouldResume = !resumed
        resumed = true
        lock.unlock()

        guard shouldResume else { return }
        continuation.resume(returning: value)
    }
}