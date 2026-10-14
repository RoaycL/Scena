import Foundation
import Testing
@testable import wallhaven

@MainActor
@Suite(.serialized)
struct PlaylistPlaybackTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.coderInvalidValue)
    }

    private func fixture() throws -> (PlaylistManager, ControlledPlayback, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let service = ControlledPlayback()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let manager = PlaylistManager(storageURL: folder.appendingPathComponent("playlists.json"),
                                      playbackDefaults: defaults, applier: service.apply)
        return (manager, service, folder)
    }

    private func entry(_ name: String, in folder: URL) throws -> PlaylistEntry {
        try #require(PlaylistEntry(GalleryItem(origin: .local(LocalMediaItem(
            url: folder.appendingPathComponent("\(name).jpg"),
            creationDate: .distantPast, fileSize: 0, source: .imported)))))
    }

    @Test func lateSuccessCannotReplaceNextOrPrevious() async throws {
        let (manager, service, folder) = try fixture()
        defer { manager.stop(); try? FileManager.default.removeItem(at: folder) }
        let entries = try [entry("a", in: folder), entry("b", in: folder), entry("c", in: folder)]
        let list = manager.create(entries: entries)
        service.suspended = [entries[0].id]
        manager.play(list.id)
        try await waitUntil { service.pending[entries[0].id] != nil }
        manager.next()
        try await waitUntil { service.applied == [entries[1].id] }
        service.finish(entries[0].id)
        try await waitUntil { service.finished.contains(entries[0].id) }
        #expect(service.applied == [entries[1].id])
        #expect(manager.currentEntryID == entries[1].id)
        service.suspended = [entries[2].id]
        manager.next()
        try await waitUntil { service.pending[entries[2].id] != nil }
        manager.previous()
        try await waitUntil { service.applied.count == 2 }
        service.finish(entries[2].id)
        try await waitUntil { service.finished.contains(entries[2].id) }
        #expect(service.applied == [entries[1].id, entries[1].id])
        #expect(manager.currentEntryID == entries[1].id)
    }

    @Test func stopCancelsPendingApplication() async throws {
        let (manager, service, folder) = try fixture()
        defer { manager.stop(); try? FileManager.default.removeItem(at: folder) }
        let a = try entry("a", in: folder)
        let list = manager.create(entries: [a])
        service.suspended = [a.id]
        manager.play(list.id)
        try await waitUntil { service.pending[a.id] != nil }
        manager.stop()
        service.finish(a.id)
        try await waitUntil { service.finished.contains(a.id) }
        #expect(service.applied.isEmpty)
        #expect(manager.activeID == nil && manager.currentEntryID == nil)
    }

    @Test func oldFailureCannotStopAnotherPlaylist() async throws {
        let (manager, service, folder) = try fixture()
        defer { manager.stop(); try? FileManager.default.removeItem(at: folder) }
        let a = try entry("a", in: folder), b = try entry("b", in: folder)
        let first = manager.create(entries: [a]), second = manager.create(entries: [b])
        service.suspended = [a.id]
        manager.play(first.id)
        try await waitUntil { service.pending[a.id] != nil }
        manager.play(second.id)
        try await waitUntil { service.applied == [b.id] }
        service.finish(a.id, error: CocoaError(.fileReadUnknown))
        try await waitUntil { service.finished.contains(a.id) }
        #expect(manager.activeID == second.id && manager.currentEntryID == b.id)
        #expect(service.applied == [b.id])
    }

    @Test func currentFailureSkipsAndAllFailuresStop() async throws {
        let (manager, service, folder) = try fixture()
        defer { manager.stop(); try? FileManager.default.removeItem(at: folder) }
        let a = try entry("a", in: folder), b = try entry("b", in: folder)
        let list = manager.create(entries: [a, b])
        service.failures = [a.id]
        manager.play(list.id)
        try await waitUntil { service.applied == [b.id] }
        #expect(manager.activeID == list.id && manager.currentEntryID == b.id)
        service.failures = [a.id, b.id]
        manager.play(list.id)
        try await waitUntil { manager.activeID == nil }
        #expect(manager.currentEntryID == nil)
    }

    @Test func deletingActiveListCancelsItsPendingApplication() async throws {
        let (manager, service, folder) = try fixture()
        defer { manager.stop(); try? FileManager.default.removeItem(at: folder) }
        let a = try entry("a", in: folder)
        let list = manager.create(entries: [a])
        service.suspended = [a.id]
        manager.play(list.id)
        try await waitUntil { service.pending[a.id] != nil }
        manager.delete(list.id)
        service.finish(a.id)
        try await waitUntil { service.finished.contains(a.id) }
        #expect(service.applied.isEmpty && manager.activeID == nil)
    }
}

/// 下载模拟器故意忽略取消；真正应用前按生产路径再次检查取消。
@MainActor
private final class ControlledPlayback {
    var pending: [String: CheckedContinuation<Void, Error>] = [:]
    var suspended = Set<String>()
    var failures = Set<String>()
    var applied: [String] = []
    var finished = Set<String>()

    func apply(_ entry: PlaylistEntry) async throws {
        defer { finished.insert(entry.id) }
        if suspended.contains(entry.id) {
            try await withCheckedThrowingContinuation { pending[entry.id] = $0 }
        }
        if failures.contains(entry.id) { throw CocoaError(.fileReadUnknown) }
        try Task.checkCancellation()
        applied.append(entry.id)
    }

    func finish(_ id: String, error: Error? = nil) {
        let continuation = pending.removeValue(forKey: id)
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }
}
