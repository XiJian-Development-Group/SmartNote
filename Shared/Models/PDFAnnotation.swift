import Foundation
import PDFKit

struct PDFAnnotation: Identifiable, Codable {
    let id: UUID
    var materialID: UUID
    var pageIndex: Int
    var annotationType: AnnotationType
    var bounds: AnnotationBounds
    var contents: String?
    var color: String
    var createdAt: Date
    
    init(
        id: UUID = UUID(),
        materialID: UUID,
        pageIndex: Int,
        annotationType: AnnotationType,
        bounds: AnnotationBounds,
        contents: String? = nil,
        color: String = "#FFEB3B",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.materialID = materialID
        self.pageIndex = pageIndex
        self.annotationType = annotationType
        self.bounds = bounds
        self.contents = contents
        self.color = color
        self.createdAt = createdAt
    }
}

enum AnnotationType: String, Codable {
    case highlight = "highlight"
    case underline = "underline"
    case strikethrough = "strikethrough"
    case square = "square"
    case text = "text"
    case freehand = "freehand"
    
    var displayName: String {
        switch self {
        case .highlight: return "高亮"
        case .underline: return "下划线"
        case .strikethrough: return "删除线"
        case .square: return "方框"
        case .text: return "文本备注"
        case .freehand: return "手写"
        }
    }
    
    var iconName: String {
        switch self {
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikethrough: return "strikethrough"
        case .square: return "square"
        case .text: return "text.bubble"
        case .freehand: return "pencil.tip"
        }
    }
}

struct AnnotationBounds: Codable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    
    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
    
    init(rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
    }
    
    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

struct PDFAnnotationsData: Codable {
    var materialID: UUID
    var annotations: [PDFAnnotation]
    var lastModified: Date
    
    init(materialID: UUID, annotations: [PDFAnnotation] = []) {
        self.materialID = materialID
        self.annotations = annotations
        self.lastModified = Date()
    }
}
