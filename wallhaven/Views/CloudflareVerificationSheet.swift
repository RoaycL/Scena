//
//  CloudflareVerificationSheet.swift
//  wallhaven
//
//  Cloudflare Turnstile 验证弹窗。
//  当 Wallsflow 等受 Cloudflare 防护的图源返回验证质询时，展示内嵌真实 WebKit 浏览器视图，
//  供用户完成人机交互验证，捕获 cf_clearance 与 __cf_bm 安全 Cookie，并自动恢复壁纸加载。
//

import SwiftUI
import WebKit

struct CloudflareVerificationSheet: View {
    let challenge: CloudflareChallengeRequiredError
    let onVerified: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @StateObject private var verification = CloudflareVerificationModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            CloudflareVerificationWebView(
                challenge: challenge,
                isLoading: $isLoading,
                verification: verification
            ) {
                onVerified()
                dismiss()
            }
            Divider()
            footer
        }
        .frame(minWidth: 500, minHeight: 600)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "shield.checkerboard")
                .font(.system(size: 16))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("安全验证")
                    .font(.headline)
                Text(challenge.domain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button("关闭") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verification.errorMessage ?? "完成页面验证后，会先检查图源是否放行，再恢复原来的操作。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("重新检查") { verification.retry() }.disabled(verification.isVerifying)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct CloudflareVerificationWebView: NSViewRepresentable {
    let challenge: CloudflareChallengeRequiredError
    @Binding var isLoading: Bool
    let verification: CloudflareVerificationModel
    let onVerificationPassed: () -> Void

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
        context.coordinator.startInspection()

        webView.load(URLRequest(url: challenge.challengeURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stopInspection()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: CloudflareVerificationWebView
        weak var webView: WKWebView?
        private var checkTimer: Timer?
        private var isCompleted = false
        private var isStopped = false
        private var inspectionTask: Task<Void, Never>?

        init(_ parent: CloudflareVerificationWebView) {
            self.parent = parent
        }

        func startInspection() {
            checkTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.inspectCookies()
                }
            }
        }

        func stopInspection() {
            isStopped = true
            checkTimer?.invalidate()
            checkTimer = nil
            inspectionTask?.cancel()
            parent.verification.cancel()
        }

        func inspectCookies() {
            guard !isStopped, !isCompleted, inspectionTask == nil else { return }
            inspectionTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.inspectionTask = nil }
                let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
                guard !self.isStopped, !Task.isCancelled else { return }
                let success = await self.parent.verification.inspect(cookies: cookies, challenge: self.parent.challenge)
                guard !self.isStopped, !Task.isCancelled else { return }
                if success {
                    self.isCompleted = true
                    ToastCenter.shared.show("图源验证通过", style: .success)
                    self.parent.onVerificationPassed()
                    self.stopInspection()
                }
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            inspectCookies()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
    }
}
