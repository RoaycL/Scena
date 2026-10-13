//
//  wallhavenTests.swift
//  wallhavenTests
//
//  Created by RoaycL on 2026/4/17.
//

import Foundation
import Darwin
import Testing
@testable import wallhaven

struct wallhavenTests {

    @Test func approvedFilterUsesOfficialTagAndLocalMetadata() {
        var filters = WorkshopFilters()
        filters.features.insert("Approved")
        #expect(filters.requiredTags.contains("Approved"))
        let approved = WorkshopItem(id: "1", title: "A", type: .video, tags: ["Approved"])
        let ordinary = WorkshopItem(id: "2", title: "B", type: .video, tags: [])
        #expect(filters.matches(approved, query: ""))
        #expect(!filters.matches(ordinary, query: ""))
    }

    @Test func hidingAnimeExcludesRatherThanRequiresIt() {
        var filters = WorkshopFilters()
        filters.genres = ["Anime"]
        filters.hideAnime = true
        #expect(!filters.requiredTags.contains("Anime"))
        #expect(filters.excludedTags.contains("Anime"))
        let anime = WorkshopItem(id: "1", title: "A", type: .video, tags: ["Anime"])
        let nature = WorkshopItem(id: "2", title: "B", type: .video, tags: ["Nature"])
        #expect(!filters.matches(anime, query: ""))
        #expect(filters.matches(nature, query: ""))
        filters.hideAnime = false
        #expect(!filters.requiredTags.contains("Anime"))
        #expect(!filters.excludedTags.contains("Anime"))
        #expect(filters.matches(anime, query: ""))
        #expect(filters.matches(nature, query: ""))
    }

