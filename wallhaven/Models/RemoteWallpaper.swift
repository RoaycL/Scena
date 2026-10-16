//
//  RemoteWallpaper.swift
//  wallhaven
//
//  在线图源的一张壁纸。各图源把自己的接口数据转换成这个结构，
//  画廊、收藏、下载、播放列表只认它，不关心来自哪个网站。
//

import Foundation

nonisolated struct RemoteWallpaper: Codable, Identifiable, Hashable, Sendable {
    /// 全局唯一：收藏、已下载文件名、播放列表都用它。新图源用「图源ID-原始ID」；
    /// Wallhaven 为兼容已有收藏和已下载的文件保留原始 ID
    let id: String
    /// 来自哪个图源（WallpaperSourceDescriptor.id）
    let sourceID: String
    /// 网页详情页（「在浏览器中打开」）
    let pageURL: URL
    /// 原图
    let imageURL: URL
    let thumbURL: URL?
    /// 「1920x1080」；未知时为空
    let resolution: String
    let category: String?
    /// 内容分级（如 sfw / sketchy / nsfw）；未知时为空
    let rating: String?
    let favorites: Int
    let views: Int
    let fileSize: Int
    let colors: [String]
    /// 列表接口直接给出的标签；需要单独请求的由图源的 tags(for:) 提供
    let tags: [String]

    init(id: String, sourceID: String, pageURL: URL, imageURL: URL, thumbURL: URL?, resolution: String = "",
         category: String? = nil, rating: String? = nil, favorites: Int = 0, views: Int = 0, fileSize: Int = 0,
         colors: [String] = [], tags: [String] = []) {
        self.id = id
        self.sourceID = sourceID
        self.pageURL = pageURL
        self.imageURL = imageURL
        self.thumbURL = thumbURL
        self.resolution = resolution
        self.category = category
        self.rating = rating
        self.favorites = favorites
        self.views = views
        self.fileSize = fileSize
        self.colors = colors
        self.tags = tags
    }

    // 存储格式沿用旧版收藏（与 Wallhaven 接口相同的字段名），旧数据无需迁移；
    // 没有 source 字段的旧数据都来自 Wallhaven
    private enum CodingKeys: String, CodingKey {
        case id, source, url, path, thumbs, resolution, category, purity, ratio, favorites, views, colors, tags
        case fileSize = "file_size"
    }

    private enum ThumbsCodingKeys: String, CodingKey {
        case large
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sourceID = try container.decodeIfPresent(String.self, forKey: .source) ?? WallhavenSource.id
        pageURL = try container.decode(URL.self, forKey: .url)
        imageURL = try container.decode(URL.self, forKey: .path)
        thumbURL = try? container.nestedContainer(keyedBy: ThumbsCodingKeys.self, forKey: .thumbs)
            .decodeIfPresent(URL.self, forKey: .large)
        resolution = try container.decodeIfPresent(String.self, forKey: .resolution) ?? ""
        category = try container.decodeIfPresent(String.self, forKey: .category)
        rating = try container.decodeIfPresent(String.self, forKey: .purity)
        favorites = try container.decodeIfPresent(Int.self, forKey: .favorites) ?? 0
        views = try container.decodeIfPresent(Int.self, forKey: .views) ?? 0
        fileSize = try container.decodeIfPresent(Int.self, forKey: .fileSize) ?? 0
        colors = try container.decodeIfPresent([String].self, forKey: .colors) ?? []
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceID, forKey: .source)
        try container.encode(pageURL, forKey: .url)
        try container.encode(imageURL, forKey: .path)
        try container.encode(resolution, forKey: .resolution)
        // 1.0.26 及更早版本解码时要求这几个字段存在，降级后收藏才不会丢
        try container.encode(category ?? "", forKey: .category)
        try container.encode(rating ?? "", forKey: .purity)
        try container.encode("", forKey: .ratio)
        try container.encode(favorites, forKey: .favorites)
        try container.encode(views, forKey: .views)
        try container.encode(fileSize, forKey: .fileSize)
        try container.encode(colors, forKey: .colors)
        if !tags.isEmpty { try container.encode(tags, forKey: .tags) }
        var thumbs = container.nestedContainer(keyedBy: ThumbsCodingKeys.self, forKey: .thumbs)
        try thumbs.encodeIfPresent(thumbURL, forKey: .large)
    }
}

extension RemoteWallpaper {
    /// 图源名称（「Wallhaven」）；图源已移除时显示其 ID
    var sourceName: String { WallpaperSources.source(id: sourceID)?.descriptor.name ?? sourceID }

    /// 资料库、播放列表里显示的名称
    var displayTitle: String { "\(sourceName) #\(id.hasPrefix(sourceID + "-") ? String(id.dropFirst(sourceID.count + 1)) : id)" }

    /// 已下载到下载目录的本地文件（下载时以 id 命名）
    var localFileURL: URL? {
        let url = URL(fileURLWithPath: DownloadLocation.currentPath, isDirectory: true).appendingPathComponent(downloadFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var downloadFileName: String {
        let ext = imageURL.pathExtension.isEmpty ? "jpg" : imageURL.pathExtension
        return "\(id).\(ext)"
    }
}
