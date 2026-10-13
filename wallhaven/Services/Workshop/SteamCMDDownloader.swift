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

    /// 下载并返回条目文件夹
    func download(id: String, username: String) async throws -> URL {
        guard let steamcmd = Self.locate() else { throw SteamCMDError.notInstalled }
        guard Self.isValidUsername(username) else { throw SteamCMDError.missingUsername }
        guard id.allSatisfy(\.isNumber) else { throw SteamCMDError.failed("无效的工坊 ID") }

        let process = Process()
        process.executableURL = steamcmd
        process.arguments = [
            "+@ShutdownOnFailedCommand", "1",
            "+@NoPromptForPassword", "1",
            "+@sSteamCmdForcePlatformType", "windows",
            "+login", username,
            "+workshop_download_item", WorkshopConstants.appID, id, "validate",
            "+quit",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        running[id] = process
        defer { running[id] = nil }

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

        return try Self.parse(output: output, id: id)
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

    nonisolated private static func parse(output: String, id: String) throws -> URL {
        // 成功：Success. Downloaded item 123 to "/path/to/123" (456 bytes)
        if let match = output.firstMatch(of: /Success\. Downloaded item \d+ to "([^"]+)"/) {
            return URL(fileURLWithPath: String(match.1), isDirectory: true)
        }
        let loginErrors = ["Cached credentials not found", "Login Failure", "Invalid Password", "Two-factor", "need two-factor"]
        if loginErrors.contains(where: output.contains) {
            throw SteamCMDError.notLoggedIn
        }
        if output.contains("Access Denied") || output.contains("No subscription") {
            throw SteamCMDError.accessDenied
        }
        let lastError = output.split(whereSeparator: \.isNewline).last { $0.contains("ERROR") || $0.contains("Failure") }
        throw SteamCMDError.failed(lastError.map(String.init) ?? "steamcmd 未返回下载结果")
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
