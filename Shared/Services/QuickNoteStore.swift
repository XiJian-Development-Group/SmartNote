import Foundation

/// 快速笔记：Siri 调 CreateQuickNoteIntent 时使用的存储。
/// 与 MenuBarContentView 的快速记录复用同一目录同一格式。
enum QuickNoteStore {

    /// 把一段文字落到 Application Support/QuickNotes/<yyyy-MM-dd>.md
    static func append(text: String, storage: StorageService = StorageService()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let dir = storage.appSupportURL.appendingPathComponent("QuickNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let day = formatter.string(from: Date())
        let url = dir.appendingPathComponent("\(day).md")
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
        let line = "## \(stamp)\n\n\(trimmed)\n\n"
        if FileManager.default.fileExists(atPath: url.path) {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                if let d = line.data(using: .utf8) { h.write(d) }
                try? h.close()
            }
        } else {
            try? line.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }
}
