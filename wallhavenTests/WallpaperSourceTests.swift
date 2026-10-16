import Foundation
import Testing
@testable import wallhaven

@MainActor
struct WallpaperSourceTests {
    private let testDefaults = TestDefaults()
    /// 1.0.26 及更早版本保存的收藏（与 Wallhaven 接口同格式，没有 source 字段）
    private let legacyFavorite = Data("""
    {"id":"abc123","url":"https://wallhaven.cc/w/abc123","path":"https://w.wallhaven.cc/full/ab/wallhaven-abc123.png",
     "thumbs":{"large":"https://th.wallhaven.cc/lg/ab/abc123.jpg"},"resolution":"3840x2160","category":"anime",
     "favorites":12,"ratio":"1.78","purity":"sfw","colors":["#000000"],"views":40,"file_size":2048}
    """.utf8)

    @Test func legacyFavoriteDecodesAsWallhavenAndRoundTrips() throws {
        let wallpaper = try JSONDecoder().decode(RemoteWallpaper.self, from: legacyFavorite)
        #expect(wallpaper.sourceID == WallhavenSource.id)
        #expect(wallpaper.thumbURL?.absoluteString == "https://th.wallhaven.cc/lg/ab/abc123.jpg")
        #expect(wallpaper.downloadFileName == "abc123.png")
        #expect(wallpaper.displayTitle == "Wallhaven #abc123")
        let decoded = try JSONDecoder().decode(RemoteWallpaper.self, from: JSONEncoder().encode(wallpaper))
        #expect(decoded == wallpaper)
    }

    @Test func savedPlaylistEntryKeepsItsWallpaper() throws {
        let entry = Data("""
        {"id":"wh-abc123","kind":"wallhaven","title":"wallhaven #abc123","thumbnail":null,"wallhaven":\(String(decoding: legacyFavorite, as: UTF8.self))}
        """.utf8)
        let decoded = try JSONDecoder().decode(PlaylistEntry.self, from: entry)
        #expect(decoded.kind == .remote)
        #expect(decoded.remote?.id == "abc123")
        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        #expect(reencoded?["kind"] as? String == "wallhaven")
        #expect(reencoded?["wallhaven"] != nil)
    }

    @Test func legacyDiscoveryPreferencesMigrate() {
        let defaults = testDefaults.make()
        defaults.set(["query": "forest", "sortOrder": "toplist", "general": false, "anime": true, "people": true,
                      "sfw": true, "sketchy": false, "nsfw": false, "resolutions": ["2560x1440"]],
                     forKey: "wallper.discovery.preferences.v1")
        let model = WallpaperViewModel(discoveryDefaults: defaults, searchLoader: { _, _ in [] })
        #expect(model.query == "forest")
        #expect(model.sortID == "toplist")
        #expect(model.filterSelections["categories"] == ["anime", "people"])
        #expect(model.filterSelections["purity"] == ["sfw"])
        #expect(model.filterSelections["resolutions"] == ["2560x1440"])
    }

    @Test func atLeastOneFilterKeepsItsLastOption() throws {
        let model = WallpaperViewModel(discoveryDefaults: testDefaults.make(), searchLoader: { _, _ in [] })
        let purity = try #require(model.descriptor.filters.first { $0.id == "purity" })
        model.toggle(purity.options.first { $0.id == "sfw" }, in: purity)
        #expect(model.filterSelections["purity"] == ["sfw"])
    }

    @Test func wallhavenEncodesSelectionsAsBitmasks() {
        #expect(WallhavenSource.bitmask(["general", "anime", "people"], ["general", "people"]) == "101")
        #expect(WallhavenSource.bitmask(["sfw", "sketchy", "nsfw"], []) == "000")
    }

