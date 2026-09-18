import Foundation
import Combine

/// 许愿仓库
final class WishService: ObservableObject {

    @Published private(set) var wishes: [Wish] = []

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
        } catch {
            print("许愿读取失败：\(error)")
            wishes = []
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(wishes)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("许愿保存失败：\(error)")
        }
    }

    func add(_ wish: Wish) {
        wishes.insert(wish, at: 0)
        save()
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
