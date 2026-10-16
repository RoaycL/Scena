import AppKit
import Foundation
import Testing
@testable import wallhaven

@MainActor
struct AdditionalWallpaperSourceTests {
    private let articleURL = URL(string: "https://wallsflow.com/live-wallpapers/cars/1254-last-ride-at-the-junkyard.html")!
    // 官网的文章编号为 1254，下载按钮的附件编号为 1771，两者并不相同。
    private let attachmentHTML = #"<a class='btn' href='/index.php?do=download&amp;id=1771'>Download Wallpaper</a>"#
    private let searchJSON = Data(#"""
    {"error":false,"body":{"illust":{"data":[
      {"isAdContainer":true},
      {"id":"150915104","title":"見晴らししか勝たん","illustType":0,"xRestrict":0,"url":"https://i.pximg.net/c/250x250_80_a2/img-master/img/2026/10/16/18/00/44/150915104_p0_square1200.jpg","tags":["風景","landscape"],"userName":"くなど","width":1024,"height":1024,"isMasked":false}
    ],"total":20780,"lastPage":10}}}
    """#.utf8)

    @Test func wallsflowReadsCategorizedCardsAndAttributeOrder() throws {
        let html = #"""
        <a href='/live-wallpapers/cars/1254-last-ride-at-the-junkyard.html'>No picture</a>
        <a href='/live-wallpapers/cars/1254-last-ride-at-the-junkyard.html'><img alt='Missing URL'></a>
        <a class='card' href='/live-wallpapers/cars/1254-last-ride-at-the-junkyard.html'>
          <img alt='Last Ride &amp; &#x591C; - Live Wallpapers' loading='lazy' data-src='//cloud.wallsflow.com/posts/car.jpg' src='data:image/gif;base64,AAAA'>
        </a>
        <a href='/live-wallpapers/cars/1254-last-ride-at-the-junkyard.html'><img src='/duplicate.jpg' alt='Duplicate'></a>
        """#
        let items = try WallsflowSource.parse(html)
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.id == "wallsflow-1254")
        #expect(item.pageURL == articleURL)
        #expect(item.title == "Last Ride & 夜")
        #expect(item.thumbURL?.absoluteString == "https://cloud.wallsflow.com/posts/car.jpg")
        #expect(item.imageURL == articleURL)
        #expect(item.resolution.isEmpty)
    }

    @Test func wallsflowUsesAttachmentIDAndResolvesLegacyFavorites() async throws {
        let html = attachmentHTML
        let source = WallsflowSource(load: { url, emptyOnNotFound in
            #expect(url.path == "/live-wallpapers/cars/1254-last-ride-at-the-junkyard.html")
            #expect(!emptyOnNotFound)
            return Data(html.utf8)
        })
        let old = RemoteWallpaper(id: "wallsflow-1254", sourceID: "wallsflow", pageURL: articleURL,
            imageURL: URL(string: "https://wallsflow.com/index.php?do=download&id=1254")!, thumbURL: nil, mediaType: .video)
        let download = try await source.downloadURL(for: old)
        #expect(download.absoluteString == "https://wallsflow.com/index.php?do=download&id=1771")
        #expect(old.downloadFileName(for: download) == "wallsflow-1254.mp4")
    }

    @Test func wallsflowRejectsChallengeAndMissingAttachment() {
        #expect(throws: (any Error).self) { try WallsflowSource.parse("<html><title>Just a moment...</title></html>") }
        #expect(throws: (any Error).self) { try WallsflowSource.parse("<html>Changed layout</html>") }
        #expect(throws: (any Error).self) { try WallsflowSource.parseDownloadURL("<a href='https://other.example/index.php?do=download&id=1771'>Download</a>", pageURL: articleURL) }
        #expect(throws: (any Error).self) { try WallsflowSource.parseDownloadURL("<p>Log in to download</p>", pageURL: articleURL) }
    }

    @Test func wallsflowEmptyResultsAndCategoryURL() throws {
        #expect(try WallsflowSource.parse("<p>The search did not return any results.</p>").isEmpty)
        #expect(try WallsflowSource.parse("").isEmpty)
        let query = WallpaperQuery(text: "", sort: "latest", filters: ["category": ["anime"]])
        #expect(WallsflowSource.listURL(query, page: 2)?.absoluteString == "https://wallsflow.com/live-wallpapers/anime/page/2/")
    }

    @Test(arguments: ["male", "female"])
    func genderRankingDoesNotSendUnsupportedContent(mode: String) {
        let query = WallpaperQuery(text: "", sort: "default", filters: ["mode": [mode], "content": ["manga"]])
        let url = PixivSource.rankingURL(query, page: 1)
        let parameters = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(parameters.first { $0.name == "mode" }?.value == mode)
        #expect(!parameters.contains { $0.name == "content" })
        #expect(PixivSource().filters(for: query).map(\.id) == ["mode"])
    }

    @Test func pixivKeywordSearchEncodesPathAndSelectsEndpoint() async throws {
        let data = searchJSON
        let query = WallpaperQuery(text: " C++ / 风景? ", sort: "default", filters: ["content": ["illust"]])
        let source = PixivSource(load: { url, emptyOnNotFound in
            #expect(!emptyOnNotFound)
            #expect(url.absoluteString.contains("/ajax/search/illustrations/C++%20%2F%20"))
            let parameters = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(parameters.first { $0.name == "word" }?.value == "C++ / 风景?")
            #expect(parameters.first { $0.name == "mode" }?.value == "safe")
            return data
        })
        let result = try await source.search(query, page: 1)
        #expect(result.count == 1)
        #expect(result.first?.id == "pixiv-150915104")
        #expect(result.first?.imageURL.path.contains("/c/") == false)
        #expect(result.first?.imageURL.lastPathComponent == "150915104_p0_master1200.jpg")
        #expect(source.filters(for: query).map(\.id) == ["content"])
        let manga = WallpaperQuery(text: "landscape", sort: "default", filters: ["content": ["manga"]])
        #expect(PixivSource.searchURL(manga, page: 2).path == "/ajax/search/manga/landscape")
        #expect(try await source.search(query, page: 11).isEmpty)
    }

    @Test func pixivParsesMangaEndpointAndIgnoresAdvertisements() throws {
        let data = Data(#"""
        {"error":false,"body":{"manga":{"data":[{"id":"123","title":"漫画","illustType":1,"xRestrict":0,"url":"https://i.pximg.net/c/250x250_80_a2/img-master/img/2026/10/16/18/00/44/123_p0_square1200.jpg","tags":[]}]}}}
        """#.utf8)
        #expect(try PixivSource.parseSearch(data, content: "manga").first?.id == "pixiv-123")
        #expect(throws: (any Error).self) { try PixivSource.parseSearch(data, content: "illust") }
    }

    @Test func pixivResolvesOriginalWithoutGuessingFileExtension() async throws {
        let data = Data(#"""
        {"error":false,"body":[{"urls":{"original":"https://i.pximg.net/img-original/img/2026/10/14/00/01/10/150822243_p0.png"},"width":1446,"height":2048}]}
        """#.utf8)
        let wallpaper = RemoteWallpaper(id: "pixiv-150822243", sourceID: "pixiv", pageURL: URL(string: "https://www.pixiv.net/artworks/150822243")!,
            imageURL: URL(string: "https://i.pximg.net/img-master/img/2026/10/14/00/01/10/150822243_p0_master1200.jpg")!, thumbURL: nil)
        let source = PixivSource(load: { url, emptyOnNotFound in
            #expect(url.path == "/ajax/illust/150822243/pages")
            #expect(!emptyOnNotFound)
            return data
        })
        let original = try await source.downloadURL(for: wallpaper)
        #expect(original.lastPathComponent == "150822243_p0.png")
        #expect(wallpaper.downloadFileName(for: original) == "pixiv-150822243.png")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = folder.appendingPathComponent("pixiv-150822243.png")
        try Data([1]).write(to: local)
        #expect(wallpaper.localFileURL(in: folder) == local)
    }

    @Test func pixivErrorsAreNotSuccessfulEmptyPages() {
        for data in [Data("<html>Log in</html>".utf8), Data(#"{"error":true,"body":[]}"#.utf8), Data(#"{"contents":[{"illust_id":"changed"}]}"#.utf8)] {
            #expect(throws: (any Error).self) { try PixivSource.parse(data) }
            #expect(throws: (any Error).self) { try PixivSource.parseSearch(data, content: "illust") }
            #expect(throws: (any Error).self) { try PixivSource.parseOriginal(data) }
        }
        #expect(throws: (any Error).self) {
            try PixivSource.parseOriginal(Data(#"{"error":false,"body":[{"urls":{"original":"https://pximg.net.evil.example/img-original/123.jpg"}}]}"#.utf8))
        }
    }

    @Test func downloadRejectsHTMLInsteadOfSavingItAsMedia() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("<html>Cloudflare challenge</html>".utf8).write(to: file)
        for mime in ["text/html", "application/octet-stream"] {
            let response = HTTPURLResponse(url: articleURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": mime])!
            #expect(throws: (any Error).self) { try DownloadService.validate(file: file, response: response, isVideo: true) }
            #expect(throws: (any Error).self) { try DownloadService.validate(file: file, response: response, isVideo: false) }
        }
    }

    @Test func downloadAcceptsImageAndMP4Signatures() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
        let image = HTTPURLResponse(url: articleURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
        try DownloadService.validate(file: file, response: image, isVideo: false)
        try Data([0,0,0,24] + Array("ftypisom".utf8)).write(to: file)
        let video = HTTPURLResponse(url: articleURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "video/mp4"])!
        try DownloadService.validate(file: file, response: video, isVideo: true)
    }
}
