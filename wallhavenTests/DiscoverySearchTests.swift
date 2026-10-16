import Foundation
import Testing
@testable import wallhaven

@MainActor
@Suite(.serialized)
struct DiscoverySearchTests {
    private func wallpaper(_ id: String) throws -> RemoteWallpaper {
        let data = Data("""
        {"id":"\(id)","url":"https://wallhaven.cc/w/\(id)","path":"https://example.com/\(id).jpg","resolution":"1920x1080","category":"general","favorites":1,"ratio":"1.777","purity":"sfw"}
        """.utf8)
        return try JSONDecoder().decode(RemoteWallpaper.self, from: data)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestTimeout()
    }

    private struct TestTimeout: Error {}

    @Test func staleEmptyResultCannotEndNewSearchOrChangeItsPagination() async throws {
        let service = ControlledSearch()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let model = WallpaperViewModel(discoveryDefaults: defaults, searchLoader: service.load)
        model.query = "seed"; model.search(reset: true)
        try await waitUntil { service.pending["seed:1"] != nil }
        service.finish("seed:1", with: .success([try wallpaper("seed01")]))
        try await waitUntil { !model.isLoading }
        model.query = "old"; model.search(reset: true)
        try await waitUntil { service.pending["old:1"] != nil }
        model.query = "new"; model.search(reset: true)
        try await waitUntil { service.pending["new:1"] != nil }
        #expect(model.wallpapers.map(\.id) == ["seed01"])
        service.finish("old:1", with: .success([]))
        try await Task.sleep(for: .milliseconds(40))
        #expect(model.isLoading)
        #expect(model.wallpapers.map(\.id) == ["seed01"])
        service.finish("new:1", with: .success([try wallpaper("new001")]))
        try await waitUntil { !model.isLoading }
        #expect(model.wallpapers.map(\.id) == ["new001"])
        model.loadNextPage()
        try await waitUntil { service.pending["new:2"] != nil }
        service.finish("new:2", with: .success([]))
        try await waitUntil { !model.isLoading }
    }

    @Test func lateFailureDoesNotOverwriteNewResultsOrErrorState() async throws {
        let service = ControlledSearch()
        let model = WallpaperViewModel(discoveryDefaults: UserDefaults(suiteName: UUID().uuidString)!, searchLoader: service.load)
        model.query = "old"; model.search(reset: true)
        try await waitUntil { service.pending["old:1"] != nil }
        model.query = "new"; model.search(reset: true)
        try await waitUntil { service.pending["new:1"] != nil }
        service.finish("new:1", with: .success([try wallpaper("new001")]))
        try await waitUntil { !model.isLoading }
        service.finish("old:1", with: .failure(CocoaError(.fileReadUnknown)))
        try await Task.sleep(for: .milliseconds(40))
        #expect(model.wallpapers.map(\.id) == ["new001"])
        #expect(model.loadError == nil)
        #expect(model.errorMessage == nil)
        #expect(!model.isLoading)
    }

    @Test func rapidFilterChangesSubmitOnlyTheFinalSnapshot() async throws {
        let service = ControlledSearch()
        let model = WallpaperViewModel(discoveryDefaults: UserDefaults(suiteName: UUID().uuidString)!, searchLoader: service.load)
        model.query = "first"; model.search(reset: true, debounce: true)
        model.query = "second"; model.search(reset: true, debounce: true)
        let categories = try #require(model.descriptor.filters.first { $0.id == "categories" })
        model.query = "final"; model.toggle(categories.options.first { $0.id == "anime" }, in: categories)
        #expect(service.requests.isEmpty)
        try await waitUntil { service.pending["final:1"] != nil }
        #expect(service.requests.count == 1)
        #expect(service.requests.first?.selection("categories") == ["general", "people"])
        service.finish("final:1", with: .success([]))
        try await waitUntil { !model.isLoading }
    }

    @Test func failedReplacementPreservesContentAndRetriesFirstPage() async throws {
        let service = ControlledSearch()
        let model = WallpaperViewModel(discoveryDefaults: UserDefaults(suiteName: UUID().uuidString)!, searchLoader: service.load)
        model.query = "seed"; model.search(reset: true)
        try await waitUntil { service.pending["seed:1"] != nil }
        service.finish("seed:1", with: .success([try wallpaper("seed01")]))
        try await waitUntil { !model.isLoading }
        model.query = "new"; model.search(reset: true)
        try await waitUntil { service.pending["new:1"] != nil }
        service.finish("new:1", with: .failure(CocoaError(.fileReadUnknown)))
        try await waitUntil { !model.isLoading }
        #expect(model.wallpapers.map(\.id) == ["seed01"])
        #expect(model.loadError != nil)
        model.retryLoading()
        try await waitUntil { service.pending["new:1"] != nil }
        service.finish("new:1", with: .success([]))
        try await waitUntil { !model.isLoading }
        #expect(model.wallpapers.isEmpty)
    }
}

/// 故意忽略任务取消，复现网络回调在新搜索完成后才返回的情况。
@MainActor
private final class ControlledSearch {
    var pending: [String: CheckedContinuation<[RemoteWallpaper], Error>] = [:]
    var requests: [WallpaperQuery] = []
    func load(_ request: WallpaperQuery, page: Int) async throws -> [RemoteWallpaper] {
        requests.append(request)
        return try await withCheckedThrowingContinuation { pending["\(request.text):\(page)"] = $0 }
    }
    func finish(_ key: String, with result: Result<[RemoteWallpaper], Error>) {
        pending.removeValue(forKey: key)?.resume(with: result)
    }
}
