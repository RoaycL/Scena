import Foundation

/// 仅在 SteamCMD 明确报告成功后记录；project.json 存在本身不能证明下载完成。
nonisolated struct WorkshopDownloadReceipt: Codable, Equatable, Sendable {
    struct FileStamp: Codable, Equatable, Sendable {
        let size: Int
        let modified: Date
    }
    let files: [String: FileStamp]
    var contentVersion: WorkshopContentVersion? = nil

    static func capture(folder: URL, contentVersion: WorkshopContentVersion? = nil) -> Self? {
        let fm = FileManager.default
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        guard let data = try? Data(contentsOf: root.appendingPathComponent("project.json")),
              let project = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = project["file"] as? String, !entry.isEmpty else { return nil }
        let entryURL = root.appendingPathComponent(entry).resolvingSymlinksInPath().standardizedFileURL
        guard entryURL.path.hasPrefix(root.path + "/"),
              let entryValues = try? entryURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              entryValues.isRegularFile == true, (entryValues.fileSize ?? 0) > 0 else { return nil }
        var failed = false
        guard let enumerator = fm.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: .skipsHiddenFiles, errorHandler: { _, _ in failed = true; return false }) else { return nil }
        var files: [String: FileStamp] = [:]
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]) else { return nil }
            guard values.isRegularFile == true else { continue }
            guard let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
            files[String(url.path.dropFirst(root.path.count + 1))] = FileStamp(size: size, modified: modified)
        }
        guard !failed, !files.isEmpty else { return nil }
        return Self(files: files, contentVersion: contentVersion)
    }

    func matches(folder: URL) -> Bool { Self.capture(folder: folder)?.files == files }
}
