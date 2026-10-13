import SwiftUI

enum DownloadsWindow { static let id = "workshop-downloads" }

struct WorkshopDownloadsButton: View {
    @EnvironmentObject private var workshop: WorkshopViewModel
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help("下载任务")
        .popover(isPresented: $isPresented) {
            WorkshopDownloadsView()
                .environmentObject(workshop)
        }
    }
}

struct WorkshopDownloadsView: View {
    @EnvironmentObject private var workshop: WorkshopViewModel

    var body: some View {
        // 进度每秒刷新，单独放在子视图里观察
        WorkshopDownloadsList(progress: workshop.progress)
            .environmentObject(workshop)
    }
}

private struct WorkshopDownloadsList: View {
    @EnvironmentObject private var workshop: WorkshopViewModel
    @ObservedObject var progress: WorkshopDownloadProgress

    /// 进行中的排在前面，已完成的放到最后
    private var sortedJobs: [WorkshopDownloadJob] {
        func rank(_ job: WorkshopDownloadJob) -> Int {
            switch job.state {
            case .downloading: progress.entries[job.id] != nil ? 0 : 1
            case .queued: 2
            case .paused, .failed: 3
            case .cancelled: 4
            case .completed, .none: 5
            }
        }
        return workshop.downloadJobs.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

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
        // 不透明背景：玻璃材质透出明亮的壁纸时文字看不清
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ job: WorkshopDownloadJob) -> some View {
        let entry = progress.entries[job.id]
        return HStack(alignment: .center, spacing: 10) {
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
            Spacer(minLength: 8)
            controls(job)
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
