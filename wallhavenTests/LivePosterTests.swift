import AppKit
import AVFoundation
import CoreVideo
import ImageIO
import Testing
@testable import wallhaven

/// 锁屏、调度中心用的静态封面：视频类内容取画面帧，视频重新生成后封面跟着换，不沿用旧缓存
@MainActor @Suite(.serialized)
struct LivePosterTests {
    private func makeMovie(at url: URL, gray: UInt8) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), Int32(gray), CVPixelBufferGetBytesPerRow(pixels) * CVPixelBufferGetHeight(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<10 {
            for _ in 0..<200 {
                if input.isReadyForMoreMediaData { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(adapter.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
        await writer.finishWriting()
        try #require(writer.status == .completed)
    }

    @Test func videoPosterUsesVideoFrameAndFollowsRegeneratedVideo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appendingPathComponent("clip.mov")
        try await makeMovie(at: video, gray: 200)
        let content = LiveContent(kind: .video, path: video.path, title: "clip")

        let first = try await LiveWallpaperController.makePoster(for: content)
        defer { try? FileManager.default.removeItem(at: first) }
        #expect(first.lastPathComponent.hasPrefix("poster-v3-"))
        let source = try #require(CGImageSourceCreateWithURL(first as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 320 && image.height == 180)
        // 没变就复用
        #expect(try await LiveWallpaperController.makePoster(for: content) == first)

        // 视频被重新生成（修改时间变了）：换一个文件名重新取帧，旧封面清掉
        try FileManager.default.removeItem(at: video)
        try await makeMovie(at: video, gray: 60)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: video.path)
        let second = try await LiveWallpaperController.makePoster(for: content)
        defer { try? FileManager.default.removeItem(at: second) }
        #expect(second != first)
        #expect(!FileManager.default.fileExists(atPath: first.path))
    }
}