    @Test func konachanMapsPostsAndBuildsTagQuery() throws {
        let json = Data("""
        [{"id":139545,"tags":"blue_eyes red_hair","file_url":"https://konachan.net/image/abc/Konachan.png","file_ext":"png",
          "file_size":893777,"preview_url":"https://konachan.net/data/preview/abc.jpg","jpeg_url":"https://konachan.net/jpeg/abc/k.jpg",
          "width":3840,"height":2160,"score":1570,"rating":"s"}]
        """.utf8)
        let wallpaper = try #require(KonachanSource.parse(json).first)
        #expect(wallpaper.id == "konachan-139545")
        #expect(wallpaper.displayTitle == "Konachan #139545")
        #expect(wallpaper.posterURL?.absoluteString == "https://konachan.net/jpeg/abc/k.jpg")
        #expect(wallpaper.downloadFileName == "konachan-139545.png")
        #expect(wallpaper.tags == ["blue_eyes", "red_hair"])
        let url = KonachanSource.searchURL(WallpaperQuery(text: "sky", sort: "score", filters: ["size": ["2560"]]), page: 2)
        let tags = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "tags" }?.value
        #expect(tags == "sky order:score width:2560.. height:1440..")
    }

    @Test func fourKWallpapersParsesCards() throws {
        let html = """
        <p class="wallpapers__item"><meta itemprop="keywords" content="Desert, Rocks, 5K"> <link itemprop="contentUrl" href="/images/walls/thumbs_2t/27362.jpg">
        <a title="Desert Wallpaper" itemprop="url" data-ripples class="wallpapers__canvas_image"  href="/nature/desert-rocks-27362.html">
        <img src="/images/walls/thumbs/27362.jpg"></a></p>
        """
        let wallpaper = try #require(FourKWallpapersSource.parse(html).first)
        #expect(wallpaper.id == "4kwallpapers-27362")
        #expect(wallpaper.title == "Desert")
        #expect(wallpaper.imageURL.absoluteString == "https://4kwallpapers.com/images/wallpapers/desert-rocks-3840x2160-27362.jpg")
        #expect(wallpaper.tags == ["Desert", "Rocks"])
        #expect(FourKWallpapersSource.listURL(WallpaperQuery(text: "", sort: "popular", filters: [:]), page: 2).absoluteString
                == "https://4kwallpapers.com/most-popular-4k-wallpapers/?page=2")
    }

    @Test func motionBGParsesVideoCardsWithoutMisaligning() throws {
        // 第一张卡片缺少图片，不能和第二张错位；第二张的文件名带分辨率后缀、短名和地址不同
        let html = """
        <a title="Broken live wallpaper" href=/broken> <figure></figure> <span class=ttl>Broken</span> </a>        <a title="Nelliel live wallpaper" href=/nelliel> <img src=/i/c/364x205/media/10273/nelliel-hollow.3840x2160.jpg>         <span class=ttl>Nelliel Hollow Beauty</span> <span class=frm> 4K </span> </a>
        """
        let items = MotionBGSource.parse(html)
        #expect(items.count == 1)
        let wallpaper = try #require(items.first)
        #expect(wallpaper.id == "motionbgs-10273")
        #expect(wallpaper.isVideo)
        #expect(wallpaper.previewVideoURL?.absoluteString == "https://motionbgs.com/media/10273/nelliel-hollow.960x540.mp4")
        #expect(wallpaper.imageURL.absoluteString == "https://motionbgs.com/dl/4k/10273/")
        #expect(wallpaper.downloadFileName == "motionbgs-10273.mp4")
        #expect(MotionBGSource.listURL(WallpaperQuery(text: "", sort: "latest", filters: ["tag": ["anime"]]), page: 3)?.absoluteString
                == "https://motionbgs.com/tag:anime/3/")
    }

    @Test func singleChoiceFilterTogglesBackToAny() throws {
        let defaults = testDefaults.make()
        let model = WallpaperViewModel(discoveryDefaults: defaults, searchLoader: { _, _ in [] })
        model.selectSource(KonachanSource())
        let size = try #require(model.descriptor.filters.first { $0.id == "size" })
        model.toggle(size.options[0], in: size)
        model.toggle(size.options[1], in: size)
        #expect(model.filterSelections["size"] == ["2560"])
        model.toggle(size.options[1], in: size)
        #expect(model.filterSelections["size"] == [])
    }
}
