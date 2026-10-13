//
//  SteamLoginView.swift
//  wallhaven
//
//  内嵌 Steam 官方登录页。密码 / 令牌由用户在 Steam 页面中自己输入，
//  App 只在登录完成后读取会话 Cookie。
//

import SwiftUI
import WebKit

enum SteamLoginWindow {
    static let id = "steam-login"
}

struct SteamLoginView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject private var account = SteamAccountSession.shared
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").foregroundStyle(.green)
                Text("steamcommunity.com")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)

            SteamLoginWebView(isLoading: $isLoading) {
                Task {
                    if await account.refreshFromCookies() {
                        ToastCenter.shared.show("已登录 Steam：\(account.personaName ?? account.steamID ?? "")", style: .success)
                        dismissWindow(id: SteamLoginWindow.id)
                    }
                }
            }

            Text("在 Steam 官方页面中登录。Scena 不会读取或保存你的密码，只使用登录后的会话同步创意工坊订阅。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
        .frame(minWidth: 480, minHeight: 600)
    }
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
