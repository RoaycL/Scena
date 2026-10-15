//
//  WallhavenDownloadTracker.swift
//  wallhaven
//

import Combine
import Foundation

/// 后台触发的 wallhaven 下载（如加入播放列表时自动下载）的进度：
/// 下载按钮据此显示转圈，完成后直接显示对勾（资料库扫描到新文件之前也不会闪回箭头）
final class WallhavenDownloadTracker: ObservableObject {
    static let shared = WallhavenDownloadTracker()

    @Published private(set) var downloading: Set<String> = []
    @Published private(set) var downloaded: Set<String> = []

    func begin(_ id: String) { downloading.insert(id) }

    func finish(_ id: String, success: Bool) {
        downloading.remove(id)
        if success { downloaded.insert(id) }
    }
}
