//
//  AutoBakeScheduler.swift
//  wallhaven
//
//  下载后自动把场景 / 网页壁纸转成视频。转换要实时渲染几十秒，为了不打扰正在用电脑的人，只在
//  「插着电源、几分钟没有操作、系统不热、没开低电量模式」时一次转一个；转换途中用户一动鼠标键盘
//  或拔掉电源就立即停下，条目留在队列里等下次空闲重来。
//

import AppKit
import Combine
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

@MainActor
final class AutoBakeScheduler: ObservableObject {
    static let shared = AutoBakeScheduler()

    private enum Keys {
        static let enabled = WorkshopPlaybackPolicy.convertedVideoKey
        static let queue = "workshop.autoBake.queue"
        static let skipped = "workshop.autoBake.skipped"
    }

    /// 至少这么久没有键盘鼠标操作才开始
    private let idleThreshold: TimeInterval = {
        #if DEBUG
        // 调试：SCENA_DEBUG_AUTOBAKE_IDLE=<秒> 缩短空闲等待
        if let value = ProcessInfo.processInfo.environment["SCENA_DEBUG_AUTOBAKE_IDLE"].flatMap(TimeInterval.init) { return value }
        #endif
        return 180
    }()

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            isEnabled ? start() : stop()
        }
    }
    /// 等待转换的壁纸文件夹（持久化，重启后继续）
    @Published private(set) var pending: [String] {
        didSet { UserDefaults.standard.set(pending, forKey: Keys.queue) }
    }
    /// 正在后台转换的条目 ID
    @Published private(set) var activeID: String?
    /// 为什么现在没有在转换（显示在设置里）
    @Published private(set) var waitingReason: String?

    /// 转换失败过的（不支持录制等）：不再自动重试，可以手动转
    private var skipped: Set<String> {
        didSet { UserDefaults.standard.set(Array(skipped), forKey: Keys.skipped) }
    }
    private var timer: Timer?
    private var watchdog: Timer?
    /// 转换期间阻止息屏和屏保（息屏后画面停止渲染，录不到东西）
    private var displayAssertion: IOPMAssertionID = 0

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Keys.enabled)
        pending = defaults.stringArray(forKey: Keys.queue) ?? []
        skipped = Set(defaults.stringArray(forKey: Keys.skipped) ?? [])
    }

    /// App 启动时调用
    func activate() {
        WallpaperBaker.shared.onFinish = { [weak self] id, outcome in self?.finished(id, outcome) }
        if isEnabled { start() }
    }

    /// 新下载完成的壁纸（开启自动转换时才排队）
    func didDownload(folder: URL) {
        guard isEnabled else { return }
        enqueue([folder])
    }

    /// 把资料库里还没转换的场景 / 网页壁纸都排进队列
    func enqueueLibrary(_ items: [WorkshopItem]) {
        enqueue(items.compactMap(\.localFolder))
    }

    func clearQueue() {
        pending.removeAll()
        if let activeID { WallpaperBaker.shared.cancel(activeID) }
    }

    /// 资料库中可以排队的数量（未转换、未失败过、不在队列里）
    func candidateCount(in items: [WorkshopItem]) -> Int {
        items.filter { item in
            BakedWallpapers.canBake(item) && !skipped.contains(item.id) && BakedWallpapers.videoURL(for: item) == nil
                && !pending.contains(item.localFolder?.path ?? "")
        }.count
    }

    private func enqueue(_ folders: [URL]) {
        for folder in folders {
            guard let item = WorkshopItem.load(from: folder, computeSize: false), BakedWallpapers.canBake(item),
                  !skipped.contains(item.id), BakedWallpapers.videoURL(for: item) == nil,
                  !pending.contains(folder.path) else { continue }
            pending.append(folder.path)
        }
        tick()
    }

    // MARK: - Scheduling

    private func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 20
        tick()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        if let activeID { WallpaperBaker.shared.cancel(activeID) }
        waitingReason = nil
    }

    private func tick() {
        guard isEnabled, activeID == nil else { return }
        guard !pending.isEmpty else { waitingReason = nil; return }
        if let reason = Self.blockingReason(idleThreshold: idleThreshold) { waitingReason = reason; return }
        // 手动转换进行中时让给它
        guard !WallpaperBaker.shared.isBusy else { waitingReason = "正在手动转换"; return }
        let path = pending[0]
        guard let item = WorkshopItem.load(from: URL(fileURLWithPath: path, isDirectory: true), computeSize: false),
              BakedWallpapers.canBake(item), BakedWallpapers.videoURL(for: item) == nil else {
            pending.removeFirst()
            tick()
            return
        }
        waitingReason = nil
        activeID = item.id
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn), "Scena 正在把壁纸转为视频" as CFString, &displayAssertion)
        WallpaperBaker.shared.bake(item, automatic: true)
        // 转换途中每 2 秒检查一次：用户回来了、拔了电源、系统变热就停下
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let id = self.activeID else { return }
                if let reason = Self.blockingReason(idleThreshold: 0, userActiveWithin: 3) {
                    self.waitingReason = reason
                    WallpaperBaker.shared.cancel(id)
                }
            }
        }
    }

    private func finished(_ id: String, _ outcome: WallpaperBaker.Outcome) {
        guard id == activeID else { return }
        watchdog?.invalidate()
        watchdog = nil
        activeID = nil
        if displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = 0
        }
        switch outcome {
        case .success:
            pending.removeAll { WorkshopItem.load(from: URL(fileURLWithPath: $0), computeSize: false)?.id == id }
        case .failed:
            skipped.insert(id)
            pending.removeAll { WorkshopItem.load(from: URL(fileURLWithPath: $0), computeSize: false)?.id == id }
        case .cancelled:
            break // 留在队列里，下次空闲再来
        }
        // 连续转换之间也重新检查条件，不一口气跑完整个队列
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.tick() }
    }

    // MARK: - Conditions

    /// 现在不适合转换的原因；nil 表示可以开始
    private static func blockingReason(idleThreshold: TimeInterval, userActiveWithin: TimeInterval? = nil) -> String? {
        if isOnBattery { return "等待接通电源" }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return "低电量模式下暂停" }
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return "系统温度较高，稍后再转" }
        let idle = idleSeconds
        if let userActiveWithin, idle < userActiveWithin { return "等待电脑空闲" }
        if idle < idleThreshold { return "等待电脑空闲" }
        return nil
    }

    private static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }

    private static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}
