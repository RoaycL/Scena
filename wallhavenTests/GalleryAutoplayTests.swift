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
}
