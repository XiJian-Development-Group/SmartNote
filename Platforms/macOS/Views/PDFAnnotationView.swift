import SwiftUI
import PDFKit

struct PDFAnnotationView: View {
    let material: StudyMaterial
    @StateObject private var annotationService = PDFAnnotationService.shared
    @State private var pdfDocument: PDFDocument?
    @State private var currentPageIndex: Int = 0
    @State private var selectedTool: AnnotationType = .highlight
    @State private var selectedColor: Color = .yellow
    @State private var showExportSheet = false
    @State private var noteText: String = ""
    @State private var showNoteInput = false
    @State private var pendingNoteBounds: CGRect?
    
    private let availableColors: [Color] = [
        .yellow, .green, .blue, .pink, .orange, .purple
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            annotationToolbar
            
            Divider()
            
            if let document = pdfDocument {
                PDFKitView(
                    document: document,
                    currentPageIndex: $currentPageIndex,
                    selectedTool: selectedTool,
                    selectedColor: selectedColor,
                    onAnnotationCreated: handleAnnotationCreated,
                    onTextSelected: handleTextSelected
                )
            } else {
                ProgressView("加载PDF...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showExportSheet) {
            exportSheet
        }
        .alert("添加备注", isPresented: $showNoteInput) {
            TextField("输入备注内容", text: $noteText)
            Button("取消", role: .cancel) {
                pendingNoteBounds = nil
                noteText = ""
            }
            Button("保存") {
                if let bounds = pendingNoteBounds {
                    saveTextAnnotation(bounds: bounds)
                }
                pendingNoteBounds = nil
                noteText = ""
            }
        } message: {
            Text("请输入备注内容")
        }
        .onAppear {
            loadPDF()
        }
    }
    
    private var annotationToolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                toolButtons
                Divider().frame(height: 24)
                colorPicker
                Divider().frame(height: 24)
                actionButtons
                Spacer()
                pageIndicator
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    private var toolButtons: some View {
        HStack(spacing: 8) {
            ForEach(AnnotationType.allCases, id: \.self) { type in
                toolButton(for: type)
            }
        }
    }
    
    private func toolButton(for type: AnnotationType) -> some View {
        Button {
            selectedTool = type
            if type == .text {
                showNoteInput = true
            }
        } label: {
            Image(systemName: type.iconName)
                .foregroundColor(selectedTool == type ? .white : .primary)
        }
        .buttonStyle(.bordered)
        .tint(selectedTool == type ? .accentColor : .clear)
    }
    
    private var colorPicker: some View {
        HStack(spacing: 6) {
            ForEach(availableColors, id: \.self) { color in
                colorButton(color)
            }
        }
    }
    
    private func colorButton(_ color: Color) -> some View {
        Button {
            selectedColor = color
        } label: {
            Circle()
                .fill(color)
                .frame(width: 20, height: 20)
                .overlay(
                    Circle()
                        .stroke(selectedColor == color ? Color.primary : Color.clear, lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
    }
    
    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                showExportSheet = true
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            
            let annotationCount = annotationService.getAnnotations(for: material.id).count
            if annotationCount > 0 {
                Button {
                    annotationService.deleteAllAnnotations(for: material.id)
                    loadPDF()
                } label: {
                    Label("清空", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
    }
    
    private var pageIndicator: some View {
        Group {
            if let document = pdfDocument {
                Text("第 \(currentPageIndex + 1) / \(document.pageCount) 页")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
    }
    
    private var exportSheet: some View {
        VStack(spacing: 16) {
            Text("导出批注")
                .font(.headline)
            
            HStack(spacing: 12) {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Button {
                        exportAnnotations(format: format)
                    } label: {
                        VStack {
                            Image(systemName: "doc")
                            Text(format.rawValue)
                        }
                        .frame(width: 80, height: 60)
                    }
                    .buttonStyle(.bordered)
                }
            }
            
            Button("关闭") {
                showExportSheet = false
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(width: 300, height: 200)
    }
    
    private func loadPDF() {
        guard let url = material.localURL else { return }
        
        if let document = PDFDocument(url: url) {
            pdfDocument = document
            annotationService.applyAnnotations(to: document, materialID: material.id)
        }
    }
    
    private func handleAnnotationCreated(bounds: CGRect, pageIndex: Int) {
        guard selectedTool != .text else { return }
        
        let annotation = PDFAnnotation(
            materialID: material.id,
            pageIndex: pageIndex,
            annotationType: selectedTool,
            bounds: AnnotationBounds(rect: bounds),
            color: colorToHex(selectedColor)
        )
        
        annotationService.addAnnotation(annotation)
    }
    
    private func handleTextSelected(text: String, bounds: CGRect, pageIndex: Int) {
        guard !text.isEmpty else { return }
        
        let annotation = PDFAnnotation(
            materialID: material.id,
            pageIndex: pageIndex,
            annotationType: .highlight,
            bounds: AnnotationBounds(rect: bounds),
            contents: text,
            color: colorToHex(selectedColor)
        )
        
        annotationService.addAnnotation(annotation)
    }
    
    private func saveTextAnnotation(bounds: CGRect) {
        let annotation = PDFAnnotation(
            materialID: material.id,
            pageIndex: currentPageIndex,
            annotationType: .text,
            bounds: AnnotationBounds(rect: bounds),
            contents: noteText,
            color: colorToHex(selectedColor)
        )
        
        annotationService.addAnnotation(annotation)
    }
    
    private func exportAnnotations(format: ExportFormat) {
        if let url = annotationService.exportAnnotations(materialID: material.id, format: format) {
            NSWorkspace.shared.open(url)
        }
        showExportSheet = false
    }
    
    private func colorToHex(_ color: Color) -> String {
        let nsColor = NSColor(color)
        guard let rgbColor = nsColor.usingColorSpace(.deviceRGB) else {
            return "#FFEB3B"
        }
        
        let r = Int(rgbColor.redComponent * 255)
        let g = Int(rgbColor.greenComponent * 255)
        let b = Int(rgbColor.blueComponent * 255)
        
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    @Binding var currentPageIndex: Int
    let selectedTool: AnnotationType
    let selectedColor: Color
    let onAnnotationCreated: (CGRect, Int) -> Void
    let onTextSelected: (String, CGRect, Int) -> Void
    
    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.backgroundColor = NSColor.windowBackgroundColor
        
        pdfView.delegate = context.coordinator
        
        let clickGesture = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        pdfView.addGestureRecognizer(clickGesture)
        
        return pdfView
    }
    
    func updateNSView(_ nsView: PDFView, context: Context) {
        if let page = document.page(at: currentPageIndex) {
            nsView.go(to: page)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, PDFViewDelegate {
        var parent: PDFKitView
        
        init(_ parent: PDFKitView) {
            self.parent = parent
        }
        
        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let pdfView = gesture.view as? PDFView,
                  let page = pdfView.currentPage,
                  let pdfDoc = pdfView.document else { return }
            
            let location = gesture.location(in: pdfView)
            let pagePoint = pdfView.convert(location, to: page)
            
            if parent.selectedTool == .text {
                let bounds = CGRect(x: pagePoint.x - 10, y: pagePoint.y - 10, width: 20, height: 20)
                parent.onAnnotationCreated(bounds, pdfDoc.index(for: page))
            }
        }
        
        func pdfViewSelectionChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let selection = pdfView.currentSelection,
                  let page = selection.pages.first,
                  let selectedText = selection.string, !selectedText.isEmpty,
                  let pdfDoc = pdfView.document else {
                return
            }
            
            let bounds = selection.bounds(for: page)
            let pageIndex = pdfDoc.index(for: page)
            
            DispatchQueue.main.async {
                self.parent.onTextSelected(selectedText, bounds, pageIndex)
            }
        }
    }
}

extension AnnotationType: CaseIterable {
    static var allCases: [AnnotationType] {
        [.highlight, .underline, .strikethrough, .square, .text, .freehand]
    }
}
