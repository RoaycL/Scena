//
//  WallhavenModels.swift
//  wallhaven
//
//  Created by RoaycL on 2026/4/17.
//

import Foundation

struct FavoriteFolder: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var wallpaperIDs: [String]
    
    init(id: UUID = UUID(), name: String, wallpaperIDs: [String] = []) {
        self.id = id
        self.name = name
        self.wallpaperIDs = wallpaperIDs
    }
}

nonisolated struct WallhavenCollection: Decodable, Sendable {
    let id: Int
    let label: String
    let views: Int
    let count: Int
}

nonisolated struct WallhavenCollectionsResponse: Decodable, Sendable {
    let data: [WallhavenCollection]
}

nonisolated struct WallhavenCollectionWallpapersResponse: Decodable, Sendable {
    let data: [WallhavenWallpaper]
    let meta: WallhavenMeta
}

nonisolated struct WallhavenMeta: Decodable, Sendable {
    let current_page: Int
    let last_page: Int
}


nonisolated struct WallhavenSearchResponse: Decodable, Sendable {
    let data: [WallhavenWallpaper]
}

nonisolated struct WallhavenSettingsResponse: Decodable, Sendable {
    let data: WallhavenSettingsData
}

nonisolated struct WallhavenSettingsData: Decodable, Sendable {
    let purity: [String]
}

/// Wallhaven 接口返回的壁纸，转换成 RemoteWallpaper 后再交给界面
nonisolated struct WallhavenWallpaper: Decodable, Sendable {
    let id: String
    let url: URL
    let path: URL
    let thumbs: Thumbs?
    let resolution: String
    let category: String
    let purity: String
    let favorites: Int
    let views: Int?
    let colors: [String]?
    let file_size: Int?

    struct Thumbs: Decodable, Sendable {
        let large: URL?
    }

    var remote: RemoteWallpaper {
        RemoteWallpaper(id: id, sourceID: WallhavenSource.id, pageURL: url, imageURL: path, thumbURL: thumbs?.large,
                        resolution: resolution, category: category, rating: purity, favorites: favorites,
                        views: views ?? 0, fileSize: file_size ?? 0, colors: colors ?? [])
    }
}

nonisolated enum WallperError: LocalizedError, Sendable {
    case network(String)
    case io(String)
    case wallpaper(String)

    var errorDescription: String? {
        switch self {
        case .network(let message), .io(let message), .wallpaper(let message):
            return message
        }
    }
}
