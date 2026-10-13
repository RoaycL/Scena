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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("下载任务").font(.headline)
                Spacer()
                Text("\(workshop.downloading.count) 个进行中")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("全部暂停") { workshop.pauseAllDownloads() }
                    .disabled(workshop.downloading.isEmpty)
                Button("全部恢复") { workshop.resumeAllDownloads() }
                    .disabled(!workshop.downloadJobs.contains { $0.state == .paused })
                Spacer()
                Button("全部停止") { workshop.cancelAllDownloads() }
                    .disabled(!workshop.downloadJobs.contains { [.queued, .downloading, .paused, .failed].contains($0.state) })
            }
            .controlSize(.small)
            Text("暂停会保留已下载内容；恢复时继续校验和下载。停止后仍可手动重试。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if workshop.downloadJobs.isEmpty {
                ContentUnavailableView("暂无下载任务", systemImage: "arrow.down.circle")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(workshop.downloadJobs) { job in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(job.title).lineLimit(2)
                                    Text(job.state.label).font(.caption).foregroundStyle(.secondary)
                                    if let error = job.error {
                                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
                                    }
                                }
                                Spacer()
                                controls(job)
                            }
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 440, height: 400)
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
