import Foundation
import Testing
@testable import wallhaven

@MainActor struct SourceVerificationRecoveryTests {
    private let preferences = TestDefaults()
    private func item(_ id: String = "1254") -> RemoteWallpaper {
        RemoteWallpaper(id: "wallsflow-\(id)", sourceID: "wallsflow", pageURL: URL(string: "https://wallsflow.com/live-wallpapers/cars/\(id)-test.html")!,
                        imageURL: URL(string: "https://wallsflow.com/index.php?do=download&id=1771")!, thumbURL: nil, mediaType: .video)
    }
    private func challenge() -> CloudflareChallengeRequiredError {
        .init(domain: "wallsflow.com", challengeURL: item().pageURL)
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CocoaError(.coderValueNotFound)
    }

    @Test func downloadAndApplyResumeOriginalItemAfterActualSheetDismissal() async throws {
        for apply in [false, true] {
            var calls: [String] = [], applied = 0
            let blocked = challenge(), wallpaper = item()
            let model = WallpaperViewModel(discoveryDefaults: preferences.make(), searchLoader: { _, _ in [] }, downloadLoader: { wallpaper in
                calls.append(wallpaper.id)
                if calls.count == 1 { throw blocked }
                return URL(fileURLWithPath: "/private/tmp/audit-original.mp4")
            }, applyDownloaded: { _ in applied += 1 }, manualApplyAction: {})
            if apply { model.downloadAndApply(wallpaper) } else { model.downloadImage(wallpaper) }
            try await waitFor { model.pendingCloudflareChallenge != nil && model.downloadingIDs.isEmpty }
            let presented = try #require(model.pendingCloudflareChallenge)
            model.cloudflareVerificationSucceeded(presented.id)
            #expect(calls.count == 1)
            model.cloudflareVerificationDismissed()
            try await waitFor { calls.count == 2 && model.downloadingIDs.isEmpty }
            #expect(calls == [wallpaper.id, wallpaper.id])
            #expect(applied == (apply ? 1 : 0))
            #expect(model.downloadedIDs.contains(wallpaper.id))
        }
    }

    @Test func cancellingSheetDoesNotRetryDownload() async throws {
        var attempts = 0
        let blocked = challenge()
        let model = WallpaperViewModel(discoveryDefaults: preferences.make(), searchLoader: { _, _ in [] }, downloadLoader: { _ in
            attempts += 1; throw blocked
        })
        model.downloadImage(item())
        try await waitFor { model.pendingCloudflareChallenge != nil && model.downloadingIDs.isEmpty }
        model.pendingCloudflareChallenge = nil
        model.cloudflareVerificationDismissed()
        await Task.yield()
        #expect(attempts == 1 && model.pendingCloudflareChallenge == nil)
    }

    @Test func repeatedDownloadChallengeDoesNotCreateAnAutomaticModalLoop() async throws {
        var attempts = 0
        let blocked = challenge()
        let model = WallpaperViewModel(discoveryDefaults: preferences.make(), searchLoader: { _, _ in [] }, downloadLoader: { _ in
            attempts += 1; throw blocked
        })
        model.downloadImage(item())
        try await waitFor { model.pendingCloudflareChallenge != nil && model.downloadingIDs.isEmpty }
        let presented = try #require(model.pendingCloudflareChallenge)
        model.cloudflareVerificationSucceeded(presented.id)
        model.cloudflareVerificationDismissed()
        try await waitFor { attempts == 2 && model.downloadingIDs.isEmpty }
        #expect(model.pendingCloudflareChallenge == nil)
    }

    @Test func changedSearchCannotResumeOldQueryAfterVerification() async throws {
        var queries: [String] = []
        let blocked = challenge()
        let model = WallpaperViewModel(discoveryDefaults: preferences.make(), searchLoader: { request, _ in
            queries.append(request.text)
            if request.text == "old" { throw blocked }
            return []
        })
        model.query = "old"; model.search(reset: true)
        try await waitFor { model.pendingCloudflareChallenge != nil && !model.isLoading }
        let old = try #require(model.pendingCloudflareChallenge)
        model.query = "new"; model.search(reset: true)
        try await waitFor { queries.contains("new") && !model.isLoading }
        model.cloudflareVerificationSucceeded(old.id)
        model.cloudflareVerificationDismissed()
        await Task.yield()
        #expect(queries == ["old", "new"])
    }

    @Test func verifiedSearchRetriesExactlyTheBlockedPage() async throws {
        var pages: [Int] = [], verified = false
        let wallpaper = item(), blocked = challenge()
        let model = WallpaperViewModel(discoveryDefaults: preferences.make(), searchLoader: { _, page in
            pages.append(page)
            if page == 1 { return [wallpaper] }
            if !verified { throw blocked }
            return []
        })
        model.search(reset: true)
        try await waitFor { !model.isLoading }
        model.loadNextPage()
        try await waitFor { model.pendingCloudflareChallenge != nil && !model.isLoading }
        let presented = try #require(model.pendingCloudflareChallenge)
        verified = true
        model.cloudflareVerificationSucceeded(presented.id)
        model.cloudflareVerificationDismissed()
        try await waitFor { pages.count == 3 && !model.isLoading }
        #expect(pages == [1, 2, 2])
    }
}
