//
//  DownloadService.swift
//  wallhaven
//
//  Created by RoaycL on 2026/4/17.
//

import Foundation

enum DownloadLocation {
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
    private let session = URLSession(configuration: .default)
    private let fm = FileManager.default

    func download(_ wallpaper: RemoteWallpaper) async throws -> URL {
        try StorageManager.shared.ensureAvailable()
        let destinationFolder = URL(fileURLWithPath: DownloadLocation.currentPath, isDirectory: true)
        if !fm.fileExists(atPath: destinationFolder.path) {
            try fm.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        }

        let destination = destinationFolder.appendingPathComponent(wallpaper.downloadFileName)
        if fm.fileExists(atPath: destination.path) {
            return destination
        }

        let (tempURL, response) = try await session.download(from: wallpaper.imageURL)
        defer { try? fm.removeItem(at: tempURL) }
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw WallperError.network("下载失败。")
        }

        // 优先移动临时文件（不占内存）；跨卷失败时退回到流式复制
        do {
            try fm.moveItem(at: tempURL, to: destination)
        } catch {
            try fm.copyItem(at: tempURL, to: destination)
        }

        return destination
    }
}
