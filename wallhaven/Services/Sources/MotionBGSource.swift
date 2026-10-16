//
//  MotionBGSource.swift
//  wallhaven
//
//  MotionBG（motionbgs.com）：免费的 4K 动态视频壁纸。没有接口，解析列表网页。
//  卡片里带编号和短名，预览视频、封面和原片地址都按站点固定格式拼出，不需要再请求详情页。
//

import Foundation

nonisolated struct MotionBGSource: WallpaperSource {
    static let id = "motionbgs"
    private static let site = "https://motionbgs.com"

    let descriptor = WallpaperSourceDescriptor(
        id: MotionBGSource.id,
        name: "MotionBG",
        filters: [
            SourceFilter(id: "tag", title: "分类", mode: .oneOf, options: [
                ("anime", "动漫"), ("games", "游戏"), ("nature", "自然"), ("landscape", "风景"), ("city", "城市"),
                ("rain", "雨景"), ("space", "太空"), ("cyberpunk", "赛博朋克"), ("sci-fi", "科幻"),
                ("fantasy", "奇幻"), ("car", "汽车"), ("superhero", "超级英雄"), ("girl", "动漫少女"),
            ].map { SourceOption(id: $0.0, title: $0.1) }, defaultSelection: [], note: "搜索时只显示一页结果"),
        ],
        sorts: [SourceOption(id: "latest", title: "最新")],
        defaultSort: "latest",
        randomSort: nil,
        folderName: "MotionBG"
    )

    func search(_ query: WallpaperQuery, page: Int) async throws -> [RemoteWallpaper] {
        guard let url = Self.listURL(query, page: page) else { return [] }
        return Self.parse(try await SourceHTTP.string(from: url))
    }

    static func listURL(_ query: WallpaperQuery, page: Int) -> URL? {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            // 站内搜索没有翻页
            guard page == 1 else { return nil }
            var components = URLComponents(string: "\(site)/search")!
            components.queryItems = [.init(name: "q", value: text)]
            return components.urlEncodingPlus
        }
        let base = query.selection("tag").first.map { "\(site)/tag:\($0)/" } ?? "\(site)/"
        return URL(string: page > 1 ? "\(base)\(page)/" : base)
    }

    /// 卡片：<a title="X live wallpaper" href=/短名> … /media/编号/文件名.jpg … <span class=ttl>标题</span> <span class=frm> 4K </span>
    /// 文件名可能带分辨率后缀（name.3840x2160），预览视频去掉后缀后是 name.960x540.mp4。
    /// 匹配限制在一张卡片内（不越过下一个 <a title=），某张卡片格式不同也不会和后面的错位
    static func parse(_ html: String) -> [RemoteWallpaper] {
        let card = /<a title="[^"]*" href=\/([a-z0-9-]+)>(?:(?!<a title=).)*?\/media\/(\d+)\/([^\/\s>]+?)\.jpg(?:(?!<a title=).)*?<span class=ttl>([^<]*)<\/span>\s*<span class=frm>\s*([^<]*?)\s*<\/span>/
            .dotMatchesNewlines()
        var seen = Set<String>()
        return html.matches(of: card).compactMap { match in
            let (_, path, number, file, title, quality) = match.output
            let id = "\(Self.id)-\(number)"
            let is4K = quality.uppercased().contains("4K")
            let base = String(file).replacing(/\.\d+x\d+$/, with: "")
            guard seen.insert(id).inserted,
                  let page = URL(string: "\(site)/\(path)"),
                  let video = URL(string: "\(site)/dl/\(is4K ? "4k" : "hd")/\(number)/") else { return nil }
            return RemoteWallpaper(
                id: id, sourceID: Self.id, pageURL: page, imageURL: video,
                thumbURL: URL(string: "\(site)/i/c/546x308/media/\(number)/\(file).jpg"),
                posterURL: URL(string: "\(site)/media/\(number)/\(file).jpg"),
                previewVideoURL: URL(string: "\(site)/media/\(number)/\(base).960x540.mp4"),
                mediaType: .video, title: decodeEntities(String(title)),
                resolution: is4K ? "3840x2160" : "1920x1080")
        }
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"").trimmingCharacters(in: .whitespaces)
    }
}
