//
//  DownloadService.swift
//  wallhaven
//
//  Created by RoaycL on 2026/4/17.
//

import Foundation
import ImageIO

nonisolated enum DownloadLocation {
    static let storageKey = "downloadPath"

    static let defaultPath: String = {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first?.appendingPathComponent("Wallhaven").path ?? ""
    }()

    /// 当前下载目录（读取 UserDefaults，每次调用都拿到最新设置）
    static var currentPath: String {
        let stored = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return stored.isEmpty ? defaultPath : stored
    }
}

struct DownloadService {
    private let session: URLSession
    private let folder: (RemoteWallpaper) -> URL
    private let checkStorage: () throws -> Void
    private let resolve: (RemoteWallpaper) async throws -> URL
    private let fm = FileManager.default

    init(session: URLSession = URLSession(configuration: .default),
         folder: @escaping (RemoteWallpaper) -> URL = { $0.downloadFolder },
         checkStorage: @escaping () throws -> Void = { try StorageManager.shared.ensureAvailable() },
         resolve: @escaping (RemoteWallpaper) async throws -> URL = { wallpaper in
             guard let source = WallpaperSources.source(id: wallpaper.sourceID) else {
                 throw WallperError.network("此图源已不可用。")
             }
             return try await source.downloadURL(for: wallpaper)
         }) {
        self.session = session; self.folder = folder; self.checkStorage = checkStorage; self.resolve = resolve
    }

    func download(_ wallpaper: RemoteWallpaper) async throws -> URL {
        try checkStorage()
        let destinationFolder = folder(wallpaper)
        if let existing = wallpaper.localFileURL(in: destinationFolder) { return existing }
        let resource = try await resolve(wallpaper)
        try Task.checkCancellation()
        // 解析可能涉及联网，期间外接盘可能已被拔出。
        try checkStorage()
        if !fm.fileExists(atPath: destinationFolder.path) {
            try fm.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        }

        let destination = destinationFolder.appendingPathComponent(wallpaper.downloadFileName(for: resource))
        if fm.fileExists(atPath: destination.path) {
            return destination
        }

        var request = URLRequest(url: resource)
        request.setValue(SourceHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        for (field, value) in WallpaperSources.requestHeaders(for: resource) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (tempURL, response) = try await session.download(for: request)
        defer { try? fm.removeItem(at: tempURL) }
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw WallperError.network("下载失败。")
        }
        try Self.validate(file: tempURL, response: httpResponse, isVideo: wallpaper.isVideo)
        try Task.checkCancellation()
        try checkStorage()
        // 同一条目可能同时从设为壁纸和播放列表触发下载。
        if fm.fileExists(atPath: destination.path) { return destination }

        // 优先移动临时文件（不占内存）；跨卷失败时退回到流式复制
        do {
            try fm.moveItem(at: tempURL, to: destination)
        } catch {
            try fm.copyItem(at: tempURL, to: destination)
        }

        return destination
    }

    static func validate(file: URL, response: HTTPURLResponse, isVideo: Bool) throws {
        let mime = response.mimeType?.lowercased() ?? ""
        guard !mime.hasPrefix("text/"), !mime.contains("json"),
              response.value(forHTTPHeaderField: "cf-mitigated") != "challenge" else {
            throw WallperError.network("图源返回了网页或验证页面，未保存下载文件。请在官网查看后重试。")
        }
        if isVideo {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: 12) ?? Data()
            // 当前在线视频图源下载 MP4，兼容 ISO BMFF 的 ftyp/moov/mdat 容器。
            let box = bytes.count >= 8 ? String(decoding: bytes[4..<8], as: UTF8.self) : ""
            guard ["ftyp", "moov", "mdat", "wide", "free"].contains(box) else {
                throw WallperError.network("下载内容不是有效的视频文件，未保存。")
            }
        } else {
            guard let image = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(image) > 0 else {
                throw WallperError.network("下载内容不是有效的图片文件，未保存。")
            }
        }
    }
}
