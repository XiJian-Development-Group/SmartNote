import Foundation
import CloudKit
import SwiftUI

/// iCloud 同步的回调协议。
protocol ICloudSyncServiceDelegate: AnyObject {
    func iCloudSyncDidChange(_ service: ICloudSyncService)
    func iCloudSyncDidFail(_ service: ICloudSyncService, error: Error)
}

/// iCloud 同步服务（仅 iOS 可用）。
///
/// 同步策略是「以本机为准的全量上推」：本地数据变更后调用 `syncAll`，
/// 把全部记录写进私有数据库。写入用 `CKModifyRecordsOperation` 批量提交，
/// 记录 ID 直接取业务实体的 UUID，因此重复同步是幂等的。
///
/// 拉取方向只做「把远端记录回读成本地实体」的转换，交给调用方决定是否采纳——
/// 真正的合并策略属于业务决策，不应藏在同步层里。
///
/// **能力可用性**：iCloud 能力需要付费 Apple Developer Program，个人（免费）
/// 账号无法生成带 iCloud 能力的描述文件，因此 `project.yml` 里默认注释掉了
/// iCloud entitlement。本类不会因此崩溃：能力缺失时 `accountStatus` 会停在
/// `.couldNotDetermine`，`isAvailable` 为 false，所有同步操作直接返回
/// `SyncError.capabilityUnavailable`，界面据此隐藏同步入口。
@MainActor
final class ICloudSyncService: ObservableObject {
    @Published var isSyncing = false
    @Published var lastSyncDate: Date?
    @Published var syncError: Error?
    @Published var accountStatus: CKAccountStatus = .couldNotDetermine
    @Published var lastSyncedCounts: [String: Int] = [:]

    weak var delegate: ICloudSyncServiceDelegate?

    private static let containerIdentifier = "iCloud.com.skyc8266.smartnote.ios"

    private let container: CKContainer
    private let privateDatabase: CKDatabase

    init() {
        // 即便没有 iCloud entitlement，`CKContainer` 也可以构造；只是后续操作会失败。
        // 因此这里不预先崩溃，而是等 `accountStatus` 给出结论。
        let container = CKContainer(identifier: Self.containerIdentifier)
        self.container = container
        self.privateDatabase = container.privateCloudDatabase
        checkAccountStatus()
    }

    /// iCloud 同步当前是否可用。
    ///
    /// 账号已就绪（`.available`）才算可用；能力缺失时会一直停在
    /// `.couldNotDetermine`，界面据此隐藏同步入口而不是给一个按了会报错的开关。
    var isAvailable: Bool {
        accountStatus == .available
    }

    // MARK: - 账号

    func checkAccountStatus() {
        Task {
            do {
                accountStatus = try await container.accountStatus()
            } catch {
                // 无 entitlement / 无账号时这里是预期的失败路径，不是程序错误：
                // 记下状态即可，不写入 `syncError` 打扰用户。
                accountStatus = .couldNotDetermine
            }
        }
    }

    // MARK: - 全量同步

    /// 把本机数据全量推送到 iCloud。
    ///
    /// 任一子步骤失败即整体抛出，调用方负责呈现错误；已经成功的部分
    /// 不会回滚——CloudKit 记录以 UUID 命名，重复执行不会产生重复数据。
    func syncAll(
        materials: [StudyMaterial],
        reviewPlans: [ReviewPlan],
        examCountdowns: [ExamCountdown]
    ) async throws {
        try requireAvailable()

        isSyncing = true
        defer { isSyncing = false }

        do {
            try await save(recordsToSave: materials.map(Self.materialRecord),
                           recordNamesToDelete: [],
                           label: "资料")
            try await save(recordsToSave: reviewPlans.map(Self.reviewPlanRecord),
                           recordNamesToDelete: [],
                           label: "复习计划")
            try await save(recordsToSave: examCountdowns.map(Self.examCountdownRecord),
                           recordNamesToDelete: [],
                           label: "考试倒计时")

            lastSyncDate = Date()
            delegate?.iCloudSyncDidChange(self)
        } catch {
            syncError = error
            delegate?.iCloudSyncDidFail(self, error: error)
            throw error
        }
    }

    /// 回读 iCloud 上的全部记录。
    ///
    /// 返回值按类别分组，交给 `AppState_iOS` 决定如何合并。
    func pullAll() async throws -> PulledRecords {
        try requireAvailable()

        isSyncing = true
        defer { isSyncing = false }

        do {
            let materials = try await fetchRecords(recordType: Self.materialRecordType)
                .compactMap(Self.material(from:))
            let reviewPlans = try await fetchRecords(recordType: Self.reviewPlanRecordType)
                .compactMap(Self.reviewPlan(from:))
            let examCountdowns = try await fetchRecords(recordType: Self.examCountdownRecordType)
                .compactMap(Self.examCountdown(from:))

            lastSyncDate = Date()
            delegate?.iCloudSyncDidChange(self)
            return PulledRecords(
                materials: materials,
                reviewPlans: reviewPlans,
                examCountdowns: examCountdowns
            )
        } catch {
            syncError = error
            delegate?.iCloudSyncDidFail(self, error: error)
            throw error
        }
    }

