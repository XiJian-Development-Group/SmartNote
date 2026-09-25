import Foundation
import SwiftUI

struct FestivalBlessing: Identifiable, Hashable {
    let id: String
    let title: String
    let message: String
    let symbol: String
}

@MainActor
final class BlessingService: ObservableObject {
    @Published private(set) var currentBlessing: FestivalBlessing
    @Published private(set) var isNationalDayPeriod: Bool

    private let calendar: Calendar
    private let everydayBlessings: [FestivalBlessing]
    private let nationalDayBlessings: [FestivalBlessing]

    private var activeBlessings: [FestivalBlessing] {
        isNationalDayPeriod ? nationalDayBlessings : everydayBlessings
    }

    init(now: Date = Date(), calendar: Calendar = .current) {
        self.calendar = calendar
        let everydayBlessings = [
            FestivalBlessing(id: "steady", title: "愿你所求皆有回应", message: "愿今天的每一份专注，都成为明天稳稳向前的底气。", symbol: "sun.max.fill"),
            FestivalBlessing(id: "calm", title: "愿你从容不迫", message: "把大事拆成小步，把小步走成答案，平静也会陪你走进每一天。", symbol: "leaf.fill"),
            FestivalBlessing(id: "bright", title: "愿你眼里有光", message: "愿你保持好奇，保持热爱，在自己的节奏里收获成长。", symbol: "sparkles"),
            FestivalBlessing(id: "together", title: "愿心愿皆成", message: "愿家人朋友安康，愿所有久别的问候都能抵达，愿幸福从四面八方来。", symbol: "heart.fill"),
            FestivalBlessing(id: "progress", title: "愿你步步有进展", message: "不必和谁比较，今天比昨天多懂一点，就是值得庆祝的进步。", symbol: "chart.line.uptrend.xyaxis"),
            FestivalBlessing(id: "courage", title: "愿你勇敢而坚定", message: "愿你在需要选择的时候，有判断的清晰，也有坚持的勇气。", symbol: "mountain.2.fill"),
            FestivalBlessing(id: "harvest", title: "愿你收获满满", message: "愿播种的努力都有回响，愿你学有所获，也愿生活给你意外的礼物。", symbol: "basket.fill"),
            FestivalBlessing(id: "peace", title: "愿你心中有暖", message: "愿忙碌之外也有休息，愿每一段路都有同行者，平安喜乐常常围绕你。", symbol: "cup.and.saucer.fill"),
            FestivalBlessing(id: "future", title: "愿未来开阔", message: "愿你敢于想象更大的世界，也相信自己有能力把想象变成现实。", symbol: "arrow.up.forward.app"),
            FestivalBlessing(id: "together-work", title: "愿你的付出有回响", message: "愿你的时间有方向，劳动有价值，休息有质量，平凡的日子也会闪闪发光。", symbol: "checkmark.seal.fill"),
            FestivalBlessing(id: "family", title: "愿团圆常在", message: "愿珍惜的人常在身边，愿想见的人很快相见，愿每次相逢都有说不完的话。", symbol: "person.2.fill"),
            FestivalBlessing(id: "new-season", title: "愿新的一页精彩", message: "愿你带着新的勇气出发，也带着照顾好自己的智慧，书写属于自己的精彩章节。", symbol: "book.closed.fill")
        ]
        let nationalDayBlessings = [
            FestivalBlessing(id: "national-day-1", title: "愿祖国山河无恙", message: "愿你在这喜庆的时节里，抬头看山河，也低头读好眼前的书。", symbol: "flag.fill"),
            FestivalBlessing(id: "national-day-2", title: "愿万事顺遂", message: "愿家人安康、朋友顺意，愿所有期待都在合适的时间抵达。", symbol: "gift.fill"),
            FestivalBlessing(id: "national-day-3", title: "愿与你一起成长", message: "愿你把热爱写进日常，把每一次努力都变成未来从容的底气。", symbol: "party.popper.fill")
        ]

        self.everydayBlessings = everydayBlessings
        self.nationalDayBlessings = nationalDayBlessings
        let isNationalDay = Self.isNationalDayPeriod(on: now, calendar: calendar)
        self.isNationalDayPeriod = isNationalDay
        self.currentBlessing = Self.blessing(
            for: now,
            calendar: calendar,
            from: isNationalDay ? nationalDayBlessings : everydayBlessings
        )
    }

    func refresh() {
        isNationalDayPeriod = Self.isNationalDayPeriod(on: Date(), calendar: calendar)
        let pool = activeBlessings
        let candidates = pool.indices.filter { pool[$0].id != currentBlessing.id }
        guard !candidates.isEmpty else { return }
        let nextIndex = candidates.randomElement() ?? 0
        currentBlessing = pool[nextIndex]
    }

    private static func isNationalDayPeriod(on date: Date, calendar: Calendar) -> Bool {
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        return month == 10 && (1...7).contains(day)
    }

    private static func blessing(for date: Date, calendar: Calendar, from blessings: [FestivalBlessing]) -> FestivalBlessing {
        precondition(!blessings.isEmpty, "祝福库不能为空")
        let year = calendar.component(.year, from: date)
        let day = calendar.component(.dayOfYear, from: date)
        let seed = abs(year * 367 + day)
        return blessings[seed % blessings.count]
    }
}

struct FestivalBlessingBar: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var service: BlessingService

    var body: some View {
        ThemeSurface(cornerRadius: 14) {
            HStack(spacing: 12) {
                Image(systemName: service.currentBlessing.symbol)
                    .font(.title3)
                    .foregroundStyle(theme.accentSecondary)
                    .frame(width: 32, height: 32)
                    .background(theme.accent.opacity(0.14))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(service.isNationalDayPeriod ? "国庆祝福" : "今日祝福")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.accentSecondary)
                        Text(service.currentBlessing.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.primaryText)
                    }
                    Text(service.currentBlessing.message)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(2)
                        .help(service.currentBlessing.message)
                }

                Spacer(minLength: 8)

                Button {
                    service.refresh()
                } label: {
                    Label("换一句", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .help("从本地祝福库中换一句")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
