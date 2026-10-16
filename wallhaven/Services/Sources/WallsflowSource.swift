//
//  WallsflowSource.swift
//  wallhaven
//
//  Wallsflow（wallsflow.com）：欧美流行的高清动态视频桌面壁纸社区。
//  解析列表 HTML 网页，提取 MP4 动态视频直链与云端缩略海报。
//

import Foundation

nonisolated struct WallsflowSource: WallpaperSource {
    static let id = "wallsflow"
    private static let site = "https://wallsflow.com"
    private let load: @Sendable (URL, Bool) async throws -> Data

    init(load: @escaping @Sendable (URL, Bool) async throws -> Data = {
        try await SourceHTTP.data(from: $0, emptyOnNotFound: $1)
    }) { self.load = load }

    let descriptor = WallpaperSourceDescriptor(
        id: WallsflowSource.id,
        name: "Wallsflow",
        filters: [
            SourceFilter(id: "category", title: "分类", mode: .oneOf, options: [
                SourceOption(id: "anime", title: "动漫"),
                SourceOption(id: "games", title: "游戏"),
                SourceOption(id: "cars", title: "汽车"),
                SourceOption(id: "nature", title: "自然"),
                SourceOption(id: "space", title: "太空"),
                SourceOption(id: "pixel-art", title: "像素"),
                SourceOption(id: "winter", title: "冬季"),
                SourceOption(id: "minimalist", title: "极简"),
                SourceOption(id: "movies", title: "电影"),
                SourceOption(id: "animals", title: "动物"),
            ], defaultSelection: [], note: "空选时浏览精选全部分类"),
        ],
        sorts: [SourceOption(id: "latest", title: "最新")],
        defaultSort: "latest",
        randomSort: nil,
        folderName: "Wallsflow"
    )

    func search(_ query: WallpaperQuery, page: Int) async throws -> [RemoteWallpaper] {
        guard let url = Self.listURL(query, page: page) else { return [] }
        return try Self.parse(String(decoding: await load(url, page > 1), as: UTF8.self))
    }

    func filters(for query: WallpaperQuery) -> [SourceFilter] {
        query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? descriptor.filters : []
    }

    func downloadURL(for wallpaper: RemoteWallpaper) async throws -> URL {
        // 收藏里可能还保存着旧版按文章 ID 拼出的下载地址；始终重新读详情。
        guard wallpaper.sourceID == Self.id, Self.article(wallpaper.pageURL) != nil else { throw Self.invalidResponse }
        let html = String(decoding: try await load(wallpaper.pageURL, false), as: UTF8.self)
        return try Self.parseDownloadURL(html, pageURL: wallpaper.pageURL)
    }

    static func listURL(_ query: WallpaperQuery, page: Int) -> URL? {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            var components = URLComponents(string: "\(site)/index.php")!
            components.queryItems = [
                .init(name: "do", value: "search"),
                .init(name: "subaction", value: "search"),
                .init(name: "story", value: text),
                .init(name: "search_start", value: String(page)),
            ]
            return components.urlEncodingPlus
        }
        let category = query.selection("category").first
        let base = category.map { "\(site)/live-wallpapers/\($0)/" } ?? "\(site)/live-wallpapers/"
        let urlString = page > 1 ? "\(base)page/\(page)/" : base
        return URL(string: urlString)
    }

    private static var invalidResponse: WallperError {
        .network("Wallsflow 页面格式无法识别，请稍后重试或在官网查看。")
    }

    private static func checkPage(_ html: String) throws {
        let lower = html.lowercased()
        if lower.contains("cf-chl-") || lower.contains("challenges.cloudflare.com") || lower.contains("<title>just a moment") {
            throw WallperError.network("Wallsflow 要求浏览器安全验证，暂时无法在应用中加载。请稍后重试或在官网查看。")
        }
    }

    private static func article(_ url: URL) -> (id: String, slug: String)? {
        guard url.scheme == "https", url.host?.lowercased() == "wallsflow.com", url.user == nil, url.password == nil,
              let match = url.path.wholeMatch(of: /\/live-wallpapers\/(?:[a-zA-Z0-9_-]+\/)*(\d+)-([^\/]+)\.html/) else { return nil }
        return (String(match.1), String(match.2))
    }

    /// 每次只处理一个完整锚点；属性顺序、单双引号和懒加载图片均不影响匹配。
    static func parse(_ html: String) throws -> [RemoteWallpaper] {
        if html.isEmpty { return [] }
        try checkPage(html)
        var seen = Set<String>()
        let items = html.matches(of: /<a\b([^>]*)>(.*?)<\/a\s*>/.dotMatchesNewlines().ignoresCase()).compactMap { match -> RemoteWallpaper? in
            let anchor = attributes(String(match.1))
            guard let href = anchor["href"], let page = URL(string: href, relativeTo: URL(string: site))?.absoluteURL,
                  let article = article(page),
                  let image = match.2.firstMatch(of: /<img\b([^>]*)>/.ignoresCase()) else { return nil }
            let imageAttributes = attributes(String(image.1))
            let rawImage = imageAttributes["data-src"] ?? imageAttributes["src"] ?? ""
            guard !rawImage.isEmpty, let thumb = URL(string: rawImage, relativeTo: page)?.absoluteURL,
                  thumb.scheme == "https", let host = thumb.host?.lowercased(),
                  (host == "wallsflow.com" || host.hasSuffix(".wallsflow.com")),
                  seen.insert(article.id).inserted else { return nil }
            let cleanTitle = (imageAttributes["alt"] ?? anchor["title"] ?? article.slug.replacingOccurrences(of: "-", with: " "))
                .replacingOccurrences(of: #"(?i)\s*[-_]?\s*wallsflow(-com|\.com)?$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)\s*Live Wallpapers?$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_")))
            // 列表没有附件 ID。保留详情页，点击下载时再解析真实附件链接。
            return RemoteWallpaper(
                id: "\(Self.id)-\(article.id)",
                sourceID: Self.id,
                pageURL: page,
                imageURL: page,
                thumbURL: thumb,
                posterURL: thumb,
                previewVideoURL: nil,
                mediaType: .video,
                title: cleanTitle.isEmpty ? "Wallsflow #\(article.id)" : cleanTitle
            )
        }
        if items.isEmpty {
            let lower = html.lowercased()
            guard ["no results", "no wallpapers found", "nothing found", "search did not return any results"].contains(where: lower.contains) else {
                throw invalidResponse
            }
        }
        return items
    }

    static func parseDownloadURL(_ html: String, pageURL: URL) throws -> URL {
        try checkPage(html)
        for anchor in html.matches(of: /<a\b([^>]*)>/.ignoresCase()) {
            guard let href = attributes(String(anchor.1))["href"],
                  let url = URL(string: href, relativeTo: pageURL)?.absoluteURL,
                  url.scheme == "https", url.host?.lowercased() == "wallsflow.com", url.user == nil, url.password == nil,
                  url.path == "/index.php", let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  query.first(where: { $0.name == "do" })?.value == "download",
                  let id = query.first(where: { $0.name == "id" })?.value,
                  id.wholeMatch(of: /[1-9]\d*/) != nil else { continue }
            return url
        }
        throw WallperError.network("未找到 Wallsflow 下载链接，作品可能已下架或需要在官网登录。")
    }

    private static func attributes(_ html: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = /([a-zA-Z_:][a-zA-Z0-9_:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/
        for match in html.matches(of: pattern) {
            result[String(match.1).lowercased()] = decodeEntities(String(match.2 ?? match.3 ?? match.4 ?? ""))
        }
        return result
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for match in text.matches(of: /&#(x[0-9a-fA-F]+|[0-9]+);/).reversed() {
            let code = String(match.1)
            let value = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            if let value, let scalar = UnicodeScalar(value) { result.replaceSubrange(match.range, with: String(scalar)) }
        }
        return result.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
