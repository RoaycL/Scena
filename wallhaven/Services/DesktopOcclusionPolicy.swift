import CoreGraphics

nonisolated enum DesktopOcclusionPolicy {
    /// 桌面层经常被 Finder 的透明图标窗口标为 occluded；只有实际覆盖工作区的普通窗口才暂停。
    static func isCovered(_ target: CGRect, by rectangles: [CGRect]) -> Bool {
        guard target.width > 0, target.height > 0 else { return false }
        return rectangles.contains { $0.insetBy(dx: -1, dy: -1).contains(target) }
    }
}
