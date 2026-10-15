import AppKit
import Testing
@testable import wallhaven

@MainActor
@Suite(.serialized)
struct WallpaperWindowLifecycleTests {
    private final class Surface {
        var closeCount = 0
        func close() { closeCount += 1 }
    }

    @Test func interruptedReplacementRetainsEveryOldWindowUntilNewestIsReady() {
        let lifecycle = WallpaperWindowLifecycle<Surface>()
        let a = Surface(), b = Surface(), c = Surface()
        let first = lifecycle.beginReplacement()
        lifecycle.append(a)
        let second = lifecycle.beginReplacement()
        lifecycle.append(b)
        let third = lifecycle.beginReplacement()
        lifecycle.append(c)

        #expect(!lifecycle.isCurrent(a, generation: first))
        #expect(!lifecycle.isCurrent(b, generation: second))
        #expect(lifecycle.isCurrent(c, generation: third))
        #expect(lifecycle.retiring.count == 2)
        let retired = lifecycle.removeRetiring(lifecycle.retiring)
        retired.forEach { $0.close() }
        #expect(a.closeCount == 1 && b.closeCount == 1 && c.closeCount == 0)
        #expect(lifecycle.retiring.isEmpty && lifecycle.active.count == 1)
    }

    @Test func stopIncludesPendingWindowsFromAllDisplaysAndInvalidatesCallbacks() {
        let lifecycle = WallpaperWindowLifecycle<Surface>()
        let previous = [Surface(), Surface()]
        lifecycle.beginReplacement()
        previous.forEach(lifecycle.append)
        let pending = [Surface(), Surface()]
        let generation = lifecycle.beginReplacement()
        pending.forEach(lifecycle.append)

        let stopped = lifecycle.removeAll()
        stopped.forEach { $0.close() }
        #expect(stopped.count == 4)
        #expect((previous + pending).allSatisfy { $0.closeCount == 1 })
        #expect(lifecycle.active.isEmpty && lifecycle.retiring.isEmpty)
        #expect(!lifecycle.isCurrent(pending[0], generation: generation))
    }

    @Test func lateRetirementCannotCloseANewerReplacement() {
        let lifecycle = WallpaperWindowLifecycle<Surface>()
        let a = Surface(), b = Surface(), c = Surface()
        lifecycle.beginReplacement()
        lifecycle.append(a)
        lifecycle.beginReplacement()
        lifecycle.append(b)
        // B 已就绪，准备延迟清理 A；这期间又切到 C。
        let retirementForB = lifecycle.retiring
        let currentGeneration = lifecycle.beginReplacement()
        lifecycle.append(c)

        lifecycle.removeRetiring(retirementForB).forEach { $0.close() }
        #expect(a.closeCount == 1 && b.closeCount == 0 && c.closeCount == 0)
        #expect(lifecycle.retiring.count == 1 && lifecycle.retiring.first === b)
        #expect(lifecycle.isCurrent(c, generation: currentGeneration))
        lifecycle.removeRetiring(lifecycle.retiring).forEach { $0.close() }
        #expect(b.closeCount == 1 && c.closeCount == 0)
    }

    @Test func duplicateReadyAndTimeoutRetirementClosesEachWindowOnlyOnce() {
        let lifecycle = WallpaperWindowLifecycle<Surface>()
        let old = Surface(), current = Surface()
        lifecycle.beginReplacement()
        lifecycle.append(old)
        lifecycle.beginReplacement()
        lifecycle.append(current)
        let batch = lifecycle.retiring
        lifecycle.removeRetiring(batch).forEach { $0.close() }
        lifecycle.removeRetiring(batch).forEach { $0.close() }
        #expect(old.closeCount == 1 && current.closeCount == 0)
    }

