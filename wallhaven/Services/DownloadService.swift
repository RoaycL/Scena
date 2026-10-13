//
//  DownloadService.swift
//  wallhaven
//
//  Created by RoaycL on 2026/4/17.
//

import SwiftUI

struct DownloadService {
    @AppStorage("downloadPath") private var downloadPath: String = {
        return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first?.appendingPathComponent("Wallhaven").path ?? ""
    }()

    private let session = URLSession(configuration: .default)
    private let fm = FileManager.default

    func download(_ wallpaper: WallhavenWallpaper) async throws -> URL {
        let destinationFolder = URL(fileURLWithPath: downloadPath, isDirectory: true)
        if !fm.fileExists(atPath: destinationFolder.path) {
            try fm.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        }

        let ext = wallpaper.path.pathExtension.isEmpty ? "jpg" : wallpaper.path.pathExtension
        let destination = destinationFolder.appendingPathComponent("\(wallpaper.id).\(ext)")
        if fm.fileExists(atPath: destination.path) {
            return destination
        }

        let (tempURL, response) = try await session.download(from: wallpaper.path)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw WallperError.network("下载失败。")
        }
        
        // 使用 Data 写入可以避免跨卷/跨沙盒 `moveItem` 的权限问题
        let data = try Data(contentsOf: tempURL)
        try data.write(to: destination, options: .atomic)
        try? fm.removeItem(at: tempURL)
        
        return destination
    }
}
