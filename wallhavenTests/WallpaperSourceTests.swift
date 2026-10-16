import Foundation
import Testing
@testable import wallhaven

@MainActor
struct WallpaperSourceTests {
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
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
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
        let model = WallpaperViewModel(discoveryDefaults: UserDefaults(suiteName: UUID().uuidString)!, searchLoader: { _, _ in [] })
        let purity = try #require(model.descriptor.filters.first { $0.id == "purity" })
        model.toggle(purity.options.first { $0.id == "sfw" }, in: purity)
        #expect(model.filterSelections["purity"] == ["sfw"])
    }

    @Test func wallhavenEncodesSelectionsAsBitmasks() {
        #expect(WallhavenSource.bitmask(["general", "anime", "people"], ["general", "people"]) == "101")
        #expect(WallhavenSource.bitmask(["sfw", "sketchy", "nsfw"], []) == "000")
    }
}
