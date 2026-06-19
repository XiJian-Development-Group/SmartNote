import Foundation
import SwiftUI
import Combine

/// 白板服务 - 管理画板文档、撤销/重做、自动保存
class WhiteboardService: ObservableObject {
    static let shared = WhiteboardService()
    
    @Published var documents: [WhiteboardDocument] = []
    @Published var currentDocument: WhiteboardDocument?
    
    // 撤销/重做栈
    @Published private(set) var canUndo: Bool = false
    @Published private(set) var canRedo: Bool = false
    
    private var undoStack: [[WhiteboardObject]] = []
    private var redoStack: [[WhiteboardObject]] = []
    private let maxUndoLevels = 50
    
    // 自动保存
    private var autoSaveTimer: Timer?
    private let autoSaveInterval: TimeInterval = 3.0
    private var lastSaveTime: Date = Date()
    
    // 存储路径
    private let documentsFileName = "whiteboards.json"
    
    private init() {
        loadDocuments()
        if documents.isEmpty {
            // 创建默认空白画板
            let defaultDoc = WhiteboardDocument(name: "我的画板")
            documents.append(defaultDoc)
            currentDocument = defaultDoc
            saveDocuments()
        } else {
            currentDocument = documents.first
        }
    }
    
    // MARK: - 文档管理
    
    /// 创建新画板
    @discardableResult
    func createDocument(name: String = "未命名画板") -> WhiteboardDocument {
        let doc = WhiteboardDocument(name: name)
        documents.append(doc)
        currentDocument = doc
        resetUndoStacks()
        saveDocuments()
        return doc
    }
    
    /// 切换到指定画板
    func selectDocument(_ doc: WhiteboardDocument) {
        currentDocument = doc
        resetUndoStacks()
    }
    
    /// 删除画板
    func deleteDocument(_ doc: WhiteboardDocument) {
        documents.removeAll { $0.id == doc.id }
        if currentDocument?.id == doc.id {
            currentDocument = documents.first
            resetUndoStacks()
        }
        saveDocuments()
    }
    
    /// 重命名画板
    func renameDocument(_ doc: WhiteboardDocument, to newName: String) {
        if let index = documents.firstIndex(where: { $0.id == doc.id }) {
            documents[index].name = newName
            if currentDocument?.id == doc.id {
                currentDocument = documents[index]
            }
            saveDocuments()
        }
    }
    
    // MARK: - 对象操作（带撤销支持）
    
    /// 添加对象
    func addObject(_ object: WhiteboardObject) {
        guard var doc = currentDocument else { return }
        pushUndoState(doc.objects)
        doc.objects.append(object)
        doc.updatedAt = Date()
        updateCurrentDocument(doc)
    }
    
    /// 添加多个对象（用于粘贴等）
    func addObjects(_ objects: [WhiteboardObject]) {
        guard var doc = currentDocument, !objects.isEmpty else { return }
        pushUndoState(doc.objects)
        doc.objects.append(contentsOf: objects)
        doc.updatedAt = Date()
        updateCurrentDocument(doc)
    }
    
    /// 删除对象
    func deleteObjects(_ objects: [WhiteboardObject]) {
        guard var doc = currentDocument, !objects.isEmpty else { return }
        let ids = Set(objects.map { $0.id })
        pushUndoState(doc.objects)
        doc.objects.removeAll { ids.contains($0.id) }
        doc.updatedAt = Date()
        updateCurrentDocument(doc)
    }
    
    /// 删除指定 ID 的对象
    func deleteObjects(ids: Set<UUID>) {
        guard var doc = currentDocument, !ids.isEmpty else { return }
        pushUndoState(doc.objects)
        doc.objects.removeAll { ids.contains($0.id) }
        doc.updatedAt = Date()
        updateCurrentDocument(doc)
    }
    
    /// 替换所有对象（用于撤销/重做）
    func replaceAllObjects(_ objects: [WhiteboardObject], recordUndo: Bool = false) {
        guard var doc = currentDocument else { return }
        if recordUndo {
            pushUndoState(doc.objects)
        }
        doc.objects = objects
        doc.updatedAt = Date()
        updateCurrentDocument(doc)
    }
    
