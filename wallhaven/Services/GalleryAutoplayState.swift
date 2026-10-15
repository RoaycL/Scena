import Foundation

/// 每次导航重新计时；手动浏览后，等用户连续一分钟没有操作才允许恢复轮播。
nonisolated struct GalleryAutoplayState {
    static let interval: TimeInterval = 5
    private var lastInteraction: TimeInterval?
    private var nextAdvanceAt: TimeInterval?
    private let idleInterval: TimeInterval = 60

    mutating func selectedManually(at time: TimeInterval) {
        lastInteraction = time
    }

    mutating func interacted(at time: TimeInterval) {
        guard lastInteraction != nil else { return }
        lastInteraction = time
    }

    /// 导航和新画面就绪时从头计时，不解除手动浏览的一分钟暂停。
    mutating func restartCountdown(at time: TimeInterval) {
        nextAdvanceAt = time + Self.interval
    }

    mutating func canAdvance(at time: TimeInterval) -> Bool {
        if let lastInteraction, time - lastInteraction < idleInterval { return false }
        if let nextAdvanceAt, time < nextAdvanceAt { return false }
        self.lastInteraction = nil
        nextAdvanceAt = time + Self.interval
        return true
    }
}
