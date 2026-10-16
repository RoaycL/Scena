import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import Kingfisher
import UniformTypeIdentifiers

nonisolated enum VideoPosterTier: String, Hashable, Sendable {
    case list, poster

    var maxPixelSize: Int { self == .list ? 480 : 1920 }
}

/// 文件内容变更后换键，避免同路径替换素材仍命中旧图片。
nonisolated struct VideoPosterRequest: Hashable, Sendable {
    let url: URL
    let tier: VideoPosterTier
    let cacheKey: String

    init(url: URL, tier: VideoPosterTier) {
        self.url = url.standardizedFileURL
        self.tier = tier
        var fresh = URL(fileURLWithPath: url.path)
        fresh.removeAllCachedResourceValues()
        let values = try? fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
        let identity = "video-poster-v1|\(self.url.path)|\(values?.fileSize ?? -1)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.creationDate?.timeIntervalSince1970 ?? 0)|\(tier.rawValue)"
        cacheKey = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct VideoPosterProvider: ImageDataProvider {
    let request: VideoPosterRequest
    var cacheKey: String { request.cacheKey }

    init(url: URL, tier: VideoPosterTier) { request = VideoPosterRequest(url: url, tier: tier) }

    func data(handler: @escaping @Sendable (Result<Data, any Error>) -> Void) {
        // Kingfisher 的消费者取消不取消共享取帧任务，其他可见卡片仍能得到结果。
        Task(priority: .userInitiated) {
            do { handler(.success(try await VideoPosterCache.shared.data(for: request))) }
            catch { handler(.failure(error)) }
        }
    }
}

actor VideoPosterCache {
    static let shared = VideoPosterCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.roayc.wallhaven/VideoPosters", isDirectory: true))

    typealias Generator = @Sendable (VideoPosterRequest) async throws -> Data
    private let directory: URL
    private let generator: Generator
    private let sizeLimit: Int
    private var tasks: [String: Task<Data, Error>] = [:]
    private var active = 0
    private var waiters: [(foreground: Bool, continuation: CheckedContinuation<Void, Never>)] = []
    private var epoch = 0
    private var lastPruned = Date.distantPast
    private var knownDiskSize: Int?

    init(directory: URL, sizeLimit: Int = 256 * 1024 * 1024, generator: @escaping Generator = VideoPosterCache.generate) {
        self.directory = directory
        self.sizeLimit = sizeLimit
        self.generator = generator
    }

    func data(for request: VideoPosterRequest, foreground: Bool = true) async throws -> Data {
        guard request == VideoPosterRequest(url: request.url, tier: request.tier) else { throw CocoaError(.fileReadUnknown) }
        if let task = tasks[request.cacheKey] { return try await task.value }
        let file = directory.appendingPathComponent(request.cacheKey + ".jpg")
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if Date().timeIntervalSince(modified) < 14 * 86400, let data = try? Data(contentsOf: file) { return data }
        let token = epoch
        let task = Task { try await produce(request, file: file, epoch: token, foreground: foreground) }
        tasks[request.cacheKey] = task
        defer { if token == epoch { tasks[request.cacheKey] = nil } }
        return try await task.value
    }

    private func produce(_ request: VideoPosterRequest, file: URL, epoch token: Int, foreground: Bool) async throws -> Data {
        await acquire(foreground: foreground)
        defer { release() }
        guard token == epoch else { throw CancellationError() }
        let data = try await generator(request)
        guard token == epoch else { throw CancellationError() }
        guard request == VideoPosterRequest(url: request.url, tier: request.tier) else { throw CocoaError(.fileReadUnknown) }
        // 缓存写入失败不能让可见封面加载失败。
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldSize = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if (try? data.write(to: file, options: .atomic)) != nil {
            pruneIfNeeded(delta: data.count - oldSize)
        }
        return data
    }

    private func acquire(foreground: Bool) async {
        if active < 2 { active += 1; return }
        await withCheckedContinuation { waiters.append((foreground, $0)) }
    }

    private func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            // 可见请求先于导入/下载后的预热，快速滚动时先服务最新出现的卡片。
            let index = waiters.lastIndex(where: \.foreground) ?? 0
            waiters.remove(at: index).continuation.resume()
        }
    }

    /// 导入或下载结束后串行预热小图，避免启动时为整个资料库抢占解码器。
    func prewarm(_ urls: [URL]) async {
        for url in urls {
            guard !Task.isCancelled else { return }
            _ = try? await data(for: VideoPosterRequest(url: url, tier: .list), foreground: false)
        }
    }

    func clear() {
        epoch += 1
        tasks.removeAll()
        try? FileManager.default.removeItem(at: directory)
        lastPruned = .distantPast
        knownDiskSize = 0
    }

    func diskSize() -> Int64 {
        let size = files().reduce(0) { $0 + $1.size }
        knownDiskSize = size
        return Int64(size)
    }

    private func files() -> [(url: URL, size: Int, modified: Date)] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        return urls.compactMap { url in
            guard url.pathExtension == "jpg", let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
    }

    private func pruneIfNeeded(delta: Int) {
        // 增量记账，避免每生成一张封面都遍历、排序整个缓存目录。
        let now = Date()
        if let size = knownDiskSize {
            knownDiskSize = size + delta
            if size + delta <= sizeLimit && now.timeIntervalSince(lastPruned) < 3600 { return }
        }
        let entries = files().sorted { $0.modified < $1.modified }
        var size = entries.reduce(0) { $0 + $1.size }
        for entry in entries {
            guard size > sizeLimit || now.timeIntervalSince(entry.modified) > 14 * 86400 else { break }
            if (try? FileManager.default.removeItem(at: entry.url)) != nil { size -= entry.size }
        }
        knownDiskSize = size
        lastPruned = now
    }

    nonisolated static func generate(_ request: VideoPosterRequest) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: request.url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: request.tier.maxPixelSize, height: request.tier.maxPixelSize)
            let duration = try await asset.load(.duration).seconds
            // 极短的视频也能提取封面，不固定请求超过片长的第 1 秒。
            let seconds = duration.isFinite && duration > 0 ? min(1, duration * 0.2) : 0
            let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            let result = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            return result as Data
        }.value
    }
}
