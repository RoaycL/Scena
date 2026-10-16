//
//  SteamLoginView.swift
//  wallhaven
//
//  默认使用 Steam 手机扫码，保留 Steam 官方网页登录作为兼容入口。
//

import CoreImage.CIFilterBuiltins
import SwiftUI
import WebKit

enum SteamLoginWindow {
    static let id = "steam-login"
}

struct SteamLoginView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject private var account = SteamAccountSession.shared
    @State private var useWebLogin = false
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            if useWebLogin {
                webLogin
            } else {
                qrLogin
            }
        }
        .frame(minWidth: 480, minHeight: useWebLogin ? 600 : 520)
        .background(SteamLoginCloseObserver { account.cancelAuthentication() }.frame(width: 0, height: 0))
        .task(id: useWebLogin) {
            if useWebLogin { account.cancelAuthentication() }
            else if account.supportsQRCode { account.beginQRCodeLogin() }
            else { useWebLogin = true }
        }
        .onDisappear { account.cancelAuthentication() }
        .onChange(of: account.loginState) { _, state in
            if state == .signedIn {
                ToastCenter.shared.show("已登录 Steam：\(account.personaName ?? account.steamID ?? "")", style: .success)
                dismissWindow(id: SteamLoginWindow.id)
            }
        }
    }

    private var qrLogin: some View {
        VStack(spacing: 20) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("扫码登录 Steam").font(.title2.bold())
                Text("使用 Steam 手机 App 扫描，并确认设备 Scena for macOS。")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Group {
                switch account.loginState {
                case .qr(let url): SteamQRCode(url: url)
                case .failed(let message):
                    VStack(spacing: 14) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text(message).multilineTextAlignment(.center).font(.callout)
                        Button("重新获取二维码") { account.beginQRCodeLogin() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(20)
                default:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在连接 Steam…").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 272, height: 272)
            Text("登录凭据安全保存在系统钥匙串中，下次启动会自动恢复。")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("使用网页登录") { useWebLogin = true }
                Spacer()
                Button("取消") { account.cancelAuthentication(); dismissWindow(id: SteamLoginWindow.id) }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var webLogin: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").foregroundStyle(.green)
                Text("steamcommunity.com").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                if account.supportsQRCode { Button("扫码登录") { useWebLogin = false } }
            }
            .padding(.horizontal, 14).padding(.vertical, 8).background(.bar)
            SteamLoginWebView(isLoading: $isLoading) {
                Task { await account.refreshFromCookies() }
            }
            Text("在 Steam 官方页面中登录。Scena 不读取或保存密码。此方式使用网页会话，过期后需要重新登录。")
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(10).frame(maxWidth: .infinity).background(.bar)
        }
    }
}

private struct SteamQRCode: View {
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
            } else { ProgressView() }
        }
        .frame(width: 232, height: 232)
        .padding(20)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityLabel("Steam 登录二维码，请使用手机 Steam 扫描")
        .task(id: url) {
            image = nil
            let value = url.absoluteString
            let rendered = await Task.detached {
                let filter = CIFilter.qrCodeGenerator()
                filter.message = Data(value.utf8)
                filter.correctionLevel = "M"
                guard let output = filter.outputImage else { return nil as CGImage? }
                return CIContext().createCGImage(output, from: output.extent)
            }.value
            guard !Task.isCancelled else { return }
            image = rendered
        }
    }
}

/// Window 场景可能保留内容视图，额外监听关闭事件，及时终止等待扫码的服务。
private struct SteamLoginCloseObserver: NSViewRepresentable {
    var onClose: () -> Void
    final class Probe: NSView {
        var onClose: () -> Void = {}
        private var observer: NSObjectProtocol?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            if let window {
                observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onClose() }
                }
            }
        }
        func detach() { if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.onClose = onClose; return view }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.onClose = onClose }
    static func dismantleNSView(_ nsView: Probe, coordinator: ()) { nsView.detach() }
}

private struct SteamLoginWebView: NSViewRepresentable {
    @Binding var isLoading: Bool
    let onNavigationFinished: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 默认的持久化存储：登录状态在 App 重启后仍然有效
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: SteamAccountSession.loginURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: SteamLoginWebView

        init(_ parent: SteamLoginWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            parent.onNavigationFinished()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
    }
}
