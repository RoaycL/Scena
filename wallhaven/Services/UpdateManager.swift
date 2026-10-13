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
    @Published private(set) var isPreparingUpdate = false
    @Published private(set) var isInstalling = false
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published private(set) var downloadSize: Int64?

    var downloadFraction: Double? {
        guard let downloadSize, downloadSize > 0 else { return nil }
        return min(1, max(0, Double(downloadedBytes) / Double(downloadSize)))
    }
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
    private var isRestartRequested = false
    private var isRelaunching = false
    private var downloadTask: Task<Void, Never>?
    private var downloadGeneration = UUID()
    private var updateAlert: NSAlert?
    private var expectedDownloadSize: Int64?

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

        var request = URLRequest(url: Self.latestReleaseURL)
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
            let asset = release.assets.first { $0.name.hasSuffix(".zip") }
            downloadURL = asset.flatMap { URL(string: $0.browserDownloadURL) }
            expectedDownloadSize = asset?.size

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
        present(alert) { [weak self] in self?.installUpdate() }
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
        guard let downloadURL, !isDownloading, !isInstalling else { return }
        isDownloading = true
        isPreparingUpdate = false
        downloadedBytes = 0
        downloadSize = expectedDownloadSize
        errorMessage = nil
        statusMessage = "正在下载 Scena \(latestVersion)…"
        let generation = UUID()
        downloadGeneration = generation

        downloadTask = Task { [self] in
            defer {
                isDownloading = false
                isPreparingUpdate = false
                downloadTask = nil
            }
            do {
                let progress = UpdateDownloadProgress { [self] bytes, expected in
                    Task { @MainActor [self] in
                        guard self.downloadGeneration == generation,
                              self.isDownloading, !self.isPreparingUpdate else { return }
                        self.downloadedBytes = max(self.downloadedBytes, bytes)
                        if expected > 0 { self.downloadSize = expected }
                    }
                }
                let (tempURL, response) = try await progress.download(from: downloadURL)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw UpdateError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                try Task.checkCancellation()
                downloadedBytes = (try tempURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? downloadedBytes
                downloadSize = downloadedBytes
                isPreparingUpdate = true
                statusMessage = "下载完成，正在解压并准备更新…"
                let extracted = try await Task.detached(priority: .utility) { try Self.extractApp(from: tempURL) }.value
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: extracted.deletingLastPathComponent())
                    throw CancellationError()
                }
                stagedApp = extracted
                isReadyToInstall = true
                // 提示出现前结束下载状态，避免界面一直显示“下载中”。
                isDownloading = false
                isPreparingUpdate = false
                statusMessage = "Scena \(latestVersion) 已下载，重启即可完成更新"
                promptToRestart()
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    statusMessage = "下载已取消，可以重新下载"
                } else {
                    statusMessage = nil
                    errorMessage = "下载更新失败：\(error.localizedDescription)"
                    ToastCenter.shared.show(errorMessage ?? "下载更新失败", style: .error)
                }
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    private func promptToRestart() {
        let alert = NSAlert()
        alert.messageText = "Scena \(latestVersion) 已准备就绪"
        alert.informativeText = "重启 Scena 即可完成更新。选择「稍后」会在下次退出时自动安装。"
        alert.addButton(withTitle: "立即重启")
        alert.addButton(withTitle: "稍后")
        present(alert) { [weak self] in self?.restartToUpdate() }
    }

    /// 使用异步 sheet，避免 runModal 阻塞下载任务和退出回调。
    /// 只挂在可见的窗口上：主窗口关闭后 SwiftUI 仍保留着窗口对象，挂在它上面的提示看不见，
    /// 之后的提示也会被这个「看不见的提示」挡住。没有可见窗口时等用户切回 Scena 再提示
    private func present(_ alert: NSAlert, onConfirm: @escaping @MainActor () -> Void) {
        guard updateAlert == nil else { return }
        let window = [NSApp.keyWindow, MainWindow.existingWindow, NSApp.mainWindow]
            .compactMap { $0 }
            .first { $0.isVisible && !$0.isMiniaturized && $0.attachedSheet == nil && $0.canBecomeKey }
        guard let window else {
            pendingPrompt = (alert, onConfirm)
            if NSApp.isActive, !hasOpenedWindowForPrompt {
                hasOpenedWindowForPrompt = true
                // 用户正在用 Scena（比如从菜单栏检查更新）但没有窗口：打开主窗口再提示
                MainWindow.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    MainActor.assumeIsolated { self?.presentPendingPrompt() }
                }
            } else {
                observeActivationForPendingPrompt()
            }
            return
        }
        hasOpenedWindowForPrompt = false
        updateAlert = alert
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        alert.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor in
                self?.updateAlert = nil
                if response == .alertFirstButtonReturn { onConfirm() }
            }
        }
    }

    private var pendingPrompt: (alert: NSAlert, onConfirm: @MainActor () -> Void)?
    /// 为显示提示打开过一次主窗口；仍然没有可见窗口时改为等待用户切回，避免反复尝试
    private var hasOpenedWindowForPrompt = false
    private var activationObserver: NSObjectProtocol?

    private func observeActivationForPendingPrompt() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // 点 Dock 图标会重新打开主窗口，稍等窗口出现再提示
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated { self?.presentPendingPrompt() }
            }
        }
    }

    private func presentPendingPrompt() {
        guard let pending = pendingPrompt else { return }
        pendingPrompt = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        // 期间可能已经通过设置或菜单栏完成了重启 / 安装
        guard isReadyToInstall || updateAvailable else { return }
        present(pending.alert, onConfirm: pending.onConfirm)
    }

    /// 解压安装包，返回其中的 .app
    nonisolated private static func extractApp(from zipURL: URL) throws -> URL {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("ScenaUpdate-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var succeeded = false
        defer { if !succeeded { try? fm.removeItem(at: folder) } }

        // ditto 能正确保留 .app 内的符号链接和权限
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipURL.path, folder.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw UpdateError.extract }

        let contents = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else { throw UpdateError.noApp }
        succeeded = true
        return app
    }

    // MARK: - Installing

    /// 复制和原子替换在后台完成，完成后才退出并重启。
    func restartToUpdate() {
        guard isReadyToInstall, !isInstalling, !isRestartRequested else { return }
        isRestartRequested = true
        Task {
            do {
                try await replaceCurrentApp()
                let pid = ProcessInfo.processInfo.processIdentifier
                let relauncher = Process()
                relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
                relauncher.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
                try relauncher.run()
                isRelaunching = true
                // terminate 会进入嵌套事件循环。先结束当前 Swift 任务，
                // 否则同一 MainActor 上的退出准备任务无法执行，永远等不到 reply。
                RunLoop.main.perform {
                    MainActor.assumeIsolated { NSApp.terminate(nil) }
                }
            } catch {
                isRestartRequested = false
                reportInstallFailure(error)
            }
        }
    }

    /// 正常退出需要等后台安装完成；安装失败时保留旧应用并取消退出。
    func installPendingUpdateBeforeQuit() async throws {
        guard !isRelaunching, isReadyToInstall else { return }
        do {
            try await replaceCurrentApp()
        } catch {
            reportInstallFailure(error)
            throw error
        }
    }

    private func reportInstallFailure(_ error: Error) {
        errorMessage = "安装更新失败：\(error.localizedDescription)"
        ToastCenter.shared.show(errorMessage ?? "安装更新失败", style: .error)
    }

    private func replaceCurrentApp() async throws {
        guard let stagedApp else { throw UpdateError.noApp }
        guard !isInstalling else { throw UpdateError.installing }
        isInstalling = true
        statusMessage = "正在安装更新，请稍候…"
        defer { isInstalling = false }
        let current = URL(fileURLWithPath: Bundle.main.bundlePath)
        let bundleID = Bundle.main.bundleIdentifier ?? "com.roayc.wallhaven"
        try await Task.detached(priority: .utility) {
            try AppReplacement.replace(staged: stagedApp, current: current, bundleID: bundleID)
            try? FileManager.default.removeItem(at: stagedApp.deletingLastPathComponent())
        }.value
        self.stagedApp = nil
        isReadyToInstall = false
        statusMessage = "更新已安装，正在重启…"
    }

    /// 最新发布信息。开发版可以用环境变量 SCENA_UPDATE_FEED 指向本地文件服务器，测试完整的更新流程
    private static var latestReleaseURL: URL {
        #if DEBUG
        if let feed = ProcessInfo.processInfo.environment["SCENA_UPDATE_FEED"], let url = URL(string: feed) { return url }
        #endif
        return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    nonisolated static func isNewer(_ latest: String, than current: String) -> Bool {
        latest.compare(current, options: .numeric) == .orderedDescending
    }
}

enum UpdateError: LocalizedError {
    case http(Int)
    case extract
    case noApp
    case installing

    var errorDescription: String? {
        switch self {
        case .http(let code): "GitHub 请求失败（\(code)）"
        case .extract: "解压安装包失败"
        case .noApp: "安装包中没有找到 Scena.app"
        case .installing: "更新正在安装，请等待完成"
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
    let size: Int64?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }
}
