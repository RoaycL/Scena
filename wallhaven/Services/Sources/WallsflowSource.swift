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
        return try Self.parse(String(decoding: await load(url, page > 1), as: UTF8.self), pageURL: url)
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

    private static func checkPage(_ html: String, pageURL: URL? = nil) throws {
        let lower = html.lowercased()
        if lower.contains("cf-chl-") || lower.contains("challenges.cloudflare.com") || lower.contains("<title>just a moment") || lower.contains("_cf_chl_opt") {
            throw CloudflareChallengeRequiredError(domain: "wallsflow.com", challengeURL: pageURL ?? URL(string: site)!)
        }
    }

    private static func article(_ url: URL) -> (id: String, slug: String)? {
        guard url.scheme == "https", url.host?.lowercased() == "wallsflow.com", url.user == nil, url.password == nil,
              let match = url.path.wholeMatch(of: /\/live-wallpapers\/(?:[a-zA-Z0-9_-]+\/)*(\d+)-([^\/]+)\.html/) else { return nil }
        return (String(match.1), String(match.2))
    }

    /// 官网卡片的图片、视频和覆盖链接是兄弟节点，必须在 article 内配对。
    /// 同时保留旧版「链接内嵌图片」的结构，不能跨卡片查找图片。
    static func parse(_ html: String, pageURL: URL? = nil) throws -> [RemoteWallpaper] {
        if html.isEmpty { return [] }
        try checkPage(html, pageURL: pageURL)
        var candidates: [(position: String.Index, item: RemoteWallpaper)] = []
        for match in html.matches(of: /<article\b([^>]*)>(.*?)<\/article\s*>/.dotMatchesNewlines().ignoresCase()) {
            if let item = parseCard(String(match.2), metadata: attributes(String(match.1))) {
                candidates.append((match.range.lowerBound, item))
            }
        }
        for match in html.matches(of: /<a\b[^>]*>.*?<\/a\s*>/.dotMatchesNewlines().ignoresCase()) {
            if let item = parseCard(String(match.0)) {
                candidates.append((match.range.lowerBound, item))
            }
        }
        var seen = Set<String>()
        let items = candidates.sorted { $0.position < $1.position }.compactMap { candidate in
            seen.insert(candidate.item.id).inserted ? candidate.item : nil
        }
        if items.isEmpty {
            let lower = html.lowercased()
            guard ["no results", "no wallpapers found", "nothing found", "search did not return any results"].contains(where: lower.contains) else {
                throw invalidResponse
            }
        }
        return items
    }

    private static func parseCard(_ html: String, metadata: [String: String] = [:]) -> RemoteWallpaper? {
        let links = html.matches(of: /<a\b([^>]*)>/.ignoresCase()).map { attributes(String($0.1)) }
        guard let link = links.first(where: { attributes in
            guard let href = attributes["href"], let url = URL(string: href, relativeTo: URL(string: site))?.absoluteURL else { return false }
            return article(url) != nil
        }), let href = link["href"], let url = URL(string: href, relativeTo: URL(string: site))?.absoluteURL,
              var canonical = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let article = article(url),
              let image = html.firstMatch(of: /<img\b([^>]*)>/.ignoresCase()) else { return nil }
        canonical.fragment = nil
        canonical.query = nil
        guard let page = canonical.url else { return nil }
        let imageAttributes = attributes(String(image.1))
        // 只检查卡片的封面图；不能在封面无效时误用后面的作者头像。
        let thumb = [imageAttributes["data-src"], imageAttributes["src"]].compactMap { value in
            value.flatMap { mediaURL($0, relativeTo: page) }
        }.first
        guard let thumb else { return nil }
        let cleanTitle = (link["aria-label"] ?? imageAttributes["alt"] ?? link["title"] ?? article.slug.replacingOccurrences(of: "-", with: " "))
            .replacingOccurrences(of: #"(?i)\s*[-_]?\s*wallsflow(-com|\.com)?$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s*Live Wallpapers?(?: for desktop)?$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_")))
        let source = html.firstMatch(of: /<source\b([^>]*)>/.ignoresCase()).map { attributes(String($0.1)) }
        let preview = [metadata["data-video-src"], source?["data-src"], source?["src"]].compactMap { value in
            value.flatMap { mediaURL($0, relativeTo: page) }
        }.first { $0.pathExtension.lowercased() == "mp4" }
        // 预览地址不等于原始附件；下载仍需解析详情页的真实附件编号。
        return RemoteWallpaper(id: "\(Self.id)-\(article.id)", sourceID: Self.id, pageURL: page, imageURL: page,
            thumbURL: thumb, posterURL: thumb, previewVideoURL: preview, mediaType: .video,
            title: cleanTitle.isEmpty ? "Wallsflow #\(article.id)" : cleanTitle)
    }

    private static func mediaURL(_ value: String, relativeTo page: URL) -> URL? {
        guard !value.isEmpty, let url = URL(string: value, relativeTo: page)?.absoluteURL,
              url.scheme == "https", url.user == nil, url.password == nil, let host = url.host?.lowercased(),
              host == "wallsflow.com" || host.hasSuffix(".wallsflow.com") else { return nil }
        return url
    }

    static func parseDownloadURL(_ html: String, pageURL: URL) throws -> URL {
        try checkPage(html, pageURL: pageURL)
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
