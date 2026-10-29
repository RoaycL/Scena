import AppKit
import SwiftUI

enum DownloadsWindow { static let id = "workshop-downloads" }

struct WorkshopDownloadsButton: View {
    /// 面板由主界面绘制（从按钮位置「长」出来），这里只负责开关
    @Binding var isPresented: Bool

    var body: some View {
        Button { withAnimation(Motion.panel) { isPresented.toggle() } } label: {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.85))
                .frame(width: 34, height: 34)
                .sceneGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .help("下载任务")
    }
}

struct WorkshopDownloadsView: View {
    @EnvironmentObject private var workshop: WorkshopViewModel
    /// 主界面浮层里点击任务跳转后收起面板；独立窗口不传，保持打开
    var onNavigate: (() -> Void)? = nil

    var body: some View {
        // 进度每秒刷新，单独放在子视图里观察
        WorkshopDownloadsList(progress: workshop.progress, onNavigate: onNavigate)
            .environmentObject(workshop)
    }
}

private struct WorkshopDownloadsList: View {
    @EnvironmentObject private var workshop: WorkshopViewModel
    @ObservedObject var progress: WorkshopDownloadProgress
    var onNavigate: (() -> Void)?

    /// 打开面板时已经完成的任务：折叠到底部。面板打开期间刚完成的留在原位，下次打开再折叠，避免按钮移位
    @State private var foldedIDs: Set<String> = []
    @State private var showsFolded = false

    // 始终保持入队顺序；暂停、完成与进度变化只更新原来的行，避免按钮移位。
    private var visibleJobs: [WorkshopDownloadJob] { workshop.downloadJobs.filter { !foldedIDs.contains($0.id) || $0.state != .completed } }
    private var foldedJobs: [WorkshopDownloadJob] { workshop.downloadJobs.filter { foldedIDs.contains($0.id) && $0.state == .completed } }

