import Foundation
import Testing
@testable import wallhaven

struct PixivFilterTests {
    @Test func testHostDoesNotRestoreProductionPixivCredentials() {
        #expect(AppRuntime.isRunningTests)
        #expect(!PixivCookieVault.shared.isAuthenticated)
    }

    private func parameters(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private func response(key: String = "illust", types: [Int] = [0], restrictions: [Int] = [0]) throws -> Data {
        let items = zip(types, restrictions).enumerated().map { index, pair -> [String: Any] in
            ["id": String(index + 1), "title": "Fixture \(index)", "url": "https://i.pximg.net/c/250x250/img-master/\(index)_square1200.jpg",
             "illustType": pair.0, "xRestrict": pair.1, "width": 1920, "height": 1080, "isMasked": false]
        }
        return try JSONSerialization.data(withJSONObject: ["error": false, "body": [key: ["data": items]]])
    }

    @Test func searchFiltersAndRankingFiltersOnlyExposeSupportedCombinations() {
        let source = PixivSource()
        let search = WallpaperQuery(text: "landscape", sort: "date_d", filters: [:])
        #expect(source.filters(for: search).map(\.id) == ["content", "age", "match", "aspect", "ai", "date", "width", "height", "bookmarks", "tool"])
        #expect(source.sorts(for: search).count == 5)
        let original = WallpaperQuery(text: "", sort: "date_d", filters: ["mode": ["original"]])
        #expect(source.filters(for: original).map(\.id) == ["mode", "rankingDate"])
        #expect(source.sorts(for: original).isEmpty)
        let month = WallpaperQuery(text: "", sort: "date_d", filters: ["mode": ["monthly"]])
        #expect(source.filters(for: month).first { $0.id == "content" }?.options.contains { $0.id == "ugoira" } == false)
    }

    @Test func everySearchConditionReachesItsActualQueryParameter() {
        let query = WallpaperQuery(text: " C++ / scenery? ", sort: "popular_female_d", filters: [
            "content": ["all"], "age": ["r18"], "match": ["s_tag_full"], "aspect": ["landscape"], "ai": ["hide"],
            "width": ["min=1920", "max=7680"], "height": ["min=1080", "max=4320"],
            "bookmarks": ["min=500", "max=10000"], "date": ["min=2026-01-02", "max=2026-02-03"], "tool": ["CLIP STUDIO PAINT"]
        ])
        let url = PixivSource.searchURL(query, page: 3, signedIn: true), params = parameters(url)
        #expect(url.path.hasPrefix("/ajax/search/artworks/"))
        #expect(params["word"] == "C++ / scenery?")
        #expect(params["order"] == "popular_female_d" && params["mode"] == "r18" && params["p"] == "3")
        #expect(params["s_mode"] == "s_tag_full" && params["type"] == "all" && params["ratio"] == "0.5")
        #expect(params["wlt"] == "1920" && params["wgt"] == "7680" && params["hlt"] == "1080" && params["hgt"] == "4320")
        #expect(params["blt"] == "500" && params["bgt"] == "10000" && params["ai_type"] == "1")
        #expect(params["scd"] == "2026-01-02" && params["ecd"] == "2026-02-03" && params["tool"] == "CLIP STUDIO PAINT")
        let guest = parameters(PixivSource.searchURL(query, page: 1))
        #expect(guest["mode"] == "safe" && guest["order"] == "date_d" && guest["blt"] == nil && guest["bgt"] == nil)
    }

    @Test func restrictedModesAndHistoricalDateUseRankingEndpoint() {
        for mode in ["original", "daily_ai", "daily_r18", "weekly_r18", "daily_r18_ai", "male_r18", "female_r18", "r18g"] {
            let query = WallpaperQuery(text: "", sort: "date_d", filters: ["mode": [mode], "content": ["illust"], "rankingDate": ["2026-01-02"]])
            let params = parameters(PixivSource.rankingURL(query, page: 2))
            #expect(params["mode"] == mode && params["date"] == "20260102" && params["p"] == "2")
            if ["original", "daily_ai", "daily_r18_ai", "male_r18", "female_r18", "r18g"].contains(mode) { #expect(params["content"] == nil) }
        }
    }

    @Test func restrictedSearchAndRankingNeverRequestWithoutPixivAuthentication() async {
        let source = PixivSource(load: { _, _ in Issue.record("Unauthorized filter must not reach network"); return Data() }, signedIn: { false })
        for query in [
            WallpaperQuery(text: "test", sort: "date_d", filters: ["age": ["r18"]]),
            WallpaperQuery(text: "test", sort: "popular_d", filters: [:]),
            WallpaperQuery(text: "test", sort: "date_d", filters: ["bookmarks": ["min=500"]]),
            WallpaperQuery(text: "", sort: "date_d", filters: ["mode": ["daily_r18"]])
        ] {
            await #expect(throws: (any Error).self) { try await source.search(query, page: 1) }
        }
    }

    @Test func loggedInSearchCanContinueBeyondGuestPageLimitAndReportsPremiumErrors() async throws {
        let data = try response()
        let source = PixivSource(load: { url, _ in
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "p" }?.value == "11")
            return data
        }, signedIn: { true })
        #expect(try await source.search(WallpaperQuery(text: "test", sort: "date_d", filters: [:]), page: 11).count == 1)
        let rejected = PixivSource(load: { _, _ in Data(#"{"error":true,"body":[]}"#.utf8) }, signedIn: { true })
        do {
            _ = try await rejected.search(WallpaperQuery(text: "test", sort: "popular_d", filters: [:]), page: 1)
            Issue.record("Premium rejection must not become empty results")
        } catch { #expect(error.localizedDescription.contains("高级会员")) }
    }

    @Test func ageSelectionControlsParsingAndDoesNotSilentlyDropAuthorizedResults() throws {
        let data = try response(types: [0, 0, 0], restrictions: [0, 1, 2])
        #expect(try PixivSource.parseSearch(data, content: "illust").map(\.id) == ["pixiv-1"])
        #expect(try PixivSource.parseSearch(data, content: "illust", age: "r18").map(\.id) == ["pixiv-2", "pixiv-3"])
        #expect(try PixivSource.parseSearch(data, content: "illust", age: "all").count == 3)
        let all = try response(key: "illustManga", types: [0, 1, 2], restrictions: [0, 0, 0])
        #expect(try PixivSource.parseSearch(all, content: "all").count == 3)
        #expect(try PixivSource.parseSearch(all, content: "all").last?.category == "动图静态封面")
        let ugoira = try response(types: [2], restrictions: [0])
        #expect(try PixivSource.parseSearch(ugoira, content: "ugoira").count == 1)
    }

    @Test func invertedRangesAndFutureRankingsAreRejectedBeforeNetwork() async {
        let source = PixivSource(load: { _, _ in Issue.record("Invalid bounds must not reach network"); return Data() }, signedIn: { true })
        for filters in [["width": ["min=4000", "max=1000"]], ["date": ["min=2026-03-01", "max=2026-01-01"]]] {
            let query = WallpaperQuery(text: "test", sort: "date_d", filters: filters.mapValues(Set.init))
            await #expect(throws: (any Error).self) { try await source.search(query, page: 1) }
        }
        let query = WallpaperQuery(text: "", sort: "date_d", filters: ["rankingDate": [SourceFilterDate.string(Date())]])
        await #expect(throws: (any Error).self) { try await source.search(query, page: 1) }
    }

    @Test func typedFiltersRejectMalformedStoredValues() throws {
        let filters = PixivSource().descriptor.filters
        let width = try #require(filters.first { $0.id == "width" })
        #expect(width.normalized(["min=-1", "max=abc", "other=500"]).isEmpty)
        #expect(width.normalized(["min=01920", "max=3840"]) == ["min=1920", "max=3840"])
        let date = try #require(filters.first { $0.id == "date" })
        #expect(date.normalized(["min=2026-02-30", "max=2026-03-01"]) == ["max=2026-03-01"])
        #expect(SourceFilterDate.date("2026-02-30") == nil)
        let tool = try #require(filters.first { $0.id == "tool" })
        #expect(tool.normalized(["CLIP "]) == ["CLIP "]) // 输入词间空格时不能被立即裁掉。
    }
}
