//
//  FourKWallpapersSource.swift
//  wallhaven
//
//  4K Wallpapers（4kwallpapers.com）：风景、汽车、科幻等写实高清壁纸。没有接口，解析列表网页。
//  列表只给出编号和地址里的短名；原图地址按站点固定格式拼出 3840×2160 版本（每张都提供这个尺寸）。
//

import Foundation

nonisolated struct FourKWallpapersSource: WallpaperSource {
    static let id = "4kwallpapers"
    private static let site = "https://4kwallpapers.com"

    let descriptor = WallpaperSourceDescriptor(
        id: FourKWallpapersSource.id,
        name: "4K Wallpapers",
        filters: [
            SourceFilter(id: "category", title: "分类", mode: .oneOf, options: [
                ("nature", "自然"), ("space", "太空"), ("cars", "汽车"), ("bikes", "机车"), ("architecture", "建筑"),
                ("abstract", "抽象"), ("minimal", "极简"), ("black-dark", "暗色"), ("gradients", "渐变"),
                ("graphics-cgi", "CGI"), ("sci-fi", "科幻"), ("fantasy", "奇幻"), ("anime", "动漫"),
                ("games", "游戏"), ("movies", "电影"), ("animals", "动物"), ("flowers", "花卉"),
                ("photography", "摄影"), ("technology", "科技"), ("world", "城市"),
            ].map { SourceOption(id: $0.0, title: $0.1) }, defaultSelection: [], note: "选择分类或搜索时按最新排序"),
        ],
        sorts: [
            SourceOption(id: "latest", title: "最新"),
            SourceOption(id: "popular", title: "热门"),
            SourceOption(id: "best", title: "精选"),
            SourceOption(id: "random", title: "随机"),
        ],
        defaultSort: "popular",
        randomSort: "random"
    )

    func search(_ query: WallpaperQuery, page: Int) async throws -> [RemoteWallpaper] {
        let html = try await SourceHTTP.string(from: Self.listURL(query, page: page))
        return Self.parse(html)
    }

    static func listURL(_ query: WallpaperQuery, page: Int) -> URL {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var components: URLComponents
        if !text.isEmpty {
            components = URLComponents(string: "\(site)/search/")!
            components.queryItems = [.init(name: "q", value: text)]
        } else if let category = query.selection("category").first {
            components = URLComponents(string: "\(site)/\(category)/")!
        } else {
            let path = switch query.sort {
            case "popular": "/most-popular-4k-wallpapers/"
            case "best": "/best-4k-wallpapers/"
            case "random": "/random-wallpapers/"
            default: "/"
            }
            components = URLComponents(string: site + path)!
        }
        if page > 1 { components.queryItems = (components.queryItems ?? []) + [.init(name: "page", value: String(page))] }
        return components.urlEncodingPlus!
    }

    /// 每张卡片：<meta itemprop="keywords" content="…"> … <a title="X Wallpaper" … href="/分类/短名-编号.html"> … <img src="/images/walls/thumbs/编号.jpg">
    /// 缩略图有 .jpg 也有 .png，从卡片里读扩展名；原图都提供 .jpg
    static func parse(_ html: String) -> [RemoteWallpaper] {
        let card = /<meta itemprop="keywords" content="([^"]*)">.*?<a title="([^"]*)"[^>]*href="\/([a-z0-9-]+)\/([a-z0-9-]+)-(\d+)\.html"(?:(?!<meta itemprop="keywords").)*?src="\/images\/walls\/thumbs\/\d+\.([a-z]+)"/
            .dotMatchesNewlines()
        var seen = Set<String>()
        return html.matches(of: card).compactMap { match in
            let (_, keywords, title, category, slug, number, thumbExtension) = match.output
            let id = "\(Self.id)-\(number)"
            guard seen.insert(id).inserted,
                  let page = URL(string: "\(site)/\(category)/\(slug)-\(number).html"),
                  let image = URL(string: "\(site)/images/wallpapers/\(slug)-3840x2160-\(number).jpg") else { return nil }
            return RemoteWallpaper(
                id: id, sourceID: Self.id, pageURL: page, imageURL: image,
                thumbURL: URL(string: "\(site)/images/walls/thumbs_2t/\(number).\(thumbExtension)"),
                title: decodeEntities(String(title)).replacingOccurrences(of: " Wallpaper", with: ""),
                resolution: "3840x2160", category: String(category),
                tags: keywords.split(separator: ",").map { decodeEntities($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { !$0.isEmpty && !["4K", "5K", "8K"].contains($0) })
        }
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}
