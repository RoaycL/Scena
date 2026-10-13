//
//  UpdateManager.swift
//  wallhaven
//
//  通过 GitHub Releases 检查更新（https://github.com/RoaycL/Scena/releases）。
//  发布要求：tag 形如 v1.0.3，附带一个包含 Scena.app 的 .zip（scripts/release.sh 会生成）。
//

import AppKit
import Combine
import Foundation

@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    static let repository = "RoaycL/Scena"
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!

    @Published private(set) var isChecking = false
    @Published private(set) var updateAvailable = false
    @Published private(set) var latestVersion = ""
    @Published private(set) var releaseNotes = ""
    @Published private(set) var releaseURL: URL?
    @Published private(set) var isDownloading = false
    /// 新版本已下载并解压，重启（或退出）即可完成安装
    @Published private(set) var isReadyToInstall = false
    @Published private(set) var errorMessage: String?
    /// 检查结果说明（已是最新、尚无发布版本等），只在设置页显示
    @Published private(set) var statusMessage: String?
    @Published var checksAutomatically: Bool {
        didSet { UserDefaults.standard.set(checksAutomatically, forKey: Keys.automatic) }
    }
    @Published var downloadsAutomatically: Bool {
        didSet { UserDefaults.standard.set(downloadsAutomatically, forKey: Keys.downloadsAutomatically) }
    }

    private var downloadURL: URL?
    /// 已解压、等待安装的新版本
    private var stagedApp: URL?
    private var isRelaunching = false

    private enum Keys {
        static let automatic = "update.checksAutomatically"
        static let downloadsAutomatically = "update.downloadsAutomatically"
        static let lastCheck = "update.lastCheck"
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// 从 Xcode 构建目录运行时不覆盖安装，避免替换开发产物
    var isDevelopmentBuild: Bool {
        Bundle.main.bundlePath.contains("/DerivedData/") || Bundle.main.bundlePath.contains("/Build/Products/")
    }

    /// 能否在 App 内直接下载安装（有 zip 安装包，且不是开发构建）
    private var canInstallInApp: Bool {
        downloadURL != nil && !isDevelopmentBuild
    }

    private init() {
        let defaults = UserDefaults.standard
        checksAutomatically = defaults.object(forKey: Keys.automatic) as? Bool ?? true
        downloadsAutomatically = defaults.object(forKey: Keys.downloadsAutomatically) as? Bool ?? true
    }

    // MARK: - Checking

    /// 启动后自动检查：每天最多一次，没有新版本时不打扰
    func checkAutomaticallyIfNeeded() async {
        guard checksAutomatically else { return }
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: Keys.lastCheck) as? Date, Date().timeIntervalSince(last) < 24 * 3600 { return }
        await check(userInitiated: false)
    }

    /// 手动检查（菜单栏、设置页）：没有新版本只在设置页和轻提示里说明，不弹窗
    func checkForUpdates() async {
        await check(userInitiated: true)
    }

    private func check(userInitiated: Bool) async {
        guard !isChecking, !isDownloading, !isReadyToInstall else {
            if isReadyToInstall { promptToRestart() }
            return
        }
        isChecking = true
        errorMessage = nil
        statusMessage = nil
        defer { isChecking = false }

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            UserDefaults.standard.set(Date(), forKey: Keys.lastCheck)

            if status == 404 {
                // 仓库还没有发布任何 Release
                statusMessage = "已是最新版本（\(currentVersion)）"
                if userInitiated { ToastCenter.shared.show("已是最新版本", style: .success) }
                return
            }
            guard status == 200 else { throw UpdateError.http(status) }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            latestVersion = version
            releaseNotes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            releaseURL = URL(string: release.htmlURL)
            downloadURL = release.assets
                .first { $0.name.hasSuffix(".zip") }
                .flatMap { URL(string: $0.browserDownloadURL) }

            updateAvailable = Self.isNewer(version, than: currentVersion)
            guard updateAvailable else {
                statusMessage = "已是最新版本（\(currentVersion)）"
                if userInitiated { ToastCenter.shared.show("已是最新版本", style: .success) }
                return
            }

            if downloadsAutomatically && canInstallInApp {
                // 后台下载，下载完成后再询问是否重启
                downloadUpdate()
            } else {
                promptForUpdate()
            }
        } catch {
            errorMessage = "检查更新失败：\(error.localizedDescription)"
            if userInitiated { ToastCenter.shared.show(errorMessage ?? "检查更新失败", style: .error) }
        }
    }

    // MARK: - Downloading

    /// 没有开启自动下载（或无法在 App 内安装）时的提示
    private func promptForUpdate() {
        let alert = NSAlert()
        alert.messageText = "Scena \(latestVersion) 可以更新了"
        let notes = releaseNotes.isEmpty ? "" : "\n\n" + String(releaseNotes.prefix(800))
        alert.informativeText = "当前版本 \(currentVersion)。\(notes)"
        alert.addButton(withTitle: canInstallInApp ? "下载并安装" : "打开发布页面")
        alert.addButton(withTitle: "稍后")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            installUpdate()
        }
    }

    /// 设置页 / 菜单里的「更新」按钮：已下载则重启，否则开始下载
    func installUpdate() {
        if isReadyToInstall {
            restartToUpdate()
        } else if canInstallInApp {
            downloadUpdate()
        } else {
            NSWorkspace.shared.open(releaseURL ?? Self.releasesPage)
        }
    }

    private func downloadUpdate() {
        guard let downloadURL, !isDownloading else { return }
        isDownloading = true
        errorMessage = nil
        statusMessage = "正在下载 Scena \(latestVersion)…"

        Task {
            defer { isDownloading = false }
            do {
                let (tempURL, response) = try await URLSession.shared.download(from: downloadURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw UpdateError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                stagedApp = try await Task.detached { try Self.extractApp(from: tempURL) }.value
                isReadyToInstall = true
                statusMessage = "Scena \(latestVersion) 已下载，重启即可完成更新"
                promptToRestart()
            } catch {
                statusMessage = nil
                errorMessage = "下载更新失败：\(error.localizedDescription)"
            }
        }
    }

    private func promptToRestart() {
        let alert = NSAlert()
        alert.messageText = "Scena \(latestVersion) 已准备就绪"
        alert.informativeText = "重启 Scena 即可完成更新。选择「稍后」会在下次退出时自动安装。"
        alert.addButton(withTitle: "立即重启")
        alert.addButton(withTitle: "稍后")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            restartToUpdate()
        }
    }

    /// 解压安装包，返回其中的 .app
    nonisolated private static func extractApp(from zipURL: URL) throws -> URL {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("ScenaUpdate-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        // ditto 能正确保留 .app 内的符号链接和权限
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipURL.path, folder.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw UpdateError.extract }

        let contents = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else { throw UpdateError.noApp }
        return app
    }

    // MARK: - Installing

    /// 替换 App 后重启：等当前进程完全退出再打开新版本，避免同时运行两个实例
    func restartToUpdate() {
        do {
            try replaceCurrentApp()
            let pid = ProcessInfo.processInfo.processIdentifier
            let relauncher = Process()
            relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
            relauncher.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
            try relauncher.run()
            isRelaunching = true
            NSApp.terminate(nil)
        } catch {
            errorMessage = "安装更新失败：\(error.localizedDescription)"
            ToastCenter.shared.show(errorMessage ?? "安装更新失败", style: .error)
        }
    }

    /// 退出时安装已下载的更新（选择了「稍后」）
    func installPendingUpdateOnQuit() {
        guard !isRelaunching, isReadyToInstall else { return }
        try? replaceCurrentApp()
    }

    private func replaceCurrentApp() throws {
        guard let stagedApp else { throw UpdateError.noApp }
        let fm = FileManager.default
        let current = URL(fileURLWithPath: Bundle.main.bundlePath)
        try AppReplacement.replace(staged: stagedApp, current: current,
                                   bundleID: Bundle.main.bundleIdentifier ?? "com.roayc.wallhaven")
        try? fm.removeItem(at: stagedApp.deletingLastPathComponent())
        self.stagedApp = nil
        isReadyToInstall = false
    }

    nonisolated static func isNewer(_ latest: String, than current: String) -> Bool {
        latest.compare(current, options: .numeric) == .orderedDescending
    }
}

enum UpdateError: LocalizedError {
    case http(Int)
    case extract
    case noApp

    var errorDescription: String? {
        switch self {
        case .http(let code): "GitHub 请求失败（\(code)）"
        case .extract: "解压安装包失败"
        case .noApp: "安装包中没有找到 Scena.app"
        }
    }
}

nonisolated struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let body: String?
    let htmlURL: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case htmlURL = "html_url"
        case assets
    }
}

nonisolated struct GitHubAsset: Decodable, Sendable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}