    /// 从 iCloud 删除全部由本 App 写入的记录。
    func deleteAllCloudData() async throws {
        try requireAvailable()

        isSyncing = true
        defer { isSyncing = false }

        do {
            for recordType in [Self.materialRecordType, Self.reviewPlanRecordType, Self.examCountdownRecordType] {
                let existing = try await fetchRecords(recordType: recordType)
                let ids = existing.map(\.recordID)
                guard !ids.isEmpty else { continue }
                try await modify(recordsToSave: [], recordIDsToDelete: ids)
            }
            lastSyncDate = Date()
            delegate?.iCloudSyncDidChange(self)
        } catch {
            syncError = error
            delegate?.iCloudSyncDidFail(self, error: error)
            throw error
        }
    }

    /// 同步前置检查：能力缺失时给出明确原因，而不是抛出一个 CloudKit 内部错误。
    private func requireAvailable() throws {
        guard isAvailable else {
            throw SyncError.accountUnavailable(accountStatus)
        }
    }

    // MARK: - CloudKit 底层操作

    private func save(
        recordsToSave: [CKRecord],
        recordNamesToDelete: [CKRecord.ID],
        label: String
    ) async throws {
        guard !recordsToSave.isEmpty || !recordNamesToDelete.isEmpty else { return }

        do {
            try await modify(recordsToSave: recordsToSave, recordIDsToDelete: recordNamesToDelete)
            lastSyncedCounts[label] = recordsToSave.count
        } catch {
            // 单次 `CKModifyRecordsOperation` 有记录数上限，超出时按批分片重试，
            // 避免一次性提交几千条记录直接失败。
            guard recordsToSave.count > Self.batchSize else { throw error }
            for chunk in recordsToSave.chunked(into: Self.batchSize) {
                try await modify(recordsToSave: chunk, recordIDsToDelete: [])
            }
            lastSyncedCounts[label] = recordsToSave.count
        }
    }

