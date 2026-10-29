import Foundation

/// Steam 的内容版本；清单 ID 保持字符串，避免 UInt64 经 Double 转换丢失精度。
nonisolated struct WorkshopContentVersion: Codable, Hashable, Sendable {
    var manifestID: String?
    var updatedAt: Int64?

    init(manifestID: String? = nil, updatedAt: Int64? = nil) {
        self.manifestID = manifestID.flatMap { !$0.isEmpty && $0 != "0" && $0.allSatisfy(\.isNumber) ? $0 : nil }
        self.updatedAt = updatedAt.flatMap { $0 > 0 ? $0 : nil }
    }

    init?(json: [String: Any]) {
        func string(_ value: Any?) -> String? {
            (value as? String) ?? (value as? NSNumber)?.stringValue
        }
        self.init(manifestID: string(json["hcontent_file"] ?? json["manifestId"]),
                  updatedAt: string(json["time_updated"] ?? json["updatedAt"]).flatMap(Int64.init))
        if manifestID == nil && updatedAt == nil { return nil }
    }
}

nonisolated enum WorkshopUpdateStatus: Equatable, Sendable {
    case current, available, unverified

    var label: String {
        switch self {
        case .current: "已是最新版本"
        case .available: "可更新"
        case .unverified: "需要校验版本"
        }
    }

    static func compare(remote: WorkshopContentVersion, installed: WorkshopContentVersion?) -> Self {
        guard let installed else { return .unverified }
        if let remoteTime = remote.updatedAt, let localTime = installed.updatedAt, remoteTime < localTime {
            return .current // 查询快照比实际下载的版本旧，不能反向降级。
        }
        if let remoteID = remote.manifestID, let localID = installed.manifestID {
            return remoteID == localID ? .current : .available
        }
        if let remoteTime = remote.updatedAt, let localTime = installed.updatedAt {
            return remoteTime > localTime ? .available : .current
        }
        return .unverified
    }

    /// 后台检查不恢复用户暂停、停止或失败的任务；手动“全部更新”也保留暂停状态。
    func canEnqueue(job: WorkshopDownloadJob?, automatic: Bool) -> Bool {
        guard self != .current else { return false }
        guard let job else { return true }
        if automatic { return job.state == .completed }
        return ![.queued, .downloading, .paused].contains(job.state)
    }
}

nonisolated struct WorkshopUpdateInventory: Sendable {
    var items: [String: WorkshopItem] = [:]
    var statuses: [String: WorkshopUpdateStatus] = [:]

    init(local: [WorkshopItem], remote: [WorkshopItem], receipts: [String: WorkshopDownloadReceipt]) {
        let byID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in local {
            guard item.type.isPlayable, let folder = item.localFolder,
                  FileManager.default.fileExists(atPath: folder.appendingPathComponent("project.json").path),
                  let remote = byID[item.id], remote.type.isPlayable, let version = remote.contentVersion else { continue }
            var linked = remote
            linked.localFolder = folder
            linked.entryFile = item.entryFile
            items[item.id] = linked
            let receipt = receipts[item.id]
            let installed = receipt?.matches(folder: folder) == true ? receipt?.contentVersion : nil
            statuses[item.id] = .compare(remote: version, installed: installed)
        }
    }
}

/// 完整暂存成功后换入同盘目录；发布失败时把旧版移回。
nonisolated enum WorkshopUpdateInstallation {
    static func install(staged: URL, destination: URL, move: (URL, URL) throws -> Void = {
        try FileManager.default.moveItem(at: $0, to: $1)
    }) throws {
        let fm = FileManager.default
        guard WorkshopDownloadReceipt.capture(folder: staged) != nil else { throw CocoaError(.fileReadCorruptFile) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent)-previous-\(UUID().uuidString)")
        let hadPrevious = fm.fileExists(atPath: destination.path)
        if hadPrevious { try move(destination, backup) }
        do { try move(staged, destination) }
        catch {
            if hadPrevious { try fm.moveItem(at: backup, to: destination) }
            throw error
        }
        if hadPrevious { try? fm.removeItem(at: backup) }
    }
}
