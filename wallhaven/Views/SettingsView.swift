//
//  SettingsView.swift
//  wallhaven
//
//  Created by RoaycL on 2026/4/17.
//

import AppKit
import SwiftUI
import Kingfisher

struct SettingsView: View {
    @EnvironmentObject private var viewModel: WallpaperViewModel
    @AppStorage("downloadPath") private var downloadPath: String = {
        let defaultPath = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first?.appendingPathComponent("Wallhaven").path ?? ""
        return defaultPath
    }()
    @State private var selectedTab = 0
    @StateObject private var updateManager = UpdateManager()
    
    private let tabs: [(String, String)] = [
        ("常规", "gearshape.fill"),
        ("账户", "person.crop.circle.fill"),
        ("关于", "info.circle.fill")
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部标签栏
            HStack(spacing: 4) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedTab = index
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.1)
                                .font(.system(size: 12))
                            Text(tab.0)
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(selectedTab == index ? .white : .secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(selectedTab == index ? Color.accentColor.opacity(0.85) : .clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .padding(.top, 18)
            .padding(.bottom, 10)
            
            Divider().opacity(0.5)
            
            // 内容区
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch selectedTab {
                    case 0: generalContent
                    case 1: accountContent
                    case 2: aboutContent
                    default: EmptyView()
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 520, height: 460)
    }
    
    // MARK: - 常规
    
    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsSectionHeader(icon: "arrow.down.circle.fill", title: "下载设置", color: .blue)
            
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("保存路径")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    
                    HStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.blue.opacity(0.8))
                                .font(.system(size: 13))
                            Text(downloadPath)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.primary.opacity(0.85))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                        
                        Button("更改...") {
                            selectDownloadFolder()
                        }
                        .controlSize(.small)
                    }
                    
                    Text("下载的壁纸将保存在此文件夹中。")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
    
    // MARK: - 账户
    
    private var accountContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsSectionHeader(icon: "key.fill", title: "Wallhaven 账户", color: .orange)
            
            settingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    settingsField(label: "API 密钥", systemImage: "lock.fill") {
                        SecureField("输入您的 API 密钥", text: $viewModel.apiKeyInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                    }
                    
                    settingsField(label: "用户名", systemImage: "person.fill") {
                        TextField("输入您的用户名", text: $viewModel.usernameInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                    }
                    
                    HStack(spacing: 8) {
                        Button {
                            viewModel.login()
                        } label: {
                            Text(viewModel.isAuthenticated ? "更新配置" : "登录验证")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        
                        Button("获取 API 密钥") {
                            viewModel.openAPIKeyPage()
                        }
                        .controlSize(.small)
                        
                        if viewModel.isAuthenticated {
                            Spacer()
                            Button("退出登录") {
                                viewModel.logout()
                            }
                            .controlSize(.small)
                            .foregroundStyle(.red.opacity(0.85))
                        }
                    }
                    .padding(.top, 2)
                    
                    Text("登录后可访问 NSFW 内容，配置用户名后可同步线上收藏夹到本地。")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            
            if viewModel.isAuthenticated {
                settingsSectionHeader(icon: "arrow.triangle.2.circlepath", title: "收藏同步", color: .green)
                
                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Button {
                                Task {
                                    await viewModel.syncCollections()
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "icloud.and.arrow.down")
                                        .font(.system(size: 12))
                                    Text("同步线上收藏到本地")
                                        .font(.system(size: 12, weight: .medium))
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(.green.opacity(0.85))
                            .disabled(viewModel.isSyncing)
                            
                            if viewModel.isSyncing {
                                ProgressView()
                                    .controlSize(.small)
                                Text(viewModel.syncProgress)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        
                        Text("将云端收藏夹结构同步到本地。考虑到 API 速率限制（45次/分钟），收藏较多时耐心等待。")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
    
    // MARK: - 关于
    
    private var aboutContent: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 20)
            
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApplication.shared.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 18))
            
            VStack(spacing: 6) {
                Text("Wallhaven")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("版本 \(version)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Capsule())
                }
            }
            
            Text("非官方 Wallhaven macOS 客户端")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            
            Link(destination: URL(string: "https://wallhaven.cc")!) {
                HStack(spacing: 5) {
                    Image(systemName: "globe")
                        .font(.system(size: 11))
                    Text("访问 Wallhaven 官网")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            
            // 更新检查区域
            VStack(spacing: 12) {
                Button(action: {
                    Task { await updateManager.checkForUpdates() }
                }) {
                    HStack {
                        if updateManager.isChecking {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.swap")
                        }
                        Text(updateManager.isChecking ? "正在检查..." : "检查更新")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(updateManager.isChecking || updateManager.isDownloading)
                
                if updateManager.updateAvailable {
                    VStack(spacing: 8) {
                        Text("发现新版本: v\(updateManager.latestVersion)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.green)
                        
                        if updateManager.isDownloading {
                            ProgressView("正在自动更新...")
                                .controlSize(.small)
                                .font(.system(size: 11))
                                .padding(.top, 4)
                        } else {
                            Button(action: {
                                updateManager.downloadAndInstall()
                            }) {
                                Text("立即更新并重启")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(Color.blue)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 24)
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
                }
                
                if let errorMsg = updateManager.errorMessage {
                    Text(errorMsg)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
            .padding(.top, 10)
            
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - 复用组件
    
    private func settingsSectionHeader(icon: String, title: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
        }
    }
    
    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
    
    private func settingsField<Content: View>(label: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary.opacity(0.7))
                    .font(.system(size: 12))
                    .frame(width: 16)
                content()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }
    
    private func selectDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择下载目录"
        
        if panel.runModal() == .OK {
            if let newPath = panel.url?.path {
                let oldPath = downloadPath
                guard newPath != oldPath else { return }
                
                // 迁移旧目录下的文件到新目录
                let fm = FileManager.default
                let oldURL = URL(fileURLWithPath: oldPath, isDirectory: true)
                let newURL = URL(fileURLWithPath: newPath, isDirectory: true)
                
                if fm.fileExists(atPath: oldPath) {
                    do {
                        // 确保新目录存在
                        if !fm.fileExists(atPath: newPath) {
                            try fm.createDirectory(at: newURL, withIntermediateDirectories: true)
                        }
                        
                        let files = try fm.contentsOfDirectory(at: oldURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                        for file in files {
                            let dest = newURL.appendingPathComponent(file.lastPathComponent)
                            if !fm.fileExists(atPath: dest.path) {
                                try fm.moveItem(at: file, to: dest)
                            }
                        }
                        
                        // 如果旧目录已清空则删除
                        let remaining = try fm.contentsOfDirectory(at: oldURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                        if remaining.isEmpty {
                            try? fm.removeItem(at: oldURL)
                        }
                    } catch {
                        // 迁移失败不阻断路径切换，仅打印日志
                        print("文件迁移失败: \(error.localizedDescription)")
                    }
                }
                
                downloadPath = newPath
            }
        }
    }
}