    /// 更新单个对象
    func updateObject(_ object: WhiteboardObject) {
        guard var doc = currentDocument,
              let index = doc.objects.firstIndex(where: { $0.id == object.id }) else { return }
        pushUndoState(doc.objects)
        doc.objects[index] = object
        doc.updatedAt = Date()
        updateCurrentDocument(doc)
    }
    
    /// 复制对象
    func copyObjects(_ objects: [WhiteboardObject], offset: WhiteboardPoint = WhiteboardPoint(x: 20, y: 20)) {
        var copied: [WhiteboardObject] = []
        for obj in objects {
            var newObj = obj
            // 修改 ID 避免冲突
            switch newObj {
            case .stroke(var s):
                s.id = UUID()
                copied.append(.stroke(s.translated(by: offset)))
            case .rectangle(var s):
                s.id = UUID()
                copied.append(.rectangle(s.translated(by: offset)))
            case .ellipse(var s):
                s.id = UUID()
                copied.append(.ellipse(s.translated(by: offset)))
            case .triangle(var s):
                s.id = UUID()
                copied.append(.triangle(s.translated(by: offset)))
            case .line(var s):
                s.id = UUID()
                copied.append(.line(s.translated(by: offset)))
            case .arrow(var s):
                s.id = UUID()
                copied.append(.arrow(s.translated(by: offset)))
            }
        }
        addObjects(copied)
    }
    
    // MARK: - 撤销/重做
    
    private func pushUndoState(_ currentState: [WhiteboardObject]) {
        undoStack.append(currentState)
        if undoStack.count > maxUndoLevels {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
        canUndo = true
        canRedo = false
    }
    
    func undo() {
        guard canUndo, let doc = currentDocument else { return }
        redoStack.append(doc.objects)
        let previousState = undoStack.removeLast()
        var newDoc = doc
        newDoc.objects = previousState
        newDoc.updatedAt = Date()
        updateCurrentDocument(newDoc)
        canUndo = !undoStack.isEmpty
        canRedo = true
    }
    
    func redo() {
        guard canRedo, let doc = currentDocument else { return }
        undoStack.append(doc.objects)
        let nextState = redoStack.removeLast()
        var newDoc = doc
        newDoc.objects = nextState
        newDoc.updatedAt = Date()
        updateCurrentDocument(newDoc)
        canRedo = !redoStack.isEmpty
        canUndo = true
    }
    
    func resetUndoStacks() {
        undoStack.removeAll()
        redoStack.removeAll()
        canUndo = false
        canRedo = false
    }
    
    // MARK: - 持久化
    
    private func updateCurrentDocument(_ doc: WhiteboardDocument) {
        if let index = documents.firstIndex(where: { $0.id == doc.id }) {
            documents[index] = doc
        }
        currentDocument = doc
        scheduleAutoSave()
    }
    
    private func scheduleAutoSave() {
        autoSaveTimer?.invalidate()
        autoSaveTimer = Timer.scheduledTimer(withTimeInterval: autoSaveInterval, repeats: false) { [weak self] _ in
            self?.saveDocuments()
        }
    }
    
    /// 立即保存
    func saveDocuments() {
        do {
            let url = storageURL()
            let data = try JSONEncoder().encode(documents)
            try data.write(to: url, options: .atomic)
            lastSaveTime = Date()
        } catch {
            print("[WhiteboardService] Save failed: \(error)")
        }
    }
    
    /// 加载文档
    func loadDocuments() {
        do {
            let url = storageURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let data = try Data(contentsOf: url)
            documents = try JSONDecoder().decode([WhiteboardDocument].self, from: data)
        } catch {
            print("[WhiteboardService] Load failed: \(error)")
            documents = []
        }
    }
    
    private func storageURL() -> URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths.first!.appendingPathComponent("SmartNote", isDirectory: true)
        if !FileManager.default.fileExists(atPath: appSupport.path) {
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        }
        return appSupport.appendingPathComponent(documentsFileName)
    }
    
    /// 获取自动保存状态信息
    var autoSaveStatus: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "已自动保存于 \(formatter.string(from: lastSaveTime))"
    }
}
