//
//  PixivLoginView.swift
//  wallhaven
//
//  Pixiv 官方网页登录视图。
//  通过内嵌 WKWebView 安全加载 Pixiv 登录页，捕获登录成功的会话 Cookie（PHPSESSID），
//  并持久化保存到系统钥匙串中。
//

import SwiftUI
import WebKit

enum PixivLoginWindow {
    static let id = "pixiv-login"
}

struct PixivLoginView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject private var session = PixivAccountSession.shared
    @State private var isLoading = true
    @State private var retryID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            PixivLoginWebView(isLoading: $isLoading, retryID: retryID) {
                let success = await session.refreshFromCookies()
                if success, session.isPersistent {
                    ToastCenter.shared.show("已登录 Pixiv", style: .success)
                    dismissWindow(id: PixivLoginWindow.id)
                }
                return success
            }
            Divider()
            footer
        }
        .frame(minWidth: 500, minHeight: 640)
        .onDisappear { session.cancelAuthentication() }

    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("登录 Pixiv")
                    .font(.headline)
                Text("accounts.pixiv.net")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button("关闭") {
                dismissWindow(id: PixivLoginWindow.id)
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = session.errorMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                HStack {
                    if session.isLoggedIn, !session.isPersistent {
                        Button("重新保存登录") {
                            if session.retryPersistence() { dismissWindow(id: PixivLoginWindow.id) }
                        }
                        Button("仅本次使用") { dismissWindow(id: PixivLoginWindow.id) }
                    } else {
                        Button("重新检查登录") { retryID = UUID() }.disabled(session.isChecking)
                    }
                }
            }
            Text("在 Pixiv 官方页面中完成登录。验证成功后保存到系统钥匙串；保存失败会明确提示仅本次有效。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 8).background(.bar)
    }

}

private struct PixivLoginWebView: NSViewRepresentable {
    @Binding var isLoading: Bool
    let retryID: UUID
    let onLoginDetected: @MainActor () async -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = SourceHTTP.userAgent
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.startCookieInspection()

        webView.load(URLRequest(url: PixivAccountSession.loginURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        let retry = context.coordinator.parent.retryID != retryID
        context.coordinator.parent = self
        if retry { context.coordinator.lastAttemptedCookie = nil; context.coordinator.inspectCookies() }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stopCookieInspection()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: PixivLoginWebView
        weak var webView: WKWebView?
        private var checkTimer: Timer?
        private var isHandlingSuccess = false
        private var isStopped = false
        private var inspectionTask: Task<Void, Never>?
        var lastAttemptedCookie: String?

        init(_ parent: PixivLoginWebView) {
            self.parent = parent
        }

        func startCookieInspection() {
            checkTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.inspectCookies()
                }
            }
        }

        func stopCookieInspection() {
            isStopped = true
            checkTimer?.invalidate()
            checkTimer = nil
            inspectionTask?.cancel()
        }

        func inspectCookies() {
            guard !isStopped, !isHandlingSuccess, inspectionTask == nil else { return }
            inspectionTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.inspectionTask = nil }
                let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
                guard !self.isStopped, !Task.isCancelled,
                      let cookie = PixivAccountSession.usableCookie(in: cookies),
                      cookie.value != self.lastAttemptedCookie else { return }
                self.lastAttemptedCookie = cookie.value
                let success = await self.parent.onLoginDetected()
                guard !self.isStopped, !Task.isCancelled else { return }
                if success {
                    self.isHandlingSuccess = true
                    self.stopCookieInspection()
                }
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            lastAttemptedCookie = nil
            inspectCookies()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
    }
}
