//
//  WallhavenSource.swift
//  wallhaven
//

import Foundation

nonisolated struct WallhavenSource: WallpaperSource {
    static let id = "wallhaven"

    private enum Filter {
        static let categories = "categories"
        static let purity = "purity"
        static let resolutions = "resolutions"
    }

    private let client = WallhavenClient()

    let descriptor = WallpaperSourceDescriptor(
        id: WallhavenSource.id,
        name: "Wallhaven",
        filters: [
            SourceFilter(id: Filter.categories, title: "分类", mode: .atLeastOne, options: [
                SourceOption(id: "general", title: "常规"),
                SourceOption(id: "anime", title: "动漫"),
                SourceOption(id: "people", title: "人物"),
            ], defaultSelection: ["general", "anime", "people"]),
            SourceFilter(id: Filter.purity, title: "内容分级", mode: .atLeastOne, options: [
                SourceOption(id: "sfw", title: "SFW", tint: .green),
                SourceOption(id: "sketchy", title: "Sketchy", tint: .orange, requiresAccount: true),
                SourceOption(id: "nsfw", title: "NSFW", tint: .red, requiresAccount: true),
            ], defaultSelection: ["sfw"], signedOutNote: "登录后可开启 Sketchy / NSFW"),
            SourceFilter(id: Filter.resolutions, title: "分辨率", mode: .anyOf,
                options: ["1920x1080", "2560x1440", "3440x1440", "3840x2160", "5120x2880"].map {
                    SourceOption(id: $0, title: $0.replacingOccurrences(of: "x", with: "×"))
                }, defaultSelection: [], note: "可多选"),
        ],
        sorts: [
            SourceOption(id: "relevance", title: "相关性"),
            SourceOption(id: "random", title: "随机"),
            SourceOption(id: "date_added", title: "最新"),
            SourceOption(id: "views", title: "浏览量"),
            SourceOption(id: "favorites", title: "收藏数"),
            SourceOption(id: "toplist", title: "热门"),
        ],
        defaultSort: "favorites",
        randomSort: "random"
    )

    func search(_ query: WallpaperQuery, page: Int) async throws -> [RemoteWallpaper] {
        try await client.search(
            query: query.text, page: page, sorting: query.sort,
            categories: Self.bitmask(["general", "anime", "people"], query.selection(Filter.categories)),
            purity: Self.bitmask(["sfw", "sketchy", "nsfw"], query.selection(Filter.purity)),
            resolutions: query.selection(Filter.resolutions).sorted(),
            apiKey: query.credential
        ).map(\.remote)
    }

    func tags(for wallpaper: RemoteWallpaper, credential: String?) async throws -> [String] {
        try await client.fetchWallpaperDetails(id: wallpaper.id, apiKey: credential)
    }

    /// Wallhaven 用「110」这样的位串表示多选
    static func bitmask(_ order: [String], _ selection: Set<String>) -> String {
        order.map { selection.contains($0) ? "1" : "0" }.joined()
    }
}
