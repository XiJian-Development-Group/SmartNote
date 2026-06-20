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
    
    /// 擦除：删除部分对象 + 修改部分笔划（不记录撤销）
    /// - Parameters:
    ///   - removeIds: 要完全移除的对象 ID
    ///   - strokeReplacements: 原笔划 ID -> 擦除后生成的笔划列表（0 个 = 移除，1 个 = 替换，2+ 个 = 拆分）
    func eraseAndReplace(removeIds: Set<UUID>, strokeReplacements: [(id: UUID, newStrokes: [StrokeShape])]) {
        guard var doc = currentDocument else { return }
        if removeIds.isEmpty && strokeReplacements.isEmpty { return }
        
        // 不在每次拖动时记录撤销，避免撤销栈爆满
        // 撤销时按最终状态回退即可
        
        var workingRemoveIds = removeIds
        
        // 1) 计算需要替换的 ID 集合
        var replaceIds = Set<UUID>()
        for (id, newStrokes) in strokeReplacements {
            replaceIds.insert(id)
            // 新的笔划数量为 0，等价于删除
            if newStrokes.isEmpty {
                workingRemoveIds.insert(id)
            }
        }
        
        // 2) 构建新的对象列表
        var newObjects: [WhiteboardObject] = []
        for obj in doc.objects {
            if workingRemoveIds.contains(obj.id) {
                continue
            }
            if replaceIds.contains(obj.id) {
                // 找到替换笔划
                if let replacement = strokeReplacements.first(where: { $0.id == obj.id }) {
                    for s in replacement.newStrokes {
                        newObjects.append(.stroke(s))
                    }
                }
                // 如果没找到或 newStrokes 为空，则跳过（删除）
            } else {
                newObjects.append(obj)
            }
        }
        
        doc.objects = newObjects
        doc.updatedAt = Date()
        updateCurrentDocument(doc)
    }
    
    /// 移动多个对象（实时拖动用）
    func moveObjects(_ objects: [WhiteboardObject], by offset: WhiteboardPoint, recordUndo: Bool = false) {
        guard var doc = currentDocument, !objects.isEmpty else { return }
        if recordUndo {
            pushUndoState(doc.objects)
        }
        
        for origObj in objects {
            guard let newObj = translateObject(origObj, by: offset) else { continue }
            if let index = doc.objects.firstIndex(where: { $0.id == origObj.id }) {
                doc.objects[index] = newObj
            }
        }
        doc.updatedAt = Date()
        updateCurrentDocument(doc)
    }
    
    private func translateObject(_ object: WhiteboardObject, by offset: WhiteboardPoint) -> WhiteboardObject? {
        switch object {
        case .stroke(let s): return .stroke(s.translated(by: offset))
        case .rectangle(let r): return .rectangle(r.translated(by: offset))
        case .ellipse(let e): return .ellipse(e.translated(by: offset))
        case .triangle(let t): return .triangle(t.translated(by: offset))
        case .line(let l): return .line(l.translated(by: offset))
        case .arrow(let a): return .arrow(a.translated(by: offset))
        }
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
        // 3 秒后自动保存（已经在 scheduleAutoSave 中做了 debounce）
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
