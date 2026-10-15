import Testing
@testable import wallhaven

struct GalleryAutoplayTests {
    @Test func manualSelectionWaitsForOneMinuteOfInactivity() {
        var state = GalleryAutoplayState()
        let advances1 = state.canAdvance(at: 0)
        #expect(advances1)
        state.selectedManually(at: 10)
        let advances2 = state.canAdvance(at: 69.9)
        #expect(!advances2)
        let advances3 = state.canAdvance(at: 70)
        #expect(advances3)
    }

    @Test func furtherInteractionRestartsTheIdleDeadline() {
        var state = GalleryAutoplayState()
        state.selectedManually(at: 10)
        state.interacted(at: 55)
        let advances4 = state.canAdvance(at: 70)
        #expect(!advances4)
        let advances5 = state.canAdvance(at: 114.9)
        #expect(!advances5)
        let advances6 = state.canAdvance(at: 115)
        #expect(advances6)
    }

    @Test func automaticPlaybackDoesNotKeepPausingOnMouseMovement() {
        var state = GalleryAutoplayState()
        state.selectedManually(at: 0)
        let advances7 = state.canAdvance(at: 60)
        #expect(advances7)
        state.interacted(at: 65)
        let advances8 = state.canAdvance(at: 70)
        #expect(advances8)
        state.selectedManually(at: 71)
        let advances9 = state.canAdvance(at: 75)
        #expect(!advances9)
    }
    @Test func navigationIgnoresTheOldTimerTickAndWaitsFiveFullSeconds() {
        var state = GalleryAutoplayState()
        let result1 = state.canAdvance(at: 0)
        #expect(result1)
        state.restartCountdown(at: 4.75)
        let result2 = state.canAdvance(at: 5)
        #expect(!result2)
        let result3 = state.canAdvance(at: 9.74)
        #expect(!result3)
        let result4 = state.canAdvance(at: 9.75)
        #expect(result4)
        let result5 = state.canAdvance(at: 10)
        #expect(!result5)
    }

    @Test func repeatedNavigationUsesTheMostRecentCountdown() {
        var state = GalleryAutoplayState()
        state.restartCountdown(at: 10)
        state.restartCountdown(at: 14)
        state.restartCountdown(at: 18)
        let result6 = state.canAdvance(at: 20)
        #expect(!result6)
        let result7 = state.canAdvance(at: 22.99)
        #expect(!result7)
        let result8 = state.canAdvance(at: 23)
        #expect(result8)
    }

    @Test func displayedWallpaperGetsItsOwnFullIntervalAfterLoading() {
        var state = GalleryAutoplayState()
        state.restartCountdown(at: 10)
        // 模拟新页的大图加载到第十八秒才就绪。
        state.restartCountdown(at: 18)
        let result9 = state.canAdvance(at: 20)
        #expect(!result9)
        let result10 = state.canAdvance(at: 23)
        #expect(result10)
    }

    @Test func navigationDoesNotClearManualBrowsingPause() {
        var state = GalleryAutoplayState()
        state.selectedManually(at: 10)
        state.restartCountdown(at: 20)
        let result11 = state.canAdvance(at: 25)
        #expect(!result11)
        let result12 = state.canAdvance(at: 69.99)
        #expect(!result12)
        let result13 = state.canAdvance(at: 70)
        #expect(result13)
    }

}
