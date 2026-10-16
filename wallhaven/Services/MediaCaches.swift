//
//  MediaCaches.swift
//  wallhaven
//
//  图片以外的网络媒体缓存：在线视频预览、工坊动图预览；以及「清除缓存」需要覆盖的其他系统缓存。
//

import CryptoKit
import Foundation
import WebKit

/// 在线视频壁纸的低分辨率预览（几 MB）：第一次选中时下载到缓存目录，之后直接播放本地文件，
/// 来回切换不再重复下载。按最近使用时间淘汰，总量不超过上限
actor RemoteVideoCache {
    static let shared = RemoteVideoCache(directory: CacheLocations.root.appendingPathComponent("VideoPreviews", isDirectory: true))

    private let directory: URL
    private let sizeLimit: Int64
    private var tasks: [URL: Task<URL, Error>] = [:]

    init(directory: URL, sizeLimit: Int64 = 512 * 1024 * 1024) {
        self.directory = directory
        self.sizeLimit = sizeLimit
    }

    nonisolated func file(for remote: URL) -> URL {
        let name = SHA256.hash(data: Data(remote.absoluteString.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".mp4")
    }

    /// 已缓存时直接返回（并刷新使用时间），否则下载；同一地址同时只下载一次
    func localURL(for remote: URL) async throws -> URL {
        let file = file(for: remote)
        if FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return file
        }
        if let task = tasks[remote] { return try await task.value }
        let directory = directory
        let task = Task<URL, Error> {
            var request = URLRequest(url: remote)
            for (field, value) in WallpaperSources.requestHeaders(for: remote) { request.setValue(value, forHTTPHeaderField: field) }
            let (temp, response) = try await URLSession.shared.download(for: request)
            defer { try? FileManager.default.removeItem(at: temp) }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw WallperError.network("预览视频加载失败。")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: temp, to: file)
            return file
        }
        tasks[remote] = task
        defer { tasks[remote] = nil }
        let result = try await task.value
        prune()
        return result
    }

    private func prune() {
        let entries = CacheLocations.files(in: directory).sorted { $0.modified > $1.modified }
        var total: Int64 = 0
        for entry in entries {
            total += entry.size
            if total > sizeLimit { try? FileManager.default.removeItem(at: entry.url) }
        }
    }

    func clear() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }
}

nonisolated enum CacheLocations {
    static let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.roayc.wallhaven", isDirectory: true)

    static let animatedPreviews = root.appendingPathComponent("AnimatedPreviews", isDirectory: true)

    /// 工坊动图预览（GIF 常有 1～5 MB）：系统默认的网络缓存太小，单个文件超过上限就不缓存，
    /// 这里给一个独立的大缓存，并优先使用缓存（预览图发布后不会变）
    static let previewSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024, directory: animatedPreviews)
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    /// 系统网络缓存和 WebKit 缓存（Steam 登录页、工坊网页渲染器）所在目录
    private static var systemCaches: [URL] {
        ["Cache.db", "Cache.db-wal", "Cache.db-shm", "fsCachedData", "WebKit"].map { root.appendingPathComponent($0) }
    }

    /// 不经过 Kingfisher 和视频封面缓存的部分：在线视频预览、动图预览、系统网络和 WebKit 缓存
    static func otherCachesSize() -> Int64 {
        ([root.appendingPathComponent("VideoPreviews"), animatedPreviews] + systemCaches).reduce(0) { $0 + size(of: $1) }
    }

    @MainActor
    static func clearOtherCaches() async {
        await RemoteVideoCache.shared.clear()
        previewSession.configuration.urlCache?.removeAllCachedResponses()
        URLCache.shared.removeAllCachedResponses()
        // 只清网页缓存，不动 Cookie（Steam 网页登录状态保留）
        let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache]
        await WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast)
    }

    static func files(in directory: URL) -> [(url: URL, size: Int64, modified: Date)] {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(values.totalFileAllocatedSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
    }

    static func size(of url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            return Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
