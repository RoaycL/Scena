//
//  WorkshopModels.swift
//  wallhaven
//
//  Wallpaper Engine 创意工坊条目模型。目录约定与 linux-wallpaperengine / webwallgl 一致：
//  每个条目一个以工坊 ID 命名的文件夹，根目录有 project.json（title / type / file / preview / tags）。
//

import Foundation

nonisolated enum WorkshopConstants {
    /// Wallpaper Engine 的 Steam AppID
    static let appID = "431960"
}

nonisolated enum WEProjectType: String, Codable, CaseIterable, Sendable {
    case scene, video, web, application, unknown

    init(declared: String?) {
        self = WEProjectType(rawValue: declared?.lowercased() ?? "") ?? .unknown
    }

    var label: String {
        switch self {
        case .scene: "场景"
        case .video: "视频"
        case .web: "网页"
        case .application: "应用"
        case .unknown: "未知"
        }
    }

    /// application 类型是 Windows 可执行程序，macOS 上无法运行
    var isPlayable: Bool { self != .application }
}

nonisolated struct WorkshopItem: Identifiable, Hashable, Sendable {
    /// 工坊 ID（publishedfileid）；本地无 ID 的工程用文件夹名
    let id: String
    var title: String
    var type: WEProjectType
    var previewURL: URL?
    var tags: [String]
    var contentRating: String?
    var fileSize: Int = 0
    var subscriptions: Int = 0
    var favorited: Int = 0
    var authorID: String?
    /// 已下载 / 导入时的本地文件夹
    var localFolder: URL?
    /// project.json 的 file 字段（场景包 / 视频文件 / 网页入口）
    var entryFile: String?

    var isDownloaded: Bool { localFolder != nil }

    var workshopPageURL: URL? {
        guard id.allSatisfy(\.isNumber) else { return nil }
        return URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")
    }

    /// 能直接交给 AVFoundation 播放的视频文件（比 WebGL 解码更省电）
    var nativeVideoURL: URL? {
        guard type == .video, let localFolder, let entryFile else { return nil }
        let url = localFolder.appendingPathComponent(entryFile)
        return MediaType.isVideo(url) ? url : nil
    }
}

nonisolated extension WorkshopItem {
    /// 从本地文件夹读取 project.json
    static func load(from folder: URL) -> WorkshopItem? {
        let projectURL = folder.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // workshopid 在不同版本里可能是字符串或数字
        let workshopID: String? = {
            if let s = json["workshopid"] as? String, !s.isEmpty { return s }
            if let n = json["workshopid"] as? NSNumber { return n.stringValue }
            return nil
        }()

        let file = json["file"] as? String
        var type = WEProjectType(declared: json["type"] as? String)
        if type == .unknown {
            type = inferType(in: folder, declaredFile: file)
        }

        let preview = (json["preview"] as? String).map { folder.appendingPathComponent($0) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }

        return WorkshopItem(
            id: workshopID ?? folder.lastPathComponent,
            title: (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? folder.lastPathComponent,
            type: type,
            previewURL: preview,
            tags: json["tags"] as? [String] ?? [],
            contentRating: json["contentrating"] as? String,
            fileSize: folderSize(folder),
            localFolder: folder,
            entryFile: file
        )
    }

    /// project.json 没写 type 时按内容推断（规则参考 webwallgl 的 we-library-scan）
    private static func inferType(in folder: URL, declaredFile: String?) -> WEProjectType {
        let fm = FileManager.default
        let exists = { (name: String) in fm.fileExists(atPath: folder.appendingPathComponent(name).path) }
        if ["index.html", "web/index.html"].contains(where: exists) { return .web }
        if ["scene.pkg", "scenes/scene.pkg", "gifscene.pkg", "scene.json"].contains(where: exists) { return .scene }
        if let declaredFile, MediaType.isVideo(URL(fileURLWithPath: declaredFile)) { return .video }
        return .unknown
    }

    private static func folderSize(_ folder: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }
}

nonisolated enum WorkshopSort: String, CaseIterable, Identifiable, Codable, Sendable {
    case trend, topRated, newest, mostSubscribed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .trend: "近期热门"
        case .topRated: "最高评分"
        case .newest: "最新发布"
        case .mostSubscribed: "订阅最多"
        }
    }

    /// Steam EPublishedFileQueryType
    var queryType: Int {
        switch self {
        case .topRated: 0
        case .newest: 1
        case .trend: 3
        case .mostSubscribed: 9
        }
    }
}

