//
//  WallpaperSource.swift
//  wallhaven
//
//  在线图源的统一接口。新增图源：实现 WallpaperSource（把站点数据转换成 RemoteWallpaper），
//  再加入 WallpaperSources.all。筛选面板、搜索、翻页、收藏、下载、播放列表都无需改动。
//

import Foundation

nonisolated protocol WallpaperSource: Sendable {
    var descriptor: WallpaperSourceDescriptor { get }
    /// 按条件取一页（从 1 开始）；返回空数组表示没有更多
    func search(_ query: WallpaperQuery, page: Int) async throws -> [RemoteWallpaper]
    /// 详情标签；列表接口已经带标签的图源不必实现
    func tags(for wallpaper: RemoteWallpaper, credential: String?) async throws -> [String]
    /// 某些站点的原文件地址只能从详情接口取得；下载时解析，避免列表逐项请求。
    func downloadURL(for wallpaper: RemoteWallpaper) async throws -> URL
    /// 仅展示当前查询确实支持的筛选条件，保留隐藏条件的选择以便返回时恢复。
    func filters(for query: WallpaperQuery) -> [SourceFilter]
}

extension WallpaperSource {
    nonisolated func tags(for wallpaper: RemoteWallpaper, credential: String?) async throws -> [String] { wallpaper.tags }
    nonisolated func downloadURL(for wallpaper: RemoteWallpaper) async throws -> URL { wallpaper.imageURL }
    nonisolated func filters(for query: WallpaperQuery) -> [SourceFilter] { descriptor.filters }
}

/// 图源能力的描述：筛选面板据此生成，不需要为每个图源单独写界面
nonisolated struct WallpaperSourceDescriptor: Sendable {
    let id: String
    let name: String
    let filters: [SourceFilter]
    let sorts: [SourceOption]
    let defaultSort: String
    /// 「随机换一张」使用的排序；没有时用当前排序随机挑
    let randomSort: String?
    /// 加载这个图源的图片、视频时附带的请求头（防盗链的 Referer 等），只对 mediaHosts 里的域名生效
    var requestHeaders: [String: String] = [:]
    var mediaHosts: [String] = []
    /// 下载文件夹名（存储目录里和 Wallhaven、Imported 并列）；nil 表示使用下载目录本身（Wallhaven）
    var folderName: String? = nil
    /// 仅原文件扩展名需要详情解析的图源，查找已下载文件时使用备选扩展名。
    var alternateDownloadExtensions: [String] = []
}

nonisolated struct SourceOption: Identifiable, Hashable, Sendable {
    enum Tint: Sendable { case green, orange, red }

    let id: String
    let title: String
    var tint: Tint? = nil
    /// 需要登录图源账号才能选择（如 Wallhaven 的 Sketchy / NSFW）
    var requiresAccount = false
}

nonisolated struct SourceFilter: Identifiable, Sendable {
    enum Mode: Sendable {
        /// 多选且至少保留一项（分类、内容分级）
        case atLeastOne
        /// 多选，空集合表示「不限」（分辨率）
        case anyOf
        /// 单选，空集合表示「不限」（分类）
        case oneOf
    }

    let id: String
    let title: String
    let mode: Mode
    let options: [SourceOption]
    let defaultSelection: Set<String>
    /// 标题右侧的说明
    var note: String? = nil
    /// 未登录时标题右侧的说明
    var signedOutNote: String? = nil
}

/// 一次搜索的条件快照
nonisolated struct WallpaperQuery: Equatable, Sendable {
    var text: String
    var sort: String
    /// 筛选 ID → 选中的选项 ID
    var filters: [String: Set<String>]
    /// 图源账号凭据（如 Wallhaven API 密钥）
    var credential: String?

    func selection(_ filterID: String) -> Set<String> { filters[filterID] ?? [] }
}

/// 网络繁忙一类、稍后重试可能成功的错误
nonisolated protocol TransientSourceError: Error {}

nonisolated enum WallpaperSources {
    static let all: [any WallpaperSource] = [
        WallhavenSource(),
        KonachanSource(),
        PixivSource(),
        FourKWallpapersSource(),
        MotionBGSource(),
        WallsflowSource(),
    ]

    static func source(id: String) -> (any WallpaperSource)? {
        all.first { $0.descriptor.id == id }
    }

    /// 图源的下载文件夹：Wallhaven 用下载目录本身；其他图源在存储目录下各有一个文件夹，
    /// 没有设置存储目录时放在下载目录里面（和 Imported 的规则一致）
    static func downloadFolder(for sourceID: String) -> URL {
        let downloads = URL(fileURLWithPath: DownloadLocation.currentPath, isDirectory: true)
        guard let name = source(id: sourceID)?.descriptor.folderName else { return downloads }
        let root = UserDefaults.standard.string(forKey: StorageManager.rootKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        return (root ?? downloads).appendingPathComponent(name, isDirectory: true)
    }

    /// 所有有独立文件夹的图源（名称、文件夹）
    static var downloadFolders: [(sourceID: String, name: String, folder: URL)] {
        all.compactMap { source in
            source.descriptor.folderName == nil ? nil
                : (source.descriptor.id, source.descriptor.name, downloadFolder(for: source.descriptor.id))
        }
    }

    /// 某个图片 / 视频地址需要附带的请求头（按域名匹配图源）
    static func requestHeaders(for url: URL) -> [String: String] {
        guard let host = url.host?.lowercased() else { return [:] }
        return all.first { source in
            source.descriptor.mediaHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }?.descriptor.requestHeaders ?? [:]
    }
}

/// 网页类图源共用的请求：带浏览器 User-Agent，429 / 503 视为稍后可重试
nonisolated enum SourceHTTP {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    struct Busy: LocalizedError, TransientSourceError {
        var errorDescription: String? { "图源暂时繁忙，请稍后再试" }
    }

    static func data(from url: URL, accept: String = "text/html,application/xhtml+xml", emptyOnNotFound: Bool = true) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        for (field, value) in WallpaperSources.requestHeaders(for: url) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "cf-mitigated") == "challenge" {
            throw WallperError.network("图源要求浏览器安全验证，暂时无法在应用中加载。请稍后重试或在官网查看。")
        }
        if status == 429 || status == 503 { throw Busy() }
        // 翻过最后一页时网页类站点返回 404：当作没有更多
        if status == 404, emptyOnNotFound { return Data() }
        guard (200...299).contains(status) else { throw WallperError.network("加载壁纸失败（\(status)）。") }
        return data
    }

    static func string(from url: URL) async throws -> String {
        String(decoding: try await data(from: url), as: UTF8.self)
    }
}
