import Foundation
import Vision
import AppKit

/// OCR 失败的具体原因。修复前所有失败路径都返回空串，
/// 上层无法区分「图片损坏」「没有可识别文字」和「识别引擎出错」。
enum OCRError: LocalizedError, Equatable {
    case imageUnreadable
    case invalidPDF
    case noRenderablePages
    case noTextRecognized
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .imageUnreadable:
            return "无法读取图片，文件可能已损坏或格式不支持。"
        case .invalidPDF:
            return "无法打开 PDF，文件可能已损坏或加密。"
        case .noRenderablePages:
            return "PDF 没有任何可渲染的页面。"
        case .noTextRecognized:
            return "没有识别到任何文字，图片可能过于模糊或不含文本。"
        case .recognitionFailed(let detail):
            return "文字识别失败：\(detail)"
        }
    }

    /// 面向用户的简短说明，供资料列表等调用方直接展示。
    var userMessage: String { errorDescription ?? "文字识别失败。" }
}

actor OCRService {
    /// 最近一次失败原因；成功后清空。调用方据此区分「识别不出文字」与「文件有问题」。
    private(set) var lastError: OCRError?

    func clearError() { lastError = nil }

    func recognizeText(from imageURL: URL) async -> String {
        guard let image = NSImage(contentsOf: imageURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            lastError = .imageUnreadable
            return ""
        }

        return await performOCR(on: cgImage)
    }

    func recognizeText(from nsImage: NSImage) async -> String {
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            lastError = .imageUnreadable
            return ""
        }

        return await performOCR(on: cgImage)
    }

    private func performOCR(on cgImage: CGImage) async -> String {
        let result: OCRRunResult = await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    // 注意：这里只能把错误带出去，不能直接写 actor 的 lastError——
                    // completion handler 不在该 actor 的隔离域内。
                    continuation.resume(returning: OCRRunResult(
                        text: "", error: .recognitionFailed(error.localizedDescription)
                    ))
                    return
                }
                guard let results = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: OCRRunResult(text: "", error: .noTextRecognized))
                    return
                }

                let recognizedText = results.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }.joined(separator: "\n")

                continuation.resume(returning: OCRRunResult(
                    text: recognizedText,
                    // 识别成功但一个字都没有，和「识别失败」是两回事。
                    error: recognizedText.isEmpty ? .noTextRecognized : nil
                ))
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = Self.recognitionLanguages

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: OCRRunResult(
                    text: "", error: .recognitionFailed(error.localizedDescription)
                ))
            }
        }
        lastError = result.error
        return result.text
    }

    /// 识别语言。除中英文外，若系统装有其它语言一并加入，
    /// 提升繁体、日文混排等场景的识别率（Vision 只接受已安装的语言）。
    nonisolated static var recognitionLanguages: [String] {
        var languages = ["zh-CN", "zh-TW", "en-US"]
        let supported = (try? VNRecognizeTextRequest.supportedRecognitionLanguages(
            for: .accurate, revision: VNRecognizeTextRequest.currentRevision
        )) ?? []
        for candidate in supported where !languages.contains(candidate) {
            languages.append(candidate)
        }
        return languages
    }

    func recognizeTextFromPDF(at url: URL) async -> String {
        guard let document = CGPDFDocument(url as CFURL) else {
            lastError = .invalidPDF
            return ""
        }
        
        var fullText = ""
        let pageCount = document.numberOfPages
        var renderedPages = 0

        for pageNumber in 1...min(pageCount, 10) {
            guard let page = document.page(at: pageNumber) else { continue }

            let pageRect = page.getBoxRect(.mediaBox)
            let scale: CGFloat = 2.0
            let width = Int(pageRect.width * scale)
            let height = Int(pageRect.height * scale)

            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }

            // 用 CGColor 直接构造白色，不在 actor 隔离域内访问 NSColor：
            // NSColor 不是 Sendable，Swift 6 严格并发下会编译失败。
            context.setFillColor(Self.whiteCGColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)

            context.drawPDFPage(page)

            guard let cgImage = context.makeImage() else { continue }
            renderedPages += 1

            let pageText = await performOCR(on: cgImage)
            fullText += "--- 第 \(pageNumber) 页 ---\n"
            fullText += pageText + "\n\n"
        }

        if renderedPages == 0 {
            lastError = .noRenderablePages
            return ""
        }
        if fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastError = .noTextRecognized
            return ""
        }
        lastError = nil
        return fullText
    }

    /// 不透明白色，等价于 `NSColor.white.cgColor` 但不触碰 AppKit 类型。
    private nonisolated static let whiteCGColor: CGColor = {
        CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [1, 1, 1, 1])
            ?? CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    }()
}

/// `performOCR` 的内部返回载体：文本 + 本次失败原因。
/// 单独包一层是因为 `VNRecognizeTextRequest` 的 completion handler
/// 运行在 Vision 自己的队列上，不在 OCRService 的 actor 隔离域内，不能直接写 actor 状态。
private struct OCRRunResult {
    let text: String
    let error: OCRError?
}
