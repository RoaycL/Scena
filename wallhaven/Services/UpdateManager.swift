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
    @Published private(set) var errorMessage: String?
    /// 手动检查的结果说明（已是最新、尚无发布版本等）
    @Published private(set) var statusMessage: String?
    @Published var checksAutomatically: Bool {
        didSet { UserDefaults.standard.set(checksAutomatically, forKey: Keys.automatic) }
    }

    private var downloadURL: URL?

    private enum Keys {
        static let automatic = "update.checksAutomatically"
        static let lastCheck = "update.lastCheck"
        static let skippedVersion = "update.skippedVersion"
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// 从 Xcode 构建目录运行时不覆盖安装，避免替换开发产物
    private var isDevelopmentBuild: Bool {
        Bundle.main.bundlePath.contains("/DerivedData/") || Bundle.main.bundlePath.contains("/Build/Products/")
    }

    private init() {
        checksAutomatically = UserDefaults.standard.object(forKey: Keys.automatic) as? Bool ?? true
    }

    // MARK: - Checking

    /// 启动后自动检查：每天最多一次，发现新版本时弹窗提示（跳过的版本不再提示）
    func checkAutomaticallyIfNeeded() async {
        guard checksAutomatically else { return }
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: Keys.lastCheck) as? Date, Date().timeIntervalSince(last) < 24 * 3600 { return }
        await check(userInitiated: false)
    }

    /// 手动检查（菜单栏、设置页）：总会给出结果
    func checkForUpdates() async {
        await check(userInitiated: true)
    }

    private func check(userInitiated: Bool) async {
        guard !isChecking else { return }
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
                statusMessage = "还没有发布的版本"
                if userInitiated { showInfo("还没有发布的版本", detail: "GitHub 上暂时没有 Scena 的发布版本。") }
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
                if userInitiated { showInfo("已是最新版本", detail: "当前版本 \(currentVersion) 是最新的。") }
                return
            }

            let skipped = UserDefaults.standard.string(forKey: Keys.skippedVersion)
            if userInitiated || skipped != version {
                promptForUpdate()
            }
        } catch {
            let message = error.localizedDescription
            errorMessage = "检查更新失败：\(message)"
            if userInitiated { showInfo("检查更新失败", detail: message) }
        }
    }

    // MARK: - Installing

    private func promptForUpdate() {
        let alert = NSAlert()
        alert.messageText = "Scena \(latestVersion) 可以更新了"
        let notes = releaseNotes.isEmpty ? "" : "\n\n" + String(releaseNotes.prefix(800))
        alert.informativeText = "当前版本 \(currentVersion)。\(notes)"
        alert.addButton(withTitle: "立即更新")
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "跳过此版本")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            downloadAndInstall()
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(latestVersion, forKey: Keys.skippedVersion)
        default:
            break
        }
    }

    func downloadAndInstall() {
        // 没有 zip 安装包，或者在开发环境运行：打开发布页面手动下载
        guard let downloadURL, !isDevelopmentBuild else {
            NSWorkspace.shared.open(releaseURL ?? Self.releasesPage)
            return
        }
        isDownloading = true
        errorMessage = nil
        ToastCenter.shared.show("正在下载 Scena \(latestVersion)…", style: .progress)

        Task {
            defer { isDownloading = false }
            do {
                let (tempURL, response) = try await URLSession.shared.download(from: downloadURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw UpdateError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                let newApp = try await Task.detached { try Self.extractApp(from: tempURL) }.value
                try installAndRelaunch(newApp)
            } catch {
                errorMessage = "更新失败：\(error.localizedDescription)"
                ToastCenter.shared.show("更新失败：\(error.localizedDescription)", style: .error)
            }
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

    /// 替换当前 App，旧版本退出后再启动新版本
    private func installAndRelaunch(_ newApp: URL) throws {
        let fm = FileManager.default
        let current = URL(fileURLWithPath: Bundle.main.bundlePath)
        let backup = current.deletingLastPathComponent().appendingPathComponent(".\(current.lastPathComponent).old")

        try? fm.removeItem(at: backup)
        try fm.moveItem(at: current, to: backup)
        do {
            try fm.copyItem(at: newApp, to: current)
        } catch {
            try? fm.moveItem(at: backup, to: current)
            throw error
        }
        try? fm.removeItem(at: backup)

        // 等当前进程完全退出后再打开新版本，避免同时运行两个实例
        let pid = ProcessInfo.processInfo.processIdentifier
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", current.path]
        try relauncher.run()
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func showInfo(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        if title == "还没有发布的版本" || errorMessage != nil {
            alert.addButton(withTitle: "打开发布页面")
        }
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(Self.releasesPage)
        }
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
