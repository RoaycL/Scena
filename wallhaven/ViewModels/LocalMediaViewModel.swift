//
//  LocalMediaViewModel.swift
//  wallhaven
//
//  Created by RoaycL on 2026/4/17.
//

import AppKit
import Combine
import SwiftUI

struct LocalMediaItem: Identifiable, Sendable {
    let id: UUID
    let url: URL
    let creationDate: Date
}

@MainActor
final class LocalMediaViewModel: ObservableObject {
    @Published private(set) var items: [LocalMediaItem] = []
    @Published var errorMessage: String?

    private var directoryURL: URL? {
        let downloadPath = DownloadLocation.currentPath
        guard !downloadPath.isEmpty else { return nil }
        return URL(fileURLWithPath: downloadPath, isDirectory: true)
    }
    
    func loadMedia() {
        guard let directoryURL else { return }
        
        let fm = FileManager.default
        if !fm.fileExists(atPath: directoryURL.path) {
            items = []
            return
        }
        
        do {
            let urls = try fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)
            var loadedItems: [LocalMediaItem] = []
            for url in urls where ["jpg", "jpeg", "png"].contains(url.pathExtension.lowercased()) {
                let attrs = try url.resourceValues(forKeys: [.creationDateKey])
                let date = attrs.creationDate ?? Date.distantPast
                loadedItems.append(LocalMediaItem(id: UUID(), url: url, creationDate: date))
            }
            items = loadedItems.sorted { $0.creationDate > $1.creationDate }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    func delete(item: LocalMediaItem) {
        do {
            try FileManager.default.removeItem(at: item.url)
            items.removeAll { $0.id == item.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    func applyWallpaper(_ item: LocalMediaItem) {
        do {
            try WallpaperManager.applyWallpaper(from: item.url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