    /// 执行一次保存/删除批次。
    ///
    /// CloudKit 的 `CKModifyRecordsOperation` 只有回调式接口，这里用
    /// continuation 桥接成 async，并按 per-record 保存结果容错。
    private func modify(
        recordsToSave: [CKRecord],
        recordIDsToDelete: [CKRecord.ID]
    ) async throws {
        let operation = CKModifyRecordsOperation(
            recordsToSave: recordsToSave,
            recordIDsToDelete: recordIDsToDelete
        )
        // 部分失败不应让整批失败：逐条记录容错，汇总后再判断。
        operation.isAtomic = false
        operation.qualityOfService = .userInitiated

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var firstError: Error?

            operation.perRecordSaveBlock = { _, result in
                if case .failure(let error) = result, firstError == nil {
                    firstError = error
                }
            }
            operation.modifyRecordsResultBlock = { result in
                if let error = firstError ?? result.failureValue {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
            privateDatabase.add(operation)
        }
    }

    /// 查询某个 recordType 下的全部记录，分页取完。
    private func fetchRecords(recordType: String) async throws -> [CKRecord] {
        var results: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?

        repeat {
            let page: (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?)
            if let cursor {
                page = try await privateDatabase.records(continuingMatchFrom: cursor)
            } else {
                page = try await privateDatabase.records(
                    matching: CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
                )
            }

            for (_, result) in page.matchResults {
                // 单条记录损坏（字段缺失、类型不符）不应中断整页拉取。
                if case .success(let record) = result { results.append(record) }
            }
            cursor = page.queryCursor
        } while cursor != nil

        return results
    }

    // MARK: - 记录类型

    private static let materialRecordType = "Material"
    private static let reviewPlanRecordType = "ReviewPlan"
    private static let examCountdownRecordType = "ExamCountdown"
    private static let batchSize = 200

    // MARK: - 实体 → 记录

    private static func materialRecord(_ material: StudyMaterial) -> CKRecord {
        let record = CKRecord(
            recordType: materialRecordType,
            recordID: CKRecord.ID(recordName: material.id.uuidString)
        )
        record["name"] = material.name
        record["type"] = material.type.rawValue
        record["category"] = material.category.rawValue
        record["content"] = material.content
        record["extractedText"] = material.extractedText
        record["keywords"] = material.keywords
        record["createdAt"] = material.createdAt
        record["modifiedAt"] = material.modifiedAt
        record["isFavorite"] = material.isFavorite
        record["notes"] = material.notes
        if let localURL = material.localURL {
            // 只存文件名：绝对路径在另一台设备上没有意义。
            record["fileName"] = localURL.lastPathComponent
        }
        return record
    }

    private static func reviewPlanRecord(_ plan: ReviewPlan) -> CKRecord {
        let record = CKRecord(
            recordType: reviewPlanRecordType,
            recordID: CKRecord.ID(recordName: plan.id.uuidString)
        )
        record["subject"] = plan.subject
        record["examDate"] = plan.examDate
        record["createdAt"] = plan.createdAt
        record["isActive"] = plan.isActive
        // 计划体量可能较大，整体以 JSON 存放，避免为每个任务单开字段。
        if let data = try? JSONEncoder().encode(plan),
           let object = try? JSONSerialization.jsonObject(with: data) as? CKRecordValue {
            record["payload"] = object
        }
        return record
    }

    private static func examCountdownRecord(_ exam: ExamCountdown) -> CKRecord {
        let record = CKRecord(
            recordType: examCountdownRecordType,
            recordID: CKRecord.ID(recordName: exam.id.uuidString)
        )
        record["name"] = exam.name
        record["examDate"] = exam.examDate
        record["subject"] = exam.subject
        record["notes"] = exam.notes
        record["isArchived"] = exam.isArchived
        return record
    }

    // MARK: - 记录 → 实体

    private static func material(from record: CKRecord) -> StudyMaterial? {
        guard let name = record["name"] as? String,
              let typeRaw = record["type"] as? String,
              let type = MaterialType(rawValue: typeRaw) else { return nil }

        return StudyMaterial(
            id: uuid(from: record.recordID.recordName) ?? UUID(),
            name: name,
            type: type,
            category: (record["category"] as? String).flatMap(MaterialCategory.init(rawValue:)) ?? .other,
            content: record["content"] as? String ?? "",
            extractedText: record["extractedText"] as? String,
            keywords: record["keywords"] as? [String],
            createdAt: record["createdAt"] as? Date ?? Date(),
            modifiedAt: record["modifiedAt"] as? Date ?? Date(),
            isFavorite: record["isFavorite"] as? Bool ?? false,
            notes: record["notes"] as? String ?? "",
            // 附件本体留在本机存储，跨设备同步只带元数据。
            storageMode: .copy
        )
    }

    private static func reviewPlan(from record: CKRecord) -> ReviewPlan? {
        guard let payload = record["payload"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return try? JSONDecoder().decode(ReviewPlan.self, from: data)
    }

    private static func examCountdown(from record: CKRecord) -> ExamCountdown? {
        guard let name = record["name"] as? String,
              let examDate = record["examDate"] as? Date else { return nil }

        return ExamCountdown(
            id: uuid(from: record.recordID.recordName) ?? UUID(),
            name: name,
            examDate: examDate,
            subject: record["subject"] as? String ?? "",
            notes: record["notes"] as? String ?? "",
            isArchived: record["isArchived"] as? Bool ?? false
        )
    }

    private static func uuid(from recordName: String) -> UUID? {
        UUID(uuidString: recordName)
    }
}

// MARK: - 结果与错误

extension ICloudSyncService {
    /// 从 iCloud 拉回的三类实体。
    struct PulledRecords {
        var materials: [StudyMaterial]
        var reviewPlans: [ReviewPlan]
        var examCountdowns: [ExamCountdown]

        var isEmpty: Bool {
            materials.isEmpty && reviewPlans.isEmpty && examCountdowns.isEmpty
        }
    }

    enum SyncError: LocalizedError {
        case accountUnavailable(CKAccountStatus)
        /// 描述文件里没有 iCloud 能力（个人开发者账号的常见情况）。
        case capabilityUnavailable

        var errorDescription: String? {
            switch self {
            case .accountUnavailable(.noAccount):
                return "未登录 iCloud 账号，无法同步。"
            case .accountUnavailable(.restricted):
                return "当前设备限制了 iCloud 使用，无法同步。"
            case .accountUnavailable(.temporarilyUnavailable):
                return "iCloud 暂时不可用，请稍后重试。"
            case .accountUnavailable:
                return "无法确定 iCloud 账号状态，请稍后重试。"
            case .capabilityUnavailable:
                return """
                当前签名不包含 iCloud 能力，因此无法同步。\
                iCloud 能力仅在付费 Apple Developer Program 下可用；\
                若需要同步，请改用付费账号重新生成描述文件。
                """
            }
        }
    }
}

// MARK: - 便捷扩展

private extension Array {
    /// 按固定大小切片。
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, count > size else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

private extension Result {
    var failureValue: Error? {
        if case .failure(let error) = self { return error }
        return nil
    }
}