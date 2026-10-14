//
//  ToastCenter.swift
//  wallhaven
//

import Combine
import SwiftUI

struct Toast: Identifiable, Equatable {
    enum Style {
        case info, success, error, progress
    }

    let id = UUID()
    let message: String
    let style: Style
    /// 点击提示条时执行（如跳转到出问题的壁纸）；为 nil 时点击只是关闭
    var action: (() -> Void)? = nil

    static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
}

/// 全局轻量提示条（替代打断式的 alert）
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published private(set) var current: Toast?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String, style: Toast.Style = .info, action: (() -> Void)? = nil) {
        dismissTask?.cancel()
        withAnimation(Motion.toast) {
            current = Toast(message: message, style: style, action: action)
        }
        // progress 类型会一直保留，直到被下一条提示替换
        guard style != .progress else { return }
        // 可点击的提示多留一会儿，来得及点
        let duration: Duration = action != nil ? .seconds(8) : (style == .error ? .seconds(4) : .seconds(2.2))
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(Motion.toastDismiss) {
            current = nil
        }
    }
}
