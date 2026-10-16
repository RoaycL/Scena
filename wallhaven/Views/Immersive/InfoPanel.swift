//
//  InfoPanel.swift
//  wallhaven
//

import SwiftUI

/// 左下角的信息面板：直接压在壁纸上（靠底部渐变保证可读性），不再使用黑色底框
struct InfoPanel<Actions: View>: View {
    @Environment(\.colorScheme) private var scheme
    private var palette: ThemePalette { ThemePalette(scheme: scheme) }
    let eyebrow: String
    let title: String
    let meta: [String]
    var colors: [String] = []
    var tags: [String] = []
    var onTag: ((String) -> Void)? = nil
    var tagLabel: (String) -> String = { $0 }
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow)
                .font(.system(size: 10, weight: .bold))
                .tracking(2.5)
                .foregroundStyle(Color.primary.opacity(0.6))

            Text(title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(Color.primary)
                .lineLimit(2)

            HStack(spacing: 8) {
                ForEach(Array(meta.enumerated()), id: \.offset) { index, value in
                    if index > 0 { Text("·").opacity(0.5) }
                    Text(value)
                }
                if !colors.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(colors.prefix(5), id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 0.5))
                                .help(hex)
                        }
                    }
                    .padding(.leading, 4)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.75))

            if !tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(tags.prefix(5), id: \.self) { tag in
                        Button { onTag?(tag) } label: {
                            Text("#\(tagLabel(tag))")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.primary.opacity(0.85))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Color.primary.opacity(0.07), in: Capsule())
                                .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .help("搜索 \(tag)")
                    }
                }
                .lineLimit(1)
                .transition(.opacity)
            }

            HStack(spacing: 8) {
                actions()
            }
            .padding(.top, 4)
        }
        .shadow(color: palette.shadow, radius: 8, y: 2)
        .animation(Motion.content, value: tags)
    }
}

/// 「设为壁纸」：按钮本身显示过程和结果——设置中（转圈）→ 已设为壁纸（对勾，2 秒）；
/// 这张正是当前桌面壁纸时常驻显示「当前壁纸」
struct ApplyWallpaperButton: View {
    @ObservedObject private var feedback = ApplyFeedback.shared
    @Environment(\.colorScheme) private var scheme
    private var palette: ThemePalette { ThemePalette(scheme: scheme) }
    let item: GalleryItem
    var title = "设为壁纸"
    let action: () -> Void

    private enum Phase { case idle, applying, applied, current }

    private var phase: Phase {
        if feedback.applying.contains(item.id) { return .applying }
        if feedback.justApplied == item.id { return .applied }
        return item.isOnDesktop ? .current : .idle
    }

    var body: some View {
        let phase = phase
        Button(action: action) {
            HStack(spacing: 5) {
                switch phase {
                case .applying:
                    ProgressView().controlSize(.mini)
                        .environment(\.colorScheme, palette.primarySpinnerScheme)
                        .transition(.opacity)
                case .applied, .current:
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .transition(Motion.reducesMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                case .idle:
                    EmptyView()
                }
                Text(label(for: phase))
                    .contentTransition(.opacity)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            // 「当前壁纸」是常驻状态，略微收敛，和可操作的主按钮区分开
            .background(palette.primaryFill.opacity(phase == .current ? (palette.isDay ? 0.72 : 0.78) : 1), in: Capsule())
            .animation(Motion.hover, value: phase)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(phase == .applying)
        .help(phase == .current ? "已是当前桌面壁纸（点击重新设置）" : title)
    }

    private func label(for phase: Phase) -> String {
        switch phase {
        case .idle: title
        case .applying: "设置中"
        case .applied: "已设为壁纸"
        case .current: "当前壁纸"
        }
    }
}

struct CircleIconLabel: View {
    let systemImage: String
    var tint: Color = .primary

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(tint)
            // 状态切换（收藏、下载完成、加入列表）：图标原地替换并轻弹一下，颜色同时过渡。
            // 调用方用壁纸 id 作为视图身份，切换壁纸时直接换新视图，不会误播这段动画
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: Motion.reducesMotion ? "" : systemImage)
            .animation(Motion.hover, value: systemImage)
            .animation(Motion.hover, value: tint)
            .frame(width: 32, height: 32)
            .sceneGlass(in: Circle(), interactive: true)
            .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 0.5))
    }
}

