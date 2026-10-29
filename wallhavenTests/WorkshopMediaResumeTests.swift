import AppKit
import AVFoundation
import CoreVideo
import Testing
import WebKit
@testable import wallhaven

@MainActor @Suite(.serialized)
struct WorkshopMediaResumeTests {
    private let testDefaults = TestDefaults()

    @Test(arguments: [true, false])
    func pauseAndInteractionExitPreserveMediaPosition(managesPlayback: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await makeMovie(at: folder.appendingPathComponent("clip.mov"))
        try Data(#"{"type":"web","file":"index.html","title":"Resume regression"}"#.utf8)
            .write(to: folder.appendingPathComponent("project.json"))
        let html = """
        <!doctype html><html><head><style>
        html,body {margin:0;width:100%;height:100%;overflow:hidden}
        video,#still {position:absolute;inset:0;width:100%;height:100%;object-fit:contain}
        </style></head><body><div id="still"></div>
        <video id="video" src="clip.mov" muted autoplay loop playsinline></video><script>
        window.documentToken = Math.random();
        window.ready = true;
        window.pauses = [];
        const video = document.getElementById('video');
        let wasPlaying = true;
        if (\(managesPlayback)) window.wallpaperPropertyListener = {
          setPaused(value) {
            window.pauses.push(value);
            if(value) { wasPlaying = !video.paused; video.pause(); }
            else if(wasPlaying) video.play().catch(() => {});
          }
        };
        </script></body></html>
        """
        try html.write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let item = try #require(WorkshopItem.load(from: folder, computeSize: false))
        let player = WorkshopPlayerNSView(item: item,
            storage: WorkshopWebStorage(scope: folder.path, defaults: testDefaults.make()))
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
                if (try? await player.evaluateJavaScript("window.ready && document.getElementById('video').readyState >= 2", in: frame)) as? Bool == true {
                    loaded = frame; break
                }
            }
            if loaded != nil && player.state == .ready { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let frame = try #require(loaded, "Video failed to load: \(player.runtimeErrors)")
        let token = try #require(try await player.evaluateJavaScript("window.documentToken", in: frame) as? Double)
        _ = try await player.evaluateJavaScript("video.currentTime=2; video.play().catch(() => {}); void 0", in: frame)
        for _ in 0..<100 {
            if (try await player.evaluateJavaScript("video.currentTime > 2.05 && !video.paused", in: frame)) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let before = try #require(try await player.evaluateJavaScript("video.currentTime", in: frame) as? Double)
        #expect(before >= 2 && before < 4)
        let desktop = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.setInteractionEnabled(true, desktopLevel: desktop)
        window.setInteractionEnabled(false, desktopLevel: desktop)
        player.pause()
        try await Task.sleep(for: .milliseconds(200))
        let paused = try #require(try await player.evaluateJavaScript("video.currentTime", in: frame) as? Double)
        #expect((try await player.evaluateJavaScript("video.paused", in: frame)) as? Bool == true)
        #expect(abs(paused - before) < 0.25)
        player.play()
        try await Task.sleep(for: .milliseconds(300))
        let resumed = try #require(try await player.evaluateJavaScript("video.currentTime", in: frame) as? Double)
        #expect(resumed >= paused && resumed < paused + 1)
        #expect((try await player.evaluateJavaScript("video.paused", in: frame)) as? Bool == false)
        #expect((try await player.evaluateJavaScript("window.documentToken", in: frame)) as? Double == token)
        #expect((try await player.evaluateJavaScript("JSON.stringify(video.getBoundingClientRect()) === JSON.stringify(document.getElementById('still').getBoundingClientRect())", in: frame)) as? Bool == true)
        if managesPlayback {
            #expect((try await player.evaluateJavaScript("window.pauses.includes(true) && window.pauses.at(-1) === false", in: frame)) as? Bool == true)
        }
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
