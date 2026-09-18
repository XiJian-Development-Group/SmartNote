import Foundation
import AppKit
import CoreGraphics
import PDFKit

class PDFService {
    /// 从 PDF 文件中提取纯文本（按页拼接）。
    /// - Returns: 拼接后的文本；nil = 解析失败或文件不是 PDF
    func extractText(from url: URL) -> String? {
        guard let pdf = PDFDocument(url: url) else { return nil }
        var out = ""
        for i in 0..<pdf.pageCount {
            if let page = pdf.page(at: i), let s = page.string {
                if !out.isEmpty { out += "\n" }
                out += s
            }
        }
        return out.isEmpty ? nil : out
    }

    static func generateQuestionsPDF(questions: String, title: String, subject: String) -> URL? {
        let pageWidth: CGFloat = 595.2
        let pageHeight: CGFloat = 841.8
        let margin: CGFloat = 50.0
        
        let pdfData = NSMutableData()
        
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            return nil
        }
        
        var currentY: CGFloat = pageHeight - margin
        let contentWidth = pageWidth - 2 * margin
        
        func startNewPage() {
            var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
            context.beginPDFPage([kCGPDFContextMediaBox as String: NSValue(rect: mediaBox)] as CFDictionary)
            currentY = pageHeight - margin
            
            let titleFont = NSFont.boldSystemFont(ofSize: 24)
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: titleFont,
                .foregroundColor: NSColor.black
            ]
            let titleString = NSAttributedString(string: title, attributes: titleAttributes)
            let titleSize = titleString.size()
            titleString.draw(at: CGPoint(x: (pageWidth - titleSize.width) / 2, y: currentY - titleSize.height))
            currentY -= titleSize.height + 20
            
            let headerFont = NSFont.boldSystemFont(ofSize: 14)
            let headerAttributes: [NSAttributedString.Key: Any] = [
                .font: headerFont,
                .foregroundColor: NSColor.darkGray
            ]
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .long
            let dateString = NSAttributedString(string: "日期: \(dateFormatter.string(from: Date()))", attributes: headerAttributes)
            dateString.draw(at: CGPoint(x: margin, y: currentY - 20))
            
