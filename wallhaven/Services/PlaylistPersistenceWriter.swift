import Foundation

/// 编码与落盘使用串行后台队列；同步退出保存也走同一队列，保证写入顺序。
nonisolated final class PlaylistPersistenceWriter: Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "com.scena.playlist-persistence", qos: .utility)

    init(url: URL) { self.url = url }

    func enqueue(_ snapshot: [Playlist]) {
        queue.async { self.write(snapshot) }
    }

    func flush(_ snapshot: [Playlist]) {
        queue.sync { write(snapshot) }
    }

    private func write(_ snapshot: [Playlist]) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
