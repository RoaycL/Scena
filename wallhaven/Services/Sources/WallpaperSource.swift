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
}

extension WallpaperSource {
    func tags(for wallpaper: RemoteWallpaper, credential: String?) async throws -> [String] { wallpaper.tags }
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
    static let all: [any WallpaperSource] = [WallhavenSource()]

    static func source(id: String) -> (any WallpaperSource)? {
        all.first { $0.descriptor.id == id }
    }
}
