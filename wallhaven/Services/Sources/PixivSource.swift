//
//  PixivSource.swift
//  wallhaven
//
//  Pixiv（pixiv.net）：全球顶级插画社区，日榜/周榜/月榜优质壁纸，官方 Web JSON 接口。
//  图片 CDN（i.pximg.net）具备严格防盗链，通过 mediaHosts 自动注入 Referer: https://www.pixiv.net/。
//

import Foundation

nonisolated struct PixivSource: WallpaperSource {
    static let id = "pixiv"
    private static let site = "https://www.pixiv.net"
    private let load: @Sendable (URL, Bool) async throws -> Data

    init(load: @escaping @Sendable (URL, Bool) async throws -> Data = {
        try await SourceHTTP.data(from: $0, accept: "application/json", emptyOnNotFound: $1)
    }) {
        self.load = load
    }

    let descriptor = WallpaperSourceDescriptor(
        id: PixivSource.id,
        name: "Pixiv",
        filters: [
            SourceFilter(id: "mode", title: "榜单", mode: .oneOf, options: [
                SourceOption(id: "daily", title: "日榜"),
                SourceOption(id: "weekly", title: "周榜"),
                SourceOption(id: "monthly", title: "月榜"),
                SourceOption(id: "rookie", title: "新人"),
                SourceOption(id: "male", title: "男性向"),
                SourceOption(id: "female", title: "女性向"),
            ], defaultSelection: ["daily"]),
            SourceFilter(id: "content", title: "类型", mode: .oneOf, options: [
                SourceOption(id: "illust", title: "插画"),
                SourceOption(id: "manga", title: "漫画"),
            ], defaultSelection: ["illust"]),
        ],
        sorts: [SourceOption(id: "default", title: "排行")],
        defaultSort: "default",
        randomSort: nil,
        requestHeaders: [
            "Referer": "https://www.pixiv.net/",
        ],
        mediaHosts: [
            "pximg.net",
            "pixiv.net",
        ],
        folderName: "Pixiv",
        alternateDownloadExtensions: MediaType.imageExtensions.sorted()
    )

    func search(_ query: WallpaperQuery, page: Int) async throws -> [RemoteWallpaper] {
        let isSearch = !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // 未登录搜索最多显示十页；榜单没有下一页时返回 404。
        guard page > 0, !isSearch || page <= 10 else { return [] }
        let url = isSearch ? Self.searchURL(query, page: page) : Self.rankingURL(query, page: page)
        let data = try await load(url, page > 1)
        guard !data.isEmpty else { return [] }
        return try isSearch ? Self.parseSearch(data, content: Self.content(query)) : Self.parse(data)
    }

    func filters(for query: WallpaperQuery) -> [SourceFilter] {
        if !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return descriptor.filters.filter { $0.id == "content" }
        }
        if ["male", "female"].contains(query.selection("mode").first ?? "daily") {
            return descriptor.filters.filter { $0.id == "mode" }.map {
                var filter = $0
                filter.note = "此榜单为综合类型"
                return filter
            }
        }
        return descriptor.filters
    }

    static func rankingURL(_ query: WallpaperQuery, page: Int) -> URL {
        let selectedMode = query.selection("mode").first ?? "daily"
        let mode = ["daily", "weekly", "monthly", "rookie", "male", "female"].contains(selectedMode) ? selectedMode : "daily"
        var components = URLComponents(string: "\(site)/ranking.php")!
        var items = [URLQueryItem(name: "mode", value: mode)]
        if !["male", "female"].contains(mode) {
            items.append(.init(name: "content", value: content(query)))
        }
        items += [
            .init(name: "p", value: String(page)),
            .init(name: "format", value: "json"),
        ]
        components.queryItems = items
        return components.url!
    }

    private static func content(_ query: WallpaperQuery) -> String {
        query.selection("content").contains("manga") ? "manga" : "illust"
    }

    static func searchURL(_ query: WallpaperQuery, page: Int) -> URL {
        let word = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = content(query)
        var components = URLComponents(string: site)!
        let segment = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#")))!
        components.percentEncodedPath = "/ajax/search/\(kind == "manga" ? "manga" : "illustrations")/\(segment)"
        components.queryItems = [
            .init(name: "word", value: word), .init(name: "order", value: "date_d"),
            .init(name: "mode", value: "safe"), .init(name: "p", value: String(page)),
            .init(name: "s_mode", value: "s_tag"), .init(name: "type", value: kind == "manga" ? "all" : "illust"),
            .init(name: "lang", value: "zh"),
        ]
        return components.urlEncodingPlus!
    }

    func downloadURL(for wallpaper: RemoteWallpaper) async throws -> URL {
        guard wallpaper.sourceID == Self.id,
              let match = wallpaper.id.wholeMatch(of: /pixiv-(\d+)/) else { throw Self.invalidResponse }
        let url = URL(string: "\(Self.site)/ajax/illust/\(match.1)/pages")!
        return try Self.parseOriginal(try await load(url, false))
    }

    private static var invalidResponse: WallperError {
        .network("Pixiv 返回的数据无法识别，请稍后重试或在官网查看。")
    }

    private struct Envelope<Body: Decodable>: Decodable {
        let error: Bool
        let body: Body?
    }

    private static func body<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        // 错误响应的 body 可能是 []；先判定 error，避免将它当作空列表。
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let failed = object["error"] as? Bool else { throw invalidResponse }
        guard !failed else { throw WallperError.network("Pixiv 无法提供此内容，可能需要登录或作品已不可用。") }
        guard let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data),
              let result = envelope.body else { throw invalidResponse }
        return result
    }

    private static func imageURL(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), host == "pximg.net" || host.hasSuffix(".pximg.net") else { return nil }
        return url
    }

    private static func preview(_ string: String) -> URL? {
        imageURL(string.replacingOccurrences(of: #"/c/[^/]+/"#, with: "/", options: .regularExpression)
            .replacingOccurrences(of: "_square1200.", with: "_master1200."))
    }

    private struct RankingResponse: Decodable {
        let contents: [RankingItem]
    }

    private struct RankingItem: Decodable {
        let illust_id: Int
        let title: String
        let user_name: String
        let url: String
        let width: Int
        let height: Int
        let tags: [String]
        let rating_count: Int?
        let view_count: Int?
    }

    static func parse(_ data: Data) throws -> [RemoteWallpaper] {
        guard let response = try? JSONDecoder().decode(RankingResponse.self, from: data) else { throw invalidResponse }
        let items = response.contents.compactMap { item -> RemoteWallpaper? in
            guard item.illust_id > 0, let thumb = imageURL(item.url), let poster = preview(item.url) else { return nil }

            return RemoteWallpaper(
                id: "\(Self.id)-\(item.illust_id)",
                sourceID: Self.id,
                pageURL: URL(string: "\(site)/artworks/\(item.illust_id)")!,
                imageURL: poster,
                thumbURL: thumb,
                posterURL: poster,
                title: item.title,
                resolution: "\(item.width)x\(item.height)",
                favorites: item.rating_count ?? 0,
                views: item.view_count ?? 0,
                tags: item.tags + [item.user_name]
            )
        }
        guard response.contents.isEmpty || !items.isEmpty else { throw invalidResponse }
        return items
    }

    private struct SearchBody: Decodable {
        let illust: SearchPage?
        let manga: SearchPage?
    }
    private struct SearchPage: Decodable { let data: [SearchItem] }
    private struct SearchItem: Decodable {
        // 广告占位条目只有 isAdContainer，不应导致整页解析失败。
        let id: String?
        let title: String?
        let url: String?
        let userName: String?
        let width: Int?
        let height: Int?
        let tags: [String]?
        let illustType: Int?
        let xRestrict: Int?
        let isMasked: Bool?
        let isAdContainer: Bool?
    }

    static func parseSearch(_ data: Data, content: String) throws -> [RemoteWallpaper] {
        let response = try body(SearchBody.self, from: data)
        guard let page = content == "manga" ? response.manga : response.illust else { throw invalidResponse }
        guard page.data.allSatisfy({ $0.isAdContainer == true || $0.isMasked == true ||
            ($0.id != nil && $0.title != nil && $0.url != nil && $0.illustType != nil && $0.xRestrict != nil) }) else {
            throw invalidResponse
        }
        return page.data.compactMap { item in
            guard let id = item.id, id.wholeMatch(of: /[1-9]\d*/) != nil,
                  let title = item.title, let rawURL = item.url, let thumb = imageURL(rawURL),
                  let poster = preview(rawURL), item.illustType == (content == "manga" ? 1 : 0),
                  item.xRestrict == 0, item.isMasked != true else { return nil }
            return RemoteWallpaper(id: "\(Self.id)-\(id)", sourceID: Self.id,
                pageURL: URL(string: "\(site)/artworks/\(id)")!, imageURL: poster, thumbURL: thumb, posterURL: poster,
                title: title, resolution: item.width.flatMap { w in item.height.map { "\(w)x\($0)" } } ?? "",
                tags: (item.tags ?? []) + (item.userName.map { [$0] } ?? []))
        }
    }

    private struct OriginalPage: Decodable { let urls: OriginalURLs }
    private struct OriginalURLs: Decodable { let original: String }

    static func parseOriginal(_ data: Data) throws -> URL {
        let pages = try body([OriginalPage].self, from: data)
        guard let value = pages.first?.urls.original, let url = imageURL(value),
              url.path.contains("/img-original/"), MediaType.imageExtensions.contains(url.pathExtension.lowercased()) else {
            throw invalidResponse
        }
        // 列表始终展示作品的第一页，下载同一页，避免随机切到漫画后续页面。
        return url
    }
}
