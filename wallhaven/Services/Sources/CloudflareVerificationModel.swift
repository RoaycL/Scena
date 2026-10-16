import Combine
import Foundation

/// Cookie 只是候选值；必须用相同 UA 和候选 Cookie 成功访问被拦截页面才提交。
@MainActor final class CloudflareVerificationModel: ObservableObject {
    typealias Probe = @MainActor (URL, [String: String]) async throws -> Void
    @Published private(set) var isVerifying = false
    @Published private(set) var errorMessage: String?
    private let store: CloudflareClearanceStore
    private let probe: Probe
    private var generation = UUID()
    private var lastFingerprint: String?
    private var active = true
    private var completed = false

    init(store: CloudflareClearanceStore = .shared, probe: Probe? = nil) {
        self.store = store
        self.probe = probe ?? { url, headers in
            _ = try await SourceHTTP.data(from: url, emptyOnNotFound: false, extraHeaders: headers)
        }
    }

    func retry() { lastFingerprint = nil; errorMessage = nil }
    func cancel() { active = false; generation = UUID(); isVerifying = false }

    func inspect(cookies: [HTTPCookie], challenge: CloudflareChallengeRequiredError) async -> Bool {
        guard active, !completed, !isVerifying,
              let candidate = CloudflareClearanceStore.candidate(from: cookies, for: challenge.challengeURL),
              candidate.fingerprint != lastFingerprint,
              let cookie = candidate.header(for: challenge.challengeURL) else { return false }
        let epoch = generation
        lastFingerprint = candidate.fingerprint
        isVerifying = true
        defer { if epoch == generation { isVerifying = false } }
        do {
            try await probe(challenge.challengeURL, ["Cookie": cookie, "User-Agent": candidate.userAgent])
            guard active, epoch == generation, !Task.isCancelled else { return false }
            guard store.save(candidate, for: challenge.challengeURL) else { return false }
            completed = true
            errorMessage = nil
            return true
        } catch {
            guard active, epoch == generation, !Task.isCancelled else { return false }
            errorMessage = "图源仍未放行此请求。请继续完成页面验证，或点击重新检查。"
            return false
        }
    }
}