    @Test func oldFilterPreferencesSurviveUpgrade() throws {
        let old = Data(#"{"type":"video","ratings":["Mature"],"genres":["Nature"],"features":["Customizable"],"sort":"newest","trendDays":30}"#.utf8)
        let decoded = try JSONDecoder().decode(WorkshopFilters.self, from: old)
        #expect(!decoded.hideAnime)
        #expect(decoded.type == .video)
        #expect(decoded.ratings == [.mature])
        #expect(decoded.genres == ["Nature"])
        #expect(decoded.features == ["Customizable"])
        #expect(decoded.sort == .newest)
        #expect(decoded.trendDays == 30)
    }

    @Test func legacyAnimeOnlyPreferenceBecomesShowAnime() throws {
        let old = Data(#"{"genres":["Anime"],"hideAnime":false}"#.utf8)
        let filters = try JSONDecoder().decode(WorkshopFilters.self, from: old)
        #expect(filters.genres.isEmpty)
        #expect(!filters.hideAnime)
        #expect(!filters.requiredTags.contains("Anime"))
    }

    @Test func clickingAnimeTagOnlyRestoresVisibility() {
        var filters = WorkshopFilters()
        filters.genres = ["Nature"]
        filters.hideAnime = true
        filters.selectGenre("Anime")
        #expect(!filters.hideAnime)
        #expect(filters.genres == ["Nature"])
        #expect(!filters.requiredTags.contains("Anime"))
    }

    @Test func newPreferencesPersistAndReset() throws {
        var filters = WorkshopFilters()
        filters.hideAnime = true
        filters.features.insert("Approved")
        let decoded = try JSONDecoder().decode(WorkshopFilters.self, from: JSONEncoder().encode(filters))
        #expect(decoded == filters)
        #expect(decoded.activeCount == 2)
        filters = WorkshopFilters()
        #expect(filters.isDefault)
        #expect(!filters.hideAnime && !filters.requiredTags.contains("Approved"))
    }

    @Test func stoppingWrapperAlsoClosesChildOutput() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 3 & echo started; wait"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        defer { if process.isRunning { SteamCMDDownloader.terminateProcessTree(process) } }
        try await Task.sleep(for: .milliseconds(100))
        let start = Date()
        SteamCMDDownloader.terminateProcessTree(process)
        process.waitUntilExit()
        // 子进程继承 stdout；如果只停止 shell，读取会等到 sleep 自己结束。
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func partialBatchReportsEveryRequestedID() throws {
        let result = try SteamCMDDownloader.parse(output: "Success. Downloaded item 123 to \"/tmp/123\" (456 bytes)", ids: ["123", "456", "789"])
        #expect(result.downloaded["123"] != nil)
        #expect(result.failed["456"] != nil)
        #expect(result.failed["789"] != nil)
        #expect(result.downloaded.count + result.failed.count == 3)
    }

    @Test func explicitFailureSurvivesPartialSuccess() throws {
        let result = try SteamCMDDownloader.parse(output: """
        Success. Downloaded item 123 to "/tmp/123" (456 bytes)
        ERROR! Download item 456 failed (Access Denied).
        """, ids: ["123", "456", "789"])
        #expect(result.failed["456"] == "Access Denied")
        #expect(result.failed["789"] != nil)
    }

    @Test func interruptionPreservesOtherJobsAndCancellation() {
        let jobs = [
            WorkshopDownloadJob(id: "1", title: "A", state: .completed),
            WorkshopDownloadJob(id: "2", title: "B", state: .cancelled),
            WorkshopDownloadJob(id: "3", title: "C", state: .downloading),
            WorkshopDownloadJob(id: "4", title: "D", state: .paused)
        ]
        let settled = WorkshopDownloadQueue.settle(jobs, batch: ["1", "2", "3", "4"], downloaded: ["1"], failures: [:], interrupted: true)
        #expect(settled.map(\.state) == [.completed, .cancelled, .queued, .paused])
    }

    @Test func ordinaryFailureDoesNotAutomaticallyRetry() {
        let jobs = [WorkshopDownloadJob(id: "1", title: "A", state: .downloading)]
        let settled = WorkshopDownloadQueue.settle(jobs, batch: ["1"], downloaded: [], failures: ["1": "网络中断"], interrupted: false)
        #expect(settled[0].state == .failed)
        #expect(settled[0].error == "网络中断")
    }

    @Test func resumeWhileBatchExitsKeepsRetryIntent() {
        let jobs = [WorkshopDownloadJob(id: "1", title: "A", state: .queued)]
        let settled = WorkshopDownloadQueue.settle(jobs, batch: ["1"], downloaded: [], failures: ["1": "已中断"], interrupted: true)
        #expect(settled[0].state == .queued)
        #expect(settled[0].error == nil)
    }

    @Test func cancelledJobIsNotRevivedByLateSuccess() {
        let jobs = [WorkshopDownloadJob(id: "1", title: "A", state: .cancelled)]
        let settled = WorkshopDownloadQueue.settle(jobs, batch: ["1"], downloaded: ["1"], failures: [:], interrupted: true)
        #expect(settled[0].state == .cancelled)
    }

    @Test func restartRestoresUnfinishedJobsWithoutApplyingWallpaper() throws {
        let jobs = [
            WorkshopDownloadJob(id: "1", title: "A", state: .downloading, applyWhenDone: true),
            WorkshopDownloadJob(id: "2", title: "B", state: .queued),
            WorkshopDownloadJob(id: "3", title: "C", state: .failed, error: "失败"),
            WorkshopDownloadJob(id: "4", title: "D", state: .cancelled)
        ]
        let saved = try JSONEncoder().encode(jobs)
        let restored = WorkshopDownloadQueue.restored(try JSONDecoder().decode([WorkshopDownloadJob].self, from: saved))
        #expect(restored.map(\.state) == [.paused, .paused, .failed, .cancelled])
        #expect(!restored[0].applyWhenDone)
        #expect(restored[2].error == "失败")
    }

    @Test func wallhavenFileNamesAreRecognizedBySixCharacterID() {
        #expect(LocalMediaViewModel.isWallhavenFileName(URL(fileURLWithPath: "/w/l8vp7y.jpg")))
        #expect(LocalMediaViewModel.isWallhavenFileName(URL(fileURLWithPath: "/w/zyxvqy.png")))
        #expect(!LocalMediaViewModel.isWallhavenFileName(URL(fileURLWithPath: "/w/DynamicWallpaper_7.mp4")))
        #expect(!LocalMediaViewModel.isWallhavenFileName(URL(fileURLWithPath: "/w/IMG001.jpg")))
        #expect(!LocalMediaViewModel.isWallhavenFileName(URL(fileURLWithPath: "/w/abc12.jpg")))
    }

    @Test func librarySourceFilterSeparatesOrigins() {
        let wallhaven = GalleryItem(origin: .local(LocalMediaItem(url: URL(fileURLWithPath: "/w/l8vp7y.jpg"), creationDate: .now, fileSize: 1, source: .wallhaven)))
        let imported = GalleryItem(origin: .local(LocalMediaItem(url: URL(fileURLWithPath: "/w/Imported/a.mp4"), creationDate: .now, fileSize: 1, source: .imported)))
        let workshop = GalleryItem(origin: .workshop(WorkshopItem(id: "1", title: "W", type: .scene, tags: [])))
        #expect(LibrarySource.wallhaven.matches(wallhaven) && !LibrarySource.wallhaven.matches(imported))
        #expect(LibrarySource.imported.matches(imported) && !LibrarySource.imported.matches(workshop))
        #expect(LibrarySource.workshop.matches(workshop) && !LibrarySource.workshop.matches(wallhaven))
        #expect([wallhaven, imported, workshop].allSatisfy(LibrarySource.all.matches))
    }
}
