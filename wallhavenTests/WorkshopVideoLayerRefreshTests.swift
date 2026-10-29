import AppKit
import AVFoundation
import CoreVideo
import Testing
import WebKit
@testable import wallhaven

/// 视频画面层刷新：偏移 1/32 像素迫使 WebKit 重算视频层，之后原样还原作者样式
@MainActor @Suite(.serialized)
struct WorkshopVideoLayerRefreshTests {
    private let testDefaults = TestDefaults()

    @Test func refreshNudgesVideoLayerAndRestoresAuthorStyle() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await makeMovie(at: folder.appendingPathComponent("clip.mov"))
        try Data(#"{"type":"web","file":"index.html","title":"Layer refresh"}"#.utf8).write(to: folder.appendingPathComponent("project.json"))
        let html = """
        <!doctype html><html><head><style>
        html,body {margin:0;width:100%;height:100%;overflow:hidden}
        video {position:absolute;inset:0;width:100%;height:100%;object-fit:contain}
        </style></head><body>
        <video id="authored" src="clip.mov" muted autoplay loop playsinline style="object-position: left top"></video>
        <video id="plain" src="clip.mov" muted autoplay loop playsinline></video>
        <script>window.ready = true;</script></body></html>
        """
        try html.write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let item = try #require(WorkshopItem.load(from: folder, computeSize: false))
        let player = WorkshopPlayerNSView(item: item, storage: WorkshopWebStorage(scope: folder.path, defaults: testDefaults.make()))
        let window = WallpaperDesktopWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                                            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = player
        window.orderFront(nil)
        defer { player.stop(); window.orderOut(nil); window.contentView = nil; window.close() }

        var loaded: WKFrameInfo?
        for _ in 0..<240 {
            for frame in player.documentFrames where !frame.isMainFrame {
                let ready = try? await player.evaluateJavaScript(
                    "window.ready && [...document.querySelectorAll('video')].every(v => v.videoWidth > 0)", in: frame)
                if ready as? Bool == true { loaded = frame }
            }
            if loaded != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let frame = try #require(loaded, "Video failed to load: \(player.runtimeErrors)")
        // 等读到尺寸时触发的那次刷新结束
        try await Task.sleep(for: .milliseconds(400))
        let inline = "JSON.stringify([...document.querySelectorAll('video')].map(v => v.style.getPropertyValue('object-position')))"
        #expect(try await player.evaluateJavaScript(inline, in: frame) as? String == #"["left top",""]"#)

        _ = try await player.evaluateJavaScript("window.__scenaRefreshMedia(); void 0", in: frame)
        let nudged = try #require(try await player.evaluateJavaScript(inline, in: frame) as? String)
        #expect(nudged.components(separatedBy: "0.03125px").count == 3, "both videos shifted: \(nudged)")

        try await Task.sleep(for: .milliseconds(400))
        #expect(try await player.evaluateJavaScript(inline, in: frame) as? String == #"["left top",""]"#)
        #expect(player.runtimeErrors.isEmpty)
    }

    private func makeMovie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 160, 90, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 128, CVPixelBufferGetBytesPerRow(pixels) * CVPixelBufferGetHeight(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<60 {
            for _ in 0..<200 {
                if input.isReadyForMoreMediaData { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(input.isReadyForMoreMediaData)
            try #require(adapter.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 6, preferredTimescale: 600))
        await writer.finishWriting()
        try #require(writer.status == .completed)
    }
}
