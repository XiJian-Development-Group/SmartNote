import Foundation
import Combine

/// 许愿仓库
final class WishService: ObservableObject {

    @Published private(set) var wishes: [Wish] = []
    /// 最近一次写盘失败的原因；成功后清空。
    /// 修复前 save() 只 print，界面无从得知愿望到底存没存上，
    /// 用户表现为「许愿后不知道是否成功」。
    @Published private(set) var saveError: String?

    private let fileURL: URL

    init(storage: StorageService = StorageService()) {
        fileURL = storage.appSupportURL.appendingPathComponent("wishes.json")
        load()
    }

    func load() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            wishes = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            wishes = try decoder.decode([Wish].self, from: data)
            saveError = nil
        } catch {
            print("许愿读取失败：\(error)")
            wishes = []
            saveError = "读取已保存的愿望失败：\(error.localizedDescription)"
        }
    }

    @discardableResult
    private func save() -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(wishes)
            try data.write(to: fileURL, options: .atomic)
            saveError = nil
            return true
        } catch {
            print("许愿保存失败：\(error)")
            saveError = "愿望没能保存到磁盘：\(error.localizedDescription)"
            return false
        }
    }

    func clearSaveError() { saveError = nil }

    @discardableResult
    func add(_ wish: Wish) -> Bool {
        wishes.insert(wish, at: 0)
        return save()
    }

    func update(_ wish: Wish) {
        if let idx = wishes.firstIndex(where: { $0.id == wish.id }) {
            wishes[idx] = wish
            save()
        }
    }

    func remove(id: UUID) {
        wishes.removeAll { $0.id == id }
        save()
    }

    func markFulfilled(id: UUID, fulfilledAt: Date = Date()) {
        if let idx = wishes.firstIndex(where: { $0.id == id }) {
            wishes[idx].status = .fulfilled
            save()
        }
    }

    func restore(id: UUID) {
        if let idx = wishes.firstIndex(where: { $0.id == id }) {
            wishes[idx].status = .wish
            save()
        }
    }
}
