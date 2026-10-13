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

struct WallhavenCollection: Decodable, Sendable {
    let id: Int
    let label: String
    let views: Int
    let count: Int
}

struct WallhavenCollectionsResponse: Decodable, Sendable {
    let data: [WallhavenCollection]
}

struct WallhavenCollectionWallpapersResponse: Decodable, Sendable {
    let data: [WallhavenWallpaper]
    let meta: WallhavenMeta
}

struct WallhavenMeta: Decodable, Sendable {
    let current_page: Int
    let last_page: Int
}


struct WallhavenSearchResponse: Decodable, Sendable {
    let data: [WallhavenWallpaper]
}

struct WallhavenSettingsResponse: Decodable, Sendable {
    let data: WallhavenSettingsData
}

struct WallhavenSettingsData: Decodable, Sendable {
    let purity: [String]
}

struct WallhavenWallpaper: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let path: URL
    let thumbURL: URL?
    let resolution: String
    let category: String
    let favorites: Int
    let ratio: String
    let purity: String

    enum CodingKeys: String, CodingKey {
        case id
        case url
        case path
        case thumbs
        case resolution
        case category
        case favorites
        case ratio
        case purity
    }

    enum ThumbsCodingKeys: String, CodingKey {
        case large
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        url = try container.decode(URL.self, forKey: .url)
        path = try container.decode(URL.self, forKey: .path)
        resolution = try container.decode(String.self, forKey: .resolution)
        category = try container.decode(String.self, forKey: .category)
        favorites = try container.decode(Int.self, forKey: .favorites)
        ratio = try container.decode(String.self, forKey: .ratio)
        purity = try container.decode(String.self, forKey: .purity)

        if let thumbsContainer = try? container.nestedContainer(keyedBy: ThumbsCodingKeys.self, forKey: .thumbs) {
            thumbURL = try thumbsContainer.decodeIfPresent(URL.self, forKey: .large)
        } else {
            thumbURL = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        try container.encode(path, forKey: .path)
        try container.encode(resolution, forKey: .resolution)
        try container.encode(category, forKey: .category)
        try container.encode(favorites, forKey: .favorites)
        try container.encode(ratio, forKey: .ratio)
        try container.encode(purity, forKey: .purity)

        var thumbsContainer = container.nestedContainer(keyedBy: ThumbsCodingKeys.self, forKey: .thumbs)
        try thumbsContainer.encodeIfPresent(thumbURL, forKey: .large)
    }
}

enum SortOrder: String, CaseIterable, Identifiable, Sendable {
    case relevance
    case random
    case dateAdded = "date_added"
    case views
    case favorites
    case toplist

    var id: String { rawValue }

    var label: String {
        switch self {
        case .relevance: return "相关性"
        case .random: return "随机"
        case .dateAdded: return "最新"
        case .views: return "浏览量"
        case .favorites: return "收藏数"
        case .toplist: return "热门"
        }
    }
}

enum WallperError: LocalizedError, Sendable {
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
