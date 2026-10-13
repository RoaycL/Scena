//
//  SteamCMDDownloader.swift
//  wallhaven
//
//  用 steamcmd + 用户自己的 Steam 账号下载工坊条目（账号需拥有 Wallpaper Engine）。
//  App 不接触密码：首次登录在「终端」里由用户自己完成，之后 steamcmd 使用缓存的登录凭据，
//  下载时以 +@NoPromptForPassword 运行，凭据失效会直接报错而不是卡住等待输入。
//

import AppKit
import Foundation

enum SteamCMDError: LocalizedError {
    case notInstalled
    case missingUsername
    case notLoggedIn
    case accessDenied
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "未找到 steamcmd，请先安装（brew install --cask steamcmd）。"
        case .missingUsername: "请先在设置中填写 Steam 用户名。"
        case .notLoggedIn: "steamcmd 尚未登录或登录已过期，请在设置中点击「在终端登录」。"
        case .accessDenied: "下载被拒绝：该账号可能没有购买 Wallpaper Engine。"
        case .failed(let message): "下载失败：\(message)"
        }
    }
}

final class SteamCMDDownloader {
    static let shared = SteamCMDDownloader()

    private var running: [String: Process] = [:]

    static var candidatePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin/steamcmd",
            "/usr/local/bin/steamcmd",
            "\(home)/Steam/steamcmd.sh",
            "\(home)/steamcmd/steamcmd.sh",
            "\(home)/Library/Application Support/Steam/steamcmd.sh",
        ]
    }

    static func locate() -> URL? {
        candidatePaths
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func isValidUsername(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    func isDownloading(_ id: String) -> Bool { running[id] != nil }

    /// 是否有 steamcmd 下载正在进行
    var isBusy: Bool { !running.isEmpty }

    nonisolated struct BatchResult: Sendable {
        var downloaded: [String: URL] = [:]
        var failed: [String: String] = [:]
    }

    /// 下载单个条目并返回文件夹
    func download(id: String, username: String) async throws -> URL {
        let result = try await download(ids: [id], username: username)
        if let url = result.downloaded[id] { return url }
        throw SteamCMDError.failed(result.failed[id] ?? "steamcmd 未返回下载结果")
    }

    /// 一次登录下载多个条目（减少登录次数，也更快）
    func download(ids: [String], username: String) async throws -> BatchResult {
        guard let steamcmd = Self.locate() else { throw SteamCMDError.notInstalled }
        guard Self.isValidUsername(username) else { throw SteamCMDError.missingUsername }
        let ids = ids.filter { $0.allSatisfy(\.isNumber) }
        guard !ids.isEmpty else { throw SteamCMDError.failed("无效的工坊 ID") }

        let process = Process()
        process.executableURL = steamcmd
        try StorageManager.shared.ensureAvailable()
        var arguments = [
            "+@ShutdownOnFailedCommand", "0",
            "+@NoPromptForPassword", "1",
            "+@sSteamCmdForcePlatformType", "windows",
        ]
        // 设置了存储位置时，工坊壁纸下载到该位置（必须在 +login 之前）
        if let installDir = StorageManager.shared.workshopInstallDir {
            try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
            arguments += ["+force_install_dir", installDir.path]
        }
        arguments += ["+login", username]
        for id in ids {
            arguments += ["+workshop_download_item", WorkshopConstants.appID, id, "validate"]
        }
        arguments.append("+quit")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        for id in ids { running[id] = process }
        defer { for id in ids { running[id] = nil } }

        let output: String = try await withCheckedThrowingContinuation { continuation in
            // 持续读取输出，避免管道写满导致 steamcmd 阻塞
            let buffer = OutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                buffer.append(handle.availableData)
            }
            process.terminationHandler = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: buffer.text)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }

        return try Self.parse(output: output, ids: ids)
    }

    /// App 退出时终止下载，避免留下无人管理的 steamcmd 进程
    func terminateAll() {
        Set(running.values.map(ObjectIdentifier.init)).forEach { id in
            running.values.first { ObjectIdentifier($0) == id }?.terminate()
        }
    }

    func cancel(_ id: String) {
        running[id]?.terminate()
    }

    /// 在「终端」中运行一次交互式登录（密码 / Steam Guard 由用户自己输入）
    static func openLoginInTerminal(username: String) throws {
        guard let steamcmd = locate() else { throw SteamCMDError.notInstalled }
        guard isValidUsername(username) else { throw SteamCMDError.missingUsername }

        let script = """
        #!/bin/bash
        echo "正在登录 Steam（只需一次，之后 steamcmd 会缓存登录状态）"
        echo "请在下方输入密码和 Steam 令牌验证码。"
        echo "提示：输入密码时屏幕不会显示字符；请先切换到英文输入法，也可以直接粘贴。"
        echo
        "\(steamcmd.path)" +login "\(username)" +quit
        status=$?
        echo
        if [ $status -eq 0 ]; then
            echo "✅ 登录成功，可以关闭此窗口，回到 wallhaven 下载壁纸。"
        else
            echo "❌ 登录失败（退出码 $status）。请检查上方的错误信息："
            echo "   Invalid Password → 密码错误（注意输入法）；Rate Limit → 尝试次数过多，请稍后再试。"
            echo "   修正后在 wallhaven 设置里重新点击「在终端登录 steamcmd」。"
        fi
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wallhaven-steam-login.command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    nonisolated private static func parse(output: String, ids: [String]) throws -> BatchResult {
        var result = BatchResult()
        // 成功：Success. Downloaded item 123 to "/path/to/123" (456 bytes)
        for match in output.matches(of: /Success\. Downloaded item (\d+) to "([^"]+)"/) {
            result.downloaded[String(match.1)] = URL(fileURLWithPath: String(match.2), isDirectory: true)
        }
        // 失败：ERROR! Download item 123 failed (Access Denied).
        for match in output.matches(of: /Download item (\d+) failed \(([^)]*)\)/) {
            result.failed[String(match.1)] = String(match.2)
        }
        if !result.downloaded.isEmpty { return result }

        let loginErrors = ["Cached credentials not found", "Login Failure", "Invalid Password", "Two-factor", "need two-factor"]
        if loginErrors.contains(where: output.contains) {
            throw SteamCMDError.notLoggedIn
        }
        if output.contains("Access Denied") || output.contains("No subscription") {
            throw SteamCMDError.accessDenied
        }
        if result.failed.isEmpty {
            let lastError = output.split(whereSeparator: \.isNewline).last { $0.contains("ERROR") || $0.contains("Failure") }
            for id in ids { result.failed[id] = lastError.map(String.init) ?? "steamcmd 未返回下载结果" }
        }
        return result
    }
}

/// 在 Process 回调线程间安全收集输出
nonisolated private final class OutputBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
