//
//  WorkshopDownloadCapsule.swift
//  wallhaven
//

import SwiftUI

/// 工坊壁纸的下载状态胶囊：底色从左往右按进度填充，填充部分有一道流动的高光；
/// 还没有字节进度（排队、连接 Steam）时高光流过整个胶囊。单独观察进度对象，每次进度更新只重绘这一小块
struct WorkshopDownloadCapsule: View {
    @ObservedObject var progress: WorkshopDownloadProgress
    let itemID: String
    let state: DownloadState
    var onPause: (() -> Void)? = nil
    let onCancel: () -> Void

    private var fraction: Double? {
        state == .downloading ? progress.entries[itemID]?.fraction : nil
    }

    private var label: String {
        guard state == .downloading else { return state.label }
        guard let fraction else { return "正在连接…" }
        var text = "下载中 \(Int(fraction * 100))%"
        if progress.bytesPerSecond > 0 { text += " · " + FileSizeText.string(progress.bytesPerSecond) + "/s" }
        return text
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down")
                .font(.system(size: 11, weight: .bold))
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
            Spacer(minLength: 8)
            if let onPause {
                Button("暂停", action: onPause).buttonStyle(.plain)
            }
            Button(onPause == nil ? "取消" : "停止", action: onCancel)
                .buttonStyle(.plain)
                .foregroundStyle(Color.primary.opacity(0.7))
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background { DownloadFill(fraction: fraction, flowing: state == .downloading || state == .queued) }
        .clipShape(Capsule())
        .animation(Motion.content, value: label)
        .accessibilityElement(children: .contain)
        .accessibilityValue(fraction.map { "\(Int($0 * 100))%" } ?? state.label)
    }
}

private struct DownloadFill: View {
    let fraction: Double?
    let flowing: Bool
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            // 有进度时只填充已完成的部分；没有进度时整条胶囊作为流动区域
            let filled = fraction.map { max(geometry.size.height, width * $0) } ?? width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06))
                Capsule()
                    .fill(Color.accentColor.opacity(fraction == nil ? 0 : 0.32))
                    .frame(width: filled)
                if flowing && !reducesMotion {
                    Sheen(width: width)
                        .frame(width: filled)
                        .clipShape(Capsule())
                }
            }
            .animation(.easeOut(duration: 0.35), value: fraction)
        }
    }
}

/// 一道从左往右循环流过的柔和高光
private struct Sheen: View {
    let width: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let period = 1.6
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            let band = max(60, width * 0.35)
            LinearGradient(colors: [.clear, Color.primary.opacity(0.14), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: band)
                .offset(x: -band + (width + band) * phase)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .allowsHitTesting(false)
    }
}
