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
    private let signedIn: @Sendable () -> Bool

    init(load: @escaping @Sendable (URL, Bool) async throws -> Data = {
        try await SourceHTTP.data(from: $0, accept: "application/json", emptyOnNotFound: $1)
    }, signedIn: @escaping @Sendable () -> Bool = { PixivCookieVault.shared.isAuthenticated }) {
        self.load = load
        self.signedIn = signedIn
    }

    let descriptor = WallpaperSourceDescriptor(
        id: PixivSource.id,
        name: "Pixiv",
        filters: [
            SourceFilter(id: "mode", title: "榜单", mode: .exactlyOne, options: [
                SourceOption(id: "daily", title: "日榜"), SourceOption(id: "weekly", title: "周榜"),
                SourceOption(id: "monthly", title: "月榜"), SourceOption(id: "rookie", title: "新人"),
                SourceOption(id: "original", title: "原创"), SourceOption(id: "daily_ai", title: "AI 生成"),
                SourceOption(id: "male", title: "男性向"), SourceOption(id: "female", title: "女性向"),
                SourceOption(id: "daily_r18", title: "R-18 日榜", requiresAccount: true),
                SourceOption(id: "weekly_r18", title: "R-18 周榜", requiresAccount: true),
                SourceOption(id: "daily_r18_ai", title: "R-18 AI", requiresAccount: true),
                SourceOption(id: "male_r18", title: "R-18 男性向", requiresAccount: true),
                SourceOption(id: "female_r18", title: "R-18 女性向", requiresAccount: true),
                SourceOption(id: "r18g", title: "R-18G", requiresAccount: true),
            ], defaultSelection: ["daily"], note: "以账号浏览权限为准", signedOutNote: "受限榜单需登录 Pixiv"),
            SourceFilter(id: "content", title: "类型", mode: .exactlyOne, options: [
                SourceOption(id: "all", title: "全部"), SourceOption(id: "illust", title: "插画"),
                SourceOption(id: "manga", title: "漫画"), SourceOption(id: "ugoira", title: "动图封面"),
            ], defaultSelection: ["illust"], note: "漫画与动图下载第一页 / 封面"),
            SourceFilter(id: "age", title: "内容分级", mode: .exactlyOne, options: [
                SourceOption(id: "safe", title: "全年龄", tint: .green),
                SourceOption(id: "all", title: "全部", requiresAccount: true),
                SourceOption(id: "r18", title: "R-18 / R-18G", tint: .red, requiresAccount: true),
            ], defaultSelection: ["safe"], note: "以账号浏览权限为准", signedOutNote: "登录 Pixiv 后可选受限内容"),
            SourceFilter(id: "match", title: "搜索范围", mode: .exactlyOne, options: [
                SourceOption(id: "s_tag", title: "标签部分一致"), SourceOption(id: "s_tag_full", title: "标签完全一致"),
                SourceOption(id: "s_tc", title: "标题、说明文字"),
            ], defaultSelection: ["s_tag"]),
            SourceFilter(id: "aspect", title: "画幅", mode: .oneOf, options: [
                SourceOption(id: "landscape", title: "横图"), SourceOption(id: "portrait", title: "竖图"),
                SourceOption(id: "square", title: "正方形"),
            ], defaultSelection: []),
            SourceFilter(id: "ai", title: "AI 生成作品", mode: .exactlyOne, options: [
                SourceOption(id: "show", title: "显示"), SourceOption(id: "hide", title: "隐藏"),
            ], defaultSelection: ["show"], note: "仍遵循官网账号设置"),
            SourceFilter(id: "date", title: "投稿日期", mode: .oneOf, options: [], defaultSelection: [], input: .dateRange),
            SourceFilter(id: "width", title: "宽度", mode: .oneOf, options: [], defaultSelection: [], note: "像素", input: .numberRange),
            SourceFilter(id: "height", title: "高度", mode: .oneOf, options: [], defaultSelection: [], note: "像素", input: .numberRange),
            SourceFilter(id: "bookmarks", title: "收藏数", mode: .oneOf, options: [], defaultSelection: [],
                note: "需 Pixiv 高级会员", signedOutNote: "需登录及高级会员", input: .numberRange, requiresAccount: true),
            SourceFilter(id: "tool", title: "创作工具", mode: .oneOf, options: [], defaultSelection: [],
                note: "例如 Photoshop、SAI", input: .text),
            SourceFilter(id: "rankingDate", title: "历史榜单", mode: .oneOf, options: [], defaultSelection: [],
                note: "日本时间，最晚昨天", input: .date),
        ],
        sorts: [
            SourceOption(id: "date_d", title: "最新"), SourceOption(id: "date", title: "最旧"),
            SourceOption(id: "popular_d", title: "热门 · 会员", requiresAccount: true),
            SourceOption(id: "popular_male_d", title: "男性热门 · 会员", requiresAccount: true),
            SourceOption(id: "popular_female_d", title: "女性热门 · 会员", requiresAccount: true),
        ],
        defaultSort: "date_d",
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
        let authenticated = signedIn()
        guard page > 0, !isSearch || page <= 10 || authenticated else { return [] }
        let mode = query.selection("mode").first ?? "daily"
        if !authenticated, (isSearch ? Self.requiresSearchAccount(query) : Self.restrictedModes.contains(mode)) {
            throw WallperError.network("此筛选需要登录 Pixiv，请先在设置中登录。")
        }
        try Self.validateRanges(query, isSearch: isSearch)
        let url = isSearch ? Self.searchURL(query, page: page, signedIn: authenticated) : Self.rankingURL(query, page: page)
        let data = try await load(url, page > 1)
        guard !data.isEmpty else { return [] }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["error"] as? Bool == true {
            if isSearch, Self.isPremiumSearch(query) {
                throw WallperError.network("Pixiv 未允许此会员筛选，请确认账号的高级会员权限，或取消热门排序与收藏数条件。")
            }
            if !isSearch && Self.restrictedModes.contains(mode) || (isSearch && Self.searchAge(query, signedIn: authenticated) != "safe") {
                throw WallperError.network("Pixiv 未允许此分级内容，请确认账号已登录，并在官网开启相应的年龄限制内容显示。")
            }
        }
        return try isSearch ? Self.parseSearch(data, content: Self.content(query), age: Self.searchAge(query, signedIn: authenticated)) : Self.parse(data)
    }

    private static let restrictedModes: Set<String> = ["daily_r18", "weekly_r18", "daily_r18_ai", "male_r18", "female_r18", "r18g"]
    private static let combinedModes: Set<String> = ["male", "female", "original", "daily_ai", "daily_r18_ai", "male_r18", "female_r18", "r18g"]

    func filters(for query: WallpaperQuery) -> [SourceFilter] {
        if !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return descriptor.filters.filter { !["mode", "rankingDate"].contains($0.id) }
        }
        let mode = query.selection("mode").first ?? "daily"
        return descriptor.filters.filter { ["mode", "rankingDate"].contains($0.id) || ($0.id == "content" && !Self.combinedModes.contains(mode)) }.map { filter in
            var result = filter
            if filter.id == "mode", Self.combinedModes.contains(mode) { result.note = "此榜单为综合类型" }
            if filter.id == "content", ["monthly", "rookie"].contains(mode) {
                result.options.removeAll { $0.id == "ugoira" }
            }
            return result
        }
    }

    func sorts(for query: WallpaperQuery) -> [SourceOption] {
        query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : descriptor.sorts
    }

    static func rankingURL(_ query: WallpaperQuery, page: Int) -> URL {
        let selectedMode = query.selection("mode").first ?? "daily"
        let modes: Set<String> = ["daily", "weekly", "monthly", "rookie", "male", "female", "original", "daily_ai"]
        let mode = modes.union(restrictedModes).contains(selectedMode) ? selectedMode : "daily"
        var components = URLComponents(string: "\(site)/ranking.php")!
        var items = [URLQueryItem(name: "mode", value: mode)]
        if !combinedModes.contains(mode) {
            let selectedContent = content(query)
            items.append(.init(name: "content", value: selectedContent == "ugoira" && ["monthly", "rookie"].contains(mode) ? "illust" : selectedContent))
        }
        items += [.init(name: "p", value: String(page)), .init(name: "format", value: "json")]
        if let date = query.selection("rankingDate").first, SourceFilterDate.date(date) != nil {
            items.append(.init(name: "date", value: date.replacingOccurrences(of: "-", with: "")))
        }
        components.queryItems = items
        return components.url!
    }

    private static func content(_ query: WallpaperQuery) -> String {
        let selected = query.selection("content").first ?? "illust"
        return ["all", "illust", "manga", "ugoira"].contains(selected) ? selected : "illust"
    }

    private static func isPremiumSearch(_ query: WallpaperQuery) -> Bool {
        query.sort.hasPrefix("popular") || !query.selection("bookmarks").isEmpty
    }

    private static func requiresSearchAccount(_ query: WallpaperQuery) -> Bool {
        ["all", "r18"].contains(query.selection("age").first ?? "safe") || isPremiumSearch(query)
    }

    private static func searchAge(_ query: WallpaperQuery, signedIn: Bool) -> String {
        let age = query.selection("age").first ?? "safe"
        return signedIn && ["safe", "all", "r18"].contains(age) ? age : "safe"
    }

    static func searchURL(_ query: WallpaperQuery, page: Int, signedIn: Bool = false) -> URL {
        let word = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = content(query)
        let endpoint = kind == "all" ? "artworks" : kind == "manga" ? "manga" : "illustrations"
        var components = URLComponents(string: site)!
        let segment = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#")))!
        components.percentEncodedPath = "/ajax/search/\(endpoint)/\(segment)"
        let order = ["date_d", "date", "popular_d", "popular_male_d", "popular_female_d"].contains(query.sort) ? query.sort : "date_d"
        let match = query.selection("match").first ?? "s_tag"
        var items: [URLQueryItem] = [
            .init(name: "word", value: word), .init(name: "order", value: !signedIn && order.hasPrefix("popular") ? "date_d" : order),
            .init(name: "mode", value: searchAge(query, signedIn: signedIn)), .init(name: "p", value: String(page)),
            .init(name: "s_mode", value: ["s_tag", "s_tag_full", "s_tc"].contains(match) ? match : "s_tag"),
            .init(name: "type", value: kind), .init(name: "lang", value: "zh"),
        ]
        if let ratio = ["landscape": "0.5", "portrait": "-0.5", "square": "0"][query.selection("aspect").first ?? ""] {
            items.append(.init(name: "ratio", value: ratio))
        }
        if query.selection("ai").contains("hide") { items.append(.init(name: "ai_type", value: "1")) }
        for (id, minKey, maxKey) in [("width", "wlt", "wgt"), ("height", "hlt", "hgt"), ("bookmarks", "blt", "bgt")] where id != "bookmarks" || signedIn {
            for (bound, key) in [("min", minKey), ("max", maxKey)] {
                if let raw = SourceFilter.bound(bound, in: query.selection(id)), let value = Int(raw), value > 0, value <= 100_000_000 {
                    items.append(.init(name: key, value: String(value)))
                }
            }
        }
        for (bound, key) in [("min", "scd"), ("max", "ecd")] {
            if let value = SourceFilter.bound(bound, in: query.selection("date")), SourceFilterDate.date(value) != nil {
                items.append(.init(name: key, value: value))
            }
        }
        if let tool = query.selection("tool").first?.trimmingCharacters(in: .whitespacesAndNewlines), !tool.isEmpty, tool.count <= 128 {
            items.append(.init(name: "tool", value: tool))
        }
        components.queryItems = items
        return components.urlEncodingPlus!
    }

    private static func validateRanges(_ query: WallpaperQuery, isSearch: Bool) throws {
        if !isSearch {
            if let raw = query.selection("rankingDate").first, let date = SourceFilterDate.date(raw),
               date >= SourceFilterDate.calendar.startOfDay(for: Date()) {
                throw WallperError.network("历史榜单日期最晚可选择日本时间的昨天。")
            }
            return
        }
        for id in ["width", "height", "bookmarks", "date"] {
            guard let min = SourceFilter.bound("min", in: query.selection(id)), let max = SourceFilter.bound("max", in: query.selection(id)) else { continue }
            let valid = id == "date" ? min <= max : (Int(min).map { lower in Int(max).map { lower <= $0 } ?? false } ?? false)
            if !valid { throw WallperError.network("筛选范围的下限不能大于上限，请检查尺寸、日期或收藏数。") }
        }
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
        let illustManga: SearchPage?
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

    static func parseSearch(_ data: Data, content: String, age: String = "safe") throws -> [RemoteWallpaper] {
        let response = try body(SearchBody.self, from: data)
        guard let page = content == "all" ? response.illustManga : content == "manga" ? response.manga : response.illust else { throw invalidResponse }
        guard page.data.allSatisfy({ $0.isAdContainer == true || $0.isMasked == true ||
            ($0.id != nil && $0.title != nil && $0.url != nil && $0.illustType != nil && $0.xRestrict != nil) }) else {
            throw invalidResponse
        }
        return page.data.compactMap { item in
            guard let id = item.id, id.wholeMatch(of: /[1-9]\d*/) != nil,
                  let title = item.title, let rawURL = item.url, let thumb = imageURL(rawURL),
                  let poster = preview(rawURL), let type = item.illustType, (content == "all" ? [0, 1, 2].contains(type) : type == (content == "manga" ? 1 : content == "ugoira" ? 2 : 0)),
                  let restriction = item.xRestrict, (age == "all" ? [0, 1, 2].contains(restriction) : age == "r18" ? [1, 2].contains(restriction) : restriction == 0), item.isMasked != true else { return nil }
            return RemoteWallpaper(id: "\(Self.id)-\(id)", sourceID: Self.id,
                pageURL: URL(string: "\(site)/artworks/\(id)")!, imageURL: poster, thumbURL: thumb, posterURL: poster,
                title: title, resolution: item.width.flatMap { w in item.height.map { "\(w)x\($0)" } } ?? "",
                category: type == 2 ? "动图静态封面" : nil, rating: restriction == 0 ? "safe" : restriction == 1 ? "r18" : "r18g",
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
