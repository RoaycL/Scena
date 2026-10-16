import Foundation

/// 缓存元数据不代表下载完整。下载完成仍由 WorkshopDownloadReceipt 单独确认。
actor WorkshopLibraryIndex {
    static let shared = WorkshopLibraryIndex(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.roayc.wallhaven/workshop-library-v1.json"))

    private struct Stamp: Codable, Equatable {
        let size: Int?
        let modified: Date?
        let created: Date?

        init?(_ url: URL) {
            var fresh = URL(fileURLWithPath: url.path)
            fresh.removeAllCachedResourceValues()
            guard let values = try? fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey]) else { return nil }
            size = values.fileSize
            modified = values.contentModificationDate
            created = values.creationDate
        }
    }

    private struct Record: Codable, Equatable {
        var item: WorkshopItem
        let project: Stamp
        let directory: Stamp?
        let entry: Stamp?
        let preview: Stamp?
        let checkedSizeAt: Date

        func matches(_ folder: URL, now: Date) -> Bool {
            project == Stamp(folder.appendingPathComponent("project.json"))
                && directory == Stamp(folder)
                && entry == item.entryFile.flatMap { Stamp(folder.appendingPathComponent($0)) }
                && preview == item.previewURL.flatMap(Stamp.init)
                && now.timeIntervalSince(checkedSizeAt) < 86400
        }
    }

    private struct Snapshot: Codable, Equatable {
        let version: Int
        var roots: [String: [String: Record]]
    }

    struct Statistics: Sendable {
        var parsedProjects = 0
        var reusedProjects = 0
    }

    private let url: URL
    private var snapshot = Snapshot(version: 1, roots: [:])
    private var loaded = false
    private(set) var statistics = Statistics()

    init(url: URL) { self.url = url }

    /// actor 串行扫描与落盘：旧的并行扫描不能随后把新索引写回旧状态。
    func scan(roots: [URL], now: Date = Date()) -> [WorkshopItem] {
        loadIfNeeded()
        var next = snapshot
        var result: [WorkshopItem] = []
        var stats = Statistics()
        let fm = FileManager.default
        for root in roots {
            guard !Task.isCancelled else { return [] }
            let key = root.standardizedFileURL.path
            let folders: [URL]
            if fm.fileExists(atPath: root.appendingPathComponent("project.json").path) {
                folders = [root]
            } else {
                // 未挂载、权限失败等都保留旧索引。不可用条目不作为已下载返回。
                guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) else { continue }
                folders = children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            }
            var records: [String: Record] = [:]
            for folder in folders {
                guard !Task.isCancelled else { return [] }
                let path = folder.standardizedFileURL.path
                if let cached = snapshot.roots[key]?[path], cached.matches(folder, now: now) {
                    records[path] = cached
                    result.append(cached.item)
                    stats.reusedProjects += 1
                    continue
                }
                guard let project = Stamp(folder.appendingPathComponent("project.json")) else { continue }
                guard var item = WorkshopItem.load(from: folder) else { continue }
                // 读取中内容发生变化的条目不提交缓存，下一次扫描重新核验。
                guard project == Stamp(folder.appendingPathComponent("project.json")) else { continue }
                item.downloadedAt = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                records[path] = Record(item: item, project: project, directory: Stamp(folder),
                    entry: item.entryFile.flatMap { Stamp(folder.appendingPathComponent($0)) },
                    preview: item.previewURL.flatMap(Stamp.init), checkedSizeAt: now)
                result.append(item)
                stats.parsedProjects += 1
            }
            next.roots[key] = records
        }
        guard !Task.isCancelled else { return [] }
        if snapshot != next {
            snapshot = next
            persist()
        }
        statistics = stats
        return Self.sortedUnique(result)
    }

    /// 快照仅用于先显示列表；订阅下载差集必须等待 scan 的真实磁盘核验。
    func cachedItems(roots: [URL]) -> [WorkshopItem] {
        loadIfNeeded()
        return Self.sortedUnique(roots.flatMap { root -> [WorkshopItem] in
            guard FileManager.default.fileExists(atPath: root.path) else { return [] }
            return (snapshot.roots[root.standardizedFileURL.path] ?? [:]).values.compactMap { record in
                guard let folder = record.item.localFolder,
                      FileManager.default.fileExists(atPath: folder.appendingPathComponent("project.json").path) else { return nil }
                return record.item
            }
        })
    }

    func invalidate(folder: URL) {
        loadIfNeeded()
        for key in Array(snapshot.roots.keys) {
            snapshot.roots[key]?[folder.standardizedFileURL.path] = nil
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Snapshot.self, from: data), saved.version == 1 {
            snapshot = saved
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(snapshot) else { return }
        // 未变化时避免唤醒磁盘与重复原子替换。
        guard (try? Data(contentsOf: url)) != data else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func sortedUnique(_ items: [WorkshopItem]) -> [WorkshopItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
            .sorted { ($0.downloadedAt ?? .distantPast) > ($1.downloadedAt ?? .distantPast) }
    }
}