    private var summary: String {
        let active = progress.entries.count
        let waiting = workshop.downloading.count - active
        var parts: [String] = []
        if active > 0 { parts.append("下载中 \(active)") }
        if waiting > 0 { parts.append("等待 \(waiting)") }
        if active > 0, progress.bytesPerSecond > 0 { parts.append(FileSizeText.string(progress.bytesPerSecond) + "/s") }
        return parts.isEmpty ? "没有进行中的任务" : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("下载任务").font(.headline)
                Spacer()
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack {
                Button("全部暂停") { workshop.pauseAllDownloads() }
                    .disabled(workshop.downloading.isEmpty)
                Button("全部恢复") { workshop.resumeAllDownloads() }
                    .disabled(!workshop.downloadJobs.contains { $0.state == .paused })
                Spacer()
                Button("清除已完成") { workshop.clearFinishedDownloads() }
                    .disabled(!workshop.downloadJobs.contains { $0.state == .completed || $0.state == .cancelled })
                Button("全部停止") { workshop.cancelAllDownloads() }
                    .disabled(!workshop.downloadJobs.contains { [.queued, .downloading, .paused, .failed].contains($0.state) })
            }
            .controlSize(.small)
            Divider()
            if workshop.pendingUpdateCount > 0 {
                HStack {
                    Text("\(workshop.pendingUpdateCount) 个工坊壁纸可更新或需校验").font(.caption)
                    Spacer()
                    Button("更新全部") { workshop.updateAllWallpapers() }.controlSize(.small)
                }
            }
            if workshop.downloadJobs.isEmpty {
                ContentUnavailableView("暂无下载任务", systemImage: "arrow.down.circle")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleJobs) { job in
                            row(job)
                                .padding(.vertical, 9)
                            Divider()
                        }
                        if !foldedJobs.isEmpty {
                            Button { showsFolded.toggle() } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.right")
                                        .rotationEffect(.degrees(showsFolded ? 90 : 0))
                                    Text("已完成 \(foldedJobs.count) 项")
                                    Spacer()
                                }
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(showsFolded ? "已展开" : "已收起")
                            .animation(Motion.reducesMotion ? nil : Motion.disclosure, value: showsFolded)

                            DownloadSectionReveal(isExpanded: showsFolded) {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(foldedJobs) { job in
                                        row(job)
                                            .padding(.vertical, 9)
                                        Divider()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            foldedIDs = Set(workshop.downloadJobs.filter { $0.state == .completed }.map(\.id))
        }
        .padding(16)
        .frame(width: 440, height: 420)
        .modifier(DownloadsBackground(inWindowPanel: onNavigate != nil))
    }

    private func row(_ job: WorkshopDownloadJob) -> some View {
        let entry = progress.entries[job.id]
        return HStack(alignment: .center, spacing: 10) {
            Button {
                MainWindow.reveal(workshopItemID: job.id)
                onNavigate?()
            } label: {
                rowText(job, entry: entry)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("在 Scena 中查看（已删除的会在创意工坊中按 ID 查找）")
            Spacer(minLength: 8)
            controls(job)
        }
        .contextMenu {
            Button("在 Scena 中查看") {
                MainWindow.reveal(workshopItemID: job.id)
                onNavigate?()
            }
            if let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(job.id)") {
                Button("在 Steam 中打开") { NSWorkspace.shared.open(url) }
            }
        }
    }

    @ViewBuilder
    private func rowText(_ job: WorkshopDownloadJob, entry: WorkshopDownloadProgress.Entry?) -> some View {
            VStack(alignment: .leading, spacing: 5) {
                Text(job.title).lineLimit(1).truncationMode(.middle)
                if job.requiresValidation == true {
                    Text("工坊更新 / 校验").font(.caption).foregroundStyle(.secondary)
                }
                if job.state == .downloading, let entry {
                    if let fraction = entry.fraction {
                        ProgressView(value: fraction).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                    Text(progressText(entry))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else if job.state == .downloading, job.id == workshop.downloadJobs.first(where: { $0.state == .downloading })?.id {
                    // 本批正在处理的条目：还没有字节进度（连接 Steam、获取清单中，或 steamcmd 估算不到）时显示不确定进度
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                    Text(workshop.usesSteamCDN ? "正在连接 Steam…" : "正在通过 steamcmd 下载…")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(statusText(job))
                        .font(.caption)
                        .foregroundStyle(job.state == .completed ? .green : .secondary)
                }
                if let error = job.error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
                }
            }
    }

    private func progressText(_ entry: WorkshopDownloadProgress.Entry) -> String {
        let done = FileSizeText.string(entry.bytes)
        guard let total = entry.total, let fraction = entry.fraction else { return "已下载 \(done)" }
        var text = "\(done) / \(FileSizeText.string(total)) · \(Int(fraction * 100))%"
        // 剩余时间：同一时间只有一个条目在传输，整体速度就是它的速度
        if progress.bytesPerSecond > 0, total > entry.bytes {
            let seconds = Double(total - entry.bytes) / Double(progress.bytesPerSecond)
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .short
            formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : (seconds >= 60 ? [.minute] : [.second])
            if let remaining = formatter.string(from: max(1, seconds)) { text += " · 剩余 \(remaining)" }
        }
        return text
    }

    private func statusText(_ job: WorkshopDownloadJob) -> String {
        let size = job.totalBytes.map { " · " + FileSizeText.string($0) } ?? ""
        switch job.state {
        // 同一批里逐个下载，还没轮到的显示为等待
        case .downloading: return "等待下载（本批次）" + size
        case .queued: return "排队中" + size
        default: return job.state.label + size
        }
    }

    @ViewBuilder
    private func controls(_ job: WorkshopDownloadJob) -> some View {
        HStack(spacing: 8) {
            switch job.state {
            case .queued, .downloading:
                Button("暂停") { workshop.pauseDownload(job.id) }
                Button("停止") { workshop.cancelDownload(job.id) }
            case .paused:
                Button("恢复") { workshop.resumeDownload(job.id) }
                Button("停止") { workshop.cancelDownload(job.id) }
            case .failed, .cancelled:
                Button("重试") { workshop.resumeDownload(job.id) }
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .none:
                EmptyView()
            }
        }
        .controlSize(.small)
    }
}

/// 主界面浮层用和筛选面板一致的玻璃卡片；独立窗口用原生磨砂背景
private struct DownloadsBackground: ViewModifier {
    let inWindowPanel: Bool

    func body(content: Content) -> some View {
        if inWindowPanel {
            content.scenaFrostedPanel()
        } else {
            content
                .background { ScenaFrostedBackground().ignoresSafeArea() }
        }
    }
}


/// 内容保持挂载，收起期间只缩小顶部对齐的可见高度，不会提前移除行。
private struct DownloadSectionReveal<Content: View>: View {
    let isExpanded: Bool
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if contentHeight != height { contentHeight = height }
            }
            .frame(height: isExpanded ? contentHeight : 0, alignment: .top)
            .clipped()
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)
            .animation(Motion.reducesMotion ? nil : Motion.disclosure, value: isExpanded)
            .animation(Motion.reducesMotion ? nil : Motion.disclosure, value: contentHeight)
    }
}
