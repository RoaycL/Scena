//
//  WorkshopControls.swift
//  wallhaven
//

import SwiftUI

// MARK: - Glass panel building blocks

/// 深色玻璃面板：与沉浸式界面统一风格（替代系统 popover，避免浅色外观下白底白字）
struct GlassPanel<Content: View>: View {
    var width: CGFloat = 340
    var maxHeight: CGFloat = 600
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .padding(18)
            .frame(width: width, alignment: .leading)
        }
        .frame(width: width)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.black.opacity(0.45), in: shape)
        .background(.ultraThinMaterial, in: shape)
        .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 0.5))
        .clipShape(shape)
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .environment(\.colorScheme, .dark)
    }
}

struct GlassSection<Content: View>: View {
    let title: String
    var trailing: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                if let trailing {
                    Spacer()
                    Text(trailing)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            content()
        }
    }
}

struct GlassChip: View {
    let title: String
    let isOn: Bool
    var tint: Color = .white
    var disabled = false
    var fontSize: CGFloat = 12
    var horizontalPadding: CGFloat = 11
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: fontSize, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(isOn ? (tint == .white ? .black : .white) : .white.opacity(0.8))
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isOn ? (tint == .white ? Color.white.opacity(0.92) : tint.opacity(0.8)) : Color.white.opacity(0.08))
                )
                .overlay(Capsule().stroke(.white.opacity(isOn ? 0 : 0.12), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .animation(.easeOut(duration: 0.15), value: isOn)
    }
}

/// 自动换行的流式布局（标签云）
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, maxWidth: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Workshop filter panel

/// 创意工坊筛选：类型、分级、排序、题材、特性、分辨率（对应 Steam 工坊的官方标签分类）
struct WorkshopFilterPanel: View {
    @EnvironmentObject private var workshop: WorkshopViewModel
    var maxHeight: CGFloat = 600

    var body: some View {
        GlassPanel(width: 360, maxHeight: maxHeight) {
            HStack {
                Text("筛选")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text(workshop.mode == .online ? "创意工坊" : "已下载")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                if !workshop.filters.isDefault {
                    Button("重置") { workshop.resetFilters() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }

            GlassSection(title: "内容偏好") {
                // 「动漫」本身是一个题材，和女孩、风景等并列，一个壁纸通常只有一个题材标签：
                // 选了其他题材时结果里本来就没有动漫，这个开关不起作用
                let hasGenre = !workshop.filters.genres.isEmpty
                HStack(spacing: 8) {
                    GlassChip(title: "显示动漫", isOn: !workshop.filters.hideAnime) {
                        workshop.filters.hideAnime = false
                    }
                    GlassChip(title: "隐藏动漫", isOn: workshop.filters.hideAnime) {
                        workshop.filters.hideAnime = true
                    }
                }
                .disabled(hasGenre)
                .opacity(hasGenre ? 0.4 : 1)
                Text(hasGenre
                     ? "已选择题材：「动漫」本身也是一个题材，壁纸通常只属于其中一个，所以选了题材后结果里本来就没有动漫标签的内容。注意动漫画风的壁纸常被归为「女孩」等题材，无法按标签排除。"
                     : "隐藏动漫时排除带有「动漫」标签的内容。动漫画风但被作者归为其他题材的壁纸不会被排除。")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }

            GlassSection(title: "仅显示") {
                FlowLayout {
                    ForEach(WorkshopTags.features, id: \.tag) { feature in
                        GlassChip(title: feature.label, isOn: workshop.filters.features.contains(feature.tag)) {
                            workshop.filters.features.formSymmetricDifference([feature.tag])
                        }
                    }
                }
                if workshop.mode == .library, workshop.filters.features.contains("Approved") {
                    Text("仅显示带有官方好评标记的素材；本地文件可能未保存该标记。")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            GlassSection(title: "类型") {
                FlowLayout {
                    ForEach(WorkshopTypeFilter.allCases) { type in
                        GlassChip(title: type.label, isOn: workshop.filters.type == type) {
                            workshop.filters.type = type
                        }
                    }
                }
            }

            GlassSection(title: "年龄分级", trailing: "可多选") {
                HStack(spacing: 6) {
                    ForEach(WorkshopRating.allCases) { rating in
                        GlassChip(title: rating.label, isOn: workshop.filters.ratings.contains(rating), tint: tint(for: rating), fontSize: 11, horizontalPadding: 8) {
                            toggle(rating)
                        }
                    }
                }
                if workshop.filters.ratings.contains(.mature) {
                    Text("部分成人内容需要 Steam 账号完成年龄验证才会返回。")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            if workshop.mode == .online {
                GlassSection(title: "排序") {
                    FlowLayout {
                        ForEach(WorkshopSort.allCases) { sort in
                            GlassChip(title: sort.label, isOn: workshop.filters.sort == sort) {
                                workshop.filters.sort = sort
                            }
                        }
                    }
                    if workshop.filters.sort == .trend {
                        FlowLayout {
                            ForEach(WorkshopTags.trendRanges, id: \.days) { range in
                                GlassChip(title: range.label, isOn: workshop.filters.trendDays == range.days, tint: .accentColor) {
                                    workshop.filters.trendDays = range.days
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }

            GlassSection(title: "标签", trailing: "多选时需同时包含") {
                FlowLayout {
                    ForEach(WorkshopTags.genres.filter { $0.tag != "Anime" }, id: \.tag) { genre in
                        GlassChip(title: genre.label, isOn: workshop.filters.genres.contains(genre.tag)) {
                            workshop.filters.toggleGenre(genre.tag)
                        }
                    }
                }
            }

            if workshop.mode == .online {
                GlassSection(title: "分辨率") {
                    FlowLayout {
                        GlassChip(title: "不限", isOn: workshop.filters.resolution == nil) {
                            workshop.filters.resolution = nil
                        }
                        ForEach(WorkshopTags.resolutions, id: \.tag) { resolution in
                            GlassChip(title: resolution.label, isOn: workshop.filters.resolution == resolution.tag) {
                                workshop.filters.resolution = resolution.tag
                            }
                        }
                    }
                }
            }

            Text("「应用」类型是 Windows 程序，macOS 无法运行，已自动排除。")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tint(for rating: WorkshopRating) -> Color {
        switch rating {
        case .everyone: .green
        case .questionable: .orange
        case .mature: .red
        }
    }

    /// 至少保留一个分级
    private func toggle(_ rating: WorkshopRating) {
        var ratings = workshop.filters.ratings
        if ratings.contains(rating) {
            guard ratings.count > 1 else { return }
            ratings.remove(rating)
        } else {
            ratings.insert(rating)
        }
        workshop.filters.ratings = ratings
    }
}

/// 已下载 / 在线 切换
struct WorkshopModePicker: View {
    @EnvironmentObject private var workshop: WorkshopViewModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(WorkshopViewModel.Mode.allCases) { mode in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { workshop.mode = mode }
                } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(workshop.mode == mode ? .white : .white.opacity(0.6))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(workshop.mode == mode ? .white.opacity(0.2) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
