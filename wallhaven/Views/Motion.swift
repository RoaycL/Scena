//
//  Motion.swift
//  wallhaven
//
//  统一的动效规范。各处动画只从这里取值，节奏一致；
//  系统开启「减少动态效果」时，位移和弹簧换成短暂的淡入淡出。
//

import AppKit
import SwiftUI

/// 圆角档位：小封面 6、卡片和缩略图 10、浮层面板 18；按钮、标签用胶囊形
enum Radius {
    static let small: CGFloat = 6
    static let card: CGFloat = 10
    static let panel: CGFloat = 18
}

enum Motion {
    /// 悬停、按下、开关等即时反馈
    static var hover: Animation { resolved(.snappy(duration: 0.18)) }
    /// 页签、模式切换等导航：带一点弹性，选中底色滑过去
    static var navigation: Animation { resolved(.spring(response: 0.34, dampingFraction: 0.86)) }
    /// 面板、搜索框、展开收起：出现干脆，收起轻
    static var panel: Animation { resolved(.spring(response: 0.32, dampingFraction: 0.84)) }
    /// 图片、文字等内容替换（交叉淡化，不涉及位移）
    static var content: Animation { .smooth(duration: 0.35) }
    /// 提示条进出：减少动态效果时只短暂淡化
    static var toast: Animation { reducesMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.85) }
    static var toastDismiss: Animation { reducesMotion ? .easeInOut(duration: 0.15) : .easeOut(duration: 0.25) }
    /// 同步状态的旋转指示；减少动态效果时用静态图标
    static var syncing: Animation { reducesMotion ? .easeInOut(duration: 0.15) : .linear(duration: 1).repeatForever(autoreverses: false) }
    /// 滚动到选中项
    static var scroll: Animation { resolved(.smooth(duration: 0.35)) }

    static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private static func resolved(_ animation: Animation) -> Animation {
        reducesMotion ? .easeInOut(duration: 0.12) : animation
    }
}

// MARK: - Glass

extension View {
    /// 统一的玻璃材质：macOS 26 用系统 Liquid Glass，旧系统退回磨砂材质。
    /// - tint: 叠加的颜色，用于在明亮壁纸上保证文字可读（面板类）
    /// - interactive: 可点击的元素，玻璃会响应悬停和按下
    @ViewBuilder
    func sceneGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            let base: Glass = tint.map { Glass.regular.tint($0) } ?? .regular
            glassEffect(interactive ? base.interactive() : base, in: shape)
        } else if let tint {
            background(tint, in: shape).background(.ultraThinMaterial, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}