            let subjectString = NSAttributedString(string: "科目: \(subject)", attributes: headerAttributes)
            subjectString.draw(at: CGPoint(x: margin, y: currentY - 45))
            currentY -= 70
        }
        
        startNewPage()
        
        let bodyFont = NSFont.systemFont(ofSize: 12)
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor.black
        ]
        
        let questionsLines = questions.components(separatedBy: "\n")
        var questionNumber = 1
        
        for line in questionsLines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty else { continue }
            
            let lineString = NSAttributedString(string: "\(questionNumber). \(trimmedLine)", attributes: bodyAttributes)
            let lineSize = lineString.size()
            
            if currentY - lineSize.height < margin {
                context.endPDFPage()
                startNewPage()
            }
            
            let wrappedLines = wrapText(trimmedLine, maxWidth: contentWidth, font: bodyFont)
            for wrappedLine in wrappedLines {
                let wrappedString = NSAttributedString(string: wrappedLine, attributes: bodyAttributes)
                let wrappedSize = wrappedString.size()
                
                if currentY - wrappedSize.height < margin {
                    context.endPDFPage()
                    startNewPage()
                }
                
                wrappedString.draw(at: CGPoint(x: margin, y: currentY - wrappedSize.height))
                currentY -= wrappedSize.height + 8
            }
            
            questionNumber += 1
        }
        
        context.endPDFPage()
        context.closePDF()
        
        let fileName = "\(subject)_复习题目_\(Int(Date().timeIntervalSince1970)).pdf"
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(fileName)
        
        do {
            try pdfData.write(to: fileURL, atomically: true)
            return fileURL
        } catch {
            print("Error saving PDF: \(error)")
            return nil
        }
    }
    
    static func generateSummaryPDF(content: String, title: String, subject: String, keywords: [String]) -> URL? {
        let pageWidth: CGFloat = 595.2
        let pageHeight: CGFloat = 841.8
        let margin: CGFloat = 50.0
        
        let pdfData = NSMutableData()
        
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            return nil
        }
        
        var currentY: CGFloat = pageHeight - margin
        let contentWidth = pageWidth - 2 * margin
        
        func startNewPage() {
            var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
            context.beginPDFPage([kCGPDFContextMediaBox as String: NSValue(rect: mediaBox)] as CFDictionary)
            currentY = pageHeight - margin
            
            let titleFont = NSFont.boldSystemFont(ofSize: 24)
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: titleFont,
                .foregroundColor: NSColor.black
            ]
            let titleString = NSAttributedString(string: title, attributes: titleAttributes)
            let titleSize = titleString.size()
            titleString.draw(at: CGPoint(x: (pageWidth - titleSize.width) / 2, y: currentY - titleSize.height))
            currentY -= titleSize.height + 15
            
            let headerFont = NSFont.boldSystemFont(ofSize: 14)
            let headerAttributes: [NSAttributedString.Key: Any] = [
                .font: headerFont,
                .foregroundColor: NSColor.darkGray
            ]
            
            let subjectString = NSAttributedString(string: "科目: \(subject)", attributes: headerAttributes)
            subjectString.draw(at: CGPoint(x: margin, y: currentY - 18))
            currentY -= 35
            
            if !keywords.isEmpty {
                let keywordsFont = NSFont.systemFont(ofSize: 11)
                let keywordsAttributes: [NSAttributedString.Key: Any] = [
                    .font: keywordsFont,
                    .foregroundColor: NSColor.blue
                ]
                let keywordsText = "核心考点: " + keywords.joined(separator: ", ")
                let keywordsString = NSAttributedString(string: keywordsText, attributes: keywordsAttributes)
                let keywordsSize = keywordsString.size()
                keywordsString.draw(at: CGPoint(x: margin, y: currentY - keywordsSize.height))
                currentY -= keywordsSize.height + 20
            }
        }
        
        startNewPage()
        
        let bodyFont = NSFont.systemFont(ofSize: 12)
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor.black
        ]
        
        let wrappedLines = wrapText(content, maxWidth: contentWidth, font: bodyFont)
        
        for line in wrappedLines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty else { continue }
            
            let lineString = NSAttributedString(string: trimmedLine, attributes: bodyAttributes)
            let lineSize = lineString.size()
            
            if currentY - lineSize.height < margin {
                context.endPDFPage()
                startNewPage()
            }
            
            lineString.draw(at: CGPoint(x: margin, y: currentY - lineSize.height))
            currentY -= lineSize.height + 8
        }
        
        context.endPDFPage()
        context.closePDF()
        
        let fileName = "\(subject)_知识点总结_\(Int(Date().timeIntervalSince1970)).pdf"
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(fileName)
        
        do {
            try pdfData.write(to: fileURL, atomically: true)
            return fileURL
        } catch {
            print("Error saving PDF: \(error)")
            return nil
        }
    }
    
    private static func wrapText(_ text: String, maxWidth: CGFloat, font: NSFont) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var wrappedLines: [String] = []
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty else {
                wrappedLines.append("")
                continue
            }
            
            var currentLine = ""
            let words = trimmedLine.components(separatedBy: " ")
            
            for word in words {
                let testLine = currentLine.isEmpty ? word : currentLine + " " + word
                let size = (testLine as NSString).size(withAttributes: [.font: font])
                
                if size.width > maxWidth {
                    if !currentLine.isEmpty {
                        wrappedLines.append(currentLine)
                        currentLine = word
                    } else {
                        wrappedLines.append(word)
                    }
                } else {
                    currentLine = testLine
                }
            }
            
            if !currentLine.isEmpty {
                wrappedLines.append(currentLine)
            }
        }
        
        return wrappedLines
    }
}
