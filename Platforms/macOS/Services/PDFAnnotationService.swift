import Foundation
import PDFKit
import AppKit

@MainActor
final class PDFAnnotationService: ObservableObject {
@MainActor static let shared = PDFAnnotationService()
    
    @Published var annotationsData: [UUID: PDFAnnotationsData] = [:]
    private let storageService = StorageService()
    
    private init() {
        loadAllAnnotations()
    }
    
    private func loadAllAnnotations() {
        annotationsData = storageService.loadPDFAnnotations()
    }
    
    func getAnnotations(for materialID: UUID) -> [PDFAnnotation] {
        return annotationsData[materialID]?.annotations ?? []
    }
    
    func addAnnotation(_ annotation: PDFAnnotation) {
        if annotationsData[annotation.materialID] == nil {
            annotationsData[annotation.materialID] = PDFAnnotationsData(materialID: annotation.materialID)
        }
        
        annotationsData[annotation.materialID]?.annotations.append(annotation)
        annotationsData[annotation.materialID]?.lastModified = Date()
        
        saveAnnotations()
    }
    
    func updateAnnotation(_ annotation: PDFAnnotation) {
        guard var data = annotationsData[annotation.materialID],
              let index = data.annotations.firstIndex(where: { $0.id == annotation.id }) else {
            return
        }
        
        data.annotations[index] = annotation
        data.lastModified = Date()
        annotationsData[annotation.materialID] = data
        
        saveAnnotations()
    }
    
    func deleteAnnotation(annotationID: UUID, materialID: UUID) {
        guard var data = annotationsData[materialID] else { return }
        
        data.annotations.removeAll { $0.id == annotationID }
        data.lastModified = Date()
        annotationsData[materialID] = data
        
        saveAnnotations()
    }
    
    func deleteAllAnnotations(for materialID: UUID) {
        annotationsData[materialID] = nil
        saveAnnotations()
    }
    
    func applyAnnotations(to pdfDocument: PDFDocument, materialID: UUID) {
        guard let annotations = annotationsData[materialID]?.annotations else { return }
        
        for annotationData in annotations {
            guard let page = pdfDocument.page(at: annotationData.pageIndex) else { continue }
            
            let bounds = annotationData.bounds.rect
            let color = NSColor(hex: annotationData.color) ?? .yellow
            
            let nativeAnnotation = createNativeAnnotation(from: annotationData)
            page.addAnnotation(nativeAnnotation)
        }
    }
    
    private func createNativeAnnotation(from annotationData: PDFAnnotation) -> PDFKit.PDFAnnotation {
        let bounds = annotationData.bounds.rect
        let color = NSColor(hex: annotationData.color) ?? .yellow
        
        switch annotationData.annotationType {
        case .highlight:
            let annotation = PDFKit.PDFAnnotation(bounds: bounds)
            annotation.color = color.withAlphaComponent(0.3)
            annotation.type = "Highlight"
            return annotation
            
        case .underline:
            let annotation = PDFKit.PDFAnnotation(bounds: bounds)
            annotation.color = color
            annotation.type = "Underline"
            return annotation
            
        case .strikethrough:
            let annotation = PDFKit.PDFAnnotation(bounds: bounds)
            annotation.color = color
            annotation.type = "StrikeOut"
            return annotation
            
        case .square:
            let annotation = PDFKit.PDFAnnotation(bounds: bounds)
            annotation.color = color.withAlphaComponent(0.2)
            annotation.border = PDFBorder()
            annotation.border?.lineWidth = 2
            annotation.type = "Square"
            return annotation
            
        case .text:
            let annotation = PDFKit.PDFAnnotation(bounds: bounds)
            annotation.contents = annotationData.contents ?? ""
            annotation.color = color
            annotation.type = "Text"
            return annotation
            
        case .freehand:
            let annotation = PDFKit.PDFAnnotation(bounds: bounds)
            annotation.color = color
            annotation.type = "Ink"
            return annotation
        }
    }
    
    private func saveAnnotations() {
        storageService.savePDFAnnotations(annotationsData)
    }
    
    func exportAnnotations(materialID: UUID, format: ExportFormat) -> URL? {
        guard let data = annotationsData[materialID] else { return nil }
        
        switch format {
        case .text:
            return exportAsText(data)
        case .markdown:
            return exportAsMarkdown(data)
        case .json:
            return exportAsJSON(data)
        }
    }
    
    private func exportAsText(_ data: PDFAnnotationsData) -> URL? {
        var text = "PDF 批注导出\n"
        text += "=" .padding(toLength: 30, withPad: "=", startingAt: 0) + "\n\n"
        
        let grouped = Dictionary(grouping: data.annotations) { $0.pageIndex }
        
        for pageIndex in grouped.keys.sorted() {
            text += "第 \(pageIndex + 1) 页\n"
            text += "-".padding(toLength: 20, withPad: "-", startingAt: 0) + "\n"
            
            for annotation in grouped[pageIndex] ?? [] {
                text += "[\(annotation.annotationType.displayName)] "
                if let contents = annotation.contents {
                    text += contents
                }
                text += "\n"
            }
            text += "\n"
        }
        
        let fileName = "批注_\(Int(Date().timeIntervalSince1970)).txt"
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(fileName)
        
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            return nil
        }
    }
    
    private func exportAsMarkdown(_ data: PDFAnnotationsData) -> URL? {
        var md = "# PDF 批注导出\n\n"
        
        let grouped = Dictionary(grouping: data.annotations) { $0.pageIndex }
        
        for pageIndex in grouped.keys.sorted() {
            md += "## 第 \(pageIndex + 1) 页\n\n"
            
            for annotation in grouped[pageIndex] ?? [] {
                md += "- **\(annotation.annotationType.displayName)**"
                if let contents = annotation.contents {
                    md += ": \(contents)"
                }
                md += "\n"
            }
            md += "\n"
        }
        
        let fileName = "批注_\(Int(Date().timeIntervalSince1970)).md"
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(fileName)
        
        do {
            try md.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            return nil
        }
    }
    
    private func exportAsJSON(_ data: PDFAnnotationsData) -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        
        do {
            let jsonData = try encoder.encode(data)
            let fileName = "批注_\(Int(Date().timeIntervalSince1970)).json"
            let tempDir = FileManager.default.temporaryDirectory
            let fileURL = tempDir.appendingPathComponent(fileName)
            try jsonData.write(to: fileURL)
            return fileURL
        } catch {
            return nil
        }
    }
}

enum ExportFormat: String, CaseIterable {
    case text = "纯文本"
    case markdown = "Markdown"
    case json = "JSON"
}

extension NSColor {
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        
        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgb & 0x0000FF) / 255.0
        
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}

extension PDFAnnotation {
    fileprivate init(bounds: CGRect, type: AnnotationType) {
        self.init(
            materialID: UUID(),
            pageIndex: 0,
            annotationType: type,
            bounds: AnnotationBounds(rect: bounds)
        )
    }
}
