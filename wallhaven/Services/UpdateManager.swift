//
//  UpdateManager.swift
//  wallhaven
//
//  Created by RoaycL on 2026/4/17.
//

import AppKit
import Combine
import Foundation

@MainActor
class UpdateManager: ObservableObject {
    @Published var isChecking = false
    @Published var updateAvailable = false
    @Published var latestVersion = ""
    @Published var releaseNotes = ""
    @Published var downloadURL: URL?
    
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var errorMessage: String?

    // 请将此处替换为你的实际 GitHub 仓库，例如："用户名/仓库名"
    private let githubRepo = "RoaycL/wallhaven"
    
    func checkForUpdates() async {
        isChecking = true
        errorMessage = nil
        defer { isChecking = false }
        
        let urlString = "https://api.github.com/repos/\(githubRepo)/releases/latest"
        guard let url = URL(string: urlString) else { return }
        
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return
            }
            
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let latestVer = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            
            let currentVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            
            if isNewerVersion(latestVer, currentVersion: currentVer) {
                self.latestVersion = latestVer
                self.releaseNotes = release.body ?? ""
                // 查找 zip 或 dmg 下载链接
                if let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }) {
                    self.downloadURL = URL(string: asset.browser_download_url)
                }
                self.updateAvailable = true
            }
        } catch {
            print("检查更新失败: \(error)")
            // self.errorMessage = "检查更新失败: \(error.localizedDescription)"
        }
    }
    
    func downloadAndInstall() {
        guard let downloadURL = downloadURL else { return }
        
        isDownloading = true
        errorMessage = nil
        downloadProgress = 0.0
        
        Task {
            do {
                let (tempURL, _) = try await URLSession.shared.download(from: downloadURL)
                self.isDownloading = false
                try self.installUpdate(from: tempURL)
            } catch {
                self.isDownloading = false
                self.errorMessage = "下载或安装过程出错: \(error.localizedDescription)"
            }
        }
    }
    
    private func installUpdate(from zipURL: URL) throws {
        let fileManager = FileManager.default
        
        // 1. 创建临时解压目录
        let tempExtractURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempExtractURL, withIntermediateDirectories: true)
        
        // 2. 解压
        let unzipProcess = Process()
        unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzipProcess.arguments = ["-q", zipURL.path, "-d", tempExtractURL.path]
        try unzipProcess.run()
        unzipProcess.waitUntilExit()
        
        if unzipProcess.terminationStatus != 0 {
            throw NSError(domain: "UpdateManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "解压缩失败"])
        }
        
        // 3. 找到解压出的 .app
        let contents = try fileManager.contentsOfDirectory(at: tempExtractURL, includingPropertiesForKeys: nil)
        guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
            throw NSError(domain: "UpdateManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "更新包中未找到应用程序"])
        }
        
        // 4. 获取当前 App 路径
        guard let currentAppPath = Bundle.main.bundlePath as String? else {
            throw NSError(domain: "UpdateManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "找不到当前应用安装路径"])
        }
        let currentAppURL = URL(fileURLWithPath: currentAppPath)
        
        // 5. 替换应用程序 (如果当前在 只读镜像 中，此步会失败)。
        let backupURL = currentAppURL.deletingPathExtension().appendingPathExtension("old.app")
        if fileManager.fileExists(atPath: backupURL.path) {
            try? fileManager.removeItem(at: backupURL)
        }
        
        // 将旧版移动到 backup 路径 (为了安全替换)
        do {
            try fileManager.moveItem(at: currentAppURL, to: backupURL)
            try fileManager.copyItem(at: appURL, to: currentAppURL)
            
            // 删除备份及临时文件
            try? fileManager.removeItem(at: backupURL)
            try? fileManager.removeItem(at: tempExtractURL)
            try? fileManager.removeItem(at: zipURL)
            
        } catch {
            // 回滚
            if fileManager.fileExists(atPath: backupURL.path) && !fileManager.fileExists(atPath: currentAppURL.path) {
                try? fileManager.moveItem(at: backupURL, to: currentAppURL)
            }
            throw error
        }
        
        // 6. 重启
        relaunchApp()
    }
    
    private func relaunchApp() {
        let bundlePath = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundlePath]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }
    
    private func isNewerVersion(_ latest: String, currentVersion: String) -> Bool {
        return latest.compare(currentVersion, options: .numeric) == .orderedDescending
    }
}

struct GitHubRelease: Decodable {
    let tag_name: String
    let body: String?
    let assets: [GitHubAsset]
}

struct GitHubAsset: Decodable {
    let name: String
    let browser_download_url: String
}
