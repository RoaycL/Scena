import Foundation

/// 测试专用的偏好域。作为测试套件的存储属性：每个测试结束、套件实例释放时删除这些偏好文件。
/// 偏好域名使用临时目录下的绝对路径，文件直接写在临时目录里，不进入 ~/Library/Preferences：
/// 即使删除后 cfprefsd 又异步写回一个空文件，也只会落在系统会自动清理的临时目录
final class TestDefaults {
    private static let folder: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scena-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    private var names: [String] = []
    private var directories: [URL] = []

    func make() -> UserDefaults {
        let name = Self.folder.appendingPathComponent(UUID().uuidString).path
        names.append(name)
        return UserDefaults(suiteName: name)!
    }

    /// 测试专用的空目录（随测试结束删除）
    func makeDirectory() -> URL {
        let url = Self.folder.appendingPathComponent("dir-\(UUID().uuidString)", isDirectory: true)
        directories.append(url)
        return url
    }

    deinit {
        for name in names {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(atPath: name + ".plist")
        }
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
    }
}
