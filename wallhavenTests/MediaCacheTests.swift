import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import Testing
@testable import wallhaven

private actor PosterGenerationCounter {
    private(set) var calls = 0
    private(set) var active = 0
    private(set) var maximum = 0

    func generate(_ request: VideoPosterRequest) async throws -> Data {
        calls += 1
        active += 1
        maximum = max(maximum, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(20))
        return Data(request.cacheKey.utf8)
    }
}

private actor SuspendedPosterGeneration {
    private(set) var started = false
    private var continuation: CheckedContinuation<Data, Never>?
    func generate() async -> Data {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func resume() { continuation?.resume(returning: Data("poster".utf8)); continuation = nil }
}

@MainActor
@Suite(.serialized)
struct MediaCacheTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func visibleConsumersShareGenerationAndDiskCacheSurvivesRestart() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("video.mov")
        try Data([1]).write(to: input)
        let counter = PosterGenerationCounter()
        let disk = folder.appendingPathComponent("cache")
        let cache = VideoPosterCache(directory: disk, generator: { try await counter.generate($0) })
        let request = VideoPosterRequest(url: input, tier: .list)
        let first = Task { try await cache.data(for: request) }
        let second = Task { try await cache.data(for: request) }
        // 一个离屏消费者取消，不能让另一个可见消费者失去封面。
        first.cancel()
        let a = try await first.value
        let b = try await second.value
        #expect(a == b)
        #expect(await counter.calls == 1)
        let restarted = VideoPosterCache(directory: disk, generator: { try await counter.generate($0) })
        #expect(try await restarted.data(for: request) == b)
        #expect(await counter.calls == 1)
    }

    @Test func tiersAndReplacedFileNeverShareStalePoster() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("video.mov")
        try Data([1]).write(to: input)
        let old = VideoPosterRequest(url: input, tier: .list)
        let large = VideoPosterRequest(url: input, tier: .poster)
        #expect(old.cacheKey != large.cacheKey)
        try Data([1, 2, 3]).write(to: input)
        let replaced = VideoPosterRequest(url: input, tier: .list)
        #expect(replaced.cacheKey != old.cacheKey)
        let counter = PosterGenerationCounter()
        let cache = VideoPosterCache(directory: folder.appendingPathComponent("cache"), generator: { try await counter.generate($0) })
        await #expect(throws: CocoaError.self) { try await cache.data(for: old) }
        _ = try await cache.data(for: replaced)
        #expect(await cache.diskSize() > 0)
    }

    @Test func manyVideosUseAtMostTwoGenerators() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let counter = PosterGenerationCounter()
        let cache = VideoPosterCache(directory: folder.appendingPathComponent("cache"), generator: { try await counter.generate($0) })
        var requests: [VideoPosterRequest] = []
        for number in 0..<10 {
            let input = folder.appendingPathComponent("\(number).mov")
            try Data([1]).write(to: input)
            requests.append(VideoPosterRequest(url: input, tier: .list))
        }
        try await withThrowingTaskGroup(of: Data.self) { group in
            for request in requests { group.addTask { try await cache.data(for: request) } }
            for try await _ in group {}
        }
        #expect(await counter.calls == 10)
        #expect(await counter.maximum == 2)
    }

    @Test func clearingDuringGenerationCannotRepopulateCache() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("video.mov")
        try Data([1]).write(to: input)
        let gate = SuspendedPosterGeneration()
        let cache = VideoPosterCache(directory: folder.appendingPathComponent("cache"), generator: { _ in await gate.generate() })
        let task = Task { try await cache.data(for: VideoPosterRequest(url: input, tier: .list)) }
        for _ in 0..<100 {
            if await gate.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.started)
        await cache.clear()
        await gate.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await cache.diskSize() == 0)
    }

    @Test func posterStorageIsBoundedAndCanBeCleared() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = VideoPosterCache(directory: folder.appendingPathComponent("cache"), sizeLimit: 15, generator: { _ in Data(repeating: 1, count: 10) })
        for number in 0..<4 {
            let input = folder.appendingPathComponent("\(number).mov")
            try Data([1]).write(to: input)
            _ = try await cache.data(for: VideoPosterRequest(url: input, tier: .list))
        }
        #expect(await cache.diskSize() <= 15)
        await cache.clear()
        #expect(await cache.diskSize() == 0)
    }

    @Test func fourKVideoProducesBoundedListAndPosterImages() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("4k.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 3840, AVVideoHeightKey: 2160])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 3840, 2160, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 128, CVPixelBufferGetBytesPerRow(pixels) * CVPixelBufferGetHeight(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<2 {
            for _ in 0..<200 {
                if input.isReadyForMoreMediaData { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(input.isReadyForMoreMediaData)
            try #require(adapter.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 2)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
        await writer.finishWriting()
        try #require(writer.status == .completed, "\(String(describing: writer.error))")
        for tier in [VideoPosterTier.list, .poster] {
            let data = try await VideoPosterCache.generate(VideoPosterRequest(url: url, tier: tier))
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width <= tier.maxPixelSize && image.height <= tier.maxPixelSize)
            #expect(image.width > image.height)
            #expect(image.width >= tier.maxPixelSize - 2)
        }
    }
}
