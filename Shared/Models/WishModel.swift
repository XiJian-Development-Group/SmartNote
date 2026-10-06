import Foundation

/// 许愿条目
struct Wish: Codable, Identifiable, Hashable {
    let id: UUID
    var content: String
    var createdAt: Date
    var status: Status

    /// 视觉颜色：手动指定或随机
    var accent: AccentColor

    enum Status: String, Codable {
        case wish       // 许愿中
        case fulfilled  // 已还愿
    }

    enum AccentColor: String, Codable, CaseIterable {
        case gold
        case rose
        case violet
        case cyan
        case mint
        case amber

        var swiftColor: WishColor {
            switch self {
            case .gold:   return WishColor(r: 1.00, g: 0.84, b: 0.42)
            case .rose:   return WishColor(r: 1.00, g: 0.64, b: 0.74)
            case .violet: return WishColor(r: 0.78, g: 0.65, b: 1.00)
            case .cyan:   return WishColor(r: 0.55, g: 0.88, b: 1.00)
            case .mint:   return WishColor(r: 0.66, g: 0.95, b: 0.78)
            case .amber:  return WishColor(r: 1.00, g: 0.72, b: 0.30)
            }
        }
    }

    init(id: UUID = UUID(), content: String, status: Status = .wish, accent: AccentColor, createdAt: Date = Date()) {
        self.id = id
        self.content = content
        self.status = status
        self.accent = accent
        self.createdAt = createdAt
    }

    /// "x days ago" 形如中文短描述
    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// SwiftUI Color 辅助（脱离 SwiftUI 单独定义以便纯模型使用）
struct WishColor: Hashable {
    var r: Double
    var g: Double
    var b: Double
}

import SwiftUI
extension WishColor {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0) }
}
