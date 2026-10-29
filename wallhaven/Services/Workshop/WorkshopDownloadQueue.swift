import Foundation

nonisolated enum DownloadState: String, Codable, Sendable {
    case none, queued, downloading, paused, completed, failed, cancelled

    var label: String {
        switch self {
        case .none: "未下载"
        case .queued: "排队中"
        case .downloading: "下载中"
        case .paused: "已暂停"
        case .completed: "已完成"
        case .failed: "下载失败"
        case .cancelled: "已停止"
        }
    }
}

nonisolated struct WorkshopDownloadJob: Codable, Identifiable, Sendable {
    let id: String
    var title: String
    var state: DownloadState
    var error: String?
    var applyWhenDone = false
    /// 工坊详情里的文件大小，用于显示进度（未知时为 nil）
    var totalBytes: Int64? = nil
    /// 更新 / 强制校验意图必须跨重启保留，不能被“本地已完整”短路。
    var requiresValidation: Bool? = nil

    var canCompleteLocally: Bool { [.queued, .paused].contains(state) && requiresValidation != true }
}

/// 每个条目单独结算；中断一个批次不会丢弃其中其他条目的下载意图。
nonisolated enum WorkshopDownloadQueue {
    static func restored(_ jobs: [WorkshopDownloadJob]) -> [WorkshopDownloadJob] {
        var seen = Set<String>()
        return jobs.filter { !$0.id.isEmpty && $0.id.allSatisfy(\.isNumber) && seen.insert($0.id).inserted }.map {
            var job = $0
            if job.state == .queued || job.state == .downloading { job.state = .paused }
            // 重启后恢复下载应由用户触发，且不能突然更换桌面。
            job.applyWhenDone = false
            return job
        }
    }

    static func settle(_ jobs: [WorkshopDownloadJob], batch: Set<String>,
                       downloaded: Set<String>, failures: [String: String], interrupted: Bool) -> [WorkshopDownloadJob] {
        jobs.map {
            var job = $0
            guard batch.contains(job.id), job.state != .cancelled else { return job }
            if downloaded.contains(job.id) {
                job.state = .completed
                job.error = nil
                job.requiresValidation = nil
            } else if job.state == .downloading {
                job.state = interrupted ? .queued : .failed
                job.error = interrupted ? nil : (failures[job.id] ?? "下载未完成")
            }
            return job
        }
    }
}
