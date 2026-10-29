import Foundation
import Kingfisher
import Testing
@testable import wallhaven

struct WorkshopUpdateTests {
    private func fixture(_ root: URL, name: String, bytes: UInt8 = 1) throws -> URL {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"workshopid":"12345","type":"video","title":"test","file":"video.mp4","preview":"preview.jpg"}"#.utf8)
            .write(to: folder.appendingPathComponent("project.json"))
        try Data(repeating: bytes, count: 100).write(to: folder.appendingPathComponent("video.mp4"))
        try Data([bytes]).write(to: folder.appendingPathComponent("preview.jpg"))
        return folder
    }

    @Test func exactManifestIDsAndTimestampFallback() throws {
        let version = try #require(WorkshopContentVersion(json: ["hcontent_file": "18446744073709551614", "time_updated": "200"]))
        #expect(version.manifestID == "18446744073709551614")
        #expect(WorkshopUpdateStatus.compare(remote: version, installed: version) == .current)
        #expect(WorkshopUpdateStatus.compare(remote: version, installed: .init(manifestID: "18446744073709551613", updatedAt: 200)) == .available)
        #expect(WorkshopUpdateStatus.compare(remote: version, installed: .init(updatedAt: 199)) == .available)
        #expect(WorkshopUpdateStatus.compare(remote: version, installed: .init(updatedAt: 201)) == .current)
        #expect(WorkshopUpdateStatus.compare(remote: version, installed: .init(manifestID: "newer", updatedAt: 201)) == .current)
        #expect(WorkshopUpdateStatus.compare(remote: version, installed: nil) == .unverified)
        #expect(WorkshopContentVersion(json: ["manifestId": "0", "updatedAt": 0]) == nil)
    }

    @Test func legacyJobsAndReceiptsRemainReadable() throws {
        let data = Data(#"[{"id":"12345","title":"old","state":"completed","applyWhenDone":false}]"#.utf8)
        let jobs = try JSONDecoder().decode([WorkshopDownloadJob].self, from: data)
        #expect(jobs.first?.requiresValidation == nil)
        let receipt = try JSONDecoder().decode(WorkshopDownloadReceipt.self, from: Data(#"{"files":{}}"#.utf8))
        #expect(receipt.contentVersion == nil)
        let item = try JSONDecoder().decode(WorkshopItem.self, from: Data(#"{"id":"12345","title":"old","type":"video","tags":[],"fileSize":0,"subscriptions":0,"favorited":0}"#.utf8))
        #expect(item.contentVersion == nil && item.localRevision == nil)
    }

    @Test func updateIntentSurvivesRestartAndInterruption() throws {
        let job = WorkshopDownloadJob(id: "12345", title: "update", state: .downloading, requiresValidation: true)
        let saved = try JSONDecoder().decode([WorkshopDownloadJob].self, from: JSONEncoder().encode([job]))
        let restored = try #require(WorkshopDownloadQueue.restored(saved).first)
        #expect(restored.state == .paused && !restored.canCompleteLocally)
        #expect(restored.requiresValidation == true)
        let interrupted = WorkshopDownloadQueue.settle([job], batch: [job.id], downloaded: [], failures: [:], interrupted: true)
        #expect(interrupted.first?.state == .queued && interrupted.first?.canCompleteLocally == false)
        let done = WorkshopDownloadQueue.settle([job], batch: [job.id], downloaded: [job.id], failures: [:], interrupted: false)
        #expect(done.first?.state == .completed && done.first?.requiresValidation == nil)
    }

    @Test(arguments: [DownloadState.paused, .failed, .cancelled, .downloading, .queued])
    func automaticUpdatesRespectUserControlledJobs(state: DownloadState) {
        let job = WorkshopDownloadJob(id: "12345", title: "old", state: state)
        #expect(!WorkshopUpdateStatus.available.canEnqueue(job: job, automatic: true))
        #expect(!WorkshopUpdateStatus.unverified.canEnqueue(job: job, automatic: true))
        if [.paused, .queued, .downloading].contains(state) {
            #expect(!WorkshopUpdateStatus.available.canEnqueue(job: job, automatic: false))
        }
        #expect(!WorkshopUpdateStatus.current.canEnqueue(job: job, automatic: false))
    }

    @Test func completedJobsCanBeQueuedForNewContent() {
        let job = WorkshopDownloadJob(id: "12345", title: "old", state: .completed)
        #expect(WorkshopUpdateStatus.available.canEnqueue(job: job, automatic: true))
        #expect(WorkshopUpdateStatus.unverified.canEnqueue(job: nil, automatic: false))
    }

    @Test func inventoryDoesNotTrustLegacyOrLocallyModifiedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, name: "12345")
        let local = try #require(WorkshopItem.load(from: folder))
        var remote = local
        remote.localFolder = nil
        remote.contentVersion = .init(manifestID: "2", updatedAt: 200)
        let old = try #require(WorkshopDownloadReceipt.capture(folder: folder, contentVersion: .init(manifestID: "1", updatedAt: 100)))
        #expect(WorkshopUpdateInventory(local: [local], remote: [remote], receipts: [local.id: old]).statuses[local.id] == .available)
        let legacy = try #require(WorkshopDownloadReceipt.capture(folder: folder))
        #expect(WorkshopUpdateInventory(local: [local], remote: [remote], receipts: [local.id: legacy]).statuses[local.id] == .unverified)
        let current = try #require(WorkshopDownloadReceipt.capture(folder: folder, contentVersion: remote.contentVersion))
        #expect(current.matches(folder: folder))
        #expect(WorkshopUpdateInventory(local: [local], remote: [remote], receipts: [local.id: current]).statuses[local.id] == .current)
        try Data([9]).write(to: folder.appendingPathComponent("video.mp4"))
        #expect(WorkshopUpdateInventory(local: [local], remote: [remote], receipts: [local.id: current]).statuses[local.id] == .unverified)
        #expect(WorkshopUpdateInventory(local: [local], remote: [], receipts: [:]).statuses.isEmpty)
        try FileManager.default.removeItem(at: folder)
        #expect(WorkshopUpdateInventory(local: [local], remote: [remote], receipts: [:]).statuses.isEmpty)
    }

    @Test func failedInstallRestoresOriginalAndCanBeRetried() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try fixture(root, name: "installed", bytes: 1)
        let staged = try fixture(root, name: "staged", bytes: 2)
        let receipt = try #require(WorkshopDownloadReceipt.capture(folder: old))
        #expect(throws: CocoaError.self) {
            try WorkshopUpdateInstallation.install(staged: staged, destination: old) { source, target in
                if source == staged { throw CocoaError(.fileWriteOutOfSpace) }
                try FileManager.default.moveItem(at: source, to: target)
            }
        }
        #expect(receipt.matches(folder: old))
        #expect(FileManager.default.fileExists(atPath: staged.path))
        try WorkshopUpdateInstallation.install(staged: staged, destination: old)
        #expect(try Data(contentsOf: old.appendingPathComponent("video.mp4")) == Data(repeating: 2, count: 100))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["installed"])
    }

    @Test func incompleteUpdateCannotReplaceWorkingWallpaper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try fixture(root, name: "installed")
        let partial = root.appendingPathComponent("partial")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data(#"{"file":"video.mp4"}"#.utf8).write(to: partial.appendingPathComponent("project.json"))
        let receipt = try #require(WorkshopDownloadReceipt.capture(folder: old))
        #expect(throws: CocoaError.self) { try WorkshopUpdateInstallation.install(staged: partial, destination: old) }
        #expect(receipt.matches(folder: old))
    }

    @Test @MainActor func previewCacheChangesWhenSamePathIsReplaced() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, name: "12345")
        let before = try #require(WorkshopItem.load(from: folder))
        let oldKey = GalleryItem(origin: .workshop(before)).thumbnailSource?.cacheKey
        try Data(repeating: 9, count: 200).write(to: folder.appendingPathComponent("preview.jpg"))
        let after = try #require(WorkshopItem.load(from: folder))
        #expect(before.id == after.id && before.previewURL == after.previewURL)
        #expect(before.localRevision != after.localRevision)
        #expect(oldKey != GalleryItem(origin: .workshop(after)).thumbnailSource?.cacheKey)
    }

    @Test @MainActor func downloadProtocolReportsActuallyInstalledVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let content = root.appendingPathComponent("content")
        let folder = try fixture(content, name: "12345")
        let executable = root.appendingPathComponent("helper.py")
        let script = """
        #!/usr/bin/python3
        import json,sys
        print(json.dumps({'v':1,'type':'ready'}),flush=True)
        r=json.loads(sys.stdin.readline())
        print(json.dumps({'v':1,'id':r['id'],'type':'itemDone','itemId':'12345','folder':r['contentRoot']+'/12345','manifestId':'18446744073709551614','updatedAt':200}),flush=True)
        print(json.dumps({'v':1,'id':r['id'],'type':'done'}),flush=True)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let downloader = SteamContentDownloader(executable: executable)
        let result = try await downloader.download(ids: ["12345"], credential: .init(accountName: "fake", steamID: "0", refreshToken: "fake"),
            loginID: 1, contentRoot: content, stagingRoot: root.appendingPathComponent("staging")) { _ in }
        #expect(result.downloaded["12345"]?.path == folder.path)
        #expect(result.versions["12345"] == .init(manifestID: "18446744073709551614", updatedAt: 200))
    }
}