nonisolated enum WorkshopTypeFilter: String, CaseIterable, Identifiable, Codable, Sendable {
    case all, scene, video, web

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "全部"
        case .scene: "场景"
        case .video: "视频"
        case .web: "网页"
        }
    }

    /// 工坊里的类型标签
    var workshopTag: String? {
        switch self {
        case .all: nil
        case .scene: "Scene"
        case .video: "Video"
        case .web: "Web"
        }
    }
}

/// 年龄分级（工坊 Age Rating 标签）
nonisolated enum WorkshopRating: String, CaseIterable, Identifiable, Codable, Sendable {
    case everyone = "Everyone"
    case questionable = "Questionable"
    case mature = "Mature"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .everyone: "大众级 (G)"
        case .questionable: "家长指导级 (PG-13)"
        case .mature: "限制级/成人级 (R-18)"
        }
    }
}

/// Wallpaper Engine 工坊官方标签（取自 Steam 创意工坊的筛选项）
nonisolated enum WorkshopTags {
    // 显示名称与官方中文筛选栏保持一致；tag 保留 Steam 请求使用的原始值。
    static let genres: [(tag: String, label: String)] = [
        ("Abstract", "抽象"), ("Animal", "动物"), ("Anime", "动漫"), ("Cartoon", "卡通"),
        ("CGI", "CGI"), ("Cyberpunk", "网络朋克"), ("Fantasy", "幻想"), ("Game", "游戏"),
        ("Girls", "女生"), ("Guys", "男生"), ("Landscape", "风景"), ("Medieval", "中世纪"),
        ("Memes", "网络事物"), ("MMD", "MMD (Miku-Miku Dance)"), ("Music", "音乐"),
        ("Nature", "自然"), ("Pixel art", "像素艺术"), ("Relaxing", "放松"), ("Retro", "复古"),
        ("Sci-Fi", "科幻"), ("Sports", "运动"), ("Technology", "科技"), ("Television", "电视节目"),
        ("Vehicle", "汽车"), ("Unspecified", "未指定样式"),
    ]

    static let features: [(tag: String, label: String)] = [
        ("Approved", "🏆 广受好评"),
        ("Audio responsive", "音频响应"), ("Customizable", "可自定义的"), ("3D", "3D"),
        ("HDR", "HDR"), ("Media Integration", "媒体联动"),
    ]

    static let resolutions: [(tag: String, label: String)] = [
        ("1920 x 1080", "1080p"), ("2560 x 1440", "2K 1440p"), ("3840 x 2160", "4K"),
        ("Ultrawide 2560 x 1080", "带鱼屏 2560×1080"), ("Ultrawide 3440 x 1440", "带鱼屏 3440×1440"),
        ("Dual 3840 x 1080", "双屏 3840×1080"), ("Dual 5120 x 1440", "双屏 5120×1440"),
        ("Portrait 1080 x 1920", "竖屏 1080×1920"), ("Dynamic resolution", "动态分辨率"),
    ]

    /// 热门排序的时间范围（天），-1 表示全部时间
    static let trendRanges: [(days: Int, label: String)] = [
        (1, "今天"), (7, "本周"), (30, "本月"), (90, "三个月"), (365, "一年"), (-1, "全部"),
    ]

    private static let labels: [String: String] = Dictionary(
        (genres + features + resolutions).map { ($0.tag, $0.label) },
        uniquingKeysWith: { first, _ in first }
    )

    static func label(for tag: String) -> String { labels[tag] ?? tag }
    static func isGenre(_ tag: String) -> Bool { genres.contains { $0.tag == tag } }
}

