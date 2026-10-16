import Foundation

/// 测试专用的偏好域。作为测试套件的存储属性：每个测试结束、套件实例释放时，清空这些偏好域并删除 plist 文件。
/// removePersistentDomain 只清空内容，系统仍会留下一个空的 plist，所以还要删文件，
/// 否则每次跑测试都会在 ~/Library/Preferences 里多出几十个残留文件
final class TestDefaults {
    private var names: [String] = []

    func make() -> UserDefaults {
        let name = "scena.tests.\(UUID().uuidString)"
        names.append(name)
        return UserDefaults(suiteName: name)!
    }

    deinit {
        let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Preferences", isDirectory: true)
        for name in names {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            CFPreferencesAppSynchronize(name as CFString)
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(name).plist"))
        }
    }
}
