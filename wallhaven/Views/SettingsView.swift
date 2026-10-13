//
//  SettingsView.swift
//  wallhaven
//
//  原生 macOS 偏好设置：顶部图标标签 + 分组表单。
//  通用 / 账户（Wallhaven 与 Steam 集中管理）/ 动态壁纸 / 创意工坊 / 存储 / 关于
//

import AppKit
import SwiftUI

struct SettingsView: View {
    private enum Tab: Hashable {
        case general, accounts, live, workshop, storage, about
    }

    @State private var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(Tab.general)
            AccountSettings()
                .tabItem { Label("账户", systemImage: "person.crop.circle") }
                .tag(Tab.accounts)
            LiveWallpaperSettings()
                .tabItem { Label("动态壁纸", systemImage: "play.rectangle") }
                .tag(Tab.live)
            WorkshopSettings()
                .tabItem { Label("创意工坊", systemImage: "square.stack.3d.up") }
                .tag(Tab.workshop)
            StorageSettings()
                .tabItem { Label("存储", systemImage: "externaldrive") }
                .tag(Tab.storage)
            AboutSettings()
                .tabItem { Label("关于", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .frame(width: 580, height: 560)
    }
}

// MARK: - Shared

/// 分组下方的说明文字
private struct SettingsFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 账号状态行：头像图标 + 名称 + 副标题
private struct AccountStatusRow<Trailing: View>: View {
    let isConnected: Bool
    let title: String
    let subtitle: String?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isConnected ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 18))
                .foregroundStyle(isConnected ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            trailing()
        }
    }
}

private func formatBytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}

// MARK: - 通用

private struct GeneralSettings: View {
    @AppStorage(AppSettings.showStatusItemKey) private var showStatusItem = true

    var body: some View {
        Form {
            Section {
                Toggle("在菜单栏显示图标", isOn: $showStatusItem)
            } header: {
                Text("菜单栏")
            } footer: {
                SettingsFootnote("通过菜单栏图标可以控制动态壁纸和播放列表、随机换一张壁纸。")
            }

            Section {
                LabeledContent("关闭主窗口") { Text("继续在后台运行，动态壁纸不中断").foregroundStyle(.secondary) }
                LabeledContent("退出 App") { Text("动态壁纸定格为当前画面").foregroundStyle(.secondary) }
            } header: {
                Text("窗口")
            }

            Section("快捷键") {
                shortcut("切换上一张 / 下一张", "← →")
                shortcut("设为壁纸", "↩")
                shortcut("隐藏 / 显示界面", "空格")
                shortcut("下载 / 收藏", "D / L")
                shortcut("全屏", "F")
                shortcut("搜索", "/  或  ⌘F")
                shortcut("切换页签", "1 – 4")
            }
        }
        .formStyle(.grouped)
    }

