import Foundation
import Vision
import AppKit

actor OCRService {
    func recognizeText(from imageURL: URL) async -> String {
        guard let image = NSImage(contentsOf: imageURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return ""
        }
        
        return await performOCR(on: cgImage)
    }
    
    func recognizeText(from nsImage: NSImage) async -> String {
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return ""
        }
        
        return await performOCR(on: cgImage)
    }
    
    private func performOCR(on cgImage: CGImage) async -> String {
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let results = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }
                
                let recognizedText = results.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }.joined(separator: "\n")
                
                continuation.resume(returning: recognizedText)
            }
            
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-CN", "en-US"]
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: "")
            }
        }
    }
    
    func recognizeTextFromPDF(at url: URL) async -> String {
        guard let document = CGPDFDocument(url as CFURL) else {
            return ""
        }
        
        var fullText = ""
        let pageCount = document.numberOfPages
        
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
            
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            
            context.drawPDFPage(page)
            
            guard let cgImage = context.makeImage() else { continue }
            
            let pageText = await performOCR(on: cgImage)
            fullText += "--- 第 \(pageNumber) 页 ---\n"
            fullText += pageText + "\n\n"
        }
        
        return fullText
    }
}
