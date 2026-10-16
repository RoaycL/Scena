import Darwin
import Foundation

/// 一次认证一个子进程；所有凭据只经私有管道传递，错误输出不进入日志。
final class SteamServiceClient: SteamAuthenticating {
    private let executable: URL?
    private let timeoutOverride: TimeInterval?
    private var operation: Operation?

    private final class Operation {
        let request: SteamServiceRequest
        let process: Process
        let input: FileHandle
        let output: FileHandle
        let onChallenge: @MainActor (URL) -> Void
        let continuation: CheckedContinuation<SteamAuthenticationResult, Error>
        var stream: Task<Void, Never>?
        var timeout: Task<Void, Never>?
        var result: SteamAuthenticationResult?
        var failure: Error?
        var ready = false

        init(request: SteamServiceRequest, process: Process, input: FileHandle, output: FileHandle,
             onChallenge: @escaping @MainActor (URL) -> Void,
             continuation: CheckedContinuation<SteamAuthenticationResult, Error>) {
            self.request = request; self.process = process; self.input = input; self.output = output
            self.onChallenge = onChallenge; self.continuation = continuation
        }
    }

    init(executable: URL? = nil, timeout: TimeInterval? = nil) {
        self.executable = executable ?? Self.bundledExecutable()
        timeoutOverride = timeout
    }

    static func bundledExecutable(in bundle: Bundle = .main) -> URL? {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return bundle.resourceURL?.appendingPathComponent("SteamService/\(arch)/ScenaSteamService")
    }

    var isAvailable: Bool { executable.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false }

    func authenticate(_ request: SteamServiceRequest, onChallenge: @escaping @MainActor (URL) -> Void) async throws -> SteamAuthenticationResult {
        guard isAvailable, let executable else { throw SteamAuthenticationError.componentMissing }
        finish(error: CancellationError())
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = executable
                process.arguments = []
                var environment = ProcessInfo.processInfo.environment
                environment["DOTNET_EnableDiagnostics"] = "0"
                environment["DOTNET_DbgEnableMiniDump"] = "0"
                process.environment = environment
                let input = Pipe(), output = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                let work = Operation(request: request, process: process,
                    input: input.fileHandleForWriting, output: output.fileHandleForReading,
                    onChallenge: onChallenge, continuation: continuation)
                operation = work
                process.terminationHandler = { [weak self] _ in
                    Task { @MainActor in
                        guard let self, let current = self.operation, current.request.id == request.id else { return }
                        await current.stream?.value
                        guard self.operation?.request.id == request.id else { return }
                        self.finish(error: current.failure ?? SteamAuthenticationError.connection)
                    }
                }
                do {
                    try process.run()
                    // 关闭父进程持有的子端，否则 EOF 可能永远不出现。
                    try? input.fileHandleForReading.close()
                    try? output.fileHandleForWriting.close()
                    work.stream = Task { [weak self] in
                        do {
                            for try await line in work.output.bytes.lines {
                                guard !Task.isCancelled, self?.operation?.request.id == request.id else { return }
                                guard line.utf8.count <= 65536 else { throw SteamAuthenticationError.protocolFailure }
                                try self?.receive(Data(line.utf8), for: work)
                            }
                        } catch {
                            guard self?.operation?.request.id == request.id else { return }
                            self?.finish(error: error is CancellationError ? error : SteamAuthenticationError.protocolFailure)
                        }
                    }
                    let seconds = timeoutOverride ?? (request.method == "qr" ? 250 : 60)
                    work.timeout = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                        guard self?.operation?.request.id == request.id else { return }
                        self?.finish(error: SteamAuthenticationError.timeout)
                    }
                } catch {
                    finish(error: SteamAuthenticationError.connection)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if self?.operation?.request.id == request.id { self?.finish(error: CancellationError()) }
            }
        }
    }

    private func receive(_ data: Data, for work: Operation) throws {
        guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any], message["v"] as? Int == 1,
              let type = message["type"] as? String else { throw SteamAuthenticationError.protocolFailure }
        if type == "ready" {
            guard !work.ready else { throw SteamAuthenticationError.protocolFailure }
            work.ready = true
            var request = try JSONEncoder().encode(work.request)
            request.append(10)
            try work.input.write(contentsOf: request)
            return
        }
        guard work.ready, message["id"] as? String == work.request.id else { throw SteamAuthenticationError.protocolFailure }
        switch type {
        case "qr":
            guard work.request.method == "qr", let value = message["challengeUrl"] as? String,
                  let url = URL(string: value), url.scheme == "https", url.host == "s.team",
                  url.path.hasPrefix("/q/"), url.user == nil, url.password == nil else {
                throw SteamAuthenticationError.protocolFailure
            }
            work.onChallenge(url)
        case "connecting", "authorizing": break
        case "result":
            guard work.result == nil else { throw SteamAuthenticationError.protocolFailure }
            let result = try JSONDecoder().decode(SteamAuthenticationResult.self, from: data)
            try result.validate()
            work.result = result
        case "error":
            work.failure = SteamAuthenticationError(code: message["code"] as? String)
            finish(error: work.failure!)
        default: throw SteamAuthenticationError.protocolFailure
        }
    }

    private func finish(error: Error) {
        guard let work = operation else { return }
        operation = nil
        work.timeout?.cancel()
        work.stream?.cancel()
        try? work.input.close()
        try? work.output.close()
        if work.process.isRunning {
            work.process.terminate()
            let pid = work.process.processIdentifier
            // 不占用主线程等退出，也不让不响应 SIGTERM 的组件一直占着会话。
            work.process.terminationHandler = nil
            Task {
                try? await Task.sleep(for: .seconds(1))
                if work.process.isRunning { kill(pid, SIGKILL) }
            }
        }
        // 令牌可能已经轮换，收到有效结果后即使组件异常退出也不能丢弃它。
        if let result = work.result { work.continuation.resume(returning: result) }
        else { work.continuation.resume(throwing: error) }
    }
}