/// 创意工坊筛选条件：在线搜索转成 Steam 的 required / excluded 标签，本地库直接在内存里过滤
nonisolated struct WorkshopFilters: Equatable, Codable, Sendable {
    var type: WorkshopTypeFilter = .all
    var ratings: Set<WorkshopRating> = [.everyone]
    /// 题材（多选时需同时包含，与 Steam 工坊行为一致）
    var genres: Set<String> = [] {
        didSet { genres.remove("Anime") }
    }
    var features: Set<String> = []
    var resolution: String?
    var sort: WorkshopSort = .trend
    var trendDays = 7
    var hideAnime = false {
        didSet { genres.remove("Anime") }
    }

    init() {}

    // 新开关缺失时沿用旧偏好，不能因升级丢失整份筛选设置。
    enum CodingKeys: String, CodingKey {
        case type, ratings, genres, features, resolution, sort, trendDays, hideAnime
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decodeIfPresent(WorkshopTypeFilter.self, forKey: .type) ?? .all
        ratings = try values.decodeIfPresent(Set<WorkshopRating>.self, forKey: .ratings) ?? [.everyone]
        genres = try values.decodeIfPresent(Set<String>.self, forKey: .genres) ?? []
        features = try values.decodeIfPresent(Set<String>.self, forKey: .features) ?? []
        resolution = try values.decodeIfPresent(String.self, forKey: .resolution)
        sort = try values.decodeIfPresent(WorkshopSort.self, forKey: .sort) ?? .trend
        trendDays = try values.decodeIfPresent(Int.self, forKey: .trendDays) ?? 7
        hideAnime = try values.decodeIfPresent(Bool.self, forKey: .hideAnime) ?? false
        genres.remove("Anime")
    }

    mutating func toggleGenre(_ tag: String) {
        guard tag != "Anime" else { return }
        genres.formSymmetricDifference([tag])
    }

    mutating func selectGenre(_ tag: String) {
        if tag == "Anime" {
            // 点击素材的动漫标签只恢复显示，不再创建“只看动漫”条件。
            hideAnime = false
        } else {
            genres = [tag]
        }
    }

    var isDefault: Bool { self == WorkshopFilters() }

    /// 非默认的筛选项数量（显示在筛选按钮的角标上）
    var activeCount: Int {
        var count = genres.count + features.count
        if type != .all { count += 1 }
        if ratings != [.everyone] { count += 1 }
        if resolution != nil { count += 1 }
        if hideAnime { count += 1 }
        return count
    }

    var requiredTags: [String] {
        // 只要壁纸，排除素材包（Asset）和预设（Preset）
        var tags = ["Wallpaper"]
        if let typeTag = type.workshopTag { tags.append(typeTag) }
        tags += genres.filter { $0 != "Anime" }.sorted() + features.sorted()
        if let resolution { tags.append(resolution) }
        return tags
    }

    /// 分级用排除法表达「或」：未勾选的分级全部排除
    var excludedTags: [String] {
        WorkshopRating.allCases.filter { !ratings.contains($0) }.map(\.rawValue)
            + ["Application"] + (hideAnime ? ["Anime"] : [])
    }

    func matches(_ item: WorkshopItem, query: String) -> Bool {
        if let typeTag = type.workshopTag, item.type.rawValue != typeTag.lowercased() { return false }
        let rating = WorkshopRating(rawValue: item.contentRating ?? "") ?? .everyone
        if !ratings.contains(rating) { return false }
        let tags = Set(item.tags)
        if hideAnime && tags.contains("Anime") { return false }
        // 题材之间任选其一（壁纸通常只有一个题材）；特性需全部满足
        let selectedGenres = genres.subtracting(["Anime"])
        if !selectedGenres.isEmpty && selectedGenres.isDisjoint(with: tags) { return false }
        if !features.isSubset(of: tags) { return false }

        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return true }
        return item.title.localizedCaseInsensitiveContains(keyword)
            || item.tags.contains { $0.localizedCaseInsensitiveContains(keyword) || WorkshopTags.label(for: $0).contains(keyword) }
    }
}

/// 本地库：扫描若干根目录下的条目文件夹
nonisolated enum WorkshopLibrary {
    /// steamcmd / Steam 客户端在 macOS 上的默认工坊下载目录
    static var steamContentFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam/steamapps/workshop/content/\(WorkshopConstants.appID)", isDirectory: true)
    }

    static func scan(roots: [URL]) -> [WorkshopItem] {
        let fm = FileManager.default
        var seen = Set<String>()
        var items: [WorkshopItem] = []

        for root in roots {
            // 根目录本身就是一个条目（导入单个壁纸文件夹时）
            if let item = WorkshopItem.load(from: root) {
                if seen.insert(item.id).inserted { items.append(item) }
                continue
            }
            guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) else { continue }
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      let item = WorkshopItem.load(from: child),
                      seen.insert(item.id).inserted else { continue }
                items.append(item)
            }
        }
        return items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
