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
                .foregroundStyle(.white.opacity(0.85))
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

    // 始终保持入队顺序；暂停、完成与进度变化只更新原来的行，避免按钮移位。
    private var sortedJobs: [WorkshopDownloadJob] { workshop.downloadJobs }

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
            if workshop.downloadJobs.isEmpty {
                ContentUnavailableView("暂无下载任务", systemImage: "arrow.down.circle")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sortedJobs) { job in
                            row(job)
                                .padding(.vertical, 9)
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 440, height: 420)
        .modifier(DownloadsBackground(inWindowPanel: onNavigate != nil))
        .environment(\.colorScheme, .dark)
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
                if job.state == .downloading, let entry {
                    if let fraction = entry.fraction {
                        ProgressView(value: fraction).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                    Text(progressText(entry))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
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
        return "\(done) / \(FileSizeText.string(total)) · \(Int(fraction * 100))%"
    }

    private func statusText(_ job: WorkshopDownloadJob) -> String {
        let size = job.totalBytes.map { " · " + FileSizeText.string($0) } ?? ""
        switch job.state {
        // 同一批里 steamcmd 逐个下载，还没轮到的显示为等待
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
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            content
                .sceneGlass(in: shape, tint: .black.opacity(0.4))
                .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 0.5))
                .clipShape(shape)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        } else {
            content
                .background(Color.black.opacity(0.28))
                .background(DownloadsGlassBackground())
        }
    }
}

/// 独立窗口的原生磨砂背景，叠加深色底保证文字可读。
private struct DownloadsGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
