//
//  WallhavenClient.swift
//  wallhaven
//
//  Created by RoaycL on 2026/4/17.
//

import Foundation

struct WallhavenClient: Sendable {
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    func validateAPIKey(_ apiKey: String) async throws {
        var components = URLComponents(string: "https://wallhaven.cc/api/v1/settings")!
        components.queryItems = [.init(name: "apikey", value: apiKey)]
        let (data, response) = try await session.data(from: components.urlEncodingPlus!)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WallperError.network("无效的响应。")
        }
        if httpResponse.statusCode == 401 {
            throw WallperError.network("无效的 Wallhaven API 密钥。")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw WallperError.network("无法验证 API 密钥。")
        }
        _ = try JSONDecoder().decode(WallhavenSettingsResponse.self, from: data)
    }

    func getCollections(apiKey: String) async throws -> [WallhavenCollection] {
        var components = URLComponents(string: "https://wallhaven.cc/api/v1/collections")!
        components.queryItems = [.init(name: "apikey", value: apiKey)]
        let (data, response) = try await session.data(from: components.urlEncodingPlus!)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            throw WallperError.network("获取合集列表失败 (状态码: \(statusCode), \(body))")
        }
        return try JSONDecoder().decode(WallhavenCollectionsResponse.self, from: data).data
    }

    func getCollectionWallpapers(username: String, collectionId: Int, page: Int, apiKey: String) async throws -> WallhavenCollectionWallpapersResponse {
        var components = URLComponents(string: "https://wallhaven.cc/api/v1/collections/\(username)/\(collectionId)")!
        components.queryItems = [
            .init(name: "page", value: String(page)),
            .init(name: "apikey", value: apiKey)
        ]
        
        let (data, response) = try await session.data(from: components.urlEncodingPlus!)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            throw WallperError.network("获取合集图片失败 (状态码: \(statusCode), \(body))")
        }
        return try JSONDecoder().decode(WallhavenCollectionWallpapersResponse.self, from: data)
    }

    func search(query: String, page: Int, sorting: SortOrder, categories: String, purity: String, resolutions: [String] = [], apiKey: String?) async throws -> [WallhavenWallpaper] {
        var components = URLComponents(string: "https://wallhaven.cc/api/v1/search")!
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var items: [URLQueryItem] = [
            .init(name: "page", value: String(page)),
            .init(name: "sorting", value: sorting.rawValue),
            .init(name: "purity", value: purity),
            .init(name: "categories", value: categories)
        ]
        if !trimmed.isEmpty {
            items.append(.init(name: "q", value: trimmed))
        }
        // 精确分辨率，多个用逗号分隔（wallhaven API 的 resolutions 参数）
        if !resolutions.isEmpty {
            items.append(.init(name: "resolutions", value: resolutions.joined(separator: ",")))
        }
        if let apiKey, !apiKey.isEmpty {
            items.append(.init(name: "apikey", value: apiKey))
        }
        components.queryItems = items

        let (data, response) = try await session.data(from: components.urlEncodingPlus!)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WallperError.network("无效的响应。")
        }
        if httpResponse.statusCode == 401 {
            throw WallperError.network("未授权。请检查您的 Wallhaven 登录状态。")
        }
        if httpResponse.statusCode == 429 {
            throw WallhavenRateLimited()
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw WallperError.network("加载壁纸失败。")
        }
        return try JSONDecoder().decode(WallhavenSearchResponse.self, from: data).data
    }

    func fetchWallpaperDetails(id: String, apiKey: String?) async throws -> [String] {
        var components = URLComponents(string: "https://wallhaven.cc/api/v1/w/\(id)")!
        if let apiKey, !apiKey.isEmpty {
            components.queryItems = [.init(name: "apikey", value: apiKey)]
        }
        let (data, response) = try await session.data(from: components.urlEncodingPlus!)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw WallperError.network("获取详情失败。")
        }
        
        struct DetailResponse: Decodable {
            let data: DetailData
            struct DetailData: Decodable {
                let tags: [Tag]
                struct Tag: Decodable {
                    let name: String
                }
            }
        }
        
        let decoder = JSONDecoder()
        let result = try decoder.decode(DetailResponse.self, from: data)
        return result.data.tags.map { $0.name }
    }
}

nonisolated extension URLComponents {
    /// 与 url 相同，但把查询参数里的「+」转义成 %2B。
    /// URLComponents 不会转义「+」，服务器会把它当成空格：Steam 的翻页 cursor 经常带「+」（不转义时那一页返回空，
    /// 工坊列表停在 4～5 页「到底了」），wallhaven 搜索里的「+标签」也会失效
    var urlEncodingPlus: URL? {
        var copy = self
        copy.percentEncodedQuery = percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return copy.url
    }
}

/// wallhaven API 每分钟最多 45 次请求，超出返回 429
nonisolated struct WallhavenRateLimited: LocalizedError {
    var errorDescription: String? { "请求太频繁（wallhaven 每分钟最多 45 次），请稍后再试" }
}
