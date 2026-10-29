//
//  SteamContentDownloader.swift
//  wallhaven
//
//  直接从 Steam 内容 CDN 下载工坊条目（不需要 steamcmd）。由内置的 Steam 组件完成：
//  用扫码登录的账号连接 Steam，取条目清单，多路并发拉取分片、解密并校验，
//  先写入暂存目录，完整后再移动到资料库目录。暂停后保留暂存文件，下次只补缺失的分片。
//

import Darwin
import Foundation

nonisolated enum SteamContentError: LocalizedError, Equatable {
    case notOwned, unavailable, storage, connection, credentialsExpired, componentMissing, signedOut

    init(code: String?) {
        self = switch code {
        case "notOwned": .notOwned
        case "unavailable": .unavailable
        case "storage": .storage
        case "credentialsExpired", "accountUnavailable", "accessDenied": .credentialsExpired
        default: .connection
        }
    }

    var errorDescription: String? {
        switch self {
        case .notOwned: "此 Steam 账号没有 Wallpaper Engine，无法下载创意工坊内容。"
        case .unavailable: "该壁纸已下架、隐藏或不是 Wallpaper Engine 内容。"
        case .storage: "无法写入下载目录，请检查存储位置和剩余空间。"
        case .connection: "下载中断，请检查网络后重试。"
        case .credentialsExpired: "Steam 授权已失效，请重新扫码登录。"
        case .componentMissing: "此构建未包含 Steam 组件。"
        case .signedOut: "请先在设置中扫码登录 Steam。"
        }
    }
}

@MainActor
final class SteamContentDownloader {
    static let shared = SteamContentDownloader()

    nonisolated struct BatchResult: Sendable {
        var downloaded: [String: URL] = [:]
        var failed: [String: String] = [:]
        var versions: [String: WorkshopContentVersion] = [:]
    }

    enum Event {
        case progress(id: String, received: Int64, total: Int64)
        case downloaded(id: String, folder: URL)
    }

    private var process: Process?
    private let executableOverride: URL?

    init(executable: URL? = nil) { executableOverride = executable }

    private var executable: URL? { executableOverride ?? SteamServiceClient.bundledExecutable() }

    var isAvailable: Bool {
        executable.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
    }

    var isBusy: Bool { process != nil }

    /// 下载一批条目（组件内逐个处理，每个条目的分片并发下载）。
    /// 条目级失败记在结果里；登录失效、账号没有 Wallpaper Engine 等整体失败直接抛出
    func download(ids: [String], credential: SteamCredential, loginID: UInt32, contentRoot: URL, stagingRoot: URL,
                  concurrency: Int = 8, onEvent: @escaping @MainActor (Event) -> Void) async throws -> BatchResult {
        guard let executable, isAvailable else { throw SteamContentError.componentMissing }
        guard process == nil else { throw SteamContentError.connection }
        let ids = ids.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        guard !ids.isEmpty else { return BatchResult() }
        try FileManager.default.createDirectory(at: contentRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        let request = Request(id: UUID().uuidString, loginId: loginID, accountName: credential.accountName,
                              refreshToken: credential.refreshToken, ids: ids, contentRoot: contentRoot.path,
                              stagingRoot: stagingRoot.path, concurrency: concurrency)
        let process = Process()
        process.executableURL = executable
        var environment = ProcessInfo.processInfo.environment
        environment["DOTNET_EnableDiagnostics"] = "0"
        environment["DOTNET_DbgEnableMiniDump"] = "0"
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        self.process = process
        defer {
            self.process = nil
            try? input.fileHandleForWriting.close()
            Self.terminate(process)
        }

        var result = BatchResult()
        var failure: SteamContentError?
        var finished = false
        do {
            for try await line in output.fileHandleForReading.bytes.lines {
                guard line.utf8.count <= 65536,
                      let message = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      message["v"] as? Int == 1, let type = message["type"] as? String else {
                    throw SteamContentError.connection
                }
                if type == "ready" {
                    var data = try JSONEncoder().encode(request)
                    data.append(10)
                    try input.fileHandleForWriting.write(contentsOf: data)
                    continue
                }
                guard message["id"] as? String == request.id else { throw SteamContentError.connection }
                let itemID = message["itemId"] as? String
                switch type {
                case "progress":
                    if let itemID, let received = (message["receivedBytes"] as? NSNumber)?.int64Value,
                       let total = (message["totalBytes"] as? NSNumber)?.int64Value {
                        onEvent(.progress(id: itemID, received: received, total: total))
                    }
                case "itemDone":
                    guard let itemID, ids.contains(itemID), let path = message["folder"] as? String else { break }
                    let folder = URL(fileURLWithPath: path, isDirectory: true)
                    // 组件只能写到指定的资料库目录
                    guard folder.standardizedFileURL.deletingLastPathComponent().path == contentRoot.standardizedFileURL.path else { break }
                    result.downloaded[itemID] = folder
                    result.versions[itemID] = WorkshopContentVersion(json: message)
                    onEvent(.downloaded(id: itemID, folder: folder))
                case "itemError":
                    if let itemID, ids.contains(itemID) {
                        result.failed[itemID] = SteamContentError(code: message["code"] as? String).localizedDescription
                    }
                case "done":
                    finished = true
                case "error":
                    failure = SteamContentError(code: message["code"] as? String)
                default:
                    break
                }
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            failure = failure ?? .connection
        }
        if let failure, result.downloaded.isEmpty, result.failed.isEmpty { throw failure }
        if !finished {
            let message = (failure ?? .connection).localizedDescription
            for id in ids where result.downloaded[id] == nil && result.failed[id] == nil { result.failed[id] = message }
            if failure == .credentialsExpired || failure == .notOwned { throw failure! }
        }
        return result
    }

    /// 暂停 / 停止：结束组件进程。暂存文件保留，恢复时继续
    func cancelAll() {
        guard let process else { return }
        Self.terminate(process)
    }

    nonisolated private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        Task.detached {
            try? await Task.sleep(for: .seconds(2))
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private nonisolated struct Request: Encodable, Sendable {
        let v = 1
        let id: String
        let method = "download"
        let loginId: UInt32
        let accountName: String
        let refreshToken: String
        let ids: [String]
        let contentRoot: String
        let stagingRoot: String
        let concurrency: Int
    }
}
