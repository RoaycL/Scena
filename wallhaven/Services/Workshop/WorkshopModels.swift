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

enum WorkshopSort: String, CaseIterable, Identifiable, Sendable {
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

enum WorkshopTypeFilter: String, CaseIterable, Identifiable, Sendable {
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