    private func shortcut(_ title: String, _ keys: String) -> some View {
        LabeledContent(title) {
            Text(keys)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 账户

private struct AccountSettings: View {
    @EnvironmentObject private var viewModel: WallpaperViewModel
    @EnvironmentObject private var workshop: WorkshopViewModel
    @ObservedObject private var steamAccount = SteamAccountSession.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            wallhavenSection
            if viewModel.isAuthenticated { wallhavenSyncSection }
            steamSection
            steamCMDSection
        }
        .formStyle(.grouped)
    }

    private var wallhavenSection: some View {
        Section {
            AccountStatusRow(
                isConnected: viewModel.isAuthenticated,
                title: viewModel.isAuthenticated ? "已登录" : "未登录",
                subtitle: viewModel.isAuthenticated && !viewModel.usernameInput.isEmpty ? viewModel.usernameInput : nil
            ) {
                if viewModel.isAuthenticated {
                    Button("退出登录") { viewModel.logout() }
                }
            }
            SecureField("API 密钥", text: $viewModel.apiKeyInput, prompt: Text("在 wallhaven.cc 账户设置中获取"))
            TextField("用户名", text: $viewModel.usernameInput, prompt: Text("同步收藏夹时需要"))
            HStack {
                Button("获取 API 密钥") { viewModel.openAPIKeyPage() }
                Spacer()
                Button(viewModel.isAuthenticated ? "更新" : "登录") { viewModel.login() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.apiKeyInput.isEmpty)
            }
        } header: {
            Label("Wallhaven", systemImage: "photo.on.rectangle")
        } footer: {
            SettingsFootnote("登录后可浏览 Sketchy / NSFW 内容；填写用户名后可把线上收藏夹同步到本地。")
        }
    }

    private var wallhavenSyncSection: some View {
        Section {
            HStack {
                Button("同步线上收藏到本地") {
                    Task { await viewModel.syncCollections() }
                }
                .disabled(viewModel.isSyncing)
                if viewModel.isSyncing {
                    ProgressView().controlSize(.small)
                    Text(viewModel.syncProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } footer: {
            SettingsFootnote("受 API 频率限制（每分钟 45 次），收藏较多时需要稍等。")
        }
    }

    private var steamSection: some View {
        Section {
            AccountStatusRow(
                isConnected: steamAccount.isLoggedIn,
                title: steamAccount.isLoggedIn ? (steamAccount.personaName ?? "已登录") : "未登录",
                subtitle: steamAccount.steamID
            ) {
                if steamAccount.isLoggedIn {
                    Button("退出登录") { workshop.logoutSteam() }
                } else {
                    Button("登录 Steam") { openWindow(id: SteamLoginWindow.id) }
                        .buttonStyle(.borderedProminent)
                }
            }
            if steamAccount.isLoggedIn {
                Toggle("在 Mac 上下载时同时订阅", isOn: $workshop.subscribeOnDownload)
                Toggle("自动下载其他设备上新订阅的壁纸", isOn: $workshop.autoDownloadSubscriptions)
                HStack {
                    Button("立即同步订阅") { workshop.syncSubscriptions(force: true) }
                        .disabled(workshop.isSyncing)
                    if workshop.isSyncing {
                        ProgressView().controlSize(.small)
                    } else if let last = workshop.lastSyncAt {
                        Text("上次同步 \(last.formatted(date: .omitted, time: .shortened)) · \(workshop.subscribedIDs.count) 个订阅")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Label("Steam 账号（创意工坊订阅）", systemImage: "arrow.triangle.2.circlepath")
        } footer: {
            SettingsFootnote("在 Steam 官方登录页登录，只使用登录后的会话读写订阅，不会读取或保存密码。同步在启动、打开工坊页或手动点击时进行，请求会限速。")
        }
    }

    private var steamCMDSection: some View {
        Section {
            LabeledContent("steamcmd") {
                if let path = workshop.steamCMDPath {
                    Label(path.path, systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Label("未安装", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            if workshop.steamCMDPath == nil {
                LabeledContent("安装命令") {
                    Text("brew install --cask steamcmd")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            TextField("Steam 用户名", text: $workshop.steamUsername, prompt: Text("登录 steamcmd 使用的账号名"))
            HStack {
                Spacer()
                Button("在终端登录 steamcmd") { workshop.loginSteamCMD() }
                    .disabled(workshop.steamCMDPath == nil || workshop.steamUsername.isEmpty)
            }
        } header: {
            Label("Steam 下载（steamcmd）", systemImage: "arrow.down.circle")
        } footer: {
            SettingsFootnote("账号需已购买 Wallpaper Engine。首次需在终端输入密码和 Steam 令牌，之后 steamcmd 会缓存登录状态，App 内即可下载。")
        }
    }
}

// MARK: - 动态壁纸

private struct LiveWallpaperSettings: View {
    @ObservedObject private var live = LiveWallpaperController.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("当前") {
                    if let content = live.current {
                        Text(content.title).lineLimit(1)
                    } else {
                        Text("未播放").foregroundStyle(.secondary)
                    }
                }
                if live.isActive {
                    HStack {
                        Spacer()
                        Button(live.isPaused ? "继续播放" : "暂停") { live.togglePause() }
                        Button("停止动态壁纸") { live.stop() }
                    }
                }
            } header: {
                Text("播放状态")
            }

            Section {
                LabeledContent("音量") {
                    HStack {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: Binding(get: { live.volume }, set: { live.setVolume($0) }), in: 0...1)
                            .frame(width: 200)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                }
                Picker("渲染帧率", selection: Binding(get: { live.frameRate }, set: { live.setFrameRate($0) })) {
                    Text("15 fps（省电）").tag(15)
                    Text("30 fps").tag(30)
                    Text("60 fps（流畅）").tag(60)
                }
            } header: {
                Text("播放")
            } footer: {
                SettingsFootnote("声音只在主显示器播放。帧率只影响场景和网页类工坊壁纸，视频按原始帧率播放。")
            }

            Section {
                LabeledContent("锁屏、睡眠、显示器关闭") { Text("自动暂停").foregroundStyle(.secondary) }
                LabeledContent("退出 App") { Text("定格为当前画面").foregroundStyle(.secondary) }
            } header: {
                Text("节能")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 创意工坊

private struct WorkshopSettings: View {
    @EnvironmentObject private var workshop: WorkshopViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                SecureField("Steam Web API Key", text: $workshop.apiKey, prompt: Text("可选"))
                HStack {
                    Button("申请 API Key") { workshop.openAPIKeyPage() }
                    Spacer()
                    if workshop.hasAPIKey {
                        Label("已配置", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            } header: {
                Text("在线浏览")
            } footer: {
                SettingsFootnote("不填也能浏览创意工坊；填写后改用 Steam 官方接口，速度更快、更稳定。")
            }

            Section {
                Stepper(value: $workshop.maxConcurrentDownloads, in: 1...10) {
                    LabeledContent("同时下载数量") {
                        Text("\(workshop.maxConcurrentDownloads) 个")
                            .monospacedDigit()
                    }
                }
                HStack {
                    Text("下载任务")
                    Spacer()
                    Text("\(workshop.downloading.count) 个进行中")
                        .foregroundStyle(.secondary)
                    Button("打开") { openWindow(id: DownloadsWindow.id) }
                }
            } header: {
                Text("下载")
            } footer: {
                SettingsFootnote("超出数量的壁纸会排队等待。同一个 Steam 账号同时只能运行一个 steamcmd，这里的数量是每次登录处理的壁纸数。")
            }

            Section {
                ForEach(workshop.libraryRoots, id: \.self) { url in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(url.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if url == StorageManager.shared.workshopContentFolder {
                            Text("存储位置").font(.caption).foregroundStyle(.secondary)
                        } else if url == WorkshopLibrary.steamContentFolder {
                            Text("Steam 默认").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button {
                                workshop.removeLibraryFolder(url)
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("从库中移除（不删除文件）")
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("添加文件夹…") { workshop.addLibraryFolder() }
                }
            } header: {
                Text("本地壁纸库")
            } footer: {
                SettingsFootnote("可以添加单个壁纸文件夹，或从 Windows 电脑拷贝的 steamapps/workshop/content/431960 目录。")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 存储

private struct StorageSettings: View {
    @ObservedObject private var storage = StorageManager.shared

    var body: some View {
        Form {
            Section {
                if let info = storage.volumeInfo() {
                    LabeledContent("磁盘") {
                        HStack(spacing: 6) {
                            Text(info.name)
                            if info.isExternal {
                                Text("外接盘")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                            }
                        }
                    }
                    LabeledContent("可用空间") {
                        VStack(alignment: .trailing, spacing: 4) {
                            ProgressView(value: Double(info.total - info.available), total: Double(max(info.total, 1)))
                                .frame(width: 180)
                            Text("\(formatBytes(info.available)) 可用，共 \(formatBytes(info.total))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    LabeledContent("磁盘") {
                        Label("存储盘未连接", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                LabeledContent("位置") {
                    Text(storage.rootPath ?? "默认位置（本机）")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if storage.isMigrating {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: Double(storage.migrationProgress.done), total: Double(max(storage.migrationProgress.total, 1)))
                        Text("正在移动 \(storage.migrationProgress.done)/\(storage.migrationProgress.total)，完成前请不要拔出存储盘")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([storage.rootURL ?? storage.wallpaperFolder])
                    }
                    Spacer()
                    if storage.rootPath != nil {
                        Button("恢复默认位置") { confirmMove(to: nil) }
                    }
                    Button("更改位置…") { selectStorageLocation() }
                        .buttonStyle(.borderedProminent)
                }
                .disabled(storage.isMigrating)
            } header: {
                Text("存储位置")
            } footer: {
                SettingsFootnote("下载的 wallhaven 壁纸、导入的图片和视频、创意工坊壁纸都保存在这里，可以设到外接盘。更改位置时会移动已下载的内容，并更新播放列表和动态壁纸的引用。")
            }

            Section {
                usageRow("壁纸图片和视频", storage.usage.wallpapers, .blue)
                usageRow("创意工坊壁纸", storage.usage.workshop, .purple)
                usageRow("图片缓存", storage.usage.cache, .gray)
                HStack {
                    Spacer()
                    Button("清除图片缓存") { storage.clearImageCache() }
                }
            } header: {
                Text("空间占用")
            } footer: {
                SettingsFootnote("图片缓存上限 1 GB，保留 14 天，清除后缩略图会重新下载。")
            }
        }
        .formStyle(.grouped)
        .onAppear { storage.refreshUsage() }
    }

    private func usageRow(_ title: String, _ value: Int64, _ color: Color) -> some View {
        LabeledContent {
            Text(formatBytes(value)).monospacedDigit().foregroundStyle(.secondary)
        } label: {
            Label {
                Text(title)
            } icon: {
                Circle().fill(color).frame(width: 8, height: 8)
            }
        }
    }

    private func selectStorageLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择存储位置（可以是外接盘），将在其中创建 wallhaven 文件夹"
        panel.prompt = "选择"
        if let volumes = URL(string: "file:///Volumes/") { panel.directoryURL = volumes }
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        // 选中盘符或普通文件夹时，在里面建一个 wallhaven 子文件夹，避免把文件散落在根目录
        let root = chosen.lastPathComponent.lowercased() == "wallhaven" ? chosen : chosen.appendingPathComponent("wallhaven", isDirectory: true)
        confirmMove(to: root)
    }

    private func confirmMove(to root: URL?) {
        let alert = NSAlert()
        alert.messageText = root.map { "将存储位置改到「\(StorageManager.volumeName(of: $0))」？" } ?? "恢复默认存储位置？"
        alert.informativeText = """
        新位置：\(root?.path ?? "~/Pictures/Wallhaven 和 Steam 默认工坊目录")
        已下载的内容（约 \(formatBytes(storage.usage.wallpapers + storage.usage.workshop))）会移动到新位置，跨盘移动可能需要一些时间。
        """
        alert.addButton(withTitle: "移动")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        storage.changeLocation(to: root)
    }
}

// MARK: - 关于

private struct AboutSettings: View {
    @StateObject private var updateManager = UpdateManager()

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Scena").font(.title2.bold())
                        Text("图片、视频与创意工坊壁纸").foregroundStyle(.secondary)
                        Text("版本 \(version)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("更新") {
                HStack {
                    if updateManager.updateAvailable {
                        Label("发现新版本 v\(updateManager.latestVersion)", systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(.green)
                    } else if let error = updateManager.errorMessage {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text("检查是否有新版本").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if updateManager.isChecking || updateManager.isDownloading {
                        ProgressView().controlSize(.small)
                    }
                    if updateManager.updateAvailable {
                        Button("立即更新并重启") { updateManager.downloadAndInstall() }
                            .buttonStyle(.borderedProminent)
                            .disabled(updateManager.isDownloading)
                    } else {
                        Button("检查更新") { Task { await updateManager.checkForUpdates() } }
                            .disabled(updateManager.isChecking)
                    }
                }
                if updateManager.updateAvailable, !updateManager.releaseNotes.isEmpty {
                    Text(updateManager.releaseNotes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
            }

            Section("链接") {
                Link(destination: URL(string: "https://wallhaven.cc")!) {
                    LabeledContent("Wallhaven 官网") { Image(systemName: "arrow.up.right") }
                }
                Link(destination: URL(string: "https://steamcommunity.com/app/431960/workshop/")!) {
                    LabeledContent("Wallpaper Engine 创意工坊") { Image(systemName: "arrow.up.right") }
                }
            }

            Section {
                LabeledContent("webwallgl") { Text("MIT · 工坊壁纸渲染").foregroundStyle(.secondary) }
                LabeledContent("Kingfisher") { Text("MIT · 图片加载与缓存").foregroundStyle(.secondary) }
            } header: {
                Text("开源组件")
            } footer: {
                SettingsFootnote("创意工坊内容版权归各自作者所有，仅供个人使用。")
            }
        }
        .formStyle(.grouped)
    }
}