struct CircleIconButton: View {
    let systemImage: String
    var tint: Color = .primary
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CircleIconLabel(systemImage: systemImage, tint: tint)
        }
        .buttonStyle(PressableButtonStyle())
        .help(help)
    }
}

/// 收藏按钮：点击菜单可选择收藏夹
struct FavoriteMenuButton: View {
    @EnvironmentObject private var viewModel: WallpaperViewModel
    let wallpaper: RemoteWallpaper
    @State private var burst = 0

    var body: some View {
        let isFavorite = viewModel.isFavorite(wallpaper.id)
        Menu {
            if !viewModel.favoriteFolders.isEmpty {
                let containing = Set(viewModel.foldersContaining(wallpaper.id).map(\.id))
                ForEach(viewModel.favoriteFolders) { folder in
                    let inFolder = containing.contains(folder.id)
                    Button {
                        inFolder
                            ? viewModel.removeFromFolder(wallpaper.id, folderID: folder.id)
                            : viewModel.addToFolder(wallpaper, folderID: folder.id)
                    } label: {
                        Label(folder.name, systemImage: inFolder ? "checkmark.circle.fill" : "folder")
                    }
                }
                Divider()
            }
            Button(role: isFavorite ? .destructive : nil) {
                viewModel.toggleFavorite(wallpaper)
            } label: {
                Label(isFavorite ? "取消收藏" : "添加到默认收藏", systemImage: isFavorite ? "heart.slash" : "heart")
            }
        } label: {
            CircleIconLabel(systemImage: isFavorite ? "heart.fill" : "heart", tint: isFavorite ? .red : .primary)
                .overlay { StateBurst(trigger: burst, color: .red) }
        }
        // .button + .plain 才能保留自定义 label 的样式（borderlessButton 会把背景去掉）
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("收藏")
        .onChange(of: isFavorite) { _, now in if now { burst += 1 } }
    }
}

/// 状态变成「已完成」时从按钮边缘扩散的一圈淡光（收藏、下载完成、加入列表共用）
struct StateBurst: View {
    let trigger: Int
    let color: Color
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(color.opacity(expanded ? 0 : 0.7), lineWidth: expanded ? 0.5 : 2)
            .scaleEffect(expanded ? 1.7 : 1)
            .opacity(trigger > 0 && !Motion.reducesMotion ? 1 : 0)
            .allowsHitTesting(false)
            .onChange(of: trigger) {
                expanded = false
                withAnimation(.easeOut(duration: 0.55)) { expanded = true }
            }
    }
}

/// 下载按钮：未下载 → 下载中（转圈）→ 已下载（绿色对勾），在同一个按钮里过渡
struct DownloadActionButton: View {
    enum Phase: Equatable { case idle, downloading, done }
    let phase: Phase
    var help = "下载 (D)"
    let action: () -> Void
    @State private var burst = 0

    var body: some View {
        Button(action: action) {
            CircleIconLabel(systemImage: phase == .done ? "checkmark" : "arrow.down",
                            tint: phase == .done ? .green : .primary.opacity(phase == .downloading ? 0.45 : 1))
                .overlay {
                    if phase == .downloading { DownloadingRing().transition(.opacity) }
                }
                .overlay { StateBurst(trigger: burst, color: .green) }
                .animation(Motion.hover, value: phase)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(phase != .idle)
        .help(phase == .done ? "已下载到本地" : (phase == .downloading ? "正在下载…" : help))
        .onChange(of: phase) { old, new in if old == .downloading, new == .done { burst += 1 } }
    }
}

/// 下载中：沿按钮边缘旋转的一段弧线；减少动态效果时静止
private struct DownloadingRing: View {
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(Color.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotatingWhileVisible(duration: 0.9)
            .padding(1)
    }
}

extension Color {
    /// 支持 "#RRGGBB" 格式
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// 按下时轻微缩小、悬停时提亮，松开回弹；所有主要按钮共用，手感一致
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration)
    }

    private struct PressableBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !Motion.reducesMotion ? 0.92 : 1)
                .brightness(isHovered && !configuration.isPressed ? 0.08 : 0)
                .animation(Motion.hover, value: configuration.isPressed)
                .animation(Motion.hover, value: isHovered)
                .onHover { isHovered = $0 }
        }
    }
}
