//
//  LibraryItems.swift
//  wallhaven
//
//  「资料库」：硬盘上所有可以直接设为壁纸的内容放在一起
//  （wallhaven 下载、导入的图片和视频、已下载的创意工坊壁纸），沉浸式展示。
//

import SwiftUI

/// 资料库的来源筛选
enum LibrarySource: String, CaseIterable, Identifiable {
    case all = "全部"
    case wallhaven = "Wallhaven"
    case workshop = "创意工坊"
    case imported = "本地导入"

    var id: String { rawValue }

    func matches(_ item: GalleryItem) -> Bool {
        switch self {
        case .all: true
        case .wallhaven: item.local?.source == .wallhaven
        case .imported: item.local?.source == .imported
        case .workshop: item.workshop != nil
        }
    }
}

extension GalleryItem {
    var libraryTitle: String {
        switch origin {
        case .remote(let wallpaper): "wallhaven #\(wallpaper.id)"
        case .local(let item): item.displayName
        case .workshop(let item): item.title
        }
    }

    var libraryKindLabel: String {
        switch origin {
        case .remote: "wallhaven"
        case .local(let item): "\(item.source == .wallhaven ? "Wallhaven" : "本地导入") · \(item.isVideo ? "视频" : "图片")"
        case .workshop(let item): "工坊 · \(item.type.label)"
        }
    }

    var librarySymbol: String {
        switch origin {
        case .remote: "photo"
        case .local(let item): item.isVideo ? "film" : "photo"
        case .workshop(let item):
            switch item.type {
            case .video: "film"
            case .web: "globe"
            default: "cube"
            }
        }
    }

    /// 本地文件夹或文件（用于在 Finder 中显示）
    var libraryFileURL: URL? {
        switch origin {
        case .remote: nil
        case .local(let item): item.url
        case .workshop(let item): item.localFolder
        }
    }

    var libraryFileSize: Int {
        switch origin {
        case .remote(let wallpaper): wallpaper.fileSize
        case .local(let item): item.fileSize
        case .workshop(let item): item.fileSize
        }
    }

    func matchesLibrarySearch(_ query: String) -> Bool {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return true }
        if libraryTitle.localizedCaseInsensitiveContains(keyword) { return true }
        return workshop?.tags.contains { $0.localizedCaseInsensitiveContains(keyword) || WorkshopTags.label(for: $0).contains(keyword) } ?? false
    }
}

/// 选中项被移除后的替代选择
nonisolated enum SelectionFallback {
    /// 新列表是旧列表的子集（只是移除了条目）时，返回被移除项原位置的下一项，没有则上一项；
    /// 列表整体变化（搜索、筛选、切换页面）时返回 nil，由调用方回到第一项
    static func neighbor(of removedID: String, previousIDs: [String], currentIDs: [String]) -> String? {
        guard let oldIndex = previousIDs.firstIndex(of: removedID) else { return nil }
        let remaining = Set(currentIDs)
        guard !remaining.contains(removedID), Set(previousIDs).isSuperset(of: remaining) else { return nil }
        return previousIDs[(oldIndex + 1)...].first(where: remaining.contains)
            ?? previousIDs[..<oldIndex].last(where: remaining.contains)
    }
}

extension GalleryItem {
    /// 加入资料库的时间：本地文件的创建时间、工坊壁纸文件夹的下载时间
    var addedDate: Date {
        switch origin {
        case .local(let item): item.creationDate
        case .workshop(let item): item.downloadedAt ?? .distantPast
        case .remote: .distantPast
        }
    }
}
