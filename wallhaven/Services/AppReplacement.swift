import Foundation
import Darwin

/// 先把新版完整复制到安装目录所在的磁盘，再原子交换；准备失败时旧应用始终留在原位。
nonisolated enum AppReplacement {
    static func replace(staged: URL, current: URL, bundleID: String,
                        copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }) throws {
        let fm = FileManager.default
        let candidate = current.deletingLastPathComponent().appendingPathComponent(".Scena-update-\(UUID().uuidString).app")
        defer { try? fm.removeItem(at: candidate) }
        try validate(staged, bundleID: bundleID)
        try copy(staged, candidate)
        try validate(candidate, bundleID: bundleID)
        let result = candidate.path.withCString { source in
            current.path.withCString { destination in renamex_np(source, destination, UInt32(RENAME_SWAP)) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // candidate 现在是旧版；只有交换成功后才允许清理。
    }

    private static func validate(_ app: URL, bundleID: String) throws {
        let info = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let values = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
              values["CFBundleIdentifier"] as? String == bundleID,
              let executable = values["CFBundleExecutable"] as? String,
              !executable.isEmpty, !executable.contains("/"),
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/\(executable)").path) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}
