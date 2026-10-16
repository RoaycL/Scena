import Foundation
import Testing
@testable import wallhaven

struct WallsflowLayoutTests {
    // 2026-10-16 官网 article.story 的精简结构：图片、视频和空覆盖链接是兄弟节点。
    // https://wallsflow.com/live-wallpapers/
    private static let card = #"""
    <article class="story relative group rounded-lg bg-white p-3 h-full flex flex-col">
      <div class="relative overflow-hidden rounded-lg aspect-video">
        <img src="https://cloud.wallsflow.com/posts/2026-10/thumbs/ae47629949_lilu-lil-knri-swamp-wallsflow-com.webp"
             alt="Lilu Lil Knri Swamp live wallpaper for desktop" width="800" height="450" loading="eager">
        <video muted loop playsinline preload="none" class="video-lazy">
          <source data-src="https://play.wallsflow.com/files/2026-10/62fc5f7cbe_lilu-lil-knri-swamp-wallsflow-com.mp4" type="video/mp4">
        </video>
        <div class="video-loader"><div class="animate-spin"></div></div>
        <a href="https://wallsflow.com/live-wallpapers/games/1304-lilu-lil-knri-swamp.html" class="absolute inset-0" aria-label="Lilu Lil Knri Swamp"></a>
      </div>
      <div><a href="/live-wallpapers/games/">Games Live Wallpapers</a>
        <h2><a href="/live-wallpapers/games/1304-lilu-lil-knri-swamp.html">Lilu Lil Knri Swamp</a></h2>
      </div>
      <div><img src="https://cloud.wallsflow.com/fotos/avatar.webp" alt="Author avatar Caen">
        <a href="/live-wallpapers/games/1304-lilu-lil-knri-swamp.html#comment">Comments</a>
      </div>
    </article>
    """#

    @Test func currentSiteSeparatesImagesAndOverlayLinks() throws {
        let items = try WallsflowSource.parse(Self.card)
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.id == "wallsflow-1304")
        #expect(item.title == "Lilu Lil Knri Swamp")
        #expect(item.thumbURL?.lastPathComponent == "ae47629949_lilu-lil-knri-swamp-wallsflow-com.webp")
        #expect(item.previewVideoURL?.host == "play.wallsflow.com")
        #expect(item.previewVideoURL?.lastPathComponent == "62fc5f7cbe_lilu-lil-knri-swamp-wallsflow-com.mp4")
        #expect(item.imageURL == item.pageURL && item.mediaType == .video)
        #expect(item.resolution.isEmpty) // 800×450 是缩略图尺寸，不是原视频分辨率。
    }

    @Test func cardsDoNotBorrowNeighborImagesAndKeepOrderWithLegacyCards() throws {
        let html = #"""
        <a href='/live-wallpapers/1200-legacy.html'><img src='/legacy.webp' alt='Legacy'></a>
        <article><a href='/live-wallpapers/1303-missing-cover.html'>Missing cover</a></article>
        """# + Self.card + #"""
        <article>
          <img src='/second.webp' alt='Second live wallpaper for desktop'>
          <a href='/live-wallpapers/1305-second.html#comment'></a>
        </article>
        """# + Self.card
        let items = try WallsflowSource.parse(html)
        #expect(items.map(\.id) == ["wallsflow-1200", "wallsflow-1304", "wallsflow-1305"])
        #expect(items.last?.thumbURL?.absoluteString == "https://wallsflow.com/second.webp")
        #expect(items.last?.title == "Second")
        #expect(items.last?.pageURL.fragment == nil)
    }

    @Test(arguments: ["http://cloud.wallsflow.com/cover.webp", "https://cloud.wallsflow.com.evil.example/cover.webp", "https://token@cloud.wallsflow.com/cover.webp"])
    func invalidCoverCannotFallBackToAuthorAvatar(url: String) {
        let html = Self.card.replacingOccurrences(
            of: "https://cloud.wallsflow.com/posts/2026-10/thumbs/ae47629949_lilu-lil-knri-swamp-wallsflow-com.webp", with: url)
        #expect(throws: (any Error).self) { try WallsflowSource.parse(html) }
    }

    @Test func invalidPreviewDoesNotBecomeDownloadOrHideValidCover() throws {
        let html = Self.card.replacingOccurrences(of: "https://play.wallsflow.com/", with: "https://play.wallsflow.com.evil.example/")
        let item = try #require(try WallsflowSource.parse(html).first)
        #expect(item.previewVideoURL == nil)
        #expect(item.thumbURL != nil && item.imageURL == item.pageURL)
    }

    @Test func challengeRecoveryKeepsExactSearchAndDetailURLs() async throws {
        let query = WallpaperQuery(text: "neon", sort: "latest", filters: [:])
        let expected = try #require(WallsflowSource.listURL(query, page: 2))
        let source = WallsflowSource(load: { url, _ in
            #expect(url == expected)
            return Data("<html><title>Just a moment...</title></html>".utf8)
        })
        do {
            _ = try await source.search(query, page: 2)
            Issue.record("Challenge must not become an empty search result")
        } catch let error as CloudflareChallengeRequiredError {
            #expect(error.challengeURL == expected)
        }
        let detail = URL(string: "https://wallsflow.com/live-wallpapers/games/1304-lilu-lil-knri-swamp.html")!
        do {
            _ = try WallsflowSource.parseDownloadURL("<html><title>Just a moment...</title></html>", pageURL: detail)
            Issue.record("Challenge must not become a download URL")
        } catch let error as CloudflareChallengeRequiredError {
            #expect(error.challengeURL == detail)
        }
    }
}