    @Test func stopThenRestartDoesNotReuseEarlierReadinessOrCleanup() {
        let lifecycle = WallpaperWindowLifecycle<Surface>()
        let old = Surface(), current = Surface()
        let oldGeneration = lifecycle.beginReplacement()
        lifecycle.append(old)
        lifecycle.removeAll().forEach { $0.close() }
        let newGeneration = lifecycle.beginReplacement()
        lifecycle.append(current)
        lifecycle.removeRetiring([old]).forEach { $0.close() }
        #expect(old.closeCount == 1 && current.closeCount == 0)
        #expect(!lifecycle.isCurrent(old, generation: oldGeneration))
        #expect(!lifecycle.isCurrent(current, generation: oldGeneration))
        #expect(lifecycle.isCurrent(current, generation: newGeneration))
    }

    @Test func disablingEveryDisplayStillReturnsAllWindowsForCleanup() {
        let lifecycle = WallpaperWindowLifecycle<Surface>()
        let old = Surface(), loading = Surface()
        lifecycle.beginReplacement()
        lifecycle.append(old)
        lifecycle.beginReplacement()
        lifecycle.append(loading)
        lifecycle.beginReplacement()
        // 当前批次没有可用显示器，因此没有新窗口。
        let removed = lifecycle.removeAll()
        removed.forEach { $0.close() }
        #expect(removed.count == 2)
        #expect(old.closeCount == 1 && loading.closeCount == 1)
        #expect(lifecycle.active.isEmpty && lifecycle.retiring.isEmpty)
    }

    @Test func interruptedResolutionChangesLeaveNoVisibleDesktopLayers() async throws {
        let lifecycle = WallpaperWindowLifecycle<NSWindow>()
        var ids = Set<CGWindowID>()
        func close(_ windows: [NSWindow]) {
            for window in windows {
                window.orderOut(nil)
                window.contentView = nil
                window.close()
            }
        }
        defer { close(lifecycle.removeAll()) }
        let sizes = [NSSize(width: 1600, height: 900), NSSize(width: 2560, height: 1440),
                     NSSize(width: 1920, height: 1080)]
        for index in 0..<12 {
            lifecycle.beginReplacement()
            autoreleasepool {
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: sizes[index % sizes.count]),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.animationBehavior = .none
                window.isRestorable = false
                window.alphaValue = 0
                window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
                // 透明测试窗口只创建系统资源，不替换桌面图片，也不显示测试画面。
                window.orderFront(nil)
                lifecycle.append(window)
                ids.insert(CGWindowID(window.windowNumber))
            }
        }
        func remainingWindowIDs() throws -> Set<CGWindowID> {
            // 检查仍参与桌面显示的窗口；不把 AppKit 对关闭窗口的内部保留当作可见残留。
            let list = try #require(CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]])
            return Set(list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }).intersection(ids)
        }
        func waitForWindows(_ expected: Set<CGWindowID>) async throws -> Set<CGWindowID> {
            // 关闭窗口要经过 WindowServer；不把同一轮主线程中的即时查询当成最终状态。
            for _ in 0..<100 {
                let remaining = try remainingWindowIDs()
                if remaining == expected { return remaining }
                try await Task.sleep(for: .milliseconds(10))
            }
            return try remainingWindowIDs()
        }
        let initiallyRegistered = try await waitForWindows(ids)
        #expect(initiallyRegistered.count == 12)
        autoreleasepool {
            close(lifecycle.removeRetiring(lifecycle.retiring))
        }
        let currentNumber = try #require(lifecycle.active.first?.windowNumber)
        let expectedCurrent: Set<CGWindowID> = [CGWindowID(currentNumber)]
        let afterRetirement = try await waitForWindows(expectedCurrent)
        #expect(afterRetirement == expectedCurrent)
        // AppKit 决定已关闭 NSWindow 的最终释放时机；交接时验证我们已放弃所有权、旧窗不再显示。
        #expect(lifecycle.retiring.isEmpty && lifecycle.active.count == 1)
        autoreleasepool {
            close(lifecycle.removeAll())
        }
        let afterStop = try await waitForWindows([])
        #expect(afterStop.isEmpty)
        #expect(lifecycle.active.isEmpty && lifecycle.retiring.isEmpty)
    }
}
