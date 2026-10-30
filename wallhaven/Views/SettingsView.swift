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
        // 窗口是透明的：磨砂要一直铺到标题栏和工具栏下面，否则那一条会直接露出后面的内容
        // 设置页用更通透的磨砂，背后的桌面和窗口能隐约透出来
        .background { ScenaFrostedBackground().ignoresSafeArea() }
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
    FileSizeText.string(value)
}

// MARK: - 通用

private struct GeneralSettings: View {
    @AppStorage(AppSettings.showStatusItemKey) private var showStatusItem = true
    @AppStorage(DesktopSettings.showDockIcon) private var showDockIcon = true
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .system

    var body: some View {
        Form {
            Section {
                Picker("主题", selection: $theme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("外观")
            } footer: {
                SettingsFootnote("跟随系统会自动切换日间与夜间外观。应用图标始终跟随系统，不受这里的主题选择影响。")
            }

            Section {
                Toggle("开机时自动启动", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                Toggle("在 Dock 中显示图标", isOn: $showDockIcon)
                    // 菜单栏图标和 Dock 图标至少保留一个，否则找不到 App
                    .disabled(!showStatusItem && showDockIcon)
                    .onChange(of: showDockIcon) { DockIcon.apply() }
                Toggle("在菜单栏显示图标", isOn: $showStatusItem)
                    .disabled(!showDockIcon && showStatusItem)
            } header: {
                Text("启动与图标")
            } footer: {
                SettingsFootnote("开机启动后会恢复上次的动态壁纸和播放列表。菜单栏图标和 Dock 图标至少保留一个。")
            }

            GlobalHotKeySection()

            Section {
                LabeledContent("关闭主窗口") { Text("继续在后台运行，动态壁纸不中断").foregroundStyle(.secondary) }
                LabeledContent("退出 App") { Text("动态壁纸定格为当前画面").foregroundStyle(.secondary) }
            } header: {
                Text("窗口")
            }

            Section("窗口内快捷键") {
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
        .scrollContentBackground(.hidden)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
        } catch {
            ToastCenter.shared.show("设置开机启动失败：\(error.localizedDescription)", style: .error)
        }
        launchAtLogin = LaunchAtLogin.isEnabled
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
    @ObservedObject private var pixivAccount = PixivAccountSession.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            wallhavenSection
            if viewModel.isAuthenticated { wallhavenSyncSection }
            steamSection
            if !workshop.usesSteamCDN { steamCMDSection }
            pixivSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
                    if steamAccount.loginState == .restoring { ProgressView().controlSize(.small) }
                    if steamAccount.hasRememberedAccount {
                        Button("重试恢复") { Task { await steamAccount.ensureAuthenticated(forceRefresh: true) } }
                            .disabled(steamAccount.loginState.isBusy)
                    }
                    Button("登录 Steam") { openWindow(id: SteamLoginWindow.id) }
                        .buttonStyle(.borderedProminent)
                }
            }
            if case .failed(let message) = steamAccount.loginState {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if steamAccount.isLoggedIn {
                if workshop.usesSteamCDN {
                    Label("创意工坊壁纸直接从 Steam 下载，无需 steamcmd", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Label("网页登录只能同步订阅；改用扫码登录后可直接下载", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
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
            Toggle("自动更新已下载的工坊壁纸", isOn: $workshop.autoUpdateWallpapers)
            HStack {
                Button("检查工坊更新") { workshop.checkForUpdates(force: true) }
                    .disabled(workshop.isCheckingUpdates)
                Button("更新全部（\(workshop.pendingUpdateCount)）") { workshop.updateAllWallpapers() }
                    .disabled(workshop.pendingUpdateCount == 0)
                if workshop.pendingValidationCount > 0 {
                    Button("校验旧记录（\(workshop.pendingValidationCount)）…") { workshop.validateOldWallpapers() }
                }
                if workshop.isCheckingUpdates { ProgressView().controlSize(.small) }
            }
            SettingsFootnote("启动及每 30 分钟检查。自动更新和更新全部只处理已确认的新版，不包含版本未知的旧记录。旧记录需手动校验，可能下载缺失或变化文件；校验使用现有下载队列，可暂停、恢复和停止。")
        } header: {
            Label("Steam 账号（订阅与下载）", systemImage: "arrow.triangle.2.circlepath")
        } footer: {
            SettingsFootnote("用 Steam 手机 App 扫码登录，凭据保存在系统钥匙串并自动恢复。扫码登录后订阅同步和壁纸下载都使用此账号，账号需已购买 Wallpaper Engine。")
        }
    }

    /// steamcmd 登录状态 + 操作
    @ViewBuilder
    private var steamCMDStatusRow: some View {
        let status = workshop.steamCMDStatus
        let (icon, color, title, detail): (String, Color, String, String?) = switch status {
        case .notInstalled: ("exclamationmark.triangle.fill", .orange, "未安装 steamcmd", nil)
        case .noUsername: ("person.crop.circle.badge.questionmark", .secondary, "请填写 Steam 用户名", nil)
        case .notLoggedIn: ("circle.dashed", .secondary, "未登录", "在终端登录一次后即可在 App 内下载")
        case .cached: ("checkmark.circle", .green, "已登录", "已缓存登录凭据，可点击「验证」确认仍然有效")
        case .verified: ("checkmark.circle.fill", .green, "已登录", "最近一次下载或验证成功")
        case .expired: ("xmark.octagon.fill", .red, "登录已失效", "请在终端重新登录")
        case .verifying: ("hourglass", .secondary, "正在验证…", nil)
        }
        HStack(spacing: 10) {
            if status == .verifying {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if status == .cached || status == .verified || status == .expired {
                Button("验证") { workshop.verifySteamCMDLogin() }
                    .help("用缓存的凭据登录一次，确认是否仍然有效")
            }
            if status != .notInstalled && status != .noUsername && status != .verifying {
                Button(status == .notLoggedIn || status == .expired ? "在终端登录" : "重新登录") { workshop.loginSteamCMD() }
                    .buttonStyle(.borderedProminent)
                    .tint(status == .notLoggedIn || status == .expired ? .accentColor : .gray)
            }
        }
        .onAppear { workshop.refreshSteamCMDStatus() }
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
            steamCMDStatusRow
        } header: {
            Label("备用下载方式（steamcmd）", systemImage: "arrow.down.circle")
        } footer: {
            SettingsFootnote("未扫码登录 Steam 时使用。账号需已购买 Wallpaper Engine；首次需在终端输入密码和 Steam 令牌，之后 steamcmd 会缓存登录状态。")
        }
    }

    private var pixivSection: some View {
        Section {
            AccountStatusRow(
                isConnected: pixivAccount.isLoggedIn,
                title: pixivAccount.isLoggedIn ? (pixivAccount.userName ?? "已登录") : "未登录",
                subtitle: pixivAccount.userID.map { "UID: \($0)" }
            ) {
                if pixivAccount.isLoggedIn {
                    Button("退出登录") {
                        Task { await pixivAccount.logout() }
                    }
                } else {
                    Button("登录 Pixiv") { openWindow(id: PixivLoginWindow.id) }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let error = pixivAccount.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            if pixivAccount.isLoggedIn {
                Label(pixivAccount.isPersistent ? "登录已验证，凭据已保存到钥匙串" : "登录已验证，仅本次有效；重启后需重新登录", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                if !pixivAccount.isPersistent {
                    Button("重新保存登录") { _ = pixivAccount.retryPersistence() }
                }
            }
        } header: {
            Label("Pixiv 账号", systemImage: "paintpalette")
        } footer: {
            SettingsFootnote("通过 Pixiv 官方网页登录，验证成功后保存凭据。可访问账号有权限的内容；本站限制和会员权限仍由 Pixiv 决定。")
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

            LiveDisplaySection()
            WebDesktopInputSection()
            AutoPauseSection(live: live)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// 动态壁纸的显示方式
private struct LiveDisplaySection: View {
    @AppStorage(DesktopSettings.coverDesktopIcons) private var coverIcons = false
    @AppStorage(DesktopSettings.syncStaticWallpaper) private var syncStatic = true
    @AppStorage(DesktopSettings.keepAspectRatio) private var keepAspect = false
    @AppStorage(DesktopSettings.backgroundColor) private var backgroundHex = "#000000"
    @State private var screens = NSScreen.screens
    @State private var disabled = DesktopSettings.disabledDisplayIDs

    var body: some View {
        Section {
            Toggle("隐藏桌面图标", isOn: $coverIcons)
            Toggle("切换动态壁纸时同步更新桌面图片", isOn: $syncStatic)
            Toggle("保持视频原始长宽比", isOn: $keepAspect)
            if keepAspect {
                ColorPicker("空白区域颜色", selection: Binding(
                    get: { Color(nsColor: NSColor(hex: backgroundHex) ?? .black) },
                    set: { backgroundHex = NSColor($0).hexString }
                ), supportsOpacity: false)
            }
        } header: {
            Text("显示")
        } footer: {
            SettingsFootnote("隐藏桌面图标只在播放动态壁纸时生效，图标仍可点击。同步桌面图片后，锁屏、调度中心和退出 App 后都显示同一画面。长宽比只影响视频类壁纸。")
        }

        Section {
            ForEach(screens, id: \.displayUUID) { screen in
                Toggle(isOn: Binding(
                    get: { !disabled.contains(screen.displayUUID) },
                    set: { setEnabled($0, screen.displayUUID) }
                )) {
                    HStack {
                        Text(screen.localizedName)
                        if screen == NSScreen.main { Text("主显示器").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        } header: {
            Text("在这些显示器上播放")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
    }

    private func setEnabled(_ enabled: Bool, _ id: String) {
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        UserDefaults.standard.set(Array(disabled), forKey: DesktopSettings.disabledDisplays)
    }
}

/// 网页壁纸：不进入交互模式，直接在桌面上点按、拖拽、滚动
private struct WebDesktopInputSection: View {
    @AppStorage(DesktopSettings.webDesktopInput) private var mode: WebDesktopInputMode = .off
    @State private var isTrusted = AXIsProcessTrusted()
    @State private var clickRevealsDesktop = WebDesktopInputSection.readClickRevealsDesktop()

    var body: some View {
        Section {
            Picker("在桌面上直接操作", selection: $mode) {
                ForEach(WebDesktopInputMode.allCases) { Text($0.title).tag($0) }
            }
            if mode == .forward {
                LabeledContent("区分桌面图标") {
                    if isTrusted {
                        Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("授予辅助功能权限…") {
                            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
                        }
                    }
                }
                if clickRevealsDesktop {
                    LabeledContent {
                        Button("打开桌面与程序坞设置…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!)
                        }
                    } label: {
                        Text("系统设置里「点按墙纸以显示桌面」为「始终」")
                        Text("每次点壁纸，窗口都会移开露出桌面。建议改为「仅在台前调度中」。")
                    }
                }
            }
        } header: {
            Text("网页壁纸交互")
        } footer: {
            SettingsFootnote(footnote)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isTrusted = AXIsProcessTrusted()
            clickRevealsDesktop = Self.readClickRevealsDesktop()
        }
    }

    private var footnote: String {
        switch mode {
        case .off:
            "只能通过壁纸的交互按钮或菜单栏进入交互，Esc 退出。"
        case .forward:
            "和 Windows 上的 Wallpaper Engine 一样，桌面图标、右键菜单、拖放照常使用，点桌面空白处时把点按、拖拽、滚轮和指针移动转给网页壁纸。不授权辅助功能时点图标也会传给壁纸。转发的是模拟事件，少数需要真实点击的功能（如有声播放）不响应；需要键盘时仍要进入交互。"
        case .direct:
            "网页壁纸放到桌面图标之上，直接接收真实的鼠标操作，兼容性最好，不会把 Scena 切到前台。桌面图标会被盖住，桌面右键菜单和拖放到桌面不可用；需要键盘时仍要进入交互。"
        }
    }

    /// macOS 14 起点按墙纸会让窗口移开（未设置时默认开启）
    private static func readClickRevealsDesktop() -> Bool {
        UserDefaults(suiteName: "com.apple.WindowManager")?.object(forKey: "EnableStandardClickToShowDesktop") as? Bool ?? true
    }
}

/// 自动暂停条件
private struct AutoPauseSection: View {
    @ObservedObject var live: LiveWallpaperController
    @AppStorage(DesktopSettings.pauseWhenOccluded) private var occluded = true
    @AppStorage(DesktopSettings.pauseWhenOtherAppActive) private var otherApp = false
    @AppStorage(DesktopSettings.pauseWhenFullScreen) private var fullScreen = true
    @AppStorage(DesktopSettings.pauseOnBattery) private var battery = false
    @AppStorage(DesktopSettings.pauseWhenIdle) private var idle = false
    @AppStorage(DesktopSettings.idleMinutes) private var idleMinutes = 10

    var body: some View {
        Section {
            Toggle("桌面被窗口完全挡住时", isOn: $occluded)
            Toggle("其他 App 在使用时", isOn: $otherApp)
            Toggle("其他 App 全屏时", isOn: $fullScreen)
            Toggle("未连接电源时", isOn: $battery)
            Toggle("电脑不活跃时", isOn: $idle)
            if idle {
                Stepper(value: $idleMinutes, in: 1...120) {
                    LabeledContent("不活跃超过") { Text("\(idleMinutes) 分钟").monospacedDigit() }
                }
            }
            LabeledContent("锁屏、睡眠、显示器关闭") { Text("始终暂停").foregroundStyle(.secondary) }
            if !live.autoPauseReasons.isEmpty, live.isActive {
                Label("当前已自动暂停：" + live.autoPauseReasons.map(\.label).sorted().joined(separator: "、"),
                      systemImage: "pause.circle")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("自动暂停")
        } footer: {
            SettingsFootnote("条件解除后自动继续播放。手动暂停的优先级更高：手动暂停后不会被自动恢复。菜单栏图标的「自动暂停」菜单里也可以快速切换。")
        }
    }
}

/// 系统范围的快捷键：App 在后台时也有效
private struct GlobalHotKeySection: View {
    @ObservedObject private var hotKeys = GlobalHotKeys.shared
    @State private var recording: GlobalHotKeys.Action?
    @State private var monitor: Any?

    var body: some View {
        Section {
            ForEach(GlobalHotKeys.Action.allCases) { action in
                LabeledContent(action.title) {
                    HStack(spacing: 6) {
                        Button {
                            recording == action ? stopRecording() : startRecording(action)
                        } label: {
                            Text(recording == action ? "请按下快捷键…" : (hotKeys.combos[action]?.display ?? "点击设置"))
                                .monospaced()
                                .frame(minWidth: 110)
                        }
                        if hotKeys.combos[action] != nil, recording != action {
                            Button {
                                hotKeys.set(nil, for: action)
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("清除")
                        }
                    }
                }
            }
        } header: {
            Text("全局快捷键")
        } footer: {
            SettingsFootnote("需要包含 ⌘、⌥ 或 ⌃ 中的至少一个。按 Esc 取消录制。")
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording(_ action: GlobalHotKeys.Action) {
        stopRecording()
        recording = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                stopRecording()
                return nil
            }
            guard let combo = GlobalHotKeys.combo(from: event) else {
                NSSound.beep()
                return nil
            }
            hotKeys.set(combo, for: action)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }
}

// MARK: - 创意工坊

private struct WorkshopSettings: View {
    @EnvironmentObject private var workshop: WorkshopViewModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var autoBake = AutoBakeScheduler.shared

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
                Picker("每批下载数量", selection: $workshop.maxConcurrentDownloads) {
                    ForEach(1...10, id: \.self) { Text("\($0) 个").tag($0) }
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
                SettingsFootnote("同一个 Steam 账号同时只能运行一个 steamcmd，一批里的壁纸会逐个下载，下载速度不会因为数量变大而变快。数量越大，登录次数越少；数量越小，暂停、停止单个任务时影响的范围越小。")
            }

            Section {
                Toggle("下载后自动转为视频", isOn: $autoBake.isEnabled)
                if autoBake.isEnabled || !autoBake.pending.isEmpty {
                    HStack {
                        Text(autoBake.activeID != nil ? "正在转换…" : (autoBake.pending.isEmpty ? "队列为空" : "\(autoBake.pending.count) 个等待转换"))
                        if let reason = autoBake.waitingReason, autoBake.activeID == nil, !autoBake.pending.isEmpty {
                            Text("· \(reason)").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !autoBake.pending.isEmpty {
                            Button("清空队列") { autoBake.clearQueue() }
                        }
                    }
                }
                let candidates = autoBake.candidateCount(in: workshop.libraryItems)
                if candidates > 0 {
                    HStack {
                        Text("资料库中还有 \(candidates) 个场景 / 网页壁纸未转换")
                        Spacer()
                        Button("全部加入队列") { autoBake.enqueueLibrary(workshop.libraryItems) }
                            .disabled(!autoBake.isEnabled)
                    }
                }
            } header: {
                Text("转为视频")
            } footer: {
                SettingsFootnote("开启后自动转换场景和网页壁纸，并优先播放已生成的循环视频；鼠标、音乐等互动效果会消失；带时钟、日期等实时文字的场景壁纸不自动转换，以免时间定格。关闭后桌面和预览立即改用源文件，已生成的视频保留。自动转换只在接通电源、电脑 3 分钟无操作、系统不热时进行，一次一个；有操作就暂停，下次空闲继续。也可以在壁纸信息面板里手动转换。")
            }

        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
                SettingsFootnote("所选位置里会创建 Scena 文件夹，内含 Wallhaven、Konachan、4K Wallpapers、MotionBG（各图源下载的壁纸）、Wallpaper Engine（创意工坊）、Imported（导入的图片和视频）。可以设到外接盘；更改位置时会移动已有内容，并更新播放列表和动态壁纸的引用。")
            }

            Section {
                usageRow("Wallhaven", storage.usage.wallpapers, .blue)
                ForEach(Array(storage.usage.sources.enumerated()), id: \.offset) { _, source in
                    usageRow(source.name, source.bytes, .cyan)
                }
                usageRow("本地导入", storage.usage.imported, .green)
                usageRow("创意工坊壁纸", storage.usage.workshop, .purple)
                usageRow("工坊转成的视频", storage.usage.baked, .indigo)
                usageRow("缓存", storage.usage.cache, .gray)
                HStack {
                    Spacer()
                    Button("清除缓存") { storage.clearImageCache() }
                }
            } header: {
                Text("空间占用")
            } footer: {
                SettingsFootnote("包括缩略图和背景图（上限 1 GB，保留 14 天）、视频封面、在线视频预览、工坊动图预览和网页缓存。清除后会按需重新下载，不影响已下载的壁纸和登录状态。")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
        panel.message = "选择存储位置（可以是外接盘），将在其中创建 Scena 文件夹"
        panel.prompt = "选择"
        if let volumes = URL(string: "file:///Volumes/") { panel.directoryURL = volumes }
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        // 在所选位置里建一个 Scena 文件夹，避免把文件散落在根目录；选中的文件夹本身就叫 Scena 时直接使用
        let root = chosen.lastPathComponent.lowercased() == StorageManager.Layout.root.lowercased()
            ? chosen
            : chosen.appendingPathComponent(StorageManager.Layout.root, isDirectory: true)
        confirmMove(to: root)
    }

    private func confirmMove(to root: URL?) {
        let alert = NSAlert()
        alert.messageText = root.map { "将存储位置改到「\(StorageManager.volumeName(of: $0))」？" } ?? "恢复默认存储位置？"
        alert.informativeText = """
        新位置：\(root?.path ?? "~/Pictures/Wallhaven 和 Steam 默认工坊目录")
        已有内容（约 \(formatBytes(storage.usage.wallpapers + storage.usage.imported + storage.usage.workshop))）会移动到新位置，跨盘移动可能需要一些时间。
        """
        alert.addButton(withTitle: "移动")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        storage.changeLocation(to: root)
    }
}

// MARK: - 关于

private struct AboutSettings: View {
    @ObservedObject private var updateManager = UpdateManager.shared

    private var updateDownloadText: String {
        let received = FileSizeText.string(updateManager.downloadedBytes)
        guard let size = updateManager.downloadSize, size > 0,
              let fraction = updateManager.downloadFraction else { return "已下载 \(received)" }
        let total = FileSizeText.string(size)
        return "\(Int(fraction * 100))% · \(received) / \(total)"
    }

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
                    SystemApplicationIcon()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Scena").font(.title2.bold())
                        Text("图片、视频与创意工坊壁纸").foregroundStyle(.secondary)
                        Text("版本 \(version)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                HStack {
                    if updateManager.isInstalling {
                        Text("正在安装更新，请稍候…").foregroundStyle(.secondary)
                    } else if updateManager.isPreparingUpdate {
                        Text("下载完成，正在解压并准备更新…").foregroundStyle(.secondary)
                    } else if updateManager.isReadyToInstall {
                        Label("v\(updateManager.latestVersion) 已下载，重启即可完成更新", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if updateManager.isDownloading {
                        Text("正在下载 v\(updateManager.latestVersion)…").foregroundStyle(.secondary)
                    } else if updateManager.updateAvailable {
                        Label("发现新版本 v\(updateManager.latestVersion)", systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text(updateManager.statusMessage ?? "当前版本 \(updateManager.currentVersion)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if updateManager.isChecking || updateManager.isDownloading || updateManager.isInstalling {
                        ProgressView().controlSize(.small)
                    }
                    if updateManager.isReadyToInstall && !updateManager.isInstalling {
                        Button("立即重启") { updateManager.restartToUpdate() }
                            .buttonStyle(.borderedProminent)
                    } else if updateManager.updateAvailable {
                        Button(updateManager.isDevelopmentBuild ? "打开发布页面" : "下载并安装") { updateManager.installUpdate() }
                            .buttonStyle(.borderedProminent)
                            .disabled(updateManager.isDownloading || updateManager.isInstalling)
                    } else {
                        Button("检查更新") { Task { await updateManager.checkForUpdates() } }
                            .disabled(updateManager.isChecking)
                    }
                }
                if updateManager.isDownloading {
                    VStack(alignment: .leading, spacing: 6) {
                        if let fraction = updateManager.downloadFraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                        HStack {
                            Text(updateDownloadText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Spacer()
                            Button("取消下载") { updateManager.cancelDownload() }
                                .controlSize(.small)
                        }
                    }
                }
                if let error = updateManager.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if updateManager.updateAvailable, !updateManager.releaseNotes.isEmpty {
                    Text(updateManager.releaseNotes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
                Toggle("自动检查更新", isOn: $updateManager.checksAutomatically)
                Toggle("自动下载更新", isOn: $updateManager.downloadsAutomatically)
                Link(destination: UpdateManager.releasesPage) {
                    LabeledContent("GitHub 发布页面") { Image(systemName: "arrow.up.right") }
                }
            } header: {
                Text("更新")
            } footer: {
                SettingsFootnote("发现新版本后在后台下载，完成后询问是否重启；选择「稍后」会在退出 Scena 时自动安装。没有新版本时不会提醒。")
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
        .scrollContentBackground(.hidden)
    }
}
