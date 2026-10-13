//
//  SteamWorkshopAPI.swift
//  wallhaven
//
//  Steam 官方 Web API：
//   - IPublishedFileService/QueryFiles：浏览 / 搜索工坊，需要用户自己的 Web API Key
//     （https://steamcommunity.com/dev/apikey 免费申请）
//   - ISteamRemoteStorage/GetPublishedFileDetails：按 ID 查详情，无需 Key
//

import Foundation

struct SteamWorkshopAPI: Sendable {
    struct Page: Sendable {
        let items: [WorkshopItem]
        let nextCursor: String?
        let total: Int
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    func query(
        apiKey: String,
        text: String,
        sort: WorkshopSort,
        type: WorkshopTypeFilter,
        includeQuestionable: Bool,
        cursor: String?
    ) async throws -> Page {
        var components = URLComponents(string: "https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/")!
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var items: [URLQueryItem] = [
            .init(name: "key", value: apiKey),
            .init(name: "appid", value: WorkshopConstants.appID),
            // 有关键词时按相关度排序
            .init(name: "query_type", value: String(trimmed.isEmpty ? sort.queryType : 12)),
            .init(name: "numperpage", value: "30"),
            .init(name: "cursor", value: cursor ?? "*"),
            .init(name: "return_previews", value: "true"),
            .init(name: "return_tags", value: "true"),
            .init(name: "return_metadata", value: "true"),
            .init(name: "match_all_tags", value: "true"),
        ]
        if sort == .trend { items.append(.init(name: "days", value: "7")) }
        if !trimmed.isEmpty { items.append(.init(name: "search_text", value: trimmed)) }

        var required: [String] = []
        if let tag = type.workshopTag { required.append(tag) }
        var excluded = ["Mature"]
        if !includeQuestionable { excluded.append("Questionable") }
        // macOS 无法运行 application 类型
        excluded.append("Application")
        for (index, tag) in required.enumerated() {
            items.append(.init(name: "requiredtags[\(index)]", value: tag))
        }
        for (index, tag) in excluded.enumerated() {
            items.append(.init(name: "excludedtags[\(index)]", value: tag))
        }
        components.queryItems = items

        let (data, response) = try await session.data(from: components.url!)
        guard let http = response as? HTTPURLResponse else { throw WallperError.network("无效的响应。") }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw WallperError.network("Steam Web API Key 无效，请在设置中检查。")
        }
        guard http.statusCode == 200 else { throw WallperError.network("Steam 工坊请求失败（\(http.statusCode)）。") }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = root["response"] as? [String: Any] else {
            throw WallperError.network("无法解析 Steam 返回的数据。")
        }
        let details = body["publishedfiledetails"] as? [[String: Any]] ?? []
        let cursor = body["next_cursor"] as? String
        return Page(
            items: details.compactMap(Self.item(from:)),
            // 最后一页时 Steam 会返回与请求相同的 cursor
            nextCursor: details.isEmpty ? nil : cursor,
            total: Self.int(body["total"])
        )
    }

    /// 按 ID 查询（支持粘贴工坊链接），无需 API Key
    func details(ids: [String]) async throws -> [WorkshopItem] {
        guard !ids.isEmpty else { return [] }
        var request = URLRequest(url: URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = ["itemcount=\(ids.count)"]
        for (index, id) in ids.enumerated() { form.append("publishedfileids%5B\(index)%5D=\(id)") }
        request.httpBody = form.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = root["response"] as? [String: Any] else {
            throw WallperError.network("获取工坊详情失败。")
        }
        let details = body["publishedfiledetails"] as? [[String: Any]] ?? []
        return details
            .filter { ($0["consumer_app_id"].map(Self.int) ?? Int(WorkshopConstants.appID)) == Int(WorkshopConstants.appID) }
            .compactMap(Self.item(from:))
    }

    /// 从工坊链接或纯数字中提取 ID
    static func extractIDs(from text: String) -> [String] {
        let pattern = #"(?:[?&]id=)?(\d{6,12})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var ids: [String] = []
        for match in regex.matches(in: text, range: range) {
            if let r = Range(match.range(at: 1), in: text), !ids.contains(String(text[r])) {
                ids.append(String(text[r]))
            }
        }
        return ids
    }

    // MARK: - Parsing

    private static func item(from json: [String: Any]) -> WorkshopItem? {
        // result != 1 表示条目不存在或不可见
        if let result = json["result"], int(result) != 1 { return nil }
        guard let id = json["publishedfileid"] as? String, let title = json["title"] as? String else { return nil }

        let tags: [String] = (json["tags"] as? [[String: Any]])?.compactMap { $0["tag"] as? String } ?? []
        let ratings = ["Everyone", "Questionable", "Mature"]
        let typeTag = tags.first { ["Scene", "Video", "Web", "Application"].contains($0) }

        return WorkshopItem(
            id: id,
            title: title,
            type: WEProjectType(declared: typeTag),
            previewURL: (json["preview_url"] as? String).flatMap(URL.init(string:)),
            // 去掉分级、类型、审核状态、分辨率等非内容标签
            tags: tags.filter { tag in
                !ratings.contains(tag) && tag != typeTag && !["Wallpaper", "Approved", "Preset"].contains(tag)
                    && !tag.contains(" x ")
            },
            contentRating: tags.first { ratings.contains($0) },
            fileSize: int(json["file_size"]),
            subscriptions: int(json["subscriptions"]),
            favorited: int(json["favorited"]),
            authorID: json["creator"] as? String
        )
    }

    /// Steam 的数字字段有时是字符串
    private static func int(_ value: Any?) -> Int {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) ?? 0 }
        return 0
    }
}
