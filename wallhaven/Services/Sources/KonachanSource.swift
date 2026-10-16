//
//  KonachanSource.swift
//  wallhaven
//
//  Konachan（konachan.net，全年龄站）：二次元高清壁纸，Moebooru 官方 JSON 接口，免登录。
//

import Foundation

nonisolated struct KonachanSource: WallpaperSource {
    static let id = "konachan"
    private static let site = "https://konachan.net"
    /// 最小宽度 → 最小高度（只要横屏且不低于该分辨率）
    private static let sizes = ["1920": 1080, "2560": 1440, "3840": 2160]

    let descriptor = WallpaperSourceDescriptor(
        id: KonachanSource.id,
        name: "Konachan",
        filters: [
            SourceFilter(id: "size", title: "最小分辨率", mode: .oneOf, options: [
                SourceOption(id: "1920", title: "1920×1080"),
                SourceOption(id: "2560", title: "2560×1440"),
                SourceOption(id: "3840", title: "3840×2160"),
            ], defaultSelection: ["1920"]),  // 早期高分作品很多只有 1280×720，默认只看够做壁纸的
        ],
        sorts: [
            SourceOption(id: "date", title: "最新"),
            SourceOption(id: "score", title: "评分"),
            SourceOption(id: "random", title: "随机"),
        ],
        defaultSort: "score",
        randomSort: "random"
    )

    func search(_ query: WallpaperQuery, page: Int) async throws -> [RemoteWallpaper] {
        let data = try await SourceHTTP.data(from: Self.searchURL(query, page: page), accept: "application/json")
        guard !data.isEmpty else { return [] }
        return try Self.parse(data)
    }

    /// 关键词即标签（空格分隔）；Konachan 匿名查询最多 6 个标签，排序和尺寸各占一个
    static func searchURL(_ query: WallpaperQuery, page: Int) -> URL {
        var tags = query.text.split(whereSeparator: \.isWhitespace).prefix(3).map(String.init)
        if query.sort != "date" { tags.append("order:\(query.sort)") }
        if let width = query.selection("size").first, let height = sizes[width] {
            tags += ["width:\(width)..", "height:\(height).."]
        }
        var components = URLComponents(string: "\(site)/post.json")!
        components.queryItems = [
            .init(name: "page", value: String(page)),
            .init(name: "limit", value: "30"),
            .init(name: "tags", value: tags.joined(separator: " ")),
        ]
        return components.urlEncodingPlus!
    }

    private struct Post: Decodable {
        let id: Int
        let tags: String
        let file_url: String
        let file_ext: String?
        let file_size: Int?
        let preview_url: String?
        let jpeg_url: String?
        let width: Int
        let height: Int
        let score: Int?
        let rating: String?
    }

    static func parse(_ data: Data) throws -> [RemoteWallpaper] {
        try JSONDecoder().decode([Post].self, from: data).compactMap { post in
            guard let image = absolute(post.file_url),
                  let page = URL(string: "\(site)/post/show/\(post.id)") else { return nil }
            // PNG 原档动辄十几 MB：背景显示同尺寸的 JPEG 版本，下载仍取原档
            let poster = post.file_ext == "png" ? post.jpeg_url.flatMap(absolute) : nil
            return RemoteWallpaper(
                id: "\(KonachanSource.id)-\(post.id)", sourceID: KonachanSource.id, pageURL: page, imageURL: image,
                thumbURL: post.preview_url.flatMap(absolute), posterURL: poster,
                resolution: "\(post.width)x\(post.height)", rating: post.rating, favorites: post.score ?? 0,
                fileSize: post.file_size ?? 0, tags: post.tags.split(separator: " ").map(String.init))
        }
    }

    private static func absolute(_ string: String) -> URL? {
        URL(string: string.hasPrefix("//") ? "https:" + string : string)
    }
}
