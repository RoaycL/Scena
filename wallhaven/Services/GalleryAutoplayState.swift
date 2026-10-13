import Foundation

/// 手动浏览后，等用户连续一分钟没有操作才允许恢复轮播。
nonisolated struct GalleryAutoplayState {
    private var lastInteraction: TimeInterval?
    private let idleInterval: TimeInterval = 60

    mutating func selectedManually(at time: TimeInterval) {
        lastInteraction = time
    }

    mutating func interacted(at time: TimeInterval) {
        guard lastInteraction != nil else { return }
        lastInteraction = time
    }

    mutating func canAdvance(at time: TimeInterval) -> Bool {
        guard let lastInteraction else { return true }
        guard time - lastInteraction >= idleInterval else { return false }
        self.lastInteraction = nil
        return true
    }
}
